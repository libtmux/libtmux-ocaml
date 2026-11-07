open Libtmux
open Runtime_io
module P = Libtmux__Protocol
module Names = Set.Make (String)

let decode ~dialect body =
  P.protect (fun () ->
      let body =
        match dialect with
        | P.Metadata.Raw -> body
        | Visual -> P.Metadata.unvis ~quoted:"" body
      in
      let length = String.length body and position = ref 0 in
      let expect text =
        if String.length text > length - !position then
          P.malformed "truncated environment record";
        String.iteri
          (fun offset c ->
            if body.[!position + offset] <> c then
              P.malformed "invalid environment record")
          text;
        position := !position + String.length text
      in
      let name () =
        let start = !position in
        let initial = function
          | 'a' .. 'z' | 'A' .. 'Z' | '_' -> true
          | _ -> false
        in
        if !position = length || not (initial body.[!position]) then
          P.malformed "environment name is not an ASCII identifier";
        while
          !position < length
          && (initial body.[!position]
             || (body.[!position] >= '0' && body.[!position] <= '9'))
        do
          incr position;
          if !position - start > 65_536 then
            P.limit "environment name exceeds 64 KiB"
        done;
        String.sub body start (!position - start)
      in
      let value () =
        let bytes = Buffer.create 64 in
        let append c =
          if c = '\000' then P.malformed "NUL in environment value";
          if Buffer.length bytes = 65_536 then
            P.limit "environment value exceeds 64 KiB";
          Buffer.add_char bytes c
        in
        let rec read () =
          if !position = length then
            P.malformed "unterminated environment value";
          let c = body.[!position] in
          incr position;
          match c with
          | '"' -> Buffer.contents bytes
          | '\\' ->
              if !position = length then
                P.malformed "truncated environment escape";
              let c = body.[!position] in
              incr position;
              if not (String.contains "$`\"\\" c) then
                P.malformed "invalid environment escape";
              append c;
              read ()
          | c ->
              append c;
              read ()
        in
        read ()
      in
      let rec rows seen count entries =
        if !position = length then Iarray.of_list (List.rev entries)
        else (
          if count = 10_000 then P.limit "environment exceeds 10000 entries";
          let removed =
            length - !position >= 6 && String.sub body !position 6 = "unset "
          in
          if removed then expect "unset ";
          let name = name () in
          if Names.mem name seen then
            P.malformed "duplicate environment variable";
          let value =
            if removed then (
              expect ";\n";
              Environment.Removed)
            else (
              expect "=\"";
              let value = value () in
              expect "; export ";
              expect name;
              expect ";\n";
              Environment.Value value)
          in
          rows (Names.add name seen) (count + 1)
            (Environment.{ name; value } :: entries))
      in
      rows Names.empty 0 [])

let capture c scope hidden arguments =
  let started_at_ns = Linux.monotonic_ns () in
  Read_process.run c "show-environment" arguments (fun body ->
      let entries = protocol (decode ~dialect:c.Connection.dialect body) in
      Environment.
        {
          source = c.source;
          scope;
          hidden;
          entries;
          started_at_ns;
          finished_at_ns = Linux.monotonic_ns ();
        })
