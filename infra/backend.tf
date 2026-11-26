# State lives in the R2 bucket made by scripts/bootstrap.sh (not by OpenTofu).
# The endpoint depends on the account id, so CI passes it at init time:
#   tofu init -backend-config='endpoints={s3="https://<account-id>.r2.cloudflarestorage.com"}'
# Credentials: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY = the R2 S3 API keys.
terraform {
  backend "s3" {
    bucket = "tfstate-cloudflare"
    key    = "cloudflare-free/terraform.tfstate"
    region = "auto"

    # R2 is S3-compatible but not AWS: skip the AWS-only checks.
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true

    # S3-native locking (OpenTofu >= 1.10.0): a <key>.tflock object written with
    # If-None-Match. R2 supports that conditional PutObject.
    use_lockfile = true
  }
}
