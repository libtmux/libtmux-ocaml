open Libtmux
module C = Libtmux_unix.Client
module S = Libtmux_unix.Subscription

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

(* Close each subscription as soon as its first bytes arrive, while the pane
   is still echoing the rest of the line. *)
let () =
  let binary = Sys.argv.(1)
  and endpoint = Endpoint.socket_path Sys.argv.(2)
  and rounds = int_of_string Sys.argv.(3) in
  let client = get (C.connect ~binary endpoint) in
  Fun.protect
    ~finally:(fun () -> ignore (get (C.close client)))
    (fun () ->
      let pane = Iarray.get (Snapshot.panes (get (C.capture client))) 0 in
      for _ = 1 to rounds do
        let sub = get (C.subscribe client pane) in
        get (C.send_text client (Pane.target pane) ~text:"after-gap");
        get (C.send_keys client (Pane.target pane) [ Key.Enter ]);
        (match get (S.next ~timeout:1. sub) with
        | Some (Output.Data _) -> ()
        | _ -> failwith "no output before close");
        get (S.close sub)
      done;
      print_endline "PASS subscriptions closed mid-output")
