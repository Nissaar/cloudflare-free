#!/usr/bin/env bash
# One-time setup, run from your machine: creates the R2 bucket that holds the
# OpenTofu state (tfstate-cloudflare). OpenTofu does not manage this bucket,
# so the state never depends on itself.
#
#   export CLOUDFLARE_API_TOKEN=...      # the token from docs/WHAT-YOU-DO.md
#   ./scripts/bootstrap.sh <account-id>
#
# Settings (environment variable, optional; docs/CONFIGURATION.md lists every variable of this repository):
#   LOCATION   R2 location hint of the state bucket: wnam, enam, weur, eeur, apac or oc   (default weur)
#
# Safe to re-run: an existing bucket is left alone.
set -euo pipefail

ACCOUNT_ID=${1:?usage: $0 <account-id>   (with CLOUDFLARE_API_TOKEN exported)}
: "${CLOUDFLARE_API_TOKEN:?export CLOUDFLARE_API_TOKEN first}"
BUCKET=tfstate-cloudflare
LOCATION=${LOCATION:-weur}
API="https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID"

case $LOCATION in wnam | enam | weur | eeur | apac | oc) ;; *) echo "LOCATION must be one of wnam, enam, weur, eeur, apac, oc" >&2; exit 1 ;; esac
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required (sudo apt install jq)" >&2; exit 1; }

if ! [[ $ACCOUNT_ID =~ ^[0-9a-f]{32}$ ]]; then
  echo "The account id is 32 hex characters (dashboard -> Account home -> ... -> Copy account ID)." >&2
  exit 1
fi

# The token is read from the environment and sent in a header read from stdin,
# so it never shows up in the process list.
cf() {
  local method=$1 url=$2; shift 2
  [[ $url == https://* ]] || url="$API$url"
  curl -sS -X "$method" "$url" \
    -H @- -H "Content-Type: application/json" "$@" <<<"Authorization: Bearer $CLOUDFLARE_API_TOKEN"
}

echo "==> Checking the token"
# Account-owned tokens verify under the account, user tokens under /user.
verify=$(cf GET /tokens/verify)
if [ "$(jq -r '.success' <<<"$verify")" != "true" ]; then
  verify=$(cf GET https://api.cloudflare.com/client/v4/user/tokens/verify)
fi
if [ "$(jq -r '.success' <<<"$verify")" != "true" ]; then
  echo "Token check failed:" >&2
  jq -r '.errors[]? | "  \(.code): \(.message)"' <<<"$verify" >&2
  echo "Check the token value and its account scope (docs/WHAT-YOU-DO.md step 2)." >&2
  exit 1
fi

echo "==> Bucket $BUCKET"
existing=$(cf GET "/r2/buckets/$BUCKET")
if [ "$(jq -r '.success' <<<"$existing")" = "true" ]; then
  echo "    already exists, nothing to do"
else
  created=$(cf POST /r2/buckets --data "$(jq -cn --arg n "$BUCKET" --arg l "$LOCATION" '{name: $n, locationHint: $l}')")
  if [ "$(jq -r '.success' <<<"$created")" != "true" ]; then
    echo "Could not create the bucket:" >&2
    jq -r '.errors[]? | "  \(.code): \(.message)"' <<<"$created" >&2
    exit 1
  fi
  echo "    created (location hint $LOCATION)"
fi

cat <<EOT

Done. The state endpoint for this account is
  https://$ACCOUNT_ID.r2.cloudflarestorage.com
Next: docs/WHAT-YOU-DO.md step 5 (GitHub secrets and variables).
To run OpenTofu from your machine instead of CI:
  export AWS_ACCESS_KEY_ID=<R2 access key id> AWS_SECRET_ACCESS_KEY=<R2 secret>
  tofu -chdir=infra init -backend-config='endpoints={s3="https://$ACCOUNT_ID.r2.cloudflarestorage.com"}'
EOT
