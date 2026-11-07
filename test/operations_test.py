"""Outer: the same creation and mutation workload through Unix and Eio."""
import json
from pathlib import Path
import subprocess
import sys
from support.tmux_fixture import TmuxFixture

peer = Path(__file__).resolve().parents[1] / "_build/default/test/operations_peer.exe"
for binary in sys.argv[1:]:
    for backend in ["unix", "eio"]:
        with TmuxFixture(binary) as fixture:
            fixture.command("set-hook", "-g", "after-new-window",
                            "set-environment -g LIBTMUX_TEST_HOOK fired")
            root = Path(fixture.directory.name)
            program = root / "program ; ignored"
            cwd = root / "cwd-#{pid}"
            cwd.mkdir()
            receipt = root / "exec.json"
            program.write_text(
                "#!/usr/bin/python3\n"
                "import json, os, pathlib, subprocess, sys\n"
                f"pathlib.Path({str(receipt)!r}).write_text(json.dumps(dict(argv=sys.argv, cwd=os.getcwd(), value=os.environ['LIBTMUX_TEST_VALUE'])))\n"
                f"subprocess.run({[fixture.binary, '-S', str(fixture.socket), 'wait-for', '-S', 'program-ready']!r}, check=True)\n"
                "os.execv('/bin/cat', ['cat'])\n"
            )
            program.chmod(0o700)
            result = subprocess.run([str(peer), fixture.binary, str(fixture.socket), backend, str(program), str(cwd)],
                                    env=fixture.environment, capture_output=True, timeout=1)
            assert result.returncode == 0, (binary, backend, result.stdout, result.stderr)
            value = json.loads(receipt.read_text())
            assert value == dict(argv=[str(program)], cwd=str(cwd), value="literal-#{pid}\n%end 1 2 3"), value
            assert result.stdout == b"PASS creation, links, geometry, movement and teardown\n", result.stdout
            assert fixture.command("list-clients").stdout == b""
            assert fixture.command("list-sessions", "-F", "#{session_name}").stdout == b"fixture\n"
            assert fixture.command("show-environment", "-g", "LIBTMUX_TEST_HOOK").stdout == b"LIBTMUX_TEST_HOOK=fired\n"
            fixture.command("set-hook", "-g", "after-new-window", "select-pane -t %4294967294")
            result = subprocess.run([str(peer), fixture.binary, str(fixture.socket), backend, str(program), str(cwd)],
                                    env=dict(fixture.environment, LIBTMUX_TEST_FAILURE="hook"),
                                    capture_output=True, timeout=1)
            assert result.returncode == 0, (binary, backend, result.stdout, result.stderr)
            lines = result.stdout.splitlines()
            assert len(lines) == 2 and lines[0].startswith(b"CREATED @"), lines
            assert lines[1] == b"PASS retained creation after hook failure", lines
            created = lines[0].removeprefix(b"CREATED ")
            assert created in fixture.command("list-windows", "-a", "-F", "#{window_id}").stdout.splitlines()
            fixture.track_panes()
            fixture.command("kill-window", "-t", created)
            assert fixture.command("list-clients").stdout == b""
            print(f"PASS {Path(binary).parent.name} {backend}: exact argv, creation receipts and mutations")
