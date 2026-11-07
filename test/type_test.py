"""Check public type errors against a known compiling consumer."""

from pathlib import Path
import subprocess
import sys
import tempfile


compiler, interface = sys.argv[1:]
programs = [
    (True, 'let _ = Libtmux.Expr.Int.ge Libtmux.Pane.Fields.width 120'),
    (False, 'let _ = Libtmux.Expr.Text.starts_with Libtmux.Pane.Fields.width "12"'),
    (False, 'let _ = Libtmux.Expr.Bool.is_true Libtmux.Pane.Fields.current_command'),
    (False, '''open Libtmux
let wrong snapshot = Snapshot.panes snapshot |> Iarray.to_seq
  |> Query.matching (Expr.Text.equal Session.Fields.name "work")'''),
    (False, '''open Libtmux
let wrong snapshot = Array.set (Snapshot.panes snapshot) 0'''),
]
with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-types-") as directory:
    path = Path(directory) / "caller.ml"
    for should_compile, source in programs:
        path.write_text(source + "\n")
        result = subprocess.run([compiler, "-color", "never", "-I", str(Path(interface).parent), "-c", str(path)],
                                capture_output=True, text=True)
        if should_compile != (result.returncode == 0):
            raise AssertionError(result.stderr or "invalid program compiled")
        if not should_compile:
            assert "Error:" in result.stderr and "Unbound" not in result.stderr, result.stderr
print("PASS public type safety: valid caller and four rejected programs")
