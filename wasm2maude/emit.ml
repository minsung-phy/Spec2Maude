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
    {|load %s

mod WASM2MAUDE-INPUT is
  protecting WASM-BUILTINS .
endm

red in WASM2MAUDE-INPUT :
  %s .
|}
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
      {|load %s

mod WASM2MAUDE-INPUT is
  protecting WASM-BUILTINS .
endm

rew [1] in WASM2MAUDE-INPUT :
  %s .
|}
      semantics request

let runtime_terms ?(name = Fun.id) ?(arguments = "inputArgs") () =
  let c = variable "C" in
  let z = variable "Z" in
  let exports = variable "EXPORTS" in
  let export_name = variable "NAME" in
  let prefix = variable "EXPORT-PREFIX" in
  let address = variable "ADDR" in
  let other_address = variable "XA" in
  let function_export =
    export_instance export_name (function_address address)
    |> fun export -> T.seq [prefix; export; exports]
    |> render
  in
  let other_export =
    export_instance export_name other_address
    |> fun export -> T.seq [prefix; export; exports]
    |> render
  in
  let instantiate =
    instantiate_term (variable (name "emptyStore"))
      (variable (name "inputModule")) empty
    |> render
  in
  let initialized = pair z empty |> render in
  let store = T.app "spectec-store" [z] in
  let module_ = T.app "spectec-moduleinst" [z] in
  let address =
    T.app (name "findFunc")
      [T.app "value" [variable "'EXPORTS"; module_];
       variable (name "inputName")]
  in
  let invocation = invoke store address (variable arguments) |> render in
  { function_export;
    other_export;
    instantiate;
    step = render (step c);
    initialized;
    invocation }

let export_lookup name runtime =
  Printf.sprintf
    "  ceq %s(%s, NAME) = ADDR\n\
     \    if not %s(EXPORT-PREFIX, NAME) .\n\
     \  eq %s(%s, NAME) = true .\n\
     \  eq %s(EXPORTS, NAME) = false [owise] .\n"
    (name "findFunc") runtime.function_export (name "hasExport")
    (name "hasExport") runtime.other_export (name "hasExport")

(* A fresh instance for each call. The enclosing model supplies well-typed
   arguments and owns persistent state, the environment, and properties. *)
let harness ~module_name ~prefix ~export (m : Frontend.module_) =
  let identifier text =
    let letter = function 'a'..'z' | 'A'..'Z' -> true | _ -> false in
    String.length text > 0 && letter text.[0]
    && String.for_all
         (fun c -> letter c || (c >= '0' && c <= '9') || c = '-') text
  in
  if not (identifier module_name && identifier prefix) then
    Ingress_error.raise Ingress_error.Unsupported m.source
      "harness module name and prefix must start with a letter and contain only letters, digits, or hyphens";
  if Frontend.import_count m <> 0 then
    Ingress_error.raise Ingress_error.Unsupported m.source
      "a harness with imports needs an explicit host-address mapping";
  (match Frontend.function_parameters m export with
   | Ok _ -> ()
   | Error _ ->
       Ingress_error.raise Ingress_error.Unsupported m.source
         "harness invocation requires a function export with a resolved type");
  let name suffix = prefix ^ String.capitalize_ascii suffix in
  let runtime = runtime_terms ~name ~arguments:"ARGS" () in
  let buffer = Buffer.create 4096 in
  let emit fmt = Printf.bprintf buffer fmt in
  let state = name "RunState" in
  emit "--- Generated by wasm2maude harness. Load semantics.maude before this file.\n";
  emit "--- Each call uses a fresh instance; the caller supplies well-typed arguments.\n";
  emit "mod %s is\n  protecting WASM-BUILTINS .\n\n" module_name;
  emit "  sort %s .\n" state;
  emit "  op %s : ValList -> %s [ctor] .\n" (name "call") state;
  emit "  op %s : SpectecTerminal ValList -> %s [ctor frozen (1)] .\n"
    (name "init") state;
  emit "  op %s : SpectecTerminal -> %s [ctor frozen (1)] .\n"
    (name "exec") state;
  emit "  op %s : ValList -> %s [ctor] .\n\n" (name "result") state;
  emit "  op %s : -> SpectecTerminal .\n" (name "inputModule");
  emit "  op %s : -> SpectecTerminals .\n" (name "inputName");
  emit "  op %s : -> SpectecTerminal .\n" (name "emptyStore");
  emit "  op %s : SpectecTerminals SpectecTerminals ~> Nat .\n" (name "findFunc");
  emit "  op %s : SpectecTerminals SpectecTerminals -> Bool .\n\n" (name "hasExport");
  emit "  vars C C2 Z XA : SpectecTerminal .\n";
  emit "  vars NAME EXPORT-PREFIX EXPORTS : SpectecTerminals .\n";
  emit "  vars ARGS RESULT : ValList .\n  var ADDR : Nat .\n\n";
  emit "  eq %s = %s .\n" (name "inputModule") (term m);
  emit "  eq %s = %s .\n" (name "inputName") (render (Encode.name export));
  emit "  eq %s = %s .\n\n" (name "emptyStore") (render empty_store);
  emit "%s\n" (export_lookup name runtime);
  emit "  crl [%s] : %s(ARGS) => %s(C, ARGS)\n    if %s => C .\n"
    (name "instantiate") (name "call") (name "init") runtime.instantiate;
  emit "  crl [%s] : %s(C, ARGS) => %s(C2, ARGS)\n    if %s => C2 .\n"
    (name "init-step") (name "init") (name "init") runtime.step;
  emit "  crl [%s] : %s(C, ARGS) => %s(%s)\n    if %s := C .\n"
    (name "invoke") (name "init") (name "exec") runtime.invocation runtime.initialized;
  emit "  crl [%s] : %s(C) => %s(C2)\n    if %s => C2 .\n"
    (name "step") (name "exec") (name "exec") runtime.step;
  emit "  crl [%s] : %s(C) => %s(RESULT)\n    if (Z ; RESULT) := C .\nendm\n"
    (name "finished") (name "exec") (name "result");
  Buffer.contents buffer

let run ~semantics ~export ~args ~steps:limit m =
  if Frontend.import_count m <> 0 then
    Ingress_error.raise Ingress_error.Unsupported m.source
      "running a module with imports needs an explicit host-address mapping"
  else
    let input, export, args = invocation m export args in
    let runtime = runtime_terms () in
    Printf.sprintf
      {|load %s

mod WASM2MAUDE-RUN is
  protecting WASM-BUILTINS .

  sort RunState .
  op boot : -> RunState [ctor] .
  op init : SpectecTerminal -> RunState [ctor frozen (1)] .
  op exec : SpectecTerminal -> RunState [ctor frozen (1)] .

  op inputModule : -> SpectecTerminal .
  op inputName : -> SpectecTerminals .
  op inputArgs : -> ValList .
  op emptyStore : -> SpectecTerminal .
  op findFunc : SpectecTerminals SpectecTerminals ~> Nat .
  op hasExport : SpectecTerminals SpectecTerminals -> Bool .

  vars C C2 Z XA : SpectecTerminal .
  vars NAME EXPORT-PREFIX EXPORTS : SpectecTerminals .
  var ADDR : Nat .

  eq inputModule = %s .
  eq inputName = %s .
  eq inputArgs = %s .
  eq emptyStore = %s .

%s
  crl [instantiate] : boot => init(C)
    if %s => C .
  crl [init-step] : init(C) => init(C2)
    if %s => C2 .
  crl [invoke] : init(C) => exec(%s)
    if %s := C .
  crl [step] : exec(C) => exec(C2)
    if %s => C2 .
endm

rew [%d] in WASM2MAUDE-RUN : boot .
|}
      semantics input export args (render empty_store) (export_lookup Fun.id runtime)
      runtime.instantiate runtime.step runtime.invocation
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
      {|load %s
load model-checker.maude

mod WASM2MAUDE-MODELCHECK is
  protecting WASM-BUILTINS .
  including MODEL-CHECKER * (
    op _xor_ : Nat Nat -> Nat to integerXor,
    op _+_ : String String -> String to stringConcat,
    op _<_ : String String -> Bool to stringLess,
    op _<=_ : String String -> Bool to stringLessEqual,
    op _>_ : String String -> Bool to stringGreater,
    op _>=_ : String String -> Bool to stringGreaterEqual,
    op char : Nat -> Char to nativeChar
  ) .

  sort ModelState .
  subsort ModelState < State .
  op boot : -> ModelState [ctor] .
  op init : SpectecTerminal -> ModelState [ctor frozen (1)] .
  op ready : SpectecTerminal -> ModelState [ctor] .
  op exec : SpectecTerminal -> ModelState [ctor frozen (1)] .
  op finished : ValList -> ModelState [ctor] .

  op inputModule : -> SpectecTerminal .
  op inputName : -> SpectecTerminals .
  op inputArgs : -> ValList .
  op emptyStore : -> SpectecTerminal .
  op expected : -> ValList .
  op rejected : -> ValList .
  op findFunc : SpectecTerminals SpectecTerminals ~> Nat .
  op hasExport : SpectecTerminals SpectecTerminals -> Bool .
  op returned : ValList -> Prop [ctor] .

  vars C C2 Z XA : SpectecTerminal .
  vars NAME EXPORT-PREFIX EXPORTS : SpectecTerminals .
  var RESULT : ValList .
  var ADDR : Nat .
  var ST : ModelState .
  var P : Prop .

  eq inputModule = %s .
  eq inputName = %s .
  eq inputArgs = %s .
  eq expected = %s .
  eq rejected = %s .
  eq emptyStore = %s .

%s
  crl [instantiate] : boot => init(C)
    if %s => C .
  crl [init-step] : init(C) => init(C2)
    if %s => C2 .
  crl [initialize] : init(C) => ready(Z)
    if %s := C .
  rl [invoke] : ready(Z) => exec(%s) .
  crl [execute-step] : exec(C) => exec(C2)
    if %s => C2 .
  crl [finished] : exec(C) => finished(RESULT)
    if (Z ; RESULT) := C .

  eq finished(RESULT) |= returned(RESULT) = true .
  eq ST |= P = false [owise] .
endm

rew [%d] in WASM2MAUDE-MODELCHECK : boot .

search [1, %d] in WASM2MAUDE-MODELCHECK :
  boot =>* finished(RESULT)
  such that RESULT == expected .

search [1, %d] in WASM2MAUDE-MODELCHECK :
  boot =>* finished(RESULT)
  such that RESULT == rejected .

red in WASM2MAUDE-MODELCHECK :
  modelCheck(boot, <> returned(expected)) .
red in WASM2MAUDE-MODELCHECK :
  modelCheck(boot, [] ~ returned(rejected)) .
red in WASM2MAUDE-MODELCHECK :
  modelCheck(boot, <> returned(rejected)) .
|}
      semantics input export args expected rejected (render empty_store)
      (export_lookup Fun.id runtime) runtime.instantiate
      runtime.step runtime.initialized runtime.invocation runtime.step limit
      limit limit
