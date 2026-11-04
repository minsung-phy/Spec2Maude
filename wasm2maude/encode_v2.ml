(* Wasm 2.0 module terms of the generated semantics
   (spectec/wasm-2.0/1-syntax.spectec). Scalar instructions have the Wasm 1.0
   terms (Encode_v1); this adds the 2.0 types, blocks, references, tables,
   bulk memory, and vector instructions. A construct outside Wasm 2.0 is
   rejected. *)
module Encode3 = Encode
module V1 = Encode_v1
open Wasm

module T = Maude_term

let app = T.app
let atom = T.atom
let seq = T.seq

let unsupported source at what =
  Ingress_error.raise ~region:at Ingress_error.Unsupported source
    ("Wasm 2.0: " ^ what)

let nat, terminal, idx, present, option, list, packsize =
  Encode3.(nat, terminal, idx, present, option, list, packsize)
let sx, limits = V1.(sx, limits)

(* Wasm 2.0 has only the nullable funcref and externref. The Wasm 3.0 parser
   gives some of their 2.0 forms the non-nullable type, such as a segment of
   function indices (elem func $f): that is funcref in Wasm 2.0. *)
let reftype source at = function
  | ((Types.Null | Types.NoNull), Types.FuncHT) -> atom "FUNCREF"
  | ((Types.Null | Types.NoNull), Types.ExternHT) -> atom "EXTERNREF"
  | _ -> unsupported source at "only funcref and externref"

let valtype source at = function
  | Types.NumT t -> V1.numtype t
  | Types.VecT Types.V128T -> atom "V128"
  | Types.RefT t -> reftype source at t
  | Types.BotT -> unsupported source at "bottom type"

(* resulttype = list(valtype); functype = resulttype -> resulttype *)
let functype source at = function
  | Types.FuncT (args, results) ->
      app "_->_" [list (valtype source at) args; list (valtype source at) results]
  | Types.StructT _ | Types.ArrayT _ -> unsupported source at "only function types"

let type_functype source at (m : Ast.module_') x =
  match List.nth_opt m.Ast.types (Int32.to_int x) with
  | Some {it = Types.RecT [Types.SubT (Types.Final, [], comp)]; at} -> functype source at comp
  | Some {at; _} -> unsupported source at "recursive or sub types"
  | None -> unsupported source at "unknown type index"

let globaltype source at (Types.GlobalT (m, t)) =
  let m = match m with Types.Cons -> seq [] | Types.Var -> present (atom "spectec-MUT") in
  app "tuple" [seq [app "seq" [m]; valtype source at t]]

(* memtype = limits PAGE *)
let memtype source at (Types.MemoryT (addr, lim)) =
  if addr <> Types.I32AT then unsupported source at "64-bit memory";
  app "_PAGE" [limits lim]

(* tabletype = limits reftype *)
let tabletype source at (Types.TableT (addr, lim, ref)) =
  if addr <> Types.I32AT then unsupported source at "64-bit table";
  app "tuple" [seq [limits lim; reftype source at ref]]

let externtype source at m = function
  | Types.ExternFuncT (Types.Idx x) -> app "FUNC" [type_functype source at m x]
  | Types.ExternGlobalT t -> app "GLOBAL" [globaltype source at t]
  | Types.ExternMemoryT t -> app "MEM" [memtype source at t]
  | Types.ExternTableT t -> app "TABLE" [tabletype source at t]
  | Types.ExternFuncT _ | Types.ExternTagT _ -> unsupported source at "this import"

(* blocktype = _RESULT valtype? | _IDX typeidx *)
let blocktype source at = function
  | Ast.ValBlockType result -> app "-RESULT" [option (valtype source at) result]
  | Ast.VarBlockType x -> app "-IDX" [idx x]

let memory source at x =
  if x.Source.it <> 0l then unsupported source at "memory index other than 0"

(* Vector shapes: lanetype X dim *)
let shape = function
  | V128.I8x16 _ -> app "_X_" [atom "I8"; nat 16]
  | V128.I16x8 _ -> app "_X_" [atom "I16"; nat 8]
  | V128.I32x4 _ -> app "_X_" [atom "I32"; nat 4]
  | V128.I64x2 _ -> app "_X_" [atom "I64"; nat 2]
  | V128.F32x4 _ -> app "_X_" [atom "F32"; nat 4]
  | V128.F64x2 _ -> app "_X_" [atom "F64"; nat 2]

let i8x16 = app "_X_" [atom "I8"; nat 16]
let i16x8 = app "_X_" [atom "I16"; nat 8]
let i32x4 = app "_X_" [atom "I32"; nat 4]
let f32x4 = app "_X_" [atom "F32"; nat 4]
let f64x2 = app "_X_" [atom "F64"; nat 2]

(* The operand shape of a widening operation with the given result shape. *)
let half_shape source at = function
  | V128.I16x8 _ -> i8x16
  | V128.I32x4 _ -> i16x8
  | V128.I64x2 _ -> i32x4
  | _ -> unsupported source at "vector widening shape"

let half = function Ast.V128Op.Low -> atom "LOW" | Ast.V128Op.High -> atom "HIGH"

let vunop source at op =
  let name = match op with
    | V128.I8x16 x | V128.I16x8 x | V128.I32x4 x | V128.I64x2 x ->
        (match (x : Ast.V128Op.iunop) with
         | Abs -> "ABS" | Neg -> "spectec-NEG" | Popcnt -> "POPCNT")
    | V128.F32x4 x | V128.F64x2 x ->
        (match (x : Ast.V128Op.funop) with
         | Abs -> "ABS" | Neg -> "spectec-NEG" | Sqrt -> "SQRT" | Ceil -> "CEIL"
         | Floor -> "FLOOR" | Trunc -> "TRUNC" | Nearest -> "NEAREST")
  in
  ignore (source, at);
  app "VUNOP" [shape op; atom name]

let vbinop source at op =
  let sh = shape op in
  match op with
  | V128.I8x16 Ast.V128Op.Swizzle -> app "VSWIZZLE" [sh]
  | V128.I8x16 (Ast.V128Op.Shuffle lanes) ->
      app "VSHUFFLE" [sh; seq (List.map (fun i -> terminal (nat (I8.to_int_u i))) lanes)]
  | V128.I8x16 (Ast.V128Op.Narrow s) -> app "VNARROW" [sh; i16x8; sx s]
  | V128.I16x8 (Ast.V128Op.Narrow s) -> app "VNARROW" [sh; i32x4; sx s]
  | V128.I16x8 (Ast.V128Op.ExtMul (h, s)) | V128.I32x4 (Ast.V128Op.ExtMul (h, s))
  | V128.I64x2 (Ast.V128Op.ExtMul (h, s)) ->
      app "VEXTBINOP" [sh; half_shape source at op; app "EXTMUL" [half h; sx s]]
  | V128.I32x4 Ast.V128Op.DotS -> app "VEXTBINOP" [sh; i16x8; atom "DOTS"]
  | V128.I8x16 x | V128.I16x8 x | V128.I32x4 x | V128.I64x2 x ->
      let op = match (x : Ast.V128Op.ibinop) with
        | Add -> atom "ADD" | Sub -> atom "SUB" | Mul -> atom "MUL"
        | Min s -> app "spectec-MIN" [sx s] | Max s -> app "spectec-MAX" [sx s]
        | AvgrU -> atom "AVGRU" | AddSat s -> app "ADD-SAT" [sx s]
        | SubSat s -> app "SUB-SAT" [sx s] | Q15MulRSatS -> atom "Q15MULR-SATS"
        | _ -> unsupported source at "vector operation outside Wasm 2.0"
      in
      app "VBINOP" [sh; op]
  | V128.F32x4 x | V128.F64x2 x ->
      let op = match (x : Ast.V128Op.fbinop) with
        | Add -> "ADD" | Sub -> "SUB" | Mul -> "MUL" | Div -> "spectec-DIV"
        | Min -> "MIN" | Max -> "MAX" | Pmin -> "PMIN" | Pmax -> "PMAX"
        | RelaxedMin | RelaxedMax -> unsupported source at "relaxed vector operation"
      in
      app "VBINOP" [sh; atom op]

let vrelop op =
  let sh = shape op in
  match op with
  | V128.I8x16 x | V128.I16x8 x | V128.I32x4 x | V128.I64x2 x ->
      app "VRELOP" [sh; V1.int_relop (match (x : Ast.V128Op.irelop) with
        | Eq -> Ast.IntOp.Eq | Ne -> Ne | Lt s -> Lt s | Gt s -> Gt s
        | Le s -> Le s | Ge s -> Ge s)]
  | V128.F32x4 x | V128.F64x2 x ->
      app "VRELOP" [sh; atom (V1.float_relop (match (x : Ast.V128Op.frelop) with
        | Eq -> Ast.FloatOp.Eq | Ne -> Ne | Lt -> Lt | Gt -> Gt | Le -> Le | Ge -> Ge))]

let vcvtop source at op =
  let sh = shape op in
  let convert operand op = app "VCVTOP" [sh; operand; op] in
  match op with
  | V128.I16x8 (Ast.V128Op.ExtAddPairwise s) | V128.I32x4 (Ast.V128Op.ExtAddPairwise s) ->
      app "VEXTUNOP" [sh; half_shape source at op; app "EXTADD-PAIRWISE" [sx s]]
  | V128.I16x8 (Ast.V128Op.Extend (h, s)) | V128.I32x4 (Ast.V128Op.Extend (h, s))
  | V128.I64x2 (Ast.V128Op.Extend (h, s)) ->
      convert (half_shape source at op) (app "spectec-EXTEND" [half h; sx s])
  | V128.I32x4 (Ast.V128Op.TruncSatF32x4 s) ->
      convert f32x4 (app "spectec-TRUNC-SAT" [sx s; seq []])
  | V128.I32x4 (Ast.V128Op.TruncSatZeroF64x2 s) ->
      convert f64x2 (app "spectec-TRUNC-SAT" [sx s; present (atom "ZERO")])
  | V128.F32x4 (Ast.V128Op.ConvertI32x4 s) ->
      convert i32x4 (app "spectec-CONVERT" [seq []; sx s])
  | V128.F64x2 (Ast.V128Op.ConvertI32x4 s) ->
      convert i32x4 (app "spectec-CONVERT" [present (atom "LOW"); sx s])
  | V128.F32x4 Ast.V128Op.DemoteZeroF64x2 -> convert f64x2 (app "spectec-DEMOTE" [atom "ZERO"])
  | V128.F64x2 Ast.V128Op.PromoteLowF32x4 -> convert f32x4 (atom "PROMOTELOW")
  | _ -> unsupported source at "vector conversion outside Wasm 2.0"

let vloadop = function
  | None -> seq []
  | Some (_, Pack.ExtLane (pack, s)) ->
      let size, lanes = match pack with
        | Pack.Pack8x8 -> 8, 8
        | Pack.Pack16x4 -> 16, 4
        | Pack.Pack32x2 -> 32, 2
      in
      present (app "SHAPE_X_-_" [nat size; nat lanes; sx s])
  | Some (size, Pack.ExtSplat) -> present (app "SPLAT" [packsize size])
  | Some (size, Pack.ExtZero) -> present (app "spectec-ZERO" [packsize size])

let rec expr source xs = seq (List.map (instr source) xs)

and instr source ({Source.it; at} as i : Ast.instr) =
  let unary name x = app name [idx x] in
  match it with
  | Ast.Select None -> app "SELECT" [seq []]
  | Ast.Select (Some ts) -> app "SELECT" [present (app "seq" [list (valtype source at) ts])]
  | Ast.Block (bt, body) -> app "BLOCK" [blocktype source at bt; expr source body]
  | Ast.Loop (bt, body) -> app "LOOP" [blocktype source at bt; expr source body]
  | Ast.If (bt, yes, no) ->
      app "IF__ELSE_" [blocktype source at bt; expr source yes; expr source no]
  | Ast.CallIndirect (table, typ) -> app "CALL-INDIRECT" [idx table; idx typ]
  | Ast.Unary (Value.I32 (Ast.IntOp.ExtendS size)) ->
      app "UNOP" [atom "I32"; app "EXTEND" [packsize size]]
  | Ast.Unary (Value.I64 (Ast.IntOp.ExtendS size)) ->
      app "UNOP" [atom "I64"; app "EXTEND" [packsize size]]
  | Ast.Convert (Value.I32 (Ast.IntOp.TruncSatF32 s)) ->
      app "CVTOP" [atom "I32"; atom "F32"; app "TRUNC-SAT" [sx s]]
  | Ast.Convert (Value.I32 (Ast.IntOp.TruncSatF64 s)) ->
      app "CVTOP" [atom "I32"; atom "F64"; app "TRUNC-SAT" [sx s]]
  | Ast.Convert (Value.I64 (Ast.IntOp.TruncSatF32 s)) ->
      app "CVTOP" [atom "I64"; atom "F32"; app "TRUNC-SAT" [sx s]]
  | Ast.Convert (Value.I64 (Ast.IntOp.TruncSatF64 s)) ->
      app "CVTOP" [atom "I64"; atom "F64"; app "TRUNC-SAT" [sx s]]
  | Ast.RefNull (Types.FuncHT) -> app "REF.NULL" [atom "FUNCREF"]
  | Ast.RefNull (Types.ExternHT) -> app "REF.NULL" [atom "EXTERNREF"]
  | Ast.RefFunc x -> unary "REF.FUNC" x
  | Ast.RefIsNull -> atom "REF.IS-NULL"
  | Ast.TableGet x -> unary "TABLE.GET" x
  | Ast.TableSet x -> unary "TABLE.SET" x
  | Ast.TableSize x -> unary "TABLE.SIZE" x
  | Ast.TableGrow x -> unary "TABLE.GROW" x
  | Ast.TableFill x -> unary "TABLE.FILL" x
  | Ast.TableCopy (x, y) -> app "TABLE.COPY" [idx x; idx y]
  | Ast.TableInit (x, y) -> app "TABLE.INIT" [idx x; idx y]
  | Ast.ElemDrop x -> unary "ELEM.DROP" x
  | Ast.MemoryFill x -> memory source at x; atom "MEMORY.FILL"
  | Ast.MemoryCopy (x, y) -> memory source at x; memory source at y; atom "MEMORY.COPY"
  | Ast.MemoryInit (x, y) -> memory source at x; unary "MEMORY.INIT" y
  | Ast.DataDrop x -> unary "DATA.DROP" x
  | Ast.VecConst v -> let Value.V128 v = v.it in Encode3.vec_value v
  | Ast.VecLoad (x, {ty = Types.V128T; pack; align; offset}) ->
      memory source at x;
      app "VLOAD" [atom "V128"; vloadop pack; V1.memarg align offset]
  | Ast.VecStore (x, {ty = Types.V128T; align; offset; _}) ->
      memory source at x;
      app "VSTORE" [atom "V128"; V1.memarg align offset]
  | Ast.VecLoadLane (x, {ty = Types.V128T; pack; align; offset}, lane) ->
      memory source at x;
      app "VLOAD-LANE" [atom "V128"; packsize pack; V1.memarg align offset; nat (I8.to_int_u lane)]
  | Ast.VecStoreLane (x, {ty = Types.V128T; pack; align; offset}, lane) ->
      memory source at x;
      app "VSTORE-LANE" [atom "V128"; packsize pack; V1.memarg align offset; nat (I8.to_int_u lane)]
  | Ast.VecTest (Value.V128 op) -> app "VTESTOP" [shape op; atom "ALL-TRUE"]
  | Ast.VecCompare (Value.V128 op) -> vrelop op
  | Ast.VecUnary (Value.V128 op) -> vunop source at op
  | Ast.VecBinary (Value.V128 op) -> vbinop source at op
  | Ast.VecConvert (Value.V128 op) -> vcvtop source at op
  | Ast.VecShift (Value.V128 op) ->
      let op' = match op with
        | V128.I8x16 Ast.V128Op.Shl | V128.I16x8 Ast.V128Op.Shl
        | V128.I32x4 Ast.V128Op.Shl | V128.I64x2 Ast.V128Op.Shl -> atom "SHL"
        | V128.I8x16 (Ast.V128Op.Shr s) | V128.I16x8 (Ast.V128Op.Shr s)
        | V128.I32x4 (Ast.V128Op.Shr s) | V128.I64x2 (Ast.V128Op.Shr s) -> app "SHR" [sx s]
        | _ -> .
      in
      app "VSHIFTOP" [shape op; op']
  | Ast.VecBitmask (Value.V128 op) -> app "VBITMASK" [shape op]
  | Ast.VecTestBits (Value.V128 Ast.V128Op.AnyTrue) -> app "VVTESTOP" [atom "V128"; atom "ANY-TRUE"]
  | Ast.VecUnaryBits (Value.V128 Ast.V128Op.Not) -> app "VVUNOP" [atom "V128"; atom "NOT"]
  | Ast.VecBinaryBits (Value.V128 op) ->
      let op = match op with
        | Ast.V128Op.And -> "AND" | AndNot -> "ANDNOT" | Or -> "OR" | Xor -> "XOR"
      in
      app "VVBINOP" [atom "V128"; atom op]
  | Ast.VecTernaryBits (Value.V128 Ast.V128Op.Bitselect) ->
      app "VVTERNOP" [atom "V128"; atom "BITSELECT"]
  | Ast.VecTernary _ -> unsupported source at "relaxed vector operation"
  | Ast.VecSplat (Value.V128 op) -> app "VSPLAT" [shape op]
  | Ast.VecExtract (Value.V128 op) ->
      let s, lane = match op with
        | V128.I8x16 (Ast.V128Op.Extract (lane, s)) | V128.I16x8 (Ast.V128Op.Extract (lane, s)) ->
            present (sx s), lane
        | V128.I32x4 (Ast.V128Op.Extract (lane, ())) | V128.I64x2 (Ast.V128Op.Extract (lane, ()))
        | V128.F32x4 (Ast.V128Op.Extract (lane, ())) | V128.F64x2 (Ast.V128Op.Extract (lane, ())) ->
            seq [], lane
      in
      app "VEXTRACT-LANE" [shape op; s; nat (I8.to_int_u lane)]
  | Ast.VecReplace (Value.V128 op) ->
      let lane = match op with
        | V128.I8x16 (Ast.V128Op.Replace l) | V128.I16x8 (Ast.V128Op.Replace l)
        | V128.I32x4 (Ast.V128Op.Replace l) | V128.I64x2 (Ast.V128Op.Replace l)
        | V128.F32x4 (Ast.V128Op.Replace l) | V128.F64x2 (Ast.V128Op.Replace l) -> l
      in
      app "VREPLACE-LANE" [shape op; nat (I8.to_int_u lane)]
  | _ -> V1.instr source i

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
  (* ELEM reftype expr* elemmode; DATA byte* datamode *)
  let mode keyword = function
    | {Source.it = Ast.Passive; _} -> atom "PASSIVE"
    | {Source.it = Ast.Declarative; at} ->
        if keyword = "elem" then atom "DECLARE"
        else unsupported source at "declarative data segment"
    | {Source.it = Ast.Active (x, offset); _} ->
        app "ACTIVE" [idx x; expr source offset.Source.it]
  in
  let elem ({Source.it = Ast.Elem (typ, inits, m); at} : Ast.elem) =
    app "ELEM"
      [ reftype source at typ;
        seq (List.map (fun init -> app "seq" [expr source init.Source.it]) inits);
        mode "elem" m ]
  in
  let data ({Source.it = Ast.Data (bytes, m); _} : Ast.data) =
    let bytes = String.to_seq bytes |> List.of_seq |> List.map (fun c -> terminal (nat (Char.code c))) in
    app "DATA" [seq bytes; mode "data" m]
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

(* Values in WAST actions and results *)
let reference_value = function
  | Script.HostRef address -> app "REF.HOST-ADDR" [atom (Int32.to_string address)]
  | Extern.ExternRef (Script.HostRef address) ->
      app "REF.HOST-ADDR" [atom (Int32.to_string address)]
  | _ -> invalid_arg "Encode_v2.reference_value"

let null_reference = function
  | Types.FuncHT -> app "REF.NULL" [atom "FUNCREF"]
  | Types.ExternHT -> app "REF.NULL" [atom "EXTERNREF"]
  | _ -> invalid_arg "Encode_v2.null_reference"

let result_reftype = function
  | Types.FuncHT -> atom "FUNCREF"
  | Types.ExternHT -> atom "EXTERNREF"
  | _ -> invalid_arg "Encode_v2.result_reftype"
