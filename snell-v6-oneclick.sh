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
INSTALL_SN_ONLY=0
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
       [--plan] [--replace-client] [--install-sn]

Default: installs standalone official Snell v6.0.0 on TCP 17888 (IPv4 only),
then writes /root/Snell-v6-ios.json for sing-box iOS 1.14+.
Name examples: Germany-Snell-v6, KR-Snell-v6 (filename: NAME-ios.json).

If an independent Snell installation already exists at the paths below,
its binary, service, port and PSK are reused without any modification.
A partially present installation is refused rather than overwritten.

--plan             Read-only inspection (no apt, download, or changes)
--replace-client   Allow atomic replacement of an existing root-only client JSON
--install-sn       Install/update sn manager (also works before Snell installation)
--family           New installations only; default ipv4, optional ipv6/dual
--port             New installations only; default 17888
EOF
}
# Embedded manager: no external download needed after initial installer.
install_sn_command() {
  local dest=/usr/local/bin/sn tmp
  [[ -d /usr/local/bin && ! -L /usr/local/bin ]] || { info 'WARNING: /usr/local/bin unavailable; manager not installed.' >&2; return 0; }
  if [[ -e "$dest" || -L "$dest" ]]; then
    if [[ ! -f "$dest" || -L "$dest" || "$(stat -c %u -- "$dest")" != 0 ]] || ! grep -Fxq '# SNELL_V6_MANAGER=1' "$dest"; then
      info "WARNING: existing $dest is not the Snell manager; refusing overwrite." >&2
      return 0
    fi
  fi
  tmp=$(mktemp /usr/local/bin/.sn.XXXXXXXX) || { info 'WARNING: Cannot stage sn manager.' >&2; return 0; }
  cat > "$tmp" <<'__SNELL_V6_MANAGER_SCRIPT_EOF__'
#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# SNELL_V6_MANAGER=1
# Independent Snell v6 only. Never edits SSH, firewall, routes, sing-box or Hysteria2.
set -Eeuo pipefail
umask 077
CONF=/etc/snell-v6/snell-server.conf
UNIT=/etc/systemd/system/snell-v6.service
BIN=/opt/snell-v6/snell-server

info() { printf '[sn] %s\n' "$*"; }
fail() { printf '[sn] ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Snell v6 standalone manager:
  sn              Interactive menu
  sn status       Show status and current TCP port
  sn port         Change TCP port with interactive prompt and rollback
  sn install      Install standalone Snell v6 (guided)
  sn uninstall    Remove standalone Snell v6, keep sn command
  sn sub          HTTPS subscription, domain/TLS and QR menu
  sn sub setup    Setup HTTPS subscription (existing ECC certificate or ACME)
  sn sub show     Show subscription URL and QR
  sn sub update   Update local subscription helper from this project
  sn --help       Display this help
EOF
}
installation_state() {
  local n=0 path
  for path in "$BIN" "$CONF" "$UNIT"; do
    if [[ -e "$path" || -L "$path" ]]; then n=$((n+1)); fi
  done
  case "$n" in 0) echo absent;; 3) echo present;; *) echo partial;; esac
}
precheck() {
  [[ $EUID -eq 0 ]] || fail 'Run as root (sudo sn).'
  for path in "$CONF" "$UNIT" "$BIN"; do
    [[ -f "$path" && ! -L "$path" ]] || fail "Standalone Snell file missing or symlink: $path"
    [[ "$(stat -c %u -- "$path")" == 0 ]] || fail "Standalone Snell file must be root-owned: $path"
  done
  [[ -d /etc/snell-v6 && ! -L /etc/snell-v6 ]] || fail 'Snell config directory is unsafe.'
  grep -Fxq 'ExecStart=/opt/snell-v6/snell-server -c /etc/snell-v6/snell-server.conf' "$UNIT" ||
    fail 'Unexpected snell-v6 systemd unit. No changes made.'
  for prog in python3 systemctl flock; do
    command -v "$prog" >/dev/null 2>&1 || fail "Required program missing: $prog"
  done
}
current_port() {
  python3 - "$CONF" <<'PY'
import configparser, re, sys
cfg = configparser.ConfigParser(interpolation=None)
with open(sys.argv[1], encoding='utf-8') as f:
    cfg.read_file(f)
ports = set()
for entry in cfg.get('snell-server', 'listen').split(','):
    entry = entry.strip()
    m = re.fullmatch(r'(0\.0\.0\.0|\[::\]|(?:\d{1,3}\.){3}\d{1,3}|\[[0-9a-fA-F:]+\]):([0-9]{1,5})', entry)
    if not m:
        raise SystemExit('Unsupported listen address: ' + entry)
    ports.add(int(m.group(2)))
if len(ports) != 1:
    raise SystemExit('Multiple distinct Snell listener ports; refusing automatic edit.')
print(ports.pop())
PY
}
show_status() {
  case "$(installation_state)" in
    absent) info 'Snell not installed. Run sn install.'; return 0 ;;
    partial) fail 'Partial Snell installation; inspect manually.' ;;
  esac
  precheck
  local old
  old=$(current_port)
  info "Current Snell TCP port: $old"
  info "snell-v6.service: $(systemctl is-active snell-v6.service 2>/dev/null || true)"
}
change_port() (
  set -Eeuo pipefail
  precheck
  [[ -t 0 ]] || fail 'Changing port requires an interactive terminal.'
  systemctl is-active --quiet snell-v6.service || fail 'Snell service not active. Diagnose before modifying.'
  local old new confirm backup="" edited=0 committed=0
  old=$(current_port)
  printf '\nSnell v6 current TCP port: %s\n' "$old"
  read -r -p 'New TCP port (1024-65535): ' new
  [[ "$new" =~ ^[0-9]{1,5}$ ]] || fail 'Enter a decimal port in range 1024-65535.'
  new=$((10#$new))
  ((new >= 1024 && new <= 65535)) || fail 'Port must be 1024-65535.'
  if ((new == old)); then info 'Port unchanged.'; exit 0; fi
  printf 'Snell port: %s -> %s. PSK will stay unchanged.\n' "$old" "$new"
  printf 'Provider firewall must allow new TCP %s; iPhone profile must be updated.\n' "$new"
  read -r -p 'Type YES to confirm: ' confirm
  [[ "$confirm" == YES ]] || { info 'Cancelled; no changes.'; exit 0; }

  exec 9>/run/lock/snell-v6-port.lock
  flock -n 9 || fail 'Another Snell port change is underway.'
  [[ "$(current_port)" == "$old" ]] || fail 'Port changed concurrently; retry.'

  # Test every actual configured IPv4/IPv6 TCP listen address, not just 0.0.0.0.
  python3 - "$CONF" "$new" <<'PY'
import configparser, ipaddress, socket, sys
cfg = configparser.ConfigParser(interpolation=None)
cfg.read(sys.argv[1])
port = int(sys.argv[2])
for entry in cfg.get('snell-server', 'listen').split(','):
    host = entry.strip().rsplit(':', 1)[0].strip('[]')
    address = ipaddress.ip_address(host)
    family = socket.AF_INET if address.version == 4 else socket.AF_INET6
    with socket.socket(family, socket.SOCK_STREAM) as sock:
        if family == socket.AF_INET6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        try:
            sock.bind((host, port))
        except OSError as ex:
            raise SystemExit(f'TCP {host}:{port} not available: {ex}')
print('PASS: New TCP port free on configured bind addresses.')
PY

  rollback() {
    local rc=$?
    trap - EXIT HUP INT TERM
    if ((edited && ! committed)); then
      info "Port change failed. Restoring TCP $old and restarting ONLY snell-v6.service..." >&2
      if cp -p -- "$backup" "$CONF" && systemctl restart snell-v6.service; then
        info "Original Snell config and port $old restored." >&2
      else
        info "WARNING: Rollback failed. Inspect service; backup kept at $backup." >&2
        exit "$rc"
      fi
    fi
    [[ -z "$backup" ]] || rm -f -- "$backup"
    exit "$rc"
  }
  trap rollback EXIT
  backup=$(mktemp /etc/snell-v6/.port-backup.XXXXXXXX)
  cp -p -- "$CONF" "$backup"

  edited=1
  python3 - "$CONF" "$new" <<'PY'
import os, pathlib, re, stat, sys, tempfile
path, port = pathlib.Path(sys.argv[1]), int(sys.argv[2])
old = path.read_text(encoding='utf-8')
rx = re.compile(r'^(\s*listen\s*=\s*)([^\r\n]+)$', re.MULTILINE)
matches = rx.findall(old)
if len(matches) != 1:
    raise SystemExit('Expected exactly one listen setting.')
def rewrite(match):
    addresses = [item.strip() for item in match.group(2).split(',')]
    return match.group(1) + ','.join(item.rsplit(':', 1)[0] + ':' + str(port) for item in addresses)
new_config = rx.sub(rewrite, old, count=1)
metadata = path.stat()
fd, tmp = tempfile.mkstemp(prefix='.snell-listen-', dir=path.parent)
try:
    os.fchmod(fd, stat.S_IMODE(metadata.st_mode))
    os.fchown(fd, metadata.st_uid, metadata.st_gid)
    with os.fdopen(fd, 'w', encoding='utf-8') as out:
        out.write(new_config)
        out.flush()
        os.fsync(out.fileno())
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
  systemctl restart snell-v6.service
  systemctl is-active --quiet snell-v6.service || fail 'Snell did not restart; rollback triggered.'
  python3 - "$CONF" "$new" <<'PY'
import configparser, socket, sys, time
cfg = configparser.ConfigParser(interpolation=None)
cfg.read(sys.argv[1])
item = cfg.get('snell-server', 'listen').split(',')[0].strip()
host = item.rsplit(':', 1)[0].strip('[]')
if host == '0.0.0.0':
    host = '127.0.0.1'
elif host == '::':
    host = '::1'
port = int(sys.argv[2])
for _ in range(12):
    try:
        with socket.create_connection((host, port), timeout=1.0):
            print('PASS: Snell v6 local TCP ready on', host, port)
            break
    except OSError:
        time.sleep(.3)
else:
    raise SystemExit('New TCP listener not ready; rollback triggered.')
PY
  committed=1
  rm -f -- "$backup"
  backup=""
  info "SUCCESS: Snell TCP port $old -> $new. PSK unchanged."

  # Private, root-owned local sing-box profiles only; match local PSK & old port.
  # Never update unrelated VPS nodes or any iPhone configuration remotely.
  if ! python3 - "$CONF" "$old" "$new" <<'PY'
import configparser, json, os, pathlib, stat, sys, tempfile
cfg = configparser.ConfigParser(interpolation=None)
cfg.read(sys.argv[1])
psk = cfg.get('snell-server', 'psk')
old, new = int(sys.argv[2]), int(sys.argv[3])
updated = 0
for path in pathlib.Path('/root').glob('*-ios.json'):
    try:
        st = path.lstat()
        if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o077:
            print('SKIP unsafe client JSON:', path.name)
            continue
        doc = json.loads(path.read_text(encoding='utf-8'))
        matches = [
            item for item in doc.get('outbounds', [])
            if isinstance(item, dict) and item.get('type') == 'snell'
            and item.get('version') == 6 and item.get('psk') == psk
            and item.get('server_port') == old
        ]
        if not matches:
            continue
        for item in matches:
            item['server_port'] = new
        fd, temp = tempfile.mkstemp(prefix='.snell-profile-', suffix='.json', dir=path.parent)
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as f:
                json.dump(doc, f, ensure_ascii=False, indent=2)
                f.write('\n')
                f.flush()
                os.fsync(f.fileno())
            os.chmod(temp, 0o600)
            os.replace(temp, path)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)
        updated += 1
        print('UPDATED client JSON:', path)
    except (OSError, ValueError, TypeError, KeyError) as ex:
        print('WARNING: Failed to update client:', path.name, type(ex).__name__)
print('Private local iOS profiles updated:', updated)
PY
  then
    info 'WARNING: Some iOS JSON files may need manual port updates.' >&2
  fi

  info "Ensure TCP $new is allowed by your VPS provider/security group."
  info 'Re-import the updated JSON on iOS sing-box or change its server_port manually.'
  info 'No SSH, firewall, other proxies, routing or PSK were modified.'
)
install_snell() (
  [[ $EUID -eq 0 ]] || fail 'Run as root.'
  [[ -t 0 ]] || fail 'Interactive SSH terminal required.'
  case "$(installation_state)" in
    present) precheck; info 'Snell already installed. Use sn status.'; exit 0 ;;
    partial) fail 'Partial installation; will not overwrite.' ;;
  esac
  command -v curl >/dev/null || fail 'curl required.'
  command -v flock >/dev/null || fail 'flock required.'
  local server name port family answer tmpdir
  local -a extra_args=()
  printf '\n===== Install Snell v6 =====\n'
  read -r -p 'Public VPS IPv4/IPv6: ' server || fail 'IP required.'
  [[ -n "$server" ]] || fail 'IP required.'
  read -r -p 'Node name [Snell-v6]: ' name || fail 'Name required.'
  if [[ -z "$name" ]]; then name=Snell-v6; fi
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,49}$ ]] || fail 'Invalid node name.'
  read -r -p 'TCP port [17888]: ' port || fail 'Port required.'
  if [[ -z "$port" ]]; then port=17888; fi
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || fail 'Invalid TCP port.'
  port=$((10#$port))
  ((port >= 1024 && port <= 65535)) || fail 'Port must be 1024-65535.'
  family=ipv4
  if [[ "$server" == *:* ]]; then family=ipv6; fi
  read -r -p "Listener family [ipv4/ipv6/dual] (default $family): " answer || fail 'Family required.'
  if [[ -n "$answer" ]]; then family=$answer; fi
  case "$family" in ipv4|ipv6|dual) ;; *) fail 'Invalid listener family.' ;; esac
  if [[ -e "/root/$name-ios.json" || -L "/root/$name-ios.json" ]]; then
    read -r -p 'Existing private iOS profile will be REPLACED. Type YES: ' answer || fail 'Confirmation required.'
    [[ "$answer" == YES ]] || { info 'Cancelled; existing profile retained.'; exit 0; }
    extra_args+=(--replace-client)
  fi
  printf 'Install Snell v6, TCP %s, %s listener, node %s.\n' "$port" "$family" "$name"
  read -r -p 'Type INSTALL to continue: ' answer || fail 'Confirmation required.'
  [[ "$answer" == INSTALL ]] || { info 'Cancelled.'; exit 0; }
  exec 9>/run/lock/snell-v6-port.lock
  flock -n 9 || fail 'Another Snell management action is running.'
  [[ "$(installation_state)" == absent ]] || fail 'Snell paths changed; abort.'
  tmpdir=$(mktemp -d /tmp/sn-install.XXXXXXXX)
  trap 'rm -rf -- "$tmpdir"' EXIT
  curl --proto '=https' --tlsv1.2 -fL --retry 2 --connect-timeout 15 --max-time 120 \
    https://raw.githubusercontent.com/pansamrt/singboxSnell/main/snell-v6-oneclick.sh \
    -o "$tmpdir/snell-v6-oneclick.sh" || fail 'Download failed.'
  bash -n "$tmpdir/snell-v6-oneclick.sh" || fail 'Invalid downloaded script.'
  bash "$tmpdir/snell-v6-oneclick.sh" --server "$server" --name "$name" \
    --port "$port" --family "$family" "${extra_args[@]}"
  info 'Snell installation completed; update/import your iOS client profile.'
)
uninstall_snell() (
  [[ $EUID -eq 0 ]] || fail 'Run as root.'
  [[ -t 0 ]] || fail 'Interactive SSH terminal required.'
  case "$(installation_state)" in
    absent) info 'Snell not installed; sn manager is still available.'; exit 0 ;;
    partial) fail 'Partial installation; will not delete unknown files.' ;;
  esac
  precheck
  [[ "$(systemctl show snell-v6.service -p FragmentPath --value)" == "$UNIT" ]] ||
    fail 'Unexpected loaded service unit.'
  [[ -z "$(systemctl show snell-v6.service -p DropInPaths --value)" ]] ||
    fail 'Custom systemd service drop-ins detected; inspect first.'
  grep -Fxq 'User=snellv6' "$UNIT" && grep -Fxq 'Group=snellv6' "$UNIT" ||
    fail 'Unexpected service user/group.'
  [[ -z "$(find /opt/snell-v6 -mindepth 1 -maxdepth 1 ! -name snell-server -print -quit)" ]] ||
    fail 'Unexpected files inside /opt/snell-v6; inspect first.'
  [[ -z "$(find /etc/snell-v6 -mindepth 1 -maxdepth 1 ! -name snell-server.conf ! -name subscription -print -quit)" ]] ||
    fail 'Unexpected files inside /etc/snell-v6; inspect first.'
  if [[ -e /etc/snell-v6/subscription || -e /etc/systemd/system/snell-v6-subscription.service ]]; then
    [[ -x /usr/local/bin/sn-sub ]] ||
      fail 'Subscription installation found but sn-sub manager missing; inspect before uninstalling.'
  fi
  printf '\n===== Uninstall Snell v6 =====\n'
  printf 'Will stop and delete ONLY snell-v6.service, Snell executable and config.\n'
  printf 'Keeps the sn manager and /root/*-ios.json client profile backups.\n'
  printf 'Existing Snell client connections will STOP working.\n'
  local answer
  read -r -p 'Confirm uninstall Snell v6? [y/N]: ' answer || fail 'Confirmation required.'
  case "$answer" in
    y|Y) ;;
    *) info 'Cancelled; Snell was not removed.'; exit 0 ;;
  esac
  exec 9>/run/lock/snell-v6-port.lock
  flock -n 9 || fail 'Another Snell management action is running.'
  precheck
  if [[ -e /etc/snell-v6/subscription || -e /etc/systemd/system/snell-v6-subscription.service ]]; then
    /usr/local/bin/sn-sub disable --yes ||
      fail 'Could not safely disable HTTPS subscription; Snell was not removed.'
  fi
  systemctl disable --now snell-v6.service || fail 'Failed to stop Snell; files retained.'
  if systemctl is-active --quiet snell-v6.service; then fail 'Snell still running; files retained.'; fi
  rm -f -- "$UNIT"
  systemctl daemon-reload
  rm -f -- "$BIN" "$CONF"
  rmdir -- /opt/snell-v6 /etc/snell-v6 || fail 'Snell files removed; inspect remaining directories.'
  if getent passwd snellv6 >/dev/null 2>&1; then
    if [[ "$(getent passwd snellv6 | cut -d: -f6,7)" == /nonexistent:/usr/sbin/nologin ]]; then
      userdel snellv6 || fail 'Snell removed but service account cleanup failed.'
    else
      info 'WARNING: customized snellv6 user retained; inspect before reinstalling.'
    fi
  fi
  if getent group snellv6 >/dev/null 2>&1; then
    groupdel snellv6 || fail 'Snell removed but dedicated group cleanup failed.'
  fi
  info 'SUCCESS: Snell service removed. sn and private iOS JSON files retained.'
  info 'Run sn install to reinstall; new PSK requires updating your clients.'
  info 'SSH, Hysteria2, other proxies, firewall and routing were unchanged.'
)
subscription_menu() (
  [[ $EUID -eq 0 ]] || fail 'Run as root.'
  local dest=/usr/local/bin/sn-sub temp refresh=0
  if [[ "${1:-}" == update ]]; then refresh=1; shift; fi
  [[ -d /usr/local/bin && ! -L /usr/local/bin ]] || fail 'Unsafe /usr/local/bin.'
  if [[ -e "$dest" || -L "$dest" ]]; then
    [[ -f "$dest" && ! -L "$dest" && -x "$dest" &&
       "$(stat -c %u -- "$dest")" == 0 ]] ||
      fail "Unsafe existing $dest; refusing to run."
    grep -Fxq '# SNELL_V6_SUBSCRIPTION_MANAGER=1' "$dest" ||
      fail "Existing $dest is not the project subscription manager."
  fi
  if (( refresh )) || [[ ! -e "$dest" && ! -L "$dest" ]]; then
    command -v curl >/dev/null 2>&1 || fail 'curl is required to bootstrap subscriptions.'
    temp=$(mktemp /usr/local/bin/.sn-sub.XXXXXXXX) ||
      fail 'Cannot stage subscription manager.'
    if ! curl --proto '=https' --tlsv1.2 -fL --retry 2 \
         --connect-timeout 15 --max-time 120 \
         https://raw.githubusercontent.com/pansamrt/singboxSnell/main/snell-v6-subscribe.sh \
         -o "$temp" ||
       ! grep -Fxq '# SNELL_V6_SUBSCRIPTION_MANAGER=1' "$temp" ||
       ! bash -n "$temp"; then
      rm -f -- "$temp"
      fail 'Cannot download or verify the subscription manager.'
    fi
    chmod 700 "$temp"
    mv -T -- "$temp" "$dest"
    info 'Installed/updated local HTTPS subscription manager /usr/local/bin/sn-sub.'
  fi
  if (( refresh )); then return 0; fi
  "$dest" "$@"
)
main() {
  if (( $# >= 1 )) && [[ "$1" == sub ]]; then
    shift
    subscription_menu "$@"
    return
  fi
  case "$*" in
    --help|-h|help) usage ;;
    status) show_status ;;
    port) change_port ;;
    install) install_snell ;;
    uninstall) uninstall_snell ;;
    "")
      [[ -t 0 ]] || fail 'Interactive menu requires an SSH terminal.'
      while true; do
        printf '\n===== Snell v6 Manager v1.1.0 =====\n'
        printf '  1) Change TCP port\n  2) Show status\n  3) Install Snell v6\n  4) Uninstall Snell v6\n  5) HTTPS subscription / QR\n  0) Exit\n'
        read -r -p 'Choose [0-5]: ' choice || exit 0
        case "$choice" in
          1) change_port ;;
          2) show_status ;;
          3) install_snell ;;
          4) uninstall_snell ;;
          5) subscription_menu ;;
          0) exit 0 ;;
          *) info 'Invalid selection.' ;;
        esac
      done
      ;;
    *) usage; fail 'Unknown command.' ;;
  esac
}
main "$@"
__SNELL_V6_MANAGER_SCRIPT_EOF__
  if ! bash -n "$tmp"; then info 'WARNING: Invalid sn manager syntax.' >&2; rm -f -- "$tmp"; return 0; fi
  chmod 755 "$tmp"
  mv -fT -- "$tmp" "$dest"
  info "Installed Snell management command $dest (enter sn for menu)."
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
    --server|--name|--port|--family)
      (( $# >= 2 )) && [[ -n "$2" ]] || fail "Missing value after $1"
      case "$1" in
        --server) SERVER=$2 ;;
        --name) NAME=$2 ;;
        --port) PORT=$2; PORT_GIVEN=1 ;;
        --family) FAMILY=$2; FAMILY_GIVEN=1 ;;
      esac
      shift 2 ;;
    --plan) PLAN=1; shift ;;
    --replace-client) REPLACE_CLIENT=1; shift ;;
    --install-sn) INSTALL_SN_ONLY=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage; fail "Unknown argument: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || fail 'Please run as root (sudo bash ...).'
[[ -r /etc/os-release ]] || fail 'Cannot read /etc/os-release.'
# shellcheck source=/etc/os-release
# /etc/os-release also defines NAME and VERSION; preserve Snell's own values.
SNELL_SAVED_NAME=$NAME
SNELL_SAVED_VERSION=$VERSION
. /etc/os-release
NAME=$SNELL_SAVED_NAME
VERSION=$SNELL_SAVED_VERSION
unset SNELL_SAVED_NAME SNELL_SAVED_VERSION
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

if (( INSTALL_SN_ONLY )); then
  count=0
  for path in "$BIN" "$CONF" "$UNIT"; do
    if [[ -e "$path" || -L "$path" ]]; then count=$((count+1)); fi
  done
  if (( count == 3 )); then
    [[ -f "$BIN" && -f "$CONF" && -f "$UNIT" && ! -L "$BIN" && ! -L "$CONF" && ! -L "$UNIT" ]] ||
      fail 'Unsafe existing Snell installation.'
    grep -Fxq 'ExecStart=/opt/snell-v6/snell-server -c /etc/snell-v6/snell-server.conf' "$UNIT" ||
      fail 'Unexpected Snell service unit.'
  elif (( count > 0 )); then
    fail 'Partial Snell installation; refusing sn manager setup.'
  fi
  install_sn_command
  [[ -x /usr/local/bin/sn ]] && grep -Fxq '# SNELL_V6_MANAGER=1' /usr/local/bin/sn ||
    fail 'sn manager was not installed (possibly conflicting command).'
  exit 0
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

install_sn_command
info "SUCCESS: ${APP_NAME}.service is active; independent Snell and sing-box installations coexist."
info "Client profile: $OUT"
info 'The profile can be downloaded via Xshell/Xftp SFTP, then imported via sing-box iOS > Profiles > Import from File.'
info 'Local TCP test is NOT a real external Snell handshake. Confirm provider firewall permits the TCP port.'
info 'No firewall, SSH, routing, host DNS, kernel, or existing proxy services were edited.'