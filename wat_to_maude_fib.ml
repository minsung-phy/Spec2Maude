(* Focused WAT-to-Maude frontend for the current C1 execution path.

   This is intentionally not a full WebAssembly parser yet.  It supports the
   focused executable init-config path used by the current C1 work: function
   types, imports, globals, memories, tables, local functions, data/elem
   segments, start, exports, and the instruction forms used by the focused
   runtime smokes.
*)

type sexpr = Atom of string | List of sexpr list

type func_type = { params : string list; results : string list }

type import_func = {
  import_module : string;
  import_name : string;
  import_id : string option;
  import_typeidx : int;
  import_wat_index : int;
}

type import_desc =
  | ImportFunc of import_func
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

type module_ir = {
  types : (string option * func_type) list;
  imports : import_desc list;
  funcs : func_def list;
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

type env = {
  type_names : (string * int) list;
  func_names : (string * int) list;
  global_names : (string * int) list;
  memory_names : (string * int) list;
  table_names : (string * int) list;
  local_names : (string * int) list;
}

exception Error of string

let fail msg = raise (Error msg)

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
  Fun.protect
    ~finally:(fun () ->
      match Unix.close_process_in ic with
      | Unix.WEXITED 0 -> ()
      | _ -> fail ("command failed: " ^ cmd))
    (fun () ->
      (try
         while true do
           Buffer.add_string buf (input_line ic);
           Buffer.add_char buf '\n'
         done
       with End_of_file -> ());
      Buffer.contents buf)

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

let last_sub_index s needle =
  let n = String.length s and m = String.length needle in
  let rec loop i last =
    if i + m > n then last
    else
      let last = if String.sub s i m = needle then Some i else last in
      loop (i + 1) last
  in
  if m = 0 then Some 0 else loop 0 None

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

let extract_final_value output =
  let value =
    match last_sub_index output "CTORCONSTA2(" with
  | Some start -> (
      match String.index_from_opt output start ')' with
      | Some stop -> String.sub output start (stop - start + 1)
      | None -> String.sub output start (String.length output - start))
  | None -> (
      match last_sub_index output "CTORREF" with
      | Some start -> (
          match String.index_from_opt output start ')' with
          | Some stop -> String.sub output start (stop - start + 1)
          | None -> String.sub output start (String.length output - start))
      | None -> String.trim output)
  in
  compact_spaces value

let is_id s = String.length s > 0 && s.[0] = '$'

let rec strip_block_comments text =
  match String.index_opt text '(' with
  | None -> text
  | Some start when start + 1 < String.length text && text.[start + 1] = ';' ->
      let rec find_end i depth =
        if i >= String.length text then fail "unterminated WAT block comment"
        else if i + 1 < String.length text && text.[i] = '(' && text.[i + 1] = ';'
        then find_end (i + 2) (depth + 1)
        else if i + 1 < String.length text && text.[i] = ';' && text.[i + 1] = ')'
        then if depth = 1 then i + 2 else find_end (i + 2) (depth - 1)
        else find_end (i + 1) depth
      in
      let stop = find_end (start + 2) 1 in
      strip_block_comments
        (String.sub text 0 start ^ " "
        ^ String.sub text stop (String.length text - stop))
  | Some start ->
      String.sub text 0 (start + 1)
      ^ strip_block_comments
          (String.sub text (start + 1) (String.length text - start - 1))

let strip_line_comments text =
  text |> String.split_on_char '\n'
  |> List.map (fun line ->
         match String.index_opt line ';' with
         | Some i when i + 1 < String.length line && line.[i + 1] = ';' ->
             String.sub line 0 i
         | _ -> line)
  |> String.concat "\n"

let tokenize text =
  let text = text |> strip_line_comments |> strip_block_comments in
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

let valtype = function
  | "i32" -> "CTORI32A0"
  | "i64" -> "CTORI64A0"
  | "f32" -> "CTORF32A0"
  | "f64" -> "CTORF64A0"
  | "v128" -> "CTORV128A0"
  | t -> fail ("unsupported value type: " ^ t)

let heaptype = function
  | "func" | "funcref" -> "CTORFUNCA0"
  | "extern" | "externref" -> "CTOREXTERNA0"
  | "any" | "anyref" -> "CTORANYA0"
  | "eq" | "eqref" -> "CTORWEQA0"
  | "i31" | "i31ref" -> "CTORI31A0"
  | "struct" | "structref" -> "CTORSTRUCTA0"
  | "array" | "arrayref" -> "CTORARRAYA0"
  | t -> fail ("unsupported heap/ref type: " ^ t)

let reftype = function
  | "funcref" -> "CTORREFA2(CTORNULLA0, CTORFUNCA0)"
  | "externref" -> "CTORREFA2(CTORNULLA0, CTOREXTERNA0)"
  | t when String.length t >= 4 && String.sub t (String.length t - 3) 3 = "ref"
    -> "CTORREFA2(CTORNULLA0, " ^ heaptype t ^ ")"
  | t -> fail ("unsupported reference type: " ^ t)

let limits_term min max_opt =
  "CTORLBRACKDOTDOTRBRACKA2(" ^ string_of_int min ^ ", "
  ^ (match max_opt with Some max -> string_of_int max | None -> "eps")
  ^ ")"

let memtype_term min max_opt =
  "CTORPAGEA2(CTORI32A0, " ^ limits_term min max_opt ^ ")"

let tabletype_term min max_opt rt =
  "CTORI32A0 " ^ limits_term min max_opt ^ " " ^ reftype rt

let globaltype_term mut t =
  if mut then "CTORMUTA0 " ^ valtype t else valtype t

let bytes_seq bytes = seq (List.map string_of_int bytes)

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
  int_of_string (int_arg (Atom s))

let is_int_literal s =
  let n = String.length s in
  let start = if n > 0 && s.[0] = '-' then 1 else 0 in
  let rec loop i =
    i = n
    || (s.[i] >= '0' && s.[i] <= '9' && loop (i + 1))
  in
  n > 0 && start < n && loop start

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
    | Atom id :: Atom t :: rest when is_id id ->
        loop (Some id :: ids) (t :: tys) rest
    | Atom t :: rest ->
        loop (None :: ids) (t :: tys) rest
    | List _ :: _ -> fail "unsupported typed field item"
  in
  loop [] [] xs

let read_func_type_fields fields =
  let params = ref [] and results = ref [] in
  List.iter
    (function
      | List (Atom "param" :: xs) ->
          let _, ts = read_typed_names xs in
          params := !params @ ts
      | List (Atom "result" :: xs) -> results := !results @ List.map atom xs
      | _ -> fail "unsupported function type field")
    fields;
  { params = !params; results = !results }

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
      (id, typ)
  | _ -> fail "expected (type ...)"

let type_term typ =
  let params = seq (List.map valtype typ.params) in
  let results = seq (List.map valtype typ.results) in
  "CTORTYPEA1(CTORRECA1(CTORSUBA3(eps, eps, CTORFUNCARROWA2("
  ^ params ^ ", " ^ results ^ "))))"

let local_decl t = "CTORLOCALA1(" ^ valtype t ^ ")"

let parse_blocktype fields =
  let results = ref [] in
  let rest = ref [] in
  List.iter
    (function
      | List (Atom "result" :: xs) -> results := !results @ List.map atom xs
      | List (Atom "param" :: _) -> fail "block params are not supported in this frontend"
      | x -> rest := !rest @ [ x ])
    fields;
  ("CTORWRESULTA1(" ^ seq (List.map valtype !results) ^ ")", !rest)

let memarg0 = "$memarg0"

let resolve_mem env = function
  | None -> "0"
  | Some x -> string_of_int (resolve_index "memory" env.memory_names x)

let resolve_table env x =
  string_of_int (resolve_index "table" env.table_names x)

let resolve_global env x =
  string_of_int (resolve_index "global" env.global_names x)

let rec parse_instr env = function
  | List (Atom "block" :: body) ->
      let body =
        match body with Atom id :: rest when is_id id -> rest | _ -> body
      in
      let bt, instrs = parse_blocktype body in
      "CTORBLOCKA2(" ^ bt ^ ", " ^ seq (parse_instr_list env instrs) ^ ")"
  | List (Atom "loop" :: body) ->
      let body =
        match body with Atom id :: rest when is_id id -> rest | _ -> body
      in
      let bt, instrs = parse_blocktype body in
      "CTORLOOPA2(" ^ bt ^ ", " ^ seq (parse_instr_list env instrs) ^ ")"
  | List [ Atom head; imm ]
    when List.mem head
           [
             "local.get";
             "local.set";
             "local.tee";
             "global.get";
             "global.set";
             "table.get";
             "table.set";
             "table.size";
             "i32.const";
             "br";
             "br_if";
             "call";
             "call_ref";
             "ref.null";
             "ref.func";
           ] ->
      parse_flat_instr env head (Some imm)
  | List [ Atom head ]
    when List.mem head
           [
             "i32.add";
             "i32.sub";
             "i32.mul";
             "i32.eqz";
             "i32.eq";
             "i32.ne";
             "i32.lt_s";
             "i32.gt_s";
             "i32.le_s";
             "i32.ge_s";
             "i32.load";
             "i32.store";
             "memory.size";
             "memory.grow";
             "drop";
             "return";
           ] ->
      parse_flat_instr env head None
  | List (Atom head :: _) -> fail ("unsupported folded instruction: " ^ head)
  | _ -> fail "empty folded instruction"

and parse_flat_instr env head imm =
  let local x = string_of_int (resolve_index "local" env.local_names x) in
  let func x = string_of_int (resolve_index "func" env.func_names x) in
  match (head, imm) with
  | "local.get", Some x -> "CTORLOCALGETA1(" ^ local x ^ ")"
  | "local.set", Some x -> "CTORLOCALSETA1(" ^ local x ^ ")"
  | "local.tee", Some x -> "CTORLOCALTEEA1(" ^ local x ^ ")"
  | "global.get", Some x -> "CTORGLOBALGETA1(" ^ resolve_global env x ^ ")"
  | "global.set", Some x -> "CTORGLOBALSETA1(" ^ resolve_global env x ^ ")"
  | "table.get", Some x -> "CTORTABLEGETA1(" ^ resolve_table env x ^ ")"
  | "table.set", Some x -> "CTORTABLESETA1(" ^ resolve_table env x ^ ")"
  | "table.size", Some x -> "CTORTABLESIZEA1(" ^ resolve_table env x ^ ")"
  | "memory.size", Some x -> "CTORMEMORYSIZEA1(" ^ resolve_mem env (Some x) ^ ")"
  | "memory.grow", Some x -> "CTORMEMORYGROWA1(" ^ resolve_mem env (Some x) ^ ")"
  | "i32.const", Some x -> "CTORCONSTA2(CTORI32A0, " ^ int_arg x ^ ")"
  | "br", Some x -> "CTORBRA1(" ^ int_arg x ^ ")"
  | "br_if", Some x -> "CTORBRIFA1(" ^ int_arg x ^ ")"
  | "call", Some x -> "CTORCALLA1(" ^ func x ^ ")"
  | "call_ref", Some (List [ Atom "type"; x ]) ->
      "CTORCALLREFA1(CTORWIDXA1(" ^ string_of_int (resolve_index "type" env.type_names x) ^ "))"
  | "call_ref", Some x ->
      "CTORCALLREFA1(CTORWIDXA1(" ^ string_of_int (resolve_index "type" env.type_names x) ^ "))"
  | "ref.null", Some x -> "CTORREFNULLA1(" ^ heaptype (atom x) ^ ")"
  | "ref.func", Some x -> "CTORREFFUNCA1(" ^ func x ^ ")"
  | "i32.add", None -> "CTORBINOPA2(CTORI32A0, CTORADDA0)"
  | "i32.sub", None -> "CTORBINOPA2(CTORI32A0, CTORSUBA0)"
  | "i32.mul", None -> "CTORBINOPA2(CTORI32A0, CTORMULA0)"
  | "i32.eqz", None -> "CTORTESTOPA2(CTORI32A0, CTOREQZA0)"
  | "i32.eq", None -> "CTORRELOPA2(CTORI32A0, CTOREQA0)"
  | "i32.ne", None -> "CTORRELOPA2(CTORI32A0, CTORNEA0)"
  | "i32.lt_s", None -> "CTORRELOPA2(CTORI32A0, CTORLTA1(CTORSA0))"
  | "i32.gt_s", None -> "CTORRELOPA2(CTORI32A0, CTORGTA1(CTORSA0))"
  | "i32.le_s", None -> "CTORRELOPA2(CTORI32A0, CTORLEA1(CTORSA0))"
  | "i32.ge_s", None -> "CTORRELOPA2(CTORI32A0, CTORGEA1(CTORSA0))"
  | "i32.load", None -> "CTORLOADA4(CTORI32A0, eps, 0, " ^ memarg0 ^ ")"
  | "i32.store", None -> "CTORSTOREA4(CTORI32A0, eps, 0, " ^ memarg0 ^ ")"
  | "memory.size", None -> "CTORMEMORYSIZEA1(0)"
  | "memory.grow", None -> "CTORMEMORYGROWA1(0)"
  | "drop", None -> "CTORDROPA0"
  | "return", None -> "CTORRETURNA0"
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
  | Atom "end" :: _ -> fail "unexpected end"
  | List _ as x :: rest -> parse_instr env x :: parse_instr_list env rest
  | Atom head :: imm :: rest
    when List.mem head
           [
             "local.get";
             "local.set";
             "local.tee";
             "global.get";
             "global.set";
             "table.get";
             "table.set";
             "table.size";
             "i32.const";
             "br";
             "br_if";
             "call";
             "call_ref";
             "ref.null";
             "ref.func";
           ] ->
      parse_flat_instr env head (Some imm) :: parse_instr_list env rest
  | Atom head :: rest
    when List.mem head
           [
             "i32.add";
             "i32.sub";
             "i32.mul";
             "i32.eqz";
             "i32.eq";
             "i32.ne";
             "i32.lt_s";
             "i32.gt_s";
             "i32.le_s";
             "i32.ge_s";
             "i32.load";
             "i32.store";
             "memory.size";
             "memory.grow";
             "drop";
             "return";
           ] ->
      parse_flat_instr env head None :: parse_instr_list env rest
  | Atom head :: _ -> fail ("unsupported instruction: " ^ head)

and parse_flat_structured env head rest =
  let rec collect depth acc = function
    | [] -> fail ("missing end for " ^ head)
    | Atom ("block" | "loop") as x :: xs -> collect (depth + 1) (x :: acc) xs
    | Atom "end" :: xs ->
        if depth = 1 then (List.rev acc, xs)
        else collect (depth - 1) (Atom "end" :: acc) xs
    | x :: xs -> collect depth (x :: acc) xs
  in
  let body, rest = collect 1 [] rest in
  let body =
    match body with Atom id :: rest when is_id id -> rest | _ -> body
  in
  let bt, instrs = parse_blocktype body in
  let term =
    match head with
    | "block" -> "CTORBLOCKA2(" ^ bt ^ ", " ^ seq (parse_instr_list env instrs) ^ ")"
    | "loop" -> "CTORLOOPA2(" ^ bt ^ ", " ^ seq (parse_instr_list env instrs) ^ ")"
    | _ -> assert false
  in
  (term, rest)

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
      | List (Atom "result" :: xs) -> results := !results @ List.map atom xs
      | _ -> ())
    fields;
  match !explicit_type with
  | Some i -> i
  | None ->
      let i = List.length !types_ref in
      types_ref := !types_ref @ [ (None, { params = !params; results = !results }) ];
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
  | [ List [ Atom "mut"; Atom t ] ] -> globaltype_term true t
  | [ Atom t ] -> globaltype_term false t
  | _ -> fail "expected global type"

let parse_memory_fields body =
  let id, body = split_leading_id body in
  let inline_exports, body = split_inline_exports body in
  let min, max, rest = parse_limits body in
  match rest with
  | [] -> (id, inline_exports, memtype_term min max, min, max)
  | _ -> fail "unsupported memory declaration"

let parse_table_fields body =
  let id, body = split_leading_id body in
  let inline_exports, body = split_inline_exports body in
  let min, max, rest = parse_limits body in
  match rest with
  | [ Atom rt ] ->
      ( id,
        inline_exports,
        tabletype_term min max rt,
        min,
        max,
        rt,
        "CTORREFNULLA1(" ^ heaptype rt ^ ")" )
  | _ -> fail "unsupported table declaration"

let parse_import type_names types_ref func_index global_index memory_index table_index = function
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

let parse_func type_names types_ref func_names global_names memory_names table_names func_index =
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
        | Some (_, typ) -> List.length typ.params
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
        {
          type_names;
          func_names;
          global_names;
          memory_names;
          table_names;
          local_names = named_params @ named_locals;
        }
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

let parse_export func_names global_names memory_names table_names = function
  | List [ Atom "export"; Atom name; List [ Atom "func"; x ] ] ->
      { export_item_name = name; export_item_desc = ExportFunc (resolve_index "func" func_names x) }
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

let parse_global global_names memory_names table_names func_names type_names global_index = function
  | List (Atom "global" :: body) ->
      let id, body = split_leading_id body in
      let inline_exports, body = split_inline_exports body in
      let rec split_type acc = function
        | [] -> fail "global declaration is missing init expression"
        | (List (Atom ("i32.const" | "ref.null" | "ref.func" | "global.get") :: _) as x) :: rest
        | (Atom ("i32.const" | "ref.null" | "ref.func" | "global.get") as x) :: rest ->
            (List.rev acc, x :: rest)
        | x :: rest -> split_type (x :: acc) rest
      in
      let type_items, expr_items = split_type [] body in
      let env =
        {
          type_names;
          func_names;
          global_names;
          memory_names;
          table_names;
          local_names = [];
        }
      in
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

let parse_data memory_names table_names global_names func_names type_names = function
  | List (Atom "data" :: body) ->
      let memidx = ref 0 in
      let mode = ref None in
      let bytes = ref [] in
      let env =
        {
          type_names;
          func_names;
          global_names;
          memory_names;
          table_names;
          local_names = [];
        }
      in
      let rec loop = function
        | [] -> ()
        | List [ Atom "memory"; x ] :: rest ->
            memidx := resolve_index "memory" memory_names x;
            loop rest
        | (List (Atom "i32.const" :: _) as expr) :: rest ->
            mode :=
              Some
                ("CTORACTIVEA2(" ^ string_of_int !memidx ^ ", "
                ^ seq (parse_instr_list env [ expr ])
                ^ ")");
            loop rest
        | Atom s :: rest when String.length s >= 2 && s.[0] = '"' ->
            bytes := !bytes @ wat_string_bytes s;
            loop rest
        | _ -> fail "unsupported data segment"
      in
      loop body;
      { data_bytes = !bytes; data_mode = Option.value !mode ~default:"CTORPASSIVEA0" }
  | _ -> fail "expected data"

let parse_elem memory_names table_names global_names func_names type_names = function
  | List (Atom "elem" :: body) ->
      let tableidx = ref 0 in
      let mode = ref None in
      let exprs = ref [] in
      let elem_type = ref "CTORREFA2(CTORNULLA0, CTORFUNCA0)" in
      let env =
        {
          type_names;
          func_names;
          global_names;
          memory_names;
          table_names;
          local_names = [];
        }
      in
      let rec loop = function
        | [] -> ()
        | Atom "declare" :: rest ->
            mode := Some "CTORDECLAREA0";
            loop rest
        | Atom "func" :: rest ->
            exprs :=
              !exprs
              @ (rest
                |> List.map (fun x ->
                       "CTORREFFUNCA1(" ^ string_of_int (resolve_index "func" func_names x) ^ ")"));
            ()
        | List [ Atom "table"; x ] :: rest ->
            tableidx := resolve_index "table" table_names x;
            loop rest
        | (List (Atom "i32.const" :: _) as expr) :: rest ->
            mode :=
              Some
                ("CTORACTIVEA2(" ^ string_of_int !tableidx ^ ", "
                ^ seq (parse_instr_list env [ expr ])
                ^ ")");
            loop rest
        | List [ Atom "ref.null"; Atom ht ] :: rest ->
            exprs := !exprs @ [ "CTORREFNULLA1(" ^ heaptype ht ^ ")" ];
            loop rest
        | Atom x :: rest when is_id x || (String.length x > 0 && x.[0] <> '"') ->
            exprs :=
              !exprs
              @ [ "CTORREFFUNCA1(" ^ string_of_int (resolve_index "func" func_names (Atom x)) ^ ")" ];
            loop rest
        | _ -> fail "unsupported elem segment"
      in
      loop body;
      { elem_type = !elem_type; elem_exprs = !exprs; elem_mode = Option.value !mode ~default:"CTORPASSIVEA0" }
  | _ -> fail "expected elem"

let parse_start func_names = function
  | List [ Atom "start"; x ] -> resolve_index "func" func_names x
  | _ -> fail "expected start"

let load_input path =
  if path = "-" then read_stdin ()
  else if has_suffix path ".wasm" then
    let cmd =
      if Sys.command "command -v wasm2wat >/dev/null 2>&1" = 0 then
        "wasm2wat " ^ Filename.quote path
      else fail "wasm2wat is required for .wasm input"
    in
    run_command_capture cmd
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
  let env =
    {
      type_names;
      func_names = [];
      global_names = [];
      memory_names = [];
      table_names = [];
      local_names = [];
    }
  in
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
  let env =
    {
      type_names = [];
      func_names = [];
      global_names = [];
      memory_names = [];
      table_names = [];
      local_names = [];
    }
  in
  let value = seq (parse_instr_list env (parse_many (tokenize rhs))) in
  {
    global_binding_module = module_name;
    global_binding_name = item_name;
    global_binding_value = value;
  }

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
        |> List.mapi (fun i (id, _) -> Option.map (fun id -> (id, i)) id)
        |> List.filter_map Fun.id
      in
      let func_index = ref 0
      and global_index = ref 0
      and memory_index = ref 0
      and table_index = ref 0 in
      let imports_raw = ref [] in
      let funcs_raw = ref [] in
      let globals_raw = ref [] in
      let memories_raw = ref [] in
      let tables_raw = ref [] in
      let datas_raw = ref [] in
      let elems_raw = ref [] in
      let starts_raw = ref [] in
      let func_names = ref [] in
      let global_names = ref [] in
      let memory_names = ref [] in
      let table_names = ref [] in
      List.iter
        (function
          | List (Atom "import" :: _) as form ->
              let import =
                parse_import type_names types_ref !func_index !global_index !memory_index
                  !table_index form
              in
              imports_raw := !imports_raw @ [ import ];
              (match import with
              | ImportFunc im ->
                  (match im.import_id with
                  | Some id -> func_names := (id, !func_index) :: !func_names
                  | None -> ());
                  incr func_index
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
      let global_names = List.rev !global_names in
      let memory_names = List.rev !memory_names in
      let table_names = List.rev !table_names in
      let funcs =
        !funcs_raw
        |> List.map (fun (i, form) ->
               parse_func type_names types_ref func_names global_names memory_names table_names i
                 form)
      in
      let globals =
        !globals_raw
        |> List.map (fun (i, form) ->
               parse_global global_names memory_names table_names func_names type_names i form)
      in
      let memories = !memories_raw |> List.map (fun (i, form) -> parse_memory i form) in
      let tables = !tables_raw |> List.map (fun (i, form) -> parse_table i form) in
      let datas =
        !datas_raw
        |> List.map (parse_data memory_names table_names global_names func_names type_names)
      in
      let elems =
        !elems_raw
        |> List.map (parse_elem memory_names table_names global_names func_names type_names)
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
        |> List.map (parse_export func_names global_names memory_names table_names)
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
      let exports = top_exports @ inline_exports @ inline_global_exports @ inline_memory_exports @ inline_table_exports in
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

let default_import_global_value globaltype =
  if contains_sub globaltype "CTORI32A0" then
    "CTORCONSTA2(CTORI32A0, 0)"
  else if contains_sub globaltype "CTORI64A0" then
    "CTORCONSTA2(CTORI64A0, 0)"
  else if contains_sub globaltype "CTORF32A0" then
    "CTORCONSTA2(CTORF32A0, 0)"
  else if contains_sub globaltype "CTORF64A0" then
    "CTORCONSTA2(CTORF64A0, 0)"
  else if contains_sub globaltype "CTORV128A0" then
    "CTORVCONSTA2(CTORV128A0, eps)"
  else "CTORREFNULLA1(CTORFUNCA0)"

let emit_import_runtime func_bindings global_bindings ir type_terms =
  let func_imports =
    ir.imports
    |> List.filter_map (function ImportFunc im -> Some im | _ -> None)
  in
  let missing =
    func_imports
    |> List.filter (fun im -> find_import_binding func_bindings im = None)
  in
  if missing <> [] then
    let names =
      missing
      |> List.map (fun im -> unquote im.import_module ^ "." ^ unquote im.import_name)
      |> String.concat ", "
    in
    fail ("missing --import-func implementation for: " ^ names)
  else ();
  let func_defs =
    func_imports
    |> List.mapi (fun i im ->
           let binding =
             match find_import_binding func_bindings im with
             | Some b -> b
             | None -> assert false
           in
           Printf.sprintf
             {|
  op generated-import-func-%d : -> Funcinst [ctor] .
  eq value('TYPE, generated-import-func-%d) = index(generated-import-deftypes, %d) .
  eq value('MODULE, generated-import-func-%d) = $empty-moduleinst .
  eq value('CODE, generated-import-func-%d) = CTORFUNCA3(%d, eps, %s) .
|}
             i i im.import_typeidx i i im.import_typeidx (seq binding.binding_body))
    |> String.concat "\n"
  in
  let func_names =
    func_imports
    |> List.mapi (fun i _ -> "generated-import-func-" ^ string_of_int i)
    |> seq
  in
  let global_names =
    ir.imports
    |> List.filter_map (function
         | ImportGlobal im ->
           let value =
             match find_import_global_binding global_bindings im.import_module im.import_name with
             | Some b -> b.global_binding_value
             | None -> default_import_global_value im.import_globaltype
           in
           Some ("RECGlobalinstA2(" ^ im.import_globaltype ^ ", " ^ value ^ ")")
         | _ -> None)
    |> seq
  in
  let memory_names =
    ir.imports
    |> List.filter_map (function
         | ImportMemory im ->
             Some
               ("RECMeminstA2(" ^ im.import_memtype ^ ", $zero-membytes("
              ^ string_of_int im.import_mem_min ^ "))")
         | _ -> None)
    |> seq
  in
  let table_names =
    ir.imports
    |> List.filter_map (function
         | ImportTable im ->
             Some
               ("RECTableinstA2(" ^ im.import_tabletype ^ ", $table-refs("
              ^ string_of_int im.import_table_min ^ ", " ^ im.import_table_default_ref ^ "))")
         | _ -> None)
    |> seq
  in
  let externaddrs =
    let fi = ref 0 and gi = ref 0 and mi = ref 0 and ti = ref 0 in
    ir.imports
    |> List.map (function
         | ImportFunc _ ->
             let i = !fi in
             incr fi;
             "CTORFUNCA1(" ^ string_of_int i ^ ")"
         | ImportGlobal _ ->
             let i = !gi in
             incr gi;
             "CTORGLOBALA1(" ^ string_of_int i ^ ")"
         | ImportMemory _ ->
             let i = !mi in
             incr mi;
             "CTORMEMA1(" ^ string_of_int i ^ ")"
         | ImportTable _ ->
             let i = !ti in
             incr ti;
             "CTORTABLEA1(" ^ string_of_int i ^ ")")
    |> seq
  in
  Printf.sprintf
    {|
  op generated-import-deftypes : -> SpectecTerminals .
  eq generated-import-deftypes = $init-deftypes(%s, 0) .
%s
  op generated-import-store : -> Store .
  eq generated-import-store = RECStoreA10(eps, %s, %s, %s, %s, eps, eps, eps, eps, eps) .

  op generated-import-externaddrs : -> SpectecTerminals .
  eq generated-import-externaddrs = %s .
|}
    type_terms func_defs global_names memory_names table_names func_names externaddrs

let emit_maude ~harness ?(link_imports = false) ?(import_bindings = [])
    ?(import_global_bindings = []) ir =
  let type_terms = ir.types |> List.map (fun (_, typ) -> type_term typ) |> seq in
  let import_runtime =
    if ir.imports = [] || not link_imports then ""
    else emit_import_runtime import_bindings import_global_bindings ir type_terms
  in
  let default_base, default_externaddrs =
    if ir.imports = [] || not link_imports then ("empty-store", "eps")
    else ("generated-import-store", "generated-import-externaddrs")
  in
  let import_terms =
    ir.imports
    |> List.map (function
         | ImportFunc im ->
             "CTORIMPORTA3($wat-name(" ^ maude_qid im.import_module ^ "), $wat-name("
             ^ maude_qid im.import_name ^ "), CTORFUNCA1(CTORWIDXA1("
             ^ string_of_int im.import_typeidx ^ ")))"
         | ImportGlobal im ->
             "CTORIMPORTA3($wat-name(" ^ maude_qid im.import_module ^ "), $wat-name("
             ^ maude_qid im.import_name ^ "), CTORGLOBALA1(" ^ im.import_globaltype ^ "))"
         | ImportMemory im ->
             "CTORIMPORTA3($wat-name(" ^ maude_qid im.import_module ^ "), $wat-name("
             ^ maude_qid im.import_name ^ "), CTORMEMA1(" ^ im.import_memtype ^ "))"
         | ImportTable im ->
             "CTORIMPORTA3($wat-name(" ^ maude_qid im.import_module ^ "), $wat-name("
             ^ maude_qid im.import_name ^ "), CTORTABLEA1(" ^ im.import_tabletype ^ "))")
    |> seq
  in
  let global_terms =
    ir.globals
    |> List.map (fun g -> "CTORGLOBALA2(" ^ g.global_type ^ ", " ^ seq g.global_init ^ ")")
    |> seq
  in
  let memory_terms =
    ir.memories |> List.map (fun m -> "CTORMEMORYA1(" ^ m.memory_type ^ ")") |> seq
  in
  let table_terms =
    ir.tables
    |> List.map (fun t -> "CTORTABLEA2(" ^ t.table_type ^ ", " ^ seq t.table_init ^ ")")
    |> seq
  in
  let func_terms =
    ir.funcs
    |> List.map (fun fn ->
           "CTORFUNCA3(" ^ string_of_int fn.func_typeidx ^ ", "
           ^ seq (List.map local_decl fn.func_locals)
           ^ ", " ^ seq fn.func_body ^ ")")
    |> seq
  in
  let data_terms =
    ir.datas
    |> List.map (fun d -> "CTORDATAA2(" ^ bytes_seq d.data_bytes ^ ", " ^ d.data_mode ^ ")")
    |> seq
  in
  let elem_terms =
    ir.elems
    |> List.map (fun e ->
           "CTORELEMA3(" ^ e.elem_type ^ ", " ^ seq e.elem_exprs ^ ", " ^ e.elem_mode ^ ")")
    |> seq
  in
  let start_terms =
    match ir.start with Some i -> "CTORSTARTA1(" ^ string_of_int i ^ ")" | None -> "eps"
  in
  let export_terms =
    ir.exports
    |> List.map (fun ex ->
           let desc =
             match ex.export_item_desc with
             | ExportFunc i -> "CTORFUNCA1(" ^ string_of_int i ^ ")"
             | ExportGlobal i -> "CTORGLOBALA1(" ^ string_of_int i ^ ")"
             | ExportMemory i -> "CTORMEMA1(" ^ string_of_int i ^ ")"
             | ExportTable i -> "CTORTABLEA1(" ^ string_of_int i ^ ")"
           in
           "CTOREXPORTA2($wat-name(" ^ maude_qid ex.export_item_name ^ "), " ^ desc ^ ")")
    |> seq
  in
  let invoke_index =
    match ir.invoke_index with
    | Some i -> i
    | None -> fail "module has no function to invoke"
  in
  Printf.sprintf
    {|load %s

mod WASM-FIB-GENERATED-BS is
  inc WASM-FIB-BS .

  var GEN-NVAL : Val .
  var GEN-S : Store .
  var GEN-F : Frame .
  var GEN-BASE : Store .
  var GEN-FADDR : Addr .
  var GEN-EXTERNADDRS : SpectecTerminals .
  vars GEN-ARGS GEN-INITS : SpectecTerminals .

  op generated-fib-module : -> SpectecTerminal .
  eq generated-fib-module =
    CTORMODULEA11(
      %s,
      %s,
      eps,
      %s,
      %s,
      %s,
      %s,
      %s,
      %s,
      %s,
      %s
    ) .
%s

  op generated-run-config-with : Store SpectecTerminals SpectecTerminals -> Config .
  ceq generated-run-config-with(GEN-BASE, GEN-EXTERNADDRS, GEN-ARGS) =
    (GEN-S ; GEN-F) ; GEN-INITS GEN-ARGS CTORREFFUNCADDRA1(GEN-FADDR) CTORCALLREFA1(value('TYPE, index(value('FUNCS, GEN-S), GEN-FADDR)))
    if ((GEN-S ; GEN-F) ; GEN-INITS) := $instantiate(GEN-BASE, generated-fib-module, GEN-EXTERNADDRS)
    /\ GEN-FADDR := index(value('FUNCS, value('MODULE, GEN-F)), %d) .

  op generated-run-config : SpectecTerminals -> Config .
  eq generated-run-config(GEN-ARGS) =
    generated-run-config-with(%s, %s, GEN-ARGS) .

  op generated-fib-init-config-with : Store SpectecTerminals Val -> Config .
  eq generated-fib-init-config-with(GEN-BASE, GEN-EXTERNADDRS, GEN-NVAL) =
    generated-run-config-with(GEN-BASE, GEN-EXTERNADDRS, GEN-NVAL i32v(0) i32v(1)) .

  op generated-fib-init-config : Val -> Config .
  eq generated-fib-init-config(GEN-NVAL) =
    generated-fib-init-config-with(%s, %s, GEN-NVAL) .
endm
|}
    harness type_terms import_terms global_terms memory_terms table_terms func_terms data_terms
    elem_terms start_terms export_terms import_runtime invoke_index default_base default_externaddrs
    default_base default_externaddrs

let run_maude_command ~maude ~result_only generated command =
  let file = Filename.temp_file "spec2maude-wat-" ".maude" in
  (* Maude stays interactive after loading a file when stdin is a terminal.
     Add an explicit quit so CLI runs finish in normal shells too. *)
  write_file file (generated ^ command ^ "\nquit\n");
  Fun.protect
    ~finally:(fun () -> try Sys.remove file with Sys_error _ -> ())
    (fun () ->
      let output = run_command_capture (Filename.quote maude ^ " " ^ Filename.quote file) in
      if result_only then Printf.printf "result: %s\n" (extract_final_value output)
      else print_string output)

let run_maude_fib ~maude ~result_only generated n =
  run_maude_command ~maude ~result_only generated
    ("\nrew [10000] in WASM-FIB-GENERATED-BS : steps(generated-fib-init-config(i32v("
    ^ string_of_int n ^ "))) .\n")

let run_maude_main ~maude ~result_only generated args =
  let arg_terms = args |> List.map (fun n -> "i32v(" ^ string_of_int n ^ ")") |> seq in
  run_maude_command ~maude ~result_only generated
    ("\nrew [10000] in WASM-FIB-GENERATED-BS : steps(generated-run-config("
    ^ arg_terms ^ ")) .\n")

let usage () =
  prerr_endline
    "usage: wat_to_maude_fib [--harness FILE] [--output FILE] [--run N] [--run-main] [--run-export NAME] [--arg-i32 N] [--maude PATH] [--invoke-index N] [--result-only] [--import-func MODULE.NAME=INSTRUCTIONS] [--import-global MODULE.NAME=VALUE] INPUT.wat|INPUT.wasm";
  exit 2

let () =
  try
    let harness = ref (Filename.concat (Sys.getcwd ()) "wasm-exec-bs.maude") in
    let maude = ref "maude" in
    let output = ref None in
    let run = ref None in
    let run_main = ref false in
    let run_export = ref None in
    let result_only = ref false in
    let arg_i32s = ref [] in
    let invoke_index = ref None in
    let import_func_specs = ref [] in
    let import_global_specs = ref [] in
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
      | "--run-export" :: name :: rest ->
          run_main := true;
          run_export := Some (unquote name);
          parse_args rest
      | "--arg-i32" :: n :: rest ->
          arg_i32s := !arg_i32s @ [ int_of_string n ];
          parse_args rest
      | "--result-only" :: rest ->
          result_only := true;
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
      | [ path ] -> input := Some path
      | _ -> usage ()
    in
    parse_args (List.tl (Array.to_list Sys.argv));
    let input = match !input with Some path -> path | None -> usage () in
    let harness =
      if Filename.is_relative !harness then Filename.concat (Sys.getcwd ()) !harness
      else !harness
    in
    let ir = parse_module ?invoke_index:!invoke_index (load_input input) in
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
    let import_bindings =
      !import_func_specs |> List.map (parse_import_func_binding [])
    in
    let import_global_bindings =
      !import_global_specs |> List.map parse_import_global_binding
    in
    let missing_func_imports =
      ir.imports
      |> List.filter_map (function ImportFunc im -> Some im | _ -> None)
      |> List.filter (fun im -> find_import_binding import_bindings im = None)
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
      emit_maude ~harness ~link_imports:(!run <> None || !run_main) ~import_bindings
        ~import_global_bindings ir
    in
    (match !output with
    | Some path -> write_file path generated
    | None -> if !run = None && not !run_main then print_string generated);
    (match (!run, !run_main) with
    | Some n, false -> run_maude_fib ~maude:!maude ~result_only:!result_only generated n
    | None, true -> run_maude_main ~maude:!maude ~result_only:!result_only generated !arg_i32s
    | None, false -> ()
    | Some _, true -> fail "use either --run or --run-main, not both")
  with
  | Error msg ->
      prerr_endline ("wat_to_maude_fib: " ^ msg);
      exit 1
  | Failure msg ->
      prerr_endline ("wat_to_maude_fib: " ^ msg);
      exit 1
  | Sys_error msg ->
      prerr_endline ("wat_to_maude_fib: " ^ msg);
      exit 1
