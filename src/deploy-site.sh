#!/bin/bash
# =============================================================================
# AWS Static Site Deployment Script
# 
# This script automates the deployment of a static website on AWS using:
# - S3 for static content hosting
# - CloudFront for CDN and HTTPS
# - ACM for SSL certificate
# - Route53 for DNS management
#
# Usage: ./deploy.sh --domain yourdomain.com [options]
# Options:
#   --domain DOMAIN     Domain name (required)
#   --profile PROFILE   AWS CLI profile (optional)
#   --region REGION     AWS region (default: us-east-1)
#   --yes               Skip all confirmation prompts
#   --status-file FILE  Custom status file path
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
AWS_REGION="us-east-1"
AWS_PROFILE=""
DOMAIN=""
STATUS_FILE=""
AUTO_APPROVE=false
TIMEOUT_RETRIES=5
CERTIFICATE_WAIT_SECONDS=120
CERTIFICATE_WAIT_INTERVAL=10

# Function to display script usage
usage() {
    echo -e "${BOLD}Usage:${NC} $0 --domain yourdomain.com [options]"
    echo -e "${BOLD}Options:${NC}"
    echo "  --domain DOMAIN     Domain name (required)"
    echo "  --profile PROFILE   AWS CLI profile (optional)"
    echo "  --region REGION     AWS region (default: us-east-1)"
    echo "  --yes               Skip all confirmation prompts"
    echo "  --status-file FILE  Custom status file path"
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

# Function to check AWS CLI configuration
check_aws_config() {
    log "STEP" "Checking AWS CLI configuration"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    if ! $aws_cmd sts get-caller-identity &> /dev/null; then
        log "ERROR" "AWS CLI is not configured correctly"
        log "INFO" "Please run 'aws configure' or check your credentials and try again."
        exit 1
    fi
    
    local account_id=$($aws_cmd sts get-caller-identity --query "Account" --output text)
    log "SUCCESS" "AWS CLI is configured correctly (Account ID: $account_id)"
    
    # Store account ID in status file
    update_status "account_id" "$account_id"
}

# Function to initialize or load status file
init_status_file() {
    if [ -z "$STATUS_FILE" ]; then
        STATUS_FILE=".deploy-status-${DOMAIN}.json"
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
        log "INFO" "Hosted zone already verified (Zone ID: $zone_id)"
        return 0
    fi
    
    log "STEP" "Checking Route53 hosted zone for $DOMAIN"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    local zone_id=$($aws_cmd route53 list-hosted-zones --query "HostedZones[?Name=='$DOMAIN.' || Name=='$DOMAIN'].Id" --output text | sed 's/\/hostedzone\///')
    
    if [ -z "$zone_id" ]; then
        log "ERROR" "No Route53 hosted zone found for $DOMAIN"
        log "INFO" "Please create a hosted zone for $DOMAIN in Route53 and try again."
        exit 1
    fi
    
    log "SUCCESS" "Found Route53 hosted zone for $DOMAIN (Zone ID: $zone_id)"
    update_status "zone_id" "$zone_id"
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
    $aws_cmd s3 website \
        --bucket "$bucket_name" \
        --index-document index.html \
        --error-document error.html
    
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
        log "INFO" "Origin Access Control already created (ID: $oac_id)"
        return 0
    fi
    
    log "STEP" "Creating CloudFront Origin Access Control"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    # Create OAC
    local oac_name="${DOMAIN}-oac"
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
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to create Origin Access Control"
        exit 1
    fi
    
    local oac_id=$(echo "$oac_result" | jq -r '.OriginAccessControl.Id')
    
    log "SUCCESS" "Origin Access Control created successfully (ID: $oac_id)"
    update_status "oac_id" "$oac_id"
    mark_step_completed "oac"
    return 0
}

# Function to create CloudFront distribution
create_cloudfront_distribution() {
    if is_step_completed "cloudfront"; then
        local distribution_id=$(get_status "distribution_id" "")
        local distribution_domain=$(get_status "distribution_domain" "")
        log "INFO" "CloudFront distribution already created (ID: $distribution_id, Domain: $distribution_domain)"
        return 0
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
    
    # Prepare distribution config
    local dist_config_file=$(mktemp)
    cat > "$dist_config_file" <<EOF
{
    "CallerReference": "${DOMAIN}-$(date +%s)",
    "Aliases": {
        "Quantity": 2,
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
        exit 1
    fi
    
    local distribution_id=$(echo "$dist_result" | jq -r '.Distribution.Id')
    local distribution_domain=$(echo "$dist_result" | jq -r '.Distribution.DomainName')
    
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
    
    # Create A record aliases for domain and www subdomain
    local change_batch=$(cat <<EOF
{
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "${DOMAIN}",
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
    $aws_cmd s3 cp "$index_file" "s3://${bucket_name}/index.html" --content-type "text/html"
    $aws_cmd s3 cp "$error_file" "s3://${bucket_name}/error.html" --content-type "text/html"
    
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
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN")
    
    if [ "$http_code" = "200" ]; then
        log "SUCCESS" "Website is accessible (HTTP 200)"
        mark_step_completed "verification"
    else
        log "WARN" "Website returned HTTP $http_code"
        log "INFO" "DNS propagation may take more time"
    fi
    
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
    if [ -z "$DOMAIN" ]; then
        log "ERROR" "Domain name is required"
        usage
    fi
    
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
    create_cloudfront_distribution
    create_dns_records
    upload_sample_content
    invalidate_cache
    wait_for_distribution
    verify_deployment
    
    # Display summary
    display_summary
}

# Run the script
main "$@"