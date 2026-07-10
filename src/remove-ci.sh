#!/bin/bash
# =============================================================================
# GitHub Actions CI Removal Script
#
# Tears down what setup-ci.sh provisioned, driven by the CI status file:
#   - per-environment IAM deploy roles (inline policy, then role)
#   - per-environment GitHub Environments (variables, branch policies and
#     reviewers go with them)
#
# Deliberately NOT touched:
#   - the OIDC provider (shared across every repo/site on the account)
#   - the site itself — buckets, distributions, DNS (that's remove-site.sh)
#   - the workflow file committed in the site repo (remove it with git)
# =============================================================================

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Default values
STATUS_FILE=""
REPO_SLUG=""
AWS_PROFILE=""
AUTO_APPROVE=false

# Populated during execution
ACCOUNT_ID=""
ENV_NAMES=()

usage() {
    local exit_code="${1:-1}"
    echo "Usage: $0 [--repo ORG/REPO | --status-file FILE] [options]"
    echo ""
    echo "Options:"
    echo "  --repo ORG/REPO          GitHub repo slug used at setup time"
    echo "                           (resolves config/.ci-status-<org>-<repo>.json)"
    echo "  --status-file FILE       CI status file from setup-ci.sh"
    echo "  --profile PROFILE        AWS CLI profile (optional)"
    echo "  --yes                    Skip all confirmation prompts"
    echo "  --help                   Display this help message"
    exit "$exit_code"
}

aws_cli() {
    local cmd="aws"
    if [ -n "$AWS_PROFILE" ]; then
        cmd="$cmd --profile $AWS_PROFILE"
    fi
    echo "$cmd"
}

get_status() {
    local key=$1
    local default=$2
    local value=$(jq -r --arg key "$key" '.[$key] // ""' "$STATUS_FILE")
    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

validate_status_file() {
    if [ ! -f "$STATUS_FILE" ]; then
        log "ERROR" "Status file does not exist: $STATUS_FILE"
        exit 1
    fi
    if ! jq empty "$STATUS_FILE" 2>/dev/null; then
        log "ERROR" "Status file is not valid JSON: $STATUS_FILE"
        exit 1
    fi

    REPO_SLUG=$(get_status "repo_slug" "")
    if [ -z "$REPO_SLUG" ]; then
        log "ERROR" "Status file has no repo_slug — is this really a CI status file?"
        exit 1
    fi

    local env_csv=$(get_status "environments" "")
    if [ -z "$env_csv" ]; then
        log "ERROR" "Status file lists no environments"
        exit 1
    fi
    IFS=',' read -r -a ENV_NAMES <<< "$env_csv"

    log "SUCCESS" "Status file is valid ($REPO_SLUG: ${env_csv})"
}

# Same account-mismatch guard as remove-site.sh: never delete resources
# recorded under a different account than the current caller.
resolve_account_id() {
    local status_account=$(get_status "account_id" "")
    local aws_cmd=$(aws_cli)
    local caller_account
    if ! caller_account=$($aws_cmd sts get-caller-identity --query Account --output text 2>/dev/null); then
        log "ERROR" "Cannot determine current AWS account. Check credentials/profile."
        exit 1
    fi

    if [ -n "$status_account" ]; then
        if [ "$status_account" != "$caller_account" ]; then
            log "ERROR" "Status file was created under account $status_account but current caller is $caller_account."
            log "ERROR" "Refusing to touch resources that may not belong to you. Switch profile and retry."
            exit 1
        fi
        ACCOUNT_ID="$status_account"
    else
        log "WARN" "Status file has no account_id; falling back to current caller ($caller_account)."
        ACCOUNT_ID="$caller_account"
    fi
}

# =============================================================================
# Plan: show exactly what will be touched. NO destructive calls here.
# =============================================================================

display_removal_plan() {
    local aws_cmd=$(aws_cli)

    echo
    print_header "CI REMOVAL PLAN — $REPO_SLUG"
    echo

    local name role_name policy_name
    for name in "${ENV_NAMES[@]}"; do
        echo -e "  ${BOLD}Environment: $name${NC} ($(get_status "env_${name}_domain" "?"))"

        role_name=$(get_status "env_${name}_role_name" "")
        policy_name=$(get_status "env_${name}_role_policy_name" "")
        if [ -n "$role_name" ]; then
            if $aws_cmd iam get-role --role-name "$role_name" &>/dev/null; then
                echo -e "    IAM role:      $role_name  $(destruct DELETE)"
                [ -n "$policy_name" ] && echo -e "    Inline policy: $policy_name  $(destruct DELETE)"
            else
                echo -e "    IAM role:      $role_name ${YELLOW}(does not exist in AWS; will skip)${NC}"
            fi
        else
            echo -e "    IAM role:      ${YELLOW}(none recorded)${NC}"
        fi

        if gh api "repos/$REPO_SLUG/environments/$name" &>/dev/null; then
            echo -e "    GitHub env:    $name (vars, branch policy, reviewers)  $(destruct DELETE)"
        else
            echo -e "    GitHub env:    $name ${YELLOW}(does not exist on GitHub; will skip)${NC}"
        fi
        echo
    done

    echo -e "  ${BOLD}Left in place:${NC}"
    echo -e "    - OIDC provider (shared account-wide): $(get_status "oidc_provider_arn" "n/a")"
    echo -e "    - The sites themselves (buckets, distributions, DNS) — use remove-site.sh"
    local repo_path=$(get_status "repo_path" "")
    local workflow_file=$(get_status "workflow_file" ".github/workflows/deploy.yml")
    echo -e "    - The committed workflow file — remove it from the site repo yourself:"
    echo -e "      ${repo_path:-<site repo>}/${workflow_file}"
    echo
    print_footer
}

# =============================================================================
# Removal
# =============================================================================

remove_deploy_roles() {
    log "STEP" "Removing IAM deploy roles"

    local aws_cmd=$(aws_cli)
    local name role_name policy_name
    for name in "${ENV_NAMES[@]}"; do
        role_name=$(get_status "env_${name}_role_name" "")
        if [ -z "$role_name" ]; then
            log "INFO" "[$name] no role recorded, skipping"
            continue
        fi

        if ! $aws_cmd iam get-role --role-name "$role_name" &>/dev/null; then
            log "INFO" "[$name] role $role_name does not exist, skipping"
            continue
        fi

        policy_name=$(get_status "env_${name}_role_policy_name" "")
        if [ -n "$policy_name" ]; then
            if $aws_cmd iam get-role-policy --role-name "$role_name" --policy-name "$policy_name" &>/dev/null; then
                log "INFO" "[$name] deleting inline policy $policy_name"
                $aws_cmd iam delete-role-policy --role-name "$role_name" --policy-name "$policy_name"
            fi
        fi

        log "INFO" "[$name] deleting role $role_name"
        if $aws_cmd iam delete-role --role-name "$role_name"; then
            log "SUCCESS" "[$name] deleted role $role_name"
        else
            log "ERROR" "[$name] failed to delete role $role_name (manually-attached policies?)"
        fi
    done
}

remove_github_environments() {
    log "STEP" "Removing GitHub environments"

    local name
    for name in "${ENV_NAMES[@]}"; do
        if ! gh api "repos/$REPO_SLUG/environments/$name" &>/dev/null; then
            log "INFO" "[$name] environment does not exist on GitHub, skipping"
            continue
        fi

        log "INFO" "[$name] deleting GitHub environment"
        if gh api -X DELETE "repos/$REPO_SLUG/environments/$name" >/dev/null; then
            log "SUCCESS" "[$name] deleted GitHub environment (vars and policies removed with it)"
        else
            log "ERROR" "[$name] failed to delete GitHub environment"
        fi
    done
}

finalize_status_file() {
    local temp_file=$(mktemp)
    jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '. + {removed_at: $ts}' "$STATUS_FILE" > "$temp_file"
    mv "$temp_file" "$STATUS_FILE"
    log "INFO" "Marked removal in $STATUS_FILE (delete the file if you're done with it)"
}

# =============================================================================
# Main
# =============================================================================

main() {
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            --repo)
                REPO_SLUG="$2"
                shift
                shift
                ;;
            --status-file)
                STATUS_FILE="$2"
                shift
                shift
                ;;
            --profile)
                AWS_PROFILE="$2"
                shift
                shift
                ;;
            -y|--yes)
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

    for tool in aws jq gh; do
        if ! command -v "$tool" &>/dev/null; then
            log "ERROR" "Required tool not found: $tool"
            exit 1
        fi
    done

    if [ -z "$STATUS_FILE" ]; then
        if [ -n "$REPO_SLUG" ]; then
            STATUS_FILE="$(default_ci_status_file "$REPO_SLUG")" || exit 1
        else
            log "ERROR" "Pass --repo ORG/REPO or --status-file FILE"
            usage
        fi
    fi

    validate_status_file
    resolve_account_id
    display_removal_plan

    if ! confirm "Proceed with CI removal?" "N" "$AUTO_APPROVE"; then
        log "INFO" "Removal cancelled"
        exit 0
    fi

    remove_deploy_roles
    remove_github_environments
    finalize_status_file

    log "SUCCESS" "CI removal complete for $REPO_SLUG"
}

# Run the script
main "$@"
