<!-- Design notes of the original private repository, kept as the technical reference. The README is the entry point. -->

> Design notes. Regions, names and sizes mentioned here are the original author's examples; the values you set are listed in
> [CONFIGURATION.md](CONFIGURATION.md) and the README says what to do.

# cloudflare-free

OpenTofu for the new pieces of the Cloudflare account behind `example.com`
(Free plan), deployed by GitHub Actions with a manual apply step. Sibling repos:
`oracle-always-free` (the OKE cluster `oke-free`) and `cluster` (Flux GitOps). The
shared names live in `the sibling repositories`.

## What this repo manages

| Piece | File | Notes |
|---|---|---|
| Tunnel `oke-free`, remotely managed ingress | `infra/tunnel.tf` | every `cluster_hostnames` entry -> `http://traefik.traefik.svc.cluster.local:80`, catch-all `http_status:404` |
| DNS: `<name>.example.com` CNAME -> `<tunnel-id>.cfargotunnel.com`, proxied | `infra/tunnel.tf` | only for names in `cluster_hostnames` (+ `*-standby` when failover is on) |
| Optional `*.example.com` wildcard CNAME + wildcard ingress for `pr-*` previews | `infra/tunnel.tf` | off (`enable_preview_dns = false`) |
| Access: one app per private hostname (allow `allowed_emails`, one-time PIN, 24 h), bypass app per public hostname | `infra/access.tf` | |
| Per-app lists: policy `app allow: <label>` (the app's addresses + the owner), per-app session length, Home apps from `app_access` | `infra/access.tf`, `infra/locals.tf` | the lists come from `<home-server-repo>/access/apps.yaml` (variables `APP_ACCESS`, `APP_ACCESS_EMAILS`), see docs/ACCESS.md |
| Access apps in front of the Authelia-protected Home apps (`home_access`: dozzle, draw, speed, uptime, umami, deps, assistant; not certdump) + bypass apps for their machine paths | `infra/access.tf` | records stay hand-made |
| Access app `pr-*.example.com` (previews), service token `ci-smoke-tests` | `infra/access.tf` | token allowed on `hello` and `pr-*` |
| One-time PIN login method | `infra/access.tf` | skipped when `OTP_IDP_ID` points to an existing one |
| R2 bucket `backups` (restic: `restic/home`, `restic/cluster`) | `infra/r2.tf` | |
| Worker `failover` on `ntfy.example.com/*` (+ optional status hostname) | `infra/worker.tf`, `workers/failover/` | on (`enable_failover = true`) |

## What it does NOT manage

- **Every DNS record that already exists** (ntfy, git, nocobase, uptime, auth,
  paperless, ... and the apex). They were made by hand and stay that way. This
  repo never imports them and never changes their proxy setting. It puts an
  Access login in front of some of them only through `home_access` (the
  Authelia apps, see docs/ACCESS.md). If you add a `cluster_hostnames` name that already
  exists by hand, the apply fails ("record already exists") instead of taking
  it over.
  How to add a name and how to switch an app over from Home:
  [docs/HOSTNAMES.md](HOSTNAMES.md).
- The state bucket `tfstate-cloudflare` (made by `scripts/bootstrap.sh`).
- Zone settings (SSL mode, Bot Fight Mode, page rules), the API token and the
  R2 S3 keys (all made in the dashboard).
- The Worker route only intercepts `ntfy.example.com/*`; ntfy's own DNS record
  and its Home origin stay hand-made.

## Pipeline

```
PR            fmt, validate, tofu test, tflint + worker and edge-script unit tests + trivy  ->  plan  ->  plan posted on the PR
push to main  same checks  ->  plan  ->  plan saved as an artifact (7 days)
manual        Actions -> tofu -> Run workflow (main), type "apply"
              -> applies exactly the plan saved for the current main commit
```

- Credentials: secrets `CLOUDFLARE_API_TOKEN`, `R2_ACCESS_KEY_ID`,
  `R2_SECRET_ACCESS_KEY`; variables `CLOUDFLARE_ACCOUNT_ID`, `ALLOWED_EMAILS`
  (JSON list, e.g. `["me@example.com"]`), optional `OTP_IDP_ID`. Only the plan
  and apply jobs see them. The R2 keys reach the `s3` backend as
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`; the R2 endpoint (it contains the
  account id) is passed with `-backend-config` at init.
- There is one API token for plan and apply (Cloudflare has no keyless CI
  login). Anyone who can push a branch to this repo can use it, so keep the
  repo private and single-owner.
- The saved plan artifact contains secret values in plain form (tunnel token,
  service token). It is private to the repo and deleted after 7 days.
- OpenTofu (`tofu`) >= 1.12.0; CI pins 1.13.9 (`TOFU_VERSION`). Providers
  come from registry.opentofu.org; the lock file covers linux_amd64,
  linux_arm64 and darwin_arm64.
- Stale plans are refused: if the state changed after the plan was made,
  OpenTofu rejects the apply; push again or re-run the main workflow.
- Actions are pinned to commit SHAs (trivy-action tags were hijacked in March
  2026, CVE-2026-33634). Renovate updates them and the OpenTofu/Trivy/tflint
  versions in the workflow `env`.
- Failures are not pushed anywhere: the ChatOps `infra` channel polls the
  GitHub API for failed runs.

Local checks (no credentials needed):

```bash
tofu fmt -check -recursive
tofu -chdir=infra init -backend=false && tofu -chdir=infra validate && tofu -chdir=infra test
tflint --init && tflint --recursive
trivy config .
(cd workers/failover && node --test)
(cd scripts && python3 -m unittest test_verify_edge)
```

`.github/workflows/access-verify.yml` (daily, and on demand) runs `scripts/verify-edge.py`: every browser app must end at the Cloudflare Access
login when asked without logging in, and the Home origin must refuse a request that skips Cloudflare (docs/ACCESS.md).

## Layout

```
infra/                 the only OpenTofu stack (state: R2 tfstate-cloudflare, key cloudflare-free/terraform.tfstate)
infra/tests/           tofu test with a mocked provider (offline)
workers/failover/      Worker source (src/index.js, uploaded as-is) + node:test tests
scripts/bootstrap.sh   creates the state bucket through the Cloudflare API
scripts/verify-edge.py edge + origin probes (stdlib), test_verify_edge.py its unit tests (fake replies)
.github/workflows/     tofu.yml (plan/apply), access-verify.yml (daily edge/origin check)
docs/WHAT-YOU-DO.md    the manual steps, in order
```

## Who may log in

Each private hostname can have its own list. The lists are decided in `<home-server-repo>/access/apps.yaml` and reach this repo as the variables
`APP_ACCESS` and `APP_ACCESS_EMAILS`; the repository variable `ALLOWED_EMAILS` is the owner, always allowed, and the whole list of a hostname without
an entry. How to add or remove a person, and why a PIN may not arrive: [docs/ACCESS.md](ACCESS.md).

## Add a hostname

1. Add it to `cluster_hostnames` in `infra/variables.tf` (default value):
   ```hcl
   default = {
     hello = { public = false }
     blog  = { public = false }   # new: behind Access
   }
   ```
   One label only (`blog`, not `x.blog`): Universal SSL does not cover
   two-level names. `pr-*` and `*-standby` are reserved.
2. In the `k8s-free-gitops` repo, give the app a Traefik route for `blog.example.com`
   on entrypoint `web`.
3. PR -> read the plan (expect a DNS record, an ingress change and an Access
   app) -> merge -> run the apply.
4. Add an Uptime Kuma monitor (accept `302` while it is private, see
   `docs/WHAT-YOU-DO.md` step 12).

## Make a hostname public

Change `public = false` to `public = true`. The plan replaces the allow app
with a bypass app (no login). The app behind it must do its own auth if it
needs any. To make it private again, flip it back.

## Failover Worker

`enable_failover = true` deploys `workers/failover/src/index.js` on
`ntfy.example.com/*` (and `<failover_status_hostname>.example.com/*` if set)
and adds `ntfy-standby` (and `<status>-standby`) to the tunnel as public
hostnames. The standby is the k8s-free-gitops repo's `apps/ntfy-standby`: same
users, ACL and tokens as Home (from OCI Vault), `base-url
https://ntfy.example.com`. The phone keeps its one subscription to
`ntfy.example.com`; no new topic, no second server. Per request:

- Everything goes to the Home origin first. A fetch to the Worker's
  own hostname goes to the origin, not back into the Worker, because the
  `global_fetch_strictly_public` compatibility flag is not set (Cloudflare
  docs, compatibility flags). Do not add that flag.
- On 5xx (including Cloudflare's 521/522/524/530), no response headers within
  `failover_timeout_ms` (4 s), or a network error, the same request (method,
  headers, body up to 16 MB) goes to `ntfy-standby.example.com`. The response
  then carries `x-failover: standby`.
- Subscriptions (`/<topic>/json`, `/sse`, `/raw`, `/ws`, websockets,
  `Accept: text/event-stream`) follow the same rule, so the phone's
  connection lands on the standby while Home is down. Only the wait for
  the response headers is timed: an open stream from Home is never cut.
- A stream served by the standby is ended after
  `failover_standby_stream_max_s` (300 s). The ntfy app reconnects by itself
  and the reconnect tries Home first, so after Home recovers the phone
  is back on it within 5 minutes. Messages published to Home in those
  minutes may arrive late or not at all on the phone; nothing is lost on
  Home. A websocket that lands on the standby stays there until the app
  reconnects on its own (the ntfy app uses the JSON stream unless you
  switched it to WebSockets in its settings).
- `/v1/health` never fails over: Uptime Kuma, ChatOps and Alloy keep seeing
  Home's real state. The standby is checked at
  `https://ntfy-standby.example.com/v1/health`.

Free plan limits: 100 000 Worker requests a day. Every ntfy request counts,
including each subscription connection.
