# WARNING

## Hold up!
**I do not recommend that you use this yet!**

## Why?

This needs a lot more testing on an empty account or super limited IAM credential set.
It will be done soon, haven't had the time to test it properly yet.

Getting closer

@todo standardize output style of help messages and instructions etc




# AWS Static Site Deployment Toolkit

This repository contains a set of scripts which are intended to help in deploying and 
managing static websites using AWS infrastructure. It automates the process of setting
up an S3-backed static site with CloudFront CDN, SSL enforced and supplied via an
auto-renewing cert via ACM, and DNS routing through Route53.

Should these scripts possibly generate Cloudformation, Terraform, or some another IAC type
configuration format, rather than using the AWS CLI / HTTP API manually?  Wouldn't that
provide better support going forward without being locked into a funky custom toolchain?  Well
what a good idea I certainly didn't think of that midway through working on this.  Maybe v2 😘


### Features

- **One-command deployment** of a complete static website infrastructure
    - After infrastructure provisioning, **One-command** site content deploy and sync
- **Auto-renewing SSL certificates** via AWS Certificate Manager
- **CloudFront distribution** with reasonable caching defaults
- **Private S3 bucket** with proper security configuration
   - **OAC** rules limit provide access to the CF instance
- **Automatic DNS configuration** via Route53
- **Status tracking** for error recovery and resource management
- **Complete cleanup tool** to remove all created resources
- **Limited humor** because honestly we are all on a deadline here people, a script toolkit doesn't need to be making fun of us the **entire** fucking time


## Prerequisites and Installation

- AWS CLI installed and configured with appropriate permissions
- `jq` command-line JSON processor
- An existing Route53 hosted zone for any of the domains you wish to use
- Bash shell environment
- Clone this repository, export your creds, run login.sh
    - Create shell aliases if you feel like it, but as I said earlier, i'm not your dad


## Usage

### AWS CLI config basics

- Run `src/login.sh` to sanity check your environment and credentials
- Confirm the AWS account ID and credentials are appropriate for the target domains


### Deployment

Deploy a static website with a single command:

```
src/deploy-site.sh --domain [yourdomain.com] [options]
Options:
  --domain DOMAIN              Domain name (required)
  --profile PROFILE            AWS CLI profile (optional)
  --region REGION              AWS region (default: us-east-1)
  --status-file FILE           Custom status file path
  --yes                        Skip all confirmation prompts
  --help                       Display this help message

```

### Redirect

Add non-authoritative domain redirects with the redirect companion script.

```
Usage: ./deploy-redirect.sh --source-domains [domains,list,as,csv] --target-domain [domain]
Options:
  --source-domains DOMAINS     Comma-separated list of source domains to redirect (required)
  --target-domain DOMAIN       The destination domain for redirects (required)
  --profile PROFILE            AWS CLI profile (optional)
  --region REGION              AWS region (default: us-east-1)
  --status-file FILE           Custom path for status tracking file
  --yes                        Skip all confirmation prompts
  --help                       Display this help message

```


### Cleanup

When you no longer need the static site, you can remove all resources with either the
`remove-site.sh` or `remove-redirect.sh` scripts.  These accept the json status files from
either process, so make sure you didn't lose those!  You lost them already?  Oh.


## Deployment Timeline

Some of the steps involved take a while to fully deploy, and the scripts will keep checking on them
until things settle, eg: ACM cert validation, CF distribution deployment, yadda yadda.


## Error Recovery

The toolkit maintains a detailed status file (`deployment_status.json`) that tracks the progress of each step.
If an error occurs during deployment, you can attempt to fix the issue and run the script again - it will 
automatically skip completed steps and continue from where it left off.


## Updating Your Website

### Using the Sync Script

The toolkit includes a dedicated sync script that makes updating your website content easy and efficient:

```
src/sync.sh --status-file [file] [options]

Options:
  --status-file FILE       Status file from deployment (default: deployment_status.json)
  --source DIRECTORY       Local directory to sync (default: current directory)
  --profile PROFILE        AWS CLI profile to use
  --region REGION          AWS region (default: us-east-1)
  --paths PATHS            CloudFront paths to invalidate (default: /*)
  --gzip                   Enable gzip compression for text-based files
  --exclude PATTERN        Exclude files matching pattern (S3 sync exclude pattern)
  --dry-run                Show what would be uploaded without making changes
  -y, --yes                Skip all confirmation prompts
  --help                   Display this help message

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


## License

This software is provided under the MIT license, which is provided below.  As i'm sure
many folks have had this same idea in parallel, I don't consider this effort groundbreaking
or magical, however if you find this useful I wouldn't mind a shout-out in your implementation.

---------------------------------------------------------------------------------------

Copyright 2025 sprky0

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

