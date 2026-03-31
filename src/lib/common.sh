#!/bin/bash
#───────────────────────────────────────────────────────────────────────────────
# lib/common.sh - Common helpers for s3-static-toolkit scripts
# Modeled after ~/access/aliases/lib/common.sh
#───────────────────────────────────────────────────────────────────────────────

set -euo pipefail

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

ensure_state_dir() {
	local home_dir="${S3ST_HOME:-$HOME/.s3-static-toolkit}"
	mkdir -p "$home_dir"
	echo "$home_dir"
}

default_site_status_file() {
	local domain="$1"
	local home_dir
	home_dir="$(ensure_state_dir)"
	echo "${home_dir}/site-${domain}.json"
}

default_redirect_status_file() {
	local target_domain="$1"
	local home_dir
	home_dir="$(ensure_state_dir)"
	echo "${home_dir}/redirect-${target_domain}.json"
}
