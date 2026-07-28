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

let unlinkable_commands path =
  Wast_plan.load path |> Wast_plan.commands
  |> List.filter_map (function
       | Wast_plan.Unlinkable (id, imports) -> Some (id, imports)
       | Wast_plan.Instantiate _ | Wast_plan.Uninstantiable _
       | Wast_plan.Return _
       | Wast_plan.Trap _ | Wast_plan.Exception _ | Wast_plan.Exhaustion _
       | Wast_plan.Do _ -> None)

let requirements imports =
  List.map (fun import -> import.Wast_plan.requirement) imports

let require_static_failures () =
  let plan = Wast_plan.load "wast_assert_unlinkable_static.wast" in
  if Wast_plan.checked plan <> 8 || Wast_plan.runtime_assertions plan <> 0 then
    failwith "static unlinkable assertions changed checked/runtime counts";
  (match Wast_plan.commands plan with
   | [Wast_plan.Instantiate _] -> ()
   | _ -> failwith "statically proven unlinkable assertion emitted a command");
  let host = Wast_plan.host plan in
  if List.length host.providers <> 2 || List.length host.funcs <> 2 then
    failwith "host allocation before a later static link failure was discarded"

let require_live_plans () =
  let before = unlinkable_commands "wast_assert_unlinkable_live_before.wast" in
  (match before with
   | [1, imports]
     when requirements imports =
       [Wast_plan.Current_memory_min 2L; Wast_plan.Current_table_min 2L] -> ()
   | _ -> failwith "memory/table minimum mismatch was not deferred in source order");
  let transition =
    unlinkable_commands "wast_assert_unlinkable_live_transition.wast"
  in
  if List.map fst transition <> [1; 4] then
    failwith "unlinkable command IDs changed across resource growth";
  List.iter
    (fun (_, imports) ->
      if requirements imports <>
          [Wast_plan.Current_memory_min 2L; Wast_plan.Current_table_min 2L]
      then failwith "the repeated unlinkable assertion changed its link plan")
    transition

let require_wrong_assertions () =
  List.iter
    (fun (path, id) ->
      match unlinkable_commands path with
      | [actual, _] when actual = id -> ()
      | _ -> failwith ("link success was not observable: " ^ path))
    ["wast_assert_unlinkable_linkable.wast", 1;
     "wast_assert_unlinkable_start_trap.wast", 1]

let require_normal_failures () =
  List.iter
    (fun path ->
      try
        ignore (Wast_plan.load path);
        failwith ("normal module accepted a static link failure: " ^ path)
      with
      | Ingress_error.Error {kind = Ingress_error.Unsupported; _} -> ())
    ["wast_import_missing_export_unsupported.wast";
     "wast_import_mismatch_unsupported.wast"]

let require_invalid_is_not_unlinkable () =
  try
    ignore (Wast_plan.load "wast_assert_unlinkable_invalid.wast");
    failwith "validation failure was accepted as unlinkable"
  with
  | Ingress_error.Error {kind = Ingress_error.Invalid; _} -> ()

let require_runtime_shape () =
  let text, _ =
    Wast_run.emit ~semantics:"builtins.maude" ~steps:100 ~call_depth:256
      "wast_assert_unlinkable_live_before.wast"
  in
  let generated = compact text in
  List.iter
    (fun fragment ->
      if not (contains generated fragment) then
        failwith ("missing AssertUnlinkable Maude fragment: " ^ fragment))
    ["opcommand.unlinkable:NatImportRefs->Command[ctor].";
     "commands.cons(command.unlinkable(ID,IMPORTS),CMDS))=>script.ready(S,ENV,CMDS)iflinkImports(S,ENV,IMPORTS)=link.error.";
     "commands.cons(command.unlinkable(ID,IMPORTS),CMDS))=>script.wrong-assertion(ID)iflink.ok(EXPORTS):=linkImports(S,ENV,IMPORTS)."];
  String.split_on_char '\n' text
  |> List.iter (fun line ->
       if contains line "[owise]" && not (contains line "eq ") then
         failwith "execution [owise] was introduced")

let () =
  require_static_failures ();
  require_live_plans ();
  require_wrong_assertions ();
  require_normal_failures ();
  require_invalid_is_not_unlinkable ();
  require_runtime_shape ()
