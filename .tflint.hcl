# There is no official tflint ruleset for the Cloudflare provider; the
# bundled terraform ruleset (naming, unused declarations, pinned versions...)
# is what we run. Resource and attribute names are checked by
# `tofu validate` against the provider schema.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
