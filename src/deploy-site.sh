#!/bin/bash
# =============================================================================
# AWS Static Site Deployment Script
# 
# This script automates the deployment of a static website on AWS, with a
# single target domain using AWS services (S3, CloudFront, ACM, and Route53).
# =============================================================================

set -e

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Default values
AWS_REGION="us-east-1"
AWS_PROFILE=""
DOMAIN=""
STATUS_FILE=""
AUTO_APPROVE=false
CREATE_SCOPED_USER=false
CLEAN_URLS=false
BASIC_AUTH_CSV=""
BASIC_AUTH_COOKIE="__s3st_auth"
TIMEOUT_RETRIES=5
CERTIFICATE_WAIT_SECONDS=120
CERTIFICATE_WAIT_INTERVAL=10

# Function to display script usage
usage() {
    local exit_code="${1:-1}"
    echo -e "${BOLD}Usage:${NC} $0 --domain yourdomain.com [options]"
    echo -e "${BOLD}Options:${NC}"
    echo "  --domain DOMAIN          Domain name (required)"
    echo "  --profile PROFILE        AWS CLI profile (optional)"
    echo "  --region REGION          AWS region (default: us-east-1)"
    echo "  --yes                    Skip all confirmation prompts"
    echo "  --status-file FILE       Custom status file path"
    echo "                           (default: {repo-root}/config/.deploy-status-<domain>.json)"
    echo "  --create-scoped-user     Also create an IAM user scoped to this site's"
    echo "                           bucket + distribution (read/write/delete on S3,"
    echo "                           CreateInvalidation on CloudFront only). Access"
    echo "                           key is printed once and NOT saved to the status"
    echo "                           file."
    echo "  --clean-urls             Rewrite extension-less paths at the edge via a"
    echo "                           CloudFront Function: /about serves /about.html,"
    echo "                           /docs/ serves /docs/index.html. Off by default."
    echo "  --basic-auth CSV         Comma-separated user:password pairs. Protects the"
    echo "                           distribution with HTTP Basic auth via a CloudFront"
    echo "                           Function; a successful login is remembered in a"
    echo "                           cookie. Credentials live only in the edge function,"
    echo "                           never in the status file. Off by default."
    echo "  --help                   Display this help message"
    exit "$exit_code"
}


# Function to check for required commands
check_prerequisites() {
    log "STEP" "Checking prerequisites"
    
    local missing_tools=()
    
    for tool in aws jq curl host; do
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

# Function to validate the --basic-auth CSV. Runs before anything else so a
# malformed credential list never leaves half-provisioned resources behind.
# Error messages reference entries by position to avoid echoing passwords.
validate_basic_auth_csv() {
    if [ -z "$BASIC_AUTH_CSV" ]; then
        return 0
    fi

    log "STEP" "Validating --basic-auth credentials"

    local pairs
    IFS=',' read -ra pairs <<< "$BASIC_AUTH_CSV"

    if [ ${#pairs[@]} -eq 0 ]; then
        log "ERROR" "--basic-auth: no user:password pairs found"
        exit 1
    fi

    local seen_users=" "
    local i=0
    local pair user pass
    for pair in "${pairs[@]}"; do
        i=$((i + 1))
        if [ -z "$pair" ]; then
            log "ERROR" "--basic-auth: entry $i is empty (check for stray commas)"
            exit 1
        fi
        case "$pair" in
            *:*) ;;
            *)
                log "ERROR" "--basic-auth: entry $i is not in user:password form"
                exit 1
                ;;
        esac
        user="${pair%%:*}"
        pass="${pair#*:}"
        if [ -z "$user" ]; then
            log "ERROR" "--basic-auth: entry $i has an empty username"
            exit 1
        fi
        if [ -z "$pass" ]; then
            log "ERROR" "--basic-auth: entry $i (user '$user') has an empty password"
            exit 1
        fi
        if ! [[ "$user" =~ ^[A-Za-z0-9._-]+$ ]]; then
            log "ERROR" "--basic-auth: entry $i has an invalid username (allowed: letters, digits, '.', '_', '-')"
            exit 1
        fi
        if [[ "$pass" =~ [^[:print:]] ]]; then
            log "ERROR" "--basic-auth: entry $i (user '$user') has a password with non-printable characters"
            exit 1
        fi
        case "$seen_users" in
            *" $user "*)
                log "ERROR" "--basic-auth: duplicate username '$user' (entry $i)"
                exit 1
                ;;
        esac
        seen_users="${seen_users}${user} "
    done

    log "SUCCESS" "--basic-auth: validated ${#pairs[@]} user:password pair(s)"
    return 0
}

# Function to check AWS CLI configuration
check_aws_config() {
    log "STEP" "Checking AWS CLI configuration"

    # Refuse to resume a status file recorded under a different AWS account
    # (wrong profile) — resources like the OAC and bucket would not exist for
    # the current caller, so the deploy would fail or split the stack across
    # accounts.
    if ! require_account_match "$STATUS_FILE" "$AWS_PROFILE"; then
        log "INFO" "Re-run with the matching --profile, or remove the status file to start over."
        exit 1
    fi

    log "SUCCESS" "AWS CLI is configured correctly (Account ID: $CALLER_ACCOUNT_ID)"

    # Store account ID in status file
    update_status "account_id" "$CALLER_ACCOUNT_ID"
}

# Function to initialize or load status file
init_status_file() {
    if [ -z "$STATUS_FILE" ]; then
        STATUS_FILE="$(default_site_status_file "$DOMAIN")" || exit 1
    fi
    
    if [ -f "$STATUS_FILE" ]; then
        log "INFO" "Using existing status file: $STATUS_FILE"
    else
        log "INFO" "Creating new status file: $STATUS_FILE"
        echo "{\"domain\": \"$DOMAIN\", \"created_at\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}" > "$STATUS_FILE"
    fi
}

# Function to update status file with a key-value pair
update_status() {
    local key=$1
    local value=$2
    
    if [ -f "$STATUS_FILE" ]; then
        # Use temp file to avoid issues with some jq versions
        local temp_file=$(mktemp)
        jq -r --arg key "$key" --arg value "$value" '. + {($key): $value}' "$STATUS_FILE" > "$temp_file"
        mv "$temp_file" "$STATUS_FILE"
    else
        log "ERROR" "Status file does not exist"
        exit 1
    fi
}

# Function to get value from status file
get_status() {
    local key=$1
    local default_value=$2
    
    if [ -f "$STATUS_FILE" ]; then
        local value=$(jq -r --arg key "$key" '.[$key] // ""' "$STATUS_FILE")
        if [ -z "$value" ] || [ "$value" = "null" ]; then
            echo "$default_value"
        else
            echo "$value"
        fi
    else
        echo "$default_value"
    fi
}

# Function to check if step is completed
is_step_completed() {
    local step=$1
    local completed=$(get_status "${step}_completed" "false")
    
    if [ "$completed" = "true" ]; then
        return 0
    else
        return 1
    fi
}

# Function to mark step as completed
mark_step_completed() {
    local step=$1
    update_status "${step}_completed" "true"
    update_status "${step}_completed_at" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
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

# Function to check Route53 hosted zone
check_hosted_zone() {
    if is_step_completed "hosted_zone"; then
        local zone_id=$(get_status "zone_id" "")
        local zone_name=$(get_status "zone_name" "")
        log "INFO" "Hosted zone already verified (Zone ID: $zone_id${zone_name:+, Zone: $zone_name})"
        return 0
    fi

    log "STEP" "Checking Route53 hosted zone for $DOMAIN"

    local match
    match=$(find_zone_for_domain "$DOMAIN" "$AWS_PROFILE")

    if [ -z "$match" ]; then
        log "ERROR" "No Route53 hosted zone found for $DOMAIN or any parent domain"
        log "INFO" "Please create a hosted zone covering $DOMAIN in Route53 and try again."
        exit 1
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

# Function to create S3 bucket
create_s3_bucket() {
    if is_step_completed "s3_bucket"; then
        local bucket_name=$(get_status "bucket_name" "")
        log "INFO" "S3 bucket already created (Bucket: $bucket_name)"
        return 0
    fi
    
    log "STEP" "Creating S3 bucket for $DOMAIN"
    
    local bucket_name="${DOMAIN}-static-site"
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    # Check if bucket already exists
    if $aws_cmd s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
        log "INFO" "Bucket $bucket_name already exists"
    else
        log "INFO" "Creating bucket $bucket_name in $AWS_REGION"
        
        # Create bucket command varies based on region
        if [ "$AWS_REGION" = "us-east-1" ]; then
            $aws_cmd s3api create-bucket \
                --bucket "$bucket_name" \
                --region "$AWS_REGION"
        else
            $aws_cmd s3api create-bucket \
                --bucket "$bucket_name" \
                --region "$AWS_REGION" \
                --create-bucket-configuration LocationConstraint="$AWS_REGION"
        fi
        
        if [ $? -ne 0 ]; then
            log "ERROR" "Failed to create S3 bucket"
            exit 1
        fi
    fi
    
    # Configure website hosting
    log "INFO" "Configuring website hosting for bucket $bucket_name"
    # $aws_cmd s3 website \
    #     --bucket "$bucket_name" \
    #     --index-document index.html \
    #     --error-document error.html
    # or like this maybe? how is this
    $aws_cmd s3api put-bucket-website \
        --bucket "$bucket_name" \
        --website-configuration '{
            "IndexDocument": {
                "Suffix": "index.html"
            },
            "ErrorDocument": {
                "Key": "error.html"
            }
        }'

    # Block public access (CloudFront will access via OAC)
    log "INFO" "Blocking public access to bucket $bucket_name"
    $aws_cmd s3api put-public-access-block \
        --bucket "$bucket_name" \
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    
    log "SUCCESS" "S3 bucket created and configured successfully"
    update_status "bucket_name" "$bucket_name"
    mark_step_completed "s3_bucket"
    return 0
}

# Function to create ACM certificate
create_certificate() {
    if is_step_completed "certificate"; then
        local cert_arn=$(get_status "certificate_arn" "")
        log "INFO" "Certificate already created (ARN: $cert_arn)"
        return 0
    fi
    
    log "STEP" "Creating ACM certificate for $DOMAIN"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    # Certificate must be in us-east-1 for CloudFront
    local cert_region="us-east-1"
    
    # Request certificate
    local cert_arn=$(get_status "certificate_arn" "")
    if [ -z "$cert_arn" ]; then
        log "INFO" "Requesting new certificate for $DOMAIN" 
        cert_arn=$($aws_cmd acm request-certificate \
            --domain-name "$DOMAIN" \
            --validation-method DNS \
            --region "$cert_region" \
            --query "CertificateArn" \
            --output text)
        
        if [ $? -ne 0 ] || [ -z "$cert_arn" ]; then
            log "ERROR" "Failed to request certificate"
            exit 1
        fi
        
        log "SUCCESS" "Certificate requested successfully (ARN: $cert_arn)"
        update_status "certificate_arn" "$cert_arn"
    fi
    
    # Wait for DNS validation records
    log "INFO" "Waiting for DNS validation records (this may take a minute)..."
    local validation_records=""
    local attempts=0
    local max_attempts=12
    
    while [ $attempts -lt $max_attempts ]; do
        validation_records=$($aws_cmd acm describe-certificate \
            --certificate-arn "$cert_arn" \
            --region "$cert_region" \
            --query "Certificate.DomainValidationOptions[].ResourceRecord" \
            --output json)
        
        if [ "$(echo "$validation_records" | jq 'length')" -gt 0 ]; then
            break
        fi
        
        attempts=$((attempts + 1))
        log "INFO" "Waiting for validation records ($attempts/$max_attempts)..."
        sleep $CERTIFICATE_WAIT_INTERVAL
    done
    
    if [ "$(echo "$validation_records" | jq 'length')" -eq 0 ]; then
        log "WARN" "Timed out waiting for validation records. Will continue with certificate ARN stored for next run."
        return 0
    fi
    
    # Create DNS validation records
    log "INFO" "Creating DNS validation records in Route53"
    local zone_id=$(get_status "zone_id" "")
    
    local change_batch=$(echo "$validation_records" | jq -c '{
        Changes: [.[] | {
            Action: "UPSERT",
            ResourceRecordSet: {
                Name: .Name,
                Type: .Type,
                TTL: 300,
                ResourceRecords: [{Value: .Value}]
            }
        }]
    }')
    
    $aws_cmd route53 change-resource-record-sets \
        --hosted-zone-id "$zone_id" \
        --change-batch "$change_batch"
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to create DNS validation records"
        exit 1
    fi
    
    # Wait for certificate validation
    log "INFO" "Waiting for certificate validation (this may take 5-30 minutes)..."
    if ! $aws_cmd acm wait certificate-validated \
        --certificate-arn "$cert_arn" \
        --region "$cert_region"; then
        log "WARN" "Timed out waiting for certificate validation. The process is still ongoing."
        log "INFO" "You can run this script again later to continue from this point."
        return 0
    fi
    
    log "SUCCESS" "Certificate validated successfully"
    mark_step_completed "certificate"
    return 0
}


# Function to create CloudFront OAC
create_oac() {
    if is_step_completed "oac"; then
        local oac_id=$(get_status "oac_id" "")
        # Check if the OAC ID is empty despite being marked as completed
        if [ -z "$oac_id" ]; then
            log "WARN" "OAC marked as completed but ID is empty, will attempt to retrieve"
            # Reset the completion status
            update_status "oac_completed" "false"
        else
            log "INFO" "Origin Access Control already created (ID: $oac_id)"
            return 0
        fi
    fi
    
    log "STEP" "Creating CloudFront Origin Access Control"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    # Create OAC
    local oac_name="${DOMAIN}-oac"
    
    # First, check if the OAC already exists by listing all OACs
    log "INFO" "Checking if OAC already exists"
    local existing_oacs=$($aws_cmd cloudfront list-origin-access-controls --output json)
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to list existing Origin Access Controls"
        return 1
    fi
    
    # Try to find the OAC with the matching name
    local existing_oac_id=$(echo "$existing_oacs" | jq -r --arg name "$oac_name" '.OriginAccessControlList.Items[] | select(.Name == $name) | .Id' 2>/dev/null)
    
    if [ -n "$existing_oac_id" ]; then
        log "INFO" "Found existing OAC with name $oac_name (ID: $existing_oac_id)"
        update_status "oac_id" "$existing_oac_id"
        mark_step_completed "oac"
        return 0
    fi
    
    # If not found, create a new OAC
    local oac_config=$(cat <<EOF
{
    "Name": "$oac_name",
    "Description": "OAC for $DOMAIN",
    "SigningProtocol": "sigv4",
    "SigningBehavior": "always",
    "OriginAccessControlOriginType": "s3"
}
EOF
)
    
    local oac_result=$($aws_cmd cloudfront create-origin-access-control \
        --origin-access-control-config "$oac_config" \
        --output json)
    
    local create_status=$?
    
    # If creation fails but it might be because it already exists, try to retrieve it again
    if [ $create_status -ne 0 ]; then
        log "WARN" "Failed to create OAC, checking if it exists despite the error"
        local retry_oacs=$($aws_cmd cloudfront list-origin-access-controls --output json)
        local retry_oac_id=$(echo "$retry_oacs" | jq -r --arg name "$oac_name" '.OriginAccessControlList.Items[] | select(.Name == $name) | .Id' 2>/dev/null)
        
        if [ -n "$retry_oac_id" ]; then
            log "INFO" "Found existing OAC with name $oac_name (ID: $retry_oac_id)"
            update_status "oac_id" "$retry_oac_id"
            mark_step_completed "oac"
            return 0
        fi
        
        log "ERROR" "Failed to create Origin Access Control and could not find existing one"
        return 1
    fi
    
    # Successfully created new OAC
    local oac_id=$(echo "$oac_result" | jq -r '.OriginAccessControl.Id')
    
    if [ -z "$oac_id" ]; then
        log "ERROR" "Failed to extract OAC ID from result"
        return 1
    fi
    
    log "SUCCESS" "Origin Access Control created successfully (ID: $oac_id)"
    update_status "oac_id" "$oac_id"
    mark_step_completed "oac"
    return 0
}


# Emit the JavaScript for the viewer-request CloudFront Function to stdout.
# CloudFront allows a single function per event type, so both optional
# behaviors (basic auth, clean URLs) are compiled into one handler containing
# only the blocks that were requested. Auth flow: a valid session cookie
# passes immediately; otherwise valid Basic credentials trigger a 302 back to
# the same URI that sets the cookie (checking the cookie FIRST is what
# prevents a redirect loop, since browsers keep resending Authorization);
# anything else gets a 401 challenge.
build_viewer_request_code() {
    echo "function handler(event) {"
    echo "    var request = event.request;"

    if [ -n "$BASIC_AUTH_CSV" ]; then
        local tokens_js=""
        local valid_js=""
        local pairs pair cred_b64 token
        IFS=',' read -ra pairs <<< "$BASIC_AUTH_CSV"
        for pair in "${pairs[@]}"; do
            cred_b64=$(printf '%s' "$pair" | base64)
            token=$(openssl rand -hex 32)
            tokens_js="${tokens_js}        '${cred_b64}': '${token}',"$'\n'
            valid_js="${valid_js}        '${token}': true,"$'\n'
        done

        cat <<EOF
    var TOKENS = {
${tokens_js}    };
    var VALID = {
${valid_js}    };
    var authed = false;
    if (request.cookies['${BASIC_AUTH_COOKIE}'] && VALID[request.cookies['${BASIC_AUTH_COOKIE}'].value]) {
        authed = true;
    }
    if (!authed) {
        var token = '';
        if (request.headers.authorization) {
            var auth = request.headers.authorization.value;
            if (auth.substring(0, 6) === 'Basic ') {
                token = TOKENS[auth.substring(6)] || '';
            }
        }
        if (!token) {
            return {
                statusCode: 401,
                statusDescription: 'Unauthorized',
                headers: {
                    'www-authenticate': { value: 'Basic realm="Restricted"' }
                }
            };
        }
        var location = request.uri;
        var qs = [];
        for (var key in request.querystring) {
            qs.push(key + '=' + request.querystring[key].value);
        }
        if (qs.length > 0) {
            location = location + '?' + qs.join('&');
        }
        return {
            statusCode: 302,
            statusDescription: 'Found',
            headers: {
                'location': { value: location }
            },
            cookies: {
                '${BASIC_AUTH_COOKIE}': {
                    value: token,
                    attributes: 'Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=86400'
                }
            }
        };
    }
EOF
    fi

    if [ "$CLEAN_URLS" = true ]; then
        cat <<'EOF'
    var uri = request.uri;
    if (uri.charAt(uri.length - 1) === '/') {
        request.uri = uri + 'index.html';
    } else if (uri.substring(uri.lastIndexOf('/') + 1).indexOf('.') === -1) {
        request.uri = uri + '.html';
    }
EOF
    fi

    echo "    return request;"
    echo "}"
}

# Function to create/update and publish the viewer-request CloudFront Function.
# No-op unless --clean-urls and/or --basic-auth was requested.
create_viewer_request_function() {
    if [ "$CLEAN_URLS" != true ] && [ -z "$BASIC_AUTH_CSV" ]; then
        return 0
    fi

    if is_step_completed "cf_function"; then
        local existing_arn=$(get_status "function_arn" "")
        if [ -n "$existing_arn" ]; then
            log "INFO" "CloudFront function already created (ARN: $existing_arn)"
            return 0
        fi
        log "WARN" "CloudFront function marked as completed but ARN is empty, will attempt to (re)create"
        update_status "cf_function_completed" "false"
    fi

    log "STEP" "Creating CloudFront viewer-request function for $DOMAIN"

    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi

    # Function names only allow [a-zA-Z0-9-_]
    local fn_name="$(echo "$DOMAIN" | tr '.' '-')-viewer-request"
    local fn_config="Comment=Viewer-request function for ${DOMAIN},Runtime=cloudfront-js-2.0"

    local code_file=$(mktemp)
    build_viewer_request_code > "$code_file"

    # Create or update depending on whether the function already exists
    local etag fn_result
    etag=$($aws_cmd cloudfront describe-function --name "$fn_name" --query "ETag" --output text 2>/dev/null) || etag=""

    if [ -n "$etag" ] && [ "$etag" != "None" ]; then
        log "INFO" "Function $fn_name already exists, updating code"
        if ! fn_result=$($aws_cmd cloudfront update-function \
            --name "$fn_name" \
            --if-match "$etag" \
            --function-config "$fn_config" \
            --function-code "fileb://${code_file}" \
            --output json); then
            rm -f "$code_file"
            log "ERROR" "Failed to update CloudFront function $fn_name"
            return 1
        fi
    else
        log "INFO" "Creating function $fn_name"
        if ! fn_result=$($aws_cmd cloudfront create-function \
            --name "$fn_name" \
            --function-config "$fn_config" \
            --function-code "fileb://${code_file}" \
            --output json); then
            rm -f "$code_file"
            log "ERROR" "Failed to create CloudFront function $fn_name"
            return 1
        fi
    fi
    rm -f "$code_file"

    local fn_arn=$(echo "$fn_result" | jq -r '.FunctionSummary.FunctionMetadata.FunctionARN')
    etag=$(echo "$fn_result" | jq -r '.ETag')

    if [ -z "$fn_arn" ] || [ "$fn_arn" = "null" ]; then
        log "ERROR" "Failed to extract function ARN from result"
        return 1
    fi

    # Publish to LIVE — the distribution can only associate a published function
    log "INFO" "Publishing function $fn_name"
    if ! $aws_cmd cloudfront publish-function --name "$fn_name" --if-match "$etag" >/dev/null; then
        log "ERROR" "Failed to publish CloudFront function $fn_name"
        return 1
    fi

    log "SUCCESS" "CloudFront function created and published (ARN: $fn_arn)"
    update_status "function_name" "$fn_name"
    update_status "function_arn" "$fn_arn"
    update_status "clean_urls" "$CLEAN_URLS"
    if [ -n "$BASIC_AUTH_CSV" ]; then
        # Usernames only — passwords are never persisted
        local users=$(echo "$BASIC_AUTH_CSV" | tr ',' '\n' | cut -d: -f1 | paste -sd' ' -)
        update_status "basic_auth_users" "$users"
    fi
    mark_step_completed "cf_function"
    return 0
}


# Function to create CloudFront distribution
create_cloudfront_distribution() {
    if is_step_completed "cloudfront"; then
        local distribution_id=$(get_status "distribution_id" "")
        local distribution_domain=$(get_status "distribution_domain" "")
        
        # Check if the distribution info is empty or malformed despite being marked as completed
        if [ -z "$distribution_id" ] || [ -z "$distribution_domain" ] || [[ "$distribution_id" == *$'\n'* ]]; then
            log "WARN" "CloudFront distribution marked as completed but information is missing or malformed, will attempt to retrieve"
            # Reset the completion status
            update_status "cloudfront_completed" "false"
        else
            log "INFO" "CloudFront distribution already created (ID: $distribution_id, Domain: $distribution_domain)"
            return 0
        fi
    fi
    
    log "STEP" "Creating CloudFront distribution for $DOMAIN"
    
    # Check if certificate is validated
    if ! is_step_completed "certificate"; then
        log "WARN" "Certificate is not yet validated. Please run the script again later."
        return 1
    fi
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    local bucket_name=$(get_status "bucket_name" "")
    local cert_arn=$(get_status "certificate_arn" "")
    local oac_id=$(get_status "oac_id" "")
    
    # Check if a distribution already exists for this domain
    log "INFO" "Checking if distribution already exists for $DOMAIN"
    local distributions=$($aws_cmd cloudfront list-distributions --output json)
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to list CloudFront distributions"
        return 1
    fi
    
    # Try to find a distribution with our domain in the aliases
    # First check if the domain exists in any Items array to avoid jq errors
    local has_domain=$(echo "$distributions" | jq -r --arg domain "$DOMAIN" '.DistributionList.Items[].Aliases | select(.Items != null) | .Items[] | select(. == $domain)' 2>/dev/null)
    
    if [ -n "$has_domain" ]; then
        # Find the distribution with this domain
        local existing_dist_id=$(echo "$distributions" | jq -r --arg domain "$DOMAIN" '.DistributionList.Items[] | select(.Aliases.Items != null) | select(.Aliases.Items[] == $domain) | .Id' 2>/dev/null | head -n 1)
        
        if [ -n "$existing_dist_id" ]; then
            # Get the domain name for the distribution
            local existing_dist_domain=$(echo "$distributions" | jq -r --arg id "$existing_dist_id" '.DistributionList.Items[] | select(.Id == $id) | .DomainName' 2>/dev/null)
            
            log "INFO" "Found existing distribution for $DOMAIN (ID: $existing_dist_id, Domain: $existing_dist_domain)"
            if [ -n "$(get_status "function_arn" "")" ]; then
                log "WARN" "Reusing an existing distribution: the viewer-request function was NOT attached to it."
                log "WARN" "Associate $(get_status "function_name" "") manually if --clean-urls/--basic-auth should apply."
            fi
            update_status "distribution_id" "$existing_dist_id"
            update_status "distribution_domain" "$existing_dist_domain"
            mark_step_completed "cloudfront"
            
            # Update S3 bucket policy
            update_bucket_policy
            
            return 0
        fi
    fi
    
    # Attach the viewer-request function if one was provisioned
    local fn_arn=$(get_status "function_arn" "")
    local function_associations
    if [ -n "$fn_arn" ]; then
        function_associations=$(cat <<EOF
{
            "Quantity": 1,
            "Items": [
                {
                    "FunctionARN": "${fn_arn}",
                    "EventType": "viewer-request"
                }
            ]
        }
EOF
)
    else
        function_associations='{ "Quantity": 0 }'
    fi

    # Prepare distribution config
    local dist_config_file=$(mktemp)
    cat > "$dist_config_file" <<EOF
{
    "CallerReference": "${DOMAIN}-$(date +%s)",
    "Aliases": {
        "Quantity": 1,
        "Items": [
            "${DOMAIN}"
        ]
    },
    "DefaultRootObject": "index.html",
    "Origins": {
        "Quantity": 1,
        "Items": [
            {
                "Id": "S3-${bucket_name}",
                "DomainName": "${bucket_name}.s3.${AWS_REGION}.amazonaws.com",
                "OriginPath": "",
                "CustomHeaders": {
                    "Quantity": 0
                },
                "S3OriginConfig": {
                    "OriginAccessIdentity": ""
                },
                "OriginAccessControlId": "${oac_id}"
            }
        ]
    },
    "OriginGroups": {
        "Quantity": 0
    },
    "DefaultCacheBehavior": {
        "TargetOriginId": "S3-${bucket_name}",
        "ViewerProtocolPolicy": "redirect-to-https",
        "AllowedMethods": {
            "Quantity": 2,
            "Items": [
                "GET",
                "HEAD"
            ],
            "CachedMethods": {
                "Quantity": 2,
                "Items": [
                    "GET",
                    "HEAD"
                ]
            }
        },
        "SmoothStreaming": false,
        "Compress": true,
        "LambdaFunctionAssociations": {
            "Quantity": 0
        },
        "FieldLevelEncryptionId": "",
        "FunctionAssociations": ${function_associations},
        "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
        "OriginRequestPolicyId": "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf"
    },
    "CacheBehaviors": {
        "Quantity": 0
    },
    "CustomErrorResponses": {
        "Quantity": 1,
        "Items": [
            {
                "ErrorCode": 404,
                "ResponsePagePath": "/error.html",
                "ResponseCode": "404",
                "ErrorCachingMinTTL": 10
            }
        ]
    },
    "Comment": "Distribution for ${DOMAIN}",
    "Logging": {
        "Enabled": false,
        "IncludeCookies": false,
        "Bucket": "",
        "Prefix": ""
    },
    "PriceClass": "PriceClass_100",
    "Enabled": true,
    "ViewerCertificate": {
        "ACMCertificateArn": "${cert_arn}",
        "SSLSupportMethod": "sni-only",
        "MinimumProtocolVersion": "TLSv1.2_2021",
        "Certificate": "${cert_arn}",
        "CertificateSource": "acm"
    },
    "Restrictions": {
        "GeoRestriction": {
            "RestrictionType": "none",
            "Quantity": 0
        }
    },
    "WebACLId": "",
    "HttpVersion": "http2",
    "IsIPV6Enabled": true
}
EOF
    
    # Create distribution
    log "INFO" "Creating CloudFront distribution (this may take a minute)..."
    local dist_result=$($aws_cmd cloudfront create-distribution \
        --distribution-config "file://${dist_config_file}" \
        --output json)
    
    rm -f "$dist_config_file"
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to create CloudFront distribution"
        return 1
    fi
    
    local distribution_id=$(echo "$dist_result" | jq -r '.Distribution.Id')
    local distribution_domain=$(echo "$dist_result" | jq -r '.Distribution.DomainName')
    
    # Validate that we got valid values
    if [ -z "$distribution_id" ] || [ -z "$distribution_domain" ]; then
        log "ERROR" "Failed to extract distribution information from result"
        return 1
    fi
    
    log "SUCCESS" "CloudFront distribution created successfully"
    log "INFO" "Distribution ID: $distribution_id"
    log "INFO" "Distribution Domain: $distribution_domain"
    
    update_status "distribution_id" "$distribution_id"
    update_status "distribution_domain" "$distribution_domain"
    mark_step_completed "cloudfront"
    
    # Update S3 bucket policy
    update_bucket_policy
    
    return 0
}


# Function to update S3 bucket policy
update_bucket_policy() {
    log "STEP" "Updating S3 bucket policy"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    local bucket_name=$(get_status "bucket_name" "")
    local account_id=$(get_status "account_id" "")
    
    # Create bucket policy
    local policy_file=$(mktemp)
    cat > "$policy_file" <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowCloudFrontServicePrincipal",
            "Effect": "Allow",
            "Principal": {
                "Service": "cloudfront.amazonaws.com"
            },
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::${bucket_name}/*",
            "Condition": {
                "StringEquals": {
                    "AWS:SourceArn": "arn:aws:cloudfront::${account_id}:distribution/$(get_status "distribution_id" "")"
                }
            }
        }
    ]
}
EOF
    
    # Apply policy
    $aws_cmd s3api put-bucket-policy \
        --bucket "$bucket_name" \
        --policy "file://${policy_file}"
    
    rm -f "$policy_file"
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to update bucket policy"
        return 1
    fi
    
    log "SUCCESS" "Bucket policy updated successfully"
    return 0
}

# Function to create Route53 DNS records

create_dns_records() {
    if is_step_completed "dns"; then
        log "INFO" "DNS records already created"
        return 0
    fi
    
    log "STEP" "Creating Route53 DNS records for $DOMAIN"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    local zone_id=$(get_status "zone_id" "")
    local distribution_domain=$(get_status "distribution_domain" "")
    
    # Sanity check for empty distribution domain
    if [ -z "$distribution_domain" ]; then
        log "ERROR" "Distribution domain is empty, cannot create DNS records"
        log "INFO" "Make sure the CloudFront distribution was created successfully"
        return 1
    fi
    
    # Create A record aliases for domain
    local change_batch=$(cat <<EOF
{
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "${DOMAIN}.",
                "Type": "A",
                "AliasTarget": {
                    "HostedZoneId": "Z2FDTNDATAQYW2",
                    "DNSName": "${distribution_domain}",
                    "EvaluateTargetHealth": false
                }
            }
        }
    ]
}
EOF
)
    
    $aws_cmd route53 change-resource-record-sets \
        --hosted-zone-id "$zone_id" \
        --change-batch "$change_batch"
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to create DNS records"
        return 1
    fi
    
    log "SUCCESS" "DNS records created successfully"
    mark_step_completed "dns"
    return 0
}


# Function to upload sample content
upload_sample_content() {
    if is_step_completed "content"; then
        log "INFO" "Sample content already uploaded"
        return 0
    fi
    
    log "STEP" "Uploading sample content to S3 bucket"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    local bucket_name=$(get_status "bucket_name" "")
    
    # Create sample index.html
    local index_file=$(mktemp)
    cat > "$index_file" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome to ${DOMAIN}</title>
    <style>
        body {
            font-family: Helvetica, Arial, sans-serif;
            max-width: 800px;
            margin: 0 auto;
            padding: 40px 20px;
            line-height: 1.6;
            color: #333;
        }
        h1 {
            color: #0066cc;
        }
        .success {
            background-color: #cccccc;
            color: #000000;
            padding: 15px;
            border-radius: 4px;
            margin-bottom: 20px;
        }
    </style>
</head>
<body>
    <div class="success">
        <h1>Hello, World!</h1>
        <p>Your site is live and routing.</p>
    </div>
    <p>Deployed on: $(date)</p>
</body>
</html>
EOF
    
    # Create sample error.html
    local error_file=$(mktemp)
    cat > "$error_file" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Page Not Found - ${DOMAIN}</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            max-width: 800px;
            margin: 0 auto;
            padding: 40px 20px;
            line-height: 1.6;
            color: #333;
            text-align: center;
        }
        h1 {
            color: #dc3545;
        }
        .error {
            background-color: #f8d7da;
            color: #721c24;
            padding: 15px;
            border-radius: 4px;
            margin-bottom: 20px;
        }
        a {
            color: #0066cc;
            text-decoration: none;
        }
        a:hover {
            text-decoration: underline;
        }
    </style>
</head>
<body>
    <div class="error">
        <h1>404 - Page Not Found</h1>
        <p>The page you are looking for does not exist.</p>
    </div>
    <p><a href="/">Return to homepage</a></p>
</body>
</html>
EOF
    
    # Upload files to S3
    $aws_cmd s3 cp "$index_file" "s3://${bucket_name}/index.html" --content-type "text/html" --cache-control "no-cache"
    $aws_cmd s3 cp "$error_file" "s3://${bucket_name}/error.html" --content-type "text/html" --cache-control "no-cache"
    
    rm -f "$index_file" "$error_file"
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to upload sample content"
        return 1
    fi
    
    log "SUCCESS" "Sample content uploaded successfully"
    mark_step_completed "content"
    return 0
}

# Function to invalidate CloudFront cache
invalidate_cache() {
    log "STEP" "Invalidating CloudFront cache"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    local distribution_id=$(get_status "distribution_id" "")
    
    # Create invalidation
    local invalidation_result=$($aws_cmd cloudfront create-invalidation \
        --distribution-id "$distribution_id" \
        --paths "/*" \
        --output json)
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to create invalidation"
        return 1
    fi
    
    local invalidation_id=$(echo "$invalidation_result" | jq -r '.Invalidation.Id')
    
    log "SUCCESS" "Cache invalidation created successfully (ID: $invalidation_id)"
    update_status "invalidation_id" "$invalidation_id"
    return 0
}

# Function to wait for CloudFront distribution deployment
wait_for_distribution() {
    log "STEP" "Waiting for CloudFront distribution deployment"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    local distribution_id=$(get_status "distribution_id" "")
    
    log "INFO" "Waiting for distribution deployment (this may take 5-10 minutes)..."
    if ! $aws_cmd cloudfront wait distribution-deployed \
        --id "$distribution_id"; then
        
        log "WARN" "Timed out waiting for distribution deployment"
        log "INFO" "Attempting additional checks..."
        
        # Additional checks
        local attempts=0
        local max_attempts=$TIMEOUT_RETRIES
        
        while [ $attempts -lt $max_attempts ]; do
            attempts=$((attempts + 1))
            log "INFO" "Additional check attempt ($attempts/$max_attempts)"
            
            local status=$($aws_cmd cloudfront get-distribution \
                --id "$distribution_id" \
                --query "Distribution.Status" \
                --output text)
            
            if [ "$status" = "Deployed" ]; then
                log "SUCCESS" "Distribution is now deployed"
                return 0
            fi
            
            log "INFO" "Current status: $status (waiting for 'Deployed')"
            sleep 30
        done
        
        log "WARN" "Distribution is still not fully deployed after additional checks"
        log "INFO" "The deployment will continue in the background"
        return 0
    fi
    
    log "SUCCESS" "Distribution is now deployed"
    return 0
}

# Function to verify deployment
verify_deployment() {
    if is_step_completed "verification"; then
        log "INFO" "Deployment already verified"
        return 0
    fi
    
    log "STEP" "Verifying deployment"
    
    # Check DNS resolution
    log "INFO" "Checking DNS resolution for $DOMAIN..."
    if ! host "$DOMAIN" &>/dev/null; then
        log "WARN" "DNS not yet propagated for $DOMAIN"
    else
        log "SUCCESS" "DNS resolution successful for $DOMAIN"
    fi
    
    # Try to access the website
    log "INFO" "Checking website accessibility..."
    local http_code
    if [ -n "$BASIC_AUTH_CSV" ]; then
        # With basic auth enabled, an anonymous request must be challenged...
        local unauth_code=$(curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN")
        if [ "$unauth_code" = "401" ]; then
            log "SUCCESS" "Unauthenticated request correctly challenged (HTTP 401)"
        else
            log "WARN" "Expected HTTP 401 without credentials, got HTTP $unauth_code"
        fi
        # ...and the first credential pair must get through (302 sets the
        # session cookie, -L -b/-c follows with it).
        local first_pair="${BASIC_AUTH_CSV%%,*}"
        local cookie_jar=$(mktemp)
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -L -u "$first_pair" -c "$cookie_jar" -b "$cookie_jar" "https://$DOMAIN")
        rm -f "$cookie_jar"
    else
        http_code=$(curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN")
    fi
    
    if [ "$http_code" = "200" ]; then
        log "SUCCESS" "Website is accessible (HTTP 200)"
        mark_step_completed "verification"
    else
        log "WARN" "Website returned HTTP $http_code"
        log "INFO" "DNS propagation may take more time"
    fi
    
    return 0
}

# Function to optionally create a scoped IAM user for site administration.
# The user gets an inline policy permitting object-level S3 access on the
# provisioned bucket and CreateInvalidation on the provisioned distribution
# only. The access key secret is printed ONCE and is NEVER written to the
# status file.
create_scoped_user() {
    if [ "$CREATE_SCOPED_USER" != true ]; then
        return 0
    fi

    if is_step_completed "scoped_user"; then
        local existing_user=$(get_status "scoped_user_name" "")
        log "INFO" "Scoped IAM user already provisioned (User: $existing_user)"
        log "INFO" "If the secret was lost, delete the user via remove-site.sh and re-run."
        return 0
    fi

    log "STEP" "Creating scoped IAM user for $DOMAIN"

    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi

    local bucket_name=$(get_status "bucket_name" "")
    local distribution_id=$(get_status "distribution_id" "")
    local account_id=$(get_status "account_id" "")

    if [ -z "$bucket_name" ] || [ -z "$distribution_id" ] || [ -z "$account_id" ]; then
        log "ERROR" "Cannot create scoped user before bucket, distribution, and account ID are known"
        return 1
    fi

    local user_name="${DOMAIN}-site-admin"
    local policy_name="${DOMAIN}-site-admin-policy"

    # Create the IAM user (idempotent: ignore EntityAlreadyExists)
    if $aws_cmd iam get-user --user-name "$user_name" &>/dev/null; then
        log "INFO" "IAM user $user_name already exists, reusing"
    else
        log "INFO" "Creating IAM user $user_name"
        if ! $aws_cmd iam create-user \
            --user-name "$user_name" \
            --tags "Key=ManagedBy,Value=s3-static-toolkit" "Key=Domain,Value=${DOMAIN}" \
            >/dev/null; then
            log "ERROR" "Failed to create IAM user $user_name"
            return 1
        fi
    fi

    # Attach the inline scoped policy. put-user-policy is idempotent (overwrites).
    local policy_file=$(mktemp)
    cat > "$policy_file" <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "S3BucketLevel",
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetBucketLocation"
            ],
            "Resource": "arn:aws:s3:::${bucket_name}"
        },
        {
            "Sid": "S3ObjectLevel",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:GetObjectTagging",
                "s3:PutObjectTagging",
                "s3:DeleteObjectTagging",
                "s3:GetObjectAcl",
                "s3:PutObjectAcl"
            ],
            "Resource": "arn:aws:s3:::${bucket_name}/*"
        },
        {
            "Sid": "CloudFrontInvalidation",
            "Effect": "Allow",
            "Action": [
                "cloudfront:CreateInvalidation",
                "cloudfront:GetInvalidation",
                "cloudfront:ListInvalidations"
            ],
            "Resource": "arn:aws:cloudfront::${account_id}:distribution/${distribution_id}"
        }
    ]
}
EOF

    log "INFO" "Attaching inline policy $policy_name"
    if ! $aws_cmd iam put-user-policy \
        --user-name "$user_name" \
        --policy-name "$policy_name" \
        --policy-document "file://${policy_file}"; then
        rm -f "$policy_file"
        log "ERROR" "Failed to attach inline policy $policy_name"
        return 1
    fi
    rm -f "$policy_file"

    # Only create an access key if the user has none. AWS limits to 2 keys per
    # user; we don't want to silently consume a slot on a re-run.
    local existing_keys
    existing_keys=$($aws_cmd iam list-access-keys --user-name "$user_name" --query 'AccessKeyMetadata[].AccessKeyId' --output text)
    if [ -n "$existing_keys" ] && [ "$existing_keys" != "None" ]; then
        log "WARN" "User $user_name already has access keys; skipping key creation."
        log "INFO" "Existing key IDs: $existing_keys"
        update_status "scoped_user_name" "$user_name"
        update_status "scoped_user_policy_name" "$policy_name"
        mark_step_completed "scoped_user"
        return 0
    fi

    log "INFO" "Creating access key for $user_name"
    local key_result
    key_result=$($aws_cmd iam create-access-key --user-name "$user_name" --output json)
    if [ $? -ne 0 ] || [ -z "$key_result" ]; then
        log "ERROR" "Failed to create access key"
        return 1
    fi

    local access_key_id=$(echo "$key_result" | jq -r '.AccessKey.AccessKeyId')
    local secret_access_key=$(echo "$key_result" | jq -r '.AccessKey.SecretAccessKey')

    update_status "scoped_user_name" "$user_name"
    update_status "scoped_user_policy_name" "$policy_name"
    update_status "scoped_user_access_key_id" "$access_key_id"
    mark_step_completed "scoped_user"

    # Print credentials prominently. This is the only time the secret is shown.
    echo
    echo -e "${BOLD}${BG_RED}${WHITE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BG_RED}${WHITE}║   SCOPED IAM USER CREDENTIALS — SHOWN ONCE, COPY NOW         ║${NC}"
    echo -e "${BOLD}${BG_RED}${WHITE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "  ${BOLD}User name:${NC}          $user_name"
    echo -e "  ${BOLD}Access Key ID:${NC}      $access_key_id"
    echo -e "  ${BOLD}Secret Access Key:${NC}  $secret_access_key"
    echo
    echo -e "${YELLOW}Permissions: read/write/delete objects in s3://${bucket_name},${NC}"
    echo -e "${YELLOW}             CreateInvalidation on distribution ${distribution_id}.${NC}"
    echo
    echo -e "${RED}${BOLD}The secret is NOT stored in the status file and cannot be retrieved.${NC}"
    echo -e "${RED}${BOLD}If lost, delete the user via remove-site.sh and re-run with --create-scoped-user.${NC}"
    echo

    log "SUCCESS" "Scoped IAM user $user_name created"
    return 0
}

# Function to display deployment summary
display_summary() {
    log "STEP" "Deployment Summary"
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                  ${BOLD}DEPLOYMENT SUMMARY${NC}${CYAN}                        ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${BOLD}Domain:${NC} $DOMAIN"
    echo -e "${BOLD}S3 Bucket:${NC} $(get_status "bucket_name" "N/A")"
    echo -e "${BOLD}CloudFront Distribution:${NC} $(get_status "distribution_id" "N/A")"
    echo -e "${BOLD}Distribution Domain:${NC} $(get_status "distribution_domain" "N/A")"
    echo -e "${BOLD}Status File:${NC} $STATUS_FILE"
    local fn_name=$(get_status "function_name" "")
    if [ -n "$fn_name" ]; then
        echo -e "${BOLD}CloudFront Function:${NC} $fn_name"
        echo -e "  clean-urls: $(get_status "clean_urls" "false")"
        local ba_users=$(get_status "basic_auth_users" "")
        if [ -n "$ba_users" ]; then
            echo -e "  basic-auth users: $ba_users (session cookie: $BASIC_AUTH_COOKIE)"
        fi
    fi
    local scoped_user=$(get_status "scoped_user_name" "")
    if [ -n "$scoped_user" ]; then
        echo -e "${BOLD}Scoped IAM User:${NC} $scoped_user (Access Key: $(get_status "scoped_user_access_key_id" "N/A"))"
    fi
    echo
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                      ${BOLD}NEXT STEPS${NC}${CYAN}                            ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "1. ${BOLD}Access your website:${NC}"
    echo -e "   https://$DOMAIN"
    echo
    echo -e "2. ${BOLD}Upload your content:${NC}"
    echo -e "   aws s3 sync ./your-content-folder/ s3://$(get_status "bucket_name" "")"
    echo
    echo -e "3. ${BOLD}Invalidate cache after updates:${NC}"
    echo -e "   aws cloudfront create-invalidation --distribution-id $(get_status "distribution_id" "") --paths \"/*\""
    echo
    
    # Check if all steps are completed
    local all_completed=true
    for step in "hosted_zone" "s3_bucket" "certificate" "oac" "cloudfront" "dns" "content" "verification"; do
        if ! is_step_completed "$step"; then
            all_completed=false
            break
        fi
    done
    
    if [ "$all_completed" = true ]; then
        echo -e "${GREEN}${BOLD}Deployment completed successfully!${NC}"
    else
        echo -e "${YELLOW}${BOLD}Deployment is partially complete.${NC}"
        echo -e "Run the script again to continue from where it left off."
    fi
}

# Main execution
main() {
    # Process command line arguments
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
            --yes)
                AUTO_APPROVE=true
                shift
                ;;
            --status-file)
                STATUS_FILE="$2"
                shift
                shift
                ;;
            --create-scoped-user)
                CREATE_SCOPED_USER=true
                shift
                ;;
            --clean-urls)
                CLEAN_URLS=true
                shift
                ;;
            --basic-auth)
                BASIC_AUTH_CSV="$2"
                shift
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
    
    # Check for required parameters
    if [ -z "$DOMAIN" ]; then
        log "ERROR" "Domain name is required"
        usage
    fi

    # Validate --basic-auth input before doing anything else
    validate_basic_auth_csv

    # Welcome message
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║            ${BOLD}AWS STATIC SITE DEPLOYMENT SCRIPT${NC}${CYAN}               ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${BOLD}Domain:${NC} $DOMAIN"
    echo -e "${BOLD}AWS Region:${NC} $AWS_REGION"
    if [ -n "$AWS_PROFILE" ]; then
        echo -e "${BOLD}AWS Profile:${NC} $AWS_PROFILE"
    fi
    echo
    
    # Initialize status file
    init_status_file
    
    # Check prerequisites
    check_prerequisites
    
    # Check AWS configuration
    check_aws_config
    
    # Confirm deployment
    if ! confirm_action "Proceed with deployment?"; then
        log "INFO" "Deployment cancelled"
        exit 0
    fi
    
    # Execute deployment steps
    check_hosted_zone
    create_s3_bucket
    create_certificate
    create_oac
    create_viewer_request_function
    create_cloudfront_distribution
    create_dns_records
    upload_sample_content
    invalidate_cache
    wait_for_distribution
    verify_deployment
    create_scoped_user

    # Display summary
    display_summary
}

# Run the script
main "$@"