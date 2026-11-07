"""Outer: installed workspace CLI, including bounded interruption and output faults."""
import ctypes
import json
import os
from pathlib import Path
import selectors
import shlex
import signal
import subprocess
import sys
import tempfile
from support.tmux_fixture import TmuxFixture

root = Path(__file__).resolve().parents[1]
libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(36, 1, 0, 0, 0) != 0:
    raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")


def config(session="cli-project", *, impossible=False):
    panes = [{"exec": ["/bin/cat", "-u"]}]
    if impossible:
        panes += [{"exec": ["/bin/cat", "-u"], "size": {"cells": 1}},
                  {"exec": ["/bin/cat", "-u"]}]
    return {"schema": "libtmux.workspace/1", "session": session,
            "windows": [{"name": "editor", "panes": panes}]}


with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-cli-install-") as installed:
    installed = Path(installed)
    subprocess.run(["dune", "install", "--prefix", str(installed), "libtmux-workspace-cli"],
                   cwd=root, check=True, capture_output=True)
    cli = installed / "bin/tmux-workspace"
    assert cli.is_file()
    version = subprocess.check_output([str(cli), "--version"], timeout=1)
    assert version == b"unreleased\n"
    unsupported = "--unsupported" in sys.argv
    for binary in [value for value in sys.argv[1:] if value != "--unsupported"]:
        actual = str(Path(binary).resolve(strict=True))
        with TmuxFixture(actual) as fixture:
            directory = Path(fixture.directory.name)
            document = directory / "project.json"
            audit = directory / "binary-calls"
            wrapper = directory / "tmux"
            wrapper.write_text("#!/bin/sh\n"
                               f"printf '%s\\n' \"$*\" >> {shlex.quote(str(audit))}\n"
                               f"exec {shlex.quote(actual)} -f /dev/null \"$@\"\n")
            wrapper.chmod(0o700)
            environment = dict(fixture.environment, PATH=str(directory) + os.pathsep + os.environ["PATH"])
            def write(value):
                document.write_text(json.dumps(value))
            def command(name, *args, expected=0, json_output=True, endpoint=None, program=None):
                argv = [str(cli), name]
                if json_output:
                    argv += ["--json"]
                if endpoint is not None:
                    argv += ["--socket", str(endpoint)]
                if name != "check":
                    argv += ["--tmux", str(program or wrapper)]
                argv += [*args, str(document)]
                result = subprocess.run(argv, cwd=directory, env=environment,
                                        capture_output=True, timeout=1)
                assert result.returncode == expected, (argv, result.returncode, result.stdout, result.stderr)
                if json_output:
                    assert result.stderr == b"", result.stderr
                    return json.loads(result.stdout)
                return result
            if unsupported:
                write(config())
                for mode in ["plan", "apply"]:
                    for endpoint in [fixture.socket, directory / "missing"]:
                        refused = command(mode, endpoint=endpoint, expected=6)
                        assert refused["error"]["code"] == "unsupported_version", refused
                        assert not (directory / "missing").exists()
                assert fixture.command("list-clients").stdout == b""
                print(f"PASS {Path(binary).parent.name}: CLI rejects old daemon and local bootstrap version before creation")
                continue
            write(config())
            checked = command("check")
            assert checked["schema"] == "libtmux.workspace-check/1"
            assert checked["windows"] == 1 and checked["panes"] == 1
            assert not audit.exists(), "check invoked tmux"
            digest = checked["document_digest"]
            document.write_bytes(b" " * 65_538)
            oversized = command("check", expected=2)
            assert oversized["error"]["code"] == "invalid_document"
            assert not audit.exists(), "invalid check invoked tmux"
            write(config())
            help_result = subprocess.run([str(cli), "apply", "--help=plain"],
                                         capture_output=True, env=environment, timeout=1)
            assert help_result.returncode == 0
            assert b"--keep-partial" in help_result.stdout and b"130" in help_result.stdout
            broken = subprocess.Popen([str(cli), "check", "--json", str(document)],
                                      env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            broken.stdout.close()
            try:
                assert broken.wait(timeout=1) == 6
                assert broken.stderr.read() == b""
            finally:
                if broken.poll() is None:
                    broken.kill()
                    broken.wait(timeout=1)
                broken.stderr.close()
            missing = directory / "missing"
            preview = command("plan", endpoint=missing)
            assert preview["advisory"] and preview["source"] is None
            assert preview["actions"][0]["action"]["bootstrap"]
            assert not missing.exists(), "plan created a daemon"
            assert audit.read_text().splitlines() == ["-V"]
            bad_version = directory / "bad-version"
            bad_version.write_text("#!/bin/sh\nprintf '%s\\n' " + shlex.quote("tmux " + "x" * 512) + "\n")
            bad_version.chmod(0o700)
            malformed = command("plan", program=bad_version, endpoint=missing, expected=6)
            assert malformed["error"]["code"] == "malformed_data"
            assert not missing.exists()
            required = command("plan", "--require-existing", endpoint=missing, expected=3)
            assert required["error"]["code"] == "plan_rejected"
            assert audit.read_text().splitlines() == ["-V"]
            changed = command("apply", "--expect-document", digest + "bad", endpoint=fixture.socket, expected=4)
            assert changed["error"]["code"] == "document_changed"
            write(preview)
            invalid = command("apply", endpoint=fixture.socket, expected=2)
            assert invalid["error"]["code"] == "invalid_document"
            write(config())
            preview_human = command("plan", endpoint=fixture.socket, json_output=False)
            assert b"Advisory plan: 1 action\n" in preview_human.stdout
            assert b"create session" in preview_human.stdout
            assert str(fixture.socket).encode() in preview_human.stdout
            assert preview_human.stderr == b""
            success = command("apply", endpoint=fixture.socket)
            assert success["schema"] == "libtmux.workspace-receipt/1"
            assert success["status"] == "succeeded" and success["completed"] == [0]
            assert success["source"]["server_pid"] == fixture.server.pid
            assert len(success["source"]["generation"]) == 64
            created = success["steps"][0]["created"][0]
            fixture.track_panes()
            assert fixture.command("display-message", "-p", "-t", created["pane"], "#{session_name}").stdout == b"cli-project\n"
            assert fixture.command("display-message", "-p", "-t", created["pane"], "#{pane_current_path}").stdout.decode().strip() == str(directory)
            command("apply", endpoint=fixture.socket, expected=4)
            command("apply", "--append", endpoint=fixture.socket, expected=4)
            appended = config("cli-project")
            appended["windows"][0]["name"] = "new-window"
            write(appended)
            receipt = command("apply", "--append", endpoint=fixture.socket)
            assert receipt["status"] == "succeeded"
            assert receipt["steps"][0]["action"]["kind"] == "create_window"
            fixture.track_panes()
            write(config("cli-partial", impossible=True))
            partial = command("apply", endpoint=fixture.socket, expected=5)
            assert partial["status"] == "partial" and partial["failed"] and partial["cleanup"]
            assert all(entry["error"] is None for entry in partial["cleanup"])
            assert fixture.command("has-session", "-t", "cli-partial", check=False).returncode != 0
            human_partial = command("apply", endpoint=fixture.socket, expected=5, json_output=False)
            assert b"split pane" in human_partial.stderr and b"command_failed" in human_partial.stderr
            assert b"cleanup:" in human_partial.stderr and human_partial.stdout == b""
            write(config("cli-retained", impossible=True))
            retained = command("apply", "--keep-partial", endpoint=fixture.socket, expected=5)
            assert retained["status"] == "partial" and retained["cleanup"] == []
            assert fixture.command("has-session", "-t", "cli-retained").returncode == 0
            fixture.track_panes()
            write(config("cli-interrupted"))
            fixture.command("set-hook", "-g", "after-new-session",
                            "wait-for -S cli-ready ; wait-for cli-block")
            process = subprocess.Popen([str(cli), "apply", "--json", "--timeout", "0.2",
                                        "--socket", str(fixture.socket), "--tmux", str(wrapper), str(document)],
                                       env=environment, cwd=directory, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       start_new_session=True)
            try:
                fixture.command("wait-for", "cli-ready")
                fixture.track_panes()
                os.killpg(process.pid, signal.SIGINT)
                with selectors.DefaultSelector() as ready:
                    ready.register(process.stdout, selectors.EVENT_READ)
                    assert ready.select(1), "SIGINT receipt was not delivered within the bound"
                stdout, stderr = process.communicate(timeout=1)
                assert process.returncode == 130, (process.returncode, stdout, stderr)
                interrupted = json.loads(stdout)
                assert interrupted["status"] in {"interrupted", "partial"}, interrupted
                assert interrupted["operation_id"] and (interrupted["completed"] or interrupted["uncertain"])
                assert stderr == b"", stderr
            finally:
                fixture.command("wait-for", "-S", "cli-block")
                fixture.command("set-hook", "-gu", "after-new-session")
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=1)
                process.stdout.close()
                process.stderr.close()
                fixture.track_panes()
            large = config("cli-output-fault")
            large["windows"][0]["panes"][0]["startup"] = ["x"] * 256
            write(large)
            process = subprocess.Popen([str(cli), "plan", "--json", "--socket", str(fixture.socket),
                                        "--tmux", str(wrapper), str(document)], env=environment, cwd=directory,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                status = process.wait(timeout=1)
                if status != 6:
                    output = process.stdout.read()
                    error = process.stderr.read()
                    raise AssertionError(("stalled output status", status, len(output), error))
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=1)
                process.stdout.close()
                process.stderr.close()
            process = subprocess.Popen([str(cli), "plan", "--json", "--socket", str(fixture.socket),
                                        "--tmux", str(wrapper), str(document)], env=environment, cwd=directory,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            try:
                with selectors.DefaultSelector() as ready:
                    ready.register(process.stdout, selectors.EVENT_READ)
                    assert ready.select(1), "blocked plan output did not start"
                os.killpg(process.pid, signal.SIGINT)
                status = process.wait(timeout=1)
                assert status == 130, ("SIGINT during result delivery", status)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=1)
                process.stdout.close()
                process.stderr.close()
            assert fixture.command("list-clients").stdout == b""
            print(f"PASS {Path(binary).parent.name}: installed CLI validation, planning, apply, collisions, partial recovery, SIGINT and stalled output")

        with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-cli-bootstrap-") as temporary:
            directory = Path(temporary)
            document = directory / "project.json"
            document.write_bytes((root / "examples/workspace/project.json").read_bytes())
            socket = directory / "server"
            wrapper = directory / "tmux"
            wrapper.write_text(f"#!/bin/sh\nexec {shlex.quote(actual)} -f /dev/null \"$@\"\n")
            wrapper.chmod(0o700)
            environment = {key: value for key, value in os.environ.items() if key not in {"TMUX", "TMUX_PANE"}}
            child_file = Path(f"/proc/self/task/{os.getpid()}/children")
            before = set(map(int, child_file.read_text().split()))
            pane_pidfds = []
            daemon = None
            try:
                result = subprocess.run([str(cli), "apply", "--json", "--socket", str(socket),
                                         "--tmux", str(wrapper), str(document)], cwd=directory,
                                        env=environment, capture_output=True, timeout=1)
                assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
                assert result.stderr == b""
                receipt = json.loads(result.stdout)
                assert receipt["status"] == "succeeded" and not receipt["failed"]
                daemon = receipt["source"]["server_pid"]
                assert daemon in set(map(int, child_file.read_text().split())) - before
                def tmux(*args):
                    return subprocess.run([actual, "-S", str(socket), *args],
                                          env=environment, capture_output=True, check=True, timeout=1).stdout
                assert tmux("list-clients") == b""
                assert tmux("list-windows", "-t", "ocaml-project", "-F", "#{window_name}:#{window_panes}") == b"editor:2\nlogs:1\n"
                assert tmux("show-options", "-t", "ocaml-project", "-v", "@project") == b"ocaml\n"
                rows = tmux("list-panes", "-a", "-F", "#{pane_pid}|#{pane_current_path}").decode().splitlines()
                assert len(rows) == 3 and all(row.split("|", 1)[1] == str(directory) for row in rows)
                for row in rows:
                    pane_pidfds.append(os.pidfd_open(int(row.split("|", 1)[0])))
            finally:
                while True:
                    children = set(map(int, child_file.read_text().split())) - before
                    if not children:
                        break
                    for pid in children:
                        descriptor = os.pidfd_open(pid)
                        try:
                            try:
                                signal.pidfd_send_signal(descriptor, signal.SIGTERM)
                            except ProcessLookupError:
                                pass
                            with selectors.DefaultSelector() as ready:
                                ready.register(descriptor, selectors.EVENT_READ)
                                assert ready.select(1), "owned CLI bootstrap descendant did not exit"
                            os.waitpid(pid, 0)
                        finally:
                            os.close(descriptor)
                for descriptor in pane_pidfds:
                    with selectors.DefaultSelector() as ready:
                        ready.register(descriptor, selectors.EVENT_READ)
                        assert ready.select(1), "owned CLI bootstrap pane did not exit"
                    os.close(descriptor)
            print(f"PASS {Path(binary).parent.name}: installed CLI applies the shipped workspace on a fresh endpoint; owned daemon and panes exit")
