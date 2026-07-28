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

let require_plan () =
  let plan = Wast_plan.load "wast_assert_exception_uncaught.wast" in
  if Wast_plan.checked plan <> 2 || Wast_plan.runtime_assertions plan <> 2 then
    failwith "AssertException changed checked/runtime counts";
  match Wast_plan.commands plan with
  | Wast_plan.Instantiate (1, _, [])
    :: Wast_plan.Exception (1, (1, _, []))
    :: Wast_plan.Return (2, Wast_plan.Invoke (1, _, []), [_]) :: [] -> ()
  | _ -> failwith "AssertException command IDs or invoke payload changed"

let require_exception_plans () =
  List.iter
    (fun path ->
      let plan = Wast_plan.load path in
      if Wast_plan.checked plan <> 1 || Wast_plan.runtime_assertions plan <> 1 then
        failwith ("AssertException metrics changed: " ^ path);
      match Wast_plan.commands plan with
      | [Wast_plan.Instantiate (1, _, []);
         Wast_plan.Exception (1, (1, _, []))] -> ()
      | _ -> failwith ("AssertException was not planned as an invoke: " ^ path))
    ["wast_assert_exception_zero_result.wast";
     "wast_assert_exception_multiple_results.wast";
     "wast_assert_exception_trap.wast";
     "wast_assert_exception_caught.wast"]

let require_get_unsupported () =
  try
    ignore (Wast_plan.load "wast_assert_exception_get.wast");
    failwith "AssertException accepted global.get"
  with
  | Ingress_error.Error
      {kind = Ingress_error.Unsupported; message; _}
      when contains message "global.get action cannot throw an exception" -> ()

let require_runtime_shape () =
  let text, _ =
    Wast_run.emit ~semantics:"builtins.maude" ~steps:100 ~call_depth:256
      "wast_assert_exception_uncaught.wast"
  in
  let generated = compact text in
  List.iter
    (fun fragment ->
      if not (contains generated fragment) then
        failwith ("missing AssertException Maude fragment: " ^ fragment))
    ["opcommand.exception:NatScriptAction->Command[ctor].";
     "opscript.exception:NatInstanceEnvCommandsSpectecTerminal->ScriptState[ctorfrozen(4)].";
     "command.exception(ID,action.invoke(TARGET,NAME,ARGS)),CMDS))=>script.exception(ID,ENV,CMDS,def.invoke(S,findFunc(value('EXPORTS,findInstance(ENV,TARGET)),NAME),ARGS)).";
     "script.exception(ID,ENV,CMDS,C)=>script.exception(ID,ENV,CMDS,C2)ifrel.step(C)=>C2.";
     "config.sym(state.sym(S,rec.frame(LOCALS,CURRENT)),ref.ref-exn-addr(A)instr.throw-ref))=>script.ready(S,ENV,CMDS).";
     "config.sym(state.sym(S,rec.frame(LOCALS,CURRENT)),instr.trap))=>script.wrong-assertion(ID).";
     "config.sym(state.sym(S,rec.frame(LOCALS,CURRENT)),ACTUAL))=>script.wrong-assertion(ID)ifruntimeResults(ACTUAL)=true."];
  let start = find_from text "  rl [call-exception]" 0 in
  let stop = find_from text "  rl [call-action]" start in
  let rules = String.sub text start (stop - start) in
  if contains rules "[owise]" then
    failwith "AssertException execution introduced [owise]";
  if contains rules "exhaust" || contains rules "timeout" then
    failwith "AssertException treats exhaustion or timeout as an exception"

let () =
  require_plan ();
  require_exception_plans ();
  require_get_unsupported ();
  require_runtime_shape ()
