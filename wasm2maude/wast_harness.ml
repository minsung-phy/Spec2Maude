(* rew runs the script until no rule applies. The runtime fixes the rule
   choice at memory.grow and table.grow (wast-runtime.maude, choice). *)
let render ~semantics ~runtime ~commands ~host_store ~host_instances
    ~host_functions =
  Printf.sprintf
    {|load %s
load %s

mod WASM2MAUDE-WAST is
  including WASM-WAST-DRIVER .

  eq emptyStore = %s .
  eq hostFunctionAddresses = %s .
endm

rew in WASM2MAUDE-WAST : script.ready(emptyStore, %s, %s) .
|}
    semantics runtime host_store host_functions host_instances
    (Maude_term.to_string commands)
