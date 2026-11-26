# Hostnames: adding one, and switching an app over from Home

> **Note for other users of this repository.** Sections B and the Home-specific parts of A describe how the original author moved apps from a home server; the
> rest (one line in `cluster_hostnames` makes the DNS record, the tunnel rule and the Access login) is generic. Your domain is the variable `zone_name`.

A hostname of the cluster is one line in `cluster_hostnames`
(`infra/variables.tf`). From that line OpenTofu makes three things together:
a proxied CNAME `<app>.example.com` -> the tunnel, the matching ingress rule
in the tunnel config, and (when `public = false`) the Access application with
its login policy. Names are always a single label (`<app>.example.com`):
Universal SSL does not cover `x.y.example.com`.

## A. A new name (nothing exists under that name yet)

1. In the `k8s-free-gitops` repo the app must exist first (`apps/<app>/`, one line in
   `apps/kustomization.yaml`), merged, and Flux must show it Ready:
   `flux get kustomizations`. Otherwise the name goes live and answers 502.
2. `infra/variables.tf`: add `<app> = { public = false }` to the default of
   `cluster_hostnames`. `false` = Cloudflare Access login in front (one-time
   PIN to an allowed email; by default the owner list `ALLOWED_EMAILS`, or the
   app's own list once it has an entry in `<home-server-repo>/access/apps.yaml`,
   see docs/ACCESS.md). `true` = no Cloudflare login: use it for apps that have
   their own login and for mobile and git clients (an Access page breaks them).
3. Pull request -> the plan comment must show exactly: `cloudflare_dns_record.cluster["<app>"]`,
   the tunnel config (ingress list gains the name), and for `false` an Access
   application plus its policy. Nothing else. Merge -> Actions -> **tofu** ->
   **Run workflow** -> `apply`.
4. Check: `getent hosts <app>.example.com` answers Cloudflare addresses
   (104.x / 172.67.x), the page loads (login first when private).
5. Describe the app in `<home-server-repo>/access/apps.yaml` (method `cloudflare-access`,
   `where: cluster`, who may open it): its `kind: "cluster"` entry in `app_access`
   must name a label that exists here and is private, otherwise the plan fails.
   Add the Kuma monitor, the Dashy link and the NocoBase/ChatOps entries the
   other repos ask for. A private name needs the `ci-smoke-tests` service token
   headers in its Kuma monitor (add the label to `service_token_hostnames`).

## B. A name that already exists by hand (an app running in Home)

Existing records (`ntfy`, `git`, `nocobase`, `paperless`, ...) were made by
hand and this repo never takes them over. If you add such a label to
`cluster_hostnames`, the apply stops with "record already exists". That is on
purpose: switching a name is a decision, not a side effect. The switch:

1. Deploy the app in the cluster first and test it under a temporary label
   (`<app>-test = { public = false }`, steps A1 to A4). Move its data
   (app specific: stop writes, restic backup, restore into the cluster) and
   test again with the real data.
2. Write down the old record: Cloudflare -> `example.com` -> **DNS** ->
   **Records** -> `<app>` -> type, content, proxy status, TTL. This is the way
   back.
3. Delete that one record in the dashboard, then immediately merge and apply
   the change that adds `<app>` (and removes `<app>-test`). Cloudflare's proxy
   switches within seconds; plan for a short gap.
4. Check as in A4. Keep the Home container stopped but not removed for a
   week.
5. **Way back:** remove `<app>` from `cluster_hostnames` and apply (OpenTofu
   deletes its record), then recreate the old record from step 2 by hand.
6. Afterwards: the Home Kuma monitors the same URL (now through Access if
   private: add the service-token headers), the Traefik router on Home can
   go, and the checklist/ChatOps `coverage` list changes the owner of the name.

## C. Things to know

- Apps behind Authelia stay behind it only if they remain on Home.
  In the cluster the login is Cloudflare Access (or the app's own). A Home
  app can ALSO get a Cloudflare Access login in front of Authelia without
  moving: that is `home_access` or an `app_access` entry of kind `home`
  (docs/ACCESS.md): only an Access application is created, never a record or a
  tunnel rule.
- `enable_preview_dns` adds `*.example.com` for `pr-*` previews. A hand-made
  or tofu-made record for an exact name always wins over the wildcard.
- Failover (`enable_failover`) is separate: it serves the status page and
  `*-standby` copies when Home is down; it does not move DNS.
