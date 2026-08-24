type shared = Memory | Table | Table64
type lifetime = Fresh | Shared of shared

type kind =
  | Function of Wasm.Types.deftype
  | Global of Wasm.Types.globaltype * Wasm.Value.num
  | Memory of Wasm.Types.memorytype
  | Table of Wasm.Types.tabletype

type export

val module_name : Wasm.Ast.name
val exports : export list
val lookup : Wasm.Ast.name -> export option
val name : export -> Wasm.Ast.name
val kind : export -> kind
val lifetime : export -> lifetime
val externtype : export -> Wasm.Types.externtype
