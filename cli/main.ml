open Cmdliner

let file =
  Arg.(
    required
    & pos 0 (some string) None
    & info [] ~docv:"FILE"
        ~doc:
          "Versioned JSON workspace document. Relative directories resolve \
           against its directory.")

let json =
  Arg.(
    value & flag
    & info [ "json" ]
        ~doc:
          "Write one versioned JSON result to stdout. Default: human-readable \
           output.")

let socket =
  Arg.(
    value
    & opt (some string) None
    & info [ "socket" ] ~docv:"PATH"
        ~doc:
          "Explicit tmux socket path. Required for plan and apply; relative \
           paths use the current directory.")

let binary =
  Arg.(
    value & opt string "tmux"
    & info [ "tmux" ] ~docv:"PROGRAM"
        ~doc:
          "tmux executable. Default: tmux from PATH. Version discovery does \
           not start a daemon.")

let timeout =
  Arg.(
    value & opt float 1.
    & info [ "timeout" ] ~docv:"SECONDS"
        ~doc:
          "Positive timeout per control exchange or local version check. \
           Default: 1 second.")

let require_existing =
  Arg.(
    value & flag
    & info [ "require-existing" ]
        ~doc:
          "Reject a missing endpoint instead of bootstrapping it. Default: \
           create the requested session if missing.")

let append =
  Arg.(
    value & flag
    & info [ "append" ]
        ~doc:
          "Add new windows to an existing session, rejecting requested \
           window-name collisions. Default: reject an existing session.")

let keep_partial =
  Arg.(
    value & flag
    & info [ "keep-partial" ]
        ~doc:
          "Retain proven creations after a failed or interrupted apply. \
           Default: compensate only proven newly created panes.")

let expect_document =
  Arg.(
    value
    & opt (some string) None
    & info [ "expect-document" ] ~docv:"DIGEST"
        ~doc:
          "Require the document_digest returned by a prior check or plan. \
           Default: accept the document read for this invocation.")

let exits =
  List.map
    (fun (code, doc) -> Cmd.Exit.info code ~doc)
    [
      (0, "Validation, planning or apply succeeded.");
      (2, "Invalid arguments or workspace document.");
      (3, "A required endpoint is missing.");
      (4, "A collision, changed document or stale plan.");
      (5, "Partial or uncertain apply; inspect its receipt.");
      (6, "Transport, capability or result-delivery failure.");
      (130, "Interrupted; any available journal is emitted.");
    ]

let term command =
  let run json file socket binary timeout require_existing append keep_partial
      expect_document =
    Runtime.run ~command ~json ~file ~socket ~binary ~timeout ~require_existing
      ~append ~keep_partial ~expect_document
  in
  if command = `Check then
    Term.(
      const (fun json file expected ->
          run json file None "tmux" 1. false false false expected)
      $ json $ file $ expect_document)
  else
    let keep_partial =
      if command = `Apply then keep_partial else Term.const false
    in
    Term.(
      const run $ json $ file $ socket $ binary $ timeout $ require_existing
      $ append $ keep_partial $ expect_document)

let command name mode doc = Cmd.v (Cmd.info name ~doc ~exits) (term mode)

let main =
  let man =
    [
      `S Manpage.s_description;
      `P
        "Validate, preview and apply libtmux.workspace/1 documents. check \
         performs no tmux I/O; plan observes without starting a daemon; apply \
         makes and rechecks a fresh plan.";
      `P
        "Previews are advisory and cannot be supplied as executable targets. \
         Cancellation does not undo admitted commands. Inspect completed, \
         uncertain and cleanup outcomes before recovery.";
      `P
        "Connections require Linux pidfds, the daemon's PID namespace and a \
         shared filesystem. Closing a client never stops its daemon. No \
         implicit reconnect or mutation retry occurs.";
      `S Manpage.s_examples;
      `P "tmux-workspace check project.json";
      `P "tmux-workspace plan --socket /tmp/project.sock --json project.json";
      `P "tmux-workspace apply --socket /tmp/project.sock --json project.json";
      `S Manpage.s_bugs;
      `P "Report issues at https://github.com/libtmux/libtmux-ocaml/issues.";
    ]
  in
  Cmd.group
    (Cmd.info "tmux-workspace" ~version:"unreleased"
       ~doc:"Validate, preview and apply native JSON tmux workspaces" ~man
       ~exits)
    [
      command "check" `Check "Validate a workspace without contacting tmux";
      command "plan" `Plan "Observe an endpoint and print an advisory plan";
      command "apply" `Apply "Apply a fresh plan and report every step outcome";
    ]

let () =
  let code = Cmd.eval' ~catch:false ~term_err:2 main in
  exit (if code = Cmd.Exit.cli_error then 2 else code)
