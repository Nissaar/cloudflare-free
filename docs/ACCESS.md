# Who may log in to which hostname (Cloudflare Access)

> **Note for other users of this repository.** This page describes the original author's setup: per-app lists generated from a private `access/apps.yaml`
> of a home-server repository, and Home apps behind Authelia. Without that setup you only need `allowed_emails` (the owner list) and, if you want, `app_access`/`app_access_emails`
> written by hand as JSON in the repository variables `APP_ACCESS` / `APP_ACCESS_EMAILS`: the rules below are the same. Skip what mentions Home or Authelia.

Every private hostname made by this repo (`hello`, `changes`, `prices`, `pr-<n>-<app>`) and the Home apps in `home_access` / `app_access` sit behind
Cloudflare Access: the visitor types an email address and Cloudflare emails a one-time PIN (24 h session by default). Only addresses that
are on the hostname's list get a PIN.

## Where the lists live

| What | Where | Notes |
|---|---|---|
| **Per-app lists** (who may open which app, guest end dates, session length, machine paths) | `access/apps.yaml` in the **<home-server-repo>** repo (private, changed by pull request) | the one source of truth for both gates; `python3 access/access.py cloudflare` turns it into the two variables below. How to add, remove and review a person: that repo's `access/README.md` |
| `APP_ACCESS` (repository variable, JSON object, not secret) | this repo -> `app_access` | `label -> { kind, session_duration, bypass_paths, service_token }` |
| `APP_ACCESS_EMAILS` (repository variable, JSON object, **sensitive**) | this repo -> `app_access_emails` | `label -> [addresses]` (an address, or `*@domain`); expired guests are already left out by the generator |
| `ALLOWED_EMAILS` (repository variable, JSON list) | this repo -> `allowed_emails` | now the **OWNER list**: always allowed on every private hostname, and the whole list for any hostname that has no entry of its own |

Tested with fake data only (`tofu test`, mocked provider, example.com addresses): nothing here has been applied to the real account yet.

Rules the code enforces (`infra/variables.tf`, `infra/tests/plan.tftest.hcl`):

- A hostname with at least one address in `app_access_emails` gets its **own policy** `app allow: <label>` = those addresses + the owner.
  A hostname with no entry, or an empty list, keeps the global policy (the owner only): **default deny** for everybody else.
- `kind: "cluster"` must be a **private** `cluster_hostnames` label (a typo or a public hostname fails the plan, nothing is created).
  It changes that app's session length and who may open it. `kind: "home"` is a hand-made Home hostname: the entry creates its Access
  app in front of Authelia (or overrides the one from `home_access`; the entry is authoritative for session, machine paths and service token).
  The DNS record stays hand-made and the origin stays untouched.
- Session length per app (`session_duration`, for example `6h`, default `24h`).
- Machine paths (`bypass_paths`): public sub-paths of a Home app that stay reachable without a login (Kuma `/api/push/*`, Umami's tracker, ...).
  Each gets a bypass application with a more specific path. The service-token path (`ci-smoke-tests`) stays for `service_token_hostnames` and for
  entries with `service_token: true`.
- At most 50 addresses per hostname (Free plan: 50 users). Only addresses and `*@domain` are accepted.
- The owner is never listed in `app_access_emails` and cannot be taken off an app: that is the break-glass.

## Things to know first

- Cloudflare says **"a code has been sent"** for ANY address and sends nothing to an address that is not on the list. That is
  deliberate (nobody can probe which addresses are allowed). "I got no PIN" means "that address is not on this hostname's list" (or the
  mail is in spam), not "Cloudflare is broken".
- Each hostname has its own list now: being on `certdump`'s list says nothing about `hello`'s. Apps with their own gate (Authelia, an app login) keep it.
- Since 18 Nov 2026 the Home Authelia apps **except certdump** (Dozzle, Kuma `uptime`, Umami, draw.io `draw`, Speedtest `speed`, Dependency-Track `deps`, and since 21 Nov 2026 the ops `assistant`)
  need the Cloudflare PIN first and then Authelia's own login (both apply). certdump stays on Authelia only, because the people it is shared with
  use it without a Cloudflare PIN. Their machine paths stay public: Kuma's `/api/push/*`, Umami's tracking script and beacons, Dependency-Track's `/api/version`.
- The Home origin refuses a request that does not come through Cloudflare (a direct request gets 403, verified 14 Nov 2026), so Access cannot be
  walked around. `scripts/verify-edge.py` and `.github/workflows/access-verify.yml` re-check that every day (see below).

## Add, change or remove a person: the steps

The decision is made in `<home-server-repo>/access/apps.yaml` (pull request, CI shows who gains and who loses access in plain words). When it is merged:

1. Generate the two variables from the merged file (in `<home-server-repo>`, with `gh` logged in):
   ```sh
   python3 access/access.py cloudflare > /tmp/cf.json
   gh variable set APP_ACCESS --repo <your-github-user>/cloudflare-free --body "$(jq -c .app_access /tmp/cf.json)"
   gh variable set APP_ACCESS_EMAILS --repo <your-github-user>/cloudflare-free --body "$(jq -c .app_access_emails /tmp/cf.json)"
   rm /tmp/cf.json
   ```
   (`access/apply-cloudflare.sh` in <home-server-repo> wraps these steps (variables, plan re-run, apply); the commands above are the manual form. Each variable holds the whole JSON object, not a patch.)
2. Make a **new plan** with the new values. Changing a variable does not start a workflow, and the apply uses the plan saved
   for the latest main commit, so re-run the latest main run of `tofu` (Actions -> tofu -> the newest run on `main` ->
   **Re-run all jobs**), or from a terminal:
   ```sh
   gh run rerun "$(gh run list --repo <your-github-user>/cloudflare-free --workflow tofu.yml --branch main --limit 1 --json databaseId -q '.[0].databaseId')" --repo <your-github-user>/cloudflare-free
   ```
   Wait until it is green. Its plan should show only Access policies (`cloudflare_zero_trust_access_policy.app["..."]`) and, when a session length
   or a machine path changed, the matching applications. Addresses appear as `(sensitive value)`.
3. Apply it: Actions -> **tofu** -> **Run workflow** -> type `apply`, or
   ```sh
   gh workflow run tofu.yml --repo <your-github-user>/cloudflare-free --ref main -f confirm=apply
   ```
4. Test in a private window: `https://hello.example.com` (or the app's hostname), type the address, the PIN arrives within a minute. An address you
   removed gets no PIN. `access-verify` (Actions) and ChatOps `access verify` re-check the edge.

The global owner list (`ALLOWED_EMAILS`) is changed the same way as before, with `gh variable set ALLOWED_EMAILS ... --body '["owner@example.com"]'`
and steps 2 and 3.

### Remove someone at once

Removing an address from the list and applying stops NEW PINs, but a session that already exists lasts until it expires (24 h by default).
To end it now, revoke the person's sessions through the API:

```sh
curl -sS -X POST "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/access/organizations/revoke_user" \
  -H "Authorization: Bearer $CF_ACCESS_REVOKE_TOKEN" -H 'Content-Type: application/json' \
  --data '{"email":"guest@example.com"}'
```

**UNTESTED**: the path and body come from Cloudflare's API documentation (organizations -> revoke users), nothing was called against the real account.
It needs an API token with the permission group **Access: Organizations Revoke** (not the CI token: see `docs/WHAT-YOU-DO.md`, "Revoking sessions").
Cloudflare's own session-management page warns that a person whose identity is still allowed can simply log in again, so the order is: take
the address off the list and apply, THEN revoke. The ChatOps `access remove` command (<home-server-repo>) does both with the confirmation and code lock.

## Checks that run by themselves

- **Plan checks** (every pull request, `tofu test`): the generated policies, fallbacks, validations. Fake data only.
- **`access-verify`** (daily, and on demand; `.github/workflows/access-verify.yml`, script `scripts/verify-edge.py`, unit tests `scripts/test_verify_edge.py`):
  - *edge*: an unauthenticated request to each browser app must end at the Cloudflare Access login (a redirect to `*.cloudflareaccess.com`);
  - *origin*: for the Home apps, a request that skips Cloudflare (sent straight to the origin address) must NOT be served by the app
    (403, or no answer, passes). Needs the optional setting `HOME_ORIGIN_IP`.
  - Cloudflare may challenge GitHub's runner addresses: such a host shows **INCONCLUSIVE** (not a failure). Run the same probes from the server with
    ChatOps `access verify`.
  - Failures are not pushed: the ChatOps `infra` channel polls failed runs.
  - Status: the unit tests pass with fake replies; the probes were **not run against the real edge** from this repo yet.
- What these checks cannot prove: that an address that is NOT on a list gets no PIN. That needs a mailbox you control; do it once by hand after
  a change (step 4 above), with an address that is not listed.

## If a PIN never arrives

| Symptom | Cause | Fix |
|---|---|---|
| "Code sent", no mail, address not on this hostname's list | not allowed here | add the person to that app in `apps.yaml` (pull request), then the steps above |
| address is on the list, no mail | spam folder, the guest's end date passed (the generator leaves expired guests out), or the new list was never applied | check spam; check the date in `apps.yaml`; confirm steps 1 to 3 ran after the change |
| the page loops back to the login | session cookie blocked | allow cookies for `*.cloudflareaccess.com` and `example.com` |
| the plan fails with "Every key of app_access_emails must also be a key of app_access" | the two variables were generated at different times | generate both again from the same file (step 1) |
| the plan fails with "A kind \"cluster\" entry must name a PRIVATE label" | the label is not in `cluster_hostnames`, or it is public | fix the label in `apps.yaml`, or add the hostname here first (`docs/HOSTNAMES.md`) |
