"""Unit tests for verify-edge.py with fake replies (no network, no real address). Run: cd scripts && python3 -m unittest -v test_verify_edge"""
import importlib.util
import os
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('verify_edge', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'verify-edge.py'))
ve = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ve)
R = ve.Reply
LOGIN = {'location': 'https://example-team.cloudflareaccess.com/cdn-cgi/access/login/dozzle.example.com?kid=abc'}


class Judge(unittest.TestCase):
    def test_edge_redirect_to_access_passes(self):
        self.assertEqual(ve.judge_edge(R(302, LOGIN))[0], ve.PASS)

    def test_edge_uppercase_header_names_and_other_3xx(self):
        self.assertEqual(ve.judge_edge(R(307, {'Location': LOGIN['location']}))[0], ve.PASS)

    def test_edge_look_alike_host_fails(self):
        r = R(302, {'location': 'https://cloudflareaccess.com.evil.example/login'})
        self.assertEqual(ve.judge_edge(r)[0], ve.FAIL)
        self.assertEqual(ve.judge_edge(R(302, {'location': 'https://notcloudflareaccess.com/x'}))[0], ve.FAIL)

    def test_edge_redirect_elsewhere_fails(self):
        self.assertEqual(ve.judge_edge(R(302, {'location': 'https://auth.example.com/?rd=x'}))[0], ve.FAIL)

    def test_edge_page_without_login_fails(self):
        v, text = ve.judge_edge(R(200, {}))
        self.assertEqual(v, ve.FAIL)
        self.assertIn('NOT behind Access', text)

    def test_edge_challenge_is_inconclusive(self):
        self.assertEqual(ve.judge_edge(R(403, {'cf-mitigated': 'challenge'}))[0], ve.INCONCLUSIVE)
        self.assertEqual(ve.judge_edge(R(403, {'server': 'cloudflare'}))[0], ve.INCONCLUSIVE)

    def test_edge_403_not_from_cloudflare_fails(self):
        self.assertEqual(ve.judge_edge(R(403, {'server': 'nginx'}))[0], ve.FAIL)

    def test_edge_no_answer_fails(self):
        self.assertEqual(ve.judge_edge(R(error='TimeoutError'))[0], ve.FAIL)

    def test_origin_403_and_no_answer_pass(self):
        self.assertEqual(ve.judge_origin(R(403))[0], ve.PASS)
        self.assertEqual(ve.judge_origin(R(error='ConnectionRefusedError'))[0], ve.PASS)
        self.assertEqual(ve.judge_origin(R(error='SSLError'))[0], ve.PASS)

    def test_origin_serving_the_app_fails(self):
        for status in (200, 301, 302, 401, 404, 502):
            self.assertEqual(ve.judge_origin(R(status))[0], ve.FAIL, status)


class Hosts(unittest.TestCase):
    def test_parse(self):
        got = ve.parse_hosts('dozzle:home, hello ,changes', {'draw': {'kind': 'home'}, 'prices': {'kind': 'cluster'}, 'hello': {'kind': 'cluster'}})
        self.assertEqual(got, {'dozzle': True, 'hello': False, 'changes': False, 'draw': True, 'prices': False})

    def test_kind_home_wins_over_plain_entry(self):
        self.assertEqual(ve.parse_hosts('draw', {'draw': {'kind': 'home'}}), {'draw': True})

    def test_bad_labels_rejected(self):
        for bad in ('a.b', 'Up', 'x:elsewhere', '-x'):
            with self.assertRaises(ValueError):
                ve.parse_hosts(bad)


class Run(unittest.TestCase):
    def setUp(self):
        self.lines = []
        self.seen_origin = []

    def origin(self, fqdn, ip, timeout):
        self.seen_origin.append((fqdn, ip))
        return R(403)

    def go(self, hosts, ip='192.0.2.10', edge=None):
        edge = edge or (lambda fqdn, t: R(302, LOGIN))
        return ve.run(hosts, 'example.com', ip, 3, edge, self.origin, self.lines.append)

    def test_all_good(self):
        self.assertEqual(self.go({'dozzle': True, 'hello': False}), 0)
        self.assertEqual(self.seen_origin, [('dozzle.example.com', '192.0.2.10')])
        self.assertIn('3 checks: 3 pass, 0 fail, 0 inconclusive', self.lines[-1])

    def test_origin_check_only_for_home_apps_and_needs_an_address(self):
        self.assertEqual(self.go({'dozzle': True}, ip=''), 0)
        self.assertEqual(self.seen_origin, [])
        self.assertTrue(any(l.startswith('SKIP dozzle origin') for l in self.lines))

    def test_failing_origin_fails_the_run(self):
        def origin(fqdn, ip, t):
            return R(200)
        code = ve.run({'dozzle': True}, 'example.com', '192.0.2.10', 3, lambda f, t: R(302, LOGIN), origin, self.lines.append)
        self.assertEqual(code, 1)
        self.assertTrue(any(l.startswith('FAIL dozzle origin') for l in self.lines))

    def test_unprotected_edge_fails(self):
        self.assertEqual(self.go({'hello': False}, edge=lambda f, t: R(200)), 1)

    def test_inconclusive_does_not_fail_but_says_so(self):
        self.assertEqual(self.go({'hello': False}, edge=lambda f, t: R(403, {'cf-mitigated': 'challenge'})), 0)
        self.assertTrue(any('INCONCLUSIVE is not a failure' in l for l in self.lines))

    def test_output_never_contains_the_origin_address(self):
        self.go({'dozzle': True, 'hello': False})
        self.assertFalse(any('192.0.2.10' in l for l in self.lines))


class NoDns(unittest.TestCase):
    def test_host_without_dns_is_skipped_not_failed(self):
        lines = []
        code = ve.run({'deps': True, 'hello': False}, 'example.com', '192.0.2.10', 1,
                      edge=lambda f, t: R(error='gaierror') if f.startswith('deps.') else R(302, LOGIN),
                      origin=lambda f, ip, t: self.fail('the origin of a host without DNS must not be probed'), out=lines.append)
        self.assertEqual(code, 0)
        self.assertTrue(any(l.startswith('SKIP deps') and 'no DNS record' in l for l in lines))
        self.assertTrue(any('hello edge' in l and l.startswith('PASS') for l in lines))

    def test_other_errors_still_fail(self):
        self.assertEqual(ve.run({'hello': False}, 'example.com', '', 1, edge=lambda f, t: R(error='TimeoutError'), out=[].append), 1)


class Main(unittest.TestCase):
    def setUp(self):
        # the workflow sets APP_ACCESS / HOME_ORIGIN_IP for the whole job: the tests must not depend on the caller's environment
        p = mock.patch.dict(os.environ)
        p.start()
        self.addCleanup(p.stop)
        os.environ.pop('APP_ACCESS', None)
        os.environ.pop('HOME_ORIGIN_IP', None)

    def test_main_reads_app_access_and_origin_ip(self):
        lines, seen = [], []
        code = ve.main(['--hosts', 'hello', '--zone', 'example.com', '--app-access', '{"draw":{"kind":"home"}}', '--origin-ip', '192.0.2.10'],
                       edge=lambda f, t: R(302, LOGIN), origin=lambda f, ip, t: seen.append(f) or R(403), out=lines.append)
        self.assertEqual(code, 0)
        self.assertEqual(seen, ['draw.example.com'])

    def test_main_rejects_bad_input(self):
        out = []
        self.assertEqual(ve.main(['--hosts', 'a.b'], out=out.append), 2)
        self.assertEqual(ve.main([], out=out.append), 2)
        self.assertEqual(ve.main(['--hosts', 'hello', '--zone', 'example.com', '--origin-ip', 'nonsense'], out=out.append), 2)
        self.assertEqual(ve.main(['--hosts', 'hello'], out=out.append), 2)  # no zone: refused instead of probing a placeholder domain
        self.assertEqual(ve.main(['--hosts', 'hello', '--app-access', '[1]'], out=out.append), 2)
        self.assertEqual(ve.main(['--hosts', 'hello', '--app-access', 'not json'], out=out.append), 2)


if __name__ == '__main__':
    unittest.main()
