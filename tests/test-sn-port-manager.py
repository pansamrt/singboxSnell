#!/usr/bin/env python3
"""Isolated root-only CI test. Simulates systemctl; never touches real VPSes."""
import json
import os
import pathlib
import re
import shutil
import socket
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[1]
unit = pathlib.Path("/etc/systemd/system/snell-v6.service")
binary = pathlib.Path("/opt/snell-v6/snell-server")
config = pathlib.Path("/etc/snell-v6/snell-server.conf")
profile = pathlib.Path("/root/CI-Snell-v6-port-test-ios.json")
assert os.geteuid() == 0, "Run under sudo in a disposable CI environment."
for item in (unit, binary, config, profile):
    assert not item.exists(), f"Refusing to touch existing resource: {item}"

temp = pathlib.Path(tempfile.mkdtemp(prefix="snell-port-ci-"))
def new_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]

def listen_port():
    return int(re.search(r"^listen\s*=\s*0\.0\.0\.0:(\d+)", config.read_text(), re.M)[1])

def check_open(port):
    with socket.create_connection(("127.0.0.1", port), timeout=2):
        pass

bin_dir = temp / "bin"
bin_dir.mkdir()
listener = temp / "listener.py"
listener.write_text("""
import socket, sys
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(('0.0.0.0', int(sys.argv[1])))
sock.listen()
while True:
    conn, _ = sock.accept()
    conn.close()
""")
systemctl = bin_dir / "systemctl"
systemctl.write_text("""#!/usr/bin/env bash
set -Eeuo pipefail
case "$1" in
  is-active)
    if [[ -f "$MOCK_PIDFILE" ]] && kill -0 "$(cat "$MOCK_PIDFILE")" 2>/dev/null; then
      [[ "$2" == "--quiet" ]] || echo active
      exit 0
    fi
    exit 3 ;;
  restart)
    if [[ -f "$MOCK_PIDFILE" ]]; then
      kill "$(cat "$MOCK_PIDFILE")" 2>/dev/null || true
      rm -f "$MOCK_PIDFILE"
      sleep 0.15
    fi
    port=$(sed -n 's/^listen = 0.0.0.0://p' /etc/snell-v6/snell-server.conf)
    if [[ -n "$MOCK_FAIL_PORT" && "$port" == "$MOCK_FAIL_PORT" ]]; then
      exit 1
    fi
    nohup python3 "$MOCK_LISTENER" "$port" </dev/null > "$MOCK_LOG" 2>&1 &
    pid=$!
    echo "$pid" > "$MOCK_PIDFILE"
    sleep .15
    kill -0 "$pid" 2>/dev/null ;;
  *) echo 'Unsupported mock systemctl action' >&2; exit 2 ;;
esac
""")
systemctl.chmod(0o755)
env = os.environ.copy()
env.update({
    "PATH": str(bin_dir) + os.pathsep + env["PATH"],
    "MOCK_PIDFILE": str(temp / "listener.pid"),
    "MOCK_LISTENER": str(listener),
    "MOCK_LOG": str(temp / "listener.log"),
    "MOCK_FAIL_PORT": ""
})

def run_cli(port, *, fail_port=None):
    call_env = env.copy()
    call_env["MOCK_FAIL_PORT"] = str(fail_port) if fail_port is not None else ""
    p = subprocess.run(
        ["script", "-q", "-e", "-c", f"bash {repo / 'sn'} port", "/dev/null"],
        input=f"{port}\nYES\n", text=True, capture_output=True,
        env=call_env, timeout=40)
    return p.returncode, p.stdout + p.stderr

try:
    unit.parent.mkdir(parents=True, exist_ok=True)
    binary.parent.mkdir(parents=True, exist_ok=True)
    config.parent.mkdir(parents=True, exist_ok=True)
    old, target, conflict, bad = [new_port() for _ in range(4)]
    assert len({old, target, conflict, bad}) == 4, "Ephemeral port collision in CI"
    psk = os.urandom(32).hex()
    binary.write_text("fake executable for CI\n")
    unit.write_text(
        "[Service]\n"
        "ExecStart=/opt/snell-v6/snell-server -c /etc/snell-v6/snell-server.conf\n"
    )
    config.write_text(
        f"[snell-server]\nlisten = 0.0.0.0:{old}\npsk = {psk}\n"
        "mode = default\ndns-ip-preference = default\n"
    )
    config.chmod(0o640)
    profile.write_text(json.dumps({
        "outbounds": [{
            "type": "snell", "tag": "CI-Snell-v6",
            "server": "203.0.113.2", "server_port": old,
            "psk": psk, "version": 6, "mode": "default"
        }]
    }))
    profile.chmod(0o600)
    subprocess.run(["systemctl", "restart", "snell-v6.service"],
                   env=env, check=True, timeout=10)
    check_open(old)

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as occupied:
        occupied.bind(("0.0.0.0", conflict))
        occupied.listen()
        rc, output = run_cli(conflict)
        assert rc != 0 and "not available" in output, output
        assert listen_port() == old
        check_open(old)
    print("PASS: Conflicting TCP port rejected; old listener unaffected")

    rc, output = run_cli(target)
    assert rc == 0, output
    assert listen_port() == target
    check_open(target)
    new_doc = json.loads(profile.read_text())
    assert new_doc["outbounds"][0]["server_port"] == target
    assert new_doc["outbounds"][0]["psk"] == psk
    print("PASS: New port active, PSK preserved, private JSON updated")

    rc, output = run_cli(bad, fail_port=bad)
    assert rc != 0, output
    assert listen_port() == target, output
    check_open(target)
    assert json.loads(profile.read_text())["outbounds"][0]["server_port"] == target
    print("PASS: Failed restart rolled back to original port without client damage")
finally:
    pidfile = temp / "listener.pid"
    if pidfile.is_file():
        try:
            os.kill(int(pidfile.read_text()), 15)
        except (ProcessLookupError, ValueError):
            pass
    for p in (profile, config, binary, unit):
        p.unlink(missing_ok=True)
    for d in (config.parent, binary.parent):
        try:
            d.rmdir()
        except OSError:
            pass
    shutil.rmtree(temp, ignore_errors=True)
