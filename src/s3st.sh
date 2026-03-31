#!/bin/bash

# s3st - local runner for s3-static-toolkit
# Modeled after ~/access/aliases/ajb-runner.sh

set -euo pipefail

# Ensure this script runs under bash (safe when sourced from zsh)
if [ -z "${BASH_VERSION:-}" ]; then
	if [ -n "${ZSH_VERSION:-}" ]; then
		S3ST_SELF="${(%):-%N}"
		command bash "$S3ST_SELF" "$@"
		return $?
	fi
	command bash "$0" "$@"
	exit $?
fi

safe_exit() {
	if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
		return "$1"
	else
		exit "$1"
	fi
}

S3ST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$S3ST_DIR/lib/common.sh"

show_help() {
	print_header "Usage: s3st <group> <command> [args...]"
	echo -e "${BOLD}Local dispatcher for s3-static-toolkit scripts.${NC}"
	echo
	echo -e "${CYAN}Groups:${NC}"
	echo -e "  ${GREEN}site${NC}      ${DIM}deploy/sync/remove a static site${NC}"
	echo -e "  ${GREEN}redirect${NC}  ${DIM}deploy/remove a multi-domain redirect stack${NC}"
	echo
	echo -e "${CYAN}Quality-of-life flags (runner-level):${NC}"
	echo -e "  ${GREEN}--yes${NC} / ${GREEN}-y${NC}   ${DIM}Auto-inject confirmation bypass${NC}"
	echo -e "  ${GREEN}--dry${NC}          ${DIM}Alias for --dry-run when calling sync${NC}"
	echo
	echo -e "${CYAN}Examples:${NC}"
	echo -e "  s3st site deploy --domain example.com --profile myaws"
	echo -e "  s3st site sync --domain example.com --source ./dist --yes --dry"
	echo -e "  s3st site remove --domain example.com --yes"
	echo -e "  s3st redirect deploy --source-domains a.com,b.com --target-domain t.com --yes"
	echo -e "  s3st redirect remove --status-file ~/.aws-redirect-status.json --yes"
	print_footer
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || -z "${1:-}" ]]; then
	show_help
	safe_exit 0
fi

# Global QoL flags
GLOBAL_YES=false
GLOBAL_DRY=false
POSITIONAL=()
for arg in "$@"; do
	case "$arg" in
		--yes|-y) GLOBAL_YES=true ;;
		--dry) GLOBAL_DRY=true ;;
		*) POSITIONAL+=("$arg") ;;
	esac
done
set -- "${POSITIONAL[@]}"

GROUP="$1"; shift

# Defensive: Only use bash arrays if running under bash, otherwise fallback to sh/zsh-safe positional passing
case "$GROUP" in
	site)
		CMD="${1:-}"; shift || true
		if [ -n "${BASH_VERSION:-}" ]; then
			declare -a ARGS=()
			case "$CMD" in
				deploy)
					ARGS=()
					if [[ "$GLOBAL_YES" == true ]]; then ARGS+=("--yes"); fi
					if (( ${#ARGS[@]} > 0 )); then
						bash "$S3ST_DIR/deploy-site.sh" "${ARGS[@]}" "$@"
					else
						bash "$S3ST_DIR/deploy-site.sh" "$@"
					fi
					safe_exit $?
					;;
				sync)
					ARGS=()
					if [[ "$GLOBAL_YES" == true ]]; then ARGS+=("--yes"); fi
					if [[ "$GLOBAL_DRY" == true ]]; then ARGS+=("--dry-run"); fi
					if (( ${#ARGS[@]} > 0 )); then
						bash "$S3ST_DIR/sync.sh" "${ARGS[@]}" "$@"
					else
						bash "$S3ST_DIR/sync.sh" "$@"
					fi
					safe_exit $?
					;;
				remove|rm|cleanup)
					ARGS=()
					if [[ "$GLOBAL_YES" == true ]]; then ARGS+=("--yes"); fi
					if (( ${#ARGS[@]} > 0 )); then
						bash "$S3ST_DIR/remove-site.sh" "${ARGS[@]}" "$@"
					else
						bash "$S3ST_DIR/remove-site.sh" "$@"
					fi
					safe_exit $?
					;;
				""|-h|--help|help)
					print_header "s3st site"
					echo -e "${BOLD}Usage:${NC} s3st site <deploy|sync|remove> [args...]"
					echo
					echo -e "${CYAN}Commands:${NC}"
					echo -e "  ${GREEN}deploy${NC}   Deploy a static site stack (S3 + CloudFront + ACM + Route53)"
					echo -e "  ${GREEN}sync${NC}     Sync a local folder to the site bucket and invalidate CloudFront"
					echo -e "  ${GREEN}remove${NC}   Remove the deployed site resources from the status file"
					print_footer
					safe_exit 0
					;;
				*)
					echo -e "${RED}Unknown site command:${NC} $CMD" >&2
					echo -e "Try: ${CYAN}s3st site --help${NC}" >&2
					safe_exit 1
					;;
			esac
		else
			# Not bash: fallback to positional passing (no arrays)
			case "$CMD" in
				deploy)
					EXTRA=""
					if [ "$GLOBAL_YES" = true ]; then EXTRA="--yes"; fi
					bash "$S3ST_DIR/deploy-site.sh" $EXTRA "$@"
					safe_exit $?
					;;
				sync)
					EXTRA=""
					if [ "$GLOBAL_YES" = true ]; then EXTRA="$EXTRA --yes"; fi
					if [ "$GLOBAL_DRY" = true ]; then EXTRA="$EXTRA --dry-run"; fi
					bash "$S3ST_DIR/sync.sh" $EXTRA "$@"
					safe_exit $?
					;;
				remove|rm|cleanup)
					EXTRA=""
					if [ "$GLOBAL_YES" = true ]; then EXTRA="--yes"; fi
					bash "$S3ST_DIR/remove-site.sh" $EXTRA "$@"
					safe_exit $?
					;;
				""|-h|--help|help)
					print_header "s3st site"
					echo -e "${BOLD}Usage:${NC} s3st site <deploy|sync|remove> [args...]"
					echo
					echo -e "${CYAN}Commands:${NC}"
					echo -e "  ${GREEN}deploy${NC}   Deploy a static site stack (S3 + CloudFront + ACM + Route53)"
					echo -e "  ${GREEN}sync${NC}     Sync a local folder to the site bucket and invalidate CloudFront"
					echo -e "  ${GREEN}remove${NC}   Remove the deployed site resources from the status file"
					print_footer
					safe_exit 0
					;;
				*)
					echo -e "${RED}Unknown site command:${NC} $CMD" >&2
					echo -e "Try: ${CYAN}s3st site --help${NC}" >&2
					safe_exit 1
					;;
			esac
		fi
		;;
	redirect)
		CMD="${1:-}"; shift || true
		if [ -n "${BASH_VERSION:-}" ]; then
			declare -a ARGS=()
			case "$CMD" in
				deploy)
					ARGS=()
					if [[ "$GLOBAL_YES" == true ]]; then ARGS+=("--yes"); fi
					if (( ${#ARGS[@]} > 0 )); then
						bash "$S3ST_DIR/deploy-redirect.sh" "${ARGS[@]}" "$@"
					else
						bash "$S3ST_DIR/deploy-redirect.sh" "$@"
					fi
					safe_exit $?
					;;
				remove|rm|cleanup)
					ARGS=()
					if [[ "$GLOBAL_YES" == true ]]; then ARGS+=("--yes"); fi
					if (( ${#ARGS[@]} > 0 )); then
						bash "$S3ST_DIR/remove-redirect.sh" "${ARGS[@]}" "$@"
					else
						bash "$S3ST_DIR/remove-redirect.sh" "$@"
					fi
					safe_exit $?
					;;
				""|-h|--help|help)
					print_header "s3st redirect"
					echo -e "${BOLD}Usage:${NC} s3st redirect <deploy|remove> [args...]"
					echo
					echo -e "${CYAN}Commands:${NC}"
					echo -e "  ${GREEN}deploy${NC}   Deploy redirect infra for multiple source domains"
					echo -e "  ${GREEN}remove${NC}   Remove redirect infra based on the status file"
					print_footer
					safe_exit 0
					;;
				*)
					echo -e "${RED}Unknown redirect command:${NC} $CMD" >&2
					echo -e "Try: ${CYAN}s3st redirect --help${NC}" >&2
					safe_exit 1
					;;
			esac
		else
			# Not bash: fallback to positional passing (no arrays)
			case "$CMD" in
				deploy)
					EXTRA=""
					if [ "$GLOBAL_YES" = true ]; then EXTRA="--yes"; fi
					bash "$S3ST_DIR/deploy-redirect.sh" $EXTRA "$@"
					safe_exit $?
					;;
				remove|rm|cleanup)
					EXTRA=""
					if [ "$GLOBAL_YES" = true ]; then EXTRA="--yes"; fi
					bash "$S3ST_DIR/remove-redirect.sh" $EXTRA "$@"
					safe_exit $?
					;;
				""|-h|--help|help)
					print_header "s3st redirect"
					echo -e "${BOLD}Usage:${NC} s3st redirect <deploy|remove> [args...]"
					echo
					echo -e "${CYAN}Commands:${NC}"
					echo -e "  ${GREEN}deploy${NC}   Deploy redirect infra for multiple source domains"
					echo -e "  ${GREEN}remove${NC}   Remove redirect infra based on the status file"
					print_footer
					safe_exit 0
					;;
				*)
					echo -e "${RED}Unknown redirect command:${NC} $CMD" >&2
					echo -e "Try: ${CYAN}s3st redirect --help${NC}" >&2
					safe_exit 1
					;;
			esac
		fi
		;;
	*)
		echo -e "${RED}Unknown group:${NC} $GROUP" >&2
		show_help
		safe_exit 1
		;;
esac
