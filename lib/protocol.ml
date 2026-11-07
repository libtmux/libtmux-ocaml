type error = Malformed of string | Limit of string

exception Invalid of error

let malformed message = raise (Invalid (Malformed message))
let limit message = raise (Invalid (Limit message))
let protect f = try Ok (f ()) with Invalid error -> Error error

module Version = struct
  type t = { major : int; minor : int; patch : string }

  let parse value =
    protect (fun () ->
        let value =
          if String.starts_with ~prefix:"tmux " value then
            String.drop_first 5 value
          else value
        in
        let number part =
          if
            part = ""
            || not (String.for_all (fun c -> c >= '0' && c <= '9') part)
          then malformed "invalid tmux version";
          match int_of_string_opt part with
          | Some value -> value
          | None -> malformed "invalid tmux version"
        in
        match String.split_on_char '.' value with
        | [ major; rest ] ->
            let digits, patch =
              String.cut_first_while (fun c -> c >= '0' && c <= '9') rest
            in
            if not (String.for_all (fun c -> c >= 'a' && c <= 'z') patch) then
              malformed "invalid tmux version suffix";
            { major = number major; minor = number digits; patch }
        | _ -> malformed "invalid tmux version")

  let supported value = value.major > 3 || (value.major = 3 && value.minor >= 3)

  let to_string value =
    Printf.sprintf "%d.%d%s" value.major value.minor value.patch
end

module Command = struct
  let check value =
    if String.contains value '\000' then
      malformed "NUL cannot occur in a tmux argument"

  let argv_argument value =
    protect (fun () ->
        check value;
        if String.ends_with ~suffix:";" value then
          String.drop_last 1 value ^ "\\;"
        else value)

  let quoted_argument ?(max_bytes = 1_048_576) value =
    protect (fun () ->
        check value;
        if max_bytes <= 0 then limit "encoded command exceeds byte limit";
        let output = Buffer.create (min 256 max_bytes) in
        let add_char char =
          if Buffer.length output >= max_bytes then
            limit "encoded command exceeds byte limit";
          Buffer.add_char output char
        in
        let add text =
          if String.length text > max_bytes - Buffer.length output then
            limit "encoded command exceeds byte limit";
          Buffer.add_string output text
        in
        add "'";
        String.iter
          (function
            | '\'' -> add "'\\''"
            | '\n' -> add "'\"\\n\"'"
            | '\r' -> add "'\"\\r\"'"
            | char when Char.code char < 32 || Char.code char >= 127 ->
                (* tmux 3.3's string lexer can confuse a signed 0xff with EOF. *)
                add (Printf.sprintf "'\"\\%03o\"'" (Char.code char))
            | char -> add_char char)
          value;
        add "'";
        Buffer.contents output)

  let render ?(max_bytes = 1_048_576) name arguments =
    protect (fun () ->
        if
          name = ""
          || not
               (String.for_all
                  (fun c -> (c >= 'a' && c <= 'z') || c = '-')
                  name)
        then malformed "invalid command name";
        if max_bytes <= 0 then limit "encoded command exceeds byte limit";
        let output = Buffer.create (min 256 max_bytes) in
        if String.length name > max_bytes then
          limit "encoded command exceeds byte limit";
        Buffer.add_string output name;
        List.iter
          (fun argument ->
            if Buffer.length output >= max_bytes then
              limit "encoded command exceeds byte limit";
            Buffer.add_char output ' ';
            match
              quoted_argument
                ~max_bytes:(max_bytes - Buffer.length output)
                argument
            with
            | Ok value -> Buffer.add_string output value
            | Error error -> raise (Invalid error))
          arguments;
        Buffer.contents output)

  let format_literal value =
    protect (fun () ->
        check value;
        if String.exists (fun c -> String.contains "#,:{}\r\n" c) value then
          malformed "literal requires unqualified tmux format escaping";
        value)
end

module Metadata = struct
  type dialect = Raw | Visual

  let detect_print = function
    | "libtmux\rprobe\n" -> Ok Raw
    | "libtmux\\rprobe\n" -> Ok Visual
    | _ -> Error (Malformed "unrecognized tmux print encoding")

  let escaped = "|&;<>(){}$`\\\"'*?[# =%\n\t"
  let always_escaped = "&;<>()$`\"'*?[# %"

  let format fields =
    protect (fun () ->
        if fields = [] then malformed "metadata requires at least one field";
        List.iter
          (fun field ->
            if
              field = ""
              || not
                   (String.for_all
                      (fun c ->
                        (c >= 'a' && c <= 'z')
                        || (c >= 'A' && c <= 'Z')
                        || (c >= '0' && c <= '9')
                        || String.contains "_@.-" c)
                      field)
            then malformed "invalid metadata field identifier")
          fields;
        String.concat "|" (List.map (fun field -> "#{q:" ^ field ^ "}") fields)
        ^ "=")

  let unvis ?(quoted = escaped) bytes =
    let result = Buffer.create (String.length bytes) in
    let length = String.length bytes in
    let variable c =
      (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_' || c = '{'
    in
    let octal c = c >= '0' && c <= '7' in
    let append_quoted c =
      if c = '\000' then malformed "NUL in visual metadata";
      if String.contains quoted c then Buffer.add_char result '\\';
      Buffer.add_char result c
    in
    let rec loop i =
      if i < length then
        if bytes.[i] <> '\\' then (
          Buffer.add_char result bytes.[i];
          loop (i + 1))
        else if i + 1 >= length then
          malformed "truncated visual metadata escape"
        else if bytes.[i + 1] = '\\' then
          if i + 3 < length && bytes.[i + 2] = '$' && variable bytes.[i + 3]
          then (
            Buffer.add_string result "\\$";
            loop (i + 3))
          else (
            Buffer.add_string result "\\\\";
            loop (i + 2))
        else if octal bytes.[i + 1] then (
          if i + 3 >= length || not (octal bytes.[i + 2] && octal bytes.[i + 3])
          then malformed "invalid visual octal escape";
          let digit j = Char.code bytes.[i + j] - Char.code '0' in
          let value = (digit 1 * 64) + (digit 2 * 8) + digit 3 in
          if value > 255 then malformed "visual escape exceeds one byte";
          append_quoted (Char.chr value);
          loop (i + 4))
        else
          match bytes.[i + 1] with
          | 'a' ->
              append_quoted '\007';
              loop (i + 2)
          | 'b' ->
              append_quoted '\b';
              loop (i + 2)
          | 'f' ->
              append_quoted '\012';
              loop (i + 2)
          | 'r' ->
              append_quoted '\r';
              loop (i + 2)
          | 'v' ->
              append_quoted '\011';
              loop (i + 2)
          | 'n' ->
              append_quoted '\n';
              loop (i + 2)
          | 't' ->
              append_quoted '\t';
              loop (i + 2)
          | 's' ->
              append_quoted ' ';
              loop (i + 2)
          | c ->
              Buffer.add_char result '\\';
              Buffer.add_char result c;
              loop (i + 2)
    in
    loop 0;
    Buffer.contents result

  let decode ?(dialect = Raw) ?(max_field = 65_536) ?(max_rows = 10_000) ~fields
      bytes =
    protect (fun () ->
        let bytes = match dialect with Raw -> bytes | Visual -> unvis bytes in
        if fields <= 0 || max_field <= 0 || max_rows <= 0 then
          malformed "invalid metadata limits";
        let rows = ref []
        and row = ref []
        and count = ref 0
        and rows_count = ref 0 in
        let field = Buffer.create 64 in
        let escaping = ref false and awaiting_newline = ref false in
        let append char =
          if Buffer.length field >= max_field then
            limit "metadata field exceeds byte limit";
          Buffer.add_char field char
        in
        let end_field () =
          incr count;
          row := Buffer.contents field :: !row;
          Buffer.clear field
        in
        String.iter
          (fun char ->
            if !awaiting_newline then (
              if char <> '\n' then
                malformed "metadata row has no newline terminator";
              awaiting_newline := false;
              incr rows_count;
              if !rows_count > max_rows then
                limit "metadata row count exceeds limit";
              rows := Iarray.of_list (List.rev !row) :: !rows;
              row := [];
              count := 0)
            else if !escaping then (
              if not (String.contains escaped char) then
                malformed "invalid metadata escape";
              escaping := false;
              append char)
            else
              match char with
              | '\000' -> malformed "NUL in metadata"
              | '\\' -> escaping := true
              | '|' ->
                  end_field ();
                  if !count >= fields then malformed "too many metadata fields"
              | '=' ->
                  end_field ();
                  if !count <> fields then
                    malformed "wrong metadata field count";
                  awaiting_newline := true
              | char when String.contains always_escaped char ->
                  malformed "unquoted metadata byte"
              | char -> append char)
          bytes;
        if
          !escaping || !awaiting_newline || !count <> 0
          || Buffer.length field <> 0
        then malformed "truncated metadata row";
        Iarray.of_list (List.rev !rows))
end

type guard = { time : int64; number : int64; flags : int }
type frame = { guard : guard; ok : bool; body : string }
type event = Frame of frame | Notification of string | Diagnostic of string

module Framer = struct
  type t = {
    max_frame : int;
    line : Buffer.t;
    body : Buffer.t;
    mutable guard : guard option;
    mutable failure : error option;
  }

  let create ?(max_frame = 4 * 1024 * 1024) () =
    if max_frame <= 0 then invalid_arg "Framer.create";
    {
      max_frame;
      line = Buffer.create 256;
      body = Buffer.create 256;
      guard = None;
      failure = None;
    }

  let retained_bytes value = Buffer.length value.line + Buffer.length value.body

  let guard line =
    let positive text =
      match Int64.of_string_opt text with
      | Some value
        when value >= 0L && String.for_all (fun c -> c >= '0' && c <= '9') text
        ->
          value
      | _ -> malformed "invalid control guard"
    in
    match String.split_on_char ' ' line with
    | [ _; time; number; flags ] ->
        let flags = positive flags in
        if flags > Int64.of_int max_int then malformed "control flags overflow";
        {
          time = positive time;
          number = positive number;
          flags = Int64.to_int flags;
        }
    | _ -> malformed "invalid control guard"

  let complete_line state line =
    if String.starts_with ~prefix:"%begin " line then (
      if Option.is_some state.guard then malformed "nested control frame";
      state.guard <- Some (guard line);
      None)
    else if
      String.starts_with ~prefix:"%end " line
      || String.starts_with ~prefix:"%error " line
    then
      let ending = guard line in
      match state.guard with
      | Some started when started = ending ->
          let frame =
            {
              guard = started;
              ok = String.starts_with ~prefix:"%end " line;
              body = Buffer.contents state.body;
            }
          in
          Buffer.clear state.body;
          state.guard <- None;
          Some (Frame frame)
      | _ -> malformed "control guard mismatch"
    else
      match state.guard with
      | Some _ ->
          if String.starts_with ~prefix:"%" line then
            malformed "unclassified control data inside frame";
          if Buffer.length state.body + String.length line + 1 > state.max_frame
          then limit "control frame exceeds byte limit";
          Buffer.add_string state.body line;
          Buffer.add_char state.body '\n';
          None
      | None ->
          Some
            (if String.starts_with ~prefix:"%" line then Notification line
             else Diagnostic line)

  let feed state bytes =
    match state.failure with
    | Some error -> Error error
    | None ->
        let result =
          protect (fun () ->
              if String.length bytes > 65_536 then
                limit "control read chunk exceeds 64 KiB";
              let events = ref [] in
              String.iter
                (fun char ->
                  if char = '\n' then (
                    let line = Buffer.contents state.line in
                    Buffer.clear state.line;
                    Option.iter
                      (fun event -> events := event :: !events)
                      (complete_line state line))
                  else (
                    if retained_bytes state >= state.max_frame then
                      limit "control frame exceeds byte limit";
                    Buffer.add_char state.line char))
                bytes;
              List.rev !events)
        in
        (match result with
        | Error error -> state.failure <- Some error
        | Ok _ -> ());
        result

  let finish state =
    match state.failure with
    | Some error -> Error error
    | None when Buffer.length state.line <> 0 || Option.is_some state.guard ->
        Error (Malformed "truncated control stream")
    | None -> Ok ()
end

module Output = struct
  let decode bytes =
    protect (fun () ->
        let output = Buffer.create (String.length bytes) in
        let rec loop index =
          if index < String.length bytes then
            if bytes.[index] <> '\\' then (
              Buffer.add_char output bytes.[index];
              loop (index + 1))
            else (
              if index + 3 >= String.length bytes then
                malformed "truncated output escape";
              let digit offset =
                let char = bytes.[index + offset] in
                if char < '0' || char > '7' then
                  malformed "invalid output escape";
                Char.code char - Char.code '0'
              in
              let value = (digit 1 * 64) + (digit 2 * 8) + digit 3 in
              if value > 255 then malformed "output escape exceeds one byte";
              Buffer.add_char output (Char.chr value);
              loop (index + 4))
        in
        loop 0;
        Buffer.contents output)
end

module Group = struct
  type reply = Succeeded of string | Failed of string | Skipped

  type receipt = {
    replies : reply Iarray.t;
    callbacks : frame Iarray.t;
    diagnostics : string list;
  }

  type t = {
    marker : string;
    count : int;
    mutable replies : reply list;
    mutable received : int;
    mutable failed : bool;
    mutable diagnostics : string list;
    mutable completed : bool;
    mutable bytes : int;
    mutable diagnostic_count : int;
    mutable callbacks : frame list;
    mutable callback_count : int;
  }

  let create ~marker ~count =
    if count <= 0 || count > 64 || marker = "" || String.contains marker '\n'
    then invalid_arg "Group.create";
    {
      marker;
      count;
      replies = [];
      received = 0;
      failed = false;
      diagnostics = [];
      completed = false;
      bytes = 0;
      diagnostic_count = 0;
      callbacks = [];
      callback_count = 0;
    }

  let accept state event =
    protect (fun () ->
        if state.completed then malformed "group already completed";
        let retained =
          match event with
          | Notification _ -> 0
          | Frame frame -> String.length frame.body
          | Diagnostic text -> String.length text
        in
        if state.bytes + retained > 4 * 1024 * 1024 then
          limit "command group exceeds 4 MiB";
        state.bytes <- state.bytes + retained;
        match event with
        | Notification _ -> None
        | Diagnostic text ->
            state.diagnostic_count <- state.diagnostic_count + 1;
            if state.diagnostic_count > 64 then
              limit "too many command diagnostics";
            state.diagnostics <- text :: state.diagnostics;
            None
        | Frame frame when frame.guard.flags = 0 ->
            if state.callback_count = 64 then limit "too many hook frames";
            state.callback_count <- state.callback_count + 1;
            state.callbacks <- frame :: state.callbacks;
            None
        | Frame frame when frame.guard.flags <> 1 ->
            malformed "unknown command frame flags"
        | Frame frame when frame.ok && frame.body = state.marker ^ "\n" ->
            if
              state.received = 0
              || ((not state.failed) && state.received <> state.count)
            then malformed "group completed with missing replies";
            state.completed <- true;
            let replies =
              List.rev state.replies
              @ List.init (state.count - state.received) (fun _ -> Skipped)
            in
            Some
              {
                replies = Iarray.of_list replies;
                callbacks = Iarray.of_list (List.rev state.callbacks);
                diagnostics = List.rev state.diagnostics;
              }
        | Frame frame ->
            if state.failed || state.received >= state.count then
              malformed "unexpected extra command frame";
            state.received <- state.received + 1;
            state.failed <- not frame.ok;
            state.replies <-
              (if frame.ok then Succeeded frame.body else Failed frame.body)
              :: state.replies;
            None)
end
