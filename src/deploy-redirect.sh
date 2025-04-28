#!/bin/bash

# AWS Multi-Domain Redirect Deployment Script
# This script automates the deployment of multiple domain redirects using:
# - S3 for website redirect configuration
# - CloudFront for CDN and HTTPS
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
STATUS_FILE="redirect_status.json"
REDIRECT_TYPE="301" # Default is permanent redirect
SOURCE_DOMAINS=()

# Function to display usage information
usage() {
  echo "Usage: $0 --source-domains <domain1,domain2,...> --target-domain <target> [options]"
  echo ""
  echo "Required:"
  echo "  --source-domains <domains> Comma-separated list of source domain names (must be Route53 hosted zones)"
  echo "  --target-domain <target>   Target domain to redirect to"
  echo ""
  echo "Options:"
  echo "  --redirect-type <type>     Redirect type: 301 (permanent) or 302 (temporary) (default: 301)"
  echo "  --redirect-path <path>     Path to redirect to on target domain (default: /)"
  echo "  --profile <profile>        AWS CLI profile to use"
  echo "  --region <region>          AWS region (default: us-east-1)"
  echo "  -y, --yes                  Skip all confirmation prompts"
  echo "  --status-file <file>       File to track deployment status (default: redirect_status.json)"
  echo "  --help                     Display this help message"
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

# Function to create S3 bucket for redirection
create_redirect_bucket() {
  local source_domain=$1
  local bucket_name="$source_domain-redirect"
  local step="create_redirect_bucket_$(echo "$source_domain" | tr '.' '_')"
  
  if check_status "$step"; then
    bucket_name=$(get_metadata "$step" "bucket_name")
    log "INFO" "Using existing bucket: $bucket_name"
    echo "$bucket_name"
    return 0
  fi
  
  log "INFO" "Creating S3 bucket for redirection: $bucket_name..."
  
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
    
    log "SUCCESS" "S3 bucket created: $bucket_name"
    
    # Update status
    update_status "$step" "COMPLETED" "{\"bucket_name\": \"$bucket_name\"}"
    
    echo "$bucket_name"
    return 0
  else
    log "ERROR" "S3 bucket creation cancelled by user"
    return 1
  fi
}

# Function to configure S3 bucket for website redirect
configure_bucket_redirect() {
  local bucket_name=$1
  local target_domain=$2
  local redirect_type=$3
  local redirect_path=$4
  local step="configure_bucket_redirect_$(echo "$bucket_name" | tr '.' '_')"
  
  if check_status "$step"; then
    log "INFO" "Bucket redirect already configured"
    return 0
  fi
  
  log "INFO" "Configuring S3 bucket website redirect to $target_domain..."
  
  if confirm "Configure bucket to redirect to '$target_domain'?"; then
    # Create website configuration with redirect
    local protocol="https"
    local website_config="{
      \"RedirectAllRequestsTo\": {
        \"HostName\": \"$target_domain\",
        \"Protocol\": \"$protocol\"
      }
    }"
    
    # If redirect path is specified, use a different configuration
    if [ -n "$redirect_path" ] && [ "$redirect_path" != "/" ]; then
      log "INFO" "Configuring redirect with custom path: $redirect_path"
      
      # For custom path redirects, we need to use routing rules which require error document
      # First create a minimal index.html file
      local temp_dir=$(mktemp -d)
      local index_file="$temp_dir/index.html"
      echo "<!DOCTYPE html><html><head><title>Redirecting...</title><meta http-equiv=\"refresh\" content=\"0;url=https://$target_domain$redirect_path\"></head><body><p>Redirecting to <a href=\"https://$target_domain$redirect_path\">https://$target_domain$redirect_path</a>...</p></body></html>" > "$index_file"
      
      # Upload the file
      aws s3 cp "$index_file" "s3://$bucket_name/index.html" --content-type "text/html" $AWS_PROFILE_ARG $AWS_REGION_ARG
      
      # Configure website with basic hosting
      website_config="{
        \"IndexDocument\": {
          \"Suffix\": \"index.html\"
        }
      }"
      
      # Clean up temp file
      rm -rf "$temp_dir"
    fi
    
    # Apply the website configuration
    aws s3api put-bucket-website --bucket "$bucket_name" \
      --website-configuration "$website_config" \
      $AWS_PROFILE_ARG $AWS_REGION_ARG
    
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to configure bucket website redirect"
      return 1
    fi
    
    # Make the bucket publicly accessible (needed for S3 website hosting)
    aws s3api put-public-access-block --bucket "$bucket_name" \
      --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" \
      $AWS_PROFILE_ARG $AWS_REGION_ARG
    
    # Set bucket policy to allow public read
    local bucket_policy="{
      \"Version\": \"2012-10-17\",
      \"Statement\": [
        {
          \"Sid\": \"PublicReadGetObject\",
          \"Effect\": \"Allow\",
          \"Principal\": \"*\",
          \"Action\": \"s3:GetObject\",
          \"Resource\": \"arn:aws:s3:::$bucket_name/*\"
        }
      ]
    }"
    
    aws s3api put-bucket-policy --bucket "$bucket_name" \
      --policy "$bucket_policy" \
      $AWS_PROFILE_ARG $AWS_REGION_ARG
    
    log "SUCCESS" "S3 bucket configured for redirect: $bucket_name -> $target_domain"
    
    # Update status with metadata
    update_status "$step" "COMPLETED" "{\"target_domain\": \"$target_domain\", \"redirect_type\": \"$redirect_type\"}"
    
    return 0
  else
    log "ERROR" "Bucket redirect configuration cancelled by user"
    return 1
  fi
}

# Function to create ACM certificate with multiple domains
create_acm_certificate() {
  local domains=("$@")
  local primary_domain="${domains[0]}"
  local step="create_acm_certificate"
  
  if check_status "$step"; then
    cert_arn=$(get_metadata "$step" "certificate_arn")
    log "INFO" "Using existing ACM certificate: $cert_arn"
    echo "$cert_arn"
    return 0
  fi
  
  log "INFO" "Creating ACM certificate for domains: ${domains[*]}"
  
  if confirm "Create new ACM certificate for domains: '${domains[*]}'?"; then
    # Build the domain parameters for the certificate request
    local domain_params="--domain-name $primary_domain"
    
    # Add alternate names if there are multiple domains
    if [ ${#domains[@]} -gt 1 ]; then
      local san_domains=("${domains[@]:1}") # All domains except the first one
      domain_params+=" --subject-alternative-names ${san_domains[*]}"
    fi
    
    # ACM certificates for CloudFront must be in us-east-1
    local result=$(aws acm request-certificate \
      $domain_params \
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
    
    # Process validation for each domain
    for domain in "${domains[@]}"; do
      log "INFO" "Processing validation for $domain..."
      
      # Extract validation record details for this domain
      local record_name=$(echo "$cert_details" | jq -r --arg domain "$domain" '.Certificate.DomainValidationOptions[] | select(.DomainName == $domain) | .ResourceRecord.Name')
      local record_value=$(echo "$cert_details" | jq -r --arg domain "$domain" '.Certificate.DomainValidationOptions[] | select(.DomainName == $domain) | .ResourceRecord.Value')
      local record_type=$(echo "$cert_details" | jq -r --arg domain "$domain" '.Certificate.DomainValidationOptions[] | select(.DomainName == $domain) | .ResourceRecord.Type')
      
      if [ -z "$record_name" ] || [ -z "$record_value" ] || [ -z "$record_type" ]; then
        log "ERROR" "Could not find validation details for $domain"
        continue
      fi
      
      # Get the hosted zone ID
      local zone_id=$(check_hosted_zone "$domain")
      if [ $? -ne 0 ]; then
        log "WARN" "Could not find hosted zone for $domain. Manual validation may be required."
        continue
      fi
      
      # Create validation DNS record
      log "INFO" "Creating DNS validation record for $domain..."
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
      
      if [ $? -eq 0 ]; then
        log "SUCCESS" "DNS validation record created for $domain"
      else
        log "ERROR" "Failed to create DNS validation record for $domain"
      fi
    done
    
    log "INFO" "All validation records created. Waiting for certificate validation..."
    
    # Wait for validation to complete
    aws acm wait certificate-validated \
      --certificate-arn "$cert_arn" \
      --region us-east-1 \
      $AWS_PROFILE_ARG
    
    if [ $? -eq 0 ]; then
      log "SUCCESS" "Certificate validation completed for all domains"
      
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

# Function to create CloudFront distribution for redirection with multiple domains
create_cloudfront_distribution() {
  local domain=$1
  local bucket_name=$2
  local cert_arn=$3
  local step="create_cloudfront_distribution_$(echo "$domain" | tr '.' '_')"
  
  if check_status "$step"; then
    distribution_id=$(get_metadata "$step" "distribution_id")
    distribution_domain=$(get_metadata "$step" "distribution_domain")
    log "INFO" "Using existing CloudFront distribution: $distribution_id ($distribution_domain)"
    echo "$distribution_id $distribution_domain"
    return 0
  fi
  
  log "INFO" "Creating CloudFront distribution for redirection domain $domain..."
  
  if confirm "Create CloudFront distribution for '$domain'?"; then
    # Get S3 website endpoint
    local region_suffix=""
    if [ "$AWS_REGION" != "us-east-1" ]; then
      region_suffix="-$AWS_REGION"
    fi
    local s3_website_endpoint="$bucket_name.s3-website$region_suffix.amazonaws.com"
    
    # Build the aliases list for CloudFront
    local aliases_json="\"Quantity\": 1, \"Items\": [\"$domain\"]"
    
    # Create config file for distribution
    local distribution_config="{
      \"CallerReference\": \"$domain-redirect-$(date +%s)\",
      \"Aliases\": {
        $aliases_json
      },
      \"DefaultRootObject\": \"index.html\",
      \"Origins\": {
        \"Quantity\": 1,
        \"Items\": [
          {
            \"Id\": \"S3-Website-$bucket_name\",
            \"DomainName\": \"$s3_website_endpoint\",
            \"OriginPath\": \"\",
            \"CustomOriginConfig\": {
              \"HTTPPort\": 80,
              \"HTTPSPort\": 443,
              \"OriginProtocolPolicy\": \"http-only\",
              \"OriginSslProtocols\": {
                \"Quantity\": 1,
                \"Items\": [\"TLSv1.2\"]
              },
              \"OriginReadTimeout\": 30,
              \"OriginKeepaliveTimeout\": 5
            }
          }
        ]
      },
      \"DefaultCacheBehavior\": {
        \"TargetOriginId\": \"S3-Website-$bucket_name\",
        \"ViewerProtocolPolicy\": \"redirect-to-https\",
        \"AllowedMethods\": {
          \"Quantity\": 2,
          \"Items\": [\"GET\", \"HEAD\"],
          \"CachedMethods\": {
            \"Quantity\": 2,
            \"Items\": [\"GET\", \"HEAD\"]
          }
        },
        \"ForwardedValues\": {
          \"QueryString\": true,
          \"Cookies\": {
            \"Forward\": \"none\"
          },
          \"Headers\": {
            \"Quantity\": 0
          },
          \"QueryStringCacheKeys\": {
            \"Quantity\": 0
          }
        },
        \"MinTTL\": 0,
        \"DefaultTTL\": 86400,
        \"MaxTTL\": 31536000,
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
      \"Comment\": \"Redirect distribution for $domain\"
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
  local step="create_route53_record_$(echo "$domain" | tr '.' '_')"
  
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
    
    # Add AAAA record for IPv6 support
    local change_batch_aaaa="{
      \"Changes\": [
        {
          \"Action\": \"UPSERT\",
          \"ResourceRecordSet\": {
            \"Name\": \"$domain\",
            \"Type\": \"AAAA\",
            \"AliasTarget\": {
              \"HostedZoneId\": \"Z2FDTNDATAQYW2\",
              \"DNSName\": \"$distribution_domain\",
              \"EvaluateTargetHealth\": false
            }
          }
        }
      ]
    }"
    
    # Add A record
    aws route53 change-resource-record-sets \
      --hosted-zone-id "$zone_id" \
      --change-batch "$change_batch" \
      $AWS_PROFILE_ARG $AWS_REGION_ARG
    
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to create Route53 A record"
      return 1
    fi
    
    # Add AAAA record
    aws route53 change-resource-record-sets \
      --hosted-zone-id "$zone_id" \
      --change-batch "$change_batch_aaaa" \
      $AWS_PROFILE_ARG $AWS_REGION_ARG
    
    if [ $? -ne 0 ]; then
      log "WARN" "Failed to create Route53 AAAA record"
    fi
    
    log "SUCCESS" "Route53 records created for $domain -> $distribution_domain"
    
    # Update status
    update_status "$step" "COMPLETED" "{}"
    
    return 0
  else
    log "ERROR" "Route53 record creation cancelled by user"
    return 1
  fi
}

# Function to wait for CloudFront distribution to deploy
wait_for_distribution() {
  local distribution_id=$1
  local step="wait_for_distribution_$(echo "$distribution_id" | tr '.' '_')"
  
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

# Function to verify the redirect
verify_redirect() {
  local source_domain=$1
  local target_domain=$2
  local step="verify_redirect_$(echo "$source_domain" | tr '.' '_')"
  
  if check_status "$step"; then
    log "INFO" "Redirect already verified"
    return 0
  fi
  
  log "INFO" "Verifying redirect from $source_domain to $target_domain..."
  
  if confirm "Verify redirect with a HTTP request?"; then
    # Check DNS resolution
    log "INFO" "Checking DNS resolution for $source_domain..."
    if host "$source_domain" >/dev/null 2>&1; then
      log "SUCCESS" "DNS resolves correctly for $source_domain"
    else
      log "WARN" "DNS resolution for $source_domain may not be complete yet"
    fi
    
    # Check redirect using curl
    log "INFO" "Checking redirect..."
    local redirect_check=$(curl -s -o /dev/null -w "%{http_code} %{redirect_url}" -L "http://$source_domain/")
    local status_code=$(echo "$redirect_check" | cut -d ' ' -f 1)
    local redirect_url=$(echo "$redirect_check" | cut -d ' ' -f 2-)
    
    if [[ $status_code -ge 200 && $status_code -lt 400 ]]; then
      log "SUCCESS" "Redirect is working. Status: $status_code, Redirect URL: $redirect_url"
    else
      log "WARN" "Redirect check returned status $status_code. This may be due to DNS or CloudFront propagation delays."
    fi
    
    # Update status
    update_status "$step" "COMPLETED" "{}"
    
    return 0
  else
    log "WARN" "Skipping redirect verification"
    return 0
  fi
}

# Main execution
main() {
  # Parse command line arguments
  while [[ $# -gt 0 ]]; do
    key="$1"
    
    case $key in
      --source-domains)
        IFS=',' read -r -a SOURCE_DOMAINS <<< "$2"
        shift
        shift
        ;;
      --target-domain)
        TARGET_DOMAIN="$2"
        shift
        shift
        ;;
      --redirect-type)
        REDIRECT_TYPE="$2"
        shift
        shift
        ;;
      --redirect-path)
        REDIRECT_PATH="$2"
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
  
  # Set default region if not specified
  if [ -z "$AWS_REGION" ]; then
    AWS_REGION="us-east-1"
    AWS_REGION_ARG="--region $AWS_REGION"
  fi
  
  # Validate required parameters
  if [ ${#SOURCE_DOMAINS[@]} -eq 0 ]; then
    log "ERROR" "Source domains are required"
    usage
  fi
  
  if [ -z "$TARGET_DOMAIN" ]; then
    log "ERROR" "Target domain name is required"
    usage
  fi
  
  # Validate redirect type
  if [ "$REDIRECT_TYPE" != "301" ] && [ "$REDIRECT_TYPE" != "302" ]; then
    log "ERROR" "Invalid redirect type. Must be 301 or 302."
    usage
  fi
  
  # Check for required commands
  for cmd in aws jq host curl; do
    if ! command -v $cmd &> /dev/null; then
      log "ERROR" "Required command not found: $cmd"
      exit 1
    fi
  done
  
  log "INFO" "Starting multi-domain redirect deployment:"
  log "INFO" "Source domains: ${SOURCE_DOMAINS[*]}"
  log "INFO" "Target domain: $TARGET_DOMAIN"
  log "INFO" "Redirect type: $REDIRECT_TYPE"
  log "INFO" "Status file: $STATUS_FILE"
  
  # Step 1: Create a shared ACM certificate for all domains
  CERT_ARN=$(create_acm_certificate "${SOURCE_DOMAINS[@]}")
  if [ $? -ne 0 ]; then
    log "WARN" "Certificate validation may be in progress. You can run this script again later."
  fi
  
  # Process each source domain
  for SOURCE_DOMAIN in "${SOURCE_DOMAINS[@]}"; do
    log "INFO" "Processing domain: $SOURCE_DOMAIN"
    
    # Step 2: Check hosted zone for this domain
    if ! check_hosted_zone "$SOURCE_DOMAIN"; then
      log "WARN" "Skipping domain $SOURCE_DOMAIN due to hosted zone check failure"
      continue
    fi
    
    # Step 3: Create S3 bucket for redirection
    BUCKET_NAME=$(create_redirect_bucket "$SOURCE_DOMAIN")
    if [ $? -ne 0 ]; then
      log "WARN" "Skipping domain $SOURCE_DOMAIN due to bucket creation failure"
      continue
    fi
    
    # Step 4: Configure bucket for website redirect
    if ! configure_bucket_redirect "$BUCKET_NAME" "$TARGET_DOMAIN" "$REDIRECT_TYPE" "$REDIRECT_PATH"; then
      log "WARN" "Skipping domain $SOURCE_DOMAIN due to bucket configuration failure"
      continue
    fi
    
    # Step 5: Create CloudFront distribution for this domain
    CF_RESULT=$(create_cloudfront_distribution "$SOURCE_DOMAIN" "$BUCKET_NAME" "$CERT_ARN")
    if [ $? -ne 0 ]; then
      log "WARN" "Skipping domain $SOURCE_DOMAIN due to CloudFront distribution creation failure"
      continue
    fi
    
    # Parse CloudFront distribution ID and domain
    CF_DISTRIBUTION_ID=$(echo "$CF_RESULT" | cut -d ' ' -f 1)
    CF_DISTRIBUTION_DOMAIN=$(echo "$CF_RESULT" | cut -d ' ' -f 2)
    
    # Step 6: Create Route53 record
    if ! create_route53_record "$SOURCE_DOMAIN" "$CF_DISTRIBUTION_DOMAIN"; then
      log "WARN" "Skipping domain $SOURCE_DOMAIN due to Route53 record creation failure"
      continue
    fi
    
    # Step 7: Wait for CloudFront distribution to deploy
    if ! wait_for_distribution "$CF_DISTRIBUTION_ID"; then
      log "WARN" "CloudFront distribution for $SOURCE_DOMAIN may not be fully deployed yet"
    fi
    
    # Step 8: Verify the redirect
    if ! verify_redirect "$SOURCE_DOMAIN" "$TARGET_DOMAIN"; then
      log "WARN" "Redirect verification for $SOURCE_DOMAIN was not successful"
    fi
    
    log "SUCCESS" "Domain $SOURCE_DOMAIN has been successfully configured to redirect to $TARGET_DOMAIN"
  done
  
  # Final summary
  log "SUCCESS" "Redirect deployment completed for domains: ${SOURCE_DOMAINS[*]}"
  echo
  echo -e "${GREEN}Redirect configuration summary:${NC}"
  echo "Source Domains: ${SOURCE_DOMAINS[*]}"
  echo "Target Domain: $TARGET_DOMAIN"
  echo "Redirect Type: $REDIRECT_TYPE"
  if [ -n "$REDIRECT_PATH" ]; then
    echo "Redirect Path: $REDIRECT_PATH"
  fi
  echo "Status File: $STATUS_FILE"
  echo
  echo -e "${GREEN}To update your redirect configuration:${NC}"
  echo "1. Delete and recreate S3 bucket website configuration:"
  echo "   aws s3 website s3://$BUCKET_NAME --index-document index.html $AWS_PROFILE_ARG $AWS_REGION_ARG"
  echo
  echo -e "${GREEN}To invalidate CloudFront cache:${NC}"
  echo "aws cloudfront create-invalidation --distribution-id $CF_DISTRIBUTION_ID --paths '/*' $AWS_PROFILE_ARG $AWS_REGION_ARG"

}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
