#!/bin/bash
# =============================================================================
# AWS Multiple Domain Redirect Cleanup Script
# 
# This script removes all AWS resources created by the deployment scripts
# based on the JSON status file.
# =============================================================================

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Default values
PROFILE=""
YES_FLAG=false
STATUS_FILE=""

# Build the aws-cli command prefix once.
aws_cli() {
    local cmd="aws"
    if [ -n "$PROFILE" ]; then
        cmd="$cmd --profile $PROFILE"
    fi
    echo "$cmd"
}

# Resolve and validate the AWS account that owns the resources in $STATUS_FILE.
# Populates the global $ACCOUNT_ID. Exits the script (not a subshell) on
# mismatch. Do NOT call via command substitution — exit must hit the parent.
# - If status file has account_id, the current caller MUST match it (else abort).
# - If status file lacks account_id, fall back to current caller and warn.
resolve_account_id() {
    local status_account=$(jq -r '.account_id // ""' "$STATUS_FILE")
    local aws_cmd=$(aws_cli)
    local caller_account
    if ! caller_account=$($aws_cmd sts get-caller-identity --query Account --output text 2>/dev/null); then
        log "ERROR" "Cannot determine current AWS account. Check credentials/profile."
        exit 1
    fi

    if [ -n "$status_account" ] && [ "$status_account" != "null" ]; then
        if [ "$status_account" != "$caller_account" ]; then
            log "ERROR" "Status file was created under account $status_account but current caller is $caller_account."
            log "ERROR" "Refusing to touch resources that may not belong to you. Switch profile and retry."
            exit 1
        fi
        ACCOUNT_ID="$status_account"
    else
        log "WARN" "Status file has no account_id; falling back to current caller ($caller_account)."
        log "WARN" "Bucket ownership will still be enforced via --expected-bucket-owner."
        ACCOUNT_ID="$caller_account"
    fi
}

# Display usage information
usage() {
    local exit_code="${1:-1}"
    echo "${BOLD}Usage:${NC} $0 [options]"
    echo "${BOLD}Options:${NC}"
    echo "  --status-file <file>         Path to status file from the original deployment (required)"
    echo "  --profile <profile>          AWS CLI profile (optional)"
    echo "  --yes                        Skip confirmation prompts"
    echo "  --help                       Display this help message"
    echo
    echo "Example:"
    echo "  $0 --status-file ./.deploy-status-redirect-example.com.json"
    exit "$exit_code"
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

# =============================================================================
# Plan: query AWS for the live state of every resource named in the status
# file and print a single explicit list. NO destructive calls. Only resources
# referenced in $STATUS_FILE are visible to this script.
# =============================================================================

plan_cloudfront_distribution() {
    local id=$(get_status "cloudfront_distribution_id")
    local region=$(get_status "region")
    if [ -z "$id" ]; then return 0; fi

    local aws_cmd=$(aws_cli)
    echo -e "  ${BOLD}CloudFront distribution${NC}"
    echo -e "    ID:     $id"

    local dist
    if dist=$($aws_cmd cloudfront get-distribution --id "$id" --region "$region" 2>/dev/null); then
        local aliases=$(echo "$dist" | jq -r '[.Distribution.DistributionConfig.Aliases.Items // [] | .[]] | join(", ")')
        local status=$(echo "$dist" | jq -r '.Distribution.Status')
        local enabled=$(echo "$dist" | jq -r '.Distribution.DistributionConfig.Enabled')
        echo -e "    Aliases: ${aliases:-<none>}"
        echo -e "    Status:  $status (enabled=$enabled)"
        if [ "$enabled" = "true" ]; then
            echo -e "    Action:  $(destruct DISABLE) then $(destruct DELETE)"
        else
            echo -e "    Action:  $(destruct DELETE)"
        fi
    else
        echo -e "    ${YELLOW}(does not exist in AWS; will skip)${NC}"
    fi
    echo
}

plan_certificate() {
    local arn=$(get_status "certificate_arn")
    if [ -z "$arn" ]; then return 0; fi

    local aws_cmd=$(aws_cli)
    echo -e "  ${BOLD}ACM certificate${NC}"
    echo -e "    ARN:    $arn"
    echo -e "    Region: us-east-1 (CloudFront)"

    local cert
    if cert=$($aws_cmd acm describe-certificate --certificate-arn "$arn" --region us-east-1 2>/dev/null); then
        local domain=$(echo "$cert" | jq -r '.Certificate.DomainName')
        local sans=$(echo "$cert" | jq -r '[.Certificate.SubjectAlternativeNames // [] | .[]] | join(", ")')
        local status=$(echo "$cert" | jq -r '.Certificate.Status')
        echo -e "    CN:     $domain"
        echo -e "    SANs:   ${sans:-<none>}"
        echo -e "    Status: $status"
        echo -e "    Action: $(destruct DELETE)"
    else
        echo -e "    ${YELLOW}(does not exist in AWS; will skip)${NC}"
    fi
    echo
}

plan_dns_records() {
    local dist_domain=$(get_status "cloudfront_domain")
    local domain_zones=$(get_status_array "domain_zones")
    local domains=$(get_status_array "domains")
    if [ -z "$dist_domain" ] || [ "$domains" = "[]" ]; then return 0; fi

    local aws_cmd=$(aws_cli)
    echo -e "  ${BOLD}Route53 A-alias records (source domains)${NC}"
    echo -e "    Target: $dist_domain"

    echo "$domains" | jq -r '.[]' | while read -r domain; do
        local zone_id=$(echo "$domain_zones" | jq -r --arg d "$domain" '.[] | select(.domain == $d) | .zone_id')
        if [ -z "$zone_id" ]; then
            echo -e "    - ${domain}  ${YELLOW}(no zone in status; will skip)${NC}"
            continue
        fi

        local rec=$($aws_cmd route53 list-resource-record-sets \
            --hosted-zone-id "$zone_id" \
            --query "ResourceRecordSets[?Name=='${domain}.' && Type=='A']" \
            --output json 2>/dev/null)

        if [ -z "$rec" ] || [ "$(echo "$rec" | jq 'length')" -eq 0 ]; then
            echo -e "    - ${domain}  (zone $zone_id) ${YELLOW}(no record; will skip)${NC}"
            continue
        fi

        local target=$(echo "$rec" | jq -r '.[0].AliasTarget.DNSName // ""')
        target=${target%.}
        local our=${dist_domain%.}
        if [[ "$target" == *"$our"* ]]; then
            echo -e "    - ${domain}  (zone $zone_id, alias -> $target)  $(destruct DELETE)"
        else
            echo -e "    - ${domain}  (zone $zone_id, alias -> $target) ${YELLOW}(not our distribution; will skip)${NC}"
        fi
    done
    echo
}

plan_validation_records() {
    local validation_records=$(get_status_array "validation_records")
    local domain_zones=$(get_status_array "domain_zones")
    local target_zone_id=$(get_status "target_zone_id")
    local target_domain=$(get_status "target_domain")
    if [ "$validation_records" = "[]" ]; then return 0; fi

    echo -e "  ${BOLD}Route53 ACM-validation CNAMEs${NC}"

    echo "$validation_records" | jq -c '.[]' | while read -r record; do
        local domain=$(echo "$record" | jq -r '.Domain')
        local name=$(echo "$record" | jq -r '.Name')
        name=${name%.}
        local zone_id=""
        if [ "$domain" = "$target_domain" ]; then
            zone_id="$target_zone_id"
        else
            zone_id=$(echo "$domain_zones" | jq -r --arg d "$domain" '.[] | select(.domain == $d) | .zone_id')
        fi
        if [ -z "$zone_id" ]; then
            echo -e "    - $name  ${YELLOW}(no zone in status; will skip)${NC}"
        else
            echo -e "    - $name  (zone $zone_id)  $(destruct DELETE)"
        fi
    done
    echo
}

plan_s3_bucket() {
    local bucket=$(get_status "s3_bucket_name")
    if [ -z "$bucket" ]; then return 0; fi

    local aws_cmd=$(aws_cli)
    echo -e "  ${BOLD}S3 bucket${NC}"
    echo -e "    Name:  $bucket"
    echo -e "    Owner: account $ACCOUNT_ID (verified via --expected-bucket-owner)"

    if $aws_cmd s3api head-bucket --bucket "$bucket" --expected-bucket-owner "$ACCOUNT_ID" &>/dev/null; then
        local region=$($aws_cmd s3api get-bucket-location --bucket "$bucket" --expected-bucket-owner "$ACCOUNT_ID" --query 'LocationConstraint' --output text 2>/dev/null)
        [ "$region" = "None" ] || [ -z "$region" ] && region="us-east-1"
        echo -e "    Region: $region"
        echo -e "    Action: $(destruct EMPTY) then $(destruct DELETE)"
    else
        echo -e "    ${YELLOW}(not owned by account $ACCOUNT_ID, or does not exist; will skip)${NC}"
    fi
    echo
}

# Print the plan and demand a typed-yes confirmation. Honors --yes.
print_plan_and_confirm() {
    echo
    echo -e "${BOLD}${MAGENTA}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║                 REDIRECT CLEANUP PLAN                     ║${NC}"
    echo -e "${BOLD}${MAGENTA}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo -e "${BOLD}Status file:${NC} $STATUS_FILE"
    echo -e "${BOLD}Source of truth:${NC} only resources listed above will be touched."
    echo

    plan_cloudfront_distribution
    plan_certificate
    plan_dns_records
    plan_validation_records
    plan_s3_bucket

    echo -e "${BOLD}${RED}This will permanently delete every resource shown above.${NC}"
    echo -e "${BOLD}Anything not in the status file will be left untouched.${NC}"
    echo

    if [ "$YES_FLAG" = true ]; then
        log "INFO" "--yes given; proceeding without prompt"
        return 0
    fi

    echo -ne "${YELLOW}Type ${BOLD}yes${NC}${YELLOW} to proceed (anything else aborts): ${NC}"
    read -r response
    if [ "$response" = "yes" ]; then
        return 0
    fi
    log "INFO" "Cleanup cancelled"
    exit 0
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

    # Certificate lives in us-east-1 for CloudFront, regardless of deploy --region
    local cert_region="us-east-1"

    if [ -z "$cert_arn" ]; then
        log "WARN" "No certificate ARN found in status file. Skipping..."
        return 0
    fi

    # Check if certificate exists
    if ! $aws_cmd acm describe-certificate --certificate-arn "$cert_arn" --region "$cert_region" &>/dev/null; then
        log "WARN" "Certificate $cert_arn not found. Skipping..."
        return 0
    fi

    log "INFO" "Deleting certificate $cert_arn..."

    $aws_cmd acm delete-certificate \
        --certificate-arn "$cert_arn" \
        --region "$cert_region"
    
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

    log "INFO" "Verifying bucket ownership: $bucket_name belongs to account $ACCOUNT_ID"
    if ! $aws_cmd s3api head-bucket --bucket "$bucket_name" --expected-bucket-owner "$ACCOUNT_ID" &>/dev/null; then
        log "WARN" "Bucket $bucket_name is not owned by account $ACCOUNT_ID (or does not exist). Refusing to touch it."
        return 0
    fi

    log "INFO" "Removing website configuration from bucket $bucket_name..."
    $aws_cmd s3api delete-bucket-website --bucket "$bucket_name" --expected-bucket-owner "$ACCOUNT_ID"

    log "INFO" "Emptying bucket $bucket_name..."
    $aws_cmd s3 rm "s3://$bucket_name" --recursive

    log "INFO" "Deleting bucket $bucket_name..."
    $aws_cmd s3api delete-bucket --bucket "$bucket_name" --expected-bucket-owner "$ACCOUNT_ID"
    
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
                usage 0
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

    # Resolve and verify the AWS account that should own these resources.
    # NOTE: must not use $(...) here — resolve_account_id may exit on mismatch.
    resolve_account_id
    log "INFO" "Operating against AWS account: $ACCOUNT_ID"

    if [ "$(jq -r '.cleanup_completed // "false"' "$STATUS_FILE")" = "true" ]; then
        log "WARN" "Status file says cleanup was completed on $(jq -r '.cleanup_timestamp // "unknown"' "$STATUS_FILE"). Re-querying AWS anyway."
    fi

    # Print live plan and demand typed-yes confirmation (or --yes)
    print_plan_and_confirm

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
