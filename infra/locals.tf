locals {
  zone_id = data.cloudflare_zone.this.zone_id

  # Hostnames whose Home origin the failover Worker protects, and their
  # standby copies in the cluster (label -> standby label).
  failover_labels = compact(["ntfy", var.failover_status_hostname])
  failover_standby = var.enable_failover ? {
    for label in local.failover_labels : label => "${label}-standby"
  } : {}

  # Everything the tunnel serves. Standby copies must be public: the apps
  # behind them (ntfy, status page) do their own auth, like the originals.
  hostnames = merge(
    var.cluster_hostnames,
    { for label, standby in local.failover_standby : standby => { public = true } },
  )

  private_hostnames = { for name, h in local.hostnames : name => h if !h.public }
  public_hostnames  = { for name, h in local.hostnames : name => h if h.public }

  # Home apps that get an Access login in front of Authelia: home_access (hand-kept defaults) merged with the app_access entries of
  # kind "home" (generated from <home-server-repo>/access/apps.yaml). An app_access entry is authoritative for its label.
  home_effective = merge(
    { for label, a in var.home_access : label => { bypass_paths = a.bypass_paths, session_duration = "24h", service_token = false } },
    {
      for label, a in var.app_access : label => {
        bypass_paths     = a.bypass_paths != null ? a.bypass_paths : try(var.home_access[label].bypass_paths, [])
        session_duration = a.session_duration
        service_token    = a.service_token
      } if a.kind == "home"
    },
  )

  # Public sub-paths of the Home apps that stay reachable without a login: "<label><path>" -> {label, path}
  home_bypass = merge([
    for label, a in local.home_effective : { for path in a.bypass_paths : "${label}${path}" => { label = label, path = path } }
  ]...)

  # Labels that get their own "app allow" policy: at least one address in app_access_emails. The list is sensitive; only the label
  # names (not secret) leave it, so they can drive for_each.
  app_policy_labels = toset(nonsensitive([for label, emails in var.app_access_emails : label if length(emails) > 0]))

  # Per-app session length (default 24h as before) and the policies of an app: its own list or the global owner list, plus the CI token.
  app_session   = { for label, a in var.app_access : label => a.session_duration }
  app_policy_id = { for label, p in cloudflare_zero_trust_access_policy.app : label => p.id }

  otp_idp_id = var.otp_idp_id != "" ? var.otp_idp_id : cloudflare_zero_trust_access_identity_provider.otp[0].id
}

data "cloudflare_zone" "this" {
  filter = {
    name = var.zone_name
    account = {
      id = var.account_id
    }
  }
}
