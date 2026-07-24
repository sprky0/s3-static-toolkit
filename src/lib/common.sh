#!/bin/bash
#───────────────────────────────────────────────────────────────────────────────
# lib/common.sh - Common helpers for s3-static-toolkit scripts
# Modeled after ~/access/aliases/lib/common.sh
#
# NOTE: this file does NOT enable `set -euo pipefail`. Sourcing scripts inherit
# `set` flags, so we leave error-handling discipline to each caller.
#───────────────────────────────────────────────────────────────────────────────

# Determine this file's directory (bash/zsh compatible best-effort)
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [[ -n "${ZSH_VERSION:-}" ]]; then
	SCRIPT_DIR="$(cd "$(dirname "${(%):-%N}")" && pwd)"
else
	SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
fi

# Source colors if not already loaded
if [[ -z "${NC:-}" ]]; then
	# shellcheck disable=SC1091
	source "$SCRIPT_DIR/colors.sh"
fi

print_header() {
	local title="$1"
	echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
	echo -e "${BOLD}${title}${NC}"
	echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_footer() {
	echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

log_info() { echo -e "${BLUE}[INFO]${NC} $(date "+%Y-%m-%d %H:%M:%S") - $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date "+%Y-%m-%d %H:%M:%S") - $*"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $(date "+%Y-%m-%d %H:%M:%S") - $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date "+%Y-%m-%d %H:%M:%S") - $*"; }
log_step() { echo -e "\n${MAGENTA}[STEP]${NC} $(date "+%Y-%m-%d %H:%M:%S") - ${BOLD}$*${NC}"; }
log_debug() { echo -e "${CYAN}[DEBUG]${NC} $(date "+%Y-%m-%d %H:%M:%S") - $*"; }

# Two-arg dispatcher used pervasively by the toolkit's scripts:
#   log "INFO" "message"
#   log "ERROR" "message"
log() {
	local level="$1"; shift
	case "$level" in
		INFO)    log_info    "$*" ;;
		SUCCESS) log_success "$*" ;;
		WARN)    log_warn    "$*" ;;
		ERROR)   log_error   "$*" ;;
		STEP)    log_step    "$*" ;;
		DEBUG)   log_debug   "$*" ;;
		*)       echo -e "[${level}] $(date "+%Y-%m-%d %H:%M:%S") - $*" ;;
	esac
}

# Render a destructive verb LOUDLY (white-on-red pill). Used in cleanup plans.
destruct() {
	echo -ne "${BOLD}${BG_RED}${WHITE} $1 ${NC}"
}

confirm() {
	local prompt="$1"
	local default="${2:-N}"
	local auto_confirm="${3:-false}"

	if [[ "$auto_confirm" == true ]]; then
		echo -e "${YELLOW}$prompt${NC} [auto-confirmed]"
		return 0
	fi

	local prompt_text
	if [[ $default == "Y" ]]; then
		prompt_text="[Y/n]"
	else
		prompt_text="[y/N]"
	fi

	echo -en "${YELLOW}$prompt $prompt_text ${NC}"
	read -r response
	response=${response:-$default}
	[[ $response =~ ^[Yy] ]]
}

# Repo root (lib/ lives at {repo-root}/src/lib)
S3ST_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Config directory holding per-site status files (.deploy-status-*.json).
# Expected to exist at {repo-root}/config — commonly a symlink to wherever
# the configs actually live. Override with S3ST_CONFIG_DIR.
config_dir() {
	local dir="${S3ST_CONFIG_DIR:-$S3ST_REPO_ROOT/config}"
	if [[ ! -d "$dir" ]]; then # -d follows symlinks
		log_error "Config directory not found: $dir (expected at {repo-root}/config)" >&2
		return 1
	fi
	echo "$dir"
}

default_site_status_file() {
	local domain="$1" dir
	dir="$(config_dir)" || return 1
	echo "${dir}/.deploy-status-${domain}.json"
}

default_redirect_status_file() {
	local target_domain="$1" dir
	dir="$(config_dir)" || return 1
	echo "${dir}/.deploy-status-redirect-${target_domain}.json"
}

# CI status files are keyed by the GitHub repo slug (org/repo), slash → dash.
default_ci_status_file() {
	local repo_slug="$1" dir
	dir="$(config_dir)" || return 1
	echo "${dir}/.ci-status-${repo_slug//\//-}.json"
}

# require_account_match STATUS_FILE [AWS_PROFILE]
#
# Guard against operating on a status file that was created under a different
# AWS account than the current caller (i.e. authenticated with the wrong
# profile). Resolves the caller's account via STS and compares it to the
# account_id recorded in STATUS_FILE, when both exist. An empty/missing
# STATUS_FILE or a status file without account_id only validates credentials.
#
# On success sets the global CALLER_ACCOUNT_ID and returns 0. Returns 1 on
# credential failure or account mismatch. Call directly and `|| exit 1` — do
# NOT invoke via command substitution (the global assignment and log output
# must reach the parent shell).
require_account_match() {
	local status_file="${1:-}"
	local aws_profile="${2:-}"
	local aws_cmd="aws"
	[[ -n "$aws_profile" ]] && aws_cmd="aws --profile $aws_profile"

	if ! CALLER_ACCOUNT_ID=$($aws_cmd sts get-caller-identity --query Account --output text 2>/dev/null); then
		log_error "Cannot determine current AWS account. Check credentials/profile${aws_profile:+ ($aws_profile)}."
		return 1
	fi

	local status_account=""
	if [[ -n "$status_file" && -f "$status_file" ]]; then
		status_account=$(jq -r '.account_id // ""' "$status_file" 2>/dev/null) || status_account=""
	fi

	if [[ -n "$status_account" && "$status_account" != "null" && "$status_account" != "$CALLER_ACCOUNT_ID" ]]; then
		log_error "Status file records account ${status_account} but you are authenticated to ${CALLER_ACCOUNT_ID}${aws_profile:+ (profile: $aws_profile)}."
		log_error "Refusing to mix accounts. Switch profile and retry. ($status_file)"
		return 1
	fi
	return 0
}

# find_zone_for_domain DOMAIN [AWS_PROFILE]
#
# Walk labels from longest to shortest looking up each suffix as a Route53
# hosted zone. Returns the longest matching zone — for "blog.foo.example.com"
# it tries "blog.foo.example.com", "foo.example.com", "example.com" in order
# and returns the first hit. Correctly handles multi-part TLDs (.co.uk etc).
#
# Prints "ZONE_ID|ZONE_NAME" on stdout when a zone is found (zone name without
# trailing dot). Prints nothing when no zone matches. Always exits 0 — caller
# decides whether absence is an error.
find_zone_for_domain() {
	local domain="$1"
	local aws_profile="${2:-}"
	local aws_cmd="aws"
	[[ -n "$aws_profile" ]] && aws_cmd="aws --profile $aws_profile"

	local candidate="${domain%.}"
	while [[ "$candidate" == *.* ]]; do
		local zone_id
		zone_id=$($aws_cmd route53 list-hosted-zones-by-name \
			--dns-name "$candidate." --max-items 1 \
			--query "HostedZones[?Name=='$candidate.'].Id" \
			--output text 2>/dev/null | head -n1 | sed 's|^/hostedzone/||')
		if [[ -n "$zone_id" && "$zone_id" != "None" ]]; then
			echo "${zone_id}|${candidate}"
			return 0
		fi
		candidate="${candidate#*.}"
	done
	return 0
}
