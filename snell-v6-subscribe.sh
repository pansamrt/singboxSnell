#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# SNELL_V6_SUBSCRIPTION_MANAGER=1
# HTTPS sing-box subscription manager for standalone Snell v6. No changes to other proxies.
set -Eeuo pipefail
umask 077

SNELL=/etc/snell-v6/snell-server.conf
SNELL_UNIT=/etc/systemd/system/snell-v6.service
ROOT=/etc/snell-v6/subscription
SETTINGS=$ROOT/settings.json
SRC=/usr/local/lib/snell-v6/subscription_server.py
CERT=$ROOT/tls-fullchain.pem
KEY=$ROOT/tls-key.pem
UNIT=/etc/systemd/system/snell-v6-subscription.service
SYNC_UNIT=/etc/systemd/system/snell-v6-subscription-cert-sync.service
TIMER=/etc/systemd/system/snell-v6-subscription-cert-sync.timer
QR=/root/Snell-v6-subscription-qr.png
QR_IMPORT=/root/Snell-v6-import-qr.png

info() { printf '[sn-sub] %s\n' "$*"; }
fail() { printf '[sn-sub] ERROR: %s\n' "$*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || fail 'Run as root (sudo sn sub).'; }
read_setting() {
  python3 - "$SETTINGS" "$1" <<'PY'
import json,sys
with open(sys.argv[1], encoding='utf-8') as f: data=json.load(f)
print(data[sys.argv[2]])
PY
}
validate_domain() {
  python3 - "$1" <<'PY'
import re,sys
domain=sys.argv[1]
parts=domain.split('.')
if len(domain)>253 or len(parts)<2 or not all(
    1<=len(p)<=63 and re.fullmatch(r'[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?', p)
    for p in parts):
    raise SystemExit('Invalid hostname; use the DNS/ASCII name (punycode for IDN).')
PY
}
cert_ok() {
  local crt=$1 key=$2 host=$3
  [[ -f "$crt" && -f "$key" ]] || return 1
  openssl x509 -in "$crt" -noout -checkend 86400 >/dev/null 2>&1 || return 1
  openssl x509 -in "$crt" -noout -checkhost "$host" >/dev/null 2>&1 || return 1
  python3 - "$crt" "$key" <<'PY' >/dev/null 2>&1
import ssl,sys
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(sys.argv[1],sys.argv[2])
PY
}
require_snell() {
  [[ -f "$SNELL" && ! -L "$SNELL" && -f "$SNELL_UNIT" ]] ||
    fail 'Install the standalone Snell v6 server before creating a subscription.'
  grep -Fxq 'ExecStart=/opt/snell-v6/snell-server -c /etc/snell-v6/snell-server.conf' "$SNELL_UNIT" ||
    fail 'Unexpected Snell service unit; refusing changes.'
  systemctl is-active --quiet snell-v6.service || fail 'Snell service is not active.'
  getent group snellv6 >/dev/null || fail 'Dedicated snellv6 service group missing.'
}
suggest_domains() {
  local crt
  printf '\nDomains found in local certificate SANs (hints only):\n'
  for crt in /root/ygkkkca/fullchain.cer /root/ygkkkca/cert.crt \
      /etc/letsencrypt/live/*/fullchain.pem; do
    [[ -f "$crt" ]] || continue
    openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null || true
  done | grep -oE 'DNS:[A-Za-z0-9*._-]+' | sed 's/^DNS://' | grep -v '^\*' | sort -u || true
  printf 'Domains referenced in local web/ACME configuration (hints only):\n'
  python3 - <<'PY'
import pathlib,re
root=pathlib.Path('/')
files=[
    *pathlib.Path('/etc/nginx/sites-enabled').glob('*'),
    *pathlib.Path('/etc/nginx/conf.d').glob('*.conf'),
    *pathlib.Path('/etc/apache2/sites-enabled').glob('*.conf'),
    pathlib.Path('/etc/caddy/Caddyfile'),
    *pathlib.Path('/root/.acme.sh').glob('*/domain.conf'),
    *pathlib.Path('/root/.acme.sh').glob('*/*.conf'),
]
names=set()
valid=re.compile(r'(?i)^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?
show_dns() {
  python3 - "$1" "$2" <<'PY'
import ipaddress,socket,sys
domain,server=sys.argv[1:]
try:
    found=sorted({row[4][0] for row in socket.getaddrinfo(domain,None)})
except OSError as exc:
    raise SystemExit('Domain DNS resolution failed: '+str(exc))
print('DNS addresses for '+domain+': '+', '.join(found))
try:
    ipaddress.ip_address(server)
except ValueError:
    pass
else:
    if server not in found:
        print('WARNING: DNS does not match the supplied Snell server IP.')
        print('If behind Cloudflare proxy, ensure the proxy supports the HTTPS port;')
        print('the Snell TCP service usually needs a direct IP rather than a proxied name.')
PY
}
ensure_known_unit() {
  local file=$1
  if [[ -e "$file" || -L "$file" ]]; then
    [[ -f "$file" && ! -L "$file" ]] || fail "Unsafe unit file: $file"
    grep -Fxq '# Managed by pansamrt/singboxSnell subscription' "$file" ||
      fail "Unrelated systemd unit at $file; refusing overwrite."
  fi
}
copy_certificates() {
  local crt=$1 key=$2 domain=$3 dest temp
  cert_ok "$crt" "$key" "$domain" || fail 'Certificate invalid, expired/expiring, hostname mismatch, or key mismatch.'
  [[ -d "$ROOT" && ! -L "$ROOT" ]] || fail 'Missing subscription directory.'
  for dest in "$CERT" "$KEY"; do
    [[ ! -L "$dest" ]] || fail 'Refusing a symlinked subscription certificate.'
  done
  if [[ -f "$CERT" && -f "$KEY" ]] &&
     cmp -s "$crt" "$CERT" && cmp -s "$key" "$KEY"; then
    return 0
  fi
  temp=$(mktemp "$ROOT/.cert.XXXXXXXX")
  install -o root -g snellv6 -m 640 "$crt" "$temp"
  mv -fT -- "$temp" "$CERT"
  temp=$(mktemp "$ROOT/.key.XXXXXXXX")
  install -o root -g snellv6 -m 640 "$key" "$temp"
  mv -fT -- "$temp" "$KEY"
  info 'TLS certificate/key refreshed from the existing source (source unchanged).'
}
sync_certs() {
  require_root
  [[ -f "$SETTINGS" && ! -L "$SETTINGS" ]] || exit 0
  local source_cert source_key domain
  source_cert=$(read_setting source_cert)
  source_key=$(read_setting source_key)
  domain=$(read_setting domain)
  exec 9>/run/lock/snell-v6-subscription.lock
  flock -x 9
  copy_certificates "$source_cert" "$source_key" "$domain"
}
links() {
  python3 - "$SETTINGS" <<'PY'
import json,sys,urllib.parse
with open(sys.argv[1],encoding='utf-8') as f:d=json.load(f)
url=f"https://{d['domain']}:{d['listen_port']}/s/{d['token']}/config.json"
deep="sing-box://import-remote-profile?url="+urllib.parse.quote(url,safe="")+"#"+urllib.parse.quote(d["node_name"],safe="")
print(url)
print(deep)
PY
}
show_links() {
  require_root
  [[ -f "$SETTINGS" && ! -L "$SETTINGS" ]] || fail 'Not configured; choose Setup first.'
  local url deep
  url=$(links | sed -n '1p')
  deep=$(links | sed -n '2p')
  info "Subscription HTTPS URL (KEEP SECRET): $url"
  info "sing-box import URL (KEEP SECRET): $deep"
  info "HTTPS service: $(systemctl is-active snell-v6-subscription.service 2>/dev/null || true)"
  if ! command -v qrencode >/dev/null 2>&1; then
    info 'Installing qrencode for QR display (optional)...'
    apt-get install -y --no-install-recommends qrencode >/dev/null 2>&1 ||
      info 'WARNING: qrencode unavailable. Install apt package qrencode for QR support.'
  fi
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$url" || true
    qrencode -o "$QR" -s 6 -m 2 "$url"
    qrencode -o "$QR_IMPORT" -s 6 -m 2 "$deep"
    chmod 600 "$QR" "$QR_IMPORT"
    info "HTTPS subscription QR: $QR"
    info "sing-box import QR: $QR_IMPORT"
    info 'These QR files contain your secret access token. Do not share publicly.'
  fi
}
rotate() {
  require_root
  [[ -t 0 ]] || fail 'An interactive terminal is required.'
  [[ -f "$SETTINGS" ]] || fail 'Subscription is not configured.'
  local answer
  read -r -p 'Rotate access token? Old subscription URL will stop working [y/N]: ' answer ||
    fail 'Confirmation required.'
  [[ "$answer" == y || "$answer" == Y ]] || { info 'Cancelled.'; return 0; }
  python3 - "$SETTINGS" <<'PY'
import json,os,pathlib,secrets,tempfile,sys
p=pathlib.Path(sys.argv[1])
doc=json.loads(p.read_text(encoding='utf-8'))
doc['token']=secrets.token_hex(32)
fd,tmp=tempfile.mkstemp(prefix='.settings-',dir=p.parent)
try:
    os.fchown(fd,0,p.stat().st_gid)
    os.fchmod(fd,0o640)
    with os.fdopen(fd,'w',encoding='utf-8') as f:
        json.dump(doc,f,indent=2)
        f.write('\n')
    os.replace(tmp,p)
finally:
    if os.path.exists(tmp):os.unlink(tmp)
PY
  show_links
}
issue_cert() {
  local domain=$1 mail answer cert_name
  cert_name="snell-sub-$domain"
  info 'No existing trusted certificate covers this domain.'
  info 'ACME HTTP-01 requires public DNS pointing here and inbound TCP port 80.'
  python3 - <<'PY'
import socket
for family,host in ((socket.AF_INET,"0.0.0.0"), (socket.AF_INET6,"::")):
    try:
        sock=socket.socket(family,socket.SOCK_STREAM)
        if family==socket.AF_INET6:sock.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
        sock.bind((host,80))
        sock.close()
    except OSError as exc:
        raise SystemExit('TCP 80 is unavailable for ACME: '+str(exc))
PY
  read -r -p 'Issue a Let’s Encrypt ECC certificate using Certbot ACME? [y/N]: ' answer ||
    fail 'Confirmation required.'
  [[ "$answer" == y || "$answer" == Y ]] || fail 'Certificate issuance cancelled.'
  if ! command -v certbot >/dev/null 2>&1; then
    info 'Installing distribution Certbot via apt (does not change SSH or existing proxy settings).'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends certbot
  fi
  read -r -p 'ACME registration email (blank = no email): ' mail || fail 'Email input required.'
  local -a account=()
  if [[ -n "$mail" ]]; then
    account=(--email "$mail")
  else
    account=(--register-unsafely-without-email)
  fi
  certbot certonly --standalone --non-interactive --agree-tos \
    --key-type ecdsa --elliptic-curve secp256r1 \
    --preferred-challenges http --cert-name "$cert_name" \
    -d "$domain" "${account[@]}"
  SOURCE_CERT="/etc/letsencrypt/live/$cert_name/fullchain.pem"
  SOURCE_KEY="/etc/letsencrypt/live/$cert_name/privkey.pem"
}
setup() {
  require_root
  [[ -t 0 ]] || fail 'Interactive SSH terminal required.'
  require_snell
  local domain server name port family answer token tmpdir candidate settings_tmp
  if [[ -f "$SETTINGS" ]]; then
    read -r -p 'HTTPS subscription exists. Reconfigure and rotate token? [y/N]: ' answer ||
      fail 'Confirmation required.'
    [[ "$answer" == y || "$answer" == Y ]] || { info 'Cancelled.'; return 0; }
  fi
  suggest_domains
  read -r -p 'HTTPS subscription domain (DNS name, not IP): ' domain || fail 'Domain required.'
  validate_domain "$domain"
  read -r -p 'Snell server public IPv4/IPv6 (for client connections): ' server || fail 'Snell server address required.'
  python3 - "$server" <<'PY'
import ipaddress,sys
try:ipaddress.ip_address(sys.argv[1])
except ValueError:raise SystemExit('Enter a public IP address, not a URL.')
PY
  show_dns "$domain" "$server"
  read -r -p 'Node name [Snell-v6]: ' name || fail 'Node name required.'
  if [[ -z "$name" ]]; then name=Snell-v6; fi
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,49}$ ]] || fail 'Invalid node name.'
  read -r -p 'HTTPS subscription TCP port [8443]: ' port || fail 'Port required.'
  if [[ -z "$port" ]]; then port=8443; fi
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || fail 'Invalid port.'
  port=$((10#$port))
  (( port >= 1024 && port <= 65535 )) || fail 'Use an unprivileged HTTPS port 1024-65535.'
  family=ipv4
  if [[ "$server" == *:* ]]; then family=ipv6; fi
  read -r -p "HTTPS bind family [ipv4/ipv6] (default $family): " answer || fail 'Family required.'
  if [[ -n "$answer" ]]; then family=$answer; fi
  case "$family" in ipv4|ipv6) ;; *) fail 'Choose ipv4 or ipv6.' ;; esac
  local existing_port=""
  if [[ -f "$SETTINGS" && ! -L "$SETTINGS" ]]; then
    existing_port=$(read_setting listen_port)
  fi
  if ! systemctl is-active --quiet snell-v6-subscription.service ||
     [[ "$existing_port" != "$port" ]]; then
    python3 - "$port" "$family" <<'PY'
import socket,sys
port=int(sys.argv[1]);ipv6=sys.argv[2]=="ipv6"
with socket.socket(socket.AF_INET6 if ipv6 else socket.AF_INET,socket.SOCK_STREAM) as s:
    if ipv6:s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
    s.bind(("::" if ipv6 else "0.0.0.0",port))
print('PASS: HTTPS listen port is free.')
PY
  fi
  SOURCE_CERT=''
  SOURCE_KEY=''
  for candidate in /root/ygkkkca/fullchain.cer /root/ygkkkca/cert.crt; do
    if cert_ok "$candidate" /root/ygkkkca/private.key "$domain"; then
      SOURCE_CERT=$candidate; SOURCE_KEY=/root/ygkkkca/private.key
      break
    fi
  done
  if [[ -z "$SOURCE_CERT" ]]; then
    for candidate in /etc/letsencrypt/live/*/fullchain.pem; do
      [[ -f "$candidate" ]] || continue
      if cert_ok "$candidate" "$(dirname "$candidate")/privkey.pem" "$domain"; then
        SOURCE_CERT=$candidate; SOURCE_KEY="$(dirname "$candidate")/privkey.pem"
        break
      fi
    done
  fi
  if [[ -z "$SOURCE_CERT" ]]; then
    issue_cert "$domain"
  else
    info "Reusing existing domain certificate (read-only): $SOURCE_CERT"
  fi
  cert_ok "$SOURCE_CERT" "$SOURCE_KEY" "$domain" ||
    fail 'Selected certificate cannot be used for this domain.'
  read -r -p 'Enable token-protected HTTPS subscription? [y/N]: ' answer ||
    fail 'Confirmation required.'
  [[ "$answer" == y || "$answer" == Y ]] || { info 'Cancelled.'; return 0; }
  exec 9>/run/lock/snell-v6-subscription.lock
  flock -x 9
  for candidate in "$UNIT" "$SYNC_UNIT" "$TIMER"; do ensure_known_unit "$candidate"; done
  if [[ -e "$ROOT" || -L "$ROOT" ]]; then
    [[ -d "$ROOT" && ! -L "$ROOT" && "$(stat -c %u "$ROOT")" == 0 ]] ||
      fail 'Unexpected subscription directory.'
  else
    install -d -o root -g snellv6 -m 750 "$ROOT"
  fi
  install -d -o root -g root -m 755 /usr/local/lib/snell-v6
  tmpdir=$(mktemp -d /tmp/snell-sub-server.XXXXXXXX)
  trap 'rm -rf -- "$tmpdir"' EXIT
  curl --proto '=https' --tlsv1.2 -fL --retry 2 \
    --connect-timeout 15 --max-time 120 \
    https://raw.githubusercontent.com/pansamrt/singboxSnell/main/snell-v6-subscription-server.py \
    -o "$tmpdir/server.py" || fail 'Subscription backend download failed.'
  python3 - "$tmpdir/server.py" <<'PY'
import ast,sys
ast.parse(open(sys.argv[1],encoding="utf-8").read())
PY
  install -o root -g root -m 755 "$tmpdir/server.py" "$SRC"
  copy_certificates "$SOURCE_CERT" "$SOURCE_KEY" "$domain"
  token=$(openssl rand -hex 32)
  settings_tmp="$ROOT/.settings.new"
  [[ ! -L "$SETTINGS" && ! -L "$settings_tmp" ]] || fail 'Unsafe subscription settings path.'
  python3 - "$settings_tmp" "$domain" "$port" "$name" "$family" "$server" "$token" "$SOURCE_CERT" "$SOURCE_KEY" <<'PY'
import json,sys
path,domain,port,name,family,address,token,crt,key=sys.argv[1:]
doc=dict(domain=domain,listen_port=int(port),node_name=name,bind_family=family,
         snell_address=address,token=token,source_cert=crt,source_key=key)
with open(path,"w",encoding="utf-8") as f:json.dump(doc,f,indent=2);f.write("\n")
PY
  chown root:snellv6 "$settings_tmp"
  chmod 640 "$settings_tmp"
  mv -fT -- "$settings_tmp" "$SETTINGS"
  /usr/bin/python3 -I "$SRC" --check
  cat > "$UNIT" <<'EOF'
# Managed by pansamrt/singboxSnell subscription
[Unit]
Description=Snell v6 HTTPS sing-box subscription endpoint
After=network-online.target snell-v6.service
Wants=network-online.target
[Service]
Type=simple
User=snellv6
Group=snellv6
ExecStart=/usr/bin/python3 -I /usr/local/lib/snell-v6/subscription_server.py
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
LockPersonality=true
RestrictSUIDSGID=true
UMask=0077
[Install]
WantedBy=multi-user.target
EOF
  cat > "$SYNC_UNIT" <<'EOF'
# Managed by pansamrt/singboxSnell subscription
[Unit]
Description=Refresh Snell HTTPS subscription TLS certificate after renewal
[Service]
Type=oneshot
ExecStart=/usr/local/bin/sn-sub sync-certs
EOF
  cat > "$TIMER" <<'EOF'
# Managed by pansamrt/singboxSnell subscription
[Unit]
Description=Check Snell subscription certificate renewal twice daily
[Timer]
OnCalendar=*-*-* 00,12:05:00
Persistent=true
Unit=snell-v6-subscription-cert-sync.service
[Install]
WantedBy=timers.target
EOF
  chmod 644 "$UNIT" "$SYNC_UNIT" "$TIMER"
  systemctl daemon-reload
  systemctl enable snell-v6-subscription.service
  systemctl restart snell-v6-subscription.service ||
    fail 'Subscription service failed; check journalctl -u snell-v6-subscription.service.'
  systemctl enable --now snell-v6-subscription-cert-sync.timer
  systemctl is-active --quiet snell-v6-subscription.service ||
    fail 'Subscription service is not running.'
  info "HTTPS subscription enabled on $domain:$port."
  info 'Existing Snell service, original certificates and other proxies were not modified.'
  show_links
}
disable() {
  require_root
  local answer
  if [[ "$1" != --yes ]]; then
    [[ -t 0 ]] || fail 'Interactive SSH terminal required.'
    read -r -p 'Disable HTTPS subscription only (keep Snell)? [y/N]: ' answer ||
      fail 'Confirmation required.'
    [[ "$answer" == Y || "$answer" == y ]] || { info 'Cancelled.'; return 0; }
  fi
  local file
  for file in "$UNIT" "$SYNC_UNIT" "$TIMER"; do ensure_known_unit "$file"; done
  if systemctl is-active --quiet snell-v6-subscription.service; then
    [[ "$(systemctl show snell-v6-subscription.service -p FragmentPath --value)" == "$UNIT" ]] ||
      fail 'Active subscription service has an unexpected systemd unit; refusing to stop it.'
  fi
  systemctl disable --now snell-v6-subscription-cert-sync.timer 2>/dev/null || true
  systemctl disable --now snell-v6-subscription.service 2>/dev/null || true
  for file in "$UNIT" "$SYNC_UNIT" "$TIMER"; do
    if [[ -f "$file" ]]; then rm -f -- "$file"; fi
  done
  systemctl daemon-reload
  [[ ! -L "$ROOT" ]] || fail 'Subscription directory symlink; manual inspection required.'
  if [[ -d "$ROOT" ]]; then
    [[ -z "$(find "$ROOT" -mindepth 1 -maxdepth 1 \
       ! -name settings.json ! -name tls-fullchain.pem ! -name tls-key.pem -print -quit)" ]] ||
       fail 'Unknown subscription files; manual inspection required.'
    rm -f -- "$SETTINGS" "$CERT" "$KEY"
    rmdir -- "$ROOT"
  fi
  rm -f -- "$QR" "$QR_IMPORT"
  info 'HTTPS subscription disabled; Snell server and original ACME certificates retained.'
}
menu() {
  [[ -t 0 ]] || fail 'Interactive SSH terminal required.'
  while true; do
    printf '\n===== Snell HTTPS Subscription =====\n'
    printf '  1) Setup / reconfigure HTTPS subscription\n'
    printf '  2) Show subscription URL and QR\n'
    printf '  3) Rotate subscription token\n'
    printf '  4) Disable HTTPS subscription (keep Snell)\n'
    printf '  0) Back\n'
    local answer
    read -r -p 'Choose [0-4]: ' answer || return 0
    case "$answer" in
      1) setup ;;
      2) show_links ;;
      3) rotate ;;
      4) disable "" ;;
      0) return 0 ;;
      *) info 'Invalid choice.' ;;
    esac
  done
}
require_root
case "${1:-}" in
  ""|menu) menu ;;
  setup) setup ;;
  show) show_links ;;
  rotate) rotate ;;
  disable) shift; disable "${1:-}" ;;
  sync-certs) sync_certs ;;
  *) printf 'Usage: sn sub [setup|show|rotate|disable]\n'; exit 1 ;;
esac
)
for path in files:
    try:
        if not path.is_file() or path.stat().st_size>2_000_000:
            continue
        data=path.read_text(encoding='utf-8',errors='replace')
    except OSError:
        continue
    for match in re.finditer(r'(?i)\bserver_name\s+([^;#]+);',data):
        names.update(match.group(1).split())
    for match in re.finditer(r'(?im)^\s*ServerName\s+(\S+)',data):
        names.add(match.group(1))
    for match in re.finditer(r"(?im)^\s*Le_Domain\s*=\s*['\"]?([^'\"\s]+)",data):
        names.add(match.group(1))
    if path.name=='Caddyfile':
        for match in re.finditer(r'(?m)^\s*([a-zA-Z0-9.-]+)(?::\d+)?\s*\{',data):
            names.add(match.group(1))
for name in sorted(names):
    if valid.fullmatch(name):
        print('  '+name)
PY
  printf 'These are candidate names, not proof of DNS ownership. Confirm one manually.\n'
}
show_dns() {
  python3 - "$1" "$2" <<'PY'
import ipaddress,socket,sys
domain,server=sys.argv[1:]
try:
    found=sorted({row[4][0] for row in socket.getaddrinfo(domain,None)})
except OSError as exc:
    raise SystemExit('Domain DNS resolution failed: '+str(exc))
print('DNS addresses for '+domain+': '+', '.join(found))
try:
    ipaddress.ip_address(server)
except ValueError:
    pass
else:
    if server not in found:
        print('WARNING: DNS does not match the supplied Snell server IP.')
        print('If behind Cloudflare proxy, ensure the proxy supports the HTTPS port;')
        print('the Snell TCP service usually needs a direct IP rather than a proxied name.')
PY
}
ensure_known_unit() {
  local file=$1
  if [[ -e "$file" || -L "$file" ]]; then
    [[ -f "$file" && ! -L "$file" ]] || fail "Unsafe unit file: $file"
    grep -Fxq '# Managed by pansamrt/singboxSnell subscription' "$file" ||
      fail "Unrelated systemd unit at $file; refusing overwrite."
  fi
}
copy_certificates() {
  local crt=$1 key=$2 domain=$3 dest temp
  cert_ok "$crt" "$key" "$domain" || fail 'Certificate invalid, expired/expiring, hostname mismatch, or key mismatch.'
  [[ -d "$ROOT" && ! -L "$ROOT" ]] || fail 'Missing subscription directory.'
  for dest in "$CERT" "$KEY"; do
    [[ ! -L "$dest" ]] || fail 'Refusing a symlinked subscription certificate.'
  done
  if [[ -f "$CERT" && -f "$KEY" ]] &&
     cmp -s "$crt" "$CERT" && cmp -s "$key" "$KEY"; then
    return 0
  fi
  temp=$(mktemp "$ROOT/.cert.XXXXXXXX")
  install -o root -g snellv6 -m 640 "$crt" "$temp"
  mv -fT -- "$temp" "$CERT"
  temp=$(mktemp "$ROOT/.key.XXXXXXXX")
  install -o root -g snellv6 -m 640 "$key" "$temp"
  mv -fT -- "$temp" "$KEY"
  info 'TLS certificate/key refreshed from the existing source (source unchanged).'
}
sync_certs() {
  require_root
  [[ -f "$SETTINGS" && ! -L "$SETTINGS" ]] || exit 0
  local source_cert source_key domain
  source_cert=$(read_setting source_cert)
  source_key=$(read_setting source_key)
  domain=$(read_setting domain)
  exec 9>/run/lock/snell-v6-subscription.lock
  flock -x 9
  copy_certificates "$source_cert" "$source_key" "$domain"
}
links() {
  python3 - "$SETTINGS" <<'PY'
import json,sys,urllib.parse
with open(sys.argv[1],encoding='utf-8') as f:d=json.load(f)
url=f"https://{d['domain']}:{d['listen_port']}/s/{d['token']}/config.json"
deep="sing-box://import-remote-profile?url="+urllib.parse.quote(url,safe="")+"#"+urllib.parse.quote(d["node_name"],safe="")
print(url)
print(deep)
PY
}
show_links() {
  require_root
  [[ -f "$SETTINGS" && ! -L "$SETTINGS" ]] || fail 'Not configured; choose Setup first.'
  local url deep
  url=$(links | sed -n '1p')
  deep=$(links | sed -n '2p')
  info "Subscription HTTPS URL (KEEP SECRET): $url"
  info "sing-box import URL (KEEP SECRET): $deep"
  info "HTTPS service: $(systemctl is-active snell-v6-subscription.service 2>/dev/null || true)"
  if ! command -v qrencode >/dev/null 2>&1; then
    info 'Installing qrencode for QR display (optional)...'
    apt-get install -y --no-install-recommends qrencode >/dev/null 2>&1 ||
      info 'WARNING: qrencode unavailable. Install apt package qrencode for QR support.'
  fi
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$url" || true
    qrencode -o "$QR" -s 6 -m 2 "$url"
    qrencode -o "$QR_IMPORT" -s 6 -m 2 "$deep"
    chmod 600 "$QR" "$QR_IMPORT"
    info "HTTPS subscription QR: $QR"
    info "sing-box import QR: $QR_IMPORT"
    info 'These QR files contain your secret access token. Do not share publicly.'
  fi
}
rotate() {
  require_root
  [[ -t 0 ]] || fail 'An interactive terminal is required.'
  [[ -f "$SETTINGS" ]] || fail 'Subscription is not configured.'
  local answer
  read -r -p 'Rotate access token? Old subscription URL will stop working [y/N]: ' answer ||
    fail 'Confirmation required.'
  [[ "$answer" == y || "$answer" == Y ]] || { info 'Cancelled.'; return 0; }
  python3 - "$SETTINGS" <<'PY'
import json,os,pathlib,secrets,tempfile,sys
p=pathlib.Path(sys.argv[1])
doc=json.loads(p.read_text(encoding='utf-8'))
doc['token']=secrets.token_hex(32)
fd,tmp=tempfile.mkstemp(prefix='.settings-',dir=p.parent)
try:
    os.fchown(fd,0,p.stat().st_gid)
    os.fchmod(fd,0o640)
    with os.fdopen(fd,'w',encoding='utf-8') as f:
        json.dump(doc,f,indent=2)
        f.write('\n')
    os.replace(tmp,p)
finally:
    if os.path.exists(tmp):os.unlink(tmp)
PY
  show_links
}
issue_cert() {
  local domain=$1 mail answer cert_name
  cert_name="snell-sub-$domain"
  info 'No existing trusted certificate covers this domain.'
  info 'ACME HTTP-01 requires public DNS pointing here and inbound TCP port 80.'
  python3 - <<'PY'
import socket
for family,host in ((socket.AF_INET,"0.0.0.0"), (socket.AF_INET6,"::")):
    try:
        sock=socket.socket(family,socket.SOCK_STREAM)
        if family==socket.AF_INET6:sock.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
        sock.bind((host,80))
        sock.close()
    except OSError as exc:
        raise SystemExit('TCP 80 is unavailable for ACME: '+str(exc))
PY
  read -r -p 'Issue a Let’s Encrypt ECC certificate using Certbot ACME? [y/N]: ' answer ||
    fail 'Confirmation required.'
  [[ "$answer" == y || "$answer" == Y ]] || fail 'Certificate issuance cancelled.'
  if ! command -v certbot >/dev/null 2>&1; then
    info 'Installing distribution Certbot via apt (does not change SSH or existing proxy settings).'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends certbot
  fi
  read -r -p 'ACME registration email (blank = no email): ' mail || fail 'Email input required.'
  local -a account=()
  if [[ -n "$mail" ]]; then
    account=(--email "$mail")
  else
    account=(--register-unsafely-without-email)
  fi
  certbot certonly --standalone --non-interactive --agree-tos \
    --key-type ecdsa --elliptic-curve secp256r1 \
    --preferred-challenges http --cert-name "$cert_name" \
    -d "$domain" "${account[@]}"
  SOURCE_CERT="/etc/letsencrypt/live/$cert_name/fullchain.pem"
  SOURCE_KEY="/etc/letsencrypt/live/$cert_name/privkey.pem"
}
setup() {
  require_root
  [[ -t 0 ]] || fail 'Interactive SSH terminal required.'
  require_snell
  local domain server name port family answer token tmpdir candidate settings_tmp
  if [[ -f "$SETTINGS" ]]; then
    read -r -p 'HTTPS subscription exists. Reconfigure and rotate token? [y/N]: ' answer ||
      fail 'Confirmation required.'
    [[ "$answer" == y || "$answer" == Y ]] || { info 'Cancelled.'; return 0; }
  fi
  suggest_domains
  read -r -p 'HTTPS subscription domain (DNS name, not IP): ' domain || fail 'Domain required.'
  validate_domain "$domain"
  read -r -p 'Snell server public IPv4/IPv6 (for client connections): ' server || fail 'Snell server address required.'
  python3 - "$server" <<'PY'
import ipaddress,sys
try:ipaddress.ip_address(sys.argv[1])
except ValueError:raise SystemExit('Enter a public IP address, not a URL.')
PY
  show_dns "$domain" "$server"
  read -r -p 'Node name [Snell-v6]: ' name || fail 'Node name required.'
  if [[ -z "$name" ]]; then name=Snell-v6; fi
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,49}$ ]] || fail 'Invalid node name.'
  read -r -p 'HTTPS subscription TCP port [8443]: ' port || fail 'Port required.'
  if [[ -z "$port" ]]; then port=8443; fi
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || fail 'Invalid port.'
  port=$((10#$port))
  (( port >= 1024 && port <= 65535 )) || fail 'Use an unprivileged HTTPS port 1024-65535.'
  family=ipv4
  if [[ "$server" == *:* ]]; then family=ipv6; fi
  read -r -p "HTTPS bind family [ipv4/ipv6] (default $family): " answer || fail 'Family required.'
  if [[ -n "$answer" ]]; then family=$answer; fi
  case "$family" in ipv4|ipv6) ;; *) fail 'Choose ipv4 or ipv6.' ;; esac
  local existing_port=""
  if [[ -f "$SETTINGS" && ! -L "$SETTINGS" ]]; then
    existing_port=$(read_setting listen_port)
  fi
  if ! systemctl is-active --quiet snell-v6-subscription.service ||
     [[ "$existing_port" != "$port" ]]; then
    python3 - "$port" "$family" <<'PY'
import socket,sys
port=int(sys.argv[1]);ipv6=sys.argv[2]=="ipv6"
with socket.socket(socket.AF_INET6 if ipv6 else socket.AF_INET,socket.SOCK_STREAM) as s:
    if ipv6:s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
    s.bind(("::" if ipv6 else "0.0.0.0",port))
print('PASS: HTTPS listen port is free.')
PY
  fi
  SOURCE_CERT=''
  SOURCE_KEY=''
  for candidate in /root/ygkkkca/fullchain.cer /root/ygkkkca/cert.crt; do
    if cert_ok "$candidate" /root/ygkkkca/private.key "$domain"; then
      SOURCE_CERT=$candidate; SOURCE_KEY=/root/ygkkkca/private.key
      break
    fi
  done
  if [[ -z "$SOURCE_CERT" ]]; then
    for candidate in /etc/letsencrypt/live/*/fullchain.pem; do
      [[ -f "$candidate" ]] || continue
      if cert_ok "$candidate" "$(dirname "$candidate")/privkey.pem" "$domain"; then
        SOURCE_CERT=$candidate; SOURCE_KEY="$(dirname "$candidate")/privkey.pem"
        break
      fi
    done
  fi
  if [[ -z "$SOURCE_CERT" ]]; then
    issue_cert "$domain"
  else
    info "Reusing existing domain certificate (read-only): $SOURCE_CERT"
  fi
  cert_ok "$SOURCE_CERT" "$SOURCE_KEY" "$domain" ||
    fail 'Selected certificate cannot be used for this domain.'
  read -r -p 'Enable token-protected HTTPS subscription? [y/N]: ' answer ||
    fail 'Confirmation required.'
  [[ "$answer" == y || "$answer" == Y ]] || { info 'Cancelled.'; return 0; }
  exec 9>/run/lock/snell-v6-subscription.lock
  flock -x 9
  for candidate in "$UNIT" "$SYNC_UNIT" "$TIMER"; do ensure_known_unit "$candidate"; done
  if [[ -e "$ROOT" || -L "$ROOT" ]]; then
    [[ -d "$ROOT" && ! -L "$ROOT" && "$(stat -c %u "$ROOT")" == 0 ]] ||
      fail 'Unexpected subscription directory.'
  else
    install -d -o root -g snellv6 -m 750 "$ROOT"
  fi
  install -d -o root -g root -m 755 /usr/local/lib/snell-v6
  tmpdir=$(mktemp -d /tmp/snell-sub-server.XXXXXXXX)
  trap 'rm -rf -- "$tmpdir"' EXIT
  curl --proto '=https' --tlsv1.2 -fL --retry 2 \
    --connect-timeout 15 --max-time 120 \
    https://raw.githubusercontent.com/pansamrt/singboxSnell/main/snell-v6-subscription-server.py \
    -o "$tmpdir/server.py" || fail 'Subscription backend download failed.'
  python3 - "$tmpdir/server.py" <<'PY'
import ast,sys
ast.parse(open(sys.argv[1],encoding="utf-8").read())
PY
  install -o root -g root -m 755 "$tmpdir/server.py" "$SRC"
  copy_certificates "$SOURCE_CERT" "$SOURCE_KEY" "$domain"
  token=$(openssl rand -hex 32)
  settings_tmp="$ROOT/.settings.new"
  [[ ! -L "$SETTINGS" && ! -L "$settings_tmp" ]] || fail 'Unsafe subscription settings path.'
  python3 - "$settings_tmp" "$domain" "$port" "$name" "$family" "$server" "$token" "$SOURCE_CERT" "$SOURCE_KEY" <<'PY'
import json,sys
path,domain,port,name,family,address,token,crt,key=sys.argv[1:]
doc=dict(domain=domain,listen_port=int(port),node_name=name,bind_family=family,
         snell_address=address,token=token,source_cert=crt,source_key=key)
with open(path,"w",encoding="utf-8") as f:json.dump(doc,f,indent=2);f.write("\n")
PY
  chown root:snellv6 "$settings_tmp"
  chmod 640 "$settings_tmp"
  mv -fT -- "$settings_tmp" "$SETTINGS"
  /usr/bin/python3 -I "$SRC" --check
  cat > "$UNIT" <<'EOF'
# Managed by pansamrt/singboxSnell subscription
[Unit]
Description=Snell v6 HTTPS sing-box subscription endpoint
After=network-online.target snell-v6.service
Wants=network-online.target
[Service]
Type=simple
User=snellv6
Group=snellv6
ExecStart=/usr/bin/python3 -I /usr/local/lib/snell-v6/subscription_server.py
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
LockPersonality=true
RestrictSUIDSGID=true
UMask=0077
[Install]
WantedBy=multi-user.target
EOF
  cat > "$SYNC_UNIT" <<'EOF'
# Managed by pansamrt/singboxSnell subscription
[Unit]
Description=Refresh Snell HTTPS subscription TLS certificate after renewal
[Service]
Type=oneshot
ExecStart=/usr/local/bin/sn-sub sync-certs
EOF
  cat > "$TIMER" <<'EOF'
# Managed by pansamrt/singboxSnell subscription
[Unit]
Description=Check Snell subscription certificate renewal twice daily
[Timer]
OnCalendar=*-*-* 00,12:05:00
Persistent=true
Unit=snell-v6-subscription-cert-sync.service
[Install]
WantedBy=timers.target
EOF
  chmod 644 "$UNIT" "$SYNC_UNIT" "$TIMER"
  systemctl daemon-reload
  systemctl enable snell-v6-subscription.service
  systemctl restart snell-v6-subscription.service ||
    fail 'Subscription service failed; check journalctl -u snell-v6-subscription.service.'
  systemctl enable --now snell-v6-subscription-cert-sync.timer
  systemctl is-active --quiet snell-v6-subscription.service ||
    fail 'Subscription service is not running.'
  info "HTTPS subscription enabled on $domain:$port."
  info 'Existing Snell service, original certificates and other proxies were not modified.'
  show_links
}
disable() {
  require_root
  local answer
  if [[ "$1" != --yes ]]; then
    [[ -t 0 ]] || fail 'Interactive SSH terminal required.'
    read -r -p 'Disable HTTPS subscription only (keep Snell)? [y/N]: ' answer ||
      fail 'Confirmation required.'
    [[ "$answer" == Y || "$answer" == y ]] || { info 'Cancelled.'; return 0; }
  fi
  local file
  for file in "$UNIT" "$SYNC_UNIT" "$TIMER"; do ensure_known_unit "$file"; done
  if systemctl is-active --quiet snell-v6-subscription.service; then
    [[ "$(systemctl show snell-v6-subscription.service -p FragmentPath --value)" == "$UNIT" ]] ||
      fail 'Active subscription service has an unexpected systemd unit; refusing to stop it.'
  fi
  systemctl disable --now snell-v6-subscription-cert-sync.timer 2>/dev/null || true
  systemctl disable --now snell-v6-subscription.service 2>/dev/null || true
  for file in "$UNIT" "$SYNC_UNIT" "$TIMER"; do
    if [[ -f "$file" ]]; then rm -f -- "$file"; fi
  done
  systemctl daemon-reload
  [[ ! -L "$ROOT" ]] || fail 'Subscription directory symlink; manual inspection required.'
  if [[ -d "$ROOT" ]]; then
    [[ -z "$(find "$ROOT" -mindepth 1 -maxdepth 1 \
       ! -name settings.json ! -name tls-fullchain.pem ! -name tls-key.pem -print -quit)" ]] ||
       fail 'Unknown subscription files; manual inspection required.'
    rm -f -- "$SETTINGS" "$CERT" "$KEY"
    rmdir -- "$ROOT"
  fi
  rm -f -- "$QR" "$QR_IMPORT"
  info 'HTTPS subscription disabled; Snell server and original ACME certificates retained.'
}
menu() {
  [[ -t 0 ]] || fail 'Interactive SSH terminal required.'
  while true; do
    printf '\n===== Snell HTTPS Subscription =====\n'
    printf '  1) Setup / reconfigure HTTPS subscription\n'
    printf '  2) Show subscription URL and QR\n'
    printf '  3) Rotate subscription token\n'
    printf '  4) Disable HTTPS subscription (keep Snell)\n'
    printf '  0) Back\n'
    local answer
    read -r -p 'Choose [0-4]: ' answer || return 0
    case "$answer" in
      1) setup ;;
      2) show_links ;;
      3) rotate ;;
      4) disable "" ;;
      0) return 0 ;;
      *) info 'Invalid choice.' ;;
    esac
  done
}
require_root
case "${1:-}" in
  ""|menu) menu ;;
  setup) setup ;;
  show) show_links ;;
  rotate) rotate ;;
  disable) shift; disable "${1:-}" ;;
  sync-certs) sync_certs ;;
  *) printf 'Usage: sn sub [setup|show|rotate|disable]\n'; exit 1 ;;
esac
