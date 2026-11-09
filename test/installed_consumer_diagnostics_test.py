"""Inner: installed-example failures retain captured bytes and their cause."""
import ast
import io
from pathlib import Path
import subprocess
from types import SimpleNamespace

source = Path(__file__).with_name("installed_consumer.py")
functions = [node for node in ast.walk(ast.parse(source.read_text()))
             if isinstance(node, ast.FunctionDef) and node.name == "run_example"]
assert len(functions) == 1, "installed-example runner must resolve once"
code = compile(ast.Module(body=functions, type_ignores=[]), str(source), "exec")
failures = []
for error in (
    subprocess.CalledProcessError(2, ["example"], output=b"\x00\xff output\n", stderr=b"error\x00\n"),
    subprocess.TimeoutExpired(["example"], 1, output=b"partial output\n", stderr=b"partial error\xff"),
):
    def run(*args, **kwargs):
        raise error

    namespace = {
        "subprocess": SimpleNamespace(run=run, CalledProcessError=subprocess.CalledProcessError,
                                      TimeoutExpired=subprocess.TimeoutExpired),
        "runtime": Path("runtime"),
        "fixture": SimpleNamespace(binary="tmux", socket=Path("owned-server")),
        "environment": {},
    }
    exec(code, namespace)
    try:
        namespace["run_example"]("example")
    except Exception as reported:
        if repr(error.stdout) not in str(reported) or repr(error.stderr) not in str(reported):
            failures.append(f"{type(error).__name__}: captured bytes missing")
        if reported.__cause__ is not error:
            failures.append(f"{type(error).__name__}: original cause missing")
    else:
        failures.append(f"{type(error).__name__}: failure accepted")
assert not failures, failures
print("PASS installed-example nonzero/timeout diagnostics preserve bytes and cause")

workspace = [node for node in ast.parse(source.read_text()).body
             if isinstance(node, ast.FunctionDef) and node.name == "run_workspace_recovery"]
assert len(workspace) == 1, "workspace recovery runner must resolve once"
workspace_code = compile(ast.Module(body=workspace, type_ignores=[]), str(source), "exec")


class Fixture:
    binary = "tmux"
    socket = Path("owned-server")
    server = SimpleNamespace(poll=lambda: 7)
    pane_pidfds = {}

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.closed = True

    def command(self, *arguments):
        if arguments == ("wait-for", "consumer-ready") and self.error is not None:
            raise self.error
        return SimpleNamespace(stdout=b"seed\n")

    def track_panes(self):
        pass


class Consumer:
    def __init__(self, cleanup_error, close_fails):
        class Output(io.BytesIO):
            def close(self):
                super().close()
                if close_fails:
                    raise OSError("consumer stdout close failed")

        self.stdout = Output()
        self.stderr = io.BytesIO()
        self.returncode = None
        self.cleanup_error = cleanup_error

    def poll(self):
        return self.returncode

    def kill(self):
        self.returncode = -9

    def wait(self, *, timeout):
        assert timeout == 1
        if self.cleanup_error:
            raise self.cleanup_error
        return self.returncode

    def communicate(self, *, timeout):
        assert timeout == 1 and self.returncode == -9
        return b"consumer output\x00\xff", b"consumer error\xff"


for outcome, cleanup_fails, close_fails in (("command", False, False), ("timeout", False, False),
                                          ("command", True, False), ("command", False, True),
                                          ("postcondition", False, True)):
    primary = (None if outcome == "postcondition" else
               subprocess.TimeoutExpired(["wait-for"], 1, output=b"command\x00\xff", stderr=b"command error\xff")
               if outcome == "timeout" else subprocess.CalledProcessError(1, ["wait-for"], output=b"command\x00\xff", stderr=b"command error\xff"))
    cleanup = subprocess.TimeoutExpired(["consumer"], 1, output=b"cleanup\x00\xff", stderr=b"cleanup error\xff") if cleanup_fails else None
    fixture = Fixture()
    fixture.error = primary
    consumer = Consumer(cleanup, close_fails)
    namespace = {"Path": Path, "TmuxFixture": lambda _: fixture,
                 "subprocess": SimpleNamespace(Popen=lambda *_, **__: consumer,
                                               DEVNULL=subprocess.DEVNULL, PIPE=subprocess.PIPE,
                                               CalledProcessError=subprocess.CalledProcessError,
                                               TimeoutExpired=subprocess.TimeoutExpired)}
    exec(workspace_code, namespace)
    try:
        namespace["run_workspace_recovery"](Path("runtime"), "tmux", {})
    except BaseException as reported:
        if primary is None:
            assert isinstance(reported, AssertionError), "cleanup replaced the postcondition assertion"
        else:
            assert reported is primary, "cleanup replaced the readiness failure"
        notes = "\n".join(getattr(reported, "__notes__", []))
        expected = ["daemon_status=7", "consumer_status=None"]
        if primary is not None:
            expected += [repr(primary.stdout), repr(primary.stderr)]
        expected += ([repr(cleanup.stdout), repr(cleanup.stderr)] if cleanup_fails
                     else [repr(b"consumer output\x00\xff"), repr(b"consumer error\xff")])
        if close_fails:
            expected.append("consumer stdout close failed")
        assert all(value in notes for value in expected), (expected, notes)
    else:
        raise AssertionError("readiness failure accepted")
    assert fixture.closed and consumer.stdout.closed and consumer.stderr.closed
print("PASS workspace failure diagnostics retain command, consumer and cleanup evidence")
