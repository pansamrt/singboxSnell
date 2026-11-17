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
QR_PASSWALL=/root/Snell-v6-passwall-qr.png

info() { printf '[sn-sub] %s\n' "$*"; }
fail() { printf '[sn-sub] 错误： %s\n' "$*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || fail '请使用 root 权限运行（sudo sn sub）。'; }
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
    raise SystemExit('无效域名，请输入 ASCII 域名（国际化域名需使用 Punycode）。')
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
    fail '请先安装独立 Snell v6 服务，再配置订阅。'
  grep -Fxq 'ExecStart=/opt/snell-v6/snell-server -c /etc/snell-v6/snell-server.conf' "$SNELL_UNIT" ||
    fail 'Snell 服务文件不符合预期，拒绝修改。'
  systemctl is-active --quiet snell-v6.service || fail 'Snell 服务未运行。'
  getent group snellv6 >/dev/null || fail '缺少专用 snellv6 用户组。'
}
suggest_domains() {
  local crt
  printf '\n从本机证书 SAN 检测到的域名（仅供参考）：\n'
  for crt in /root/ygkkkca/fullchain.cer /root/ygkkkca/cert.crt \
      /etc/letsencrypt/live/*/fullchain.pem; do
    [[ -f "$crt" ]] || continue
    openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null || true
  done | grep -oE 'DNS:[A-Za-z0-9*._-]+' | sed 's/^DNS://' | grep -v '^\*' | sort -u || true
  printf '仅能发现本地配置或证书中记录的域名，不能扫描全部域名。\n'
}
show_dns() {
  python3 - "$1" "$2" <<'PY'
import ipaddress,socket,sys
domain,server=sys.argv[1:]
try:
    found=sorted({row[4][0] for row in socket.getaddrinfo(domain,None)})
except OSError as exc:
    raise SystemExit('域名 DNS 解析失败： '+str(exc))
print('域名解析地址：'+domain+': '+', '.join(found))
try:
    ipaddress.ip_address(server)
except ValueError:
    pass
else:
    if server not in found:
        print('警告：域名 DNS 解析结果与填写的 Snell 服务器 IP 不一致。')
        print('如果使用 Cloudflare 代理，请确认其支持所选 HTTPS 端口；')
        print('Snell TCP 服务通常需要直连 IP，而不是被代理的域名。')
PY
}
ensure_known_unit() {
  local file=$1
  if [[ -e "$file" || -L "$file" ]]; then
    [[ -f "$file" && ! -L "$file" ]] || fail "Unsafe unit file: $file"
    grep -Fxq '# Managed by pansamrt/singboxSnell subscription' "$file" ||
      fail "检测到非本项目的 systemd 服务文件 $file，拒绝覆盖。"
  fi
}
copy_certificates() {
  local crt=$1 key=$2 domain=$3 dest temp
  cert_ok "$crt" "$key" "$domain" || fail '证书不可用：可能已过期、即将过期、域名不匹配或密钥不匹配。'
  [[ -d "$ROOT" && ! -L "$ROOT" ]] || fail '订阅目录不存在。'
  for dest in "$CERT" "$KEY"; do
    [[ ! -L "$dest" ]] || fail '拒绝使用符号链接形式的订阅证书。'
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
  info 'TLS 证书与密钥已从现有来源同步（原文件未修改）。'
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
print(url.replace("/config.json", "/passwall.txt"))
PY
}
show_links() {
  require_root
  [[ -f "$SETTINGS" && ! -L "$SETTINGS" ]] || fail 'Not configured; choose Setup first.'
  local url deep passwall
  url=$(links | sed -n '1p')
  deep=$(links | sed -n '2p')
  passwall=$(links | sed -n '3p')
  info "iOS sing-box HTTPS 配置订阅（请保密）： $url"
  info "sing-box 图形客户端导入链接（请保密）： $deep"
  info "iStoreOS PassWall 专用节点订阅（请保密）： $passwall"
  info "HTTPS 服务状态： $(systemctl is-active snell-v6-subscription.service 2>/dev/null || true)"
  if ! command -v qrencode >/dev/null 2>&1; then
    info '正在安装 qrencode 以生成二维码（可选）……'
    apt-get install -y --no-install-recommends qrencode >/dev/null 2>&1 ||
      info '警告：qrencode 不可用，请通过 apt 安装 qrencode。'
  fi
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$url" || true
    qrencode -o "$QR" -s 6 -m 2 "$url"
    qrencode -o "$QR_IMPORT" -s 6 -m 2 "$deep"
    qrencode -o "$QR_PASSWALL" -s 6 -m 2 "$passwall"
    chmod 600 "$QR" "$QR_IMPORT" "$QR_PASSWALL"
    info "HTTPS 订阅二维码： $QR"
    info "sing-box 导入二维码： $QR_IMPORT"
    info "PassWall 专用订阅二维码： $QR_PASSWALL"
    info '二维码含有私密访问令牌，请勿公开分享。'
  fi
}
rotate() {
  require_root
  [[ -t 0 ]] || fail '此操作需要交互式终端。'
  [[ -f "$SETTINGS" ]] || fail '尚未配置订阅。'
  local answer
  read -r -p '确认更换订阅令牌？旧订阅地址将立即失效 [y/N]： ' answer ||
    fail '需要确认后才能继续。'
  [[ "$answer" == y || "$answer" == Y ]] || { info '操作已取消。'; return 0; }
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
  info '没有找到适用于该域名的可信证书。'
  info 'ACME HTTP-01 需要公网 DNS 指向本 VPS，并允许外部访问 TCP 80。'
  python3 - <<'PY'
import errno,socket
for family,host in ((socket.AF_INET,"0.0.0.0"), (socket.AF_INET6,"::")):
    try:
        with socket.socket(family,socket.SOCK_STREAM) as sock:
            if family==socket.AF_INET6:sock.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
            sock.bind((host,80))
    except OSError as exc:
        if family==socket.AF_INET6 and exc.errno in (errno.EAFNOSUPPORT,errno.EPROTONOSUPPORT):
            continue
        raise SystemExit('TCP 80 无法用于 ACME 验证： '+str(exc))
PY
  read -r -p '使用 Certbot ACME 申请 Let’s Encrypt ECC 证书？[y/N]： ' answer ||
    fail '需要确认后才能继续。'
  [[ "$answer" == y || "$answer" == Y ]] || fail '证书申请已取消。'
  if ! command -v certbot >/dev/null 2>&1; then
    info '正在通过 apt 安装 Certbot（不会更改 SSH 或现有代理配置）。'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends certbot
  fi
  read -r -p 'ACME 注册邮箱（直接回车表示不填写）： ' mail || fail '必须完成邮箱输入步骤。'
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
  [[ -t 0 ]] || fail '此操作需要交互式 SSH 终端。'
  require_snell
  local domain server name port family answer token tmpdir candidate settings_tmp
  if [[ -f "$SETTINGS" ]]; then
    info 'HTTPS 订阅已配置，请使用 sn sub show 查看或 sn sub rotate 更换令牌。'
    info '如需更换域名或证书，请先运行 sn sub disable，再运行 sn sub setup。'
    return 0
  fi
  suggest_domains
  read -r -p '请输入 HTTPS 订阅域名（不是 IP）： ' domain || fail '必须输入域名。'
  validate_domain "$domain"
  read -r -p '请输入 Snell 服务器公网 IPv4/IPv6（客户端连接地址）： ' server || fail '必须输入 Snell 服务器地址。'
  python3 - "$server" <<'PY'
import ipaddress,sys
try:ipaddress.ip_address(sys.argv[1])
except ValueError:raise SystemExit('请输入公网 IP 地址，不能填写 URL。')
PY
  show_dns "$domain" "$server"
  read -r -p '节点名称 [默认 Snell-v6]： ' name || fail '必须填写节点名称。'
  if [[ -z "$name" ]]; then name=Snell-v6; fi
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,49}$ ]] || fail '节点名称格式错误。'
  read -r -p 'HTTPS 订阅 TCP 端口 [默认 8443]： ' port || fail '必须输入端口。'
  if [[ -z "$port" ]]; then port=8443; fi
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || fail '端口号无效。'
  port=$((10#$port))
  (( port >= 1024 && port <= 65535 )) || fail '请使用 1024-65535 范围内的 HTTPS 端口。'
  family=ipv4
  if [[ "$server" == *:* ]]; then family=ipv6; fi
  read -r -p "HTTPS 监听模式 [ipv4/ipv6，默认 $family]： " answer || fail '必须选择监听模式。'
  if [[ -n "$answer" ]]; then family=$answer; fi
  case "$family" in ipv4|ipv6) ;; *) fail '请选择 ipv4 或 ipv6。' ;; esac
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
print('检查通过：HTTPS 监听端口未被占用。')
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
    info "正在复用已有域名证书（只读）： $SOURCE_CERT"
  fi
  cert_ok "$SOURCE_CERT" "$SOURCE_KEY" "$domain" ||
    fail '所选证书无法用于此域名。'
  read -r -p '确认启用令牌保护的 HTTPS 订阅？[y/N]： ' answer ||
    fail '需要确认后才能继续。'
  [[ "$answer" == y || "$answer" == Y ]] || { info '操作已取消。'; return 0; }
  exec 9>/run/lock/snell-v6-subscription.lock
  flock -x 9
  for candidate in "$UNIT" "$SYNC_UNIT" "$TIMER"; do ensure_known_unit "$candidate"; done
  if [[ -e "$ROOT" || -L "$ROOT" ]]; then
    [[ -d "$ROOT" && ! -L "$ROOT" && "$(stat -c %u "$ROOT")" == 0 ]] ||
      fail '订阅目录不符合预期。'
  else
    install -d -o root -g snellv6 -m 750 "$ROOT"
  fi
  install -d -o root -g root -m 755 /usr/local/lib/snell-v6
  tmpdir=$(mktemp -d /tmp/snell-sub-server.XXXXXXXX)
  trap 'rm -rf -- "$tmpdir"' EXIT
  curl --proto '=https' --tlsv1.2 -fL --retry 2 \
    --connect-timeout 15 --max-time 120 \
    https://raw.githubusercontent.com/pansamrt/singboxSnell/main/snell-v6-subscription-server.py \
    -o "$tmpdir/server.py" || fail '下载订阅服务程序失败。'
  python3 - "$tmpdir/server.py" <<'PY'
import ast,sys
ast.parse(open(sys.argv[1],encoding="utf-8").read())
PY
  install -o root -g root -m 755 "$tmpdir/server.py" "$SRC"
  copy_certificates "$SOURCE_CERT" "$SOURCE_KEY" "$domain"
  token=$(openssl rand -hex 32)
  settings_tmp="$ROOT/.settings.new"
  [[ ! -L "$SETTINGS" && ! -L "$settings_tmp" ]] || fail '订阅配置路径不安全。'
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
    fail '订阅服务启动失败，请检查 journalctl -u snell-v6-subscription.service。'
  systemctl enable --now snell-v6-subscription-cert-sync.timer
  systemctl is-active --quiet snell-v6-subscription.service ||
    fail '订阅服务未运行。'
  info "HTTPS 订阅已启用：$domain:$port。"
  info '未修改现有 Snell 服务、原始证书或其他代理。'
  show_links
}
disable() {
  require_root
  local answer
  if [[ "$1" != --yes ]]; then
    [[ -t 0 ]] || fail '此操作需要交互式 SSH 终端。'
    read -r -p '确认关闭 HTTPS 订阅（保留 Snell 服务）？[y/N]： ' answer ||
      fail '需要确认后才能继续。'
    [[ "$answer" == Y || "$answer" == y ]] || { info '操作已取消。'; return 0; }
  fi
  local file
  for file in "$UNIT" "$SYNC_UNIT" "$TIMER"; do ensure_known_unit "$file"; done
  if systemctl is-active --quiet snell-v6-subscription.service; then
    [[ "$(systemctl show snell-v6-subscription.service -p FragmentPath --value)" == "$UNIT" ]] ||
      fail '订阅服务文件不符合预期，为安全起见拒绝停止。'
  fi
  systemctl disable --now snell-v6-subscription-cert-sync.timer 2>/dev/null || true
  systemctl disable --now snell-v6-subscription.service 2>/dev/null || true
  for file in "$UNIT" "$SYNC_UNIT" "$TIMER"; do
    if [[ -f "$file" ]]; then rm -f -- "$file"; fi
  done
  systemctl daemon-reload
  [[ ! -L "$ROOT" ]] || fail '订阅目录是符号链接，请人工检查。'
  if [[ -d "$ROOT" ]]; then
    [[ -z "$(find "$ROOT" -mindepth 1 -maxdepth 1 \
       ! -name settings.json ! -name tls-fullchain.pem ! -name tls-key.pem -print -quit)" ]] ||
       fail '订阅目录中存在未知文件，请人工检查。'
    rm -f -- "$SETTINGS" "$CERT" "$KEY"
    rmdir -- "$ROOT"
  fi
  rm -f -- "$QR" "$QR_IMPORT" "$QR_PASSWALL"
  info 'HTTPS 订阅已关闭，Snell 服务及原有 ACME 证书已保留。'
}
menu() {
  [[ -t 0 ]] || fail '此操作需要交互式 SSH 终端。'
  while true; do
    printf '\n===== Snell HTTPS 订阅与二维码管理 =====\n'
    printf '  1) 配置 HTTPS 订阅\n'
    printf '  2) 查看订阅地址和二维码\n'
    printf '  3) 更换订阅访问令牌\n'
    printf '  4) 关闭 HTTPS 订阅（保留 Snell）\n'
    printf '  0) 返回上一级\n'
    local answer
    read -r -p '请选择 [0-4]： ' answer || return 0
    case "$answer" in
      1) setup ;;
      2) show_links ;;
      3) rotate ;;
      4) disable "" ;;
      0) return 0 ;;
      *) info '选项无效，请重新输入。' ;;
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
  *) printf '用法：sn sub [setup|show|rotate|disable]\n'; exit 1 ;;
esac
