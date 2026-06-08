(* WebAssembly WAT/Wasm-to-Maude frontend for the C1 execution path.

   Input parsing and validation use the official SpecTec/WebAssembly
   interpreter library vendored under vendor/wasm.  The frontend then lowers
   the validated Wasm AST into the Maude constructor terms consumed by the
   generated C1 semantics and execution harness.
*)

type sexpr = Atom of string | List of sexpr list

type func_type = { params : string list; results : string list }

type type_def = {
  type_id : string option;
  type_term : string;
  type_func : func_type option;
}

type import_func = {
  import_module : string;
  import_name : string;
  import_id : string option;
  import_typeidx : int;
  import_wat_index : int;
}

type import_desc =
  | ImportFunc of import_func
  | ImportTag of {
      import_module : string;
      import_name : string;
      import_id : string option;
      import_tagtype : string;
      import_wat_index : int;
    }
  | ImportGlobal of {
      import_module : string;
      import_name : string;
      import_id : string option;
      import_globaltype : string;
      import_wat_index : int;
    }
  | ImportMemory of {
      import_module : string;
      import_name : string;
      import_id : string option;
      import_memtype : string;
      import_mem_min : int;
      import_wat_index : int;
    }
  | ImportTable of {
      import_module : string;
      import_name : string;
      import_id : string option;
      import_tabletype : string;
      import_table_min : int;
      import_table_default_ref : string;
      import_wat_index : int;
    }

type func_def = {
  func_id : string option;
  func_typeidx : int;
  func_locals : string list;
  func_body : string list;
  func_inline_exports : string list;
  func_wat_index : int;
}

type export_desc =
  | ExportFunc of int
  | ExportTag of int
  | ExportGlobal of int
  | ExportMemory of int
  | ExportTable of int

type export_item = { export_item_name : string; export_item_desc : export_desc }

type global_def = {
  global_id : string option;
  global_type : string;
  global_init : string list;
  global_inline_exports : string list;
  global_wat_index : int;
}

type tag_def = {
  tag_id : string option;
  tag_type : string;
  tag_inline_exports : string list;
  tag_wat_index : int;
}

type memory_def = {
  memory_id : string option;
  memory_type : string;
  memory_inline_exports : string list;
  memory_wat_index : int;
}

type table_def = {
  table_id : string option;
  table_type : string;
  table_init : string list;
  table_inline_exports : string list;
  table_wat_index : int;
}

type data_def = { data_bytes : int list; data_mode : string }

type elem_def = { elem_type : string; elem_exprs : string list; elem_mode : string }

(* This is not a parser AST.  The parser AST is Wasm.Ast.module_ from the
   official SpecTec/WebAssembly interpreter.  module_ir is only the small
   post-validation emission record used to print Maude constructor terms. *)
type module_ir = {
  types : type_def list;
  imports : import_desc list;
  funcs : func_def list;
  tags : tag_def list;
  globals : global_def list;
  memories : memory_def list;
  tables : table_def list;
  datas : data_def list;
  elems : elem_def list;
  start : int option;
  exports : export_item list;
  invoke_index : int option;
}

type import_func_binding = {
  binding_module : string;
  binding_name : string;
  binding_body : string list;
}

type import_global_binding = {
  global_binding_module : string;
  global_binding_name : string;
  global_binding_value : string;
}

type import_memory_binding = {
  memory_binding_module : string;
  memory_binding_name : string;
  memory_binding_pages : int;
  memory_binding_max : int option;
  memory_binding_overlays : memory_overlay list;
}

and memory_overlay = { overlay_offset : int; overlay_bytes : int list }

type memory_data_binding = {
  memory_data_name : string;
  memory_data_overlays : memory_overlay list;
}

type table_overlay = { table_overlay_offset : int; table_overlay_refs : string list }

type table_data_binding = {
  table_data_name : string;
  table_data_overlays : table_overlay list;
}

type state_func_binding = {
  state_func_type : string;
  state_func_locals : string;
  state_func_body : string;
}

type prelude_call = {
  prelude_field : string option;
  prelude_funcidx : int option;
  prelude_args : string list;
  prelude_drop_count : int;
}

type env = {
  type_names : (string * int) list;
  func_names : (string * int) list;
  tag_names : (string * int) list;
  global_names : (string * int) list;
  memory_names : (string * int) list;
  table_names : (string * int) list;
  local_names : (string * int) list;
  label_names : (string * int) list;
  fresh_type : func_type -> int;
}

exception Error of string

let fail msg = raise (Error msg)

let no_fresh_type _ = fail "internal error: no type sink is available here"

let make_env ?(type_names = []) ?(func_names = []) ?(tag_names = [])
    ?(global_names = []) ?(memory_names = []) ?(table_names = [])
    ?(local_names = []) ?(label_names = []) ?(fresh_type = no_fresh_type) () =
  {
    type_names;
    func_names;
    tag_names;
    global_names;
    memory_names;
    table_names;
    local_names;
    label_names;
    fresh_type;
  }

let enter_label env id =
  let label_names = List.map (fun (name, depth) -> (name, depth + 1)) env.label_names in
  match id with
  | Some name -> { env with label_names = (name, 0) :: label_names }
  | None -> { env with label_names }

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let len = in_channel_length ic in
      really_input_string ic len)

let read_stdin () =
  let buf = Buffer.create 4096 in
  (try
     while true do
       Buffer.add_string buf (input_line stdin);
       Buffer.add_char buf '\n'
     done
   with End_of_file -> ());
  Buffer.contents buf

let write_file path text =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc text)

let run_command_capture cmd =
  let ic = Unix.open_process_in cmd in
  let buf = Buffer.create 4096 in
  (try
     while true do
       Buffer.add_string buf (input_line ic);
       Buffer.add_char buf '\n'
     done
   with End_of_file -> ());
  let out = Buffer.contents buf in
  match Unix.close_process_in ic with
  | Unix.WEXITED 0 -> out
  | _ -> fail ("command failed: " ^ cmd ^ "\n" ^ out)

let command_exists tool =
  Sys.command ("command -v " ^ Filename.quote tool ^ " >/dev/null 2>&1") = 0

let require_command tool purpose =
  if not (command_exists tool) then
    fail
      (tool ^ " is required " ^ purpose
     ^ ". Install WABT, for example: brew install wabt")

let wabt_flags = "--enable-all"

let _run_status cmd =
  match Sys.command cmd with
  | 0 -> ()
  | code -> fail ("command failed (" ^ string_of_int code ^ "): " ^ cmd)

let run_status_capture_stderr cmd =
  let stderr_path = Filename.temp_file "spec2maude-cmd-" ".stderr" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove stderr_path with Sys_error _ -> ())
    (fun () ->
      let code = Sys.command (cmd ^ " 2> " ^ Filename.quote stderr_path) in
      (code, read_file stderr_path))

let first_line text =
  match String.split_on_char '\n' text with
  | line :: _ -> line
  | [] -> ""

let validate_wasm _path =
  (* Kept for older call sites; validation now happens through the official
     Wasm.Valid.check_module path in official_module_ir_of_file. *)
  ()

let has_suffix s suffix =
  let n = String.length s and m = String.length suffix in
  n >= m && String.sub s (n - m) m = suffix

let contains_sub s needle =
  let n = String.length s and m = String.length needle in
  let rec loop i =
    i + m <= n
    && (String.sub s i m = needle || loop (i + 1))
  in
  m = 0 || loop 0

let contains_sub_ci s needle =
  contains_sub (String.lowercase_ascii s) (String.lowercase_ascii needle)

let starts_with s prefix =
  let n = String.length s and m = String.length prefix in
  n >= m && String.sub s 0 m = prefix

let last_sub_index s needle =
  let n = String.length s and m = String.length needle in
  let rec loop i last =
    if i + m > n then last
    else
      let last = if String.sub s i m = needle then Some i else last in
      loop (i + 1) last
  in
  if m = 0 then Some 0 else loop 0 None

let sub_index s needle =
  let n = String.length s and m = String.length needle in
  let rec loop i =
    if i + m > n then None
    else if String.sub s i m = needle then Some i
    else loop (i + 1)
  in
  if m = 0 then Some 0 else loop 0

let strip_between s start_marker stop_marker =
  match (sub_index s start_marker, sub_index s stop_marker) with
  | Some start, Some stop when start < stop ->
      String.sub s 0 start ^ String.sub s stop (String.length s - stop)
  | _ -> s

let compact_spaces s =
  let b = Buffer.create (String.length s) in
  let pending_space = ref false in
  String.iter
    (fun c ->
      match c with
      | ' ' | '\n' | '\r' | '\t' ->
          pending_space := true
      | _ ->
          if !pending_space && Buffer.length b > 0 then Buffer.add_char b ' ';
          pending_space := false;
          Buffer.add_char b c)
    s;
  let s = Buffer.contents b |> String.trim in
  let s =
    String.split_on_char '(' s
    |> String.concat "("
    |> fun x -> String.split_on_char ')' x |> String.concat ")"
  in
  let s = String.concat "(" (List.map String.trim (String.split_on_char '(' s)) in
  String.concat ")" (List.map String.trim (String.split_on_char ')' s))

let compact_surface_specs =
  [
    ("ACTIVEDATAMODE__", [ "ACTIVE-DATAMODE"; ""; "" ]);
    ("ACTIVEELEMMODE__", [ "ACTIVE-ELEMMODE"; ""; "" ]);
    ("ACTIVE__", [ "ACTIVE-DATAMODE"; ""; "" ]);
    ("ANY__", [ "ANY"; ""; "" ]);
    ("ARROW__", [ ""; "arrow"; "" ]);
    ("ARRAYCOPY__", [ "ARRAY-COPY"; ""; "" ]);
    ("ARRAYFILL_", [ "ARRAY-FILL"; "" ]);
    ("ARRAYGET__", [ "ARRAY-GET"; ""; "" ]);
    ("ARRAYINITDATA__", [ "ARRAY-INIT-DATA"; ""; "" ]);
    ("ARRAYINITELEM__", [ "ARRAY-INIT-ELEM"; ""; "" ]);
    ("ARRAYNEWDATA__", [ "ARRAY-NEW-DATA"; ""; "" ]);
    ("ARRAYNEWELEM__", [ "ARRAY-NEW-ELEM"; ""; "" ]);
    ("ARRAYNEWFIXED__", [ "ARRAY-NEW-FIXED"; ""; "" ]);
    ("ARRAYNEWDEFAULT_", [ "ARRAY-NEW-DEFAULT"; "" ]);
    ("ARRAYNEW_", [ "ARRAY-NEW"; "" ]);
    ("ARRAYSET_", [ "ARRAY-SET"; "" ]);
    ("ARRAY_", [ "ARRAY"; "" ]);
    ("BINOP__", [ "BINOP"; ""; "" ]);
    ("BLOCK__", [ "BLOCK"; ""; "" ]);
    ("BRONCASTFAIL___", [ "BR-ON-CAST-FAIL"; ""; ""; "" ]);
    ("BRONCAST___", [ "BR-ON-CAST"; ""; ""; "" ]);
    ("BRONNONNULL_", [ "BR-ON-NON-NULL"; "" ]);
    ("BRONNULL_", [ "BR-ON-NULL"; "" ]);
    ("BRTABLE__", [ "BR-TABLE"; ""; "" ]);
    ("BRIF_", [ "BR-IF"; "" ]);
    ("BR_", [ "BR"; "" ]);
    ("CALLINDIRECT__", [ "CALL-INDIRECT"; ""; "" ]);
    ("CALLREF_", [ "CALL-REF"; "" ]);
    ("CALL_", [ "CALL"; "" ]);
    ("CATCHALLREF_", [ "CATCH-ALL-REF"; "" ]);
    ("CATCHALL_", [ "CATCH-ALL"; "" ]);
    ("CATCHREF__", [ "CATCH-REF"; ""; "" ]);
    ("CATCH__", [ "CATCH"; ""; "" ]);
    ("CONST__", [ "CONST"; ""; "" ]);
    ("CONVERT_", [ "CONVERT"; "" ]);
    ("CVTOP___", [ "CVTOP"; ""; ""; "" ]);
    ("DATA__", [ "DATA"; ""; "" ]);
    ("DATADROP_", [ "DATA-DROP"; "" ]);
    ("DEMOTE_", [ "DEMOTE"; "" ]);
    ("DIVSXBINOP_", [ "DIV-SX-BINOP"; "" ]);
    ("DIVBINOP_", [ "DIV-SX-BINOP"; "" ]);
    ("DIVVBINOP_", [ "DIV-VBINOP"; "" ]);
    ("DIV_", [ "DIV-SX-BINOP"; "" ]);
    ("ELEMDROP_", [ "ELEM-DROP"; "" ]);
    ("ELEM___", [ "ELEM"; ""; ""; "" ]);
    ("EXPORT__", [ "EXPORT"; ""; "" ]);
    ("EXTEND_", [ "EXTEND"; "" ]);
    ("FRAMELBRACERBRACE___", [ "FRAME"; "lbrace"; "rbrace"; "" ]);
    ("FUNCARROW__", [ "FUNCCOMPTYPEARROW"; ""; "" ]);
    ("FUNCEXTERNADDR_", [ "FUNC-EXTERNADDR"; "" ]);
    ("FUNCEXTERNIDX_", [ "FUNC-EXTERNIDX"; "" ]);
    ("FUNCEXTERNTYPE_", [ "FUNC-EXTERNTYPE"; "" ]);
    ("FUNC___", [ "FUNC-FUNC"; ""; ""; "" ]);
    ("FUNC_", [ "FUNC-EXTERNTYPE"; "" ]);
    ("GLOBALGET_", [ "GLOBAL-GET"; "" ]);
    ("GLOBALSET_", [ "GLOBAL-SET"; "" ]);
    ("GLOBALEXTERNADDR_", [ "GLOBAL-EXTERNADDR"; "" ]);
    ("GLOBALEXTERNIDX_", [ "GLOBAL-EXTERNIDX"; "" ]);
    ("GLOBALEXTERNTYPE_", [ "GLOBAL-EXTERNTYPE"; "" ]);
    ("GLOBAL__", [ "GLOBAL-GLOBAL"; ""; "" ]);
    ("GLOBAL_", [ "GLOBAL-EXTERNTYPE"; "" ]);
    ("I31GET_", [ "I31-GET"; "" ]);
    ("IMPORT___", [ "IMPORT"; ""; ""; "" ]);
    ("LABELLBRACERBRACE___", [ "LABEL"; "lbrace"; "rbrace"; "" ]);
    ("LBRACKDOTDOTRBRACK__", [ "lbrack"; "dotdot"; "rbrack" ]);
    ("LOAD____", [ "LOAD"; ""; ""; ""; "" ]);
    ("LOCALGET_", [ "LOCAL-GET"; "" ]);
    ("LOCALSET_", [ "LOCAL-SET"; "" ]);
    ("LOCALTEE_", [ "LOCAL-TEE"; "" ]);
    ("LOCAL_", [ "LOCAL"; "" ]);
    ("LOOP__", [ "LOOP"; ""; "" ]);
    ("GESXVRELOP_", [ "GE-SX-VRELOP"; "" ]);
    ("GTSXVRELOP_", [ "GT-SX-VRELOP"; "" ]);
    ("LESXVRELOP_", [ "LE-SX-VRELOP"; "" ]);
    ("LTSXVRELOP_", [ "LT-SX-VRELOP"; "" ]);
    ("GESXRELOP_", [ "GE-SX-RELOP"; "" ]);
    ("GTSXRELOP_", [ "GT-SX-RELOP"; "" ]);
    ("LESXRELOP_", [ "LE-SX-RELOP"; "" ]);
    ("LTSXRELOP_", [ "LT-SX-RELOP"; "" ]);
    ("GERELOP_", [ "GE-SX-RELOP"; "" ]);
    ("GTRELOP_", [ "GT-SX-RELOP"; "" ]);
    ("LERELOP_", [ "LE-SX-RELOP"; "" ]);
    ("LTRELOP_", [ "LT-SX-RELOP"; "" ]);
    ("LE_", [ "LE-SX-VRELOP"; "" ]);
    ("LT_", [ "LT-SX-VRELOP"; "" ]);
    ("MAXSXVBINOP_", [ "MAX-SX-VBINOP"; "" ]);
    ("MAX_", [ "MAX-SX-VBINOP"; "" ]);
    ("MEMORYCOPY__", [ "MEMORY-COPY"; ""; "" ]);
    ("MEMORYFILL_", [ "MEMORY-FILL"; "" ]);
    ("MEMORYGROW_", [ "MEMORY-GROW"; "" ]);
    ("MEMORYINIT__", [ "MEMORY-INIT"; ""; "" ]);
    ("MEMORYSIZE_", [ "MEMORY-SIZE"; "" ]);
    ("MEMORY_", [ "MEMORY"; "" ]);
    ("MEMEXTERNADDR_", [ "MEM-EXTERNADDR"; "" ]);
    ("MEMEXTERNIDX_", [ "MEM-EXTERNIDX"; "" ]);
    ("MEMEXTERNTYPE_", [ "MEM-EXTERNTYPE"; "" ]);
    ("MEM_", [ "MEM-EXTERNTYPE"; "" ]);
    ("MINSXVBINOP_", [ "MIN-SX-VBINOP"; "" ]);
    ("MIN_", [ "MIN-SX-VBINOP"; "" ]);
    ("MODULE___________", [ "MODULE"; ""; ""; ""; ""; ""; ""; ""; ""; ""; ""; "" ]);
    ("NAN_", [ "NAN"; "" ]);
    ("NEG_", [ "NEG-FN"; "" ]);
    ("NORM__", [ "NORM"; ""; "" ]);
    ("PACK__", [ "PACK"; ""; "" ]);
    ("PAGE__", [ ""; ""; "PAGE" ]);
    ("POS_", [ "POS"; "" ]);
    ("RECHEAPTYPE_", [ "REC-HEAPTYPE"; "" ]);
    ("RECRECTYPE_", [ "REC-RECTYPE"; "" ]);
    ("RECTYPEUSE_", [ "REC-TYPEUSE"; "" ]);
    ("RECTYPEVAR_", [ "REC-TYPEVAR"; "" ]);
    ("REC_", [ "REC-RECTYPE"; "" ]);
    ("REFARRAYADDR_", [ "REF-ARRAY-ADDR"; "" ]);
    ("REFCAST_", [ "REF-CAST"; "" ]);
    ("REFEXNADDR_", [ "REF-EXN-ADDR"; "" ]);
    ("REFEXTERN_", [ "REF-EXTERN"; "" ]);
    ("REFFUNCADDR_", [ "REF-FUNC-ADDR"; "" ]);
    ("REFFUNC_", [ "REF-FUNC"; "" ]);
    ("REFHOSTADDR_", [ "REF-HOST-ADDR"; "" ]);
    ("REFI31NUM_", [ "REF-I31-NUM"; "" ]);
    ("REFNULL_", [ "REF-NULL"; "" ]);
    ("REFSTRUCTADDR_", [ "REF-STRUCT-ADDR"; "" ]);
    ("REFTEST_", [ "REF-TEST"; "" ]);
    ("REF__", [ "REF"; ""; "" ]);
    ("RELOP__", [ "RELOP"; ""; "" ]);
    ("RETURNCALLINDIRECT__", [ "RETURN-CALL-INDIRECT"; ""; "" ]);
    ("RETURNCALLREF_", [ "RETURN-CALL-REF"; "" ]);
    ("RETURNCALL_", [ "RETURN-CALL"; "" ]);
    ("GE_", [ "GE-SX-VRELOP"; "" ]);
    ("GT_", [ "GT-SX-VRELOP"; "" ]);
    ("SELECT_", [ "SELECT"; "" ]);
    ("SHR_", [ "SHR"; "" ]);
    ("START_", [ "START"; "" ]);
    ("STORE____", [ "STORE"; ""; ""; ""; "" ]);
    ("STRUCTGET___", [ "STRUCT-GET"; ""; ""; "" ]);
    ("STRUCTNEWDEFAULT_", [ "STRUCT-NEW-DEFAULT"; "" ]);
    ("STRUCTNEW_", [ "STRUCT-NEW"; "" ]);
    ("STRUCTSET__", [ "STRUCT-SET"; ""; "" ]);
    ("STRUCT_", [ "STRUCT-COMPTYPE"; "" ]);
    ("SUB___", [ "SUB-SUBTYPE"; ""; ""; "" ]);
    ("SUBNORM_", [ "SUBNORM"; "" ]);
    ("TABLECOPY__", [ "TABLE-COPY"; ""; "" ]);
    ("TABLEFILL_", [ "TABLE-FILL"; "" ]);
    ("TABLEGET_", [ "TABLE-GET"; "" ]);
    ("TABLEGROW_", [ "TABLE-GROW"; "" ]);
    ("TABLEINIT__", [ "TABLE-INIT"; ""; "" ]);
    ("TABLESET_", [ "TABLE-SET"; "" ]);
    ("TABLESIZE_", [ "TABLE-SIZE"; "" ]);
    ("TABLEEXTERNADDR_", [ "TABLE-EXTERNADDR"; "" ]);
    ("TABLEEXTERNIDX_", [ "TABLE-EXTERNIDX"; "" ]);
    ("TABLEEXTERNTYPE_", [ "TABLE-EXTERNTYPE"; "" ]);
    ("TABLE__", [ "TABLE-TABLE"; ""; "" ]);
    ("TABLE_", [ "TABLE-EXTERNTYPE"; "" ]);
    ("TAGEXTERNADDR_", [ "TAG-EXTERNADDR"; "" ]);
    ("TAGEXTERNIDX_", [ "TAG-EXTERNIDX"; "" ]);
    ("TAGEXTERNTYPE_", [ "TAG-EXTERNTYPE"; "" ]);
    ("TAGTAG_", [ "TAG-TAG"; "" ]);
    ("TAG_", [ "TAG-EXTERNTYPE"; "" ]);
    ("TESTOP__", [ "TESTOP"; ""; "" ]);
    ("THROW_", [ "THROW"; "" ]);
    ("TRUNCSAT_", [ "TRUNC-SAT"; "" ]);
    ("TRUNC_", [ "TRUNC"; "" ]);
    ("TRYTABLE___", [ "TRY-TABLE"; ""; ""; "" ]);
    ("TYPE_", [ "TYPE"; "" ]);
    ("UNOP__", [ "UNOP"; ""; "" ]);
    ("VBINOP__", [ "VBINOP"; ""; "" ]);
    ("VCONST__", [ "VCONST"; ""; "" ]);
    ("VCVTOP___", [ "VCVTOP"; ""; ""; "" ]);
    ("VRELOP__", [ "VRELOP"; ""; "" ]);
    ("WDEF__", [ "w--DEF"; ""; "" ]);
    ("WIDX_", [ "w--IDX"; "" ]);
    ("WIFELSE___", [ "IF"; ""; "ELSE"; "" ]);
    ("WREM_", [ "REM"; "" ]);
    ("WRESULT_", [ "w--RESULT"; "" ]);
    ("X__", [ ""; "X"; "" ]);
  ]
  |> List.sort (fun (a, _) (b, _) -> compare (String.length b) (String.length a))

let compact_surface_is_ident_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' | '$' -> true
  | _ -> false

let maude_keywords =
  [ "if"; "var"; "op"; "eq"; "sort"; "mod"; "quo"; "rem"; "or"; "and"; "not" ]

let maude_source_op_token name =
  let lowered = String.lowercase_ascii (String.trim name) in
  if lowered = "" then lowered
  else if List.mem lowered maude_keywords then "w-" ^ lowered
  else lowered

let compact_surface_token_aliases =
  [
    ("ABS", "abs");
    ("ADD", "add");
    ("ANY", "any");
    ("ANYCONVERTEXTERN", "any-convert-extern");
    ("ARRAY", "array-absheaptype");
    ("CEIL", "ceil");
    ("CLZ", "clz");
    ("COPYSIGN", "copysign");
    ("CTZ", "ctz");
    ("DECLARE", "declare");
    ("DEMOTE", "demote");
    ("DIV", "div-binop");
    ("DIVBINOP", "div-binop");
    ("DIVSXBINOP", "div-sx-binop");
    ("DIVVBINOP", "div-vbinop");
    ("divbinop", "div-binop");
    ("divsxbinop", "div-sx-binop");
    ("divvbinop", "div-vbinop");
    ("EQZ", "eqz");
    ("EXN", "exn");
    ("EXTERN", "extern");
    ("EXTERNCONVERTANY", "extern-convert-any");
    ("F32", "f32");
    ("F64", "f64");
    ("FINAL", "final");
    ("FLOOR", "floor");
    ("FUNC", "func-absheaptype");
    ("GE", "ge-relop");
    ("GERELOP", "ge-relop");
    ("GESXRELOP", "ge-sx-relop");
    ("GESXVRELOP", "ge-sx-vrelop");
    ("GEVRELOP", "ge-vrelop");
    ("gerelop", "ge-relop");
    ("gesxrelop", "ge-sx-relop");
    ("gesxvrelop", "ge-sx-vrelop");
    ("gevrelop", "ge-vrelop");
    ("GT", "gt-relop");
    ("GTRELOP", "gt-relop");
    ("GTSXRELOP", "gt-sx-relop");
    ("GTSXVRELOP", "gt-sx-vrelop");
    ("GTVRELOP", "gt-vrelop");
    ("gtrelop", "gt-relop");
    ("gtsxrelop", "gt-sx-relop");
    ("gtsxvrelop", "gt-sx-vrelop");
    ("gtvrelop", "gt-vrelop");
    ("I31", "i31");
    ("I32", "i32");
    ("I64", "i64");
    ("LE", "le-relop");
    ("LERELOP", "le-relop");
    ("LESXRELOP", "le-sx-relop");
    ("LESXVRELOP", "le-sx-vrelop");
    ("LEVRELOP", "le-vrelop");
    ("lerelop", "le-relop");
    ("lesxrelop", "le-sx-relop");
    ("lesxvrelop", "le-sx-vrelop");
    ("levrelop", "le-vrelop");
    ("LT", "lt-relop");
    ("LTRELOP", "lt-relop");
    ("LTSXRELOP", "lt-sx-relop");
    ("LTSXVRELOP", "lt-sx-vrelop");
    ("LTVRELOP", "lt-vrelop");
    ("ltrelop", "lt-relop");
    ("ltsxrelop", "lt-sx-relop");
    ("ltsxvrelop", "lt-sx-vrelop");
    ("ltvrelop", "lt-vrelop");
    ("MAX", "max-binop");
    ("MAXBINOP", "max-binop");
    ("MAXSXVBINOP", "max-sx-vbinop");
    ("MAXVBINOP", "max-vbinop");
    ("maxbinop", "max-binop");
    ("maxsxvbinop", "max-sx-vbinop");
    ("maxvbinop", "max-vbinop");
    ("MIN", "min-binop");
    ("MINBINOP", "min-binop");
    ("MINSXVBINOP", "min-sx-vbinop");
    ("MINVBINOP", "min-vbinop");
    ("minbinop", "min-binop");
    ("minsxvbinop", "min-sx-vbinop");
    ("minvbinop", "min-vbinop");
    ("MUL", "mul");
    ("MUT", "mut");
    ("NE", "ne");
    ("NEAREST", "nearest");
    ("NEG", "neg-unop");
    ("NEGFN", "neg-fn");
    ("NEGUNOP", "neg-unop");
    ("NEGVUNOP", "neg-vunop");
    ("negfn", "neg-fn");
    ("negunop", "neg-unop");
    ("negvunop", "neg-vunop");
    ("NULL", "null");
    ("PASSIVE", "passive");
    ("POPCNT", "popcnt");
    ("PROMOTE", "promote");
    ("REFASNONNULL", "ref-as-non-null");
    ("REFEQ", "ref-eq");
    ("REFI31", "ref-i31");
    ("REFISNULL", "ref-is-null");
    ("REINTERPRET", "reinterpret");
    ("S", "s");
    ("SQRT", "sqrt");
    ("STRUCT", "struct-absheaptype");
    ("SUB", "sub-binop");
    ("SUBBINOP", "sub-binop");
    ("SUBVBINOP", "sub-vbinop");
    ("subbinop", "sub-binop");
    ("subvbinop", "sub-vbinop");
    ("THROWREF", "throw-ref");
    ("TRUNC", "trunc-unop");
    ("TRUNCUNOP", "trunc-unop");
    ("TRUNCVUNOP", "trunc-vunop");
    ("truncunop", "trunc-unop");
    ("truncvunop", "trunc-vunop");
    ("U", "u");
    ("V128", "v128");
    ("WAND", "w-and");
    ("WEQ", "w-eq");
    ("WOR", "w-or");
    ("WREM", "w-rem");
    ("WRAP", "wrap");
    ("XOR", "xor");
  ]

let compact_surface_token_aliases_by_length =
  compact_surface_token_aliases
  |> List.sort (fun (a, _) (b, _) -> compare (String.length b) (String.length a))

let compact_surface_token_alias atom =
  compact_surface_token_aliases_by_length
  |> List.find_map (fun (old, repl) ->
       if atom = old then Some repl else None)

let replace_compact_surface_token_aliases text =
  let len = String.length text in
  let alias_at i =
    compact_surface_token_aliases_by_length
    |> List.find_map (fun (old, repl) ->
         let n = String.length old in
         if i + n <= len
            && String.sub text i n = old
            && (i = 0 || not (compact_surface_is_ident_char text.[i - 1]))
            && (i + n = len
                || not (compact_surface_is_ident_char text.[i + n]))
         then Some (old, repl)
         else None)
  in
  let b = Buffer.create len in
  let rec loop i =
    if i >= len then ()
    else
      match alias_at i with
      | Some (old, repl) ->
          Buffer.add_string b repl;
          loop (i + String.length old)
      | None ->
          Buffer.add_char b text.[i];
          loop (i + 1)
  in
  loop 0;
  Buffer.contents b

let compact_surface_needs_parens arg =
  let arg = String.trim arg in
  arg <> ""
  && (String.exists
        (function ' ' | '\n' | '\r' | '\t' -> true | _ -> false)
        arg)
  && not
       (String.length arg >= 2 && arg.[0] = '('
        && arg.[String.length arg - 1] = ')')

let compact_prefix_component s =
  let b = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      if (c >= 'a' && c <= 'z')
         || (c >= 'A' && c <= 'Z')
         || (c >= '0' && c <= '9')
      then Buffer.add_char b c)
    s;
  String.uppercase_ascii (Buffer.contents b)

let compact_prefix_name old sections =
  let meaningful =
    sections
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
  in
  match meaningful with
  | [single] -> maude_source_op_token single
  | _ ->
      let components =
        meaningful
        |> List.map compact_prefix_component
        |> List.filter (fun s -> s <> "")
      in
      if components <> [] then maude_source_op_token (String.concat "" components)
      else
        let rec trim = function
          | s when s <> "" && s.[String.length s - 1] = '_' ->
              trim (String.sub s 0 (String.length s - 1))
          | s -> s
        in
        maude_source_op_token (trim old)

let render_compact_surface sections args =
  let _ = compact_surface_needs_parens in
  let op_name = compact_prefix_name "" sections in
  if args = [] then op_name
  else op_name ^ "(" ^ String.concat ", " (List.map String.trim args) ^ ")"

let source_surface_atom_of_compact_atom atom =
  let atom = String.trim atom in
  match compact_surface_token_alias atom with
  | Some alias -> alias
  | None -> (
  match atom with
  | "WAND" -> "w-and"
  | "WEQ" -> "w-eq"
  | "WOR" -> "w-or"
  | "WREM" -> "w-rem"
  | _ ->
  let is_source_like =
    let n = String.length atom in
    n > 0
    &&
    ((atom.[0] >= 'A' && atom.[0] <= 'Z')
     || (n > 3 && String.sub atom 0 3 = "w--"
         && atom.[3] >= 'A' && atom.[3] <= 'Z'))
    && String.for_all
         (fun c ->
            (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9')
            || (n > 3 && String.sub atom 0 3 = "w--" && c = '-'))
         (if n > 3 && String.sub atom 0 3 = "w--"
          then String.sub atom 3 (n - 3)
          else atom)
  in
  if is_source_like then maude_source_op_token atom else atom)

let source_surface_plain_atom_sequence text =
  let text = String.trim text in
  if text = "" then text
  else
    text
    |> String.split_on_char ' '
    |> List.map String.trim
    |> List.filter (fun tok -> tok <> "")
    |> List.map source_surface_atom_of_compact_atom
    |> String.concat " "

let source_surface_syntax_of_compact text =
  let len = String.length text in
  let find_matching_paren open_i =
    let rec loop i depth =
      if i >= len then None
      else
        match text.[i] with
        | '(' -> loop (i + 1) (depth + 1)
        | ')' ->
            let depth' = depth - 1 in
            if depth' = 0 then Some i else loop (i + 1) depth'
        | _ -> loop (i + 1) depth
    in
    loop open_i 0
  in
  let rec convert s =
    let len_s = String.length s in
    let find_matching_in_s open_i =
      let rec loop i depth =
        if i >= len_s then None
        else
          match s.[i] with
          | '(' -> loop (i + 1) (depth + 1)
          | ')' ->
              let depth' = depth - 1 in
              if depth' = 0 then Some i else loop (i + 1) depth'
          | _ -> loop (i + 1) depth
      in
      loop open_i 0
    in
    let split_commas inner =
      let len_i = String.length inner in
      let rec loop i depth start acc =
        if i >= len_i then
          List.rev ((String.sub inner start (len_i - start) |> String.trim) :: acc)
        else
          match inner.[i] with
          | '(' -> loop (i + 1) (depth + 1) start acc
          | ')' -> loop (i + 1) (max 0 (depth - 1)) start acc
          | ',' when depth = 0 ->
              let part = String.sub inner start (i - start) |> String.trim in
              loop (i + 1) depth (i + 1) (part :: acc)
          | _ -> loop (i + 1) depth start acc
      in
      if String.trim inner = "" then [] else loop 0 0 0 []
    in
    let starts_at i old =
      let n = String.length old in
      i + n < len_s
      && String.sub s i n = old
      && (i = 0 || not (compact_surface_is_ident_char s.[i - 1]))
      &&
      let rec skip_ws j =
        if j < len_s then
          match s.[j] with
          | ' ' | '\n' | '\r' | '\t' -> skip_ws (j + 1)
          | _ -> j
        else j
      in
      let j = skip_ws (i + n) in
      j < len_s && s.[j] = '('
    in
    let spec_at i =
      compact_surface_specs
      |> List.find_map (fun (old, sections) ->
           if starts_at i old then Some (old, sections) else None)
    in
    let b = Buffer.create len_s in
    let rec loop i =
      if i >= len_s then ()
      else
        match spec_at i with
        | Some (old, sections) ->
            let after_old = i + String.length old in
            let rec skip_ws j =
              if j < len_s then
                match s.[j] with
                | ' ' | '\n' | '\r' | '\t' -> skip_ws (j + 1)
                | _ -> j
              else j
            in
            let open_i = skip_ws after_old in
            (match find_matching_in_s open_i with
            | Some close_i ->
                let inner =
                  String.sub s (open_i + 1) (close_i - open_i - 1)
                in
	                let args = split_commas inner |> List.map convert in
	                let rendered = render_compact_surface sections args in
	                Buffer.add_string b
	                  ("( " ^ rendered ^ " ).SpectecTerminal");
	                loop (close_i + 1)
            | None ->
                Buffer.add_char b s.[i];
                loop (i + 1))
        | None ->
            Buffer.add_char b s.[i];
            loop (i + 1)
    in
    loop 0;
    let rendered = Buffer.contents b in
    let simple_atom =
      let t = String.trim s in
      t <> ""
      && not
           (String.exists
              (function
                | ' ' | '\n' | '\r' | '\t' | '(' | ')' | ',' -> true
                | _ -> false)
              t)
    in
    let plain_atom_sequence =
      let t = String.trim s in
      t <> ""
      && not
           (String.exists
              (function
                | '(' | ')' | ',' -> true
                | _ -> false)
              t)
      && String.exists
           (function ' ' | '\n' | '\r' | '\t' -> true | _ -> false)
           t
    in
    if simple_atom then source_surface_atom_of_compact_atom rendered
    else if plain_atom_sequence then source_surface_plain_atom_sequence rendered
    else rendered
  in
  ignore find_matching_paren;
  convert text |> replace_compact_surface_token_aliases

let balanced_term_from text start =
  let len = String.length text in
  let rec scan i depth seen_open =
    if i >= len then String.sub text start (len - start)
    else
      match text.[i] with
      | '(' -> scan (i + 1) (depth + 1) true
      | ')' ->
          let depth' = max 0 (depth - 1) in
          if seen_open && depth' = 0 then String.sub text start (i - start + 1)
          else scan (i + 1) depth' seen_open
      | '\n' when not seen_open -> String.sub text start (i - start)
      | _ -> scan (i + 1) depth seen_open
  in
  scan start 0 false

let maude_line_is_fatal line =
  contains_sub_ci line "unpatchable errors"
  || (contains_sub_ci line "module " && contains_sub_ci line " is unusable")
  || contains_sub_ci line "does not exist"
  || contains_sub_ci line "no parse for"
  || contains_sub_ci line "parse error"

let maude_output_is_fatal output =
  contains_sub_ci output "unpatchable errors"
  || (contains_sub_ci output "module " && contains_sub_ci output " is unusable")
  || contains_sub_ci output "does not exist"
  || contains_sub_ci output "no parse for"
  || contains_sub_ci output "parse error"

let first_n n xs =
  let rec loop n acc = function
    | [] -> List.rev acc
    | _ when n <= 0 -> List.rev acc
    | x :: rest -> loop (n - 1) (x :: acc) rest
  in
  loop n [] xs

let check_maude_output output =
  if maude_output_is_fatal output then
    let lines =
      String.split_on_char '\n' output
      |> List.filter maude_line_is_fatal
      |> first_n 12
    in
    let excerpt =
      match lines with
      | [] -> first_line output
      | _ -> String.concat "\n" lines
    in
    fail ("Maude reported fatal diagnostics:\n" ^ excerpt)

let extract_final_value output =
  let result_config_tail text =
    match last_sub_index text "result Config:" with
    | None -> None
    | Some start ->
        let body_start = start + String.length "result Config:" in
        let body =
          String.sub text body_start (String.length text - body_start)
        in
        let body =
          match last_sub_index body "\nBye." with
          | Some stop -> String.sub body 0 stop
          | None -> body
        in
        let depth = ref 0 in
        let last_top_semicolon = ref None in
        String.iteri
          (fun i c ->
            match c with
            | '(' -> incr depth
            | ')' -> if !depth > 0 then decr depth
            | ';' when !depth = 0 -> last_top_semicolon := Some i
            | _ -> ())
          body;
        (match !last_top_semicolon with
        | Some i ->
            Some
              (String.sub body (i + 1) (String.length body - i - 1)
              |> compact_spaces)
        | None -> Some (compact_spaces body))
  in
	  match result_config_tail output with
	  | Some value when value <> "" -> value
	  | _ ->
          let compact_output = compact_spaces output in
          if contains_sub compact_output "result StepsConf: steps("
             || contains_sub compact_output "StepsConf]: steps("
             || contains_sub compact_output "]: steps("
          then
            fail
              "Maude returned a stuck execution term instead of a final Config; \
               increase the rewrite limit or inspect the full Maude output."
          else
		      let value =
		        match last_sub_index output "result ValidJudgement: valid" with
		        | Some _ -> "valid"
	        | None -> (
	        match last_sub_index output "result Judgement: valid" with
	        | Some _ -> "valid"
	        | None -> (
	        match last_sub_index output "result Judgement: Module-ok(" with
	        | Some _ -> "NOT-VALID"
	        | None -> (
	        match last_sub_index output "result StepsConf:" with
	        | Some start ->
	            let body_start = start + String.length "result StepsConf:" in
	            let body = String.sub output body_start (String.length output - body_start) in
            let body =
              match last_sub_index body "\nBye." with
              | Some stop -> String.sub body 0 stop
              | None -> body
            in
            compact_spaces body
        | None -> (
        match last_sub_index output "CONST__(" with
        | Some start -> balanced_term_from output start
        | None -> (
            let ref_prefixes =
              [ "REFNULL_"; "REFFUNCADDR_"; "REFEXTERN_";
                "REFHOSTADDR_"; "REFI31NUM_"; "REFSTRUCTADDR_";
                "REFARRAYADDR_"; "REFEXNADDR_"; "REFFUNC_" ]
            in
            let ref_start =
              ref_prefixes
              |> List.filter_map (fun prefix ->
                   Option.map (fun idx -> (idx, prefix))
                     (last_sub_index output prefix))
              |> List.sort (fun (a, _) (b, _) -> compare b a)
              |> function
                 | (idx, _) :: _ -> Some idx
                 | [] -> None
            in
            match ref_start with
            | Some start -> balanced_term_from output start
            | None -> String.trim output)))))
	      in
      compact_spaces value

let is_id s = String.length s > 0 && s.[0] = '$'

let strip_comments text =
  let b = Buffer.create (String.length text) in
  let n = String.length text in
  let rec skip_block i depth =
    if i >= n then fail "unterminated WAT block comment"
    else if i + 1 < n && text.[i] = '(' && text.[i + 1] = ';' then
      skip_block (i + 2) (depth + 1)
    else if i + 1 < n && text.[i] = ';' && text.[i + 1] = ')' then
      if depth = 1 then i + 2 else skip_block (i + 2) (depth - 1)
    else skip_block (i + 1) depth
  in
  let rec copy_string i =
    if i >= n then fail "unterminated string token"
    else (
      Buffer.add_char b text.[i];
      if text.[i] = '\\' && i + 1 < n then (
        Buffer.add_char b text.[i + 1];
        copy_string (i + 2))
      else if text.[i] = '"' then i + 1
      else copy_string (i + 1))
  in
  let rec loop i =
    if i >= n then ()
    else if text.[i] = '"' then (
      Buffer.add_char b text.[i];
      loop (copy_string (i + 1)))
    else if i + 1 < n && text.[i] = ';' && text.[i + 1] = ';' then (
      let j = ref (i + 2) in
      while !j < n && text.[!j] <> '\n' do
        incr j
      done;
      if !j < n then Buffer.add_char b '\n';
      loop !j)
    else if i + 1 < n && text.[i] = '(' && text.[i + 1] = ';' then (
      Buffer.add_char b ' ';
      loop (skip_block (i + 2) 1))
    else (
      Buffer.add_char b text.[i];
      loop (i + 1))
  in
  loop 0;
  Buffer.contents b

let tokenize text =
  let text = strip_comments text in
  let toks = ref [] in
  let add s = if s <> "" then toks := s :: !toks in
  let rec loop i =
    if i >= String.length text then ()
    else
      match text.[i] with
      | ' ' | '\t' | '\r' | '\n' -> loop (i + 1)
      | '(' | ')' as c ->
          add (String.make 1 c);
          loop (i + 1)
      | '"' ->
          let j = ref (i + 1) in
          let escaped = ref false in
          while
            !j < String.length text
            && (!escaped || text.[!j] <> '"')
          do
            escaped := (not !escaped && text.[!j] = '\\');
            if text.[!j] <> '\\' then escaped := false;
            incr j
          done;
          if !j >= String.length text then fail "unterminated string token";
          add (String.sub text i (!j - i + 1));
          loop (!j + 1)
      | _ ->
          let j = ref i in
          while
            !j < String.length text
            && not (List.mem text.[!j] [ ' '; '\t'; '\r'; '\n'; '('; ')' ])
          do
            incr j
          done;
          add (String.sub text i (!j - i));
          loop !j
  in
  loop 0;
  List.rev !toks

let parse tokens =
  let rec parse_one = function
    | [] -> fail "unexpected end of WAT"
    | "(" :: rest ->
        let rec items acc = function
          | [] -> fail "missing ')' in WAT"
          | ")" :: rest -> (List (List.rev acc), rest)
          | toks ->
              let x, rest = parse_one toks in
              items (x :: acc) rest
        in
        items [] rest
    | ")" :: _ -> fail "unexpected ')' in WAT"
    | tok :: rest -> (Atom tok, rest)
  in
  let parsed, rest = parse_one tokens in
  match rest with [] -> parsed | _ -> fail "extra tokens after first WAT form"

let parse_many tokens =
  let rec loop acc = function
    | [] -> List.rev acc
    | toks ->
        let x, rest =
          let rec parse_one = function
            | [] -> fail "unexpected end of WAT"
            | "(" :: rest ->
                let rec items acc = function
                  | [] -> fail "missing ')' in WAT"
                  | ")" :: rest -> (List (List.rev acc), rest)
                  | toks ->
                      let x, rest = parse_one toks in
                      items (x :: acc) rest
                in
                items [] rest
            | ")" :: _ -> fail "unexpected ')' in WAT"
            | tok :: rest -> (Atom tok, rest)
          in
          parse_one toks
        in
        loop (x :: acc) rest
  in
  loop [] tokens

let atom = function Atom s -> s | List _ -> fail "expected atom, got list"

let seq xs =
  let xs = List.filter (fun x -> x <> "" && x <> "eps") xs in
  match xs with [] -> "eps" | _ -> String.concat " " xs

let typed_seq seq_sort xs =
  ignore seq_sort;
  let xs = List.filter (fun x -> x <> "" && x <> "eps") xs in
  match xs with
  | [] -> "eps"
  | _ -> String.concat " " xs

let valtype_seq xs = typed_seq "ValtypeSeq" xs
let instr_seq xs = typed_seq "InstrSeq" xs
let typeuse_seq xs = typed_seq "TypeuseSeq" xs
let subtype_seq xs = typed_seq "SubtypeSeq" xs
let fieldtype_seq xs = typed_seq "FieldtypeSeq" xs
let local_seq xs = typed_seq "LocalSeq" xs
let labelidx_seq xs = typed_seq "LabelidxSeq" xs
let catch_seq xs = typed_seq "CatchSeq" xs
let byte_seq xs = typed_seq "ByteSeq" xs
let type_seq xs = typed_seq "TypeSeq" xs
let import_seq xs = typed_seq "ImportSeq" xs
let tag_seq xs = typed_seq "TagSeq" xs
let global_seq xs = typed_seq "GlobalSeq" xs
let mem_seq xs = typed_seq "MemSeq" xs
let table_seq xs = typed_seq "TableSeq" xs
let func_seq xs = typed_seq "FuncSeq" xs
let data_seq xs = typed_seq "DataSeq" xs
let elem_seq xs = typed_seq "ElemSeq" xs
let export_seq xs = typed_seq "ExportSeq" xs

let collect_ref_func_indices terms =
  let prefix = "REFFUNC_(" in
  let plen = String.length prefix in
  let wrap_prefix = "$wrap-Funcidx(" in
  let wplen = String.length wrap_prefix in
  let scan_digits s start =
    let j = ref start in
    while
      !j < String.length s
      && s.[!j] >= '0'
      && s.[!j] <= '9'
    do
      incr j
    done;
    if !j > start then Some (!j, int_of_string (String.sub s start (!j - start)))
    else None
  in
  let rec scan_term acc s pos =
    if pos + plen > String.length s then acc
    else if String.sub s pos plen = prefix then
      let arg_start = pos + plen in
      let parsed =
        match scan_digits s arg_start with
        | Some (j, n) when j < String.length s && s.[j] = ')' -> Some (j, n)
        | _ when arg_start + wplen <= String.length s
                 && String.sub s arg_start wplen = wrap_prefix ->
            let digit_start = arg_start + wplen in
            (match scan_digits s digit_start with
             | Some (j, n)
                 when j + 1 < String.length s && s.[j] = ')' && s.[j + 1] = ')' ->
                 Some (j + 1, n)
             | _ -> None)
        | _ -> None
      in
      let acc, next =
        match parsed with
        | Some (j, n) -> (n :: acc, j)
        | None -> (acc, pos + 1)
      in
      scan_term acc s (max (pos + 1) next)
    else
      scan_term acc s (pos + 1)
  in
  terms
  |> List.fold_left (fun acc s -> scan_term acc s 0) []
  |> List.sort_uniq compare
  |> List.map string_of_int
  |> seq

let wrap_source_category sort payload =
  let _ = sort in
  String.trim payload

let sz_term n =
  wrap_source_category "Sz" (string_of_int n)

let rec valtype = function
  | "i32" -> "I32"
  | "i64" -> "I64"
  | "f32" -> "F32"
  | "f64" -> "F64"
  | "v128" -> "V128"
  | "funcref" | "externref" | "anyref" | "eqref" | "i31ref" | "structref"
  | "arrayref" | "exnref" as t ->
      reftype t
  | t -> fail ("unsupported value type: " ^ t)

and heaptype = function
  | t
    when
      let n = String.length t in
      n > 0
      &&
      let rec loop i =
        i = n || (t.[i] >= '0' && t.[i] <= '9' && loop (i + 1))
      in
      loop 0 ->
      "WIDX_(" ^ wrap_source_category "Typeidx" t ^ ")"
  | "func" | "funcref" -> "FUNC"
  | "extern" | "externref" -> "EXTERN"
  | "any" | "anyref" -> "ANY"
  | "eq" | "eqref" -> "WEQ"
  | "i31" | "i31ref" -> "I31"
  | "struct" | "structref" -> "STRUCT"
  | "array" | "arrayref" -> "ARRAY"
  | "exn" | "exnref" -> "EXN"
  | t -> fail ("unsupported heap/ref type: " ^ t)

and reftype = function
  | "funcref" -> "REF__(NULL, FUNC)"
  | "externref" -> "REF__(NULL, EXTERN)"
  | "exnref" -> "REF__(NULL, EXN)"
  | t when String.length t >= 4 && String.sub t (String.length t - 3) 3 = "ref"
    -> "REF__(NULL, " ^ heaptype t ^ ")"
  | t -> fail ("unsupported reference type: " ^ t)

let rec heaptype_of_sexpr = function
  | Atom t -> heaptype t
  | List [ Atom "type"; x ] ->
      "WIDX_(" ^ wrap_source_category "Typeidx" (atom x) ^ ")"
  | x -> fail ("unsupported heap type expression: " ^ atom_or_shape x)

and reftype_of_sexpr = function
  | Atom t -> reftype t
  | List [ Atom "ref"; Atom "null"; ht ] ->
      "REF__(NULL, " ^ heaptype_of_sexpr ht ^ ")"
  | List [ Atom "ref"; ht ] -> "REF__(eps, " ^ heaptype_of_sexpr ht ^ ")"
  | x -> fail ("unsupported reference type expression: " ^ atom_or_shape x)

and valtype_of_sexpr = function
  | Atom t -> valtype t
  | List (Atom "ref" :: _) as x -> reftype_of_sexpr x
  | x -> fail ("unsupported value type expression: " ^ atom_or_shape x)

and atom_or_shape = function
  | Atom s -> s
  | List (Atom h :: _) -> "(" ^ h ^ " ...)"
  | List (List _ :: _) -> "((...) ...)"
  | List [] -> "()"

let limits_term min max_opt =
  "LBRACKDOTDOTRBRACK__(" ^ wrap_source_category "U64" (string_of_int min) ^ ", "
  ^ (match max_opt with
     | Some max -> wrap_source_category "U64" (string_of_int max)
     | None -> "eps")
  ^ ")"

let memtype_term ?(addrtype = "I32") min max_opt =
  "PAGE__(" ^ addrtype ^ ", " ^ limits_term min max_opt ^ ")"

let tabletype_term ?(addrtype = "I32") min max_opt rt =
  addrtype ^ " " ^ limits_term min max_opt ^ " " ^ rt

let globaltype_term mut t =
  if mut then "MUT " ^ t else t

let bytes_seq bytes = byte_seq (List.map string_of_int bytes)

let unquote s =
  let n = String.length s in
  if n >= 2 && s.[0] = '"' && s.[n - 1] = '"' then String.sub s 1 (n - 2)
  else s

let wat_string_bytes s =
  let raw = unquote s in
  let bytes = ref [] in
  let add c = bytes := !bytes @ [ Char.code c ] in
  let hex c =
    if c >= '0' && c <= '9' then Char.code c - Char.code '0'
    else if c >= 'a' && c <= 'f' then 10 + Char.code c - Char.code 'a'
    else if c >= 'A' && c <= 'F' then 10 + Char.code c - Char.code 'A'
    else fail "bad hex escape in WAT string"
  in
  let rec loop i =
    if i >= String.length raw then ()
    else if raw.[i] = '\\' && i + 2 < String.length raw then (
      match raw.[i + 1] with
      | 'n' ->
          add '\n';
          loop (i + 2)
      | 't' ->
          add '\t';
          loop (i + 2)
      | 'r' ->
          add '\r';
          loop (i + 2)
      | '"' ->
          add '"';
          loop (i + 2)
      | '\\' ->
          add '\\';
          loop (i + 2)
      | c when
          ((c >= '0' && c <= '9')
          || (c >= 'a' && c <= 'f')
          || (c >= 'A' && c <= 'F'))
          && i + 2 < String.length raw ->
          bytes := !bytes @ [ (hex raw.[i + 1] * 16) + hex raw.[i + 2] ];
          loop (i + 3)
      | _ ->
          add raw.[i + 1];
          loop (i + 2))
    else (
      add raw.[i];
      loop (i + 1))
  in
  loop 0;
  !bytes

let int_arg x =
  let s = atom x in
  let n = String.length s in
  let start = if n > 0 && s.[0] = '-' then 1 else 0 in
  let rec loop i =
    i = n
    || (Char.code s.[i] >= Char.code '0'
       && Char.code s.[i] <= Char.code '9'
       && loop (i + 1))
  in
  if n > 0 && start < n && loop start then s
  else fail ("expected integer immediate, got " ^ s)

let int_atom s =
  try int_of_string (int_arg (Atom s))
  with Failure _ -> fail ("unsupported integer literal outside OCaml int range: " ^ s)

let is_int_literal s =
  let n = String.length s in
  let start = if n > 0 && s.[0] = '-' then 1 else 0 in
  let rec loop i =
    i = n
    || (s.[i] >= '0' && s.[i] <= '9' && loop (i + 1))
  in
  n > 0 && start < n && loop start

let decimal_double s =
  let carry = ref 0 in
  let b = Buffer.create (String.length s + 1) in
  for i = String.length s - 1 downto 0 do
    let n = ((Char.code s.[i] - Char.code '0') * 2) + !carry in
    Buffer.add_char b (Char.chr (Char.code '0' + (n mod 10)));
    carry := n / 10
  done;
  if !carry > 0 then Buffer.add_char b (Char.chr (Char.code '0' + !carry));
  let rev = Buffer.contents b in
  String.init (String.length rev) (fun i -> rev.[String.length rev - 1 - i])

let decimal_pow2 bits =
  let rec loop i acc =
    if i <= 0 then acc else loop (i - 1) (decimal_double acc)
  in
  loop bits "1"

let decimal_sub a b =
  let ai = ref (String.length a - 1) in
  let bi = ref (String.length b - 1) in
  let borrow = ref 0 in
  let out = Buffer.create (String.length a) in
  while !ai >= 0 do
    let av = Char.code a.[!ai] - Char.code '0' - !borrow in
    let bv = if !bi >= 0 then Char.code b.[!bi] - Char.code '0' else 0 in
    let digit, borrow' =
      if av < bv then (av + 10 - bv, 1) else (av - bv, 0)
    in
    Buffer.add_char out (Char.chr (Char.code '0' + digit));
    borrow := borrow';
    decr ai;
    decr bi
  done;
  let rev = Buffer.contents out in
  let raw = String.init (String.length rev) (fun i -> rev.[String.length rev - 1 - i]) in
  let rec first_non_zero i =
    if i >= String.length raw - 1 then i
    else if raw.[i] = '0' then first_non_zero (i + 1)
    else i
  in
  String.sub raw (first_non_zero 0) (String.length raw - first_non_zero 0)

let decimal_normalize s =
  let s =
    if String.length s > 0 && s.[0] = '+' then
      String.sub s 1 (String.length s - 1)
    else s
  in
  let rec first_non_zero i =
    if i >= String.length s - 1 then i
    else if s.[i] = '0' then first_non_zero (i + 1)
    else i
  in
  if s = "" then "0"
  else String.sub s (first_non_zero 0) (String.length s - first_non_zero 0)

let decimal_compare a b =
  let a = decimal_normalize a in
  let b = decimal_normalize b in
  let la = String.length a and lb = String.length b in
  if la <> lb then compare la lb else String.compare a b

let strip_numeric_separators s =
  let b = Buffer.create (String.length s) in
  String.iter (fun c -> if c <> '_' then Buffer.add_char b c) s;
  Buffer.contents b

let unsigned_payload bits s =
  let s = String.trim s |> strip_numeric_separators in
  if String.length s > 0 && s.[0] = '-' then
    decimal_sub (decimal_pow2 bits) (String.sub s 1 (String.length s - 1))
  else s

let signed_float_payload bits s =
  let s = String.trim s |> strip_numeric_separators in
  if String.length s > 0 && s.[0] = '-' then s
  else
    let modulus = decimal_pow2 bits in
    let sign_cutoff = decimal_pow2 (bits - 1) in
    if decimal_compare s modulus >= 0 then
      fail
        ("f" ^ string_of_int bits
       ^ " bit-pattern outside unsigned payload range: " ^ s)
    else if decimal_compare s sign_cutoff >= 0 then
      let mag = decimal_sub modulus s in
      if mag = "0" then "0" else "-" ^ mag
    else s

let resolve_index kind names x =
  let s = atom x in
  if is_id s then
    match List.assoc_opt s names with
    | Some i -> i
    | None -> fail ("unknown " ^ kind ^ " id: " ^ s)
  else int_atom s

let maude_qid s =
  let raw = unquote s in
  let b = Buffer.create (String.length raw + 4) in
  String.iter
    (fun c ->
      let ok =
        (c >= 'a' && c <= 'z')
        || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9')
        || c = '_'
      in
      Buffer.add_char b (if ok then c else '_'))
    raw;
  let base =
    let s = Buffer.contents b in
    if s = "" then "name"
    else if s.[0] >= '0' && s.[0] <= '9' then "wat_" ^ s
    else s
  in
  "'" ^ base

let read_typed_names xs =
  let rec loop ids tys = function
    | [] -> (List.rev ids, List.rev tys)
    | Atom id :: t :: rest when is_id id ->
        loop (Some id :: ids) (valtype_of_sexpr t :: tys) rest
    | t :: rest -> loop (None :: ids) (valtype_of_sexpr t :: tys) rest
  in
  loop [] [] xs

let read_func_type_fields fields =
  let params = ref [] and results = ref [] in
  List.iter
    (function
      | List (Atom "param" :: xs) ->
          let _, ts = read_typed_names xs in
          params := !params @ ts
      | List (Atom "result" :: xs) -> results := !results @ List.map valtype_of_sexpr xs
      | _ -> fail "unsupported function type field")
	    fields;
	  { params = !params; results = !results }

let type_term typ =
  let params = valtype_seq typ.params in
  let results = valtype_seq typ.results in
  "TYPE_(REC_(SUB___(FINAL, eps, FUNCARROW__("
  ^ params ^ ", " ^ results ^ "))))"

let func_type_def id typ = { type_id = id; type_term = type_term typ; type_func = Some typ }

let read_type_decl = function
  | List (Atom "type" :: body) ->
      let id, body =
        match body with
        | Atom id :: rest when is_id id -> (Some id, rest)
        | _ -> (None, body)
      in
      let typ =
        match body with
        | [ List (Atom "func" :: fields) ] -> read_func_type_fields fields
        | _ -> fail "only (type (func ...)) is supported"
      in
	      func_type_def id typ
	  | _ -> fail "expected (type ...)"

let local_decl t = "LOCAL_(" ^ t ^ ")"

let parse_blocktype env fields =
  let params = ref [] and results = ref [] in
  let rest = ref [] in
  List.iter
    (function
      | List (Atom "result" :: xs) -> results := !results @ List.map valtype_of_sexpr xs
      | List (Atom "param" :: xs) ->
          let _, ts = read_typed_names xs in
          params := !params @ ts
      | List [ Atom "type"; x ] ->
          rest := !rest @ [ List [ Atom "type"; x ] ]
      | x -> rest := !rest @ [ x ])
    fields;
  match !rest with
  | List [ Atom "type"; x ] :: instrs ->
      ("WIDX_("
      ^ wrap_source_category "Typeidx"
          (string_of_int (resolve_index "type" env.type_names x))
      ^ ")", instrs)
  | instrs ->
      if !params <> [] || List.length !results > 1 then
        let idx = env.fresh_type { params = !params; results = !results } in
        ("WIDX_(" ^ wrap_source_category "Typeidx" (string_of_int idx) ^ ")", instrs)
      else ("WRESULT_(" ^ seq !results ^ ")", instrs)

let memarg_term ?(align = "0") offset =
  "RECMemargA2("
  ^ wrap_source_category "U32" align
  ^ ", "
  ^ wrap_source_category "U64" offset
  ^ ")"

let numtype_of_prefix = function
  | "i32" -> "I32"
  | "i64" -> "I64"
  | "f32" -> "F32"
  | "f64" -> "F64"
  | t -> fail ("unsupported numeric type prefix: " ^ t)

let int64_numeric s =
  Int64.of_string (String.trim s |> strip_numeric_separators)

let float_shape width =
  match width with
  | 32 -> (23, 8, 127)
  | 64 -> (52, 11, 1023)
  | _ -> fail ("unsupported float width: " ^ string_of_int width)

let float_bits_term width payload =
  let fracbits, ebits, bias = float_shape width in
  let raw = int64_numeric (signed_float_payload width payload) in
  let bits =
    if width = 32 then Int64.logand raw 0xffffffffL else raw
  in
  let sign =
    Int64.(to_int (shift_right_logical bits (width - 1)))
  in
  let exp_field =
    Int64.(
      to_int
        (logand
           (shift_right_logical bits fracbits)
           (sub (shift_left 1L ebits) 1L)))
  in
  let frac =
    Int64.(
      logand bits
        (sub (shift_left 1L fracbits) 1L))
  in
  let max_exp = (1 lsl ebits) - 1 in
  let mag =
    if exp_field = 0 then
      "SUBNORM_(" ^ Int64.to_string frac ^ ")"
    else if exp_field = max_exp && frac = 0L then
      "INF"
    else if exp_field = max_exp then
      "NAN_(" ^ Int64.to_string frac ^ ")"
    else
      "NORM__(" ^ Int64.to_string frac ^ ", "
      ^ string_of_int (exp_field - bias) ^ ")"
  in
  if sign = 0 then "POS_(" ^ mag ^ ")" else "NEG_(" ^ mag ^ ")"

let nan_float_bits width normalized =
  let sign, rest =
    if starts_with normalized "-nan" then (1, String.sub normalized 1 (String.length normalized - 1))
    else if starts_with normalized "+nan" then (0, String.sub normalized 1 (String.length normalized - 1))
    else (0, normalized)
  in
  let fracbits, ebits, _ = float_shape width in
  let default_payload = Int64.shift_left 1L (fracbits - 1) in
  let payload =
    match String.split_on_char ':' rest with
    | [ "nan" ] -> default_payload
    | [ "nan"; p ] when starts_with p "0x" ->
        let parsed = Int64.of_string p in
        if parsed = 0L then default_payload else parsed
    | _ -> fail ("unsupported f" ^ string_of_int width ^ " NaN literal: " ^ normalized)
  in
  let max_exp = Int64.sub (Int64.shift_left 1L ebits) 1L in
  let mag = Int64.add (Int64.shift_left max_exp fracbits) payload in
  let bits =
    if sign = 0 then mag
    else Int64.add (Int64.shift_left 1L (width - 1)) mag
  in
  Int64.to_string bits

let simple_float_literal width s =
  let normalized = String.lowercase_ascii s in
  if starts_with normalized "nan" || starts_with normalized "+nan"
     || starts_with normalized "-nan"
  then nan_float_bits width normalized
  else
    let ocaml_lit =
      if normalized = "inf" || normalized = "+inf" then "infinity"
      else if normalized = "-inf" then "neg_infinity"
      else normalized
    in
    try
      let f = float_of_string ocaml_lit in
      if width = 32 then Int32.to_string (Int32.bits_of_float f)
      else Int64.to_string (Int64.bits_of_float f)
    with Failure _ ->
      fail ("unsupported non-integer f" ^ string_of_int width ^ " literal: " ^ s)

let wrapped_num_payload = function
  | ("i32" | "i64" | "f32" | "f64" as ty), payload ->
      let _ = ty in
      String.trim payload |> strip_numeric_separators
  | ty, _ -> fail ("unsupported numeric literal wrapper type: " ^ ty)

let num_const_term ty payload =
  "CONST__(" ^ numtype_of_prefix ty ^ ", " ^ wrapped_num_payload (ty, payload) ^ ")"

let i32_const payload = num_const_term "i32" (unsigned_payload 32 payload)
let i64_const payload = num_const_term "i64" (unsigned_payload 64 payload)
let f32_const payload = "CONST__(F32, " ^ float_bits_term 32 payload ^ ")"
let f64_const payload = "CONST__(F64, " ^ float_bits_term 64 payload ^ ")"
let float_arg_const width value =
  let bits_prefix = "bits:" in
  let payload =
    if starts_with value bits_prefix then
      String.sub value (String.length bits_prefix)
        (String.length value - String.length bits_prefix)
    else simple_float_literal width value
  in
  if width = 32 then f32_const payload else f64_const payload

let int_binop = function
  | "add" -> "ADD"
  | "sub" -> "SUBBINOP"
  | "mul" -> "MUL"
  | "div_s" -> "DIVSXBINOP_(S)"
  | "div_u" -> "DIVSXBINOP_(U)"
  | "rem_s" -> "WREM_(S)"
  | "rem_u" -> "WREM_(U)"
  | "and" -> "WAND"
  | "or" -> "WOR"
  | "xor" -> "XOR"
  | "shl" -> "SHL"
  | "shr_s" -> "SHR_(S)"
  | "shr_u" -> "SHR_(U)"
  | "rotl" -> "ROTL"
  | "rotr" -> "ROTR"
  | op -> fail ("unsupported integer binop: " ^ op)

let float_binop = function
  | "add" -> "ADD"
  | "sub" -> "SUBBINOP"
  | "mul" -> "MUL"
  | "div" -> "DIVBINOP"
  | "min" -> "MINBINOP"
  | "max" -> "MAXBINOP"
  | "copysign" -> "COPYSIGN"
  | op -> fail ("unsupported float binop: " ^ op)

let int_relop = function
  | "eq" -> "WEQ"
  | "ne" -> "NE"
  | "lt_s" -> "LTSXRELOP_(S)"
  | "lt_u" -> "LTSXRELOP_(U)"
  | "gt_s" -> "GTSXRELOP_(S)"
  | "gt_u" -> "GTSXRELOP_(U)"
  | "le_s" -> "LESXRELOP_(S)"
  | "le_u" -> "LESXRELOP_(U)"
  | "ge_s" -> "GESXRELOP_(S)"
  | "ge_u" -> "GESXRELOP_(U)"
  | op -> fail ("unsupported integer relop: " ^ op)

let float_relop = function
  | "eq" -> "WEQ"
  | "ne" -> "NE"
  | "lt" -> "LTRELOP"
  | "gt" -> "GTRELOP"
  | "le" -> "LERELOP"
  | "ge" -> "GERELOP"
  | op -> fail ("unsupported float relop: " ^ op)

let int_unop = function
  | "clz" -> "CLZ"
  | "ctz" -> "CTZ"
  | "popcnt" -> "POPCNT"
  | "extend8_s" -> "EXTEND_(8)"
  | "extend16_s" -> "EXTEND_(16)"
  | "extend32_s" -> "EXTEND_(32)"
  | op -> fail ("unsupported integer unop: " ^ op)

let float_unop = function
  | "abs" -> "ABS"
  | "neg" -> "NEGUNOP"
  | "sqrt" -> "SQRT"
  | "ceil" -> "CEIL"
  | "floor" -> "FLOOR"
  | "trunc" -> "TRUNCUNOP"
  | "nearest" -> "NEAREST"
  | op -> fail ("unsupported float unop: " ^ op)

let split_opcode head =
  match String.split_on_char '.' head with
  | [ ty; op ] -> Some (ty, op)
  | _ -> None

let cvtop_term = function
  | "i64.extend_i32_s" -> Some "CVTOP___(I64, I32, EXTEND_(S))"
  | "i64.extend_i32_u" -> Some "CVTOP___(I64, I32, EXTEND_(U))"
  | "i32.wrap_i64" -> Some "CVTOP___(I32, I64, WRAP)"
  | "i32.trunc_f32_s" -> Some "CVTOP___(I32, F32, TRUNC_(S))"
  | "i32.trunc_f32_u" -> Some "CVTOP___(I32, F32, TRUNC_(U))"
  | "i32.trunc_f64_s" -> Some "CVTOP___(I32, F64, TRUNC_(S))"
  | "i32.trunc_f64_u" -> Some "CVTOP___(I32, F64, TRUNC_(U))"
  | "i64.trunc_f32_s" -> Some "CVTOP___(I64, F32, TRUNC_(S))"
  | "i64.trunc_f32_u" -> Some "CVTOP___(I64, F32, TRUNC_(U))"
  | "i64.trunc_f64_s" -> Some "CVTOP___(I64, F64, TRUNC_(S))"
  | "i64.trunc_f64_u" -> Some "CVTOP___(I64, F64, TRUNC_(U))"
  | "i32.trunc_sat_f32_s" -> Some "CVTOP___(I32, F32, TRUNCSAT_(S))"
  | "i32.trunc_sat_f32_u" -> Some "CVTOP___(I32, F32, TRUNCSAT_(U))"
  | "i32.trunc_sat_f64_s" -> Some "CVTOP___(I32, F64, TRUNCSAT_(S))"
  | "i32.trunc_sat_f64_u" -> Some "CVTOP___(I32, F64, TRUNCSAT_(U))"
  | "i64.trunc_sat_f32_s" -> Some "CVTOP___(I64, F32, TRUNCSAT_(S))"
  | "i64.trunc_sat_f32_u" -> Some "CVTOP___(I64, F32, TRUNCSAT_(U))"
  | "i64.trunc_sat_f64_s" -> Some "CVTOP___(I64, F64, TRUNCSAT_(S))"
  | "i64.trunc_sat_f64_u" -> Some "CVTOP___(I64, F64, TRUNCSAT_(U))"
  | "f32.convert_i32_s" -> Some "CVTOP___(F32, I32, CONVERT_(S))"
  | "f32.convert_i32_u" -> Some "CVTOP___(F32, I32, CONVERT_(U))"
  | "f32.convert_i64_s" -> Some "CVTOP___(F32, I64, CONVERT_(S))"
  | "f32.convert_i64_u" -> Some "CVTOP___(F32, I64, CONVERT_(U))"
  | "f64.convert_i32_s" -> Some "CVTOP___(F64, I32, CONVERT_(S))"
  | "f64.convert_i32_u" -> Some "CVTOP___(F64, I32, CONVERT_(U))"
  | "f64.convert_i64_s" -> Some "CVTOP___(F64, I64, CONVERT_(S))"
  | "f64.convert_i64_u" -> Some "CVTOP___(F64, I64, CONVERT_(U))"
  | "f64.promote_f32" -> Some "CVTOP___(F64, F32, PROMOTE)"
  | "f32.demote_f64" -> Some "CVTOP___(F32, F64, DEMOTE)"
  | "i32.reinterpret_f32" -> Some "CVTOP___(I32, F32, REINTERPRET)"
  | "i64.reinterpret_f64" -> Some "CVTOP___(I64, F64, REINTERPRET)"
  | "f32.reinterpret_i32" -> Some "CVTOP___(F32, I32, REINTERPRET)"
  | "f64.reinterpret_i64" -> Some "CVTOP___(F64, I64, REINTERPRET)"
  | _ -> None

let signedness_ctor = function
  | "s" -> "S"
  | "u" -> "U"
  | sx -> fail ("unsupported signedness suffix: " ^ sx)

let dim_lit n = string_of_int n

let shape_term lane dim =
  "X__(" ^ lane ^ ", " ^ dim_lit dim ^ ")"

let vector_shape = function
  | "i8x16" -> Some (shape_term "I8" 16)
  | "i16x8" -> Some (shape_term "I16" 8)
  | "i32x4" -> Some (shape_term "I32" 4)
  | "i64x2" -> Some (shape_term "I64" 2)
  | "f32x4" -> Some (shape_term "F32" 4)
  | "f64x2" -> Some (shape_term "F64" 2)
  | _ -> None

let vector_shape_exn name =
  match vector_shape name with
  | Some sh -> sh
  | None -> fail ("unsupported vector shape: " ^ name)

let vector_half_ctor = function
  | "low" -> "LOW"
  | "high" -> "HIGH"
  | half -> fail ("unsupported vector half: " ^ half)

let vector_unop = function
  | "abs" -> Some "ABS"
  | "neg" -> Some "NEGVUNOP"
  | "sqrt" -> Some "SQRT"
  | "ceil" -> Some "CEIL"
  | "floor" -> Some "FLOOR"
  | "trunc" -> Some "TRUNCVUNOP"
  | "nearest" -> Some "NEAREST"
  | "popcnt" -> Some "POPCNT"
  | _ -> None

let vector_binop = function
  | "add" -> Some "ADD"
  | "sub" -> Some "SUBVBINOP"
  | "mul" -> Some "MUL"
  | "div" -> Some "DIVVBINOP"
  | "min" -> Some "MINVBINOP"
  | "max" -> Some "MAXVBINOP"
  | "pmin" -> Some "PMIN"
  | "pmax" -> Some "PMAX"
  | "relaxed_min" -> Some "RELAXEDMIN"
  | "relaxed_max" -> Some "RELAXEDMAX"
  | "q15mulr_sat_s" -> Some "Q15MULRSATS"
  | "relaxed_q15mulr_s" -> Some "RELAXEDQ15MULRS"
  | "avgr_u" -> Some "AVGRU"
  | op when starts_with op "add_sat_" ->
      Some ("ADDSAT_(" ^ signedness_ctor (String.sub op 8 (String.length op - 8)) ^ ")")
  | op when starts_with op "sub_sat_" ->
      Some ("SUBSAT_(" ^ signedness_ctor (String.sub op 8 (String.length op - 8)) ^ ")")
  | op when starts_with op "min_" ->
      Some ("MINSXVBINOP_(" ^ signedness_ctor (String.sub op 4 (String.length op - 4)) ^ ")")
  | op when starts_with op "max_" ->
      Some ("MAXSXVBINOP_(" ^ signedness_ctor (String.sub op 4 (String.length op - 4)) ^ ")")
  | _ -> None

let vector_relop = function
  | "eq" -> Some "WEQ"
  | "ne" -> Some "NE"
  | "lt" -> Some "LTVRELOP"
  | "gt" -> Some "GTVRELOP"
  | "le" -> Some "LEVRELOP"
  | "ge" -> Some "GEVRELOP"
  | op when starts_with op "lt_" ->
      Some ("LTSXVRELOP_(" ^ signedness_ctor (String.sub op 3 (String.length op - 3)) ^ ")")
  | op when starts_with op "gt_" ->
      Some ("GTSXVRELOP_(" ^ signedness_ctor (String.sub op 3 (String.length op - 3)) ^ ")")
  | op when starts_with op "le_" ->
      Some ("LESXVRELOP_(" ^ signedness_ctor (String.sub op 3 (String.length op - 3)) ^ ")")
  | op when starts_with op "ge_" ->
      Some ("GESXVRELOP_(" ^ signedness_ctor (String.sub op 3 (String.length op - 3)) ^ ")")
  | _ -> None

let vector_shiftop = function
  | "shl" -> Some "SHL"
  | "shr_s" -> Some "SHR_(S)"
  | "shr_u" -> Some "SHR_(U)"
  | _ -> None

let vector_cvtop_term prefix op =
  let dest = vector_shape_exn prefix in
  let term src opctor = Some ("VCVTOP___(" ^ dest ^ ", " ^ src ^ ", " ^ opctor ^ ")") in
  match String.split_on_char '_' op with
  | [ "trunc"; "sat"; src; sx ] ->
      term (vector_shape_exn src) ("TRUNCSAT__(" ^ signedness_ctor sx ^ ", eps)")
  | [ "trunc"; "sat"; src; sx; "zero" ] ->
      term (vector_shape_exn src)
        ("TRUNCSAT__(" ^ signedness_ctor sx ^ ", ZERO)")
  | [ "relaxed"; "trunc"; src; sx ] ->
      term (vector_shape_exn src) ("RELAXEDTRUNC__(" ^ signedness_ctor sx ^ ", eps)")
  | [ "relaxed"; "trunc"; src; sx; "zero" ] ->
      term (vector_shape_exn src)
        ("RELAXEDTRUNC__(" ^ signedness_ctor sx ^ ", ZERO)")
  | [ "convert"; src; sx ] ->
      term (vector_shape_exn src) ("CONVERT__(eps, " ^ signedness_ctor sx ^ ")")
  | [ "convert"; "low"; src; sx ] ->
      term (vector_shape_exn src) ("CONVERT__(LOW, " ^ signedness_ctor sx ^ ")")
  | [ "extend"; half; src; sx ] ->
      term (vector_shape_exn src)
        ("EXTEND__(" ^ vector_half_ctor half ^ ", " ^ signedness_ctor sx ^ ")")
  | [ "demote"; src; "zero" ] -> term (vector_shape_exn src) "DEMOTE_(ZERO)"
  | [ "promote"; "low"; src ] -> term (vector_shape_exn src) "PROMOTELOW"
  | _ -> None

let vector_extunop_term prefix op =
  match (prefix, op) with
  | "i32x4", "extadd_pairwise_i16x8_s" ->
      Some
        ("VEXTUNOP___(" ^ vector_shape_exn "i32x4" ^ ", "
        ^ vector_shape_exn "i16x8" ^ ", EXTADDPAIRWISE_(S))")
  | "i32x4", "extadd_pairwise_i16x8_u" ->
      Some
        ("VEXTUNOP___(" ^ vector_shape_exn "i32x4" ^ ", "
        ^ vector_shape_exn "i16x8" ^ ", EXTADDPAIRWISE_(U))")
  | "i16x8", "extadd_pairwise_i8x16_s" ->
      Some
        ("VEXTUNOP___(" ^ vector_shape_exn "i16x8" ^ ", "
        ^ vector_shape_exn "i8x16" ^ ", EXTADDPAIRWISE_(S))")
  | "i16x8", "extadd_pairwise_i8x16_u" ->
      Some
        ("VEXTUNOP___(" ^ vector_shape_exn "i16x8" ^ ", "
        ^ vector_shape_exn "i8x16" ^ ", EXTADDPAIRWISE_(U))")
  | _ -> None

let vector_extbinop_term prefix op =
  let dest = vector_shape_exn prefix in
  let term src opctor = Some ("VEXTBINOP___(" ^ dest ^ ", " ^ src ^ ", " ^ opctor ^ ")") in
  match String.split_on_char '_' op with
  | [ "extmul"; half; src; sx ] ->
      term (vector_shape_exn src)
        ("EXTMUL__(" ^ vector_half_ctor half ^ ", " ^ signedness_ctor sx ^ ")")
  | [ "dot"; src; "s" ] -> term (vector_shape_exn src) "DOTS"
  | [ "relaxed"; "dot"; "i8x16"; "i7x16"; "s" ] ->
      term (vector_shape_exn "i8x16") "RELAXEDDOTS"
  | _ -> None

let vector_extternop_term prefix op =
  let dest = vector_shape_exn prefix in
  let term src opctor = Some ("VEXTTERNOP___(" ^ dest ^ ", " ^ src ^ ", " ^ opctor ^ ")") in
  match String.split_on_char '_' op with
  | [ "relaxed"; "dot"; "i8x16"; "i7x16"; "add"; "s" ] ->
      term (vector_shape_exn "i8x16") "RELAXEDDOTADDS"
  | _ -> None

let vector_narrow_term prefix op =
  match String.split_on_char '_' op with
  | [ "narrow"; src; sx ] ->
      Some
        ("VNARROW___(" ^ vector_shape_exn prefix ^ ", " ^ vector_shape_exn src ^ ", "
        ^ signedness_ctor sx ^ ")")
  | _ -> None

let vector_instr_term head =
  match String.split_on_char '.' head with
  | [ "v128"; "not" ] -> Some "VVUNOP__(V128, WNOT)"
  | [ "v128"; "and" ] -> Some "VVBINOP__(V128, WAND)"
  | [ "v128"; "andnot" ] -> Some "VVBINOP__(V128, ANDNOT)"
  | [ "v128"; "or" ] -> Some "VVBINOP__(V128, WOR)"
  | [ "v128"; "xor" ] -> Some "VVBINOP__(V128, XOR)"
  | [ "v128"; "bitselect" ] -> Some "VVTERNOP__(V128, BITSELECT)"
  | [ "v128"; "any_true" ] -> Some "VVTESTOP__(V128, ANYTRUE)"
  | [ prefix; op ] -> (
      match vector_shape prefix with
      | None -> None
      | Some sh -> (
          match vector_cvtop_term prefix op with
          | Some term -> Some term
          | None -> (
              match vector_extunop_term prefix op with
              | Some term -> Some term
              | None -> (
              match vector_extbinop_term prefix op with
              | Some term -> Some term
              | None -> (
              match vector_extternop_term prefix op with
              | Some term -> Some term
              | None -> (
              match vector_narrow_term prefix op with
              | Some term -> Some term
              | None -> (
              match vector_unop op with
              | Some vop -> Some ("VUNOP__(" ^ sh ^ ", " ^ vop ^ ")")
              | None -> (
                  match vector_binop op with
                  | Some vop -> Some ("VBINOP__(" ^ sh ^ ", " ^ vop ^ ")")
                  | None -> (
                      match vector_relop op with
                      | Some vop -> Some ("VRELOP__(" ^ sh ^ ", " ^ vop ^ ")")
                      | None -> (
                          match vector_shiftop op with
                          | Some vop -> Some ("VSHIFTOP__(" ^ sh ^ ", " ^ vop ^ ")")
                          | None ->
                              if op = "all_true" then Some ("VTESTOP__(" ^ sh ^ ", ALLTRUE)")
                              else if op = "bitmask" then Some ("VBITMASK_(" ^ sh ^ ")")
                              else if op = "swizzle" then Some ("VSWIZZLOP__(" ^ sh ^ ", SWIZZLE)")
                              else if op = "relaxed_swizzle" then
                                Some ("VSWIZZLOP__(" ^ sh ^ ", RELAXEDSWIZZLE)")
                              else if op = "relaxed_laneselect" then
                                Some ("VTERNOP__(" ^ sh ^ ", RELAXEDLANESELECT)")
                              else if op = "relaxed_madd" then
                                Some ("VTERNOP__(" ^ sh ^ ", RELAXEDMADD)")
                              else if op = "relaxed_nmadd" then
                                Some ("VTERNOP__(" ^ sh ^ ", RELAXEDNMADD)")
                              else if op = "splat" then Some ("VSPLAT_(" ^ sh ^ ")")
                              else None))))))))))
  | _ -> None

let vector_lane_instr_term head lane =
  try
    let lane = int_arg lane in
    match String.split_on_char '.' head with
    | [ prefix; op ] -> (
        match vector_shape prefix with
        | None -> None
        | Some sh ->
            if op = "replace_lane" then Some ("VREPLACELANE__(" ^ sh ^ ", " ^ lane ^ ")")
            else if op = "extract_lane" then
              Some ("VEXTRACTLANE___(" ^ sh ^ ", eps, " ^ lane ^ ")")
            else if starts_with op "extract_lane_" then
              let sx = String.sub op 13 (String.length op - 13) in
              Some
                ("VEXTRACTLANE___(" ^ sh ^ ", " ^ signedness_ctor sx ^ ", " ^ lane
               ^ ")")
            else None)
    | _ -> None
  with Error _ -> None

let load_store_names =
  [
    "i32.load";
    "i64.load";
    "f32.load";
    "f64.load";
    "i32.store";
    "i64.store";
    "f32.store";
    "f64.store";
    "i32.load8_s";
    "i32.load8_u";
    "i32.load16_s";
    "i32.load16_u";
    "i64.load8_s";
    "i64.load8_u";
    "i64.load16_s";
    "i64.load16_u";
    "i64.load32_s";
    "i64.load32_u";
    "i32.store8";
    "i32.store16";
    "i64.store8";
    "i64.store16";
    "i64.store32";
  ]

let vector_memory_names =
  [
    "v128.load";
    "v128.store";
    "v128.load8_lane";
    "v128.load16_lane";
    "v128.load32_lane";
    "v128.load64_lane";
    "v128.store8_lane";
    "v128.store16_lane";
    "v128.store32_lane";
    "v128.store64_lane";
    "v128.load8_splat";
    "v128.load16_splat";
    "v128.load32_splat";
    "v128.load64_splat";
    "v128.load8x8_s";
    "v128.load8x8_u";
    "v128.load16x4_s";
    "v128.load16x4_u";
    "v128.load32x2_s";
    "v128.load32x2_u";
    "v128.load32_zero";
    "v128.load64_zero";
  ]

let opcode_without_immediate =
  [
    "memory.size";
    "memory.grow";
    "select";
    "drop";
    "return";
    "nop";
    "unreachable";
    "ref.is_null";
    "ref.as_non_null";
    "ref.eq";
    "ref.i31";
    "throw_ref";
  ]

let opcode_with_immediate =
  [
    "local.get";
    "local.set";
    "local.tee";
    "global.get";
    "global.set";
    "table.get";
    "table.set";
    "table.size";
    "memory.size";
    "memory.grow";
    "memory.init";
    "memory.copy";
    "memory.fill";
    "i32.const";
    "i64.const";
    "f32.const";
    "f64.const";
    "br";
    "br_if";
    "br_on_null";
    "br_on_non_null";
    "call";
    "return_call";
    "call_ref";
    "return_call_ref";
    "ref.null";
    "ref.func";
    "ref.test";
    "ref.cast";
    "throw";
    "v128.const";
  ]

let is_known_opcode = function
  | "block" | "loop" | "end" | "else" | "if" | "try_table" | "br_table" | "call_indirect"
  | "return_call_indirect"
  | "table.init" | "table.copy" | "table.grow" | "table.fill" | "elem.drop"
  | "data.drop" | "memory.init" | "memory.copy" | "memory.fill" ->
      true
  | op ->
      List.mem op opcode_without_immediate
      || List.mem op opcode_with_immediate
      || List.mem op load_store_names
      || List.mem op vector_memory_names
      || Option.is_some (cvtop_term op)
      || starts_with op "i8x16."
      || starts_with op "i16x8."
      || starts_with op "i32x4."
      || starts_with op "i64x2."
      || starts_with op "f32x4."
      || starts_with op "f64x2."
      || starts_with op "v128."
      ||
      match split_opcode op with
      | Some ((("i32" | "i64" | "f32" | "f64") as ty), op) -> (
          match (ty, op) with
          | ("i32" | "i64"), "eqz" -> true
          | ("i32" | "i64"), _ -> (
              try
                ignore (int_binop op);
                true
              with Error _ -> (
                try
                  ignore (int_relop op);
                  true
                with Error _ -> (
                  try
                    ignore (int_unop op);
                    true
                  with Error _ -> false)))
          | ("f32" | "f64"), _ -> (
              try
                ignore (float_binop op);
                true
              with Error _ -> (
                try
                  ignore (float_relop op);
                  true
                with Error _ -> (
                  try
                    ignore (float_unop op);
                    true
                  with Error _ -> false)))
          | _ -> false)
      | _ -> starts_with op "i32." || starts_with op "i64." || starts_with op "f32." || starts_with op "f64."

let parse_memory_operands env rest =
  let rec loop memidx align offset = function
    | Atom a :: xs when not (is_known_opcode a) && is_int_literal a ->
        loop
          (wrap_source_category "Memidx"
             (string_of_int (resolve_index "memory" env.memory_names (Atom a))))
          align offset xs
    | Atom a :: xs when starts_with a "offset=" ->
      let value = String.sub a 7 (String.length a - 7) in
        ignore (int_arg (Atom value));
        loop memidx align value xs
    | Atom a :: xs when starts_with a "align=" ->
        let value = String.sub a 6 (String.length a - 6) in
        ignore (int_arg (Atom value));
        loop memidx value offset xs
    | xs -> (memidx, memarg_term ~align offset, xs)
  in
  loop (wrap_source_category "Memidx" "0") "0" "0" rest

let parse_load_store_instr env head rest =
  let memidx, memarg, rest = parse_memory_operands env rest in
  let term =
    match head with
    | "i32.load" -> "LOAD____(I32, eps, " ^ memidx ^ ", " ^ memarg ^ ")"
    | "i64.load" -> "LOAD____(I64, eps, " ^ memidx ^ ", " ^ memarg ^ ")"
    | "f32.load" -> "LOAD____(F32, eps, " ^ memidx ^ ", " ^ memarg ^ ")"
    | "f64.load" -> "LOAD____(F64, eps, " ^ memidx ^ ", " ^ memarg ^ ")"
    | "i32.load8_s" ->
        "LOAD____(I32, ANY__(" ^ sz_term 8 ^ ", S), " ^ memidx ^ ", " ^ memarg ^ ")"
    | "i32.load8_u" ->
        "LOAD____(I32, ANY__(" ^ sz_term 8 ^ ", U), " ^ memidx ^ ", " ^ memarg ^ ")"
    | "i32.load16_s" ->
        "LOAD____(I32, ANY__(" ^ sz_term 16 ^ ", S), " ^ memidx ^ ", " ^ memarg ^ ")"
    | "i32.load16_u" ->
        "LOAD____(I32, ANY__(" ^ sz_term 16 ^ ", U), " ^ memidx ^ ", " ^ memarg ^ ")"
    | "i64.load8_s" ->
        "LOAD____(I64, ANY__(" ^ sz_term 8 ^ ", S), " ^ memidx ^ ", " ^ memarg ^ ")"
    | "i64.load8_u" ->
        "LOAD____(I64, ANY__(" ^ sz_term 8 ^ ", U), " ^ memidx ^ ", " ^ memarg ^ ")"
    | "i64.load16_s" ->
        "LOAD____(I64, ANY__(" ^ sz_term 16 ^ ", S), " ^ memidx ^ ", " ^ memarg ^ ")"
    | "i64.load16_u" ->
        "LOAD____(I64, ANY__(" ^ sz_term 16 ^ ", U), " ^ memidx ^ ", " ^ memarg ^ ")"
    | "i64.load32_s" ->
        "LOAD____(I64, ANY__(" ^ sz_term 32 ^ ", S), " ^ memidx ^ ", " ^ memarg ^ ")"
    | "i64.load32_u" ->
        "LOAD____(I64, ANY__(" ^ sz_term 32 ^ ", U), " ^ memidx ^ ", " ^ memarg ^ ")"
    | "i32.store" -> "STORE____(I32, eps, " ^ memidx ^ ", " ^ memarg ^ ")"
    | "i64.store" -> "STORE____(I64, eps, " ^ memidx ^ ", " ^ memarg ^ ")"
    | "f32.store" -> "STORE____(F32, eps, " ^ memidx ^ ", " ^ memarg ^ ")"
    | "f64.store" -> "STORE____(F64, eps, " ^ memidx ^ ", " ^ memarg ^ ")"
    | "i32.store8" -> "STORE____(I32, " ^ sz_term 8 ^ ", " ^ memidx ^ ", " ^ memarg ^ ")"
    | "i32.store16" -> "STORE____(I32, " ^ sz_term 16 ^ ", " ^ memidx ^ ", " ^ memarg ^ ")"
    | "i64.store8" -> "STORE____(I64, " ^ sz_term 8 ^ ", " ^ memidx ^ ", " ^ memarg ^ ")"
    | "i64.store16" -> "STORE____(I64, " ^ sz_term 16 ^ ", " ^ memidx ^ ", " ^ memarg ^ ")"
    | "i64.store32" -> "STORE____(I64, " ^ sz_term 32 ^ ", " ^ memidx ^ ", " ^ memarg ^ ")"
    | _ -> assert false
  in
  (term, rest)

let parse_vector_memory_instr env head rest =
  let lane_size = function
    | "v128.load8_lane" | "v128.store8_lane" -> 8
    | "v128.load16_lane" | "v128.store16_lane" -> 16
    | "v128.load32_lane" | "v128.store32_lane" -> 32
    | "v128.load64_lane" | "v128.store64_lane" -> 64
    | _ -> fail ("not a vector lane memory instruction: " ^ head)
  in
  let splat_size = function
    | "v128.load8_splat" -> 8
    | "v128.load16_splat" -> 16
    | "v128.load32_splat" -> 32
    | "v128.load64_splat" -> 64
    | _ -> fail ("not a vector splat memory instruction: " ^ head)
  in
  let packed_load = function
    | "v128.load8x8_s" -> Some (8, 8, "S")
    | "v128.load8x8_u" -> Some (8, 8, "U")
    | "v128.load16x4_s" -> Some (16, 4, "S")
    | "v128.load16x4_u" -> Some (16, 4, "U")
    | "v128.load32x2_s" -> Some (32, 2, "S")
    | "v128.load32x2_u" -> Some (32, 2, "U")
    | _ -> None
  in
  if contains_sub head "_lane" then
    let rec loop align offset ints = function
      | Atom a :: xs when starts_with a "offset=" ->
          let value = String.sub a 7 (String.length a - 7) in
          ignore (int_arg (Atom value));
          loop align value ints xs
      | Atom a :: xs when starts_with a "align=" ->
          let value = String.sub a 6 (String.length a - 6) in
          ignore (int_arg (Atom value));
          loop value offset ints xs
      | Atom a :: xs when is_int_literal a && not (is_known_opcode a) ->
          loop align offset (ints @ [ a ]) xs
      | xs ->
          let memidx, lane =
            match ints with
            | [ lane ] -> ("0", lane)
            | [ memidx; lane ] -> (memidx, lane)
            | _ -> fail ("missing lane immediate for " ^ head)
          in
          let memarg = memarg_term ~align offset in
          let n = string_of_int (lane_size head) in
          let ctor =
            if starts_with head "v128.load" then
              "VLOADLANE_____(V128, " ^ n ^ ", " ^ memidx ^ ", " ^ memarg
              ^ ", " ^ lane ^ ")"
            else
              "VSTORELANE_____(V128, " ^ n ^ ", " ^ memidx ^ ", " ^ memarg
              ^ ", " ^ lane ^ ")"
          in
          (ctor, xs)
    in
    loop "0" "0" [] rest
  else
    let memidx, memarg, rest = parse_memory_operands env rest in
    let term =
      match head with
      | "v128.load" -> "VLOAD____(V128, eps, " ^ memidx ^ ", " ^ memarg ^ ")"
      | "v128.store" -> "VSTORE___(V128, " ^ memidx ^ ", " ^ memarg ^ ")"
      | "v128.load32_zero" ->
          "VLOAD____(V128, ZERO_(" ^ sz_term 32 ^ "), " ^ memidx ^ ", " ^ memarg ^ ")"
      | "v128.load64_zero" ->
          "VLOAD____(V128, ZERO_(" ^ sz_term 64 ^ "), " ^ memidx ^ ", " ^ memarg ^ ")"
      | "v128.load8_splat" | "v128.load16_splat" | "v128.load32_splat"
      | "v128.load64_splat" ->
          "VLOAD____(V128, SPLAT_(" ^ sz_term (splat_size head)
          ^ "), " ^ memidx ^ ", " ^ memarg ^ ")"
      | _ -> (
          match packed_load head with
          | Some (m, k, sx) ->
              "VLOAD____(V128, SHAPEXANY___("
              ^ sz_term m ^ ", " ^ string_of_int k ^ ", " ^ sx ^ "), "
              ^ memidx ^ ", " ^ memarg ^ ")"
          | None -> fail ("unsupported vector memory instruction: " ^ head))
    in
    (term, rest)

let collect_vector_const_operands rest =
  let rec loop acc = function
    | Atom a :: xs when not (is_known_opcode a) -> loop (Atom a :: acc) xs
    | xs -> (List.rev acc, xs)
  in
  loop [] rest

let v128_const_term operands =
  match operands with
  | Atom _shape :: lanes ->
      let lane_terms = List.map atom lanes in
      "VCONST__(V128, $v128lanes(" ^ seq lane_terms ^ "))"
  | [] -> "VCONST__(V128, $v128lanes(eps))"
  | _ -> fail "unsupported v128.const operands"

let collect_shuffle_lanes rest =
  let rec loop n acc = function
    | Atom a :: xs when n < 16 && is_int_literal a -> loop (n + 1) (a :: acc) xs
    | xs when n = 16 -> (List.rev acc, xs)
    | _ -> fail "i8x16.shuffle requires 16 lane immediates"
  in
  loop 0 [] rest

let shuffle_term lanes =
  "VSHUFFLE__(" ^ vector_shape_exn "i8x16" ^ ", " ^ seq lanes ^ ")"

let resolve_label env = function
  | Atom id when is_id id ->
      wrap_source_category "Labelidx"
        (string_of_int (resolve_index "label" env.label_names (Atom id)))
  | x -> wrap_source_category "Labelidx" (int_arg x)

let resolve_tag env x =
  wrap_source_category "Tagidx"
    (string_of_int (resolve_index "tag" env.tag_names x))

let parse_br_table env labels =
  let labels = List.map (resolve_label env) labels in
  let rec split_last acc = function
    | [] -> fail "br_table requires at least one label"
    | [ x ] -> (List.rev acc, x)
    | x :: xs -> split_last (x :: acc) xs
  in
  let prefix, default = split_last [] labels in
  "BRTABLE__(" ^ labelidx_seq prefix ^ ", " ^ default ^ ")"

let collect_br_table_operands rest =
  let rec loop acc = function
    | Atom a :: xs when not (is_known_opcode a) -> loop (Atom a :: acc) xs
    | xs -> (List.rev acc, xs)
  in
  loop [] rest

let parse_catch_clause env = function
  | List [ Atom "catch"; tag; label ] ->
      "CATCH__(" ^ resolve_tag env tag ^ ", " ^ resolve_label env label ^ ")"
  | List [ Atom "catch_ref"; tag; label ] ->
      "CATCHREF__(" ^ resolve_tag env tag ^ ", " ^ resolve_label env label ^ ")"
  | List [ Atom "catch_all"; label ] ->
      "CATCHALL_(" ^ resolve_label env label ^ ")"
  | List [ Atom "catch_all_ref"; label ] ->
      "CATCHALLREF_(" ^ resolve_label env label ^ ")"
  | x -> fail ("unsupported catch clause: " ^ atom_or_shape x)

let is_catch_clause = function
  | List (Atom ("catch" | "catch_ref" | "catch_all" | "catch_all_ref") :: _) -> true
  | _ -> false

let resolve_mem env = function
  | None -> wrap_source_category "Memidx" "0"
  | Some x ->
      wrap_source_category "Memidx"
        (string_of_int (resolve_index "memory" env.memory_names x))

let resolve_table env x =
  wrap_source_category "Tableidx"
    (string_of_int (resolve_index "table" env.table_names x))

let resolve_global env x =
  wrap_source_category "Globalidx"
    (string_of_int (resolve_index "global" env.global_names x))

let rec parse_instr env = function
  | List (Atom "block" :: body) ->
      let id, body =
        match body with Atom id :: rest when is_id id -> (Some id, rest) | _ -> (None, body)
      in
      let bt, instrs = parse_blocktype env body in
      let env = enter_label env id in
      "BLOCK__(" ^ bt ^ ", " ^ instr_seq (parse_instr_list env instrs) ^ ")"
  | List (Atom "loop" :: body) ->
      let id, body =
        match body with Atom id :: rest when is_id id -> (Some id, rest) | _ -> (None, body)
      in
      let bt, instrs = parse_blocktype env body in
      let env = enter_label env id in
      "LOOP__(" ^ bt ^ ", " ^ instr_seq (parse_instr_list env instrs) ^ ")"
  | List (Atom "if" :: body) ->
      let bt, instrs = parse_blocktype env body in
      "WIFELSE___(" ^ bt ^ ", " ^ instr_seq (parse_instr_list env instrs) ^ ", eps)"
  | List (Atom "try_table" :: body) ->
      let id, body =
        match body with Atom id :: rest when is_id id -> (Some id, rest) | _ -> (None, body)
      in
      let bt, rest = parse_blocktype env body in
      let catches, instrs = List.partition is_catch_clause rest in
      let body_env = enter_label env id in
      "TRYTABLE___(" ^ bt ^ ", " ^ catch_seq (List.map (parse_catch_clause env) catches)
      ^ ", " ^ instr_seq (parse_instr_list body_env instrs) ^ ")"
  | List [ Atom "call_indirect"; List [ Atom "type"; x ] ] ->
      "CALLINDIRECT__(" ^ wrap_source_category "Tableidx" "0" ^ ", WIDX_("
      ^ wrap_source_category "Typeidx" (string_of_int (resolve_index "type" env.type_names x))
      ^ "))"
  | List (Atom "return_call" :: target :: operands) ->
      seq (parse_instr_list env operands @ [ parse_flat_instr env "return_call" (Some target) ])
  | List (Atom "return_call_ref" :: target :: operands) ->
      seq (parse_instr_list env operands @ [ parse_flat_instr env "return_call_ref" (Some target) ])
  | List (Atom "br_table" :: labels) -> parse_br_table env labels
  | List (Atom "v128.const" :: operands) -> v128_const_term operands
  | List (Atom "i8x16.shuffle" :: lanes_and_operands) ->
      let lanes, operands = collect_shuffle_lanes lanes_and_operands in
      seq (parse_instr_list env operands @ [ shuffle_term lanes ])
  | List (Atom "select" :: List (Atom "result" :: tys) :: operands) ->
      seq
        (parse_instr_list env operands
        @ [ "SELECT_(" ^ valtype_seq (List.map valtype_of_sexpr tys) ^ ")" ])
  | List (Atom (("i32.const" | "i64.const" | "f32.const" | "f64.const" | "global.get") as head)
          :: imm :: rest) ->
      seq (parse_flat_instr env head (Some imm) :: parse_instr_list env rest)
  | List (Atom head :: rest) when List.mem head load_store_names ->
      let term, rest = parse_load_store_instr env head rest in
      if rest = [] then term else fail ("unexpected operands after " ^ head)
  | List (Atom head :: rest) when List.mem head vector_memory_names ->
      let term, rest = parse_vector_memory_instr env head rest in
      if rest = [] then term else fail ("unexpected operands after " ^ head)
  | List (Atom head :: lane :: operands) when Option.is_some (vector_lane_instr_term head lane) ->
      seq (parse_instr_list env operands @ [ Option.get (vector_lane_instr_term head lane) ])
  | List (Atom head :: operands) when Option.is_some (vector_instr_term head) ->
      seq (parse_instr_list env operands @ [ Option.get (vector_instr_term head) ])
  | List [ Atom head; lane ] when Option.is_some (vector_lane_instr_term head lane) ->
      Option.get (vector_lane_instr_term head lane)
  | List (Atom head :: operands)
    when
      (not (List.mem head opcode_with_immediate))
      &&
      (match split_opcode head with
      | Some (("i32" | "i64" | "f32" | "f64"), _) -> true
      | _ -> false)
      || Option.is_some (cvtop_term head)
      || List.mem head opcode_without_immediate ->
      seq (parse_instr_list env operands @ [ parse_flat_instr env head None ])
  | List [ Atom head; imm ] when List.mem head opcode_with_immediate ->
      parse_flat_instr env head (Some imm)
  | List [ Atom head ] when List.mem head opcode_without_immediate ->
      parse_flat_instr env head None
  | List [ Atom head ] when is_known_opcode head && not (List.mem head opcode_with_immediate)
    ->
      parse_flat_instr env head None
  | List (Atom head :: _) -> fail ("unsupported folded instruction: " ^ head)
  | _ -> fail "empty folded instruction"

and parse_flat_instr env head imm =
  let local x =
    wrap_source_category "Localidx"
      (string_of_int (resolve_index "local" env.local_names x))
  in
  let func x =
    wrap_source_category "Funcidx"
      (string_of_int (resolve_index "func" env.func_names x))
  in
  let typeidx x =
    wrap_source_category "Typeidx"
      (string_of_int (resolve_index "type" env.type_names x))
  in
  match (head, imm) with
  | "local.get", Some x -> "LOCALGET_(" ^ local x ^ ")"
  | "local.set", Some x -> "LOCALSET_(" ^ local x ^ ")"
  | "local.tee", Some x -> "LOCALTEE_(" ^ local x ^ ")"
  | "global.get", Some x -> "GLOBALGET_(" ^ resolve_global env x ^ ")"
  | "global.set", Some x -> "GLOBALSET_(" ^ resolve_global env x ^ ")"
  | "table.get", Some x -> "TABLEGET_(" ^ resolve_table env x ^ ")"
  | "table.set", Some x -> "TABLESET_(" ^ resolve_table env x ^ ")"
  | "table.size", Some x -> "TABLESIZE_(" ^ resolve_table env x ^ ")"
  | "table.size", None -> "TABLESIZE_(" ^ wrap_source_category "Tableidx" "0" ^ ")"
  | "memory.size", Some x -> "MEMORYSIZE_(" ^ resolve_mem env (Some x) ^ ")"
  | "memory.grow", Some x -> "MEMORYGROW_(" ^ resolve_mem env (Some x) ^ ")"
  | "i32.const", Some x -> i32_const (int_arg x)
  | "i64.const", Some x -> i64_const (int_arg x)
  | "f32.const", Some x -> f32_const (simple_float_literal 32 (atom x))
  | "f64.const", Some x -> f64_const (simple_float_literal 64 (atom x))
  | "br", Some x -> "BR_(" ^ resolve_label env x ^ ")"
  | "br_if", Some x -> "BRIF_(" ^ resolve_label env x ^ ")"
  | "br_on_null", Some x -> "BRONNULL_(" ^ resolve_label env x ^ ")"
  | "br_on_non_null", Some x -> "BRONNONNULL_(" ^ resolve_label env x ^ ")"
  | "call", Some x -> "CALL_(" ^ func x ^ ")"
  | "return_call", Some x -> "RETURNCALL_(" ^ func x ^ ")"
  | "call_ref", Some (List [ Atom "type"; x ]) ->
      "CALLREF_(WIDX_(" ^ typeidx x ^ "))"
  | "call_ref", Some x ->
      "CALLREF_(WIDX_(" ^ typeidx x ^ "))"
  | "return_call_ref", Some (List [ Atom "type"; x ]) ->
      "RETURNCALLREF_(WIDX_("
      ^ typeidx x
      ^ "))"
  | "return_call_ref", Some x ->
      "RETURNCALLREF_(WIDX_("
      ^ typeidx x
      ^ "))"
  | "ref.null", Some x -> "REFNULL_(" ^ heaptype (atom x) ^ ")"
  | "ref.func", Some x -> "REFFUNC_(" ^ func x ^ ")"
  | "ref.test", Some x -> "REFTEST_(" ^ reftype_of_sexpr x ^ ")"
  | "ref.cast", Some x -> "REFCAST_(" ^ reftype_of_sexpr x ^ ")"
  | "ref.is_null", None -> "REFISNULL"
  | "ref.as_non_null", None -> "REFASNONNULL"
  | "ref.eq", None -> "REFEQ"
  | "ref.i31", None -> "REFI31"
  | "throw_ref", None -> "THROWREF"
  | "throw", Some x -> "THROW_(" ^ resolve_tag env x ^ ")"
  | "v128.const", Some x -> "VCONST__(V128, $v128lanes(" ^ atom x ^ "))"
  | "v128.const", None -> "VCONST__(V128, $v128lanes(eps))"
  | head, None when Option.is_some (vector_instr_term head) ->
      Option.get (vector_instr_term head)
  | head, None when Option.is_some (cvtop_term head) ->
      Option.get (cvtop_term head)
  | head, None when List.mem head load_store_names ->
      fst (parse_load_store_instr env head [])
  | head, None
    when
      (match split_opcode head with
      | Some (("i32" | "i64" | "f32" | "f64"), _) -> true
      | _ -> false) -> (
      match split_opcode head with
      | Some ((("i32" | "i64") as ty), "eqz") ->
          "TESTOP__(" ^ numtype_of_prefix ty ^ ", EQZ)"
      | Some ((("i32" | "i64") as ty), op) -> (
          try "BINOP__(" ^ numtype_of_prefix ty ^ ", " ^ int_binop op ^ ")"
          with Error _ -> (
            try "RELOP__(" ^ numtype_of_prefix ty ^ ", " ^ int_relop op ^ ")"
            with Error _ ->
              "UNOP__(" ^ numtype_of_prefix ty ^ ", " ^ int_unop op ^ ")"))
      | Some ((("f32" | "f64") as ty), op) -> (
          try "BINOP__(" ^ numtype_of_prefix ty ^ ", " ^ float_binop op ^ ")"
          with Error _ -> (
            try "RELOP__(" ^ numtype_of_prefix ty ^ ", " ^ float_relop op ^ ")"
            with Error _ ->
              "UNOP__(" ^ numtype_of_prefix ty ^ ", " ^ float_unop op ^ ")"))
      | _ -> fail ("unsupported instruction form: " ^ head))
  | "memory.size", None -> "MEMORYSIZE_(" ^ wrap_source_category "Memidx" "0" ^ ")"
  | "memory.grow", None -> "MEMORYGROW_(" ^ wrap_source_category "Memidx" "0" ^ ")"
  | "select", None -> "SELECT_(eps)"
  | "drop", None -> "DROP"
  | "return", None -> "RETURN"
  | "nop", None -> "NOP"
  | "unreachable", None -> "UNREACHABLE"
  | _ -> fail ("unsupported instruction form: " ^ head)

and parse_instr_list env items =
  match items with
  | [] -> []
  | Atom ("block" as head) :: rest ->
      let term, rest = parse_flat_structured env head rest in
      term :: parse_instr_list env rest
  | Atom ("loop" as head) :: rest ->
      let term, rest = parse_flat_structured env head rest in
      term :: parse_instr_list env rest
  | Atom "if" :: rest ->
      let term, rest = parse_flat_if env rest in
      term :: parse_instr_list env rest
  | Atom "try_table" :: rest ->
      let term, rest = parse_flat_try_table env rest in
      term :: parse_instr_list env rest
  | Atom "end" :: _ -> fail "unexpected end"
  | List _ as x :: rest -> parse_instr env x :: parse_instr_list env rest
  | Atom "call_indirect" :: List [ Atom "type"; x ] :: rest ->
      ("CALLINDIRECT__(" ^ wrap_source_category "Tableidx" "0" ^ ", WIDX_("
      ^ wrap_source_category "Typeidx" (string_of_int (resolve_index "type" env.type_names x))
      ^ "))")
      :: parse_instr_list env rest
  | Atom "return_call_indirect" :: List [ Atom "type"; x ] :: rest ->
      ("RETURNCALLINDIRECT__(" ^ wrap_source_category "Tableidx" "0" ^ ", WIDX_("
      ^ wrap_source_category "Typeidx" (string_of_int (resolve_index "type" env.type_names x))
      ^ "))")
      :: parse_instr_list env rest
  | Atom "call_indirect" :: Atom tableidx :: List [ Atom "type"; x ] :: rest
    when not (is_known_opcode tableidx) ->
      ("CALLINDIRECT__("
      ^ wrap_source_category "Tableidx"
          (string_of_int (resolve_index "table" env.table_names (Atom tableidx)))
      ^ ", WIDX_("
      ^ wrap_source_category "Typeidx" (string_of_int (resolve_index "type" env.type_names x))
      ^ "))")
      :: parse_instr_list env rest
  | Atom "return_call_indirect" :: Atom tableidx :: List [ Atom "type"; x ] :: rest
    when not (is_known_opcode tableidx) ->
      ("RETURNCALLINDIRECT__("
      ^ wrap_source_category "Tableidx"
          (string_of_int (resolve_index "table" env.table_names (Atom tableidx)))
      ^ ", WIDX_("
      ^ wrap_source_category "Typeidx" (string_of_int (resolve_index "type" env.type_names x))
      ^ "))")
      :: parse_instr_list env rest
  | Atom "table.init" :: Atom tableidx :: Atom elemidx :: rest
    when (not (is_known_opcode tableidx)) && not (is_known_opcode elemidx) ->
      ("TABLEINIT__(" ^ wrap_source_category "Tableidx" (int_arg (Atom tableidx))
      ^ ", " ^ wrap_source_category "Elemidx" (int_arg (Atom elemidx)) ^ ")")
      :: parse_instr_list env rest
  | Atom "table.init" :: Atom elemidx :: rest when not (is_known_opcode elemidx) ->
      ("TABLEINIT__(" ^ wrap_source_category "Tableidx" "0"
      ^ ", " ^ wrap_source_category "Elemidx" (int_arg (Atom elemidx)) ^ ")")
      :: parse_instr_list env rest
  | Atom "table.copy" :: Atom dst :: Atom src :: rest
    when (not (is_known_opcode dst)) && not (is_known_opcode src) ->
      ("TABLECOPY__(" ^ wrap_source_category "Tableidx" (int_arg (Atom dst))
      ^ ", " ^ wrap_source_category "Tableidx" (int_arg (Atom src)) ^ ")")
      :: parse_instr_list env rest
  | Atom "table.copy" :: rest ->
      ("TABLECOPY__(" ^ wrap_source_category "Tableidx" "0"
      ^ ", " ^ wrap_source_category "Tableidx" "0" ^ ")")
      :: parse_instr_list env rest
  | Atom (("table.grow" | "table.fill") as head) :: Atom tableidx :: rest
    when not (is_known_opcode tableidx) ->
      let ctor = if head = "table.grow" then "TABLEGROW_" else "TABLEFILL_" in
      (ctor ^ "(" ^ resolve_table env (Atom tableidx) ^ ")") :: parse_instr_list env rest
  | Atom (("table.grow" | "table.fill") as head) :: rest ->
      let ctor = if head = "table.grow" then "TABLEGROW_" else "TABLEFILL_" in
      (ctor ^ "(" ^ wrap_source_category "Tableidx" "0" ^ ")") :: parse_instr_list env rest
  | Atom "elem.drop" :: Atom elemidx :: rest when not (is_known_opcode elemidx) ->
      ("ELEMDROP_(" ^ wrap_source_category "Elemidx" (int_arg (Atom elemidx)) ^ ")")
      :: parse_instr_list env rest
  | Atom "data.drop" :: Atom dataidx :: rest when not (is_known_opcode dataidx) ->
      ("DATADROP_(" ^ wrap_source_category "Dataidx" (int_arg (Atom dataidx)) ^ ")")
      :: parse_instr_list env rest
  | Atom "memory.init" :: Atom dataidx :: Atom memidx :: rest
    when (not (is_known_opcode dataidx)) && not (is_known_opcode memidx) ->
      ("MEMORYINIT__(" ^ resolve_mem env (Some (Atom memidx)) ^ ", "
      ^ wrap_source_category "Dataidx" (int_arg (Atom dataidx)) ^ ")")
      :: parse_instr_list env rest
  | Atom "memory.init" :: Atom dataidx :: rest when not (is_known_opcode dataidx) ->
      ("MEMORYINIT__(" ^ wrap_source_category "Memidx" "0"
      ^ ", " ^ wrap_source_category "Dataidx" (int_arg (Atom dataidx)) ^ ")")
      :: parse_instr_list env rest
  | Atom "memory.copy" :: Atom dst :: Atom src :: rest
    when (not (is_known_opcode dst)) && not (is_known_opcode src) ->
      ("MEMORYCOPY__(" ^ resolve_mem env (Some (Atom dst)) ^ ", "
      ^ resolve_mem env (Some (Atom src)) ^ ")")
      :: parse_instr_list env rest
  | Atom "memory.copy" :: rest ->
      ("MEMORYCOPY__(" ^ wrap_source_category "Memidx" "0"
      ^ ", " ^ wrap_source_category "Memidx" "0" ^ ")")
      :: parse_instr_list env rest
  | Atom "memory.fill" :: Atom memidx :: rest when not (is_known_opcode memidx) ->
      ("MEMORYFILL_(" ^ resolve_mem env (Some (Atom memidx)) ^ ")")
      :: parse_instr_list env rest
  | Atom "memory.fill" :: rest ->
      ("MEMORYFILL_(" ^ wrap_source_category "Memidx" "0" ^ ")")
      :: parse_instr_list env rest
  | Atom (("memory.size" | "memory.grow") as head) :: Atom x :: rest
    when not (is_known_opcode x) ->
      parse_flat_instr env head (Some (Atom x)) :: parse_instr_list env rest
  | Atom (("memory.size" | "memory.grow") as head) :: rest ->
      parse_flat_instr env head None :: parse_instr_list env rest
  | Atom "br_table" :: rest ->
      let labels, rest = collect_br_table_operands rest in
      parse_br_table env labels :: parse_instr_list env rest
  | Atom "v128.const" :: rest ->
      let operands, rest = collect_vector_const_operands rest in
      v128_const_term operands :: parse_instr_list env rest
  | Atom "i8x16.shuffle" :: rest ->
      let lanes, rest = collect_shuffle_lanes rest in
      shuffle_term lanes :: parse_instr_list env rest
  | Atom "select" :: List (Atom "result" :: tys) :: rest ->
      ("SELECT_(" ^ valtype_seq (List.map valtype_of_sexpr tys) ^ ")")
      :: parse_instr_list env rest
  | Atom head :: rest when List.mem head load_store_names ->
      let term, rest = parse_load_store_instr env head rest in
      term :: parse_instr_list env rest
  | Atom head :: rest when List.mem head vector_memory_names ->
      let term, rest = parse_vector_memory_instr env head rest in
      term :: parse_instr_list env rest
  | Atom head :: lane :: rest when Option.is_some (vector_lane_instr_term head lane) ->
      Option.get (vector_lane_instr_term head lane) :: parse_instr_list env rest
  | Atom head :: imm :: rest when List.mem head opcode_with_immediate ->
      parse_flat_instr env head (Some imm) :: parse_instr_list env rest
  | Atom head :: rest when List.mem head opcode_without_immediate ->
      parse_flat_instr env head None :: parse_instr_list env rest
  | Atom head :: rest when is_known_opcode head && not (List.mem head opcode_with_immediate) ->
      parse_flat_instr env head None :: parse_instr_list env rest
  | Atom head :: _ -> fail ("unsupported instruction: " ^ head)

and parse_flat_structured env head rest =
  let rec collect depth acc = function
    | [] -> fail ("missing end for " ^ head)
    | Atom ("block" | "loop" | "if" | "try_table") as x :: xs ->
        collect (depth + 1) (x :: acc) xs
    | Atom "end" :: xs ->
        if depth = 1 then (List.rev acc, xs)
        else collect (depth - 1) (Atom "end" :: acc) xs
    | x :: xs -> collect depth (x :: acc) xs
  in
  let body, rest = collect 1 [] rest in
  let id, body =
    match body with Atom id :: rest when is_id id -> (Some id, rest) | _ -> (None, body)
  in
  let bt, instrs = parse_blocktype env body in
  let body_env = enter_label env id in
  let term =
    match head with
    | "block" -> "BLOCK__(" ^ bt ^ ", " ^ instr_seq (parse_instr_list body_env instrs) ^ ")"
    | "loop" -> "LOOP__(" ^ bt ^ ", " ^ instr_seq (parse_instr_list body_env instrs) ^ ")"
    | _ -> assert false
  in
  (term, rest)

and parse_flat_if env rest =
  let rec collect depth in_else then_acc else_acc = function
    | [] -> fail "missing end for if"
    | Atom ("block" | "loop" | "if" | "try_table") as x :: xs ->
        if in_else then collect (depth + 1) in_else then_acc (x :: else_acc) xs
        else collect (depth + 1) in_else (x :: then_acc) else_acc xs
    | Atom "else" :: xs when depth = 1 ->
        collect depth true then_acc else_acc xs
    | Atom "end" :: xs ->
        if depth = 1 then (List.rev then_acc, List.rev else_acc, xs)
        else if in_else then collect (depth - 1) in_else then_acc (Atom "end" :: else_acc) xs
        else collect (depth - 1) in_else (Atom "end" :: then_acc) else_acc xs
    | x :: xs ->
        if in_else then collect depth in_else then_acc (x :: else_acc) xs
        else collect depth in_else (x :: then_acc) else_acc xs
  in
  let then_body, else_body, rest = collect 1 false [] [] rest in
  let id, then_body =
    match then_body with Atom id :: rest when is_id id -> (Some id, rest) | _ -> (None, then_body)
  in
  let bt, then_instrs = parse_blocktype env then_body in
  let body_env = enter_label env id in
  let term =
    "WIFELSE___(" ^ bt ^ ", " ^ instr_seq (parse_instr_list body_env then_instrs) ^ ", "
    ^ instr_seq (parse_instr_list body_env else_body) ^ ")"
  in
  (term, rest)

and parse_flat_try_table env rest =
  let rec collect depth acc = function
    | [] -> fail "missing end for try_table"
    | Atom ("block" | "loop" | "if" | "try_table") as x :: xs ->
        collect (depth + 1) (x :: acc) xs
    | Atom "end" :: xs ->
        if depth = 1 then (List.rev acc, xs)
        else collect (depth - 1) (Atom "end" :: acc) xs
    | x :: xs -> collect depth (x :: acc) xs
  in
  let body, rest = collect 1 [] rest in
  let id, body =
    match body with Atom id :: body when is_id id -> (Some id, body) | _ -> (None, body)
  in
  let bt, body = parse_blocktype env body in
  let rec split_catches catches = function
    | x :: xs when is_catch_clause x -> split_catches (catches @ [ x ]) xs
    | instrs -> (catches, instrs)
  in
  let catches, instrs = split_catches [] body in
  let body_env = enter_label env id in
  ( "TRYTABLE___(" ^ bt ^ ", " ^ catch_seq (List.map (parse_catch_clause env) catches)
    ^ ", " ^ instr_seq (parse_instr_list body_env instrs) ^ ")",
    rest )

let parse_typeuse type_names types_ref fields =
  let explicit_type = ref None in
  let params = ref [] and results = ref [] in
  List.iter
    (function
      | List [ Atom "type"; x ] ->
          explicit_type := Some (resolve_index "type" type_names x)
      | List (Atom "param" :: xs) ->
          let _, ts = read_typed_names xs in
          params := !params @ ts
      | List (Atom "result" :: xs) -> results := !results @ List.map valtype_of_sexpr xs
      | _ -> ())
    fields;
  match !explicit_type with
  | Some i -> i
  | None ->
      let i = List.length !types_ref in
	      types_ref := !types_ref @ [ func_type_def None { params = !params; results = !results } ];
      i

let split_leading_id body =
  match body with Atom id :: rest when is_id id -> (Some id, rest) | _ -> (None, body)

let split_inline_exports body =
  let exports = ref [] and rest = ref [] in
  List.iter
    (function
      | List [ Atom "export"; Atom name ] -> exports := !exports @ [ name ]
      | x -> rest := !rest @ [ x ])
    body;
  (!exports, !rest)

let parse_limits = function
  | Atom min :: Atom max :: rest when is_int_literal min && is_int_literal max ->
      (int_atom min, Some (int_atom max), rest)
  | Atom min :: rest when is_int_literal min -> (int_atom min, None, rest)
  | _ -> fail "expected limits"

let parse_globaltype = function
  | [ List [ Atom "mut"; t ] ] -> globaltype_term true (valtype_of_sexpr t)
  | [ t ] -> globaltype_term false (valtype_of_sexpr t)
  | _ -> fail "expected global type"

let parse_memory_fields body =
  let id, body = split_leading_id body in
  let inline_exports, body = split_inline_exports body in
  let addrtype, body =
    match body with
    | Atom ("i32" | "i64" as at) :: rest -> (valtype at, rest)
    | _ -> ("I32", body)
  in
  let min, max, rest = parse_limits body in
  match rest with
  | [] -> (id, inline_exports, memtype_term ~addrtype min max, min, max)
  | _ -> fail "unsupported memory declaration"

let parse_table_fields body =
  let id, body = split_leading_id body in
  let inline_exports, body = split_inline_exports body in
  let addrtype, body =
    match body with
    | Atom ("i32" | "i64" as at) :: rest -> (valtype at, rest)
    | _ -> ("I32", body)
  in
  let min, max, rest = parse_limits body in
  let parse_rt = function
    | [ Atom rt ] -> (reftype rt, "REFNULL_(" ^ heaptype rt ^ ")")
    | [ List [ Atom "ref"; Atom "null"; Atom ht ] ] ->
        ( "REF__(NULL, " ^ heaptype ht ^ ")",
          "REFNULL_(" ^ heaptype ht ^ ")" )
    | [ List [ Atom "ref"; Atom ht ] ] ->
        ("REF__(eps, " ^ heaptype ht ^ ")", "REFNULL_(" ^ heaptype ht ^ ")")
    | _ -> fail "unsupported table declaration"
  in
  match rest with
  | _ ->
      let rt, default_ref = parse_rt rest in
      ( id,
        inline_exports,
        tabletype_term ~addrtype min max rt,
        min,
        max,
        rt,
        default_ref )

let parse_tag_fields type_names types_ref fields =
  let id, fields = split_leading_id fields in
  let inline_exports, fields = split_inline_exports fields in
  let typeidx = parse_typeuse type_names types_ref fields in
  (id, inline_exports,
   "WIDX_(" ^ wrap_source_category "Typeidx" (string_of_int typeidx) ^ ")")

let parse_import type_names types_ref func_index tag_index global_index memory_index table_index =
  function
  | List
      [
        Atom "import";
        Atom module_name;
        Atom item_name;
        List (Atom "func" :: fields);
      ] ->
      let id, fields =
        match fields with
        | Atom id :: rest when is_id id -> (Some id, rest)
        | _ -> (None, fields)
      in
      let typeidx = parse_typeuse type_names types_ref fields in
      ImportFunc
        {
          import_module = module_name;
          import_name = item_name;
          import_id = id;
          import_typeidx = typeidx;
          import_wat_index = func_index;
        }
  | List
      [
        Atom "import";
        Atom module_name;
        Atom item_name;
        List (Atom "tag" :: fields);
      ] ->
      let id, _, tagtype = parse_tag_fields type_names types_ref fields in
      ImportTag
        {
          import_module = module_name;
          import_name = item_name;
          import_id = id;
          import_tagtype = tagtype;
          import_wat_index = tag_index;
        }
  | List
      [
        Atom "import";
        Atom module_name;
        Atom item_name;
        List (Atom "global" :: fields);
      ] ->
      let id, fields = split_leading_id fields in
      ImportGlobal
        {
          import_module = module_name;
          import_name = item_name;
          import_id = id;
          import_globaltype = parse_globaltype fields;
          import_wat_index = global_index;
        }
  | List
      [
        Atom "import";
        Atom module_name;
        Atom item_name;
        List (Atom "memory" :: fields);
      ] ->
      let id, _, memtype, min, _ = parse_memory_fields fields in
      ImportMemory
        {
          import_module = module_name;
          import_name = item_name;
          import_id = id;
          import_memtype = memtype;
          import_mem_min = min;
          import_wat_index = memory_index;
        }
  | List
      [
        Atom "import";
        Atom module_name;
        Atom item_name;
        List (Atom "table" :: fields);
      ] ->
      let id, _, tabletype, min, _, _, default_ref = parse_table_fields fields in
      ImportTable
        {
          import_module = module_name;
          import_name = item_name;
          import_id = id;
          import_tabletype = tabletype;
          import_table_min = min;
          import_table_default_ref = default_ref;
          import_wat_index = table_index;
        }
  | List (Atom "import" :: _) ->
      fail "unsupported import declaration"
  | _ -> fail "expected import"

let parse_func type_names types_ref func_names tag_names global_names memory_names table_names
    fresh_type func_index =
  function
  | List (Atom "func" :: body) ->
      let id, body =
        match body with
        | Atom id :: rest when is_id id -> (Some id, rest)
        | _ -> (None, body)
      in
      let rec split_decls type_fields local_decls inline_exports = function
        | List (Atom "export" :: [ Atom name ]) :: rest ->
            split_decls type_fields local_decls (inline_exports @ [ name ]) rest
        | (List [ Atom "type"; _ ] as x) :: rest ->
            split_decls (type_fields @ [ x ]) local_decls inline_exports rest
        | (List (Atom "param" :: _) as x) :: rest ->
            split_decls (type_fields @ [ x ]) local_decls inline_exports rest
        | (List (Atom "result" :: _) as x) :: rest ->
            split_decls (type_fields @ [ x ]) local_decls inline_exports rest
        | (List (Atom "local" :: _) as x) :: rest ->
            split_decls type_fields (local_decls @ [ x ]) inline_exports rest
        | instrs -> (type_fields, local_decls, inline_exports, instrs)
      in
      let type_fields, local_decls, inline_exports, instrs =
        split_decls [] [] [] body
      in
      let typeidx = parse_typeuse type_names types_ref type_fields in
      let local_types = ref [] in
      let local_ids = ref [] in
      let param_ids = ref [] in
      List.iter
        (function
          | List (Atom "param" :: xs) ->
              let ids, _ = read_typed_names xs in
              param_ids := !param_ids @ ids
          | _ -> ())
        type_fields;
      List.iter
        (function
          | List (Atom "local" :: xs) ->
              let ids, ts = read_typed_names xs in
              local_ids := !local_ids @ ids;
              local_types := !local_types @ ts
          | _ -> ())
        local_decls;
      let param_count =
	        match List.nth_opt !types_ref typeidx with
	        | Some { type_func = Some typ; _ } -> List.length typ.params
	        | Some { type_func = None; _ } ->
	            fail ("function references non-function type index " ^ string_of_int typeidx)
	        | None -> fail ("function references missing type index " ^ string_of_int typeidx)
      in
      let named_params =
        !param_ids
        |> List.mapi (fun i id -> Option.map (fun id -> (id, i)) id)
        |> List.filter_map Fun.id
      in
      let named_locals =
        !local_ids
        |> List.mapi (fun i id -> Option.map (fun id -> (id, param_count + i)) id)
        |> List.filter_map Fun.id
      in
      let env =
        make_env ~type_names ~func_names ~tag_names ~global_names ~memory_names ~table_names
          ~local_names:(named_params @ named_locals) ~fresh_type ()
      in
      {
        func_id = id;
        func_typeidx = typeidx;
        func_locals = !local_types;
        func_body = parse_instr_list env instrs;
        func_inline_exports = inline_exports;
        func_wat_index = func_index;
      }
  | _ -> fail "expected func"

let parse_export func_names tag_names global_names memory_names table_names = function
  | List [ Atom "export"; Atom name; List [ Atom "func"; x ] ] ->
      { export_item_name = name; export_item_desc = ExportFunc (resolve_index "func" func_names x) }
  | List [ Atom "export"; Atom name; List [ Atom "tag"; x ] ] ->
      { export_item_name = name; export_item_desc = ExportTag (resolve_index "tag" tag_names x) }
  | List [ Atom "export"; Atom name; List [ Atom "global"; x ] ] ->
      {
        export_item_name = name;
        export_item_desc = ExportGlobal (resolve_index "global" global_names x);
      }
  | List [ Atom "export"; Atom name; List [ Atom "memory"; x ] ] ->
      {
        export_item_name = name;
        export_item_desc = ExportMemory (resolve_index "memory" memory_names x);
      }
  | List [ Atom "export"; Atom name; List [ Atom "table"; x ] ] ->
      {
        export_item_name = name;
        export_item_desc = ExportTable (resolve_index "table" table_names x);
      }
  | List (Atom "export" :: _) ->
      fail "unsupported export declaration"
  | _ -> fail "expected export"

let parse_global tag_names global_names memory_names table_names func_names type_names global_index = function
  | List (Atom "global" :: body) ->
      let id, body = split_leading_id body in
      let inline_exports, body = split_inline_exports body in
      let rec split_type acc = function
        | [] -> fail "global declaration is missing init expression"
        | (List
             (Atom
                ( "i32.const" | "i64.const" | "f32.const" | "f64.const" | "v128.const"
                | "ref.null" | "ref.func" | "global.get" )
             :: _) as x)
          :: rest
        | (Atom
             ( "i32.const" | "i64.const" | "f32.const" | "f64.const" | "v128.const"
             | "ref.null" | "ref.func" | "global.get" ) as x)
          :: rest ->
            (List.rev acc, x :: rest)
        | x :: rest -> split_type (x :: acc) rest
      in
      let type_items, expr_items = split_type [] body in
      let env = make_env ~type_names ~func_names ~tag_names ~global_names ~memory_names ~table_names () in
      {
        global_id = id;
        global_type = parse_globaltype type_items;
        global_init = parse_instr_list env expr_items;
        global_inline_exports = inline_exports;
        global_wat_index = global_index;
      }
  | _ -> fail "expected global"

let parse_memory memory_index = function
  | List (Atom "memory" :: body) ->
      let id, inline_exports, memory_type, _, _ = parse_memory_fields body in
      { memory_id = id; memory_type; memory_inline_exports = inline_exports; memory_wat_index = memory_index }
  | _ -> fail "expected memory"

let parse_table table_index = function
  | List (Atom "table" :: body) ->
      let id, inline_exports, table_type, _, _, _, table_init = parse_table_fields body in
      {
        table_id = id;
        table_type;
        table_init = [ table_init ];
        table_inline_exports = inline_exports;
        table_wat_index = table_index;
      }
  | _ -> fail "expected table"

let parse_tag type_names types_ref tag_index = function
  | List (Atom "tag" :: body) ->
      let id, inline_exports, tag_type = parse_tag_fields type_names types_ref body in
      { tag_id = id; tag_type; tag_inline_exports = inline_exports; tag_wat_index = tag_index }
  | _ -> fail "expected tag"

let parse_data memory_names table_names global_names func_names tag_names type_names = function
  | List (Atom "data" :: body) ->
      let memidx = ref 0 in
      let mode = ref None in
      let bytes = ref [] in
      let env = make_env ~type_names ~func_names ~tag_names ~global_names ~memory_names ~table_names () in
      let rec loop = function
        | [] -> ()
        | List [ Atom "memory"; x ] :: rest ->
            memidx := resolve_index "memory" memory_names x;
            loop rest
        | (List (Atom ("i32.const" | "i64.const" | "global.get") :: _) as expr) :: rest ->
            mode :=
              Some
                ("ACTIVEDATAMODE__(" ^ wrap_source_category "Memidx" (string_of_int !memidx) ^ ", "
                ^ seq (parse_instr_list env [ expr ])
                ^ ")");
            loop rest
        | Atom s :: rest when String.length s >= 2 && s.[0] = '"' ->
            bytes := !bytes @ wat_string_bytes s;
            loop rest
        | _ -> fail "unsupported data segment"
      in
      loop body;
      { data_bytes = !bytes; data_mode = Option.value !mode ~default:"PASSIVE" }
  | _ -> fail "expected data"

let parse_elem memory_names table_names global_names func_names tag_names type_names = function
  | List (Atom "elem" :: body) ->
      let tableidx = ref 0 in
      let mode = ref None in
      let exprs = ref [] in
      let elem_type = ref "REF__(NULL, FUNC)" in
      let saw_segment_body = ref false in
      let env = make_env ~type_names ~func_names ~tag_names ~global_names ~memory_names ~table_names () in
      let rec elem_item = function
        | List [ Atom "item"; item ] -> elem_item item
        | List [ Atom "ref.func"; x ] ->
            "REFFUNC_("
            ^ wrap_source_category "Funcidx"
                (string_of_int (resolve_index "func" func_names x))
            ^ ")"
        | List [ Atom "ref.null"; Atom ht ] -> "REFNULL_(" ^ heaptype ht ^ ")"
        | Atom x when is_id x || is_int_literal x ->
            "REFFUNC_("
            ^ wrap_source_category "Funcidx"
                (string_of_int (resolve_index "func" func_names (Atom x)))
            ^ ")"
        | x -> fail ("unsupported elem item: " ^ atom_or_shape x)
      in
      let rec loop = function
        | [] -> ()
        | Atom id :: rest when is_id id && not !saw_segment_body && not (List.mem_assoc id func_names) ->
            loop rest
        | Atom "declare" :: rest ->
            saw_segment_body := true;
            mode := Some "DECLARE";
            loop rest
        | Atom "func" :: rest ->
            saw_segment_body := true;
            exprs := !exprs @ List.map elem_item rest;
            ()
        | List [ Atom "table"; x ] :: rest ->
            saw_segment_body := true;
            tableidx := resolve_index "table" table_names x;
            loop rest
        | List [ Atom "offset"; expr ] :: rest ->
            saw_segment_body := true;
            mode :=
              Some
                ("ACTIVEELEMMODE__(" ^ wrap_source_category "Tableidx" (string_of_int !tableidx) ^ ", "
                ^ seq (parse_instr_list env [ expr ])
                ^ ")");
            loop rest
        | (List (Atom ("i32.const" | "i64.const" | "global.get") :: _) as expr) :: rest ->
            saw_segment_body := true;
            mode :=
              Some
                ("ACTIVEELEMMODE__(" ^ wrap_source_category "Tableidx" (string_of_int !tableidx) ^ ", "
                ^ seq (parse_instr_list env [ expr ])
                ^ ")");
            loop rest
        | List [ Atom "ref.func"; x ] :: rest ->
            saw_segment_body := true;
            exprs :=
              !exprs
              @ [ "REFFUNC_("
                  ^ wrap_source_category "Funcidx"
                      (string_of_int (resolve_index "func" func_names x))
                  ^ ")" ];
            loop rest
        | List [ Atom "item"; item ] :: rest ->
            saw_segment_body := true;
            exprs := !exprs @ [ elem_item item ];
            loop rest
        | Atom ("funcref" | "externref" | "anyref" | "eqref" | "i31ref" | "structref"
               | "arrayref" as rt)
          :: rest ->
            saw_segment_body := true;
            elem_type := reftype rt;
            loop rest
        | List [ Atom "ref"; Atom "null"; Atom ht ] :: rest ->
            saw_segment_body := true;
            elem_type := "REF__(NULL, " ^ heaptype ht ^ ")";
            loop rest
        | List [ Atom "ref"; Atom ht ] :: rest ->
            saw_segment_body := true;
            elem_type := "REF__(eps, " ^ heaptype ht ^ ")";
            loop rest
        | List [ Atom "ref.null"; Atom ht ] :: rest ->
            saw_segment_body := true;
            exprs := !exprs @ [ "REFNULL_(" ^ heaptype ht ^ ")" ];
            loop rest
        | Atom x :: rest when is_id x || (String.length x > 0 && x.[0] <> '"') ->
            saw_segment_body := true;
            exprs := !exprs @ [ elem_item (Atom x) ];
            loop rest
        | _ -> fail "unsupported elem segment"
      in
      loop body;
      { elem_type = !elem_type; elem_exprs = !exprs; elem_mode = Option.value !mode ~default:"PASSIVE" }
  | _ -> fail "expected elem"

let parse_start func_names = function
  | List [ Atom "start"; x ] -> resolve_index "func" func_names x
  | _ -> fail "expected start"

let load_input ~canonicalize path =
  (* Legacy fallback for --legacy-wat-parser.  The default path below uses the
     official Wasm parser/validator and does not go through WABT. *)
  if path = "-" then read_stdin ()
  else if has_suffix path ".wasm" then (
    let () = require_command "wasm2wat" "for .wasm input" in
    validate_wasm path;
    run_command_capture
      ("wasm2wat " ^ wabt_flags ^ " " ^ Filename.quote path))
  else if canonicalize && has_suffix path ".wat" then (
    require_command "wat2wasm" "to canonicalize .wat input";
    require_command "wasm2wat" "to canonicalize .wat input";
    let tmp = Filename.temp_file "spec2maude-wat-" ".wasm" in
    Fun.protect
      ~finally:(fun () -> try Sys.remove tmp with Sys_error _ -> ())
      (fun () ->
        let code, stderr =
          run_status_capture_stderr
          ("wat2wasm " ^ wabt_flags ^ " " ^ Filename.quote path ^ " -o "
         ^ Filename.quote tmp ^ " >/dev/null")
        in
        if code = 0 then (
          validate_wasm tmp;
          run_command_capture
            ("wasm2wat " ^ wabt_flags ^ " " ^ Filename.quote tmp))
        else if contains_sub stderr "unexpected token" then
          (* The installed WABT can lag proposal syntax used by wasm-3.0
             examples.  Prefer wasm-tools when available, then fall back to
             source-shaped parsing for syntax gaps; do not hide validation/type
             errors that WABT reports with a more specific message. *)
          if command_exists "wasm-tools" then
            let code2, stderr2 =
              run_status_capture_stderr
                ("wasm-tools parse -t " ^ Filename.quote path ^ " >/dev/null")
            in
            if code2 = 0 then
              run_command_capture ("wasm-tools parse -t " ^ Filename.quote path)
            else if contains_sub stderr2 "extra tokens remaining" then read_file path
            else fail ("wasm-tools rejected WAT: " ^ first_line stderr2)
          else read_file path
        else fail ("wat2wasm rejected invalid WAT: " ^ first_line stderr)))
  else read_file path

let parse_import_func_binding type_names body =
  let eq =
    match String.index_opt body '=' with
    | Some i -> i
    | None -> fail "--import-func expects MODULE.NAME=INSTRUCTIONS"
  in
  let lhs = String.sub body 0 eq in
  let rhs = String.sub body (eq + 1) (String.length body - eq - 1) in
  let dot =
    match String.rindex_opt lhs '.' with
    | Some i -> i
    | None -> fail "--import-func expects MODULE.NAME=INSTRUCTIONS"
  in
  let module_name = String.sub lhs 0 dot in
  let item_name = String.sub lhs (dot + 1) (String.length lhs - dot - 1) in
  let env = make_env ~type_names () in
  {
    binding_module = module_name;
    binding_name = item_name;
    binding_body = parse_instr_list env (parse_many (tokenize rhs));
  }

let parse_import_global_binding body =
  let eq =
    match String.index_opt body '=' with
    | Some i -> i
    | None -> fail "--import-global expects MODULE.NAME=VALUE"
  in
  let lhs = String.sub body 0 eq in
  let rhs = String.sub body (eq + 1) (String.length body - eq - 1) in
  let dot =
    match String.rindex_opt lhs '.' with
    | Some i -> i
    | None -> fail "--import-global expects MODULE.NAME=VALUE"
  in
  let module_name = String.sub lhs 0 dot in
  let item_name = String.sub lhs (dot + 1) (String.length lhs - dot - 1) in
  let env = make_env () in
  let value = seq (parse_instr_list env (parse_many (tokenize rhs))) in
  {
    global_binding_module = module_name;
    global_binding_name = item_name;
    global_binding_value = value;
  }

let parse_int_auto s =
  let s = String.trim s in
  if starts_with s "0x" || starts_with s "0X" then
    int_of_string s
  else int_of_string s

let parse_byte_list s =
  String.split_on_char ',' s
  |> List.filter_map (fun item ->
         let item = String.trim item in
         if item = "" then None
         else
           let b = parse_int_auto item in
           if b < 0 || b > 255 then fail "--memory byte values must be in 0..255";
           Some b)

let parse_memory_overlay body =
  match String.split_on_char ':' body with
  | [ offset; bytes ] ->
      let overlay_bytes = parse_byte_list bytes in
      {
        overlay_offset = parse_int_auto offset;
        overlay_bytes;
      }
  | _ -> fail "memory overlay expects OFFSET:BYTE,..."

let split_memory_base_and_overlays rhs =
  match String.split_on_char '@' (String.trim rhs) with
  | [] -> ("", [])
  | base :: overlays -> (base, List.map parse_memory_overlay overlays)

let parse_import_memory_binding body =
  let eq =
    match String.index_opt body '=' with
    | Some i -> i
    | None -> fail "--import-memory expects MODULE.NAME=PAGES"
  in
  let lhs = String.sub body 0 eq in
  let rhs = String.sub body (eq + 1) (String.length body - eq - 1) in
  let rhs_base, overlays = split_memory_base_and_overlays rhs in
  let dot =
    match String.rindex_opt lhs '.' with
    | Some i -> i
    | None -> fail "--import-memory expects MODULE.NAME=PAGES"
  in
  {
    memory_binding_module = String.sub lhs 0 dot;
    memory_binding_name = String.sub lhs (dot + 1) (String.length lhs - dot - 1);
    memory_binding_pages =
      (match String.split_on_char '/' (String.trim rhs_base) with
      | pages :: _ -> int_of_string pages
      | [] -> fail "--import-memory expects MODULE.NAME=PAGES[/MAX]");
    memory_binding_max =
      (match String.split_on_char '/' (String.trim rhs_base) with
      | [ _; max_pages ] -> Some (int_of_string max_pages)
      | _ -> None);
    memory_binding_overlays = overlays;
  }

let parse_memory_data_binding body =
  let eq =
    match String.index_opt body '=' with
    | Some i -> i
    | None -> fail "--memory-data expects MEMORY=OFFSET:BYTE,..."
  in
  let lhs = String.sub body 0 eq |> String.trim in
  let rhs = String.sub body (eq + 1) (String.length body - eq - 1) in
  let _, overlays = split_memory_base_and_overlays ("@" ^ rhs) in
  if lhs = "" then fail "--memory-data expects MEMORY=OFFSET:BYTE,...";
  { memory_data_name = lhs; memory_data_overlays = overlays }

let parse_table_overlay body =
  match String.index_opt body ':' with
  | Some i ->
      let offset = String.sub body 0 i |> String.trim |> parse_int_auto in
      let refs =
        String.sub body (i + 1) (String.length body - i - 1)
        |> String.split_on_char ','
        |> List.map String.trim
        |> List.filter (fun s -> s <> "")
      in
      if refs = [] then fail "table overlay expects OFFSET:REF";
      { table_overlay_offset = offset; table_overlay_refs = refs }
  | None -> fail "table overlay expects OFFSET:REF"

let parse_table_data_binding body =
  let eq =
    match String.index_opt body '=' with
    | Some i -> i
    | None -> fail "--table-data expects TABLE=OFFSET:REF[@OFFSET:REF]"
  in
  let lhs = String.sub body 0 eq |> String.trim in
  let rhs = String.sub body (eq + 1) (String.length body - eq - 1) in
  let overlays =
    rhs |> String.split_on_char '@' |> List.map String.trim
    |> List.filter (fun s -> s <> "")
    |> List.map parse_table_overlay
  in
  if lhs = "" || overlays = [] then fail "--table-data expects TABLE=OFFSET:REF[@OFFSET:REF]";
  { table_data_name = lhs; table_data_overlays = overlays }

let parse_state_func_binding body =
  let parts = String.split_on_char '|' body |> List.map String.trim in
  let pick prefix =
    let plen = String.length prefix in
    List.find_map
      (fun part ->
        if String.length part >= plen && String.sub part 0 plen = prefix then
          Some (String.sub part plen (String.length part - plen) |> String.trim)
        else None)
      parts
  in
  match (pick "type=", pick "locals=", pick "body=") with
  | Some state_func_type, Some state_func_locals, Some state_func_body ->
      { state_func_type; state_func_locals; state_func_body }
  | _ -> (
      match parts with
      | [ state_func_type; state_func_locals; state_func_body ] ->
          { state_func_type; state_func_locals; state_func_body }
      | _ -> fail "--state-func expects type=TYPE|locals=LOCALS|body=BODY")

let maude_arg_term typ value =
  let ref_heaptype = function
    | "funcref" -> "FUNC"
    | "externref" -> "EXTERN"
    | "anyref" -> "ANY"
    | "eqref" -> "WEQ"
    | "i31ref" -> "I31"
    | "structref" -> "STRUCT"
    | "arrayref" -> "ARRAY"
    | "exnref" -> "EXN"
    | t -> fail ("unsupported reference arg type: " ^ t)
  in
  let compact =
  match typ with
  | "i32" -> i32_const value
  | "i64" -> i64_const value
  | "f32" -> float_arg_const 32 value
  | "f64" -> float_arg_const 64 value
  | "v128" ->
      let lanes =
        value
        |> String.map (fun c -> if c = ',' || c = '[' || c = ']' || c = '\'' then ' ' else c)
        |> String.split_on_char ' '
        |> List.map String.trim
        |> List.filter (fun s -> s <> "")
      in
      "VCONST__(V128, $v128lanes(" ^ seq lanes ^ "))"
  | ( "funcref" | "externref" | "anyref" | "eqref" | "i31ref" | "structref"
    | "arrayref" | "exnref" ) when value = "null" ->
      "REFNULL_(" ^ ref_heaptype typ ^ ")"
  | "funcref" -> "REFFUNCADDR_(" ^ value ^ ")"
  | "externref" -> "REFEXTERN_(REFHOSTADDR_(" ^ value ^ "))"
  | "anyref" -> "REFHOSTADDR_(" ^ value ^ ")"
  | "eqref" -> "REFI31NUM_(" ^ value ^ ")"
  | "i31ref" -> "REFI31NUM_(" ^ value ^ ")"
  | "structref" -> "REFSTRUCTADDR_(" ^ value ^ ")"
  | "arrayref" -> "REFARRAYADDR_(" ^ value ^ ")"
  | "exnref" -> "REFEXNADDR_(" ^ value ^ ")"
  | _ -> fail ("unsupported invoke arg type: " ^ typ)
  in
  source_surface_syntax_of_compact compact

let parse_prelude_call body =
  let parts = String.split_on_char ';' body |> List.map String.trim in
  let target, args_part, drop_part =
    match parts with
    | [ target ] -> (target, "", "")
    | [ target; args ] -> (target, args, "")
    | [ target; args; drop ] -> (target, args, drop)
    | _ -> fail "--prelude-call expects FIELD;TYPE=VALUE,...;drop=N"
  in
  let prelude_field, prelude_funcidx =
    let index_prefix = "@index=" in
    if starts_with target index_prefix then
      ( None,
        Some
          (int_of_string
             (String.sub target (String.length index_prefix)
                (String.length target - String.length index_prefix))) )
    else (Some target, None)
  in
  let prelude_args =
    if args_part = "" then []
    else
      args_part
      |> String.split_on_char ','
      |> List.filter_map (fun item ->
             let item = String.trim item in
             if item = "" then None
             else
               let eq =
                 match String.index_opt item '=' with
                 | Some i -> i
                 | None -> fail "--prelude-call arg expects TYPE=VALUE"
               in
               let typ = String.sub item 0 eq |> String.trim in
               let value =
                 String.sub item (eq + 1) (String.length item - eq - 1)
                 |> String.trim
               in
               Some (maude_arg_term typ value))
  in
  let prelude_drop_count =
    if drop_part = "" then 0
    else
      let prefix = "drop=" in
      if starts_with drop_part prefix then
        int_of_string (String.sub drop_part (String.length prefix) (String.length drop_part - String.length prefix))
      else fail "--prelude-call drop expects drop=N"
  in
  { prelude_field; prelude_funcidx; prelude_args; prelude_drop_count }

let parse_module ?invoke_index text =
  match parse (tokenize text) with
  | List (Atom "module" :: fields) ->
      let type_decls =
        fields
        |> List.filter (function List (Atom "type" :: _) -> true | _ -> false)
        |> List.map read_type_decl
      in
      let types_ref = ref type_decls in
      let type_names =
        type_decls
	        |> List.mapi (fun i typ -> Option.map (fun id -> (id, i)) typ.type_id)
        |> List.filter_map Fun.id
      in
      let func_index = ref 0
      and tag_index = ref 0
      and global_index = ref 0
      and memory_index = ref 0
      and table_index = ref 0 in
      let imports_raw = ref [] in
      let funcs_raw = ref [] in
      let tags_raw = ref [] in
      let globals_raw = ref [] in
      let memories_raw = ref [] in
      let tables_raw = ref [] in
      let datas_raw = ref [] in
      let elems_raw = ref [] in
      let starts_raw = ref [] in
      let func_names = ref [] in
      let tag_names = ref [] in
      let global_names = ref [] in
      let memory_names = ref [] in
      let table_names = ref [] in
      List.iter
        (function
          | List (Atom "import" :: _) as form ->
              let import =
                parse_import type_names types_ref !func_index !tag_index !global_index !memory_index
                  !table_index form
              in
              imports_raw := !imports_raw @ [ import ];
              (match import with
              | ImportFunc im ->
                  (match im.import_id with
                  | Some id -> func_names := (id, !func_index) :: !func_names
                  | None -> ());
                  incr func_index
              | ImportTag im ->
                  (match im.import_id with
                  | Some id -> tag_names := (id, !tag_index) :: !tag_names
                  | None -> ());
                  incr tag_index
              | ImportGlobal im ->
                  (match im.import_id with
                  | Some id -> global_names := (id, !global_index) :: !global_names
                  | None -> ());
                  incr global_index
              | ImportMemory im ->
                  (match im.import_id with
                  | Some id -> memory_names := (id, !memory_index) :: !memory_names
                  | None -> ());
                  incr memory_index
              | ImportTable im ->
                  (match im.import_id with
                  | Some id -> table_names := (id, !table_index) :: !table_names
                  | None -> ());
                  incr table_index)
          | List (Atom "func" :: body) as form ->
              (match body with
              | Atom id :: _ when is_id id -> func_names := (id, !func_index) :: !func_names
              | _ -> ());
              funcs_raw := !funcs_raw @ [ (!func_index, form) ];
              incr func_index
          | List (Atom "tag" :: body) as form ->
              (match body with
              | Atom id :: _ when is_id id -> tag_names := (id, !tag_index) :: !tag_names
              | _ -> ());
              tags_raw := !tags_raw @ [ (!tag_index, form) ];
              incr tag_index
          | List (Atom "global" :: body) as form ->
              (match body with
              | Atom id :: _ when is_id id -> global_names := (id, !global_index) :: !global_names
              | _ -> ());
              globals_raw := !globals_raw @ [ (!global_index, form) ];
              incr global_index
          | List (Atom "memory" :: body) as form ->
              (match body with
              | Atom id :: _ when is_id id -> memory_names := (id, !memory_index) :: !memory_names
              | _ -> ());
              memories_raw := !memories_raw @ [ (!memory_index, form) ];
              incr memory_index
          | List (Atom "table" :: body) as form ->
              (match body with
              | Atom id :: _ when is_id id -> table_names := (id, !table_index) :: !table_names
              | _ -> ());
              tables_raw := !tables_raw @ [ (!table_index, form) ];
              incr table_index
          | List (Atom "data" :: _) as form -> datas_raw := !datas_raw @ [ form ]
          | List (Atom "elem" :: _) as form -> elems_raw := !elems_raw @ [ form ]
          | List (Atom "start" :: _) as form -> starts_raw := !starts_raw @ [ form ]
          | _ -> ())
        fields;
      let func_names = List.rev !func_names in
      let tag_names = List.rev !tag_names in
      let global_names = List.rev !global_names in
      let memory_names = List.rev !memory_names in
      let table_names = List.rev !table_names in
      let fresh_type typ =
        let i = List.length !types_ref in
	        types_ref := !types_ref @ [ func_type_def None typ ];
        i
      in
      let funcs =
        !funcs_raw
        |> List.map (fun (i, form) ->
               parse_func type_names types_ref func_names tag_names global_names memory_names
                 table_names fresh_type i form)
      in
      let tags =
        !tags_raw |> List.map (fun (i, form) -> parse_tag type_names types_ref i form)
      in
      let globals =
        !globals_raw
        |> List.map (fun (i, form) ->
               parse_global tag_names global_names memory_names table_names func_names type_names i
                 form)
      in
      let memories = !memories_raw |> List.map (fun (i, form) -> parse_memory i form) in
      let tables = !tables_raw |> List.map (fun (i, form) -> parse_table i form) in
      let datas =
        !datas_raw
        |> List.map (parse_data memory_names table_names global_names func_names tag_names type_names)
      in
      let elems =
        !elems_raw
        |> List.map (parse_elem memory_names table_names global_names func_names tag_names type_names)
      in
      let start =
        match !starts_raw with
        | [] -> None
        | [ form ] -> Some (parse_start func_names form)
        | _ -> fail "multiple start declarations are not supported"
      in
      let top_exports =
        fields
        |> List.filter (function List (Atom "export" :: _) -> true | _ -> false)
        |> List.map (parse_export func_names tag_names global_names memory_names table_names)
      in
      let inline_exports =
        funcs
        |> List.concat_map (fun fn ->
               List.map
                 (fun name ->
                   { export_item_name = name; export_item_desc = ExportFunc fn.func_wat_index })
                 fn.func_inline_exports)
      in
      let inline_global_exports =
        globals
        |> List.concat_map (fun g ->
               List.map
                 (fun name ->
                   { export_item_name = name; export_item_desc = ExportGlobal g.global_wat_index })
                 g.global_inline_exports)
      in
      let inline_tag_exports =
        tags
        |> List.concat_map (fun t ->
               List.map
                 (fun name ->
                   { export_item_name = name; export_item_desc = ExportTag t.tag_wat_index })
                 t.tag_inline_exports)
      in
      let inline_memory_exports =
        memories
        |> List.concat_map (fun m ->
               List.map
                 (fun name ->
                   { export_item_name = name; export_item_desc = ExportMemory m.memory_wat_index })
                 m.memory_inline_exports)
      in
      let inline_table_exports =
        tables
        |> List.concat_map (fun t ->
               List.map
                 (fun name ->
                   { export_item_name = name; export_item_desc = ExportTable t.table_wat_index })
                 t.table_inline_exports)
      in
      let exports =
        top_exports @ inline_exports @ inline_tag_exports @ inline_global_exports
        @ inline_memory_exports @ inline_table_exports
      in
      let invoke_index =
        match invoke_index with
        | Some i -> Some i
        | None -> (
            match
              List.find_map
                (function
                  | { export_item_desc = ExportFunc i; _ } -> Some i
                  | _ -> None)
                exports
            with
            | Some i -> Some i
            | None -> if !func_index > 0 then Some 0 else None)
      in
      {
        types = !types_ref;
        imports = !imports_raw;
        funcs;
        tags;
        globals;
        memories;
        tables;
        datas;
        elems;
        start;
        exports;
        invoke_index;
      }
  | _ -> fail "expected top-level (module ...)"

module Official = struct
  module A = Wasm.Ast
  module T = Wasm.Types
  module V = Wasm.Value
  module P = Wasm.Pack
  module S = Wasm.Source
  module Script = Wasm.Script

  let it = S.it

  let i32_index x = Int32.to_int (it x)

  let int64_to_int n =
    let i = Int64.to_int n in
    if Int64.of_int i <> n then fail "integer literal is outside OCaml int range";
    i

  let quote_wat_string s = "\"" ^ String.escaped s ^ "\""

  let name n = quote_wat_string (Wasm.Utf8.encode n)

  let sx_term = function P.S -> "S" | P.U -> "U"

  let pack_bits = function
    | P.Pack8 -> 8
    | P.Pack16 -> 16
    | P.Pack32 -> 32
    | P.Pack64 -> 64

  let limits (lim : T.limits) =
    limits_term (int64_to_int lim.min) (Option.map int64_to_int lim.max)

  let addrtype = function T.I32AT -> "I32" | T.I64AT -> "I64"

  let numtype = function
    | T.I32T -> "I32"
    | T.I64T -> "I64"
    | T.F32T -> "F32"
    | T.F64T -> "F64"

  let vectype = function T.V128T -> "V128"

  let typeuse = function
    | T.Idx x ->
        "WIDX_(" ^ wrap_source_category "Typeidx" (string_of_int (Int32.to_int x)) ^ ")"
    | T.Rec x -> "RECTYPEUSE_(" ^ Int32.to_string x ^ ")"
    | T.Def _ -> fail "unsupported resolved deftype in source type use"

  let rec heaptype = function
    | T.AnyHT -> "ANY"
    | T.NoneHT -> "NONE"
    | T.EqHT -> "WEQ"
    | T.I31HT -> "I31"
    | T.StructHT -> "STRUCT"
    | T.ArrayHT -> "ARRAY"
    | T.FuncHT -> "FUNC"
    | T.NoFuncHT -> "NOFUNC"
    | T.ExnHT -> "EXN"
    | T.NoExnHT -> "NOEXN"
    | T.ExternHT -> "EXTERN"
    | T.NoExternHT -> "NOEXTERN"
    | T.UseHT tu -> typeuse tu
    | T.BotHT -> "BOT"

  and reftype (nul, ht) =
    let nul = match nul with T.NoNull -> "eps" | T.Null -> "NULL" in
    "REF__(" ^ nul ^ ", " ^ heaptype ht ^ ")"

  let valtype = function
    | T.NumT nt -> numtype nt
    | T.VecT vt -> vectype vt
    | T.RefT rt -> reftype rt
    | T.BotT -> "BOT"

	  let packtype = function T.I8T -> "I8" | T.I16T -> "I16"

	  let storagetype = function
	    | T.ValStorageT t -> valtype t
	    | T.PackStorageT t -> packtype t

	  let fieldtype = function
	    | T.FieldT (T.Cons, t) -> storagetype t
	    | T.FieldT (T.Var, t) -> "MUT " ^ storagetype t

		  let comptype = function
		    | T.FuncT (params, results) ->
		        "FUNCARROW__(" ^ valtype_seq (List.map valtype params) ^ ", "
		        ^ valtype_seq (List.map valtype results) ^ ")"
		    | T.StructT fields -> "STRUCT_(" ^ fieldtype_seq (List.map fieldtype fields) ^ ")"
	    | T.ArrayT field -> "ARRAY_(" ^ fieldtype field ^ ")"

	  let final = function T.NoFinal -> "eps" | T.Final -> "FINAL"

		  let subtype (T.SubT (fin, supers, ct)) =
		    "SUB___(" ^ final fin ^ ", " ^ typeuse_seq (List.map typeuse supers) ^ ", " ^ comptype ct
		    ^ ")"

	  let type_def_of_rectype rt =
	    let func =
	      match rt with
	      | T.RecT [ T.SubT (_, _, T.FuncT (params, results)) ] ->
	          Some { params = List.map valtype params; results = List.map valtype results }
	      | _ -> None
	    in
	    {
	      type_id = None;
		      type_term = "TYPE_(REC_(" ^ subtype_seq (List.map subtype (match rt with T.RecT sts -> sts)) ^ "))";
	      type_func = func;
	    }

  let globaltype = function
    | T.GlobalT (T.Cons, t) -> valtype t
    | T.GlobalT (T.Var, t) -> "MUT " ^ valtype t

  let memtype = function
    | T.MemoryT (at, lim) -> "PAGE__(" ^ addrtype at ^ ", " ^ limits lim ^ ")"

  let tabletype = function
    | T.TableT (at, lim, rt) -> addrtype at ^ " " ^ limits lim ^ " " ^ reftype rt

  let tagtype = function T.TagT tu -> typeuse tu

  let blocktype = function
    | A.VarBlockType x ->
        "WIDX_(" ^ wrap_source_category "Typeidx" (string_of_int (i32_index x)) ^ ")"
    | A.ValBlockType None -> "WRESULT_(eps)"
    | A.ValBlockType (Some t) -> "WRESULT_(" ^ valtype t ^ ")"

  let memarg offset =
    memarg_term (Int64.to_string offset)

  let num_const = function
    | V.I32 i -> i32_const (Wasm.I32.to_string_s i)
    | V.I64 i -> i64_const (Wasm.I64.to_string_s i)
    | V.F32 f -> f32_const (Int32.to_string (Wasm.F32.to_bits f))
    | V.F64 f -> f64_const (Int64.to_string (Wasm.F64.to_bits f))

  let int_unop = function
    | A.IntOp.Clz -> "CLZ"
    | A.IntOp.Ctz -> "CTZ"
    | A.IntOp.Popcnt -> "POPCNT"
    | A.IntOp.ExtendS sz -> "EXTEND_(" ^ string_of_int (8 * P.packed_size sz) ^ ")"

  let int_binop = function
    | A.IntOp.Add -> "ADD"
    | A.IntOp.Sub -> "SUBBINOP"
    | A.IntOp.Mul -> "MUL"
    | A.IntOp.Div sx -> "DIVSXBINOP_(" ^ sx_term sx ^ ")"
    | A.IntOp.Rem sx -> "WREM_(" ^ sx_term sx ^ ")"
    | A.IntOp.And -> "WAND"
    | A.IntOp.Or -> "WOR"
    | A.IntOp.Xor -> "XOR"
    | A.IntOp.Shl -> "SHL"
    | A.IntOp.Shr sx -> "SHR_(" ^ sx_term sx ^ ")"
    | A.IntOp.Rotl -> "ROTL"
    | A.IntOp.Rotr -> "ROTR"

  let int_relop = function
    | A.IntOp.Eq -> "WEQ"
    | A.IntOp.Ne -> "NE"
    | A.IntOp.Lt sx -> "LTSXRELOP_(" ^ sx_term sx ^ ")"
    | A.IntOp.Gt sx -> "GTSXRELOP_(" ^ sx_term sx ^ ")"
    | A.IntOp.Le sx -> "LESXRELOP_(" ^ sx_term sx ^ ")"
    | A.IntOp.Ge sx -> "GESXRELOP_(" ^ sx_term sx ^ ")"

  let float_unop = function
    | A.FloatOp.Neg -> "NEGUNOP"
    | A.FloatOp.Abs -> "ABS"
    | A.FloatOp.Ceil -> "CEIL"
    | A.FloatOp.Floor -> "FLOOR"
    | A.FloatOp.Trunc -> "TRUNCUNOP"
    | A.FloatOp.Nearest -> "NEAREST"
    | A.FloatOp.Sqrt -> "SQRT"

  let float_binop = function
    | A.FloatOp.Add -> "ADD"
    | A.FloatOp.Sub -> "SUBBINOP"
    | A.FloatOp.Mul -> "MUL"
    | A.FloatOp.Div -> "DIVBINOP"
    | A.FloatOp.Min -> "MINBINOP"
    | A.FloatOp.Max -> "MAXBINOP"
    | A.FloatOp.CopySign -> "COPYSIGN"

  let float_relop = function
    | A.FloatOp.Eq -> "WEQ"
    | A.FloatOp.Ne -> "NE"
    | A.FloatOp.Lt -> "LTRELOP"
    | A.FloatOp.Gt -> "GTRELOP"
    | A.FloatOp.Le -> "LERELOP"
    | A.FloatOp.Ge -> "GERELOP"

  let testop = function
    | V.I32 A.IntOp.Eqz -> "TESTOP__(I32, EQZ)"
    | V.I64 A.IntOp.Eqz -> "TESTOP__(I64, EQZ)"
    | V.F32 _ | V.F64 _ -> fail "invalid floating-point testop in official AST"

  let unop = function
    | V.I32 op -> "UNOP__(I32, " ^ int_unop op ^ ")"
    | V.I64 op -> "UNOP__(I64, " ^ int_unop op ^ ")"
    | V.F32 op -> "UNOP__(F32, " ^ float_unop op ^ ")"
    | V.F64 op -> "UNOP__(F64, " ^ float_unop op ^ ")"

  let binop = function
    | V.I32 op -> "BINOP__(I32, " ^ int_binop op ^ ")"
    | V.I64 op -> "BINOP__(I64, " ^ int_binop op ^ ")"
    | V.F32 op -> "BINOP__(F32, " ^ float_binop op ^ ")"
    | V.F64 op -> "BINOP__(F64, " ^ float_binop op ^ ")"

  let relop = function
    | V.I32 op -> "RELOP__(I32, " ^ int_relop op ^ ")"
    | V.I64 op -> "RELOP__(I64, " ^ int_relop op ^ ")"
    | V.F32 op -> "RELOP__(F32, " ^ float_relop op ^ ")"
    | V.F64 op -> "RELOP__(F64, " ^ float_relop op ^ ")"

  let cvtop = function
    | V.I32 (A.IntOp.WrapI64) -> "CVTOP___(I32, I64, WRAP)"
    | V.I64 (A.IntOp.ExtendI32 sx) ->
        "CVTOP___(I64, I32, EXTEND_(" ^ sx_term sx ^ "))"
    | V.I32 (A.IntOp.TruncF32 sx) ->
        "CVTOP___(I32, F32, TRUNC_(" ^ sx_term sx ^ "))"
    | V.I32 (A.IntOp.TruncF64 sx) ->
        "CVTOP___(I32, F64, TRUNC_(" ^ sx_term sx ^ "))"
    | V.I64 (A.IntOp.TruncF32 sx) ->
        "CVTOP___(I64, F32, TRUNC_(" ^ sx_term sx ^ "))"
    | V.I64 (A.IntOp.TruncF64 sx) ->
        "CVTOP___(I64, F64, TRUNC_(" ^ sx_term sx ^ "))"
    | V.I32 (A.IntOp.TruncSatF32 sx) ->
        "CVTOP___(I32, F32, TRUNCSAT_(" ^ sx_term sx ^ "))"
    | V.I32 (A.IntOp.TruncSatF64 sx) ->
        "CVTOP___(I32, F64, TRUNCSAT_(" ^ sx_term sx ^ "))"
    | V.I64 (A.IntOp.TruncSatF32 sx) ->
        "CVTOP___(I64, F32, TRUNCSAT_(" ^ sx_term sx ^ "))"
    | V.I64 (A.IntOp.TruncSatF64 sx) ->
        "CVTOP___(I64, F64, TRUNCSAT_(" ^ sx_term sx ^ "))"
    | V.I32 A.IntOp.ReinterpretFloat ->
        "CVTOP___(I32, F32, REINTERPRET)"
    | V.I64 A.IntOp.ReinterpretFloat ->
        "CVTOP___(I64, F64, REINTERPRET)"
    | V.F32 (A.FloatOp.ConvertI32 sx) ->
        "CVTOP___(F32, I32, CONVERT_(" ^ sx_term sx ^ "))"
    | V.F32 (A.FloatOp.ConvertI64 sx) ->
        "CVTOP___(F32, I64, CONVERT_(" ^ sx_term sx ^ "))"
    | V.F64 (A.FloatOp.ConvertI32 sx) ->
        "CVTOP___(F64, I32, CONVERT_(" ^ sx_term sx ^ "))"
    | V.F64 (A.FloatOp.ConvertI64 sx) ->
        "CVTOP___(F64, I64, CONVERT_(" ^ sx_term sx ^ "))"
    | V.F64 A.FloatOp.PromoteF32 -> "CVTOP___(F64, F32, PROMOTE)"
    | V.F32 A.FloatOp.DemoteF64 -> "CVTOP___(F32, F64, DEMOTE)"
    | V.F32 A.FloatOp.ReinterpretInt ->
        "CVTOP___(F32, I32, REINTERPRET)"
    | V.F64 A.FloatOp.ReinterpretInt ->
        "CVTOP___(F64, I64, REINTERPRET)"
    | V.I32 _ | V.I64 _ | V.F32 _ | V.F64 _ ->
        fail "unsupported conversion operator in official AST"

  let load_pack = function
    | None -> "eps"
    | Some (sz, sx') -> "ANY__(" ^ sz_term (pack_bits sz) ^ ", " ^ sx_term sx' ^ ")"

	  let store_pack = function
	    | None -> "eps"
	    | Some sz -> sz_term (pack_bits sz)

	  let idx x = string_of_int (i32_index x)
    let idx_as sort x = wrap_source_category sort (idx x)
    let typeidx x = idx_as "Typeidx" x
    let funcidx x = idx_as "Funcidx" x
    let labelidx x = idx_as "Labelidx" x
    let localidx x = idx_as "Localidx" x
    let globalidx x = idx_as "Globalidx" x
    let tableidx x = idx_as "Tableidx" x
    let memidx x = idx_as "Memidx" x
    let tagidx x = idx_as "Tagidx" x
    let elemidx x = idx_as "Elemidx" x
    let dataidx x = idx_as "Dataidx" x
    let field_u32 x = wrap_source_category "U32" (Int32.to_string x)

	  let catch c =
	    match it c with
	    | A.Catch (tag, label) -> "CATCH__(" ^ tagidx tag ^ ", " ^ labelidx label ^ ")"
	    | A.CatchRef (tag, label) -> "CATCHREF__(" ^ tagidx tag ^ ", " ^ labelidx label ^ ")"
	    | A.CatchAll label -> "CATCHALL_(" ^ labelidx label ^ ")"
	    | A.CatchAllRef label -> "CATCHALLREF_(" ^ labelidx label ^ ")"

	  let initop explicit default x =
	    match x with A.Explicit -> explicit | A.Implicit -> default

	  let optional_sx = function None -> "eps" | Some sx -> sx_term sx

	  let externop = function
	    | A.Internalize -> "ANYCONVERTEXTERN"
	    | A.Externalize -> "EXTERNCONVERTANY"

	  let lower_arranged_instr e =
	    let text = Wasm.Sexpr.to_string 1_000_000 (Wasm.Arrange.instr e) in
	    match parse_many (tokenize text) with
	    | [ sexpr ] -> parse_instr (make_env ()) sexpr
	    | sexprs -> seq (parse_instr_list (make_env ()) sexprs)

	  let rec instr e =
	    match it e with
    | A.Unreachable -> "UNREACHABLE"
    | A.Nop -> "NOP"
    | A.Drop -> "DROP"
    | A.Select None -> "SELECT_(eps)"
	    | A.Select (Some ts) -> "SELECT_(" ^ valtype_seq (List.map valtype ts) ^ ")"
	    | A.Block (bt, es) -> "BLOCK__(" ^ blocktype bt ^ ", " ^ instrs es ^ ")"
	    | A.Loop (bt, es) -> "LOOP__(" ^ blocktype bt ^ ", " ^ instrs es ^ ")"
    | A.If (bt, es1, es2) ->
        "WIFELSE___(" ^ blocktype bt ^ ", " ^ instrs es1 ^ ", " ^ instrs es2 ^ ")"
	    | A.Br x -> "BR_(" ^ labelidx x ^ ")"
	    | A.BrIf x -> "BRIF_(" ^ labelidx x ^ ")"
	    | A.BrTable (xs, x) ->
		        "BRTABLE__(" ^ labelidx_seq (List.map labelidx xs) ^ ", " ^ labelidx x ^ ")"
	    | A.BrOnNull x -> "BRONNULL_(" ^ labelidx x ^ ")"
	    | A.BrOnNonNull x -> "BRONNONNULL_(" ^ labelidx x ^ ")"
	    | A.BrOnCast (x, rt1, rt2) ->
	        "BRONCAST___(" ^ labelidx x ^ ", " ^ reftype rt1 ^ ", " ^ reftype rt2 ^ ")"
	    | A.BrOnCastFail (x, rt1, rt2) ->
	        "BRONCASTFAIL___(" ^ labelidx x ^ ", " ^ reftype rt1 ^ ", " ^ reftype rt2
	        ^ ")"
	    | A.Return -> "RETURN"
	    | A.Call x -> "CALL_(" ^ funcidx x ^ ")"
	    | A.CallRef x -> "CALLREF_(WIDX_(" ^ typeidx x ^ "))"
	    | A.CallIndirect (tx, x) ->
	        "CALLINDIRECT__(" ^ tableidx tx ^ ", WIDX_(" ^ typeidx x ^ "))"
	    | A.ReturnCall x -> "RETURNCALL_(" ^ funcidx x ^ ")"
	    | A.ReturnCallRef x -> "RETURNCALLREF_(WIDX_(" ^ typeidx x ^ "))"
	    | A.ReturnCallIndirect (tx, x) ->
	        "RETURNCALLINDIRECT__(" ^ tableidx tx ^ ", WIDX_(" ^ typeidx x ^ "))"
	    | A.Throw x -> "THROW_(" ^ tagidx x ^ ")"
	    | A.ThrowRef -> "THROWREF"
	    | A.TryTable (bt, cs, es) ->
		        "TRYTABLE___(" ^ blocktype bt ^ ", " ^ catch_seq (List.map catch cs) ^ ", "
		        ^ instrs es ^ ")"
	    | A.LocalGet x -> "LOCALGET_(" ^ localidx x ^ ")"
	    | A.LocalSet x -> "LOCALSET_(" ^ localidx x ^ ")"
	    | A.LocalTee x -> "LOCALTEE_(" ^ localidx x ^ ")"
	    | A.GlobalGet x -> "GLOBALGET_(" ^ globalidx x ^ ")"
	    | A.GlobalSet x -> "GLOBALSET_(" ^ globalidx x ^ ")"
	    | A.TableGet x -> "TABLEGET_(" ^ tableidx x ^ ")"
	    | A.TableSet x -> "TABLESET_(" ^ tableidx x ^ ")"
	    | A.TableSize x -> "TABLESIZE_(" ^ tableidx x ^ ")"
	    | A.TableGrow x -> "TABLEGROW_(" ^ tableidx x ^ ")"
	    | A.TableFill x -> "TABLEFILL_(" ^ tableidx x ^ ")"
	    | A.TableCopy (x1, x2) ->
	        "TABLECOPY__(" ^ tableidx x1 ^ ", " ^ tableidx x2 ^ ")"
	    | A.TableInit (x1, x2) ->
	        "TABLEINIT__(" ^ tableidx x1 ^ ", " ^ elemidx x2 ^ ")"
	    | A.ElemDrop x -> "ELEMDROP_(" ^ elemidx x ^ ")"
    | A.Load (x, op) ->
        "LOAD____(" ^ numtype op.ty ^ ", " ^ load_pack op.pack ^ ", "
	        ^ memidx x ^ ", " ^ memarg op.offset ^ ")"
	    | A.Store (x, op) ->
	        "STORE____(" ^ numtype op.ty ^ ", " ^ store_pack op.pack ^ ", "
	        ^ memidx x ^ ", " ^ memarg op.offset ^ ")"
	    | A.MemorySize x -> "MEMORYSIZE_(" ^ memidx x ^ ")"
	    | A.MemoryGrow x -> "MEMORYGROW_(" ^ memidx x ^ ")"
	    | A.MemoryFill x -> "MEMORYFILL_(" ^ memidx x ^ ")"
	    | A.MemoryCopy (x1, x2) ->
	        "MEMORYCOPY__(" ^ memidx x1 ^ ", " ^ memidx x2 ^ ")"
	    | A.MemoryInit (x1, x2) ->
	        "MEMORYINIT__(" ^ memidx x1 ^ ", " ^ dataidx x2 ^ ")"
	    | A.DataDrop x -> "DATADROP_(" ^ dataidx x ^ ")"
	    | A.RefNull ht -> "REFNULL_(" ^ heaptype ht ^ ")"
	    | A.RefFunc x -> "REFFUNC_(" ^ funcidx x ^ ")"
    | A.RefIsNull -> "REFISNULL"
    | A.RefAsNonNull -> "REFASNONNULL"
    | A.RefTest rt -> "REFTEST_(" ^ reftype rt ^ ")"
    | A.RefCast rt -> "REFCAST_(" ^ reftype rt ^ ")"
    | A.RefEq -> "REFEQ"
    | A.RefI31 -> "REFI31"
    | A.Const n -> num_const (it n)
    | A.Test op -> testop op
    | A.Compare op -> relop op
    | A.Unary op -> unop op
	    | A.Binary op -> binop op
	    | A.Convert op -> cvtop op
	    | A.VecConst _ -> lower_arranged_instr e
	    | A.VecLoad _ | A.VecStore _ | A.VecLoadLane _ | A.VecStoreLane _ | A.VecTest _
	    | A.VecCompare _ | A.VecUnary _ | A.VecBinary _ | A.VecTernary _
	    | A.VecConvert _ | A.VecShift _ | A.VecBitmask _ | A.VecTestBits _
	    | A.VecUnaryBits _ | A.VecBinaryBits _ | A.VecTernaryBits _ | A.VecSplat _
	    | A.VecExtract _ | A.VecReplace _ ->
	        lower_arranged_instr e
	    | A.I31Get sx -> "I31GET_(" ^ sx_term sx ^ ")"
	    | A.StructNew (x, op) ->
	        initop ("STRUCTNEW_(" ^ typeidx x ^ ")")
	          ("STRUCTNEWDEFAULT_(" ^ typeidx x ^ ")") op
	    | A.StructGet (x, field, sx) ->
	        "STRUCTGET___(" ^ optional_sx sx ^ ", " ^ typeidx x ^ ", "
          ^ field_u32 field
	        ^ ")"
	    | A.StructSet (x, field) ->
	        "STRUCTSET__(" ^ typeidx x ^ ", " ^ field_u32 field ^ ")"
	    | A.ArrayNew (x, op) ->
	      initop ("ARRAYNEW_(" ^ typeidx x ^ ")")
	          ("ARRAYNEWDEFAULT_(" ^ typeidx x ^ ")") op
	    | A.ArrayNewFixed (x, n) ->
          "ARRAYNEWFIXED__(" ^ typeidx x ^ ", "
          ^ wrap_source_category "U32" (Int32.to_string n) ^ ")"
	    | A.ArrayNewData (x, y) -> "ARRAYNEWDATA__(" ^ typeidx x ^ ", " ^ dataidx y ^ ")"
	    | A.ArrayNewElem (x, y) -> "ARRAYNEWELEM__(" ^ typeidx x ^ ", " ^ elemidx y ^ ")"
	    | A.ArrayGet (x, sx) -> "ARRAYGET__(" ^ optional_sx sx ^ ", " ^ typeidx x ^ ")"
	    | A.ArraySet x -> "ARRAYSET_(" ^ typeidx x ^ ")"
	    | A.ArrayLen -> "ARRAYLEN"
	    | A.ArrayCopy (x, y) -> "ARRAYCOPY__(" ^ typeidx x ^ ", " ^ typeidx y ^ ")"
	    | A.ArrayFill x -> "ARRAYFILL_(" ^ typeidx x ^ ")"
	    | A.ArrayInitData (x, y) -> "ARRAYINITDATA__(" ^ typeidx x ^ ", " ^ dataidx y ^ ")"
	    | A.ArrayInitElem (x, y) -> "ARRAYINITELEM__(" ^ typeidx x ^ ", " ^ elemidx y ^ ")"
	    | A.ExternConvert op -> externop op

	  and instrs es = instr_seq (List.map instr es)

  let const c = instrs (it c)

  let local = function A.Local t -> valtype t

  let segmentmode index_sort = function
    | A.Passive -> "PASSIVE"
    | A.Active (x, c) ->
        let ctor =
          if index_sort = "Memidx" then "ACTIVEDATAMODE__"
          else "ACTIVEELEMMODE__"
        in
        ctor ^ "(" ^ wrap_source_category index_sort (string_of_int (i32_index x))
        ^ ", " ^ const c ^ ")"
    | A.Declarative -> "DECLARE"

  let module_definition_of_file path =
    if has_suffix path ".wasm" then (
      let decoded = Wasm.Decode.decode_with_custom path (read_file path) in
      ignore (Wasm.Valid.check_module_with_custom decoded);
      fst decoded)
    else
      let _, def = Wasm.Parse.Module.parse_file path in
      match it def with
      | Script.Textual (m, custom) ->
          ignore (Wasm.Valid.check_module_with_custom (m, custom));
          m
      | Script.Encoded (_, bytes) ->
          let decoded = Wasm.Decode.decode_with_custom path (it bytes) in
          ignore (Wasm.Valid.check_module_with_custom decoded);
          fst decoded
      | Script.Quoted _ -> fail "quoted WAT modules are not supported"

  let module_ir_of_ast ?invoke_index (m : A.module_) =
	    let types = List.map (fun t -> type_def_of_rectype (it t)) (it m).types in
    let func_import_count = ref 0
    and tag_import_count = ref 0
    and global_import_count = ref 0
    and memory_import_count = ref 0
    and table_import_count = ref 0 in
    let import_desc im =
      let A.Import (module_name, item_name, xt) = it im in
      let module_name = name module_name and item_name = name item_name in
      match xt with
      | T.ExternFuncT (T.Idx x) ->
          let wat_index = !func_import_count in
          incr func_import_count;
          ImportFunc
            {
              import_module = module_name;
              import_name = item_name;
              import_id = None;
              import_typeidx = Int32.to_int x;
              import_wat_index = wat_index;
            }
      | T.ExternFuncT _ -> fail "unsupported resolved function import type"
      | T.ExternTagT tt ->
          let wat_index = !tag_import_count in
          incr tag_import_count;
          ImportTag
            {
              import_module = module_name;
              import_name = item_name;
              import_id = None;
              import_tagtype = tagtype tt;
              import_wat_index = wat_index;
            }
      | T.ExternGlobalT gt ->
          let wat_index = !global_import_count in
          incr global_import_count;
          ImportGlobal
            {
              import_module = module_name;
              import_name = item_name;
              import_id = None;
              import_globaltype = globaltype gt;
              import_wat_index = wat_index;
            }
      | T.ExternMemoryT mt ->
          let wat_index = !memory_import_count in
          incr memory_import_count;
          let T.MemoryT (_, lim) = mt in
          ImportMemory
            {
              import_module = module_name;
              import_name = item_name;
              import_id = None;
              import_memtype = memtype mt;
              import_mem_min = int64_to_int lim.min;
              import_wat_index = wat_index;
            }
      | T.ExternTableT tt ->
          let wat_index = !table_import_count in
          incr table_import_count;
          let T.TableT (_, lim, rt) = tt in
          ImportTable
            {
              import_module = module_name;
              import_name = item_name;
              import_id = None;
              import_tabletype = tabletype tt;
              import_table_min = int64_to_int lim.min;
              import_table_default_ref = "REFNULL_(" ^ heaptype (snd rt) ^ ")";
              import_wat_index = wat_index;
            }
    in
    let imports = List.map import_desc (it m).imports in
    let funcs =
      List.mapi
        (fun i f ->
          let A.Func (typeidx, locals, body) = it f in
          {
            func_id = None;
            func_typeidx = i32_index typeidx;
            func_locals = List.map (fun l -> local (it l)) locals;
            func_body = List.map instr body;
            func_inline_exports = [];
            func_wat_index = !func_import_count + i;
          })
        (it m).funcs
    in
    let tags =
      List.mapi
        (fun i t ->
          let A.Tag tt = it t in
          {
            tag_id = None;
            tag_type = tagtype tt;
            tag_inline_exports = [];
            tag_wat_index = !tag_import_count + i;
          })
        (it m).tags
    in
    let globals =
      List.mapi
        (fun i g ->
          let A.Global (gt, c) = it g in
          {
            global_id = None;
            global_type = globaltype gt;
            global_init = List.map instr (it c);
            global_inline_exports = [];
            global_wat_index = !global_import_count + i;
          })
        (it m).globals
    in
    let memories =
      List.mapi
        (fun i mem ->
          let A.Memory mt = it mem in
          {
            memory_id = None;
            memory_type = memtype mt;
            memory_inline_exports = [];
            memory_wat_index = !memory_import_count + i;
          })
        (it m).memories
    in
    let tables =
      List.mapi
        (fun i tab ->
          let A.Table (tt, init) = it tab in
          {
            table_id = None;
            table_type = tabletype tt;
            table_init = List.map instr (it init);
            table_inline_exports = [];
            table_wat_index = !table_import_count + i;
          })
        (it m).tables
    in
    let datas =
      List.map
        (fun data ->
          let A.Data (bytes, mode) = it data in
          {
            data_bytes = List.of_seq (String.to_seq bytes) |> List.map Char.code;
            data_mode = segmentmode "Memidx" (it mode);
          })
        (it m).datas
    in
    let elems =
      List.map
        (fun elem ->
          let A.Elem (rt, exprs, mode) = it elem in
          {
            elem_type = reftype rt;
            elem_exprs = List.map const exprs;
            elem_mode = segmentmode "Tableidx" (it mode);
          })
        (it m).elems
    in
    let start =
      match (it m).start with
      | None -> None
      | Some s ->
          let A.Start x = it s in
          Some (i32_index x)
    in
    let exports =
      List.map
        (fun ex ->
          let A.Export (n, x) = it ex in
          let export_item_desc =
            match it x with
            | A.FuncX x -> ExportFunc (i32_index x)
            | A.TagX x -> ExportTag (i32_index x)
            | A.GlobalX x -> ExportGlobal (i32_index x)
            | A.MemoryX x -> ExportMemory (i32_index x)
            | A.TableX x -> ExportTable (i32_index x)
          in
          { export_item_name = name n; export_item_desc })
        (it m).exports
    in
    let invoke_index =
      match invoke_index with
      | Some i -> Some i
      | None -> (
          match
            List.find_map
              (function
                | { export_item_desc = ExportFunc i; _ } -> Some i
                | _ -> None)
              exports
          with
          | Some i -> Some i
          | None -> if !func_import_count + List.length funcs > 0 then Some 0 else None)
    in
    {
      types;
      imports;
      funcs;
      tags;
      globals;
      memories;
      tables;
      datas;
      elems;
      start;
      exports;
      invoke_index;
    }

  let module_ir_of_file ?invoke_index path =
    try module_ir_of_ast ?invoke_index (module_definition_of_file path)
    with exn ->
      fail ("official Wasm parser/validator rejected input: " ^ Printexc.to_string exn)
end

let find_import_binding bindings im =
  let module_name = unquote im.import_module in
  let item_name = unquote im.import_name in
  List.find_opt
    (fun b -> b.binding_module = module_name && b.binding_name = item_name)
    bindings

let find_import_global_binding bindings module_name item_name =
  List.find_opt
    (fun b ->
      b.global_binding_module = unquote module_name
      && b.global_binding_name = unquote item_name)
    bindings

let find_import_memory_binding bindings module_name item_name =
  List.find_opt
    (fun b ->
      b.memory_binding_module = unquote module_name
      && b.memory_binding_name = unquote item_name)
    bindings

let membytes_term pages overlays =
  let base = "$zero-membytes(" ^ string_of_int pages ^ ")" in
  overlays
  |> List.filter (fun overlay -> overlay.overlay_bytes <> [])
  |> List.fold_left
       (fun acc overlay ->
         "$mem-bytes(" ^ acc ^ ", " ^ string_of_int overlay.overlay_offset ^ ", "
         ^ string_of_int (List.length overlay.overlay_bytes)
         ^ ", " ^ bytes_seq overlay.overlay_bytes ^ ")")
       base

let memory_index_of_name ir name =
  let raw = unquote name in
  match int_of_string_opt raw with
  | Some i -> i
  | None -> (
      match
        List.find_map
          (fun ex ->
            if unquote ex.export_item_name = raw then
              match ex.export_item_desc with ExportMemory i -> Some i | _ -> None
            else None)
          ir.exports
      with
      | Some i -> i
      | None -> (
          match
            List.find_map
              (fun mem ->
                match mem.memory_id with
                | Some id when id = raw -> Some mem.memory_wat_index
                | _ -> None)
              ir.memories
          with
          | Some i -> i
          | None -> fail ("no memory export or index named " ^ raw)))

let memory_data_terms ir bindings =
  bindings
  |> List.concat_map (fun binding ->
         let memidx = memory_index_of_name ir binding.memory_data_name in
         binding.memory_data_overlays
         |> List.filter (fun overlay -> overlay.overlay_bytes <> [])
         |> List.map (fun overlay ->
                "DATA__(" ^ bytes_seq overlay.overlay_bytes ^ ", ACTIVEDATAMODE__("
                ^ wrap_source_category "Memidx" (string_of_int memidx)
                ^ ", "
                ^ i32_const (string_of_int overlay.overlay_offset)
                ^ "))"))

let table_index_of_name ir name =
  let raw = unquote name in
  match int_of_string_opt raw with
  | Some i -> i
  | None -> (
      match
        List.find_map
          (fun ex ->
            if unquote ex.export_item_name = raw then
              match ex.export_item_desc with ExportTable i -> Some i | _ -> None
            else None)
          ir.exports
      with
      | Some i -> i
      | None -> (
          match
            List.find_map
              (fun table ->
                match table.table_id with
                | Some id when id = raw -> Some table.table_wat_index
                | _ -> None)
              ir.tables
          with
          | Some i -> i
          | None -> fail ("no table export or index named " ^ raw)))

let table_data_terms ir bindings =
  bindings
  |> List.concat_map (fun binding ->
         let tableidx = table_index_of_name ir binding.table_data_name in
         binding.table_data_overlays
         |> List.concat_map (fun overlay ->
                overlay.table_overlay_refs
                |> List.mapi (fun i ref_term ->
                       "ELEM___(REF__(NULL, FUNC), "
                       ^ ref_term ^ ", ACTIVEELEMMODE__("
                       ^ wrap_source_category "Tableidx" (string_of_int tableidx)
                       ^ ", "
                       ^ i32_const
                           (string_of_int (overlay.table_overlay_offset + i))
                       ^ "))")))

let json_escape s =
  let b = Buffer.create (String.length s + 8) in
  String.iter
    (function
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

let json_string s = "\"" ^ json_escape s ^ "\""

let split_top_level_comma s =
  let len = String.length s in
  let rec loop depth start i acc =
    if i >= len then
      List.rev ((String.sub s start (len - start) |> String.trim) :: acc)
    else
      match s.[i] with
      | '(' -> loop (depth + 1) start (i + 1) acc
      | ')' -> loop (max 0 (depth - 1)) start (i + 1) acc
      | ',' when depth = 0 ->
          let part = String.sub s start (i - start) |> String.trim in
          loop depth (i + 1) (i + 1) (part :: acc)
      | _ -> loop depth start (i + 1) acc
  in
  loop 0 0 0 []

let last_int_in_string s =
  let len = String.length s in
  let rec loop i current last =
    if i >= len then
      match current with
      | Some start -> Some (String.sub s start (len - start) |> int_of_string)
      | None -> last
    else
      let c = s.[i] in
      if c >= '0' && c <= '9' then
        loop (i + 1) (match current with Some _ -> current | None -> Some i) last
      else
        let last =
          match current with
          | Some start -> Some (String.sub s start (i - start) |> int_of_string)
          | None -> last
        in
        loop (i + 1) None last
  in
  loop 0 None None

let active_elem_info mode =
  let prefix = "ACTIVEDATAMODE__(" in
  if not (starts_with mode prefix) || String.length mode <= String.length prefix then
    None
  else
    let inside =
      String.sub mode (String.length prefix)
        (String.length mode - String.length prefix - 1)
    in
    match split_top_level_comma inside with
    | [ tableidx_term; offset_term ] -> (
        match (last_int_in_string tableidx_term, last_int_in_string offset_term) with
        | Some tableidx, Some offset -> Some (tableidx, offset)
        | _ -> None)
    | _ -> None

let ref_func_index ref_term =
  let prefix = "REFFUNC_(" in
  if starts_with ref_term prefix then last_int_in_string ref_term else None

let deftype_of_type_term type_term =
  let prefix = "TYPE_(" in
  if starts_with type_term prefix && String.length type_term > String.length prefix then
    let inner =
      String.sub type_term (String.length prefix)
        (String.length type_term - String.length prefix - 1)
    in
    "WDEF__(" ^ inner ^ ", 0)"
  else type_term

let print_state_effects ir =
  let import_func_count =
    ir.imports |> List.filter (function ImportFunc _ -> true | _ -> false) |> List.length
  in
  let func_json =
    ir.funcs
    |> List.mapi (fun local_i fn ->
           let wasm_index = import_func_count + local_i in
           let type_term =
             match List.nth_opt ir.types fn.func_typeidx with
             | Some typ -> deftype_of_type_term typ.type_term
             | None -> "eps"
           in
           "{"
           ^ "\"index\":" ^ string_of_int wasm_index
           ^ ",\"type\":" ^ json_string type_term
           ^ ",\"locals\":" ^ json_string (local_seq (List.map local_decl fn.func_locals))
           ^ ",\"body\":" ^ json_string (instr_seq fn.func_body)
           ^ "}")
    |> String.concat ","
  in
  let table_import_json =
    ir.imports
    |> List.filter_map (function
         | ImportTable im ->
             Some
               ("{\"index\":" ^ string_of_int im.import_wat_index
               ^ ",\"module\":" ^ json_string (unquote im.import_module)
               ^ ",\"name\":" ^ json_string (unquote im.import_name) ^ "}")
         | _ -> None)
    |> String.concat ","
  in
  let table_export_json =
    ir.exports
    |> List.filter_map (fun ex ->
           match ex.export_item_desc with
           | ExportTable i ->
               Some
                 ("{\"name\":" ^ json_string (unquote ex.export_item_name)
                 ^ ",\"index\":" ^ string_of_int i ^ "}")
           | _ -> None)
    |> String.concat ","
  in
  let active_elem_json =
    ir.elems
    |> List.filter_map (fun elem ->
           match active_elem_info elem.elem_mode with
           | None -> None
           | Some (tableidx, offset) ->
               let refs =
                 elem.elem_exprs
                 |> List.map (fun ref_term ->
                        let func_index =
                          match ref_func_index ref_term with
                          | Some i -> string_of_int i
                          | None -> "null"
                        in
                        "{\"term\":" ^ json_string ref_term ^ ",\"func_index\":"
                        ^ func_index ^ "}")
                 |> String.concat ","
               in
               Some
                 ("{\"table\":" ^ string_of_int tableidx
                 ^ ",\"offset\":" ^ string_of_int offset
                 ^ ",\"refs\":[" ^ refs ^ "]}"))
    |> String.concat ","
  in
  print_string
    ("{\"funcs\":[" ^ func_json ^ "],\"table_imports\":["
    ^ table_import_json ^ "],\"table_exports\":[" ^ table_export_json
    ^ "],\"active_elems\":[" ^ active_elem_json ^ "]}\n")

let default_import_global_value globaltype =
  if contains_sub globaltype "I32" then
    i32_const "0"
  else if contains_sub globaltype "I64" then
    i64_const "0"
  else if contains_sub globaltype "F32" then
    f32_const "0"
  else if contains_sub globaltype "F64" then
    f64_const "0"
  else if contains_sub globaltype "V128" then
    "VCONST__(V128, eps)"
  else "REFNULL_(FUNC)"

let default_result_instr = function
  | "i32" -> Some (i32_const "0")
  | "i64" -> Some (i64_const "0")
  | "f32" -> Some (f32_const "0")
  | "f64" -> Some (f64_const "0")
  | "v128" -> Some "VCONST__(V128, 0)"
  | "funcref" -> Some "REFNULL_(FUNC)"
  | "externref" -> Some "REFNULL_(EXTERN)"
  | "anyref" -> Some "REFNULL_(ANY)"
  | "eqref" -> Some "REFNULL_(WEQ)"
  | "i31ref" -> Some "REFNULL_(I31)"
  | "structref" -> Some "REFNULL_(STRUCT)"
  | "arrayref" -> Some "REFNULL_(ARRAY)"
  | _ -> None

let default_import_func_body ir im =
  let module_name = unquote im.import_module in
  let import_name = unquote im.import_name in
  let is_defaultable =
    module_name = "spectest"
    || module_name = "wasi_snapshot_preview1"
    || starts_with module_name "wasi:"
  in
  if not is_defaultable then None
  else
	    match List.nth_opt ir.types im.import_typeidx with
	    | None | Some { type_func = None; _ } -> None
	    | Some { type_func = Some typ; _ } ->
	        let defaults = List.filter_map default_result_instr typ.results in
	        if List.length defaults = List.length typ.results then Some defaults
	        else if import_name = "proc_exit" then Some [ "TRAP" ]
	        else None

let emit_import_runtime func_bindings global_bindings memory_bindings
    state_func_bindings ir type_terms =
  let import_key module_name item_name =
    unquote module_name ^ "\000" ^ unquote item_name
  in
  let unique_by key xs =
    let rec loop seen acc = function
      | [] -> List.rev acc
      | x :: rest ->
          let k = key x in
          if List.mem k seen then loop seen acc rest
          else loop (k :: seen) (x :: acc) rest
    in
    loop [] [] xs
  in
  let index_of_key key xs wanted =
    let rec loop i = function
      | [] -> 0
      | x :: rest -> if key x = wanted then i else loop (i + 1) rest
    in
    loop 0 xs
  in
  let func_imports =
    ir.imports
    |> List.filter_map (function ImportFunc im -> Some im | _ -> None)
  in
  let func_key im = import_key im.import_module im.import_name in
  let unique_func_imports = unique_by func_key func_imports in
  let missing =
    func_imports
    |> List.filter (fun im ->
           find_import_binding func_bindings im = None
           && default_import_func_body ir im = None)
  in
  if missing <> [] then
    let names =
      missing
      |> List.map (fun im -> unquote im.import_module ^ "." ^ unquote im.import_name)
      |> String.concat ", "
    in
    fail ("missing --import-func implementation for: " ^ names)
  else ();
  let state_func_names =
    state_func_bindings
    |> List.map (fun binding ->
           "RECFuncinstA3(" ^ binding.state_func_type ^ ", $empty-moduleinst, "
           ^ "FUNC___(0, " ^ binding.state_func_locals ^ ", "
           ^ binding.state_func_body ^ "))")
  in
  let state_func_count = List.length state_func_names in
  let func_defs =
    unique_func_imports
    |> List.mapi (fun i im ->
           let binding =
             match find_import_binding func_bindings im with
             | Some b -> b.binding_body
             | None -> (
                 match default_import_func_body ir im with
                 | Some body -> body
                 | None -> assert false)
           in
           Printf.sprintf
             {|
  op generated-import-func-%d : -> SpectecTerminal [ctor] .
  eq value('TYPE, generated-import-func-%d) = index(generated-import-deftypes, %d) .
  eq value('MODULE, generated-import-func-%d) = $empty-moduleinst .
  eq value('CODE, generated-import-func-%d) = FUNC___(%s, eps, %s) .
|}
             i i im.import_typeidx i i
             (wrap_source_category "Typeidx" (string_of_int im.import_typeidx))
             (seq binding))
    |> String.concat "\n"
  in
  let func_names =
    state_func_names
    @ (unique_func_imports
      |> List.mapi (fun i _ -> "generated-import-func-" ^ string_of_int i))
    |> seq
  in
  let tag_imports =
    ir.imports |> List.filter (function ImportTag _ -> true | _ -> false)
  in
  let tag_key = function
    | ImportTag im -> import_key im.import_module im.import_name
    | _ -> assert false
  in
  let unique_tag_imports = unique_by tag_key tag_imports in
  let tag_names =
    unique_tag_imports
    |> List.map (function
         | ImportTag im -> "RECTaginstA1(" ^ im.import_tagtype ^ ")"
         | _ -> assert false)
    |> seq
  in
  let global_imports =
    ir.imports |> List.filter (function ImportGlobal _ -> true | _ -> false)
  in
  let global_key = function
    | ImportGlobal im -> import_key im.import_module im.import_name
    | _ -> assert false
  in
  let unique_global_imports = unique_by global_key global_imports in
  let global_names =
    unique_global_imports
    |> List.map (function
         | ImportGlobal im ->
           let value =
             match find_import_global_binding global_bindings im.import_module im.import_name with
             | Some b -> b.global_binding_value
             | None -> default_import_global_value im.import_globaltype
           in
           "RECGlobalinstA2(" ^ im.import_globaltype ^ ", " ^ value ^ ")"
         | _ -> assert false)
    |> seq
  in
  let memory_imports =
    ir.imports |> List.filter (function ImportMemory _ -> true | _ -> false)
  in
  let memory_key = function
    | ImportMemory im -> import_key im.import_module im.import_name
    | _ -> assert false
  in
  let unique_memory_imports = unique_by memory_key memory_imports in
  let memory_names =
    unique_memory_imports
    |> List.map (function
         | ImportMemory im ->
             let binding = find_import_memory_binding memory_bindings im.import_module im.import_name in
             let pages =
               match binding with Some b -> b.memory_binding_pages | None -> im.import_mem_min
             in
             let runtime_memtype =
               match binding with
               | Some b -> memtype_term pages b.memory_binding_max
               | None -> im.import_memtype
             in
             let overlays =
               match binding with Some b -> b.memory_binding_overlays | None -> []
             in
             "RECMeminstA2(" ^ runtime_memtype ^ ", " ^ membytes_term pages overlays ^ ")"
         | _ -> assert false)
    |> seq
  in
  let table_imports =
    ir.imports |> List.filter (function ImportTable _ -> true | _ -> false)
  in
  let table_key = function
    | ImportTable im -> import_key im.import_module im.import_name
    | _ -> assert false
  in
  let unique_table_imports = unique_by table_key table_imports in
  let table_names =
    unique_table_imports
    |> List.map (function
         | ImportTable im ->
           "RECTableinstA2(" ^ im.import_tabletype ^ ", $table-refs("
           ^ string_of_int im.import_table_min ^ ", " ^ im.import_table_default_ref ^ "))"
         | _ -> assert false)
    |> seq
  in
  let externaddrs =
    ir.imports
    |> List.map (function
         | ImportFunc im ->
             let i = index_of_key func_key unique_func_imports (func_key im) in
             "FUNCEXTERNADDR_(" ^ string_of_int (state_func_count + i) ^ ")"
         | ImportTag im ->
             let i = index_of_key tag_key unique_tag_imports (import_key im.import_module im.import_name) in
             "TAGEXTERNADDR_(" ^ string_of_int i ^ ")"
         | ImportGlobal im ->
             let i = index_of_key global_key unique_global_imports (import_key im.import_module im.import_name) in
             "GLOBALEXTERNADDR_(" ^ string_of_int i ^ ")"
         | ImportMemory im ->
             let i = index_of_key memory_key unique_memory_imports (import_key im.import_module im.import_name) in
             "MEMEXTERNADDR_(" ^ string_of_int i ^ ")"
         | ImportTable im ->
             let i = index_of_key table_key unique_table_imports (import_key im.import_module im.import_name) in
             "TABLEEXTERNADDR_(" ^ string_of_int i ^ ")")
    |> seq
  in
  Printf.sprintf
    {|
  op generated-import-deftypes : -> SpectecTerminals .
  eq generated-import-deftypes = $init-deftypes(%s, 0) .
%s
  op generated-import-store : -> Store .
  eq generated-import-store = RECStoreA10(%s, %s, %s, %s, %s, eps, eps, eps, eps, eps) .

  op generated-import-externaddrs : -> SpectecTerminals .
  eq generated-import-externaddrs = %s .
|}
    type_terms func_defs tag_names global_names memory_names table_names func_names externaddrs

let emit_maude ~harness ?(link_imports = false) ?(include_maude_validation = false)
    ?(import_bindings = []) ?(import_global_bindings = []) ?(import_memory_bindings = [])
    ?(memory_data_bindings = []) ?(table_data_bindings = [])
    ?(state_func_bindings = []) ?(prelude_calls = []) ir =
	  let type_terms = ir.types |> List.map (fun typ -> typ.type_term) |> type_seq in
  let has_explicit_import_state =
    import_bindings <> [] || import_global_bindings <> []
    || import_memory_bindings <> [] || state_func_bindings <> []
  in
  let has_linked_base =
    (link_imports || has_explicit_import_state)
    && (ir.imports <> [] || state_func_bindings <> [])
  in
  let import_runtime =
    if not has_linked_base then ""
    else
      emit_import_runtime import_bindings import_global_bindings import_memory_bindings
        state_func_bindings ir type_terms
  in
  let default_base, default_externaddrs =
    if not has_linked_base then ("empty-store", "eps")
    else ("generated-import-store", "generated-import-externaddrs")
  in
  let import_terms =
    ir.imports
    |> List.map (function
         | ImportFunc im ->
             "IMPORT___($wat-name(" ^ maude_qid im.import_module ^ "), $wat-name("
             ^ maude_qid im.import_name ^ "), FUNCEXTERNTYPE_(WIDX_("
             ^ wrap_source_category "Typeidx" (string_of_int im.import_typeidx) ^ ")))"
         | ImportTag im ->
             "IMPORT___($wat-name(" ^ maude_qid im.import_module ^ "), $wat-name("
             ^ maude_qid im.import_name ^ "), TAGEXTERNTYPE_(" ^ im.import_tagtype ^ "))"
         | ImportGlobal im ->
             "IMPORT___($wat-name(" ^ maude_qid im.import_module ^ "), $wat-name("
             ^ maude_qid im.import_name ^ "), GLOBALEXTERNTYPE_(" ^ im.import_globaltype ^ "))"
         | ImportMemory im ->
             "IMPORT___($wat-name(" ^ maude_qid im.import_module ^ "), $wat-name("
             ^ maude_qid im.import_name ^ "), MEMEXTERNTYPE_(" ^ im.import_memtype ^ "))"
         | ImportTable im ->
             "IMPORT___($wat-name(" ^ maude_qid im.import_module ^ "), $wat-name("
             ^ maude_qid im.import_name ^ "), TABLEEXTERNTYPE_(" ^ im.import_tabletype ^ "))")
	    |> import_seq
  in
  let global_terms =
    ir.globals
	    |> List.map (fun g -> "GLOBAL__(" ^ g.global_type ^ ", " ^ instr_seq g.global_init ^ ")")
	    |> global_seq
  in
  let tag_terms =
	    ir.tags |> List.map (fun t -> "TAGTAG_(" ^ t.tag_type ^ ")") |> tag_seq
  in
  let memory_terms =
	    ir.memories |> List.map (fun m -> "MEMORY_(" ^ m.memory_type ^ ")") |> mem_seq
  in
  let table_terms =
    ir.tables
	    |> List.map (fun t -> "TABLE__(" ^ t.table_type ^ ", " ^ instr_seq t.table_init ^ ")")
	    |> table_seq
  in
  let func_terms =
    ir.funcs
    |> List.map (fun fn ->
           "FUNC___(" ^ wrap_source_category "Typeidx" (string_of_int fn.func_typeidx) ^ ", "
	           ^ local_seq (List.map local_decl fn.func_locals)
	           ^ ", " ^ instr_seq fn.func_body ^ ")")
	    |> func_seq
  in
  let source_data_terms =
    ir.datas
    |> List.map (fun d -> "DATA__(" ^ bytes_seq d.data_bytes ^ ", " ^ d.data_mode ^ ")")
  in
  let extra_data_terms = memory_data_terms ir memory_data_bindings in
  let all_data_terms = source_data_terms @ extra_data_terms in
  let all_data_modes =
    List.map (fun d -> d.data_mode) ir.datas
    @ List.map
        (fun term ->
          match sub_index term "ACTIVEDATAMODE__(" with
          | Some _ -> term
          | None -> "")
        extra_data_terms
  in
  let data_terms = data_seq all_data_terms
  in
  let source_elem_terms =
    ir.elems
    |> List.map (fun e ->
	           "ELEM___(" ^ e.elem_type ^ ", " ^ instr_seq e.elem_exprs ^ ", " ^ e.elem_mode ^ ")")
  in
  let extra_elem_terms = table_data_terms ir table_data_bindings in
  let all_elem_terms = source_elem_terms @ extra_elem_terms in
  let elem_terms = elem_seq all_elem_terms
  in
  let start_terms =
    match ir.start with
    | Some i -> "START_(" ^ wrap_source_category "Funcidx" (string_of_int i) ^ ")"
    | None -> "eps"
  in
  let export_terms =
    ir.exports
    |> List.map (fun ex ->
           let desc =
             match ex.export_item_desc with
             | ExportFunc i -> "FUNCEXTERNIDX_(" ^ wrap_source_category "Funcidx" (string_of_int i) ^ ")"
             | ExportTag i -> "TAGEXTERNIDX_(" ^ wrap_source_category "Tagidx" (string_of_int i) ^ ")"
             | ExportGlobal i -> "GLOBALEXTERNIDX_(" ^ wrap_source_category "Globalidx" (string_of_int i) ^ ")"
             | ExportMemory i -> "MEMEXTERNIDX_(" ^ wrap_source_category "Memidx" (string_of_int i) ^ ")"
             | ExportTable i -> "TABLEEXTERNIDX_(" ^ wrap_source_category "Tableidx" (string_of_int i) ^ ")"
           in
           "EXPORT__($wat-name(" ^ maude_qid ex.export_item_name ^ "), " ^ desc ^ ")")
	    |> export_seq
  in
  let import_func_dts =
    ir.imports
    |> List.filter_map (function
         | ImportFunc im ->
             Some ("index(generated-validation-deftypes, " ^ string_of_int im.import_typeidx ^ ")")
         | _ -> None)
  in
  let local_func_dts =
    ir.funcs
    |> List.map (fun fn ->
           "index(generated-validation-deftypes, " ^ string_of_int fn.func_typeidx ^ ")")
  in
  let validation_local_func_dts = seq local_func_dts in
  let validation_functypes = seq (import_func_dts @ local_func_dts) in
  let validation_tagtypes =
    ir.imports
    |> List.filter_map (function ImportTag im -> Some im.import_tagtype | _ -> None)
    |> fun imports -> seq (imports @ List.map (fun t -> t.tag_type) ir.tags)
  in
  let validation_import_tagtypes =
    ir.imports
    |> List.filter_map (function ImportTag im -> Some im.import_tagtype | _ -> None)
    |> seq
  in
  let validation_local_tagtypes = ir.tags |> List.map (fun t -> t.tag_type) |> seq in
  let validation_globaltypes =
    ir.imports
    |> List.filter_map (function ImportGlobal im -> Some im.import_globaltype | _ -> None)
    |> fun imports -> seq (imports @ List.map (fun g -> g.global_type) ir.globals)
  in
  let validation_import_globaltypes =
    ir.imports
    |> List.filter_map (function ImportGlobal im -> Some im.import_globaltype | _ -> None)
    |> seq
  in
  let validation_local_globaltypes =
    ir.globals |> List.map (fun g -> g.global_type) |> seq
  in
  let validation_memtypes =
    ir.imports
    |> List.filter_map (function ImportMemory im -> Some im.import_memtype | _ -> None)
    |> fun imports -> seq (imports @ List.map (fun m -> m.memory_type) ir.memories)
  in
  let validation_import_memtypes =
    ir.imports
    |> List.filter_map (function ImportMemory im -> Some im.import_memtype | _ -> None)
    |> seq
  in
  let validation_local_memtypes =
    ir.memories |> List.map (fun m -> m.memory_type) |> seq
  in
  let validation_tabletypes =
    ir.imports
    |> List.filter_map (function ImportTable im -> Some im.import_tabletype | _ -> None)
    |> fun imports -> seq (imports @ List.map (fun t -> t.table_type) ir.tables)
  in
  let validation_import_tabletypes =
    ir.imports
    |> List.filter_map (function ImportTable im -> Some im.import_tabletype | _ -> None)
    |> seq
  in
  let validation_local_tabletypes =
    ir.tables |> List.map (fun t -> t.table_type) |> seq
  in
  let validation_local_datatypes =
    all_data_terms |> List.map (fun _ -> "OK") |> seq
  in
  let validation_local_elemtypes =
    (ir.elems |> List.map (fun e -> e.elem_type))
    @ List.map (fun _ -> "REF__(NULL, FUNC)") extra_elem_terms
    |> seq
  in
  let validation_export_names =
    ir.exports
    |> List.map (fun ex -> "$wat-name(" ^ maude_qid ex.export_item_name ^ ")")
    |> seq
  in
  let validation_refs =
    collect_ref_func_indices
      (List.concat
         [
           List.concat (List.map (fun g -> g.global_init) ir.globals);
           List.concat (List.map (fun t -> t.table_init) ir.tables);
           all_data_modes;
           List.concat (List.map (fun e -> e.elem_exprs @ [ e.elem_mode ]) ir.elems);
           extra_elem_terms;
         ])
  in
  let import_exttypes =
    ir.imports
    |> List.map (function
         | ImportFunc im ->
             "FUNCEXTERNTYPE_(index(generated-validation-deftypes, "
             ^ string_of_int im.import_typeidx ^ "))"
         | ImportTag im -> "TAGEXTERNTYPE_(" ^ im.import_tagtype ^ ")"
         | ImportGlobal im -> "GLOBALEXTERNTYPE_(" ^ im.import_globaltype ^ ")"
         | ImportMemory im -> "MEMEXTERNTYPE_(" ^ im.import_memtype ^ ")"
         | ImportTable im -> "TABLEEXTERNTYPE_(" ^ im.import_tabletype ^ ")")
    |> seq
  in
  let export_exttype = function
    | ExportFunc i -> "FUNCEXTERNTYPE_(index(generated-validation-functypes, " ^ string_of_int i ^ "))"
    | ExportTag i -> "TAGEXTERNTYPE_(index(generated-validation-tagtypes, " ^ string_of_int i ^ "))"
    | ExportGlobal i ->
        "GLOBALEXTERNTYPE_($typed-index(globaltype, generated-validation-globaltypes, "
        ^ string_of_int i ^ "))"
    | ExportMemory i -> "MEMEXTERNTYPE_(index(generated-validation-memtypes, " ^ string_of_int i ^ "))"
    | ExportTable i ->
        "TABLEEXTERNTYPE_($typed-index(tabletype, generated-validation-tabletypes, "
        ^ string_of_int i ^ "))"
  in
  let export_exttypes =
    ir.exports |> List.map (fun ex -> export_exttype ex.export_item_desc) |> seq
  in
  let funcidx_of_export field =
    ir.exports
    |> List.find_map (fun ex ->
           if unquote ex.export_item_name = field then
             match ex.export_item_desc with ExportFunc i -> Some i | _ -> None
           else None)
    |> function
    | Some i -> i
    | None -> fail ("no function export named " ^ field)
  in
  let call_instr funcidx args drop_count =
    let faddr =
      "index(value('FUNCS, value('MODULE, GEN-F)), " ^ string_of_int funcidx ^ ")"
    in
    let ftype = "value('TYPE, index(value('FUNCS, GEN-S), " ^ faddr ^ "))" in
    seq
      (args
      @ [
          "REFFUNCADDR_(" ^ faddr ^ ")";
          "CALLREF_(" ^ ftype ^ ")";
        ]
      @ List.init drop_count (fun _ -> "DROP"))
  in
  let prelude_terms =
    prelude_calls
    |> List.map (fun call ->
           let funcidx =
             match (call.prelude_funcidx, call.prelude_field) with
             | Some i, _ -> i
             | None, Some field -> funcidx_of_export field
             | None, None -> fail "prelude call has no target"
           in
           call_instr funcidx call.prelude_args call.prelude_drop_count)
    |> String.concat " "
    |> String.trim
  in
  let invoke_index =
    match ir.invoke_index with
    | Some i -> i
    | None -> 0
  in
  let generated =
    Printf.sprintf
    {|load %s

mod WASM-FIB-GENERATED is
  inc WASM-FIB .

  var GEN-NVAL : SpectecTerminal .
  var GEN-S : Store .
  var GEN-F : Frame .
  var GEN-CONFIG : Config .
  var GEN-BASE : Store .
  var GEN-FADDR : Addr .
  var GEN-EXTERNADDRS : SpectecTerminals .
  vars GEN-ARGS GEN-INITS GEN-MODULE GEN-MODULETYPE : SpectecTerminals .
  vars GEN-TYPES GEN-IMPORTS GEN-TAGS GEN-GLOBALS GEN-MEMS GEN-TABLES GEN-FUNCS GEN-DATAS GEN-ELEMS GEN-STARTS GEN-EXPORTS : SpectecTerminals .

	  op generated-fib-module : -> SpectecTerminal .
	  eq generated-fib-module =
	    MODULE___________(
	      %s,
      %s,
      %s,
      %s,
      %s,
      %s,
      %s,
      %s,
      %s,
      %s,
	      %s
	    ) .

	  op generated-module-types : -> SpectecTerminals .
	  eq generated-module-types = %s .

	  op generated-module-imports : -> SpectecTerminals .
	  eq generated-module-imports = %s .

	  op generated-module-tags : -> SpectecTerminals .
	  eq generated-module-tags = %s .

	  op generated-module-globals : -> SpectecTerminals .
	  eq generated-module-globals = %s .

	  op generated-module-mems : -> SpectecTerminals .
	  eq generated-module-mems = %s .

	  op generated-module-tables : -> SpectecTerminals .
	  eq generated-module-tables = %s .

	  op generated-module-funcs : -> SpectecTerminals .
	  eq generated-module-funcs = %s .

	  op generated-module-datas : -> SpectecTerminals .
	  eq generated-module-datas = %s .

	  op generated-module-elems : -> SpectecTerminals .
	  eq generated-module-elems = %s .

	  op generated-module-starts : -> SpectecTerminals .
	  eq generated-module-starts = %s .

	  op generated-module-exports : -> SpectecTerminals .
	  eq generated-module-exports = %s .
%s

	  op generated-base-store : -> Store .
  eq generated-base-store = %s .

  op generated-externaddrs : -> SpectecTerminals .
  eq generated-externaddrs = %s .

  op generated-validation-deftypes : -> SpectecTerminals .
  eq generated-validation-deftypes = $init-deftypes(%s, 0) .

  op generated-validation-functypes : -> SpectecTerminals .
  eq generated-validation-functypes = %s .

  op generated-validation-tagtypes : -> SpectecTerminals .
  eq generated-validation-tagtypes = %s .

  op generated-validation-globaltypes : -> SpectecTerminals .
  eq generated-validation-globaltypes = %s .

  op generated-validation-memtypes : -> SpectecTerminals .
  eq generated-validation-memtypes = %s .

  op generated-validation-tabletypes : -> SpectecTerminals .
  eq generated-validation-tabletypes = %s .

  op generated-validation-import-tagtypes : -> SpectecTerminals .
  eq generated-validation-import-tagtypes = %s .

  op generated-validation-local-tagtypes : -> SpectecTerminals .
  eq generated-validation-local-tagtypes = %s .

  op generated-validation-import-globaltypes : -> SpectecTerminals .
  eq generated-validation-import-globaltypes = %s .

  op generated-validation-local-globaltypes : -> SpectecTerminals .
  eq generated-validation-local-globaltypes = %s .

  op generated-validation-import-memtypes : -> SpectecTerminals .
  eq generated-validation-import-memtypes = %s .

  op generated-validation-local-memtypes : -> SpectecTerminals .
  eq generated-validation-local-memtypes = %s .

  op generated-validation-import-tabletypes : -> SpectecTerminals .
  eq generated-validation-import-tabletypes = %s .

  op generated-validation-local-tabletypes : -> SpectecTerminals .
  eq generated-validation-local-tabletypes = %s .

  op generated-validation-local-functypes : -> SpectecTerminals .
  eq generated-validation-local-functypes = %s .

  op generated-validation-datatypes : -> SpectecTerminals .
  eq generated-validation-datatypes = %s .

  op generated-validation-elemtypes : -> SpectecTerminals .
  eq generated-validation-elemtypes = %s .

  op generated-validation-export-names : -> SpectecTerminals .
  eq generated-validation-export-names = %s .

  op generated-validation-import-context : -> SpectecTerminal .
  eq generated-validation-import-context =
    RECContextA13(generated-validation-deftypes, eps, eps, eps, eps, eps,
      eps, eps, eps, eps, eps, eps, eps) .

  op generated-validation-cq : -> SpectecTerminal .
  eq generated-validation-cq =
    RECContextA13(generated-validation-deftypes, eps, eps,
      generated-validation-import-globaltypes, eps, eps,
      generated-validation-functypes, eps, eps, eps, eps, eps,
      %s) .

  op generated-validation-context : -> SpectecTerminal .
  eq generated-validation-context =
    RECContextA13(generated-validation-deftypes, eps, generated-validation-tagtypes,
      generated-validation-globaltypes, generated-validation-memtypes,
      generated-validation-tabletypes, generated-validation-functypes,
      generated-validation-datatypes, generated-validation-elemtypes,
      eps, eps, eps, %s) .

  op generated-module-type : -> SpectecTerminal .
  eq generated-module-type =
    $clos-moduletype(generated-validation-context, ARROW__(%s, %s)) .

	  op generated-init-config-with : Store SpectecTerminals -> Config .
	  eq generated-init-config-with(GEN-BASE, GEN-EXTERNADDRS) =
	    (($init-store-full(GEN-BASE, generated-module-types, generated-module-imports,
	        generated-module-tags, generated-module-globals, generated-module-mems,
	        generated-module-tables, generated-module-funcs, generated-module-datas,
	        generated-module-elems, generated-module-starts, generated-module-exports,
	        GEN-EXTERNADDRS) ;
	      RECFrameA2(eps, $init-moduleinst-full(GEN-BASE, generated-module-types,
	        generated-module-imports, generated-module-tags, generated-module-globals,
	        generated-module-mems, generated-module-tables, generated-module-funcs,
	        generated-module-datas, generated-module-elems, generated-module-starts,
	        generated-module-exports, GEN-EXTERNADDRS))) ;
	      $init-run-datas(generated-module-datas, 0)
	      $init-run-elems(generated-module-elems, 0)
	      $init-start-instrs(generated-module-starts)) .

  op generated-init-config : -> Config .
  eq generated-init-config =
    generated-init-config-with(generated-base-store, generated-externaddrs) .

  op generated-run-config-with : Store SpectecTerminals SpectecTerminals -> Config .
  ceq generated-run-config-with(GEN-BASE, GEN-EXTERNADDRS, GEN-ARGS) =
    (GEN-S ; GEN-F) ; GEN-INITS %s GEN-ARGS REFFUNCADDR_(GEN-FADDR) CALLREF_(value('TYPE, index(value('FUNCS, GEN-S), GEN-FADDR)))
    if ((GEN-S ; GEN-F) ; GEN-INITS) := generated-init-config-with(GEN-BASE, GEN-EXTERNADDRS)
    /\ GEN-FADDR := index(value('FUNCS, value('MODULE, GEN-F)), %d) .

  ceq steps(generated-run-config-with(GEN-BASE, GEN-EXTERNADDRS, GEN-ARGS)) =
    steps((GEN-S ; GEN-F) ; GEN-INITS %s GEN-ARGS REFFUNCADDR_(GEN-FADDR) CALLREF_(value('TYPE, index(value('FUNCS, GEN-S), GEN-FADDR))))
    if ((GEN-S ; GEN-F) ; GEN-INITS) := generated-init-config-with(GEN-BASE, GEN-EXTERNADDRS)
    /\ GEN-FADDR := index(value('FUNCS, value('MODULE, GEN-F)), %d) .

  op generated-run-config : SpectecTerminals -> Config .
  eq generated-run-config(GEN-ARGS) =
    generated-run-config-with(%s, %s, GEN-ARGS) .

  --- Experimental Maude-internal validation/debug path.
  --- The default tool-chain validates WAT/Wasm before Maude and uses
  --- generated-run-config for execution.
  op generated-checked-run-config-with : Store SpectecTerminals SpectecTerminals -> Config .
  crl [generated-checked-run-config-with] :
    generated-checked-run-config-with(GEN-BASE, GEN-EXTERNADDRS, GEN-ARGS)
    =>
    steps(generated-run-config-with(GEN-BASE, GEN-EXTERNADDRS, GEN-ARGS))
    if Module-ok(generated-fib-module, generated-module-type) => valid .

  crl [generated-module-ok-checked] :
    Module-ok(GEN-MODULE, GEN-MODULETYPE)
    =>
    valid
    if (GEN-MODULE == generated-fib-module) = true
    /\ (GEN-MODULETYPE == generated-module-type) = true
    /\ Types-ok(RECContextA13(eps, eps, eps, eps, eps, eps, eps, eps, eps, eps, eps, eps, eps),
         %s, generated-validation-deftypes) => valid
    /\ Import-oks(generated-validation-import-context, %s, %s) => valid
    /\ Tag-oks(generated-validation-cq, %s, generated-validation-local-tagtypes) => valid
    /\ Globals-ok(generated-validation-cq, %s, generated-validation-local-globaltypes) => valid
    /\ Mem-oks(generated-validation-cq, %s, generated-validation-local-memtypes) => valid
    /\ Table-oks(generated-validation-cq, %s, generated-validation-local-tabletypes) => valid
    /\ Func-oks(generated-validation-context, %s, generated-validation-local-functypes) => valid
    /\ Data-oks(generated-validation-context, %s, generated-validation-datatypes) => valid
    /\ Elem-oks(generated-validation-context, %s, generated-validation-elemtypes) => valid
    /\ Start-ok(generated-validation-context, %s) => valid
    /\ Export-oks(generated-validation-context, %s, generated-validation-export-names, %s) => valid
    /\ $disjoint(name, generated-validation-export-names) = true
    /\ (generated-module-type == $clos-moduletype(generated-validation-context, ARROW__(%s, %s))) = true .

  op generated-checked-run-config : SpectecTerminals -> Config .
  eq generated-checked-run-config(GEN-ARGS) =
    generated-checked-run-config-with(%s, %s, GEN-ARGS) .

  op generated-fib-init-config-with : Store SpectecTerminals SpectecTerminal -> Config .
  eq generated-fib-init-config-with(GEN-BASE, GEN-EXTERNADDRS, GEN-NVAL) =
    generated-run-config-with(GEN-BASE, GEN-EXTERNADDRS, GEN-NVAL i32v(0) i32v(1)) .

  op generated-checked-fib-init-config-with : Store SpectecTerminals SpectecTerminal -> Config .
  eq generated-checked-fib-init-config-with(GEN-BASE, GEN-EXTERNADDRS, GEN-NVAL) =
    generated-checked-run-config-with(GEN-BASE, GEN-EXTERNADDRS, GEN-NVAL i32v(0) i32v(1)) .

  op generated-fib-init-config : SpectecTerminal -> Config .
  eq generated-fib-init-config(GEN-NVAL) =
    generated-fib-init-config-with(%s, %s, GEN-NVAL) .

  op generated-checked-fib-init-config : SpectecTerminal -> Config .
  eq generated-checked-fib-init-config(GEN-NVAL) =
    generated-checked-fib-init-config-with(%s, %s, GEN-NVAL) .
endm
	|}
	    harness type_terms import_terms tag_terms global_terms memory_terms table_terms func_terms
	    data_terms elem_terms start_terms export_terms
	    type_terms import_terms tag_terms global_terms memory_terms table_terms func_terms
	    data_terms elem_terms start_terms export_terms
	    import_runtime default_base default_externaddrs
	    type_terms validation_functypes validation_tagtypes validation_globaltypes
    validation_memtypes validation_tabletypes
    validation_import_tagtypes validation_local_tagtypes
    validation_import_globaltypes validation_local_globaltypes
    validation_import_memtypes validation_local_memtypes
    validation_import_tabletypes validation_local_tabletypes
    validation_local_func_dts validation_local_datatypes validation_local_elemtypes
    validation_export_names
    validation_refs
    validation_refs
    import_exttypes export_exttypes
    prelude_terms
    invoke_index
    prelude_terms
    invoke_index
    default_base default_externaddrs
    type_terms import_terms import_exttypes tag_terms global_terms memory_terms
    table_terms func_terms data_terms elem_terms start_terms export_terms
    export_exttypes import_exttypes export_exttypes
    default_base default_externaddrs default_base default_externaddrs
    default_base default_externaddrs
  in
  if include_maude_validation then generated
  else
    generated
    |> fun s ->
    strip_between s "  op generated-validation-deftypes : -> SpectecTerminals ."
      "  op generated-init-config-with : Store SpectecTerminals -> Config ."
    |> fun s ->
    strip_between s "  --- Experimental Maude-internal validation/debug path."
      "  op generated-fib-init-config-with : Store SpectecTerminals SpectecTerminal -> Config ."
    |> fun s ->
    strip_between s
      "  op generated-checked-fib-init-config-with : Store SpectecTerminals SpectecTerminal -> Config ."
      "  op generated-fib-init-config : SpectecTerminal -> Config ."
    |> fun s ->
    strip_between s "  op generated-checked-fib-init-config : SpectecTerminal -> Config ."
      "endm"

let run_maude_command ~maude ~result_only generated command =
  let file = Filename.temp_file "spec2maude-wat-" ".maude" in
  (* Maude stays interactive after loading a file when stdin is a terminal.
     Add an explicit quit so CLI runs finish in normal shells too. *)
  write_file file (generated ^ command ^ "\nquit\n");
  Fun.protect
    ~finally:(fun () -> try Sys.remove file with Sys_error _ -> ())
    (fun () ->
      let output =
        run_command_capture
          (Filename.quote maude ^ " " ^ Filename.quote file ^ " 2>&1")
      in
      check_maude_output output;
      if result_only then Printf.printf "result: %s\n" (extract_final_value output)
      else print_string output)

let run_maude_fib ~maude ~result_only ~checked ~rewrite_limit generated n =
  let config_term =
    if checked then
      "generated-checked-fib-init-config(i32v(" ^ string_of_int n ^ "))"
    else
      "generated-fib-init-config(i32v(" ^ string_of_int n ^ "))"
  in
  let command =
    if checked then
      "\nrew [" ^ string_of_int rewrite_limit ^ "] in WASM-FIB-GENERATED : "
      ^ config_term ^ " .\n"
    else
      "\nrew [" ^ string_of_int rewrite_limit ^ "] in WASM-FIB-GENERATED : "
      ^ "steps(" ^ config_term ^ ") .\n"
  in
  run_maude_command ~maude ~result_only generated command

let run_maude_main ~maude ~result_only ~checked ~rewrite_limit ?search_expected generated args =
  let arg_terms = seq args in
  let term =
    if checked then
      "generated-checked-run-config(" ^ arg_terms ^ ")"
    else
      "steps(generated-run-config(" ^ arg_terms ^ "))"
  in
  match search_expected with
  | Some expected ->
      let command =
        "\nsearch [1] in WASM-FIB-GENERATED : " ^ term
        ^ " =>* (GENSEARCHZ:State ; " ^ expected ^ ") .\n"
      in
      if result_only then (
        let file = Filename.temp_file "spec2maude-wat-" ".maude" in
        write_file file (generated ^ command ^ "\nquit\n");
        Fun.protect
          ~finally:(fun () -> try Sys.remove file with Sys_error _ -> ())
          (fun () ->
            let output =
              run_command_capture
                (Filename.quote maude ^ " " ^ Filename.quote file ^ " 2>&1")
            in
            check_maude_output output;
            if last_sub_index output "Solution 1" <> None then
              Printf.printf "result: SEARCH-PASS\n"
            else Printf.printf "result: SEARCH-FAIL\n"))
      else run_maude_command ~maude ~result_only generated command
  | None ->
      let command =
        if checked then
          "\nrew [" ^ string_of_int rewrite_limit ^ "] in WASM-FIB-GENERATED : "
          ^ term ^ " .\n"
        else
          "\nrew [" ^ string_of_int rewrite_limit ^ "] in WASM-FIB-GENERATED : "
          ^ term ^ " .\n"
      in
      run_maude_command ~maude ~result_only generated command

let run_maude_validation ~maude ~result_only ~rewrite_limit generated =
  run_maude_command ~maude ~result_only generated
    ("\nrew [" ^ string_of_int rewrite_limit ^ "] in WASM-FIB-GENERATED : Module-ok(generated-fib-module, generated-module-type) .\n")

let usage () =
  prerr_endline
    "usage: wasm_to_maude [--harness FILE] [--output FILE] [--run N] [--run-main] [--run-export NAME] [--maude-validate-only] [--checked-run|--unchecked-run] [--rewrite-limit N] [--arg-i32 N] [--arg-i64 N] [--arg-f32 LIT] [--arg-f64 LIT] [--arg-v128 LANES] [--arg-ref-null REF] [--arg-externref N] [--arg-funcref N] [--arg-anyref N] [--arg-eqref N] [--arg-i31ref N] [--arg-structref N] [--arg-arrayref N] [--arg-exnref N] [--prelude-call FIELD;TYPE=VALUE,...;drop=N] [--maude PATH] [--invoke-index N] [--result-only] [--search-expected TERM] [--legacy-wat-parser] [--no-canonicalize] [--dump-state-effects] [--import-func MODULE.NAME=INSTRUCTIONS] [--import-global MODULE.NAME=VALUE] [--import-memory MODULE.NAME=PAGES[@OFFSET:BYTE,...]] [--memory-data MEMORY=OFFSET:BYTE,...] [--table-data TABLE=OFFSET:REF[@OFFSET:REF]] [--state-func type=TYPE|locals=LOCALS|body=BODY] INPUT.wat|INPUT.wasm";
  exit 2

let () =
  try
    let harness = ref (Filename.concat (Sys.getcwd ()) "wasm-exec.maude") in
    let maude = ref "maude" in
    let output = ref None in
    let run = ref None in
    let run_main = ref false in
    let validate_only = ref false in
    let checked_run = ref false in
    let run_export = ref None in
    let search_expected = ref None in
    let result_only = ref false in
    let arg_terms = ref [] in
    let invoke_index = ref None in
    let canonicalize = ref true in
    let legacy_wat_parser = ref false in
    let import_func_specs = ref [] in
    let import_global_specs = ref [] in
    let import_memory_specs = ref [] in
    let memory_data_specs = ref [] in
    let table_data_specs = ref [] in
    let state_func_specs = ref [] in
    let prelude_calls = ref [] in
    let dump_state_effects = ref false in
    let rewrite_limit = ref 10000 in
    let input = ref None in
    let rec parse_args = function
      | [] -> ()
      | "--harness" :: path :: rest ->
          harness := path;
          parse_args rest
      | "--output" :: path :: rest ->
          output := Some path;
          parse_args rest
      | "--run" :: n :: rest ->
          run := Some (int_of_string n);
          parse_args rest
      | "--run-main" :: rest ->
          run_main := true;
          parse_args rest
      | "--maude-validate-only" :: rest
      | "--validate-only" :: rest ->
          validate_only := true;
          parse_args rest
      | "--checked-run" :: rest ->
          checked_run := true;
          parse_args rest
      | "--unchecked-run" :: rest ->
          checked_run := false;
          parse_args rest
      | "--rewrite-limit" :: n :: rest ->
          rewrite_limit := int_of_string n;
          parse_args rest
      | "--run-export" :: name :: rest ->
          run_main := true;
          run_export := Some (unquote name);
          parse_args rest
      | "--search-expected" :: term :: rest ->
          search_expected := Some term;
          parse_args rest
      | "--arg-i32" :: n :: rest ->
          arg_terms := !arg_terms @ [ maude_arg_term "i32" n ];
          parse_args rest
      | "--arg-i64" :: n :: rest ->
          arg_terms := !arg_terms @ [ maude_arg_term "i64" n ];
          parse_args rest
      | "--arg-f32" :: n :: rest ->
          arg_terms := !arg_terms @ [ maude_arg_term "f32" n ];
          parse_args rest
      | "--arg-f64" :: n :: rest ->
          arg_terms := !arg_terms @ [ maude_arg_term "f64" n ];
          parse_args rest
      | "--arg-v128" :: n :: rest ->
          arg_terms := !arg_terms @ [ maude_arg_term "v128" n ];
          parse_args rest
      | "--arg-ref-null" :: typ :: rest ->
          arg_terms := !arg_terms @ [ maude_arg_term typ "null" ];
          parse_args rest
      | "--arg-externref" :: n :: rest ->
          arg_terms := !arg_terms @ [ maude_arg_term "externref" n ];
          parse_args rest
      | "--arg-funcref" :: n :: rest ->
          arg_terms := !arg_terms @ [ maude_arg_term "funcref" n ];
          parse_args rest
      | "--arg-anyref" :: n :: rest ->
          arg_terms := !arg_terms @ [ maude_arg_term "anyref" n ];
          parse_args rest
      | "--arg-eqref" :: n :: rest ->
          arg_terms := !arg_terms @ [ maude_arg_term "eqref" n ];
          parse_args rest
      | "--arg-i31ref" :: n :: rest ->
          arg_terms := !arg_terms @ [ maude_arg_term "i31ref" n ];
          parse_args rest
      | "--arg-structref" :: n :: rest ->
          arg_terms := !arg_terms @ [ maude_arg_term "structref" n ];
          parse_args rest
      | "--arg-arrayref" :: n :: rest ->
          arg_terms := !arg_terms @ [ maude_arg_term "arrayref" n ];
          parse_args rest
      | "--arg-exnref" :: n :: rest ->
          arg_terms := !arg_terms @ [ maude_arg_term "exnref" n ];
          parse_args rest
      | "--result-only" :: rest ->
          result_only := true;
          parse_args rest
      | "--no-canonicalize" :: rest ->
          canonicalize := false;
          parse_args rest
      | "--legacy-wat-parser" :: rest ->
          legacy_wat_parser := true;
          parse_args rest
      | "--maude" :: path :: rest ->
          maude := path;
          parse_args rest
      | "--invoke-index" :: n :: rest ->
          invoke_index := Some (int_of_string n);
          parse_args rest
      | "--import-func" :: spec :: rest ->
          import_func_specs := !import_func_specs @ [ spec ];
          parse_args rest
      | "--import-global" :: spec :: rest ->
          import_global_specs := !import_global_specs @ [ spec ];
          parse_args rest
      | "--import-memory" :: spec :: rest ->
          import_memory_specs := !import_memory_specs @ [ spec ];
          parse_args rest
      | "--memory-data" :: spec :: rest ->
          memory_data_specs := !memory_data_specs @ [ spec ];
          parse_args rest
      | "--table-data" :: spec :: rest ->
          table_data_specs := !table_data_specs @ [ spec ];
          parse_args rest
      | "--state-func" :: spec :: rest ->
          state_func_specs := !state_func_specs @ [ spec ];
          parse_args rest
      | "--dump-state-effects" :: rest ->
          dump_state_effects := true;
          parse_args rest
      | "--prelude-call" :: spec :: rest ->
          prelude_calls := !prelude_calls @ [ parse_prelude_call spec ];
          parse_args rest
      | [ path ] -> input := Some path
      | _ -> usage ()
    in
    parse_args (List.tl (Array.to_list Sys.argv));
    let input = match !input with Some path -> path | None -> usage () in
    let harness =
      if Filename.is_relative !harness then Filename.concat (Sys.getcwd ()) !harness
      else !harness
    in
    let ir =
      if !legacy_wat_parser then
        parse_module ?invoke_index:!invoke_index (load_input ~canonicalize:!canonicalize input)
      else Official.module_ir_of_file ?invoke_index:!invoke_index input
    in
    let ir =
      match !run_export with
      | None -> ir
      | Some name -> (
          match
            List.find_map
              (fun ex ->
                if unquote ex.export_item_name = name then
                  match ex.export_item_desc with ExportFunc i -> Some i | _ -> None
                else None)
              ir.exports
          with
          | Some i -> { ir with invoke_index = Some i }
          | None -> fail ("no function export named " ^ name))
    in
    if !dump_state_effects then (
      print_state_effects ir;
      exit 0)
    else ();
    let import_bindings =
      !import_func_specs |> List.map (parse_import_func_binding [])
    in
    let import_global_bindings =
      !import_global_specs |> List.map parse_import_global_binding
    in
    let import_memory_bindings =
      !import_memory_specs |> List.map parse_import_memory_binding
    in
    let memory_data_bindings =
      !memory_data_specs |> List.map parse_memory_data_binding
    in
    let table_data_bindings =
      !table_data_specs |> List.map parse_table_data_binding
    in
    let state_func_bindings =
      !state_func_specs |> List.map parse_state_func_binding
    in
    if (!run <> None || !run_main) && ir.invoke_index = None then
      fail "module has no function to invoke"
    else ();
    let missing_func_imports =
      ir.imports
      |> List.filter_map (function ImportFunc im -> Some im | _ -> None)
      |> List.filter (fun im ->
             find_import_binding import_bindings im = None
             && default_import_func_body ir im = None)
    in
    if (!run <> None || !run_main) && missing_func_imports <> [] then
      let names =
        missing_func_imports
        |> List.map (fun im -> unquote im.import_module ^ "." ^ unquote im.import_name)
        |> String.concat ", "
      in
      fail
        ("module has imports; provide function implementations with --import-func"
        ^ if names = "" then "" else " for: " ^ names)
    else ();
    let generated =
      emit_maude ~harness ~link_imports:(!run <> None || !run_main)
        ~include_maude_validation:(!validate_only || !checked_run) ~import_bindings
        ~import_global_bindings ~import_memory_bindings ~memory_data_bindings
        ~table_data_bindings ~state_func_bindings ~prelude_calls:!prelude_calls ir
      |> source_surface_syntax_of_compact
    in
    (match !output with
    | Some path -> write_file path generated
    | None -> if !run = None && not !run_main && not !validate_only then print_string generated);
    if !validate_only then
      run_maude_validation ~maude:!maude ~result_only:!result_only
        ~rewrite_limit:!rewrite_limit generated;
    (match (!run, !run_main) with
    | Some n, false ->
        run_maude_fib ~maude:!maude ~result_only:!result_only ~checked:!checked_run
          ~rewrite_limit:!rewrite_limit generated n
    | None, true ->
        run_maude_main ~maude:!maude ~result_only:!result_only ~checked:!checked_run
          ~rewrite_limit:!rewrite_limit ?search_expected:!search_expected generated !arg_terms
    | None, false -> ()
    | Some _, true -> fail "use either --run or --run-main, not both")
  with
  | Error msg ->
      prerr_endline ("wasm_to_maude: " ^ msg);
      exit 1
  | Failure msg ->
      prerr_endline ("wasm_to_maude: " ^ msg);
      exit 1
  | Sys_error msg ->
      prerr_endline ("wasm_to_maude: " ^ msg);
      exit 1
