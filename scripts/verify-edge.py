#!/usr/bin/env python3
"""verify-edge.py: prove the Cloudflare edge in front of the apps, without logging in and without any credential.

For every host (a label under the zone):
  edge    an unauthenticated GET (redirects NOT followed) must end at the Cloudflare Access login: a 3xx whose Location is on
          *.cloudflareaccess.com. A challenge from Cloudflare itself (header cf-mitigated, or a 403 served by Cloudflare) is INCONCLUSIVE, not a
          failure: GitHub runner addresses may be challenged by Bot Fight Mode. Run it from the server (ChatOps) when it is inconclusive.
  origin  (hosts marked :home, needs --origin-ip) a request that skips Cloudflare (connects to the Home origin address with the host name as
          Host header and SNI, certificate not verified) must NOT be served by the app. 403, or no answer at all (refused, reset, timeout,
          TLS handshake refused), passes. Any other answer (200, 301, 302, 401, 404 ...) fails: Access could be walked around.
A host with no DNS record yet (the app is listed but not published) is SKIPPED with a line saying so: nothing can reach it.
Exit 1 when any check FAILS. One line per host and check. The origin address and every token stay out of the output.

  verify-edge.py --hosts dozzle:home,hello,changes --zone <your-domain> [--origin-ip IP | env HOME_ORIGIN_IP] [--app-access JSON | env APP_ACCESS]

--hosts items are `label` or `label:home`; labels of --app-access (the APP_ACCESS repository variable, JSON) are added, kind home implies :home.
Standard library only. Tested with fake responses only (scripts/test_verify_edge.py); never run against the real edge from this repo's CI before the
first scheduled run of .github/workflows/access-verify.yml.
"""
import argparse
import http.client
import json
import os
import re
import socket
import ssl
import sys
from urllib.parse import urlsplit

LABEL_RE = re.compile(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$')
PASS, FAIL, INCONCLUSIVE = 'PASS', 'FAIL', 'INCONCLUSIVE'
USER_AGENT = 'access-edge-verify/1'


class Reply:
    """What a probe saw: a status and lower-case headers, or an error class name (never the address)."""

    def __init__(self, status=None, headers=None, error=None):
        self.status = status
        self.headers = {k.lower(): v for k, v in (headers or {}).items()}
        self.error = error


def parse_hosts(spec, app_access=None):
    """'a:home,b' + {'c': {'kind': 'home'}} -> {'a': True, 'b': False, 'c': True} (label -> is a Home app). Raises ValueError on a bad label."""
    out = {}
    for item in [i.strip() for i in (spec or '').split(',') if i.strip()]:
        label, _, tag = item.partition(':')
        if not LABEL_RE.match(label) or tag not in ('', 'home', 'cluster'):
            raise ValueError(f'bad host entry {item!r}: use label or label:home')
        out[label] = out.get(label, False) or tag == 'home'
    for label, a in (app_access or {}).items():
        if not LABEL_RE.match(label):
            raise ValueError(f'bad label {label!r} in app_access')
        out[label] = out.get(label, False) or (isinstance(a, dict) and a.get('kind') == 'home')
    return out


def fetch_edge(host, timeout):
    """Real probe: HTTPS GET /, no redirect following."""
    conn = http.client.HTTPSConnection(host, 443, timeout=timeout, context=ssl.create_default_context())
    try:
        conn.request('GET', '/', headers={'Host': host, 'User-Agent': USER_AGENT, 'Accept': 'text/html'})
        r = conn.getresponse()
        r.read(512)
        return Reply(r.status, dict(r.getheaders()))
    except (OSError, http.client.HTTPException) as e:
        return Reply(error=type(e).__name__)
    finally:
        conn.close()


class _OriginConnection(http.client.HTTPSConnection):
    """HTTPS to a fixed address with the host name as Host and SNI, certificate not verified (the origin presents its own)."""

    def __init__(self, host, ip, timeout):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        super().__init__(host, 443, timeout=timeout, context=ctx)
        self._ip = ip

    def connect(self):
        sock = socket.create_connection((self._ip, 443), self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


def fetch_origin(host, ip, timeout):
    conn = _OriginConnection(host, ip, timeout)
    try:
        conn.request('GET', '/', headers={'Host': host, 'User-Agent': USER_AGENT})
        r = conn.getresponse()
        r.read(512)
        return Reply(r.status, dict(r.getheaders()))
    except (OSError, http.client.HTTPException) as e:        # refused, reset, timeout, handshake refused: the origin did not serve us
        return Reply(error=type(e).__name__)
    finally:
        conn.close()


def judge_edge(reply):
    """-> (verdict, text)."""
    if reply.error:
        return FAIL, f'no answer from the edge ({reply.error})'
    if 'cf-mitigated' in reply.headers:
        return INCONCLUSIVE, f'Cloudflare challenged this client (cf-mitigated: {reply.headers["cf-mitigated"]}); run it from another address'
    loc = reply.headers.get('location', '')
    host = (urlsplit(loc).hostname or '').lower()
    if reply.status in (301, 302, 303, 307, 308) and (host == 'cloudflareaccess.com' or host.endswith('.cloudflareaccess.com')):
        return PASS, f'{reply.status} to the Cloudflare Access login'
    if reply.status == 403 and 'cloudflare' in reply.headers.get('server', '').lower():
        return INCONCLUSIVE, '403 served by Cloudflare (probably a bot challenge for this client)'
    if reply.status in (301, 302, 303, 307, 308):
        return FAIL, f'{reply.status} to {host or "?"}, not the Access login'
    return FAIL, f'answered {reply.status} without a login: NOT behind Access'


def judge_origin(reply):
    if reply.error:
        return PASS, f'origin did not answer a direct request ({reply.error})'
    if reply.status == 403:
        return PASS, 'origin answers 403 to a direct request'
    return FAIL, f'origin answered {reply.status} to a request that skipped Cloudflare: Access can be walked around'


def run(hosts, zone, origin_ip, timeout, edge=fetch_edge, origin=fetch_origin, out=print):
    """hosts: {label: is_home}. -> exit code. `edge` and `origin` are injectable for tests."""
    fails = inconclusive = checked = skipped = 0
    for label in sorted(hosts):
        fqdn = f'{label}.{zone}'
        reply = edge(fqdn, timeout)
        if reply.error == 'gaierror':        # no DNS record: the app is not published (yet), so there is nothing to reach and nothing to protect
            out(f'SKIP {label}: {fqdn} has no DNS record (not published yet); checked as soon as it exists')
            skipped += 1
            continue
        checks = [('edge', *judge_edge(reply))]
        if hosts[label]:
            if origin_ip:
                checks.append(('origin', *judge_origin(origin(fqdn, origin_ip, timeout))))
            else:
                out(f'SKIP {label} origin: no origin address given (HOME_ORIGIN_IP)')
        for name, verdict, text in checks:
            out(f'{verdict} {label} {name}: {text}')
            checked += 1
            fails += verdict == FAIL
            inconclusive += verdict == INCONCLUSIVE
    out(f'{checked} checks: {checked - fails - inconclusive} pass, {fails} fail, {inconclusive} inconclusive' + (f', {skipped} skipped (no DNS record)' if skipped else ''))
    if inconclusive:
        out('INCONCLUSIVE is not a failure: Cloudflare challenged this client. Run `access verify` from the server (ChatOps) to see the real answer.')
    return 1 if fails else 0


def main(argv=None, edge=fetch_edge, origin=fetch_origin, out=print):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--hosts', default='')
    ap.add_argument('--zone', default=os.environ.get('ZONE_NAME', ''))
    ap.add_argument('--origin-ip', default=os.environ.get('HOME_ORIGIN_IP', ''))
    ap.add_argument('--app-access', default=os.environ.get('APP_ACCESS', ''))
    ap.add_argument('--timeout', type=float, default=8.0)
    a = ap.parse_args(argv)
    try:
        app_access = json.loads(a.app_access) if a.app_access.strip() else {}
        if not isinstance(app_access, dict):
            raise ValueError('app_access must be a JSON object')
        hosts = parse_hosts(a.hosts, app_access)
    except ValueError as e:
        out(f'error: {e}')
        return 2
    if not hosts:
        out('error: no hosts (--hosts, or APP_ACCESS)')
        return 2
    if not re.fullmatch(r'([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}', a.zone or ''):
        out('error: your domain is required: --zone mydomain.org, or the environment variable ZONE_NAME')
        return 2
    if a.origin_ip:
        try:
            socket.inet_aton(a.origin_ip) if '.' in a.origin_ip else socket.inet_pton(socket.AF_INET6, a.origin_ip)
        except OSError:
            out('error: --origin-ip is not an IP address')
            return 2
    return run(hosts, a.zone, a.origin_ip.strip(), a.timeout, edge, origin, out)


if __name__ == '__main__':
    sys.exit(main())
