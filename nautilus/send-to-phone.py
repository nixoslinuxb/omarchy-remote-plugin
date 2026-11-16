"""Send to phone — Nautilus right-click action for Omarchy Remote.

Selected files are copied into the service's outbox; the phone picks them up on
its next poll and saves them. Unlike the phone-to-computer direction this uses
the PC's own filesystem, so there is no size limit.
"""

import os
import shutil
import stat
import subprocess

from gi import require_version

require_version("Nautilus", "4.1")

from gi.repository import GObject, Gio, Nautilus

APP_ID = "yhcramo.remote"


def outbox_dir():
    state = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(state, "omarchy-remote", "outbox")


def _safe_dir(path):
    """True when the outbox is a private directory we really own.

    A shared or attacker-owned state directory would let another local account
    read the queued file, or swap in a symlink so the copy writes somewhere we
    did not intend. Both are refused instead of being silently ignored.
    """
    absolute = os.path.abspath(path)
    # Resolving the whole path catches a symlink planted in any component
    # (state dir, omarchy-remote, or outbox itself).
    if os.path.realpath(absolute) != absolute:
        return False

    # The two directories this action creates must belong to us and be
    # owner-only; that is what keeps the queued bytes private.
    for folder in (os.path.dirname(absolute), absolute):
        try:
            info = os.lstat(folder)
        except OSError:
            return False
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            return False
        if stat.S_IMODE(info.st_mode) & 0o077:
            return False

    # Ancestors only need to be trustworthy as far as "another user cannot
    # replace an entry here": a sticky world-writable directory such as /tmp is
    # acceptable, a plain group-writable one is not.
    current = os.path.dirname(os.path.dirname(absolute))
    while True:
        try:
            info = os.lstat(current)
        except OSError:
            return False
        if stat.S_IMODE(info.st_mode) & 0o022 and not stat.S_IMODE(info.st_mode) & 0o1000:
            return False
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent
    return True


def unique_target(directory, name):
    """Reserve a fresh name atomically and return an open, owner-only fd.

    O_EXCL|O_NOFOLLOW closes the race where a second account creates the target
    (or a symlink at that name) between the existence check and the copy.
    """
    stem, dot, ext = name.rpartition(".")
    counter = 0
    while counter < 1000:
        suffix = f"-{counter}" if counter else ""
        candidate = (stem + suffix + dot + ext) if dot else (name + suffix)
        target = os.path.join(directory, candidate)
        try:
            fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            return target, fd
        except FileExistsError:
            counter += 1
    raise OSError("too many files with the same name")


def notify(title, body):
    """Best-effort desktop toast; the queue itself never depends on it."""
    if not shutil.which("notify-send"):
        return
    try:
        subprocess.run(["notify-send", "-a", APP_ID, title, body],
                       capture_output=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        pass


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
        try:
            os.makedirs(directory, mode=0o700, exist_ok=True)
            # Queued files can contain private documents. Make the directories
            # owner-only, but fail closed: a chmod that cannot be applied means
            # the queue may be readable by another account, so nothing is copied.
            for folder in (os.path.dirname(directory), directory):
                info = os.lstat(folder)
                if info.st_uid != os.getuid() or os.path.islink(folder):
                    raise OSError("outbox is not owned by this user")
                os.chmod(folder, 0o700)
        except OSError:
            notify("Send to phone failed", "The transfer folder is not private.")
            return
        if not _safe_dir(directory):
            notify("Send to phone failed", "The transfer folder is not private.")
            return

        queued = 0
        for path in paths:
            handle = None
            target = None
            try:
                source = os.path.basename(path)
                if not source:
                    continue
                target, fd = unique_target(directory, source)
                handle = os.fdopen(fd, "wb")
                with open(path, "rb") as src:
                    shutil.copyfileobj(src, handle, 65536)
                handle.close()
                handle = None
                os.chmod(target, 0o600)
                queued += 1
            except OSError:
                if handle is not None:
                    try:
                        handle.close()
                    except OSError:
                        pass
                if target is not None:
                    try:
                        os.unlink(target)   # never leave a half-written file
                    except OSError:
                        pass
                continue
        if queued == 0:
            notify("Send to phone failed", "No file could be queued.")
            return
        if queued == 1:
            notify("Queued for phone", os.path.basename(paths[0]))
        else:
            notify("Queued for phone", f"{queued} files")
        if service_running():
            return
        # Nudge the service awake so the phone can pick the file up.
        binary = shutil.which("omarchy-remote")
        if binary:
            Gio.Subprocess.new([binary, "start"], Gio.SubprocessFlags.NONE)
