#!/bin/bash
# =============================================================================
# AWS CLI login helper script
#
# This script confirms that the AWS credentials are set in the environment 
# and that the AWS CLI is configured to use them.
# =============================================================================


# Check if required environment variables are set

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
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

# Check if required environment variables are set
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  log "ERROR" "AWS credentials not found in environment variables."
  echo "Please ensure AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are set."
  exit 1
fi

# Optional: Check for AWS_SESSION_TOKEN
if [ -n "$AWS_SESSION_TOKEN" ]; then
  log "INFO" "Session token found and will be used."
fi

# Optional: Check for AWS_REGION
if [ -z "$AWS_REGION" ]; then
  log "WARN" "AWS_REGION not set. Using default region if configured."
fi

# Verify credentials work by listing AWS account ID
log "INFO" "Attempting to authenticate with AWS using environment credentials..."
aws sts get-caller-identity

# Check if the command was successful
if [ $? -eq 0 ]; then
  log "SUCCESS" "Authentication successful! You are logged in to AWS CLI."
else
  log "ERROR" "Authentication failed. Please check your credentials."
  exit 1
fi