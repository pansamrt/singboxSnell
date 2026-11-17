# singboxSnell — Surge Snell v6 standalone installer

Snell v6 一键安装地址（点击代码框右上角的复制按钮）：

```text
https://raw.githubusercontent.com/pansamrt/singboxSnell/main/snell-v6-oneclick.sh
```

Standalone **Surge official Snell Server v6.0.0** setup and **sing-box 1.14+ iOS** JSON profile generator. Hosted independently from Smart's sing-box installer and service. GPL-3.0-only wrapper script; the downloaded official Snell executable is proprietary and is not committed to this repository.

Entry point: [`snell-v6-oneclick.sh`](snell-v6-oneclick.sh).

## Retrieve safely

Use HTTPS from this public repository; do not pipe a remote installer straight to a root shell:

```bash
cd /root
curl --proto '=https' --tlsv1.2 -fL \
  https://raw.githubusercontent.com/pansamrt/singboxSnell/main/snell-v6-oneclick.sh \
  -o snell-v6-oneclick.sh
bash -n snell-v6-oneclick.sh
bash snell-v6-oneclick.sh --help
```

## Manage Snell with `sn` — port, status, install and uninstall

On a VPS installed with this version, run as root:

```bash
sn
```

Menu choices: `1` to change the TCP listen port, `2` to show current status and port, `3` to install Snell, `4` to uninstall Snell, or `0` to exit. Direct commands: `sn port`, `sn status`, `sn install`, `sn uninstall`. Enter a new unprivileged TCP port **1024–65535** and type `YES` when prompted. The manager verifies the port is free, edits **only** the Snell `listen` setting, restarts **only** `snell-v6.service`, tests its local TCP listener, and automatically restores the previous config and restarts the old service if the new listener fails. It preserves the existing PSK, user, Snell binary and encryption settings. It updates only private root-owned `/root/*-ios.json` profiles matching the local Snell PSK and old port.

### Install and uninstall from the menu

Run `sn` and choose **3** to install. The manager asks for the VPS public IP, node name (default `Snell-v6`), TCP port (default **17888**), and listener family (`ipv4`, `ipv6`, or `dual`). After typing `INSTALL`, it downloads the current official project installer from this repository over HTTPS, checks Bash syntax, and invokes the existing standalone Snell v6 installer. If Snell is already installed, installation is refused rather than overwriting the current binary, PSK, or service. If a private local client JSON has the same name, replacement requires a separate `YES` confirmation. Permit the selected TCP port in your provider firewall and update/import the generated private iOS client profile.

Choose **4** or run `sn uninstall` to uninstall only this standalone Snell installation. Before any deletion, the manager checks the expected standalone unit, binary and config paths, systemd unit ownership, and whether unexpected files are present. It asks `Confirm uninstall Snell v6? [y/N]:`; only `Y` or `y` proceeds. Entering `N`/`n`, any other input, or pressing Enter cancels the removal. It stops/disables `snell-v6.service` and removes the dedicated executable, server config and service unit, then cleans up the dedicated service user/group when possible. **Uninstallation immediately disconnects Snell clients**, but retains `/usr/local/bin/sn` so `sn install` can reinstall later; it also retains private `/root/*-ios.json` files as backups. Reinstalling generates a **new PSK**, so old client profiles must be replaced or regenerated. The manager does not intentionally edit SSH, Hysteria2, unrelated sing-box configurations, firewalls or routing. If the installation is partial/customized, automatic removal is refused or manual inspection is requested.

**Fresh VPS without a Snell service:** Download the script as shown above, then bootstrap only the menu with:

```bash
bash /root/snell-v6-oneclick.sh --install-sn
sn
```

**Previously installed VPS (Germany/Korea):** download the latest script from the copyable link above and install just the management command **without re-installing the proxy or regenerating client JSON**:

```bash
bash /root/snell-v6-oneclick.sh --install-sn
sn status
sn
```

The `--install-sn` command installs/updates `/usr/local/bin/sn`, even when standalone Snell has not yet been installed. If Snell exists, it checks the expected independent paths. It never asks for your IP, changes your port or PSK, restarts Snell, or downloads upstream packages. An unrelated existing `/usr/local/bin/sn` is not overwritten.

**Network and client caveats:** The script never changes host/provider firewalls or security groups. Before switching, ensure the **new TCP port** is permitted by your VPS provider. A newly edited server port will **not** automatically update profiles already imported on your iPhone; re-import the updated `*-ios.json` via Xftp/SFTP or change the client `server_port` manually. Older QR/remote-subscription URLs, if used, require updating their hosted JSON separately. Local TCP reachability is not proof of Snell authentication or internet reachability.

## v1.1.0 — HTTPS subscription, ECC/ACME certificates and QR (sn option 5)

The Surge **Snell server remains v6.0.0**. v1.1.0 is the version of the install/management features.

After updating the local sn command using the normal --install-sn procedure, choose **5) HTTPS subscription / QR**. The companion sn-sub helper is downloaded from this public repository only on first use. Direct commands: **sn sub**, **sn sub setup**, **sn sub show**, **sn sub rotate**, **sn sub disable**, **sn sub update** (refreshes the local helper from this repository).

**Reuse existing ECC:** setup reads Subject Alternative Names from the local ygkkk certificate at /root/ygkkkca/cert.crt (key: /root/ygkkkca/private.key), optional /root/ygkkkca/fullchain.cer, and existing Certbot certificates in /etc/letsencrypt/live. It shows discoverable domain hints, but cannot discover domains that are not visible in this VPS's certificate/configuration files. You must choose or enter the real domain. DNS resolution is checked; no DNS provider settings are modified. It verifies certificate expiry, hostname coverage and the private key pairing without modifying the original certificate files.

**If no matching certificate:** choose ACME issuance via distribution-packaged Certbot. The script requests a Let's Encrypt **ECC P-256** certificate using standalone HTTP-01, requiring correct public DNS, **inbound TCP 80** and **port 80 unoccupied**. It refuses to stop or alter other webservers/proxies just to free that port. If port 80 is used, supply your own valid certificate or arrange a separate DNS-01/webroot challenge. Certbot's renewal service/timer must be working. The new HTTPS server checks the original cert files for renewal twice daily and refreshes its private copy.

To switch the configured HTTPS domain or certificate after setup, first run **sn sub disable**, then **sn sub setup**; the first-time setup intentionally avoids overwriting a live subscription.

**Subscription URL and import QR:** the helper creates a token-protected, read-only HTTPS server on **TCP 8443 by default**; it does not occupy 443, SSH or Snell's data port 17888. Open the selected HTTPS TCP port in the VPS provider's firewall. The URL follows this form:

~~~text
https://your-domain.example:8443/s/SECRET_TOKEN/config.json
~~~

The HTTPS endpoint returns a complete sing-box remote-profile JSON with the currently configured Snell PSK and TCP port. The QR facility outputs terminal QR (if qrencode is available), a raw subscription URL QR at /root/Snell-v6-subscription-qr.png, and a sing-box import-link QR at /root/Snell-v6-import-qr.png. Both PNGs are intended to remain root-only. Use sing-box Remote Profile URL import or compatible QR scanning, then test actual client connectivity.

**Security and compatibility:** Subscription URLs/QRs contain a bearer token; holders can fetch your Snell PSK. Keep them private, and run **sn sub rotate** to invalidate an exposed token. The helper installs qrencode from apt when missing. An existing ygkkk cert.crt may be only a leaf certificate; iOS TLS may reject it unless the served chain includes the required intermediate certificates. Test HTTPS trust and real remote-profile import. The HTTPS server runs as the dedicated snellv6 service account using group-readable certificate copies, not the original ygkkk private key path.

**Lifecycle:** sn sub disable removes only its HTTPS service, settings and generated QR while retaining the original certificates and the Snell server. sn uninstall first disables the managed HTTPS endpoint and then removes only standalone Snell files. The script does not deliberately alter existing ygkkk sing-box, Hysteria2, SSH, provider firewall, DNS or routing. Reinstalling Snell generates new credentials; reconfigure/refresh clients after reinstalling.

## Read-only plan first

For a new Debian 12/13 or Ubuntu 24.04 VPS with systemd:

```bash
bash /root/snell-v6-oneclick.sh --plan --server YOUR_PUBLIC_IPV4 --name KR-Snell-v6
```

The script installs dependencies only on a **new** installation, checks the upstream official HTTPS download and verifies the server version, verifies TCP socket availability, creates a non-login `snellv6` service user, sets up `snell-v6.service` with a private 0640 config and a random PSK, confirms the local listener, and writes a **root-only 0600** sing-box iOS profile. An existing complete independent installation is detected and reused without changing its service or PSK.

## Explicit installation / reuse

```bash
# New standalone Snell v6 on TCP 17888 (default IPv4 listener)
sudo bash /root/snell-v6-oneclick.sh --server YOUR_PUBLIC_IPV4 --name KR-Snell-v6

# On a VPS that already has the earlier independent Snell v6 layout,
# preserve its binary, service, port and PSK and only generate a client profile:
sudo bash /root/snell-v6-oneclick.sh --server YOUR_PUBLIC_IPV4 --name Germany-Snell-v6
```

Use `--family ipv4|ipv6|dual` and `--port 17888` **only on new installations**. To replace an existing client file with a different server/profile, explicitly pass `--replace-client`. Output is `/root/NAME-ios.json` (where NAME is `--name`). Transfer it privately by SFTP/Xftp to your device and import the JSON in sing-box iOS Profiles. Do not publish generated JSON, PSKs, or screenshots containing them. **Do not use a raw public GitHub URL for the private generated JSON.**

Installed paths are `/opt/snell-v6/snell-server`, `/etc/snell-v6/snell-server.conf`, and `/etc/systemd/system/snell-v6.service`. The original `sing-box.service`, `/etc/s-box/`, Hysteria2, SSH, firewall, DNS, host routing and kernel are not deliberately edited. Existing operator firewall/security-group policy must separately allow the selected **TCP** port. An inactive original `sing-box.service` is *not* changed or restarted by this tool.

**Verification boundary:** A successful local TCP listener probe is **not** proof of Snell authentication or outside connectivity. Confirm external TCP reachability, iOS client compatibility, the official proprietary Snell binary's origin and terms, and a real Snell connection independently. A binary version string and HTTPS download do not constitute cryptographic supply-chain verification; the script prints the downloaded archive SHA256 for operator records but has no pinned vendor checksum. Use a disposable VPS for initial testing.
