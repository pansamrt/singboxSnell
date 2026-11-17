#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Snell v6 standalone one-click installer + sing-box for iOS profile generator.
# Supported: Debian 12/13, Ubuntu 24.04, systemd, amd64/aarch64.
# Does not touch sshd, firewall, routes, DNS, other sing-box/Hysteria2 services.
set -Eeuo pipefail
umask 077

VERSION=v6.0.0
PORT=17888
PORT_GIVEN=0
SERVER=''
NAME='Snell-v6'
FAMILY=ipv4
FAMILY_GIVEN=0
PLAN=0
REPLACE_CLIENT=0
QR_URL_FILE=''
QR_TERMINAL=0
REPLACE_QR=0
APP_NAME=snell-v6
UNIT=/etc/systemd/system/snell-v6.service
BIN=/opt/snell-v6/snell-server
CONF=/etc/snell-v6/snell-server.conf
INSTALL_DIR=/opt/snell-v6
CONFIG_DIR=/etc/snell-v6
WORK=''
NEW_INSTALL=0
CREATED_USER=0
CREATED_BIN=0
CREATED_CONFIG=0
CREATED_UNIT=0

info() { printf '[Snell-v6] %s\n' "$*"; }
fail() { printf '[Snell-v6] ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: sudo bash snell-v6-oneclick.sh [--server PUBLIC_IP] [--name NODE_NAME]
       [--port 17888] [--family ipv4|ipv6|dual]
       [--plan] [--replace-client]
       [--qr-url-file /root/private-subscription-url.txt] [--qr-terminal] [--replace-qr]

Default: installs standalone official Snell v6.0.0 on TCP 17888 (IPv4 only),
then writes /root/Snell-v6-ios.json for sing-box iOS 1.14+.
Name examples: Germany-Snell-v6, KR-Snell-v6 (filename: NAME-ios.json).

If an independent Snell installation already exists at the paths below,
its binary, service, port and PSK are reused without any modification.
A partially present installation is refused rather than overwritten.

--plan             Read-only inspection (no apt, download, or changes)
--replace-client   Allow atomic replacement of an existing root-only client JSON
--qr-url-file     OPTIONAL: root-owned private 0600 file containing one HTTPS JSON URL
--qr-terminal     Show the import QR in terminal (exposes subscription URL visually)
--replace-qr      Replace an existing private QR PNG explicitly

QR uses the official sing-box REMOTE profile import scheme. A real privately
hosted HTTPS URL serving this JSON is REQUIRED; no server or port is created.
A QR that embeds raw JSON or a snell:// node link will not import into the
official sing-box iOS app as a normal profile.
--family           New installations only; default ipv4, optional ipv6/dual
--port             New installations only; default 17888
EOF
}
cleanup() {
  local rc=$?
  trap - EXIT HUP INT TERM
  if [[ -n "$WORK" && -d "$WORK" ]]; then rm -rf -- "$WORK"; fi
  if (( rc != 0 && NEW_INSTALL == 1 )); then
    info 'Installation failed: removing ONLY files created by this attempt.' >&2
    if (( CREATED_UNIT )); then
      systemctl disable --now "${APP_NAME}.service" >/dev/null 2>&1 || true
      rm -f -- "$UNIT"
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if (( CREATED_CONFIG )); then rm -f -- "$CONF"; fi
    if (( CREATED_BIN )); then rm -f -- "$BIN"; fi
    rmdir -- "$CONFIG_DIR" "$INSTALL_DIR" 2>/dev/null || true
    if (( CREATED_USER )); then userdel snellv6 >/dev/null 2>&1 || true; fi
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

while (($#)); do
  case "$1" in
    --server|--name|--port|--family|--qr-url-file)
      (( $# >= 2 )) && [[ -n "$2" ]] || fail "Missing value after $1"
      case "$1" in
        --server) SERVER=$2 ;;
        --name) NAME=$2 ;;
        --port) PORT=$2; PORT_GIVEN=1 ;;
        --family) FAMILY=$2; FAMILY_GIVEN=1 ;;
        --qr-url-file) QR_URL_FILE=$2 ;;
      esac
      shift 2 ;;
    --plan) PLAN=1; shift ;;
    --replace-client) REPLACE_CLIENT=1; shift ;;
    --qr-terminal) QR_TERMINAL=1; shift ;;
    --replace-qr) REPLACE_QR=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage; fail "Unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || fail 'Please run as root (sudo bash ...).'
[[ -r /etc/os-release ]] || fail 'Cannot read /etc/os-release.'
# shellcheck source=/etc/os-release
. /etc/os-release
case "${ID}:${VERSION_ID}" in
  debian:12|debian:13|ubuntu:24.04) ;;
  *) fail "Unsupported OS: ${ID} ${VERSION_ID}; use Debian 12/13 or Ubuntu 24.04." ;;
esac
[[ -d /run/systemd/system ]] || fail 'systemd must be running on the VPS.'
command -v apt-get >/dev/null 2>&1 || fail 'apt-get not found.'

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=aarch64 ;;
  *) fail "Unsupported CPU architecture: $(uname -m)" ;;
esac
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,49}$ ]] ||
  fail 'Node name may contain only 1-50 ASCII letters/digits/dashes/underscores.'
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || fail 'Invalid port.'
PORT=$((10#$PORT))
(( PORT >= 1024 && PORT <= 65535 )) || fail 'Choose an unprivileged TCP port 1024-65535.'
case "$FAMILY" in ipv4|ipv6|dual) ;; *) fail 'Use --family ipv4|ipv6|dual.' ;; esac
if (( QR_TERMINAL || REPLACE_QR )) && [[ -z "$QR_URL_FILE" ]]; then
  fail '--qr-terminal and --replace-qr require --qr-url-file.'
fi
if [[ -n "$QR_URL_FILE" ]]; then
  [[ -f "$QR_URL_FILE" && ! -L "$QR_URL_FILE" ]] || fail 'QR URL file must be an existing regular, non-symlink file.'
  [[ "$(stat -c '%u' -- "$QR_URL_FILE")" == '0' ]] || fail 'QR URL file must be root-owned.'
  QR_FILE_MODE=$(stat -c '%a' -- "$QR_URL_FILE")
  [[ "$QR_FILE_MODE" =~ ^[0-7]{3,4}$ ]] || fail 'QR URL file permissions invalid.'
  (( (8#$QR_FILE_MODE & 0077) == 0 )) || fail 'QR URL file must not be group/world accessible (use chmod 600).'
fi

if [[ -z "$SERVER" ]]; then
  [[ -t 0 ]] || fail 'Noninteractive session requires --server PUBLIC_IP.'
  read -r -p 'Enter this VPS public IPv4 or IPv6 (not a URL): ' SERVER || fail 'No server supplied.'
  [[ -n "$SERVER" ]] || fail 'Public IP must not be empty.'
fi

# Exact older standalone installation paths are intentionally supported.
EXISTING=0
COUNT=0
for path in "$BIN" "$CONF" "$UNIT"; do
  if [[ -e "$path" || -L "$path" ]]; then COUNT=$((COUNT + 1)); fi
done
if (( COUNT == 3 )); then
  EXISTING=1
  for path in "$BIN" "$CONF" "$UNIT"; do
    [[ -f "$path" && ! -L "$path" ]] || fail "Unsafe existing file: $path"
  done
  [[ -d "$INSTALL_DIR" && ! -L "$INSTALL_DIR" && -d "$CONFIG_DIR" && ! -L "$CONFIG_DIR" ]] ||
    fail 'Existing Snell installation has unsafe directories.'
  grep -Fxq 'ExecStart=/opt/snell-v6/snell-server -c /etc/snell-v6/snell-server.conf' "$UNIT" ||
    fail 'Existing systemd unit is not the dedicated Snell unit; no changes made.'
elif (( COUNT > 0 )); then
  fail 'Partial Snell installation detected. Stop and inspect manually; refusing overwrite.'
else
  for path in "$INSTALL_DIR" "$CONFIG_DIR" "$UNIT"; do
    [[ ! -e "$path" && ! -L "$path" ]] || fail "Conflicting path: $path"
  done
  if getent passwd snellv6 >/dev/null 2>&1; then
    fail 'User snellv6 already exists without a complete owned Snell installation.'
  fi
fi

if (( EXISTING )); then
  (( PORT_GIVEN == 0 && FAMILY_GIVEN == 0 )) ||
    fail 'Existing installation is immutable: omit --port and --family.'
fi

URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-${ARCH}.zip"
OUT="/root/${NAME}-ios.json"
QR_OUT="/root/${NAME}-ios-qr.png"
[[ ! -L "$OUT" ]] || fail "Refusing client-output symlink: $OUT"
if [[ -e "$OUT" ]]; then
  [[ -f "$OUT" ]] || fail 'Client output exists but is not a regular file.'
  [[ "$(stat -c %u "$OUT")" == 0 ]] || fail 'Existing client output is not root-owned.'
  if (( ! REPLACE_CLIENT )); then
    info "Existing client file will NOT be overwritten: $OUT"
    if (( ! EXISTING && ! PLAN )); then
      fail "Use a different --name or --replace-client BEFORE installing."
    fi
  fi
fi

if (( PLAN )); then
  info "PLAN ONLY: OS=${PRETTY_NAME}; ARCH=$ARCH; existing=$EXISTING"
  info "Snell unit: ${APP_NAME}.service; new-install TCP port=$PORT, family=$FAMILY"
  info "Official archive: $URL"
  info "Client JSON: $OUT"
  if [[ -n "$QR_URL_FILE" ]]; then info "Private QR PNG: $QR_OUT (requires a working private HTTPS URL)"; fi
  info 'Will not change SSH, host DNS, routes, firewall, kernel, or other proxy services.'
  if (( EXISTING )); then systemctl is-active "${APP_NAME}.service" || true; fi
  exit 0
fi

# Dependencies are installed ONLY on first install, and only after path preflight.
if (( ! EXISTING )); then
  info 'Installing required Debian/Ubuntu packages (no autoremove or kernel changes).'
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    curl unzip openssl ca-certificates iproute2 python3
else
  info 'Detected existing independent Snell installation; skipping apt and binary/service changes.'
  command -v python3 >/dev/null 2>&1 || fail 'python3 required for iOS client generation.'
fi
if [[ -n "$QR_URL_FILE" ]] && ! command -v qrencode >/dev/null 2>&1; then
  info 'Installing optional qrencode package for private sing-box iOS QR generation.'
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qrencode
fi

# Confirm IP address and server-side listener compatibility without leaking keys.
python3 - "$SERVER" "$FAMILY" "$EXISTING" "$CONF" <<'PY'
import ipaddress, sys, configparser
address = ipaddress.ip_address(sys.argv[1])
family, existing, conf = sys.argv[2], int(sys.argv[3]), sys.argv[4]
if not existing:
    if (address.version == 4 and family == 'ipv6') or (address.version == 6 and family == 'ipv4'):
        raise SystemExit('Public IP family does not match the new server listener family.')
else:
    cfg = configparser.ConfigParser(interpolation=None)
    if not cfg.read(conf):
        raise SystemExit('Missing existing Snell configuration.')
    value = cfg.get('snell-server', 'listen', fallback='')
    parts = [item.strip() for item in value.split(',')]
    supported = any((item.startswith('0.0.0.0:') or
                    (item.startswith(str(address) + ':')))
                    for item in parts) if address.version == 4 else any(
                    item.startswith('[::]:') or item.startswith('[' + str(address) + ']:')
                    for item in parts)
    if not supported:
        raise SystemExit('Existing listen family does not match supplied public IP.')
print('PASS: Public IP and listener family validated.')
PY

if (( ! EXISTING )); then
  # Verify the official download is reachable before creating any Snell directories.
  info "Checking Surge official HTTPS archive: $URL"
  curl --proto '=https' --tlsv1.2 -fIsS --connect-timeout 10 --max-time 25 \
    "$URL" >/dev/null || fail 'Surge HTTPS download check failed. No Snell service installed.'
  WORK="$(mktemp -d /tmp/snell-v6.XXXXXXXX)"
  curl --proto '=https' --tlsv1.2 -fL \
    --retry 2 --connect-timeout 15 --max-time 120 \
    "$URL" -o "$WORK/snell.zip" || fail 'Official download failed.'
  unzip -Z1 "$WORK/snell.zip" | grep -Fxq 'snell-server' || fail 'Unexpected archive structure.'
  unzip -p "$WORK/snell.zip" snell-server > "$WORK/snell-server"
  [[ -s "$WORK/snell-server" ]] || fail 'Archive binary is empty.'
  chmod 755 "$WORK/snell-server"
  "$WORK/snell-server" -v 2>&1 | grep -Fq 'snell-server v6.0.0' ||
    fail 'Downloaded binary did not report official Snell v6.0.0.'
  info "Downloaded official v6.0.0; SHA256 (informational, not pinned): $(sha256sum "$WORK/snell.zip" | cut -d' ' -f1)"

  # Test only the sockets being requested. No firewall or route mutation.
  python3 - "$PORT" "$FAMILY" <<'PY'
import socket, sys
port, family = int(sys.argv[1]), sys.argv[2]
for ver in ([4, 6] if family == 'dual' else [4] if family == 'ipv4' else [6]):
    af = socket.AF_INET if ver == 4 else socket.AF_INET6
    with socket.socket(af, socket.SOCK_STREAM) as s:
        if ver == 6:
            s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        try:
            s.bind(('0.0.0.0' if ver == 4 else '::', port))
        except OSError as exc:
            raise SystemExit(f'Port {port}/TCP IPv{ver} unavailable: {exc}')
print('PASS: All requested TCP listener addresses are available.')
PY

  case "$FAMILY" in
    ipv4) LISTEN="0.0.0.0:${PORT}" ;;
    ipv6) LISTEN="[::]:${PORT}" ;;
    dual) LISTEN="0.0.0.0:${PORT},[::]:${PORT}" ;;
  esac
  PSK=$(openssl rand -hex 32)

  NEW_INSTALL=1
  useradd --system --user-group --no-create-home \
    --home-dir /nonexistent --shell /usr/sbin/nologin snellv6
  CREATED_USER=1
  install -d -m 755 "$INSTALL_DIR"
  install -d -o root -g snellv6 -m 750 "$CONFIG_DIR"
  CREATED_BIN=1
  install -m 755 "$WORK/snell-server" "$BIN"
  cat > "$WORK/snell-server.conf" <<EOF
[snell-server]
listen = ${LISTEN}
psk = ${PSK}
mode = default
dns-ip-preference = default
EOF
  CREATED_CONFIG=1
  install -o root -g snellv6 -m 640 "$WORK/snell-server.conf" "$CONF"
  CREATED_UNIT=1
  cat > "$UNIT" <<'EOF'
[Unit]
Description=Independent Surge Snell v6 Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=snellv6
Group=snellv6
ExecStart=/opt/snell-v6/snell-server -c /etc/snell-v6/snell-server.conf
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$UNIT"
  systemctl daemon-reload
  systemctl enable --now "${APP_NAME}.service"
fi

if ! systemctl is-active --quiet "${APP_NAME}.service"; then
  fail "${APP_NAME}.service is not active; no existing service was changed."
fi
if ! "$BIN" -v 2>&1 | grep -Fq 'snell-server v6.0.0'; then
  fail 'Installed binary version differs from Snell v6.0.0.'
fi

# Confirm local TCP accepts a connection; not equivalent to real Snell authentication.
python3 - "$CONF" <<'PY'
import configparser, socket, re, sys
p = configparser.ConfigParser(interpolation=None)
p.read(sys.argv[1])
listeners = [item.strip() for item in p['snell-server']['listen'].split(',')]
for item in listeners:
    m = re.fullmatch(r'(0\.0\.0\.0|\[::\]):([0-9]{1,5})', item)
    if not m:
        continue
    addr = '127.0.0.1' if m[1] == '0.0.0.0' else '::1'
    with socket.create_connection((addr, int(m[2])), timeout=4):
        print(f'PASS: local TCP listener on {addr}:{m[2]}')
    break
else:
    raise SystemExit('Cannot locally probe the configured Snell listener.')
PY

# Never print PSK. Client JSON is generated atomically, root-owned, mode 0600.
python3 - "$CONF" "$SERVER" "$NAME" "$OUT" "$REPLACE_CLIENT" <<'PY'
import configparser, ipaddress, json, os, pathlib, re, stat, sys, tempfile

source, server, name, target, replace = sys.argv[1:]
ipaddress.ip_address(server)
config_path = pathlib.Path(source)
info = config_path.lstat()
if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o007 or info.st_mode & 0o020:
    raise SystemExit('Server config permissions are unsafe.')
if info.st_uid != 0:
    raise SystemExit('Server config must be root-owned.')
p = configparser.ConfigParser(interpolation=None)
with config_path.open(encoding='utf-8') as f:
    p.read_file(f)
key = p.get('snell-server', 'psk')
if not 12 <= len(key.encode('utf-8')) <= 255:
    raise SystemExit('Snell v6 PSK must contain 12 to 255 bytes.')
mode = p.get('snell-server', 'mode', fallback='default')
if mode not in ('default', 'unshaped'):
    raise SystemExit('Refusing unsafe-raw or unsupported Snell encryption mode.')
listeners = [x.strip() for x in p.get('snell-server', 'listen').split(',')]
ports = set()
for listener in listeners:
    match = re.fullmatch(r'(?:0\.0\.0\.0|\[::\]|(?:\d{1,3}\.){3}\d{1,3}|\[[0-9a-fA-F:]+\]):(\d{1,5})', listener)
    if not match:
        raise SystemExit('Unsupported existing listen address; cannot safely generate client.')
    ports.add(int(match.group(1)))
if len(ports) != 1 or not 1 <= next(iter(ports)) <= 65535:
    raise SystemExit('Conflicting listener ports.')
port = ports.pop()
profile = {
    'log': {'level': 'warn'},
    'dns': {'servers': [{'type': 'tcp', 'tag': 'remote-dns', 'server': '1.1.1.1',
                         'server_port': 53, 'detour': name}], 'final': 'remote-dns'},
    'inbounds': [{'type': 'tun', 'tag': 'tun-in',
                  'address': ['172.19.0.1/30', 'fd00:19::1/126'], 'auto_route': True}],
    'outbounds': [{'type': 'snell', 'tag': name, 'server': server,
                   'server_port': port, 'version': 6, 'psk': key, 'mode': mode}],
    'route': {'rules': [{'protocol': 'dns', 'action': 'hijack-dns'}], 'final': name}
}

path = pathlib.Path(target)
if path.exists() or path.is_symlink():
    oldstat = path.lstat()
    if not stat.S_ISREG(oldstat.st_mode) or oldstat.st_uid != 0 or oldstat.st_mode & 0o077:
        raise SystemExit('Refusing unsafe existing client file.')
    if json.loads(path.read_text(encoding='utf-8')) == profile:
        print('PASS: Existing iOS JSON exactly matches current server; no overwrite needed.')
        print('Client file:', path)
        sys.exit(0)
    if replace != '1':
        raise SystemExit('Client JSON already exists with different content. Use --replace-client explicitly.')

fd, temp = tempfile.mkstemp(prefix='.' + name + '-', suffix='.json', dir=path.parent)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as out:
        json.dump(profile, out, ensure_ascii=False, indent=2)
        out.write('\n')
        out.flush()
        os.fsync(out.fileno())
    os.chmod(temp, 0o600)
    os.replace(temp, path)
finally:
    if os.path.exists(temp):
        os.unlink(temp)
print('PASS: Private iOS sing-box JSON generated:', path)
print('Node name:', name, '| TCP port:', port, '| mode:', mode)
print('PSK stays in private server/client files. DO NOT publish the JSON.')
PY

# Optional sing-box for iOS QR import. The code contains the URL of a PRIVATELY
# HOSTED HTTPS sing-box JSON profile, not the JSON/PSK and not a snell:// link.
# No hosting service is created; QR alone does NOT make the file downloadable.
if [[ -n "$QR_URL_FILE" ]]; then
  python3 - "$QR_URL_FILE" "$NAME" "$QR_OUT" "$REPLACE_QR" "$QR_TERMINAL" <<'PY'
import os, pathlib, stat, subprocess, sys, tempfile
from urllib.parse import quote, urlsplit

source_name, name, target_name, replace, terminal = sys.argv[1:]
source = pathlib.Path(source_name)
st = source.lstat()
if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o077:
    raise SystemExit('QR URL file must be root-owned, private and not a symlink.')
url = source.read_text(encoding='utf-8').strip()
if not url or len(url) > 1024 or any(c.isspace() or ord(c) < 32 for c in url):
    raise SystemExit('QR URL must be one HTTPS URL of <= 1024 characters without whitespace.')
parts = urlsplit(url)
if (parts.scheme != 'https' or not parts.netloc or not parts.hostname
        or parts.username or parts.password or parts.fragment):
    raise SystemExit('QR URL must be a private HTTPS URL with no userinfo or fragment.')
try:
    _ = parts.port
except ValueError as exc:
    raise SystemExit('Invalid HTTPS URL port.') from exc
link = 'sing-box://import-remote-profile?url=' + quote(url, safe='') + '#' + quote(name, safe='')
target = pathlib.Path(target_name)
if target.exists() or target.is_symlink():
    existing = target.lstat()
    if not stat.S_ISREG(existing.st_mode) or existing.st_uid != 0 or existing.st_mode & 0o077:
        raise SystemExit('Refusing unsafe existing QR PNG.')
fd, tmp = tempfile.mkstemp(prefix='.' + name + '-qr-', suffix='.png', dir=target.parent)
os.close(fd)
try:
    subprocess.run(['qrencode', '-t', 'PNG', '-l', 'M', '-s', '8', '-m', '4',
                    '-o', tmp], input=link, text=True, check=True)
    if not os.path.getsize(tmp):
        raise SystemExit('QR generation returned an empty image.')
    os.chmod(tmp, 0o600)
    if target.exists() and target.read_bytes() != pathlib.Path(tmp).read_bytes() and replace != '1':
        raise SystemExit('QR image already exists and differs; use --replace-qr explicitly.')
    if target.exists() and target.read_bytes() == pathlib.Path(tmp).read_bytes():
        print('PASS: Existing private QR image exactly matches; no overwrite needed.')
    else:
        os.replace(tmp, target)
    print('PASS: Private sing-box iOS remote-import QR saved:', target)
    print('WARNING: This QR is a credential if its HTTPS URL is a bearer token.')
    print('WARNING: The HTTPS URL must actually serve the PRIVATE iOS JSON for import to work.')
    if terminal == '1':
        if not sys.stdout.isatty():
            raise SystemExit('--qr-terminal requires an interactive terminal.')
        subprocess.run(['qrencode', '-t', 'ANSIUTF8', '-l', 'M'],
                       input=link, text=True, check=True)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
fi

info "SUCCESS: ${APP_NAME}.service is active; independent Snell and sing-box installations coexist."
info "Client profile: $OUT"
info 'JSON can be copied via Xshell/Xftp SFTP and imported in sing-box iOS > Profiles > Import from File.'
if [[ -n "$QR_URL_FILE" ]]; then info 'QR is for PRIVATE HTTPS remote-profile import only; scan it in sing-box iOS > Profiles > Scan QR Code.'; fi
info 'Local TCP test is NOT a real external Snell handshake. Confirm provider firewall permits the TCP port.'
info 'No firewall, SSH, routing, host DNS, kernel, or existing proxy services were edited.'