#!/bin/bash
# =============================================================================
# AWS Static Site Import Script
#
# Reconstitutes a .deploy-status-<domain>.json config file from infrastructure
# that is already live (e.g. deployed manually or by another tool), by
# inspecting CloudFront, S3, ACM, Route53 and IAM. The resulting status file
# is compatible with sync.sh, remove-site.sh, setup-ci.sh and re-runs of
# deploy-site.sh.
#
# Discovery is anchored on the CloudFront distribution whose Aliases contain
# the domain; everything else (bucket, OAC, certificate, function) is read
# from the distribution config rather than guessed from naming conventions,
# so manually-created resources with non-standard names import correctly.
# =============================================================================

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Default values
AWS_REGION="us-east-1"
AWS_PROFILE=""
DOMAIN=""
DISTRIBUTION_ID=""
STATUS_FILE=""
AUTO_APPROVE=false
DRY_RUN=false

# Discovery happens into a temp file; it only lands at STATUS_FILE at the end
# (never with --dry-run), so a failed import can't leave a half-written config.
WORK_FILE=""

usage() {
    local exit_code="${1:-1}"
    echo -e "${BOLD}Usage:${NC} $0 --domain yourdomain.com [options]"
    echo -e "${BOLD}Options:${NC}"
    echo "  --domain DOMAIN          Domain name (required)"
    echo "  --profile PROFILE        AWS CLI profile (optional)"
    echo "  --region REGION          AWS region (default: us-east-1)"
    echo "  --distribution-id ID     CloudFront distribution ID (optional; only"
    echo "                           needed when the distribution cannot be found"
    echo "                           by its alias)"
    echo "  --status-file FILE       Custom status file path"
    echo "                           (default: {repo-root}/config/.deploy-status-<domain>.json)"
    echo "  --dry-run                Print the reconstituted config to stdout"
    echo "                           without writing the status file"
    echo "  --yes                    Skip confirmation prompts (including"
    echo "                           overwriting an existing status file)"
    echo "  --help                   Display this help message"
    exit "$exit_code"
}

check_prerequisites() {
    log "STEP" "Checking prerequisites"

    local missing_tools=()

    for tool in aws jq curl; do
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

# Same key-value helpers as deploy-site.sh, operating on WORK_FILE so the
# reconstituted config uses identical field semantics.
update_status() {
    local key=$1
    local value=$2

    local temp_file=$(mktemp)
    jq -r --arg key "$key" --arg value "$value" '. + {($key): $value}' "$WORK_FILE" > "$temp_file"
    mv "$temp_file" "$WORK_FILE"
}

get_status() {
    local key=$1
    local default_value=$2

    local value=$(jq -r --arg key "$key" '.[$key] // ""' "$WORK_FILE")
    if [ -z "$value" ] || [ "$value" = "null" ]; then
        echo "$default_value"
    else
        echo "$value"
    fi
}

mark_step_completed() {
    local step=$1
    update_status "${step}_completed" "true"
    update_status "${step}_completed_at" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}

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

check_aws_config() {
    log "STEP" "Checking AWS CLI configuration"

    # Empty status-file argument: only validate credentials here. Re-importing
    # under a different account is legitimate (that is what import is for) but
    # easy to do by accident, so it gets a warning + confirmation below rather
    # than the hard abort the deploy/sync/remove scripts use.
    if ! require_account_match "" "$AWS_PROFILE"; then
        exit 1
    fi

    if [ -f "$STATUS_FILE" ]; then
        local existing_account=$(jq -r '.account_id // ""' "$STATUS_FILE" 2>/dev/null)
        if [ -n "$existing_account" ] && [ "$existing_account" != "$CALLER_ACCOUNT_ID" ]; then
            log "WARN" "Existing status file records account $existing_account but you are authenticated to $CALLER_ACCOUNT_ID."
            if ! confirm_action "Import from account $CALLER_ACCOUNT_ID anyway?"; then
                log "INFO" "Import cancelled. Switch profile and retry."
                exit 0
            fi
        fi
    fi

    log "SUCCESS" "AWS CLI is configured correctly (Account ID: $CALLER_ACCOUNT_ID)"

    update_status "account_id" "$CALLER_ACCOUNT_ID"
}

discover_hosted_zone() {
    log "STEP" "Looking up Route53 hosted zone for $DOMAIN"

    local match
    match=$(find_zone_for_domain "$DOMAIN" "$AWS_PROFILE")

    if [ -z "$match" ]; then
        log "WARN" "No Route53 hosted zone found for $DOMAIN or any parent domain"
        log "INFO" "DNS may be managed outside this account; zone fields will be omitted."
        return 0
    fi

    local zone_id="${match%%|*}"
    local zone_name="${match#*|}"

    if [ "$zone_name" = "$DOMAIN" ]; then
        log "SUCCESS" "Found Route53 hosted zone for $DOMAIN (Zone ID: $zone_id)"
    else
        log "SUCCESS" "Found parent Route53 hosted zone $zone_name covering $DOMAIN (Zone ID: $zone_id)"
    fi

    update_status "zone_id" "$zone_id"
    update_status "zone_name" "$zone_name"
    mark_step_completed "hosted_zone"
    return 0
}

# Anchor of the import: find the distribution serving the domain and read the
# bucket, OAC, certificate and viewer-request function out of its config.
discover_distribution() {
    log "STEP" "Discovering CloudFront distribution for $DOMAIN"

    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi

    local distribution_id="$DISTRIBUTION_ID"

    if [ -z "$distribution_id" ]; then
        log "INFO" "Searching distributions for alias $DOMAIN"
        local distributions=$($aws_cmd cloudfront list-distributions --output json)

        if [ $? -ne 0 ]; then
            log "ERROR" "Failed to list CloudFront distributions"
            exit 1
        fi

        distribution_id=$(echo "$distributions" | jq -r --arg domain "$DOMAIN" \
            '.DistributionList.Items[]? | select(.Aliases.Items != null) | select(.Aliases.Items[] == $domain) | .Id' 2>/dev/null | head -n 1)
    fi

    if [ -z "$distribution_id" ]; then
        log "ERROR" "No CloudFront distribution found with alias $DOMAIN"
        log "INFO" "If the distribution exists but lacks the alias, pass --distribution-id explicitly."
        exit 1
    fi

    local dist=$($aws_cmd cloudfront get-distribution --id "$distribution_id" --output json)

    if [ $? -ne 0 ] || [ -z "$dist" ]; then
        log "ERROR" "Failed to fetch distribution $distribution_id"
        exit 1
    fi

    local distribution_domain=$(echo "$dist" | jq -r '.Distribution.DomainName')
    local dist_status=$(echo "$dist" | jq -r '.Distribution.Status')
    local dist_enabled=$(echo "$dist" | jq -r '.Distribution.DistributionConfig.Enabled')

    log "SUCCESS" "Found distribution $distribution_id ($distribution_domain, status: $dist_status, enabled: $dist_enabled)"

    if [ "$dist_enabled" != "true" ]; then
        log "WARN" "Distribution is disabled; importing anyway"
    fi

    # When found via --distribution-id, verify the alias actually covers the domain
    local has_alias=$(echo "$dist" | jq -r --arg domain "$DOMAIN" \
        '.Distribution.DistributionConfig.Aliases.Items // [] | map(select(. == $domain)) | length')
    if [ "$has_alias" = "0" ]; then
        log "WARN" "Distribution $distribution_id does not list $DOMAIN as an alias"
    fi

    update_status "distribution_id" "$distribution_id"
    update_status "distribution_domain" "$distribution_domain"
    mark_step_completed "cloudfront"

    # --- Origin: S3 bucket + OAC ---
    local origin=$(echo "$dist" | jq -c '.Distribution.DistributionConfig.Origins.Items[0]')
    local origin_domain=$(echo "$origin" | jq -r '.DomainName')
    local origin_count=$(echo "$dist" | jq -r '.Distribution.DistributionConfig.Origins.Quantity')

    if [ "$origin_count" != "1" ]; then
        log "WARN" "Distribution has $origin_count origins; importing the first ($origin_domain)"
    fi

    case "$origin_domain" in
        *.s3.*.amazonaws.com|*.s3.amazonaws.com|*.s3-website*.amazonaws.com)
            local bucket_name=$(echo "$origin_domain" | sed -E 's/\.s3[.-][a-z0-9.-]*amazonaws\.com$//')
            log "INFO" "Origin is S3 bucket: $bucket_name"

            case "$origin_domain" in
                *.s3-website*)
                    log "WARN" "Origin uses the S3 website endpoint (public bucket), not the toolkit's OAC pattern"
                    ;;
            esac

            if $aws_cmd s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
                log "SUCCESS" "Bucket $bucket_name exists and is accessible"
                update_status "bucket_name" "$bucket_name"
                mark_step_completed "s3_bucket"

                if [ "$bucket_name" != "${DOMAIN}-static-site" ]; then
                    log "WARN" "Bucket name does not follow the toolkit convention (${DOMAIN}-static-site); the actual name is recorded and downstream scripts will use it"
                fi

                # Content step: any object in the bucket counts
                local key_count=$($aws_cmd s3api list-objects-v2 --bucket "$bucket_name" --max-keys 1 --query 'KeyCount' --output text 2>/dev/null)
                if [ "$key_count" != "0" ] && [ -n "$key_count" ] && [ "$key_count" != "None" ]; then
                    mark_step_completed "content"
                else
                    log "WARN" "Bucket $bucket_name is empty; content step left incomplete"
                fi
            else
                log "WARN" "Origin bucket $bucket_name is not accessible from this account/profile; bucket fields omitted"
            fi
            ;;
        *)
            log "WARN" "Origin $origin_domain is not an S3 endpoint; bucket fields omitted"
            ;;
    esac

    local oac_id=$(echo "$origin" | jq -r '.OriginAccessControlId // ""')
    local oai=$(echo "$origin" | jq -r '.S3OriginConfig.OriginAccessIdentity // ""')

    if [ -n "$oac_id" ]; then
        local oac_name=$($aws_cmd cloudfront get-origin-access-control --id "$oac_id" \
            --query "OriginAccessControl.OriginAccessControlConfig.Name" --output text 2>/dev/null)
        log "SUCCESS" "Origin Access Control in use (ID: $oac_id${oac_name:+, Name: $oac_name})"
        update_status "oac_id" "$oac_id"
        mark_step_completed "oac"
    elif [ -n "$oai" ]; then
        log "WARN" "Distribution uses a legacy Origin Access Identity ($oai), not an OAC"
        log "INFO" "remove-site.sh will not clean up the OAI; consider migrating to OAC."
    else
        log "WARN" "No Origin Access Control on the origin"
    fi

    # --- Viewer certificate ---
    local cert_arn=$(echo "$dist" | jq -r '.Distribution.DistributionConfig.ViewerCertificate.ACMCertificateArn // ""')

    if [ -n "$cert_arn" ]; then
        local cert_status=$($aws_cmd acm describe-certificate \
            --certificate-arn "$cert_arn" \
            --region us-east-1 \
            --query "Certificate.Status" \
            --output text 2>/dev/null)

        update_status "certificate_arn" "$cert_arn"
        if [ "$cert_status" = "ISSUED" ]; then
            log "SUCCESS" "ACM certificate is issued (ARN: $cert_arn)"
            mark_step_completed "certificate"
        else
            log "WARN" "ACM certificate status is ${cert_status:-unknown}; certificate step left incomplete"
        fi
    else
        log "WARN" "Distribution does not use an ACM certificate (default CloudFront cert?)"
    fi

    # --- Viewer-request function ---
    local fn_arn=$(echo "$dist" | jq -r '.Distribution.DistributionConfig.DefaultCacheBehavior.FunctionAssociations.Items[]? | select(.EventType == "viewer-request") | .FunctionARN' | head -n 1)

    if [ -n "$fn_arn" ]; then
        local fn_name="${fn_arn##*function/}"
        log "SUCCESS" "Viewer-request function attached (Name: $fn_name)"
        log "INFO" "Function behavior (clean-urls / basic-auth) cannot be inferred and is not recorded."
        update_status "function_name" "$fn_name"
        update_status "function_arn" "$fn_arn"
        mark_step_completed "cf_function"
    fi

    return 0
}

# Verify the domain's A record actually points at the discovered distribution.
discover_dns_records() {
    local zone_id=$(get_status "zone_id" "")
    local distribution_domain=$(get_status "distribution_domain" "")

    if [ -z "$zone_id" ]; then
        return 0
    fi

    log "STEP" "Checking Route53 DNS records for $DOMAIN"

    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi

    local alias_target=$($aws_cmd route53 list-resource-record-sets \
        --hosted-zone-id "$zone_id" \
        --query "ResourceRecordSets[?Name=='${DOMAIN}.' && Type=='A'].AliasTarget.DNSName" \
        --output text 2>/dev/null)

    if [ "${alias_target%.}" = "${distribution_domain%.}" ] && [ -n "$distribution_domain" ]; then
        log "SUCCESS" "A record aliases the distribution ($distribution_domain)"
        mark_step_completed "dns"
    elif [ -n "$alias_target" ] && [ "$alias_target" != "None" ]; then
        log "WARN" "A record for $DOMAIN points at ${alias_target%.}, not the distribution; dns step left incomplete"
    else
        log "WARN" "No A alias record found for $DOMAIN in zone $zone_id; dns step left incomplete"
    fi

    return 0
}

# Pick up a scoped IAM user if one exists under the toolkit's naming
# convention. Manual deploys usually won't have one; that's fine.
discover_scoped_user() {
    log "STEP" "Checking for scoped IAM user"

    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi

    local user_name="${DOMAIN}-site-admin"

    if ! $aws_cmd iam get-user --user-name "$user_name" &>/dev/null; then
        log "INFO" "No IAM user named $user_name; skipping (re-run deploy-site.sh with --create-scoped-user to add one)"
        return 0
    fi

    log "SUCCESS" "Found scoped IAM user $user_name"
    update_status "scoped_user_name" "$user_name"

    local policy_name=$($aws_cmd iam list-user-policies --user-name "$user_name" \
        --query "PolicyNames[0]" --output text 2>/dev/null)
    if [ -n "$policy_name" ] && [ "$policy_name" != "None" ]; then
        update_status "scoped_user_policy_name" "$policy_name"
    fi

    local access_key_id=$($aws_cmd iam list-access-keys --user-name "$user_name" \
        --query "AccessKeyMetadata[0].AccessKeyId" --output text 2>/dev/null)
    if [ -n "$access_key_id" ] && [ "$access_key_id" != "None" ]; then
        update_status "scoped_user_access_key_id" "$access_key_id"
    fi

    mark_step_completed "scoped_user"
    return 0
}

verify_site() {
    log "STEP" "Verifying site responds"

    local http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "https://$DOMAIN")

    if [ "$http_code" = "200" ]; then
        log "SUCCESS" "Website is accessible (HTTP 200)"
        mark_step_completed "verification"
    elif [ "$http_code" = "401" ] && [ -n "$(get_status "function_name" "")" ]; then
        log "WARN" "Got HTTP 401 — the viewer-request function likely enforces basic auth; verification step left incomplete"
    else
        log "WARN" "Website returned HTTP $http_code; verification step left incomplete"
    fi

    return 0
}

display_summary() {
    log "STEP" "Import Summary"
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    ${BOLD}IMPORT SUMMARY${NC}${CYAN}                          ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${BOLD}Domain:${NC} $DOMAIN"
    echo -e "${BOLD}S3 Bucket:${NC} $(get_status "bucket_name" "N/A")"
    echo -e "${BOLD}CloudFront Distribution:${NC} $(get_status "distribution_id" "N/A")"
    echo -e "${BOLD}Distribution Domain:${NC} $(get_status "distribution_domain" "N/A")"
    echo -e "${BOLD}Certificate:${NC} $(get_status "certificate_arn" "N/A")"
    echo -e "${BOLD}OAC:${NC} $(get_status "oac_id" "N/A")"
    echo -e "${BOLD}Zone:${NC} $(get_status "zone_name" "N/A") ($(get_status "zone_id" "N/A"))"
    local fn_name=$(get_status "function_name" "")
    if [ -n "$fn_name" ]; then
        echo -e "${BOLD}CloudFront Function:${NC} $fn_name"
    fi
    local scoped_user=$(get_status "scoped_user_name" "")
    if [ -n "$scoped_user" ]; then
        echo -e "${BOLD}Scoped IAM User:${NC} $scoped_user"
    fi
    echo

    local incomplete=""
    for step in "hosted_zone" "s3_bucket" "certificate" "oac" "cloudfront" "dns" "content" "verification"; do
        if [ "$(get_status "${step}_completed" "false")" != "true" ]; then
            incomplete="$incomplete $step"
        fi
    done

    if [ -z "$incomplete" ]; then
        echo -e "${GREEN}${BOLD}All deployment steps verified against live infrastructure.${NC}"
    else
        echo -e "${YELLOW}${BOLD}Steps not verified:${NC}${incomplete}"
        echo -e "Run deploy-site.sh --domain $DOMAIN to fill the gaps, or investigate the warnings above."
    fi

    if [ "$DRY_RUN" = true ]; then
        echo
        echo -e "${BOLD}Reconstituted config (--dry-run, not written):${NC}"
        jq . "$WORK_FILE"
    else
        echo
        echo -e "${BOLD}Status File:${NC} $STATUS_FILE"
    fi
}

main() {
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
                shift
                shift
                ;;
            --region)
                AWS_REGION="$2"
                shift
                shift
                ;;
            --distribution-id)
                DISTRIBUTION_ID="$2"
                shift
                shift
                ;;
            --status-file)
                STATUS_FILE="$2"
                shift
                shift
                ;;
            --dry-run)
                DRY_RUN=true
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

    if [ -z "$DOMAIN" ]; then
        log "ERROR" "Domain name is required"
        usage
    fi

    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║             ${BOLD}AWS STATIC SITE IMPORT SCRIPT${NC}${CYAN}                  ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${BOLD}Domain:${NC} $DOMAIN"
    echo -e "${BOLD}AWS Region:${NC} $AWS_REGION"
    if [ -n "$AWS_PROFILE" ]; then
        echo -e "${BOLD}AWS Profile:${NC} $AWS_PROFILE"
    fi
    echo

    if [ -z "$STATUS_FILE" ]; then
        STATUS_FILE="$(default_site_status_file "$DOMAIN")" || exit 1
    fi

    if [ -f "$STATUS_FILE" ] && [ "$DRY_RUN" != true ]; then
        log "WARN" "Status file already exists: $STATUS_FILE"
        if ! confirm_action "Overwrite it with the reconstituted config?"; then
            log "INFO" "Import cancelled. Use --dry-run to inspect without writing."
            exit 0
        fi
    fi

    WORK_FILE=$(mktemp)
    echo "{\"domain\": \"$DOMAIN\", \"created_at\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\", \"imported\": \"true\"}" > "$WORK_FILE"
    trap 'rm -f "$WORK_FILE"' EXIT

    check_prerequisites
    check_aws_config
    discover_hosted_zone
    discover_distribution
    discover_dns_records
    discover_scoped_user
    verify_site

    if [ "$DRY_RUN" != true ]; then
        cp "$WORK_FILE" "$STATUS_FILE"
        log "SUCCESS" "Wrote status file: $STATUS_FILE"
    fi

    display_summary
}

main "$@"
