type t = Maude_term.t

let raw_atom = Maude_term.atom
let raw_app = Maude_term.app
let seq = Maude_term.seq

let upper = String.uppercase_ascii

let remove_syn name =
  match String.split_on_char '.' name with
  | "syn" :: parts -> String.concat "." parts
  | _ -> name

let instruction_name suffix =
  let dotted category =
    let prefix = category ^ "-" in
    if String.starts_with ~prefix suffix then
      let suffix =
        String.sub suffix (String.length prefix)
          (String.length suffix - String.length prefix)
      in
      Some (upper category ^ "." ^ upper suffix)
    else None
  in
  if suffix = "if-else" then "IF__ELSE_"
  else
    [ "local"; "global"; "table"; "memory"; "elem"; "data"; "ref"
    ; "struct"; "array"; "extern"; "any"; "i31"
    ]
    |> List.find_map dotted
    |> Option.value ~default:(upper suffix)

let source_name = function
  | "i32" -> "I32"
  | "i64" -> "I64"
  | "f32" -> "F32"
  | "f64" -> "F64"
  | "bot" -> "BOT"
  | "passive" -> "PASSIVE"
  | "rec" -> "REC"
  | "idx" -> "-IDX"
  | "absheaptype.func" -> "spectec-FUNC"
  | name when String.starts_with ~prefix:"absheaptype." name ->
      upper (String.sub name 12 (String.length name - 12))
  | "vectype.v128" -> "V128"
  | "packtype.i8" -> "I8"
  | "packtype.i16" -> "I16"
  | "null.null" -> "NULL"
  | "mut.mut" -> "MUT"
  | "final.final" -> "FINAL"
  | "sx.u" -> "U"
  | "sx.s" -> "S"
  | "half.low" -> "LOW"
  | "half.high" -> "HIGH"
  | "fNmag.norm" -> "NORM"
  | "fNmag.subnorm" -> "SUBNORM"
  | "fNmag.inf" -> "INF"
  | "fNmag.nan" -> "NAN"
  | "fN.pos" -> "POS"
  | "fN.neg" -> "NEG"
  | "reftype.ref" -> "REF"
  | "subtype.sub" -> "SUB"
  | "rectype.rec" -> "REC"
  | "deftype.def" -> "-DEF"
  | "comptype.struct" -> "spectec-STRUCT"
  | "comptype.array" -> "spectec-ARRAY"
  | "comptype.func-sym" -> "FUNC_->_"
  | "limits.sym-sym-sym" -> "[_.._]"
  | "memtype.page" -> "__PAGE"
  | "shape.x" -> "_X_"
  | "loadop.sym" -> "spectec-_-_"
  | "vloadop.shape-x-sym" -> "SHAPE_X_-_"
  | "vloadop.splat" -> "SPLAT"
  | "vloadop.zero" -> "spectec-ZERO"
  | "blocktype.result" -> "-RESULT"
  | "catch.catch" -> "CATCH"
  | "catch.catch-ref" -> "CATCH-REF"
  | "catch.catch-all" -> "CATCH-ALL"
  | "catch.catch-all-ref" -> "CATCH-ALL-REF"
  | "unop.neg" | "vunop.neg" -> "spectec-NEG"
  | name when String.starts_with ~prefix:"unop." name ->
      upper (String.sub name 5 (String.length name - 5))
  | "binop.sub" -> "spectec-SUB"
  | "binop.div" -> "spectec-DIV"
  | "binop.div-sx" -> "DIV"
  | name when String.starts_with ~prefix:"binop." name ->
      let suffix = String.sub name 6 (String.length name - 6) in
      upper (if suffix = "rem" then "REM" else suffix)
  | "relop.lt" -> "spectec-LT"
  | "relop.gt" -> "spectec-GT"
  | "relop.le" -> "spectec-LE"
  | "relop.ge" -> "spectec-GE"
  | "relop.lt-sx" -> "LT"
  | "relop.gt-sx" -> "GT"
  | "relop.le-sx" -> "LE"
  | "relop.ge-sx" -> "GE"
  | name when String.starts_with ~prefix:"relop." name ->
      upper (String.sub name 6 (String.length name - 6))
  | "cvtop.trunc" -> "spectec-TRUNC"
  | name when String.starts_with ~prefix:"cvtop." name ->
      upper (String.sub name 6 (String.length name - 6))
  | "vbinop.sub" -> "spectec-SUB"
  | "vbinop.div" -> "spectec-DIV"
  | "vbinop.min-sx" -> "spectec-MIN"
  | "vbinop.max-sx" -> "spectec-MAX"
  | "vbinop.avgr-u" -> "AVGRU"
  | "vbinop.q15mulr-sat-s" -> "Q15MULR-SATS"
  | "vbinop.relaxed-q15mulr-s" -> "RELAXED-Q15MULRS"
  | name when String.starts_with ~prefix:"vbinop." name ->
      upper (String.sub name 7 (String.length name - 7))
  | "vrelop.lt" -> "spectec-LT"
  | "vrelop.gt" -> "spectec-GT"
  | "vrelop.le" -> "spectec-LE"
  | "vrelop.ge" -> "spectec-GE"
  | "vrelop.lt-sx" -> "LT"
  | "vrelop.gt-sx" -> "GT"
  | "vrelop.le-sx" -> "LE"
  | "vrelop.ge-sx" -> "GE"
  | name when String.starts_with ~prefix:"vrelop." name ->
      upper (String.sub name 7 (String.length name - 7))
  | name when String.starts_with ~prefix:"vshiftop." name ->
      upper (String.sub name 9 (String.length name - 9))
  | name when String.starts_with ~prefix:"vswizzlop." name ->
      upper (String.sub name 10 (String.length name - 10))
  | "vextunop.extadd-pairwise" -> "EXTADD-PAIRWISE"
  | "vextbinop.extmul" -> "EXTMUL"
  | "vextbinop.dot-s" -> "DOTS"
  | "vextbinop.relaxed-dot-s" -> "RELAXED-DOTS"
  | "vextternop.relaxed-dot-add-s" -> "RELAXED-DOT-ADDS"
  | "vcvtop.extend" -> "spectec-EXTEND"
  | "vcvtop.convert" -> "spectec-CONVERT"
  | "vcvtop.trunc-sat" -> "spectec-TRUNC-SAT"
  | "vcvtop.relaxed-trunc" -> "RELAXED-TRUNC"
  | "vcvtop.demote" -> "spectec-DEMOTE"
  | "vcvtop.promote-low" -> "PROMOTELOW"
  | name when String.starts_with ~prefix:"vunop." name ->
      upper (String.sub name 6 (String.length name - 6))
  | name when String.starts_with ~prefix:"vternop." name ->
      upper (String.sub name 8 (String.length name - 8))
  | name when String.starts_with ~prefix:"vtestop." name ->
      upper (String.sub name 8 (String.length name - 8))
  | name when String.starts_with ~prefix:"vvunop." name ->
      upper (String.sub name 7 (String.length name - 7))
  | name when String.starts_with ~prefix:"vvbinop." name ->
      upper (String.sub name 8 (String.length name - 8))
  | name when String.starts_with ~prefix:"vvternop." name ->
      upper (String.sub name 9 (String.length name - 9))
  | name when String.starts_with ~prefix:"vvtestop." name ->
      upper (String.sub name 9 (String.length name - 9))
  | "zero.zero" -> "ZERO"
  | name when String.starts_with ~prefix:"instr." name ->
      instruction_name (String.sub name 6 (String.length name - 6))
  | "const" -> "CONST"
  | "vconst" -> "VCONST"
  | "type.type" -> "TYPE"
  | "tag" -> "TAG"
  | "global.global" -> "spectec-GLOBAL"
  | "mem.memory" -> "MEMORY"
  | "table.table" -> "spectec-TABLE"
  | "local.local" -> "LOCAL"
  | "func.func" -> "spectec-FUNC-2"
  | "data.data" -> "DATA"
  | "elem.elem" -> "ELEM"
  | "start.start" -> "START"
  | "import.import" -> "IMPORT"
  | "export.export" -> "EXPORT"
  | "module.module" -> "MODULE"
  | "datamode.active" | "elemmode.active" -> "ACTIVE"
  | "elemmode.declare" -> "DECLARE"
  | name when String.starts_with ~prefix:"externtype." name ->
      upper (String.sub name 11 (String.length name - 11))
  | name when String.starts_with ~prefix:"externidx." name ->
      upper (String.sub name 10 (String.length name - 10))
  | name when String.starts_with ~prefix:"externaddr." name ->
      upper (String.sub name 11 (String.length name - 11))
  | name when String.starts_with ~prefix:"testop." name ->
      upper (String.sub name 7 (String.length name - 7))
  | "ref.ref-null-addr" -> "REF.NULL-ADDR"
  | "ref.ref-i31-num" -> "REF.I31-NUM"
  | "ref.ref-struct-addr" -> "REF.STRUCT-ADDR"
  | "ref.ref-array-addr" -> "REF.ARRAY-ADDR"
  | "ref.ref-func-addr" -> "REF.FUNC-ADDR"
  | "ref.ref-exn-addr" -> "REF.EXN-ADDR"
  | "ref.ref-host-addr" -> "REF.HOST-ADDR"
  | "ref.ref-extern" -> "REF.EXTERN"
  | "hostfunc.sym" -> "..."
  | "typecheck" | "isOpt" | "seq" | "_?" as name -> name
  | name when String.starts_with ~prefix:"instances." name -> name
  | name when String.starts_with ~prefix:"syn." name -> remove_syn name
  | name when String.contains name '.' ->
      invalid_arg ("unmapped SpecTec term name: " ^ name)
  | name -> name

let atom name = raw_atom (source_name name)

let item field value = raw_app "item" [raw_atom ("'" ^ field); value]

let rec items = function
  | [] -> raw_atom "EMPTY"
  | [entry] -> entry
  | entry :: rest -> raw_app "_;_" [entry; items rest]

let record fields =
  fields
  |> List.map (fun (name, value) -> item name value)
  |> items
  |> fun fields -> raw_app "{_}" [fields]

let app name arguments =
  match name, arguments with
  | ( "uN.wrap" | "dim.wrap" | "sz.wrap" | "byte.wrap" | "char.wrap"
    | "name.wrap" | "list.wrap" | "bshape.wrap" | "ishape.wrap"
    | "storeop.wrap" ), [value] ->
      value
  | ("fieldtype.wrap" | "globaltype.wrap"), [modifier; value_type] ->
      raw_app "tuple" [seq [raw_app "seq" [modifier]; value_type]]
  | "tabletype.wrap", [addr; limits; reftype] ->
      raw_app "tuple" [seq [addr; limits; reftype]]
  | "rec.memarg", [align; offset] ->
      record ["ALIGN", align; "OFFSET", offset]
  | "rec.exportinst", [name; addr] ->
      record ["NAME", name; "ADDR", addr]
  | "rec.globalinst", [typ; value] ->
      record ["TYPE", typ; "VALUE", value]
  | "rec.meminst", [typ; bytes] ->
      record ["TYPE", typ; "BYTES", bytes]
  | "rec.tableinst", [typ; refs] ->
      record ["TYPE", typ; "REFS", refs]
  | "rec.funcinst", [typ; module_; code] ->
      record ["TYPE", typ; "MODULE", module_; "CODE", code]
  | "rec.frame", [locals; module_] ->
      record ["LOCALS", locals; "MODULE", module_]
  | ( "rec.moduleinst"
    , [types; tags; globals; mems; tables; funcs; datas; elems; exports] ) ->
      record
        [ "TYPES", types; "TAGS", tags; "GLOBALS", globals; "MEMS", mems
        ; "TABLES", tables; "FUNCS", funcs; "DATAS", datas; "ELEMS", elems
        ; "EXPORTS", exports
        ]
  | ( "rec.store"
    , [tags; globals; mems; tables; funcs; datas; elems; structs; arrays; exns] ) ->
      record
        [ "TAGS", tags; "GLOBALS", globals; "MEMS", mems; "TABLES", tables
        ; "FUNCS", funcs; "DATAS", datas; "ELEMS", elems; "STRUCTS", structs
        ; "ARRAYS", arrays; "EXNS", exns
        ]
  | "helper.iter-count.allocmem", [count; _minimum] ->
      raw_app "repeatSeq" [count; raw_atom "0"]
  | "helper.iter-count.alloctable", [count; _minimum; reference] ->
      raw_app "repeatSeq" [count; reference]
  | _ -> raw_app (source_name name) arguments
