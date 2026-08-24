open Spec2maude_translate

let fail message =
  prerr_endline ("translation_smoke: " ^ message);
  exit 1

let contains text fragment =
  let text_length = String.length text in
  let fragment_length = String.length fragment in
  let rec search index =
    if index + fragment_length > text_length then false
    else if String.sub text index fragment_length = fragment then true
    else search (index + 1)
  in
  search 0

let spectec_files dir =
  Sys.readdir dir
  |> Array.to_list
  |> List.filter (fun name -> Filename.check_suffix name ".spectec")
  |> List.sort String.compare
  |> List.map (Filename.concat dir)

let () =
  let source_dir =
    match Array.to_list Sys.argv with
    | [_; dir] -> dir
    | _ -> fail "expected the SpecTec source directory"
  in
  let files = spectec_files source_dir in
  if List.length files <> 21 then
    fail (Printf.sprintf "expected 21 SpecTec files, found %d" (List.length files));
  let script =
    files
    |> List.concat_map Frontend.Parse.parse_file
    |> Frontend.Elab.elab
    |> fst
  in
  let modul : Maude_il.modul =
    { name = "SPEC2MAUDE-GENERATED"
    ; kind = System
    ; imports = [Protecting "SPECTEC-SUPPORT"]
    ; statements = Definition.translate_script script
    }
  in
  let output = Maude_emit.emit_module modul in
  if not (contains output "mod SPEC2MAUDE-GENERATED is") then
    fail "generated module header is missing";
  if not (contains output "protecting SPECTEC-SUPPORT .") then
    fail "generated support import is missing";
  Printf.printf "translated %d SpecTec files into %d Maude bytes\n"
    (List.length files) (String.length output)
