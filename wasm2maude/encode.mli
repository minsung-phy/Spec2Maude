val module_ : Frontend.module_ -> Maude_term.t

(* Term helpers shared with the Wasm 1.0 and 2.0 encoders. *)
val nat : int -> Maude_term.t
val u64 : int64 -> Maude_term.t
val terminal : Maude_term.t -> Maude_term.t
val idx : Wasm.Ast.idx -> Maude_term.t
val present : Maude_term.t -> Maude_term.t
val option : ('a -> Maude_term.t) -> 'a option -> Maude_term.t
val list : ('a -> Maude_term.t) -> 'a list -> Maude_term.t
val packsize : Wasm.Pack.packsize -> Maude_term.t
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
