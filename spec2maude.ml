let die msg =
  prerr_endline ("spec2maude: " ^ msg);
  exit 2

let quote = Filename.quote

let show_cmd args = String.concat " " (List.map quote args)

let translator_exe = "_build/default/main.exe"

let wasm_frontend_exe = "_build/default/wasm_to_maude.exe"

let ensure_executable path =
  if Sys.file_exists path then ()
  else
    die
      (path ^ " does not exist. Run `make build` first.")

let run ?stdout_to args =
  match args with
  | [] -> invalid_arg "empty command"
  | prog :: _ ->
      prerr_endline ("[spec2maude] " ^ show_cmd args);
      let stdout_fd =
        match stdout_to with
        | None -> Unix.stdout
        | Some path ->
            Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644
      in
      let close_stdout () =
        match stdout_to with None -> () | Some _ -> Unix.close stdout_fd
      in
      let pid =
        Unix.create_process prog (Array.of_list args) Unix.stdin stdout_fd Unix.stderr
      in
      close_stdout ();
      match Unix.waitpid [] pid |> snd with
      | Unix.WEXITED 0 -> ()
      | Unix.WEXITED n -> exit n
      | Unix.WSIGNALED n -> die ("command killed by signal " ^ string_of_int n)
      | Unix.WSTOPPED n -> die ("command stopped by signal " ^ string_of_int n)

let usage () =
  print_endline
    {|
Spec2Maude reproducible CLI

Usage:
  spec2maude translate [-o FILE] [SPECTEC...]
  spec2maude run INPUT.wat|INPUT.wasm [--fib N | --main | --export NAME] [ARGS...]
  spec2maude validate INPUT.wat|INPUT.wasm [ARGS...]
  spec2maude maude-validate INPUT.wat|INPUT.wasm [ARGS...]
  spec2maude test smoke|official|all [OPTIONS]

Examples:
  spec2maude translate
  spec2maude run wat_examples/fib.wat --fib 5
  spec2maude run wat_examples/global-get.wat --main
  spec2maude run wat_examples/import-func.wat --export main --arg-i32 41 \
    --import-func 'env.bump=local.get 0 i32.const 1 i32.add'
  spec2maude validate wat_examples/fib.wat
  spec2maude test official --limit 200 --timeout 10

Notes:
  - run defaults to execution-only (--unchecked-run) so small demos print a result.
  - validate checks the official SpecTec/Wasm parser-validator input path.
  - maude-validate is an experimental debug command for the generated Module-ok path.
|};
  exit 0

let default_maude () =
  match Sys.getenv_opt "MAUDE_BIN" with Some p -> p | None -> "maude"

let sorted_spectec_files () =
  let dir = "wasm-3.0" in
  if not (Sys.file_exists dir) then die "cannot find wasm-3.0/";
  Sys.readdir dir
  |> Array.to_list
  |> List.filter (fun name -> Filename.check_suffix name ".spectec")
  |> List.sort String.compare
  |> List.map (Filename.concat dir)

let cmd_translate args =
  let output = ref "output.maude" in
  let files = ref [] in
  let rec loop = function
    | [] -> ()
    | ("-o" | "--output") :: path :: rest ->
        output := path;
        loop rest
    | ("-o" | "--output") :: [] -> die "translate expects a path after -o/--output"
    | "--help" :: _ -> usage ()
    | arg :: rest ->
        files := !files @ [ arg ];
        loop rest
  in
  loop args;
  let files = if !files = [] then sorted_spectec_files () else !files in
  ensure_executable translator_exe;
  run ~stdout_to:!output ([ translator_exe ] @ files);
  prerr_endline ("[spec2maude] wrote " ^ !output)

let option_takes_value = function
  | "--arg-i32" | "--arg-i64" | "--arg-f32" | "--arg-f64" | "--arg-v128"
  | "--arg-ref-null" | "--arg-externref" | "--arg-funcref" | "--search-expected"
  | "--invoke-index" | "--import-func" | "--import-global" | "--import-memory"
  | "--memory-data" | "--table-data" | "--state-func" | "--prelude-call"
  | "--harness" | "--output" ->
      true
  | _ -> false

let parse_common_wasm_args ?(default_result_only = true) mode args =
  let maude = ref (default_maude ()) in
  let checked = ref false in
  let result_only = ref default_result_only in
  let input = ref None in
  let target = ref [] in
  let pass = ref [] in
  let add_pass xs = pass := !pass @ xs in
  let set_target xs =
    if !target <> [] then die (mode ^ " accepts only one target: --fib, --main, or --export");
    target := xs
  in
  let rec loop = function
    | [] -> ()
    | "--help" :: _ -> usage ()
    | "--maude" :: path :: rest ->
        maude := path;
        loop rest
    | "--maude" :: [] -> die (mode ^ " expects a path after --maude")
    | "--checked" :: rest ->
        checked := true;
        loop rest
    | "--unchecked" :: rest ->
        checked := false;
        loop rest
    | "--full-output" :: rest ->
        result_only := false;
        loop rest
    | "--result-only" :: rest ->
        result_only := true;
        loop rest
    | "--fib" :: n :: rest ->
        set_target [ "--run"; n ];
        loop rest
    | "--fib" :: [] -> die (mode ^ " expects a number after --fib")
    | "--main" :: rest ->
        set_target [ "--run-main" ];
        loop rest
    | "--export" :: name :: rest ->
        set_target [ "--run-export"; name ];
        loop rest
    | "--export" :: [] -> die (mode ^ " expects a name after --export")
    | opt :: value :: rest when String.length opt > 0 && opt.[0] = '-' && option_takes_value opt ->
        add_pass [ opt; value ];
        loop rest
    | opt :: rest when String.length opt > 0 && opt.[0] = '-' ->
        add_pass [ opt ];
        loop rest
    | path :: rest -> (
        match !input with
        | None ->
            input := Some path;
            loop rest
        | Some _ -> die (mode ^ " accepts only one input file"))
  in
  loop args;
  let input = match !input with Some p -> p | None -> die (mode ^ " expects INPUT.wat or INPUT.wasm") in
  (!maude, !checked, !result_only, !target, !pass, input)

let cmd_run args =
  let maude, checked, result_only, target, pass, input = parse_common_wasm_args "run" args in
  let target = if target = [] then [ "--run-main" ] else target in
  let checked_arg = if checked then "--checked-run" else "--unchecked-run" in
  let result_arg = if result_only then [ "--result-only" ] else [] in
  ensure_executable wasm_frontend_exe;
  run
    ([ wasm_frontend_exe; "--maude"; maude; checked_arg]
    @ result_arg @ target @ pass @ [ input ])

let cmd_validate args =
  let _maude, _checked, _result_only, _target, pass, input =
    parse_common_wasm_args ~default_result_only:false "validate" args
  in
  ensure_executable wasm_frontend_exe;
  let tmp = Filename.temp_file "spec2maude-validate-" ".maude" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove tmp with Sys_error _ -> ())
    (fun () ->
      run ([ wasm_frontend_exe; "--output"; tmp ] @ pass @ [ input ]);
      prerr_endline
        ("[spec2maude] official SpecTec/Wasm parser-validator accepted " ^ input
       ^ " and generated a Maude harness"))

let cmd_maude_validate args =
  let maude, _checked, result_only, _target, pass, input =
    parse_common_wasm_args ~default_result_only:false "maude-validate" args
  in
  let result_arg = if result_only then [ "--result-only" ] else [] in
  ensure_executable wasm_frontend_exe;
  run
    ([ wasm_frontend_exe; "--maude"; maude; "--maude-validate-only" ]
    @ result_arg @ pass @ [ input ])

let cmd_test args =
  let suite = ref None in
  let maude = ref (default_maude ()) in
  let timeout = ref "10" in
  let artifact_dir = ref None in
  let limit = ref None in
  let max_file_bytes = ref None in
  let rec loop = function
    | [] -> ()
    | "--help" :: _ -> usage ()
    | "--maude" :: path :: rest ->
        maude := path;
        loop rest
    | "--timeout" :: n :: rest ->
        timeout := n;
        loop rest
    | "--artifact-dir" :: path :: rest ->
        artifact_dir := Some path;
        loop rest
    | "--limit" :: n :: rest ->
        limit := Some n;
        loop rest
    | "--max-file-bytes" :: n :: rest ->
        max_file_bytes := Some n;
        loop rest
    | ("smoke" | "official" | "all" as name) :: rest ->
        if !suite <> None then die "test accepts only one suite";
        suite := Some name;
        loop rest
    | bad :: _ -> die ("unknown test argument: " ^ bad)
  in
  loop args;
  let suite = match !suite with Some s -> s | None -> "smoke" in
  run ["dune"; "build"; "./main.exe"; "./wasm_to_maude.exe"];
  let artifact =
    match !artifact_dir with
    | Some path -> path
    | None ->
        "artifacts/spec2maude-" ^ suite ^ "-"
        ^ string_of_int (int_of_float (Unix.time ()))
  in
  let base =
    [
      "scripts/run_wasm_benchmarks.py";
      "--cli";
      "_build/default/wasm_to_maude.exe";
      "--maude";
      !maude;
      "--timeout";
      !timeout;
      "--artifact-dir";
      artifact;
    ]
  in
  let suite_args =
    match suite with
    | "smoke" -> [ "--skip-external" ]
    | "official" ->
        [
          "--skip-smokes";
          "--external-root";
          "benchmarks/external/webassembly-spec/test/core";
        ]
    | "all" -> []
    | _ -> assert false
  in
  let limit_args =
    match !limit with None -> [] | Some n -> [ "--max-external-files"; n ]
  in
  let size_args =
    match !max_file_bytes with None -> [] | Some n -> [ "--max-file-bytes"; n ]
  in
  run (base @ suite_args @ limit_args @ size_args)

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [] | [ "help" ] | [ "--help" ] | [ "-h" ] -> usage ()
  | "translate" :: args -> cmd_translate args
  | "run" :: args -> cmd_run args
  | "validate" :: args -> cmd_validate args
  | "maude-validate" :: args -> cmd_maude_validate args
  | "test" :: args -> cmd_test args
  | cmd :: _ -> die ("unknown command: " ^ cmd)
