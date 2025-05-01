#!/bin/bash
# =============================================================================
# AWS Multiple Domain Redirect Script
#
# This script automates the setup of AWS infrastructure to redirect multiple source domains
# to a single target domain using AWS services (S3, CloudFront, ACM, and Route53).
# =============================================================================

set -e

# Default values
REGION="us-east-1"
PROFILE=""
YES_FLAG=false
STATUS_FILE="$HOME/.aws-redirect-status.json"

# Color codes for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Display usage information
usage() {
    echo "${BOLD}Usage:${NC} $0 [options]"
    echo "${BOLD}Options:${NC}"
    echo "  --source-domains <domains>   Comma-separated list of source domains to redirect (required)"
    echo "  --target-domain <domain>     The destination domain for redirects (required)"
    echo "  --profile <profile>          AWS CLI profile (optional)"
    echo "  --region <region>            AWS region (default: us-east-1)"
    echo "  --yes                        Skip confirmation prompts"
    echo "  --status-file <file>         Custom path for status tracking file"
    echo "  --help                       Display this help message"
    echo
    echo "Example:"
    echo "  $0 --source-domains example.com,www.example.com --target-domain target.example.com"
    exit 1
}

# Log formatted messages
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_level=$1
    local message=$2
    local color=$NC
    
    case $log_level in
        "INFO") color=$GREEN ;;
        "WARN") color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "DEBUG") color=$BLUE ;;
    esac
    
    echo -e "${color}[$timestamp] [$log_level] $message${NC}"
}

# Check if required tools are installed
check_prerequisites() {
    log "INFO" "Checking prerequisites..."
    
    local missing_tools=()
    
    if ! command -v aws &> /dev/null; then
        missing_tools+=("aws")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing_tools+=("jq")
    fi
    
    if ! command -v curl &> /dev/null; then
        missing_tools+=("curl")
    fi
    
    if ! command -v host &> /dev/null; then
        missing_tools+=("host")
    fi
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log "ERROR" "Missing required tools: ${missing_tools[*]}"
        log "ERROR" "Please install the missing tools and try again."
        exit 1
    fi
    
    log "INFO" "All required tools are installed."
}

# Check AWS configuration
check_aws_config() {
    log "INFO" "Checking AWS configuration..."
    
    local aws_cmd="aws"
    if [ -n "$PROFILE" ]; then
        aws_cmd="aws --profile $PROFILE"
    fi
    
    if ! $aws_cmd sts get-caller-identity &> /dev/null; then
        log "ERROR" "AWS credentials are not configured correctly."
        log "ERROR" "Please run 'aws configure' or provide a valid profile."
        exit 1
    fi
    
    local account_id=$($aws_cmd sts get-caller-identity --query Account --output text)
    local user=$($aws_cmd sts get-caller-identity --query Arn --output text)
    
    log "INFO" "AWS credentials configured correctly."
    log "INFO" "AWS Account: $account_id"
    log "INFO" "AWS User: $user"
    log "INFO" "AWS Region: $REGION"
}

# Initialize or load status file
init_status_file() {
    log "INFO" "Initializing status file at $STATUS_FILE..."
    
    if [ ! -f "$STATUS_FILE" ]; then
        echo "{}" > "$STATUS_FILE"
        log "INFO" "Created new status file."
    else
        log "INFO" "Using existing status file."
    fi
    
    # Update basic info
    update_status "source_domains" "$SOURCE_DOMAINS"
    update_status "target_domain" "$TARGET_DOMAIN"
    update_status "region" "$REGION"
    update_status "timestamp" "$(date '+%Y-%m-%d %H:%M:%S')"
    
    # Initialize arrays if they don't exist
    if ! jq -e '.domains' "$STATUS_FILE" &> /dev/null; then
        update_status_array "domains" "[]"
    fi
    
    if ! jq -e '.completed_steps' "$STATUS_FILE" &> /dev/null; then
        update_status_array "completed_steps" "[]"
    fi
}

# Update status file with key-value pair
update_status() {
    local key=$1
    local value=$2
    
    jq --arg key "$key" --arg value "$value" '.[$key] = $value' "$STATUS_FILE" > "$STATUS_FILE.tmp"
    mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}

# Update status file with array
update_status_array() {
    local key=$1
    local value=$2
    
    jq --arg key "$key" --argjson value "$value" '.[$key] = $value' "$STATUS_FILE" > "$STATUS_FILE.tmp"
    mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}

# Get value from status file
get_status() {
    local key=$1
    jq -r --arg key "$key" '.[$key] // empty' "$STATUS_FILE"
}

# Get array from status file
get_status_array() {
    local key=$1
    jq -c --arg key "$key" '.[$key] // []' "$STATUS_FILE"
}

# Check if a step was completed
is_step_completed() {
    local step=$1
    jq -e --arg step "$step" '.completed_steps | index($step) >= 0' "$STATUS_FILE" &> /dev/null
}

# Mark a step as completed
mark_step_completed() {
    local step=$1
    
    if ! is_step_completed "$step"; then
        local current_steps=$(get_status_array "completed_steps")
        local updated_steps=$(jq --arg step "$step" '. + [$step]' <<< "$current_steps")
        update_status_array "completed_steps" "$updated_steps"
        log "INFO" "Marked step '$step' as completed."
    fi
}

# Confirm action with user
confirm_action() {
    local message=$1
    
    if [ "$YES_FLAG" = true ]; then
        return 0
    fi
    
    read -p "$message [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY]) 
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Parse domains into an array
parse_domains() {
    log "INFO" "Parsing domain inputs..."
    
    # Parse source domains
    IFS=',' read -ra DOMAIN_LIST <<< "$SOURCE_DOMAINS"
    
    # Validate domains
    if [ ${#DOMAIN_LIST[@]} -eq 0 ]; then
        log "ERROR" "No source domains provided."
        exit 1
    fi
    
    if [ ${#DOMAIN_LIST[@]} -gt 100 ]; then
        log "ERROR" "Too many source domains provided (max 100)."
        exit 1
    fi
    
    # Remove duplicates
    UNIQUE_DOMAINS=($(echo "${DOMAIN_LIST[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
    
    # Create a JSON array of domains
    local domains_json="["
    for ((i=0; i<${#UNIQUE_DOMAINS[@]}; i++)); do
        domains_json+="\"${UNIQUE_DOMAINS[$i]}\""
        if [ $i -lt $((${#UNIQUE_DOMAINS[@]}-1)) ]; then
            domains_json+=","
        fi
    done
    domains_json+="]"
    
    update_status_array "domains" "$domains_json"
    
    log "INFO" "Found ${#UNIQUE_DOMAINS[@]} unique source domains."
    log "DEBUG" "Domains: ${UNIQUE_DOMAINS[*]}"
    log "INFO" "Target domain: $TARGET_DOMAIN"
}

# # Check Route53 hosted zones for all domains
# check_hosted_zones() {
#     if is_step_completed "check_hosted_zones"; then
#         log "INFO" "Hosted zones already checked. Skipping..."
#         return 0
#     fi
    
#     log "INFO" "Checking Route53 hosted zones..."
    
#     local aws_cmd="aws"
#     if [ -n "$PROFILE" ]; then
#         aws_cmd="aws --profile $PROFILE"
#     fi
    
#     # Check target domain
#     local target_zone_id=$($aws_cmd route53 list-hosted-zones-by-name --dns-name "$TARGET_DOMAIN." --max-items 1 --query "HostedZones[?Name=='$TARGET_DOMAIN.'].Id" --output text | cut -d'/' -f3)
    
#     if [ -z "$target_zone_id" ]; then
#         log "ERROR" "No Route53 hosted zone found for target domain: $TARGET_DOMAIN"
#         log "ERROR" "Please create a hosted zone for this domain before continuing."
#         exit 1
#     fi
    
#     update_status "target_zone_id" "$target_zone_id"
#     log "INFO" "Found hosted zone for target domain: $target_zone_id"
    
#     # Check source domains
#     local missing_zones=()
#     local domains_json="["
    
#     for domain in "${UNIQUE_DOMAINS[@]}"; do
#         local zone_id=$($aws_cmd route53 list-hosted-zones-by-name --dns-name "$domain." --max-items 1 --query "HostedZones[?Name=='$domain.'].Id" --output text | cut -d'/' -f3)
        
#         if [ -z "$zone_id" ]; then
#             missing_zones+=("$domain")
#         else
#             if [ $((${#domains_json}-1)) -gt 1 ]; then
#                 domains_json+=","
#             fi
#             domains_json+="{\"domain\":\"$domain\",\"zone_id\":\"$zone_id\"}"
#         fi
#     done
    
#     domains_json+="]"
#     update_status_array "domain_zones" "$domains_json"
    
#     if [ ${#missing_zones[@]} -gt 0 ]; then
#         log "ERROR" "No Route53 hosted zones found for these domains: ${missing_zones[*]}"
#         log "ERROR" "Please create hosted zones for these domains before continuing."
#         exit 1
#     fi
    
#     log "INFO" "All domains have Route53 hosted zones."
#     mark_step_completed "check_hosted_zones"
# }


# Check Route53 hosted zones for all domains
check_hosted_zones() {
    if is_step_completed "check_hosted_zones"; then
        log "INFO" "Hosted zones already checked. Skipping..."
        return 0
    fi
    
    log "INFO" "Checking Route53 hosted zones..."
    
    local aws_cmd="aws"
    if [ -n "$PROFILE" ]; then
        aws_cmd="aws --profile $PROFILE"
    fi
    
    # Check target domain
    local target_zone_id=$($aws_cmd route53 list-hosted-zones-by-name --dns-name "$TARGET_DOMAIN." --max-items 1 --query "HostedZones[?Name=='$TARGET_DOMAIN.'].Id" --output text | cut -d'/' -f3)
    
    if [ -z "$target_zone_id" ]; then
        log "ERROR" "No Route53 hosted zone found for target domain: $TARGET_DOMAIN"
        log "ERROR" "Please create a hosted zone for this domain before continuing."
        exit 1
    fi
    
    update_status "target_zone_id" "$target_zone_id"
    log "INFO" "Found hosted zone for target domain: $target_zone_id"
    
    # Check source domains
    local missing_zones=()
    local domains_json="["
    
    for domain in "${UNIQUE_DOMAINS[@]}"; do
        # Find the root domain by splitting on dots and taking the last two parts
        local domain_parts=(${domain//./ })
        local domain_length=${#domain_parts[@]}
        local root_domain=""
        
        if [ $domain_length -ge 2 ]; then
            root_domain="${domain_parts[$((domain_length-2))]}.${domain_parts[$((domain_length-1))]}"
        else
            root_domain="$domain"
        fi
        
        log "INFO" "Checking domain: $domain (root: $root_domain)"
        
        # Look for the hosted zone of the root domain
        local zone_id=$($aws_cmd route53 list-hosted-zones-by-name --dns-name "$root_domain." --max-items 1 --query "HostedZones[?Name=='$root_domain.'].Id" --output text | cut -d'/' -f3)
        
        if [ -z "$zone_id" ]; then
            missing_zones+=("$domain -> $root_domain")
        else
            if [ $((${#domains_json}-1)) -gt 1 ]; then
                domains_json+=","
            fi
            domains_json+="{\"domain\":\"$domain\",\"root_domain\":\"$root_domain\",\"zone_id\":\"$zone_id\"}"
        fi
    done
    
    domains_json+="]"
    update_status_array "domain_zones" "$domains_json"
    
    if [ ${#missing_zones[@]} -gt 0 ]; then
        log "ERROR" "No Route53 hosted zones found for the root domains of these domains: ${missing_zones[*]}"
        log "ERROR" "Please create hosted zones for these root domains before continuing."
        exit 1
    fi
    
    log "INFO" "All domains have corresponding Route53 hosted zones."
    mark_step_completed "check_hosted_zones"
}


# Create S3 bucket for redirection
create_s3_bucket() {
    if is_step_completed "create_s3_bucket"; then
        log "INFO" "S3 bucket already created. Skipping..."
        local bucket_name=$(get_status "s3_bucket_name")
        log "INFO" "Using existing S3 bucket: $bucket_name"
        return 0
    fi
    
    log "INFO" "Creating S3 bucket for redirection..."
    
    local aws_cmd="aws"
    if [ -n "$PROFILE" ]; then
        aws_cmd="aws --profile $PROFILE"
    fi
    
    # Generate a unique bucket name
    local timestamp=$(date +%s)
    local bucket_name="redirect-${timestamp}"
    
    # Create the bucket
    if [ "$REGION" = "us-east-1" ]; then
        $aws_cmd s3api create-bucket --bucket "$bucket_name" --region "$REGION"
    else
        $aws_cmd s3api create-bucket --bucket "$bucket_name" --region "$REGION" --create-bucket-configuration LocationConstraint="$REGION"
    fi
    
    # Configure website redirect
    local redirect_config="{\"RedirectAllRequestsTo\":{\"HostName\":\"$TARGET_DOMAIN\",\"Protocol\":\"https\"}}"
    $aws_cmd s3api put-bucket-website --bucket "$bucket_name" --website-configuration "$redirect_config"
    
    # Update status
    update_status "s3_bucket_name" "$bucket_name"
    update_status "s3_website_endpoint" "$bucket_name.s3-website-$REGION.amazonaws.com"
    
    log "INFO" "S3 bucket created and configured for redirection."
    log "INFO" "Bucket name: $bucket_name"
    log "INFO" "Website endpoint: $bucket_name.s3-website-$REGION.amazonaws.com"
    
    mark_step_completed "create_s3_bucket"
}

# Create ACM certificate
create_certificate() {
    if is_step_completed "create_certificate"; then
        log "INFO" "Certificate already created. Skipping..."
        local cert_arn=$(get_status "certificate_arn")
        log "INFO" "Using existing certificate: $cert_arn"
        return 0
    fi
    
    log "INFO" "Creating ACM certificate..."
    
    local aws_cmd="aws"
    if [ -n "$PROFILE" ]; then
        aws_cmd="aws --profile $PROFILE"
    fi
    
    # Build domain list for certificate
    local san_array=()
    for domain in "${UNIQUE_DOMAINS[@]}"; do
        # Validate domain format before adding
        if [[ "$domain" =~ ^(\*\.)?((([a-zA-Z0-9])|([a-zA-Z0-9][a-zA-Z0-9\-]{0,61}[a-zA-Z0-9]))\.)+([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])$ ]]; then
            san_array+=("$domain")
        else
            log "WARN" "Skipping invalid domain format: $domain"
        fi
    done
    
    # Request certificate - use proper JSON array formatting for SANs
    local sans_json=$(printf '%s\n' "${san_array[@]}" | jq -R . | jq -s .)
    
    # Request certificate
    local cert_arn=$($aws_cmd acm request-certificate \
        --domain-name "$TARGET_DOMAIN" \
        --subject-alternative-names "$sans_json" \
        --validation-method DNS \
        --region "$REGION" \
        --query CertificateArn \
        --output text)
    
    update_status "certificate_arn" "$cert_arn"
    log "INFO" "Certificate requested: $cert_arn"
    
    # Wait for certificate details to be available
    log "INFO" "Waiting for certificate details (this may take a moment)..."
    sleep 10
    
    # Get validation records
    local validation_records=$($aws_cmd acm describe-certificate \
        --certificate-arn "$cert_arn" \
        --region "$REGION" \
        --query "Certificate.DomainValidationOptions[].{Domain:DomainName,Name:ResourceRecord.Name,Type:ResourceRecord.Type,Value:ResourceRecord.Value}")
    
    update_status_array "validation_records" "$validation_records"
    
    # Create validation DNS records
    log "INFO" "Creating DNS validation records..."
    
    local domain_zones=$(get_status_array "domain_zones")
    local validation_records=$(get_status_array "validation_records")
    
    echo "$validation_records" | jq -c '.[]' | while read -r record; do
        local domain=$(echo "$record" | jq -r '.Domain')
        local record_name=$(echo "$record" | jq -r '.Name')
        local record_type=$(echo "$record" | jq -r '.Type')
        local record_value=$(echo "$record" | jq -r '.Value')
        
        # Find the matching zone
        local zone_id=""
        if [ "$domain" = "$TARGET_DOMAIN" ]; then
            zone_id=$(get_status "target_zone_id")
        else
            zone_id=$(echo "$domain_zones" | jq -r --arg domain "$domain" '.[] | select(.domain == $domain) | .zone_id')
        fi
        
        if [ -n "$zone_id" ]; then
            # Remove trailing dot from record name if present
            record_name=${record_name%.}
            
            # Create the DNS record
            local change_batch="{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$record_name\",\"Type\":\"$record_type\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"$record_value\"}]}}]}"
            
            $aws_cmd route53 change-resource-record-sets \
                --hosted-zone-id "$zone_id" \
                --change-batch "$change_batch"
            
            log "INFO" "Created validation record for $domain in zone $zone_id"
        else
            log "WARN" "Could not find zone ID for domain $domain"
        fi
    done
    
    # Wait for certificate validation
    log "INFO" "Waiting for certificate validation (this may take 5-30 minutes)..."
    $aws_cmd acm wait certificate-validated --certificate-arn "$cert_arn" --region "$REGION"
    
    log "INFO" "Certificate validated successfully."
    mark_step_completed "create_certificate"
}

# Create CloudFront distribution
create_cloudfront_distribution() {
    if is_step_completed "create_cloudfront_distribution"; then
        log "INFO" "CloudFront distribution already created. Skipping..."
        local dist_id=$(get_status "cloudfront_distribution_id")
        local dist_domain=$(get_status "cloudfront_domain")
        log "INFO" "Using existing CloudFront distribution: $dist_id ($dist_domain)"
        return 0
    fi
    
    log "INFO" "Creating CloudFront distribution..."
    
    local aws_cmd="aws"
    if [ -n "$PROFILE" ]; then
        aws_cmd="aws --profile $PROFILE"
    fi
    
    local bucket_domain=$(get_status "s3_website_endpoint")
    local cert_arn=$(get_status "certificate_arn")
    
    # Build domain aliases JSON array
    local aliases="["
    for ((i=0; i<${#UNIQUE_DOMAINS[@]}; i++)); do
        aliases+="\"${UNIQUE_DOMAINS[$i]}\""
        if [ $i -lt $((${#UNIQUE_DOMAINS[@]}-1)) ]; then
            aliases+=","
        fi
    done
    aliases+="]"
    
    # Create distribution configuration
    local dist_config=$(cat <<EOF
{
    "CallerReference": "redirect-$(date +%s)",
    "Origins": {
        "Quantity": 1,
        "Items": [
            {
                "Id": "S3Origin",
                "DomainName": "$bucket_domain",
                "CustomOriginConfig": {
                    "HTTPPort": 80,
                    "HTTPSPort": 443,
                    "OriginProtocolPolicy": "http-only",
                    "OriginSslProtocols": {
                        "Quantity": 1,
                        "Items": ["TLSv1.2"]
                    },
                    "OriginReadTimeout": 30,
                    "OriginKeepaliveTimeout": 5
                }
            }
        ]
    },
    "DefaultCacheBehavior": {
        "TargetOriginId": "S3Origin",
        "ViewerProtocolPolicy": "redirect-to-https",
        "AllowedMethods": {
            "Quantity": 2,
            "Items": ["GET", "HEAD"],
            "CachedMethods": {
                "Quantity": 2,
                "Items": ["GET", "HEAD"]
            }
        },
        "Compress": true,
        "DefaultTTL": 86400,
        "MinTTL": 0,
        "MaxTTL": 31536000,
        "ForwardedValues": {
            "QueryString": false,
            "Cookies": {
                "Forward": "none"
            },
            "Headers": {
                "Quantity": 0
            },
            "QueryStringCacheKeys": {
                "Quantity": 0
            }
        }
    },
    "Enabled": true,
    "Comment": "Distribution for domain redirects",
    "Aliases": {
        "Quantity": ${#UNIQUE_DOMAINS[@]},
        "Items": $aliases
    },
    "PriceClass": "PriceClass_100",
    "ViewerCertificate": {
        "ACMCertificateArn": "$cert_arn",
        "SSLSupportMethod": "sni-only",
        "MinimumProtocolVersion": "TLSv1.2_2021"
    },
    "HttpVersion": "http2",
    "DefaultRootObject": ""
}
EOF
)
    
    # Create the distribution
    local dist_result=$($aws_cmd cloudfront create-distribution --distribution-config "$dist_config" --region "$REGION")
    
    local dist_id=$(echo "$dist_result" | jq -r '.Distribution.Id')
    local dist_domain=$(echo "$dist_result" | jq -r '.Distribution.DomainName')
    
    update_status "cloudfront_distribution_id" "$dist_id"
    update_status "cloudfront_domain" "$dist_domain"
    
    log "INFO" "CloudFront distribution created."
    log "INFO" "Distribution ID: $dist_id"
    log "INFO" "Distribution domain: $dist_domain"
    
    mark_step_completed "create_cloudfront_distribution"
}

# Create DNS records for redirection
create_dns_records() {
    if is_step_completed "create_dns_records"; then
        log "INFO" "DNS records already created. Skipping..."
        return 0
    fi
    
    log "INFO" "Creating DNS records for redirection..."
    
    local aws_cmd="aws"
    if [ -n "$PROFILE" ]; then
        aws_cmd="aws --profile $PROFILE"
    fi
    
    local dist_domain=$(get_status "cloudfront_domain")
    local domain_zones=$(get_status_array "domain_zones")
    
    for domain in "${UNIQUE_DOMAINS[@]}"; do
        # Find the zone ID for this domain
        local zone_id=$(echo "$domain_zones" | jq -r --arg domain "$domain" '.[] | select(.domain == $domain) | .zone_id')
        
        if [ -n "$zone_id" ]; then
            # Create the DNS record
            local change_batch="{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$domain\",\"Type\":\"A\",\"AliasTarget\":{\"HostedZoneId\":\"Z2FDTNDATAQYW2\",\"DNSName\":\"$dist_domain\",\"EvaluateTargetHealth\":false}}}]}"
            
            $aws_cmd route53 change-resource-record-sets \
                --hosted-zone-id "$zone_id" \
                --change-batch "$change_batch"
            
            log "INFO" "Created A record for $domain pointing to CloudFront"
        else
            log "WARN" "Could not find zone ID for domain $domain"
        fi
    done
    
    log "INFO" "DNS records created for all domains."
    mark_step_completed "create_dns_records"
}

# Wait for CloudFront distribution to deploy
wait_for_distribution() {
    if is_step_completed "wait_for_distribution"; then
        log "INFO" "Already waited for distribution deployment. Skipping..."
        return 0
    fi
    
    log "INFO" "Waiting for CloudFront distribution to deploy (this may take 10-15 minutes)..."
    
    local aws_cmd="aws"
    if [ -n "$PROFILE" ]; then
        aws_cmd="aws --profile $PROFILE"
    fi
    
    local dist_id=$(get_status "cloudfront_distribution_id")
    
    local status="InProgress"
    while [ "$status" = "InProgress" ]; do
        sleep 60
        status=$($aws_cmd cloudfront get-distribution --id "$dist_id" --query "Distribution.Status" --output text)
        log "INFO" "Distribution status: $status"
    done
    
    if [ "$status" = "Deployed" ]; then
        log "INFO" "CloudFront distribution deployed successfully."
        mark_step_completed "wait_for_distribution"
    else
        log "ERROR" "CloudFront distribution failed to deploy. Status: $status"
        exit 1
    fi
}

# Verify the deployment
verify_deployment() {
    if is_step_completed "verify_deployment"; then
        log "INFO" "Deployment already verified. Skipping..."
        return 0
    fi
    
    log "INFO" "Verifying deployment..."
    
    local failed_domains=()
    
    for domain in "${UNIQUE_DOMAINS[@]}"; do
        log "INFO" "Testing domain: $domain"
        
        # Test DNS resolution
        if ! host "$domain" &> /dev/null; then
            log "WARN" "DNS resolution failed for $domain"
            failed_domains+=("$domain (DNS resolution failed)")
            continue
        fi
        
        # Test HTTP redirect
        local redirect_url=$(curl -s -I -L -o /dev/null -w '%{url_effective}' "http://$domain")
        if [[ "$redirect_url" != "https://$TARGET_DOMAIN"* ]]; then
            log "WARN" "HTTP redirect failed for $domain"
            log "WARN" "Expected: https://$TARGET_DOMAIN, Got: $redirect_url"
            failed_domains+=("$domain (HTTP redirect failed)")
            continue
        fi
        
        # Test HTTPS redirect
        local https_redirect_url=$(curl -s -I -L -o /dev/null -w '%{url_effective}' "https://$domain")
        if [[ "$https_redirect_url" != "https://$TARGET_DOMAIN"* ]]; then
            log "WARN" "HTTPS redirect failed for $domain"
            log "WARN" "Expected: https://$TARGET_DOMAIN, Got: $https_redirect_url"
            failed_domains+=("$domain (HTTPS redirect failed)")
            continue
        fi
        
        log "INFO" "Domain $domain redirects correctly."
    done
    
    if [ ${#failed_domains[@]} -gt 0 ]; then
        log "WARN" "Some domains failed verification: ${failed_domains[*]}"
        log "WARN" "This may be due to DNS propagation delays. Try again in a few minutes."
    else
        log "INFO" "All domains verified successfully."
        mark_step_completed "verify_deployment"
    fi
}

# Display deployment summary
display_summary() {
    log "INFO" "Deployment Summary:"
    log "INFO" "===================="
    log "INFO" "Source Domains: ${UNIQUE_DOMAINS[*]}"
    log "INFO" "Target Domain: $TARGET_DOMAIN"
    log "INFO" "Region: $REGION"
    log "INFO" "S3 Bucket: $(get_status "s3_bucket_name")"
    log "INFO" "Certificate ARN: $(get_status "certificate_arn")"
    log "INFO" "CloudFront Distribution: $(get_status "cloudfront_distribution_id")"
    log "INFO" "CloudFront Domain: $(get_status "cloudfront_domain")"
    log "INFO" "Status File: $STATUS_FILE"
    log "INFO" ""
    log "INFO" "Next Steps:"
    log "INFO" "1. DNS propagation may take up to 48 hours to complete worldwide."
    log "INFO" "2. You may need to clear your browser cache to see the redirects."
    log "INFO" "3. To monitor traffic, set up CloudFront access logs or CloudWatch metrics."
    log "INFO" ""
    log "INFO" "Cleanup (if needed):"
    log "INFO" "1. Delete the CloudFront distribution"
    log "INFO" "2. Delete the ACM certificate"
    log "INFO" "3. Delete the S3 bucket"
    log "INFO" "4. Remove DNS records"
    log "INFO" ""
    log "INFO" "Put hands on your hands and do a little dance around your desk, lazy code monkey!"
}

# Main function
main() {
    # Parse command-line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source-domains)
                SOURCE_DOMAINS="$2"
                shift 2
                ;;
            --target-domain)
                TARGET_DOMAIN="$2"
                shift 2
                ;;
            --profile)
                PROFILE="$2"
                shift 2
                ;;
            --region)
                REGION="$2"
                shift 2
                ;;
            --yes)
                YES_FLAG=true
                shift
                ;;
            --status-file)
                STATUS_FILE="$2"
                shift 2
                ;;
            --help)
                usage
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                usage
                ;;
        esac
    done
    
    # Check required parameters
    if [ -z "$SOURCE_DOMAINS" ]; then
        log "ERROR" "Source domains not specified."
        usage
    fi
    
    if [ -z "$TARGET_DOMAIN" ]; then
        log "ERROR" "Target domain not specified."
        usage
    fi
    
    # Initialize or load status file
    init_status_file
    
    # Check prerequisites
    check_prerequisites
    
    # Check AWS configuration
    check_aws_config
    
    # Parse domains
    parse_domains
    
    # Confirm deployment
    if ! confirm_action "Ready to deploy redirect infrastructure for ${#UNIQUE_DOMAINS[@]} domains. Continue?"; then
        log "INFO" "Deployment cancelled by user."
        exit 0
    fi
    
    # Execute deployment steps
    check_hosted_zones
    create_s3_bucket
    create_certificate
    create_cloudfront_distribution
    create_dns_records
    wait_for_distribution
    verify_deployment
    
    # Display summary
    display_summary
}

# Execute main function
main "$@"