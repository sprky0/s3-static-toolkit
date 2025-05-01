#!/bin/bash
# =============================================================================
# AWS Multiple Domain Redirect Cleanup Script
# 
# This script removes all AWS resources created by the deployment scripts
# based on the JSON status file.
# =============================================================================

set -e

# Default values
PROFILE=""
YES_FLAG=false
STATUS_FILE=""

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
    echo "  --status-file <file>         Path to status file from the original deployment (required)"
    echo "  --profile <profile>          AWS CLI profile (optional)"
    echo "  --yes                        Skip confirmation prompts"
    echo "  --help                       Display this help message"
    echo
    echo "Example:"
    echo "  $0 --status-file ~/.aws-redirect-status.json"
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
    local region=$(get_status "region")
    
    log "INFO" "AWS credentials configured correctly."
    log "INFO" "AWS Account: $account_id"
    log "INFO" "AWS User: $user"
    log "INFO" "AWS Region: $region"
}

# Load status file
load_status_file() {
    log "INFO" "Loading status file from $STATUS_FILE..."
    
    if [ ! -f "$STATUS_FILE" ]; then
        log "ERROR" "Status file not found: $STATUS_FILE"
        exit 1
    fi
    
    if ! jq empty "$STATUS_FILE" 2>/dev/null; then
        log "ERROR" "Status file is not valid JSON: $STATUS_FILE"
        exit 1
    fi
    
    # Validate required fields
    local required_fields=("cloudfront_distribution_id" "certificate_arn" "s3_bucket_name" "region")
    local missing_fields=()
    
    for field in "${required_fields[@]}"; do
        if [ -z "$(get_status "$field")" ]; then
            missing_fields+=("$field")
        fi
    done
    
    if [ ${#missing_fields[@]} -gt 0 ]; then
        log "ERROR" "Status file is missing required fields: ${missing_fields[*]}"
        exit 1
    fi
    
    log "INFO" "Status file loaded successfully."
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

# Delete CloudFront distribution
delete_cloudfront_distribution() {
    log "INFO" "Disabling and deleting CloudFront distribution..."
    
    local aws_cmd="aws"
    if [ -n "$PROFILE" ]; then
        aws_cmd="aws --profile $PROFILE"
    fi
    
    local dist_id=$(get_status "cloudfront_distribution_id")
    local region=$(get_status "region")
    
    if [ -z "$dist_id" ]; then
        log "WARN" "No CloudFront distribution ID found in status file. Skipping..."
        return 0
    fi
    
    # Check if distribution exists
    if ! $aws_cmd cloudfront get-distribution --id "$dist_id" --region "$region" &>/dev/null; then
        log "WARN" "CloudFront distribution $dist_id not found. Skipping..."
        return 0
    fi
    
    # Get the current configuration and ETag
    local dist_config=$($aws_cmd cloudfront get-distribution --id "$dist_id" --region "$region")
    local etag=$(echo "$dist_config" | jq -r '.ETag')
    
    # Disable the distribution if it's enabled
    local enabled=$(echo "$dist_config" | jq -r '.Distribution.DistributionConfig.Enabled')
    
    if [ "$enabled" = "true" ]; then
        log "INFO" "Disabling CloudFront distribution $dist_id..."
        
        # Update the configuration to disable it
        local updated_config=$(echo "$dist_config" | jq '.Distribution.DistributionConfig.Enabled = false')
        local config_only=$(echo "$updated_config" | jq '.Distribution.DistributionConfig')
        
        # Update the distribution
        $aws_cmd cloudfront update-distribution \
            --id "$dist_id" \
            --distribution-config "$config_only" \
            --if-match "$etag" \
            --region "$region" > /dev/null
        
        log "INFO" "CloudFront distribution disabled. Waiting for the change to propagate..."
        
        # Wait for deployment to complete
        local status="InProgress"
        while [ "$status" = "InProgress" ]; do
            sleep 30
            status=$($aws_cmd cloudfront get-distribution --id "$dist_id" --query "Distribution.Status" --output text --region "$region")
            log "INFO" "Distribution status: $status"
        done
    fi
    
    # Delete the distribution
    log "INFO" "Deleting CloudFront distribution $dist_id..."
    
    # Get the updated ETag
    dist_config=$($aws_cmd cloudfront get-distribution --id "$dist_id" --region "$region")
    etag=$(echo "$dist_config" | jq -r '.ETag')
    
    $aws_cmd cloudfront delete-distribution \
        --id "$dist_id" \
        --if-match "$etag" \
        --region "$region"
    
    log "INFO" "CloudFront distribution $dist_id deleted successfully."
}

# Delete ACM certificate
delete_certificate() {
    log "INFO" "Deleting ACM certificate..."
    
    local aws_cmd="aws"
    if [ -n "$PROFILE" ]; then
        aws_cmd="aws --profile $PROFILE"
    fi
    
    local cert_arn=$(get_status "certificate_arn")
    local region=$(get_status "region")
    
    if [ -z "$cert_arn" ]; then
        log "WARN" "No certificate ARN found in status file. Skipping..."
        return 0
    fi
    
    # Check if certificate exists
    if ! $aws_cmd acm describe-certificate --certificate-arn "$cert_arn" --region "$region" &>/dev/null; then
        log "WARN" "Certificate $cert_arn not found. Skipping..."
        return 0
    fi
    
    log "INFO" "Deleting certificate $cert_arn..."
    
    $aws_cmd acm delete-certificate \
        --certificate-arn "$cert_arn" \
        --region "$region"
    
    log "INFO" "Certificate $cert_arn deleted successfully."
}

# Delete DNS records
delete_dns_records() {
    log "INFO" "Removing DNS records for redirection..."
    
    local aws_cmd="aws"
    if [ -n "$PROFILE" ]; then
        aws_cmd="aws --profile $PROFILE"
    fi
    
    local dist_domain=$(get_status "cloudfront_domain")
    local domain_zones=$(get_status_array "domain_zones")
    local domains=$(get_status_array "domains")
    
    if [ -z "$dist_domain" ] || [ "$domains" = "[]" ]; then
        log "WARN" "No domains or CloudFront domain found in status file. Skipping DNS cleanup..."
        return 0
    fi
    
    echo "$domains" | jq -r '.[]' | while read -r domain; do
        # Find the zone ID for this domain
        local zone_id=$(echo "$domain_zones" | jq -r --arg domain "$domain" '.[] | select(.domain == $domain) | .zone_id')
        
        if [ -n "$zone_id" ]; then
            log "INFO" "Checking DNS records for $domain in zone $zone_id..."
            
            # Get existing record
            local record_sets=$($aws_cmd route53 list-resource-record-sets \
                --hosted-zone-id "$zone_id" \
                --query "ResourceRecordSets[?Name=='$domain.' && Type=='A']")
            
            local record_count=$(echo "$record_sets" | jq 'length')
            
            if [ "$record_count" -gt 0 ]; then
                local record=$(echo "$record_sets" | jq -c '.[0]')
                local is_alias=$(echo "$record" | jq -r 'has("AliasTarget")')
                
                if [ "$is_alias" = "true" ]; then
                    local target_domain=$(echo "$record" | jq -r '.AliasTarget.DNSName')
                    
                    # Remove any trailing dot from target_domain for comparison
                    target_domain=${target_domain%.}
                    
                    # Remove any trailing dot from dist_domain for comparison
                    local compare_dist_domain=${dist_domain%.}
                    
                    if [[ "$target_domain" == *"$compare_dist_domain"* ]]; then
                        log "INFO" "Removing A record for $domain pointing to CloudFront..."
                        
                        # Create the change batch
                        local change_batch="{\"Changes\":[{\"Action\":\"DELETE\",\"ResourceRecordSet\":$record}]}"
                        
                        $aws_cmd route53 change-resource-record-sets \
                            --hosted-zone-id "$zone_id" \
                            --change-batch "$change_batch"
                        
                        log "INFO" "Removed A record for $domain successfully."
                    else
                        log "WARN" "A record for $domain points to $target_domain, not to our CloudFront distribution. Skipping..."
                    fi
                else
                    log "WARN" "A record for $domain is not an alias record. Skipping..."
                fi
            else
                log "WARN" "No A record found for $domain. Skipping..."
            fi
        else
            log "WARN" "Could not find zone ID for domain $domain. Skipping..."
        fi
    done
    
    log "INFO" "DNS record cleanup completed."
}

# Delete S3 bucket
delete_s3_bucket() {
    log "INFO" "Deleting S3 bucket..."
    
    local aws_cmd="aws"
    if [ -n "$PROFILE" ]; then
        aws_cmd="aws --profile $PROFILE"
    fi
    
    local bucket_name=$(get_status "s3_bucket_name")
    
    if [ -z "$bucket_name" ]; then
        log "WARN" "No S3 bucket name found in status file. Skipping..."
        return 0
    fi
    
    # Check if bucket exists
    if ! $aws_cmd s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
        log "WARN" "S3 bucket $bucket_name not found. Skipping..."
        return 0
    fi
    
    log "INFO" "Removing website configuration from bucket $bucket_name..."
    $aws_cmd s3api delete-bucket-website --bucket "$bucket_name"
    
    log "INFO" "Emptying bucket $bucket_name..."
    $aws_cmd s3 rm "s3://$bucket_name" --recursive
    
    log "INFO" "Deleting bucket $bucket_name..."
    $aws_cmd s3api delete-bucket --bucket "$bucket_name"
    
    log "INFO" "S3 bucket $bucket_name deleted successfully."
}

# Delete validation DNS records
delete_validation_records() {
    log "INFO" "Removing certificate validation DNS records..."
    
    local aws_cmd="aws"
    if [ -n "$PROFILE" ]; then
        aws_cmd="aws --profile $PROFILE"
    fi
    
    local validation_records=$(get_status_array "validation_records")
    local domain_zones=$(get_status_array "domain_zones")
    local target_zone_id=$(get_status "target_zone_id")
    local target_domain=$(get_status "target_domain")
    
    if [ "$validation_records" = "[]" ]; then
        log "WARN" "No validation records found in status file. Skipping..."
        return 0
    fi
    
    echo "$validation_records" | jq -c '.[]' | while read -r record; do
        local domain=$(echo "$record" | jq -r '.Domain')
        local record_name=$(echo "$record" | jq -r '.Name')
        local record_type=$(echo "$record" | jq -r '.Type')
        local record_value=$(echo "$record" | jq -r '.Value')
        
        # Remove trailing dot from record name if present
        record_name=${record_name%.}
        
        # Add trailing dot for Route53 query
        record_name="${record_name}."
        
        # Find the matching zone
        local zone_id=""
        if [ "$domain" = "$target_domain" ]; then
            zone_id="$target_zone_id"
        else
            zone_id=$(echo "$domain_zones" | jq -r --arg domain "$domain" '.[] | select(.domain == $domain) | .zone_id')
        fi
        
        if [ -n "$zone_id" ]; then
            log "INFO" "Checking for validation record $record_name in zone $zone_id..."
            
            # Get existing record
            local record_sets=$($aws_cmd route53 list-resource-record-sets \
                --hosted-zone-id "$zone_id" \
                --query "ResourceRecordSets[?Name=='$record_name' && Type=='$record_type']")
            
            local record_count=$(echo "$record_sets" | jq 'length')
            
            if [ "$record_count" -gt 0 ]; then
                local existing_record=$(echo "$record_sets" | jq -c '.[0]')
                
                # Check if the value matches
                local existing_value=$(echo "$existing_record" | jq -r '.ResourceRecords[0].Value')
                
                if [ "$existing_value" = "$record_value" ]; then
                    log "INFO" "Removing validation record $record_name in zone $zone_id..."
                    
                    # Create the change batch
                    local change_batch="{\"Changes\":[{\"Action\":\"DELETE\",\"ResourceRecordSet\":$existing_record}]}"
                    
                    $aws_cmd route53 change-resource-record-sets \
                        --hosted-zone-id "$zone_id" \
                        --change-batch "$change_batch"
                    
                    log "INFO" "Removed validation record $record_name successfully."
                else
                    log "WARN" "Validation record $record_name exists but has a different value. Skipping..."
                fi
            else
                log "WARN" "Validation record $record_name not found in zone $zone_id. Skipping..."
            fi
        else
            log "WARN" "Could not find zone ID for domain $domain. Skipping validation record cleanup..."
        fi
    done
    
    log "INFO" "Certificate validation record cleanup completed."
}

# Update status file to mark cleanup completion
update_status_file() {
    log "INFO" "Updating status file to mark cleanup completion..."
    
    # Add cleanup information
    jq --arg timestamp "$(date '+%Y-%m-%d %H:%M:%S')" \
       '.cleanup_timestamp = $timestamp | .cleanup_completed = true' \
       "$STATUS_FILE" > "${STATUS_FILE}.new"
    
    mv "${STATUS_FILE}.new" "$STATUS_FILE"
    
    log "INFO" "Status file updated."
}

# Display cleanup summary
display_summary() {
    log "INFO" "Cleanup Summary:"
    log "INFO" "===================="
    log "INFO" "Source Domains: $(get_status_array "domains" | jq -r '. | join(", ")')"
    log "INFO" "Target Domain: $(get_status "target_domain")"
    log "INFO" "Region: $(get_status "region")"
    log "INFO" "S3 Bucket: $(get_status "s3_bucket_name") - REMOVED"
    log "INFO" "Certificate ARN: $(get_status "certificate_arn") - REMOVED"
    log "INFO" "CloudFront Distribution: $(get_status "cloudfront_distribution_id") - REMOVED"
    log "INFO" "DNS Records - REMOVED"
    log "INFO" "Status File: $STATUS_FILE - UPDATED"
    log "INFO" ""
    log "INFO" "All AWS resources created for domain redirection have been removed."
    log "INFO" "Note: DNS changes may take up to 48 hours to propagate worldwide."
}

# Main function
main() {
    # Parse command-line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status-file)
                STATUS_FILE="$2"
                shift 2
                ;;
            --profile)
                PROFILE="$2"
                shift 2
                ;;
            --yes)
                YES_FLAG=true
                shift
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
    if [ -z "$STATUS_FILE" ]; then
        log "ERROR" "Status file not specified."
        usage
    fi
    
    # Load status file
    load_status_file
    
    # Check prerequisites
    check_prerequisites
    
    # Check AWS configuration
    check_aws_config
    
    # Check if cleanup was already completed
    if [ "$(jq -r '.cleanup_completed // "false"' "$STATUS_FILE")" = "true" ]; then
        log "WARN" "Cleanup was already completed on $(jq -r '.cleanup_timestamp // "unknown"' "$STATUS_FILE")"
        if ! confirm_action "Do you want to run the cleanup again?"; then
            log "INFO" "Cleanup cancelled by user."
            exit 0
        fi
    fi
    
    # Confirm cleanup
    if ! confirm_action "This will remove all AWS resources created for domain redirection. Continue?"; then
        log "INFO" "Cleanup cancelled by user."
        exit 0
    fi
    
    # Execute cleanup steps in correct order
    delete_cloudfront_distribution
    delete_certificate
    delete_dns_records
    delete_validation_records
    delete_s3_bucket
    
    # Update status file
    update_status_file
    
    # Display summary
    display_summary
}

# Execute main function
main "$@"
