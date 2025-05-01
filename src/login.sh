#!/bin/bash
# =============================================================================
# AWS CLI login helper script
#
# This script confirms that the AWS credentials are set in the environment 
# and that the AWS CLI is configured to use them.
# =============================================================================


# Check if required environment variables are set
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  echo "Error: AWS credentials not found in environment variables."
  echo "Please ensure AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are set."
  exit 1
fi

# Optional: Check for AWS_SESSION_TOKEN
if [ -n "$AWS_SESSION_TOKEN" ]; then
  echo "Session token found and will be used."
fi

# Optional: Check for AWS_REGION
if [ -z "$AWS_REGION" ]; then
  echo "Warning: AWS_REGION not set. Using default region if configured."
fi

# Verify credentials work by listing AWS account ID
echo "Attempting to authenticate with AWS using environment credentials..."
aws sts get-caller-identity

# Check if the command was successful
if [ $? -eq 0 ]; then
  echo "Authentication successful! You are logged in to AWS CLI."
else
  echo "Authentication failed. Please check your credentials."
  exit 1
fi