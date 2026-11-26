# restic repositories: restic/home (Home backup service) and
# restic/cluster. The state bucket tfstate-cloudflare is NOT here: it is made
# by scripts/bootstrap.sh so the state never depends on itself.
resource "cloudflare_r2_bucket" "backups" {
  account_id = var.account_id
  name       = "backups"
  # Location hint only (most writes come from Home). Changing it later
  # replaces the bucket, so leave it alone once data is in (variable r2_location).
  location = var.r2_location
}
