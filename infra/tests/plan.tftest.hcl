# Offline checks of the wiring (no Cloudflare credentials needed):
#   tofu -chdir=infra init -backend=false && tofu -chdir=infra test

# OpenTofu applies mock defaults during plan as well (Terraform needed
# `override_during = plan` for that; OpenTofu has no such argument).
mock_provider "cloudflare" {
  mock_data "cloudflare_zone" {
    defaults = {
      zone_id = "0123456789abcdef0123456789abcdef"
    }
  }
  mock_resource "cloudflare_zero_trust_tunnel_cloudflared" {
    defaults = {
      id = "11111111-2222-3333-4444-555555555555"
    }
  }
}

variables {
  account_id     = "fedcba9876543210fedcba9876543210"
  zone_name      = "zone.test"
  allowed_emails = ["someone@example.com"]
  # Pinned: the tests must not change every time a hostname is added to the real default.
  cluster_hostnames = { hello = { public = false } }
  # Pinned off: the "failover_on" run turns it on; the real default may change.
  enable_failover = false
  home_access     = {}
}

run "defaults" {
  command = plan

  assert {
    condition     = keys(cloudflare_dns_record.cluster) == ["hello"]
    error_message = "Only hello in the test setup."
  }
  assert {
    condition     = cloudflare_dns_record.cluster["hello"].content == "11111111-2222-3333-4444-555555555555.cfargotunnel.com" && cloudflare_dns_record.cluster["hello"].proxied
    error_message = "hello must be a proxied CNAME to the tunnel."
  }
  assert {
    condition     = cloudflare_dns_record.cluster["hello"].name == "hello.zone.test"
    error_message = "Wrong record name."
  }
  assert {
    condition     = keys(cloudflare_zero_trust_access_application.private) == ["hello"] && length(cloudflare_zero_trust_access_application.public) == 0
    error_message = "hello must be private."
  }
  assert {
    condition     = cloudflare_zero_trust_access_application.private["hello"].session_duration == "24h"
    error_message = "24 h session."
  }
  assert {
    condition     = length(cloudflare_zero_trust_access_application.private["hello"].policies) == 2
    error_message = "hello allows the owner and the ci-smoke-tests token."
  }
  assert {
    condition     = cloudflare_zero_trust_access_application.previews.destinations[0].uri == "pr-*.zone.test"
    error_message = "Preview app pattern."
  }
  assert {
    condition = jsonencode([for r in cloudflare_zero_trust_tunnel_cloudflared_config.oke.config.ingress : [r.hostname, r.service]]) == jsonencode([
      ["hello.zone.test", "http://traefik.traefik.svc.cluster.local:80"],
      [null, "http_status:404"],
    ])
    error_message = "Ingress must be hello then the 404 catch-all."
  }
  assert {
    condition     = length(cloudflare_workers_script.failover) == 0 && length(cloudflare_workers_route.failover) == 0 && length(cloudflare_dns_record.preview_wildcard) == 0
    error_message = "Failover and preview DNS are off in the test setup."
  }
  assert {
    condition     = length(cloudflare_zero_trust_access_identity_provider.otp) == 1
    error_message = "OTP login method is created when otp_idp_id is empty."
  }
}

run "failover_on" {
  command = plan

  variables {
    enable_failover          = true
    failover_status_hostname = "status"
    cluster_hostnames = {
      hello = { public = false }
      blog  = { public = true }
    }
  }

  assert {
    condition     = toset(keys(cloudflare_dns_record.cluster)) == toset(["hello", "blog", "ntfy-standby", "status-standby"])
    error_message = "Standby hostnames must be added to the tunnel."
  }
  assert {
    condition     = toset(keys(cloudflare_zero_trust_access_application.public)) == toset(["blog", "ntfy-standby", "status-standby"])
    error_message = "Standby and public hostnames get a bypass app."
  }
  assert {
    condition     = toset([for r in cloudflare_workers_route.failover : r.pattern]) == toset(["ntfy.zone.test/*", "status.zone.test/*"])
    error_message = "Worker routes."
  }
  assert {
    condition     = jsondecode(cloudflare_workers_script.failover[0].bindings[0].json) == { "ntfy.zone.test" = "ntfy-standby.zone.test", "status.zone.test" = "status-standby.zone.test" }
    error_message = "STANDBY_HOSTS binding."
  }
  assert {
    condition     = one([for b in cloudflare_workers_script.failover[0].bindings : b.text if b.name == "STANDBY_STREAM_MAX_MS"]) == "300000"
    error_message = "STANDBY_STREAM_MAX_MS binding (5 minutes by default)."
  }
  assert {
    condition     = cloudflare_zero_trust_access_application.public["ntfy-standby"].destinations[0].uri == "ntfy-standby.zone.test"
    error_message = "The cluster's ntfy standby (apps/ntfy-standby, Ingress host ntfy-standby.zone.test) is a public bypass hostname: ntfy does its own auth."
  }
  assert {
    condition     = !contains(keys(cloudflare_dns_record.cluster), "ntfy") && !contains(keys(cloudflare_zero_trust_access_application.private), "ntfy")
    error_message = "The hand-made ntfy record must never be managed or put behind Access."
  }
}

run "home_access" {
  command = plan

  variables {
    home_access = {
      draw  = {}
      umami = { bypass_paths = ["/script.js", "/api/send*"] }
    }
  }

  assert {
    condition     = toset(keys(cloudflare_zero_trust_access_application.home)) == toset(["draw", "umami"])
    error_message = "One Access app per Home label."
  }
  assert {
    condition     = cloudflare_zero_trust_access_application.home["umami"].destinations[0].uri == "umami.zone.test" && length(cloudflare_zero_trust_access_application.home["umami"].policies) == 1
    error_message = "Login for the whole hostname, owner only."
  }
  assert {
    condition     = toset([for a in cloudflare_zero_trust_access_application.home_bypass : a.destinations[0].uri]) == toset(["umami.zone.test/script.js", "umami.zone.test/api/send*"])
    error_message = "A bypass app per public path, with the full path."
  }
  assert {
    condition     = length(cloudflare_dns_record.cluster) == 1 && !contains(keys(cloudflare_dns_record.cluster), "draw") && !contains(keys(cloudflare_dns_record.cluster), "umami")
    error_message = "Home records stay hand-made: no DNS record, no tunnel rule for them."
  }
  assert {
    condition     = !contains([for r in cloudflare_zero_trust_tunnel_cloudflared_config.oke.config.ingress : r.hostname], "draw.zone.test")
    error_message = "Home hostnames never enter the tunnel config."
  }
}

run "home_access_rejects_clashes_and_bad_paths" {
  command = plan

  variables {
    home_access = { hello = {} }
  }

  expect_failures = [var.home_access]
}

run "home_access_rejects_a_path_without_slash" {
  command = plan

  variables {
    home_access = { draw = { bypass_paths = ["api/send"] } }
  }

  expect_failures = [var.home_access]
}

# ---- Per-app lists (app_access / app_access_emails). FAKE data only (example.com): tested with fake data, never against Cloudflare.

run "app_access_unset_changes_nothing" {
  command = plan

  assert {
    condition     = length(cloudflare_zero_trust_access_policy.app) == 0
    error_message = "No app_access: no per-app policy."
  }
  assert {
    condition     = cloudflare_zero_trust_access_application.private["hello"].policies[0].id == cloudflare_zero_trust_access_policy.allow_owner.id
    error_message = "Without a per-app list the global owner policy is used."
  }
}

run "app_list_gets_its_own_policy_with_owner" {
  command = plan

  variables {
    cluster_hostnames = {
      hello = { public = false }
      notes = { public = false }
      empty = { public = false }
    }
    app_access = {
      hello = { kind = "cluster", session_duration = "6h", service_token = true }
      empty = { kind = "cluster" }
    }
    app_access_emails = {
      hello = ["guest@example.com", "*@partner.example.org"]
      empty = []
    }
  }

  assert {
    condition     = keys(cloudflare_zero_trust_access_policy.app) == ["hello"]
    error_message = "Only a label with at least one address gets its own policy."
  }
  assert {
    condition     = cloudflare_zero_trust_access_policy.app["hello"].name == "app allow: hello" && cloudflare_zero_trust_access_policy.app["hello"].decision == "allow"
    error_message = "Policy name and decision."
  }
  assert {
    condition     = length(cloudflare_zero_trust_access_policy.app["hello"].include) == 3
    error_message = "Owner + one address + one domain."
  }
  assert {
    condition     = length([for i in cloudflare_zero_trust_access_policy.app["hello"].include : i if i.email != null && i.email.email == "someone@example.com"]) == 1
    error_message = "The owner (allowed_emails) is always included."
  }
  assert {
    condition     = length([for i in cloudflare_zero_trust_access_policy.app["hello"].include : i if i.email != null && i.email.email == "guest@example.com"]) == 1
    error_message = "The listed address is included."
  }
  assert {
    condition     = length([for i in cloudflare_zero_trust_access_policy.app["hello"].include : i if i.email_domain != null && i.email_domain.domain == "partner.example.org"]) == 1
    error_message = "*@domain becomes an email_domain rule."
  }
  assert {
    condition     = cloudflare_zero_trust_access_application.private["hello"].policies[0].id == cloudflare_zero_trust_access_policy.app["hello"].id
    error_message = "hello uses its own policy."
  }
  assert {
    condition     = cloudflare_zero_trust_access_application.private["hello"].session_duration == "6h"
    error_message = "Per-app session length."
  }
  assert {
    condition     = length(cloudflare_zero_trust_access_application.private["hello"].policies) == 2
    error_message = "The service-token policy stays (hello is in service_token_hostnames and service_token is true)."
  }
  assert {
    condition     = cloudflare_zero_trust_access_application.private["notes"].policies[0].id == cloudflare_zero_trust_access_policy.allow_owner.id && cloudflare_zero_trust_access_application.private["notes"].session_duration == "24h"
    error_message = "A label without an entry keeps the global owner list and 24 h."
  }
  assert {
    condition     = cloudflare_zero_trust_access_application.private["empty"].policies[0].id == cloudflare_zero_trust_access_policy.allow_owner.id
    error_message = "An empty list keeps the global owner list (default deny to everybody else)."
  }
  assert {
    condition     = length(cloudflare_zero_trust_access_application.private["notes"].policies) == 1 && length(cloudflare_zero_trust_access_application.private["empty"].policies) == 1
    error_message = "No service token unless asked for."
  }
}

run "app_access_home_kind_overrides_and_adds" {
  command = plan

  variables {
    home_access = {
      draw  = { bypass_paths = ["/old"] }
      umami = { bypass_paths = ["/script.js"] }
    }
    app_access = {
      draw   = { kind = "home", session_duration = "12h", bypass_paths = ["/new*"], service_token = true }
      umami  = { kind = "home" }
      newapp = { kind = "home", bypass_paths = [] }
    }
    app_access_emails = {
      draw = ["guest@example.com"]
    }
  }

  assert {
    condition     = toset(keys(cloudflare_zero_trust_access_application.home)) == toset(["draw", "umami", "newapp"])
    error_message = "home_access plus the app_access entries of kind home."
  }
  assert {
    condition     = cloudflare_zero_trust_access_application.home["draw"].session_duration == "12h" && cloudflare_zero_trust_access_application.home["umami"].session_duration == "24h"
    error_message = "Per-app session length."
  }
  assert {
    condition     = cloudflare_zero_trust_access_application.home["draw"].policies[0].id == cloudflare_zero_trust_access_policy.app["draw"].id && length(cloudflare_zero_trust_access_application.home["draw"].policies) == 2
    error_message = "draw: own list, plus the service token because app_access says so."
  }
  assert {
    condition     = cloudflare_zero_trust_access_application.home["umami"].policies[0].id == cloudflare_zero_trust_access_policy.allow_owner.id && length(cloudflare_zero_trust_access_application.home["umami"].policies) == 1
    error_message = "umami: no list, global owner policy."
  }
  assert {
    condition     = toset([for a in cloudflare_zero_trust_access_application.home_bypass : a.destinations[0].uri]) == toset(["draw.zone.test/new*", "umami.zone.test/script.js"])
    error_message = "app_access bypass_paths replace the home_access ones; a null list falls back to home_access; an empty list means none."
  }
  assert {
    condition     = length(cloudflare_dns_record.cluster) == 1 && !contains([for r in cloudflare_zero_trust_tunnel_cloudflared_config.oke.config.ingress : r.hostname], "newapp.zone.test")
    error_message = "Home records stay hand-made: no DNS record, no tunnel rule."
  }
}

run "app_access_cluster_kind_unknown_label_fails" {
  command = plan

  variables {
    app_access = { helo = { kind = "cluster" } }
  }

  expect_failures = [var.app_access]
}

run "app_access_cluster_kind_public_label_fails" {
  command = plan

  variables {
    cluster_hostnames = {
      hello = { public = false }
      blog  = { public = true }
    }
    app_access = { blog = { kind = "cluster" } }
  }

  expect_failures = [var.app_access]
}

run "app_access_home_kind_on_cluster_label_fails" {
  command = plan

  variables {
    app_access = { hello = { kind = "home" } }
  }

  expect_failures = [var.app_access]
}

run "app_access_bad_session_fails" {
  command = plan

  variables {
    app_access = { hello = { kind = "cluster", session_duration = "1 day" } }
  }

  expect_failures = [var.app_access]
}

run "app_access_bad_path_fails" {
  command = plan

  variables {
    app_access = { draw = { kind = "home", bypass_paths = ["api"] } }
  }

  expect_failures = [var.app_access]
}

run "app_access_bad_kind_and_label_fail" {
  command = plan

  variables {
    app_access = { "a.b" = { kind = "elsewhere" } }
  }

  expect_failures = [var.app_access]
}

run "app_access_emails_key_without_app_fails" {
  command = plan

  variables {
    app_access        = { hello = { kind = "cluster" } }
    app_access_emails = { helo = ["guest@example.com"] }
  }

  expect_failures = [var.app_access_emails]
}

run "app_access_emails_bad_address_fails" {
  command = plan

  variables {
    app_access        = { hello = { kind = "cluster" } }
    app_access_emails = { hello = ["not-an-address"] }
  }

  expect_failures = [var.app_access_emails]
}

run "app_access_emails_odd_wildcard_fails" {
  command = plan

  variables {
    app_access        = { hello = { kind = "cluster" } }
    app_access_emails = { hello = ["*@*.com"] }
  }

  expect_failures = [var.app_access_emails]
}

run "app_access_emails_more_than_50_fails" {
  command = plan

  variables {
    app_access        = { hello = { kind = "cluster" } }
    app_access_emails = { hello = [for i in range(51) : "guest${i}@example.com"] }
  }

  expect_failures = [var.app_access_emails]
}

run "preview_dns_and_existing_otp" {
  command = plan

  variables {
    enable_preview_dns = true
    otp_idp_id         = "99999999-2222-3333-4444-555555555555"
  }

  assert {
    condition     = cloudflare_dns_record.preview_wildcard[0].name == "*.zone.test"
    error_message = "Wildcard record."
  }
  assert {
    condition     = cloudflare_zero_trust_tunnel_cloudflared_config.oke.config.ingress[1].hostname == "*.zone.test"
    error_message = "Wildcard ingress sits after the named hosts, before the 404."
  }
  assert {
    condition     = length(cloudflare_zero_trust_access_identity_provider.otp) == 0 && cloudflare_zero_trust_access_application.private["hello"].allowed_idps == toset(["99999999-2222-3333-4444-555555555555"])
    error_message = "Existing OTP login method is reused."
  }
}

run "rejects_two_level_names" {
  command = plan

  variables {
    cluster_hostnames = { "a.b" = { public = false } }
  }

  expect_failures = [var.cluster_hostnames]
}

run "rejects_reserved_prefixes" {
  command = plan

  variables {
    cluster_hostnames = { "pr-1" = { public = false } }
  }

  expect_failures = [var.cluster_hostnames]
}

# ---- Required values of a stranger's copy: placeholders are refused before anything is planned.
run "rejects_the_example_zone" {
  command = plan
  variables {
    zone_name = "example.com"
  }
  expect_failures = [var.zone_name]
}

run "rejects_a_placeholder_email" {
  command = plan
  variables {
    allowed_emails = ["<your-email>@mydomain.org"]
  }
  expect_failures = [var.allowed_emails]
}

run "rejects_an_unknown_r2_location" {
  command = plan
  variables {
    r2_location = "mars"
  }
  expect_failures = [var.r2_location]
}
