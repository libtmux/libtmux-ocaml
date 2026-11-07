"""Owned Linux tmux fixtures. Readiness and teardown use kernel events."""

import ctypes
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import tempfile


class TmuxFixture:
    def __init__(self, binary):
        self.binary = str(Path(binary).resolve(strict=True))
        self.directory = tempfile.TemporaryDirectory(prefix="libtmux-ocaml-")
        self.socket = Path(self.directory.name) / "server"
        self.environment = {
            key: value for key, value in os.environ.items()
            if key not in {"TMUX", "TMUX_PANE"}
        }
        self.server = None
        self.pidfd = None
        self.pane_pidfds = {}
        self.log = tempfile.TemporaryFile()

    def command(self, *arguments, check=True):
        return subprocess.run(
            [self.binary, "-S", str(self.socket), *arguments],
            env=self.environment, capture_output=True, check=check, timeout=1,
        )

    def __enter__(self):
        libc = ctypes.CDLL(None, use_errno=True)
        notification = libc.inotify_init1(os.O_CLOEXEC | os.O_NONBLOCK)
        if notification < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1")
        try:
            watch = libc.inotify_add_watch(
                notification, os.fsencode(self.directory.name), 0x100 | 0x80,
            )
            if watch < 0:
                raise OSError(ctypes.get_errno(), "inotify_add_watch")
            self.server = subprocess.Popen(
                [self.binary, "-D", "-S", str(self.socket), "-f", "/dev/null"],
                env=self.environment, stdin=subprocess.DEVNULL,
                stdout=self.log, stderr=self.log,
            )
            self.pidfd = os.pidfd_open(self.server.pid)
            with selectors.DefaultSelector() as ready:
                ready.register(notification, selectors.EVENT_READ)
                ready.register(self.pidfd, selectors.EVENT_READ)
                while not self.socket.exists():
                    events = ready.select(1)
                    if not events:
                        raise TimeoutError("owned tmux did not create its socket")
                    if any(key.fd == self.pidfd for key, _ in events):
                        raise RuntimeError("owned tmux exited during setup")
                    os.read(notification, 4096)
            if not stat.S_ISSOCK(self.socket.stat().st_mode):
                raise RuntimeError("tmux endpoint is not a socket")
            self.command("new-session", "-d", "-s", "fixture", "exec cat")
            pid = int(self.command("display-message", "-p", "#{pid}").stdout)
            if pid != self.server.pid:
                raise RuntimeError("fixture reached an unowned daemon")
            if not os.path.samefile(f"/proc/{pid}/ns/pid", "/proc/self/ns/pid"):
                raise RuntimeError("fixture requires a shared PID namespace")
            self.track_panes()
            return self
        except BaseException:
            self.close()
            raise
        finally:
            os.close(notification)

    def track_panes(self):
        for value in self.command("list-panes", "-a", "-F", "#{pane_pid}").stdout.splitlines():
            if value and int(value) > 0 and int(value) not in self.pane_pidfds:
                try:
                    self.pane_pidfds[int(value)] = os.pidfd_open(int(value))
                except ProcessLookupError:
                    pass

    def close(self):
        try:
            if self.server is not None and self.server.poll() is None:
                try:
                    self.command("kill-server", check=False)
                    self.server.wait(timeout=1)
                except (subprocess.TimeoutExpired, OSError):
                    self.server.kill()
                    self.server.wait(timeout=1)
                    raise
            for pane_pidfd in self.pane_pidfds.values():
                with selectors.DefaultSelector() as ready:
                    ready.register(pane_pidfd, selectors.EVENT_READ)
                    if not ready.select(1):
                        signal.pidfd_send_signal(pane_pidfd, signal.SIGKILL)
                        raise RuntimeError("owned pane did not exit with its daemon")
        finally:
            for name in ("pidfd",):
                descriptor = getattr(self, name)
                if descriptor is not None:
                    os.close(descriptor)
                    setattr(self, name, None)
            for descriptor in self.pane_pidfds.values():
                os.close(descriptor)
            self.pane_pidfds.clear()
            self.log.close()
            self.directory.cleanup()

    def __exit__(self, *_):
        self.close()
