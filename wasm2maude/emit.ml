let term m = Maude_term.to_string (Encode.module_ m)

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
        | Frontend.Non_function_export -> "requested export is not a function"
        | Frontend.Unresolved_function_type ->
            "validated function export retained an unresolved type index"
        | Frontend.Wrong_arity ->
            "function invocation has the wrong number of arguments"
        | Frontend.Wrong_argument_type _ ->
            "function invocation argument has the wrong type"
      in
      Ingress_error.raise Ingress_error.Unsupported m.source message

let invocation m export args =
  let () = check_arguments m export args in
  let export = Encode.name export |> Maude_term.to_string in
  let args =
    args |> List.map Encode.num_value |> Maude_term.seq
    |> Maude_term.to_string
  in
  term m, export, args

let typecheck ~semantics m =
  Printf.sprintf
    "load %s\n\nmod WASM2MAUDE-INPUT is\n  protecting WASM-BUILTINS .\nendm\n\nred in WASM2MAUDE-INPUT :\n  typecheck(\n    %s,\n    syn.module) .\n"
    semantics (term m)

let instantiate ~semantics m =
  if Frontend.import_count m <> 0 then
    Ingress_error.raise Ingress_error.Unsupported m.source
      "module instantiation needs an explicit host-import address mapping"
  else
    Printf.sprintf
      "load %s\n\nmod WASM2MAUDE-INPUT is\n  protecting WASM-BUILTINS .\nendm\n\nrew [1] in WASM2MAUDE-INPUT :\n  def.instantiate(\n    rec.store(eps, eps, eps, eps, eps, eps, eps, eps, eps, eps),\n    %s,\n    eps) .\n"
      semantics (term m)

let run ~semantics ~export ~args ~steps m =
  if Frontend.import_count m <> 0 then
    Ingress_error.raise Ingress_error.Unsupported m.source
      "running a module with imports needs an explicit host-address mapping"
  else
    let input, export, args = invocation m export args in
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
       \  op findFunc : SpectecTerminals SpectecTerminals ~> SpectecTerminal .\n\n\
       \  vars C C2 S MI ADDR XA : SpectecTerminal .\n\
       \  vars NAME OTHER LOCALS EXPORTS : SpectecTerminals .\n\n\
       \  eq inputModule = %s .\n\
       \  eq inputName = %s .\n\
       \  eq inputArgs = %s .\n\
       \  eq emptyStore = rec.store(eps, eps, eps, eps, eps,\n\
       \    eps, eps, eps, eps, eps) .\n\n\
       \  eq findFunc(\n\
       \    rec.exportinst(NAME, externaddr.func(ADDR)) EXPORTS, NAME) = ADDR .\n\
       \  ceq findFunc(rec.exportinst(OTHER, XA) EXPORTS, NAME) =\n\
       \      findFunc(EXPORTS, NAME)\n\
       \    if OTHER =/= NAME .\n\n\
       \  crl [instantiate] : boot => init(C)\n\
       \    if def.instantiate(emptyStore, inputModule, eps) => C .\n\
       \  crl [init-step] : init(C) => init(C2)\n\
       \    if rel.step(C) => C2 .\n\
       \  rl [invoke] :\n\
       \    init(config.sym(state.sym(S, rec.frame(LOCALS, MI)), eps))\n\
       \    => exec(def.invoke(\n\
       \      S, findFunc(value('EXPORTS, MI), inputName), inputArgs)) .\n\
       \  crl [step] : exec(C) => exec(C2)\n\
       \    if rel.step(C) => C2 .\n\
       endm\n\n\
       rew [%d] in WASM2MAUDE-RUN : boot .\n"
      semantics input export args steps

let modelcheck ~semantics ~export ~args ~expected ~rejected ~steps m =
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
    let result_type =
      Encode.result_numtype expected_type |> Maude_term.to_string
    in
    let expected =
      Encode.num_instr expected |> Maude_term.to_string
    in
    let rejected =
      Encode.num_instr rejected |> Maude_term.to_string
    in
    Printf.sprintf
      "load %s\nload model-checker.maude\n\nmod WASM2MAUDE-MODELCHECK is\n\
       \  protecting WASM-BUILTINS .\n\
       \  including MODEL-CHECKER .\n\n\
       \  sort ModelState .\n\
       \  subsort ModelState < State .\n\
       \  op boot : -> ModelState [ctor] .\n\
       \  op init : SpectecTerminal -> ModelState [ctor frozen (1)] .\n\
       \  op ready : SpectecTerminal SpectecTerminal -> ModelState [ctor] .\n\
       \  op exec : SpectecTerminal -> ModelState [ctor frozen (1)] .\n\
       \  op finished : SpectecTerminal SpectecTerminal -> ModelState [ctor] .\n\n\
       \  op inputModule : -> SpectecTerminal .\n\
       \  op inputName : -> SpectecTerminals .\n\
       \  op inputArgs : -> SpectecTerminals .\n\
       \  op emptyStore : -> SpectecTerminal .\n\
       \  op expected : -> SpectecTerminal .\n\
       \  op rejected : -> SpectecTerminal .\n\
       \  op findFunc : SpectecTerminals SpectecTerminals ~> SpectecTerminal .\n\
       \  op returned : SpectecTerminals -> Prop [ctor] .\n\n\
       \  vars C S MI ADDR XA VALUE RESULT : SpectecTerminal .\n\
       \  vars NAME OTHER LOCALS EXPORTS : SpectecTerminals .\n\
       \  var ST : ModelState .\n\
       \  var P : Prop .\n\n\
       \  eq inputModule = %s .\n\
       \  eq inputName = %s .\n\
       \  eq inputArgs = %s .\n\
       \  eq expected = %s .\n\
       \  eq rejected = %s .\n\
       \  eq emptyStore = rec.store(eps, eps, eps, eps, eps,\n\
       \    eps, eps, eps, eps, eps) .\n\n\
       \  eq findFunc(\n\
       \    rec.exportinst(NAME, externaddr.func(ADDR)) EXPORTS, NAME) = ADDR .\n\
       \  ceq findFunc(rec.exportinst(OTHER, XA) EXPORTS, NAME) =\n\
       \      findFunc(EXPORTS, NAME)\n\
       \    if OTHER =/= NAME .\n\n\
       \  crl [instantiate] : boot => init(C)\n\
       \    if def.instantiate(emptyStore, inputModule, eps) => C .\n\
       \  crl [initialize] : init(C) => ready(S, MI)\n\
       \    if rel.steps(C) =>\n\
       \      config.sym(state.sym(S, rec.frame(LOCALS, MI)), eps) .\n\
       \  rl [invoke] :\n\
       \    ready(S, MI)\n\
       \    => exec(def.invoke(\n\
       \      S, findFunc(value('EXPORTS, MI), inputName), inputArgs)) .\n\
       \  crl [execute] : exec(C) =>\n\
       \      finished(S, const(%s, VALUE))\n\
       \    if rel.steps(C) => config.sym(S, const(%s, VALUE)) .\n\n\
       \  eq finished(S, RESULT) |= returned(RESULT) = true .\n\
       \  eq ST |= P = false [owise] .\n\
       endm\n\n\
       rew [%d] in WASM2MAUDE-MODELCHECK : boot .\n\n\
       search [1, %d] in WASM2MAUDE-MODELCHECK :\n\
       \  boot =>* finished(S, %s) .\n\n\
       search [1, %d] in WASM2MAUDE-MODELCHECK :\n\
       \  boot =>* finished(S, %s) .\n\n\
       red in WASM2MAUDE-MODELCHECK :\n\
       \  modelCheck(boot, <> returned(expected)) .\n\
       red in WASM2MAUDE-MODELCHECK :\n\
       \  modelCheck(boot, [] ~ returned(rejected)) .\n\
       red in WASM2MAUDE-MODELCHECK :\n\
       \  modelCheck(boot, <> returned(rejected)) .\n"
      semantics input export args expected rejected result_type result_type steps
      steps expected steps rejected
