# v1.1 proposal — Optional sing-box iOS QR remote-profile import

**v1.0 remains on `main`.** This feature is opt-in; it does not change normal Snell installation or local JSON import.

## Why a remote URL is required

sing-box for Apple accepts the normal QR code as a **remote-profile import link**:

```text
sing-box://import-remote-profile?url=urlEncodedURL#urlEncodedName
```

See the [official sing-box profile documentation](https://sing-box.sagernet.org/clients/general/) and [iOS client's QR handler](https://github.com/SagerNet/sing-box-for-apple/blob/dev/ApplicationLibrary/Views/Profile/NewProfileMenuView.swift). Plain Snell URLs or raw JSON in a standard QR code are not valid one-step imports through this mechanism. This is distinct from the client's multi-frame QRS transfer system.

This optional tool **does not** start a public HTTP server, expose another port, upload secrets, or deploy a subscription host. Before QR import can work, the owner must already securely host the generated private sing-box JSON over HTTPS, ideally behind a long unguessable per-device bearer token with revocation and HTTPS TLS validation. Treat the QR itself as secret if it contains a bearer URL.

## Usage after a normal v1.0 install

1. Install/reuse Snell and generate `/root/NAME-ios.json` the standard way.
2. Host that JSON at a private HTTPS URL accessible by the iPhone. Do not put the JSON or PSK in a public GitHub repository or anonymous unprotected URL.
3. On the VPS, create a root-only single-line file containing the private URL:

```bash
umask 077
read -r -s -p 'Private HTTPS JSON URL: ' PROFILE_URL; echo
printf '%s\n' "$PROFILE_URL" >/root/snell-private-profile-url.txt
unset PROFILE_URL
chmod 600 /root/snell-private-profile-url.txt
```

4. Use the **v1.1 candidate** installer locally (or reuse existing Snell). Example:

```bash
bash /root/snell-v6-oneclick.sh \
  --server YOUR_PUBLIC_IPV4 \
  --name KR-Snell-v6 \
  --qr-url-file /root/snell-private-profile-url.txt
```

It creates `/root/KR-Snell-v6-ios-qr.png` (mode 0600). Run with `--qr-terminal` to display a terminal QR, and `--replace-qr` to explicitly regenerate a changed QR.

5. Open sing-box for iOS → Profiles → `+` → Scan QR Code. The iPhone must be able to **download and validate** the hosted JSON. Actual handshake requires external TCP access to your Snell port.

**Limitations:** A PNG file is not an independently usable QR subscription; the URL behind it must work. A protected file requiring interactive website login/cookies may fail when fetched by the app. This feature has not been validated end-to-end on iPhone and is not approved for v1.1 release yet. Continue to use SFTP → Import from File until the remote-profile workflow is tested.

## Non-goals / unchanged

No modification to existing sing-box, Hysteria2, firewalls, SSH, routes, DNS, or PSK. No implicit QR publishing, third-party upload, or QR that embeds the PSK directly. Server version remains Surge Snell v6.0.0.
