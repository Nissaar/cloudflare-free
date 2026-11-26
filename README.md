# cloudflare-free

The **Cloudflare Free plan** as code: a tunnel from a Kubernetes cluster to the internet (no public IP, no open port), DNS records,
**Cloudflare Access** (a one-time-PIN login in front of private apps), an R2 bucket for backups, and an optional failover Worker.
Built with [OpenTofu](https://opentofu.org) (`tofu`, not Terraform) and applied by GitHub Actions with a manual apply step.

> **Use it from a PRIVATE repository of your own, not from a fork** (reasons in [Use it](#use-it), step 2): the saved plan contains the tunnel token and
> CI holds a Cloudflare API token. Community code, not affiliated with Cloudflare. Plan limits change: check Cloudflare's pages.
> `Nissaar` below is the GitHub account that publishes this repository; `<your-...>` is always a value of yours.
> Every variable is listed in [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## What you get for free

| Piece | Defined in | Free allowance |
|---|---|---|
| Tunnel (`tunnel_name`, default `oke-free`) with remotely managed ingress: every name in `cluster_hostnames` goes to `http://traefik.traefik.svc.cluster.local:80`, catch-all `http_status:404` | `infra/tunnel.tf` | Tunnels are free |
| DNS: `<name>.<your-domain>` CNAME to the tunnel, proxied | `infra/tunnel.tf` | Free |
| Access: one application per private name (allow list, one-time PIN, 24 h), a bypass application per public name | `infra/access.tf` | Zero Trust Free: up to 50 users |
| Per-app allow lists and session lengths (variables `APP_ACCESS`, `APP_ACCESS_EMAILS`) | `infra/access.tf`, `infra/locals.tf`, [docs/ACCESS.md](docs/ACCESS.md) | within the 50 users |
| One-time PIN login method (skipped if you already have one: `OTP_IDP_ID`) | `infra/access.tf` | Free |
| Access application `pr-*` and a service token `ci-smoke-tests` for preview environments (`enable_preview_dns`, off by default) | `infra/access.tf`, `infra/tunnel.tf` | Free |
| R2 bucket `backups` (for restic) | `infra/r2.tf` | 10 GB free |
| Optional Worker `failover` that sends a hostname to a standby copy when the main origin fails (`enable_failover`, off by default) | `infra/worker.tf`, `workers/failover/` | Workers Free: 100,000 requests a day |

How it works and the design decisions: [docs/DESIGN.md](docs/DESIGN.md). Adding a name: [docs/HOSTNAMES.md](docs/HOSTNAMES.md).

**What this repository does not manage:** DNS records that already exist (it never imports them or changes their proxy setting; if you add a name that already exists the
apply fails with "record already exists"), zone settings (SSL mode, bot fight mode), the API token, the R2 S3 keys, and the state bucket (made by `scripts/bootstrap.sh`).

## Who it is for

You own a domain on Cloudflare's Free plan and want to publish apps from a cluster (or any HTTP service) **without opening a port**, with a login in
front of the private ones, managed from git. It works on its own (point `cluster_origin` at any internal HTTP address your connector can reach) and is built to
sit in front of the cluster of `oracle-always-free` and `k8s-free-gitops`. It is **not** a firewall product: you decide per name whether it is private or public.

## Accounts, tools and the one thing that can still cost money

- A **Cloudflare account** with a **domain whose DNS is on Cloudflare** (a zone on the Free plan; the zone must be *active*), **R2** switched on (it may ask for a payment method;
  nothing is billed below 10 GB) and **Zero Trust** switched on with the Free plan (team name: anything).
- A **GitHub account** and `gh`, logged in.
- On your laptop: `git`, `gh`, `curl`, `jq`, `python3`, [OpenTofu](https://opentofu.org/docs/intro/install/) 1.12 or newer (CI pins 1.13.9). Install steps: [docs/WHAT-YOU-DO.md](docs/WHAT-YOU-DO.md) step 0.
- Your **account ID** (32 hex characters: dashboard, Account home, the `...` next to the account name, Copy account ID).

**The one thing that can still cost money:** **R2 storage above 10 GB** (the `backups` bucket, once restic writes to it). Cloudflare has no budget feature for these products,
so there is **no spending cap** in this repository: look at the size of `backups` in the dashboard and at **Billing** after the first week. Workers
(only with `enable_failover = true`) are free up to 100,000 requests a day; tunnels, DNS, Universal SSL and Access (up to 50 users) cost nothing.

## Use it

Every command runs on your laptop in the folder of your private copy. Steps marked **verify** were not run by anyone yet.

**1. Prepare the account** (dashboard, once): add your domain and wait until it is *Active*; **R2 Object Storage -> Overview** (accept the free plan); **Zero Trust** (choose a team name,
Free plan); note your account ID. If **Zero Trust -> Integrations -> Identity providers** already lists **One-time PIN**, copy its ID (`OTP_IDP_ID`, step 7): [docs/WHAT-YOU-DO.md](docs/WHAT-YOU-DO.md) steps 1 and 2.

**2. Make your own PRIVATE copy** (clone, then push to a new private repository):

```bash
git clone https://github.com/Nissaar/cloudflare-free.git my-cloudflare-free && cd my-cloudflare-free
git remote rename origin upstream
gh repo create <your-github-user>/<your-private-repo> --private --source . --remote origin --push
git remote -v          # origin = your private copy, upstream = this repository
```

Why private and not a fork: the saved plan files (workflow artifacts) contain the tunnel token and the service token in plain form, pull-request comments show your plan,
and CI holds a Cloudflare API token; a public repository lets strangers read all of it, and a fork of a public repository is always public. Why clone and not "Use this template":
the shared history lets you merge updates later ([Keep it up to date](#keep-it-up-to-date)).

**3. Harden the repository settings now** (web: **Settings**; the commands are **verify**):

```bash
SLUG=<your-github-user>/<your-private-repo>
# Actions: read-only default token; fork pull requests need your approval; Actions may not approve pull requests
gh api -X PUT "repos/$SLUG/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
gh api -X PUT "repos/$SLUG/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors
```

Also in **Settings -> Code security**: secret scanning and push protection (a private repository may need GitHub's paid secret-protection plan; the gitleaks workflow scans every push either way).
**Protect `main`** (pull request and one review, enforced for admins): needs GitHub Pro, Team or Enterprise on a private repository; on the Free plan keep the repository single-owner.
Cloudflare has no keyless login, so **anyone with write access can read the token the plan job holds**: that is why step 5 creates a read-only token for plans.

**4. Create the API tokens** (dashboard, My Profile -> API Tokens -> Create Custom Token; details in [docs/WHAT-YOU-DO.md](docs/WHAT-YOU-DO.md) step 3):
- the **edit token** `cloudflare-free CI`: policy *Zone* (your zone only): Zone Read, DNS Edit, Workers Routes Edit; policy *Account* (your account only): Cloudflare Tunnel Edit, Access Apps and Policies Edit,
  Access Service Tokens Edit, Access Organizations/Identity Providers/Groups Edit, Workers R2 Storage Edit, Workers Scripts Edit;
- the **read-only plan token** `cloudflare-free plan` (recommended, **verify**): the same permissions with **Read** instead of **Edit**.

**5. Check everything before touching anything** (read-only; the token is read from the environment and never printed):

```bash
read -rs CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN                      # paste the EDIT token, Enter
./scripts/preflight.sh <your-account-id> <your-domain> <you@your-domain> <your-github-user>/<your-private-repo>
```

It lists tools, variables, files, the token and the zone (asked from Cloudflare, read-only) and your repository settings as `[ ok ]`, `[warn]` or `[FAIL]`, and ends with `Nothing to fix (...)`
or with what to fix. Run it again after step 7: it then also checks that the Actions variables and secrets exist (names only).

**6. Create the state bucket** (one command; OpenTofu does not manage this bucket so the state never depends on itself):

```bash
./scripts/bootstrap.sh <your-account-id>
```

Expected: `==> Checking the token`, then `==> Bucket tfstate-cloudflare` and `created (location hint weur)`; it prints the R2 state endpoint and is safe to re-run (`LOCATION=eeur ./scripts/bootstrap.sh ...` picks another R2 location hint).

**7. Create the R2 keys for the state and set the repository secrets and variables** (R2 -> Manage API tokens -> Object Read & Write, bucket `tfstate-cloudflare` only; [docs/WHAT-YOU-DO.md](docs/WHAT-YOU-DO.md) steps 5 and 6):

```bash
R=<your-github-user>/<your-private-repo>
gh secret set CLOUDFLARE_API_TOKEN --repo $R          # the EDIT token; paste when asked
gh secret set CLOUDFLARE_API_TOKEN_PLAN --repo $R     # the READ-ONLY token (optional but recommended)
gh secret set R2_ACCESS_KEY_ID --repo $R
gh secret set R2_SECRET_ACCESS_KEY --repo $R
gh variable set CLOUDFLARE_ACCOUNT_ID --repo $R --body <your-account-id>
gh variable set ZONE_NAME --repo $R --body <your-domain>
gh variable set ALLOWED_EMAILS --repo $R --body '["<you@your-domain>"]'     # who may log in; JSON list, double quotes
# gh variable set OTP_IDP_ID --repo $R --body <id>   # only if One-time PIN already exists in Zero Trust -> Integrations -> Identity providers
```

**8. Start the first plan.** GitHub does not start a workflow for the push that creates a repository, so make a small commit under `infra/`:

```bash
sed -i '1i # my private copy' infra/versions.tf && git add infra/versions.tf && git commit -m "chore: first plan" && git push
```

**Actions -> tofu**: the run of your push is your **first plan**. Read it in the run summary (`Plan: N to add, 0 to change, 0 to destroy.`): it should create the tunnel, its configuration,
the `hello` record, the Access applications and policies, the login method, the service token and the `backups` bucket, and must not touch any existing record. If the `plan` job is *skipped*,
the variable `CLOUDFLARE_ACCOUNT_ID` is empty. If it fails with `Missing repository settings`, the message names what is missing.

**9. Apply it yourself:** **Actions -> tofu -> Run workflow -> branch `main` -> type `apply`**. Next: give the tunnel token to the cluster ([docs/WHAT-YOU-DO.md](docs/WHAT-YOU-DO.md) step 9), then add your
own names ([docs/HOSTNAMES.md](docs/HOSTNAMES.md)).

Only want to read a plan on your laptop, without CI? (**verify**)
```bash
cp infra/terraform.tfvars.example infra/terraform.tfvars          # git-ignored; fill in account_id, zone_name, allowed_emails
export AWS_ACCESS_KEY_ID=<R2 key id> AWS_SECRET_ACCESS_KEY=<R2 secret> CLOUDFLARE_API_TOKEN=<token>
tofu -chdir=infra init -backend-config='endpoints={s3="https://<your-account-id>.r2.cloudflarestorage.com"}'
tofu -chdir=infra plan
```

## How the pieces fit with the other three repositories

Order to use them: `oracle-always-free` first (the cluster and the vault), then **this repository** (the domain and the tunnel), then `k8s-free-gitops` (what Flux runs on the cluster). The hand-offs: the tunnel
token this repository outputs goes into the Oracle vault secret `cloudflared-tunnel-token` (the cluster's `cloudflared` reads it); the names in `cluster_hostnames` must match the Ingress hosts in `k8s-free-gitops`
(`<name>.<your-domain>`); the R2 `backups` bucket is where restic backups go. `gcp-always-free` is independent. Recipes: [docs/RECIPES.md](docs/RECIPES.md).

## Keep it up to date

```bash
git fetch upstream
git log --oneline HEAD..upstream/main          # what is new; read docs/CHANGELOG.md
git switch -c update-from-upstream
git merge upstream/main                        # keep YOUR edits (cluster_hostnames, ...)
git push -u origin update-from-upstream        # open a pull request: read the plan comment, merge, then apply
```

Never merge a plan you have not read. `docs/CHANGELOG.md` says when a change needs a manual step.

## Spending caps

There is **no spending cap** for Cloudflare in this repository: Cloudflare has no budget feature for these products, so the guard is what the code creates (almost nothing) and your own checks.

- **R2**: 10 GB of storage is free; above it, storage and operations are billed. Only the `backups` bucket (and the state bucket) exist; watch the size of `backups` in the dashboard.
- **Access**: free up to 50 users. `app_access_emails` is validated to at most 50 addresses per app.
- **Workers** (only with `enable_failover = true`): 100,000 requests a day on the Free plan. Every request to the covered hostnames counts, including each subscription connection.
- Tunnel, DNS and Universal SSL cost nothing. Adding a paid product by hand in the dashboard is your own decision.

## Tear it down

None of this was run by the authors, so treat it as **verify**: disable the `tofu` workflow; empty the `backups` bucket; from your laptop with the same credentials as the last step of "Use it", run
`tofu -chdir=infra init -backend-config='endpoints={s3="https://<your-account-id>.r2.cloudflarestorage.com"}'` and `tofu -chdir=infra destroy`; then delete the state bucket `tfstate-cloudflare`
(made by the bootstrap script, so OpenTofu does not know it), the API tokens and the R2 keys in the dashboard, and the GitHub secrets and variables. The records you made by hand are untouched by all of this.

## Troubleshooting (real problems from building this)

| What you see | Cause and fix |
|---|---|
| `Invalid value for variable "zone_name"` or `Missing repository settings: ZONE_NAME(variable)` | You did not set your domain: the repository variable `ZONE_NAME` (CI) or `zone_name` in `infra/terraform.tfvars`. It has no default and must not be `example.com`. |
| Apply stops with `record already exists` | The hostname you added to `cluster_hostnames` already exists in DNS (made by hand). This repository never takes records over. Rename yours, or delete the old record in the dashboard, then plan again. |
| The data source for the zone finds nothing | The zone is not *Active* in this account yet (nameservers not switched), or the token lacks `Zone: Read` for it. `./scripts/preflight.sh` asks Cloudflare and says which. |
| TLS error on a name like `a.b.<your-domain>` | Universal SSL covers one level only. Use `app.<your-domain>`. The code rejects two-level labels and the reserved prefixes `pr-*` and `*-standby`. |
| The apply fails creating the one-time-PIN login | One-time PIN already exists in your Zero Trust account (Integrations, Identity providers). Copy its ID and set the repository variable `OTP_IDP_ID`. Since mid 2026 a new account may have none: then OpenTofu creates it. |
| "I got no PIN" | By design Access never says whether an address is allowed. Either the address is not on that hostname's list, or the mail is in spam, or a guest's end date passed. See [docs/ACCESS.md](docs/ACCESS.md), "If a PIN never arrives". |
| `tofu init` cannot reach the state | The R2 endpoint contains your account ID and is passed with `-backend-config` at init; the R2 keys travel as `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`. Keys left from another repository (for example Oracle's) in your shell break it: use a fresh terminal. |
| `bootstrap.sh`: token check failed | Wrong token value or scope. Account-owned tokens verify under the account, user tokens under `/user`; the script tries both. Re-check the two policies. |
| The plan fails with a permission error only with the read-only token | Your `CLOUDFLARE_API_TOKEN_PLAN` lacks a Read permission (verify the list in docs/WHAT-YOU-DO.md step 3.7), or a data source needs more than Read. Delete that secret to fall back to the edit token for plans. |
| The Worker loops or the standby never answers | The Worker must reach its own hostname's origin: do **not** add the `global_fetch_strictly_public` compatibility flag. |
| A hostname that should be private answers 200 without a login | Check it is `public = false` in `cluster_hostnames`; a public name gets a bypass application on purpose and the app behind it must do its own login. |
| Wildcard record clash when enabling previews | `enable_preview_dns = true` adds `*.<zone>`. If a `*` record already exists the apply fails: decide which one you keep first. |
| The first push did not start the workflow | Expected: GitHub does not evaluate the path filter for the push that creates the first branch. Step 8 makes a commit that does. |

## Security notes

- **Secret:** `CLOUDFLARE_API_TOKEN` (edit rights on DNS, tunnels, Access, R2, Workers of your zone and account: a leak is serious, rotate it in the dashboard), `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY`, the tunnel
  token (an output of the stack, in the state and in saved plans), the service-token secret `ci_smoke_tests_client_secret`, `*.tfvars` files, and `ALLOWED_EMAILS` / `APP_ACCESS_EMAILS` (personal data; the variables are
  readable by everyone with access to the repository settings). **Not secret:** account ID, zone name, hostnames, tunnel ID.
- **The OpenTofu state contains secrets** (tunnel token, service token). It lives in the private R2 bucket `tfstate-cloudflare` (R2 buckets are private unless you enable public access: do not). Never copy a state file around.
- **Default deny:** a name in `cluster_hostnames` is private (Cloudflare Access login first) unless you write `public = true`; the allow list is `allowed_emails` only (the owner is always on every list);
  `home_access`, `app_access` and failover are empty or off by default.
- **Wildcard previews widen the door:** with `enable_preview_dns = true` the wildcard record sends every unknown name of your zone to the tunnel, and anything your cluster's Traefik routes for such a name is reachable
  **without** a Cloudflare login (only `pr-*` gets the Access application). Leave it off unless you want previews.
- **Tokens in CI:** the plan job of a pull request from a branch of your repository holds the plan token (the edit token if you set no plan token). Anyone with write access can read it: keep write access to yourself.
  Fork pull requests never get secrets. Apply holds the edit token and only runs manually on `main`.
- **Saved plans** (`tfplan-<sha>`, 7 days) and plan comments contain the tunnel token: another reason for a private repository.
- The service token `ci-smoke-tests` lasts 1 year (`8760h`); rotate it with the stack.

Report a vulnerability: [SECURITY.md](SECURITY.md).

## CI safety: pull requests from forks

- The workflows never use `pull_request_target` or `workflow_run`.
- The `plan` job is the only job that sees the API token and the R2 keys on a pull request, and it is skipped unless the pull request's head repository is this repository
  (`.github/workflows/tofu.yml`). Fork pull requests run only formatting, validation, `tofu test`, tflint, trivy and the offline tests, with no credentials.
- Apply is a manual `workflow_dispatch` that only runs on `main`.
- In the repository settings require approval for outside collaborators' workflows and leave secrets off for fork pull requests (see SECURITY.md).

## Checks (the same run in CI)

```bash
tofu fmt -check -recursive
tofu -chdir=infra init -backend=false && tofu -chdir=infra validate && tofu -chdir=infra test
tflint --init && tflint --recursive
trivy config .
(cd workers/failover && node --test)
(cd scripts && python3 -m unittest test_verify_edge)
shellcheck scripts/*.sh
gitleaks detect --redact --no-banner
```

## Layout

```
infra/                 the only OpenTofu stack (state: R2 bucket tfstate-cloudflare)
infra/tests/           tofu test with a mocked provider (offline)
workers/failover/      the optional Worker (src/index.js) + node:test tests
scripts/preflight.sh   read-only checks before the first plan
scripts/bootstrap.sh   creates the state bucket through the Cloudflare API
scripts/verify-edge.py probes that private names end at the Access login (daily workflow access-verify)
docs/                  CONFIGURATION.md (every variable), WHAT-YOU-DO.md (manual steps in order), DESIGN.md, ACCESS.md, HOSTNAMES.md, RECIPES.md, CHANGELOG.md
```

Some files mention a home server, "Authelia", a "ChatOps" assistant and a generator of access lists: optional integrations of the original author's own setup. The defaults here
(`home_access = {}`, `enable_failover = false`, only `hello` in `cluster_hostnames`) switch them off.

## License and contributing

MIT, see [LICENSE](LICENSE). [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md).
