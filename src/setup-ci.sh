#!/bin/bash
# =============================================================================
# GitHub Actions CI Setup Script
#
# Wires an already-deployed site (or several, one per environment) to a
# push-to-deploy GitHub Actions pipeline in an external site repository:
#
#   - one IAM role per environment, trusted via GitHub OIDC and scoped to
#     that environment's bucket + distribution only (no long-lived keys)
#   - one GitHub Environment per environment, holding the AWS vars and a
#     deployment-branch restriction (branch name == environment name)
#   - a single generated .github/workflows/deploy.yml in the site repo
#
# Environments come from repeated --env NAME=DOMAIN flags. Each DOMAIN must
# already be deployed by deploy-site.sh (its status file supplies the bucket
# and distribution ID). The deployment branch for each environment is the
# environment name itself: pushing to branch "production" deploys the
# "production" environment. Enforcement lives in the GitHub environment's
# deployment-branch policy, not in the workflow file.
#
# The generated workflow's sha256 is recorded in the CI status file; re-runs
# and --check compare it against the file in the site repo to detect edits
# made outside this toolkit.
# =============================================================================

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Default values
REPO_PATH=""
REPO_SLUG=""
ENV_SPECS=()
DOCROOT="."
AWS_REGION="us-east-1"
AWS_PROFILE=""
STATUS_FILE=""
NO_APPROVAL=false
CHECK_ONLY=false
AUTO_APPROVE=false

# Populated during execution
ACCOUNT_ID=""
ENV_NAMES=()
ENV_DOMAINS=()
OIDC_PROVIDER_ARN=""
WORKFLOW_REL_PATH=".github/workflows/deploy.yml"

usage() {
    local exit_code="${1:-1}"
    echo "Usage: $0 --repo-path <path> --env <name>=<domain> [--env ...] [options]"
    echo ""
    echo "Options:"
    echo "  --repo-path PATH         Local clone of the site repository (prompted if omitted)"
    echo "  --repo ORG/REPO          GitHub repo slug (default: derived from the clone's origin remote)"
    echo "  --env NAME=DOMAIN        Environment mapping, repeatable (prompted if omitted)."
    echo "                           NAME is both the GitHub environment and its deploy branch;"
    echo "                           DOMAIN must have a deploy-site.sh status file in config/"
    echo "  --docroot PATH           Directory inside the site repo to sync (default: .)"
    echo "  --region REGION          AWS region variable for the workflow (default: us-east-1)"
    echo "  --profile PROFILE        AWS CLI profile (optional)"
    echo "  --status-file FILE       Custom CI status file path"
    echo "                           (default: config/.ci-status-<org>-<repo>.json)"
    echo "  --no-approval            Skip adding a required reviewer on the 'production' environment"
    echo "  --check                  Only verify the generated workflow in the site repo still"
    echo "                           matches the recorded sha256, then exit (0 ok, 1 modified/missing)"
    echo "  --yes                    Skip all confirmation prompts"
    echo "  --help                   Display this help message"
    echo ""
    echo "Example:"
    echo "  $0 --repo-path ~/gits/my-site \\"
    echo "     --env integration=integration.example.com \\"
    echo "     --env stage=stage.example.com \\"
    echo "     --env production=example.com"
    exit "$exit_code"
}

# =============================================================================
# Status file helpers (same contract as deploy-site.sh)
# =============================================================================

init_status_file() {
    if [ -z "$STATUS_FILE" ]; then
        STATUS_FILE="$(default_ci_status_file "$REPO_SLUG")" || exit 1
    fi

    if [ -f "$STATUS_FILE" ]; then
        log "INFO" "Using existing status file: $STATUS_FILE"
    else
        log "INFO" "Creating new status file: $STATUS_FILE"
        echo "{\"repo_slug\": \"$REPO_SLUG\", \"created_at\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}" > "$STATUS_FILE"
    fi
}

update_status() {
    local key=$1
    local value=$2

    if [ -f "$STATUS_FILE" ]; then
        local temp_file=$(mktemp)
        jq -r --arg key "$key" --arg value "$value" '. + {($key): $value}' "$STATUS_FILE" > "$temp_file"
        mv "$temp_file" "$STATUS_FILE"
    fi
}

get_status() {
    local key=$1
    local default=$2

    if [ -f "$STATUS_FILE" ]; then
        local value=$(jq -r --arg key "$key" '.[$key] // ""' "$STATUS_FILE")
        if [ -n "$value" ]; then
            echo "$value"
            return
        fi
    fi
    echo "$default"
}

is_step_completed() {
    local step=$1
    [ "$(get_status "${step}_completed" "false")" = "true" ]
}

mark_step_completed() {
    local step=$1
    update_status "${step}_completed" "true"
    update_status "${step}_completed_at" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}

confirm_action() {
    confirm "$1" "Y" "$AUTO_APPROVE"
}

aws_cli() {
    local cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        cmd="$cmd --profile $AWS_PROFILE"
    fi
    echo "$cmd"
}

file_sha256() {
    if command -v shasum &>/dev/null; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

# =============================================================================
# Prerequisites and input collection
# =============================================================================

check_prerequisites() {
    log "STEP" "Checking prerequisites"

    for tool in aws jq gh git; do
        if ! command -v "$tool" &>/dev/null; then
            log "ERROR" "Required tool not found: $tool"
            exit 1
        fi
    done

    if ! gh auth status &>/dev/null; then
        log "ERROR" "gh is not authenticated. Run: gh auth login"
        exit 1
    fi

    log "SUCCESS" "All prerequisites available"
}

prompt_for_missing_inputs() {
    if [ -z "$REPO_PATH" ]; then
        if [ "$AUTO_APPROVE" = true ]; then
            log "ERROR" "--repo-path is required with --yes"
            usage
        fi
        echo -en "${YELLOW}Path to the site repository clone: ${NC}"
        read -r REPO_PATH
    fi
    # Expand ~ if the shell didn't
    REPO_PATH="${REPO_PATH/#\~/$HOME}"

    if [ ${#ENV_SPECS[@]} -eq 0 ]; then
        if [ "$AUTO_APPROVE" = true ]; then
            log "ERROR" "At least one --env NAME=DOMAIN is required with --yes"
            usage
        fi
        echo -e "${CYAN}Define environments. The name is both the GitHub environment and its${NC}"
        echo -e "${CYAN}deploy branch (e.g. integration, stage, production). Blank name to finish.${NC}"
        while true; do
            if [ ${#ENV_SPECS[@]} -eq 0 ]; then
                echo -en "${YELLOW}Environment name: ${NC}"
            else
                echo -en "${YELLOW}Environment name (blank to finish): ${NC}"
            fi
            read -r env_name
            [ -z "$env_name" ] && break
            echo -en "${YELLOW}Deployed domain for '$env_name': ${NC}"
            read -r env_domain
            if [ -z "$env_domain" ]; then
                log "WARN" "No domain given, skipping $env_name"
                continue
            fi
            ENV_SPECS+=("${env_name}=${env_domain}")
        done
    fi

    if [ ${#ENV_SPECS[@]} -eq 0 ]; then
        log "ERROR" "No environments defined"
        usage
    fi
}

parse_env_specs() {
    local spec name domain
    for spec in "${ENV_SPECS[@]}"; do
        name="${spec%%=*}"
        domain="${spec#*=}"

        if [ -z "$name" ] || [ -z "$domain" ] || [ "$name" = "$spec" ]; then
            log "ERROR" "Invalid --env spec '$spec' (expected NAME=DOMAIN)"
            exit 1
        fi
        if ! [[ "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
            log "ERROR" "Environment name '$name' must be lowercase alphanumeric with - or _"
            exit 1
        fi
        if ! [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            log "ERROR" "'$domain' does not look like a domain name"
            exit 1
        fi
        local existing
        for existing in "${ENV_NAMES[@]}"; do
            if [ "$existing" = "$name" ]; then
                log "ERROR" "Environment '$name' defined twice"
                exit 1
            fi
        done

        ENV_NAMES+=("$name")
        ENV_DOMAINS+=("$domain")
    done
}

# Derive the org/repo slug from the clone's origin remote (unless --repo was
# given), then canonicalize it against the GitHub API. Canonical casing
# matters: the OIDC sub claim comparison in the trust policy is exact-match.
resolve_repo() {
    log "STEP" "Resolving site repository"

    if [ ! -d "$REPO_PATH" ]; then
        log "ERROR" "Repo path does not exist: $REPO_PATH"
        exit 1
    fi
    if ! git -C "$REPO_PATH" rev-parse --is-inside-work-tree &>/dev/null; then
        log "ERROR" "$REPO_PATH is not a git repository"
        exit 1
    fi
    REPO_PATH="$(cd "$REPO_PATH" && pwd)"

    if [ -z "$REPO_SLUG" ]; then
        local origin_url
        origin_url=$(git -C "$REPO_PATH" remote get-url origin 2>/dev/null)
        if [ -z "$origin_url" ]; then
            log "ERROR" "No 'origin' remote in $REPO_PATH; pass --repo ORG/REPO explicitly"
            exit 1
        fi
        REPO_SLUG=$(echo "$origin_url" | sed -E 's#^(git@|https://|ssh://git@)github\.com[:/]##; s#\.git$##; s#/$##')
    fi

    if ! [[ "$REPO_SLUG" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
        log "ERROR" "Could not derive an org/repo slug (got '$REPO_SLUG'); pass --repo ORG/REPO"
        exit 1
    fi

    # Canonicalize against the API (also proves the token can see the repo)
    local canonical
    canonical=$(gh api "repos/$REPO_SLUG" --jq '.full_name' 2>/dev/null)
    if [ -z "$canonical" ]; then
        log "ERROR" "GitHub repo not found or not accessible: $REPO_SLUG"
        exit 1
    fi
    REPO_SLUG="$canonical"

    log "SUCCESS" "Site repo: $REPO_SLUG ($REPO_PATH)"

    if ! confirm_action "Wire CI for $REPO_SLUG?"; then
        log "INFO" "Cancelled"
        exit 0
    fi
}

check_aws_config() {
    log "STEP" "Checking AWS configuration"

    local aws_cmd=$(aws_cli)
    local caller_account
    if ! caller_account=$($aws_cmd sts get-caller-identity --query Account --output text 2>/dev/null); then
        log "ERROR" "Cannot determine current AWS account. Check credentials/profile."
        exit 1
    fi

    local status_account=$(get_status "account_id" "")
    if [ -n "$status_account" ] && [ "$status_account" != "$caller_account" ]; then
        log "ERROR" "Status file was created under account $status_account but current caller is $caller_account."
        log "ERROR" "Refusing to mix accounts. Switch profile and retry."
        exit 1
    fi

    ACCOUNT_ID="$caller_account"
    update_status "account_id" "$ACCOUNT_ID"
    log "SUCCESS" "Using AWS account $ACCOUNT_ID"
}

# =============================================================================
# Per-environment site lookups
# =============================================================================

# Pull bucket + distribution from each environment's deploy-site.sh status
# file into the CI status file. Fails fast if a site hasn't been deployed.
load_site_configs() {
    log "STEP" "Loading site deployments for each environment"

    local i name domain site_file bucket dist_id site_account
    for i in "${!ENV_NAMES[@]}"; do
        name="${ENV_NAMES[$i]}"
        domain="${ENV_DOMAINS[$i]}"

        site_file="$(default_site_status_file "$domain")" || exit 1
        if [ ! -f "$site_file" ]; then
            log "ERROR" "No deployment status file for $domain (expected $site_file)"
            log "ERROR" "Deploy the site first: src/deploy-site.sh --domain $domain"
            exit 1
        fi

        bucket=$(jq -r '.bucket_name // ""' "$site_file")
        dist_id=$(jq -r '.distribution_id // ""' "$site_file")
        site_account=$(jq -r '.account_id // ""' "$site_file")

        if [ -z "$bucket" ] || [ -z "$dist_id" ]; then
            log "ERROR" "Status file for $domain is missing bucket_name or distribution_id"
            log "ERROR" "Finish the deployment first: src/deploy-site.sh --domain $domain"
            exit 1
        fi
        if [ -n "$site_account" ] && [ "$site_account" != "$ACCOUNT_ID" ]; then
            log "ERROR" "$domain was deployed under account $site_account, but current caller is $ACCOUNT_ID"
            exit 1
        fi

        update_status "env_${name}_domain" "$domain"
        update_status "env_${name}_bucket" "$bucket"
        update_status "env_${name}_distribution_id" "$dist_id"
        log "INFO" "$name -> $domain (bucket: $bucket, distribution: $dist_id)"
    done

    update_status "environments" "$(IFS=,; echo "${ENV_NAMES[*]}")"
    log "SUCCESS" "All environment domains have completed deployments"
}

# =============================================================================
# AWS: OIDC provider + per-environment deploy roles
# =============================================================================

ensure_oidc_provider() {
    log "STEP" "Ensuring GitHub OIDC provider exists"

    local aws_cmd=$(aws_cli)
    local provider_arn="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

    if $aws_cmd iam get-open-id-connect-provider --open-id-connect-provider-arn "$provider_arn" &>/dev/null; then
        log "INFO" "OIDC provider already exists (shared across environments)"
    else
        log "INFO" "Creating OIDC provider for token.actions.githubusercontent.com"
        # Thumbprints are vestigial for GitHub (AWS trusts the cert chain since
        # 2023) but the API still requires the parameter.
        if ! $aws_cmd iam create-open-id-connect-provider \
            --url "https://token.actions.githubusercontent.com" \
            --client-id-list "sts.amazonaws.com" \
            --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" "1c58a3a8518e8759bf075b76b750d4f2df264fcd" \
            --tags "Key=ManagedBy,Value=s3-static-toolkit" \
            >/dev/null; then
            log "ERROR" "Failed to create OIDC provider"
            exit 1
        fi
        log "SUCCESS" "OIDC provider created"
    fi

    OIDC_PROVIDER_ARN="$provider_arn"
    update_status "oidc_provider_arn" "$provider_arn"
}

create_deploy_roles() {
    log "STEP" "Creating environment-scoped deploy roles"

    local aws_cmd=$(aws_cli)
    local i name domain bucket dist_id role_name policy_name role_arn
    for i in "${!ENV_NAMES[@]}"; do
        name="${ENV_NAMES[$i]}"
        domain="${ENV_DOMAINS[$i]}"
        bucket=$(get_status "env_${name}_bucket" "")
        dist_id=$(get_status "env_${name}_distribution_id" "")
        role_name="gha-deploy-${domain//./-}"
        policy_name="${role_name}-policy"
        role_arn="arn:aws:iam::${ACCOUNT_ID}:role/${role_name}"

        if is_step_completed "role_${name}"; then
            log "INFO" "[$name] role already provisioned: $role_name"
            continue
        fi

        # Trust only tokens minted for this repo AND this environment. A
        # workflow run can only get such a token if GitHub's deployment-branch
        # policy let it select the environment in the first place.
        local trust_file=$(mktemp)
        cat > "$trust_file" <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "${OIDC_PROVIDER_ARN}"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
                    "token.actions.githubusercontent.com:sub": "repo:${REPO_SLUG}:environment:${name}"
                }
            }
        }
    ]
}
EOF

        if $aws_cmd iam get-role --role-name "$role_name" &>/dev/null; then
            log "INFO" "[$name] role $role_name already exists, converging trust policy"
            if ! $aws_cmd iam update-assume-role-policy \
                --role-name "$role_name" \
                --policy-document "file://${trust_file}"; then
                rm -f "$trust_file"
                log "ERROR" "[$name] failed to update trust policy on $role_name"
                exit 1
            fi
        else
            log "INFO" "[$name] creating role $role_name"
            if ! $aws_cmd iam create-role \
                --role-name "$role_name" \
                --assume-role-policy-document "file://${trust_file}" \
                --description "GitHub Actions deploy role for ${domain} (${REPO_SLUG}:${name})" \
                --tags "Key=ManagedBy,Value=s3-static-toolkit" "Key=Domain,Value=${domain}" \
                >/dev/null; then
                rm -f "$trust_file"
                log "ERROR" "[$name] failed to create role $role_name"
                exit 1
            fi
        fi
        rm -f "$trust_file"

        # Permissions: exactly what a sync + invalidation needs, nothing else.
        local policy_file=$(mktemp)
        cat > "$policy_file" <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ListBucket",
            "Effect": "Allow",
            "Action": "s3:ListBucket",
            "Resource": "arn:aws:s3:::${bucket}"
        },
        {
            "Sid": "ReadWriteObjects",
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:DeleteObject"
            ],
            "Resource": "arn:aws:s3:::${bucket}/*"
        },
        {
            "Sid": "InvalidateDistribution",
            "Effect": "Allow",
            "Action": "cloudfront:CreateInvalidation",
            "Resource": "arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${dist_id}"
        }
    ]
}
EOF

        if ! $aws_cmd iam put-role-policy \
            --role-name "$role_name" \
            --policy-name "$policy_name" \
            --policy-document "file://${policy_file}"; then
            rm -f "$policy_file"
            log "ERROR" "[$name] failed to attach inline policy $policy_name"
            exit 1
        fi
        rm -f "$policy_file"

        update_status "env_${name}_role_name" "$role_name"
        update_status "env_${name}_role_policy_name" "$policy_name"
        update_status "env_${name}_role_arn" "$role_arn"
        mark_step_completed "role_${name}"
        log "SUCCESS" "[$name] role ready: $role_arn"
    done
}

# The workflow deploys with `aws s3 sync --delete`, which is destructive to
# anything not in the docroot. Versioning is the rollback story.
check_bucket_versioning() {
    log "STEP" "Checking bucket versioning (rollback safety for sync --delete)"

    local aws_cmd=$(aws_cli)
    local i name bucket vstatus
    for i in "${!ENV_NAMES[@]}"; do
        name="${ENV_NAMES[$i]}"
        bucket=$(get_status "env_${name}_bucket" "")

        vstatus=$($aws_cmd s3api get-bucket-versioning --bucket "$bucket" --query 'Status' --output text 2>/dev/null)
        if [ "$vstatus" = "Enabled" ]; then
            log "INFO" "[$name] versioning already enabled on $bucket"
            continue
        fi

        log "WARN" "[$name] versioning is NOT enabled on $bucket"
        log "WARN" "A bad CI deploy would permanently delete objects with no recovery path."
        if confirm_action "Enable versioning on $bucket?"; then
            if $aws_cmd s3api put-bucket-versioning \
                --bucket "$bucket" \
                --expected-bucket-owner "$ACCOUNT_ID" \
                --versioning-configuration Status=Enabled; then
                log "SUCCESS" "[$name] versioning enabled on $bucket"
            else
                log "ERROR" "[$name] failed to enable versioning on $bucket"
                exit 1
            fi
        else
            log "WARN" "[$name] continuing WITHOUT versioning — rollback will require a redeploy"
        fi
    done
}

# =============================================================================
# GitHub: environments, branch policies, variables
# =============================================================================

setup_github_environments() {
    log "STEP" "Configuring GitHub environments on $REPO_SLUG"

    local reviewer_id="" reviewer_login=""
    if [ "$NO_APPROVAL" != true ]; then
        reviewer_id=$(gh api user --jq '.id' 2>/dev/null)
        reviewer_login=$(gh api user --jq '.login' 2>/dev/null)
    fi

    local i name body
    for i in "${!ENV_NAMES[@]}"; do
        name="${ENV_NAMES[$i]}"

        # Required reviewer on 'production' only (the cheapest guard against
        # "merged, whoops"). Everything else deploys unattended.
        if [ "$name" = "production" ] && [ -n "$reviewer_id" ]; then
            body=$(jq -n --argjson id "$reviewer_id" \
                '{deployment_branch_policy: {protected_branches: false, custom_branch_policies: true},
                  reviewers: [{type: "User", id: $id}]}')
            log "INFO" "[$name] requiring approval from @$reviewer_login before deploys"
        else
            body=$(jq -n \
                '{deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}}')
        fi

        log "INFO" "[$name] creating/updating GitHub environment"
        if ! echo "$body" | gh api -X PUT "repos/$REPO_SLUG/environments/$name" --input - >/dev/null; then
            log "ERROR" "[$name] failed to create GitHub environment"
            log "ERROR" "Note: environments with protection rules require a public repo or a paid GitHub plan."
            exit 1
        fi

        # Restrict the environment to its same-named branch. This — not the
        # workflow file — is what enforces the branch → environment mapping.
        local existing_policies
        existing_policies=$(gh api "repos/$REPO_SLUG/environments/$name/deployment-branch-policies" \
            --jq '.branch_policies[].name' 2>/dev/null)
        if echo "$existing_policies" | grep -qx "$name"; then
            log "INFO" "[$name] branch policy for '$name' already present"
        else
            if ! gh api -X POST "repos/$REPO_SLUG/environments/$name/deployment-branch-policies" \
                -f name="$name" >/dev/null; then
                log "ERROR" "[$name] failed to add deployment branch policy for branch '$name'"
                exit 1
            fi
            log "INFO" "[$name] restricted to deploys from branch '$name'"
        fi

        # gh variable set upserts, so re-runs converge on current values.
        local role_arn=$(get_status "env_${name}_role_arn" "")
        local bucket=$(get_status "env_${name}_bucket" "")
        local dist_id=$(get_status "env_${name}_distribution_id" "")
        local ok=true
        gh variable set AWS_ROLE_ARN --env "$name" --repo "$REPO_SLUG" --body "$role_arn" || ok=false
        gh variable set AWS_REGION --env "$name" --repo "$REPO_SLUG" --body "$AWS_REGION" || ok=false
        gh variable set S3_BUCKET --env "$name" --repo "$REPO_SLUG" --body "$bucket" || ok=false
        gh variable set CLOUDFRONT_DISTRIBUTION_ID --env "$name" --repo "$REPO_SLUG" --body "$dist_id" || ok=false
        if [ "$ok" != true ]; then
            log "ERROR" "[$name] failed to set one or more environment variables"
            exit 1
        fi

        mark_step_completed "gh_env_${name}"
        log "SUCCESS" "[$name] GitHub environment configured"
    done
}

# =============================================================================
# Workflow generation + integrity hash
# =============================================================================

# Emits the workflow to stdout. Deliberately deterministic (no timestamps):
# re-generating with the same inputs yields the same sha256, so a changed
# hash always means a changed configuration or an edit in the site repo.
build_workflow() {
    cat <<EOF
# Generated by s3-static-toolkit (src/setup-ci.sh) for ${REPO_SLUG}.
# Do not edit by hand — changes here will be flagged as tampering by
# setup-ci.sh --check and overwritten on the next re-run.
#
# Branch == environment: pushing to a branch below deploys the GitHub
# environment of the same name. The branch restriction is enforced by each
# environment's deployment-branch policy on GitHub, not by this file.
name: Deploy static site

on:
  push:
    branches:
EOF
    local name
    for name in "${ENV_NAMES[@]}"; do
        echo "      - $name"
    done
    cat <<'EOF'
  workflow_dispatch:
    inputs:
      environment:
        description: Environment to deploy
        type: choice
        required: true
        options:
EOF
    for name in "${ENV_NAMES[@]}"; do
        echo "          - $name"
    done
    cat <<'EOF' | sed "s|__DOCROOT__|${DOCROOT}|g"
      run_build:
        description: Run the build step before syncing
        type: boolean
        default: false

permissions:
  id-token: write
  contents: read

concurrency:
  group: deploy-${{ github.event_name == 'workflow_dispatch' && inputs.environment || github.ref_name }}
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: ${{ github.event_name == 'workflow_dispatch' && inputs.environment || github.ref_name }}
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      # Optional build, off by default (manual dispatch only).
      # Customize the commands for your toolchain.
      - name: Build
        if: ${{ github.event_name == 'workflow_dispatch' && inputs.run_build }}
        run: |
          npm ci
          npm run build

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}

      - name: Sync docroot to S3
        run: |
          aws s3 sync "__DOCROOT__" "s3://${{ vars.S3_BUCKET }}" \
            --delete \
            --exclude ".git/*" \
            --exclude ".github/*"

      - name: Invalidate CloudFront cache
        run: |
          aws cloudfront create-invalidation \
            --distribution-id "${{ vars.CLOUDFRONT_DISTRIBUTION_ID }}" \
            --paths "/*"
EOF
}

generate_workflow() {
    log "STEP" "Generating workflow file in site repo"

    local workflow_path="${REPO_PATH}/${WORKFLOW_REL_PATH}"
    local stored_hash=$(get_status "workflow_sha256" "")

    # Tamper check before overwriting: if we generated this file before and
    # it no longer matches the recorded hash, someone edited it in the site
    # repo. Make that loud instead of silently clobbering their changes.
    if [ -f "$workflow_path" ]; then
        local current_hash=$(file_sha256 "$workflow_path")
        if [ -n "$stored_hash" ] && [ "$current_hash" != "$stored_hash" ]; then
            log "WARN" "Existing $WORKFLOW_REL_PATH does NOT match the recorded sha256!"
            log "WARN" "  recorded: $stored_hash"
            log "WARN" "  current:  $current_hash"
            log "WARN" "It was modified in the site repo since it was generated."
            if ! confirm_action "Overwrite the modified workflow file?"; then
                log "INFO" "Leaving existing workflow file untouched"
                return 0
            fi
        elif [ -z "$stored_hash" ]; then
            log "WARN" "A $WORKFLOW_REL_PATH already exists in the site repo (not generated by this toolkit)"
            if ! confirm_action "Overwrite it?"; then
                log "INFO" "Leaving existing workflow file untouched"
                return 0
            fi
        fi
    fi

    mkdir -p "$(dirname "$workflow_path")"
    if ! build_workflow > "$workflow_path"; then
        log "ERROR" "Failed to write $workflow_path"
        exit 1
    fi

    local new_hash=$(file_sha256 "$workflow_path")
    update_status "repo_path" "$REPO_PATH"
    update_status "docroot" "$DOCROOT"
    update_status "region" "$AWS_REGION"
    update_status "workflow_file" "$WORKFLOW_REL_PATH"
    update_status "workflow_sha256" "$new_hash"
    update_status "workflow_generated_at" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    mark_step_completed "workflow"

    log "SUCCESS" "Wrote $workflow_path"
    log "INFO" "sha256 recorded: $new_hash"
}

# --check mode: compare the workflow in the site repo against the recorded
# hash. Exit 0 if intact, 1 if modified or missing.
check_workflow_integrity() {
    local stored_hash=$(get_status "workflow_sha256" "")
    local repo_path="${REPO_PATH:-$(get_status "repo_path" "")}"

    if [ -z "$stored_hash" ]; then
        log "ERROR" "No workflow_sha256 recorded in $STATUS_FILE — run setup first"
        exit 1
    fi
    if [ -z "$repo_path" ]; then
        log "ERROR" "No repo path known; pass --repo-path"
        exit 1
    fi

    local workflow_path="${repo_path}/$(get_status "workflow_file" "$WORKFLOW_REL_PATH")"
    if [ ! -f "$workflow_path" ]; then
        log "ERROR" "Workflow file is MISSING: $workflow_path"
        exit 1
    fi

    local current_hash=$(file_sha256 "$workflow_path")
    if [ "$current_hash" = "$stored_hash" ]; then
        log "SUCCESS" "Workflow file matches recorded sha256 ($current_hash)"
        log "INFO" "Generated at: $(get_status "workflow_generated_at" "unknown")"
        exit 0
    else
        log "ERROR" "Workflow file has been MODIFIED since it was generated!"
        log "ERROR" "  recorded: $stored_hash"
        log "ERROR" "  current:  $current_hash"
        log "ERROR" "File: $workflow_path"
        log "ERROR" "Review the diff in the site repo, then re-run setup-ci.sh to regenerate if appropriate."
        exit 1
    fi
}

# =============================================================================
# Summary
# =============================================================================

display_summary() {
    log "STEP" "CI Setup Summary"
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    ${BOLD}CI SETUP SUMMARY${NC}${CYAN}                          ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${BOLD}Repository:${NC} $REPO_SLUG"
    echo -e "${BOLD}Workflow:${NC}   ${REPO_PATH}/${WORKFLOW_REL_PATH}"
    echo -e "${BOLD}sha256:${NC}     $(get_status "workflow_sha256" "N/A")"
    echo -e "${BOLD}Status File:${NC} $STATUS_FILE"
    echo
    local i name
    for i in "${!ENV_NAMES[@]}"; do
        name="${ENV_NAMES[$i]}"
        echo -e "${BOLD}[$name]${NC} branch '${name}' -> ${ENV_DOMAINS[$i]}"
        echo -e "    Bucket:       $(get_status "env_${name}_bucket" "N/A")"
        echo -e "    Distribution: $(get_status "env_${name}_distribution_id" "N/A")"
        echo -e "    Role:         $(get_status "env_${name}_role_arn" "N/A")"
    done
    echo
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                      ${BOLD}NEXT STEPS${NC}${CYAN}                            ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "1. ${BOLD}Commit and push the workflow in the site repo:${NC}"
    echo -e "   cd $REPO_PATH"
    echo -e "   git add ${WORKFLOW_REL_PATH} && git commit -m 'add deploy workflow' && git push"
    echo
    echo -e "2. ${BOLD}Create the deploy branches (if they don't exist yet):${NC}"
    for name in "${ENV_NAMES[@]}"; do
        echo -e "   git branch $name && git push -u origin $name"
    done
    echo
    echo -e "3. ${BOLD}Deploy:${NC} push to a branch above, or run the workflow manually"
    echo -e "   from the Actions tab (workflow_dispatch with an environment picker)."
    if [ "$NO_APPROVAL" != true ]; then
        local has_prod=false
        for name in "${ENV_NAMES[@]}"; do
            [ "$name" = "production" ] && has_prod=true
        done
        if [ "$has_prod" = true ]; then
            echo -e "   ${YELLOW}production deploys pause for approval in the Actions UI.${NC}"
        fi
    fi
    echo
    echo -e "4. ${BOLD}Check workflow integrity anytime:${NC}"
    echo -e "   $0 --check --repo $REPO_SLUG"
    echo
    echo -e "${GREEN}${BOLD}CI setup complete.${NC}"
}

# =============================================================================
# Main
# =============================================================================

main() {
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            --repo-path)
                REPO_PATH="$2"
                shift
                shift
                ;;
            --repo)
                REPO_SLUG="$2"
                shift
                shift
                ;;
            --env)
                ENV_SPECS+=("$2")
                shift
                shift
                ;;
            --docroot)
                DOCROOT="$2"
                shift
                shift
                ;;
            --region)
                AWS_REGION="$2"
                shift
                shift
                ;;
            --profile)
                AWS_PROFILE="$2"
                shift
                shift
                ;;
            --status-file)
                STATUS_FILE="$2"
                shift
                shift
                ;;
            --no-approval)
                NO_APPROVAL=true
                shift
                ;;
            --check)
                CHECK_ONLY=true
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

    # --check only needs to find the status file and the repo clone
    if [ "$CHECK_ONLY" = true ]; then
        if [ -z "$STATUS_FILE" ]; then
            if [ -n "$REPO_SLUG" ]; then
                STATUS_FILE="$(default_ci_status_file "$REPO_SLUG")" || exit 1
            else
                log "ERROR" "--check needs --repo ORG/REPO or --status-file"
                usage
            fi
        fi
        if [ ! -f "$STATUS_FILE" ]; then
            log "ERROR" "Status file not found: $STATUS_FILE"
            exit 1
        fi
        check_workflow_integrity
    fi

    check_prerequisites
    prompt_for_missing_inputs
    parse_env_specs

    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           ${BOLD}GITHUB ACTIONS CI SETUP SCRIPT${NC}${CYAN}                   ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${BOLD}Site repo path:${NC} $REPO_PATH"
    echo -e "${BOLD}Docroot:${NC} $DOCROOT"
    echo -e "${BOLD}AWS Region:${NC} $AWS_REGION"
    if [ -n "$AWS_PROFILE" ]; then
        echo -e "${BOLD}AWS Profile:${NC} $AWS_PROFILE"
    fi
    local i
    for i in "${!ENV_NAMES[@]}"; do
        echo -e "${BOLD}Environment:${NC} ${ENV_NAMES[$i]} (branch '${ENV_NAMES[$i]}') -> ${ENV_DOMAINS[$i]}"
    done
    echo

    resolve_repo
    init_status_file
    check_aws_config

    if ! confirm_action "Proceed with CI setup?"; then
        log "INFO" "CI setup cancelled"
        exit 0
    fi

    load_site_configs
    ensure_oidc_provider
    create_deploy_roles
    check_bucket_versioning
    setup_github_environments
    generate_workflow

    display_summary
}

# Run the script
main "$@"
