# Changelog

Notable changes of this public copy, newest first. Changes that need a manual step from you are marked **ACTION**.

## 2026-11-25: audit for strangers, variables, preflight

### Security
- **No default domain.** `zone_name` has no default (it was a placeholder domain) and is validated; CI takes it from the Actions variable `ZONE_NAME`.
  **ACTION** when you update an older copy: set the variable `ZONE_NAME`. The daily `access-verify` job also reads it and is skipped while it is empty.
- **Optional read-only plan token** (`CLOUDFLARE_API_TOKEN_PLAN`): the plan job of a pull request no longer has to hold the edit token (apply always uses `CLOUDFLARE_API_TOKEN`).
- `allowed_emails` refuses wildcards and `<placeholders>`; `cluster_origin` is validated; `verify-edge.py` no longer probes a default domain (`--zone` or `ZONE_NAME` is required).
- Workflow: `persist-credentials: false` on every checkout, `timeout-minutes` on every job, a clear message when a required setting is missing.

### Added
- `docs/CONFIGURATION.md`: every variable, where it is set, default, example.
- `scripts/preflight.sh`: read-only check of tools, variables, files, the API token and the zone (asked from Cloudflare), repository settings and the names of the Actions variables and secrets.
- Variables `tunnel_name` and `r2_location` (the tunnel and the bucket location were fixed in code); `LOCATION` for the state bucket in `bootstrap.sh`.
- `tofu test` cases for the new validations; README: how a stranger uses the repository, step by step, including the commit that starts the first plan.

### Changed
- docs/ACCESS.md and docs/HOSTNAMES.md say which parts describe the original author's home-server setup and can be skipped.
