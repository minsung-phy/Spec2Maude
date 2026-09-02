module T = Spectec_term

let render = Maude_term.to_string
let term m = render (Encode.module_ m)
let empty = T.seq []

let empty_store =
  T.app "rec.store" (List.init 10 (fun _ -> empty))

let variable = T.atom
let pair left right = T.app "_;_" [left; right]

let export_instance name address =
  T.app "rec.exportinst" [name; address]

let function_address address = T.app "externaddr.func" [address]
let export_sequence export rest = T.seq [export; rest]
let find_function exports name = T.app "findFunc" [exports; name]

let instantiate_term store module_ imports =
  T.app "instantiate" [store; module_; imports]

let invoke store address arguments =
  T.app "invoke" [store; address; arguments]

let step config = T.app "Step" [config]

type runtime_terms = {
  function_export : string;
  other_export : string;
  instantiate : string;
  step : string;
  initialized : string;
  invocation : string;
}

let check_arguments m export args =
  let arguments =
    List.map
      (fun argument -> Wasm.Types.NumT (Wasm.Value.type_of_num argument))
      args
  in
  match Frontend.validate_invocation m export arguments with
  | Ok () -> ()
  | Error error ->
      let message =
        match error with
        | Frontend.Missing_export -> "requested function export does not exist"
        | Frontend.Non_function_export ->
            "requested export is not a function"
        | Frontend.Unresolved_function_type ->
            "validated function export retained an unresolved type index"
        | Frontend.Wrong_arity ->
            "function invocation has the wrong number of arguments"
        | Frontend.Wrong_argument_type _ ->
            "function invocation argument has the wrong type"
      in
      Ingress_error.raise Ingress_error.Unsupported m.source message

let invocation m export args =
  check_arguments m export args;
  let export = Encode.name export |> render in
  let args = args |> List.map Encode.num_value |> T.seq |> render in
  term m, export, args

let typecheck ~semantics m =
  let check =
    T.app "typecheck" [Encode.module_ m; T.atom "syn.module"] |> render
  in
  Printf.sprintf
    "load %s\n\nmod WASM2MAUDE-INPUT is\n  protecting WASM-BUILTINS .\nendm\n\nred in WASM2MAUDE-INPUT :\n  %s .\n"
    semantics check

let instantiate ~semantics m =
  if Frontend.import_count m <> 0 then
    Ingress_error.raise Ingress_error.Unsupported m.source
      "module instantiation needs an explicit host-import address mapping"
  else
    let request =
      instantiate_term empty_store (Encode.module_ m) empty |> render
    in
    Printf.sprintf
      "load %s\n\nmod WASM2MAUDE-INPUT is\n  protecting WASM-BUILTINS .\nendm\n\nrew [1] in WASM2MAUDE-INPUT :\n  %s .\n"
      semantics request

let runtime_terms () =
  let c = variable "C" in
  let z = variable "Z" in
  let exports = variable "EXPORTS" in
  let name = variable "NAME" in
  let other = variable "OTHER" in
  let address = variable "ADDR" in
  let other_address = variable "XA" in
  let function_export =
    export_instance name (function_address address)
    |> fun export -> export_sequence export exports
    |> render
  in
  let other_export =
    export_instance other other_address
    |> fun export -> export_sequence export exports
    |> render
  in
  let instantiate =
    instantiate_term (variable "emptyStore") (variable "inputModule") empty
    |> render
  in
  let initialized = pair z empty |> render in
  let store = T.app "spectec-store" [z] in
  let module_ = T.app "spectec-moduleinst" [z] in
  let address =
    find_function
      (T.app "value" [variable "'EXPORTS"; module_])
      (variable "inputName")
  in
  let invocation = invoke store address (variable "inputArgs") |> render in
  { function_export;
    other_export;
    instantiate;
    step = render (step c);
    initialized;
    invocation }

let run ~semantics ~export ~args ~steps:limit m =
  if Frontend.import_count m <> 0 then
    Ingress_error.raise Ingress_error.Unsupported m.source
      "running a module with imports needs an explicit host-address mapping"
  else
    let input, export, args = invocation m export args in
    let runtime = runtime_terms () in
    Printf.sprintf
      "load %s\n\nmod WASM2MAUDE-RUN is\n\
       \  protecting WASM-BUILTINS .\n\n\
       \  sort RunState .\n\
       \  op boot : -> RunState [ctor] .\n\
       \  op init : SpectecTerminal -> RunState [ctor frozen (1)] .\n\
       \  op exec : SpectecTerminal -> RunState [ctor frozen (1)] .\n\n\
       \  op inputModule : -> SpectecTerminal .\n\
       \  op inputName : -> SpectecTerminals .\n\
       \  op inputArgs : -> SpectecTerminals .\n\
       \  op emptyStore : -> SpectecTerminal .\n\
       \  op findFunc : SpectecTerminals SpectecTerminals ~> Nat .\n\n\
       \  vars C C2 Z XA : SpectecTerminal .\n\
       \  vars NAME OTHER EXPORTS : SpectecTerminals .\n\
       \  var ADDR : Nat .\n\n\
       \  eq inputModule = %s .\n\
       \  eq inputName = %s .\n\
       \  eq inputArgs = %s .\n\
       \  eq emptyStore = %s .\n\n\
       \  eq findFunc(%s, NAME) = ADDR .\n\
       \  ceq findFunc(%s, NAME) = findFunc(EXPORTS, NAME)\n\
       \    if OTHER =/= NAME .\n\n\
       \  crl [instantiate] : boot => init(C)\n\
       \    if %s => C .\n\
       \  crl [init-step] : init(C) => init(C2)\n\
       \    if %s => C2 .\n\
       \  crl [invoke] : init(C) => exec(%s)\n\
       \    if %s := C .\n\
       \  crl [step] : exec(C) => exec(C2)\n\
       \    if %s => C2 .\n\
       endm\n\n\
       rew [%d] in WASM2MAUDE-RUN : boot .\n"
      semantics input export args (render empty_store) runtime.function_export
      runtime.other_export runtime.instantiate runtime.step runtime.invocation
      runtime.initialized runtime.step limit

let modelcheck ~semantics ~export ~args ~expected ~rejected ~steps:limit m =
  if Frontend.import_count m <> 0 then
    Ingress_error.raise Ingress_error.Unsupported m.source
      "model checking a module with imports needs an explicit host-address mapping"
  else
    let input, export, args = invocation m export args in
    let expected_type = Wasm.Value.type_of_num expected in
    let rejected_type = Wasm.Value.type_of_num rejected in
    if expected_type <> rejected_type then
      Ingress_error.raise Ingress_error.Unsupported m.source
        "expected and rejected model-checking results must have the same type";
    let expected = Encode.num_instr expected |> render in
    let rejected = Encode.num_instr rejected |> render in
    let runtime = runtime_terms () in
    Printf.sprintf
      "load %s\nload model-checker.maude\n\nmod WASM2MAUDE-MODELCHECK is\n\
       \  protecting WASM-BUILTINS .\n\
       \  including MODEL-CHECKER .\n\n\
       \  sort ModelState .\n\
       \  subsort ModelState < State .\n\
       \  op boot : -> ModelState [ctor] .\n\
       \  op init : SpectecTerminal -> ModelState [ctor frozen (1)] .\n\
       \  op ready : SpectecTerminal -> ModelState [ctor] .\n\
       \  op exec : SpectecTerminal -> ModelState [ctor frozen (1)] .\n\
       \  op finished : SpectecTerminal -> ModelState [ctor] .\n\n\
       \  op inputModule : -> SpectecTerminal .\n\
       \  op inputName : -> SpectecTerminals .\n\
       \  op inputArgs : -> SpectecTerminals .\n\
       \  op emptyStore : -> SpectecTerminal .\n\
       \  op expected : -> SpectecTerminal .\n\
       \  op rejected : -> SpectecTerminal .\n\
       \  op findFunc : SpectecTerminals SpectecTerminals ~> Nat .\n\
       \  op returned : SpectecTerminal -> Prop [ctor] .\n\n\
       \  vars C C2 Z XA RESULT : SpectecTerminal .\n\
       \  vars NAME OTHER EXPORTS RESULTS : SpectecTerminals .\n\
       \  var ADDR : Nat .\n\
       \  var ST : ModelState .\n\
       \  var P : Prop .\n\n\
       \  eq inputModule = %s .\n\
       \  eq inputName = %s .\n\
       \  eq inputArgs = %s .\n\
       \  eq expected = %s .\n\
       \  eq rejected = %s .\n\
       \  eq emptyStore = %s .\n\n\
       \  eq findFunc(%s, NAME) = ADDR .\n\
       \  ceq findFunc(%s, NAME) = findFunc(EXPORTS, NAME)\n\
       \    if OTHER =/= NAME .\n\n\
       \  crl [instantiate] : boot => init(C)\n\
       \    if %s => C .\n\
       \  crl [init-step] : init(C) => init(C2)\n\
       \    if %s => C2 .\n\
       \  crl [initialize] : init(C) => ready(Z)\n\
       \    if %s := C .\n\
       \  rl [invoke] : ready(Z) => exec(%s) .\n\
       \  crl [execute-step] : exec(C) => exec(C2)\n\
       \    if %s => C2 .\n\
       \  crl [finished] : exec(C) => finished(RESULT)\n\
       \    if (Z ; RESULTS) := C\n\
       \    /\\ RESULT := RESULTS\n\
       \    /\\ typecheck(RESULT, val) = true .\n\n\
       \  eq finished(RESULT) |= returned(RESULT) = true .\n\
       \  eq ST |= P = false [owise] .\n\
       endm\n\n\
       rew [%d] in WASM2MAUDE-MODELCHECK : boot .\n\n\
       search [1, %d] in WASM2MAUDE-MODELCHECK :\n\
       \  boot =>* finished(RESULT)\n\
       \  such that RESULT == expected .\n\n\
       search [1, %d] in WASM2MAUDE-MODELCHECK :\n\
       \  boot =>* finished(RESULT)\n\
       \  such that RESULT == rejected .\n\n\
       red in WASM2MAUDE-MODELCHECK :\n\
       \  modelCheck(boot, <> returned(expected)) .\n\
       red in WASM2MAUDE-MODELCHECK :\n\
       \  modelCheck(boot, [] ~ returned(rejected)) .\n\
       red in WASM2MAUDE-MODELCHECK :\n\
       \  modelCheck(boot, <> returned(rejected)) .\n"
      semantics input export args expected rejected (render empty_store)
      runtime.function_export runtime.other_export runtime.instantiate
      runtime.step runtime.initialized runtime.invocation runtime.step limit
      limit limit
