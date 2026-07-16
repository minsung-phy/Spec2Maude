let die message =
  prerr_endline ("spec2maude: " ^ message);
  exit 2

let usage ?(code = 2) () =
  prerr_endline
    "Usage:\n  spec2maude translate [-o FILE] [--builtins FILE] [--builtin-report FILE] [--emit-partial] [SPECTEC...]\n\nSpec2Maude uses the official SpecTec builtin semantics and the bundled verified runtime-ingress contract. If no input files are provided, translate reads wasm-3.0/*.spectec in lexical order. --emit-partial is verification-only: marked output is written on fatal diagnostics, but the command still exits nonzero.";
  exit code

let sorted_default_spectec_files () =
  let dir = "wasm-3.0" in
  if not (Sys.file_exists dir) then die "cannot find wasm-3.0/";
  Sys.readdir dir
  |> Array.to_list
  |> List.filter (fun name -> Filename.check_suffix name ".spectec")
  |> List.sort String.compare
  |> List.map (Filename.concat dir)

let write_file path contents =
  let channel = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)

let strip_maude_suffix path =
  let suffix = ".maude" in
  let path_len = String.length path in
  let suffix_len = String.length suffix in
  if path_len >= suffix_len
     && String.sub path (path_len - suffix_len) suffix_len = suffix
  then
    String.sub path 0 (path_len - suffix_len)
  else
    path

let builtin_output_load output builtins_output =
  if Filename.dirname output = Filename.dirname builtins_output then
    strip_maude_suffix (Filename.basename output)
  else
    strip_maude_suffix output

let parse_translate_args args =
  let output = ref "output.maude" in
  let builtins_output = ref None in
  let builtin_report = ref None in
  let emit_partial = ref false in
  let files = ref [] in
  let rec loop = function
    | [] -> ()
    | ("-o" | "--output") :: path :: rest ->
      output := path;
      loop rest
    | ("-o" | "--output") :: [] ->
      die "translate expects a path after -o/--output"
    | "--builtins" :: path :: rest ->
      builtins_output := Some path;
      loop rest
    | "--builtins" :: [] ->
      die "translate expects a path after --builtins"
    | "--builtin-report" :: path :: rest ->
      builtin_report := Some path;
      loop rest
    | "--builtin-report" :: [] ->
      die "translate expects a path after --builtin-report"
    | "--emit-partial" :: rest ->
      emit_partial := true;
      loop rest
    | "--help" :: _ -> usage ~code:0 ()
    | file :: rest ->
      files := !files @ [ file ];
      loop rest
  in
  loop args;
  let files =
    if !files = [] then sorted_default_spectec_files () else !files
  in
  !output, !builtins_output, !builtin_report, !emit_partial, files

let split_fields line =
  line
  |> String.split_on_char ' '
  |> List.filter (fun field -> field <> "")

let parse_output_indices text =
  if text = "-" then []
  else
    text
    |> String.split_on_char ','
    |> List.map (fun value ->
      match int_of_string_opt value with
      | Some index when index >= 0 -> index
      | Some _ | None -> die ("invalid ingress output index `" ^ value ^ "`"))

let parse_ingress_line path line_number line =
  match split_fields line with
  | [ capability; definition_id; clause_index; producer_index; consumer_index
    ; producer_relation_id; consumer_relation_id; output_indices
    ; source_digest; trusted_formula_digest ] ->
    let capability =
      match capability with
      | "linking" -> Translator.Runtime_ingress_contract.Linking
      | "invocation" -> Invocation
      | value -> die ("invalid ingress capability `" ^ value ^ "`")
    in
    let index label value =
      match int_of_string_opt value with
      | Some index when index >= 0 -> index
      | Some _ | None ->
        die
          (Printf.sprintf
             "invalid %s `%s` at ingress contract line %d"
             label value line_number)
    in
    { Translator.Runtime_ingress_contract.capability
    ; origin = Printf.sprintf "%s:%d" path line_number
    ; definition_id
    ; clause_index = index "clause index" clause_index
    ; producer_premise_index = index "producer premise index" producer_index
    ; consumer_premise_index = index "consumer premise index" consumer_index
    ; producer_relation_id
    ; consumer_relation_id
    ; producer_output_indices = parse_output_indices output_indices
    ; source_digest
    ; trusted_formula_digest
    }
  | _ ->
    die
      (Printf.sprintf
         "runtime ingress contract line %d must have 10 space-separated fields"
         line_number)

let runtime_ingress_contract = "config/wasm-3.0-runtime-ingress.contract"

let load_runtime_ingress_specs path =
  let channel =
    try open_in path with Sys_error message ->
      die ("cannot read runtime ingress contract `" ^ path ^ "`: " ^ message)
  in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () ->
      let rec loop line_number specs =
        match input_line channel with
        | line ->
          let trimmed = String.trim line in
          if trimmed = "" || String.starts_with ~prefix:"#" trimmed then
            loop (line_number + 1) specs
          else
            loop (line_number + 1)
              (parse_ingress_line path line_number trimmed :: specs)
        | exception End_of_file -> List.rev specs
      in
      loop 1 [])

let load_il_script files =
  let el_script =
    files
    |> List.map Frontend.Parse.parse_file
    |> List.concat
  in
  fst (Frontend.Elab.elab el_script)

let cmd_translate args =
  let output, builtins_output, builtin_report, emit_partial, files =
    parse_translate_args args
  in
  let il_script = load_il_script files in
  let runtime_ingress_specs = load_runtime_ingress_specs runtime_ingress_contract in
  let result =
    Translator.Driver.translate ~runtime_ingress_specs il_script
  in
  let fatal = Translator.Driver.has_fatal_diagnostics result in
  if not fatal || emit_partial then (
    if fatal then
      prerr_endline
        "[spec2maude] WARNING: fatal diagnostics remain; writing marked partial/incomplete verification output and exiting nonzero";
    write_file output
      (if fatal then Translator.Driver.emit_partial result
       else Translator.Driver.emit result);
    prerr_endline ("[spec2maude] wrote " ^ output);
    match builtins_output with
    | None -> ()
    | Some path ->
      write_file path
        (if fatal then
           Translator.Driver.emit_partial_builtins
             ~output_load:(builtin_output_load output path) result
         else
           Translator.Driver.emit_builtins
             ~output_load:(builtin_output_load output path) result);
      prerr_endline ("[spec2maude] wrote " ^ path));
  (match builtin_report with
  | None -> ()
  | Some path ->
    write_file path (Translator.Driver.emit_builtin_report result);
    prerr_endline ("[spec2maude] wrote " ^ path));
  prerr_endline ("[spec2maude] " ^ Translator.Diagnostics.summary result.diagnostics);
  if result.diagnostics <> [] then
    prerr_endline (Translator.Diagnostics.render_all result.diagnostics);
  if fatal then exit 1

let () =
  try
    match Array.to_list Sys.argv with
    | [ _ ] -> usage ()
    | _ :: "translate" :: args -> cmd_translate args
    | _ :: "--help" :: _ | _ :: "-h" :: _ -> usage ~code:0 ()
    | _ :: command :: _ -> die ("unknown command " ^ command)
    | [] -> usage ()
  with
  | Util.Error.Error (region, message) ->
    Util.Error.print_error region message;
    exit 1
