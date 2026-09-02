open Wasm

module T = Spectec_term

let atom = T.atom
let app = T.app
let seq = T.seq

let unsupported source at what =
  Ingress_error.raise ~region:at Ingress_error.Unsupported source what

let nat n = atom (string_of_int n)
let decimal text = String.concat "" (String.split_on_char '_' text)
let i32_nat n = atom (decimal (I32.to_string_u n))
let i64_nat n = atom (decimal (I64.to_string_u n))
let u32 n = app "uN.wrap" [i32_nat n]
let u64 n = app "uN.wrap" [i64_nat n]
let idx x = u32 x.Source.it
let list f xs = app "list.wrap" [seq (List.map f xs)]
let present term = app "_?" [term]
let option f = function
  | None -> seq []
  | Some x -> present (f x)

type lane_shape = I8x16 | I16x8 | I32x4 | I64x2 | F32x4 | F64x2

let lane_shape = function
  | V128.I8x16 _ -> I8x16
  | V128.I16x8 _ -> I16x8
  | V128.I32x4 _ -> I32x4
  | V128.I64x2 _ -> I64x2
  | V128.F32x4 _ -> F32x4
  | V128.F64x2 _ -> F64x2

let shape = function
  | I8x16 -> app "shape.x" [atom "packtype.i8"; app "dim.wrap" [nat 16]]
  | I16x8 -> app "shape.x" [atom "packtype.i16"; app "dim.wrap" [nat 8]]
  | I32x4 -> app "shape.x" [atom "i32"; app "dim.wrap" [nat 4]]
  | I64x2 -> app "shape.x" [atom "i64"; app "dim.wrap" [nat 2]]
  | F32x4 -> app "shape.x" [atom "f32"; app "dim.wrap" [nat 4]]
  | F64x2 -> app "shape.x" [atom "f64"; app "dim.wrap" [nat 2]]

let result_shape value = shape (lane_shape value)

let ishape lane = app "ishape.wrap" [shape lane]
let bshape lane = app "bshape.wrap" [shape lane]

let laneidx i = app "uN.wrap" [nat (I8.to_int_u i)]

let decimal_mul_add digits factor add =
  let digit n = Char.chr (Char.code '0' + n) in
  let rec carry_digits carry acc =
    if carry = 0 then acc
    else carry_digits (carry / 10) (digit (carry mod 10) :: acc)
  in
  let rec loop i carry acc =
    if i < 0 then carry_digits carry acc
    else
      let value = (Char.code digits.[i] - Char.code '0') * factor + carry in
      loop (i - 1) (value / 10) (digit (value mod 10) :: acc)
  in
  loop (String.length digits - 1) add []
  |> List.to_seq |> String.of_seq

let v128_nat value =
  let bytes = V128.to_bits value in
  let rec loop i digits =
    if i < 0 then digits
    else loop (i - 1) (decimal_mul_add digits 256 (Char.code bytes.[i]))
  in
  loop (String.length bytes - 1) "0"

let v128 constructor value =
  let bits = app "uN.wrap" [atom (v128_nat value)] in
  app constructor [atom "vectype.v128"; bits]

let vec_value value = v128 "vconst" value
let vec_instr value = v128 "vconst" value

let rec expr source xs = seq (List.map (fun x -> instr source x) xs)

and expr_item source xs = app "seq" [expr source xs]

and numtype = function
  | Types.I32T -> atom "i32"
  | Types.I64T -> atom "i64"
  | Types.F32T -> atom "f32"
  | Types.F64T -> atom "f64"

and addrtype = function
  | Types.I32AT -> atom "i32"
  | Types.I64AT -> atom "i64"

and vectype Types.V128T = atom "vectype.v128"

and null = function
  | Types.NoNull -> seq []
  | Types.Null -> present (atom "null.null")

and mut = function
  | Types.Cons -> seq []
  | Types.Var -> present (atom "mut.mut")

and final = function
  | Types.NoFinal -> seq []
  | Types.Final -> present (atom "final.final")

and typeuse source at = function
  | Types.Idx x -> app "idx" [u32 x]
  | Types.Rec i -> app "rec" [i32_nat i]
  | Types.Def _ ->
      unsupported source at "semantic deftype found in a source type use"

and heaptype source at = function
  | Types.AnyHT -> atom "absheaptype.any"
  | Types.NoneHT -> atom "absheaptype.none"
  | Types.EqHT -> atom "absheaptype.eq"
  | Types.I31HT -> atom "absheaptype.i31"
  | Types.StructHT -> atom "absheaptype.struct"
  | Types.ArrayHT -> atom "absheaptype.array"
  | Types.FuncHT -> atom "absheaptype.func"
  | Types.NoFuncHT -> atom "absheaptype.nofunc"
  | Types.ExnHT -> atom "absheaptype.exn"
  | Types.NoExnHT -> atom "absheaptype.noexn"
  | Types.ExternHT -> atom "absheaptype.extern"
  | Types.NoExternHT -> atom "absheaptype.noextern"
  | Types.BotHT -> atom "bot"
  | Types.UseHT use -> typeuse source at use

and reftype source at (nul, heap) =
  app "reftype.ref" [null nul; heaptype source at heap]

and valtype source at = function
  | Types.NumT t -> numtype t
  | Types.VecT t -> vectype t
  | Types.RefT t -> reftype source at t
  | Types.BotT -> atom "bot"

and storagetype source at = function
  | Types.ValStorageT t -> valtype source at t
  | Types.PackStorageT Types.I8T -> atom "packtype.i8"
  | Types.PackStorageT Types.I16T -> atom "packtype.i16"

and fieldtype source at (Types.FieldT (m, t)) =
  app "fieldtype.wrap" [mut m; storagetype source at t]

and comptype source at = function
  | Types.StructT fields ->
      app "comptype.struct" [list (fieldtype source at) fields]
  | Types.ArrayT field -> app "comptype.array" [fieldtype source at field]
  | Types.FuncT (args, results) ->
      app "comptype.func-sym"
        [list (valtype source at) args; list (valtype source at) results]

and subtype source at (Types.SubT (fin, supers, comp)) =
  app "subtype.sub"
    [final fin; seq (List.map (typeuse source at) supers); comptype source at comp]

and rectype source at (Types.RecT subs) =
  app "rectype.rec" [list (subtype source at) subs]

and limits {Types.min; max} =
  app "limits.sym-sym-sym"
    [u64 min; option u64 max]

and globaltype source at (Types.GlobalT (m, t)) =
  app "globaltype.wrap" [mut m; valtype source at t]

and memtype (Types.MemoryT (addr, lim)) =
  app "memtype.page" [addrtype addr; limits lim]

and tabletype source at (Types.TableT (addr, lim, ref)) =
  app "tabletype.wrap" [addrtype addr; limits lim; reftype source at ref]

and externtype source at = function
  | Types.ExternTagT (Types.TagT use) ->
      app "externtype.tag" [typeuse source at use]
  | Types.ExternGlobalT t -> app "externtype.global" [globaltype source at t]
  | Types.ExternMemoryT t -> app "externtype.mem" [memtype t]
  | Types.ExternTableT t -> app "externtype.table" [tabletype source at t]
  | Types.ExternFuncT use -> app "externtype.func" [typeuse source at use]

and sx = function
  | Pack.U -> atom "sx.u"
  | Pack.S -> atom "sx.s"

and packsize = function
  | Pack.Pack8 -> app "sz.wrap" [nat 8]
  | Pack.Pack16 -> app "sz.wrap" [nat 16]
  | Pack.Pack32 -> app "sz.wrap" [nat 32]
  | Pack.Pack64 -> app "sz.wrap" [nat 64]

and memarg align offset =
  app "rec.memarg"
    [app "uN.wrap" [nat align]; app "uN.wrap" [i64_nat offset]]

and loadop {Ast.ty; pack; _} =
  let packed = option (fun (size, sign) -> app "loadop.sym" [packsize size; sx sign]) pack in
  numtype ty, packed

and storeop {Ast.ty; pack; _} =
  numtype ty, option (fun size -> app "storeop.wrap" [packsize size]) pack

and half = function
  | Ast.V128Op.Low -> atom "half.low"
  | Ast.V128Op.High -> atom "half.high"

and vector_input_shape source at = function
  | I16x8 -> shape I8x16
  | I32x4 -> shape I16x8
  | I64x2 -> shape I32x4
  | _ -> unsupported source at "vector widening operation has no valid input shape"

and vector_narrow_input_shape source at = function
  | I8x16 -> shape I16x8
  | I16x8 -> shape I32x4
  | _ -> unsupported source at "vector narrowing operation has no valid input shape"

and vector_dot_input_shape source at = function
  | I16x8 -> shape I8x16
  | I32x4 -> shape I16x8
  | _ -> unsupported source at "vector dot operation has no valid input shape"

and vector_dot_add_input_shape source at = function
  | I32x4 -> shape I8x16
  | _ -> unsupported source at "vector dot-add operation has no valid input shape"

and vloadop op =
  let encode = function
    | _, Pack.ExtLane (pack, sign) ->
        let size, lanes =
          match pack with
          | Pack.Pack8x8 -> packsize Pack.Pack8, 8
          | Pack.Pack16x4 -> packsize Pack.Pack16, 4
          | Pack.Pack32x2 -> packsize Pack.Pack32, 2
        in
        app "vloadop.shape-x-sym" [size; nat lanes; sx sign]
    | size, Pack.ExtSplat -> app "vloadop.splat" [packsize size]
    | size, Pack.ExtZero -> app "vloadop.zero" [packsize size]
  in
  option encode op

and int_vunop (op : Ast.V128Op.iunop) = match op with
  | Ast.V128Op.Abs -> atom "vunop.abs"
  | Ast.V128Op.Neg -> atom "vunop.neg"
  | Ast.V128Op.Popcnt -> atom "vunop.popcnt"

and float_vunop (op : Ast.V128Op.funop) = match op with
  | Ast.V128Op.Abs -> atom "vunop.abs"
  | Ast.V128Op.Neg -> atom "vunop.neg"
  | Ast.V128Op.Sqrt -> atom "vunop.sqrt"
  | Ast.V128Op.Ceil -> atom "vunop.ceil"
  | Ast.V128Op.Floor -> atom "vunop.floor"
  | Ast.V128Op.Trunc -> atom "vunop.trunc"
  | Ast.V128Op.Nearest -> atom "vunop.nearest"

and int_vbinop source at (op : Ast.V128Op.ibinop) = match op with
  | Ast.V128Op.Add -> atom "vbinop.add"
  | Ast.V128Op.Sub -> atom "vbinop.sub"
  | Ast.V128Op.Mul -> atom "vbinop.mul"
  | Ast.V128Op.Min sign -> app "vbinop.min-sx" [sx sign]
  | Ast.V128Op.Max sign -> app "vbinop.max-sx" [sx sign]
  | Ast.V128Op.AvgrU -> atom "vbinop.avgr-u"
  | Ast.V128Op.AddSat sign -> app "vbinop.add-sat" [sx sign]
  | Ast.V128Op.SubSat sign -> app "vbinop.sub-sat" [sx sign]
  | Ast.V128Op.Q15MulRSatS -> atom "vbinop.q15mulr-sat-s"
  | Ast.V128Op.RelaxedQ15MulRS -> atom "vbinop.relaxed-q15mulr-s"
  | (Ast.V128Op.DotS | Ast.V128Op.ExtMul _ | Ast.V128Op.Swizzle
    | Ast.V128Op.Shuffle _ | Ast.V128Op.Narrow _ | Ast.V128Op.RelaxedSwizzle
    | Ast.V128Op.RelaxedDot) ->
      unsupported source at "vector binary operation has an invalid lane shape"

and float_vbinop (op : Ast.V128Op.fbinop) = match op with
  | Ast.V128Op.Add -> atom "vbinop.add"
  | Ast.V128Op.Sub -> atom "vbinop.sub"
  | Ast.V128Op.Mul -> atom "vbinop.mul"
  | Ast.V128Op.Div -> atom "vbinop.div"
  | Ast.V128Op.Min -> atom "vbinop.min"
  | Ast.V128Op.Max -> atom "vbinop.max"
  | Ast.V128Op.Pmin -> atom "vbinop.pmin"
  | Ast.V128Op.Pmax -> atom "vbinop.pmax"
  | Ast.V128Op.RelaxedMin -> atom "vbinop.relaxed-min"
  | Ast.V128Op.RelaxedMax -> atom "vbinop.relaxed-max"

and int_vrelop (op : Ast.V128Op.irelop) = match op with
  | Ast.V128Op.Eq -> atom "vrelop.eq"
  | Ast.V128Op.Ne -> atom "vrelop.ne"
  | Ast.V128Op.Lt sign -> app "vrelop.lt-sx" [sx sign]
  | Ast.V128Op.Gt sign -> app "vrelop.gt-sx" [sx sign]
  | Ast.V128Op.Le sign -> app "vrelop.le-sx" [sx sign]
  | Ast.V128Op.Ge sign -> app "vrelop.ge-sx" [sx sign]

and float_vrelop (op : Ast.V128Op.frelop) = match op with
  | Ast.V128Op.Eq -> atom "vrelop.eq"
  | Ast.V128Op.Ne -> atom "vrelop.ne"
  | Ast.V128Op.Lt -> atom "vrelop.lt"
  | Ast.V128Op.Gt -> atom "vrelop.gt"
  | Ast.V128Op.Le -> atom "vrelop.le"
  | Ast.V128Op.Ge -> atom "vrelop.ge"

and vector_unop op =
  let sh = shape (lane_shape op) in
  match op with
  | V128.I8x16 x | V128.I16x8 x | V128.I32x4 x | V128.I64x2 x ->
      app "instr.vunop" [sh; int_vunop x]
  | V128.F32x4 x | V128.F64x2 x -> app "instr.vunop" [sh; float_vunop x]

and vector_test (op : Ast.V128Op.testop) =
  let sh = shape (lane_shape op) in
  match op with
  | V128.I8x16 Ast.V128Op.AllTrue
  | V128.I16x8 Ast.V128Op.AllTrue
  | V128.I32x4 Ast.V128Op.AllTrue
  | V128.I64x2 Ast.V128Op.AllTrue ->
      app "instr.vtestop" [sh; atom "vtestop.all-true"]
  | _ -> .

and vector_relop op =
  let sh = shape (lane_shape op) in
  match op with
  | V128.I8x16 x | V128.I16x8 x | V128.I32x4 x | V128.I64x2 x ->
      app "instr.vrelop" [sh; int_vrelop x]
  | V128.F32x4 x | V128.F64x2 x -> app "instr.vrelop" [sh; float_vrelop x]

and vector_binop source at op =
  let lane = lane_shape op in
  let sh = shape lane in
  match op with
  | V128.I8x16 Ast.V128Op.Swizzle ->
      app "instr.vswizzlop" [bshape lane; atom "vswizzlop.swizzle"]
  | V128.I8x16 Ast.V128Op.RelaxedSwizzle ->
      app "instr.vswizzlop" [bshape lane; atom "vswizzlop.relaxed-swizzle"]
  | V128.I8x16 (Ast.V128Op.Shuffle lanes) ->
      app "instr.vshuffle" [bshape lane; seq (List.map laneidx lanes)]
  | (V128.I8x16 (Ast.V128Op.Narrow sign)
    | V128.I16x8 (Ast.V128Op.Narrow sign)) ->
      app "instr.vnarrow"
        [ishape lane;
         app "ishape.wrap" [vector_narrow_input_shape source at lane];
         sx sign]
  | (V128.I16x8 (Ast.V128Op.ExtMul (part, sign))
    | V128.I32x4 (Ast.V128Op.ExtMul (part, sign))
    | V128.I64x2 (Ast.V128Op.ExtMul (part, sign))) ->
      app "instr.vextbinop"
        [ishape lane; app "ishape.wrap" [vector_input_shape source at lane];
         app "vextbinop.extmul" [half part; sx sign]]
  | V128.I16x8 Ast.V128Op.RelaxedDot ->
      app "instr.vextbinop"
        [ishape lane; app "ishape.wrap" [vector_dot_input_shape source at lane];
         atom "vextbinop.relaxed-dot-s"]
  | V128.I32x4 Ast.V128Op.DotS ->
      app "instr.vextbinop"
        [ishape lane; app "ishape.wrap" [vector_dot_input_shape source at lane];
         atom "vextbinop.dot-s"]
  | V128.I8x16 x | V128.I16x8 x | V128.I32x4 x | V128.I64x2 x ->
      app "instr.vbinop" [sh; int_vbinop source at x]
  | V128.F32x4 x | V128.F64x2 x -> app "instr.vbinop" [sh; float_vbinop x]

and vector_ternop source at op =
  let lane = lane_shape op in
  let sh = shape lane in
  match op with
  | V128.I32x4 Ast.V128Op.RelaxedDotAddS ->
      app "instr.vextternop"
        [ishape lane;
         app "ishape.wrap" [vector_dot_add_input_shape source at lane];
         atom "vextternop.relaxed-dot-add-s"]
  | (V128.I8x16 Ast.V128Op.RelaxedLaneselect
    | V128.I16x8 Ast.V128Op.RelaxedLaneselect
    | V128.I32x4 Ast.V128Op.RelaxedLaneselect
    | V128.I64x2 Ast.V128Op.RelaxedLaneselect) ->
      app "instr.vternop" [sh; atom "vternop.relaxed-laneselect"]
  | V128.F32x4 Ast.V128Op.RelaxedMadd
  | V128.F64x2 Ast.V128Op.RelaxedMadd ->
      app "instr.vternop" [sh; atom "vternop.relaxed-madd"]
  | V128.F32x4 Ast.V128Op.RelaxedNmadd
  | V128.F64x2 Ast.V128Op.RelaxedNmadd ->
      app "instr.vternop" [sh; atom "vternop.relaxed-nmadd"]
  | V128.I8x16 Ast.V128Op.RelaxedDotAddS
  | V128.I16x8 Ast.V128Op.RelaxedDotAddS
  | V128.I64x2 Ast.V128Op.RelaxedDotAddS ->
      unsupported source at "vector dot-add operation has an invalid result shape"

and vector_convert source at op =
  let lane = lane_shape op in
  let result = shape lane in
  let convert input operator = app "instr.vcvtop" [result; input; operator] in
  match op with
  | (V128.I16x8 (Ast.V128Op.ExtAddPairwise sign)
    | V128.I32x4 (Ast.V128Op.ExtAddPairwise sign)) ->
      app "instr.vextunop"
        [ishape lane; app "ishape.wrap" [vector_input_shape source at lane];
         app "vextunop.extadd-pairwise" [sx sign]]
  | (V128.I16x8 (Ast.V128Op.Extend (part, sign))
    | V128.I32x4 (Ast.V128Op.Extend (part, sign))
    | V128.I64x2 (Ast.V128Op.Extend (part, sign))) ->
      convert (vector_input_shape source at lane) (app "vcvtop.extend" [half part; sx sign])
  | V128.I32x4 (Ast.V128Op.TruncSatF32x4 sign) ->
      convert (shape F32x4) (app "vcvtop.trunc-sat" [sx sign; seq []])
  | V128.I32x4 (Ast.V128Op.TruncSatZeroF64x2 sign) ->
      convert (shape F64x2)
        (app "vcvtop.trunc-sat" [sx sign; present (atom "zero.zero")])
  | V128.I32x4 (Ast.V128Op.RelaxedTruncF32x4 sign) ->
      convert (shape F32x4) (app "vcvtop.relaxed-trunc" [sx sign; seq []])
  | V128.I32x4 (Ast.V128Op.RelaxedTruncZeroF64x2 sign) ->
      convert (shape F64x2)
        (app "vcvtop.relaxed-trunc" [sx sign; present (atom "zero.zero")])
  | V128.F32x4 (Ast.V128Op.ConvertI32x4 sign) ->
      convert (shape I32x4) (app "vcvtop.convert" [seq []; sx sign])
  | V128.F64x2 (Ast.V128Op.ConvertI32x4 sign) ->
      convert (shape I32x4)
        (app "vcvtop.convert" [present (atom "half.low"); sx sign])
  | V128.F32x4 Ast.V128Op.DemoteZeroF64x2 ->
      convert (shape F64x2) (app "vcvtop.demote" [atom "zero.zero"])
  | V128.F64x2 Ast.V128Op.PromoteLowF32x4 ->
      convert (shape F32x4) (atom "vcvtop.promote-low")
  | _ ->
      unsupported source at "vector conversion has an invalid source/result shape"

and vector_shift (op : Ast.V128Op.shiftop) =
  match op with
  | V128.I8x16 Ast.V128Op.Shl | V128.I16x8 Ast.V128Op.Shl
  | V128.I32x4 Ast.V128Op.Shl | V128.I64x2 Ast.V128Op.Shl ->
      app "instr.vshiftop" [ishape (lane_shape op); atom "vshiftop.shl"]
  | V128.I8x16 (Ast.V128Op.Shr sign)
  | V128.I16x8 (Ast.V128Op.Shr sign)
  | V128.I32x4 (Ast.V128Op.Shr sign)
  | V128.I64x2 (Ast.V128Op.Shr sign) ->
      app "instr.vshiftop"
        [ishape (lane_shape op); app "vshiftop.shr" [sx sign]]
  | _ -> .

and vector_bitmask (op : Ast.V128Op.bitmaskop) =
  match op with
  | V128.I8x16 Ast.V128Op.Bitmask | V128.I16x8 Ast.V128Op.Bitmask
  | V128.I32x4 Ast.V128Op.Bitmask | V128.I64x2 Ast.V128Op.Bitmask ->
      app "instr.vbitmask" [ishape (lane_shape op)]
  | _ -> .

and vector_splat op =
  match op with
  | V128.I8x16 Ast.V128Op.Splat | V128.I16x8 Ast.V128Op.Splat
  | V128.I32x4 Ast.V128Op.Splat | V128.I64x2 Ast.V128Op.Splat
  | V128.F32x4 Ast.V128Op.Splat | V128.F64x2 Ast.V128Op.Splat ->
      app "instr.vsplat" [shape (lane_shape op)]

and vector_extract op =
  let sh = shape (lane_shape op) in
  match op with
  | V128.I8x16 (Ast.V128Op.Extract (lane, sign))
  | V128.I16x8 (Ast.V128Op.Extract (lane, sign)) ->
      app "instr.vextract-lane" [sh; present (sx sign); laneidx lane]
  | V128.I32x4 (Ast.V128Op.Extract (lane, ()))
  | V128.I64x2 (Ast.V128Op.Extract (lane, ()))
  | V128.F32x4 (Ast.V128Op.Extract (lane, ()))
  | V128.F64x2 (Ast.V128Op.Extract (lane, ())) ->
      app "instr.vextract-lane" [sh; seq []; laneidx lane]

and vector_replace op =
  match op with
  | V128.I8x16 (Ast.V128Op.Replace lane)
  | V128.I16x8 (Ast.V128Op.Replace lane)
  | V128.I32x4 (Ast.V128Op.Replace lane)
  | V128.I64x2 (Ast.V128Op.Replace lane)
  | V128.F32x4 (Ast.V128Op.Replace lane)
  | V128.F64x2 (Ast.V128Op.Replace lane) ->
      app "instr.vreplace-lane" [shape (lane_shape op); laneidx lane]

and int_unop = function
  | Ast.IntOp.Clz -> atom "unop.clz"
  | Ast.IntOp.Ctz -> atom "unop.ctz"
  | Ast.IntOp.Popcnt -> atom "unop.popcnt"
  | Ast.IntOp.ExtendS size -> app "unop.extend" [packsize size]

and float_unop = function
  | Ast.FloatOp.Abs -> atom "unop.abs"
  | Ast.FloatOp.Neg -> atom "unop.neg"
  | Ast.FloatOp.Sqrt -> atom "unop.sqrt"
  | Ast.FloatOp.Ceil -> atom "unop.ceil"
  | Ast.FloatOp.Floor -> atom "unop.floor"
  | Ast.FloatOp.Trunc -> atom "unop.trunc"
  | Ast.FloatOp.Nearest -> atom "unop.nearest"

and unop = function
  | Value.I32 op -> (numtype Types.I32T, int_unop op)
  | Value.I64 op -> (numtype Types.I64T, int_unop op)
  | Value.F32 op -> (numtype Types.F32T, float_unop op)
  | Value.F64 op -> (numtype Types.F64T, float_unop op)

and int_binop = function
  | Ast.IntOp.Add -> atom "binop.add"
  | Ast.IntOp.Sub -> atom "binop.sub"
  | Ast.IntOp.Mul -> atom "binop.mul"
  | Ast.IntOp.Div sign -> app "binop.div-sx" [sx sign]
  | Ast.IntOp.Rem sign -> app "binop.rem" [sx sign]
  | Ast.IntOp.And -> atom "binop.and"
  | Ast.IntOp.Or -> atom "binop.or"
  | Ast.IntOp.Xor -> atom "binop.xor"
  | Ast.IntOp.Shl -> atom "binop.shl"
  | Ast.IntOp.Shr sign -> app "binop.shr" [sx sign]
  | Ast.IntOp.Rotl -> atom "binop.rotl"
  | Ast.IntOp.Rotr -> atom "binop.rotr"

and float_binop = function
  | Ast.FloatOp.Add -> atom "binop.add"
  | Ast.FloatOp.Sub -> atom "binop.sub"
  | Ast.FloatOp.Mul -> atom "binop.mul"
  | Ast.FloatOp.Div -> atom "binop.div"
  | Ast.FloatOp.Min -> atom "binop.min"
  | Ast.FloatOp.Max -> atom "binop.max"
  | Ast.FloatOp.CopySign -> atom "binop.copysign"

and binop = function
  | Value.I32 op -> (numtype Types.I32T, int_binop op)
  | Value.I64 op -> (numtype Types.I64T, int_binop op)
  | Value.F32 op -> (numtype Types.F32T, float_binop op)
  | Value.F64 op -> (numtype Types.F64T, float_binop op)

and testop = function
  | Value.I32 Ast.IntOp.Eqz -> (numtype Types.I32T, atom "testop.eqz")
  | Value.I64 Ast.IntOp.Eqz -> (numtype Types.I64T, atom "testop.eqz")
  | Value.F32 op -> float_testop op
  | Value.F64 op -> float_testop op

and float_testop (op : Ast.FloatOp.testop) = match op with _ -> .

and int_relop = function
  | Ast.IntOp.Eq -> atom "relop.eq"
  | Ast.IntOp.Ne -> atom "relop.ne"
  | Ast.IntOp.Lt sign -> app "relop.lt-sx" [sx sign]
  | Ast.IntOp.Gt sign -> app "relop.gt-sx" [sx sign]
  | Ast.IntOp.Le sign -> app "relop.le-sx" [sx sign]
  | Ast.IntOp.Ge sign -> app "relop.ge-sx" [sx sign]

and float_relop = function
  | Ast.FloatOp.Eq -> atom "relop.eq"
  | Ast.FloatOp.Ne -> atom "relop.ne"
  | Ast.FloatOp.Lt -> atom "relop.lt"
  | Ast.FloatOp.Gt -> atom "relop.gt"
  | Ast.FloatOp.Le -> atom "relop.le"
  | Ast.FloatOp.Ge -> atom "relop.ge"

and relop = function
  | Value.I32 op -> (numtype Types.I32T, int_relop op)
  | Value.I64 op -> (numtype Types.I64T, int_relop op)
  | Value.F32 op -> (numtype Types.F32T, float_relop op)
  | Value.F64 op -> (numtype Types.F64T, float_relop op)

and cvtop_op = function
  | Ast.IntOp.ExtendI32 sign -> app "cvtop.extend" [sx sign]
  | Ast.IntOp.WrapI64 -> atom "cvtop.wrap"
  | Ast.IntOp.TruncF32 sign | Ast.IntOp.TruncF64 sign ->
      app "cvtop.trunc" [sx sign]
  | Ast.IntOp.TruncSatF32 sign | Ast.IntOp.TruncSatF64 sign ->
      app "cvtop.trunc-sat" [sx sign]
  | Ast.IntOp.ReinterpretFloat -> atom "cvtop.reinterpret"

and float_cvtop_op = function
  | Ast.FloatOp.ConvertI32 sign | Ast.FloatOp.ConvertI64 sign ->
      app "cvtop.convert" [sx sign]
  | Ast.FloatOp.PromoteF32 -> atom "cvtop.promote"
  | Ast.FloatOp.DemoteF64 -> atom "cvtop.demote"
  | Ast.FloatOp.ReinterpretInt -> atom "cvtop.reinterpret"

and int_cvtop_source reinterpret_source = function
  | Ast.IntOp.ExtendI32 _ -> numtype Types.I32T
  | Ast.IntOp.WrapI64 -> numtype Types.I64T
  | Ast.IntOp.TruncF32 _ | Ast.IntOp.TruncSatF32 _ -> numtype Types.F32T
  | Ast.IntOp.TruncF64 _ | Ast.IntOp.TruncSatF64 _ -> numtype Types.F64T
  | Ast.IntOp.ReinterpretFloat -> numtype reinterpret_source

and float_cvtop_source reinterpret_source = function
  | Ast.FloatOp.ConvertI32 _ -> numtype Types.I32T
  | Ast.FloatOp.ConvertI64 _ -> numtype Types.I64T
  | Ast.FloatOp.PromoteF32 -> numtype Types.F32T
  | Ast.FloatOp.DemoteF64 -> numtype Types.F64T
  | Ast.FloatOp.ReinterpretInt -> numtype reinterpret_source

and cvtop = function
  | Value.I32 op ->
      let target = Types.I32T in
      (numtype target, int_cvtop_source Types.F32T op, cvtop_op op)
  | Value.I64 op ->
      let target = Types.I64T in
      (numtype target, int_cvtop_source Types.F64T op, cvtop_op op)
  | Value.F32 op ->
      let target = Types.F32T in
      (numtype target, float_cvtop_source Types.I32T op, float_cvtop_op op)
  | Value.F64 op ->
      let target = Types.F64T in
      (numtype target, float_cvtop_source Types.I64T op, float_cvtop_op op)

and float_term ~negative ~exponent ~fraction ~max_exponent ~bias =
  let mag =
    if exponent = 0 then app "fNmag.subnorm" [atom (Int64.to_string fraction)]
    else if exponent = max_exponent then
      if fraction = 0L then atom "fNmag.inf"
      else app "fNmag.nan" [atom (Int64.to_string fraction)]
    else
      app "fNmag.norm"
        [atom (Int64.to_string fraction); atom (string_of_int (exponent - bias))]
  in
  app (if negative then "fN.neg" else "fN.pos") [mag]

and f32 n =
  let bits = Int64.logand (Int64.of_int32 (F32.to_bits n)) 0xffff_ffffL in
  float_term
    ~negative:(Int64.shift_right_logical bits 31 = 1L)
    ~exponent:(Int64.to_int (Int64.logand (Int64.shift_right_logical bits 23) 0xffL))
    ~fraction:(Int64.logand bits 0x7f_ffffL)
    ~max_exponent:0xff ~bias:127

and f64 n =
  let bits = F64.to_bits n in
  float_term
    ~negative:(Int64.shift_right_logical bits 63 = 1L)
    ~exponent:(Int64.to_int (Int64.logand (Int64.shift_right_logical bits 52) 0x7ffL))
    ~fraction:(Int64.logand bits 0x000f_ffff_ffff_ffffL)
    ~max_exponent:0x7ff ~bias:1023

and const = function
  | Value.I32 n -> (numtype Types.I32T, app "uN.wrap" [i32_nat n])
  | Value.I64 n -> (numtype Types.I64T, app "uN.wrap" [i64_nat n])
  | Value.F32 n -> (numtype Types.F32T, f32 n)
  | Value.F64 n -> (numtype Types.F64T, f64 n)

and blocktype source at = function
  | Ast.VarBlockType x -> app "idx" [idx x]
  | Ast.ValBlockType result ->
      app "blocktype.result" [option (valtype source at) result]

and typeidx x = app "idx" [idx x]

and catch {Source.it; _} = match it with
  | Ast.Catch (tag, label) -> app "catch.catch" [idx tag; idx label]
  | Ast.CatchRef (tag, label) -> app "catch.catch-ref" [idx tag; idx label]
  | Ast.CatchAll label -> app "catch.catch-all" [idx label]
  | Ast.CatchAllRef label -> app "catch.catch-all-ref" [idx label]

and instr source ({Source.it; at} : Ast.instr) =
  let unary name x = app name [idx x] in
  match it with
  | Ast.Unreachable -> atom "instr.unreachable"
  | Ast.Nop -> atom "instr.nop"
  | Ast.Drop -> atom "instr.drop"
  | Ast.Select types ->
      let types =
        option
          (fun ts -> app "seq" [seq (List.map (valtype source at) ts)])
          types
      in
      app "instr.select" [types]
  | Ast.Block (bt, body) ->
      app "instr.block" [blocktype source at bt; seq (List.map (instr source) body)]
  | Ast.Loop (bt, body) ->
      app "instr.loop" [blocktype source at bt; seq (List.map (instr source) body)]
  | Ast.If (bt, yes, no) ->
      app "instr.if-else"
        [ blocktype source at bt;
          seq (List.map (instr source) yes);
          seq (List.map (instr source) no) ]
  | Ast.Br x -> unary "instr.br" x
  | Ast.BrIf x -> unary "instr.br-if" x
  | Ast.BrTable (xs, x) ->
      app "instr.br-table" [seq (List.map idx xs); idx x]
  | Ast.BrOnNull x -> unary "instr.br-on-null" x
  | Ast.BrOnNonNull x -> unary "instr.br-on-non-null" x
  | Ast.BrOnCast (label, from, into) ->
      app "instr.br-on-cast"
        [idx label; reftype source at from; reftype source at into]
  | Ast.BrOnCastFail (label, from, into) ->
      app "instr.br-on-cast-fail"
        [idx label; reftype source at from; reftype source at into]
  | Ast.Return -> atom "instr.return"
  | Ast.Call x -> unary "instr.call" x
  | Ast.CallRef x -> app "instr.call-ref" [typeidx x]
  | Ast.CallIndirect (table, typ) ->
      app "instr.call-indirect" [idx table; typeidx typ]
  | Ast.ReturnCall x -> unary "instr.return-call" x
  | Ast.ReturnCallRef x -> app "instr.return-call-ref" [typeidx x]
  | Ast.ReturnCallIndirect (table, typ) ->
      app "instr.return-call-indirect" [idx table; typeidx typ]
  | Ast.Throw tag -> unary "instr.throw" tag
  | Ast.ThrowRef -> atom "instr.throw-ref"
  | Ast.TryTable (bt, catches, body) ->
      app "instr.try-table"
        [blocktype source at bt; list catch catches; expr source body]
  | Ast.LocalGet x -> unary "instr.local-get" x
  | Ast.LocalSet x -> unary "instr.local-set" x
  | Ast.LocalTee x -> unary "instr.local-tee" x
  | Ast.GlobalGet x -> unary "instr.global-get" x
  | Ast.GlobalSet x -> unary "instr.global-set" x
  | Ast.TableGet x -> unary "instr.table-get" x
  | Ast.TableSet x -> unary "instr.table-set" x
  | Ast.TableSize x -> unary "instr.table-size" x
  | Ast.TableGrow x -> unary "instr.table-grow" x
  | Ast.TableFill x -> unary "instr.table-fill" x
  | Ast.TableCopy (x, y) -> app "instr.table-copy" [idx x; idx y]
  | Ast.TableInit (x, y) -> app "instr.table-init" [idx x; idx y]
  | Ast.ElemDrop x -> unary "instr.elem-drop" x
  | Ast.Load (memory, op) ->
      let typ, packed = loadop op in
      app "instr.load" [typ; packed; idx memory; memarg op.align op.offset]
  | Ast.Store (memory, op) ->
      let typ, packed = storeop op in
      app "instr.store" [typ; packed; idx memory; memarg op.align op.offset]
  | Ast.VecLoad (memory, op) ->
      app "instr.vload"
        [vectype op.ty; vloadop op.pack; idx memory; memarg op.align op.offset]
  | Ast.VecStore (memory, op) ->
      app "instr.vstore"
        [vectype op.ty; idx memory; memarg op.align op.offset]
  | Ast.VecLoadLane (memory, op, lane) ->
      app "instr.vload-lane"
        [ vectype op.ty; packsize op.pack; idx memory;
          memarg op.align op.offset; laneidx lane ]
  | Ast.VecStoreLane (memory, op, lane) ->
      app "instr.vstore-lane"
        [ vectype op.ty; packsize op.pack; idx memory;
          memarg op.align op.offset; laneidx lane ]
  | Ast.MemorySize x -> unary "instr.memory-size" x
  | Ast.MemoryGrow x -> unary "instr.memory-grow" x
  | Ast.MemoryFill x -> unary "instr.memory-fill" x
  | Ast.MemoryCopy (x, y) -> app "instr.memory-copy" [idx x; idx y]
  | Ast.MemoryInit (x, y) -> app "instr.memory-init" [idx x; idx y]
  | Ast.DataDrop x -> unary "instr.data-drop" x
  | Ast.RefNull t -> app "instr.ref-null" [heaptype source at t]
  | Ast.RefFunc x -> unary "instr.ref-func" x
  | Ast.RefIsNull -> atom "instr.ref-is-null"
  | Ast.RefAsNonNull -> atom "instr.ref-as-non-null"
  | Ast.RefTest t -> app "instr.ref-test" [reftype source at t]
  | Ast.RefCast t -> app "instr.ref-cast" [reftype source at t]
  | Ast.RefEq -> atom "instr.ref-eq"
  | Ast.RefI31 -> atom "instr.ref-i31"
  | Ast.I31Get sign -> app "instr.i31-get" [sx sign]
  | Ast.StructNew (typ, Ast.Explicit) -> unary "instr.struct-new" typ
  | Ast.StructNew (typ, Ast.Implicit) -> unary "instr.struct-new-default" typ
  | Ast.StructGet (typ, field, sign) ->
      app "instr.struct-get"
        [option sx sign; idx typ; app "uN.wrap" [i32_nat field]]
  | Ast.StructSet (typ, field) ->
      app "instr.struct-set"
        [idx typ; app "uN.wrap" [i32_nat field]]
  | Ast.ArrayNew (typ, Ast.Explicit) -> unary "instr.array-new" typ
  | Ast.ArrayNew (typ, Ast.Implicit) -> unary "instr.array-new-default" typ
  | Ast.ArrayNewFixed (typ, count) ->
      app "instr.array-new-fixed"
        [idx typ; app "uN.wrap" [i32_nat count]]
  | Ast.ArrayNewData (typ, data) ->
      app "instr.array-new-data" [idx typ; idx data]
  | Ast.ArrayNewElem (typ, elem) ->
      app "instr.array-new-elem" [idx typ; idx elem]
  | Ast.ArrayGet (typ, sign) -> app "instr.array-get" [option sx sign; idx typ]
  | Ast.ArraySet typ -> unary "instr.array-set" typ
  | Ast.ArrayLen -> atom "instr.array-len"
  | Ast.ArrayCopy (dst, src) -> app "instr.array-copy" [idx dst; idx src]
  | Ast.ArrayFill typ -> unary "instr.array-fill" typ
  | Ast.ArrayInitData (typ, data) ->
      app "instr.array-init-data" [idx typ; idx data]
  | Ast.ArrayInitElem (typ, elem) ->
      app "instr.array-init-elem" [idx typ; idx elem]
  | Ast.ExternConvert Ast.Internalize -> atom "instr.any-convert-extern"
  | Ast.ExternConvert Ast.Externalize -> atom "instr.extern-convert-any"
  | Ast.Const n ->
      let typ, value = const n.it in
      app "const" [typ; value]
  | Ast.Test op ->
      let typ, op = testop op in
      app "instr.testop" [typ; op]
  | Ast.Compare op ->
      let typ, op = relop op in
      app "instr.relop" [typ; op]
  | Ast.Unary op ->
      let typ, op = unop op in
      app "instr.unop" [typ; op]
  | Ast.Binary op ->
      let typ, op = binop op in
      app "instr.binop" [typ; op]
  | Ast.Convert op ->
      let target, source, op = cvtop op in
      app "instr.cvtop" [target; source; op]
  | Ast.VecConst value ->
      let Value.V128 value = value.it in
      vec_instr value
  | Ast.VecTest (Value.V128 op) -> vector_test op
  | Ast.VecCompare (Value.V128 op) -> vector_relop op
  | Ast.VecUnary (Value.V128 op) -> vector_unop op
  | Ast.VecBinary (Value.V128 op) -> vector_binop source at op
  | Ast.VecTernary (Value.V128 op) -> vector_ternop source at op
  | Ast.VecConvert (Value.V128 op) -> vector_convert source at op
  | Ast.VecShift (Value.V128 op) -> vector_shift op
  | Ast.VecBitmask (Value.V128 op) -> vector_bitmask op
  | Ast.VecTestBits (Value.V128 Ast.V128Op.AnyTrue) ->
      app "instr.vvtestop" [atom "vectype.v128"; atom "vvtestop.any-true"]
  | Ast.VecUnaryBits (Value.V128 Ast.V128Op.Not) ->
      app "instr.vvunop" [atom "vectype.v128"; atom "vvunop.not"]
  | Ast.VecBinaryBits (Value.V128 op) ->
      let op = match op with
        | Ast.V128Op.And -> atom "vvbinop.and"
        | Ast.V128Op.AndNot -> atom "vvbinop.andnot"
        | Ast.V128Op.Or -> atom "vvbinop.or"
        | Ast.V128Op.Xor -> atom "vvbinop.xor"
      in
      app "instr.vvbinop" [atom "vectype.v128"; op]
  | Ast.VecTernaryBits (Value.V128 Ast.V128Op.Bitselect) ->
      app "instr.vvternop" [atom "vectype.v128"; atom "vvternop.bitselect"]
  | Ast.VecSplat (Value.V128 op) -> vector_splat op
  | Ast.VecExtract (Value.V128 op) -> vector_extract op
  | Ast.VecReplace (Value.V128 op) -> vector_replace op

let name chars =
  seq (List.map nat chars)

let num_value value =
  let typ, value = const value in
  app "const" [typ; value]

let num_instr value =
  let typ, value = const value in
  app "const" [typ; value]

let num_payload value = snd (const value)

let reference_value = function
  | Value.NullRef -> atom "ref.ref-null-addr"
  | Script.HostRef address ->
      app "ref.ref-host-addr" [atom (Int32.to_string address)]
  | Extern.ExternRef (Script.HostRef address) ->
      app "ref.ref-extern"
        [app "ref.ref-host-addr" [atom (Int32.to_string address)]]
  | _ -> invalid_arg "Encode.reference_value"

let result_heaptype typ =
  heaptype "WAST result pattern" Source.no_region typ

let result_numtype = numtype

let type_ source ({Source.it; at} : Ast.type_) =
  app "type.type" [rectype source at it]

let tag source ({Source.it = Ast.Tag typ; at} : Ast.tag) =
  let Types.TagT use = typ in
  app "tag" [typeuse source at use]

let global source ({Source.it = Ast.Global (typ, init); at} : Ast.global) =
  app "global.global" [globaltype source at typ; expr source init.it]

let memory ({Source.it = Ast.Memory typ; _} : Ast.memory) =
  app "mem.memory" [memtype typ]

let table source ({Source.it = Ast.Table (typ, init); at} : Ast.table) =
  app "table.table" [tabletype source at typ; expr source init.it]

let local source ({Source.it = Ast.Local typ; at} : Ast.local) =
  app "local.local" [valtype source at typ]

let func source ({Source.it = Ast.Func (typ, locals, body); _} : Ast.func) =
  app "func.func" [idx typ; seq (List.map (local source) locals); expr source body]

let mode source = function
  | {Source.it = Ast.Passive; _} -> atom "passive"
  | {Source.it = Ast.Active (x, init); _} ->
      app "datamode.active" [idx x; expr source init.it]
  | {Source.it = Ast.Declarative; at} ->
      unsupported source at "declarative mode is valid only for element segments"

let elem_mode source = function
  | {Source.it = Ast.Passive; _} -> atom "passive"
  | {Source.it = Ast.Declarative; _} -> atom "elemmode.declare"
  | {Source.it = Ast.Active (x, init); _} ->
      app "elemmode.active" [idx x; expr source init.it]

let data source ({Source.it = Ast.Data (bytes, m); _} : Ast.data) =
  let bytes =
    String.to_seq bytes
    |> List.of_seq
    |> List.map (fun c -> app "byte.wrap" [nat (Char.code c)])
  in
  app "data.data" [seq bytes; mode source m]

let elem source ({Source.it = Ast.Elem (typ, inits, m); at} : Ast.elem) =
  app "elem.elem"
    [ reftype source at typ;
      seq (List.map (fun init -> expr_item source init.Source.it) inits);
      elem_mode source m ]

let start ({Source.it = Ast.Start x; _} : Ast.start) = app "start.start" [idx x]

let externidx = function
  | {Source.it = Ast.TagX x; _} -> app "externidx.tag" [idx x]
  | {Source.it = Ast.GlobalX x; _} -> app "externidx.global" [idx x]
  | {Source.it = Ast.MemoryX x; _} -> app "externidx.mem" [idx x]
  | {Source.it = Ast.TableX x; _} -> app "externidx.table" [idx x]
  | {Source.it = Ast.FuncX x; _} -> app "externidx.func" [idx x]

let export ({Source.it = Ast.Export (n, x); _} : Ast.export) =
  app "export.export" [name n; externidx x]

let import source ({Source.it = Ast.Import (m, n, typ); at} : Ast.import) =
  app "import.import" [name m; name n; externtype source at typ]

let module_ ({Frontend.source; ast; _} : Frontend.module_) =
  let m = ast.Source.it in
  app "module.module"
    [ list (type_ source) m.Ast.types;
      list (import source) m.imports;
      list (tag source) m.tags;
      list (global source) m.globals;
      list memory m.memories;
      list (table source) m.tables;
      list (func source) m.funcs;
      list (data source) m.datas;
      list (elem source) m.elems;
      option start m.start;
      list export m.exports ]

type check = {label : string; term : T.t}

let typecheck label term typ =
  {label; term = app "typecheck" [term; typ]}

let check label term typ = typecheck label term (atom typ)
let check_sequence = check

let rec instr_checks source path instruction =
  let here = check path (instr source instruction) "syn.instr" in
  let nested suffix body = body_checks source (path ^ suffix) body in
  let children =
    match instruction.Source.it with
    | Ast.Block (_, body) -> nested ".block" body
    | Ast.Loop (_, body) -> nested ".loop" body
    | Ast.If (_, yes, no) -> nested ".then" yes @ nested ".else" no
    | Ast.TryTable (_, _, body) -> nested ".try" body
    | _ -> []
  in
  here :: children

and body_checks source path body =
  body
  |> List.mapi (fun i instruction ->
         instr_checks source (Printf.sprintf "%s.%d" path (i + 1)) instruction)
  |> List.concat

let func_checks source i ({Source.it = Ast.Func (_, _, body); _} as f) =
  let path = Printf.sprintf "func.%d" (i + 1) in
  check path (func source f) "syn.func"
  :: check_sequence (path ^ ".body") (expr source body) "syn.expr"
  :: body_checks source (path ^ ".instr") body

let module_checks ({Frontend.source; ast; _} as m : Frontend.module_) =
  let m' = ast.Source.it in
  let list_check label encode xs typ =
    typecheck label (list encode xs) (app "list" [atom typ])
  in
  [ check "module" (module_ m) "syn.module";
    list_check "types" (type_ source) m'.Ast.types "syn.type";
    list_check "imports" (import source) m'.imports "syn.import";
    list_check "tags" (tag source) m'.tags "syn.tag";
    list_check "globals" (global source) m'.globals "syn.global";
    list_check "memories" memory m'.memories "syn.mem";
    list_check "tables" (table source) m'.tables "syn.table";
    list_check "funcs" (func source) m'.funcs "syn.func";
    list_check "datas" (data source) m'.datas "syn.data";
    list_check "elems" (elem source) m'.elems "syn.elem";
    check_sequence "start" (option start m'.start) "syn.start";
    list_check "exports" export m'.exports "syn.export" ]
  @ (m'.funcs |> List.mapi (func_checks source) |> List.concat)

let check_label check = check.label
let check_term check = check.term
