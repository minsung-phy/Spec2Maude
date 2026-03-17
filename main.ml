let () =
  let usage = "Usage: " ^ Sys.argv.(0) ^ " <file1.spectec> <file2.spectec> ..." in
  if Array.length Sys.argv < 2 then (print_endline usage; exit 1);

  (* 1. 모든 파일의 프론트엔드 AST를 하나로 수집 *)
  let files = List.init (Array.length Sys.argv - 1) (fun i -> Sys.argv.(i + 1)) in
  
  let all_frontend_defs = List.fold_left (fun acc file ->
    try
      Printf.eprintf "[INFO] Parsing file: %s\n%!" file;
      acc @ (Frontend.Parse.parse_file file)
    with e ->
      Printf.eprintf "[ERROR] Failed to parse %s: %s\n%!" file (Printexc.to_string e);
      acc
  ) [] files in

  (* 2. 합쳐진 AST를 단 한 번만 엘라보레이션 (모든 참조 해결) *)
  try
    Printf.eprintf "[INFO] Elaborating all definitions together...\n%!";
    let (il_defs, _env) = Frontend.Elab.elab all_frontend_defs in
    
    (* 3. 타입 환경 구축 (구조적 plural 타입 탐지) *)
    Translator.build_type_env il_defs;
    
    (* 4. 번역 및 Maude 형식 출력 *)
    print_endline Translator.header;
    List.iter (fun def ->
      let result = Translator.translate_definition def in
      if result <> "" then print_endline result
    ) il_defs;
    print_endline Translator.footer
    
  with
  | Util.Error.Error (at, msg) ->
      Printf.eprintf "%s: error: %s\n%!" (Util.Source.string_of_region at) msg
  | e ->
      Printf.eprintf "[FATAL ERROR] Elaboration failed: %s\n%!" (Printexc.to_string e)