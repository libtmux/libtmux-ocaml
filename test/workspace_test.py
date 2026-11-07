"""Outer: public blocking workspace execution and journal recovery on owned servers."""
from pathlib import Path
import selectors
import subprocess
import sys
from support.tmux_fixture import TmuxFixture

peer = Path(__file__).resolve().parents[1] / "_build/default/test/workspace_peer.exe"
for binary in sys.argv[1:]:
    with TmuxFixture(binary) as fixture:
        process = subprocess.Popen([str(peer), fixture.binary, str(fixture.socket)],
                                   env=fixture.environment, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            with selectors.DefaultSelector() as ready:
                ready.register(process.stdout, selectors.EVENT_READ)
                assert ready.select(1), "workspace peer not ready"
                line = process.stdout.readline()
                if line == b"CONTEXT_READY\n":
                    fixture.command("set-hook", "-g", "after-new-session",
                                    "link-window -t fixture:")
                    process.stdin.write(b"continue\n")
                    process.stdin.flush()
                    assert ready.select(1), "workspace context result not ready"
                    line = process.stdout.readline()
                    if line != b"CONTEXT_PASSED\n":
                        stdout, stderr = process.communicate(timeout=1)
                        raise AssertionError((line, stdout, stderr))
                    fixture.command("set-hook", "-gu", "after-new-session")
                    process.stdin.write(b"continue\n")
                    process.stdin.flush()
                    assert ready.select(1), "workspace safety probe not ready"
                    line = process.stdout.readline()
                if line.startswith(b"SAFETY_READY "):
                    foreign = line.decode().strip().split()[1]
                    fixture.command("set-hook", "-g", "after-new-window",
                                    f"join-pane -s {foreign}")
                    process.stdin.write(b"continue\n")
                    process.stdin.flush()
                    assert ready.select(1), "workspace safety result not ready"
                    line = process.stdout.readline()
                    if line != b"SAFETY_PASSED\n":
                        stdout, stderr = process.communicate(timeout=1)
                        raise AssertionError((line, stdout, stderr))
                    fixture.command("set-hook", "-gu", "after-new-window")
                    process.stdin.write(b"continue\n")
                    process.stdin.flush()
                    assert ready.select(1), "workspace cancellation not ready"
                    line = process.stdout.readline()
                if line != b"CANCEL_READY\n":
                    stdout, stderr = process.communicate(timeout=1)
                    raise AssertionError((line, stdout, stderr))
                fixture.track_panes()
                fixture.command("set-hook", "-g", "after-new-session",
                                "wait-for -S workspace-ready ; wait-for workspace-block")
                process.stdin.write(b"continue\n")
                process.stdin.flush()
                fixture.command("wait-for", "workspace-ready")
                fixture.track_panes()
                process.stdin.write(b"cancel\n")
                process.stdin.flush()
                assert ready.select(1), "cancellation signal not observed"
                assert process.stdout.readline() == b"CANCELLED_SIGNAL\n"
                fixture.command("wait-for", "-S", "workspace-block")
                stdout, stderr = process.communicate(timeout=1)
                assert process.returncode == 0, (stdout, stderr)
                assert stdout == b"PASS workspace execution, partial compensation, append, races, stale plans, cancellation journal\n"
                assert stderr == b"", stderr
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=1)
            for stream in [process.stdin, process.stdout, process.stderr]:
                stream.close()
            fixture.track_panes()
        assert fixture.command("list-clients").stdout == b""
        print(f"PASS {Path(binary).parent.name}: public Unix workspace executor, compensation and cancellation journal")
