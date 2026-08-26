type report = {
  commands : int;
  checked_assertions : int;
  runtime_assertions : int;
}

let emit ~semantics ~steps ~call_depth source =
  if call_depth < 0 then invalid_arg "Wast_run.emit: negative call depth";
  let plan = Wast_plan.load source in
  let commands =
    Wast_plan.commands plan
    |> Wast_command_encode.commands ~call_depth
    |> Maude_term.to_string
  in
  let host = Wast_plan.host plan in
  let host_store = Wast_host_encode.store host |> Maude_term.to_string in
  let host_instances =
    Wast_host_encode.instances host.providers
    |> Maude_term.to_string
  in
  let host_functions =
    Wast_host_encode.function_addresses host.funcs
    |> Maude_term.to_string
  in
  let text =
    Wast_harness.render ~semantics ~steps ~commands ~host_store ~host_instances
      ~host_functions
  in
  let commands = Wast_plan.source_commands plan in
  let checked_assertions = Wast_plan.checked_assertions plan in
  let runtime_assertions = Wast_plan.runtime_assertions plan in
  text, {commands; checked_assertions; runtime_assertions}

let commands report = report.commands
let checked_assertions report = report.checked_assertions
let runtime_assertions report = report.runtime_assertions
