# What you do (manual steps, in order)

Nothing in this repo has been applied or pushed. These steps take it from a
local git repo to a working tunnel. Do them in order; each says where to click
or what to run.

## 0. Install OpenTofu on the laptop (once)

OpenTofu replaced Terraform in this repo on 2026-11-06: every command is
`tofu ...`, the `terraform` binary is no longer used (you can keep it
installed; nothing here calls it).

1. In WSL, install it from OpenTofu's own apt repository (the official
   installer, Debian/Ubuntu method). It asks for your sudo password:
   ```bash
   cd /tmp
   curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
   chmod +x install-opentofu.sh
   ./install-opentofu.sh --install-method deb
   rm -f install-opentofu.sh
   cd -
   ```
   Updates then come with `sudo apt update && sudo apt upgrade`.
2. Check: `tofu version` prints `OpenTofu v1.13.x` or newer (CI uses 1.13.9;
   the code needs at least 1.12.0).
3. If you ever ran `terraform init` in this repo, delete the old provider
   download once: `rm -rf infra/.terraform` (it came from
   registry.terraform.io; `tofu init` fetches it again from
   registry.opentofu.org and checks it against `infra/.terraform.lock.hcl`).
4. Optional offline check that everything works (no credentials needed):
   ```bash
   cd ~/cloudflare-free
   tofu -chdir=infra init -backend=false && tofu -chdir=infra test
   ```
   Good output ends with `Success! 5 passed, 0 failed.`

## 1. Turn on R2 and Zero Trust (once per account)

1. https://dash.cloudflare.com -> pick the account that owns `example.com`.
2. Left menu **R2 Object Storage** -> **Overview**. If it asks, add a payment
   method and confirm the free plan (10 GB free; nothing is billed below that).
3. Left menu **Zero Trust**. If this is the first time: choose a team name
   (anything, e.g. `my-account`), pick the **Free** plan, add a payment method if
   asked (Free plan: up to 50 users, no charge).
4. Copy the **account ID**: left menu **Account home** -> the `...` next to
   the account name -> **Copy account ID** (32 hex characters). Keep it for
   steps 3, 5 and 6.

## 2. Check for an existing One-time PIN login

1. **Zero Trust** -> **Integrations** -> **Identity providers** (older guides say
   Settings -> Authentication -> Login methods: that menu no longer exists).
2. If **One-time PIN** is already listed: click it and copy its ID (also in the
   URL). You will set it as `OTP_IDP_ID` in step 6. If it is not listed, do
   nothing: OpenTofu creates it. Since 18 June 2026 a new Zero Trust account
   starts with Cloudflare's own login method instead of One-time PIN, so a
   recent account usually has none.

## 3. Create the API token

The token form groups permissions into **policies** (one per scope). You need
two: one for the zone, one for the account.

1. Top right profile icon -> **My Profile** -> **API Tokens** ->
   **Create Token** -> **Create Custom Token** -> **Get started**.
2. Token name: `cloudflare-free CI`.
3. **Policy 1, the zone.** The first policy is a *Zone* policy. Change
   **All zones** to **Specific zone** -> `example.com`. In the search box,
   find each permission group and set its access:

   | Permission group | Access |
   |---|---|
   | Zone | Read |
   | DNS | Edit |
   | Workers Routes | Edit |

4. **Policy 2, the account.** **Add new policy** -> **Account**. Include ->
   your account (the one from step 1, not "All accounts"). Search and set:

   | Permission group | Access |
   |---|---|
   | Cloudflare Tunnel | Edit |
   | Access: Apps and Policies | Edit |
   | Access: Service Tokens | Edit |
   | Access: Organizations, Identity Providers, and Groups | Edit |
   | Workers R2 Storage | Edit |
   | Workers Scripts | Edit |

   Groups sit in folders (Developer Platform, Cloudflare One / Zero Trust, DNS
   & Zones, ...); searching is faster than opening them.
5. **Token expiration**: **1 year** (add a rotation reminder), or **No
   expiration** if you prefer. **Client IP address filtering**: leave empty
   (GitHub's runners have changing addresses).
6. **Continue to summary**: two policies, nine permissions. **Create Token** ->
   copy the token now (it is shown once). This is `CLOUDFLARE_API_TOKEN`.
7. **Recommended second token for the plan job (verify):** Cloudflare has no keyless login, so a pull request from a
   branch of your repository runs with the token you store. Repeat steps 1 to 6 with the name `cloudflare-free plan`
   and **Read** instead of **Edit** on every permission group (Zone/DNS/Workers Routes: Read; Tunnel, Access, R2, Workers Scripts: Read).
   Store it as the secret `CLOUDFLARE_API_TOKEN_PLAN` (step 6). The plan job then never holds the edit token; the apply job always uses
   `CLOUDFLARE_API_TOKEN`. If a plan fails with a permission error that Read cannot cover, delete the plan secret (the plan falls back to the edit token) and tell
   the maintainers which permission was missing.

## 4. Create the state bucket

In WSL:

```bash
cd ~/cloudflare-free
read -rs CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN   # paste the token, Enter
./scripts/bootstrap.sh <account-id>
```

Expected: `==> Bucket tfstate-cloudflare` then `created`. Re-running it is
safe (`already exists, nothing to do`).

## 5. Create the R2 S3 keys for the state

1. **R2 Object Storage** -> **Overview** -> **API** (right side) ->
   **Manage API tokens** -> **Create Account API token** (or User API token).
2. Name `cloudflare-free state`. Permissions: **Object Read & Write**.
3. **Specify bucket(s)** -> `tfstate-cloudflare` only. TTL: Forever.
4. **Create** -> copy **Access Key ID** (`R2_ACCESS_KEY_ID`) and **Secret
   Access Key** (`R2_SECRET_ACCESS_KEY`). They are shown once.

## 6. Create the GitHub repo and set its secrets and variables

1. https://github.com/new -> owner `<your-github-user>`, name `cloudflare-free`,
   **Private**, no README/.gitignore/license -> **Create repository**.
2. Repo -> **Settings** -> **Secrets and variables** -> **Actions**.
3. Tab **Secrets** -> **New repository secret**, three times:
   - `CLOUDFLARE_API_TOKEN` = token from step 3
   - `R2_ACCESS_KEY_ID` = from step 5
   - `R2_SECRET_ACCESS_KEY` = from step 5
4. Tab **Variables** -> **New repository variable**:
   - `CLOUDFLARE_ACCOUNT_ID` = account ID from step 1
   - `ZONE_NAME` = your domain, in lower case (for example `mydomain.org`); it must be active in that account
   - `ALLOWED_EMAILS` = JSON list with your email, exactly like
     `["you@example.com"]` (double quotes, square brackets)
   - `OTP_IDP_ID` = only if step 2 found an existing One-time PIN
   - `R2_LOCATION` = optional, `wnam`, `enam`, `weur`, `eeur`, `apac` or `oc` (default `weur`; fixed once the bucket has data)
   - optional secret `CLOUDFLARE_API_TOKEN_PLAN` = the read-only token of step 3.7
5. Same with the CLI instead, if you prefer:
   ```bash
   R=<your-github-user>/cloudflare-free
   gh secret set CLOUDFLARE_API_TOKEN --repo $R     # paste when asked
   gh secret set R2_ACCESS_KEY_ID --repo $R
   gh secret set R2_SECRET_ACCESS_KEY --repo $R
   gh variable set CLOUDFLARE_ACCOUNT_ID --repo $R --body <account-id>
   gh variable set ZONE_NAME --repo $R --body <your-domain>
   gh variable set ALLOWED_EMAILS --repo $R --body '["you@example.com"]'
   ```
6. Renovate: https://github.com/apps/renovate -> **Configure** -> add
   `cloudflare-free` to the selected repositories (same as the other repos).

## 7. Push

```bash
cd ~/cloudflare-free
git remote add origin git@github.com:<your-github-user>/cloudflare-free.git
git push -u origin main
```

Repo -> **Actions** -> **tofu**: wait for the run on `main` to go green.
Open its summary and read the plan: on the first run it creates the tunnel,
its config, the `hello` DNS record, the Access apps/policies, the One-time PIN
login (unless `OTP_IDP_ID`), the service token and the `backups` bucket.
Nothing in it should touch an existing record; if a line mentions `ntfy`,
`git` or any other hand-made name, stop and ask.

## 8. First apply

**Actions** -> **tofu** -> **Run workflow** -> branch `main` -> type
`apply` -> **Run workflow**. It applies exactly the plan from step 7.

## 9. Copy the tunnel token into the k8s-free-gitops repo

The token is a sensitive output, so read it locally (needs `tofu`, step 0):

```bash
cd ~/cloudflare-free
export CLOUDFLARE_API_TOKEN=...                     # step 3
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...   # step 5
tofu -chdir=infra init -backend-config='endpoints={s3="https://<account-id>.r2.cloudflarestorage.com"}'
tofu -chdir=infra output -raw tunnel_token; echo
```

Now in OCI Vault (the cluster reads it through External Secrets). Instead of
printing it, pipe it straight into the Vault secret `cloudflared-tunnel-token`
(needs the Oracle login of oracle-always-free step 2: `oci session refresh
--profile oracle-always-free-admin` if it is older than an hour):

```bash
tofu -chdir=infra output -raw tunnel_token \
  | jq -R '{TUNNEL_TOKEN: .}' | ~/oracle-always-free/scripts/put-secret.sh cloudflared-tunnel-token -
```

It prints `created cloudflared-tunnel-token (keys: TUNNEL_TOKEN)`. Nothing to
commit. Once cloudflared runs, **Networking** -> **Tunnels** (main dashboard menu;
Tunnels is no longer inside Zero Trust) shows `oke-free` as **Healthy**.

## 10. Service token for preview smoke tests

```bash
tofu -chdir=infra output -raw ci_smoke_tests_client_id; echo
tofu -chdir=infra output -raw ci_smoke_tests_client_secret; echo
```

Both go into the Vault secret `previews-preview-smoke` used by the preview
smoke-test Job (headers `CF-Access-Client-Id` / `CF-Access-Client-Secret`),
together with an ntfy token: now in Vault, run the command of the cluster
repo's `docs/WHAT-YOU-DO.md` step 5e (it reads both outputs itself). The
token lasts one year: **Zero Trust** -> **Access** -> **Service auth** shows
the expiry; renew it there before it ends and run step 5e again.

## 11. R2 keys for the backups bucket

Same as step 5, but name `restic backups`, **Object Read & Write**, bucket
`backups` only. Put the key pair into the Home `backup/.env`. The cluster's restore
test has its own read-only key, now in Vault (k8s-free-gitops repo
`docs/WHAT-YOU-DO.md` step 5d, `put-secret.sh restore-test-restore-test`). Endpoint:
`tofu -chdir=infra output -raw r2_s3_endpoint` (restic repo
`s3:<endpoint>/backups/restic/home`).

## 12. Uptime Kuma monitor for hello.example.com

`hello` is behind Access, so without a login it answers **302** (redirect to
the Access login page). The monitor checks exactly that:

1. In `~/<home-server-repo>/uptime-kuma/monitors/`, copy `gitea.json` to
   `hello-oke.json` and change:
   ```json
   "name": "hello (OKE)",
   "url": "https://hello.example.com/",
   "max_redirects": 0,
   "accepted_statuscodes": ["302"]
   ```
   `max_redirects: 0` makes Kuma report the 302 itself instead of following
   it to the login page (which would answer 200 even if the tunnel is down).
2. Add the row to `uptime-kuma/README.md`, commit, push; on the server
   `git pull`. AutoKuma creates the monitor within a minute.
3. If you prefer the UI: **Add New Monitor** -> HTTP(s) -> URL above ->
   **Advanced** -> Max. Redirects `0`, Accepted Status Codes: remove `200-299`,
   add `302`.

A 302 proves Cloudflare and Access answer, not that the cluster does. The
preview smoke tests (service token) cover the cluster side.

## 13. Later: turn on failover

Only after the cluster serves the ntfy copy (k8s-free-gitops repo
`docs/WHAT-YOU-DO.md` steps 22 and 24.1-24.3: `apps/ntfy-standby` is Ready
and answers with your users and tokens). The phone keeps its one
subscription to `ntfy.example.com`: nothing to change in the app.

1. Check that the Home ntfy record is proxied (orange cloud): Cloudflare
   dashboard -> `example.com` -> **DNS** -> **Records** -> `ntfy` -> Proxy
   status **Proxied**. A Worker route only runs on proxied names. Do not
   change the record otherwise; OpenTofu never manages it.
2. In `infra/variables.tf`, variable `enable_failover`: change
   `default = false` to `default = true` (and set `failover_status_hostname`
   only if you publish a status page with a standby copy).
3. Commit on a branch, push, open a PR: the plan comment must show the
   Worker `failover`, the route `ntfy.example.com/*`, the DNS record
   `ntfy-standby`, its tunnel ingress rule and a `ntfy-standby.example.com
   (public)` Access app. Nothing about the `ntfy` record itself.
4. Merge. GitHub -> <your-github-user>/cloudflare-free -> **Actions** -> **tofu**
   -> wait for the green run of main -> **Run workflow** -> type `apply`.
5. Home up, normal path (replace `<bot token>` with the ntfy publisher
   token from Proton Pass):
   ```bash
   curl -s -D - -o /dev/null -H "Authorization: Bearer <bot token>" -d "failover test 1" https://ntfy.example.com/general | grep -i -E '^HTTP|x-failover'
   ```
   -> `HTTP/2 200`, no `x-failover` line. The phone shows "failover test 1".
6. Home down: on the Home server
   `cd <home-server-dir>/ntfy && docker compose stop ntfy`. Wait one
   minute (the phone's app reconnects and lands on the standby), then run the
   curl of 5 with "failover test 2": `HTTP/2 200` and
   `x-failover: standby`, and the phone shows the message.
   `curl -s https://ntfy.example.com/v1/health` now fails on purpose (health
   is never failed over); `curl -s https://ntfy-standby.example.com/v1/health`
   -> `{"healthy":true}`.
7. Home back: `docker compose start ntfy`. Wait 5 minutes (the Worker ends
   the standby stream after `failover_standby_stream_max_s`), run the curl of
   5 with "failover test 3": no `x-failover`, and the phone shows it.
8. To turn it off again: set the default back to `false`, PR, merge, apply.

## 14. Later: preview DNS

When the cluster's preview ResourceSet is ready, set `enable_preview_dns =
true`. It adds a proxied `*.example.com` CNAME to the tunnel. First check
**DNS** -> **Records** for an existing `*` record: if there is one, the apply
fails; decide which one you keep. Hand-made records keep working (an exact
record always beats the wildcard).

## 15. Per-app access lists (new repository variables, optional settings)

Set once; afterwards the values come from `<home-server-repo>/access/apps.yaml` (see docs/ACCESS.md). Nothing here is needed to keep today's setup working: an unset variable means `{}`
and every private hostname keeps using the owner list `ALLOWED_EMAILS`.

| Where | Name | What |
|---|---|---|
| GitHub -> `cloudflare-free` -> Settings -> Secrets and variables -> Actions -> **Variables** | `APP_ACCESS` | JSON object, the `app_access` part of `python3 access/access.py cloudflare` (in `<home-server-repo>`). Not secret. |
| same | `APP_ACCESS_EMAILS` | JSON object, the `app_access_emails` part. Contains addresses: keep the repo private. |
| same (a **Secret** is better) | `HOME_ORIGIN_IP` | optional: the Home server's public IPv4. Without it the daily `access-verify` workflow skips the origin check. |
| same, Variables | `ACCESS_VERIFY_HOSTS` | optional: comma list of `label` or `label:home` for `access-verify` (default: the six Home apps, `hello`, `changes`, `prices`). |

Set them with `gh variable set APP_ACCESS --repo <your-github-user>/cloudflare-free --body "$(jq -c .app_access cf.json)"` (and the same for `APP_ACCESS_EMAILS`).

### Revoking sessions (used by ChatOps, not by this repo)

To end a person's Cloudflare Access sessions at once, ChatOps calls `POST /accounts/<account id>/access/organizations/revoke_user` with `{"email": ...}`.
That needs its own API token, separate from the CI token: **My Profile -> API Tokens -> Create Token -> Create Custom Token**, policy **Account** ->
your account -> permission group **Access: Organizations Revoke** (granular permission, Cloudflare changelog 22 Jan 2026) -> Edit. Put it in ChatOps' env on the
server, never in GitHub or git. **UNTESTED** against the real account: the endpoint and permission name come from Cloudflare's documentation.
