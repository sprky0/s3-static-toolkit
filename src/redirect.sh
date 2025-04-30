#!/bin/bash
# =============================================================================
# AWS Multiple Domain Redirect Script
# 
# This script sets up redirects from multiple source domains to a single
# target domain using:
# - S3 for website redirect
# - CloudFront for CDN and HTTPS
# - ACM for SSL certificate
# - Route53 for DNS management
#
# Usage: ./redirect.sh --source-domains domain1.com,www.domain1.com,domain2.com 
#                      --target-domain target.com [options]
# Options:
#   --source-domains DOMAINS   Comma-separated list of source domains (required)
#   --target-domain DOMAIN     Target domain to redirect to (required)
#   --profile PROFILE          AWS CLI profile (optional)
#   --region REGION            AWS region (default: us-east-1)
#   --yes                      Skip all confirmation prompts
#   --status-file FILE         Custom status file path
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
SOURCE_DOMAINS=""
TARGET_DOMAIN=""
STATUS_FILE=""
AUTO_APPROVE=false
TIMEOUT_RETRIES=5
CERTIFICATE_WAIT_SECONDS=120
CERTIFICATE_WAIT_INTERVAL=10

# Function to display script usage
usage() {
    echo -e "${BOLD}Usage:${NC} $0 --source-domains domain1.com,www.domain1.com,domain2.com --target-domain target.com [options]"
    echo -e "${BOLD}Options:${NC}"
    echo "  --source-domains DOMAINS   Comma-separated list of source domains (required)"
    echo "  --target-domain DOMAIN     Target domain to redirect to (required)"
    echo "  --profile PROFILE          AWS CLI profile (optional)"
    echo "  --region REGION            AWS region (default: us-east-1)"
    echo "  --yes                      Skip all confirmation prompts"
    echo "  --status-file FILE         Custom status file path"
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
        STATUS_FILE=".redirect-status-$(echo $SOURCE_DOMAINS | cut -d',' -f1).json"
    fi
    
    if [ -f "$STATUS_FILE" ]; then
        log "INFO" "Using existing status file: $STATUS_FILE"
    else {
        local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        local json_content=$(cat <<EOF
{
    "source_domains": "$SOURCE_DOMAINS",
    "target_domain": "$TARGET_DOMAIN",
    "created_at": "$timestamp"
}
EOF
)
        echo "$json_content" > "$STATUS_FILE"
        log "INFO" "Creating new status file: $STATUS_FILE"
    }
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

# Function to update status file with a JSON array
update_status_array() {
    local key=$1
    local json_array=$2
    
    if [ -f "$STATUS_FILE" ]; then
        # Use temp file
        local temp_file=$(mktemp)
        jq -r --arg key "$key" --argjson value "$json_array" '. + {($key): $value}' "$STATUS_FILE" > "$temp_file"
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

# Function to get array from status file
get_status_array() {
    local key=$1
    
    if [ -f "$STATUS_FILE" ]; then
        jq -r --arg key "$key" '.[$key] // []' "$STATUS_FILE"
    else
        echo "[]"
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

# Function to parse domains into an array
# Function to parse domains into an array
parse_domains() {
    log "STEP" "Parsing domain information"
    
    # Parse source domains
    IFS=',' read -ra DOMAIN_ARRAY <<< "$SOURCE_DOMAINS"
    
    # Check if there are more than 10 domains
    if [ ${#DOMAIN_ARRAY[@]} -gt 10 ]; then
        log "ERROR" "Too many domains provided. Maximum allowed is 10, but got ${#DOMAIN_ARRAY[@]}"
        exit 1
    fi
    
    # Create JSON array of domains
    local domains_json="["
    local first=true
    for domain in "${DOMAIN_ARRAY[@]}"; do
        domain=$(echo "$domain" | xargs) # Trim whitespace
        if [ "$first" = true ]; then
            first=false
        else
            domains_json+=","
        fi
        domains_json+="\"$domain\""
    done
    domains_json+="]"
    
    update_status_array "domains_array" "$domains_json"
    log "INFO" "Parsed ${#DOMAIN_ARRAY[@]} source domains"
    log "INFO" "Target domain: $TARGET_DOMAIN"
}

# Function to check Route53 hosted zones for all domains
check_hosted_zones() {
    if is_step_completed "hosted_zones"; then
        log "INFO" "Hosted zones already verified"
        return 0
    fi
    
    log "STEP" "Checking Route53 hosted zones for all domains"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    # Get all hosted zones
    local all_zones=$($aws_cmd route53 list-hosted-zones --output json)
    
    # Domains array from status file
    local domains_json=$(get_status_array "domains_array")
    # Add target domain to check
    domains_json=$(echo "$domains_json" | jq ". + [\"$TARGET_DOMAIN\"]")
    
    # Create zones JSON
    local zones_json="{"
    local first=true
    
    # For each domain, find its zone
    for domain in $(echo "$domains_json" | jq -r '.[]'); do
        log "INFO" "Checking hosted zone for $domain"
        
        # Try exact domain
        local zone_id=$(echo "$all_zones" | jq -r --arg domain "$domain." '.HostedZones[] | select(.Name == $domain) | .Id' | sed 's/\/hostedzone\///')
        
        # If not found, try to find parent domain
        if [ -z "$zone_id" ]; then
            # Split domain into parts
            IFS='.' read -ra DOMAIN_PARTS <<< "$domain"
            local parts_count=${#DOMAIN_PARTS[@]}
            
            # Try to find parent domain (e.g., example.com for www.example.com)
            if [ $parts_count -gt 2 ]; then
                local parent_domain="${DOMAIN_PARTS[$(($parts_count-2))]}.${DOMAIN_PARTS[$(($parts_count-1))]}"
                zone_id=$(echo "$all_zones" | jq -r --arg domain "$parent_domain." '.HostedZones[] | select(.Name == $domain) | .Id' | sed 's/\/hostedzone\///')
            fi
        fi
        
        if [ -z "$zone_id" ]; then
            log "ERROR" "No Route53 hosted zone found for $domain"
            log "INFO" "Please create a hosted zone for $domain in Route53 and try again."
            exit 1
        fi
        
        log "SUCCESS" "Found Route53 hosted zone for $domain (Zone ID: $zone_id)"
        
        # Add to zones JSON
        if [ "$first" = true ]; then
            first=false
        else
            zones_json+=","
        fi
        zones_json+="\"$domain\":\"$zone_id\""
    done
    zones_json+="}"
    
    # Store zones in status file
    local temp_file=$(mktemp)
    jq -r --argjson zones "$zones_json" '. + {"zones": $zones}' "$STATUS_FILE" > "$temp_file"
    mv "$temp_file" "$STATUS_FILE"
    
    mark_step_completed "hosted_zones"
    return 0
}

# Function to create S3 buckets for all source domains
create_s3_bucket() {
    if is_step_completed "s3_buckets"; then
        log "INFO" "S3 buckets already created"
        return 0
    fi
    
    log "STEP" "Creating S3 buckets for domain redirects"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    # Get domains array
    local domains_json=$(get_status_array "domains_array")
    local buckets_json="{}"
    
    # Create a bucket for each source domain
    for domain in $(echo "$domains_json" | jq -r '.[]'); do
        local bucket_name="${domain}-redirect"
        log "INFO" "Processing bucket for $domain"
        
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
                log "ERROR" "Failed to create S3 bucket $bucket_name"
                continue
            fi
        fi
        
        # Configure website redirect
        log "INFO" "Configuring website redirect for bucket $bucket_name to https://$TARGET_DOMAIN"
        
        # Create website configuration with redirect
        local website_config_file=$(mktemp)
        cat > "$website_config_file" <<EOF
{
    "RedirectAllRequestsTo": {
        "HostName": "$TARGET_DOMAIN",
        "Protocol": "https"
    }
}
EOF
        
        $aws_cmd s3api put-bucket-website \
            --bucket "$bucket_name" \
            --website-configuration "file://${website_config_file}"
        
        rm -f "$website_config_file"
        
        # Update buckets JSON
        buckets_json=$(echo "$buckets_json" | jq --arg domain "$domain" --arg bucket "$bucket_name" '. + {($domain): $bucket}')
    done
    
    # Save buckets to status file
    local temp_file=$(mktemp)
    jq -r --argjson buckets "$buckets_json" '. + {"buckets": $buckets}' "$STATUS_FILE" > "$temp_file"
    mv "$temp_file" "$STATUS_FILE"
    
    log "SUCCESS" "All S3 buckets created and configured for redirection"
    mark_step_completed "s3_buckets"
    return 0
}

# Function to create ACM certificate for all domains
create_certificate() {
    if is_step_completed "certificate"; then
        local cert_arn=$(get_status "certificate_arn" "")
        log "INFO" "Certificate already created (ARN: $cert_arn)"
        return 0
    fi
    
    log "STEP" "Creating ACM certificate for all domains"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    # Certificate must be in us-east-1 for CloudFront
    local cert_region="us-east-1"
    
    # Get domains array and add target domain
    local domains_json=$(get_status_array "domains_array")
    domains_json=$(echo "$domains_json" | jq ". + [\"$TARGET_DOMAIN\"]")
    
    # Request certificate
    local cert_arn=$(get_status "certificate_arn" "")
    if [ -z "$cert_arn" ]; then
        log "INFO" "Requesting new certificate for all domains"
        
        # Create domain strings for certificate request
        local primary_domain=$(echo "$domains_json" | jq -r '.[0]')
        local alt_domains=$(echo "$domains_json" | jq -r '.[1:] | join(",")')
        
        # Request certificate
        cert_arn=$($aws_cmd acm request-certificate \
            --domain-name "$primary_domain" \
            --subject-alternative-names $(echo "$alt_domains" | tr ',' ' ') \
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
    
    # Create DNS validation records for each domain
    log "INFO" "Creating DNS validation records in Route53"
    local zones_json=$(jq -r '.zones' "$STATUS_FILE")
    
    # Group validation records by hosted zone
    local validation_by_zone="{}"
    
    for record in $(echo "$validation_records" | jq -c '.[]'); do
        local record_name=$(echo "$record" | jq -r '.Name')
        local record_value=$(echo "$record" | jq -r '.Value')
        local record_type=$(echo "$record" | jq -r '.Type')
        
        # Find the correct zone for this record
        local zone_id=""
        local domain_name=""
        
        for domain in $(echo "$zones_json" | jq -r 'keys[]'); do
            # Check if this record belongs to this domain or a subdomain
            if [[ "$record_name" == *"$domain"* ]]; then
                zone_id=$(echo "$zones_json" | jq -r --arg domain "$domain" '.[$domain]')
                domain_name="$domain"
                break
            fi
        done
        
        if [ -z "$zone_id" ]; then
            log "WARN" "Could not find matching zone for validation record: $record_name"
            continue
        fi
        
        # Add to validation_by_zone
        if [ "$(echo "$validation_by_zone" | jq --arg zone "$zone_id" 'has($zone)')" = "true" ]; then
            # Add to existing zone
            validation_by_zone=$(echo "$validation_by_zone" | jq --arg zone "$zone_id" --arg name "$record_name" --arg value "$record_value" --arg type "$record_type" '.[$zone] += [{"Name": $name, "Value": $value, "Type": $type}]')
        else
            # Create new zone entry
            validation_by_zone=$(echo "$validation_by_zone" | jq --arg zone "$zone_id" --arg name "$record_name" --arg value "$record_value" --arg type "$record_type" '. + {($zone): [{"Name": $name, "Value": $value, "Type": $type}]}')
        fi
    done
    
    # Create validation records for each zone
    for zone_id in $(echo "$validation_by_zone" | jq -r 'keys[]'); do
        local records=$(echo "$validation_by_zone" | jq -r --arg zone "$zone_id" '.[$zone]')
        
        log "INFO" "Creating validation records in zone $zone_id"
        
        local change_batch=$(echo "$records" | jq -c '{
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
            log "ERROR" "Failed to create DNS validation records in zone $zone_id"
        fi
    done
    
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

# Function to create CloudFront Origin Access Control
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
    local oac_name="redirect-oac"
    local oac_config=$(cat <<EOF
{
    "Name": "$oac_name",
    "Description": "OAC for domain redirects",
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

# Function to create CloudFront distributions for all domains
create_cloudfront_distribution() {
    if is_step_completed "cloudfront"; then
        log "INFO" "CloudFront distributions already created"
        return 0
    fi
    
    log "STEP" "Creating CloudFront distributions for all domains"
    
    # Check if certificate is validated
    if ! is_step_completed "certificate"; then
        log "WARN" "Certificate is not yet validated. Please run the script again later."
        return 1
    fi
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    local cert_arn=$(get_status "certificate_arn" "")
    local oac_id=$(get_status "oac_id" "")
    local domains_json=$(get_status_array "domains_array")
    local buckets_json=$(jq -r '.buckets' "$STATUS_FILE")
    local distributions_json="{}"
    
    # Create a distribution for each domain
    for domain in $(echo "$domains_json" | jq -r '.[]'); do
        local bucket_name=$(echo "$buckets_json" | jq -r --arg domain "$domain" '.[$domain]')
        
        log "INFO" "Creating CloudFront distribution for $domain"
        
        # Prepare distribution config
        local dist_config_file=$(mktemp)
        cat > "$dist_config_file" <<EOF
{
    "CallerReference": "${domain}-$(date +%s)",
    "Aliases": {
        "Quantity": 1,
        "Items": ["${domain}"]
    },
    "DefaultRootObject": "",
    "Origins": {
        "Quantity": 1,
        "Items": [
            {
                "Id": "S3-${bucket_name}",
                "DomainName": "${bucket_name}.s3-website-${AWS_REGION}.amazonaws.com",
                "OriginPath": "",
                "CustomHeaders": {
                    "Quantity": 0
                },
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
        "TargetOriginId": "S3-${bucket_name}",
        "ViewerProtocolPolicy": "redirect-to-https",
        "AllowedMethods": {
            "Quantity": 2,
            "Items": ["GET", "HEAD"],
            "CachedMethods": {
                "Quantity": 2,
                "Items": ["GET", "HEAD"]
            }
        },
        "SmoothStreaming": false,
        "Compress": true,
        "LambdaFunctionAssociations": {
            "Quantity": 0
        },
        "FieldLevelEncryptionId": "",
        "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6"
    },
    "CacheBehaviors": {
        "Quantity": 0
    },
    "CustomErrorResponses": {
        "Quantity": 0
    },
    "Comment": "Distribution for ${domain} redirect",
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
    "HttpVersion": "http2",
    "IsIPV6Enabled": true
}
EOF
        
        # Create distribution
        log "INFO" "Creating CloudFront distribution for $domain (this may take a minute)..."
        local dist_result=$($aws_cmd cloudfront create-distribution \
            --distribution-config "file://${dist_config_file}" \
            --output json)
        
        rm -f "$dist_config_file"
        
        if [ $? -ne 0 ]; then
            log "ERROR" "Failed to create CloudFront distribution for $domain"
            continue
        fi
        
        local distribution_id=$(echo "$dist_result" | jq -r '.Distribution.Id')
        local distribution_domain=$(echo "$dist_result" | jq -r '.Distribution.DomainName')
        
        log "SUCCESS" "CloudFront distribution created for $domain"
        log "INFO" "Distribution ID: $distribution_id"
        log "INFO" "Distribution Domain: $distribution_domain"
        
        # Update distributions JSON
        distributions_json=$(echo "$distributions_json" | jq --arg domain "$domain" --arg id "$distribution_id" --arg dname "$distribution_domain" '. + {($domain): {"id": $id, "domain": $dname}}')
    done
    
    # Save distributions to status file
    local temp_file=$(mktemp)
    jq -r --argjson dists "$distributions_json" '. + {"distributions": $dists}' "$STATUS_FILE" > "$temp_file"
    mv "$temp_file" "$STATUS_FILE"
    
    mark_step_completed "cloudfront"
    return 0
}

# Function to create Route53 DNS records
create_dns_records() {
    if is_step_completed "dns"; then
        log "INFO" "DNS records already created"
        return 0
    fi
    
    log "STEP" "Creating Route53 DNS records"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    local domains_json=$(get_status_array "domains_array")
    local zones_json=$(jq -r '.zones' "$STATUS_FILE")
    local distributions_json=$(jq -r '.distributions' "$STATUS_FILE")
    
    for domain in $(echo "$domains_json" | jq -r '.[]'); do
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
                log "WARN" "Could not find Route53 zone for $domain, skipping DNS record creation"
                continue
            fi
        fi
        
        # Get CloudFront distribution domain
        local distribution_domain=$(echo "$distributions_json" | jq -r --arg domain "$domain" '.[$domain].domain // empty')
        if [ -z "$distribution_domain" ]; then
            log "WARN" "Could not find CloudFront distribution for $domain, skipping DNS record creation"
            continue
        fi
        
        log "INFO" "Creating DNS record for $domain in zone $zone_id"
        
        # Create A record alias
        local change_batch=$(cat <<EOF
{
    "Changes": [
        {
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "${domain}",
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
            log "ERROR" "Failed to create DNS record for $domain"
            continue
        fi
        
        log "SUCCESS" "DNS record created for $domain"
    done
    
    mark_step_completed "dns"
    return 0
}

# Function to wait for CloudFront distributions deployment
wait_for_distribution() {
    log "STEP" "Waiting for CloudFront distributions deployment"
    
    local aws_cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        aws_cmd="$aws_cmd --profile $AWS_PROFILE"
    fi
    
    local distributions_json=$(jq -r '.distributions' "$STATUS_FILE")
    
    # Wait for each distribution
    for domain in $(echo "$distributions_json" | jq -r 'keys[]'); do
        local distribution_id=$(echo "$distributions_json" | jq -r --arg domain "$domain" '.[$domain].id')
        
        log "INFO" "Waiting for distribution $distribution_id ($domain) deployment (this may take 5-10 minutes)..."
        if ! $aws_cmd cloudfront wait distribution-deployed \
            --id "$distribution_id"; then
            
            log "WARN" "Timed out waiting for distribution deployment for $domain"
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
                    log "SUCCESS" "Distribution for $domain is now deployed"
                    break
                fi
                
                log "INFO" "Current status: $status (waiting for 'Deployed')"
                sleep 30
            done
            
            if [ $attempts -ge $max_attempts ]; then
                log "WARN" "Distribution for $domain is still not fully deployed after additional checks"
                log "INFO" "The deployment will continue in the background"
            fi
        else
            log "SUCCESS" "Distribution for $domain is now deployed"
        fi
    done
    
    return 0
}

# Function to verify deployment
verify_deployment() {
    if is_step_completed "verification"; then
        log "INFO" "Deployment already verified"
        return 0
    fi
    
    log "STEP" "Verifying deployment"
    
    local domains_json=$(get_status_array "domains_array")
    local all_success=true
    
    # Check each domain
    for domain in $(echo "$domains_json" | jq -r '.[]'); do
        log "INFO" "Checking DNS resolution for $domain..."
        if ! host "$domain" &>/dev/null; then
            log "WARN" "DNS not yet propagated for $domain"
            all_success=false
        else
            log "SUCCESS" "DNS resolution successful for $domain"
            
            # Try to access the website and check for redirect
            log "INFO" "Checking redirect for $domain..."
            local redirect_url=$(curl -s -I -H "Host: $domain" "https://$domain" | grep -i "location:" | awk '{print $2}' | tr -d '\r')
            
            if [[ "$redirect_url" == *"$TARGET_DOMAIN"* ]]; then
                log "SUCCESS" "$domain successfully redirects to $TARGET_DOMAIN"
            else
                log "WARN" "$domain does not properly redirect to $TARGET_DOMAIN (got: $redirect_url)"
                all_success=false
            fi
        fi
    done
    
    if [ "$all_success" = true ]; then
        mark_step_completed "verification"
    else
        log "INFO" "Some domains are not fully deployed yet, DNS propagation may take more time"
    fi
    
    return 0
}

# Function to display deployment summary
display_summary() {
    log "STEP" "Deployment Summary"
    
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                  ${BOLD}DEPLOYMENT SUMMARY${NC}${CYAN}                     ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${BOLD}Source Domains:${NC}"
    local domains_json=$(get_status_array "domains_array")
    for domain in $(echo "$domains_json" | jq -r '.[]'); do
        echo -e "  - $domain"
    done
    echo
    echo -e "${BOLD}Target Domain:${NC} $TARGET_DOMAIN"
    echo -e "${BOLD}Status File:${NC} $STATUS_FILE"
    echo
    
    # Display distributions
    local distributions_json=$(jq -r '.distributions' "$STATUS_FILE")
    if [ "$(echo "$distributions_json" | jq 'length')" -gt 0 ]; then
        echo -e "${BOLD}CloudFront Distributions:${NC}"
        for domain in $(echo "$distributions_json" | jq -r 'keys[]'); do
            local dist_id=$(echo "$distributions_json" | jq -r --arg domain "$domain" '.[$domain].id')
            local dist_domain=$(echo "$distributions_json" | jq -r --arg domain "$domain" '.[$domain].domain')
            echo -e "  - $domain: $dist_id ($dist_domain)"
        done
        echo
    fi
    
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                      ${BOLD}NEXT STEPS${NC}${CYAN}                         ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "1. ${BOLD}Verify redirects:${NC}"
    echo -e "   Visit each source domain in your browser to confirm redirect to $TARGET_DOMAIN"
    echo
    echo -e "2. ${BOLD}DNS propagation:${NC}"
    echo -e "   DNS changes may take up to 48 hours to fully propagate"
    echo
    
    # Check if all steps are completed
    local all_completed=true
    for step in "hosted_zones" "s3_buckets" "certificate" "oac" "cloudfront" "dns"; do
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
            --source-domains)
                SOURCE_DOMAINS="$2"
                shift
                shift
                ;;
            --target-domain)
                TARGET_DOMAIN="$2"
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
    if [ -z "$SOURCE_DOMAINS" ]; then
        log "ERROR" "Source domains are required"
        usage
    fi
    
    if [ -z "$TARGET_DOMAIN" ]; then
        log "ERROR" "Target domain is required"
        usage
    fi
    
    # Welcome message
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║            ${BOLD}AWS MULTIPLE DOMAIN REDIRECT SCRIPT${NC}${CYAN}            ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${BOLD}Source Domains:${NC} $SOURCE_DOMAINS"
    echo -e "${BOLD}Target Domain:${NC} $TARGET_DOMAIN"
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
    
    # Parse domains
    parse_domains
    
    # Confirm deployment
    if ! confirm_action "Proceed with deployment?"; then
        log "INFO" "Deployment cancelled"
        exit 0
    fi
    
    # Execute deployment steps
    check_hosted_zones
    create_s3_bucket
    create_certificate
    create_oac
    create_cloudfront_distribution
    create_dns_records
    wait_for_distribution
    verify_deployment
    
    # Display summary
    display_summary
}

# Run the script
main "$@"