#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Token-protected, HTTPS-only sing-box remote JSON for the standalone Snell v6 service."""
import argparse
import configparser
import hmac
import http.server
import json
import re
import socket
import ssl
from pathlib import Path

SETTINGS = Path("/etc/snell-v6/subscription/settings.json")
SNELL_CONF = Path("/etc/snell-v6/snell-server.conf")
CERT = Path("/etc/snell-v6/subscription/tls-fullchain.pem")
KEY = Path("/etc/snell-v6/subscription/tls-key.pem")


def read_settings():
    item = json.loads(SETTINGS.read_text(encoding="utf-8"))
    if not re.fullmatch(r"[a-f0-9]{64}", item["token"]):
        raise ValueError("Invalid subscription token")
    if not isinstance(item["listen_port"], int) or not 1024 <= item["listen_port"] <= 65535:
        raise ValueError("Invalid HTTPS port")
    return item


def profile(settings):
    cfg = configparser.ConfigParser(interpolation=None)
    with SNELL_CONF.open(encoding="utf-8") as f:
        cfg.read_file(f)
    psk = cfg.get("snell-server", "psk")
    mode = cfg.get("snell-server", "mode", fallback="default")
    if not (12 <= len(psk.encode("utf-8")) <= 255) or mode not in ("default", "unshaped"):
        raise ValueError("Invalid Snell credentials or encryption mode")
    listeners = [x.strip() for x in cfg.get("snell-server", "listen").split(",")]
    ports = set()
    for entry in listeners:
        match = re.fullmatch(
            r"(?:0\.0\.0\.0|\[::\]|(?:\d{1,3}\.){3}\d{1,3}|\[[0-9a-fA-F:]+\]):(\d{1,5})",
            entry,
        )
        if not match:
            raise ValueError("Unsupported Snell listening address")
        ports.add(int(match.group(1)))
    if len(ports) != 1:
        raise ValueError("Snell has conflicting listener ports")
    port = ports.pop()
    name = settings["node_name"]
    target = settings["snell_address"]
    return {
        "log": {"level": "warn"},
        "dns": {"servers": [{"type": "tcp", "tag": "remote-dns",
                             "server": "1.1.1.1", "server_port": 53, "detour": name}],
                "final": "remote-dns"},
        "inbounds": [{"type": "tun", "tag": "tun-in",
                      "address": ["172.19.0.1/30", "fd00:19::1/126"],
                      "auto_route": True}],
        "outbounds": [{"type": "snell", "tag": name, "server": target,
                       "server_port": port, "version": 6, "psk": psk,
                       "mode": mode}],
        "route": {"rules": [{"protocol": "dns", "action": "hijack-dns"}],
                  "final": name},
    }


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "SnellSubscription/1.1"

    def log_message(self, fmt, *args):
        # Never expose capability tokens or client secrets in logs.
        return

    def do_HEAD(self):
        self.respond(head_only=True)

    def do_GET(self):
        self.respond(head_only=False)

    def respond(self, head_only=False):
        try:
            settings = read_settings()
            requested = self.path.split("?", 1)[0]
            expected = f"/s/{settings['token']}/config.json"
            if not hmac.compare_digest(requested, expected):
                self.send_error(404, "Not found")
                return
            data = (json.dumps(profile(settings), ensure_ascii=False,
                               indent=2) + "\n").encode("utf-8")
        except Exception:
            self.send_error(503, "Subscription unavailable")
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store, private")
        self.send_header("Pragma", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        if not head_only:
            self.wfile.write(data)


class TLSHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def get_request(self):
        raw, address = super().get_request()
        try:
            # Bound handshake/read timeouts prevent stalled clients from holding
            # the single accept loop or a worker thread indefinitely.
            raw.settimeout(5.0)
            tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            tls.minimum_version = ssl.TLSVersion.TLSv1_2
            tls.load_cert_chain(str(CERT), str(KEY))
            wrapped = tls.wrap_socket(raw, server_side=True)
            wrapped.settimeout(10.0)
            return wrapped, address
        except Exception:
            raw.close()
            raise


class IPv6TLSHTTPServer(TLSHTTPServer):
    address_family = socket.AF_INET6


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    settings = read_settings()
    profile(settings)  # Validate before binding or serving.
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(str(CERT), str(KEY))
    if args.check:
        print("PASS: Subscription configuration and TLS keypair are valid.")
        return
    is_ipv6 = settings.get("bind_family") == "ipv6"
    cls = IPv6TLSHTTPServer if is_ipv6 else TLSHTTPServer
    host = "::" if is_ipv6 else "0.0.0.0"
    with cls((host, settings["listen_port"]), Handler) as server:
        server.serve_forever(poll_interval=0.5)


if __name__ == "__main__":
    main()
