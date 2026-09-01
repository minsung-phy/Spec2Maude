val module_ : Frontend.module_ -> Maude_term.t
val name : Wasm.Ast.name -> Maude_term.t
val num_value : Wasm.Value.num -> Maude_term.t
val num_instr : Wasm.Value.num -> Maude_term.t
val num_payload : Wasm.Value.num -> Maude_term.t
val reference_value : Wasm.Value.ref_ -> Maude_term.t
val vec_value : Wasm.V128.t -> Maude_term.t
val vec_instr : Wasm.V128.t -> Maude_term.t
val result_shape : Wasm.V128.shape -> Maude_term.t
val result_heaptype : Wasm.Types.heaptype -> Maude_term.t
val result_numtype : Wasm.Types.numtype -> Maude_term.t

type check

val module_checks : Frontend.module_ -> check list
val check_label : check -> string
val check_term : check -> Maude_term.t
