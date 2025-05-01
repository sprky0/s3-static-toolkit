#!/bin/bash
# =============================================================================
# AWS Static Site Sync Script
#
# This script synchronizes a local directory with the S3 bucket and 
# invalidates the CloudFront cache
# =============================================================================

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to log messages with timestamp
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


# Default values
AUTO_CONFIRM=false
STATUS_FILE="deployment_status.json"
LOCAL_DIR="."
INVALIDATE_PATHS="/*"
USE_GZIP=false
EXCLUDE_PATTERN=""
DRY_RUN=false

# Function to display usage information
usage() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Options:"
  echo "  --status-file <file>     Status file from deployment (default: deployment_status.json)"
  echo "  --source <directory>     Local directory to sync (default: current directory)"
  echo "  --profile <profile>      AWS CLI profile to use"
  echo "  --region <region>        AWS region (default: us-east-1)"
  echo "  --paths <paths>          CloudFront paths to invalidate (default: /*)"
  echo "  --gzip                   Enable gzip compression for text-based files"
  echo "  --exclude <pattern>      Exclude files matching pattern (S3 sync exclude pattern)"
  echo "  --dry-run                Show what would be uploaded without making changes"
  echo "  -y, --yes                Skip all confirmation prompts"
  echo "  --help                   Display this help message"
  exit 1
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

# Function to get metadata from the status file
get_metadata() {
  local step=$1
  local key=$2
  
  if [ ! -f "$STATUS_FILE" ]; then
    log "ERROR" "Status file not found: $STATUS_FILE"
    return 1
  fi
  
  local value=$(jq -r --arg step "$step" --arg key "$key" '.steps[$step].metadata[$key] // empty' "$STATUS_FILE")
  
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    return 1
  fi
  
  echo "$value"
}

# Function to determine content type based on file extension
get_content_type() {
  local file=$1
  local extension="${file##*.}"
  
  case $extension in
    html)
      echo "text/html"
      ;;
    css)
      echo "text/css"
      ;;
    js)
      echo "application/javascript"
      ;;
    json)
      echo "application/json"
      ;;
    xml)
      echo "application/xml"
      ;;
    svg)
      echo "image/svg+xml"
      ;;
    jpg|jpeg)
      echo "image/jpeg"
      ;;
    png)
      echo "image/png"
      ;;
    gif)
      echo "image/gif"
      ;;
    webp)
      echo "image/webp"
      ;;
    pdf)
      echo "application/pdf"
      ;;
    zip)
      echo "application/zip"
      ;;
    ttf)
      echo "font/ttf"
      ;;
    woff)
      echo "font/woff"
      ;;
    woff2)
      echo "font/woff2"
      ;;
    eot)
      echo "application/vnd.ms-fontobject"
      ;;
    ico)
      echo "image/x-icon"
      ;;
    txt)
      echo "text/plain"
      ;;
    md)
      echo "text/markdown"
      ;;
    *)
      echo "application/octet-stream"
      ;;
  esac
}

# Function to determine if a file should be gzipped
should_gzip() {
  local file=$1
  local extension="${file##*.}"
  
  case $extension in
    html|css|js|json|xml|svg|txt|md)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Function to create a temporary directory for gzipped files
create_temp_dir() {
  mktemp -d
}

# Function to sync files to S3 bucket
sync_to_s3() {
  local bucket_name=$1
  local local_dir=$2
  
  if [ ! -d "$local_dir" ]; then
    log "ERROR" "Local directory not found: $local_dir"
    return 1
  fi
  
  log "INFO" "Syncing files from $local_dir to S3 bucket $bucket_name..."
  
  if confirm "Sync files to S3 bucket '$bucket_name'?"; then
    # Prepare S3 sync command
    local cmd="aws s3 sync \"$local_dir\" s3://$bucket_name/ --delete $AWS_PROFILE_ARG $AWS_REGION_ARG"
    
    # Add exclude pattern if specified
    if [ -n "$EXCLUDE_PATTERN" ]; then
      cmd="$cmd --exclude \"$EXCLUDE_PATTERN\""
    fi
    
    # Add dry-run flag if specified
    if [ "$DRY_RUN" = true ]; then
      cmd="$cmd --dryrun"
    fi
    
    if [ "$USE_GZIP" = true ]; then
      log "INFO" "Gzip compression enabled for text-based files"
      
      # Create temporary directory for gzipped files
      local temp_dir=$(create_temp_dir)
      log "INFO" "Created temporary directory: $temp_dir"
      
      # Copy all files to temporary directory
      cp -r "$local_dir"/* "$temp_dir"/ 2>/dev/null || true
      
      # Process each file in the temporary directory
      find "$temp_dir" -type f | while read -r file; do
        if should_gzip "$file"; then
          # Get content type
          local content_type=$(get_content_type "$file")
          
          # Compress the file
          gzip -9 -c "$file" > "$file.gz"
          
          # Replace original with gzipped version
          mv "$file.gz" "$file"
          
          # Update file metadata for S3 upload
          aws s3 cp "$file" "s3://$bucket_name/${file#$temp_dir/}" \
            --content-type "$content_type" \
            --content-encoding "gzip" \
            --metadata-directive "REPLACE" \
            $AWS_PROFILE_ARG $AWS_REGION_ARG $([ "$DRY_RUN" = true ] && echo "--dryrun")
        else
          # Skip gzipping for non-text files
          log "INFO" "Skipping gzip for $(basename "$file")"
        fi
      done
      
      # Clean up temporary directory
      rm -rf "$temp_dir"
      log "INFO" "Removed temporary directory"
    else
      # Execute S3 sync command
      eval "$cmd"
    fi
    
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to sync files to S3 bucket"
      return 1
    fi
    
    log "SUCCESS" "Files synced to S3 bucket"
    return 0
  else
    log "WARN" "S3 sync cancelled by user"
    return 1
  fi
}

# Function to invalidate CloudFront cache
invalidate_cloudfront() {
  local distribution_id=$1
  local paths=$2
  
  log "INFO" "Invalidating CloudFront cache for distribution $distribution_id..."
  
  if confirm "Invalidate CloudFront cache for paths '$paths'?"; then
    local invalidation_batch="{
      \"Paths\": {
        \"Quantity\": 1,
        \"Items\": [\"$paths\"]
      },
      \"CallerReference\": \"$(date +%s)\"
    }"
    
    local cmd="aws cloudfront create-invalidation --distribution-id \"$distribution_id\" --invalidation-batch '$invalidation_batch' $AWS_PROFILE_ARG $AWS_REGION_ARG"
    
    if [ "$DRY_RUN" = true ]; then
      log "INFO" "DRY RUN: Would execute: $cmd"
      log "SUCCESS" "CloudFront invalidation simulated (dry run)"
      return 0
    fi
    
    local result=$(eval "$cmd")
    
    if [ $? -ne 0 ]; then
      log "ERROR" "Failed to invalidate CloudFront cache"
      return 1
    fi
    
    local invalidation_id=$(echo "$result" | jq -r '.Invalidation.Id')
    log "SUCCESS" "CloudFront invalidation created: $invalidation_id"
    return 0
  else
    log "WARN" "CloudFront invalidation cancelled by user"
    return 1
  fi
}

# Main execution
main() {
  # Parse command line arguments
  while [[ $# -gt 0 ]]; do
    key="$1"
    
    case $key in
      --status-file)
        STATUS_FILE="$2"
        shift
        shift
        ;;
      --source)
        LOCAL_DIR="$2"
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
      --paths)
        INVALIDATE_PATHS="$2"
        shift
        shift
        ;;
      --gzip)
        USE_GZIP=true
        shift
        ;;
      --exclude)
        EXCLUDE_PATTERN="$2"
        shift
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -y|--yes)
        AUTO_CONFIRM=true
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
  
  # Check if status file exists
  if [ ! -f "$STATUS_FILE" ]; then
    log "ERROR" "Status file not found: $STATUS_FILE"
    exit 1
  fi
  
  # Check for required commands
  for cmd in aws jq; do
    if ! command -v $cmd &> /dev/null; then
      log "ERROR" "Required command not found: $cmd"
      exit 1
    fi
  done
  
  # Check for gzip if compression is enabled
  if [ "$USE_GZIP" = true ] && ! command -v gzip &> /dev/null; then
    log "ERROR" "Gzip compression requested but gzip command not found"
    exit 1
  fi
  
  # Get S3 bucket name from status file
  BUCKET_NAME=$(get_metadata "create_s3_bucket" "bucket_name")
  if [ -z "$BUCKET_NAME" ]; then
    log "ERROR" "Failed to retrieve S3 bucket name from status file"
    exit 1
  fi
  
  # Get CloudFront distribution ID from status file
  CF_DISTRIBUTION_ID=$(get_metadata "create_cloudfront_distribution" "distribution_id")
  if [ -z "$CF_DISTRIBUTION_ID" ]; then
    log "ERROR" "Failed to retrieve CloudFront distribution ID from status file"
    exit 1
  fi
  
  # Extract domain from status file if available
  DOMAIN=$(jq -r '.domain // empty' "$STATUS_FILE")
  if [ -z "$DOMAIN" ]; then
    # Try to extract domain from bucket name
    DOMAIN=${BUCKET_NAME%-static-site}
  fi
  
  # Display operation summary
  echo
  echo -e "${GREEN}===== SYNC OPERATION =====${NC}"
  echo "Domain: $DOMAIN"
  echo "S3 Bucket: $BUCKET_NAME"
  echo "CloudFront Distribution: $CF_DISTRIBUTION_ID"
  echo "Local Directory: $LOCAL_DIR"
  echo "Invalidation Paths: $INVALIDATE_PATHS"
  if [ "$USE_GZIP" = true ]; then
    echo "Gzip Compression: Enabled"
  fi
  if [ -n "$EXCLUDE_PATTERN" ]; then
    echo "Exclude Pattern: $EXCLUDE_PATTERN"
  fi
  if [ "$DRY_RUN" = true ]; then
    echo "Mode: DRY RUN (no changes will be made)"
  fi
  echo
  
  # Sync files to S3 bucket
  if sync_to_s3 "$BUCKET_NAME" "$LOCAL_DIR"; then
    # Invalidate CloudFront cache
    invalidate_cloudfront "$CF_DISTRIBUTION_ID" "$INVALIDATE_PATHS"
  fi
  
  if [ "$DRY_RUN" = true ]; then
    log "INFO" "Dry run completed. No changes were made."
  else
    log "SUCCESS" "Sync operation completed!"
    echo
    echo -e "${GREEN}Website URL: https://${DOMAIN}${NC}"
    echo
  fi
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
