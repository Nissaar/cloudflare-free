#!/usr/bin/env bash
# preflight.sh: READ-ONLY check of everything you need before the first plan.
# It changes nothing: no file is written, no Cloudflare call except reads (token check, zone lookup), no GitHub setting is touched.
# The API token is read from the environment and sent in a header read from stdin: it never shows up in the process list or in the output.
#
#   export CLOUDFLARE_API_TOKEN=...                                   (read -rs CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN)
#   ./scripts/preflight.sh <account-id> <zone-name> <your-email> [owner/repo]
#   ./scripts/preflight.sh                       reads infra/terraform.tfvars if it exists
#   ./scripts/preflight.sh --offline ...         skip every check that needs the network (Cloudflare, GitHub)
#
# Exit code 0 = nothing to fix (warnings are advice), 1 = at least one FAIL, with what to do about it.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OFFLINE=false
ARGS=()
for a in "$@"; do
  case $a in
    --offline) OFFLINE=true ;;
    -h | --help) sed -n 2,11p "$0"; exit 0 ;;
    *) ARGS+=("$a") ;;
  esac
done
ACCOUNT=${ARGS[0]:-}
ZONE=${ARGS[1]:-}
EMAIL=${ARGS[2]:-}
REPO=${ARGS[3]:-}
TFV=$ROOT/infra/terraform.tfvars

fails=0
warns=0
ok() { printf '  [ ok ] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; fails=$((fails + 1)); }
section() { printf '\n%s\n' "$*"; }
have() { command -v "$1" > /dev/null 2>&1; }
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }
tfvar() { sed -n -E "s/^[[:space:]]*${1}[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$TFV" 2> /dev/null | head -n1; }
# GET against the Cloudflare API; the token goes through stdin (-H @-), never through argv
cf() { curl -sS --proto '=https' -m 20 "$1" -H @- -H "Content-Type: application/json" <<< "Authorization: Bearer $CLOUDFLARE_API_TOKEN" 2> /dev/null; }

section "1. Tools on this machine"
for t in git jq curl python3; do
  if have "$t"; then ok "$t"; else fail "$t is not installed (sudo apt install $t)"; fi
done
if have tofu; then
  v=$(tofu version 2> /dev/null | sed -n '1s/[^0-9.]*\([0-9][0-9.]*\).*/\1/p')
  if [ -n "$v" ] && version_ge "$v" 1.12.0; then ok "tofu (OpenTofu) $v"; else fail "OpenTofu 1.12.0 or newer is required, found '${v:-none}' (docs/WHAT-YOU-DO.md step 0). Terraform is not supported: use tofu"; fi
else
  fail "tofu (OpenTofu) is not installed (docs/WHAT-YOU-DO.md step 0)"
fi
if have gh; then ok "gh $(gh --version 2> /dev/null | head -n1 | cut -d' ' -f3)"; else fail "the GitHub CLI (gh) is not installed: https://cli.github.com/"; fi
if have node; then ok "node $(node --version) (the failover Worker tests)"; else warn "node is not installed: only needed to run the Worker tests (workers/failover) yourself"; fi
if have shellcheck; then ok "shellcheck (optional)"; else warn "shellcheck not installed: only needed for the checks in the README"; fi

section "2. Variables you must set"
[ -n "$ACCOUNT" ] || ACCOUNT=$(tfvar account_id)
[ -n "$ZONE" ] || ZONE=$(tfvar zone_name)
if [ -f "$TFV" ]; then ok "infra/terraform.tfvars exists (git-ignored)"; fi
if [ -z "$ACCOUNT$ZONE$EMAIL" ] && [ ! -f "$TFV" ]; then
  fail "nothing to check yet: no arguments and no infra/terraform.tfvars. Run  ./scripts/preflight.sh <account-id> <zone-name> <your-email> [owner/repo]"
fi
if [ -n "$ACCOUNT" ]; then
  if [[ $ACCOUNT =~ ^[0-9a-f]{32}$ && $ACCOUNT != 0123456789abcdef0123456789abcdef && $ACCOUNT != fedcba9876543210fedcba9876543210 ]]; then ok "account id has the right shape (32 hex characters)"; else fail "account id is not 32 hex characters, or is the example (dashboard -> Account home -> ... -> Copy account ID)"; fi
elif [ -f "$TFV" ]; then fail "infra/terraform.tfvars: account_id is not set"; fi
if [ -n "$ZONE" ]; then
  if [[ $ZONE =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ && $ZONE != example.com && $ZONE != example.net && $ZONE != example.org ]]; then ok "zone name $ZONE"; else fail "zone name '$ZONE' is not your own domain in lower case (not a placeholder, not example.com)"; fi
elif [ -f "$TFV" ]; then fail "infra/terraform.tfvars: zone_name is not set"; fi
if [ -z "$EMAIL" ] && [ -f "$TFV" ]; then
  EMAIL=$(sed -n -E 's/^[[:space:]]*allowed_emails[[:space:]]*=[[:space:]]*\[[[:space:]]*"([^"]*)".*/\1/p' "$TFV" | head -n1)
  [ -n "$EMAIL" ] || fail "infra/terraform.tfvars: allowed_emails is not set"
fi
if [ -n "$EMAIL" ]; then
  if [[ $EMAIL =~ ^[^@[:space:]\<\>*]+@[^@[:space:]\<\>*]+\.[^@[:space:]\<\>*]+$ && $EMAIL != *@example.com && $EMAIL != *@example.org ]]; then ok "owner e-mail looks real (the only address that can pass the login)"; else fail "owner e-mail '$EMAIL' is a placeholder or not an address"; fi
fi
if [ -n "$REPO" ] && ! [[ $REPO =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$ ]]; then fail "repository '$REPO' must look like owner/name"; fi
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then ok "CLOUDFLARE_API_TOKEN is set in this shell"; else warn "CLOUDFLARE_API_TOKEN is not exported: needed for scripts/bootstrap.sh and for the token check below (read -rs CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN)"; fi
if [ -n "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}" ]; then warn "AWS_* variables are set in this shell: they are the R2 keys for tofu commands on your laptop; make sure they are the keys of THIS repository's state bucket, not Oracle's"; fi

section "3. Files of this repository"
left=$(cd "$ROOT" && grep -rIn -E '<your-[a-z0-9-]+>' --include='*.tf' --include='*.tfvars' --include='*.yml' --include='*.yaml' --include='*.js' --include='*.json' . 2> /dev/null | grep -v -E '^\./(docs|\.git)/|\.example|\.env|node_modules|^[^:]+:[0-9]+:[[:space:]]*(#|//)' | head -n 5)
if [ -z "$left" ]; then ok "no <your-...> placeholder in the code files"; else fail "placeholders left in files you would commit:"; printf '%s\n' "$left" | sed 's/^/           /'; fi
if [ -n "$(cd "$ROOT" && git ls-files '*.tfvars' '*.tfstate' '*.pem' '*.key' '.env' 2> /dev/null | grep -v -E '\.example$')" ]; then fail "a tfvars, state, key or .env file is tracked by git: git rm --cached it (it may hold secrets)"; else ok "no tfvars, state, key or .env file is tracked by git"; fi
if (cd "$ROOT" && tofu fmt -check -recursive > /dev/null 2>&1); then ok "tofu fmt -check"; else warn "tofu fmt -check reports unformatted files: tofu fmt -recursive"; fi

section "4. Cloudflare and GitHub (network, read-only)"
if [ "$OFFLINE" = true ]; then
  warn "--offline: Cloudflare and GitHub were not asked"
else
  if [ -n "${CLOUDFLARE_API_TOKEN:-}" ] && have curl && have jq; then
    v=$(cf "https://api.cloudflare.com/client/v4/user/tokens/verify")
    if [ "$(jq -r '.success // false' <<< "$v" 2> /dev/null)" != true ] && [[ $ACCOUNT =~ ^[0-9a-f]{32}$ ]]; then v=$(cf "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/tokens/verify"); fi
    if [ "$(jq -r '.success // false' <<< "$v" 2> /dev/null)" = true ]; then ok "the API token is valid ($(jq -r '.result.status // "status unknown"' <<< "$v"))"; else fail "the API token is not valid (wrong value, expired, or no Cloudflare access from this machine): docs/WHAT-YOU-DO.md step 3"; fi
    if [[ $ACCOUNT =~ ^[0-9a-f]{32}$ && -n "$ZONE" && $ZONE != *"<"* ]]; then
      z=$(cf "https://api.cloudflare.com/client/v4/zones?name=$ZONE&account.id=$ACCOUNT&status=active")
      if [ "$(jq -r '.success // false' <<< "$z" 2> /dev/null)" = true ] && [ "$(jq -r '.result | length' <<< "$z" 2> /dev/null)" -ge 1 ] 2> /dev/null; then ok "zone $ZONE is active in this account"; else fail "zone $ZONE was not found as an ACTIVE zone in this account (domain not added, nameservers not switched yet, or the token lacks Zone: Read)"; fi
    fi
  else
    warn "token check skipped (no CLOUDFLARE_API_TOKEN, or curl/jq missing)"
  fi
  if have gh; then
    if gh auth status > /dev/null 2>&1; then ok "gh is logged in"; else fail "gh is not logged in: gh auth login"; fi
  fi
  if have gh && gh auth status > /dev/null 2>&1; then
    slug=${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2> /dev/null || true)}
    if [ -z "$slug" ]; then
      warn "no GitHub repository found for this folder yet: create YOUR private copy first (README, step 1)"
    else
      priv=$(gh repo view "$slug" --json isPrivate,isFork --jq '"\(.isPrivate) \(.isFork)"' 2> /dev/null || true)
      case $priv in
        "true false") ok "$slug is private and is not a fork" ;;
        "true true") warn "$slug is a private fork: prefer a clone pushed to a new private repository" ;;
        "false"*) fail "$slug is PUBLIC: the plan output and the API token belong in a PRIVATE repository (gh repo edit $slug --visibility private --accept-visibility-change-consequences)" ;;
        *) warn "could not read the visibility of $slug (no access? wrong name?)" ;;
      esac
      pol=$(gh api "repos/$slug/actions/permissions/workflow" --jq .default_workflow_permissions 2> /dev/null || true)
      case $pol in
        read) ok "Actions default token permission is read" ;;
        write) fail "Actions default token permission is write: Settings -> Actions -> General -> Workflow permissions -> Read repository contents" ;;
        *) warn "could not read the Actions workflow permissions (verify in Settings -> Actions -> General)" ;;
      esac
      fpr=$(gh api "repos/$slug/actions/permissions/fork-pr-contributor-approval" --jq .approval_policy 2> /dev/null || true)
      if [ "$fpr" = all_external_contributors ]; then ok "fork pull requests need approval from you"; else warn "fork pull request approval is '${fpr:-unknown}': set Settings -> Actions -> General -> Fork pull request workflows -> Require approval for all external contributors (verify)"; fi
      vars=$(gh variable list --repo "$slug" --json name --jq '.[].name' 2> /dev/null || true)
      secs=$(gh secret list --repo "$slug" --json name --jq '.[].name' 2> /dev/null || true)
      if [ -z "$vars$secs" ]; then
        warn "no Actions variables or secrets on $slug yet (docs/WHAT-YOU-DO.md step 6), or they could not be listed"
      else
        for n in CLOUDFLARE_ACCOUNT_ID ZONE_NAME ALLOWED_EMAILS; do
          if grep -qx "$n" <<< "$vars"; then ok "Actions variable $n is set"; else fail "Actions variable $n is missing (docs/WHAT-YOU-DO.md step 6)"; fi
        done
        for n in CLOUDFLARE_API_TOKEN R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do
          if grep -qx "$n" <<< "$secs"; then ok "Actions secret $n is set"; else fail "Actions secret $n is missing (docs/WHAT-YOU-DO.md step 6)"; fi
        done
        if grep -qx CLOUDFLARE_API_TOKEN_PLAN <<< "$secs"; then ok "a separate read-only plan token is set"; else warn "no CLOUDFLARE_API_TOKEN_PLAN: pull-request plans run with the edit token (docs/WHAT-YOU-DO.md step 3.7)"; fi
      fi
      br=$(gh api "repos/$slug/branches/main/protection" --jq .url 2> /dev/null || true)
      if [ -n "$br" ]; then ok "branch main is protected"; else warn "branch main has no protection (or the plan does not offer it on private repositories): do not give write access to anybody you do not trust (README, security notes)"; fi
    fi
  fi
fi

section "Result"
if [ "$fails" -eq 0 ]; then
  printf '  Nothing to fix (%d warning(s)). Next: README, "Use it".\n' "$warns"
  exit 0
fi
printf '  %d thing(s) to fix (the [FAIL] lines above), %d warning(s). Nothing was changed by this script.\n' "$fails" "$warns"
exit 1
