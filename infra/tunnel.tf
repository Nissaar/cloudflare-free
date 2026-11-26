# Remotely managed tunnel: cloudflared in the cluster only needs the token;
# the ingress rules below live in Cloudflare.
resource "cloudflare_zero_trust_tunnel_cloudflared" "oke" {
  account_id = var.account_id
  name       = var.tunnel_name
  config_src = "cloudflare"
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "oke" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.oke.id
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "oke" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.oke.id
  source     = "cloudflare"

  config = {
    ingress = concat(
      [
        for name in sort(keys(local.hostnames)) : {
          hostname = "${name}.${var.zone_name}"
          service  = var.cluster_origin
        }
      ],
      # cloudflared only accepts a leading "*." wildcard, so previews use
      # *.<zone>; only names without their own DNS record ever reach it.
      var.enable_preview_dns ? [{
        hostname = "*.${var.zone_name}"
        service  = var.cluster_origin
      }] : [],
      [{ service = "http_status:404" }],
    )
  }
}

resource "cloudflare_dns_record" "cluster" {
  for_each = local.hostnames

  zone_id = local.zone_id
  name    = "${each.key}.${var.zone_name}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.oke.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "cloudflare-free: OKE tunnel (${each.value.public ? "public" : "Access"})"
}

resource "cloudflare_dns_record" "preview_wildcard" {
  count = var.enable_preview_dns ? 1 : 0

  zone_id = local.zone_id
  name    = "*.${var.zone_name}"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.oke.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "cloudflare-free: pr-* previews via the OKE tunnel (Access app protects pr-*)"
}
