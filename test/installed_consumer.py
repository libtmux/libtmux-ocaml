"""Outer: install a package and execute a consumer outside its source tree."""

import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
from support.tmux_fixture import TmuxFixture
from support import readme_walkthrough


root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root))
from tools.docs_snippets import snippet
with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-consumer-") as directory:
    temporary = Path(directory)
    prefix = temporary / "installed"
    packages = ["libtmux", "libtmux-workspace", "libtmux-json", "libtmux-unix", "libtmux-eio"]
    subprocess.run(["dune", "install", "--prefix", str(prefix), *packages], cwd=root, check=True)
    consumer = temporary / "consumer"
    consumer.mkdir()
    (consumer / "dune-project").write_text("(lang dune 3.24)\n")
    (consumer / "dune").write_text("(executable (name main) (libraries libtmux libtmux-json))\n")
    (consumer / "model_fixture.ml").write_text((root / "test/model_fixture.ml").read_text())
    examples = [snippet(f"examples/native_query.ml#{region}")
                for region in ["native-filter", "typed-filter", "relationship-filter"]]
    examples.append(snippet("examples/native_recovery.ml#preserve-primary"))
    (consumer / "main.ml").write_text("open Libtmux\n" + "\n".join(examples) + '''
let () =
  assert (try ignore (protect ~finally:(fun () -> raise Exit)
      (fun () -> failwith "retained primary")); false
    with Failure message when message = "retained primary" -> true);
  assert (try ignore (protect ~finally:(fun () -> raise Exit) (fun () -> ())); false
    with Exit -> true);
  let endpoint = Endpoint.named_socket "installed-consumer" in
  assert (Endpoint.equal endpoint (Endpoint.named_socket "installed-consumer"));
  assert (Query.exactly_one (List.to_seq [42]) = Ok 42);
  assert (Query.exactly_one (List.to_seq [42; 42]) =
          Error (Cardinality.Multiple_matches {at_least = 2}));
  let snapshot = Model_fixture.snapshot () in
  assert (List.map Pane.Id.to_string (roomy_ids snapshot) = ["%1"]);
  assert (List.map Pane.Id.to_string (active_ids snapshot) = ["%1"]);
  assert (sessions_with_room snapshot = ["work"; "also-work"]);
  let wire = match Libtmux_json.Expr.to_string Model.pane roomy_terminals with
    | Ok value -> value
    | Error error -> failwith (Format.asprintf "%a" Libtmux_json.Decode_error.pp error) in
  let decoded = match Libtmux_json.Expr.of_string Model.pane wire with
    | Ok value -> value
    | Error error -> failwith (Format.asprintf "%a" Libtmux_json.Decode_error.pp error) in
  assert (Expr.compile decoded (Iarray.get (Snapshot.panes snapshot) 0));
  let workspace = match Libtmux_json.Workspace.of_string ~directory:"/srv/project"
      {|{"schema":"libtmux.workspace/1","session":"project","windows":[{"name":"editor","panes":[{"exec":["nvim"],"cwd":"src"}]}]}|} with
    | Ok config -> config
    | Error error -> failwith (Format.asprintf "%a" Libtmux_json.Decode_error.pp error) in
  assert (Libtmux_workspace.Config.session workspace = "project");
  let window = Iarray.get (Libtmux_workspace.Config.windows workspace) 0 in
  assert ((List.hd window.panes).spawn.cwd = Some "/srv/project/src");
  print_endline "installed core/JSON consumer and README examples: PASS"
''')
    environment = dict(os.environ, OCAMLPATH=str(prefix / "lib"))
    activation = next(block[2:].strip() for block in re.findall(r"```console\n(.*?)```", (root / "README.md").read_text(), re.DOTALL)
                      if block.startswith('$ eval "$(opam env'))
    switch = subprocess.check_output(["/bin/sh", "-c", activation + '\nprintf "%s" "$OPAMSWITCH"'],
                                     cwd=root, env=environment, text=True).strip()
    assert switch, "README switch activation did not export OPAMSWITCH"
    environment["OPAMSWITCH"] = switch
    for key in ("DUNE_SOURCEROOT", "DUNE_WORKSPACE"):
        environment.pop(key, None)
    for package in packages:
        resolved = subprocess.check_output(["ocamlfind", "query", package], env=environment, text=True).strip()
        assert Path(resolved) == prefix / "lib" / package
    subprocess.run(["dune", "exec", "--root", str(consumer), "--no-print-directory", "./main.exe"],
                   cwd=consumer, env=environment, check=True)
    package_examples = temporary / "package-readmes"
    package_examples.mkdir()
    (package_examples / "dune-project").write_text("(lang dune 3.24)\n")
    for package, name in [("lib", "query_description"), ("json", "query_json"),
                          ("unix", "native_graph"), ("eio", "native_watch")]:
        project = package_examples / package
        project.mkdir()
        readme = (root / package / "README.md").read_text()
        stanza, = re.findall(r"```dune\n(.*?)```", readme, re.DOTALL)
        (project / "dune").write_text(stanza)
        (project / f"{name}.ml").write_text(snippet(f"examples/{name}.ml"))
    subprocess.run(["dune", "build", "--root", str(package_examples)], cwd=package_examples,
                   env=environment, check=True)
    expected = {
        "lib/query_description": b'all [pane_active = true; pane_current_command in ["nvim"; "vim"]; pane_width >= 120]\nambiguous: at least 2 entries\n',
        "json/query_json": b'{"schema":"libtmux.filter/1","model":"pane","expr":{"node":"compare","field":"pane_current_command","op":"starts_with","value":"nv"}}\ninvalid operand at /expr/value\n',
    }
    for program, output in expected.items():
        result = subprocess.run([str(package_examples / "_build/default" / f"{program}.exe")],
                                env=environment, capture_output=True, check=True, timeout=1)
        assert result.stdout == output and result.stderr == b"", result
    print("installed package README Dune files and pure examples: PASS")
    runtime = temporary / "runtime"
    runtime.mkdir()
    (runtime / "dune-project").write_text("(lang dune 3.24)\n")
    (runtime / "dune").write_text('''
(executable (name native_capture) (modules native_capture) (libraries libtmux libtmux-eio eio_main))
(executable (name native_wait) (modules native_wait) (libraries libtmux libtmux-eio eio_main))
(executables (names native_graph native_query native_build) (modules native_graph native_query native_build) (libraries libtmux libtmux-unix))
(executable (name native_watch) (modules native_watch) (libraries libtmux libtmux-eio eio_main))
(executable (name native_recovery) (modules native_recovery) (libraries libtmux libtmux-eio eio_main))
(executable (name configuration_unix) (modules configuration_unix) (libraries libtmux libtmux-workspace libtmux-json libtmux-unix yojson))
(executable (name configuration_eio) (modules configuration_eio) (libraries libtmux libtmux-workspace libtmux-json libtmux-eio yojson eio_main))
''')
    (runtime / "native_capture.ml").write_bytes((root / "examples/native_capture.ml").read_bytes())
    (runtime / "native_wait.ml").write_bytes((root / "examples/native_wait.ml").read_bytes())
    for name in ["native_graph", "native_query", "native_build", "native_watch", "native_recovery"]:
        (runtime / f"{name}.ml").write_bytes((root / "examples" / f"{name}.ml").read_bytes())
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
  get (C.unset_environment client Global "LIBTMUX_CONVENIENCE");
  let module Config = Libtmux_workspace.Config in
  let config = match Config.make ~directory:"/tmp" ~session:"installed-workspace"
      [Config.window ~name:"editor" [Config.pane ~spawn:(Spawn.make (Shell "exec cat")) ()]] with
    | Ok value -> value
    | Error error -> failwith (Format.asprintf "%a" Config.pp_error error) in
  let observed = get (C.capture client) in
  let plan = match Libtmux_workspace.Plan.make ~endpoint:(Source.endpoint (C.source client))
      ~version:(C.version client) ~observed:(Some observed) config with
    | Ok value -> value
    | Error error -> failwith (Format.asprintf "%a" Libtmux_workspace.Plan.pp_error error) in
  let operation = get (W.submit client plan) in
  assert ((get (W.inspect operation)).status = Libtmux_workspace.Execution.Queued);
  let receipt = get (W.await operation) in
  assert (receipt.status = Libtmux_workspace.Execution.Succeeded);
  let encoded = Result.get_ok (Libtmux_json.Workspace.encode_receipt receipt) in
  assert (Yojson.Safe.Util.(member "schema" encoded |> to_string) = "libtmux.workspace-receipt/1");
  get (W.close operation);
  let created = get (C.capture client) |> Snapshot.sessions
    |> Iarray.find_opt (fun session -> Session.name session = "installed-workspace") |> Option.get in
  get (C.run client (Operations.kill_session (Session.target created)))
'''
    for backend in ["unix", "eio"]:
        module = f"open Libtmux\nmodule C = Libtmux_{backend}.Client\nmodule W = Libtmux_{backend}.Workspace\n"
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
    walkthrough = readme_walkthrough.prepare(root, temporary, environment)
    binaries = sys.argv[1:] or [root / f"scratch/tmux/tmux-{version}/tmux" for version in ["3.3", "3.3a", "3.4", "3.8"]]
    for binary in binaries:
        for document in ("unix/README.md", "eio/README.md"):
            readme_walkthrough.run(root, walkthrough, binary, environment, document)
        with TmuxFixture(binary) as fixture:
            result = subprocess.run([str(runtime / "_build/default/native_capture.exe"),
                                     fixture.binary, str(fixture.socket)],
                                    cwd=runtime, env=environment, capture_output=True, timeout=1, check=True)
            assert result.stdout == b"%0\n" and result.stderr == b"", result
            for backend in ["unix", "eio"]:
                with TmuxFixture(binary) as configuration:
                    result = subprocess.run([str(runtime / f"_build/default/configuration_{backend}.exe"),
                                             configuration.binary, str(configuration.socket)],
                                            cwd=runtime, env=environment, capture_output=True, timeout=1, check=True)
                    assert result.stdout == b"" and result.stderr == b"", result
                    assert configuration.command("list-clients").stdout == b""
                    assert configuration.command("list-panes", "-a", "-F", "#{pane_id}").stdout == b"%0\n"
            assert fixture.command("list-clients").stdout == b""
            fixture.command("send-keys", "-t", "%0", "-l", "present-value")
            result = subprocess.run([str(runtime / "_build/default/native_wait.exe"),
                                     fixture.binary, str(fixture.socket), "present-value"],
                                    cwd=runtime, env=environment, capture_output=True, timeout=1, check=True)
            assert result.stdout == b"%0\n" and result.stderr == b"", result
            assert fixture.command("list-clients").stdout == b""
            fixture.command("rename-window", "-t", "@0", "editor")
            fixture.command("resize-window", "-t", "@0", "-x", "160", "-y", "40")
            fixture.command("new-session", "-d", "-s", "linked", "exec cat")
            fixture.command("link-window", "-d", "-s", "@0", "-t", "$1:7")
            fixture.track_panes()
            def run_example(name, *arguments):
                return subprocess.run([str(runtime / f"_build/default/{name}.exe"),
                                       fixture.binary, str(fixture.socket), *arguments],
                                      cwd=runtime, env=environment, capture_output=True, timeout=1, check=True)
            result = run_example("native_graph")
            assert result.stderr == b"", result
            graph = result.stdout.decode()
            assert graph.count('window @0 at ') == 2, graph
            assert 'window @0 at 7 "editor"' in graph, graph
            assert graph.count('pane %0 active=true 160x40 "cat"') == 2, graph
            result = run_example("native_query")
            assert result.stdout == b"active=%0,%1\nroomy=%0,%1\nsessions=fixture,linked\n" and result.stderr == b"", result
            literal = "ready #{pane_id}; $HOME is literal"
            result = run_example("native_watch", "%0", literal)
            assert re.fullmatch(rb"future_match_offset=[1-9][0-9]*\nrendered_pane=%0\n", result.stdout), result
            assert result.stderr == b"", result
            assert fixture.command("list-clients").stdout == b""
            before_recovery = fixture.command("list-panes", "-a", "-F", "#{pane_id}:#{window_id}:#{window_name}").stdout
            result = run_example("native_recovery", "$0")
            assert result.stdout == (b"waiter=cancelled; operation=retained\n"
                                     b"operation=finished; postcondition=recovery-complete\n"
                                     b"cleanup-issues=0; omitted=0\n"), result
            assert result.stderr == b"", result
            assert fixture.command("list-clients").stdout == b""
            assert fixture.command("list-panes", "-a", "-F", "#{pane_id}:#{window_id}:#{window_name}").stdout == before_recovery
            result = run_example("native_build", "project", fixture.directory.name)
            created = dict(line.split("=", 1) for line in result.stdout.decode().splitlines())
            assert set(created) == {"session", "editor", "right", "logs"}, created
            fixture.track_panes()
            rows = fixture.command("list-windows", "-t", created["session"], "-F", "#{window_name}:#{window_panes}").stdout
            assert rows == b"editor:2\nlogs:1\n", rows
            value = fixture.command("show-options", "-t", created["session"], "-v", "@project").stdout
            assert value == b"project\n", value
            title = fixture.command("display-message", "-p", "-t", created["right"], "#{pane_title}").stdout
            assert title == b"build output\n", title
            paths = fixture.command("list-panes", "-s", "-t", created["session"], "-F", "#{pane_current_path}").stdout.splitlines()
            assert paths == [fixture.directory.name.encode()] * 3, paths
            assert fixture.command("list-clients").stdout == b""
        readme_walkthrough.run(root, walkthrough, binary, environment)
        readme_walkthrough.run(root, walkthrough, binary, environment, "docs/recovery.md")
    print(f"installed Eio native capture example: PASS on {len(binaries)} releases")
    print(f"installed Unix/Eio generated conveniences: PASS on {len(binaries)} releases")
    print(f"installed rendered-wait example: PASS on {len(binaries)} releases")
    print(f"installed graph/query/build/Eio-stream examples: PASS on {len(binaries)} releases")
    print(f"installed cancellation/recovery example and preserved panes: PASS on {len(binaries)} releases")
