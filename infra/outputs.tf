output "tunnel_id" {
  description = "Tunnel id (CNAME target is <id>.cfargotunnel.com)."
  value       = cloudflare_zero_trust_tunnel_cloudflared.oke.id
}

output "tunnel_token" {
  description = "cloudflared token. Goes into the OCI Vault secret cloudflared-tunnel-token (JSON key TUNNEL_TOKEN), which the cluster reads through External Secrets."
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.oke.token
  sensitive   = true
}

output "hostnames" {
  description = "Hostnames routed to the cluster and whether each is public."
  value       = { for name, h in local.hostnames : "${name}.${var.zone_name}" => h.public ? "public" : "Access" }
}

output "ci_smoke_tests_client_id" {
  description = "CF-Access-Client-Id header value for preview smoke tests."
  value       = cloudflare_zero_trust_access_service_token.ci_smoke_tests.client_id
}

output "ci_smoke_tests_client_secret" {
  description = "CF-Access-Client-Secret header value (only readable after the apply that created the token)."
  value       = cloudflare_zero_trust_access_service_token.ci_smoke_tests.client_secret
  sensitive   = true
}

output "r2_s3_endpoint" {
  description = "S3 endpoint for restic (s3:<endpoint>/backups/restic/...)."
  value       = "https://${var.account_id}.r2.cloudflarestorage.com"
}

output "failover_routes" {
  description = "Worker routes and their standby hostnames (empty when enable_failover = false)."
  value       = { for label, standby in local.failover_standby : "${label}.${var.zone_name}/*" => "${standby}.${var.zone_name}" }
}
