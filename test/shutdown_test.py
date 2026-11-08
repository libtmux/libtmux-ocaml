#!/usr/bin/env python3
"""Outer: owned-child TERM grace, escalation and reaping require real processes."""
import json
import os
from pathlib import Path
import pty
import selectors
import signal
import socket
import subprocess
import sys
import time

from support.tmux_fixture import TmuxFixture


def helper():
    """Survive both TERM and pipe EOF, forwarding a real control client if needed."""
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    mode = os.environ["LIBTMUX_SHUTDOWN_MODE"]
    child = None
    if mode == "close":
        child = subprocess.Popen(
            [os.environ["LIBTMUX_SHUTDOWN_BINARY"], *sys.argv[1:]],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr,
        )
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as barrier:
        barrier.connect(os.environ["LIBTMUX_SHUTDOWN_BARRIER"])
        barrier.sendall(json.dumps({"helper": os.getpid(), "client": child.pid if child else None}).encode() + b"\n")
        assert barrier.recv(1) == b"G"
    if mode == "failed":
        os.write(1, b"shutdown fixture\n")
    if mode != "close":
        if os.environ["LIBTMUX_SHUTDOWN_STOPPED"] == "1":
            os.kill(os.getpid(), signal.SIGSTOP)
        while True:
            signal.pause()
    with selectors.DefaultSelector() as ready:
        ready.register(0, selectors.EVENT_READ)
        ready.register(child.stdout, selectors.EVENT_READ)
        while ready.get_map():
            for key, _ in ready.select():
                data = os.read(key.fd, 65536)
                if not data:
                    ready.unregister(key.fileobj)
                    if key.fd == 0:
                        child.stdin.close()
                elif key.fd == 0:
                    child.stdin.write(data)
                    child.stdin.flush()
                else:
                    try:
                        os.write(1, data)
                    except BrokenPipeError:
                        pass
    child.wait()
    while True:
        signal.pause()


def line(stream, timeout=1):
    with selectors.DefaultSelector() as ready:
        ready.register(stream, selectors.EVENT_READ)
        if not ready.select(timeout):
            raise TimeoutError("shutdown peer did not reach the next boundary")
    value = stream.readline()
    if not value:
        raise RuntimeError("shutdown peer exited before the next boundary")
    return value


def run_case(fixture, backend, mode, stopped):
    path = Path(fixture.directory.name) / "shutdown-barrier"
    proxy = Path(fixture.directory.name) / "shutdown-tmux"
    proxy.write_text(f"#!/bin/sh\nexec '{sys.executable}' '{Path(__file__).resolve()}' \"$@\"\n")
    proxy.chmod(0o700)
    peer = Path(__file__).resolve().parents[1] / "_build/default/test/shutdown_peer.exe"
    master, slave = pty.openpty()
    process = None
    children = []
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as barrier:
            barrier.bind(str(path))
            barrier.listen(1)
            barrier.settimeout(1)
            env = fixture.environment | {
                "LIBTMUX_SHUTDOWN_HELPER": "1",
                "LIBTMUX_SHUTDOWN_MODE": mode,
                "LIBTMUX_SHUTDOWN_BINARY": fixture.binary,
                "LIBTMUX_SHUTDOWN_BARRIER": str(path),
                "LIBTMUX_SHUTDOWN_STOPPED": str(int(stopped)),
            }
            process = subprocess.Popen(
                [str(peer), str(proxy), str(fixture.socket), backend, mode, os.ttyname(slave)],
                env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                bufsize=0,
            )
            connection, _ = barrier.accept()
            with connection:
                with connection.makefile("rb") as message:
                    pids = json.loads(line(message))
                children = [(pid, os.pidfd_open(pid)) for pid in pids.values() if pid]
                connection.sendall(b"G")
            if mode == "close":
                assert line(process.stdout) == b"READY\n"
                if stopped:
                    signal.pidfd_send_signal(children[0][1], signal.SIGSTOP)
            if mode != "failed":
                process.stdin.write(b"GO\n")
                process.stdin.flush()
            started = time.monotonic()
            if backend == "eio" and mode == "close":
                assert line(process.stdout, 0.75) == b"YIELDED\n"
            assert line(process.stdout, 0.75) == b"DONE\n"
            elapsed = time.monotonic() - started
            for pid, pidfd in children:
                with selectors.DefaultSelector() as exited:
                    exited.register(pidfd, selectors.EVENT_READ)
                    assert exited.select(0.5), "owned child survived library cleanup"
            assert not Path(f"/proc/{pids['helper']}").exists(), "owned helper was not reaped"
            assert fixture.server.poll() is None, "library cleanup killed the tmux daemon"
            assert fixture.command("has-session", "-t", "=fixture").returncode == 0
            process.stdin.write(b"EXIT\n")
            process.stdin.flush()
            stdout, stderr = process.communicate(timeout=1)
            assert process.returncode == 0 and stdout == b"" and stderr == b"", (process.returncode, stdout, stderr)
            print(f"PASS {backend} {mode} {'stopped' if stopped else 'TERM/EOF resistant'}: {elapsed:.3f}s", flush=True)
    finally:
        # Recovery is scoped to the helper/client pidfds created by this case.
        for _, pidfd in children:
            try:
                signal.pidfd_send_signal(pidfd, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if process is not None:
            if process.poll() is None:
                try:
                    process.communicate(b"EXIT\n", timeout=0.5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate(timeout=1)
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None:
                    stream.close()
        for _, pidfd in children:
            os.close(pidfd)
        os.close(master)
        os.close(slave)
        path.unlink(missing_ok=True)


if os.environ.get("LIBTMUX_SHUTDOWN_HELPER") == "1":
    helper()
else:
    failures = []
    for binary in sys.argv[1:]:
        with TmuxFixture(binary) as fixture:
            for backend in ("unix", "eio"):
                modes = ("close", "failed", "terminal") + (("cancel-setup",) if backend == "eio" else ())
                for mode in modes:
                    for stopped in (False, True):
                        try:
                            run_case(fixture, backend, mode, stopped)
                        except (AssertionError, TimeoutError, RuntimeError) as error:
                            failures.append((backend, mode, stopped, str(error)))
                            print(f"FAIL {backend} {mode} stopped={stopped}: {error}", flush=True)
    if failures:
        raise SystemExit(f"{len(failures)} shutdown cases failed")
