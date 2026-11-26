# Configuration: every variable of this repository

Everything that is yours (account, domain, e-mail) or a matter of taste (hostnames, switches) is a variable. Nothing of the original author is
left in the defaults: **required** variables have no default and fail with a message that says what is wrong. `./scripts/preflight.sh` checks
them (read-only) before you start. Examples use placeholders only: `<your-...>`.

Where a value is set:

| Where | How |
|---|---|
| **tfvars** | `infra/terraform.tfvars` (git-ignored; `infra/terraform.tfvars.example` shows the format): only for running OpenTofu from your laptop |
| **Actions variable / secret** | GitHub: repository **Settings -> Secrets and variables -> Actions**; CI passes them to OpenTofu as `TF_VAR_*` |
| **env** | exported in your shell for a script (`LOCATION=eeur ./scripts/bootstrap.sh ...`) |
| **code default** | the `default` in `infra/variables.tf`; change it in a pull request, read the plan, merge, apply (this is how you add hostnames) |

## 1. What you MUST set (nothing else is needed for a first plan)

| Name | Meaning | Set in | Example |
|---|---|---|---|
| account ID | Cloudflare account (32 hex characters) | Actions variable `CLOUDFLARE_ACCOUNT_ID`; argument of `scripts/bootstrap.sh`; `account_id` in tfvars | `<your-account-id>` |
| domain | YOUR zone, active in that account; every hostname is `<name>.<domain>` | Actions variable `ZONE_NAME`; `zone_name` in tfvars | `<your-domain>` (for example `mydomain.org`) |
| owner e-mail(s) | the people who may pass the login of a private hostname (JSON list in CI) | Actions variable `ALLOWED_EMAILS`; `allowed_emails` in tfvars | `["<you@your-domain>"]` |
| API token | edit rights on your zone and account | Actions **secret** `CLOUDFLARE_API_TOKEN`; env for `bootstrap.sh` | created in the dashboard (docs/WHAT-YOU-DO.md step 3) |
| R2 keys for the state | S3 keys limited to the bucket `tfstate-cloudflare` | Actions **secrets** `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | created in the dashboard (step 5) |

## 2. OpenTofu variables (`infra/variables.tf`)

| Variable | Meaning | Default | Required | Validation / note |
|---|---|---|---|---|
| `account_id` | Cloudflare account ID | none | yes | 32 hex characters |
| `zone_name` | your domain | none | yes | a domain name; `example.com` is refused |
| `allowed_emails` (sensitive) | owner list: always allowed on every private hostname | none | yes | non-empty list of addresses, no wildcard, no `<placeholder>` |
| `otp_idp_id` | ID of an existing One-time PIN login method; empty = OpenTofu creates one | empty | no | set only if One-time PIN already exists in Zero Trust |
| `tunnel_name` | name of the tunnel (changing it later makes a new tunnel and a new token) | `oke-free` | no | letters, digits, `.-_` |
| `r2_location` | location hint of the `backups` bucket; **changing it later replaces the bucket** | `weur` | no | `wnam`, `enam`, `weur`, `eeur`, `apac`, `oc`; Actions variable `R2_LOCATION` |
| `cluster_hostnames` | names served by the cluster through the tunnel: `label = { public = false }` (Access login) or `true` (no Cloudflare login) | `{ hello = { public = false } }` | no | single DNS label; `pr-*` and `*-standby` are reserved. **Edit the default in a pull request** |
| `cluster_origin` | where `cloudflared` sends every hostname | `http://traefik.traefik.svc.cluster.local:80` | no | `http(s)://host[:port]` |
| `service_token_hostnames` | private labels the `ci-smoke-tests` service token may also open | `["hello"]` | no | |
| `enable_preview_dns` | wildcard `*.<zone>` to the tunnel for `pr-<n>` previews; **widens the door, see README** | `false` | no | fails if a `*` record exists |
| `enable_failover` | deploy the failover Worker for the `ntfy` label (and `failover_status_hostname`) | `false` | no | |
| `failover_status_hostname` | label of a status page the Worker also covers | empty | no | single DNS label or empty |
| `failover_timeout_ms` | wait for the primary origin's headers before trying the standby | `4000` | no | |
| `failover_standby_stream_max_s` | seconds after which a stream served by the standby is ended | `300` | no | 30 to 3600 |
| `home_access`, `app_access`, `app_access_emails` | optional per-app Access settings and lists (docs/ACCESS.md); CI: variables `APP_ACCESS`, `APP_ACCESS_EMAILS` (JSON objects) | empty | no | at most 50 addresses per app (Free plan) |

## 3. GitHub Actions variables and secrets

| Name | Kind | Meaning | Required |
|---|---|---|---|
| `CLOUDFLARE_ACCOUNT_ID` | variable | account ID; **while it is empty every credential job is skipped** (unconfigured template) | yes |
| `ZONE_NAME` | variable | your domain; **while it is empty the daily `access-verify` job is skipped** and `tofu.yml` stops with a message | yes |
| `ALLOWED_EMAILS` | variable | JSON list with the owner e-mail(s) | yes |
| `OTP_IDP_ID` | variable | existing One-time PIN login ID | no |
| `R2_LOCATION` | variable | `wnam`, `enam`, `weur`, `eeur`, `apac`, `oc` | no (`weur`) |
| `APP_ACCESS`, `APP_ACCESS_EMAILS` | variable | per-app settings and lists (JSON objects); unset = `{}` | no |
| `ACCESS_VERIFY_HOSTS` | variable | comma list of `label` or `label:home` for the daily edge probe | no (`hello`) |
| `HOME_ORIGIN_IP` | secret or variable | public IPv4 of a home origin, for the optional origin check of `:home` hosts; a secret is masked in logs | no |
| `CLOUDFLARE_API_TOKEN` | **secret** | edit token: used by apply (and by plan while there is no plan token) | yes |
| `CLOUDFLARE_API_TOKEN_PLAN` | **secret** | read-only token for the plan job of pull requests (recommended, docs/WHAT-YOU-DO.md step 3.7) | no |
| `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | **secret** | S3 keys of the state bucket | yes |

## 4. Environment variables of the scripts

| Variable | Used by | Meaning | Default |
|---|---|---|---|
| `CLOUDFLARE_API_TOKEN` | `bootstrap.sh`, `preflight.sh` | edit token (read from the environment, never from an argument) | none |
| `LOCATION` | `bootstrap.sh` | R2 location hint of the state bucket | `weur` |
| `ZONE_NAME`, `APP_ACCESS`, `HOME_ORIGIN_IP` | `verify-edge.py` | your domain (or `--zone`), per-app settings, origin address | none |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | your own `tofu` commands on a laptop | the R2 keys of the state bucket | none |

## 5. Pinned versions in the workflows

`TOFU_VERSION`, `TRIVY_VERSION`, `TFLINT_VERSION` (`tofu.yml`), `GITLEAKS_VERSION` + `GITLEAKS_SHA256` (`gitleaks.yml`: change both together, the
checksum comes from the release's checksums file). Actions are pinned to commit SHAs; Renovate proposes bumps.

## 6. Fixed on purpose (not variables)

State bucket `tfstate-cloudflare` (made by `scripts/bootstrap.sh`), R2 bucket `backups`, service token `ci-smoke-tests`, the access policy names,
the Worker `failover` (for the label `ntfy`). The sibling repositories refer to some of them by name.
