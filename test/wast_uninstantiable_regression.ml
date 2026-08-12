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

let find_from text fragment start =
  let rec find i =
    if i + String.length fragment > String.length text then
      failwith ("missing generated boundary: " ^ fragment)
    else if String.sub text i (String.length fragment) = fragment then i
    else find (i + 1)
  in
  find start

let uninstantiable_commands path =
  Wast_plan.load path |> Wast_plan.commands
  |> List.filter_map (function
       | Wast_plan.Uninstantiable (id, plan) -> Some (id, plan)
       | Wast_plan.Instantiate _ | Wast_plan.Unlinkable _
       | Wast_plan.Return _ | Wast_plan.Trap _
       | Wast_plan.Exception _ | Wast_plan.Exhaustion _
       | Wast_plan.Do _ -> None)

let require_named_live_plan () =
  let plan = Wast_plan.load "wast_assert_uninstantiable_trap.wast" in
  if Wast_plan.checked plan <> 2 || Wast_plan.runtime_assertions plan <> 2 then
    failwith "uninstantiable assertion changed checked/runtime counts";
  (match Wast_plan.commands plan with
   | Wast_plan.Uninstantiable
       (1, {expected = "expected-source-message";
            instantiation = Wast_plan.Live_instantiation (module_, [])})
     :: Wast_plan.Instantiate (1, _, []) :: Wast_plan.Return (2, _, _) :: []
     when Maude_term.to_string module_ <> "" -> ()
   | _ ->
       failwith
         "named source lookup, expected metadata, or instance allocation changed")

let require_static_plans () =
  let plan = Wast_plan.load "wast_assert_uninstantiable_static.wast" in
  let commands = uninstantiable_commands "wast_assert_uninstantiable_static.wast" in
  if List.map fst commands <> [1; 2; 3] || Wast_plan.checked plan <> 3
     || Wast_plan.runtime_assertions plan <> 3
  then failwith "static failures did not each consume one runtime command ID";
  List.iter
    (fun (_, plan) ->
      match plan.Wast_plan.instantiation with
      | Wast_plan.Static_link_failure -> ()
      | Wast_plan.Live_instantiation _ ->
          failwith "static link failure was planned as live instantiation")
    commands;
  let host = Wast_plan.host plan in
  if List.length host.providers <> 1 || List.length host.funcs <> 1 then
    failwith "host allocation before static failure was not preserved"

let require_live_link_plan () =
  match uninstantiable_commands
          "wast_assert_uninstantiable_live_link_error.wast" with
  | [1, {expected = "incompatible import type";
         instantiation = Wast_plan.Live_instantiation (_, [import])}]
    when import.Wast_plan.requirement = Wast_plan.Current_memory_min 2L -> ()
  | _ -> failwith "live-store minimum check was not preserved in the plan"

let require_failed_instance_not_allocated () =
  let instance_ids =
    Wast_plan.load "wast_assert_uninstantiable_memory.wast"
    |> Wast_plan.commands
    |> List.filter_map (function
         | Wast_plan.Instantiate (id, _, _) -> Some id
         | Wast_plan.Unlinkable _ | Wast_plan.Uninstantiable _
         | Wast_plan.Return _ | Wast_plan.Trap _
         | Wast_plan.Exception _ | Wast_plan.Exhaustion _
         | Wast_plan.Do _ -> None)
  in
  if instance_ids <> [1; 2] then
    failwith "failed module consumed or registered an instance ID"

let require_runtime_shape () =
  let text, _ =
    Wast_run.emit ~semantics:"builtins.maude" ~steps:100 ~call_depth:256
      "wast_assert_uninstantiable_trap.wast"
  in
  let generated = compact text in
  List.iter
    (fun fragment ->
      if not (contains generated fragment) then
        failwith ("missing AssertUninstantiable Maude fragment: " ^ fragment))
    ["opcommand.uninstantiable-static:Nat->Command[ctor].";
     "opcommand.uninstantiable:NatSpectecTerminalImportRefs->Command[ctor].";
     "opscript.uninstantiable:NatInstanceEnvCommandsSpectecTerminal->ScriptState[ctorfrozen(4)].";
     "command.uninstantiable-static(ID),CMDS))=>script.wrong-assertion(ID).";
     "command.uninstantiable(ID,M,IMPORTS),CMDS))=>script.wrong-assertion(ID)iflinkImports(S,ENV,IMPORTS)=link.error.";
     "command.uninstantiable(ID,M,IMPORTS),CMDS))=>script.uninstantiable(ID,ENV,CMDS,C)iflink.ok(EXPORTS):=linkImports(S,ENV,IMPORTS)/\\def.instantiate(S,M,EXPORTS)=>C.";
     "script.uninstantiable(ID,ENV,CMDS,C)=>script.uninstantiable(ID,ENV,CMDS,C2)ifrel.step(C)=>C2.";
     "config.sym(state.sym(S,rec.frame(LOCALS,CURRENT)),trap))=>script.ready(S,ENV,CMDS).";
     "config.sym(state.sym(S,rec.frame(LOCALS,CURRENT)),ref.ref-exn-addr(A)instr.throw-ref))=>script.ready(S,ENV,CMDS).";
     "config.sym(state.sym(S,rec.frame(LOCALS,CURRENT)),eps))=>script.wrong-assertion(ID)."];
  let start = find_from text "  rl [assert-uninstantiable-static" 0 in
  let stop = find_from text "  rl [call-return]" start in
  let assertion_rules = String.sub text start (stop - start) in
  if contains assertion_rules "[owise]" then
    failwith "AssertUninstantiable execution introduced [owise]";
  if contains assertion_rules "instances.cons" then
    failwith "AssertUninstantiable registered the failed module";
  if contains text "expected-source-message" then
    failwith "expected message leaked across the explicitly ignored Maude boundary"

let () =
  require_named_live_plan ();
  require_static_plans ();
  require_live_link_plan ();
  require_failed_instance_not_allocated ();
  require_runtime_shape ()
