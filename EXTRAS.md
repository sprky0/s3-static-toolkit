# AWS Multi-Domain Redirect Script

## Overview

The AWS Multi-Domain Redirect Script automates the creation and management of domain redirects using AWS infrastructure. It's designed to complement the static site deployment toolkit by providing a solution for vanity URLs, www to non-www redirects, or any scenario where one or more domains need to redirect to a target domain.

## Key Features

- **Multiple Source Domains**: Redirects multiple source domains to a single target domain
- **Shared SSL Certificate**: Uses a single ACM certificate for all redirect domains
- **Permanent or Temporary Redirects**: Support for both 301 (permanent) and 302 (temporary) redirects
- **Path Preservation**: Maintains request paths during redirection
- **Secure by Default**: Enforces HTTPS for all requests
- **Status Tracking**: Maintains detailed status information for each domain
- **Error Recovery**: Automatically resumes incomplete deployments

## Usage

### Basic Redirect Setup

To create redirects from multiple domains to a single target domain:

```bash
./aws-redirect-deploy.sh --source-domains domain1.com,domain2.com,www.example.com \
                         --target-domain example.com \
                         [options]
```

Required parameters:
- `--source-domains <domains>`: Comma-separated list of source domain names
- `--target-domain <target>`: Target domain to redirect to

Optional parameters:
- `--redirect-type <type>`: Redirect type: 301 (permanent) or 302 (temporary) (default: 301)
- `--redirect-path <path>`: Path to redirect to on target domain (default: /)
- `--profile <profile>`: AWS CLI profile to use
- `--region <region>`: AWS region (default: us-east-1)
- `-y, --yes`: Skip all confirmation prompts
- `--status-file <file>`: File to track deployment status (default: redirect_status.json)

### Common Use Cases

#### Redirect www Subdomain to Root Domain

```bash
./aws-redirect-deploy.sh --source-domains www.example.com --target-domain example.com
```

#### Set Up Multiple Vanity URLs

```bash
./aws-redirect-deploy.sh --source-domains short.link,go.example.org,click.example.net \
                         --target-domain example.com
```

#### Redirect to a Specific Page

```bash
./aws-redirect-deploy.sh --source-domains promo.example.com \
                         --target-domain example.com \
                         --redirect-path /special-offer
```

#### Temporary Redirect (for Maintenance)

```bash
./aws-redirect-deploy.sh --source-domains app.example.com \
                         --target-domain maintenance.example.com \
                         --redirect-type 302
```

## Implementation Details

The redirect script uses the following AWS services:

1. **S3**: Creates buckets configured for website hosting with redirect rules
2. **ACM**: Creates a shared SSL certificate covering all source domains
3. **CloudFront**: Sets up distributions that serve the redirects with proper caching
4. **Route53**: Creates DNS records pointing to CloudFront distributions

## Deployment Timeline

A typical redirect deployment involves:

1. **ACM Certificate Creation and Validation**: ~5-10 minutes (DNS propagation dependent)
2. **S3 Bucket Setup** (per domain): ~1-2 minutes 
3. **CloudFront Distribution** (per domain): ~5-7 minutes
4. **Route53 DNS Configuration** (per domain): ~1-2 minutes

**Total deployment time**: Approximately 10-20 minutes, with the majority spent waiting for AWS service propagation.

## Important Considerations

- **DNS Requirements**: Each source domain must have a Route53 hosted zone
- **Shared Certificate**: All source domains share a single ACM certificate (100 domains maximum per certificate)
- **CloudFront Distribution**: Each source domain requires its own CloudFront distribution
- **S3 Bucket Names**: The script creates S3 buckets named after the source domains
- **Regional Constraints**: ACM certificates used with CloudFront must be in the `us-east-1` region

## Troubleshooting

### Common Issues

1. **Certificate Validation Failures**: Ensure all domains have proper Route53 hosted zones
2. **"Bucket Already Exists"**: S3 bucket names are globally unique
3. **Slow DNS Propagation**: DNS changes may take time to propagate globally

### Resuming Failed Deployments

If a deployment is interrupted, simply run the script again with the same parameters. The script tracks progress in the status file and will resume from where it left off.

## Integration with Static Site Toolkit

The redirect script complements the static site deployment script, allowing you to:

1. Deploy your main website using `deploy-static-site.sh`
2. Set up redirects from alternate domains using `aws-redirect-deploy.sh`

This combination provides a complete solution for managing both your primary website and any additional domains that should redirect to it.