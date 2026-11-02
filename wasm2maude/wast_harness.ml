(* rew runs the script until no rule applies. The runtime fixes the rule
   choice at memory.grow and table.grow (wast-runtime.maude, choice). *)
let render ~semantics ~runtime ~commands ~host_store ~host_instances
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
  including WASM-WAST-DRIVER .

%s  eq emptyStore = %s .
  eq hostFunctionAddresses = %s .
  eq initialState = script.ready(emptyStore, %s, inputCommands) .
endm

rew in WASM2MAUDE-WAST : script.start .
|}
    semantics runtime commands host_store host_functions host_instances
