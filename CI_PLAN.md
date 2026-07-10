# Static Site Deployment Plan — S3 / CloudFront via GitHub Actions

## Overview

Push-to-deploy pipeline for a static docroot. Three environments —
`integration`, `stage`, `production` — each with its own S3 bucket and
CloudFront distribution, selected automatically by branch. Auth is via
GitHub OIDC, no long-lived AWS keys stored anywhere.

Branch → environment mapping — branch name and environment name are
always identical (decided; no `main` exception):

| Branch        | Environment   |
| ------------- | ------------- |
| `integration` | integration   |
| `stage`       | stage         |
| `production`  | production    |

> **Status: implemented** by `src/setup-ci.sh` (provisioning + workflow
> generation, with a sha256 tamper check on the generated workflow) and
> `src/remove-ci.sh` (teardown). See the README's "CI: Push-to-Deploy via
> GitHub Actions" section for usage.

## Why GitHub Environments, not just branch conditionals

Rather than branching on `github.ref` inside a single job and picking
secrets with `if:` chains, this plan uses **GitHub Environments**
(Settings → Environments). Each environment gets its own set of
variables and, optionally, its own required reviewers for production.
The workflow job declares `environment: <name>`, and GitHub
auto-selects that environment's vars/secrets — no manual branching
logic needed inside the job for bucket/distribution/role selection.

Environments also let the IAM trust policy scope by **environment**
rather than branch, using the OIDC `sub` claim's
`repo:<org>/<repo>:environment:<name>` form. This is cleaner than
scoping by branch name and survives branch renames.

## 1. AWS setup (one-time, per environment)

For each of `integration`, `stage`, `production`:

1. Confirm the OIDC provider for `token.actions.githubusercontent.com`
   exists on the account (shared across environments, created once).
2. Create one IAM role per environment (e.g. `gha-deploy-integration`,
   `gha-deploy-stage`, `gha-deploy-production`) — keeps blast radius
   contained; a compromised integration deploy can't touch production.
3. Trust policy per role, scoped to that environment only:

	```json
	{
		"Version":   "2012-10-17",
		"Statement": [
			{
				"Effect":    "Allow",
				"Principal": {
					"Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
				},
				"Action":    "sts:AssumeRoleWithWebIdentity",
				"Condition": {
					"StringEquals": {
						"token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
						"token.actions.githubusercontent.com:sub": "repo:<ORG>/<REPO>:environment:<ENV_NAME>"
					}
				}
			}
		]
	}
	```

4. Permissions policy per role, scoped to that environment's bucket
   and distribution only:

	```json
	{
		"Version":   "2012-10-17",
		"Statement": [
			{
				"Sid":      "ListBucket",
				"Effect":   "Allow",
				"Action":   "s3:ListBucket",
				"Resource": "arn:aws:s3:::<ENV_BUCKET_NAME>"
			},
			{
				"Sid":      "ReadWriteObjects",
				"Effect":   "Allow",
				"Action":   ["s3:PutObject", "s3:DeleteObject"],
				"Resource": "arn:aws:s3:::<ENV_BUCKET_NAME>/*"
			},
			{
				"Sid":      "InvalidateDistribution",
				"Effect":   "Allow",
				"Action":   "cloudfront:CreateInvalidation",
				"Resource": "arn:aws:cloudfront::<ACCOUNT_ID>:distribution/<ENV_DISTRIBUTION_ID>"
			}
		]
	}
	```

## 2. GitHub setup

Create three environments under **Settings → Environments**:
`integration`, `stage`, `production`.

For each environment, set these environment-level variables:

| Variable                     | Example (production)                          |
| ----------------------------- | ---------------------------------------------- |
| `AWS_ROLE_ARN`                | `arn:aws:iam::<ACCOUNT_ID>:role/gha-deploy-production` |
| `AWS_REGION`                  | `us-east-1`                                    |
| `S3_BUCKET`                   | `radicalmedia-site-production`                 |
| `CLOUDFRONT_DISTRIBUTION_ID`  | `EABCDEF12345`                                 |

Optionally, add required reviewers on the `production` environment so
a deploy pauses for approval before it runs.

Under **Settings → Environments → \<env\> → Deployment branches**,
restrict each environment to its matching branch (`integration`,
`stage`, or `main`) so a workflow run can only select an environment
its branch is allowed to use — this is what actually enforces the
branch → environment mapping, not the workflow file itself.

## 3. Workflow behavior

1. Trigger on push to any of `integration`, `stage`, `main`, plus
   manual `workflow_dispatch` with an environment picker as a
   fallback.
2. A small step maps `github.ref_name` to an environment name.
3. The deploy job declares `environment: ${{ needs.resolve-env.outputs.env }}`,
   which pulls in that environment's vars automatically.
4. Optional build step, gated behind a `run_build` input, same as
   before — off by default for pure static-file pushes.
5. `configure-aws-credentials` assumes the environment-scoped role.
6. `aws s3 sync --delete` to that environment's bucket.
7. `aws cloudfront create-invalidation --paths "/*"` on that
   environment's distribution.

## 4. Rollback note

`aws s3 sync --delete` is destructive to anything in the bucket not
present in the current docroot. Worth confirming versioning is
enabled on each bucket before this goes live, so a bad deploy can be
recovered by restoring previous object versions rather than needing a
git revert + redeploy cycle.

## Resolved questions

- Branch names: always identical to the environment name, including
  `production` (no `main` exception).
- `production` requires manual approval by default — setup adds the
  invoking GitHub user as a required reviewer; skip with `--no-approval`.
- All environments auto-deploy on push to their branch;
  `workflow_dispatch` with an environment picker exists as a fallback.
- The generated `deploy.yml` is deterministic and its sha256 is recorded
  in the CI status file (`config/.ci-status-<org>-<repo>.json`), so
  `setup-ci.sh --check` detects out-of-band edits in the site repo.
