module P = Libtmux__Protocol

let get = function
  | Ok value -> value
  | Error (P.Malformed message | P.Limit message) -> failwith message

let hex value =
  String.concat ""
    (List.init (String.length value) (fun i ->
         Printf.sprintf "%02x" (Char.code value.[i])))

let event = function
  | P.Notification text ->
      `Assoc [ ("kind", `String "notification"); ("hex", `String (hex text)) ]
  | P.Diagnostic text ->
      `Assoc [ ("kind", `String "diagnostic"); ("hex", `String (hex text)) ]
  | P.Frame frame ->
      `Assoc
        [
          ("kind", `String "frame");
          ("ok", `Bool frame.ok);
          ("hex", `String (hex frame.body));
        ]

let () =
  match Array.to_list Sys.argv |> List.tl with
  | "quote" :: [ value ] -> print_string (get (P.Command.quoted_argument value))
  | "argv" :: [ value ] -> print_string (get (P.Command.argv_argument value))
  | "render" :: name :: arguments ->
      print_string (get (P.Command.render name arguments))
  | "format" :: fields -> print_string (get (P.Metadata.format fields))
  | [ "metadata"; count; dialect ] ->
      let dialect =
        match dialect with
        | "raw" -> P.Metadata.Raw
        | "visual" -> P.Metadata.Visual
        | _ -> failwith "invalid dialect"
      in
      let rows =
        get
          (P.Metadata.decode ~dialect ~fields:(int_of_string count)
             (In_channel.input_all stdin))
      in
      let json =
        `List
          (Iarray.to_list
             (Iarray.map
                (fun row ->
                  `List
                    (Iarray.to_list
                       (Iarray.map (fun value -> `String (hex value)) row)))
                rows))
      in
      Yojson.Safe.to_channel stdout json;
      print_newline ()
  | [ "detect-print" ] ->
      print_string
        (match get (P.Metadata.detect_print (In_channel.input_all stdin)) with
        | Raw -> "raw"
        | Visual -> "visual")
  | [ "frames"; chunk ] ->
      let state = P.Framer.create () in
      let input = Bytes.create (int_of_string chunk) in
      let rec loop () =
        let count = Unix.read Unix.stdin input 0 (Bytes.length input) in
        if count = 0 then get (P.Framer.finish state)
        else
          let events =
            get (P.Framer.feed state (Bytes.sub_string input 0 count))
          in
          List.iter
            (fun value ->
              Yojson.Safe.to_channel stdout (event value);
              print_newline ())
            events;
          loop ()
      in
      loop ()
  | _ -> failwith "invalid codec peer invocation"
