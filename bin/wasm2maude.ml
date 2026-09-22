open Wasm_to_maude

let usage () =
  Printf.eprintf
    "usage:\n  wasm2maude module INPUT [-o FILE] [--semantics FILE] [--term-only]\n  wasm2maude instantiate INPUT [-o FILE] [--semantics FILE]\n  wasm2maude run INPUT --invoke NAME [--arg TYPE:VALUE]... [-o FILE] [--semantics FILE] [--runtime FILE] [--steps N]\n  wasm2maude modelcheck INPUT --invoke NAME [--arg TYPE:VALUE]... --expect TYPE:VALUE --reject TYPE:VALUE [-o FILE] [--semantics FILE] [--runtime FILE] [--steps N]\n  wasm2maude harness INPUT --invoke NAME --module-name NAME --prefix NAME [-o FILE]\n  wasm2maude wast-run FILE [-o FILE] [--semantics FILE] [--wast-runtime FILE] [--steps N] [--call-depth N]\n  wasm2maude suite-run PATH [-o REPORT] [--semantics FILE] [--wast-runtime FILE] [--maude FILE] [--timeout SEC] [--steps N] [--call-depth N] [--log-dir DIR]\n  wasm2maude wast-summary FILE\n  wasm2maude suite-summary DIRECTORY\n  wasm2maude suite-audit DIRECTORY\n  wasm2maude suite-typecheck DIRECTORY [-o FILE] [--semantics FILE]\n  wasm2maude wast-typecheck FILE [-o FILE] [--semantics FILE]\n";
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

let default_semantics = "translator/backend/semantics.maude"

let nonnegative value =
  match int_of_string_opt value with
  | Some value when value >= 0 -> value
  | Some _ | None -> usage ()

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
    options None None default_semantics false args
  in
  let input = match input with Some path -> path | None -> usage () in
  input, output, resolve semantics, term_only

let module_command args =
  let input, output, semantics, term_only = input_options args in
  let m = Frontend.load input in
  let text =
    if term_only then Emit.term m ^ "\n"
    else Emit.typecheck ~semantics m
  in
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

type execution_mode = Run | Modelcheck | Harness

type execution_options = {
  input : string option;
  output : string option;
  semantics : string;
  runtime : string option;
  export : string option;
  arguments : Wasm.Value.num list;
  expected : Wasm.Value.num option;
  rejected : Wasm.Value.num option;
  steps : int;
  module_name : string option;
  prefix : string option;
}

let execution_command mode args =
  let rec options opts = function
    | [] -> opts
    | "-o" :: path :: rest -> options {opts with output = Some path} rest
    | "--semantics" :: path :: rest when mode <> Harness ->
        options {opts with semantics = path} rest
    | "--runtime" :: path :: rest when mode <> Harness ->
        options {opts with runtime = Some path} rest
    | "--invoke" :: name :: rest -> options {opts with export = Some name} rest
    | "--arg" :: value :: rest when mode <> Harness ->
        options {opts with arguments = parse_arg value :: opts.arguments} rest
    | "--steps" :: value :: rest when mode <> Harness ->
        let steps = nonnegative value in
        options {opts with steps} rest
    | "--expect" :: value :: rest when mode = Modelcheck ->
        options {opts with expected = Some (parse_arg value)} rest
    | "--reject" :: value :: rest when mode = Modelcheck ->
        options {opts with rejected = Some (parse_arg value)} rest
    | "--module-name" :: name :: rest when mode = Harness ->
        options {opts with module_name = Some name} rest
    | "--prefix" :: name :: rest when mode = Harness ->
        options {opts with prefix = Some name} rest
    | arg :: rest when opts.input = None && not (String.starts_with ~prefix:"-" arg) ->
        options {opts with input = Some arg} rest
    | _ -> usage ()
  in
  let opts = options
    {input = None; output = None; semantics = default_semantics; runtime = None;
     export = None; arguments = []; expected = None; rejected = None;
     steps = 100000; module_name = None; prefix = None} args
  in
  let required = function Some value -> value | None -> usage () in
  let input = required opts.input in
  let export =
    try Wasm.Utf8.decode (required opts.export) with Wasm.Utf8.Utf8 -> usage ()
  in
  let semantics = resolve opts.semantics in
  let args = List.rev opts.arguments in
  let steps = opts.steps in
  let m = Frontend.load input in
  let text =
    match mode with
    | Run -> Emit.run ?runtime:opts.runtime ~semantics ~export ~args ~steps m
    | Modelcheck ->
        let expected = required opts.expected in
        let rejected = required opts.rejected in
        Emit.modelcheck ?runtime:opts.runtime ~semantics ~export ~args ~expected
          ~rejected ~steps m
    | Harness ->
        let module_name = required opts.module_name in
        let prefix = required opts.prefix in
        Emit.harness ~module_name ~prefix ~export m
  in
  write opts.output text

let wast_run args =
  let rec options input output semantics runtime steps call_depth = function
    | [] -> input, output, semantics, runtime, steps, call_depth
    | "-o" :: path :: rest ->
        options input (Some path) semantics runtime steps call_depth rest
    | "--semantics" :: path :: rest ->
        options input output path runtime steps call_depth rest
    | "--wast-runtime" :: path :: rest ->
        options input output semantics (Some path) steps call_depth rest
    | "--steps" :: value :: rest ->
        options input output semantics runtime (nonnegative value) call_depth rest
    | "--call-depth" :: value :: rest ->
        options input output semantics runtime steps (nonnegative value) rest
    | arg :: rest when input = None ->
        options (Some arg) output semantics runtime steps call_depth rest
    | _ -> usage ()
  in
  let input, output, semantics, runtime, steps, call_depth =
    options None None default_semantics None 1000000 256 args
  in
  let semantics = resolve semantics in
  let input = match input with Some path -> path | None -> usage () in
  let text, report = Wast_run.emit ?runtime ~semantics ~steps ~call_depth input in
  write output text;
  Printf.eprintf
    "[wasm2maude] commands=%d checked-assertions=%d runtime-assertions=%d\n"
    (Wast_run.commands report) (Wast_run.checked_assertions report)
    (Wast_run.runtime_assertions report)

let suite_run args =
  let positive_float value =
    match float_of_string_opt value with
    | Some value when value > 0. -> value
    | Some _ | None -> usage ()
  in
  let rec options input output semantics runtime maude timeout steps call_depth log_dir =
    function
    | [] ->
        input, output, semantics, runtime, maude, timeout, steps, call_depth, log_dir
    | "-o" :: path :: rest ->
        options input (Some path) semantics runtime maude timeout steps call_depth log_dir
          rest
    | "--semantics" :: path :: rest ->
        options input output path runtime maude timeout steps call_depth log_dir rest
    | "--wast-runtime" :: path :: rest ->
        options input output semantics (Some path) maude timeout steps call_depth log_dir rest
    | "--maude" :: path :: rest ->
        options input output semantics runtime path timeout steps call_depth log_dir rest
    | "--timeout" :: value :: rest ->
        options input output semantics runtime maude (positive_float value) steps call_depth
          log_dir rest
    | "--steps" :: value :: rest ->
        options input output semantics runtime maude timeout (nonnegative value) call_depth
          log_dir rest
    | "--call-depth" :: value :: rest ->
        options input output semantics runtime maude timeout steps (nonnegative value)
          log_dir rest
    | "--log-dir" :: path :: rest ->
        options input output semantics runtime maude timeout steps call_depth (Some path)
          rest
    | arg :: rest when input = None ->
        options (Some arg) output semantics runtime maude timeout steps call_depth log_dir
          rest
    | _ -> usage ()
  in
  let input, output, semantics, runtime, maude, timeout, steps, call_depth, log_dir =
    options None None default_semantics None "maude" 60. 1000000 256 None args
  in
  let input = match input with Some path -> path | None -> usage () in
  let progress ~completed ~total ~source ~status ~seconds =
    Printf.eprintf "[wasm2maude] %d/%d %-14s %6.2fs %s\n%!" completed total
      status seconds source
  in
  let report =
    Suite_run.run ?runtime ~semantics:(resolve semantics) ~maude ~timeout ~steps ~call_depth
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
  | "run" :: args -> execution_command Run args
  | "modelcheck" :: args -> execution_command Modelcheck args
  | "harness" :: args -> execution_command Harness args
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
