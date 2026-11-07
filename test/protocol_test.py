"""Outer: exercise the native codecs on isolated release daemons."""

import json
import os
from pathlib import Path
import selectors
import subprocess
import sys

from support.tmux_fixture import TmuxFixture


peer = Path(__file__).resolve().parents[1] / "_build/default/test/codec_peer.exe"


def codec(*arguments, input=None):
    return subprocess.check_output([str(peer), *arguments], input=input)


class Control:
    def __init__(self, fixture, chunk):
        self.process = subprocess.Popen(
            [fixture.binary, "-u", "-S", str(fixture.socket), "-C", "attach-session", "-f", "no-output", "-t", "fixture"],
            env=fixture.environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.parser = subprocess.Popen([str(peer), "frames", str(chunk)], stdin=self.process.stdout,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.process.stdout.close()
        self.ready = selectors.DefaultSelector()
        self.ready.register(self.parser.stdout, selectors.EVENT_READ)
        self.buffer = b""
        self.saw_command_error = False
        assert self.frame()["ok"]

    def event(self):
        while b"\n" not in self.buffer:
            if not self.ready.select(1):
                raise TimeoutError("native control parser did not deliver an event")
            data = os.read(self.parser.stdout.fileno(), 65536)
            if not data:
                raise RuntimeError(self.parser.stderr.read().decode())
            self.buffer += data
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def frame(self):
        while True:
            event = self.event()
            if event["kind"] == "frame":
                self.saw_command_error |= not event["ok"]
                event["body"] = bytes.fromhex(event["hex"])
                return event
            assert event["kind"] == "notification", event

    def send(self, name, *arguments):
        self.process.stdin.write(codec("render", name, *arguments) + b"\n")
        self.process.stdin.flush()

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=1)
        self.parser.wait(timeout=1)
        assert self.process.returncode == int(self.saw_command_error) and self.parser.returncode == 0, (
            self.process.returncode, self.parser.returncode,
            self.process.stderr.read(), self.parser.stderr.read(),
        )
        self.process.stderr.close()
        self.parser.stdout.close()
        self.parser.stderr.close()
        self.ready.close()


for binary in sys.argv[1:]:
    with TmuxFixture(binary) as fixture:
        control = Control(fixture, 1)
        try:
            control.send("display-message", "-p", "libtmux\rprobe")
            dialect = codec("detect-print", input=control.frame()["body"])
            opaque = b'quote\'"\\|=\n%end 1 1 1\t\r\xff{}$value${x}$_x;'
            fixture.command("set-option", "-g", "@codec", codec("argv", opaque))
            template = codec("format", "@codec")
            expected = [[opaque.hex()]]
            control.send("display-message", "-p", template)
            assert json.loads(codec("metadata", "1", dialect, input=control.frame()["body"])) == expected
            all_bytes = bytes(range(1, 256))
            control.send("set-option", "-g", "@codec", all_bytes)
            assert control.frame()["ok"]
            control.send("display-message", "-p", template)
            assert json.loads(codec("metadata", "1", dialect, input=control.frame()["body"])) == [[all_bytes.hex()]]
            control.send("set-option", "-g", "@codec", opaque)
            changed = control.frame()
            assert changed["ok"], changed
            control.send("display-message", "-p", template)
            assert json.loads(codec("metadata", "1", dialect, input=control.frame()["body"])) == expected
            first = codec("render", "display-message", "-p", "FIRST")
            fail = codec("render", "select-pane", "-t", "%4294967295")
            skipped = codec("render", "display-message", "-p", "SKIPPED")
            control.process.stdin.write(b" ; ".join([first, fail, skipped]) + b"\n")
            control.process.stdin.flush()
            assert control.frame()["body"] == b"FIRST\n"
            assert not control.frame()["ok"]
            control.send("display-message", "-p", "AFTER")
            assert control.frame()["body"] == b"AFTER\n"
            control.send("wait-for", "libtmux-ocaml-ready")
            assert control.frame()["ok"]
            control.send("display-message", "-p", "COMPLETED")
            fixture.command("wait-for", "-S", "libtmux-ocaml-ready")
            assert control.frame()["body"] == b"COMPLETED\n"
            daemon_pid = fixture.command("display-message", "-p", "#{pid}").stdout
        finally:
            control.close()
        assert fixture.command("display-message", "-p", "#{pid}").stdout == daemon_pid
    print(f"PASS {Path(binary).parent.name}: native byte codecs, one-byte reads, groups, wait completion, client close")
