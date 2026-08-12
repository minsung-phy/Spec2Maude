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
  let plan = Wast_plan.load "wast_assert_exhaustion_recursive.wast" in
  if Wast_plan.checked plan <> 1 || Wast_plan.runtime_assertions plan <> 1 then
    failwith "AssertExhaustion did not increment both counters exactly once";
  match Wast_plan.commands plan with
  | [Wast_plan.Instantiate (1, _, []);
     Wast_plan.Exhaustion
       (1, {expected = "call stack exhausted";
            invocation = 1, name, [_]})]
    when Wasm.Types.string_of_name name = "recurse" -> ()
  | _ -> failwith "AssertExhaustion command ID, metadata, or invoke shape changed"

let require_get_unsupported () =
  try
    ignore (Wast_plan.load "wast_assert_exhaustion_get.wast");
    failwith "AssertExhaustion accepted global.get"
  with
  | Ingress_error.Error
      {kind = Ingress_error.Unsupported; region = Some at; message; _}
    when at.Wasm.Source.left.line = 5 &&
         contains message "global.get action cannot exhaust the call depth" -> ()
  | Ingress_error.Error _ ->
      failwith "AssertExhaustion global.get lost its structured source region"

let require_runtime_shape () =
  let text, _ =
    Wast_run.emit ~semantics:"builtins.maude" ~steps:100 ~call_depth:2
      "wast_assert_exhaustion_recursive.wast"
  in
  let generated = compact text in
  List.iter
    (fun fragment ->
      if not (contains generated fragment) then
        failwith ("missing AssertExhaustion Maude fragment: " ^ fragment))
    ["command.exhaustion(1,2,action.invoke(1,";
     "opcommand.exhaustion:NatNatScriptAction->Command[ctor].";
     "opscript.exhaustion:NatNatInstanceEnvCommandsSpectecTerminal->ScriptState[ctorfrozen(5)].";
     "opscript.exhaustion-check:NatNatInstanceEnvCommandsSpectecTerminalSpectecTerminal->ScriptState[ctorfrozen(56)].";
     "activeFrameDepth(instr.frame-sym-sym(N,C,BODY)REST)=_+_(1,activeFrameDepth(BODY)).";
     "activeFrameDepth(instr.label-sym-sym(N,INSTRS,BODY)REST)=activeFrameDepth(BODY).";
     "activeFrameDepth(instr.handler-sym-sym(N,CATCHES,BODY)REST)=activeFrameDepth(BODY).";
     "activeFrameDepth(const(NT,VALUE)REST)=activeFrameDepth(REST)iftypecheck(NT,syn.numtype)/\\typecheck(VALUE,syn.num(NT)).";
     "activeFrameDepth(vconst(vectype.v128,C)REST)=activeFrameDepth(REST).";
     "activeFrameDepth(CREST)=activeFrameDepth(REST)iftypecheck(C,syn.ref).";
     "=>script.exhaustion-check(ID,REQUIRED,ENV,CMDS,S2,config.sym(state.sym(S2,F2),INSTRS))ifrel.step(config.sym(state.sym(S,rec.frame(LOCALS,CURRENT)),BODY))=>config.sym(state.sym(S2,F2),INSTRS).";
     "script.exhaustion-check(ID,REQUIRED,ENV,CMDS,S,config.sym(C2,INSTRS))=>script.ready(S,ENV,CMDS)if_>_(activeFrameDepth(INSTRS),REQUIRED)=true.";
     "script.exhaustion-check(ID,REQUIRED,ENV,CMDS,S,C)=>script.exhaustion(ID,REQUIRED,ENV,CMDS,C)ifconfig.sym(C2,INSTRS):=C/\\_<=_(activeFrameDepth(INSTRS),REQUIRED)=true.";
     "trap))=>script.wrong-assertion(ID).";
     "ref.ref-exn-addr(A)instr.throw-ref))=>script.wrong-assertion(ID).";
     "ifruntimeResults(ACTUAL)=true."];
  if contains text "call stack exhausted" then
    failwith "expected message leaked across the documented payload-free boundary";
  if contains generated "activeFrameDepth(CREST)=activeFrameDepth(REST)iftypecheck(C,syn.val)." then
    failwith "activeFrameDepth still treats semantic syn.val as an instruction";
  let start = find_from text "  rl [call-exhaustion]" 0 in
  let stop = find_from text "  rl [done]" start in
  let rules = String.sub text start (stop - start) in
  if contains rules "[owise]" then
    failwith "AssertExhaustion execution introduced [owise]";
  if contains rules "rel.steps" || contains rules "timeout" then
    failwith "AssertExhaustion accepted search exhaustion or timeout"

let require_call_depth_argument () =
  let text, _ =
    Wast_run.emit ~semantics:"builtins.maude" ~steps:100 ~call_depth:256
      "wast_assert_exhaustion_zero.wast"
  in
  if not (contains (compact text) "command.exhaustion(1,256,") then
    failwith "Wast_run.emit did not materialize its call-depth argument";
  try
    ignore
      (Wast_run.emit ~semantics:"builtins.maude" ~steps:1 ~call_depth:(-1)
         "wast_assert_exhaustion_zero.wast");
    failwith "Wast_run.emit accepted a negative call depth"
  with Invalid_argument _ -> ()

let () =
  require_plan ();
  require_get_unsupported ();
  require_runtime_shape ();
  require_call_depth_argument ()
