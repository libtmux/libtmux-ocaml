"""Inner: installed-example failures retain captured bytes and their cause."""
import ast
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
