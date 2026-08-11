open Wasm_to_maude

let usage () =
  Printf.eprintf
    "usage:\n  wasm2maude module INPUT [-o FILE] [--semantics FILE] [--term-only]\n  wasm2maude instantiate INPUT [-o FILE] [--semantics FILE]\n  wasm2maude run INPUT --invoke NAME [--arg TYPE:VALUE]... [-o FILE] [--semantics FILE] [--steps N]\n  wasm2maude modelcheck INPUT --invoke NAME [--arg TYPE:VALUE]... --expect TYPE:VALUE --reject TYPE:VALUE [-o FILE] [--semantics FILE] [--steps N]\n  wasm2maude wast-run FILE [-o FILE] [--semantics FILE] [--steps N] [--call-depth N]\n  wasm2maude suite-run PATH [-o REPORT] [--semantics FILE] [--maude FILE] [--timeout SEC] [--steps N] [--call-depth N] [--log-dir DIR]\n  wasm2maude wast-summary FILE\n  wasm2maude suite-summary DIRECTORY\n  wasm2maude suite-audit DIRECTORY\n  wasm2maude suite-typecheck DIRECTORY [-o FILE] [--semantics FILE]\n  wasm2maude wast-typecheck FILE [-o FILE] [--semantics FILE]\n";
  exit 2

let write output text =
  match output with
  | None -> print_string text
  | Some path ->
      let oc = open_out path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () -> output_string oc text)

let resolve path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
  else path

let input_options args =
  let rec options input output semantics term_only = function
    | [] -> (input, output, semantics, term_only)
    | "-o" :: path :: rest -> options input (Some path) semantics term_only rest
    | "--semantics" :: path :: rest ->
        options input output path term_only rest
    | "--term-only" :: rest -> options input output semantics true rest
    | arg :: rest when input = None ->
        options (Some arg) output semantics term_only rest
    | _ -> usage ()
  in
  let input, output, semantics, term_only =
    options None None "builtins.maude" false args
  in
  let input = match input with Some path -> path | None -> usage () in
  input, output, resolve semantics, term_only

let module_command args =
  let input, output, semantics, term_only = input_options args in
  let m = Frontend.load input in
  let text = if term_only then Emit.term m ^ "\n" else Emit.typecheck ~semantics m in
  write output text

let instantiate_command args =
  let input, output, semantics, term_only = input_options args in
  if term_only then usage ();
  let m = Frontend.load input in
  write output (Emit.instantiate ~semantics m)

let parse_arg text =
  let kind, value =
    match String.index_opt text ':' with
    | Some i ->
        String.sub text 0 i,
        String.sub text (i + 1) (String.length text - i - 1)
    | None -> usage ()
  in
  try
    match kind with
    | "i32" -> Wasm.Value.I32 (Wasm.I32.of_string value)
    | "i64" -> Wasm.Value.I64 (Wasm.I64.of_string value)
    | "f32" -> Wasm.Value.F32 (Wasm.F32.of_string value)
    | "f64" -> Wasm.Value.F64 (Wasm.F64.of_string value)
    | _ -> usage ()
  with Failure _ -> usage ()

let run_command args =
  let rec options input output semantics export args steps = function
    | [] -> input, output, semantics, export, List.rev args, steps
    | "-o" :: path :: rest ->
        options input (Some path) semantics export args steps rest
    | "--semantics" :: path :: rest ->
        options input output path export args steps rest
    | "--invoke" :: name :: rest ->
        options input output semantics (Some name) args steps rest
    | "--arg" :: value :: rest ->
        options input output semantics export (parse_arg value :: args) steps rest
    | "--steps" :: value :: rest ->
        options input output semantics export args (int_of_string value) rest
    | arg :: rest when input = None ->
        options (Some arg) output semantics export args steps rest
    | _ -> usage ()
  in
  let input, output, semantics, export, args, steps =
    options None None "builtins.maude" None [] 100000 args
  in
  let semantics = resolve semantics in
  let input = match input with Some path -> path | None -> usage () in
  let export = match export with Some name -> name | None -> usage () in
  let m = Frontend.load input in
  let export =
    try Wasm.Utf8.decode export with Wasm.Utf8.Utf8 -> usage ()
  in
  write output (Emit.run ~semantics ~export ~args ~steps m)

let modelcheck_command args =
  let rec options input output semantics export arguments expected rejected steps =
    function
    | [] ->
        input, output, semantics, export, List.rev arguments, expected, rejected,
        steps
    | "-o" :: path :: rest ->
        options input (Some path) semantics export arguments expected rejected
          steps rest
    | "--semantics" :: path :: rest ->
        options input output path export arguments expected rejected steps rest
    | "--invoke" :: name :: rest ->
        options input output semantics (Some name) arguments expected rejected
          steps rest
    | "--arg" :: value :: rest ->
        options input output semantics export (parse_arg value :: arguments)
          expected rejected steps rest
    | "--expect" :: value :: rest ->
        options input output semantics export arguments (Some (parse_arg value))
          rejected steps rest
    | "--reject" :: value :: rest ->
        options input output semantics export arguments expected
          (Some (parse_arg value)) steps rest
    | "--steps" :: value :: rest ->
        options input output semantics export arguments expected rejected
          (int_of_string value) rest
    | arg :: rest when input = None ->
        options (Some arg) output semantics export arguments expected rejected
          steps rest
    | _ -> usage ()
  in
  let input, output, semantics, export, args, expected, rejected, steps =
    options None None "builtins.maude" None [] None None 100000 args
  in
  let input = match input with Some path -> path | None -> usage () in
  let export = match export with Some name -> name | None -> usage () in
  let expected = match expected with Some value -> value | None -> usage () in
  let rejected = match rejected with Some value -> value | None -> usage () in
  let export =
    try Wasm.Utf8.decode export with Wasm.Utf8.Utf8 -> usage ()
  in
  let m = Frontend.load input in
  write output
    (Emit.modelcheck ~semantics:(resolve semantics) ~export ~args ~expected
       ~rejected ~steps m)

let wast_run args =
  let nonnegative value =
    match int_of_string_opt value with
    | Some value when value >= 0 -> value
    | Some _ | None -> usage ()
  in
  let rec options input output semantics steps call_depth = function
    | [] -> input, output, semantics, steps, call_depth
    | "-o" :: path :: rest ->
        options input (Some path) semantics steps call_depth rest
    | "--semantics" :: path :: rest ->
        options input output path steps call_depth rest
    | "--steps" :: value :: rest ->
        options input output semantics (nonnegative value) call_depth rest
    | "--call-depth" :: value :: rest ->
        options input output semantics steps (nonnegative value) rest
    | arg :: rest when input = None ->
        options (Some arg) output semantics steps call_depth rest
    | _ -> usage ()
  in
  let input, output, semantics, steps, call_depth =
    options None None "builtins.maude" 1000000 256 args
  in
  let semantics = resolve semantics in
  let input = match input with Some path -> path | None -> usage () in
  let text, report = Wast_run.emit ~semantics ~steps ~call_depth input in
  write output text;
  Printf.eprintf "[wasm2maude] checked=%d runtime=%d\n"
    (Wast_run.checked report) (Wast_run.runtime_assertions report)

let suite_run args =
  let positive_float value =
    match float_of_string_opt value with
    | Some value when value > 0. -> value
    | Some _ | None -> usage ()
  in
  let nonnegative value =
    match int_of_string_opt value with
    | Some value when value >= 0 -> value
    | Some _ | None -> usage ()
  in
  let rec options input output semantics maude timeout steps call_depth log_dir =
    function
    | [] ->
        input, output, semantics, maude, timeout, steps, call_depth, log_dir
    | "-o" :: path :: rest ->
        options input (Some path) semantics maude timeout steps call_depth log_dir
          rest
    | "--semantics" :: path :: rest ->
        options input output path maude timeout steps call_depth log_dir rest
    | "--maude" :: path :: rest ->
        options input output semantics path timeout steps call_depth log_dir rest
    | "--timeout" :: value :: rest ->
        options input output semantics maude (positive_float value) steps call_depth
          log_dir rest
    | "--steps" :: value :: rest ->
        options input output semantics maude timeout (nonnegative value) call_depth
          log_dir rest
    | "--call-depth" :: value :: rest ->
        options input output semantics maude timeout steps (nonnegative value)
          log_dir rest
    | "--log-dir" :: path :: rest ->
        options input output semantics maude timeout steps call_depth (Some path)
          rest
    | arg :: rest when input = None ->
        options (Some arg) output semantics maude timeout steps call_depth log_dir
          rest
    | _ -> usage ()
  in
  let input, output, semantics, maude, timeout, steps, call_depth, log_dir =
    options None None "builtins.maude" "maude" 60. 1000000 256 None args
  in
  let input = match input with Some path -> path | None -> usage () in
  let progress ~completed ~total ~source ~status ~seconds =
    Printf.eprintf "[wasm2maude] %d/%d %-14s %6.2fs %s\n%!" completed total
      status seconds source
  in
  let report =
    Suite_run.run ~semantics:(resolve semantics) ~maude ~timeout ~steps ~call_depth
      ~progress ?log_dir input
  in
  write output (Suite_run.to_tsv report);
  List.iter
    (fun (status, count) ->
      Printf.eprintf "[wasm2maude] %-14s %d\n" status count)
    (Suite_run.summary report);
  if not (Suite_run.successful report) then exit 1

let wast_summary path =
  let summary = Wast.load path in
  Printf.printf "commands: %d\n" (Wast.total summary);
  List.iter (fun (kind, count) -> Printf.printf "%-28s %d\n" kind count)
    (Wast.to_lines summary)

let suite_summary path =
  let suite = Wast.load_suite path in
  let summary = Wast.summary suite in
  Printf.printf "files: %d\ncommands: %d\n" (Wast.files suite) (Wast.total summary);
  List.iter (fun (kind, count) -> Printf.printf "%-28s %d\n" kind count)
    (Wast.to_lines summary)

let suite_audit path =
  let audit = Wast.audit_suite path in
  Printf.printf "files: %d\nmodules: %d\nencoded: %d\n"
    (Wast.audit_files audit) (Wast.audit_modules audit)
    (Wast.audit_encoded audit);
  List.iter (fun (reason, count) -> Printf.printf "%-6d %s\n" count reason)
    (Wast.audit_failures audit);
  List.iter (Printf.printf "- %s\n") (Wast.audit_issues audit)

let suite_typecheck ?(details = false) args =
  let input, output, semantics, term_only = input_options args in
  if term_only then usage ();
  let text, audit = Wast.typecheck_suite ~details ~semantics input in
  write output text;
  Printf.eprintf "[wasm2maude] files=%d modules=%d encoded=%d\n"
    (Wast.audit_files audit) (Wast.audit_modules audit)
    (Wast.audit_encoded audit);
  List.iter
    (fun (reason, count) -> Printf.eprintf "[wasm2maude] skipped=%d %s\n" count reason)
    (Wast.audit_failures audit);
  List.iter
    (Printf.eprintf "[wasm2maude] %s\n") (Wast.audit_issues audit)

let main = function
  | "module" :: args -> module_command args
  | "instantiate" :: args -> instantiate_command args
  | "run" :: args -> run_command args
  | "modelcheck" :: args -> modelcheck_command args
  | "wast-run" :: args -> wast_run args
  | "suite-run" :: args -> suite_run args
  | ["wast-summary"; path] -> wast_summary path
  | ["suite-summary"; path] -> suite_summary path
  | ["suite-audit"; path] -> suite_audit path
  | "suite-typecheck" :: args -> suite_typecheck args
  | "wast-typecheck" :: args -> suite_typecheck ~details:true args
  | _ -> usage ()

let () =
  try main (List.tl (Array.to_list Sys.argv)) with
  | Ingress_error.Error error ->
      prerr_endline (Ingress_error.to_string error);
      exit 1
  | Sys_error message ->
      prerr_endline message;
      exit 1
