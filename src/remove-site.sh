#!/bin/bash
# =============================================================================
# AWS Resource Cleanup Script
# 
# This script removes all AWS resources created by the deployment scripts
# based on the JSON status file.
# =============================================================================

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
BG_RED='\033[41m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Render a destructive verb LOUDLY. Used in the plan so the user can't miss it.
destruct() {
    echo -ne "${BOLD}${BG_RED}${WHITE} $1 ${NC}"
}

# Default values
AWS_PROFILE=""
STATUS_FILE=""
DOMAIN=""
AUTO_APPROVE=false

# Function to display script usage
usage() {
    local exit_code="${1:-1}"
    echo -e "${BOLD}Usage:${NC} $0 --status-file status.json [options]"
    echo -e "${BOLD}Options:${NC}"
    echo "  --status-file FILE     Path to the status JSON file (required)"
    echo "  --domain DOMAIN        Domain used to derive default status file (.deploy-status-<domain>.json)"
    echo "  --profile PROFILE      AWS CLI profile (optional)"
    echo "  --yes                  Skip all confirmation prompts"
    echo "  --help                 Display this help message"
    exit "$exit_code"
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
        "DEBUG")
            echo -e "${CYAN}[DEBUG]${NC} ${timestamp} - ${message}"
            ;;
    esac
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

# =============================================================================
# Plan: query AWS for the live state of every resource in the status file and
# print a single, explicit list of what will be touched. NO destructive calls.
# Anything not referenced in $STATUS_FILE is invisible to this script.
# =============================================================================

# Build the aws-cli command prefix once.
aws_cli() {
    local cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        cmd="$cmd --profile $AWS_PROFILE"
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

plan_cloudfront_distribution() {
    local id=$(jq -r '.distribution_id // ""' "$STATUS_FILE")
    if [ -z "$id" ] || [ "$id" = "null" ]; then return 0; fi

    local aws_cmd=$(aws_cli)
    echo -e "  ${BOLD}CloudFront distribution${NC}"
    echo -e "    ID:      $id"

    local dist
    if dist=$($aws_cmd cloudfront get-distribution --id "$id" 2>/dev/null); then
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

plan_origin_access_control() {
    local id=$(jq -r '.oac_id // ""' "$STATUS_FILE")
    if [ -z "$id" ] || [ "$id" = "null" ]; then return 0; fi

    local aws_cmd=$(aws_cli)
    echo -e "  ${BOLD}CloudFront Origin Access Control${NC}"
    echo -e "    ID:   $id"

    local oac
    if oac=$($aws_cmd cloudfront get-origin-access-control --id "$id" 2>/dev/null); then
        local name=$(echo "$oac" | jq -r '.OriginAccessControl.OriginAccessControlConfig.Name // "<unknown>"')
        echo -e "    Name: $name"
        echo -e "    Action: $(destruct DELETE)"
    else
        echo -e "    ${YELLOW}(does not exist in AWS; will skip)${NC}"
    fi
    echo
}

plan_certificate() {
    local arn=$(jq -r '.certificate_arn // ""' "$STATUS_FILE")
    if [ -z "$arn" ] || [ "$arn" = "null" ]; then return 0; fi

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

plan_validation_records() {
    local arn=$(jq -r '.certificate_arn // ""' "$STATUS_FILE")
    local zone_id=$(jq -r '.zone_id // ""' "$STATUS_FILE")
    if [ -z "$arn" ] || [ "$arn" = "null" ]; then return 0; fi
    if [ -z "$zone_id" ] || [ "$zone_id" = "null" ]; then return 0; fi

    local aws_cmd=$(aws_cli)
    local cert
    if ! cert=$($aws_cmd acm describe-certificate --certificate-arn "$arn" --region us-east-1 2>/dev/null); then
        return 0  # certificate missing — covered by plan_certificate
    fi

    local records=$(echo "$cert" | jq -c '.Certificate.DomainValidationOptions[]?.ResourceRecord | select(. != null)')
    if [ -z "$records" ]; then return 0; fi

    echo -e "  ${BOLD}Route53 ACM-validation CNAMEs${NC}"
    echo -e "    Zone: $zone_id"
    echo "$records" | while read -r rec; do
        local name=$(echo "$rec" | jq -r '.Name')
        local type=$(echo "$rec" | jq -r '.Type')
        echo -e "    - $type ${name%.}  $(destruct DELETE)"
    done
    echo
}

plan_s3_bucket() {
    local bucket=$(jq -r '.bucket_name // ""' "$STATUS_FILE")
    if [ -z "$bucket" ] || [ "$bucket" = "null" ]; then return 0; fi

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

plan_dns_records() {
    local zone_id=$(jq -r '.zone_id // ""' "$STATUS_FILE")
    local domain=$(jq -r '.domain // ""' "$STATUS_FILE")
    if [ -z "$zone_id" ] || [ "$zone_id" = "null" ]; then return 0; fi
    if [ -z "$domain" ] || [ "$domain" = "null" ]; then return 0; fi

    local aws_cmd=$(aws_cli)
    echo -e "  ${BOLD}Route53 A records (apex)${NC}"
    echo -e "    Zone:   $zone_id"
    echo -e "    Domain: $domain"

    local records
    if records=$($aws_cmd route53 list-resource-record-sets \
            --hosted-zone-id "$zone_id" \
            --query "ResourceRecordSets[?Name=='${domain}.' && Type=='A']" \
            --output json 2>/dev/null); then
        if [ "$(echo "$records" | jq 'length')" -eq 0 ]; then
            echo -e "    ${YELLOW}(no A records found; will skip)${NC}"
        else
            echo "$records" | jq -c '.[]' | while read -r r; do
                local target=$(echo "$r" | jq -r '.AliasTarget.DNSName // (.ResourceRecords[0].Value // "<unknown>")')
                echo -e "    -> $target   $(destruct DELETE)"
            done
        fi
    else
        echo -e "    ${YELLOW}(zone not accessible; will skip)${NC}"
    fi
    echo
}

# Print the plan and demand a typed-yes confirmation. Honors --yes.
print_plan_and_confirm() {
    echo
    echo -e "${BOLD}${MAGENTA}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║                       CLEANUP PLAN                        ║${NC}"
    echo -e "${BOLD}${MAGENTA}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo -e "${BOLD}Status file:${NC} $STATUS_FILE"
    echo -e "${BOLD}Source of truth:${NC} only resources listed above will be touched."
    echo

    plan_cloudfront_distribution
    plan_origin_access_control
    plan_certificate
    plan_validation_records
    plan_s3_bucket
    plan_dns_records

    echo -e "${BOLD}${RED}This will permanently delete every resource shown above.${NC}"
    echo -e "${BOLD}Anything not in the status file will be left untouched.${NC}"
    echo

    if [ "$AUTO_APPROVE" = true ]; then
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

# Function to remove the CloudFront distribution
remove_cloudfront_distribution() {
    log "STEP" "Removing CloudFront distribution"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    local distribution_id=$(jq -r '.distribution_id // ""' "$STATUS_FILE")
    if [ -z "$distribution_id" ] || [ "$distribution_id" = "null" ]; then
        log "INFO" "No CloudFront distribution found in status file"
        return 0
    fi

    local domain=$(jq -r '.domain // "main"' "$STATUS_FILE")
    log "INFO" "Processing CloudFront distribution: $distribution_id ($domain)"

    # Check if distribution exists
    if ! $aws_cmd cloudfront get-distribution --id "$distribution_id" &>/dev/null; then
        log "INFO" "Distribution $distribution_id does not exist, skipping"
        return 0
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
            return 1
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

# Function to remove ACM validation CNAME records from Route53
remove_validation_records() {
    log "STEP" "Removing ACM validation DNS records"

    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi

    local cert_arn=$(jq -r '.certificate_arn // ""' "$STATUS_FILE")
    local zone_id=$(jq -r '.zone_id // ""' "$STATUS_FILE")

    if [ -z "$cert_arn" ] || [ "$cert_arn" = "null" ]; then
        log "INFO" "No certificate found in status file, skipping validation record cleanup"
        return 0
    fi

    if [ -z "$zone_id" ] || [ "$zone_id" = "null" ]; then
        log "WARN" "No zone_id in status file, skipping validation record cleanup"
        return 0
    fi

    # Certificate must be in us-east-1 for CloudFront
    local cert_region="us-east-1"

    # Re-query ACM for the validation records, since deploy-site.sh does not persist them.
    # Must run before remove_certificate so the cert still exists.
    if ! $aws_cmd acm describe-certificate --certificate-arn "$cert_arn" --region "$cert_region" &>/dev/null; then
        log "INFO" "Certificate $cert_arn does not exist, skipping validation record cleanup"
        return 0
    fi

    local validation_records=$($aws_cmd acm describe-certificate \
        --certificate-arn "$cert_arn" \
        --region "$cert_region" \
        --query "Certificate.DomainValidationOptions[].ResourceRecord" \
        --output json)

    if [ -z "$validation_records" ] || [ "$(echo "$validation_records" | jq 'length')" -eq 0 ]; then
        log "INFO" "No validation records reported by ACM, skipping"
        return 0
    fi

    echo "$validation_records" | jq -c '.[]' | while read -r record; do
        local record_name=$(echo "$record" | jq -r '.Name')
        local record_type=$(echo "$record" | jq -r '.Type')
        local record_value=$(echo "$record" | jq -r '.Value')

        # Route53 stores names with a trailing dot; normalize for matching.
        record_name="${record_name%.}."

        local existing=$($aws_cmd route53 list-resource-record-sets \
            --hosted-zone-id "$zone_id" \
            --query "ResourceRecordSets[?Name=='$record_name' && Type=='$record_type']" \
            --output json)

        if [ "$(echo "$existing" | jq 'length')" -eq 0 ]; then
            log "INFO" "Validation record $record_name not present in zone $zone_id, skipping"
            continue
        fi

        local existing_value=$(echo "$existing" | jq -r '.[0].ResourceRecords[0].Value')
        if [ "$existing_value" != "$record_value" ]; then
            log "WARN" "Validation record $record_name exists but value differs, skipping"
            continue
        fi

        local change_batch=$(echo "$existing" | jq -c '{
            Changes: [{
                Action: "DELETE",
                ResourceRecordSet: .[0]
            }]
        }')

        log "INFO" "Removing validation record $record_name from zone $zone_id"
        $aws_cmd route53 change-resource-record-sets \
            --hosted-zone-id "$zone_id" \
            --change-batch "$change_batch" >/dev/null

        if [ $? -eq 0 ]; then
            log "SUCCESS" "Removed validation record $record_name"
        else
            log "ERROR" "Failed to remove validation record $record_name"
        fi
    done
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

# Function to remove the S3 bucket
remove_s3_bucket() {
    log "STEP" "Removing S3 bucket"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    local bucket=$(jq -r '.bucket_name // ""' "$STATUS_FILE")
    if [ -z "$bucket" ] || [ "$bucket" = "null" ]; then
        log "INFO" "No S3 bucket found in status file"
        return 0
    fi

    log "INFO" "Processing S3 bucket: $bucket (owner check: account $ACCOUNT_ID)"

    # Verify the bucket is owned by the expected account before touching it.
    # --expected-bucket-owner makes head-bucket fail with 403 on mismatch.
    if ! $aws_cmd s3api head-bucket --bucket "$bucket" --expected-bucket-owner "$ACCOUNT_ID" &>/dev/null; then
        log "WARN" "Bucket $bucket is not owned by account $ACCOUNT_ID (or does not exist). Refusing to touch it."
        return 0
    fi

    # Empty the bucket first
    log "INFO" "Emptying bucket $bucket"
    $aws_cmd s3 rm "s3://$bucket" --recursive

    if [ $? -ne 0 ]; then
        log "WARN" "Failed to completely empty bucket $bucket"
    fi

    # Delete the bucket
    log "INFO" "Deleting bucket $bucket"
    $aws_cmd s3api delete-bucket --bucket "$bucket" --expected-bucket-owner "$ACCOUNT_ID"

    if [ $? -eq 0 ]; then
        log "SUCCESS" "Deleted S3 bucket $bucket"
    else
        log "ERROR" "Failed to delete S3 bucket $bucket"
    fi
}

# Function to remove Route53 DNS records
remove_dns_records() {
    log "STEP" "Removing Route53 DNS records"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    local zone_id=$(jq -r '.zone_id // ""' "$STATUS_FILE")
    local domain=$(jq -r '.domain // ""' "$STATUS_FILE")

    if [ -z "$zone_id" ] || [ "$zone_id" = "null" ]; then
        log "INFO" "No Route53 zone found in status file"
        return 0
    fi
    if [ -z "$domain" ] || [ "$domain" = "null" ]; then
        log "WARN" "Status file has zone_id but no domain, skipping DNS cleanup"
        return 0
    fi

    log "INFO" "Processing DNS records for domain: $domain"

    # Check if zone exists
    if ! $aws_cmd route53 get-hosted-zone --id "$zone_id" &>/dev/null; then
        log "INFO" "Hosted zone $zone_id does not exist, skipping"
        return 0
    fi

    # Find A records pointing to CloudFront
    log "INFO" "Finding A records for $domain in zone $zone_id"

    local records=$($aws_cmd route53 list-resource-record-sets \
        --hosted-zone-id "$zone_id" \
        --query "ResourceRecordSets[?Name=='${domain}.' && Type=='A']" \
        --output json)

    if [ "$(echo "$records" | jq 'length')" -eq 0 ]; then
        log "INFO" "No A records found for $domain in zone $zone_id"
        return 0
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
            --domain)
                DOMAIN="$2"
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
                usage 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                ;;
        esac
    done

    if [ -z "$STATUS_FILE" ] && [ -n "$DOMAIN" ]; then
        STATUS_FILE=".deploy-status-${DOMAIN}.json"
    fi
    
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

    # Resolve and verify the AWS account that should own these resources.
    # NOTE: must not use $(...) here — resolve_account_id may exit on mismatch.
    resolve_account_id
    log "INFO" "Operating against AWS account: $ACCOUNT_ID"

    # Print live plan and demand typed-yes confirmation (or --yes)
    print_plan_and_confirm

    # Execute cleanup steps in reverse order
    remove_cloudfront_distribution
    remove_origin_access_controls
    remove_validation_records
    remove_certificate
    remove_s3_bucket
    remove_dns_records
    
    # Success message
    log "SUCCESS" "Cleanup completed"
}

# Run the script
main "$@"