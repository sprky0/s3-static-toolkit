#!/bin/bash

# list-sites.sh - List known configs (sites, redirects, CI) with statuses
#
# Scans the config directory for status files and renders colored tables:
#   .deploy-status-<domain>.json           -> SITES
#   .deploy-status-redirect-<target>.json  -> REDIRECTS
#   .ci-status-<org>-<repo>.json           -> CI
#
# Status is derived from the *_completed flags / completed_steps recorded by
# the deploy scripts; no AWS calls are made, so this is fast and offline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

show_help() {
	print_header "s3st list"
	echo -e "${BOLD}Usage:${NC} s3st list"
	echo
	echo -e "Lists every known config in the config directory with its status:"
	echo -e "  ${GREEN}SITES${NC}      static site stacks   ${DIM}(.deploy-status-<domain>.json)${NC}"
	echo -e "  ${GREEN}REDIRECTS${NC}  redirect stacks      ${DIM}(.deploy-status-redirect-<target>.json)${NC}"
	echo -e "  ${GREEN}CI${NC}         GitHub Actions CI    ${DIM}(.ci-status-<org>-<repo>.json)${NC}"
	echo
	echo -e "Reads only local status files — no AWS calls are made."
	echo -e "Set ${CYAN}S3ST_CONFIG_DIR${NC} to override the config directory."
	print_footer
}

case "${1:-}" in
	-h|--help|help)
		show_help
		exit 0
		;;
	"")
		;;
	*)
		echo -e "${RED}Unknown argument:${NC} $1" >&2
		show_help
		exit 1
		;;
esac

if ! command -v jq >/dev/null 2>&1; then
	log_error "jq is required but not installed"
	exit 1
fi

CONFIG_DIR="$(config_dir)" || exit 1

# Field separator used inside table rows (never appears in the data)
US=$'\x1f'

# Sites deploy in 7 core steps; redirects in 7 (see deploy-*.sh)
SITE_TOTAL_STEPS=7
REDIRECT_TOTAL_STEPS=7

# pad TEXT WIDTH - print TEXT padded with spaces to WIDTH (plain length).
# Colors are applied around the padded text by callers so ANSI codes never
# skew the column math.
pad() {
	local text="$1" width="$2"
	local len=${#text}
	printf '%s' "$text"
	if [ "$len" -lt "$width" ]; then
		printf '%*s' $((width - len)) ""
	fi
}

# max VAR_NAME VALUE - grow the width variable if VALUE's length exceeds it
max() {
	local var="$1" val="$2"
	if [ "${#val}" -gt "$(eval echo "\$$var")" ]; then
		eval "$var=${#val}"
	fi
}

#───────────────────────────────────────────────────────────────────────────────
# Collect rows
#───────────────────────────────────────────────────────────────────────────────

SITE_ROWS=()
REDIRECT_ROWS=()
CI_ROWS=()
CI_DOMAIN_TAGS=""	# newline-separated "<domain>${US}<env>" from CI configs
SKIPPED=0

# CI configs first so site rows can be tagged with their CI environment
for f in "$CONFIG_DIR"/.ci-status-*.json; do
	[ -e "$f" ] || continue
	if ! row=$(jq -r '
		. as $root
		| ((.environments // "") | split(",") | map(select(. != ""))) as $envs
		| [
			(.repo_slug // "?"),
			(if (.workflow_completed == "true")
				and (($envs | length) > 0)
				and ($envs | all(. as $e
					| ($root["role_" + $e + "_completed"] == "true")
					and ($root["gh_env_" + $e + "_completed"] == "true")))
			 then "ready" else "partial" end),
			($envs | map(. as $e | $e + "=" + ($root["env_" + $e + "_domain"] // "?")) | join("  ")),
			(.account_id // "-"),
			((.created_at // "") | .[0:10])
		  ] | join("")
	' "$f" 2>/dev/null); then
		log_warn "Skipping unparseable status file: $f"
		SKIPPED=$((SKIPPED + 1))
		continue
	fi
	CI_ROWS+=("$row")
	tags=$(jq -r '
		to_entries[]
		| select(.key | test("^env_.+_domain$"))
		| .value + "" + (.key | sub("^env_"; "") | sub("_domain$"; ""))
	' "$f" 2>/dev/null || true)
	if [ -n "$tags" ]; then
		CI_DOMAIN_TAGS="${CI_DOMAIN_TAGS}${tags}
"
	fi
done

# ci_envs_for_domain DOMAIN - print comma-joined "ci:<env>" tags for DOMAIN
ci_envs_for_domain() {
	local domain="$1" out="" d env
	[ -n "$CI_DOMAIN_TAGS" ] || return 0
	while IFS="$US" read -r d env; do
		if [ "$d" = "$domain" ] && [ -n "$env" ]; then
			out="${out:+$out,}ci:$env"
		fi
	done <<< "$CI_DOMAIN_TAGS"
	printf '%s' "$out"
}

for f in "$CONFIG_DIR"/.deploy-status-*.json; do
	[ -e "$f" ] || continue
	base="$(basename "$f")"
	case "$base" in
		.deploy-status-redirect-*)
			if ! row=$(jq -r '
				[
					((.domains // ((.source_domains // "") | split(","))) | map(select(. != "")) | join(", ")),
					(.target_domain // "?"),
					(if ((.completed_steps // []) | index("verify_deployment")) then "live" else "partial" end),
					(((.completed_steps // []) | length) | tostring),
					(.cloudfront_distribution_id // "-"),
					(.account_id // "-"),
					((.timestamp // .created_at // "") | .[0:10])
				] | join("")
			' "$f" 2>/dev/null); then
				log_warn "Skipping unparseable status file: $f"
				SKIPPED=$((SKIPPED + 1))
				continue
			fi
			REDIRECT_ROWS+=("$row")
			;;
		*)
			if ! row=$(jq -r '
				def flag($s): if .[$s + "_completed"] == "true" then 1 else 0 end;
				[
					(.domain // "?"),
					(if .cloudfront_completed == "true" and .dns_completed == "true" then "live" else "partial" end),
					([flag("hosted_zone"), flag("s3_bucket"), flag("certificate"), flag("oac"),
					  flag("cloudfront"), flag("content"), flag("dns")] | add | tostring),
					(.distribution_id // "-"),
					(.bucket_name // "-"),
					(.account_id // "-"),
					((.created_at // "") | .[0:10]),
					([
						(if .imported == "true" then "imported" else empty end),
						(if .cf_function_completed == "true" then "basic-auth" else empty end)
					] | join(","))
				] | join("")
			' "$f" 2>/dev/null); then
				log_warn "Skipping unparseable status file: $f"
				SKIPPED=$((SKIPPED + 1))
				continue
			fi
			# Append CI tags (ci:<env>) to the notes column
			domain="${row%%$US*}"
			ci_tags="$(ci_envs_for_domain "$domain")"
			if [ -n "$ci_tags" ]; then
				notes="${row##*$US}"
				row="${row%$US*}$US${notes:+$notes,}$ci_tags"
			fi
			SITE_ROWS+=("$row")
			;;
	esac
done

#───────────────────────────────────────────────────────────────────────────────
# Render
#───────────────────────────────────────────────────────────────────────────────

print_header "s3st configs ${DIM}${CONFIG_DIR}${NC}"

# ── Sites ─────────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${CYAN}SITES${NC} ${DIM}(${#SITE_ROWS[@]})${NC}"
if [ "${#SITE_ROWS[@]}" -eq 0 ]; then
	echo -e "  ${DIM}(none)${NC}"
else
	w_dom=6; w_status=6; w_cdn=12; w_bucket=6; w_acct=7; w_date=7
	for row in "${SITE_ROWS[@]}"; do
		IFS="$US" read -r dom state steps cdn bucket acct date notes <<< "$row"
		max w_dom "$dom"
		if [ "$state" = "live" ]; then max w_status "● live"; else max w_status "◐ ${steps}/${SITE_TOTAL_STEPS}"; fi
		max w_cdn "$cdn"; max w_bucket "$bucket"; max w_acct "$acct"; max w_date "${date:--}"
	done
	echo -e "  ${BOLD}$(pad "DOMAIN" "$w_dom")  $(pad "STATUS" "$w_status")  $(pad "DISTRIBUTION" "$w_cdn")  $(pad "BUCKET" "$w_bucket")  $(pad "ACCOUNT" "$w_acct")  $(pad "CREATED" "$w_date")  NOTES${NC}"
	for row in "${SITE_ROWS[@]}"; do
		IFS="$US" read -r dom state steps cdn bucket acct date notes <<< "$row"
		if [ "$state" = "live" ]; then
			status_txt="● live"; status_col="$GREEN"
		else
			status_txt="◐ ${steps}/${SITE_TOTAL_STEPS}"; status_col="$YELLOW"
		fi
		echo -e "  ${GREEN}$(pad "$dom" "$w_dom")${NC}  ${status_col}$(pad "$status_txt" "$w_status")${NC}  ${DIM}$(pad "$cdn" "$w_cdn")${NC}  $(pad "$bucket" "$w_bucket")  ${DIM}$(pad "$acct" "$w_acct")${NC}  ${DIM}$(pad "${date:--}" "$w_date")${NC}  ${MAGENTA}${notes}${NC}"
	done
fi

# ── Redirects ─────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${CYAN}REDIRECTS${NC} ${DIM}(${#REDIRECT_ROWS[@]})${NC}"
if [ "${#REDIRECT_ROWS[@]}" -eq 0 ]; then
	echo -e "  ${DIM}(none)${NC}"
else
	w_redir=8; w_status=6; w_cdn=12; w_acct=7; w_date=7
	for row in "${REDIRECT_ROWS[@]}"; do
		IFS="$US" read -r sources target state steps cdn acct date <<< "$row"
		max w_redir "$sources → $target"
		if [ "$state" = "live" ]; then max w_status "● live"; else max w_status "◐ ${steps}/${REDIRECT_TOTAL_STEPS}"; fi
		max w_cdn "$cdn"; max w_acct "$acct"; max w_date "${date:--}"
	done
	echo -e "  ${BOLD}$(pad "REDIRECT" "$w_redir")  $(pad "STATUS" "$w_status")  $(pad "DISTRIBUTION" "$w_cdn")  $(pad "ACCOUNT" "$w_acct")  CREATED${NC}"
	for row in "${REDIRECT_ROWS[@]}"; do
		IFS="$US" read -r sources target state steps cdn acct date <<< "$row"
		if [ "$state" = "live" ]; then
			status_txt="● live"; status_col="$GREEN"
		else
			status_txt="◐ ${steps}/${REDIRECT_TOTAL_STEPS}"; status_col="$YELLOW"
		fi
		echo -e "  ${GREEN}$(pad "$sources → $target" "$w_redir")${NC}  ${status_col}$(pad "$status_txt" "$w_status")${NC}  ${DIM}$(pad "$cdn" "$w_cdn")${NC}  ${DIM}$(pad "$acct" "$w_acct")${NC}  ${DIM}${date:--}${NC}"
	done
fi

# ── CI ────────────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${CYAN}CI${NC} ${DIM}(${#CI_ROWS[@]})${NC}"
if [ "${#CI_ROWS[@]}" -eq 0 ]; then
	echo -e "  ${DIM}(none)${NC}"
else
	w_repo=4; w_status=7; w_envs=12; w_acct=7
	for row in "${CI_ROWS[@]}"; do
		IFS="$US" read -r repo state envs acct date <<< "$row"
		max w_repo "$repo"
		if [ "$state" = "ready" ]; then max w_status "● ready"; else max w_status "◐ partial"; fi
		max w_envs "${envs:--}"; max w_acct "$acct"
	done
	echo -e "  ${BOLD}$(pad "REPO" "$w_repo")  $(pad "STATUS" "$w_status")  $(pad "ENVIRONMENTS" "$w_envs")  $(pad "ACCOUNT" "$w_acct")  CREATED${NC}"
	for row in "${CI_ROWS[@]}"; do
		IFS="$US" read -r repo state envs acct date <<< "$row"
		if [ "$state" = "ready" ]; then
			status_txt="● ready"; status_col="$GREEN"
		else
			status_txt="◐ partial"; status_col="$YELLOW"
		fi
		echo -e "  ${GREEN}$(pad "$repo" "$w_repo")${NC}  ${status_col}$(pad "$status_txt" "$w_status")${NC}  $(pad "${envs:--}" "$w_envs")  ${DIM}$(pad "$acct" "$w_acct")${NC}  ${DIM}${date:--}${NC}"
	done
fi

echo
summary="${#SITE_ROWS[@]} site(s) · ${#REDIRECT_ROWS[@]} redirect(s) · ${#CI_ROWS[@]} CI config(s)"
if [ "$SKIPPED" -gt 0 ]; then
	summary="$summary · ${YELLOW}${SKIPPED} skipped${NC}"
fi
echo -e "${DIM}${summary}${NC}"
print_footer
