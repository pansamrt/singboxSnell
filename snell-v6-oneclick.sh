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
check_dependency_commands() {
  local cmd missing=()
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} )); then
    fail "Missing command(s): ${missing[*]}. Install the corresponding Debian/Ubuntu packages before continuing; no automatic apt changes for an existing installation."
  fi
}

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
fail() { printf '[sn] 错误： %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Snell v6 管理工具：
  sn              打开交互式菜单
  sn status       查看运行状态和 TCP 端口
  sn json         查看本机 sing-box iOS JSON 配置（默认隐藏 PSK）
  sn port         修改 TCP 端口（失败自动回滚）
  sn install      一键安装 Snell v6
  sn uninstall    卸载 Snell v6（保留 sn 命令）
  sn sub          直接显示订阅地址与二维码
  sn sub menu     打开 HTTPS 订阅管理菜单
  sn sub setup    配置 HTTPS 订阅（复用 ECC 证书或申请 ACME）
  sn sub show     查看订阅地址和二维码
  sn sub update   更新订阅管理组件
  sn --help       显示帮助
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
  [[ $EUID -eq 0 ]] || fail '请使用 root 权限运行（sudo sn）。'
  for path in "$CONF" "$UNIT" "$BIN"; do
    [[ -f "$path" && ! -L "$path" ]] || fail "独立 Snell 文件缺失或是软链接： $path"
    [[ "$(stat -c %u -- "$path")" == 0 ]] || fail "独立 Snell 文件必须由 root 所有： $path"
  done
  [[ -d /etc/snell-v6 && ! -L /etc/snell-v6 ]] || fail 'Snell 配置目录存在安全风险。'
  grep -Fxq 'ExecStart=/opt/snell-v6/snell-server -c /etc/snell-v6/snell-server.conf' "$UNIT" ||
    fail 'snell-v6 服务文件不符合预期，未进行修改。'
  for prog in python3 systemctl flock; do
    command -v "$prog" >/dev/null 2>&1 || fail "缺少必要程序： $prog"
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
        raise SystemExit('不支持的监听地址： ' + entry)
    ports.add(int(m.group(2)))
if len(ports) != 1:
    raise SystemExit('检测到多个不同的监听端口，拒绝自动修改。')
print(ports.pop())
PY
}
show_status() {
  case "$(installation_state)" in
    absent) info 'Snell 未安装，请运行 sn install。'; return 0 ;;
    partial) fail 'Snell 安装不完整，请手动检查。' ;;
  esac
  precheck
  local old
  old=$(current_port)
  info "当前 Snell TCP 端口： $old"
  info "snell-v6.service 状态：$(systemctl is-active snell-v6.service 2>/dev/null || true)"
}
# View root-owned private sing-box/Snell iOS profiles generated by this installer.
print_client_json() {
  local file=$1 reveal=$2
  python3 - "$file" "$reveal" <<'PY'
import json, os, pathlib, re, stat, sys
path=pathlib.Path(sys.argv[1])
if path.parent != pathlib.Path("/root") or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,49}-ios\.json",path.name):
    raise SystemExit("仅允许查看 /root/ 下本项目生成的 *-ios.json 配置文件。")
fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
with os.fdopen(fd,"r",encoding="utf-8") as handle:
    st=os.fstat(handle.fileno())
    if not stat.S_ISREG(st.st_mode) or st.st_uid!=0 or st.st_mode & 0o077:
        raise SystemExit("拒绝读取非 root 所有或权限过宽的私有配置。")
    doc=json.load(handle)
if not isinstance(doc,dict) or not any(
    isinstance(v,dict) and v.get("type")=="snell" and v.get("version")==6
    for v in doc.get("outbounds",[]) if isinstance(doc.get("outbounds"),list)
):
    raise SystemExit("文件不是 Snell v6 的 sing-box 客户端配置。")
if sys.argv[2]!="reveal":
    hidden={"psk","password","secret","token","private_key","uuid","auth","auth_str"}
    def mask(value):
        if isinstance(value,dict):
            return {k:("[已隐藏]" if k.lower() in hidden else mask(v)) for k,v in value.items()}
        if isinstance(value,list):
            return [mask(v) for v in value]
        return value
    doc=mask(doc)
print(json.dumps(doc,ensure_ascii=False,indent=2))
PY
}
show_client_json() {
  [[ $EUID -eq 0 ]] || fail '请使用 root 权限查看私有配置。'
  command -v python3 >/dev/null 2>&1 || fail '缺少 python3，无法查看配置。'
  [[ -d /root && ! -L /root ]] || fail '根用户配置目录不安全。'
  local -a profiles=()
  local file choice i selected
  while IFS= read -r -d '' file; do
    profiles+=("$file")
  done < <(python3 - <<'PY'
import json, os, pathlib, re, stat, sys
root=pathlib.Path("/root")
for path in sorted(root.glob("*-ios.json")):
    try:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,49}-ios\.json",path.name):
            continue
        st=path.lstat()
        if not stat.S_ISREG(st.st_mode) or st.st_uid!=0 or st.st_mode & 0o077:
            continue
        fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
        with os.fdopen(fd,"r",encoding="utf-8") as handle:
            doc=json.load(handle)
        if not isinstance(doc,dict) or not isinstance(doc.get("outbounds"),list):
            continue
        if not any(isinstance(o,dict) and o.get("type")=="snell" and o.get("version")==6
                   for o in doc["outbounds"]):
            continue
        sys.stdout.buffer.write(os.fsencode(str(path))+b"\0")
    except (OSError,ValueError,TypeError,UnicodeError,json.JSONDecodeError):
        continue
PY
  )
  if (( ${#profiles[@]} == 0 )); then
    info '未找到本项目生成的 /root/*-ios.json 配置。'
    return 0
  fi
  if (( ${#profiles[@]} == 1 )); then
    selected=${profiles[0]}
  else
    printf '\n===== 可查看的 sing-box iOS JSON 配置 =====\n'
    for i in "${!profiles[@]}"; do
      printf '  %d) %s\n' "$((i+1))" "${profiles[i]##*/}"
    done
    [[ -t 0 ]] || { info '发现多个配置文件，请在交互式 SSH 终端中选择。'; return 0; }
    while true; do
      read -r -p '请选择配置编号（0 返回）： ' choice || return 0
      [[ "$choice" == 0 ]] && return 0
      selected=''
      for i in "${!profiles[@]}"; do
        if [[ "$choice" == "$((i+1))" ]]; then selected=${profiles[i]}; break; fi
      done
      if [[ -n "$selected" ]]; then break; fi
      info '编号无效，请重新输入。'
    done
  fi
  printf '\n===== sing-box 配置：%s（PSK 已隐藏） =====\n' "${selected##*/}"
  print_client_json "$selected" masked || return 1
  if [[ -t 0 ]]; then
    printf '\n警告：完整配置含有 Snell PSK，请勿截图、公开或发送给他人。\n'
    read -r -p '要显示完整原文请输入 SHOW（其他输入返回）： ' choice || return 0
    if [[ "$choice" == SHOW ]]; then
      printf '\n===== 完整配置（含敏感密钥）：%s =====\n' "${selected##*/}"
      print_client_json "$selected" reveal
    fi
  fi
}
change_port() (
  set -Eeuo pipefail
  precheck
  [[ -t 0 ]] || fail '修改端口需要交互式终端。'
  systemctl is-active --quiet snell-v6.service || fail 'Snell service not active. Diagnose before modifying.'
  local old new confirm backup="" edited=0 committed=0
  old=$(current_port)
  printf '\nSnell v6 当前 TCP 端口： %s\n' "$old"
  read -r -p '请输入新的 TCP 端口（1024-65535）： ' new
  [[ "$new" =~ ^[0-9]{1,5}$ ]] || fail '请输入 1024-65535 之间的端口号。'
  new=$((10#$new))
  ((new >= 1024 && new <= 65535)) || fail '端口必须在 1024-65535 范围内。'
  if ((new == old)); then info '端口没有变化。'; exit 0; fi
  printf 'Snell 端口：%s → %s，PSK 不变。\n' "$old" "$new"
  printf '请在服务商防火墙放行 TCP %s，并同步更新 iPhone 配置。\n' "$new"
  read -r -p '请输入 YES 确认修改： ' confirm
  [[ "$confirm" == YES ]] || { info '已取消，未进行修改。'; exit 0; }

  exec 9>/run/lock/snell-v6-port.lock
  flock -n 9 || fail '另一项端口修改正在进行。'
  [[ "$(current_port)" == "$old" ]] || fail '端口已被其他操作修改，请重试。'

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
            raise SystemExit(f'TCP {host}:{port} 不可用：{ex}')
print('检查通过：新 TCP 端口未被占用。')
PY

  rollback() {
    local rc=$?
    trap - EXIT HUP INT TERM
    if ((edited && ! committed)); then
      info "端口修改失败，正在恢复 TCP $old 并仅重启 snell-v6.service……" >&2
      if cp -p -- "$backup" "$CONF" && systemctl restart snell-v6.service; then
        info "原配置和端口 $old 已恢复。" >&2
      else
        info "警告：回滚失败，请检查服务；备份保留在 $backup。" >&2
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
    raise SystemExit('配置中必须只有一项 listen 设置。')
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
  systemctl is-active --quiet snell-v6.service || fail 'Snell 重启失败，正在执行回滚。'
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
            print('检查通过：Snell v6 本地 TCP 监听正常：', host, port)
            break
    except OSError:
        time.sleep(.3)
else:
    raise SystemExit('新 TCP 监听端口尚未就绪，正在回滚。')
PY
  committed=1
  rm -f -- "$backup"
  backup=""
  info "修改成功：Snell TCP 端口 $old → $new，PSK 不变。"

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
            print('跳过不安全的客户端 JSON：', path.name)
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
        print('已更新客户端 JSON：', path)
    except (OSError, ValueError, TypeError, KeyError) as ex:
        print('警告：客户端配置更新失败：', path.name, type(ex).__name__)
print('已更新的本地 iOS 私有配置数量：', updated)
PY
  then
    info '警告：部分 iOS JSON 文件可能仍需手动更新端口。' >&2
  fi

  info "请确认 VPS 服务商防火墙已放行 TCP $new。"
  info '请在 iOS sing-box 重新导入 JSON，或手动修改 server_port。'
  info '未修改 SSH、防火墙、其他代理、路由或 PSK。'
)
install_snell() (
  [[ $EUID -eq 0 ]] || fail '请使用 root 权限运行。'
  [[ -t 0 ]] || fail '此操作需要交互式 SSH 终端。'
  case "$(installation_state)" in
    present) precheck; info 'Snell 已安装，请运行 sn status 查看状态。'; exit 0 ;;
    partial) fail '检测到不完整安装，拒绝覆盖。' ;;
  esac
  command -v curl >/dev/null || fail '缺少 curl。'
  command -v flock >/dev/null || fail '缺少 flock。'
  local server name port family answer tmpdir
  local -a extra_args=()
  printf '\n===== 一键安装 Snell v6 =====\n'
  read -r -p '请输入 VPS 公网 IPv4/IPv6： ' server || fail '必须输入 IP 地址。'
  [[ -n "$server" ]] || fail '必须输入 IP 地址。'
  read -r -p '请输入节点名称 [Snell-v6]： ' name || fail '必须输入节点名称。'
  if [[ -z "$name" ]]; then name=Snell-v6; fi
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,49}$ ]] || fail '节点名称格式错误。'
  read -r -p '请输入 TCP 端口 [默认 17888]： ' port || fail '必须输入端口号。'
  if [[ -z "$port" ]]; then port=17888; fi
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || fail '无效的 TCP 端口。'
  port=$((10#$port))
  ((port >= 1024 && port <= 65535)) || fail '端口必须在 1024-65535 范围内。'
  family=ipv4
  if [[ "$server" == *:* ]]; then family=ipv6; fi
  read -r -p "监听模式 [ipv4/ipv6/dual，默认 $family]： " answer || fail '必须选择监听模式。'
  if [[ -n "$answer" ]]; then family=$answer; fi
  case "$family" in ipv4|ipv6|dual) ;; *) fail '监听模式无效。' ;; esac
  if [[ -e "/root/$name-ios.json" || -L "/root/$name-ios.json" ]]; then
    read -r -p '已有同名 iOS 配置，确认覆盖请输入 YES： ' answer || fail '必须确认后才能继续。'
    [[ "$answer" == YES ]] || { info '已取消，原有客户端配置已保留。'; exit 0; }
    extra_args+=(--replace-client)
  fi
  printf '即将安装 Snell v6：TCP %s、监听模式 %s、节点 %s。\n' "$port" "$family" "$name"
  read -r -p '请输入 INSTALL 确认安装： ' answer || fail '必须确认后才能继续。'
  [[ "$answer" == INSTALL ]] || { info '操作已取消。'; exit 0; }
  exec 9>/run/lock/snell-v6-port.lock
  flock -n 9 || fail '另一项 Snell 管理操作正在进行。'
  [[ "$(installation_state)" == absent ]] || fail 'Snell 安装路径发生变化，已终止操作。'
  tmpdir=$(mktemp -d /tmp/sn-install.XXXXXXXX)
  trap 'rm -rf -- "$tmpdir"' EXIT
  curl --proto '=https' --tlsv1.2 -fL --retry 2 --connect-timeout 15 --max-time 120 \
    https://raw.githubusercontent.com/pansamrt/singboxSnell/main/snell-v6-oneclick.sh \
    -o "$tmpdir/snell-v6-oneclick.sh" || fail '下载失败。'
  bash -n "$tmpdir/snell-v6-oneclick.sh" || fail '下载的脚本语法检查失败。'
  bash "$tmpdir/snell-v6-oneclick.sh" --server "$server" --name "$name" \
    --port "$port" --family "$family" "${extra_args[@]}"
  info 'Snell 安装完成，请更新或导入 iOS 配置。'
)
uninstall_snell() (
  [[ $EUID -eq 0 ]] || fail '请使用 root 权限运行。'
  [[ -t 0 ]] || fail '此操作需要交互式 SSH 终端。'
  case "$(installation_state)" in
    absent) info 'Snell 未安装，sn 管理命令仍可使用。'; exit 0 ;;
    partial) fail '检测到不完整安装，拒绝删除未知文件。' ;;
  esac
  precheck
  [[ "$(systemctl show snell-v6.service -p FragmentPath --value)" == "$UNIT" ]] ||
    fail '当前 systemd 服务文件不符合预期。'
  [[ -z "$(systemctl show snell-v6.service -p DropInPaths --value)" ]] ||
    fail '检测到自定义 systemd 服务附加配置，请先检查。'
  grep -Fxq 'User=snellv6' "$UNIT" && grep -Fxq 'Group=snellv6' "$UNIT" ||
    fail '服务账户或用户组不符合预期。'
  [[ -z "$(find /opt/snell-v6 -mindepth 1 -maxdepth 1 ! -name snell-server -print -quit)" ]] ||
    fail '/opt/snell-v6 下存在未知文件，请先检查。'
  [[ -z "$(find /etc/snell-v6 -mindepth 1 -maxdepth 1 ! -name snell-server.conf ! -name subscription -print -quit)" ]] ||
    fail '/etc/snell-v6 下存在未知文件，请先检查。'
  if [[ -e /etc/snell-v6/subscription || -e /etc/systemd/system/snell-v6-subscription.service ]]; then
    [[ -x /usr/local/bin/sn-sub ]] ||
      fail '检测到订阅服务但缺少 sn-sub 管理器，请检查后再卸载。'
  fi
  printf '\n===== 卸载 Snell v6 =====\n'
  printf '将仅停止并删除 snell-v6.service、Snell 程序和配置。\n'
  printf '保留 sn 管理命令与 /root/*-ios.json 配置备份。\n'
  printf '注意：卸载将中断现有 Snell 客户端连接。\n'
  local answer
  read -r -p '确认卸载 Snell v6？[y/N]： ' answer || fail '必须确认后才能继续。'
  case "$answer" in
    y|Y) ;;
    *) info '已取消，Snell 未被卸载。'; exit 0 ;;
  esac
  exec 9>/run/lock/snell-v6-port.lock
  flock -n 9 || fail '另一项 Snell 管理操作正在进行。'
  precheck
  if [[ -e /etc/snell-v6/subscription || -e /etc/systemd/system/snell-v6-subscription.service ]]; then
    /usr/local/bin/sn-sub disable --yes ||
      fail '无法安全停止 HTTPS 订阅，Snell 未被删除。'
  fi
  systemctl disable --now snell-v6.service || fail '停止 Snell 失败，文件已保留。'
  if systemctl is-active --quiet snell-v6.service; then fail 'Snell 仍在运行，文件已保留。'; fi
  rm -f -- "$UNIT"
  systemctl daemon-reload
  rm -f -- "$BIN" "$CONF"
  rmdir -- /opt/snell-v6 /etc/snell-v6 || fail 'Snell 文件已删除，请检查残余目录。'
  if getent passwd snellv6 >/dev/null 2>&1; then
    if [[ "$(getent passwd snellv6 | cut -d: -f6,7)" == /nonexistent:/usr/sbin/nologin ]]; then
      userdel snellv6 || fail 'Snell 已删除，但清理服务用户失败。'
    else
      info '警告：自定义 snellv6 用户已保留，请在重装前检查。'
    fi
  fi
  if getent group snellv6 >/dev/null 2>&1; then
    groupdel snellv6 || fail 'Snell 已删除，但清理用户组失败。'
  fi
  info '卸载成功：Snell 已删除，sn 命令和 iOS 配置备份已保留。'
  info '可运行 sn install 重新安装；生成的新 PSK 需要同步更新客户端。'
  info '未更改 SSH、Hysteria2、其他代理、防火墙及路由。'
)
subscription_menu() (
  [[ $EUID -eq 0 ]] || fail '请使用 root 权限运行。'
  local dest=/usr/local/bin/sn-sub temp refresh=0
  if [[ "${1:-}" == update ]]; then refresh=1; shift; fi
  [[ -d /usr/local/bin && ! -L /usr/local/bin ]] || fail '/usr/local/bin 目录不安全。'
  if [[ -e "$dest" || -L "$dest" ]]; then
    [[ -f "$dest" && ! -L "$dest" && -x "$dest" &&
       "$(stat -c %u -- "$dest")" == 0 ]] ||
      fail "现有文件 $dest 不安全，拒绝执行。"
    grep -Fxq '# SNELL_V6_SUBSCRIPTION_MANAGER=1' "$dest" ||
      fail "现有文件 $dest 不是本项目订阅管理器。"
  fi
  if (( refresh )) || [[ ! -e "$dest" && ! -L "$dest" ]]; then
    command -v curl >/dev/null 2>&1 || fail '初始化订阅功能需要 curl。'
    temp=$(mktemp /usr/local/bin/.sn-sub.XXXXXXXX) ||
      fail '无法暂存订阅管理器。'
    if ! curl --proto '=https' --tlsv1.2 -fL --retry 2 \
         --connect-timeout 15 --max-time 120 \
         https://raw.githubusercontent.com/pansamrt/singboxSnell/main/snell-v6-subscribe.sh \
         -o "$temp" ||
       ! grep -Fxq '# SNELL_V6_SUBSCRIPTION_MANAGER=1' "$temp" ||
       ! bash -n "$temp"; then
      rm -f -- "$temp"
      fail '无法下载或校验订阅管理器。'
    fi
    chmod 700 "$temp"
    mv -T -- "$temp" "$dest"
    info '已安装或更新 HTTPS 订阅管理器：/usr/local/bin/sn-sub。'
  fi
  if (( refresh )); then
    "$dest" upgrade
    return
  fi
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
    json|config) show_client_json ;;
    port) change_port ;;
    install) install_snell ;;
    uninstall) uninstall_snell ;;
    "")
      [[ -t 0 ]] || fail '管理菜单需要交互式 SSH 终端。'
      while true; do
        printf '\n===== Snell v6 中文管理面板 v1.1.0 =====\n'
        printf '  1) 修改 TCP 端口\n  2) 查看运行状态\n  3) 一键安装 Snell v6\n  4) 卸载 Snell v6\n  5) HTTPS 订阅和二维码\n  6) 查看 sing-box JSON 配置\n  0) 退出\n'
        read -r -p '请选择 [0-6]： ' choice || exit 0
        case "$choice" in
          1) change_port ;;
          2) show_status ;;
          3) install_snell ;;
          4) uninstall_snell ;;
          5) subscription_menu menu ;;
          6) show_client_json ;;
          0) exit 0 ;;
          *) info '选项无效，请重新输入。' ;;
        esac
      done
      ;;
    *) usage; fail '未知命令，请运行 sn --help。' ;;
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
  # Installing the standalone manager is offline; check only its immediate tools.
  check_dependency_commands mktemp grep stat
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
    curl unzip openssl ca-certificates iproute2 python3 \
    util-linux passwd coreutils libc-bin
  # These commands are used by Snell setup, rollback and the sn manager.
  check_dependency_commands curl unzip openssl python3 flock useradd userdel \
    getent sha256sum stat mktemp install systemctl grep sed
else
  info 'Detected existing independent Snell installation; skipping apt and binary/service changes.'
  # Read-only check: never run apt or reinstall existing Snell or other proxies.
  check_dependency_commands python3 curl openssl flock getent stat mktemp \
    install systemctl grep sed
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