# Failover Worker for ntfy (and optionally the status page): tries the
# Home origin first, then <label>-standby.<zone> (the cluster copy).
# Subscriptions (streams, websockets) fail over too; a stream served by the
# standby is ended after failover_standby_stream_max_s so the phone's app
# reconnects and comes back to Home once it answers again.
locals {
  failover_source = "${path.module}/../workers/failover/src/index.js"
}

resource "cloudflare_workers_script" "failover" {
  count = var.enable_failover ? 1 : 0

  account_id     = var.account_id
  script_name    = "failover"
  main_module    = "index.js"
  content_file   = local.failover_source
  content_sha256 = filesha256(local.failover_source)

  # Do NOT add the global_fetch_strictly_public flag: without it, fetch() to
  # the Worker's own hostname goes straight to the origin (Home) instead of
  # looping back into this Worker.
  compatibility_date = "2026-10-01"

  bindings = [
    {
      type = "json"
      name = "STANDBY_HOSTS"
      json = jsonencode({
        for label, standby in local.failover_standby :
        "${label}.${var.zone_name}" => "${standby}.${var.zone_name}"
      })
    },
    {
      type = "plain_text"
      name = "PRIMARY_TIMEOUT_MS"
      text = tostring(var.failover_timeout_ms)
    },
    {
      type = "plain_text"
      name = "STANDBY_STREAM_MAX_MS"
      text = tostring(var.failover_standby_stream_max_s * 1000)
    },
  ]

  observability = {
    enabled = true
  }
}

resource "cloudflare_workers_route" "failover" {
  for_each = var.enable_failover ? toset(local.failover_labels) : toset([])

  zone_id = local.zone_id
  pattern = "${each.key}.${var.zone_name}/*"
  script  = cloudflare_workers_script.failover[0].script_name

  # The standby hostname must exist before traffic can fail over to it.
  depends_on = [cloudflare_dns_record.cluster, cloudflare_zero_trust_tunnel_cloudflared_config.oke]
}
