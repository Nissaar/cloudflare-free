variable "account_id" {
  description = "Cloudflare account id (CI: repository variable CLOUDFLARE_ACCOUNT_ID)."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.account_id))
    error_message = "account_id is the 32-character hex id shown on the Cloudflare dashboard overview."
  }
}

variable "zone_name" {
  description = "YOUR domain: the zone that is active in your Cloudflare account. Every hostname this repo makes is <name>.<zone_name> (Universal SSL covers one level only). CI: repository variable ZONE_NAME. Required: no default on purpose."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,}$", var.zone_name)) && !contains(["example.com", "example.net", "example.org", "your-domain.example"], var.zone_name)
    error_message = "zone_name is your own domain in lower case (for example mydomain.org), not the example.com placeholder."
  }
}

variable "tunnel_name" {
  description = "Name of the Cloudflare Tunnel that connects the cluster. Name only: changing it later makes a new tunnel (a new token for cloudflared)."
  type        = string
  default     = "oke-free"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$", var.tunnel_name))
    error_message = "tunnel_name uses letters, digits, dot, dash and underscore (up to 63 characters)."
  }
}

variable "r2_location" {
  description = "Location hint of the R2 bucket `backups` (most writes should come from near it). Changing it later REPLACES the bucket (data loss): choose once. CI: optional repository variable R2_LOCATION."
  type        = string
  default     = "weur"

  validation {
    condition     = contains(["wnam", "enam", "weur", "eeur", "apac", "oc"], var.r2_location)
    error_message = "r2_location is one of wnam, enam, weur, eeur, apac, oc."
  }
}

variable "allowed_emails" {
  description = "Emails that may log in to private hostnames with a one-time PIN (CI: repository variable ALLOWED_EMAILS, a JSON list)."
  type        = list(string)
  sensitive   = true

  validation {
    condition     = length(var.allowed_emails) > 0 && alltrue([for e in var.allowed_emails : can(regex("^[^@\\s<>*]+@[^@\\s<>*]+\\.[^@\\s<>*]+$", e))])
    error_message = "allowed_emails must be a non-empty list of email addresses (no wildcard, no <placeholder>): they are the only people who can pass the login of a private hostname."
  }
}

variable "otp_idp_id" {
  description = "Id of an existing One-time PIN login method. Empty: OpenTofu creates one. Set it (CI: OTP_IDP_ID) only if One-time PIN already exists in Zero Trust -> Settings -> Authentication."
  type        = string
  default     = ""
}

variable "cluster_hostnames" {
  description = "Hostnames served by the OKE cluster through the tunnel: label -> { public }. Private (public = false) means behind Cloudflare Access."
  type = map(object({
    public = bool
  }))
  default = {
    hello = { public = false }
  }

  validation {
    condition     = alltrue([for name in keys(var.cluster_hostnames) : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", name))])
    error_message = "Keys are single DNS labels (a-z, 0-9, '-'): Universal SSL does not cover x.y.example.com."
  }

  validation {
    condition     = alltrue([for name in keys(var.cluster_hostnames) : !startswith(name, "pr-") && !endswith(name, "-standby")])
    error_message = "pr-* is reserved for preview environments and *-standby for failover copies (added automatically)."
  }
}

variable "home_access" {
  description = <<-EOT
    Hand-made Home hostnames that get a Cloudflare Access login IN FRONT of their own login (Authelia):
    label -> { bypass_paths }. Only the Access application is created here: the DNS record stays hand-made
    (proxied, pointing at Home) and the origin keeps its Authelia rule. bypass_paths are the public
    sub-paths that machines need (they get a bypass application with a more specific path, which Access
    prefers): a trailing * is a prefix match.
  EOT
  type = map(object({
    bypass_paths = optional(list(string), [])
  }))
  default = {}

  validation {
    condition     = alltrue([for name in keys(var.home_access) : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", name))])
    error_message = "Keys are single DNS labels (a-z, 0-9, '-')."
  }

  validation {
    condition     = alltrue(flatten([for a in values(var.home_access) : [for path in a.bypass_paths : startswith(path, "/")]]))
    error_message = "bypass_paths start with a slash (a trailing * is a prefix match)."
  }

  validation {
    condition     = length(setintersection(keys(var.home_access), keys(var.cluster_hostnames))) == 0
    error_message = "A label is either a cluster hostname or a Home one, not both."
  }
}

variable "app_access" {
  description = <<-EOT
    Per-app Cloudflare Access settings, generated from <home-server-repo>/access/apps.yaml (`python3 access/access.py cloudflare`)
    (CI: repository variable APP_ACCESS, a JSON object; not secret). label -> { kind, session_duration, bypass_paths, service_token }.
    kind "cluster": the label must be a PRIVATE cluster_hostnames label (typo guard); it only changes that app's session length and
    who may open it. kind "home": the hostname is a hand-made Home record; the entry creates (or overrides, if the label is
    also in home_access) its Access app and is authoritative for session_duration, bypass_paths and service_token.
    The people allowed per label are in app_access_emails. Empty: nothing changes.
  EOT
  type = map(object({
    kind             = string
    session_duration = optional(string, "24h")
    bypass_paths     = optional(list(string))
    service_token    = optional(bool, false)
  }))
  default = {}

  validation {
    condition     = alltrue([for label in keys(var.app_access) : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", label))])
    error_message = "app_access keys are single DNS labels (a-z, 0-9, '-')."
  }

  validation {
    condition     = alltrue([for a in values(var.app_access) : contains(["home", "cluster"], a.kind)])
    error_message = "app_access kind is \"home\" or \"cluster\"."
  }

  validation {
    condition     = alltrue([for a in values(var.app_access) : can(regex("^[1-9][0-9]{0,3}(m|h)$", a.session_duration))])
    error_message = "session_duration looks like 30m, 6h, 24h."
  }

  validation {
    condition     = alltrue(flatten([for a in values(var.app_access) : [for path in coalesce(a.bypass_paths, []) : startswith(path, "/")]]))
    error_message = "bypass_paths start with a slash (a trailing * is a prefix match)."
  }

  validation {
    condition = alltrue([
      for label, a in var.app_access : a.kind != "cluster" || (contains(keys(var.cluster_hostnames), label) && !try(var.cluster_hostnames[label].public, true))
    ])
    error_message = "A kind \"cluster\" entry must name a PRIVATE label of cluster_hostnames (typo, or the hostname is public)."
  }

  validation {
    condition     = alltrue([for label, a in var.app_access : a.kind != "home" || !contains(keys(var.cluster_hostnames), label)])
    error_message = "A kind \"home\" entry cannot use a cluster_hostnames label."
  }
}

variable "app_access_emails" {
  description = <<-EOT
    Who may open each app_access label (CI: repository variable APP_ACCESS_EMAILS, a JSON object): label -> list of email
    addresses (lower case) or "*@domain" (a whole domain). The owner (allowed_emails) is ALWAYS allowed too and is not listed here.
    A label with at least one entry gets its own policy "app allow: <label>"; a label with none (or an empty list) keeps the global
    allowed_emails policy. Expired guests are already removed by the generator.
  EOT
  type        = map(list(string))
  sensitive   = true
  default     = {}

  validation {
    condition     = alltrue([for label in keys(var.app_access_emails) : contains(keys(var.app_access), label)])
    error_message = "Every key of app_access_emails must also be a key of app_access (label typo?)."
  }

  validation {
    condition     = alltrue([for emails in values(var.app_access_emails) : length(emails) <= 50])
    error_message = "At most 50 addresses per app (Cloudflare Access Free plan has 50 users)."
  }

  validation {
    condition = alltrue(flatten([
      for emails in values(var.app_access_emails) : [
        for e in emails : can(regex("^[^@\\s*]+@[^@\\s*]+\\.[^@\\s*]+$", e)) || can(regex("^\\*@[^@\\s*]+\\.[^@\\s*]+$", e))
      ]
    ]))
    error_message = "Entries are email addresses or \"*@domain\" (no other wildcard)."
  }
}

variable "cluster_origin" {
  description = "Where cloudflared in the cluster sends every hostname (Traefik's ClusterIP service, entrypoint web)."
  type        = string
  default     = "http://traefik.traefik.svc.cluster.local:80"

  validation {
    condition     = can(regex("^https?://[A-Za-z0-9._-]+(:[0-9]{1,5})?$", var.cluster_origin))
    error_message = "cluster_origin looks like http://traefik.traefik.svc.cluster.local:80."
  }
}

variable "service_token_hostnames" {
  description = "Private labels from cluster_hostnames that the ci-smoke-tests service token may also open (pr-* previews always allow it)."
  type        = list(string)
  default     = ["hello"]
}

variable "enable_preview_dns" {
  description = "Create a proxied wildcard *.<zone> CNAME to the tunnel plus a wildcard ingress rule, so pr-<n> preview hostnames reach the cluster. Hand-made records still win (explicit DNS records beat the wildcard). Fails if a hand-made * record already exists."
  type        = bool
  default     = false
}

variable "enable_failover" {
  description = "Deploy the failover Worker on ntfy (and the status hostname, if set) and publish their <label>-standby copies through the tunnel."
  type        = bool
  default     = false
}

variable "failover_status_hostname" {
  description = "Label of the status page hostname that the failover Worker also covers (for example \"status\"). Empty: ntfy only. Its standby is <label>-standby.<zone>."
  type        = string
  default     = ""

  validation {
    condition     = var.failover_status_hostname == "" || can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.failover_status_hostname))
    error_message = "failover_status_hostname is a single DNS label or empty."
  }
}

variable "failover_timeout_ms" {
  description = "How long the Worker waits for the Home origin's response headers before trying the standby."
  type        = number
  default     = 4000
}

variable "failover_standby_stream_max_s" {
  description = "Seconds after which the Worker ends a subscription stream (JSON/SSE/raw) that the standby serves. The ntfy app reconnects by itself and tries Home first, so subscribers move back within this time after Home recovers."
  type        = number
  default     = 300

  validation {
    condition     = var.failover_standby_stream_max_s >= 30 && var.failover_standby_stream_max_s <= 3600
    error_message = "failover_standby_stream_max_s must be between 30 and 3600."
  }
}
