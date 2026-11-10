# Phone Remote for Omarchy

Turn your Android phone into a remote for the computer running
[Omarchy](https://omarchy.org): media, trackpad, keyboard, clipboard, files, and
your phone's messaging notifications — all over your own Wi-Fi, with no cloud
account.

The bar widget starts a small HTTPS service on this computer and shows a pairing
QR code. The companion Android app scans it once and keeps the pairing until the
computer restarts.

- Companion app: [nixoslinuxb/omarchy-remote-android](https://github.com/nixoslinuxb/omarchy-remote-android)
- Tested on Omarchy 4.x / Quickshell on Wayland
- Everything is open source (MIT); no telemetry, no external servers

## Features

- **Media**: play/pause, next/previous, seek, volume, mute, album art, and a
  player/tab picker. The bar widget and the phone share one service.
- **Mirror**: mirrors the phone into a window and drives it with this computer's
  keyboard and mouse (scrcpy over USB or Wi-Fi adb).
- **Notification relay**: the phone's messaging notifications appear as cards at
  the top right, with **Reply** and **Mark read** only when that notification
  really exposes the matching action. Calendar reminders and other
  non-conversation cards show no buttons. The bell icon silences the relay.
- **Clipboard, both ways**: paste into this computer's Wayland clipboard, and
  publish this computer's clipboard for the phone.
- **Files**: phone uploads land in `~/Documents/omarchy-remote/`; the optional
  Nautilus item **Send to phone** queues files for the phone. No size limit in
  either direction.
- **Pairing**: the token lives in the URL fragment of the QR code and never
  crosses the network. The phone pins the service certificate by SHA-256.

## Requirements

- Omarchy on Wayland (`/usr/share/omarchy` and `WAYLAND_DISPLAY` are required;
  the service refuses to start otherwise)
- `python3` with `python-gobject` (already present on Omarchy)
- `openssl`, `qrencode`, `wl-clipboard`, PipeWire (`wpctl`)
- Optional: `scrcpy` + `adb` for **Mirror**
- Optional: `nautilus-python` for **Send to phone**
- The Android app on a phone running Android 16 (API 36)
- Both devices on the same network

## Install

```bash
omarchy plugin add https://github.com/nixoslinuxb/omarchy-remote-plugin.git --yes
omarchy plugin enable yhcramo.remote --section right
```

1. Click the new bar icon, then **Start** (play icon). A QR code appears.
2. Install the companion app and scan that QR code.
3. Open port **8765/tcp** for your LAN, or the phone will pair but every request
   will fail. With `ufw`, replacing the subnet with yours:

   ```bash
   sudo ufw allow from 192.168.1.0/24 to any port 8765 proto tcp
   ```

The plugin directory contains the service itself, so nothing is copied into
`~/.local/bin`.

### Optional: Send to phone (Nautilus)

```bash
./install.sh
nautilus -q
```

`install.sh` copies `nautilus/send-to-phone.py` into
`~/.local/share/nautilus-python/extensions/`. Right-click one or more files in
Nautilus and choose **Send to phone**; the phone downloads them on its next poll.

## Stop, restart, and removal

- **Stop / start**: the two icon buttons in the popup. Stopping also stops the
  pointer daemon and clears queued cards.
- **Removal**:

  ```bash
  omarchy plugin remove yhcramo.remote
  rm -rf ~/.local/state/omarchy-remote        # outbox and mirror address
  rm -f ~/.local/share/nautilus-python/extensions/send-to-phone.py
  sudo ufw delete allow from 192.168.1.0/24 to any port 8765 proto tcp
  ```

  The plugin never edits your shell, Hyprland, or Omarchy configuration. The
  only files it creates are the runtime directory under `$XDG_RUNTIME_DIR` (tmpfs,
  removed at logout), the outbox under `$XDG_STATE_HOME`, and uploaded files in
  `~/Documents/omarchy-remote/`.

## Security and permissions

- The service binds **only the LAN address**, not every interface, and serves
  HTTPS with a fresh self-signed certificate and a fresh random token on every
  start. Restarting the computer therefore requires scanning a new QR code.
- All API calls need the token in an `X-Token` header. The token is never accepted
  from the query string, so it cannot leak into logs.
- The phone pins the certificate fingerprint from the QR code; a wrong pin fails
  during the TLS handshake.
- **Notification access** is granted to the companion app on the phone, not to
  this plugin. Only message-like notifications (or the SMS app's own cards) are
  forwarded; OTPs, bank alerts, and other app notifications are not.
- **Reply / Mark read** use the notification's own remote-input and
  mark-as-read actions. The service refuses an action the notification did not
  advertise.
- The pointer daemon writes to `/dev/uinput`, which is what makes real clicks and
  drags possible. It is stopped with the service.
- The terminal page runs a command you type on the phone in a new terminal
  window on this computer. Anyone holding a paired phone can run commands as
  your user — pair only your own devices.

Plugins run unsandboxed in the Omarchy shell. Read the code before enabling any
third-party plugin, including this one.

## How it works

| Piece | Role |
|---|---|
| `BarWidget.qml` | Bar icon, popup, QR, start/stop, clipboard/mute/mirror actions |
| `NotifyOverlay.qml` | Message cards and the inline reply box |
| `omarchy-remote` | HTTPS service, MPRIS/PipeWire bridge, uploads, outbox |
| `omarchy-remote-pointer` | `/dev/uinput` buttons and Hyprland cursor warping |
| `omarchy-mirror` | scrcpy wrapper (USB handshake, then wireless) |
| `nautilus/send-to-phone.py` | Nautilus context-menu item that fills the outbox |

Runtime state lives in `$XDG_RUNTIME_DIR/omarchy-remote/` (`state.json`,
`token`, `cert.pem`, `service.log`, notification files). The log rotates at
2 MB.

## License

MIT — see [LICENSE](LICENSE).
