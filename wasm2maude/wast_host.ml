open Wasm.Types

type shared = Memory | Table | Table64
type lifetime = Fresh | Shared of shared

type kind =
  | Function of deftype
  | Global of globaltype * Wasm.Value.num
  | Memory of memorytype
  | Table of tabletype

type export = {name : Wasm.Ast.name; kind : kind; lifetime : lifetime}

let wasm_name text = Wasm.Utf8.decode text

let functype args =
  DefT (RecT [SubT (Final, [], FuncT (args, []))], 0l)

let func export_name args =
  {name = wasm_name export_name;
   kind = Function (functype args);
   lifetime = Fresh}

let global export_name typ value =
  let typ = GlobalT (Cons, NumT typ) in
  {name = wasm_name export_name; kind = Global (typ, value); lifetime = Fresh}

let memory =
  let typ = MemoryT (I32AT, {min = 1L; max = Some 2L}) in
  {name = wasm_name "memory"; kind = Memory typ; lifetime = Shared Memory}

let table export_name addr shared =
  let typ = TableT (addr, {min = 10L; max = Some 20L}, (Null, FuncHT)) in
  {name = wasm_name export_name; kind = Table typ; lifetime = Shared shared}

let module_name = wasm_name "spectest"

let exports =
  [ func "print" [];
    func "print_i32" [NumT I32T];
    func "print_i64" [NumT I64T];
    func "print_f32" [NumT F32T];
    func "print_f64" [NumT F64T];
    func "print_i32_f32" [NumT I32T; NumT F32T];
    func "print_f64_f64" [NumT F64T; NumT F64T];
    global "global_i32" I32T (Wasm.Value.I32 666l);
    global "global_i64" I64T (Wasm.Value.I64 666L);
    global "global_f32" F32T
      (Wasm.Value.F32 (Wasm.F32.of_float 666.6));
    global "global_f64" F64T
      (Wasm.Value.F64 (Wasm.F64.of_float 666.6));
    memory;
    table "table" I32AT Table;
    table "table64" I64AT Table64 ]

let lookup name =
  List.find_opt (fun export -> export.name = name) exports

let name export = export.name
let kind export = export.kind
let lifetime export = export.lifetime

let externtype export =
  match export.kind with
  | Function typ -> ExternFuncT (Def typ)
  | Global (typ, _) -> ExternGlobalT typ
  | Memory typ -> ExternMemoryT typ
  | Table typ -> ExternTableT typ
