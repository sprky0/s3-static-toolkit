#!/bin/bash

# AWS Static Site Deployment Script
# This script automates the deployment of a static website using:
# - S3 for storage
# - CloudFront for CDN
# - ACM for SSL certificate
# - Route53 for DNS

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
SAMPLE_HTML="<!DOCTYPE html><html><head><title>Deployment Successful</title></head><body><h1>Hello, World!</h1><p>Your static site is successfully deployed.</p></body></html>"

# Function to display usage information
usage() {
  echo "Usage: $0 --domain <domain> [options]"
  echo ""
  echo "Required:"
  echo "  --domain <domain>     Domain name for the static site (must be a Route53 hosted zone)"
  echo ""
  echo "Options:"
  echo "  --profile <profile>   AWS CLI profile to use"
  echo "  --region <region>     AWS region (default: us-east-1)"
  echo "  -y, --yes             Skip all confirmation prompts"
  echo "  --status-file <file>  File to track deployment status (default: deployment_status.json)"
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

# Function to update the status file
update_status() {
  local step=$1
  local status=$2
  local metadata=$3
  
  # Create the file with initial structure if it doesn't exist
  if [ ! -f "$STATUS_FILE" ]; then
    echo '{"steps":{}}' > "$STATUS_FILE"
  fi
  
  # Update the status file with jq
  if [ -z "$metadata" ]; then
    jq --arg step "$step" --arg status "$status" '.steps[$step] = {"status": $status, "timestamp": "'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'"}' "$STATUS_FILE" > "${STATUS_FILE}.tmp"
  else
    jq --arg step "$step" --arg status "$status" --argjson metadata "$metadata" '.steps[$step] = {"status": $status, "timestamp": "'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'", "metadata": $metadata}' "$STATUS_FILE" > "${STATUS_FILE}.tmp"
  fi
  
  mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
  log "INFO" "Status updated: $step -> $status"
}

# Function to check status and determine if a step should be skipped
check_status() {
  local step=$1
  
  if [ ! -f "$STATUS_FILE" ]; then
    return 1
  fi
  
  local status=$(jq -r --arg step "$step" '.steps[$step].status // "NOT_STARTED"' "$STATUS_FILE")
  
  if [ "$status" == "COMPLETED" ]; then
    log "INFO" "Step '$step' already completed. Skipping..."
    return 0
  else
    return 1
  fi
}

# Function to get metadata from the status file
get_metadata() {
  local step=$1
  local key=$2
  
  if [ ! -f "$STATUS_FILE" ]; then
    return 1
  fi
  
  jq -r --arg step "$step" --arg key "$key" '.steps[$step].metadata[$key] // empty' "$STATUS_FILE"
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

# Function to check if a Route53 hosted zone exists for the domain
check_hosted_zone() {
  local domain=$1
  local cmd="aws route53 list-hosted-zones-by-name --dns-name $domain. $AWS_PROFILE_ARG $AWS_REGION_ARG"
  
  log "INFO" "Checking if hosted zone exists for $domain..."
  local result=$(eval "$cmd")
  local zone_count=$(echo "$result" | jq -r --arg domain "$domain." '.HostedZones | map(select(.Name == $domain)) | length')
  
  if [ "$zone_count" -gt 0 ]; then
    local zone_id=$(echo "$result" | jq -r --arg domain "$domain." '.HostedZones | map(select(.Name == $domain)) | .[0].Id' | sed 's|/hostedzone/||')
    log "SUCCESS" "Found hosted zone for $domain (ID: $zone_id)"
    echo "$zone_id"
    return 0
  else
    log "ERROR" "No hosted zone found for $domain. Please create it first in Route53."
    return 1
  fi
}

# Function to create or check S3 bucket
create_s3_bucket() {
  local domain=$1
  local bucket_name="$domain-static-site"
  local step="create_s3_bucket"
  
  if check_status "$step"; then
    bucket_name=$(get_metadata "$step" "bucket_name")
    log "INFO" "Using existing bucket: $bucket_name"
    echo "$bucket_name"
    return 0
  fi
  
  log "INFO" "Creating S3 bucket: $bucket_name..."
  
  if confirm "Create S3 bucket '$bucket_name'?"; then
    # Check if bucket exists
    if aws s3api head-bucket --bucket "$bucket_name" $AWS_PROFILE_ARG $AWS_REGION_ARG 2>/dev/null; then
      log "INFO" "Bucket already exists: $bucket_name"
    else
      # Create the bucket
      local cmd="aws s3api create-bucket --bucket $bucket_name $AWS_PROFILE_ARG"
      
      # If region is not us-east-1, we need to specify LocationConstraint
      if [ "$AWS_REGION" != "us-east-1" ] && [ -n "$AWS_REGION" ]; then
        cmd="$cmd --create-bucket-configuration LocationConstraint=$AWS_REGION"
      fi
      
      eval "$cmd"
      
      if [ $? -ne 0 ]; then
        log "ERROR" "Failed to create S3 bucket"
        return 1
      fi
    fi
    
    # Enable static website hosting
    aws s3api put-bucket-website --bucket "$bucket_name" \
      --website-configuration '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"error.html"}}' \
      $AWS_PROFILE_ARG $AWS_REGION_ARG
    
    # Block public access
    aws s3api put-public-access-block --bucket "$bucket_name" \
      --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
      $AWS_PROFILE_ARG $AWS_REGION_ARG
    
    log "SUCCESS" "S3 bucket created and configured: $bucket_name"
    
    # Update status
    update_status "$step" "COMPLETED" "{\"bucket_name\": \"$bucket_name\"}"
    
    echo "$bucket_name"
    return 0
  else
    log "ERROR" "S3 bucket creation cancelled by user"
    return 1
  fi
}

# Function to create ACM certificate
create_acm_certificate() {
  local domain=$1
  local step="create_acm_certificate"
  
  if check_status "$step"; then
    cert_arn=$(get_metadata "$step" "certificate_arn")
    log "INFO" "Using existing ACM certificate: $cert_arn"
    echo "$cert_arn"
    return 0
  fi
  
  log "INFO" "Creating ACM certificate for $domain..."
  
  if confirm "Create new ACM certificate for '$domain'?"; then
    # ACM certificates for CloudFront must be in us-east-1
    local result=$(aws acm request-certificate \
      --domain-name "$domain" \
      --validation-method DNS \
      --region us-east-1 \
      $AWS_PROFILE_ARG)
    
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to create ACM certificate"
      return 1
    fi
    
    local cert_arn=$(echo "$result" | jq -r '.CertificateArn')
    log "SUCCESS" "ACM certificate request created: $cert_arn"
    
    # Wait for certificate details to be available
    log "INFO" "Waiting for certificate details..."
    sleep 5
    
    # Get validation details
    local cert_details=$(aws acm describe-certificate \
      --certificate-arn "$cert_arn" \
      --region us-east-1 \
      $AWS_PROFILE_ARG)
    
    # Extract validation record details
    local record_name=$(echo "$cert_details" | jq -r '.Certificate.DomainValidationOptions[0].ResourceRecord.Name')
    local record_value=$(echo "$cert_details" | jq -r '.Certificate.DomainValidationOptions[0].ResourceRecord.Value')
    local record_type=$(echo "$cert_details" | jq -r '.Certificate.DomainValidationOptions[0].ResourceRecord.Type')
    
    # Get the hosted zone ID
    local zone_id=$(check_hosted_zone "$domain")
    
    # Create validation DNS record
    log "INFO" "Creating DNS validation record..."
    local change_batch="{
      \"Changes\": [
        {
          \"Action\": \"UPSERT\",
          \"ResourceRecordSet\": {
            \"Name\": \"$record_name\",
            \"Type\": \"$record_type\",
            \"TTL\": 300,
            \"ResourceRecords\": [
              {
                \"Value\": \"$record_value\"
              }
            ]
          }
        }
      ]
    }"
    
    aws route53 change-resource-record-sets \
      --hosted-zone-id "$zone_id" \
      --change-batch "$change_batch" \
      $AWS_PROFILE_ARG $AWS_REGION_ARG
    
    log "INFO" "DNS validation record created. Waiting for certificate validation..."
    
    # Wait for validation to complete
    aws acm wait certificate-validated \
      --certificate-arn "$cert_arn" \
      --region us-east-1 \
      $AWS_PROFILE_ARG
    
    if [ $? -eq 0 ]; then
      log "SUCCESS" "Certificate validation completed"
      
      # Update status
      update_status "$step" "COMPLETED" "{\"certificate_arn\": \"$cert_arn\"}"
      
      echo "$cert_arn"
      return 0
    else
      log "ERROR" "Certificate validation timed out. You may need to manually check the status later."
      
      # Still save the ARN for later
      update_status "$step" "PENDING" "{\"certificate_arn\": \"$cert_arn\"}"
      
      echo "$cert_arn"
      return 1
    fi
  else
    log "ERROR" "ACM certificate creation cancelled by user"
    return 1
  fi
}

# Function to create CloudFront Origin Access Control (OAC)
create_origin_access_control() {
  local domain=$1
  local step="create_origin_access_control"
  
  if check_status "$step"; then
    oac_id=$(get_metadata "$step" "oac_id")
    log "INFO" "Using existing Origin Access Control: $oac_id"
    echo "$oac_id"
    return 0
  fi
  
  log "INFO" "Creating CloudFront Origin Access Control..."
  
  if confirm "Create Origin Access Control for S3 access?"; then
    local oac_name="$domain-s3-oac"
    local result=$(aws cloudfront create-origin-access-control \
      --origin-access-control-config "{
        \"Name\": \"$oac_name\",
        \"Description\": \"OAC for $domain static site\",
        \"SigningProtocol\": \"sigv4\",
        \"SigningBehavior\": \"always\",
        \"OriginAccessControlOriginType\": \"s3\"
      }" \
      $AWS_PROFILE_ARG $AWS_REGION_ARG)
    
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to create Origin Access Control"
      return 1
    fi
    
    local oac_id=$(echo "$result" | jq -r '.OriginAccessControl.Id')
    log "SUCCESS" "Origin Access Control created: $oac_id"
    
    # Update status
    update_status "$step" "COMPLETED" "{\"oac_id\": \"$oac_id\"}"
    
    echo "$oac_id"
    return 0
  else
    log "ERROR" "Origin Access Control creation cancelled by user"
    return 1
  fi
}

# Function to update S3 bucket policy for CloudFront access
update_bucket_policy() {
  local bucket_name=$1
  local oac_id=$2
  local step="update_bucket_policy"
  
  if check_status "$step"; then
    log "INFO" "Bucket policy already configured"
    return 0
  fi
  
  log "INFO" "Updating bucket policy to allow CloudFront access..."
  
  if confirm "Update bucket policy to allow CloudFront access?"; then
    # Create bucket policy
    local bucket_policy="{
      \"Version\": \"2012-10-17\",
      \"Statement\": [
        {
          \"Sid\": \"AllowCloudFrontServicePrincipal\",
          \"Effect\": \"Allow\",
          \"Principal\": {
            \"Service\": \"cloudfront.amazonaws.com\"
          },
          \"Action\": \"s3:GetObject\",
          \"Resource\": \"arn:aws:s3:::$bucket_name/*\",
          \"Condition\": {
            \"StringEquals\": {
              \"AWS:SourceArn\": \"arn:aws:cloudfront::$(aws sts get-caller-identity $AWS_PROFILE_ARG $AWS_REGION_ARG | jq -r .Account):distribution/*\"
            }
          }
        }
      ]
    }"
    
    aws s3api put-bucket-policy \
      --bucket "$bucket_name" \
      --policy "$bucket_policy" \
      $AWS_PROFILE_ARG $AWS_REGION_ARG
    
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to update bucket policy"
      return 1
    fi
    
    log "SUCCESS" "Bucket policy updated to allow CloudFront access"
    
    # Update status
    update_status "$step" "COMPLETED" "{}"
    
    return 0
  else
    log "ERROR" "Bucket policy update cancelled by user"
    return 1
  fi
}

# Function to create CloudFront distribution
create_cloudfront_distribution() {
  local domain=$1
  local bucket_name=$2
  local cert_arn=$3
  local oac_id=$4
  local step="create_cloudfront_distribution"
  
  if check_status "$step"; then
    distribution_id=$(get_metadata "$step" "distribution_id")
    distribution_domain=$(get_metadata "$step" "distribution_domain")
    log "INFO" "Using existing CloudFront distribution: $distribution_id ($distribution_domain)"
    echo "$distribution_id $distribution_domain"
    return 0
  fi
  
  log "INFO" "Creating CloudFront distribution for $bucket_name..."
  
  if confirm "Create CloudFront distribution for '$domain'?"; then
    # Create config file for distribution
    local distribution_config="{
      \"CallerReference\": \"$domain-$(date +%s)\",
      \"Aliases\": {
        \"Quantity\": 1,
        \"Items\": [\"$domain\"]
      },
      \"DefaultRootObject\": \"index.html\",
      \"Origins\": {
        \"Quantity\": 1,
        \"Items\": [
          {
            \"Id\": \"S3-$bucket_name\",
            \"DomainName\": \"$bucket_name.s3.amazonaws.com\",
            \"OriginPath\": \"\",
            \"S3OriginConfig\": {
              \"OriginAccessIdentity\": \"\"
            },
            \"OriginAccessControlId\": \"$oac_id\"
          }
        ]
      },
      \"DefaultCacheBehavior\": {
        \"TargetOriginId\": \"S3-$bucket_name\",
        \"ViewerProtocolPolicy\": \"redirect-to-https\",
        \"AllowedMethods\": {
          \"Quantity\": 2,
          \"Items\": [\"GET\", \"HEAD\"],
          \"CachedMethods\": {
            \"Quantity\": 2,
            \"Items\": [\"GET\", \"HEAD\"]
          }
        },
        \"CachePolicyId\": \"658327ea-f89d-4fab-a63d-7e88639e58f6\",
        \"Compress\": true
      },
      \"ViewerCertificate\": {
        \"ACMCertificateArn\": \"$cert_arn\",
        \"SSLSupportMethod\": \"sni-only\",
        \"MinimumProtocolVersion\": \"TLSv1.2_2021\"
      },
      \"Enabled\": true,
      \"HttpVersion\": \"http2and3\",
      \"PriceClass\": \"PriceClass_100\",
      \"Comment\": \"Distribution for $domain static site\"
    }"
    
    local result=$(aws cloudfront create-distribution \
      --distribution-config "$distribution_config" \
      $AWS_PROFILE_ARG $AWS_REGION_ARG)
    
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to create CloudFront distribution"
      return 1
    fi
    
    local distribution_id=$(echo "$result" | jq -r '.Distribution.Id')
    local distribution_domain=$(echo "$result" | jq -r '.Distribution.DomainName')
    
    log "SUCCESS" "CloudFront distribution created: $distribution_id ($distribution_domain)"
    
    # Update status
    update_status "$step" "COMPLETED" "{\"distribution_id\": \"$distribution_id\", \"distribution_domain\": \"$distribution_domain\"}"
    
    echo "$distribution_id $distribution_domain"
    return 0
  else
    log "ERROR" "CloudFront distribution creation cancelled by user"
    return 1
  fi
}

# Function to create Route53 DNS record
create_route53_record() {
  local domain=$1
  local distribution_domain=$2
  local step="create_route53_record"
  
  if check_status "$step"; then
    log "INFO" "Route53 record already created"
    return 0
  fi
  
  log "INFO" "Creating Route53 record to point $domain to CloudFront..."
  
  if confirm "Create Route53 record for '$domain' pointing to CloudFront?"; then
    # Get the hosted zone ID
    local zone_id=$(check_hosted_zone "$domain")
    
    # Create A record alias to CloudFront
    local change_batch="{
      \"Changes\": [
        {
          \"Action\": \"UPSERT\",
          \"ResourceRecordSet\": {
            \"Name\": \"$domain\",
            \"Type\": \"A\",
            \"AliasTarget\": {
              \"HostedZoneId\": \"Z2FDTNDATAQYW2\",
              \"DNSName\": \"$distribution_domain\",
              \"EvaluateTargetHealth\": false
            }
          }
        }
      ]
    }"
    
    aws route53 change-resource-record-sets \
      --hosted-zone-id "$zone_id" \
      --change-batch "$change_batch" \
      $AWS_PROFILE_ARG $AWS_REGION_ARG
    
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to create Route53 record"
      return 1
    fi
    
    log "SUCCESS" "Route53 record created for $domain -> $distribution_domain"
    
    # Update status
    update_status "$step" "COMPLETED" "{}"
    
    return 0
  else
    log "ERROR" "Route53 record creation cancelled by user"
    return 1
  fi
}

# Function to upload sample content
upload_sample_content() {
  local bucket_name=$1
  local step="upload_sample_content"
  
  if check_status "$step"; then
    log "INFO" "Sample content already uploaded"
    return 0
  fi
  
  log "INFO" "Uploading sample content to S3 bucket..."
  
  if confirm "Upload sample content to S3 bucket?"; then
    # Create temporary files
    local temp_dir=$(mktemp -d)
    local index_file="$temp_dir/index.html"
    local error_file="$temp_dir/error.html"
    
    echo "$SAMPLE_HTML" > "$index_file"
    echo "<!DOCTYPE html><html><head><title>Error</title></head><body><h1>Error</h1><p>The requested page was not found.</p></body></html>" > "$error_file"
    
    # Upload files
    aws s3 cp "$index_file" "s3://$bucket_name/index.html" --content-type "text/html" $AWS_PROFILE_ARG $AWS_REGION_ARG
    aws s3 cp "$error_file" "s3://$bucket_name/error.html" --content-type "text/html" $AWS_PROFILE_ARG $AWS_REGION_ARG
    
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to upload sample content"
      rm -rf "$temp_dir"
      return 1
    fi
    
    log "SUCCESS" "Sample content uploaded to S3 bucket"
    
    # Clean up
    rm -rf "$temp_dir"
    
    # Update status
    update_status "$step" "COMPLETED" "{}"
    
    return 0
  else
    log "ERROR" "Sample content upload cancelled by user"
    return 1
  fi
}

# Function to invalidate CloudFront cache
invalidate_cloudfront_cache() {
  local distribution_id=$1
  local step="invalidate_cloudfront_cache"
  
  if check_status "$step"; then
    log "INFO" "CloudFront cache already invalidated"
    return 0
  fi
  
  log "INFO" "Invalidating CloudFront cache..."
  
  if confirm "Invalidate CloudFront cache?"; then
    local result=$(aws cloudfront create-invalidation \
      --distribution-id "$distribution_id" \
      --paths "/*" \
      $AWS_PROFILE_ARG $AWS_REGION_ARG)
    
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to invalidate CloudFront cache"
      return 1
    fi
    
    local invalidation_id=$(echo "$result" | jq -r '.Invalidation.Id')
    log "SUCCESS" "CloudFront cache invalidation created: $invalidation_id"
    
    # Update status
    update_status "$step" "COMPLETED" "{\"invalidation_id\": \"$invalidation_id\"}"
    
    return 0
  else
    log "ERROR" "CloudFront cache invalidation cancelled by user"
    return 1
  fi
}

# Function to wait for CloudFront distribution to deploy
wait_for_distribution() {
  local distribution_id=$1
  local step="wait_for_distribution"
  
  if check_status "$step"; then
    log "INFO" "Distribution deployment already completed"
    return 0
  fi
  
  log "INFO" "Waiting for CloudFront distribution to deploy..."
  
  if confirm "Wait for CloudFront distribution to deploy? This may take 5-10 minutes."; then
    aws cloudfront wait distribution-deployed \
      --id "$distribution_id" \
      $AWS_PROFILE_ARG $AWS_REGION_ARG
    
    if [ $? -ne 0 ]; then
      log "WARN" "CloudFront distribution deployment is taking longer than expected"
      if confirm "Continue waiting?"; then
        aws cloudfront wait distribution-deployed \
          --id "$distribution_id" \
          $AWS_PROFILE_ARG $AWS_REGION_ARG
      fi
    fi
    
    log "SUCCESS" "CloudFront distribution deployed"
    
    # Update status
    update_status "$step" "COMPLETED" "{}"
    
    return 0
  else
    log "WARN" "Skipping wait for CloudFront distribution deployment"
    return 0
  fi
}

# Function to verify the deployment
verify_deployment() {
  local domain=$1
  local step="verify_deployment"
  
  if check_status "$step"; then
    log "INFO" "Deployment already verified"
    return 0
  fi
  
  log "INFO" "Verifying deployment..."
  
  if confirm "Verify deployment by checking site access?"; then
    # Check DNS resolution
    log "INFO" "Checking DNS resolution for $domain..."
    if host "$domain" >/dev/null 2>&1; then
      log "SUCCESS" "DNS resolves correctly for $domain"
    else
      log "WARN" "DNS resolution for $domain may not be complete yet"
    fi
    
    # Check HTTP access (follow redirects to HTTPS)
    log "INFO" "Checking website access..."
    if curl -s -o /dev/null -w "%{http_code}" -L "http://$domain/"; then
      log "SUCCESS" "Website is accessible"
    else
      log "WARN" "Website access check failed. This may be due to DNS or CloudFront propagation delays."
    fi
    
    # Update status
    update_status "$step" "COMPLETED" "{}"
    
    return 0
  else
    log "WARN" "Skipping deployment verification"
    return 0
  fi
}

# Main execution
main() {
  # Parse command line arguments
  while [[ $# -gt 0 ]]; do
    key="$1"
    
    case $key in
      --domain)
        DOMAIN="$2"
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
      --status-file)
        STATUS_FILE="$2"
        shift
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
  
  # Validate required parameters
  if [ -z "$DOMAIN" ]; then
    log "ERROR" "Domain name is required"
    usage
  fi
  
  # Check for required commands
  for cmd in aws jq host curl; do
    if ! command -v $cmd &> /dev/null; then
      log "ERROR" "Required command not found: $cmd"
      exit 1
    fi
  done
  
  log "INFO" "Starting deployment for domain: $DOMAIN"
  log "INFO" "Status file: $STATUS_FILE"
  
  # Execute deployment steps
  if ! check_hosted_zone "$DOMAIN"; then
    exit 1
  fi
  
  # Step 1: Create S3 bucket
  BUCKET_NAME=$(create_s3_bucket "$DOMAIN")
  if [ $? -ne 0 ]; then
    exit 1
  fi
  
  # Step 2: Create ACM certificate
  CERT_ARN=$(create_acm_certificate "$DOMAIN")
  if [ $? -ne 0 ]; then
    log "WARN" "Certificate validation may be in progress. You can run this script again later."
  fi
  
  # Step 3: Create CloudFront Origin Access Control
  OAC_ID=$(create_origin_access_control "$DOMAIN")
  if [ $? -ne 0 ]; then
    exit 1
  fi
  
  # Step 4: Update S3 bucket policy
  if ! update_bucket_policy "$BUCKET_NAME" "$OAC_ID"; then
    exit 1
  fi
  
  # Step 5: Create CloudFront distribution
  CF_RESULT=$(create_cloudfront_distribution "$DOMAIN" "$BUCKET_NAME" "$CERT_ARN" "$OAC_ID")
  if [ $? -ne 0 ]; then
    exit 1
  fi
  
  # Extract distribution ID and domain
  CF_DISTRIBUTION_ID=$(echo "$CF_RESULT" | cut -d ' ' -f 1)
  CF_DISTRIBUTION_DOMAIN=$(echo "$CF_RESULT" | cut -d ' ' -f 2)
  
  # Step 6: Create Route53 record
  if ! create_route53_record "$DOMAIN" "$CF_DISTRIBUTION_DOMAIN"; then
    exit 1
  fi
  
  # Step 7: Upload sample content
  if ! upload_sample_content "$BUCKET_NAME"; then
    exit 1
  fi
  
  # Step 8: Invalidate CloudFront cache
  if ! invalidate_cloudfront_cache "$CF_DISTRIBUTION_ID"; then
    exit 1
  fi
  
  # Step 9: Wait for distribution to deploy
  if ! wait_for_distribution "$CF_DISTRIBUTION_ID"; then
    log "WARN" "CloudFront distribution may still be deploying"
  fi
  
  # Step 10: Verify deployment
  if ! verify_deployment "$DOMAIN"; then
    log "WARN" "Deployment verification skipped or failed"
  fi
  
  log "SUCCESS" "Deployment completed successfully!"
  log "INFO" "Website URL: https://$DOMAIN"
  log "INFO" "CloudFront Distribution ID: $CF_DISTRIBUTION_ID"
  log "INFO" "S3 Bucket: $BUCKET_NAME"
  
  # Print deployment summary
  echo
  echo -e "${GREEN}===== DEPLOYMENT SUMMARY =====${NC}"
  echo "Domain: $DOMAIN"
  echo "S3 Bucket: $BUCKET_NAME"
  echo "CloudFront Distribution ID: $CF_DISTRIBUTION_ID"
  echo "CloudFront Domain: $CF_DISTRIBUTION_DOMAIN"
  echo "Status File: $STATUS_FILE"
  echo
  echo -e "${GREEN}To update your website, upload files to:${NC}"
  echo "aws s3 cp your-file.html s3://$BUCKET_NAME/ $AWS_PROFILE_ARG $AWS_REGION_ARG"
  echo
  echo -e "${GREEN}To invalidate CloudFront cache:${NC}"
  echo "aws cloudfront create-invalidation --distribution-id $CF_DISTRIBUTION_ID --paths '/*' $AWS_PROFILE_ARG $AWS_REGION_ARG"
  echo
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
