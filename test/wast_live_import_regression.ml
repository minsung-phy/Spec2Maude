open Wasm_to_maude

let contains text fragment =
  let n = String.length text and m = String.length fragment in
  let rec loop i =
    i + m <= n && (String.sub text i m = fragment || loop (i + 1))
  in
  m = 0 || loop 0

let compact text =
  text |> String.to_seq
  |> Seq.filter (function ' ' | '\n' | '\r' | '\t' -> false | _ -> true)
  |> String.of_seq

let requirements path =
  Wast_plan.load path |> Wast_plan.commands
  |> List.concat_map (function
       | Wast_plan.Instantiate (_, _, imports) ->
           List.map (fun import -> import.Wast_plan.requirement) imports
       | Wast_plan.Unlinkable (_, imports) ->
           List.map (fun import -> import.Wast_plan.requirement) imports
       | Wast_plan.Uninstantiable _ | Wast_plan.Return _
       | Wast_plan.Trap _ | Wast_plan.Exception _ | Wast_plan.Exhaustion _
       | Wast_plan.Do _ -> [])

let require_requirements path expected =
  if requirements path <> expected then
    failwith ("wrong live import requirements: " ^ path)

let require_unsupported path =
  try
    ignore (Wast_plan.load path);
    failwith ("static mismatch was deferred: " ^ path)
  with
  | Ingress_error.Error
      {kind = Ingress_error.Unsupported; message; _}
    when contains message "incompatible import type" -> ()

let require_host_identity () =
  let host = Wast_plan.load "wast_live_spectest_imports.wast" |> Wast_plan.host in
  let addresses =
    List.map (fun provider -> provider.Wast_plan.binding.address) host.providers
  in
  if addresses <> [0; 0; 0; 0] then
    failwith "spectest live resource imports lost shared addresses"

let require_linker_shape () =
  let text, _ =
    Wast_run.emit ~semantics:"builtins.maude" ~steps:100 ~call_depth:256
      "wast_live_memory_import.wast"
  in
  let generated = compact text in
  if not (contains text "  including WASM-BUILTINS .") then
    failwith "WAST harness does not include executable builtin rules";
  if contains text "protecting WASM-BUILTINS ." then
    failwith "WAST harness still protects executable builtin rules";
  List.iter
    (fun fragment ->
      if not (contains generated fragment) then
        failwith ("missing live linker fragment: " ^ fragment))
    [ "import.current-memory-min(2)";
      "oplink.ok:SpectecTerminals->LinkResult[ctor].";
      "_>=_(MIN,REQUIRED)=true";
      "_<_(MIN,REQUIRED)=true";
      "link.ok(EXPORTS):=linkImports(S,ENV,IMPORTS)";
      "def.instantiate(S,M,EXPORTS)";
      "script.link-error(ID)" ];
  if contains generated "resolveImports" then
    failwith "partial address-only import resolver remains";
  String.split_on_char '\n' text
  |> List.iter (fun line ->
       if contains line "[owise]" && not (contains line "eq ") then
         failwith "execution [owise] was introduced")

let () =
  require_requirements "wast_live_memory_import.wast"
    [Wast_plan.Current_memory_min 2L];
  require_requirements "wast_live_table_import.wast"
    [Wast_plan.Current_table_min 2L];
  require_requirements "wast_live_import_before_grow.wast"
    [Wast_plan.Current_memory_min 2L];
  require_requirements "wast_live_spectest_imports.wast"
    [ Wast_plan.Ready; Wast_plan.Current_memory_min 2L;
      Wast_plan.Ready; Wast_plan.Current_table_min 11L ];
  if List.exists (( <> ) Wast_plan.Ready)
       (requirements "wast_register_imports.wast")
  then failwith "function/global import requirements changed";
  List.iter require_unsupported
    [ "wast_live_import_max_unsupported.wast";
      "wast_live_import_addr_unsupported.wast";
      "wast_live_import_ref_unsupported.wast" ];
  require_host_identity ();
  require_linker_shape ()
