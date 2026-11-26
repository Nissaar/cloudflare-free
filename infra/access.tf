# Cloudflare Access: every private hostname this repo creates needs a login
# (one-time PIN to an allowed email, 24 h session). Public ones get a bypass.
# Only hostnames created here get an app: hand-made records (ntfy, git, ...)
# are never put behind Access by this repo.

resource "cloudflare_zero_trust_access_identity_provider" "otp" {
  count = var.otp_idp_id == "" ? 1 : 0

  account_id = var.account_id
  name       = "One-time PIN"
  type       = "onetimepin"
  config     = {}
}

resource "cloudflare_zero_trust_access_policy" "allow_owner" {
  account_id = var.account_id
  name       = "allow owner (one-time PIN)"
  decision   = "allow"
  include    = [for email in var.allowed_emails : { email = { email = email } }]
}

# One policy per app that has its own list (app_access_emails): those addresses PLUS the owner (allowed_emails), which is always allowed.
# The addresses are sensitive: they never reach a name, an output or a for_each key.
resource "cloudflare_zero_trust_access_policy" "app" {
  for_each = local.app_policy_labels

  account_id = var.account_id
  name       = "app allow: ${each.key}"
  decision   = "allow"
  include = distinct(concat(
    [for email in var.allowed_emails : { email = { email = email } }],
    [for email in var.app_access_emails[each.key] : { email = { email = email } } if !startswith(email, "*@")],
    [for email in var.app_access_emails[each.key] : { email_domain = { domain = substr(email, 2, -1) } } if startswith(email, "*@")],
  ))
}

resource "cloudflare_zero_trust_access_service_token" "ci_smoke_tests" {
  account_id = var.account_id
  name       = "ci-smoke-tests"
  duration   = "8760h"
}

# "Service Auth" in the dashboard: lets the token through without a login.
resource "cloudflare_zero_trust_access_policy" "ci_smoke_tests" {
  account_id = var.account_id
  name       = "ci-smoke-tests service token"
  decision   = "non_identity"
  include = [{
    service_token = { token_id = cloudflare_zero_trust_access_service_token.ci_smoke_tests.id }
  }]
}

resource "cloudflare_zero_trust_access_policy" "bypass" {
  account_id = var.account_id
  name       = "public (bypass)"
  decision   = "bypass"
  include    = [{ everyone = {} }]
}

resource "cloudflare_zero_trust_access_application" "private" {
  for_each = local.private_hostnames

  account_id                = var.account_id
  name                      = "${each.key}.${var.zone_name}"
  type                      = "self_hosted"
  destinations              = [{ type = "public", uri = "${each.key}.${var.zone_name}" }]
  session_duration          = lookup(local.app_session, each.key, "24h")
  allowed_idps              = [local.otp_idp_id]
  auto_redirect_to_identity = true
  app_launcher_visible      = false

  policies = concat(
    [{ id = lookup(local.app_policy_id, each.key, cloudflare_zero_trust_access_policy.allow_owner.id), precedence = 1 }],
    contains(var.service_token_hostnames, each.key) || try(var.app_access[each.key].service_token, false) ? [{ id = cloudflare_zero_trust_access_policy.ci_smoke_tests.id, precedence = 2 }] : [],
  )
}

resource "cloudflare_zero_trust_access_application" "public" {
  for_each = local.public_hostnames

  account_id           = var.account_id
  name                 = "${each.key}.${var.zone_name} (public)"
  type                 = "self_hosted"
  destinations         = [{ type = "public", uri = "${each.key}.${var.zone_name}" }]
  app_launcher_visible = false
  policies             = [{ id = cloudflare_zero_trust_access_policy.bypass.id, precedence = 1 }]
}

# Home apps behind Authelia: a Cloudflare Access login in front of it (both
# logins apply). The set is home_access plus the app_access entries of kind home. Only the Access app is made here; the DNS record is hand-made
# and the origin is untouched. Machine paths get a bypass app with a more
# specific path (Access applies the most specific path).
resource "cloudflare_zero_trust_access_application" "home" {
  for_each = local.home_effective

  account_id                = var.account_id
  name                      = "${each.key}.${var.zone_name} (Home, in front of Authelia)"
  type                      = "self_hosted"
  destinations              = [{ type = "public", uri = "${each.key}.${var.zone_name}" }]
  session_duration          = each.value.session_duration
  allowed_idps              = [local.otp_idp_id]
  auto_redirect_to_identity = true
  app_launcher_visible      = false

  policies = concat(
    [{ id = lookup(local.app_policy_id, each.key, cloudflare_zero_trust_access_policy.allow_owner.id), precedence = 1 }],
    contains(var.service_token_hostnames, each.key) || each.value.service_token ? [{ id = cloudflare_zero_trust_access_policy.ci_smoke_tests.id, precedence = 2 }] : [],
  )
}

resource "cloudflare_zero_trust_access_application" "home_bypass" {
  for_each = local.home_bypass

  account_id           = var.account_id
  name                 = "${each.value.label}.${var.zone_name}${each.value.path} (public path)"
  type                 = "self_hosted"
  destinations         = [{ type = "public", uri = "${each.value.label}.${var.zone_name}${each.value.path}" }]
  app_launcher_visible = false
  policies             = [{ id = cloudflare_zero_trust_access_policy.bypass.id, precedence = 1 }]
}

# Preview environments pr-<n>.<zone>: private, plus the smoke-test token.
# A partial-label wildcard ("*test.example.com") is documented for Access
# app hostnames; no plan restriction is documented.
resource "cloudflare_zero_trust_access_application" "previews" {
  account_id                = var.account_id
  name                      = "pr-* previews"
  type                      = "self_hosted"
  destinations              = [{ type = "public", uri = "pr-*.${var.zone_name}" }]
  session_duration          = "24h"
  allowed_idps              = [local.otp_idp_id]
  auto_redirect_to_identity = true
  app_launcher_visible      = false

  policies = [
    { id = cloudflare_zero_trust_access_policy.allow_owner.id, precedence = 1 },
    { id = cloudflare_zero_trust_access_policy.ci_smoke_tests.id, precedence = 2 },
  ]
}
