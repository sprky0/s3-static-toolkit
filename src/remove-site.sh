#!/bin/bash
# =============================================================================
# AWS Resource Cleanup Script
# 
# This script removes all AWS resources created by the deployment scripts
# based on the JSON status file.
#
# Usage: ./cleanup.sh --status-file status.json [options]
# Options:
#   --status-file FILE     Path to the status JSON file (required)
#   --profile PROFILE      AWS CLI profile (optional)
#   --yes                  Skip all confirmation prompts
# =============================================================================

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Default values
AWS_PROFILE=""
STATUS_FILE=""
AUTO_APPROVE=false

# Function to display script usage
usage() {
    echo -e "${BOLD}Usage:${NC} $0 --status-file status.json [options]"
    echo -e "${BOLD}Options:${NC}"
    echo "  --status-file FILE     Path to the status JSON file (required)"
    echo "  --profile PROFILE      AWS CLI profile (optional)"
    echo "  --yes                  Skip all confirmation prompts"
    exit 1
}

# Function to display messages with timestamp
log() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    case $level in
        "INFO") 
            echo -e "${BLUE}[INFO]${NC} ${timestamp} - ${message}"
            ;;
        "SUCCESS") 
            echo -e "${GREEN}[SUCCESS]${NC} ${timestamp} - ${message}"
            ;;
        "WARN") 
            echo -e "${YELLOW}[WARNING]${NC} ${timestamp} - ${message}"
            ;;
        "ERROR") 
            echo -e "${RED}[ERROR]${NC} ${timestamp} - ${message}"
            ;;
        "STEP") 
            echo -e "\n${MAGENTA}[STEP]${NC} ${timestamp} - ${BOLD}${message}${NC}"
            ;;
    esac
}

# Function to confirm action with user
confirm_action() {
    local message=$1
    
    if [ "$AUTO_APPROVE" = true ]; then
        return 0
    fi
    
    echo -e "${YELLOW}${message} (y/n)${NC}"
    read -r response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to check for required commands
check_prerequisites() {
    log "STEP" "Checking prerequisites"
    
    local missing_tools=()
    
    for tool in aws jq; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=($tool)
        fi
    done
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log "ERROR" "Missing required tools: ${missing_tools[*]}"
        log "INFO" "Please install the required tools and try again."
        exit 1
    fi
    
    log "SUCCESS" "All required tools are installed"
}

# Function to validate status file
validate_status_file() {
    log "STEP" "Validating status file"
    
    if [ ! -f "$STATUS_FILE" ]; then
        log "ERROR" "Status file does not exist: $STATUS_FILE"
        exit 1
    fi
    
    if ! jq empty "$STATUS_FILE" 2>/dev/null; then
        log "ERROR" "Status file is not valid JSON: $STATUS_FILE"
        exit 1
    fi
    
    log "SUCCESS" "Status file is valid"
}

# Function to remove CloudFront distributions
remove_cloudfront_distributions() {
    log "STEP" "Removing CloudFront distributions"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    # Try to get distributions from different status file formats
    local distributions_json=$(jq -r '.distributions // {}' "$STATUS_FILE")
    if [ "$(echo "$distributions_json" | jq 'length')" -eq 0 ]; then
        # Alternative format: check for a single distribution
        local distribution_id=$(jq -r '.distribution_id // ""' "$STATUS_FILE")
        if [ -n "$distribution_id" ]; then
            distributions_json="{\"main\": {\"id\": \"$distribution_id\"}}"
        fi
    fi
    
    if [ "$(echo "$distributions_json" | jq 'length')" -eq 0 ]; then
        log "INFO" "No CloudFront distributions found in status file"
        return 0
    fi
    
    for domain in $(echo "$distributions_json" | jq -r 'keys[]'); do
        local distribution_id=""
        
        # Handle both formats (object or string)
        if echo "$distributions_json" | jq -e --arg domain "$domain" '.[$domain] | has("id")' > /dev/null; then
            distribution_id=$(echo "$distributions_json" | jq -r --arg domain "$domain" '.[$domain].id')
        else
            distribution_id=$(echo "$distributions_json" | jq -r --arg domain "$domain" '.[$domain]')
        fi
        
        if [ -z "$distribution_id" ] || [ "$distribution_id" = "null" ]; then
            log "WARN" "Invalid distribution ID for $domain"
            continue
        fi
        
        log "INFO" "Processing CloudFront distribution: $distribution_id ($domain)"
        
        # Check if distribution exists
        if ! $aws_cmd cloudfront get-distribution --id "$distribution_id" &>/dev/null; then
            log "INFO" "Distribution $distribution_id does not exist, skipping"
            continue
        fi
        
        # Get the current ETag and configuration
        local etag=$($aws_cmd cloudfront get-distribution --id "$distribution_id" --query "ETag" --output text)
        local config=$($aws_cmd cloudfront get-distribution-config --id "$distribution_id" --query "DistributionConfig" --output json)
        
        # Disable the distribution
        if [ "$(echo "$config" | jq '.Enabled')" = "true" ]; then
            log "INFO" "Disabling distribution $distribution_id"
            local disabled_config=$(echo "$config" | jq '.Enabled = false')
            
            $aws_cmd cloudfront update-distribution \
                --id "$distribution_id" \
                --distribution-config "$disabled_config" \
                --if-match "$etag" \
                >/dev/null
            
            if [ $? -ne 0 ]; then
                log "ERROR" "Failed to disable distribution $distribution_id"
                continue
            fi
            
            log "INFO" "Waiting for distribution $distribution_id to be deployed after disabling (this may take 5-10 minutes)..."
            $aws_cmd cloudfront wait distribution-deployed --id "$distribution_id"
        else
            log "INFO" "Distribution $distribution_id is already disabled"
        fi
        
        # Delete the distribution
        log "INFO" "Deleting distribution $distribution_id"
        
        # Get the current ETag again (it changes after update)
        etag=$($aws_cmd cloudfront get-distribution --id "$distribution_id" --query "ETag" --output text)
        
        $aws_cmd cloudfront delete-distribution \
            --id "$distribution_id" \
            --if-match "$etag"
        
        if [ $? -eq 0 ]; then
            log "SUCCESS" "Deleted CloudFront distribution $distribution_id"
        else
            log "ERROR" "Failed to delete CloudFront distribution $distribution_id"
        fi
    done
}

# Function to remove CloudFront Origin Access Controls
remove_origin_access_controls() {
    log "STEP" "Removing CloudFront Origin Access Controls"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    local oac_id=$(jq -r '.oac_id // ""' "$STATUS_FILE")
    if [ -z "$oac_id" ] || [ "$oac_id" = "null" ]; then
        log "INFO" "No Origin Access Control found in status file"
        return 0
    fi
    
    log "INFO" "Removing Origin Access Control: $oac_id"
    
    # Check if OAC exists
    if ! $aws_cmd cloudfront get-origin-access-control --id "$oac_id" &>/dev/null; then
        log "INFO" "Origin Access Control $oac_id does not exist, skipping"
        return 0
    fi
    
    # Delete OAC
    $aws_cmd cloudfront delete-origin-access-control --id "$oac_id"
    
    if [ $? -eq 0 ]; then
        log "SUCCESS" "Deleted Origin Access Control $oac_id"
    else
        log "ERROR" "Failed to delete Origin Access Control $oac_id"
    fi
}

# Function to remove ACM certificate
remove_certificate() {
    log "STEP" "Removing ACM certificate"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    local cert_arn=$(jq -r '.certificate_arn // ""' "$STATUS_FILE")
    if [ -z "$cert_arn" ] || [ "$cert_arn" = "null" ]; then
        log "INFO" "No certificate found in status file"
        return 0
    fi
    
    log "INFO" "Removing certificate: $cert_arn"
    
    # Certificate must be in us-east-1 for CloudFront
    local cert_region="us-east-1"
    
    # Check if certificate exists
    if ! $aws_cmd acm describe-certificate --certificate-arn "$cert_arn" --region "$cert_region" &>/dev/null; then
        log "INFO" "Certificate $cert_arn does not exist, skipping"
        return 0
    fi
    
    # Delete certificate
    $aws_cmd acm delete-certificate --certificate-arn "$cert_arn" --region "$cert_region"
    
    if [ $? -eq 0 ]; then
        log "SUCCESS" "Deleted certificate $cert_arn"
    else
        log "ERROR" "Failed to delete certificate $cert_arn"
    fi
}

# Function to remove S3 buckets
remove_s3_buckets() {
    log "STEP" "Removing S3 buckets"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    # Try different bucket formats in status file
    local buckets_to_remove=()
    
    # Check for buckets object
    local buckets_json=$(jq -r '.buckets // {}' "$STATUS_FILE")
    if [ "$(echo "$buckets_json" | jq 'length')" -gt 0 ]; then
        for domain in $(echo "$buckets_json" | jq -r 'keys[]'); do
            local bucket_name=$(echo "$buckets_json" | jq -r --arg domain "$domain" '.[$domain]')
            buckets_to_remove+=("$bucket_name")
        done
    fi
    
    # Check for single bucket
    local single_bucket=$(jq -r '.bucket_name // ""' "$STATUS_FILE")
    if [ -n "$single_bucket" ] && [ "$single_bucket" != "null" ]; then
        buckets_to_remove+=("$single_bucket")
    fi
    
    if [ ${#buckets_to_remove[@]} -eq 0 ]; then
        log "INFO" "No S3 buckets found in status file"
        return 0
    fi
    
    for bucket in "${buckets_to_remove[@]}"; do
        log "INFO" "Processing S3 bucket: $bucket"
        
        # Check if bucket exists
        if ! $aws_cmd s3api head-bucket --bucket "$bucket" 2>/dev/null; then
            log "INFO" "Bucket $bucket does not exist, skipping"
            continue
        fi
        
        # Empty the bucket first
        log "INFO" "Emptying bucket $bucket"
        $aws_cmd s3 rm "s3://$bucket" --recursive
        
        if [ $? -ne 0 ]; then
            log "WARN" "Failed to completely empty bucket $bucket"
        fi
        
        # Delete the bucket
        log "INFO" "Deleting bucket $bucket"
        $aws_cmd s3api delete-bucket --bucket "$bucket"
        
        if [ $? -eq 0 ]; then
            log "SUCCESS" "Deleted S3 bucket $bucket"
        else
            log "ERROR" "Failed to delete S3 bucket $bucket"
        fi
    done
}

# Function to remove Route53 DNS records
remove_dns_records() {
    log "STEP" "Removing Route53 DNS records"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    # Get zones information
    local zones_json="{}"
    
    # Check for zones object in status file
    if jq -e '.zones' "$STATUS_FILE" > /dev/null; then
        zones_json=$(jq -r '.zones' "$STATUS_FILE")
    else
        # Check for single zone
        local zone_id=$(jq -r '.zone_id // ""' "$STATUS_FILE")
        local domain=$(jq -r '.domain // ""' "$STATUS_FILE")
        
        if [ -n "$zone_id" ] && [ "$zone_id" != "null" ]; then
            if [ -z "$domain" ] || [ "$domain" = "null" ]; then
                domain="main"
            fi
            zones_json="{\"$domain\": \"$zone_id\"}"
        fi
    fi
    
    if [ "$(echo "$zones_json" | jq 'length')" -eq 0 ]; then
        log "INFO" "No Route53 zones found in status file"
        return 0
    fi
    
    # Get domains information
    local domains_json="[]"
    
    # Check for domains array in status file
    if jq -e '.domains_array' "$STATUS_FILE" > /dev/null; then
        domains_json=$(jq -r '.domains_array' "$STATUS_FILE")
    else
        # Check for single domain
        local domain=$(jq -r '.domain // ""' "$STATUS_FILE")
        if [ -n "$domain" ] && [ "$domain" != "null" ]; then
            domains_json="[\"$domain\"]"
        fi
    fi
    
    # Add target domain if it exists
    local target_domain=$(jq -r '.target_domain // ""' "$STATUS_FILE")
    if [ -n "$target_domain" ] && [ "$target_domain" != "null" ]; then
        domains_json=$(echo "$domains_json" | jq ". + [\"$target_domain\"]" 2>/dev/null || echo "$domains_json")
    fi
    
    # Process each domain
    for domain in $(echo "$domains_json" | jq -r '.[]'); do
        log "INFO" "Processing DNS records for domain: $domain"
        
        # Find zone for domain
        local zone_id=$(echo "$zones_json" | jq -r --arg domain "$domain" '.[$domain] // empty')
        if [ -z "$zone_id" ]; then
            # Try to find parent domain for subdomains
            IFS='.' read -ra DOMAIN_PARTS <<< "$domain"
            local parts_count=${#DOMAIN_PARTS[@]}
            
            if [ $parts_count -gt 2 ]; then
                local parent_domain="${DOMAIN_PARTS[$(($parts_count-2))]}.${DOMAIN_PARTS[$(($parts_count-1))]}"
                zone_id=$(echo "$zones_json" | jq -r --arg domain "$parent_domain" '.[$domain] // empty')
            fi
            
            if [ -z "$zone_id" ]; then
                log "WARN" "Could not find Route53 zone for $domain, skipping DNS record removal"
                continue
            fi
        fi
        
        # Check if zone exists
        if ! $aws_cmd route53 get-hosted-zone --id "$zone_id" &>/dev/null; then
            log "INFO" "Hosted zone $zone_id does not exist, skipping"
            continue
        fi
        
        # Find A records pointing to CloudFront
        log "INFO" "Finding A records for $domain in zone $zone_id"
        
        local records=$($aws_cmd route53 list-resource-record-sets \
            --hosted-zone-id "$zone_id" \
            --query "ResourceRecordSets[?Name=='${domain}.' && Type=='A']" \
            --output json)
        
        if [ "$(echo "$records" | jq 'length')" -eq 0 ]; then
            log "INFO" "No A records found for $domain in zone $zone_id"
            continue
        fi
        
        # Delete each record
        local change_batch=$(echo "$records" | jq '{
            Changes: [.[] | {
                Action: "DELETE",
                ResourceRecordSet: .
            }]
        }')
        
        log "INFO" "Deleting A records for $domain"
        $aws_cmd route53 change-resource-record-sets \
            --hosted-zone-id "$zone_id" \
            --change-batch "$change_batch"
        
        if [ $? -eq 0 ]; then
            log "SUCCESS" "Deleted A records for $domain"
        else
            log "ERROR" "Failed to delete A records for $domain"
        fi
    done
}

# Main execution
main() {
    # Process command line arguments
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
                shift
                shift
                ;;
            --yes)
                AUTO_APPROVE=true
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
    
    # Check for required parameters
    if [ -z "$STATUS_FILE" ]; then
        log "ERROR" "Status file is required"
        usage
    fi
    
    # Welcome message
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║            ${BOLD}AWS RESOURCE CLEANUP SCRIPT${NC}${CYAN}                     ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${BOLD}Status File:${NC} $STATUS_FILE"
    if [ -n "$AWS_PROFILE" ]; then
        echo -e "${BOLD}AWS Profile:${NC} $AWS_PROFILE"
    fi
    echo
    
    # Check prerequisites
    check_prerequisites
    
    # Validate status file
    validate_status_file
    
    # Display resources to be removed
    echo -e "${YELLOW}${BOLD}The following resources will be removed:${NC}"
    
    # CloudFront distributions
    local distributions_json=$(jq -r '.distributions // {}' "$STATUS_FILE")
    local distribution_id=$(jq -r '.distribution_id // ""' "$STATUS_FILE")
    if [ "$(echo "$distributions_json" | jq 'length')" -gt 0 ] || [ -n "$distribution_id" ]; then
        echo -e "  ${BOLD}CloudFront Distributions${NC}"
    fi
    
    # OAC
    local oac_id=$(jq -r '.oac_id // ""' "$STATUS_FILE")
    if [ -n "$oac_id" ] && [ "$oac_id" != "null" ]; then
        echo -e "  ${BOLD}CloudFront Origin Access Control${NC}"
    fi
    
    # Certificate
    local cert_arn=$(jq -r '.certificate_arn // ""' "$STATUS_FILE")
    if [ -n "$cert_arn" ] && [ "$cert_arn" != "null" ]; then
        echo -e "  ${BOLD}ACM Certificate${NC}"
    fi
    
    # S3 buckets
    local buckets_json=$(jq -r '.buckets // {}' "$STATUS_FILE")
    local bucket_name=$(jq -r '.bucket_name // ""' "$STATUS_FILE")
    if [ "$(echo "$buckets_json" | jq 'length')" -gt 0 ] || [ -n "$bucket_name" ]; then
        echo -e "  ${BOLD}S3 Buckets${NC}"
    fi
    
    # DNS records
    local zones_json=$(jq -r '.zones // {}' "$STATUS_FILE")
    local zone_id=$(jq -r '.zone_id // ""' "$STATUS_FILE")
    if [ "$(echo "$zones_json" | jq 'length')" -gt 0 ] || [ -n "$zone_id" ]; then
        echo -e "  ${BOLD}Route53 DNS Records${NC}"
    fi
    
    echo
    
    # Confirm cleanup
    if ! confirm_action "Are you sure you want to remove all these resources?"; then
        log "INFO" "Cleanup cancelled"
        exit 0
    fi
    
    # Execute cleanup steps in reverse order
    remove_cloudfront_distributions
    remove_origin_access_controls
    remove_certificate
    remove_s3_buckets
    remove_dns_records
    
    # Success message
    log "SUCCESS" "Cleanup completed"
}

# Run the script
main "$@"