#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Local HTTPS endpoint tests using throwaway config and a self-signed certificate."""
import base64
import importlib.util
import json
import ssl
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from urllib.parse import unquote, urlsplit, parse_qs
from pathlib import Path


class SubscriptionTest(unittest.TestCase):
    def test_https_remote_profile_and_token_rotation(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            cert = root / "test.crt"
            key = root / "test.key"
            subprocess.run(
                ["openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048",
                 "-days", "1", "-keyout", str(key), "-out", str(cert),
                 "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            conf = root / "snell.conf"
            conf.write_text(
                "[snell-server]\nlisten = 0.0.0.0:17888\n"
                "psk = test-secret-strong-psk\nmode = default\n",
                encoding="utf-8",
            )
            settings = root / "settings.json"
            options = {
                "token": "a" * 64, "listen_port": 18443,
                "node_name": "Snell-v6", "snell_address": "203.0.113.10",
                "domain": "localhost", "bind_family": "ipv4",
            }
            settings.write_text(json.dumps(options), encoding="utf-8")
            spec = importlib.util.spec_from_file_location(
                "subscription_server", Path(__file__).parents[1] /
                "snell-v6-subscription-server.py",
            )
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            mod.SETTINGS, mod.SNELL_CONF = settings, conf
            mod.CERT, mod.KEY = cert, key
            server = mod.TLSHTTPServer(("127.0.0.1", 0), mod.Handler)
            options["listen_port"] = server.server_address[1]
            settings.write_text(json.dumps(options), encoding="utf-8")
            ctx = ssl.create_default_context(cafile=str(cert))
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()

            def request(token, path="config.json"):
                url = f"https://localhost:{server.server_address[1]}/s/{token}/{path}"
                return urllib.request.urlopen(url, context=ctx, timeout=5)

            def passwall_node(token):
                with request(token, "passwall.txt") as response:
                    self.assertEqual(response.status, 200)
                    self.assertIn("text/plain", response.headers["Content-Type"])
                    subscription = base64.b64decode(response.read(), validate=False).decode("utf-8")
                nodes = [x for x in subscription.splitlines() if x.strip()]
                self.assertEqual(len(nodes), 1)
                parsed = urlsplit(nodes[0])
                self.assertEqual(parsed.scheme, "snell")
                self.assertEqual(parsed.hostname, options["snell_address"])
                self.assertEqual(unquote(parsed.username), "test-secret-strong-psk")
                self.assertEqual(parse_qs(parsed.query), {"version": ["6"], "mode": ["default"]})
                self.assertEqual(unquote(parsed.fragment), "Snell-v6")
                return parsed.port

            try:
                with request("a" * 64) as response:
                    self.assertEqual(response.status, 200)
                    self.assertEqual(response.headers["Cache-Control"], "no-store, private")
                    profile = json.load(response)
                self.assertEqual(profile["outbounds"][0]["server_port"], 17888)
                self.assertEqual(profile["outbounds"][0]["psk"], "test-secret-strong-psk")
                self.assertEqual(passwall_node("a" * 64), 17888)
                with self.assertRaises(urllib.error.HTTPError) as bad:
                    request("x" * 64)
                self.assertEqual(bad.exception.code, 404)
                with self.assertRaises(urllib.error.HTTPError) as bad_pw:
                    request("x" * 64, "passwall.txt")
                self.assertEqual(bad_pw.exception.code, 404)

                conf.write_text(
                    "[snell-server]\nlisten = 0.0.0.0:25678\n"
                    "psk = test-secret-strong-psk\nmode = default\n",
                    encoding="utf-8",
                )
                with request("a" * 64) as response:
                    changed = json.load(response)
                self.assertEqual(changed["outbounds"][0]["server_port"], 25678)
                self.assertEqual(passwall_node("a" * 64), 25678)

                options["token"] = "b" * 64
                settings.write_text(json.dumps(options), encoding="utf-8")
                with self.assertRaises(urllib.error.HTTPError) as revoked:
                    request("a" * 64)
                self.assertEqual(revoked.exception.code, 404)
                with request("b" * 64) as response:
                    self.assertEqual(response.status, 200)
                with self.assertRaises(urllib.error.HTTPError) as bad_after_rotation:
                    request("a" * 64, "passwall.txt")
                self.assertEqual(bad_after_rotation.exception.code, 404)
                self.assertEqual(passwall_node("b" * 64), 25678)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)


    def test_passwall_ipv6_authority(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            cfg = root / "snell.conf"
            cfg.write_text("[snell-server]\nlisten = [::]:17888\n"
                           "psk = strong-ipv6-test-secret\nmode = default\n",
                           encoding="utf-8")
            spec = importlib.util.spec_from_file_location(
                "subscription_server_ipv6", Path(__file__).parents[1] /
                "snell-v6-subscription-server.py",
            )
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            mod.SNELL_CONF = cfg
            encoded = mod.passwall_subscription({
                "node_name": "Snell-v6", "snell_address": "2001:db8::1"
            })
            link = base64.b64decode(encoded).decode("utf-8").strip()
            parsed = urlsplit(link)
            self.assertEqual(parsed.hostname, "2001:db8::1")
            self.assertEqual(parsed.port, 17888)
            self.assertIn("[2001:db8::1]:17888", link)


if __name__ == "__main__":
    unittest.main()
