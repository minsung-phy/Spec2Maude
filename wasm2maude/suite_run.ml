type status =
  | Pass
  | Wrong_result
  | Unsupported
  | Frontend_error
  | Maude_error
  | Timeout
  | Step_limit
  | Stuck

type case = {
  source : string;
  status : status;
  seconds : float;
  commands : int;
  checked_assertions : int;
  runtime_assertions : int;
  detail : string;
}

type report = case list

type process_result =
  | Exited of Unix.process_status
  | Timed_out

let status_name = function
  | Pass -> "PASS"
  | Wrong_result -> "WRONG_RESULT"
  | Unsupported -> "UNSUPPORTED"
  | Frontend_error -> "FRONTEND_ERROR"
  | Maude_error -> "MAUDE_ERROR"
  | Timeout -> "TIMEOUT"
  | Step_limit -> "STEP_LIMIT"
  | Stuck -> "STUCK"

let contains text pattern =
  let text_len = String.length text in
  let pattern_len = String.length pattern in
  let rec search i =
    i + pattern_len <= text_len
    && (String.sub text i pattern_len = pattern || search (i + 1))
  in
  pattern_len = 0 || search 0

let find_line pattern text =
  String.split_on_char '\n' text
  |> List.find_opt (fun line -> contains line pattern)
  |> Option.value ~default:""
  |> String.trim

let result_lines text =
  String.split_on_char '\n' text
  |> List.filter (fun line -> contains line "result ")

let bounded_result text =
  match List.rev (result_lines text) with
  | _probe :: result :: _ -> String.trim result
  | result :: _ -> String.trim result
  | [] -> "no Maude result"

let last_rewrite_count text =
  let parse line =
    String.split_on_char ' ' (String.trim line)
    |> List.filter (fun field -> field <> "")
    |> function
    | "rewrites:" :: count :: _ -> int_of_string_opt count
    | _ -> None
  in
  String.split_on_char '\n' text |> List.filter_map parse |> List.rev
  |> function count :: _ -> count | [] -> 0

let classify process output =
  if contains output "Warning:" then Maude_error, find_line "Warning:" output
  else if contains output "Error:" then Maude_error, find_line "Error:" output
  else
    match process with
    | Timed_out -> Timeout, "Maude exceeded the per-file timeout"
    | Exited (Unix.WEXITED 0) ->
        let result = bounded_result output in
        if contains result "script.wrong-" then Wrong_result, result
        else if contains result "script.done" then Pass, ""
        else if last_rewrite_count output > 0 then
          Step_limit,
          "bounded rewrite budget exhausted while execution could still step"
        else Stuck, result
    | Exited (Unix.WEXITED code) ->
        Maude_error, Printf.sprintf "Maude exited with status %d" code
    | Exited (Unix.WSIGNALED signal) ->
        Maude_error, Printf.sprintf "Maude was killed by signal %d" signal
    | Exited (Unix.WSTOPPED signal) ->
        Maude_error, Printf.sprintf "Maude stopped on signal %d" signal

let write_file path text =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc text)

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let remove_file path =
  try Sys.remove path with Sys_error _ -> ()

let rec wait pid deadline =
  match Unix.waitpid [Unix.WNOHANG] pid with
  | 0, _ when Unix.gettimeofday () < deadline ->
      Unix.sleepf 0.05;
      wait pid deadline
  | 0, _ ->
      Unix.kill pid Sys.sigkill;
      ignore (Unix.waitpid [] pid);
      Timed_out
  | _, status -> Exited status

let execute ~maude ~timeout harness output =
  let fd =
    Unix.openfile output [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600
  in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      let shell = "/bin/sh" in
      let argv =
        [|shell; "-c";
          "ulimit -s unlimited 2>/dev/null || ulimit -s 65520 2>/dev/null || true; exec \"$@\"";
          "spec2maude-maude"; maude; "-no-banner"; harness|]
      in
      let pid = Unix.create_process shell argv Unix.stdin fd fd in
      wait pid (Unix.gettimeofday () +. timeout))

let ensure_directory path =
  if Sys.file_exists path then begin
    if not (Sys.is_directory path) then
      Ingress_error.raise Ingress_error.Io path "log path is not a directory"
  end else
    try Unix.mkdir path 0o755 with Unix.Unix_error (error, _, _) ->
      Ingress_error.raise Ingress_error.Io path (Unix.error_message error)

let log_path dir index source =
  let name = Filename.basename source in
  Filename.concat dir (Printf.sprintf "%04d-%s.log" index name)

let run_case ~semantics ~maude ~timeout ~steps ~call_depth ~log_dir index source =
  let started = Unix.gettimeofday () in
  let commands = ref 0 in
  let checked_assertions = ref 0 in
  let runtime_assertions = ref 0 in
  let status, detail =
    try
      let harness, emitted = Wast_run.emit ~semantics ~steps ~call_depth source in
      commands := Wast_run.commands emitted;
      checked_assertions := Wast_run.checked_assertions emitted;
      runtime_assertions := Wast_run.runtime_assertions emitted;
      let harness_file = Filename.temp_file "spec2maude-wast-" ".maude" in
      let output_file = Filename.temp_file "spec2maude-wast-" ".log" in
      Fun.protect
        ~finally:(fun () ->
          remove_file harness_file;
          remove_file output_file)
        (fun () ->
          write_file harness_file harness;
          let process = execute ~maude ~timeout harness_file output_file in
          let output = read_file output_file in
          Option.iter (fun dir -> write_file (log_path dir index source) output)
            log_dir;
          classify process output)
    with
    | Ingress_error.Error error ->
        let status =
          match error.kind with
          | Ingress_error.Unsupported -> Unsupported
          | Ingress_error.Io | Ingress_error.Syntax | Ingress_error.Invalid ->
              Frontend_error
        in
        status, Ingress_error.to_string error
    | Unix.Unix_error (error, function_name, argument) ->
        Maude_error,
        Printf.sprintf "%s(%s): %s" function_name argument
          (Unix.error_message error)
    | Sys_error message -> Frontend_error, message
  in
  { source;
    status;
    seconds = Unix.gettimeofday () -. started;
    commands = !commands;
    checked_assertions = !checked_assertions;
    runtime_assertions = !runtime_assertions;
    detail }

let run ~semantics ~maude ~timeout ~steps ~call_depth ?progress ?log_dir path =
  if timeout <= 0. then invalid_arg "Suite_run.run: non-positive timeout";
  Option.iter ensure_directory log_dir;
  let sources = Wast.sources path in
  let total = List.length sources in
  sources
  |> List.mapi
       (fun index source ->
         let case =
           run_case ~semantics ~maude ~timeout ~steps ~call_depth ~log_dir
             (index + 1) source
         in
         Option.iter
           (fun progress ->
             progress ~completed:(index + 1) ~total ~source
               ~status:(status_name case.status) ~seconds:case.seconds)
           progress;
         case)

let clean_field text =
  String.map (function '\t' | '\n' | '\r' -> ' ' | char -> char) text

let to_tsv report =
  let buffer = Buffer.create 4096 in
  Buffer.add_string buffer
    "status\tseconds\tcommands\tchecked_assertions\truntime_assertions\tsource\tdetail\n";
  List.iter
    (fun case ->
      Buffer.add_string buffer
        (Printf.sprintf "%s\t%.3f\t%d\t%d\t%d\t%s\t%s\n"
           (status_name case.status) case.seconds case.commands
           case.checked_assertions case.runtime_assertions (clean_field case.source)
           (clean_field case.detail)))
    report;
  Buffer.contents buffer

let summary report =
  let statuses =
    [ Pass;
      Wrong_result;
      Unsupported;
      Frontend_error;
      Maude_error;
      Timeout;
      Step_limit;
      Stuck ]
  in
  List.filter_map
    (fun status ->
      let count =
        List.fold_left
          (fun count case -> if case.status = status then count + 1 else count)
          0 report
      in
      if count = 0 then None else Some (status_name status, count))
    statuses

let successful report = List.for_all (fun case -> case.status = Pass) report
