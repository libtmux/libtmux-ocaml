"""Outer: byte-stream continuity and bounded subscribers against exact tmux releases."""
import os
from pathlib import Path
import selectors
import subprocess
import sys
from support.tmux_fixture import TmuxFixture

peer = Path(__file__).resolve().parents[1] / "_build/default/test/streaming_peer.exe"
for binary in sys.argv[1:]:
    for backend in ["unix", "eio"]:
        with TmuxFixture(binary) as fixture:
            root = Path(fixture.directory.name)
            fifo = root / "control"
            os.mkfifo(fifo)
            control = os.open(fifo, os.O_RDWR | os.O_CLOEXEC)
            program = root / "output.py"
            program.write_text(
                "import os, subprocess, tty\n"
                "tty.setraw(0)\n"
                f"control = os.open({str(fifo)!r}, os.O_RDONLY)\n"
                f"subprocess.run({[fixture.binary, '-S', str(fixture.socket), 'wait-for', '-S', 'output-ready']!r}, check=True)\n"
                "while True:\n"
                "    key = os.read(control, 1)\n"
                "    if key == b'A': os.write(1, bytes(range(256)) + b'DONE')\n"
                "    elif key == b'B': os.write(1, b'recovered')\n"
            )
            fixture.command("respawn-pane", "-k", "-t", "%0", "/usr/bin/python3", str(program))
            fixture.track_panes()
            fixture.command("wait-for", "output-ready")
            process = subprocess.Popen([str(peer), fixture.binary, str(fixture.socket), backend],
                                       env=fixture.environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, bufsize=0)
            try:
                with selectors.DefaultSelector() as ready:
                    ready.register(process.stdout, selectors.EVENT_READ)
                    for expected in [b"READY\n", b"CHANGE\n", b"RECOVER\n", b"CAPACITY\n"]:
                        assert ready.select(1), "streaming peer did not progress"
                        line = process.stdout.readline()
                        assert line == expected, (line, process.stderr.read())
                        if expected == b"READY\n":
                            os.write(control, b"A")
                        elif expected == b"CHANGE\n":
                            fixture.command("split-window", "-d", "-t", "%0", "exec cat")
                            fixture.track_panes()
                        elif expected == b"RECOVER\n":
                            os.write(control, b"B")
                        else:
                            assert len(fixture.command("list-clients").stdout.splitlines()) == 2
                            process.stdin.write(b"CHECKED\n")
                stdout, stderr = process.communicate(timeout=1)
                assert process.returncode == 0, (binary, backend, stdout, stderr)
                assert stdout == b"PASS bytes, cursors, shared lanes, overflow, coverage and closure\n", stdout
                assert fixture.command("list-clients").stdout == b""
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=1)
                for stream in [process.stdin, process.stdout, process.stderr]:
                    stream.close()
                os.close(control)
            print(f"PASS {Path(binary).parent.name} {backend}: byte stream and subscriber isolation")
