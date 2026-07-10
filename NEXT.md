# NEXT.md — what's missing, broken, or sloppy

Audit of the toolkit as of `main` @ e26457a. Grouped by severity, with file:line
references so you can jump straight to the offending code.

---

## ✅ Progress (last updated 2026-05-08)

**Completed**
- **1.1** ACM cert pinned to us-east-1 in `deploy-redirect.sh` and `remove-redirect.sh` — `a6084ca`
- **1.2** Missing `$MAGENTA`/`$CYAN` colors — fixed by adopting `lib/common.sh` everywhere — *working tree*
- **1.3** Orphan ACM validation CNAMEs — `remove_validation_records()` re-queries ACM and prunes Route53 — `a6084ca`
- **1.4** Dead plural-key lookups in `remove-site.sh` — singular-only schema — `a6084ca`
- **1.5** Multi-part TLD root extraction + subdomain-under-parent-zone provisioning — shared `find_zone_for_domain()` in `lib/common.sh` — *working tree*
- **1.6** Duplicate `usage()` and default-vars block in `remove-site.sh` — deduped — `a6084ca`
- **2.7 / 3.1** `lib/colors.sh` + `lib/common.sh` adopted by all 6 scripts; ~330 LOC of duplicated `log()`+colors removed — *working tree*
- **3.2** ~285 lines of commented-out v1 implementations in `deploy-site.sh` — deleted — *working tree*
- **3.6** Leaked status JSONs — audit was wrong; `git ls-files` confirms they were never committed (`.gitignore` was doing its job). No-op.

**Beyond original audit — security hardening (`a6084ca`)**
- Live cleanup plan in both remove scripts: per-resource AWS metadata (CF aliases, cert SANs, R53 record names+targets, bucket region) printed before any destructive call.
- Bold-red `[ DELETE ]` / `[ DISABLE ]` / `[ EMPTY ]` pills via `destruct()` (now in `lib/common.sh`).
- Typed-`yes` confirmation (not single-letter); `--yes` still bypasses for unattended runs.
- `account_id` written by `deploy-redirect.sh` (`deploy-site.sh` already did); `resolve_account_id()` aborts hard if status-file account ≠ current caller.
- All S3 ops (`head-bucket`, `get-bucket-location`, `delete-bucket-website`, `delete-bucket`) pass `--expected-bucket-owner $ACCOUNT_ID`. Smoke-tested: a globally-namespaced bucket I didn't own correctly resolved to "skip — not owned."
- Renamed `remove_cloudfront_distributions` / `remove_s3_buckets` → singular to match new bodies.

**Not in original audit — flagged but not fixed**
- `lib/common.sh` retains `default_site_status_file` / `default_redirect_status_file` / `ensure_state_dir` (under `~/.s3-static-toolkit/`) — still unused by the actual scripts. See 2.8.
- `lib/common.sh` retains a `confirm()` (single-letter y/N) that nothing calls anymore.
- Profile flag inconsistency: `$AWS_PROFILE` (site scripts) vs `$PROFILE` (redirect/sync). Not a bug, but worth a normalize pass.
- `remove-site.sh:remove_origin_access_controls` — name still plural; body is singular (cosmetic).

---

## 1. Real bugs

### 1.1 `deploy-redirect.sh` puts the ACM cert in the wrong region when `--region` is non-default
> ✅ **DONE** — `a6084ca`. Pinned to `us-east-1` in deploy and remove sides.

- `deploy-redirect.sh:404-410` requests the certificate with `--region "$REGION"`.
- CloudFront only accepts certs from `us-east-1`. If a user passes `--region us-west-2`,
  the cert is created in us-west-2 and the distribution will fail to attach it.
- Compare to `deploy-site.sh:316` which correctly hardcodes `cert_region="us-east-1"`.
- **Fix:** mirror `deploy-site.sh` and force `cert_region=us-east-1` regardless of `$REGION`.

### 1.2 Three scripts reference `$MAGENTA` and `$CYAN` without defining them
> ✅ **DONE** — fixed by adopting `lib/common.sh` (working tree). All 6 scripts source the lib for colors+log now.

- `deploy-redirect.sh:46,49`, `remove-redirect.sh:44,47`, `sync.sh:38,41` use these in
  the `STEP`/`DEBUG` log branches but only declare RED/GREEN/YELLOW/BLUE/BOLD/NC.
- Result: STEP and DEBUG log lines render with no color and a literal trailing `[STEP]`/`[DEBUG]` tag — cosmetic only,
  but it betrays that those branches were never exercised.
- **Fix:** add the missing color vars, or (better) delete the duplicated `log()` and source `lib/colors.sh` + `lib/common.sh`
  (see #3.1).

### 1.3 `remove-site.sh` does not delete ACM validation CNAMEs
> ✅ **DONE** — `a6084ca`. New `remove_validation_records()` re-queries ACM (validation records aren't persisted to status by `deploy-site.sh`) and prunes Route53 only when name+type+value match. Runs before `remove_certificate`.

- `remove-site.sh:264-298` deletes the certificate but leaves the `_<random>.<domain>` CNAMEs in Route53.
- `remove-redirect.sh:389-466` does this correctly (`delete_validation_records()`).
- **Fix:** port `delete_validation_records()` into `remove-site.sh` and call it before
  `remove_certificate`.

### 1.4 `remove-site.sh` reads schema keys that the deploy script never writes
> ✅ **DONE** — `a6084ca`. Plural lookups removed; singular schema is now the single source of truth.

- `remove-site.sh:150,313,374,398` reads `.distributions`, `.buckets`, `.zones`, `.domains_array`
  (plural) — but `deploy-site.sh` only ever writes `.distribution_id`, `.bucket_name`, `.zone_id`,
  `.domain` (singular). The "primary" lookups are dead and the script always takes the fallback
  path. Fine in practice but wildly confusing to anyone debugging it.
- **Fix:** remove the dead plural lookups, OR commit to the plural shape and migrate the deploy
  script.

### 1.5 `deploy-redirect.sh` root-domain extraction breaks on multi-part TLDs
> ✅ **DONE** — *working tree*. New `find_zone_for_domain()` in `lib/common.sh` walks suffixes longest-to-shortest. Both `deploy-site.sh:check_hosted_zone` and `deploy-redirect.sh:check_hosted_zones` now use it, so subdomain provisioning (e.g. `blog.example.com` under an `example.com` zone) works without a separate zone, and `.co.uk`-style TLDs no longer abort.

- `deploy-redirect.sh:294-301` splits on `.` and takes the last two labels as the "root."
- `foo.example.co.uk` → `co.uk`, which has no hosted zone, so the script aborts.
- **Fix:** look up the hosted zone by walking suffixes from longest to shortest, or use
  `route53 list-hosted-zones-by-name` and pick the longest zone name that is a suffix of the
  domain.

### 1.6 `remove-site.sh` defines `usage()` and the default-vars block twice
> ✅ **DONE** — `a6084ca`. Second definition deleted.

- `remove-site.sh:22-38` and again at `remove-site.sh:69-82`. The second definition shadows
  the first and drops the `--domain` doc line. Pure copy/paste residue.
- **Fix:** delete the second block.

---

## 2. Functional gaps (features missing from a "complete" v1)

### 2.1 No `www.` subdomain support in `deploy-site.sh`
- The script wires up the apex only. There is a stub comment at line 978 (`Quantity: 2`) hinting
  this was started and abandoned.
- For most real sites you want `www.example.com` redirecting (or aliasing) to the apex. Today the
  user has to bolt this on manually with `deploy-redirect.sh`.

### 2.2 No "directory index" rewriting on CloudFront
- With OAC + the S3 REST endpoint (which is what we use), `https://site.com/about/` does **not**
  return `/about/index.html` — it 404s. This is the standard CF + OAC gotcha.
- Fix needs a CloudFront Function (~10 lines of JS) for the viewer-request event that rewrites
  paths ending in `/` to `/index.html`. Without it, anything beyond a single-page index is broken.

### 2.3 Custom error pages only handle 404
- `deploy-site.sh:633-641` only configures a 404 response. With OAC + REST endpoint, S3 returns
  **403** for missing keys, not 404, unless we also map 403 → `/error.html`.
- Either add a 403 mapping, or fix the access pattern so 404 actually fires.

### 2.4 SPA routing is not supported
- Related to 2.2/2.3 — for SPAs you typically rewrite all 403/404 to `/index.html` with a 200
  status. There is no flag to opt into this.

### 2.5 No resource tagging
- Nothing tags the bucket, distribution, or cert with the domain or a project label. Cost
  attribution and `terraform import`-style adoption later become guesswork.

### 2.6 Idempotency-by-status-file only
- If the status JSON is lost, re-running the deploy script will create a duplicate ACM cert and
  may try to create a second CloudFront distribution with the same alias (which AWS will reject,
  but only after creating a new cert). The `create_oac` and `create_cloudfront_distribution`
  paths got "look up by name/alias" recovery added; `create_certificate` did not.

### 2.7 `lib/common.sh` and `lib/colors.sh` are dead code
> ✅ **DONE** — working tree. All 6 scripts now source `lib/common.sh`. Lib gained a `log "LEVEL" "msg"` dispatcher (no call-site rewrite needed), `destruct()`, `BG_RED`, `WHITE`, `log_step`, `log_debug`. `set -euo pipefail` removed from the lib (was being silently propagated). Lib's `default_*_status_file` / `ensure_state_dir` / `confirm()` are still unused — see flagged-but-not-fixed at the top.

- Only `s3st.sh` sources them. Every other script (`deploy-site.sh`, `deploy-redirect.sh`,
  `remove-*.sh`, `sync.sh`, `login.sh`) has its own inlined `log()` and color block.
- The lib also defines `default_site_status_file` / `default_redirect_status_file` /
  `ensure_state_dir` (placing state under `~/.s3-static-toolkit/`) that **nothing uses** —
  the deploy/remove/sync scripts still default to `.deploy-status-<domain>.json` in CWD.
- Pick one path: either commit to `lib/` and refactor the rest, or delete `lib/`.

### 2.8 Deploy/sync/remove status-file conventions are inconsistent
- `deploy-site.sh` defaults to `.deploy-status-<domain>.json` in CWD.
- `deploy-redirect.sh` defaults to `~/.aws-redirect-status.json` (single global file — overwritten
  on every redirect deploy! see 1.x candidate).
- `lib/common.sh` proposes `~/.s3-static-toolkit/site-<domain>.json`.
- All three should agree.

### 2.9 `deploy-redirect.sh` default status file collides across runs
- `STATUS_FILE="$HOME/.aws-redirect-status.json"` (line 16). Run it twice for two different
  target domains and the second run silently corrupts the first's record.
- **Fix:** include `$TARGET_DOMAIN` in the default path.

### 2.10 Redirect bucket name is timestamp-only
- `deploy-redirect.sh:348-349`: `redirect-${timestamp}`. Globally namespaced. Two near-simultaneous
  runs can collide; also makes the bucket invisible to humans.
- **Fix:** include the target domain or at least an account-scoped slug.

### 2.11 No www / apex aware DNS for redirect either
- Redirect script creates an A-ALIAS only for the source domain literal. If user passes
  `example.com` they don't get `www.example.com` covered (and vice versa).

### 2.12 No `--profile` propagation in `s3st.sh`
- The runner forwards positional args through but doesn't preserve a `S3ST_PROFILE` env var
  or default profile. Minor — but a multi-account user has to retype `--profile X` every time.

---

## 3. Sloppy / inconsistent / dead code

### 3.1 Massive duplication of the `log()` + color-vars block
> ✅ **DONE** — working tree. Bundled with 2.7. ~330 LOC removed across 6 scripts.

- Six scripts each carry their own copy. Already covered in 2.7 — flagged separately because
  it is the single largest cleanup win.

### 3.2 Commented-out v1 implementations left in `deploy-site.sh`
> ✅ **DONE** — working tree. 285 lines deleted from three blocks. File: 1431 → 1146 lines.

- ~300 lines of commented-out `create_oac`, `create_cloudfront_distribution`, `create_dns_records`
  bodies remain inline (lines ~406-448, 546-699, 958-1007). Git history exists; delete them.

### 3.3 README still has a "do not use this yet" warning at the top
- `README.md:1-14`. If this is closer to ready, drop the WARNING block or move it to a
  "Stability" section so the rest of the README isn't drowned by it.

### 3.4 README @todo
- `README.md:13` — "@todo standardize output style of help messages and instructions etc".
  Partly addressed by `s3st.sh` using `print_header`/`print_footer`, but the underlying scripts
  don't.

### 3.5 `deploy-site.sh` has a "or like this maybe? how is this" comment
- Line 276. Friendly, but probably want to resolve and remove before calling v1.

### 3.6 `git ls-files` shows `src/wurmanprelude-com.json` and `src/.deploy-status-thisisagardeningshow.com.json` are committed
> ✅ **NO-OP** — audit was wrong. `git ls-files` and `git log --all --full-history` both show these were never committed; `.gitignore` (`src/*.json`) was already excluding them. They exist locally only.

- `.gitignore` has `src/*.json` but the files predate the rule. They contain real AWS account IDs,
  zone IDs, certificate ARNs, and CloudFront distribution IDs. Not credentials, but you usually
  don't want this in a public repo.
- **Fix:** `git rm --cached src/wurmanprelude-com.json src/.deploy-status-thisisagardeningshow.com.json`
  and commit. Keep .gitignore as-is.

### 3.7 `deploy-redirect.sh` `parse_domains()` builds JSON manually with string concat
- Lines 245-252. Works, but `printf '%s\n' ... | jq -R . | jq -s .` (which the same script uses
  later at line 401) is robust and readable.

### 3.8 `check_hosted_zones()` JSON-builder uses `${#domains_json}` arithmetic
- `deploy-redirect.sh:311`. Functions but is brittle and unobvious. Replace with the same
  `jq -R . | jq -s .` idiom or accumulate into a bash array and emit at the end.

---

## 4. Operational / safety

### 4.1 No documented IAM policy
- README lists `aws cli` and `jq` as prereqs but never says what permissions the caller needs.
  Minimum policy spans: `s3:*` on the target bucket, `cloudfront:*`, `acm:RequestCertificate`/
  `DescribeCertificate`/`DeleteCertificate`, `route53:ChangeResourceRecordSets` and List, and
  `sts:GetCallerIdentity`. Document this — bonus points for a sample minimal policy JSON in the
  repo.

### 4.2 `set -e` + `$?` checks
- Multiple scripts do `cmd; if [ $? -ne 0 ]; then ...; fi` while `set -e` is active. Under
  `set -e` the `if` block never fires because the script already exited. Either drop `set -e`
  or drop the `$?` checks. Examples: `deploy-site.sh:264`, `deploy-site.sh:386`,
  `deploy-site.sh:1057`, etc.

### 4.3 Cleanup order in `remove-site.sh` doesn't await CloudFront full deletion
- It disables and waits for the disable to deploy (good), then deletes (good), but it does **not**
  wait for the delete to complete before tearing down the cert. ACM will refuse to delete a cert
  still in use by a CF distribution that's mid-deletion, so cleanup can fail mid-flight and leave
  orphans.

### 4.4 No dry-run on the deploy/remove paths
- `sync.sh` has `--dry-run`; nothing else does. A `--plan` mode that prints the AWS calls without
  executing would be a huge confidence boost given v1's "don't use this yet" framing.

### 4.5 No retry/backoff on Route53 changes
- A few `route53 change-resource-record-sets` calls can fail transiently with throttling. No
  backoff anywhere.

---

## 5. Documentation

### 5.1 No CLAUDE.md or AGENTS.md
- For an automation-friendly toolkit this is low-cost and high-value.

### 5.2 No examples for sync's `--exclude`, `--gzip`, or paths arguments
- README mentions them but doesn't show real-world invocations.

### 5.3 No troubleshooting section
- Common foot-guns (DNS not propagating, cert validation stuck, distribution still deploying)
  all happen in the field; users will benefit from a "if you see X, do Y" page.

### 5.4 README claims `host` is required but `login.sh` and `s3st.sh` don't check it
- Only `deploy-site.sh` and `deploy-redirect.sh` check for `host`. Minor.

---

## 6. Strategic / v2 questions

These are not bugs — just decisions worth making before piling on more features.

### 6.1 The README itself raises this: should v2 be Terraform / CloudFormation / CDK?
- The bash scripts are now ~1500 lines and growing. A 60-line Terraform module would express
  the same intent with state management, drift detection, and `plan` for free. The "status JSON"
  files are essentially a hand-rolled Terraform state.
- Counter: bash is portable and grok-able. If the toolkit's audience is "I want one script, no
  toolchain," bash wins.
- Decide before adding www, SPA, and per-feature flags — those are cheap in Terraform and
  expensive here.

### 6.2 Should the redirect bucket use a per-domain bucket name, or one bucket with multiple
distributions?
- Today: one redirect → one bucket → one distribution → N source domains (all 301'd to the same
  target). Fine.
- If the use case grows to multiple redirect targets, the current single-status-file design
  collapses. See 2.9.

### 6.3 Zero observability story
- No CloudWatch alarms, no log retention defaults, no access logging on the distribution.
  Fine for v1 ("here's your site!"); needs a story for v2.

---

## Suggested triage order

If we're trying to call this v1-ready without v2-style rewrites:

1. ✅ Fix the cert region bug (1.1)
2. ✅ Fix the validation-CNAME orphan (1.3)
3. ✅ Fix the schema-mismatch dead code in remove-site.sh (1.4, 1.6)
4. **Add `www` and directory-index handling (2.1, 2.2)** — without these, "static site" over-promises.
5. ✅ De-duplicate `log()` and adopt `lib/` everywhere (2.7, 3.1, 3.2)
6. ✅ Untrack the leaked status JSONs (3.6) — non-issue; never committed
7. **Document IAM and update the README warning (3.3, 4.1, 5.1, 5.2, 5.3)**

Then revisit 6.1 before committing to v2.

### Recommended next batch (after current testing)

Quick wins:
- **1.5** Multi-part TLD root extraction in `deploy-redirect.sh` — single function fix.
- **3.5** Remove "or like this maybe? how is this" comment at `deploy-site.sh:276`.
- **3.7 / 3.8** Replace brittle JSON-by-string-concat in `deploy-redirect.sh` with the `jq -R . | jq -s .` idiom.
- **2.9 / 2.10** Per-domain status-file path and per-domain redirect bucket name (status file collision + bucket name collision).

Bigger:
- **2.1 + 2.2** `www` apex/subdomain handling and CloudFront-Function `/about/` → `/about/index.html` rewrite. These two are what make "static site" actually mean static site.
- **4.2** `set -e` + `$?` checks (multiple scripts) — these never fire and mask errors. Audit when adopting `set -o pipefail`.
- **4.3** Cleanup ordering in `remove-site.sh` doesn't await CloudFront full deletion before cert delete (race-y).
- **2.8** Status-file path convention (CWD vs `~/.aws-redirect-status.json` vs lib's proposed `~/.s3-static-toolkit/`). Lib has scaffolding (`default_*_status_file`) waiting to be adopted.
- **5.1 / 5.3 / 4.1** README + IAM doc + troubleshooting.
