#!/bin/bash

# AWS Static Site Removal Script
# This script removes all resources created by the static site deployment script

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
AUTO_CONFIRM=false
STATUS_FILE="deployment_status.json"

# Function to display usage information
usage() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Options:"
  echo "  --status-file <file>  Status file from deployment (default: deployment_status.json)"
  echo "  --profile <profile>   AWS CLI profile to use"
  echo "  --region <region>     AWS region (default: us-east-1)"
  echo "  -y, --yes             Skip all confirmation prompts"
  echo "  --help                Display this help message"
  exit 1
}

# Function to log messages with timestamp
log() {
  local level=$1
  local message=$2
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  
  case $level in
    "INFO")
      echo -e "${BLUE}[INFO]${NC} $timestamp - $message"
      ;;
    "SUCCESS")
      echo -e "${GREEN}[SUCCESS]${NC} $timestamp - $message"
      ;;
    "WARN")
      echo -e "${YELLOW}[WARNING]${NC} $timestamp - $message"
      ;;
    "ERROR")
      echo -e "${RED}[ERROR]${NC} $timestamp - $message"
      ;;
    *)
      echo "$timestamp - $message"
      ;;
  esac
}

# Function to confirm with the user
confirm() {
  local message=$1
  
  if [ "$AUTO_CONFIRM" = true ]; then
    return 0
  fi
  
  echo -e "${YELLOW}$message (Y/n)${NC}"
  read -r answer
  
  if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
    return 1
  else
    return 0
  fi
}

# Function to get metadata from the status file
get_metadata() {
  local step=$1
  local key=$2
  
  if [ ! -f "$STATUS_FILE" ]; then
    log "ERROR" "Status file not found: $STATUS_FILE"
    return 1
  fi
  
  local value=$(jq -r --arg step "$step" --arg key "$key" '.steps[$step].metadata[$key] // empty' "$STATUS_FILE")
  
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    return 1
  fi
  
  echo "$value"
}

# Function to check if a step exists in the status file
step_exists() {
  local step=$1
  
  if [ ! -f "$STATUS_FILE" ]; then
    return 1
  fi
  
  local status=$(jq -r --arg step "$step" '.steps[$step].status // "NOT_FOUND"' "$STATUS_FILE")
  
  if [ "$status" = "NOT_FOUND" ]; then
    return 1
  else
    return 0
  fi
}

# Function to update the status file after removal
mark_as_removed() {
  local step=$1
  
  if [ ! -f "$STATUS_FILE" ]; then
    return 1
  fi
  
  jq --arg step "$step" '.steps[$step].status = "REMOVED" | .steps[$step].removed_at = "'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'"}' "$STATUS_FILE" > "${STATUS_FILE}.tmp"
  mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

# Function to remove CloudFront invalidation
remove_cloudfront_invalidation() {
  log "INFO" "CloudFront invalidations are automatically removed after 15 minutes"
  log "SUCCESS" "No action needed for invalidation removal"
  
  if step_exists "invalidate_cloudfront_cache"; then
    mark_as_removed "invalidate_cloudfront_cache"
  fi
  
  return 0
}

# Function to remove Route53 record
remove_route53_record() {
  local domain=$(jq -r '.domain // empty' "$STATUS_FILE")
  
  if [ -z "$domain" ]; then
    log "WARN" "Domain not found in status file"
    return 1
  fi
  
  local distribution_domain=$(get_metadata "create_cloudfront_distribution" "distribution_domain")
  
  if [ -z "$distribution_domain" ]; then
    log "WARN" "CloudFront distribution domain not found in status file"
    return 1
  fi
  
  log "INFO" "Removing Route53 record for $domain..."
  
  if confirm "Remove Route53 record for '$domain'?"; then
    # Find hosted zone
    local hosted_zones=$(aws route53 list-hosted-zones $AWS_PROFILE_ARG $AWS_REGION_ARG)
    local zone_id=""
    
    # Find the most specific zone for this domain
    for zone in $(echo "$hosted_zones" | jq -r '.HostedZones[].Id'); do
      # Extract just the ID without the /hostedzone/ prefix
      local clean_zone_id=$(echo "$zone" | sed 's|/hostedzone/||')
      local zone_name=$(aws route53 get-hosted-zone --id "$zone" $AWS_PROFILE_ARG $AWS_REGION_ARG | jq -r '.HostedZone.Name')
      
      # Remove trailing dot from zone name for comparison
      zone_name=${zone_name%?}
      
      if [[ "$domain" == *"$zone_name"* ]]; then
        zone_id=$clean_zone_id
        break
      fi
    done
    
    if [ -z "$zone_id" ]; then
      log "ERROR" "Could not find Route53 hosted zone for $domain"
      return 1
    fi
    
    # Get the current record
    local records=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" $AWS_PROFILE_ARG $AWS_REGION_ARG)
    local record=$(echo "$records" | jq -r --arg domain "$domain." '.ResourceRecordSets[] | select(.Name==$domain and .Type=="A" and .AliasTarget != null)')
    
    if [ -z "$record" ]; then
      log "WARN" "Route53 record not found for $domain"
      
      if step_exists "create_route53_record"; then
        mark_as_removed "create_route53_record"
      fi
      
      return 0
    fi
    
    # Create change batch for deletion
    local change_batch="{
      \"Changes\": [
        {
          \"Action\": \"DELETE\",
          \"ResourceRecordSet\": $record
        }
      ]
    }"
    
    aws route53 change-resource-record-sets \
      --hosted-zone-id "$zone_id" \
      --change-batch "$change_batch" \
      $AWS_PROFILE_ARG $AWS_REGION_ARG
    
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to remove Route53 record"
      return 1
    fi
    
    log "SUCCESS" "Route53 record removed for $domain"
    
    if step_exists "create_route53_record"; then
      mark_as_removed "create_route53_record"
    fi
    
    # Wait a bit for DNS propagation
    log "INFO" "Waiting for DNS changes to propagate..."
    sleep 10
    
    return 0
  else
    log "WARN" "Route53 record removal cancelled by user"
    return 1
  fi
}

# Function to remove CloudFront distribution
remove_cloudfront_distribution() {
  local distribution_id=$(get_metadata "create_cloudfront_distribution" "distribution_id")
  
  if [ -z "$distribution_id" ]; then
    log "WARN" "CloudFront distribution ID not found in status file"
    return 1
  fi
  
  log "INFO" "Removing CloudFront distribution $distribution_id..."
  
  if confirm "Remove CloudFront distribution '$distribution_id'?"; then
    # Get current config to check if it's disabled
    local distribution_config=$(aws cloudfront get-distribution-config \
      --id "$distribution_id" $AWS_PROFILE_ARG $AWS_REGION_ARG)
    
    local enabled=$(echo "$distribution_config" | jq -r '.DistributionConfig.Enabled')
    local etag=$(echo "$distribution_config" | jq -r '.ETag')
    
    # Disable the distribution if it's enabled
    if [ "$enabled" = "true" ]; then
      log "INFO" "Disabling CloudFront distribution before deletion..."
      
      # Update the config to disable the distribution
      local updated_config=$(echo "$distribution_config" | jq '.DistributionConfig.Enabled = false')
      
      aws cloudfront update-distribution \
        --id "$distribution_id" \
        --if-match "$etag" \
        --distribution-config "$(echo "$updated_config" | jq '.DistributionConfig')" \
        $AWS_PROFILE_ARG $AWS_REGION_ARG
      
      if [ $? -ne 0 ]; then
        log "ERROR" "Failed to disable CloudFront distribution"
        return 1
      fi
      
      log "INFO" "CloudFront distribution disabled. Waiting for deployment..."
      
      # Wait for the distribution to be deployed with the disabled state
      if confirm "Wait for CloudFront distribution to be disabled? This may take 5-10 minutes."; then
        aws cloudfront wait distribution-deployed \
          --id "$distribution_id" \
          $AWS_PROFILE_ARG $AWS_REGION_ARG
        
        if [ $? -ne 0 ]; then
          log "WARN" "CloudFront distribution is taking longer than expected to update"
        fi
      else
        log "WARN" "Skipping wait for CloudFront distribution update"
      fi
      
      # Get the updated etag
      distribution_config=$(aws cloudfront get-distribution-config \
        --id "$distribution_id" $AWS_PROFILE_ARG $AWS_REGION_ARG)
      
      etag=$(echo "$distribution_config" | jq -r '.ETag')
    fi
    
    # Delete the distribution
    log "INFO" "Deleting CloudFront distribution..."
    aws cloudfront delete-distribution \
      --id "$distribution_id" \
      --if-match "$etag" \
      $AWS_PROFILE_ARG $AWS_REGION_ARG
    
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to delete CloudFront distribution. It might still be in use or not fully disabled."
      return 1
    fi
    
    log "SUCCESS" "CloudFront distribution deleted"
    
    if step_exists "create_cloudfront_distribution"; then
      mark_as_removed "create_cloudfront_distribution"
    fi
    
    if step_exists "wait_for_distribution"; then
      mark_as_removed "wait_for_distribution"
    fi
    
    return 0
  else
    log "WARN" "CloudFront distribution removal cancelled by user"
    return 1
  fi
}

# Function to remove Origin Access Control
remove_origin_access_control() {
  local oac_id=$(get_metadata "create_origin_access_control" "oac_id")
  
  if [ -z "$oac_id" ]; then
    log "WARN" "Origin Access Control ID not found in status file"
    return 1
  fi
  
  log "INFO" "Removing Origin Access Control $oac_id..."
  
  if confirm "Remove Origin Access Control?"; then
    # First, get the etag for the OAC
    local oac_config=$(aws cloudfront get-origin-access-control \
      --id "$oac_id" $AWS_PROFILE_ARG $AWS_REGION_ARG)
    
    local etag=$(echo "$oac_config" | jq -r '.ETag')
    
    # Delete the OAC
    aws cloudfront delete-origin-access-control \
      --id "$oac_id" \
      --if-match "$etag" \
      $AWS_PROFILE_ARG $AWS_REGION_ARG
    
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to delete Origin Access Control. It might still be in use."
      return 1
    fi
    
    log "SUCCESS" "Origin Access Control deleted"
    
    if step_exists "create_origin_access_control"; then
      mark_as_removed "create_origin_access_control"
    fi
    
    return 0
  else
    log "WARN" "Origin Access Control removal cancelled by user"
    return 1
  fi
}

# Function to remove ACM certificate
remove_acm_certificate() {
  local cert_arn=$(get_metadata "create_acm_certificate" "certificate_arn")
  
  if [ -z "$cert_arn" ]; then
    log "WARN" "ACM certificate ARN not found in status file"
    return 1
  fi
  
  log "INFO" "Removing ACM certificate $cert_arn..."
  
  if confirm "Remove ACM certificate?"; then
    aws acm delete-certificate \
      --certificate-arn "$cert_arn" \
      --region us-east-1 \
      $AWS_PROFILE_ARG
    
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to delete ACM certificate. It might still be in use."
      return 1
    fi
    
    log "SUCCESS" "ACM certificate deleted"
    
    if step_exists "create_acm_certificate"; then
      mark_as_removed "create_acm_certificate"
    fi
    
    return 0
  else
    log "WARN" "ACM certificate removal cancelled by user"
    return 1
  fi
}

# Function to empty and remove S3 bucket
remove_s3_bucket() {
  local bucket_name=$(get_metadata "create_s3_bucket" "bucket_name")
  
  if [ -z "$bucket_name" ]; then
    log "WARN" "S3 bucket name not found in status file"
    return 1
  fi
  
  log "INFO" "Removing S3 bucket $bucket_name..."
  
  if confirm "Empty and remove S3 bucket '$bucket_name'?"; then
    # First, check if the bucket exists
    if ! aws s3api head-bucket --bucket "$bucket_name" $AWS_PROFILE_ARG $AWS_REGION_ARG 2>/dev/null; then
      log "WARN" "S3 bucket $bucket_name does not exist or you don't have access to it"
      
      if step_exists "create_s3_bucket"; then
        mark_as_removed "create_s3_bucket"
      fi
      
      if step_exists "update_bucket_policy"; then
        mark_as_removed "update_bucket_policy"
      fi
      
      if step_exists "upload_sample_content"; then
        mark_as_removed "upload_sample_content"
      }
      
      return 0
    fi
    
    # Empty the bucket
    log "INFO" "Emptying S3 bucket..."
    aws s3 rm "s3://$bucket_name/" --recursive $AWS_PROFILE_ARG $AWS_REGION_ARG
    
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to empty S3 bucket"
      return 1
    fi
    
    # Delete the bucket
    log "INFO" "Deleting S3 bucket..."
    aws s3api delete-bucket --bucket "$bucket_name" $AWS_PROFILE_ARG $AWS_REGION_ARG
    
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to delete S3 bucket"
      return 1
    fi
    
    log "SUCCESS" "S3 bucket emptied and deleted"
    
    if step_exists "create_s3_bucket"; then
      mark_as_removed "create_s3_bucket"
    fi
    
    if step_exists "update_bucket_policy"; then
      mark_as_removed "update_bucket_policy"
    fi
    
    if step_exists "upload_sample_content"; then
      mark_as_removed "upload_sample_content"
    fi
    
    return 0
  else
    log "WARN" "S3 bucket removal cancelled by user"
    return 1
  fi
}

# Function to clean up status file
cleanup_status_file() {
  if confirm "Mark deployment as fully removed in the status file?"; then
    # Add a summary section to the status file
    jq '. + {"removal_completed": true, "removal_timestamp": "'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'"}' "$STATUS_FILE" > "${STATUS_FILE}.tmp"
    mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    
    log "SUCCESS" "Status file updated with removal information"
    return 0
  else
    return 0
  fi
}

# Main execution
main() {
  # Parse command line arguments
  while [[ $# -gt 0 ]]; do
    key="$1"
    
    case $key in
      --status-file)
        STATUS_FILE="$2"
        shift
        shift
        ;;
      --profile)
        AWS_PROFILE="$2"
        AWS_PROFILE_ARG="--profile $AWS_PROFILE"
        shift
        shift
        ;;
      --region)
        AWS_REGION="$2"
        AWS_REGION_ARG="--region $AWS_REGION"
        shift
        shift
        ;;
      -y|--yes)
        AUTO_CONFIRM=true
        shift
        ;;
      --help)
        usage
        ;;
      *)
        echo "Unknown option: $1"
        usage
        ;;
    esac
  done
  
  # Check if status file exists
  if [ ! -f "$STATUS_FILE" ]; then
    log "ERROR" "Status file not found: $STATUS_FILE"
    exit 1
  fi
  
  # Check for required commands
  for cmd in aws jq; do
    if ! command -v $cmd &> /dev/null; then
      log "ERROR" "Required command not found: $cmd"
      exit 1
    fi
  done
  
  # Extract domain from status file if available
  DOMAIN=$(jq -r '.domain // empty' "$STATUS_FILE")
  if [ -z "$DOMAIN" ]; then
    # Try to extract domain from bucket name
    BUCKET_NAME=$(get_metadata "create_s3_bucket" "bucket_name")
    if [ -n "$BUCKET_NAME" ]; then
      DOMAIN=${BUCKET_NAME%-static-site}
    fi
  fi
  
  if [ -n "$DOMAIN" ]; then
    log "INFO" "Starting removal of resources for domain: $DOMAIN"
  else
    log "INFO" "Starting removal of resources from status file: $STATUS_FILE"
  fi
  
  # Display warning and confirmation
  echo
  echo -e "${RED}WARNING: This script will remove all AWS resources created by the deployment script.${NC}"
  echo -e "${RED}This action cannot be undone. All data in the S3 bucket will be permanently deleted.${NC}"
  echo
  
  if ! confirm "Do you want to proceed with removing all resources?"; then
    log "INFO" "Removal cancelled by user"
    exit 0
  fi
  
  # Execute removal steps in reverse order
  
  # Step 1: Remove CloudFront invalidation (no actual removal needed)
  remove_cloudfront_invalidation
  
  # Step 2: Remove Route53 record
  remove_route53_record
  
  # Step 3: Remove CloudFront distribution
  remove_cloudfront_distribution
  
  # Step 4: Remove Origin Access Control
  remove_origin_access_control
  
  # Step 5: Remove ACM certificate
  remove_acm_certificate
  
  # Step 6: Empty and remove S3 bucket
  remove_s3_bucket
  
  # Step 7: Clean up status file
  cleanup_status_file
  
  log "SUCCESS" "Resource removal completed!"
  
  # Print removal summary
  echo
  echo -e "${GREEN}===== REMOVAL SUMMARY =====${NC}"
  echo "Status File: $STATUS_FILE"
  
  # Check if any steps failed
  local failed_steps=$(jq -r '.steps | to_entries[] | select(.value.status != "REMOVED" and .value.status != "NOT_STARTED") | .key' "$STATUS_FILE")
  
  if [ -n "$failed_steps" ]; then
    echo -e "${YELLOW}The following resources may need manual cleanup:${NC}"
    echo "$failed_steps" | while read -r step; do
      echo "- $step"
    done
    echo
    echo -e "${YELLOW}Check the AWS Management Console to ensure all resources are properly removed.${NC}"
  else
    echo -e "${GREEN}All resources have been successfully removed.${NC}"
  fi
  echo
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi