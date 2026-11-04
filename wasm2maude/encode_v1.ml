(* Wasm 1.0 module terms of the generated semantics
   (spectec/wasm-1.0/1-syntax.spectec). The reference interpreter parses and
   validates the module; a construct outside Wasm 1.0 is rejected. Numbers,
   names, and floats have the same terms as in Wasm 3.0 (Encode). *)
module Encode3 = Encode
open Wasm

module T = Maude_term

let app = T.app
let atom = T.atom
let seq = T.seq

let unsupported source at what =
  Ingress_error.raise ~region:at Ingress_error.Unsupported source
    ("Wasm 1.0: " ^ what)

let nat, u64, terminal, idx, present, option, list, packsize =
  Encode3.(nat, u64, terminal, idx, present, option, list, packsize)

let numtype = function
  | Types.I32T -> atom "I32"
  | Types.I64T -> atom "I64"
  | Types.F32T -> atom "F32"
  | Types.F64T -> atom "F64"

let valtype source at = function
  | Types.NumT t -> numtype t
  | Types.VecT _ | Types.RefT _ | Types.BotT ->
      unsupported source at "only number types"

let sx = function Pack.U -> atom "U" | Pack.S -> atom "S"

(* limits = `[u32 .. u32?] *)
let limits {Types.min; max} =
  app "[_.._]" [u64 min; option (fun max -> terminal (u64 max)) max]

(* mut = MUT?; globaltype = mut valtype *)
let globaltype source at (Types.GlobalT (m, t)) =
  let m = match m with Types.Cons -> seq [] | Types.Var -> present (atom "spectec-MUT") in
  app "tuple" [seq [app "seq" [m]; valtype source at t]]

let memtype source at (Types.MemoryT (addr, lim)) =
  if addr <> Types.I32AT then unsupported source at "64-bit memory";
  limits lim

let tabletype source at (Types.TableT (addr, lim, (_, heap))) =
  if addr <> Types.I32AT || heap <> Types.FuncHT then
    unsupported source at "only funcref tables of 32-bit addresses";
  limits lim

(* functype = valtype* -> valtype*, from the module's type section *)
let functype source at = function
  | Types.FuncT (args, results) ->
      app "_->_" [list (valtype source at) args; list (valtype source at) results]
  | Types.StructT _ | Types.ArrayT _ -> unsupported source at "only function types"

let deftype_functype source at (m : Ast.module_') x =
  match List.nth_opt m.Ast.types (Int32.to_int x) with
  | Some {it = Types.RecT [Types.SubT (Types.Final, [], comp)]; at} ->
      functype source at comp
  | Some {at; _} -> unsupported source at "recursive or sub types"
  | None -> unsupported source at "unknown type index"

let externtype source at m = function
  | Types.ExternFuncT (Types.Idx x) -> app "FUNC" [deftype_functype source at m x]
  | Types.ExternGlobalT t -> app "GLOBAL" [globaltype source at t]
  | Types.ExternMemoryT t -> app "MEM" [memtype source at t]
  | Types.ExternTableT t -> app "TABLE" [tabletype source at t]
  | Types.ExternFuncT _ | Types.ExternTagT _ -> unsupported source at "this import"

let blocktype source at = function
  | Ast.ValBlockType result -> option (valtype source at) result
  | Ast.VarBlockType _ -> unsupported source at "type-indexed block type"

let memarg align offset =
  app "{_}"
    [app "_;_"
       [ app "field" [atom "'ALIGN"; terminal (nat align)]
       ; app "field" [atom "'OFFSET"; terminal (u64 offset)] ]]

let memory source at x =
  if x.Source.it <> 0l then unsupported source at "memory index other than 0"

let int_unop = function
  | Ast.IntOp.Clz -> Some "CLZ" | Ctz -> Some "CTZ" | Popcnt -> Some "POPCNT"
  | ExtendS _ -> None

let float_unop = function
  | Ast.FloatOp.Neg -> "spectec-NEG" | Abs -> "ABS" | Ceil -> "CEIL"
  | Floor -> "FLOOR" | Trunc -> "TRUNC" | Nearest -> "NEAREST" | Sqrt -> "SQRT"

let int_binop = function
  | Ast.IntOp.Add -> atom "ADD" | Sub -> atom "SUB" | Mul -> atom "MUL"
  | Div s -> app "DIV" [sx s] | Rem s -> app "REM" [sx s]
  | And -> atom "AND" | Or -> atom "OR" | Xor -> atom "XOR" | Shl -> atom "SHL"
  | Shr s -> app "SHR" [sx s]
  | Rotl -> atom "ROTL" | Rotr -> atom "ROTR"

let float_binop = function
  | Ast.FloatOp.Add -> "ADD" | Sub -> "SUB" | Mul -> "MUL" | Div -> "spectec-DIV"
  | Min -> "MIN" | Max -> "MAX" | CopySign -> "COPYSIGN"

let int_relop = function
  | Ast.IntOp.Eq -> atom "EQ" | Ne -> atom "NE"
  | Lt s -> app "LT" [sx s] | Gt s -> app "GT" [sx s]
  | Le s -> app "LE" [sx s] | Ge s -> app "GE" [sx s]

let float_relop = function
  | Ast.FloatOp.Eq -> "EQ" | Ne -> "NE" | Lt -> "spectec-LT" | Gt -> "spectec-GT"
  | Le -> "spectec-LE" | Ge -> "spectec-GE"

(* CVTOP valtype_1 valtype_2 cvtop: the result type, then the operand type. *)
let cvtop source at = function
  | Value.I32 Ast.IntOp.WrapI64 -> "I32", "I64", atom "WRAP"
  | Value.I64 (Ast.IntOp.ExtendI32 s) -> "I64", "I32", app "EXTEND" [sx s]
  | Value.I32 (Ast.IntOp.TruncF32 s) -> "I32", "F32", app "spectec-TRUNC" [sx s]
  | Value.I32 (Ast.IntOp.TruncF64 s) -> "I32", "F64", app "spectec-TRUNC" [sx s]
  | Value.I64 (Ast.IntOp.TruncF32 s) -> "I64", "F32", app "spectec-TRUNC" [sx s]
  | Value.I64 (Ast.IntOp.TruncF64 s) -> "I64", "F64", app "spectec-TRUNC" [sx s]
  | Value.I32 Ast.IntOp.ReinterpretFloat -> "I32", "F32", atom "REINTERPRET"
  | Value.I64 Ast.IntOp.ReinterpretFloat -> "I64", "F64", atom "REINTERPRET"
  | Value.F32 (Ast.FloatOp.ConvertI32 s) -> "F32", "I32", app "CONVERT" [sx s]
  | Value.F32 (Ast.FloatOp.ConvertI64 s) -> "F32", "I64", app "CONVERT" [sx s]
  | Value.F64 (Ast.FloatOp.ConvertI32 s) -> "F64", "I32", app "CONVERT" [sx s]
  | Value.F64 (Ast.FloatOp.ConvertI64 s) -> "F64", "I64", app "CONVERT" [sx s]
  | Value.F32 Ast.FloatOp.DemoteF64 -> "F32", "F64", atom "DEMOTE"
  | Value.F64 Ast.FloatOp.PromoteF32 -> "F64", "F32", atom "PROMOTE"
  | Value.F32 Ast.FloatOp.ReinterpretInt -> "F32", "I32", atom "REINTERPRET"
  | Value.F64 Ast.FloatOp.ReinterpretInt -> "F64", "I64", atom "REINTERPRET"
  | _ -> unsupported source at "this conversion"

let rec expr source xs = seq (List.map (instr source) xs)

and instr source ({Source.it; at} : Ast.instr) =
  let unary name x = app name [idx x] in
  let ints name i32 i64 = function
    | Value.I32 op -> app name [atom "I32"; i32 op]
    | Value.I64 op -> app name [atom "I64"; i64 op]
    | Value.F32 _ | Value.F64 _ -> assert false
  in
  match it with
  | Ast.Unreachable -> atom "UNREACHABLE"
  | Ast.Nop -> atom "NOP"
  | Ast.Drop -> atom "DROP"
  | Ast.Select None -> atom "SELECT"
  | Ast.Block (bt, body) -> app "BLOCK" [blocktype source at bt; expr source body]
  | Ast.Loop (bt, body) -> app "LOOP" [blocktype source at bt; expr source body]
  | Ast.If (bt, yes, no) ->
      app "IF__ELSE_" [blocktype source at bt; expr source yes; expr source no]
  | Ast.Br x -> unary "BR" x
  | Ast.BrIf x -> unary "BR-IF" x
  | Ast.BrTable (xs, x) -> app "BR-TABLE" [seq (List.map (fun x -> terminal (idx x)) xs); idx x]
  | Ast.Return -> atom "RETURN"
  | Ast.Call x -> unary "CALL" x
  | Ast.CallIndirect (table, typ) when table.Source.it = 0l -> unary "CALL-INDIRECT" typ
  | Ast.LocalGet x -> unary "LOCAL.GET" x
  | Ast.LocalSet x -> unary "LOCAL.SET" x
  | Ast.LocalTee x -> unary "LOCAL.TEE" x
  | Ast.GlobalGet x -> unary "GLOBAL.GET" x
  | Ast.GlobalSet x -> unary "GLOBAL.SET" x
  | Ast.Load (x, {ty; pack; align; offset}) ->
      memory source at x;
      let packed = option (fun (size, s) -> app "spectec-_-_" [packsize size; sx s]) pack in
      app "LOAD" [numtype ty; packed; memarg align offset]
  | Ast.Store (x, {ty; pack; align; offset}) ->
      memory source at x;
      app "STORE" [numtype ty; option (fun size -> terminal (packsize size)) pack; memarg align offset]
  | Ast.MemorySize x -> memory source at x; atom "MEMORY.SIZE"
  | Ast.MemoryGrow x -> memory source at x; atom "MEMORY.GROW"
  | Ast.Const n -> Encode3.num_instr n.it
  | Ast.Test (Value.I32 Ast.IntOp.Eqz) -> app "TESTOP" [atom "I32"; atom "EQZ"]
  | Ast.Test (Value.I64 Ast.IntOp.Eqz) -> app "TESTOP" [atom "I64"; atom "EQZ"]
  | Ast.Compare (Value.F32 op) -> app "RELOP" [atom "F32"; atom (float_relop op)]
  | Ast.Compare (Value.F64 op) -> app "RELOP" [atom "F64"; atom (float_relop op)]
  | Ast.Compare op -> ints "RELOP" int_relop int_relop op
  | Ast.Unary (Value.F32 op) -> app "UNOP" [atom "F32"; atom (float_unop op)]
  | Ast.Unary (Value.F64 op) -> app "UNOP" [atom "F64"; atom (float_unop op)]
  | Ast.Unary (Value.I32 op | Value.I64 op as typed) ->
      (match int_unop op with
       | Some name ->
           app "UNOP" [atom (match typed with Value.I32 _ -> "I32" | _ -> "I64"); atom name]
       | None -> unsupported source at "sign-extension operator")
  | Ast.Binary (Value.F32 op) -> app "BINOP" [atom "F32"; atom (float_binop op)]
  | Ast.Binary (Value.F64 op) -> app "BINOP" [atom "F64"; atom (float_binop op)]
  | Ast.Binary op -> ints "BINOP" int_binop int_binop op
  | Ast.Convert op ->
      (match op with
       | Value.I32 (Ast.IntOp.TruncSatF32 _ | Ast.IntOp.TruncSatF64 _)
       | Value.I64 (Ast.IntOp.TruncSatF32 _ | Ast.IntOp.TruncSatF64 _) ->
           unsupported source at "saturating truncation"
       | _ ->
           let target, operand, op = cvtop source at op in
           app "CVTOP" [atom target; atom operand; op])
  | _ -> unsupported source at "instruction outside Wasm 1.0"

let module_ ({Frontend.source; ast; _} : Frontend.module_) =
  let m = ast.Source.it in
  let at = ast.Source.at in
  if m.Ast.tags <> [] then unsupported source at "tags";
  let type_ ({Source.it = Types.RecT subs; at} : Ast.type_) =
    match subs with
    | [Types.SubT (Types.Final, [], comp)] -> app "TYPE" [functype source at comp]
    | _ -> unsupported source at "recursive or sub types"
  in
  let import ({Source.it = Ast.Import (module_name, name, typ); at} : Ast.import) =
    app "IMPORT" [Encode3.name module_name; Encode3.name name; externtype source at m typ]
  in
  let func ({Source.it = Ast.Func (typ, locals, body); at} : Ast.func) =
    let local ({Source.it = Ast.Local t; _} : Ast.local) = app "LOCAL" [valtype source at t] in
    app "spectec-FUNC" [idx typ; list local locals; expr source body]
  in
  let global ({Source.it = Ast.Global (typ, init); at} : Ast.global) =
    app "spectec-GLOBAL" [globaltype source at typ; expr source init.it]
  in
  let table ({Source.it = Ast.Table (typ, init); at} : Ast.table) =
    (match init.it with
     | [{Source.it = Ast.RefNull _; _}] -> ()
     | _ -> unsupported source at "table initializer");
    app "TABLE" [tabletype source at typ]
  in
  let memory_ ({Source.it = Ast.Memory typ; at} : Ast.memory) =
    app "MEMORY" [memtype source at typ]
  in
  let active source at = function
    | {Source.it = Ast.Active (x, offset); _} when x.Source.it = 0l -> offset.Source.it
    | _ -> unsupported source at "passive or declarative segment"
  in
  (* ELEM expr funcidx*: the offset, then the function indices *)
  let elem ({Source.it = Ast.Elem (_, inits, mode); at} : Ast.elem) =
    let funcidx = function
      | {Source.it = [{Source.it = Ast.RefFunc x; _}]; _} -> terminal (idx x)
      | _ -> unsupported source at "element expression other than ref.func"
    in
    app "ELEM" [expr source (active source at mode); seq (List.map funcidx inits)]
  in
  (* DATA expr byte* *)
  let data ({Source.it = Ast.Data (bytes, mode); at} : Ast.data) =
    let bytes = String.to_seq bytes |> List.of_seq |> List.map (fun c -> terminal (nat (Char.code c))) in
    app "DATA" [expr source (active source at mode); seq bytes]
  in
  let start ({Source.it = Ast.Start x; _} : Ast.start) = app "START" [idx x] in
  let externidx = function
    | {Source.it = Ast.FuncX x; _} -> app "FUNC" [idx x]
    | {Source.it = Ast.GlobalX x; _} -> app "GLOBAL" [idx x]
    | {Source.it = Ast.TableX x; _} -> app "TABLE" [idx x]
    | {Source.it = Ast.MemoryX x; _} -> app "MEM" [idx x]
    | {Source.it = Ast.TagX _; at} -> unsupported source at "tag export"
  in
  let export ({Source.it = Ast.Export (n, x); _} : Ast.export) =
    app "EXPORT" [Encode3.name n; externidx x]
  in
  app "MODULE"
    [ list type_ m.types; list import m.imports; list func m.funcs;
      list global m.globals; list table m.tables; list memory_ m.memories;
      list elem m.elems; list data m.datas; option start m.start;
      list export m.exports ]
