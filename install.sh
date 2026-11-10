#!/usr/bin/env bash
# Optional integration: the Nautilus "Send to phone" context-menu item.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
target="${XDG_DATA_HOME:-$HOME/.local/share}/nautilus-python/extensions"

if ! python3 -c 'import gi; gi.require_version("Nautilus", "4.1")' 2>/dev/null; then
    printf 'nautilus-python is not installed; skipping the Send to phone item.\n' >&2
    printf 'Install it with: sudo pacman -S nautilus-python\n' >&2
    exit 0
fi

mkdir -p "$target"
install -m 0644 "$here/nautilus/send-to-phone.py" "$target/send-to-phone.py"
printf 'Installed %s\n' "$target/send-to-phone.py"
printf 'Restart Nautilus to load it: nautilus -q\n'
