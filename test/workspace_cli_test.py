"""Outer: installed workspace CLI, including bounded interruption and output faults."""

import contextlib
import ctypes
import json
import os
import selectors
import signal
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from support.tmux_fixture import AMBIENT_SELECTORS, TmuxFixture

root = Path(__file__).resolve().parents[1]
standin = root / "_build/default/test/tmux_standin.exe"
libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(36, 1, 0, 0, 0) != 0:
    raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")


def config(session="cli-project", *, impossible=False):
    panes: list[dict[str, Any]] = [{"exec": ["/bin/cat", "-u"]}]
    if impossible:
        panes += [
            {"exec": ["/bin/cat", "-u"], "size": {"cells": 1}},
            {"exec": ["/bin/cat", "-u"]},
        ]
    return {
        "schema": "libtmux.workspace/1",
        "session": session,
        "windows": [{"name": "editor", "panes": panes}],
    }


with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-cli-install-") as installed:
    installed = Path(installed)
    subprocess.run(
        ["dune", "install", "--prefix", str(installed), "libtmux-workspace-cli"],
        cwd=root,
        check=True,
        capture_output=True,
    )
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
            wrapper.symlink_to(standin)
            environment = dict(
                fixture.environment,
                PATH=str(directory) + os.pathsep + os.environ["PATH"],
                LIBTMUX_STANDIN_TMUX=actual,
                LIBTMUX_STANDIN_CONFIG="/dev/null",
                LIBTMUX_STANDIN_AUDIT=str(audit),
            )

            def write(value):
                document.write_text(json.dumps(value))

            def command(
                name,
                *args,
                expected=0,
                json_output=True,
                endpoint=None,
                socket_name=None,
                program=None,
                reply=None,
                extra_env=None,
            ):
                argv = [str(cli), name]
                if json_output:
                    argv += ["--json"]
                if endpoint is not None:
                    argv += ["--socket", str(endpoint)]
                if socket_name is not None:
                    argv += ["--socket-name", str(socket_name)]
                if name != "check":
                    argv += ["--tmux", str(program or wrapper)]
                argv += [*args, str(document)]
                run_env = dict(environment)
                if extra_env is not None:
                    run_env.update(extra_env)
                if reply is not None:
                    run_env["LIBTMUX_STANDIN_REPLY"] = reply
                result = subprocess.run(
                    argv,
                    cwd=directory,
                    env=run_env,
                    capture_output=True,
                    timeout=1,
                    check=False,
                )
                assert result.returncode == expected, (
                    argv,
                    result.returncode,
                    result.stdout,
                    result.stderr,
                )
                if json_output:
                    assert result.stderr == b"", result.stderr
                    return json.loads(result.stdout)
                return result

            if unsupported:
                write(config())
                for mode in ["plan", "apply"]:
                    for endpoint in [fixture.socket, directory / "missing"]:
                        refused = command(mode, endpoint=endpoint, expected=6)
                        assert refused["error"]["code"] == "unsupported_version", (
                            refused
                        )
                        assert not (directory / "missing").exists()
                assert fixture.command("list-clients").stdout == b""
                print(
                    f"PASS {Path(binary).parent.name}: CLI rejects old daemon and local bootstrap version before creation"
                )
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
            help_result = subprocess.run(
                [str(cli), "apply", "--help=plain"],
                capture_output=True,
                env=environment,
                timeout=1,
                check=False,
            )
            assert help_result.returncode == 0
            assert (
                b"--keep-partial" in help_result.stdout and b"130" in help_result.stdout
            )
            broken = subprocess.Popen(
                [str(cli), "check", "--json", str(document)],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            assert broken.stdout is not None
            assert broken.stderr is not None
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
            bad_version.symlink_to(standin)
            malformed = command(
                "plan",
                program=bad_version,
                reply="tmux " + "x" * 512,
                endpoint=missing,
                expected=6,
            )
            assert malformed["error"]["code"] == "malformed_data"
            assert not missing.exists()
            required = command(
                "plan", "--require-existing", endpoint=missing, expected=3
            )
            assert required["error"]["code"] == "plan_rejected"
            assert audit.read_text().splitlines() == ["-V"]
            changed = command(
                "apply",
                "--expect-document",
                digest + "bad",
                endpoint=fixture.socket,
                expected=4,
            )
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
            assert (
                fixture.command(
                    "display-message", "-p", "-t", created["pane"], "#{session_name}"
                ).stdout
                == b"cli-project\n"
            )
            assert fixture.command(
                "display-message", "-p", "-t", created["pane"], "#{pane_current_path}"
            ).stdout.decode().strip() == str(directory)
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
            assert (
                partial["status"] == "partial"
                and partial["failed"]
                and partial["cleanup"]
            )
            assert all(entry["error"] is None for entry in partial["cleanup"])
            assert (
                fixture.command(
                    "has-session", "-t", "cli-partial", check=False
                ).returncode
                != 0
            )
            human_partial = command(
                "apply", endpoint=fixture.socket, expected=5, json_output=False
            )
            assert (
                b"split pane" in human_partial.stderr
                and b"command_failed" in human_partial.stderr
            )
            assert b"cleanup:" in human_partial.stderr and human_partial.stdout == b""
            write(config("cli-retained", impossible=True))
            retained = command(
                "apply", "--keep-partial", endpoint=fixture.socket, expected=5
            )
            assert retained["status"] == "partial" and retained["cleanup"] == []
            assert fixture.command("has-session", "-t", "cli-retained").returncode == 0
            fixture.track_panes()
            write(config("cli-interrupted"))
            fixture.command(
                "set-hook",
                "-g",
                "after-new-session",
                "wait-for -S cli-ready ; wait-for cli-block",
            )
            process = subprocess.Popen(
                [
                    str(cli),
                    "apply",
                    "--json",
                    "--timeout",
                    "0.2",
                    "--socket",
                    str(fixture.socket),
                    "--tmux",
                    str(wrapper),
                    str(document),
                ],
                env=environment,
                cwd=directory,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            assert process.stdout is not None
            assert process.stderr is not None
            try:
                fixture.command("wait-for", "cli-ready")
                fixture.track_panes()
                os.killpg(process.pid, signal.SIGINT)
                with selectors.DefaultSelector() as ready:
                    ready.register(process.stdout, selectors.EVENT_READ)
                    assert ready.select(1), (
                        "SIGINT receipt was not delivered within the bound"
                    )
                stdout, stderr = process.communicate(timeout=1)
                assert process.returncode == 130, (process.returncode, stdout, stderr)
                interrupted = json.loads(stdout)
                assert interrupted["status"] in {"interrupted", "partial"}, interrupted
                assert interrupted["operation_id"] and (
                    interrupted["completed"] or interrupted["uncertain"]
                )
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
            # Pin capacity: a non-reading pipe can otherwise accept the whole response.
            large = config("cli-output-fault")
            large["windows"][0]["panes"][0]["startup"] = ["x"] * 256
            write(large)
            process = subprocess.Popen(
                [
                    str(cli),
                    "plan",
                    "--json",
                    "--socket",
                    str(fixture.socket),
                    "--tmux",
                    str(wrapper),
                    str(document),
                ],
                env=environment,
                cwd=directory,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                pipesize=4096,
            )
            assert process.stdout is not None
            assert process.stderr is not None
            try:
                status = process.wait(timeout=1)
                if status != 6:
                    output = process.stdout.read()
                    error = process.stderr.read()
                    raise AssertionError(
                        ("stalled output status", status, len(output), error)
                    )
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=1)
                process.stdout.close()
                process.stderr.close()
            process = subprocess.Popen(
                [
                    str(cli),
                    "plan",
                    "--json",
                    "--socket",
                    str(fixture.socket),
                    "--tmux",
                    str(wrapper),
                    str(document),
                ],
                env=environment,
                cwd=directory,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                pipesize=4096,
                start_new_session=True,
            )
            assert process.stdout is not None
            assert process.stderr is not None
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
            write(config("cli-env-select"))
            both_flags = command(
                "plan",
                endpoint=fixture.socket,
                socket_name="conflict",
                expected=2,
            )
            assert both_flags["error"]["code"] == "invalid_endpoint"
            bad_name = command("plan", socket_name="bad/slash", expected=2)
            assert bad_name["error"]["code"] == "invalid_endpoint"
            bad_env = command(
                "plan",
                extra_env={"LIBTMUX_SOCKET": "bad/slash"},
                expected=2,
            )
            assert bad_env["error"]["code"] == "invalid_endpoint"
            override = command(
                "plan",
                endpoint=fixture.socket,
                extra_env={
                    "LIBTMUX_SOCKET_PATH": str(directory / "other"),
                    "LIBTMUX_SOCKET": "bad/slash",
                    "TMUX": "/unrelated/server,123,0",
                },
            )
            assert override["source"]["server_pid"] == fixture.server.pid
            env_path = command(
                "plan",
                extra_env={
                    "LIBTMUX_SOCKET_PATH": "server",
                    "LIBTMUX_SOCKET": "bad/slash",
                    "TMUX": "/unrelated/server,123,0",
                },
            )
            assert env_path["source"]["server_pid"] == fixture.server.pid
            env_tmux = command(
                "apply",
                extra_env={
                    "LIBTMUX_SOCKET_PATH": "   ",
                    "LIBTMUX_SOCKET": "\t",
                    "TMUX": f"{fixture.socket},4242,0",
                    "TMUX_PANE": "%0",
                },
            )
            assert env_tmux["status"] == "succeeded"
            assert env_tmux["source"]["server_pid"] == fixture.server.pid
            fixture.track_panes()
            assert fixture.command("list-clients").stdout == b""
            print(
                f"PASS {Path(binary).parent.name}: installed CLI validation, planning, apply, default server selection, collisions, partial recovery, SIGINT and stalled output"
            )

        with tempfile.TemporaryDirectory(
            prefix="libtmux-ocaml-cli-bootstrap-"
        ) as temporary:
            directory = Path(temporary)
            document = directory / "project.json"
            document.write_bytes(
                (root / "examples/workspace/project.json").read_bytes()
            )
            sandbox = directory / "sandbox"
            sandbox.mkdir(mode=0o700)
            wrapper = directory / "tmux"
            wrapper.symlink_to(standin)
            environment = {
                key: value
                for key, value in os.environ.items()
                if key not in AMBIENT_SELECTORS
            } | {
                "LIBTMUX_STANDIN_TMUX": actual,
                "LIBTMUX_STANDIN_CONFIG": "/dev/null",
                "TMUX_TMPDIR": str(sandbox),
                "LIBTMUX_TEST_SANDBOX": str(sandbox),
            }
            child_file = Path(f"/proc/self/task/{os.getpid()}/children")
            for label, extra in [
                ("default", {}),
                (
                    "named",
                    {"LIBTMUX_SOCKET_PATH": "  ", "LIBTMUX_SOCKET": "named"},
                ),
            ]:
                before = set(map(int, child_file.read_text().split()))
                pane_pidfds = []
                try:
                    preview = subprocess.run(
                        [
                            str(cli),
                            "plan",
                            "--json",
                            "--tmux",
                            str(wrapper),
                            str(document),
                        ],
                        cwd=directory,
                        env=environment | extra,
                        capture_output=True,
                        timeout=1,
                        check=True,
                    )
                    planned = json.loads(preview.stdout)
                    assert planned["endpoint"] == {
                        "kind": "named_socket",
                        "value": label,
                    }
                    result = subprocess.run(
                        [
                            str(cli),
                            "apply",
                            "--json",
                            "--tmux",
                            str(wrapper),
                            str(document),
                        ],
                        cwd=directory,
                        env=environment | extra,
                        capture_output=True,
                        timeout=1,
                        check=False,
                    )
                    assert result.returncode == 0, (
                        result.returncode,
                        result.stdout,
                        result.stderr,
                    )
                    assert result.stderr == b""
                    receipt = json.loads(result.stdout)
                    assert receipt["status"] == "succeeded" and not receipt["failed"]
                    daemon = receipt["source"]["server_pid"]
                    assert (
                        daemon in set(map(int, child_file.read_text().split())) - before
                    )

                    def tmux(*args, sock_label=label):
                        assert (
                            environment["LIBTMUX_TEST_SANDBOX"]
                            == environment["TMUX_TMPDIR"]
                        )
                        return subprocess.run(
                            [actual, "-L", sock_label, *args],
                            env=environment,
                            capture_output=True,
                            check=True,
                            timeout=1,
                        ).stdout

                    assert tmux("list-clients") == b""
                    assert (
                        tmux(
                            "list-windows",
                            "-t",
                            "ocaml-project",
                            "-F",
                            "#{window_name}:#{window_panes}",
                        )
                        == b"editor:2\nlogs:1\n"
                    )
                    assert (
                        tmux("show-options", "-t", "ocaml-project", "-v", "@project")
                        == b"ocaml\n"
                    )
                    rows = (
                        tmux(
                            "list-panes",
                            "-a",
                            "-F",
                            "#{pane_pid}|#{pane_current_path}",
                        )
                        .decode()
                        .splitlines()
                    )
                    assert len(rows) == 3 and all(
                        row.split("|", 1)[1] == str(directory) for row in rows
                    )
                    for row in rows:
                        pane_pidfds.append(os.pidfd_open(int(row.split("|", 1)[0])))
                    named_plan = subprocess.run(
                        [
                            str(cli),
                            "plan",
                            "--json",
                            "--socket-name",
                            label,
                            "--tmux",
                            str(wrapper),
                            str(document),
                        ],
                        cwd=directory,
                        env=environment
                        | {"LIBTMUX_SOCKET_PATH": "/unrelated", "LIBTMUX_SOCKET": "x"},
                        capture_output=True,
                        timeout=1,
                        check=False,
                    )
                    assert named_plan.returncode == 4
                finally:
                    while True:
                        children = (
                            set(map(int, child_file.read_text().split())) - before
                        )
                        if not children:
                            break
                        for pid in children:
                            descriptor = os.pidfd_open(pid)
                            try:
                                with contextlib.suppress(ProcessLookupError):
                                    signal.pidfd_send_signal(descriptor, signal.SIGTERM)
                                with selectors.DefaultSelector() as ready:
                                    ready.register(descriptor, selectors.EVENT_READ)
                                    assert ready.select(1), (
                                        "owned CLI bootstrap descendant did not exit"
                                    )
                                os.waitpid(pid, 0)
                            finally:
                                os.close(descriptor)
                    for descriptor in pane_pidfds:
                        with selectors.DefaultSelector() as ready:
                            ready.register(descriptor, selectors.EVENT_READ)
                            assert ready.select(1), (
                                "owned CLI bootstrap pane did not exit"
                            )
                        os.close(descriptor)
            print(
                f"PASS {Path(binary).parent.name}: installed CLI applies the shipped workspace on default and named endpoints; owned daemons and panes exit"
            )
