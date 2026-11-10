"""Send to phone — Nautilus right-click action for Omarchy Remote.

Selected files are copied into the service's outbox; the phone picks them up on
its next poll and saves them. Unlike the phone-to-computer direction this uses
the PC's own filesystem, so there is no size limit.
"""

import os
import shutil

from gi import require_version

require_version("Nautilus", "4.1")

from gi.repository import GObject, Gio, Nautilus

APP_ID = "yhcramo.remote"


def outbox_dir():
    state = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(state, "omarchy-remote", "outbox")


def unique_target(directory, name):
    target = os.path.join(directory, name)
    stem, dot, ext = name.rpartition(".")
    counter = 1
    while os.path.exists(target):
        suffix = f"-{counter}"
        target = os.path.join(
            directory,
            (stem + suffix + dot + ext) if dot else (name + suffix),
        )
        counter += 1
    return target


def service_running():
    runtime = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    pid_path = os.path.join(runtime, "omarchy-remote", "pid")
    try:
        pid = int(open(pid_path, encoding="utf-8").read().strip())
        os.kill(pid, 0)
        with open(f"/proc/{pid}/cmdline", "rb") as handle:
            cmdline = handle.read().decode("utf-8", "replace")
        return "omarchy-remote" in cmdline and "_serve" in cmdline
    except (OSError, ValueError):
        return False


class SendToPhone(GObject.GObject, Nautilus.MenuProvider):
    def _paths(self, files):
        paths = []
        seen = set()
        for item in files:
            if item.is_directory():
                continue
            location = item.get_location()
            path = location.get_path() if location else None
            if path and path not in seen:
                seen.add(path)
                paths.append(path)
        return paths

    def get_file_items(self, *args):
        files = args[0] if len(args) == 1 else args[1]
        paths = self._paths(files)
        if not paths:
            return []

        label = "Send to phone" if len(paths) == 1 else f"Send {len(paths)} files to phone"
        item = Nautilus.MenuItem(
            name="OmarchyRemote::send-to-phone",
            label=label,
            icon="send-to",
        )
        item.connect("activate", self._on_activate, paths)
        return [item]

    def _on_activate(self, _menu, paths):
        directory = outbox_dir()
        os.makedirs(directory, mode=0o700, exist_ok=True)
        # Queued files can contain private documents; keep them owner-only even
        # if the caller's umask or the source file mode is permissive.
        for folder in (os.path.dirname(directory), directory):
            try:
                os.chmod(folder, 0o700)
            except OSError:
                pass
        for path in paths:
            try:
                target = unique_target(directory, os.path.basename(path))
                shutil.copy2(path, target)
                os.chmod(target, 0o600)
            except OSError:
                continue
        if service_running():
            return
        # Nudge the service awake so the phone can pick the file up.
        binary = shutil.which("omarchy-remote")
        if binary:
            Gio.Subprocess.new([binary, "start"], Gio.SubprocessFlags.NONE)
