"""Outer: install a package and execute a consumer outside its source tree."""

import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
from support.tmux_fixture import TmuxFixture


root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-consumer-") as directory:
    temporary = Path(directory)
    prefix = temporary / "installed"
    packages = ["libtmux", "libtmux-json", "libtmux-unix", "libtmux-eio"]
    subprocess.run(["dune", "install", "--prefix", str(prefix), *packages], cwd=root, check=True)
    consumer = temporary / "consumer"
    consumer.mkdir()
    (consumer / "dune-project").write_text("(lang dune 3.24)\n")
    (consumer / "dune").write_text("(executable (name main) (libraries libtmux libtmux-json))\n")
    (consumer / "model_fixture.ml").write_text((root / "test/model_fixture.ml").read_text())
    examples = re.findall(r"```ocaml\n(.*?)```", (root / "README.md").read_text(), re.DOTALL)
    assert len(examples) == 2
    (consumer / "main.ml").write_text("\n".join(examples) + '''
let () =
  let endpoint = Endpoint.named_socket "installed-consumer" in
  assert (Endpoint.equal endpoint (Endpoint.named_socket "installed-consumer"));
  assert (Query.exactly_one (List.to_seq [42]) = Ok 42);
  assert (Query.exactly_one (List.to_seq [42; 42]) =
          Error (Cardinality.Multiple_matches {at_least = 2}));
  let snapshot = Model_fixture.snapshot () in
  assert (List.map Pane.Id.to_string (editor_ids snapshot) = ["%1"]);
  assert (List.map Pane.Id.to_string (active_ids snapshot) = ["%1"]);
  let wire = match Libtmux_json.Expr.to_string Model.pane editors with
    | Ok value -> value
    | Error error -> failwith (Format.asprintf "%a" Libtmux_json.Decode_error.pp error) in
  let decoded = match Libtmux_json.Expr.of_string Model.pane wire with
    | Ok value -> value
    | Error error -> failwith (Format.asprintf "%a" Libtmux_json.Decode_error.pp error) in
  assert (Expr.compile decoded (Iarray.get (Snapshot.panes snapshot) 0));
  print_endline "installed core/JSON consumer and README examples: PASS"
''')
    environment = dict(os.environ, OCAMLPATH=str(prefix / "lib"))
    for key in ("DUNE_SOURCEROOT", "DUNE_WORKSPACE"):
        environment.pop(key, None)
    for package in packages:
        resolved = subprocess.check_output(["ocamlfind", "query", package], env=environment, text=True).strip()
        assert Path(resolved) == prefix / "lib" / package
    subprocess.run(["dune", "exec", "--root", str(consumer), "--no-print-directory", "./main.exe"],
                   cwd=consumer, env=environment, check=True)
    runtime = temporary / "runtime"
    runtime.mkdir()
    (runtime / "dune-project").write_text("(lang dune 3.24)\n")
    (runtime / "dune").write_text('''
(executable (name native_capture) (modules native_capture) (libraries libtmux libtmux-eio eio_main))
(executable (name native_wait) (modules native_wait) (libraries libtmux libtmux-eio eio_main))
(executable (name configuration_unix) (modules configuration_unix) (libraries libtmux libtmux-unix))
(executable (name configuration_eio) (modules configuration_eio) (libraries libtmux libtmux-eio eio_main))
''')
    (runtime / "native_capture.ml").write_bytes((root / "examples/native_capture.ml").read_bytes())
    (runtime / "native_wait.ml").write_bytes((root / "examples/native_wait.ml").read_bytes())
    common = '''
let get = function Ok value -> value | Error error -> failwith (Format.asprintf "%a" Error.pp error)
let exercise client =
  let snapshot = get (C.capture client) in
  let target = Session.target (Iarray.get (Snapshot.sessions snapshot) 0) in
  let scope = Options.Session target in
  get (C.set_option client scope ~name:"@libtmux-convenience" (Text "literal-#{pid}"));
  assert (get (C.read_option client scope "@libtmux-convenience") = Some (Options.Scalar (Text "literal-#{pid}")));
  let table = get (C.capture_options client scope) in
  assert (Option.is_some (Options.lookup table "@libtmux-convenience"));
  get (C.unset_option client scope "@libtmux-convenience");
  assert (get (C.read_option client scope "@libtmux-convenience") = None);
  get (C.set_environment client Global ~name:"LIBTMUX_CONVENIENCE" "");
  assert (Environment.lookup (get (C.capture_environment client Global)) "LIBTMUX_CONVENIENCE" = Some (Value ""));
  get (C.unset_environment client Global "LIBTMUX_CONVENIENCE")
'''
    for backend in ["unix", "eio"]:
        module = f"open Libtmux\nmodule C = Libtmux_{backend}.Client\n"
        connect = '''
let () =
  let client = get (C.connect ~binary:Sys.argv.(1) (Endpoint.socket_path Sys.argv.(2))) in
  Fun.protect ~finally:(fun () -> ignore (get (C.close client))) (fun () ->
      Libtmux_unix.Cancellation.with_ (fun cancel ->
          Libtmux_unix.Cancellation.cancel cancel;
          assert (try ignore (C.set_environment ~cancel client Global ~name:"LIBTMUX_MUST_NOT_RUN" "x"); false
                  with Libtmux_unix.Cancellation.Cancelled -> true));
      assert (Environment.lookup (get (C.capture_environment client Global)) "LIBTMUX_MUST_NOT_RUN" = None);
      exercise client)
''' if backend == "unix" else '''
let () = Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    let client = get (C.connect ~sw ~binary:Sys.argv.(1)
        ~process_mgr:(Eio.Stdenv.process_mgr env) ~mono_clock:(Eio.Stdenv.mono_clock env)
        (Endpoint.socket_path Sys.argv.(2))) in
    Fun.protect ~finally:(fun () -> ignore (get (C.close client))) (fun () -> exercise client)))
'''
        (runtime / f"configuration_{backend}.ml").write_text(module + common + connect)
    subprocess.run(["dune", "build", "--root", str(runtime)], cwd=runtime, env=environment, check=True)
    binaries = sys.argv[1:] or [root / f"scratch/tmux/tmux-{version}/tmux" for version in ["3.3", "3.3a", "3.4", "3.8"]]
    for binary in binaries:
        with TmuxFixture(binary) as fixture:
            result = subprocess.run([str(runtime / "_build/default/native_capture.exe"),
                                     fixture.binary, str(fixture.socket)],
                                    cwd=runtime, env=environment, capture_output=True, timeout=1, check=True)
            assert result.stdout == b"%0\n" and result.stderr == b"", result
            for backend in ["unix", "eio"]:
                result = subprocess.run([str(runtime / f"_build/default/configuration_{backend}.exe"),
                                         fixture.binary, str(fixture.socket)],
                                        cwd=runtime, env=environment, capture_output=True, timeout=1, check=True)
                assert result.stdout == b"" and result.stderr == b"", result
            assert fixture.command("list-clients").stdout == b""
            fixture.command("send-keys", "-t", "%0", "-l", "present-value")
            result = subprocess.run([str(runtime / "_build/default/native_wait.exe"),
                                     fixture.binary, str(fixture.socket), "present-value"],
                                    cwd=runtime, env=environment, capture_output=True, timeout=1, check=True)
            assert result.stdout == b"%0\n" and result.stderr == b"", result
            assert fixture.command("list-clients").stdout == b""
    print(f"installed Eio native capture example: PASS on {len(binaries)} releases")
    print(f"installed Unix/Eio generated conveniences: PASS on {len(binaries)} releases")
    print(f"installed rendered-wait example: PASS on {len(binaries)} releases")
