(* The final [continue 1] probes whether execution can still step after the
   bounded rewrite. Suite_run judges the first result and uses the probe only
   to distinguish a step limit from a stuck state. *)
let render ~semantics ~runtime ~steps ~commands ~host_store ~host_instances
    ~host_functions =
  let buffer = Buffer.create 4096 in
  List.iter
    (fun (name, body) ->
      Printf.bprintf buffer "  op %s : -> Commands .\n  eq %s = %s .\n"
        name name (Maude_term.to_string body))
    commands;
  let commands = Buffer.contents buffer in
  Printf.sprintf
    {|load %s
load %s

mod WASM2MAUDE-WAST is
  including WASM2MAUDE-WAST-RUNTIME .

%s  eq emptyStore = %s .
  eq hostFunctionAddresses = %s .
  eq initialState = script.ready(emptyStore, %s, inputCommands) .
endm

rew [%d] in WASM2MAUDE-WAST : script.start .
continue 1 .
|}
    semantics runtime commands host_store host_functions host_instances steps
