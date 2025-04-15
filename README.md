# AWS Static Site Deployment Toolkit

This repository contains an a "Static Site Deployment Toolkit," intended to help in deploying and managing static websites using
AWS infrastructure. It automates the process of setting up an S3-backed static site with CloudFront CDN, SSL via ACM, and DNS
routing through Route53.


### Features

- **One-command deployment** of a complete static website infrastructure
- **Auto-renewing SSL certificates** via AWS Certificate Manager
- **CloudFront distribution** with reasonable caching defaults
- **Private S3 bucket** with proper security configuration
- **Automatic DNS configuration** via Route53
- **Status tracking** for error recovery and resource management
- **Complete cleanup tool** to remove all created resources


## Prerequisites

- AWS CLI installed and configured with appropriate permissions
- `jq` command-line JSON processor
- An existing Route53 hosted zone for your domain
- Bash shell environment


## Installation

Clone this repository to get started:

```bash
git clone https://github.com/yourusername/aws-static-site-toolkit.git
cd aws-static-site-toolkit
chmod +x deploy-static-site.sh remove-static-site.sh
```

Ensure that both jq and awscli tools are installed on your local environment.


## Usage

### Deployment

Deploy a static website with a single command:

```bash
./deploy-static-site.sh --domain yourdomain.com [--profile aws-profile] [--region us-east-1] [--yes]
```

Required parameters:
- `--domain <domain>`: The domain name for your static site (must have an existing Route53 hosted zone)

Optional parameters:
- `--profile <profile>`: AWS CLI profile to use
- `--region <region>`: AWS region (default: us-east-1)
- `-y, --yes`: Skip all confirmation prompts
- `--status-file <file>`: Specify a custom status file location (default: deployment_status.json)

### Cleanup

When you no longer need the static site, you can remove all resources:

```bash
./remove-static-site.sh [--status-file deployment_status.json] [--profile aws-profile] [--region us-east-1] [--yes]
```

Optional parameters:
- `--status-file <file>`: Status file from deployment (default: deployment_status.json)
- `--profile <profile>`: AWS CLI profile to use
- `--region <region>`: AWS region (default: us-east-1)
- `-y, --yes`: Skip all confirmation prompts

## Scripts Overview

The toolkit includes three main scripts:

1. **`deploy-static-site.sh`**: Creates all necessary AWS resources for your static website
2. **`sync-static-site.sh`**: Updates your website content and invalidates CloudFront cache
3. **`remove-static-site.sh`**: Cleans up all AWS resources when you no longer need the site

Together, these scripts provide a complete lifecycle management solution for your AWS-hosted static websites.

## Deployment Timeline

The deployment process involves several steps, each taking different amounts of time:

1. **S3 Bucket Creation**: ~1-2 minutes
2. **ACM Certificate Validation**: ~5-10 minutes (DNS propagation dependent)
3. **Origin Access Control Setup**: ~1 minute
4. **CloudFront Distribution**: ~5-7 minutes
5. **Route53 DNS Configuration**: ~1-2 minutes

**Total deployment time**: Approximately 15-20 minutes, with the majority spent waiting for AWS service propagation.

## Error Recovery

The toolkit maintains a detailed status file (`deployment_status.json`) that tracks the progress of each step. If an error occurs during deployment, you can fix the issue and run the script again - it will automatically skip completed steps and continue from where it left off.

## Updating Your Website

### Using the Sync Script

The toolkit includes a dedicated sync script that makes updating your website content easy and efficient:

```bash
./sync-static-site.sh --source ./website [options]
```

Key features of the sync script:

- **Smart Synchronization**: Only uploads changed files
- **Content Optimization**: Optional gzip compression for text-based files
- **Cache Management**: Automatic CloudFront invalidation
- **Intelligent Defaults**: Reads your deployment status file for configuration

Options:
- `--source <directory>`: Local directory to sync (default: current directory)
- `--paths <paths>`: CloudFront paths to invalidate (default: /*)
- `--gzip`: Enable gzip compression for text-based files (HTML, CSS, JS, etc.)
- `--exclude <pattern>`: Exclude files matching pattern (e.g., "*.tmp" or "node_modules/*")
- `--dry-run`: Preview changes without applying them
- `--profile <profile>`: AWS CLI profile to use
- `--region <region>`: AWS region (default: us-east-1)
- `-y, --yes`: Skip all confirmation prompts

Examples:

```bash
# Basic sync from current directory
./sync-static-site.sh

# Sync from specific directory with compression
./sync-static-site.sh --source ./dist --gzip

# Sync with exclusions and specific invalidation path
./sync-static-site.sh --source ./public --exclude "*.map" --paths "/images/*"

# Preview changes without applying them
./sync-static-site.sh --source ./website --dry-run
```

### Manual Updates

If you prefer to use the AWS CLI directly, you can update your website as follows:

```bash
aws s3 cp your-files/ s3://yourdomain.com-static-site/ --recursive
aws cloudfront create-invalidation --distribution-id YOUR_DISTRIBUTION_ID --paths "/*"
```

The distribution ID is provided in the deployment summary and also stored in the status file.

## Considerations and Limitations

- **CloudFront Distribution Removal**: When removing resources, CloudFront distributions need to be disabled first and can take 5-10 minutes to complete.
- **ACM Certificate Region**: Certificates for CloudFront must be in the `us-east-1` region regardless of your website's region.
- **DNS Propagation**: After deployment, it may take some time (minutes to hours) for DNS changes to propagate globally.
- **Costs**: While this toolkit creates resources within the AWS Free Tier limits for many users, standard AWS charges apply for the created services.
- **Custom Error Pages**: The default setup includes a basic error page. For custom error handling, upload additional error documents to S3 and update the CloudFront configuration.

## Troubleshooting

### Common Issues

1. **Certificate Validation Timeout**: ACM certificate validation via DNS can sometimes take longer than expected. The script will save the certificate ARN in the status file, and you can run the script again later to continue.

2. **"Bucket already exists"**: S3 bucket names are globally unique. If you see this error, it means someone else has already claimed that bucket name.

3. **CloudFront Distribution Taking Too Long**: CloudFront distributions can occasionally take longer than expected to deploy. The script provides an option to continue waiting.

4. **DNS Resolution Issues**: After deployment, it may take some time for DNS changes to propagate. Use tools like `dig` or `nslookup` to verify the DNS records.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Notices

- AWS Documentation for reference on service configurations
- The `jq` project for making JSON handling in bash scripts possible

