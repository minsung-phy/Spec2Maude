(* ========================================================================= *)
(* Spec2Maude: SpecTec IL AST → Maude Algebraic Specification Translator     *)
(*                                                                           *)
(* Architecture:                                                             *)
(*  1. Foundation types (StringSet, texpr, var_map, exp_ctx)                 *)
(*  2. Identifier sanitization                                               *)
(*  3. Type environment (plural-type detection)                              *)
(*  4. Mixfix operator interleaving                                          *)
(*  5. Declaration management (shared mutable dedup state)                   *)
(*  6. Pre-scan phase (collect tokens, call signatures, ctors)               *)
(*  7. Expression translation (pure: returns texpr = text + vars)            *)
(*  8. Definition handlers (TypD / DecD / RelD)                              *)
(*  9. Top-level: prescan → header → translate → reorder → emit             *)
(* ========================================================================= *)

open Util.Source
open Il.Ast

(* ========================================================================= *)
(* 1. Foundation types                                                       *)
(* ========================================================================= *)

module SSet = Set.Make (String)

module SIPairSet = Set.Make (struct
  type t = string * int
  let compare = compare
end)

type var_map = (string * string) list
let rewrite_defs_seen : SSet.t ref = ref SSet.empty

type exp_ctx = BoolCtx | TermCtx

(** Translation result: Maude source text paired with collected variable names.
    Replaces the global [undeclared_vars] ref with a pure accumulator. *)
type texpr = { text : string; vars : string list }

let texpr s = { text = s; vars = [] }

let texpr_with_var s v = { text = s; vars = [v] }

let feature_uses_bool_wrapper : bool ref = ref false
let feature_uses_has_type : bool ref = ref false
let feature_uses_star_prefix : bool ref = ref false

let tconcat sep ts =
  { text = String.concat sep (List.map (fun t -> t.text) ts);
    vars = List.concat_map (fun t -> t.vars) ts }

let tmap f t = { t with text = f t.text }

let tjoin2 f t1 t2 =
  { text = f t1.text t2.text; vars = t1.vars @ t2.vars }

let tjoin3 f t1 t2 t3 =
  { text = f t1.text t2.text t3.text; vars = t1.vars @ t2.vars @ t3.vars }

let rename_texpr_vars renames (t : texpr) =
  let text =
    List.fold_left (fun acc (src, dst) ->
      Str.global_replace (Str.regexp_string src) dst acc
    ) t.text renames
  in
  let vars =
    List.map (fun v -> match List.assoc_opt v renames with Some v' -> v' | None -> v) t.vars
  in
  { text; vars = List.sort_uniq String.compare vars }

let replace_maude_var_token src dst text =
  let is_var_char = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '\'' -> true
    | _ -> false
  in
  let src_len = String.length src in
  let text_len = String.length text in
  let buf = Buffer.create (text_len + String.length dst) in
  let rec loop i =
    if i >= text_len then ()
    else if i + src_len <= text_len
         && String.sub text i src_len = src
         && (i = 0 || not (is_var_char text.[i - 1]))
         && (i + src_len = text_len || not (is_var_char text.[i + src_len]))
    then begin
      Buffer.add_string buf dst;
      loop (i + src_len)
    end else begin
      Buffer.add_char buf text.[i];
      loop (i + 1)
    end
  in
  loop 0;
  Buffer.contents buf

let str_matched_group_opt n s =
  try Some (Str.matched_group n s) with _ -> None

let starts_with s prefix =
  let slen = String.length s in
  let plen = String.length prefix in
  slen >= plen && String.sub s 0 plen = prefix

let contains_substring s lit =
  try ignore (Str.search_forward (Str.regexp_string lit) s 0); true
  with Not_found -> false

let wrap_paren s = Printf.sprintf "( %s )" s

let debug_iter_enabled =
  match Sys.getenv_opt "SPEC2MAUDE_DEBUG_ITER" with
  | Some "1" | Some "true" | Some "TRUE" | Some "yes" | Some "YES" -> true
  | _ -> false

let debug_iter fmt =
  if debug_iter_enabled then Printf.eprintf (fmt ^^ "\n")
  else Printf.ifprintf stderr (fmt ^^ "\n")

let bs_disabled_ctxt_rules =
  match Sys.getenv_opt "SPEC2MAUDE_BS_DISABLE_CTXT" with
  | None -> SSet.empty
  | Some raw ->
      raw
      |> String.split_on_char ','
      |> List.map String.trim
      |> List.filter (fun s -> s <> "")
      |> List.map String.lowercase_ascii
      |> SSet.of_list

let bs_skip_ctxt_rule case_id =
  SSet.mem (String.lowercase_ascii case_id) bs_disabled_ctxt_rules

let syntax_keywords =
  SSet.of_list
    ["semicolon"; "lbrace"; "rbrace"; "lbrack"; "rbrack";
     "arrow"; "dotdot"]

let wrap_mix_token s =
  s

let strip_trailing_eq_true s =
  let t = String.trim s in
  let re = Str.regexp "[ \t]*=[ \t]*true[ \t]*$" in
  String.trim (Str.replace_first re "" t)

let cond_join conds =
  conds
  |> List.map String.trim
  |> List.map strip_trailing_eq_true
  |> List.filter (fun c -> c <> "" && c <> "true" && c <> "( true )" && c <> "(true)")
  |> String.concat " /\\ "

let safe_term_text s =
  let t = String.trim s in
  if t = "" then "T" else t

let rec strip_wrapping_parens s =
  let t = String.trim s in
  let n = String.length t in
  if n >= 2 && t.[0] = '(' && t.[n - 1] = ')'
  then strip_wrapping_parens (String.sub t 1 (n - 2))
  else t

let is_plain_var_like s =
  let b = strip_wrapping_parens s in
  String.length b > 0
  && b.[0] >= 'A' && b.[0] <= 'Z'
  && not (String.contains b ' ')
  && not (String.contains b '(')
  && not (String.contains b ')')

let bool_cond s =
  let t = String.trim s in
  if t = "" then "true" else t

(* A premise text passes through unwrapped if it is already a Maude
   side-condition in its own right:
   - LetPr / match-binding: contains ":="
   - Membership condition: contains ':' but no '='
   - Rewrite condition: contains "=>"
   Otherwise we keep the translated Bool term directly, without wrapping it
   as `(s) = true`. *)
let prem_cond s =
  let has_colon = String.contains s ':' in
  let has_eq    = String.contains s '=' in
  let has_rewrite =
    try
      ignore (Str.search_forward (Str.regexp_string "=>") s 0);
      true
    with Not_found -> false
  in
  if has_rewrite then s
  else if has_colon && has_eq then s            (* LetPr `:=` *)
  else if has_colon && not has_eq then s   (* membership condition *)
  else bool_cond s

let split_once needle s =
  let n = String.length needle in
  let rec loop i =
    if i + n > String.length s then None
    else if String.sub s i n = needle then
      Some (String.sub s 0 i, String.sub s (i + n) (String.length s - i - n))
    else loop (i + 1)
  in
  loop 0

let split_once_re re s =
  try
    let pos = Str.search_forward re s 0 in
    let len = String.length (Str.matched_string s) in
    Some (String.sub s 0 pos, String.sub s (pos + len) (String.length s - pos - len))
  with Not_found -> None

let head_symbol_of_text s =
  let t = strip_wrapping_parens s |> String.trim in
  let n = String.length t in
  let rec find_end i =
    if i >= n then i
    else
      match t.[i] with
      | ' ' | '(' | ')' | ',' -> i
      | _ -> find_end (i + 1)
  in
  if n = 0 then None
  else
    match t.[0] with
    | '$' | 'A' .. 'Z' | 'a' .. 'z' ->
        let j = find_end 0 in
        Some (String.sub t 0 j)
    | _ -> None

let rewriteify_prem_text ?(extra_heads=[]) text =
  let emit_rewrite call result = Some (Printf.sprintf "%s => %s" call result) in
  let is_rewrite_def_term term =
    match head_symbol_of_text term with
    | Some head -> SSet.mem head !rewrite_defs_seen || List.mem head extra_heads
    | None -> false
  in
  let normalize s =
    let t = String.trim s in
    let t =
      match split_once " = true" t with
      | Some (lhs, rhs) when String.trim rhs = "" -> lhs
      | _ -> t
    in
    strip_wrapping_parens t |> String.trim
  in
  if
    try
      ignore (Str.search_forward (Str.regexp_string "=> valid") text 0);
      true
    with Not_found -> false
  then Some text
  else
    match split_once_re (Str.regexp "[ \t]+:=[ \t]+") text with
    | Some (lhs, rhs) ->
        let lhs = normalize lhs in
        let rhs = normalize rhs in
        if is_rewrite_def_term rhs then emit_rewrite rhs lhs
        else if is_rewrite_def_term lhs then emit_rewrite lhs rhs
        else None
    | _ ->
        let t = normalize text in
        (match split_once_re (Str.regexp "[ \t]+==[ \t]+") t with
         | Some (lhs, rhs) ->
             let lhs = normalize lhs in
             let rhs = normalize rhs in
             if is_rewrite_def_term rhs then emit_rewrite rhs lhs
             else if is_rewrite_def_term lhs then emit_rewrite lhs rhs
             else None
         | _ ->
             if String.contains text ':' then None else None)

(* ========================================================================= *)
(* 2. Identifier sanitization                                                *)
(* ========================================================================= *)

let maude_keywords =
  SSet.of_list
    ["if"; "var"; "op"; "eq"; "sort"; "mod"; "quo"; "rem"; "or"; "and"; "not"]

let is_alpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')

let is_upper_start s = String.length s > 0 && s.[0] >= 'A' && s.[0] <= 'Z'

(** Transform a SpecTec identifier into a valid Maude token.
    - Single-char, non-alpha-start, or keyword names get a [w-] prefix.
    - Special chars become [-]; [-digit] sequences become [Ndigit].
    - Trailing hyphens are stripped. *)
let sanitize name =
  if name = "_" then "any"
  else
    let needs_prefix =
      (String.length name > 0 && name.[0] <> '$' && not (is_alpha name.[0]))
      || SSet.mem (String.lowercase_ascii name) maude_keywords
    in
    let base = if needs_prefix then "w-" ^ name else name in
    let mapped = String.map (function
      | '.' | '_' | '*' | '+' | '?' -> '-'
      | '\'' -> 'Q'
      | c -> c) base
    in
    let buf = Buffer.create (String.length mapped) in
    let len = String.length mapped in
    let rec scan i =
      if i >= len then ()
      else if mapped.[i] = '-' && i + 1 < len
           && mapped.[i + 1] >= '0' && mapped.[i + 1] <= '9' then
        (Buffer.add_char buf mapped.[i + 1]; scan (i + 2))
      else
        (Buffer.add_char buf mapped.[i]; scan (i + 1))
    in
    scan 0;
    let res = Buffer.contents buf in
    let rec strip_tail s =
      let n = String.length s in
      if n > 0 && s.[n - 1] = '-'
      then strip_tail (String.sub s 0 (n - 1))
      else s
    in
    strip_tail res

let sanitize_rule_label_part name =
  if name = "_" then "any"
  else
    let mapped = String.map (function
      | '.' | '_' | '*' | '+' | '?' -> '-'
      | '\'' -> 'Q'
      | c -> c) name
    in
    let buf = Buffer.create (String.length mapped) in
    let len = String.length mapped in
    let rec scan i =
      if i >= len then ()
      else if mapped.[i] = '-' && i + 1 < len
           && mapped.[i + 1] >= '0' && mapped.[i + 1] <= '9' then
        (Buffer.add_char buf mapped.[i + 1]; scan (i + 2))
      else
        (Buffer.add_char buf mapped.[i]; scan (i + 1))
    in
    scan 0;
    let rec strip_edges s =
      let n = String.length s in
      if n > 0 && s.[0] = '-' then strip_edges (String.sub s 1 (n - 1))
      else if n > 0 && s.[n - 1] = '-' then strip_edges (String.sub s 0 (n - 1))
      else s
    in
    strip_edges (Buffer.contents buf)

let rule_label_prefix rel_name case_id rule_idx =
  let rel_part = String.uppercase_ascii (sanitize_rule_label_part rel_name) in
  let case_part_raw = String.uppercase_ascii (sanitize_rule_label_part case_id) in
  let case_part = if case_part_raw = "" then Printf.sprintf "R%d" rule_idx else case_part_raw in
  Printf.sprintf "%s-%s" rel_part case_part

let to_var_name name =
  String.uppercase_ascii (sanitize name)

let is_upper_token s =
  String.length s > 0 &&
  let c = s.[0] in c >= 'A' && c <= 'Z'

let ends_with s suffix =
  let ns = String.length s and nf = String.length suffix in
  ns >= nf && String.sub s (ns - nf) nf = suffix

let star_prefix_pattern text =
  let core = strip_wrapping_parens text |> String.trim in
  let parts =
    if core = "" then []
    else Str.split (Str.regexp "[ \t\n\r]+") core
  in
  match parts with
  | [ctor; seq_var]
      when starts_with ctor "CTOR"
           && ends_with ctor "A0"
           && is_plain_var_like seq_var ->
      Some (ctor, strip_wrapping_parens seq_var)
  | _ -> None

let star_prefix_text ctor seq =
  feature_uses_star_prefix := true;
  Printf.sprintf "$star-prefix ( %s, %s )" ctor seq

let star_unprefix_text ctor seq =
  feature_uses_star_prefix := true;
  Printf.sprintf "$star-unprefix ( %s, %s )" ctor seq

let split_top_level_commas s =
  let len = String.length s in
  let rec loop i depth start acc =
    if i >= len then
      let part = String.sub s start (len - start) |> String.trim in
      List.rev (part :: acc)
    else
      match s.[i] with
      | '(' | '[' | '{' -> loop (i + 1) (depth + 1) start acc
      | ')' | ']' | '}' -> loop (i + 1) (max 0 (depth - 1)) start acc
      | ',' when depth = 0 ->
          let part = String.sub s start (i - start) |> String.trim in
          loop (i + 1) depth (i + 1) (part :: acc)
      | _ -> loop (i + 1) depth start acc
  in
  if String.trim s = "" then [] else loop 0 0 0 []

let parse_call_text text =
  let text = strip_wrapping_parens text |> String.trim in
  try
    let open_i = String.index text '(' in
    let close_i = String.rindex text ')' in
    if close_i <= open_i then None
    else
      let fn = String.sub text 0 open_i |> String.trim in
      let args =
        String.sub text (open_i + 1) (close_i - open_i - 1)
        |> split_top_level_commas
      in
      if fn = "" then None else Some (fn, args)
  with Not_found -> None

type iter_rel_helper = {
  iter_helper_name : string;
  iter_rel_name : string;
  iter_arity : int;
  iter_split_positions : bool list;
}

let iter_rel_helpers : iter_rel_helper list ref = ref []

type infer_rel_helper = {
  infer_rel_name : string;
  infer_arity : int;
  infer_arg_index : int;
}

let infer_rel_helpers : infer_rel_helper list ref = ref []
let infer_rel_rules : (string * rule list) list ref = ref []

type map_call_helper = {
  map_helper_name : string;
  map_fn_name : string;
  map_arity : int;
  map_seq_index : int;
  map_arg_sorts : string list;
}

let map_call_helpers : map_call_helper list ref = ref []
let known_call_names : SSet.t ref = ref SSet.empty
let g_sequence_binder_vars : SSet.t ref = ref SSet.empty
let ctor_arg_sort_hints : (string, string list) Hashtbl.t = Hashtbl.create 512

let ctor_decl_arg_sort s =
  if s = "SpectecTerminals" then "SpectecTerminals" else "SpectecTerminal"

let register_ctor_arg_sorts ctor sorts =
  let sorts = List.map ctor_decl_arg_sort sorts in
  let merge old fresh =
    if List.length old <> List.length fresh then old
    else
      List.map2
        (fun a b ->
          if a = "SpectecTerminals" || b = "SpectecTerminals"
          then "SpectecTerminals"
          else "SpectecTerminal")
        old fresh
  in
  match Hashtbl.find_opt ctor_arg_sort_hints ctor with
  | None -> Hashtbl.replace ctor_arg_sort_hints ctor sorts
  | Some old -> Hashtbl.replace ctor_arg_sort_hints ctor (merge old sorts)

let iter_rel_helper_name rel_name split_positions =
  ignore split_positions;
  sanitize rel_name ^ "s"

let iter_rel_label_base helper_name =
  String.lowercase_ascii (sanitize helper_name)

let register_iter_rel_helper rel_name split_positions =
  let helper = {
    iter_helper_name = iter_rel_helper_name rel_name split_positions;
    iter_rel_name = rel_name;
    iter_arity = List.length split_positions;
    iter_split_positions = split_positions;
  } in
  if not (List.exists (fun h ->
      h.iter_helper_name = helper.iter_helper_name
      && h.iter_rel_name = helper.iter_rel_name
      && h.iter_split_positions = helper.iter_split_positions)
      !iter_rel_helpers)
  then iter_rel_helpers := helper :: !iter_rel_helpers;
  helper.iter_helper_name

let infer_rel_helper_name rel_name arg_index =
  Printf.sprintf "$infer-%s-arg%d"
    (String.lowercase_ascii (sanitize rel_name))
    arg_index

let register_infer_rel_rules rel_name rules =
  let rel_name = sanitize rel_name in
  infer_rel_rules :=
    (rel_name, rules) ::
    List.remove_assoc rel_name !infer_rel_rules

let has_infer_rel_rules rel_name =
  List.mem_assoc (sanitize rel_name) !infer_rel_rules

let register_infer_rel_helper rel_name arity arg_index =
  let helper =
    { infer_rel_name = sanitize rel_name;
      infer_arity = arity;
      infer_arg_index = arg_index }
  in
  if not (List.exists (fun h ->
      h.infer_rel_name = helper.infer_rel_name
      && h.infer_arity = helper.infer_arity
      && h.infer_arg_index = helper.infer_arg_index)
      !infer_rel_helpers)
  then infer_rel_helpers := helper :: !infer_rel_helpers;
  infer_rel_helper_name rel_name arg_index

let map_call_helper_name fn arity seq_index =
  let stem =
    fn
    |> String.lowercase_ascii
    |> String.map (function '$' -> 'S' | '-' -> '-' | c -> c)
  in
  Printf.sprintf "$map-%s-a%d-s%d" stem arity seq_index

let register_map_call_helper fn arity seq_index arg_sorts =
  let helper = {
    map_helper_name = map_call_helper_name fn arity seq_index;
    map_fn_name = fn;
    map_arity = arity;
    map_seq_index = seq_index;
    map_arg_sorts = arg_sorts;
  } in
  if not (List.exists (fun h ->
      h.map_fn_name = helper.map_fn_name
      && h.map_arity = helper.map_arity
      && h.map_seq_index = helper.map_seq_index
      && h.map_arg_sorts = helper.map_arg_sorts)
      !map_call_helpers)
  then map_call_helpers := helper :: !map_call_helpers;
  helper.map_helper_name

let unmap_call_helper_name map_helper_name =
  if starts_with map_helper_name "$map-" then
    "$unmap-" ^ String.sub map_helper_name 5 (String.length map_helper_name - 5)
  else
    map_helper_name ^ "-unmap"

let sort_of_type_name raw =
  let s = sanitize raw in
  if String.length s >= 2 && String.sub s 0 2 = "w-" then "SpectecTerminal"
  else
    let hyphen_to_under = String.map (fun c -> if c = '-' then '_' else c) s in
    (* Maude sort names must start with uppercase *)
    if String.length hyphen_to_under > 0
       && hyphen_to_under.[0] >= 'a' && hyphen_to_under.[0] <= 'z'
    then String.capitalize_ascii hyphen_to_under
    else hyphen_to_under

let rec simple_sort_of_typ (t : typ) vm : string option =
  match t.it with
  | VarT (id, []) ->
      let resolved = match List.assoc_opt id.it vm with
        | Some mapped when mapped <> String.uppercase_ascii mapped -> mapped
        | _ -> sanitize id.it
      in
      if is_upper_token resolved then None
      else Some (sort_of_type_name resolved)
  | IterT (_, (List | List1 | ListN _)) -> None
  | IterT (inner, Opt) -> simple_sort_of_typ inner vm
  | _ -> None

let is_token_like_id raw =
  is_upper_start raw
  && String.length raw > 1
  && not (raw = "I" || raw = "T" || raw = "W")
  && not (String.length raw >= 2 && raw.[0] = 'W' && raw.[1] = '-')

let is_lower_token_id raw =
  let len = String.length raw in
  let first_lower = len > 0 && raw.[0] >= 'a' && raw.[0] <= 'z' in
  first_lower && String.contains raw '-'

let call_name id =
  let f = sanitize id in
  if f = "w-$" then f
  else if String.length f > 0 && f.[0] = '$' then f
  else "$" ^ f

let inverse_call_name fn =
  if String.length fn > 1 && fn.[0] = '$' then
    let stem = String.sub fn 1 (String.length fn - 1) in
    let candidate = "$inv-" ^ stem in
    if SSet.mem candidate !known_call_names then Some candidate else None
  else None

(* ========================================================================= *)
(* 3. Type environment                                                       *)
(* ========================================================================= *)

let plural_types : (string, bool) Hashtbl.t = Hashtbl.create 32
let zero_arity_source_sorts : SSet.t ref = ref SSet.empty
let sequence_alias_sorts : SSet.t ref = ref SSet.empty
let sequence_alias_type_terms : (string, string) Hashtbl.t = Hashtbl.create 32
let flat_sequence_source_sorts : SSet.t ref = ref SSet.empty
let simple_alias_source_sorts : SSet.t ref = ref SSet.empty
let source_membership_sorts : SSet.t ref = ref SSet.empty
let nat_subsort_sorts : SSet.t ref = ref SSet.empty

type source_record_info = {
  rec_source_name : string;
  rec_sort : string;
  rec_ctor : string;
  rec_fields : string list;
}

let source_record_infos : source_record_info list ref = ref []
let source_record_shape_counts : (string, int) Hashtbl.t = Hashtbl.create 32
let source_record_field_sorts : (string, string) Hashtbl.t = Hashtbl.create 128
let source_record_field_seq_elem_sorts : (string, string) Hashtbl.t = Hashtbl.create 128
let source_sort_type_atoms : (string, string) Hashtbl.t = Hashtbl.create 128
let source_var_sorts : (string, string) Hashtbl.t = Hashtbl.create 512
let source_var_seq_elem_sorts : (string, string) Hashtbl.t = Hashtbl.create 512
let typed_index_helper_sorts : SSet.t ref = ref SSet.empty
let source_seq_pred_sorts : SSet.t ref = ref SSet.empty
let source_category_subsort_edges : (string, SSet.t) Hashtbl.t = Hashtbl.create 128

let record_shape_key fields = String.concat "\x1f" fields

let source_record_ctor_name sort arity =
  Printf.sprintf "REC%sA%d" sort arity

let source_record_field_key record_sort field =
  record_sort ^ "." ^ field

let source_record_sequence_elem_sort_exists sort =
  Hashtbl.fold
    (fun _ elem found -> found || elem = sort)
    source_record_field_seq_elem_sorts
    false

let unique_source_record_by_fields fields =
  let key = record_shape_key fields in
  match Hashtbl.find_opt source_record_shape_counts key with
  | Some 1 ->
      List.find_opt (fun info -> record_shape_key info.rec_fields = key)
        !source_record_infos
  | _ -> None

let rec source_type_term_of_typ_simple (t : typ) : string option =
  match t.it with
  | VarT (id, []) -> Some (sanitize id.it)
  | IterT (inner, (List | List1 | ListN _)) ->
      Option.map
        (fun inner -> Printf.sprintf "list ( %s )" inner)
        (source_type_term_of_typ_simple inner)
  | IterT (inner, Opt) -> source_type_term_of_typ_simple inner
  | _ -> None

let build_type_env defs =
  Hashtbl.reset plural_types;
  Hashtbl.reset source_record_shape_counts;
  Hashtbl.reset source_category_subsort_edges;
  Hashtbl.reset sequence_alias_type_terms;
  Hashtbl.reset source_record_field_sorts;
  Hashtbl.reset source_record_field_seq_elem_sorts;
  Hashtbl.reset source_sort_type_atoms;
  Hashtbl.reset source_var_sorts;
  Hashtbl.reset source_var_seq_elem_sorts;
  zero_arity_source_sorts := SSet.empty;
  sequence_alias_sorts := SSet.empty;
  flat_sequence_source_sorts := SSet.empty;
  simple_alias_source_sorts := SSet.empty;
  source_membership_sorts := SSet.empty;
  nat_subsort_sorts := SSet.empty;
  source_record_infos := [];
  typed_index_helper_sorts := SSet.empty;
  let rec scan d = match d.it with
    | RecD ds -> List.iter scan ds
    | TypD (id, _params, insts) ->
        Hashtbl.replace source_sort_type_atoms (sort_of_type_name id.it) (sanitize id.it);
        List.iter (fun inst -> match inst.it with
          | InstD (_, _, deftyp) -> (match deftyp.it with
	              | AliasT typ -> (match typ.it with
	                  | IterT (_, (List | List1 | ListN _)) ->
                      let alias_sort = sort_of_type_name id.it in
	                      Hashtbl.replace plural_types id.it true;
	                      sequence_alias_sorts :=
	                        SSet.add alias_sort !sequence_alias_sorts;
                      (match source_type_term_of_typ_simple typ with
                       | Some ty -> Hashtbl.replace sequence_alias_type_terms alias_sort ty
                       | None -> ())
	                  | VarT (tid, args)
	                    when String.lowercase_ascii tid.it = "list" && args <> [] ->
                      let alias_sort = sort_of_type_name id.it in
	                      Hashtbl.replace plural_types id.it true;
	                      sequence_alias_sorts :=
	                        SSet.add alias_sort !sequence_alias_sorts;
                      (match source_type_term_of_typ_simple typ with
                       | Some ty -> Hashtbl.replace sequence_alias_type_terms alias_sort ty
                       | None -> ())
	                  | _ -> ())
              | StructT fields ->
                  let rec_sort = sort_of_type_name id.it in
                  let rec_fields =
                    List.map (fun (atom, _, _) ->
                      to_var_name (Xl.Atom.name atom)
                    ) fields
                  in
                  List.iter (fun (atom, (_, ft, _), _) ->
                    let field = to_var_name (Xl.Atom.name atom) in
                    let key = source_record_field_key rec_sort field in
                    (match simple_sort_of_typ ft [] with
                     | Some sort -> Hashtbl.replace source_record_field_sorts key sort
                     | None -> ());
                    (match ft.it with
                     | IterT (inner, (List | List1 | ListN _)) ->
                         (match simple_sort_of_typ inner [] with
                          | Some elem_sort ->
                              Hashtbl.replace source_record_field_sorts key "SpectecTerminals";
                              Hashtbl.replace source_record_field_seq_elem_sorts key elem_sort
                          | None -> ())
                     | _ -> ())
                  ) fields;
                  let info = {
                    rec_source_name = id.it;
                    rec_sort;
                    rec_ctor = source_record_ctor_name rec_sort (List.length rec_fields);
                    rec_fields;
                  } in
                  source_record_infos := info :: !source_record_infos;
                  let key = record_shape_key rec_fields in
                  let old = match Hashtbl.find_opt source_record_shape_counts key with
                    | Some n -> n
                    | None -> 0
                  in
                  Hashtbl.replace source_record_shape_counts key (old + 1)
              | _ -> ())
        ) insts
    | _ -> ()
  in
  List.iter scan defs;

  let typ_defs =
    let acc = ref [] in
    let rec collect d = match d.it with
      | RecD ds -> List.iter collect ds
      | TypD (id, params, insts) ->
          acc := (sort_of_type_name id.it, id.it, params, insts) :: !acc
      | _ -> ()
    in
    List.iter collect defs;
    !acc
  in
  let rec typ_is_nat_carrier known t =
    match t.it with
    | VarT (id, _) ->
        let raw = String.lowercase_ascii id.it in
        raw = "nat"
        || raw = "un"
        || SSet.mem (sort_of_type_name id.it) known
    | IterT (inner, Opt) -> typ_is_nat_carrier known inner
    | NumT `NatT -> true
    | _ -> false
  in
  let inst_is_nat_alias known inst =
    match inst.it with
    | InstD (binders, args, deftyp) ->
        binders = [] && args = [] &&
        (match deftyp.it with
         | AliasT typ -> typ_is_nat_carrier known typ
         | _ -> false)
  in
  let rec fix_nat known =
    let next =
      List.fold_left (fun acc (sort, _raw, params, insts) ->
        if params = [] && insts <> [] && List.for_all (inst_is_nat_alias known) insts
        then SSet.add sort acc
        else acc)
        known typ_defs
    in
    if SSet.equal known next then known else fix_nat next
  in
  nat_subsort_sorts := SSet.remove "Nat" (fix_nat SSet.empty);
  source_membership_sorts :=
    typ_defs
    |> List.fold_left (fun acc (sort, _raw, params, _insts) ->
        if params = [] && not (SSet.mem sort !sequence_alias_sorts)
        then SSet.add sort acc
        else acc)
      SSet.empty;
  let rec typ_ref_sort t =
    match t.it with
    | VarT (id, []) -> Some (sort_of_type_name id.it)
    | IterT (inner, Opt) -> typ_ref_sort inner
    | _ -> None
  in
  let add_source_category_subsort child parent =
    if child <> parent then
      let parents =
        match Hashtbl.find_opt source_category_subsort_edges child with
        | Some ps -> ps
        | None -> SSet.empty
      in
      Hashtbl.replace source_category_subsort_edges child (SSet.add parent parents)
  in
  let mixop_is_empty mixop_val =
    mixop_val
    |> List.flatten
    |> List.for_all (fun atom -> Xl.Atom.name atom = "")
  in
  List.iter
    (fun (parent_sort, _raw, params, insts) ->
      if params = [] then
        List.iter
          (fun inst -> match inst.it with
            | InstD (binders, args, deftyp)
              when binders = [] && args = [] ->
                (match deftyp.it with
                 | AliasT typ ->
                     (match typ_ref_sort typ with
                      | Some child -> add_source_category_subsort child parent_sort
                      | None -> ())
                 | VariantT cases ->
                     List.iter
                       (fun (mixop_val, (_, case_typ, prems), _) ->
                         if prems = [] && mixop_is_empty mixop_val then
                           match typ_ref_sort case_typ with
                           | Some child -> add_source_category_subsort child parent_sort
                           | None -> ())
                       cases
                 | StructT _ -> ())
            | _ -> ())
          insts)
    typ_defs;
	  let typ_constructor_arity t =
	    match t.it with
	    | TupT fields -> List.length fields
	    | VarT _ | IterT _ | BoolT | NumT _ | TextT -> 1
	  in
  typ_defs
  |> List.iter (fun (parent_sort, _raw, params, insts) ->
      if params = [] then
        List.iter (fun inst -> match inst.it with
          | InstD (binders, args, deftyp)
            when binders = [] && args = [] ->
              (match deftyp.it with
               | VariantT cases ->
                   if List.exists
                        (fun (mixop_val, (_, case_typ, _prems), _) ->
                          mixop_is_empty mixop_val && typ_constructor_arity case_typ > 1)
                        cases
                   then flat_sequence_source_sorts :=
                     SSet.add parent_sort !flat_sequence_source_sorts
               | _ -> ())
          | _ -> ())
          insts);
	  let mixop_has_zero_arity_ctor mixop_val =
    let compact_alnum s =
      let b = Buffer.create (String.length s) in
      String.iter (fun c ->
        if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
        then Buffer.add_char b c
      ) s;
      Buffer.contents b
    in
    mixop_val
    |> List.flatten
    |> List.exists (fun atom ->
        let name = compact_alnum (Xl.Atom.name atom) in
        name <> "")
  in
  let variant_case_is_zero_arity known (mixop_val, (_, case_typ, prems), _) =
    prems = []
    && ((mixop_has_zero_arity_ctor mixop_val && typ_constructor_arity case_typ = 0)
        || match typ_ref_sort case_typ with
           | Some s -> SSet.mem s known
           | None -> false)
  in
  let inst_is_zero_arity known inst =
    match inst.it with
    | InstD (binders, args, deftyp) ->
        binders = [] && args = [] &&
        (match deftyp.it with
         | VariantT cases ->
             cases <> [] && List.for_all (variant_case_is_zero_arity known) cases
         | AliasT typ ->
             (match typ_ref_sort typ with
              | Some s -> SSet.mem s known
              | None -> false)
         | _ -> false)
  in
  let rec fix known =
    let next =
      List.fold_left (fun acc (sort, _raw, params, insts) ->
        if params = [] && insts <> [] && List.for_all (inst_is_zero_arity known) insts
        then SSet.add sort acc
        else acc)
        known typ_defs
    in
    if SSet.equal known next then known else fix next
  in
  zero_arity_source_sorts := fix SSet.empty;

  let builtin_narrow_sort s =
    List.mem s [ "Bool"; "Nat"; "Int"; "SpectecTerminal"; "SpectecTerminals" ]
  in
  let typ_is_simple_alias known t =
    match t.it with
    | IterT (_, (List | List1 | ListN _ | Opt)) -> false
    | VarT (id, args) ->
        let s = sort_of_type_name id.it in
        args <> []
        || builtin_narrow_sort s
        || SSet.mem s known
        || SSet.mem s !zero_arity_source_sorts
    | BoolT | NumT _ | TextT -> true
    | _ -> false
  in
  let inst_is_simple_alias known inst =
    match inst.it with
    | InstD (binders, args, deftyp) ->
        binders = [] && args = [] &&
        (match deftyp.it with
         | AliasT typ -> typ_is_simple_alias known typ
         | _ -> false)
  in
  let rec fix_alias known =
    let next =
      List.fold_left (fun acc (sort, _raw, params, insts) ->
        if params = [] && insts <> [] && List.for_all (inst_is_simple_alias known) insts
        then SSet.add sort acc
        else acc)
        known typ_defs
    in
    if SSet.equal known next then known else fix_alias next
  in
  simple_alias_source_sorts := fix_alias SSet.empty

let is_plural_type name = Hashtbl.mem plural_types name

(* ========================================================================= *)
(* 4. Mixfix operator interleaving                                           *)
(* ========================================================================= *)

let mixop_sections (mixop : Xl.Mixop.mixop) =
  let trim_tail_hyphen s =
    let rec go x =
      let n = String.length x in
      if n > 0 && x.[n - 1] = '-' then go (String.sub x 0 (n - 1)) else x
    in
    go s
  in
  List.map (fun atoms ->
    atoms |> List.map Xl.Atom.name |> String.concat "" |> sanitize |> trim_tail_hyphen
  ) mixop

let canonical_ctor_name_arity (mixop : Xl.Mixop.mixop) arity =
  let compact_alnum s =
    let b = Buffer.create (String.length s) in
    String.iter (fun c ->
      if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
      then Buffer.add_char b c
    ) s;
    String.uppercase_ascii (Buffer.contents b)
  in
  let atoms =
    mixop_sections mixop
    |> List.filter (fun s -> s <> "")
    |> List.filter (fun s -> s <> "%" && s <> "$")
    |> List.map compact_alnum
    |> List.filter (fun s -> s <> "")
  in
  match atoms with
  | [] -> None
  | _ -> Some (Printf.sprintf "CTOR%sA%d" (String.concat "" atoms) arity)

let interleave_lhs sections vars =
  let norm_var v =
    let s = String.trim v in
    if s = "" || s = "eps" then s else Printf.sprintf "( %s )" s
  in
  let rec go secs vs = match secs, vs with
    | [], rest -> List.map norm_var rest
    | s :: ss, v :: vs' -> (if s <> "" then [s; norm_var v] else [norm_var v]) @ go ss vs'
    | [s], [] -> if s <> "" then [s] else []
    | _ :: ss, [] -> go ss []
  in
  String.concat " " (go sections vars)

let interleave_op sections n_vars =
  let rec go secs n = match secs, n with
    | [], n -> List.init n (fun _ -> "_")
    | s :: ss, n when n > 0 -> (if s <> "" then [s; "_"] else ["_"]) @ go ss (n - 1)
    | [s], 0 -> if s <> "" then [s] else []
    | _ :: ss, 0 -> go ss 0
    | _, _ -> []
  in
  String.concat " " (go sections n_vars)

let find_opt_param_indices case_typ =
  let rec scan t is_opt idx = match t.it with
    | VarT _ -> ((if is_opt then [idx] else []), idx + 1)
    | IterT (inner, Opt) -> scan inner true idx
    | IterT (inner, _) -> scan inner is_opt idx
    | TupT fields ->
        List.fold_left (fun (acc, i) (_, ft) ->
          let (idxs, i') = scan ft is_opt i in
          (acc @ idxs, i')
        ) ([], idx) fields
    | _ -> ([], idx)
  in
  fst (scan case_typ false 0)

(* ========================================================================= *)
(* 5. Declaration management                                                 *)
(*                                                                           *)
(* [declared_vars] is intentionally mutable shared state:  declarations are  *)
(* global within a single Maude module and must be deduplicated.             *)
(* ========================================================================= *)

let declared_vars : (string, string) Hashtbl.t = Hashtbl.create 2048

let normalize_decl_sort name sort =
  let last_fragment s =
    match List.rev (String.split_on_char '-' s) with
    | x :: _ -> x
    | [] -> s
  in
  let looks_like_sequence_var s =
    let frag = last_fragment s in
    let len = String.length frag in
    let excluded =
      List.mem frag
        [ "LIMITS"; "STATUS"; "MODULES"; "S"; "ZS" ]
    in
    not excluded
    && (List.mem frag
          [ "IS"; "ISQ"; "IQS"; "KS"; "KSQ"; "KQS";
            "TS"; "TSQ"; "TQS"; "VS"; "VSQ"; "VQS";
            "WS"; "WSQ"; "WQS"; "XS"; "XSQ"; "XQS" ]
        || (len > 2 && (ends_with frag "S" || ends_with frag "SQ" || ends_with frag "QS")))
  in
  if sort = "SpectecTerminal"
     && ((String.contains name '-'
          && (try
                ignore (Str.search_forward (Str.regexp_string "-LIST-") name 0);
                true
              with Not_found -> false))
         || looks_like_sequence_var name)
  then "SpectecTerminals"
  else sort

let init_declared_vars () =
  Hashtbl.reset declared_vars;
  rewrite_defs_seen := SSet.empty;
  List.iter (fun (v, s) -> Hashtbl.replace declared_vars v s)
    [ ("I", "Int"); ("W-I", "Int"); ("EXP", "Int");
      ("W-N", "Nat"); ("W-M", "Nat");
      ("ZS", "State");
      ("T", "SpectecTerminal"); ("W", "SpectecTerminal");
      ("WW", "SpectecTerminal");
      ("TS", "SpectecTerminals"); ("W*", "SpectecTerminals") ]

let declare_var name sort =
  let sort = normalize_decl_sort name sort in
  if Hashtbl.mem declared_vars name then ""
  else (Hashtbl.replace declared_vars name sort;
        Printf.sprintf "  var %s : %s .\n" name sort)

let _declare_op_const name sort =
  if Hashtbl.mem declared_vars name then ""
  else (Hashtbl.replace declared_vars name sort;
        Printf.sprintf "  op %s : -> %s .\n" name sort)

let declare_batch emit names sort =
  let fresh = names
    |> List.sort_uniq String.compare
    |> List.filter (fun n -> not (Hashtbl.mem declared_vars n))
  in
  let fresh = List.map (fun n -> (n, normalize_decl_sort n sort)) fresh in
  List.iter (fun (n, s) -> Hashtbl.replace declared_vars n s) fresh;
  match emit, fresh with
  | _, [] -> ""
  | `Vars, _ ->
      let groups =
        List.fold_left (fun acc (n, s) ->
          let existing = match List.assoc_opt s acc with Some vs -> vs | None -> [] in
          (s, n :: existing) :: List.remove_assoc s acc
        ) [] fresh
      in
      groups
      |> List.map (fun (s, vs) ->
           Printf.sprintf "  vars %s : %s .\n" (String.concat " " (List.rev vs)) s)
      |> String.concat ""
  | `Ops, _ -> String.concat "" (List.map (fun (n, s) ->
      Printf.sprintf "  op %s : -> %s .\n" n s) fresh)

let declare_vars_same_sort names sort = declare_batch `Vars names sort
let declare_ops_const_list names sort = declare_batch `Ops names sort

let declare_vars_by_sort pairs =
  pairs
  |> List.map (fun (v, s) -> (v, normalize_decl_sort v s))
  |> List.sort_uniq compare
  |> List.fold_left (fun acc (v, s) ->
      let vs = match List.assoc_opt s acc with Some xs -> xs | None -> [] in
      (s, v :: vs) :: List.remove_assoc s acc
    ) []
  |> List.map (fun (s, vs) -> declare_vars_same_sort (List.rev vs) s)
  |> String.concat ""

(* ========================================================================= *)
(* 6. Pre-scan phase                                                         *)
(* ========================================================================= *)

type scan_state = {
  mutable tokens    : SSet.t;
  mutable calls     : SIPairSet.t;
  mutable dec_funcs : SSet.t;
  mutable bool_calls: SSet.t;
  mutable rewrite_defs: SSet.t;
  mutable ctors     : SSet.t;
  mutable scan_uses_sequence_index : bool;
  mutable scan_uses_repeat : bool;
  mutable scan_uses_slice : bool;
  mutable scan_uses_set_membership : bool;
  mutable scan_uses_merge : bool;
  mutable scan_uses_any : bool;
  mutable scan_uses_record_literal : bool;
  mutable scan_uses_record_projection : bool;
  mutable scan_uses_record_update : bool;
  mutable scan_uses_record_extend : bool;
  mutable scan_uses_sequence_update : bool;
}

let new_scan () = {
  tokens = SSet.empty; calls = SIPairSet.empty;
  dec_funcs = SSet.empty; bool_calls = SSet.empty;
  rewrite_defs = SSet.empty;
  ctors = SSet.empty;
  scan_uses_sequence_index = false;
  scan_uses_repeat = false;
  scan_uses_slice = false;
  scan_uses_set_membership = false;
  scan_uses_merge = false;
  scan_uses_any = false;
  scan_uses_record_literal = false;
  scan_uses_record_projection = false;
  scan_uses_record_update = false;
  scan_uses_record_extend = false;
  scan_uses_sequence_update = false;
}

let scan_add_token ss raw =
  let low = String.lowercase_ascii raw in
  if low <> "true" && low <> "false" then
    let tok = sanitize raw in
    if tok <> "" then ss.tokens <- SSet.add tok ss.tokens

let scan_mixop_tokens ss mixop =
  List.iter (fun atoms ->
    List.iter (fun a ->
      let raw = Xl.Atom.name a in
      if raw <> "$" && raw <> "%" then scan_add_token ss raw
    ) atoms
  ) mixop

let rec scan_exp ss (e : exp) = match e.it with
  | VarE id ->
    if id.it = "_" then (
      ss.scan_uses_any <- true;
      ss.tokens <- SSet.add "any" ss.tokens)
  | CaseE (mixop, inner) ->
      scan_mixop_tokens ss mixop;
      scan_exp ss inner
  | TupE es | ListE es -> List.iter (scan_exp ss) es
  | UnE (_, _, e1) | CvtE (e1, _, _) | SubE (e1, _, _) | ProjE (e1, _)
  | UncaseE (e1, _) | LenE e1 | OptE (Some e1) | TheE e1
  | LiftE e1 | DotE (e1, _) -> scan_exp ss e1
  | IterE (e1, (ListN _, _)) ->
      ss.scan_uses_repeat <- true;
      scan_exp ss e1
  | IterE (e1, _) -> scan_exp ss e1
  | BinE (_, _, e1, e2) | CmpE (_, _, e1, e2) | CatE (e1, e2) ->
      scan_exp ss e1; scan_exp ss e2
  | UpdE (e1, path, e2) ->
      scan_exp ss e1; scan_update_path ss `Update path; scan_exp ss e2
  | ExtE (e1, path, e2) ->
      scan_exp ss e1; scan_update_path ss `Extend path; scan_exp ss e2
  | MemE (e1, e2) ->
      ss.scan_uses_set_membership <- true;
      scan_exp ss e1; scan_exp ss e2
  | IdxE (e1, e2) ->
      ss.scan_uses_sequence_index <- true;
      scan_exp ss e1; scan_exp ss e2
  | CompE (e1, e2) ->
      ss.scan_uses_merge <- true;
      scan_exp ss e1; scan_exp ss e2
  | SliceE (e1, e2, e3) ->
      ss.scan_uses_slice <- true;
      scan_exp ss e1; scan_exp ss e2; scan_exp ss e3
  | IfE (e1, e2, e3) ->
      scan_exp ss e1; scan_exp ss e2; scan_exp ss e3
  | StrE fields ->
      let field_names =
        List.map (fun (atom, _) -> to_var_name (Xl.Atom.name atom)) fields
      in
      (match unique_source_record_by_fields field_names with
       | Some _ -> ()
       | None -> ss.scan_uses_record_literal <- true);
      List.iter (fun (_, e1) -> scan_exp ss e1) fields
  | CallE (id, args) ->
      let cn = call_name id.it in
      if cn <> "w-$" then ss.calls <- SIPairSet.add (cn, List.length args) ss.calls;
      List.iter (fun a -> match a.it with ExpA e1 -> scan_exp ss e1 | _ -> ()) args
  | OptE None | BoolE _ | NumE _ | TextE _ -> ()

and scan_path_features ss (p : path) =
  match p.it with
  | RootP -> ()
  | DotP (parent, _) ->
      ss.scan_uses_record_projection <- true;
      scan_path_features ss parent
  | IdxP (parent, idx) ->
      ss.scan_uses_sequence_index <- true;
      scan_exp ss idx;
      scan_path_features ss parent
  | SliceP (parent, e_s, e_e) ->
      ss.scan_uses_slice <- true;
      scan_exp ss e_s;
      scan_exp ss e_e;
      scan_path_features ss parent

and scan_update_path ss kind (p : path) =
  let rec has_dot p =
    match p.it with
    | RootP -> false
    | DotP _ -> true
    | IdxP (parent, _) | SliceP (parent, _, _) -> has_dot parent
  in
  let rec has_sequence_update p =
    match p.it with
    | RootP -> false
    | DotP (parent, _) -> has_sequence_update parent
    | IdxP _ | SliceP _ -> true
  in
  scan_path_features ss p;
  if has_dot p then (
    ss.scan_uses_record_update <- true;
    match kind with
    | `Extend -> ss.scan_uses_record_extend <- true
    | `Update -> ());
  if has_sequence_update p then ss.scan_uses_sequence_update <- true

let rec scan_bool_exp ss (e : exp) = match e.it with
  | CallE (id, args) ->
      ss.bool_calls <- SSet.add (call_name id.it) ss.bool_calls;
      List.iter (fun a -> match a.it with ExpA e1 -> scan_exp ss e1 | _ -> ()) args
  | BinE ((`AndOp | `OrOp | `ImplOp), _, e1, e2) ->
      scan_bool_exp ss e1; scan_bool_exp ss e2
  | UnE (`NotOp, _, e1) -> scan_bool_exp ss e1
  | _ -> scan_exp ss e

let rec scan_prem ss (p : prem) = match p.it with
  | IfPr e -> scan_bool_exp ss e
  | RulePr (_, _, e) -> scan_exp ss e
  | LetPr (e1, e2, _) -> scan_exp ss e1; scan_exp ss e2
  | ElsePr -> ()
  | IterPr (inner, _) | NegPr inner -> scan_prem ss inner

let rec scan_def ss (d : def) = match d.it with
  | RecD ds -> List.iter (scan_def ss) ds
  | TypD (_, _, insts) ->
      List.iter (fun inst -> match inst.it with
        | InstD (_, _, deftyp) -> (match deftyp.it with
            | VariantT cases ->
                List.iter (fun (mixop_val, (_, _, prems), _) ->
                  (match List.flatten mixop_val with
                   | a :: _ ->
                       let cn = sanitize (Xl.Atom.name a) in
                       if cn <> "" then ss.ctors <- SSet.add cn ss.ctors
                   | [] -> ());
                  List.iter (scan_prem ss) prems
                ) cases
            | AliasT _ | StructT _ -> ())
      ) insts
  | DecD (id, _, _, insts) ->
      ss.dec_funcs <- SSet.add (call_name id.it) ss.dec_funcs;
      List.iter (fun inst -> match inst.it with
        | DefD (_, lhs_args, rhs, prems) ->
            List.iter (fun a -> match a.it with ExpA e -> scan_exp ss e | _ -> ()) lhs_args;
            scan_exp ss rhs; List.iter (scan_prem ss) prems
      ) insts
  | RelD (_, _, _, rules) ->
      List.iter (fun r -> match r.it with
        | RuleD (_, _, _, concl, prems) ->
            scan_exp ss concl; List.iter (scan_prem ss) prems
      ) rules
  | GramD _ | HintD _ -> ()

let build_token_ops ss =
  let starts_with s p =
    let ls = String.length s and lp = String.length p in
    ls >= lp && String.sub s 0 lp = p
  in
  let toks =
    SSet.diff ss.tokens ss.ctors
    |> SSet.elements
    |> List.filter (fun t -> not (starts_with t "CTOR"))
  in
  if toks = [] then ""
  else
    let rec chunks acc = function
      | [] -> List.rev acc
      | lst ->
          let hd = List.filteri (fun i _ -> i < 20) lst in
          let tl = List.filteri (fun i _ -> i >= 20) lst in
          chunks (("  ops " ^ String.concat " " hd ^ " : -> SpectecTerminal [ctor] .\n") :: acc) tl
    in
    String.concat "" (chunks [] toks) ^ "\n"

let build_call_ops ss =
  let lines = SIPairSet.elements ss.calls
    |> List.filter (fun (name, arity) ->
         not (SSet.mem name ss.dec_funcs) && arity >= 0)
    |> List.map (fun (name, arity) ->
         let args = String.concat " " (List.init arity (fun _ -> "SpectecTerminal")) in
         let ret = if SSet.mem name ss.bool_calls then "Bool" else "SpectecTerminal" in
         Printf.sprintf "  op %s : %s -> %s .\n" name args ret)
  in
  if lines = [] then ""
  else "\n  --- Auto-declared helper calls\n" ^ String.concat "" lines ^ "\n"

(* ========================================================================= *)
(* 7. Expression translation                                                 *)
(*                                                                           *)
(* Pure functional: every function returns [texpr] carrying both the Maude   *)
(* text and the list of variable names encountered during traversal.         *)
(* ========================================================================= *)

let format_call fn = function
  | [] -> fn
  | args ->
      let norm_arg a =
        let s = String.trim a in
        if String.contains s ' ' then Printf.sprintf "( %s )" s else s
      in
      Printf.sprintf "%s ( %s )" fn (String.concat ", " (List.map norm_arg args))

let wrap_bool ctx s = match ctx with
  | BoolCtx -> s
  | TermCtx ->
      feature_uses_bool_wrapper := true;
      Printf.sprintf "w-bool ( %s )" s

let rec exp_is_boolish (e : exp) = match e.it with
  | BoolE _ | CmpE _ | MemE _ | UnE (`NotOp, _, _) -> true
  | BinE ((`AndOp | `OrOp | `ImplOp | `EquivOp), _, _, _) -> true
  | IfE (_, e1, e2) -> exp_is_boolish e1 && exp_is_boolish e2
  | _ -> false

let strip_iter_suffix name =
  let len = String.length name in
  if len = 0 then name
  else
    let last = name.[len - 1] in
    if last = '*' || last = '+' || last = '?' then String.sub name 0 (len - 1)
    else name

let is_sequence_typ t =
  match t.it with
  | IterT (_, (List | List1 | ListN _ | Opt)) -> true
  | VarT (id, args) when String.lowercase_ascii id.it = "list" && args <> [] -> true
  | _ -> false

let split_trailing_quotes s =
  let n = String.length s in
  let rec loop i =
    if i > 0 && s.[i - 1] = '\''
    then loop (i - 1)
    else i
  in
  let i = loop n in
  (String.sub s 0 i, String.sub s i (n - i))

let split_numeric_suffix s =
  let n = String.length s in
  let rec loop i =
    if i > 0 && s.[i - 1] >= '0' && s.[i - 1] <= '9'
    then loop (i - 1)
    else i
  in
  let i = loop n in
  if i < n && i > 0 && s.[i - 1] = '_' then
    (String.sub s 0 (i - 1), String.sub s (i - 1) (n - i + 1))
  else
    (s, "")

let pluralize_sequence_var_source_name raw =
  let raw = strip_iter_suffix raw in
  let raw_no_quote, quote_suffix = split_trailing_quotes raw in
  let core, numeric_suffix = split_numeric_suffix raw_no_quote in
  let core_low = String.lowercase_ascii core in
  let core_plural =
    if core = "" || ends_with core_low "s" then core
    else core ^ "s"
  in
  core_plural ^ numeric_suffix ^ quote_suffix

let source_name_for_binder raw typ =
  if is_sequence_typ typ then pluralize_sequence_var_source_name raw
  else strip_iter_suffix raw

let find_vm_case_insensitive name vm =
  match List.find_opt (fun (k, _) ->
    String.lowercase_ascii k = String.lowercase_ascii name) vm with
  | Some (_, mapped) -> Some mapped
  | None -> None

(** Resolve suffixed variable names like ["numtype_2"] to the 2nd
    ["numtype"] entry in [vm]. Handles the SpecTec convention where
    binder variables with numeric suffixes reference indexed params. *)
let resolve_suffixed name vm =
  let len = String.length name in
  let rec find_split i =
    if i <= 0 then None
    else if name.[i-1] >= '0' && name.[i-1] <= '9' then find_split (i-1)
    else if name.[i-1] = '_' && i < len then
      let base = String.sub name 0 (i-1) in
      let suffix = String.sub name i (len - i) in
      (try
         let idx = int_of_string suffix in
         let matches = vm
           |> List.filter (fun (k, _) ->
                String.lowercase_ascii k = String.lowercase_ascii base)
           |> List.rev in
         if idx >= 1 && idx <= List.length matches
         then Some (snd (List.nth matches (idx - 1)))
         else None
       with _ -> None)
    else None
  in
  find_split len

let resolve_var_name name vm =
  let probe n =
    match find_vm_case_insensitive n vm with
    | Some _ as hit -> hit
    | None -> resolve_suffixed n vm
  in
  match probe name with
  | Some _ as hit -> hit
  | None ->
      let base = strip_iter_suffix name in
      if base <> name then probe base
      else None

let rec unwrap_exp_for_source_sort (e : exp) =
  match e.it with
  | CvtE (e1, _, _) | SubE (e1, _, _) | ProjE (e1, _)
  | UncaseE (e1, _) | TheE e1 | LiftE e1 -> unwrap_exp_for_source_sort e1
  | _ -> e

let source_sort_of_var name vm =
  match resolve_var_name name vm with
  | Some mapped -> Hashtbl.find_opt source_var_sorts mapped
  | None -> None

let source_seq_elem_sort_of_var name vm =
  match resolve_var_name name vm with
  | Some mapped -> Hashtbl.find_opt source_var_seq_elem_sorts mapped
  | None -> None

let rec source_sort_of_exp (e : exp) vm =
  match (unwrap_exp_for_source_sort e).it with
  | VarE id -> source_sort_of_var id.it vm
  | DotE (parent, atom) ->
      (match source_sort_of_exp parent vm with
       | Some parent_sort ->
           Hashtbl.find_opt source_record_field_sorts
             (source_record_field_key parent_sort (to_var_name (Xl.Atom.name atom)))
       | None -> None)
  | IdxE (base, _) -> source_seq_elem_sort_of_exp base vm
  | _ -> None

and source_seq_elem_sort_of_exp (e : exp) vm =
  match (unwrap_exp_for_source_sort e).it with
  | VarE id -> source_seq_elem_sort_of_var id.it vm
  | DotE (parent, atom) ->
      (match source_sort_of_exp parent vm with
       | Some parent_sort ->
           Hashtbl.find_opt source_record_field_seq_elem_sorts
             (source_record_field_key parent_sort (to_var_name (Xl.Atom.name atom)))
       | None -> None)
  | _ -> None

let typed_index_helper_name = "$typed-index"

let typed_index_type_atom sort =
  match Hashtbl.find_opt source_sort_type_atoms sort with
  | Some atom -> atom
  | None -> String.lowercase_ascii sort

let typed_index_call elem_sort base_text idx_text =
  Printf.sprintf "%s ( %s, %s, %s )"
    typed_index_helper_name (typed_index_type_atom elem_sort) base_text idx_text

(* Global accumulator: ListN count variable -> sequence variable pairs.
   Populated by translate_exp when it encounters IterE with ListN iter.
   Reset at the start of each Step rule translation. *)
let g_listn_pairs : (string * string) list ref = ref []
let reset_listn_pairs () = g_listn_pairs := []
let record_listn_pair cnt seq =
  if not (List.mem (cnt, seq) !g_listn_pairs) then
    g_listn_pairs := (cnt, seq) :: !g_listn_pairs

let record_listn_pair_if_sequence_var count_t seq_t =
  let seq = strip_wrapping_parens seq_t.text |> String.trim in
  if is_plain_var_like seq then
    record_listn_pair count_t.text seq

let map_call_texpr_from_text (inner : texpr) =
  match parse_call_text inner.text with
  | Some (fn, args) ->
      let seq_positions =
        args
        |> List.mapi (fun i arg ->
            let arg_core = strip_wrapping_parens arg |> String.trim in
            if SSet.mem arg_core !g_sequence_binder_vars then Some i else None)
        |> List.filter_map (fun x -> x)
      in
      (match seq_positions with
       | [seq_i] ->
           let arg_sorts =
             List.init (List.length args) (fun i ->
                 if i = seq_i then "SpectecTerminals" else "SpectecTerminal")
           in
           let helper = register_map_call_helper fn (List.length args) seq_i arg_sorts in
           Some { text = format_call helper args; vars = inner.vars }
       | _ -> None)
  | None -> None

let texpr_looks_sequence (t : texpr) =
  let text = strip_wrapping_parens t.text |> String.trim in
  text = "eps"
  || Hashtbl.find_opt declared_vars text = Some "SpectecTerminals"
  || List.exists (fun v ->
      Hashtbl.find_opt declared_vars v = Some "SpectecTerminals"
      || normalize_decl_sort v "SpectecTerminal" = "SpectecTerminals")
      t.vars

let sequence_lift_arg_sorts seq_i arg_ts =
  arg_ts
  |> List.mapi (fun i t ->
      if i = seq_i || texpr_looks_sequence t
      then "SpectecTerminals"
      else "SpectecTerminal")

let source_call_sequence_positions args arg_ts vm =
  let direct_positions =
    args
    |> List.mapi (fun i a ->
        match a.it, List.nth arg_ts i with
        | ExpA { it = VarE vid; _ }, ({ text; vars = [v] } as _t) ->
            (match resolve_var_name (vid.it ^ "*") vm with
             | Some mapped when mapped = v && text = v -> Some i
             | _ -> None)
        | _ -> None)
    |> List.filter_map (fun x -> x)
  in
  match direct_positions with
  | [] ->
      arg_ts
      |> List.mapi (fun i t -> if texpr_looks_sequence t then Some i else None)
      |> List.filter_map (fun x -> x)
  | xs -> xs

let rec translate_exp ctx (e : exp) vm : texpr = match e.it with
  | VarE id -> translate_var ctx id.it vm
  | CaseE (mixop, inner) -> translate_case ctx mixop inner vm
  | NumE n -> texpr (match n with
      | `Nat z | `Int z -> Z.to_string z
      | `Rat q -> Z.to_string (Q.num q) ^ "/" ^ Z.to_string (Q.den q)
      | `Real r -> Printf.sprintf "%.17g" r)
  | CvtE (e1, _, _) | SubE (e1, _, _) | ProjE (e1, _)
  | UncaseE (e1, _) -> translate_exp ctx e1 vm
  | UnE (op, _, e1) -> (match op with
      | `MinusOp -> tmap (Printf.sprintf "_-_ ( 0, %s )") (translate_exp TermCtx e1 vm)
      | `PlusOp -> translate_exp TermCtx e1 vm
      | `NotOp ->
          let t = translate_exp BoolCtx e1 vm in
          { text = wrap_bool ctx (Printf.sprintf "not ( %s )" t.text); vars = t.vars })
  | BinE (op, _, e1, e2) -> translate_binop ctx op e1 e2 vm
  | CmpE (op, _, e1, e2) ->
      let op_str = match (op : cmpop) with
        | `LtOp -> "_<_" | `GtOp -> "_>_" | `LeOp -> "_<=_" | `GeOp -> "_>=_"
        | `EqOp -> "_==_" | `NeOp -> "_=/=_" in
      let t1 = translate_exp TermCtx e1 vm and t2 = translate_exp TermCtx e2 vm in
      { text = wrap_bool ctx (Printf.sprintf "%s ( %s, %s )" op_str t1.text t2.text);
        vars = t1.vars @ t2.vars }
  | CallE (id, args) ->
      let ts = List.map (fun a -> translate_arg a vm) args in
      let fname = sanitize id.it in
      let strs = List.map (fun t -> t.text) ts in
      let all_v = List.concat_map (fun t -> t.vars) ts in
      if fname = "w-$" then { text = String.concat ", " strs; vars = all_v }
      else
        let fn = if String.length fname > 0 && fname.[0] = '$' then fname
                 else "$" ^ fname in
        { text = format_call fn strs; vars = all_v }
  | TupE [] | ListE [] -> texpr "eps"
  | TupE [e1] -> translate_exp ctx e1 vm
  | TupE el | ListE el -> tconcat " " (List.map (fun x -> translate_exp TermCtx x vm) el)
  | BoolE b -> texpr (wrap_bool ctx (if b then "true" else "false"))
  | TextE s -> texpr ("\"" ^ s ^ "\"")
  | StrE fields ->
      let field_values = List.map (fun (atom, e1) ->
        let name = to_var_name (Xl.Atom.name atom) in
        let t = translate_exp TermCtx e1 vm in
        (name, t)
      ) fields in
      let field_names = List.map fst field_values in
      (match unique_source_record_by_fields field_names with
       | Some info ->
           let args = List.map snd field_values in
           { text = format_call info.rec_ctor (List.map (fun t -> t.text) args);
             vars = List.concat_map (fun t -> t.vars) args }
       | None ->
           let items = List.map (fun (name, t) ->
             { t with text = Printf.sprintf "item('%s, %s)" name t.text }
           ) field_values in
           { text = "{" ^ String.concat " ; " (List.map (fun t -> t.text) items) ^ "}";
             vars = List.concat_map (fun t -> t.vars) items })
  | DotE (e1, atom) ->
      tmap (Printf.sprintf "value('%s, %s)" (to_var_name (Xl.Atom.name atom)))
        (translate_exp TermCtx e1 vm)
  | CompE (e1, e2) ->
      tjoin2 (Printf.sprintf "merge ( %s , %s )")
        (translate_exp TermCtx e1 vm) (translate_exp TermCtx e2 vm)
  | MemE (e1, e2) ->
      let r = tjoin2 (Printf.sprintf "( %s <- %s )")
        (translate_exp TermCtx e1 vm) (translate_exp TermCtx e2 vm) in
      { r with text = wrap_bool ctx r.text }
  | LenE e1 ->
      tmap (Printf.sprintf "len ( %s )") (translate_exp TermCtx e1 vm)
  | CatE (e1, e2) ->
      tjoin2 (Printf.sprintf "%s %s")
        (translate_exp TermCtx e1 vm) (translate_exp TermCtx e2 vm)
  | IdxE (e1, e2) ->
      let base_t = translate_exp TermCtx e1 vm in
      let idx_t = translate_exp TermCtx e2 vm in
      (match source_seq_elem_sort_of_exp e1 vm with
       | Some elem_sort
         when SSet.mem elem_sort !flat_sequence_source_sorts
              && source_record_sequence_elem_sort_exists elem_sort ->
           { text = typed_index_call elem_sort base_t.text idx_t.text;
             vars = base_t.vars @ idx_t.vars }
       | _ ->
           { text = Printf.sprintf "index ( %s, %s )" base_t.text idx_t.text;
             vars = base_t.vars @ idx_t.vars })
  | SliceE (e1, e2, e3) ->
      tjoin3 (Printf.sprintf "slice ( %s, %s, %s )")
        (translate_exp TermCtx e1 vm) (translate_exp TermCtx e2 vm)
        (translate_exp TermCtx e3 vm)
  | UpdE (e1, path, e2) -> translate_bracket_op "<-" e1 path e2 vm
  | ExtE (e1, path, e2) -> translate_bracket_op "=++" e1 path e2 vm
  | OptE (Some e1) | TheE e1 | LiftE e1 -> translate_exp ctx e1 vm
  | OptE None -> texpr "eps"
  | IterE (e1, (iter_type, _)) ->
    let suffix = match iter_type with
      | List -> "*" | List1 -> "+" | Opt -> "?" | ListN _ -> "" in
    (match e1.it with
     | VarE id ->
         let full = id.it ^ suffix in
         (match resolve_var_name full vm with
          | Some mapped ->
              debug_iter "[ITER-MAP] kind=%s raw=%s probe=%s mapped=%s"
                suffix id.it full mapped;
              (match iter_type with
               | ListN (count_e, _) ->
                   (match count_e.it with
                    | VarE count_id ->
                        (match resolve_var_name count_id.it vm with
                         | Some cnt_mapped -> record_listn_pair cnt_mapped mapped
                         | None -> ())
                    | _ -> ())
               | _ -> ());
              texpr_with_var mapped mapped
          | None ->
              let fallback_raw =
                match iter_type with
                | List | List1 | ListN _ -> pluralize_sequence_var_source_name id.it
                | Opt -> id.it ^ "?"
              in
              let v = String.uppercase_ascii (sanitize fallback_raw) in
              texpr_with_var v v)
     | _ ->
         let inner = translate_exp ctx e1 vm in
         (match iter_type, e1.it with
          | ListN (count_e, _), _ ->
              (match count_e.it with
               | VarE _ ->
                   let count_t = translate_exp TermCtx count_e vm in
                   record_listn_pair_if_sequence_var count_t inner;
                   (match e1.it with
                    | CallE (id, args) ->
                        let arg_ts = List.map (fun a -> translate_arg a vm) args in
                        let seq_positions = source_call_sequence_positions args arg_ts vm in
                        (match seq_positions with
                         | seq_i :: _ ->
                             let fn = call_name id.it in
                             let arg_sorts = sequence_lift_arg_sorts seq_i arg_ts in
                             let helper =
                               register_map_call_helper fn (List.length arg_ts) seq_i arg_sorts
                             in
                             { text = format_call helper (List.map (fun (t : texpr) -> t.text) arg_ts);
                               vars =
                                 List.sort_uniq String.compare
                                   (List.concat_map (fun (t : texpr) -> t.vars) arg_ts) }
                         | [] -> inner)
                    | _ -> inner)
               | _ ->
                   let count_t = translate_exp TermCtx count_e vm in
                   { text = Printf.sprintf "$repeat ( %s, %s )" inner.text count_t.text;
                     vars = List.sort_uniq String.compare (inner.vars @ count_t.vars) })
          | (List | List1), CallE (id, args) ->
              let arg_ts = List.map (fun a -> translate_arg a vm) args in
              let seq_positions = source_call_sequence_positions args arg_ts vm in
              (match seq_positions with
               | [seq_i] ->
                   let fn = call_name id.it in
                   let arg_sorts = sequence_lift_arg_sorts seq_i arg_ts in
                   let helper = register_map_call_helper fn (List.length arg_ts) seq_i arg_sorts in
                   { text = format_call helper (List.map (fun (t : texpr) -> t.text) arg_ts);
                     vars =
                       List.sort_uniq String.compare
                         (List.concat_map (fun (t : texpr) -> t.vars) arg_ts) }
               | _ ->
	                   (match map_call_texpr_from_text inner, star_prefix_pattern inner.text with
	                    | Some mapped, _ -> mapped
	                    | None, Some (ctor, seq_var) ->
	                        { text = star_prefix_text ctor seq_var; vars = [seq_var] }
	                    | None, None -> inner))
          | (List | List1), _ ->
	              (match map_call_texpr_from_text inner, star_prefix_pattern inner.text with
	               | Some mapped, _ -> mapped
	               | None, Some (ctor, seq_var) ->
	                   { text = star_prefix_text ctor seq_var; vars = [seq_var] }
	               | None, None -> inner)
          | Opt, _ -> inner))
  | IfE (c, e1, e2) ->
      tjoin3 (Printf.sprintf "if %s then %s else %s fi")
        (translate_exp BoolCtx c vm) (translate_exp ctx e1 vm) (translate_exp ctx e2 vm)

and translate_var ctx name vm =
  match resolve_var_name name vm with
  | Some mapped -> texpr_with_var mapped mapped
  | None ->
      let low = String.lowercase_ascii name in
      if low = "true" then texpr (wrap_bool ctx "true")
      else if low = "false" then texpr (wrap_bool ctx "false")
      else if is_lower_token_id name then texpr (sanitize name)
      else let v = to_var_name name in texpr_with_var v v

and translate_case ctx mixop inner vm =
  let op_name =
    try List.flatten mixop |> List.map Xl.Atom.name |> String.concat ""
    with _ -> "" in
  if op_name = "$" || op_name = "%" || op_name = "" then
    translate_exp ctx inner vm
  else
    let args = match inner.it with
      | TupE es -> List.map (fun e -> translate_exp TermCtx e vm) es
      | _ -> [translate_exp TermCtx inner vm] in
    let arg_texts = List.map (fun t -> t.text) args in
    match canonical_ctor_name_arity mixop (List.length arg_texts) with
    | Some "CTORSEMICOLONA2" when List.length arg_texts = 2 ->
        { text = Printf.sprintf "( %s ; %s )" (List.nth arg_texts 0) (List.nth arg_texts 1);
          vars = List.concat_map (fun t -> t.vars) args }
    | Some ctor ->
        { text = format_call ctor arg_texts;
          vars = List.concat_map (fun t -> t.vars) args }
    | None ->
        { text = interleave_lhs (mixop_sections mixop) arg_texts;
          vars = List.concat_map (fun t -> t.vars) args }

and translate_binop ctx op e1 e2 vm =
  let (op_name, is_bool) = match (op : binop) with
    | `AddOp -> ("_+_", false) | `SubOp -> ("_-_", false) | `MulOp -> ("_*_", false)
    | `DivOp -> ("_quo_", false) | `ModOp -> ("_rem_", false) | `PowOp -> ("_^_", false)
    | `AndOp -> ("_and_", true) | `OrOp -> ("_or_", true)
    | `ImplOp -> ("_implies_", true) | `EquivOp -> ("_==_", true) in
  let sub_ctx = if is_bool then BoolCtx else TermCtx in
  let t1 = translate_exp sub_ctx e1 vm and t2 = translate_exp sub_ctx e2 vm in
  let text = Printf.sprintf "%s ( %s, %s )" op_name t1.text t2.text in
  { text = if is_bool then wrap_bool ctx text else text; vars = t1.vars @ t2.vars }

(* Translate `base [ path op= value ]` where `path` may be a chain of
   record-field accesses, list indices, and slices.  We build the Maude
   expression outside-in:

     base [. 'A <- (value('A, base) [ i <- (value('B, ...)) op= value ]) ]

   - `path_access p`: the Maude expression for the sub-value at `p`, read
     from `base` via `value(...)`/`index(...)`/`slice(...)`.
   - `path_update p new_val`: the Maude expression for `base` updated so
     that the value at `p` becomes `new_val`.  When `p` is non-root, the
     outer update is always `<-` (record/list update); `op` (either `<-`
     or `=++`) applies only at the innermost segment. *)
and translate_bracket_op op e1 path e2 vm =
  let t1 = translate_exp TermCtx e1 vm in
  let t2 = translate_exp TermCtx e2 vm in
  let base_text = t1.text in
  let vars_acc = ref (t1.vars @ t2.vars) in
  let rec path_access p =
    match p.it with
    | RootP -> base_text
    | DotP (parent, atom) ->
        let pa = path_access parent in
        let qid = "'" ^ String.uppercase_ascii (sanitize (Xl.Atom.name atom)) in
        Printf.sprintf "value(%s, %s)" qid pa
    | IdxP (parent, idx) ->
        let pa = path_access parent in
        let it = translate_exp TermCtx idx vm in
        vars_acc := !vars_acc @ it.vars;
        Printf.sprintf "index(%s, %s)" pa it.text
    | SliceP (parent, e_s, e_e) ->
        let pa = path_access parent in
        let es = translate_exp TermCtx e_s vm in
        let ee = translate_exp TermCtx e_e vm in
        vars_acc := !vars_acc @ es.vars @ ee.vars;
        Printf.sprintf "slice(%s, %s, %s)" pa es.text ee.text
  in
  (* update_at p v_text inner_op:
     returns the Maude text for `base` updated so that the value at path `p`
     becomes `v_text`, using `inner_op` (`<-` or `=++`) at the outermost
     segment of `p`.  Wraps recursively: non-root parents are collapsed via
     `<-` updates of the sub-value obtained through `path_access`. *)
  let rec update_at p v_text inner_op =
    match p.it with
    | RootP -> v_text
    | DotP (parent, atom) ->
        let qid = "'" ^ String.uppercase_ascii (sanitize (Xl.Atom.name atom)) in
        let parent_text = path_access parent in
        let this_upd =
          Printf.sprintf "( %s [. %s %s %s ] )" parent_text qid inner_op v_text in
        update_at parent this_upd "<-"
    | IdxP (parent, idx) ->
        let it = translate_exp TermCtx idx vm in
        vars_acc := !vars_acc @ it.vars;
        let parent_text = path_access parent in
        let this_upd =
          Printf.sprintf "( %s [ %s %s %s ] )" parent_text it.text inner_op v_text in
        update_at parent this_upd "<-"
    | SliceP (parent, e_s, e_e) ->
        let es = translate_exp TermCtx e_s vm in
        let ee = translate_exp TermCtx e_e vm in
        vars_acc := !vars_acc @ es.vars @ ee.vars;
        let parent_text = path_access parent in
        let this_upd =
          Printf.sprintf "( %s [ %s %s %s %s ] )"
            parent_text es.text ee.text inner_op v_text in
        update_at parent this_upd "<-"
  in
  let text = update_at path t2.text op in
  { text; vars = !vars_acc }

and translate_path (p : path) vm : texpr =
  let vars_acc = ref [] in
  let rec aux p =
    match p.it with
    | RootP -> ""
    | DotP (parent, atom) ->
        let pa = aux parent in
        let qid = "'" ^ String.uppercase_ascii (sanitize (Xl.Atom.name atom)) in
        if pa = "" then Printf.sprintf ". %s" qid
        else Printf.sprintf "%s . %s" pa qid
    | IdxP (parent, idx) ->
        let pa = aux parent in
        let it = translate_exp TermCtx idx vm in
        vars_acc := !vars_acc @ it.vars;
        if pa = "" then Printf.sprintf "[ %s ]" it.text
        else Printf.sprintf "%s [ %s ]" pa it.text
    | SliceP (parent, e_s, e_e) ->
        let pa = aux parent in
        let es = translate_exp TermCtx e_s vm in
        let ee = translate_exp TermCtx e_e vm in
        vars_acc := !vars_acc @ es.vars @ ee.vars;
        if pa = "" then Printf.sprintf "[ %s : %s ]" es.text ee.text
        else Printf.sprintf "%s [ %s : %s ]" pa es.text ee.text
  in
  { text = aux p; vars = !vars_acc }

and translate_arg (a : arg) vm : texpr = match a.it with
  | ExpA e -> translate_exp TermCtx e vm
  | TypA t -> translate_typ_texpr t vm
  | _ -> texpr "eps"

and is_ok_judgement_rel name =
  let low = String.lowercase_ascii name in
  let len = String.length low in
  let rec trailing_digits_start i =
    if i <= 0 then 0
    else
      let c = low.[i - 1] in
      if c >= '0' && c <= '9' then trailing_digits_start (i - 1) else i
  in
  let base_end = trailing_digits_start len in
  base_end >= 3 && String.sub low (base_end - 3) 3 = "-ok"

and is_rewrite_judgement_rel name =
  match String.lowercase_ascii name with
  | "steps" -> true
  | "eval-expr" -> true
  | _ -> false

and config_text z instr =
  Printf.sprintf "( %s ; %s )" z instr

and state_text store frame =
  Printf.sprintf "( %s ; %s )" store frame

and translate_prem (p : prem) vm : texpr = match p.it with
  | IfPr e -> translate_exp BoolCtx e vm
  | RulePr (id, _, e) ->
      let decompose_cfg exp =
        match exp.it with
        | CaseE (mixop, inner) ->
            let arity = match inner.it with TupE es -> List.length es | _ -> 1 in
            (match canonical_ctor_name_arity mixop arity with
             | Some name when name = "CTORSEMICOLONA2" ->
                 (match inner.it with
                  | TupE [z_e; instr_e] -> Some (z_e, instr_e)
                  | _ -> None)
             | _ -> None)
        | _ -> None
      in
      let ts = match e.it with
        | TupE el -> List.map (fun x -> translate_exp TermCtx x vm) el
        | _ -> [translate_exp TermCtx e vm] in
      let name = sanitize id.it in
      let all_vars = List.concat_map (fun t -> t.vars) ts in
      let text =
        if name = "Step-pure" then
          match e.it with
          | TupE [lhs; rhs] ->
              let lhs_t = translate_exp TermCtx lhs vm in
              let rhs_t = translate_exp TermCtx rhs vm in
              Printf.sprintf "step-pure ( %s ) => %s"
                lhs_t.text rhs_t.text
          | _ ->
              let call = format_call name (List.map (fun t -> t.text) ts) in
              Printf.sprintf "prove ( %s ) => proved" call
        else if name = "Step-read" then
          match e.it with
          | TupE [cfg_lhs; rhs] ->
              (match decompose_cfg cfg_lhs with
               | Some (z_e, lhs_e) ->
                   let z_t = translate_exp TermCtx z_e vm in
                   let lhs_t = translate_exp TermCtx lhs_e vm in
                   let rhs_t = translate_exp TermCtx rhs vm in
                   Printf.sprintf "step-read ( %s ) => %s"
                     (config_text z_t.text lhs_t.text) rhs_t.text
               | None ->
                   let call = format_call name (List.map (fun t -> t.text) ts) in
                   Printf.sprintf "prove ( %s ) => proved" call)
          | _ ->
              let call = format_call name (List.map (fun t -> t.text) ts) in
              Printf.sprintf "prove ( %s ) => proved" call
        else if name = "Step" then
          match e.it with
          | TupE [cfg_lhs; cfg_rhs] ->
              (match decompose_cfg cfg_lhs, decompose_cfg cfg_rhs with
               | Some (z_e, lhs_e), Some (zp_e, rhs_e) ->
                   let z_t = translate_exp TermCtx z_e vm in
                   let lhs_t = translate_exp TermCtx lhs_e vm in
                   let zp_t = translate_exp TermCtx zp_e vm in
                   let rhs_t = translate_exp TermCtx rhs_e vm in
                   Printf.sprintf "step ( %s ) => %s"
                     (config_text z_t.text lhs_t.text)
                     (config_text zp_t.text rhs_t.text)
               | _ ->
                   let call = format_call name (List.map (fun t -> t.text) ts) in
                   Printf.sprintf "prove ( %s ) => proved" call)
          | _ ->
              let call = format_call name (List.map (fun t -> t.text) ts) in
              Printf.sprintf "prove ( %s ) => proved" call
        else if name = "Steps" then
          match e.it with
          | TupE [cfg_lhs; cfg_rhs] ->
              (match decompose_cfg cfg_lhs, decompose_cfg cfg_rhs with
               | Some (z_e, lhs_e), Some (zp_e, rhs_e) ->
                   let z_t = translate_exp TermCtx z_e vm in
                   let lhs_t = translate_exp TermCtx lhs_e vm in
                   let zp_t = translate_exp TermCtx zp_e vm in
                   let rhs_t = translate_exp TermCtx rhs_e vm in
                   Printf.sprintf "steps ( %s ) => %s"
                     (config_text z_t.text lhs_t.text)
                     (config_text zp_t.text rhs_t.text)
               | _ ->
                   let call = format_call name (List.map (fun t -> t.text) ts) in
                   Printf.sprintf "%s => valid" call)
          | _ ->
              let call = format_call name (List.map (fun t -> t.text) ts) in
              Printf.sprintf "%s => valid" call
        else
          let call = format_call name (List.map (fun t -> t.text) ts) in
          if is_rewrite_judgement_rel name then
            Printf.sprintf "%s => valid" call
          else
            Printf.sprintf "%s => valid" call
      in
      let vars = all_vars in
      { text; vars }
  | LetPr (e1, e2, _) ->
      tjoin2 (Printf.sprintf "%s := %s")
        (translate_exp TermCtx e1 vm) (translate_exp TermCtx e2 vm)
  | ElsePr -> texpr "owise"
  | IterPr (inner, _) | NegPr inner -> translate_prem inner vm

and translate_typ (t : typ) vm : string = match t.it with
  | VarT (id, args) ->
      let name = match List.assoc_opt id.it vm with
        | Some mapped when mapped <> String.uppercase_ascii mapped -> mapped
        | _ -> sanitize id.it
      in
      if args = [] then name
      else Printf.sprintf "%s ( %s )" name
        (String.concat " , " (List.map (fun a -> (translate_arg a vm).text) args))
  | IterT (inner, (List | List1 | ListN _)) ->
      Printf.sprintf "list ( %s )" (translate_typ inner vm)
  | IterT (inner, Opt) -> translate_typ inner vm
  | _ -> "SpectecType"

and translate_typ_texpr (t : typ) vm : texpr =
  match t.it with
  | VarT (id, args) ->
      let name = match List.assoc_opt id.it vm with
        | Some mapped -> mapped
        | _ -> sanitize id.it
      in
      let arg_ts = List.map (fun a -> translate_arg a vm) args in
      let text =
        if arg_ts = [] then name
        else
          Printf.sprintf "%s ( %s )" name
            (String.concat " , " (List.map (fun a -> a.text) arg_ts))
      in
      let own_vars = if arg_ts = [] && is_upper_token name then [name] else [] in
      { text; vars = own_vars @ List.concat_map (fun a -> a.vars) arg_ts }
  | IterT (inner, (List | List1 | ListN _)) ->
      let it = translate_typ_texpr inner vm in
      { it with text = Printf.sprintf "list ( %s )" it.text }
  | IterT (inner, Opt) -> translate_typ_texpr inner vm
  | _ -> texpr "SpectecType"

let bool_sort_guard_for_exp (e : exp) vm =
  let t = translate_exp BoolCtx e vm in
  let text = String.trim t.text in
  if text = "" || text = "true" || text = "false" then []
  else [Printf.sprintf "%s : Bool" text]

let rec bool_sort_safety_conds_exp (e : exp) vm =
  let child_conds =
    match e.it with
    | VarE _ | NumE _ | BoolE _ | TextE _ | OptE None -> []
    | CvtE (e1, _, _) | SubE (e1, _, _) | ProjE (e1, _)
    | UncaseE (e1, _) | TheE e1 | LiftE e1 | OptE (Some e1)
    | LenE e1 ->
        bool_sort_safety_conds_exp e1 vm
    | UnE (_, _, e1) ->
        bool_sort_safety_conds_exp e1 vm
    | BinE (_, _, e1, e2) | CatE (e1, e2) | MemE (e1, e2)
    | IdxE (e1, e2) | CompE (e1, e2) ->
        bool_sort_safety_conds_exp e1 vm @ bool_sort_safety_conds_exp e2 vm
    | CmpE (_, _, e1, e2) ->
        bool_sort_safety_conds_exp e1 vm @ bool_sort_safety_conds_exp e2 vm
    | SliceE (e1, e2, e3) | IfE (e1, e2, e3) ->
        bool_sort_safety_conds_exp e1 vm
        @ bool_sort_safety_conds_exp e2 vm
        @ bool_sort_safety_conds_exp e3 vm
    | CallE (_, args) ->
        args |> List.concat_map (fun a -> bool_sort_safety_conds_arg a vm)
    | CaseE (_, inner) ->
        bool_sort_safety_conds_exp inner vm
    | TupE es | ListE es ->
        es |> List.concat_map (fun e -> bool_sort_safety_conds_exp e vm)
    | StrE fields ->
        fields |> List.concat_map (fun (_, e) -> bool_sort_safety_conds_exp e vm)
    | DotE (e1, _) ->
        bool_sort_safety_conds_exp e1 vm
    | IterE (e1, (iter, _)) ->
        let count_conds =
          match iter with
          | ListN (count_e, _) -> bool_sort_safety_conds_exp count_e vm
          | List | List1 | Opt -> []
        in
        bool_sort_safety_conds_exp e1 vm @ count_conds
    | UpdE (e1, path, e2) | ExtE (e1, path, e2) ->
        bool_sort_safety_conds_exp e1 vm
        @ bool_sort_safety_conds_path path vm
        @ bool_sort_safety_conds_exp e2 vm
  in
  let self_conds =
    match e.it with
    | CmpE _ | MemE _ | UnE (`NotOp, _, _) -> bool_sort_guard_for_exp e vm
    | BinE ((`AndOp | `OrOp | `ImplOp | `EquivOp), _, _, _) ->
        bool_sort_guard_for_exp e vm
    | _ -> []
  in
  List.sort_uniq String.compare (self_conds @ child_conds)

and bool_sort_safety_conds_arg (a : arg) vm =
  match a.it with
  | ExpA e -> bool_sort_safety_conds_exp e vm
  | TypA _ -> []
  | _ -> []

and bool_sort_safety_conds_path (p : path) vm =
  match p.it with
  | RootP -> []
  | DotP (parent, _) -> bool_sort_safety_conds_path parent vm
  | IdxP (parent, idx) ->
      bool_sort_safety_conds_path parent vm @ bool_sort_safety_conds_exp idx vm
  | SliceP (parent, e1, e2) ->
      bool_sort_safety_conds_path parent vm
      @ bool_sort_safety_conds_exp e1 vm
      @ bool_sort_safety_conds_exp e2 vm

let type_guard term typ vm =
  match simple_sort_of_typ typ vm with
  | Some s when SSet.mem s !sequence_alias_sorts ->
      (match Hashtbl.find_opt sequence_alias_type_terms s with
       | Some ty ->
           feature_uses_has_type := true;
           Printf.sprintf "( %s hasType ( %s ) ) : WellTyped" term ty
       | None -> Printf.sprintf "%s : %s" term s)
  | Some s -> Printf.sprintf "%s : %s" term s
  | None ->
      let ty = translate_typ typ vm in
      if ty = "SpectecType" then "true"
      else
        let has_var_ref =
          try
            let _ = Str.search_forward (Str.regexp "[A-Z][A-Z0-9-]*") ty 0 in
            true
          with Not_found -> false
        in
        if has_var_ref then "true"
        else (
          feature_uses_has_type := true;
          Printf.sprintf "( %s hasType ( %s ) ) : WellTyped" term ty)

let is_bool_typ t vm =
  let s = String.lowercase_ascii (translate_typ t vm) in
  s = "bool" || s = "w-b" ||
  (match t.it with
	   | VarT (tid, _) ->
       let low = String.lowercase_ascii tid.it in
       low = "bool" || low = "b"
   | _ -> false)

(* ========================================================================= *)
(* 8. Definition handlers                                                    *)
(* ========================================================================= *)

let base_types = SSet.empty

(** Extract variable name from an [ExpB] binder. *)
let binder_var_map binders =
  List.filter_map (fun b -> match b.it with
    | ExpB (tid, t) -> Some (tid.it, to_var_name (source_name_for_binder tid.it t))
    | _ -> None
  ) binders

let binder_type_conds binders =
  List.filter_map (fun b -> match b.it with
    | ExpB (tid, t) ->
        Some (type_guard (to_var_name (source_name_for_binder tid.it t)) t [])
    | _ -> None
  ) binders

let type_sort_of_typ (t : typ) vm : string option =
  simple_sort_of_typ t vm

let declared_sort_of_typ t =
  if is_bool_typ t [] then "Bool"
  else match type_sort_of_typ t [] with
    | Some s when s <> "SpectecTerminal" -> s
    | _ -> "SpectecTerminal"

let seq_decl_sort_of_inner_typ (inner : typ) =
  match simple_sort_of_typ inner [] with
  | Some "Val" -> "SpectecTerminals"
  | Some "Instr" -> "SpectecTerminals"
  | _ -> "SpectecTerminals"

let decl_sort_of_typ (t : typ) =
  match t.it with
  | IterT (inner, (List | List1 | ListN _)) ->
      seq_decl_sort_of_inner_typ inner
  | _ ->
      match type_sort_of_typ t [] with
      | Some s when SSet.mem s !sequence_alias_sorts -> "SpectecTerminals"
      | _ -> declared_sort_of_typ t

let source_carrier_sort_of_typ (t : typ) vm =
  if is_sequence_typ t then "SpectecTerminals"
  else
	    match simple_sort_of_typ t vm with
	    | Some s when SSet.mem s !sequence_alias_sorts
	               || SSet.mem s !flat_sequence_source_sorts -> "SpectecTerminals"
	    | Some s when s <> "SpectecTerminal" -> s
	    | _ -> "SpectecTerminal"

(* DecD helper functions operate on C1's coarse CTOR carrier, but must
   preserve runtime structural sorts used by generated configs/states. *)
let structural_decd_sorts =
  ["Config"; "State"; "Store"; "Frame"; "Judgement"]

let decd_sort_of_typ (t : typ) =
  match t.it with
  | IterT (_, (List | List1 | ListN _)) -> "SpectecTerminals"
  | _ ->
      if is_bool_typ t [] then "Bool"
      else
        match type_sort_of_typ t [] with
        | Some s when List.mem s structural_decd_sorts -> s
        | _ -> "SpectecTerminal"

let decd_binder_var_sorts binders vm =
  List.filter_map (fun b -> match b.it with
    | ExpB (v_id, t) ->
        (match List.assoc_opt v_id.it vm with
         | Some mv -> Some (mv, decd_sort_of_typ t)
         | None -> None)
    | _ -> None
  ) binders
  |> List.sort_uniq compare

(** Build a mapping from suffixed binder names (e.g. ["numtype_2"])
    to their corresponding indexed parameter names (e.g. ["NUMTYPE2"]). *)
let build_suffix_map binders =
  List.filter_map (fun b -> match b.it with
    | ExpB (tid, _) ->
        let name = tid.it in
        let len = String.length name in
        let rec find_split i =
          if i <= 0 then None
          else if name.[i-1] >= '0' && name.[i-1] <= '9' then find_split (i-1)
          else if name.[i-1] = '_' && i < len then
            Some (name, to_var_name (String.sub name 0 (i-1)) ^ String.sub name i (len - i))
          else None
        in
        find_split len
    | _ -> None
  ) binders

(* --- TypD handler -------------------------------------------------------- *)

let translate_typd id params insts =
  let name = sanitize id.it in
  let is_parametric = params <> [] in
  let type_sort = sort_of_type_name id.it in
  let sig_types = String.concat " " (List.map (fun _ -> "SpectecTerminal") params) in
  let mk_type_term_texpr args v_map =
    let arg_ts = List.map (fun a -> translate_arg a v_map) args in
    let args_str = String.concat " , " (List.map (fun a -> a.text) arg_ts) in
    { text = if args_str = "" then name else Printf.sprintf "%s ( %s )" name args_str;
      vars = List.concat_map (fun a -> a.vars) arg_ts }
  in
  (* Pure nat/integer meta-variable TYPES (N, M, K, n, m): Maude variables in
     equations conflict with constants "op X : -> SpectecType [ctor]".  We suppress
     the CONSTANT declaration but keep "sort X . subsort X < SpectecType ." so that
     membership axioms like "cmb T : N if ..." can still reference them as sorts. *)
  let pure_meta_var_names = SSet.of_list ["N"; "M"; "K"; "n"; "m"] in
  let is_pure_meta = SSet.mem id.it pure_meta_var_names in
  (* Sorts already declared in Maude built-in modules — skip sort/subsort declarations *)
  let maude_builtin_sorts = SSet.of_list ["Char"; "Zero"; "NzNat"; "Nat"; "Int"; "Bool"] in
  (* Sorts where instance axiom (cmb/mb) generation doesn't work — list-based or conflicting *)
  let skip_instance_sorts = SSet.of_list ["Char"; "Zero"; "NzNat"; "Nat"; "Int"; "Bool"; "Name"] in
  let sort_decl =
    if is_parametric || SSet.mem name base_types || type_sort = "SpectecTerminal"
       || SSet.mem type_sort maude_builtin_sorts then ""
    else Printf.sprintf "  sort %s .\n  subsort %s < SpectecType .\n" type_sort type_sort in
  let source_category_subsort_decl =
    Hashtbl.fold
      (fun child parents acc ->
        if SSet.mem type_sort parents then
          Printf.sprintf "  subsort %s < %s .\n" child type_sort :: acc
        else acc)
      source_category_subsort_edges
      []
    |> List.sort String.compare
    |> String.concat ""
  in
  let op_decl =
    if is_pure_meta || SSet.mem name base_types then ""
    else Printf.sprintf "  op %s : %s -> SpectecType [ctor] .\n" name sig_types in
  let uniq_vars_local vs = List.sort_uniq String.compare vs in
  let extract_vars_local s =
    let re = Str.regexp "[A-Z][A-Z0-9-]*" in
    let rec loop pos acc =
      match (try Some (Str.search_forward re s pos) with Not_found -> None) with
      | None -> acc
      | Some _ ->
          let tok = Str.matched_string s in
          loop (Str.match_end ()) (tok :: acc)
    in
    loop 0 [] |> List.sort_uniq String.compare
  in
  let is_keywordish_token_local v =
    List.mem v
      ["TRUE"; "FALSE"; "EPS"; "CONST"; "LOCAL-GET"; "GLOBAL-GET";
       "VAL"; "TYPE"; "MODULE"; "LOCALS"]
  in
  let is_upper_initial_local v =
    String.length v > 0 &&
    let c = v.[0] in
    c >= 'A' && c <= 'Z'
  in
  let is_hyphen_var_like_local v =
    if not (String.contains v '-') then true
    else
      let parts = String.split_on_char '-' v |> List.filter (fun s -> s <> "") in
      match List.rev parts with
      | [] -> false
      | last :: _ ->
          String.exists (fun c -> c >= '0' && c <= '9') v || String.length last <= 2
  in
  let is_bindable_name_local v =
    v <> "" && is_upper_initial_local v && is_hyphen_var_like_local v
    && not (starts_with v "CTOR")
    && not (is_keywordish_token_local v)
  in
  let vars_of_texpr_local (t : texpr) =
    let extracted = extract_vars_local t.text |> List.filter is_bindable_name_local in
    uniq_vars_local (t.vars @ extracted)
  in
  let finite_numeric_membership_literals lhs rhs =
    let var = strip_wrapping_parens lhs |> String.trim in
    if not (is_plain_var_like var) || rhs = "" || not (contains_substring rhs "_==_")
       || contains_substring rhs "_/=_"
       || contains_substring rhs "_<_"
       || contains_substring rhs "_>_"
       || contains_substring rhs "_<=_"
       || contains_substring rhs "_>=_"
    then []
    else
      let rhs_without_var =
        Str.global_replace (Str.regexp_string var) "" rhs
      in
      let cleaned =
        rhs_without_var
        |> Str.global_replace (Str.regexp_string "_or_") ""
        |> Str.global_replace (Str.regexp_string "_==_") ""
        |> Str.global_replace (Str.regexp "[0-9]+") ""
        |> Str.global_replace (Str.regexp "[(), \t]") ""
        |> String.trim
      in
      if cleaned <> "" then []
      else
        let re = Str.regexp "[0-9]+" in
        let rec loop pos acc =
          match (try Some (Str.search_forward re rhs pos) with Not_found -> None) with
          | None -> List.rev acc |> List.sort_uniq String.compare
          | Some _ ->
              let lit = Str.matched_string rhs in
              loop (Str.match_end ()) (lit :: acc)
        in
        loop 0 []
  in
  let subset_bound_local bound vars =
    List.for_all (fun v -> SSet.mem v bound) vars
  in
  let rec decompose_eq_expr_typd (e : exp) : (exp * exp) option =
    let first_some xs =
      let rec go = function
        | [] -> None
        | y :: ys ->
            (match decompose_eq_expr_typd y with
             | Some _ as hit -> hit
             | None -> go ys)
      in
      go xs
    in
    let exp_of_arg (a : arg) = match a.it with
      | ExpA e1 -> Some e1
      | _ -> None
    in
    match e.it with
    | CmpE (`EqOp, _, e1, ({it = BoolE true; _} as e2)) ->
        (match decompose_eq_expr_typd e1 with
         | Some _ as hit -> hit
         | None -> Some (e1, e2))
    | CmpE (`EqOp, _, ({it = BoolE true; _} as e1), e2) ->
        (match decompose_eq_expr_typd e2 with
         | Some (l, r) -> Some (l, r)
         | None -> Some (e1, e2))
    | CmpE (`EqOp, _, e1, e2) -> Some (e1, e2)
    | BinE (`EquivOp, _, e1, e2) -> Some (e1, e2)
    | CvtE (e1, _, _) | SubE (e1, _, _) | ProjE (e1, _) | UncaseE (e1, _)
    | TheE e1 | LiftE e1 | IterE (e1, _) ->
        decompose_eq_expr_typd e1
    | OptE (Some e1) -> decompose_eq_expr_typd e1
    | BinE ((`AndOp | `OrOp | `ImplOp), _, e1, e2) ->
        (match decompose_eq_expr_typd e1 with
         | Some _ as hit -> hit
         | None -> decompose_eq_expr_typd e2)
    | IfE (c, e1, e2) ->
        (match decompose_eq_expr_typd c with
         | Some _ as hit -> hit
         | None ->
             match decompose_eq_expr_typd e1 with
             | Some _ as hit -> hit
             | None -> decompose_eq_expr_typd e2)
    | CallE (_, args) -> first_some (List.filter_map exp_of_arg args)
    | TupE es | ListE es -> first_some es
    | DotE (e1, _) | LenE e1 -> decompose_eq_expr_typd e1
    | CatE (e1, e2) | MemE (e1, e2) | IdxE (e1, e2) | CompE (e1, e2)
    | UpdE (e1, _, e2) | ExtE (e1, _, e2) ->
        (match decompose_eq_expr_typd e1 with
         | Some _ as hit -> hit
         | None -> decompose_eq_expr_typd e2)
    | SliceE (e1, e2, e3) ->
        (match decompose_eq_expr_typd e1 with
         | Some _ as hit -> hit
         | None ->
             match decompose_eq_expr_typd e2 with
             | Some _ as hit -> hit
             | None -> decompose_eq_expr_typd e3)
    | StrE fields -> first_some (List.map snd fields)
    | _ -> None
  in
  let prem_item_of_prem_typd vm (p : prem) =
    match p.it with
    | ElsePr -> None
    | LetPr (e1, e2, _) ->
        let lhs = translate_exp TermCtx e1 vm in
        let rhs = translate_exp TermCtx e2 vm in
        let bool_t =
          { text = Printf.sprintf "( %s == %s )" lhs.text rhs.text;
            vars = uniq_vars_local (lhs.vars @ rhs.vars) }
        in
        Some (`Eq (lhs, rhs, bool_t))
    | IfPr e ->
        (match decompose_eq_expr_typd e with
         | Some (e1, e2) ->
             let lhs = translate_exp TermCtx e1 vm in
             let rhs = translate_exp TermCtx e2 vm in
             let bool_t = translate_exp BoolCtx e vm in
             Some (`Eq (lhs, rhs, bool_t))
         | None ->
             let t = translate_prem p vm in
             if t.text = "" || t.text = "owise" then None else Some (`Bool t))
    | _ ->
        let t = translate_prem p vm in
        if t.text = "" || t.text = "owise" then None else Some (`Bool t)
  in
  let classify_prem_typd bound = function
    | `Bool t ->
        let vars = vars_of_texpr_local t in
        let ready = subset_bound_local bound vars in
        (`Bool, (t.text, vars, []), ready)
    | `Eq (lhs, rhs, bool_t) ->
        let lhs_vars = vars_of_texpr_local lhs in
        let rhs_vars = vars_of_texpr_local rhs in
        let lhs_set = SSet.of_list lhs_vars in
        let rhs_set = SSet.of_list rhs_vars in
        let lhs_has_no_bound = SSet.is_empty (SSet.inter lhs_set bound) in
        let rhs_has_no_bound = SSet.is_empty (SSet.inter rhs_set bound) in
        let lhs_nonempty = not (SSet.is_empty lhs_set) in
        let rhs_nonempty = not (SSet.is_empty rhs_set) in
        if lhs_nonempty && lhs_has_no_bound && subset_bound_local bound rhs_vars then
          (`Match,
           (Printf.sprintf "%s := %s" lhs.text rhs.text,
            uniq_vars_local (lhs_vars @ rhs_vars),
            lhs_vars),
           true)
        else if rhs_nonempty && rhs_has_no_bound && subset_bound_local bound lhs_vars then
          (`Match,
           (Printf.sprintf "%s := %s" rhs.text lhs.text,
            uniq_vars_local (lhs_vars @ rhs_vars),
            rhs_vars),
           true)
        else
          let vars = vars_of_texpr_local bool_t in
          let ready = subset_bound_local bound vars in
          (`Bool, (bool_t.text, vars, []), ready)
  in
  let normalize_sched_typd bound (txt, vars, binds) =
    match split_once_re (Str.regexp "[ \t]+:=[ \t]+") txt with
    | None -> (txt, vars, binds)
    | Some (lhs, rhs) ->
        let lhs_vars =
          let re = Str.regexp "[A-Z][A-Z0-9-]*" in
          let rec loop pos acc =
            match (try Some (Str.search_forward re lhs pos) with Not_found -> None) with
            | None -> List.sort_uniq String.compare acc
            | Some _ ->
                let tok = Str.matched_string lhs in
                let acc =
                  if starts_with tok "CTOR" then acc else tok :: acc
                in
                loop (Str.match_end ()) acc
          in
          loop 0 []
        in
        let lhs_already_known =
          lhs_vars = []
          || List.for_all
               (fun v -> SSet.mem v bound || starts_with v "FREE-")
               lhs_vars
        in
        if lhs_already_known then
          (Printf.sprintf "( %s == %s )" (String.trim lhs) (String.trim rhs),
           vars,
           [])
        else (txt, vars, binds)
  in
  let rec schedule_prems_typd bound acc items =
    match items with
    | [] -> List.rev acc
    | _ ->
        let rec pick prefix = function
          | [] -> None
          | it :: rest ->
              let (_kind, sched, ready) = classify_prem_typd bound it in
              if ready then Some (List.rev prefix, sched, rest)
              else pick (it :: prefix) rest
        in
        match pick [] items with
        | Some (before, chosen, after) ->
            let chosen = normalize_sched_typd bound chosen in
            let (_, _, binds) = chosen in
            let bound' = List.fold_left (fun b v -> SSet.add v b) bound binds in
            schedule_prems_typd bound' (chosen :: acc) (before @ after)
        | None ->
            let rec force bound2 acc2 = function
              | [] -> List.rev acc2
              | it :: rest ->
                  let (_kind, sched, _ready) = classify_prem_typd bound2 it in
                  let sched = normalize_sched_typd bound2 sched in
                  let (_txt, _vars, binds) = sched in
                  let bound3 = List.fold_left (fun b v -> SSet.add v b) bound2 binds in
                  force bound3 (sched :: acc2) rest
            in
            List.rev_append acc (force bound [] items)
  in
  (* Skip instance axiom generation for sorts with incompatible encodings *)
  let insts = if SSet.mem type_sort skip_instance_sorts then [] else insts in
  let res = List.map (fun inst -> match inst.it with
    | InstD (binders, args, deftyp) ->
        let v_map = binder_var_map binders in
        let binder_conds = binder_type_conds binders in
        let type_term_t = mk_type_term_texpr args v_map in
        let type_term = type_term_t.text in
        let full_type_sort = type_sort in
        (match deftyp.it with
         | VariantT cases ->
             List.filter_map (fun (mixop_val, (_, case_typ, prems), _) ->
               let debug_numeric_variant =
                 debug_iter_enabled &&
	                 List.mem (String.lowercase_ascii id.it) ["bit"; "byte"; "un"; "sn"; "uN"; "sN"]
               in
               let type_counters = ref [] in
               let get_count tname =
                 let c = (try List.assoc tname !type_counters with Not_found -> 0) + 1 in
                 type_counters := (tname, c) :: (List.remove_assoc tname !type_counters); c in
               let rec collect_params cur_vm t is_list = match t.it with
	                 | VarT (tid, args) ->
                     let vb = to_var_name tid.it in
                     let count = get_count vb in
                     let indexed =
                       if is_list then
                         vb ^ "-LIST-" ^ String.uppercase_ascii (sanitize tid.it)
                       else vb ^ string_of_int count in
                     let new_vm = (tid.it, indexed) :: cur_vm in
	                     let ms =
	                       if is_list || is_plural_type tid.it
	                          || (String.lowercase_ascii tid.it = "list" && args <> []) then
                         "SpectecTerminals"
	                       else source_carrier_sort_of_typ t cur_vm
                     in
                     let guard = "true" in
                     ([(indexed, guard, ms)], new_vm)
	                 | IterT (inner, iter) ->
	                     let sequence_like =
	                       match iter with
	                       | List | List1 | ListN _ -> true
	                       | Opt -> false
	                     in
	                     collect_params cur_vm inner sequence_like
                 | TupT fields ->
                     List.fold_left (fun (acc, vm) (fe, ft) ->
                       match fe.it with
                       | VarE tid when tid.it <> "_" ->
                           let vb = to_var_name tid.it in
                           let count = get_count vb in
                           let indexed =
                             if is_list then
                               vb ^ "-LIST-" ^ String.uppercase_ascii (sanitize tid.it)
                             else vb ^ string_of_int count in
                       let vm' = (tid.it, indexed) :: vm in
                       let ms =
                             if is_list then
                               "SpectecTerminals"
                             else
	                               source_carrier_sort_of_typ ft vm'
                        in
                        (acc @ [(indexed, "true", ms)], vm')
                       | _ ->
                           let (ps, vm') = collect_params vm ft is_list in
                           (acc @ ps, vm')
                     ) ([], cur_vm) fields
                 | _ -> ([], cur_vm)
               in
               let enriched_vm = build_suffix_map binders @ v_map in
               let rec ctor_arg_sorts cur_vm t is_list =
                 match t.it with
                 | VarT (tid, args) ->
                     let ms =
                       if is_list || is_plural_type tid.it
                          || (String.lowercase_ascii tid.it = "list" && args <> [])
                       then "SpectecTerminals"
                       else source_carrier_sort_of_typ t cur_vm
                     in
                     [ms]
                 | IterT (inner, Opt) ->
                     (* Optional source arguments accept eps at the operator
                        boundary, even though the non-empty pattern variable is
                        declared at the inner category sort. *)
                     List.map (fun _ -> "SpectecTerminals")
                       (ctor_arg_sorts cur_vm inner false)
                 | IterT (inner, (List | List1 | ListN _)) ->
                     ctor_arg_sorts cur_vm inner true
                 | TupT fields ->
                     fields
                     |> List.concat_map (fun (fe, ft) ->
                          match fe.it with
                          | VarE tid when tid.it <> "_" ->
                              let vm' = (tid.it, to_var_name tid.it) :: cur_vm in
                              if is_list then ["SpectecTerminals"]
                              else [source_carrier_sort_of_typ ft vm']
                          | _ -> ctor_arg_sorts cur_vm ft is_list)
                 | _ -> []
               in
               let (params0, param_vm) = collect_params enriched_vm case_typ false in
               let params =
                 if params0 <> [] || canonical_ctor_name_arity mixop_val 0 <> None then params0
                 else
                   List.filter_map (fun b -> match b.it with
                     | ExpB (tid, t) ->
                         let mv = match List.assoc_opt tid.it param_vm with
                           | Some v -> v
                           | None -> to_var_name tid.it
                         in
                         let ms =
	                           source_carrier_sort_of_typ t param_vm
                         in
                         Some (mv, "true", ms)
                     | _ -> None
                   ) binders
               in
               let p_vars = List.map (fun (v, _, _) -> v) params in
               let v_decl () =
                 String.concat "" (List.map (fun (v, _, ms) -> declare_var v ms) params)
               in
               let binder_decl () = String.concat "" (List.map (fun b -> match b.it with
                 | ExpB (tid, _) -> declare_var (to_var_name tid.it) "SpectecTerminal"
                 | _ -> "") binders) in
               let type_term_decl () =
                 declare_vars_same_sort (vars_of_texpr_local type_term_t) "SpectecTerminal"
               in
               let decl_prefix () = type_term_decl () ^ binder_decl () ^ v_decl () in
               let prem_items = List.filter_map (prem_item_of_prem_typd param_vm) prems in
               let prem_sched = schedule_prems_typd (SSet.of_list p_vars) [] prem_items in
               let prem_match_strs =
                 prem_sched
                 |> List.filter_map (fun (txt, _, binds) ->
                     if binds = [] then None else Some (prem_cond txt))
               in
               let prem_bool_strs =
                 prem_sched
                 |> List.filter_map (fun (txt, _, binds) ->
                     if binds = [] then Some (prem_cond txt) else None)
               in
               let normalize_typd_condition_assignments seed_vars conds =
                 let known = ref (SSet.of_list seed_vars) in
                 let vars_in text =
                   let re = Str.regexp "[A-Z][A-Z0-9-]*" in
                   let rec loop pos acc =
                     match (try Some (Str.search_forward re text pos) with Not_found -> None) with
                     | None -> List.sort_uniq String.compare acc
                     | Some _ ->
                         let tok = Str.matched_string text in
                         let acc =
                           if starts_with tok "CTOR" then acc else tok :: acc
                         in
                         loop (Str.match_end ()) acc
                   in
                   loop 0 []
                 in
                 conds
                 |> List.map (fun cond ->
                     match split_once_re (Str.regexp "[ \t]+:=[ \t]+") cond with
                     | None -> cond
                     | Some (lhs, rhs) ->
                         let lhs_vars = vars_in lhs in
                         let known_lhs =
                           lhs_vars = []
                           || List.for_all
                                (fun v -> SSet.mem v !known || starts_with v "FREE-")
                                lhs_vars
                         in
                         if known_lhs then
                           Printf.sprintf "( %s == %s )" (String.trim lhs) (String.trim rhs)
                         else begin
                           List.iter (fun v -> known := SSet.add v !known) lhs_vars;
                           cond
                         end)
               in
               let rhs =
                 let typd_seed_vars =
                   p_vars @
                   List.filter_map (fun b -> match b.it with
                     | ExpB (tid, _) -> Some (to_var_name tid.it)
                     | _ -> None) binders
                 in
                 cond_join
                   (normalize_typd_condition_assignments typd_seed_vars
                      (prem_match_strs @ prem_bool_strs @ binder_conds))
               in
                 let sections = mixop_sections mixop_val in
               let lhs0 =
                 match canonical_ctor_name_arity mixop_val (List.length p_vars) with
                 | Some "CTORSEMICOLONA2" when List.length p_vars = 2 ->
                     Printf.sprintf "( %s ; %s )" (List.nth p_vars 0) (List.nth p_vars 1)
                 | Some ctor -> format_call ctor p_vars
                 | None -> interleave_lhs sections p_vars
               in
               let () =
                 if debug_numeric_variant then
                   let case_typ_kind =
                     match case_typ.it with
                     | VarT _ -> "VarT"
                     | BoolT -> "BoolT"
                     | NumT _ -> "NumT"
                     | TextT -> "TextT"
                     | TupT _ -> "TupT"
                     | IterT _ -> "IterT"
                   in
                   let prem_str =
                     String.concat " || "
                       (List.map Il.Print.string_of_prem prems)
                   in
                   debug_iter
                     "[TYPD-VARIANT] id=%s kind=%s binders=%s args=%s case_typ=%s prems=%s params0=%s params=%s p_vars=%s lhs0=%s"
                     id.it
                     case_typ_kind
                     (Il.Print.string_of_binds binders)
                     (String.concat ", " (List.map Il.Print.string_of_arg args))
                     (Il.Print.string_of_typ case_typ)
                     prem_str
                     (String.concat "; " (List.map (fun (v, _, ms) -> v ^ ":" ^ ms) params0))
                     (String.concat "; " (List.map (fun (v, _, ms) -> v ^ ":" ^ ms) params))
                     (String.concat "," p_vars)
                     lhs0
               in
	               let lhs = safe_term_text lhs0
	                 in
	                 let cons_name = match List.flatten mixop_val with a :: _ -> Xl.Atom.name a | [] -> "" in
                   let typed_index_block =
                     if (cons_name = "" || cons_name = "eps") && (not is_parametric)
                        && String.trim lhs <> "eps"
                        && SSet.mem full_type_sort !flat_sequence_source_sorts
                        && source_record_sequence_elem_sort_exists full_type_sort
                     then begin
                       let first_for_sort =
                         not (SSet.mem full_type_sort !typed_index_helper_sorts)
                       in
                       if first_for_sort then
                         typed_index_helper_sorts :=
                           SSet.add full_type_sort !typed_index_helper_sorts;
                       let rest_v = "TYPED-INDEX-" ^ String.uppercase_ascii full_type_sort ^ "-REST" in
                       let n_v = "TYPED-INDEX-" ^ String.uppercase_ascii full_type_sort ^ "-N" in
                       let decls =
                         if first_for_sort then
                           declare_var rest_v "SpectecTerminals" ^
                           declare_var n_v "Nat"
                         else ""
                       in
                       let type_atom = typed_index_type_atom full_type_sort in
                       let lhs_with_rest = Printf.sprintf "%s %s" lhs rest_v in
                       let cond_suffix =
                         if rhs = "" then ""
                         else "\n   if " ^ rhs
                       in
                       let eq0 =
                         Printf.sprintf
                           "  eq $typed-index(%s, eps, %s) = eps ."
                           type_atom n_v
                       in
                       let eq_head =
                         Printf.sprintf
                           "  %s $typed-index(%s, %s, 0) = %s%s ."
                           (if rhs = "" then "eq" else "ceq")
                           type_atom lhs_with_rest lhs cond_suffix
                       in
                       let eq_tail =
                         Printf.sprintf
                           "  %s $typed-index(%s, %s, s(%s)) = $typed-index(%s, %s, %s)%s ."
                           (if rhs = "" then "eq" else "ceq")
                           type_atom lhs_with_rest n_v type_atom rest_v n_v cond_suffix
                       in
                       let header =
                         if first_for_sort then
                           "\n  --- Source-derived typed index for " ^ name ^ "* elements.\n"
                           ^ decls ^ eq0 ^ "\n"
                         else ""
                       in
                       header ^ eq_head ^ "\n" ^ eq_tail ^ "\n"
                     end
                     else ""
                   in
	                 let main =
	                   if cons_name = "" then
	                     if is_parametric then
	                       (feature_uses_has_type := true;
	                       Printf.sprintf "\n%s  %s ( %s hasType ( %s ) ) : WellTyped%s ."
                         (decl_prefix ()) (if rhs = "" then "mb" else "cmb") lhs type_term
                         (if rhs = "" then "" else "\n   if " ^ rhs))
                     else if is_plain_var_like lhs then
                       let finite_lits = finite_numeric_membership_literals lhs rhs in
                       if finite_lits <> [] then
                         finite_lits
                         |> List.map (fun lit ->
                             Printf.sprintf "  mb ( %s ) : %s ." lit full_type_sort)
                         |> String.concat "\n"
                         |> fun s -> s ^ "\n"
                       else if rhs = "" then
                         let () =
                           List.iter (fun (v, _, _) -> Hashtbl.remove declared_vars v) params;
                           List.iter (fun b -> match b.it with
                             | ExpB (tid, _) -> Hashtbl.remove declared_vars (to_var_name tid.it)
                             | _ -> ()) binders
                         in
                         ""
                       else
                         Printf.sprintf "\n%s  cmb ( %s ) : %s\n   if %s ."
                           (decl_prefix ()) lhs full_type_sort rhs
		                       else
		                         Printf.sprintf "\n%s  %s ( %s ) : %s%s ."
	                         (decl_prefix ()) (if rhs = "" then "mb" else "cmb") lhs full_type_sort
	                         (if rhs = "" then "" else "\n   if " ^ rhs)
	                   else
	                     let canonical_name = canonical_ctor_name_arity mixop_val (List.length p_vars) in
                     let op_sig =
                       match canonical_name with
                       | Some ctor -> ctor
                       | None -> interleave_op sections (List.length p_vars)
                     in
                     let param_sorts = List.map (fun (_, _, ms) -> ms) params in
                     let ctor_param_sorts = ctor_arg_sorts param_vm case_typ false in
                     let () =
                       match canonical_name with
                       | Some ctor ->
                           let op_sorts =
                             if List.length ctor_param_sorts = List.length param_sorts
                             then ctor_param_sorts
                             else param_sorts
                           in
                           register_ctor_arg_sorts ctor op_sorts
                       | None -> ()
                     in
	                     let arg_sorts = String.concat " " param_sorts in
                     let op_line =
                       match canonical_name with
                       | Some _ -> ""
                       | None ->
                           Printf.sprintf "  op %s : %s -> SpectecTerminal [ctor] .\n" op_sig arg_sorts
                     in
                     if is_parametric then
                       (feature_uses_has_type := true;
                       Printf.sprintf "%s%s  %s ( %s hasType ( %s ) ) : WellTyped%s ."
                         op_line (decl_prefix ()) (if rhs = "" then "mb" else "cmb") lhs type_term
                         (if rhs = "" then "" else "\n   if " ^ rhs))
                     else
                       Printf.sprintf "%s%s  %s ( %s ) : %s%s ."
                         op_line (decl_prefix ()) (if rhs = "" then "mb" else "cmb") lhs full_type_sort
                         (if rhs = "" then "" else "\n   if " ^ rhs)
                 in
                 let opts =
                   if prems <> [] then []
                   else
                     List.map (fun opt_idx ->
                       let eps_args = List.mapi (fun i v -> if i = opt_idx then "eps" else v) p_vars in
                       let lhs_eps =
                         match canonical_ctor_name_arity mixop_val (List.length eps_args) with
                         | Some "CTORSEMICOLONA2" when List.length eps_args = 2 ->
                             Printf.sprintf "( %s ; %s )" (List.nth eps_args 0) (List.nth eps_args 1)
                         | Some ctor -> format_call ctor eps_args
                         | None -> interleave_lhs sections eps_args in
                       let lhs_eps = safe_term_text lhs_eps in
                       let r = cond_join
                         (binder_conds @ List.filteri (fun i _ -> i <> opt_idx)
                           (List.map (fun (_, g, _) -> g) params)) in
                       if is_parametric then
                         (feature_uses_has_type := true;
                         Printf.sprintf "\n  %s ( %s hasType ( %s ) ) : WellTyped%s ."
                           (if r = "" then "mb" else "cmb") lhs_eps type_term
                           (if r = "" then "" else "\n   if " ^ r))
	                       else
                         let membership =
	                         Printf.sprintf "\n  %s ( %s ) : %s%s ."
	                           (if r = "" then "mb" else "cmb") lhs_eps full_type_sort
	                           (if r = "" then "" else "\n   if " ^ r)
                         in
                         let typed_index_opt_block =
                           if (not is_parametric)
                              && String.trim lhs_eps <> "eps"
                              && SSet.mem full_type_sort !flat_sequence_source_sorts
                              && source_record_sequence_elem_sort_exists full_type_sort
                           then
                             let rest_v = "TYPED-INDEX-" ^ String.uppercase_ascii full_type_sort ^ "-REST" in
                             let n_v = "TYPED-INDEX-" ^ String.uppercase_ascii full_type_sort ^ "-N" in
                             let type_atom = typed_index_type_atom full_type_sort in
                             let lhs_with_rest = Printf.sprintf "%s %s" lhs_eps rest_v in
                             let cond_suffix =
                               if r = "" then ""
                               else "\n   if " ^ r
                             in
                             let eq_head =
                               Printf.sprintf
                                 "  %s $typed-index(%s, %s, 0) = %s%s ."
                                 (if r = "" then "eq" else "ceq")
                                 type_atom lhs_with_rest lhs_eps cond_suffix
                             in
                             let eq_tail =
                               Printf.sprintf
                                 "  %s $typed-index(%s, %s, s(%s)) = $typed-index(%s, %s, %s)%s ."
                                 (if r = "" then "eq" else "ceq")
                                 type_atom lhs_with_rest n_v type_atom rest_v n_v cond_suffix
                             in
                             "\n" ^ eq_head ^ "\n" ^ eq_tail ^ "\n"
                           else ""
                         in
                         membership ^ typed_index_opt_block
	                     ) (find_opt_param_indices case_typ)
                 in
                 Some (main ^ typed_index_block ^ String.concat "" opts)
             ) cases |> String.concat "\n"
         | AliasT typ ->
             let bd () = String.concat "" (List.map (fun b -> match b.it with
               | ExpB (tid, _) -> declare_var (to_var_name tid.it) "SpectecTerminal"
               | _ -> "") binders) in
             let var = match typ.it with IterT (_, (List | List1)) -> "TS" | _ -> "T" in
             let lhs = if SSet.mem name base_types then "T" else var in
             let alias_guard_opt =
               match typ.it with
               | NumT `NatT -> Some (Printf.sprintf "%s : Nat" lhs)
               | NumT `IntT -> Some (Printf.sprintf "%s : Int" lhs)
               | VarT (tid, _) ->
                   (match String.lowercase_ascii tid.it with
                    | "un" | "u8" | "u16" | "u31" | "u32" | "u64" ->
                        Some (Printf.sprintf "%s : Nat" lhs)
                    | "sn" | "in" | "i32" | "i64" | "i128" | "exp" ->
                        Some (Printf.sprintf "%s : Int" lhs)
                    | _ ->
                        Some (type_guard lhs typ v_map))
               | _ -> Some (type_guard lhs typ v_map)
             in
             (match alias_guard_opt with
             | None -> ""
             | Some alias_guard ->
                  let cond =
                    if alias_guard = "true" then ""
                    else if binder_conds = [] then alias_guard
                    else cond_join (binder_conds @ [alias_guard]) in
                  if is_parametric then
                    (feature_uses_has_type := true;
                    Printf.sprintf "%s  %s ( %s hasType ( %s ) ) : WellTyped%s ."
                      (bd ()) (if cond = "" then "mb" else "cmb") lhs type_term
                      (if cond = "" then "" else "\n   if " ^ cond))
                  else
                    Printf.sprintf "%s  %s ( %s ) : %s%s ."
                      (bd ()) (if cond = "" then "mb" else "cmb") lhs full_type_sort
                      (if cond = "" then "" else "\n   if " ^ cond))
         | StructT fields ->
             let bd = String.concat "" (List.map (fun b -> match b.it with
               | ExpB (tid, _) -> declare_var (to_var_name tid.it) "SpectecTerminal"
               | _ -> "") binders) in
             let () =
               if debug_iter_enabled &&
                  List.mem (String.lowercase_ascii id.it) ["moduleinst"; "store"; "frame"]
               then
                 List.iter (fun (atom, (_, ft, _), _) ->
                   debug_iter "[TYPD-STRUCT] id=%s field=%s typ=%s"
                     id.it (Xl.Atom.name atom) (Il.Print.string_of_typ ft)
                 ) fields
             in
             let record_var_prefix = to_var_name id.it in
             let info = List.mapi (fun i (atom, (_, ft, _), _) ->
               let fn = to_var_name (Xl.Atom.name atom) in
               let sn = translate_typ (match ft.it with IterT (inner, _) -> inner | _ -> ft) v_map in
	               let ms =
	                 if is_plural_type sn then "SpectecTerminals"
	                 else source_carrier_sort_of_typ ft v_map
	               in
	               (fn, Printf.sprintf "F-%s-%s-%d" record_var_prefix fn i, ft, ms)
	             ) fields in
             let decls = String.concat "" (List.map (fun (_, vn, _, ms) -> declare_var vn ms) info) in
             let field_guards =
               List.map (fun (_, vn, ft, _) -> (vn, type_guard vn ft v_map)) info
             in
             let optional_vns =
               info
               |> List.filter_map (fun (_, vn, ft, _) ->
                   match ft.it with
                   | IterT (_, Opt) -> Some vn
                   | _ -> None)
             in
             let rec nonempty_subsets = function
               | [] -> []
               | x :: xs ->
                   let rest = nonempty_subsets xs in
                   [ [ x ] ] @ rest @ List.map (fun ys -> x :: ys) rest
             in
             let emit_record_membership empty_vns =
               let is_empty vn = List.mem vn empty_vns in
               let rhs =
                 field_guards
                 |> List.filter (fun (vn, _) -> not (is_empty vn))
                 |> List.map snd
                 |> fun guards -> cond_join (binder_conds @ guards)
               in
               let record_items =
                 String.concat " ; "
                   (List.map (fun (f, vn, _, _) ->
                        if is_empty vn then Printf.sprintf "item('%s, eps)" f
                        else Printf.sprintf "item('%s, ( %s ))" f vn)
                      info)
               in
               if is_parametric then
                 (feature_uses_has_type := true;
                 Printf.sprintf "  %s ( {%s} hasType ( %s ) ) : WellTyped%s ."
                   (if rhs = "" then "mb" else "cmb")
                   record_items type_term
                   (if rhs = "" then "" else "\n   if " ^ rhs))
               else
                 Printf.sprintf "  %s ( {%s} ) : %s%s ."
                   (if rhs = "" then "mb" else "cmb")
                   record_items full_type_sort
                   (if rhs = "" then "" else "\n   if " ^ rhs)
             in
             let memberships =
               emit_record_membership [] ::
               List.map emit_record_membership (nonempty_subsets optional_vns)
             in
             let source_record_block =
               if is_parametric || info = [] then ""
               else
                 let field_names = List.map (fun (f, _, _, _) -> f) info in
                 match List.find_opt (fun ri ->
                   ri.rec_sort = full_type_sort && ri.rec_fields = field_names
                 ) !source_record_infos with
	                 | None -> ""
	                 | Some ri ->
	                     let unique_record_shape =
	                       match Hashtbl.find_opt source_record_shape_counts
	                               (record_shape_key field_names) with
	                       | Some 1 -> true
	                       | _ -> false
	                     in
	                     let arg_sorts =
	                       String.concat " "
	                         (List.map (fun _ -> "SpectecTerminals") field_names)
                     in
                     let record_call vars = format_call ri.rec_ctor vars in
                     let vars = List.map (fun (_, vn, _, _) -> vn) info in
                     let record_items_for vars =
                       "{"
                       ^ String.concat " ; "
                           (List.map2 (fun f v -> Printf.sprintf "item('%s, %s)" f v)
                              field_names vars)
                       ^ "}"
                     in
                     let canonicalization empty_vns =
                       let is_empty vn = List.mem vn empty_vns in
                       let rhs_conds =
                         field_guards
                         |> List.filter (fun (vn, _) -> not (is_empty vn))
                         |> List.map snd
                         |> fun guards -> cond_join (binder_conds @ guards)
                       in
                       let lhs_vars =
                         List.map (fun (_, vn, _, _) ->
                           if is_empty vn then "eps" else vn
                         ) info
                       in
                       let lhs = record_items_for lhs_vars in
                       let rhs = record_call lhs_vars in
                       if rhs_conds = "" then
                         Printf.sprintf "  eq %s = %s ." lhs rhs
	                       else
	                         Printf.sprintf "  ceq %s = %s\n   if %s ." lhs rhs rhs_conds
	                     in
	                     let canonicalizations =
	                       if unique_record_shape then
	                         canonicalization [] ::
	                         List.map canonicalization (nonempty_subsets optional_vns)
	                       else []
	                     in
	                     let projections =
	                       List.map2 (fun f v ->
	                         Printf.sprintf "  eq value('%s, %s) = %s ."
                           f (record_call vars) v)
                         field_names vars
                       |> String.concat "\n"
                     in
                     let update_eqs =
                       info
                       |> List.mapi (fun i (f, _vn, _, _) ->
                           let uv = Printf.sprintf "U-%s-%s-%d" record_var_prefix f i in
                           let updated =
                             List.mapi (fun j v -> if i = j then uv else v) vars
                           in
                           Printf.sprintf
                             "%s  eq %s [. '%s <- %s] = %s ."
                             (declare_var uv "SpectecTerminals")
                             (record_call vars) f uv (record_call updated))
                       |> String.concat "\n"
                     in
                     let merge_eq =
                       let rhs_vars =
                         List.mapi (fun i f -> Printf.sprintf "M-%s-%s-%d" record_var_prefix f i)
                           field_names
                       in
                       let rhs_decls =
                         rhs_vars
                         |> List.map (fun v -> declare_var v "SpectecTerminals")
                         |> String.concat ""
                       in
                       let merged =
                         List.map2 (fun a b -> Printf.sprintf "%s %s" a b)
                           vars rhs_vars
                       in
                       Printf.sprintf "%s  eq merge ( %s , %s ) = %s ."
                         rhs_decls
                         (record_call vars)
                         (record_call rhs_vars)
                         (record_call merged)
                     in
	                     "\n  --- Source-derived typed record representation for "
	                     ^ ri.rec_source_name ^ ".\n"
	                     ^ Printf.sprintf "  op %s : %s -> %s [ctor] .\n"
	                         ri.rec_ctor arg_sorts full_type_sort
	                     ^ (if canonicalizations = [] then ""
	                        else String.concat "\n" canonicalizations ^ "\n")
	                     ^ projections ^ "\n" ^ update_eqs ^ "\n" ^ merge_eq
	             in
             bd ^ decls ^ source_record_block ^ "\n" ^ String.concat "\n" memberships)
  ) insts in
  sort_decl ^ source_category_subsort_decl ^ op_decl ^ String.concat "\n" res

(* --- Binding analysis (shared by DecD / RelD) ---------------------------- *)

let extract_vars_from_maude s =
  let re = Str.regexp "[A-Z][A-Z0-9-]*" in
  let excluded = SSet.of_list
    ["SpectecTerminal"; "SpectecTerminals"; "SpectecType"; "SpectecTypes"; "Bool"; "Nat"; "Int";
     "EMPTY"; "REC"; "FUNC"; "SUB"; "STRUCT"; "ARRAY"; "FIELD";
     (* Maude DSL-RECORD atom labels — these appear in value('FOO, ...) and must not
        be treated as free variables when deciding := vs == in condition scheduling *)
     "TYPES"; "TAGS"; "GLOBALS"; "LOCALS"; "MEMS"; "TABLES"; "FUNCS"; "DATAS"; "ELEMS";
     "STRUCTS"; "ARRAYS"; "EXNS"; "EXPORTS"; "LABELS"; "RETURN"; "MODULE"; "OFFSET";
     "ALIGN"; "BYTES"; "CODE"; "REFS"; "RECS"; "FIELDS"; "TAG"; "TYPE"; "VALUE"; "NAME";
     "ADDR"; "LABEL"; "LABEL"; "LABEL"; "IMPORT"] in
  (* Also exclude CTOR-prefixed names (generated constructor ops, not variables) *)
  let is_ctor_name t =
    String.length t >= 4 && String.sub t 0 4 = "CTOR"
  in
  let is_name_char c =
    (c >= 'A' && c <= 'Z')
    || (c >= 'a' && c <= 'z')
    || (c >= '0' && c <= '9')
    || c = '_' || c = '-'
  in
  let rec loop pos acc =
    match (try Some (Str.search_forward re s pos) with Not_found -> None) with
    | None -> acc
    | Some start ->
        let tok = Str.matched_string s in
        let stop = Str.match_end () in
        let partial_token =
          (start > 0 && is_name_char s.[start - 1])
          || (stop < String.length s && is_name_char s.[stop])
        in
        loop (Str.match_end ())
          (if partial_token || SSet.mem tok excluded || is_ctor_name tok then acc else tok :: acc)
  in
  loop 0 [] |> List.sort_uniq String.compare

(** Build a per-equation variable prefix from a case/rule identifier. *)
let make_var_prefix prefix eq_idx raw_v =
  let normalized_raw =
    String.concat "" (String.split_on_char '-' (String.uppercase_ascii (sanitize raw_v)))
  in
  Printf.sprintf "%s%d-%s" prefix eq_idx
    normalized_raw

let add_vm_alias key value acc =
  if key = "" then acc
  else if List.exists (fun (k, _) -> String.lowercase_ascii k = String.lowercase_ascii key) acc
  then acc
  else (key, value) :: acc

(** Create [var_map] from binders, filtering out Bool-typed bindings. *)
let binder_to_var_map prefix eq_idx binders =
  let sequence_vars = ref SSet.empty in
  let vm =
  List.fold_left (fun acc b -> match b.it with
    | ExpB (v_id, t) ->
        if is_bool_typ t [] || String.lowercase_ascii v_id.it = "bool" then acc
        else
          let raw = v_id.it in
          let base = strip_iter_suffix raw in
          let named_base = source_name_for_binder raw t in
          let mapped = make_var_prefix prefix eq_idx named_base in
          let iter_kind = match t.it with
            | IterT (_, List) -> "*"
            | IterT (_, List1) -> "+"
            | IterT (_, Opt) -> "?"
            | IterT (_, ListN _) -> "N"
            | _ -> "-" in
          (match t.it with
           | IterT (_, (List | List1 | ListN _)) ->
               sequence_vars := SSet.add mapped !sequence_vars
           | _ -> ());
          (match simple_sort_of_typ t [] with
           | Some sort -> Hashtbl.replace source_var_sorts mapped sort
           | None -> ());
          (match t.it with
           | IterT (inner, (List | List1 | ListN _)) ->
               (match simple_sort_of_typ inner [] with
                | Some elem_sort ->
                    Hashtbl.replace source_var_sorts mapped "SpectecTerminals";
                    Hashtbl.replace source_var_seq_elem_sorts mapped elem_sort
                | None -> ())
           | _ -> ());
          debug_iter "[BINDER-MAP] eq=%d raw=%s base=%s kind=%s mapped=%s"
            eq_idx raw base iter_kind mapped;
          let acc = add_vm_alias raw mapped acc in
          let acc = add_vm_alias base mapped acc in
          let acc = add_vm_alias named_base mapped acc in
          let acc = add_vm_alias (base ^ "*") mapped acc in
          let acc = add_vm_alias (base ^ "+") mapped acc in
          let acc = add_vm_alias (base ^ "?") mapped acc in
          acc
    | _ -> acc
  ) [] binders
  in
  g_sequence_binder_vars := !sequence_vars;
  vm

let record_listn_pairs_from_binders binders vm =
  List.iter (fun b -> match b.it with
    | ExpB (v_id, t) ->
        (match t.it with
         | IterT (_, ListN (count_e, _)) ->
             (match List.assoc_opt v_id.it vm with
              | Some seq_mv ->
                  let cnt_t = translate_exp TermCtx count_e vm in
                  record_listn_pair cnt_t.text seq_mv
              | None -> ())
         | _ -> ())
    | _ -> ()
  ) binders

let listn_len_conditions lhs_bound_vars =
  let is_simple_var_name s =
    let s = String.trim s in
    try
      ignore (Str.search_forward (Str.regexp "^[A-Z][A-Z0-9-]*$") s 0);
      true
    with Not_found -> false
  in
  List.filter_map (fun (cnt_mv, seq_mv) ->
    if List.mem cnt_mv lhs_bound_vars then
      Some (Printf.sprintf "( ( len ( %s ) == %s ) )" seq_mv cnt_mv)
    else if is_simple_var_name cnt_mv then
      Some (Printf.sprintf "%s := len ( %s )" cnt_mv seq_mv)
    else
      Some (Printf.sprintf "( ( len ( %s ) == %s ) )" seq_mv cnt_mv)
  ) !g_listn_pairs

(** Create type-check conditions from binders, only for non-trivial types. *)
let binder_to_type_conds binders vm =
  List.filter_map (fun b -> match b.it with
    | ExpB (v_id, t) ->
        let ts = translate_typ t [] in
        if ts = "SpectecType" || is_bool_typ t [] || String.lowercase_ascii v_id.it = "bool"
        then None
        else (match List.assoc_opt v_id.it vm with
          | Some mv -> Some (mv, type_guard mv t vm)
          | None -> None)
    | _ -> None
  ) binders

let binder_decl_sort (t : typ) =
  decl_sort_of_typ t

let binder_var_sorts binders vm =
  List.filter_map (fun b -> match b.it with
    | ExpB (v_id, t) ->
        (match List.assoc_opt v_id.it vm with
         | Some mv -> Some (mv, binder_decl_sort t)
         | None -> None)
    | _ -> None
  ) binders
  |> List.sort_uniq compare

let redundant_binder_guard typed_vars cond =
  let cond = String.trim cond in
  List.exists (fun (mv, sort) ->
    cond = Printf.sprintf "%s : %s" (String.trim mv) (String.trim sort)
  ) typed_vars

let refined_exec_sorts =
  ["Heaptype"; "Typeuse"; "Valtype"; "Numtype"; "Reftype"; "Blocktype"; "Resulttype"]

let reld_type_pred_sorts : SSet.t ref = ref SSet.empty

let is_refined_exec_sort sort =
  List.mem sort refined_exec_sorts

let refined_exec_pred sort =
  "$is-spectec-" ^ String.lowercase_ascii sort

let has_representation_narrow_sort sort =
  List.mem sort
    [ "SpectecTerminal"; "SpectecTerminals";
      "Bool"; "Nat"; "Int";
      "Config"; "State"; "Store"; "Frame"; "Judgement" ]
  || SSet.mem sort !zero_arity_source_sorts
  || SSet.mem sort !simple_alias_source_sorts
  || List.exists (fun ri -> ri.rec_sort = sort) !source_record_infos

let has_narrow_runtime_sort sort =
  (not (SSet.mem sort !flat_sequence_source_sorts))
  && (has_representation_narrow_sort sort
      || SSet.mem sort !source_membership_sorts)

let needs_source_category_predicate sort =
  SSet.mem sort !sequence_alias_sorts
  || SSet.mem sort !flat_sequence_source_sorts
  || not (has_narrow_runtime_sort sort)

let needs_exec_source_category_predicate sort =
  SSet.mem sort !sequence_alias_sorts
  || SSet.mem sort !flat_sequence_source_sorts
  || not (has_representation_narrow_sort sort)

let refined_exec_guard var sort =
  if needs_source_category_predicate sort then
    Printf.sprintf "%s ( %s )" (refined_exec_pred sort) var
  else
    Printf.sprintf "%s : %s" var sort

let refined_exec_runtime_guard var sort =
  if needs_exec_source_category_predicate sort then
    Printf.sprintf "%s ( %s )" (refined_exec_pred sort) var
  else
    Printf.sprintf "%s : %s" var sort

let source_category_seq_pred sort =
  "$is-spectec-" ^ String.lowercase_ascii sort ^ "-seq"

let source_category_seq_guard sort term =
  let sort = sort_of_type_name sort in
  source_seq_pred_sorts := SSet.add sort !source_seq_pred_sorts;
  Printf.sprintf "%s ( %s )" (source_category_seq_pred sort) term

let val_seq_guard term =
  source_category_seq_guard "Val" term

let widen_refined_lhs_typed_vars typed_vars lhs_vars =
  let lhs_set = SSet.of_list lhs_vars in
  let refined_pairs =
    typed_vars
    |> List.filter (fun (v, s) -> is_refined_exec_sort s && SSet.mem v lhs_set)
    |> List.sort_uniq compare
  in
  let refined_names = refined_pairs |> List.map fst |> SSet.of_list in
  let typed_vars_for_decl =
    typed_vars
    |> List.map (fun (v, s) ->
      if SSet.mem v refined_names then (v, "SpectecTerminal") else (v, s))
    |> List.sort_uniq compare
  in
  let guards =
    refined_pairs
    |> List.map (fun (v, s) -> refined_exec_runtime_guard v s)
    |> List.sort_uniq String.compare
  in
  (typed_vars_for_decl, refined_pairs, guards)

let preserve_narrow_lhs_sort sort =
  has_narrow_runtime_sort sort

let widen_reld_lhs_typed_vars typed_vars lhs_vars =
  let lhs_set = SSet.of_list lhs_vars in

  let lhs_typed_vars =
    typed_vars
    |> List.filter (fun (v, _) -> SSet.mem v lhs_set)
    |> List.sort_uniq compare
  in

  let predicate_pairs =
    lhs_typed_vars
    |> List.filter (fun (_, s) -> not (preserve_narrow_lhs_sort s))
    |> List.sort_uniq compare
  in

  List.iter
    (fun (_, sort) ->
      if needs_source_category_predicate sort then
        reld_type_pred_sorts := SSet.add sort !reld_type_pred_sorts)
    predicate_pairs;

  let typed_vars_for_decl =
    typed_vars
    |> List.map (fun (v, s) ->
         if not (preserve_narrow_lhs_sort s)
         then (v, "SpectecTerminal")
         else (v, s))
    |> List.sort_uniq compare
  in

  let guards =
    predicate_pairs
    |> List.map (fun (v, s) -> refined_exec_guard v s)
    |> List.sort_uniq String.compare
  in

  (typed_vars_for_decl, predicate_pairs, guards)

let is_refined_exec_original_guard refined_pairs cond =
  let cond = String.trim cond in
  List.exists (fun (mv, sort) ->
    cond = Printf.sprintf "%s : %s" (String.trim mv) (String.trim sort)
  ) refined_pairs

let exec_pred_sorts () =
  List.fold_left
    (fun acc sort -> SSet.add sort acc)
    !reld_type_pred_sorts
    (List.filter needs_exec_source_category_predicate refined_exec_sorts)
  |> SSet.elements

let exec_pred_decls sorts =
  sorts
  |> List.map (fun sort ->
      Printf.sprintf "  op %s : SpectecTerminal -> Bool ." (refined_exec_pred sort))

let parse_membership_statement stmt =
  let s = String.trim stmt in
  let starts_kw kw = starts_with s (kw ^ " ") in
  if not (starts_kw "mb" || starts_kw "cmb") then None
  else
    let conditional = starts_kw "cmb" in
    let rest =
      let n = if conditional then 3 else 2 in
      String.trim (String.sub s n (String.length s - n))
    in
    if rest = "" || rest.[0] <> '(' then None
    else
      let rec find_close i depth =
        if i >= String.length rest then None
        else
          match rest.[i] with
          | '(' -> find_close (i + 1) (depth + 1)
          | ')' ->
              let depth' = depth - 1 in
              if depth' = 0 then Some i else find_close (i + 1) depth'
          | _ -> find_close (i + 1) depth
      in
      match find_close 0 0 with
      | None -> None
      | Some close_idx ->
          let pattern = String.sub rest 0 (close_idx + 1) in
          let tail =
            String.sub rest (close_idx + 1) (String.length rest - close_idx - 1)
            |> String.trim
          in
          if not (starts_with tail ":") then None
          else
            let tail = String.trim (String.sub tail 1 (String.length tail - 1)) in
            let parts = Str.bounded_split (Str.regexp "[ \t\n\r]+") tail 2 in
            match parts with
            | sort :: rem_parts ->
                let rem = String.trim (String.concat " " rem_parts) in
                if rem = "." then Some (sort, pattern, None)
                else if starts_with rem "if " && ends_with rem " ." then
                  let cond =
                    String.sub rem 3 (String.length rem - 5)
                    |> String.trim
                  in
                  Some (sort, pattern, Some cond)
                else None
            | _ -> None

let collect_membership_statements lines =
  let rec finish acc cur = function
    | [] ->
        (match cur with
         | None -> List.rev acc
         | Some chunks -> List.rev (String.concat "\n" (List.rev chunks) :: acc))
    | line :: rest ->
        let s = String.trim line in
        let starts_membership = starts_with s "mb " || starts_with s "cmb " in
        let ends_stmt = ends_with s "." in
        match cur with
        | None when starts_membership && ends_stmt ->
            finish (line :: acc) None rest
        | None when starts_membership ->
            finish acc (Some [line]) rest
        | None ->
            finish acc None rest
        | Some chunks when ends_stmt ->
            finish (String.concat "\n" (List.rev (line :: chunks)) :: acc) None rest
        | Some chunks ->
            finish acc (Some (line :: chunks)) rest
  in
  finish [] None lines

let normalize_ws s =
  Str.global_replace (Str.regexp "[ \t\n\r]+") " " (String.trim s)

let parse_unconditional_refined_membership pred_sorts line =
  let s = String.trim line in
  match parse_membership_statement s with
  | Some (sort, pattern, cond) when SSet.mem sort pred_sorts -> Some (sort, pattern, cond)
  | _ -> None

let var_sort_map_of_decls decls =
  let tbl = Hashtbl.create 128 in
  List.iter (fun line ->
    let s = String.trim line in
    let payload =
      if starts_with s "var " then Some (String.sub s 4 (String.length s - 4))
      else if starts_with s "vars " then Some (String.sub s 5 (String.length s - 5))
      else None
    in
    match payload with
    | None -> ()
    | Some payload ->
        (match Str.bounded_split (Str.regexp_string " : ") payload 2 with
         | [names; sort_part] ->
             let sort =
               if ends_with sort_part " ." then
                 String.sub sort_part 0 (String.length sort_part - 2)
               else sort_part
             in
             names
             |> String.split_on_char ' '
             |> List.map String.trim
             |> List.filter (fun name -> name <> "")
             |> List.iter (fun name -> Hashtbl.replace tbl name sort)
         | _ -> ())
  ) decls;
  tbl

let refined_exec_pred_pattern_var pred_sort v =
  "IS-" ^ String.uppercase_ascii pred_sort ^ "-" ^ v

let refined_exec_pred_eqs pred_sorts eqs decls =
  let var_sorts = var_sort_map_of_decls decls in
  let fresh_var_decls = ref [] in
  let membership_pred_eqs =
    pred_sorts
    |> SSet.elements
    |> List.map (fun sort ->
        let v = refined_exec_pred_pattern_var sort "TERM" in
        fresh_var_decls :=
          Printf.sprintf "  var %s : SpectecTerminal ." v :: !fresh_var_decls;
        Printf.sprintf "  ceq %s ( %s ) = true\n      if %s : %s ."
          (refined_exec_pred sort) v v sort)
  in
  let rewrite_pattern_vars pred_sort pattern =
    let vars = extract_vars_from_maude pattern |> List.sort_uniq String.compare in
    List.fold_left (fun (pat, guards, renames) v ->
      match Hashtbl.find_opt var_sorts v with
      | Some sort ->
          let fresh = refined_exec_pred_pattern_var pred_sort v in
          let fresh_sort =
            if has_representation_narrow_sort sort then sort else "SpectecTerminal"
          in
          fresh_var_decls := Printf.sprintf "  var %s : %s ." fresh fresh_sort :: !fresh_var_decls;
          let guards =
            if is_refined_exec_sort sort then refined_exec_runtime_guard fresh sort :: guards
            else guards
          in
          (replace_maude_var_token v fresh pat, guards, (v, fresh) :: renames)
      | _ -> (pat, guards, renames)
    ) (pattern, [], []) vars
  in
  let true_eqs =
    collect_membership_statements eqs
    |> List.map normalize_ws
    |> List.filter_map (parse_unconditional_refined_membership pred_sorts)
    |> List.map (fun (sort, pattern, cond) ->
        let pattern, guards, renames = rewrite_pattern_vars sort pattern in
        let rename_cond cond =
          List.fold_left
            (fun acc (old_name, fresh_name) -> replace_maude_var_token old_name fresh_name acc)
            cond renames
        in
        let guards =
          match cond with
          | None -> guards
          | Some c -> rename_cond c :: guards
          |> List.sort_uniq String.compare
        in
        match guards with
        | [] ->
            Printf.sprintf "  eq %s %s = true ." (refined_exec_pred sort) pattern
        | guards ->
            Printf.sprintf "  ceq %s %s = true\n      if %s ."
              (refined_exec_pred sort) pattern (cond_join guards))
    |> (@) membership_pred_eqs
    |> List.sort_uniq String.compare
  in
  (List.sort_uniq String.compare !fresh_var_decls, true_eqs)

(** Partition variables into bound (in LHS) and free (not in LHS). *)
let partition_vars lhs_vars all_texts all_collected_vars =
  let extracted = extract_vars_from_maude (String.concat " " all_texts) in
  let all_used = List.sort_uniq String.compare (all_collected_vars @ extracted) in
  let lhs_set = List.sort_uniq String.compare lhs_vars in
  let bound = List.filter (fun v -> List.mem v lhs_set) all_used in
  let free = List.filter (fun v -> not (List.mem v lhs_set)) all_used in
  (bound, free, lhs_set)

type prem_item =
  | PremBool of texpr
  | PremRel of { rel_name : string; args : texpr list; text : string }
  | PremMatch of { lhs : texpr; rhs : texpr; binds : string list }
  | PremEq of { lhs : texpr; rhs : texpr; bool_t : texpr }

type prem_sched = { text : string; vars : string list; binds : string list }

let is_generated_free_const_name v =
  String.length v >= 5 && String.sub v 0 5 = "FREE-"

let normalize_assignment_sched bound (p : prem_sched) =
  match split_once_re (Str.regexp "[ \t]+:=[ \t]+") p.text with
  | None -> p
  | Some (lhs, rhs) ->
      let lhs_vars = extract_vars_from_maude lhs in
      let lhs_already_known =
        lhs_vars = []
        || List.for_all
             (fun v -> SSet.mem v bound || is_generated_free_const_name v)
             lhs_vars
      in
      if lhs_already_known then
        { text = Printf.sprintf "( %s == %s )" (String.trim lhs) (String.trim rhs);
          vars = p.vars;
          binds = [] }
      else p

let assignment_lhs_vars text =
  match split_once_re (Str.regexp "[ \t]+:=[ \t]+") text with
  | None -> None
  | Some (lhs, rhs) -> Some (lhs, rhs, extract_vars_from_maude lhs)

let normalize_assignment_conditions_ordered seed_vars conds =
  let known = ref (SSet.of_list seed_vars) in
  conds
  |> List.map (fun cond ->
      match assignment_lhs_vars cond with
      | None -> cond
      | Some (lhs, rhs, lhs_vars) ->
          let lhs_already_known =
            lhs_vars = []
            || List.for_all
                 (fun v -> SSet.mem v !known || is_generated_free_const_name v)
                 lhs_vars
          in
          if lhs_already_known then
            Printf.sprintf "( %s == %s )" (String.trim lhs) (String.trim rhs)
          else begin
            List.iter (fun v -> known := SSet.add v !known) lhs_vars;
            cond
          end)

let normalize_generated_free_const_assignment cond =
  match assignment_lhs_vars cond with
  | Some (lhs, rhs, lhs_vars)
      when lhs_vars <> [] && List.for_all is_generated_free_const_name lhs_vars ->
      Printf.sprintf "( %s == %s )" (String.trim lhs) (String.trim rhs)
  | _ -> cond

let rhs_inline_from_sched rhs_text prem_scheduled =
  let rhs_key = strip_wrapping_parens rhs_text |> String.trim in
  let match_rhs_binding (p : prem_sched) =
    match split_once_re (Str.regexp "[ \t]+:=[ \t]+") p.text with
    | Some (lhs, rhs) when String.trim (strip_wrapping_parens lhs) = rhs_key ->
        Some (String.trim rhs)
    | Some (lhs, rhs) when String.trim (strip_wrapping_parens rhs) = rhs_key ->
        Some (String.trim lhs)
    | _ -> None
  in
  match List.find_map match_rhs_binding prem_scheduled with
  | Some rhs_expr ->
      let kept =
        List.filter (fun (p : prem_sched) ->
          match match_rhs_binding p with
          | Some _ -> false
          | None -> true) prem_scheduled
      in
      (rhs_expr, kept)
  | None -> (rhs_text, prem_scheduled)

let uniq_vars vs = List.sort_uniq String.compare vs

let rec unwrap_exp_for_meta (e : exp) =
  match e.it with
  | CvtE (e1, _, _) | SubE (e1, _, _) | ProjE (e1, _)
  | UncaseE (e1, _) | TheE e1 | LiftE e1 -> unwrap_exp_for_meta e1
  | _ -> e

let source_category_sort_of_pattern_name name =
  let sort = sort_of_type_name name in
  if SSet.mem sort !source_membership_sorts then Some sort else None

let source_category_guard_texpr sort (term : texpr) : texpr =
  if needs_source_category_predicate sort then begin
    reld_type_pred_sorts := SSet.add sort !reld_type_pred_sorts;
    { text = Printf.sprintf "%s ( %s )" (refined_exec_pred sort) term.text;
      vars = term.vars }
  end else
    { text = Printf.sprintf "%s : %s" term.text sort; vars = term.vars }

let source_category_bool_guard_texpr sort (term : texpr) : texpr =
  reld_type_pred_sorts := SSet.add sort !reld_type_pred_sorts;
  { text = Printf.sprintf "%s ( %s )" (refined_exec_pred sort) term.text;
    vars = term.vars }

let category_equality_side_condition vm lhs_e rhs_e =
  let category_sort e =
    match (unwrap_exp_for_meta e).it with
    | VarE id -> source_category_sort_of_pattern_name id.it
    | _ -> None
  in
  match category_sort lhs_e, category_sort rhs_e with
  | Some sort, None ->
      source_category_bool_guard_texpr sort (translate_exp TermCtx rhs_e vm)
  | None, Some sort ->
      source_category_bool_guard_texpr sort (translate_exp TermCtx lhs_e vm)
  | _ -> texpr ""

let rec category_disjunction_side_condition vm e =
  match (unwrap_exp_for_meta e).it with
  | CmpE (`EqOp, _, lhs_e, rhs_e) ->
      let t = category_equality_side_condition vm lhs_e rhs_e in
      if t.text = "" then None else Some t
  | BinE (`OrOp, _, e1, e2) ->
      (match category_disjunction_side_condition vm e1,
             category_disjunction_side_condition vm e2 with
       | Some t1, Some t2 ->
           Some { text = Printf.sprintf "_or_ ( %s, %s )" t1.text t2.text;
                  vars = uniq_vars (t1.vars @ t2.vars) }
       | _ -> None)
  | _ -> None

let inverse_prem_item_of_equality vm lhs_e rhs_e bool_t =
  let lhs_e = unwrap_exp_for_meta lhs_e in
  match lhs_e.it with
  | CallE (id, args) ->
      let fn = call_name id.it in
      (match inverse_call_name fn with
       | None -> None
       | Some inv_fn ->
           let arg_ts = List.map (fun a -> translate_arg a vm) args in
           let rhs_t = translate_exp TermCtx rhs_e vm in
           let candidate_indices =
             arg_ts
             |> List.mapi (fun i (t : texpr) ->
                 let other_vars =
                   arg_ts
                   |> List.mapi (fun j (u : texpr) -> if i = j then [] else u.vars)
                   |> List.flatten
                 in
                 match t.vars with
                 | [v]
                     when String.trim t.text = v
                          && not (List.mem v rhs_t.vars)
                          && not (List.mem v other_vars) -> Some i
                 | _ -> None)
             |> List.filter_map (fun x -> x)
           in
           (match candidate_indices with
            | [target_i] ->
                let target = List.nth arg_ts target_i in
                let inv_args =
                  arg_ts
                  |> List.mapi (fun i t -> if i = target_i then None else Some t)
                  |> List.filter_map (fun x -> x)
                  |> fun xs -> xs @ [rhs_t]
                in
                let inv_rhs =
                  { text = format_call inv_fn (List.map (fun (t : texpr) -> t.text) inv_args);
                    vars = uniq_vars (List.concat_map (fun (t : texpr) -> t.vars) inv_args) }
                in
                Some (PremEq { lhs = target; rhs = inv_rhs; bool_t })
            | _ -> None))
  | _ -> None

let is_keywordish_token v =
  List.mem v
    ["TRUE"; "FALSE"; "EPS"; "CONST"; "LOCAL-GET"; "GLOBAL-GET";
     "VAL"; "TYPE"; "MODULE"; "LOCALS"]

let is_upper_initial v =
  String.length v > 0 &&
  let c = v.[0] in
  c >= 'A' && c <= 'Z'

let is_hyphen_var_like v =
  if not (String.contains v '-') then true
  else
    let parts = String.split_on_char '-' v |> List.filter (fun s -> s <> "") in
    match List.rev parts with
    | [] -> false
    | last :: _ ->
        String.exists (fun c -> c >= '0' && c <= '9') v || String.length last <= 2

let is_bindable_name v =
  v <> "" && is_upper_initial v && is_hyphen_var_like v && not (is_keywordish_token v)

let vars_of_texpr (t : texpr) =
  let extracted = extract_vars_from_maude t.text |> List.filter is_bindable_name in
  uniq_vars (t.vars @ extracted)

let subset_bound bound vars =
  List.for_all (fun v -> SSet.mem v bound) vars

let split_unbound bound vars =
  let unbound = List.filter (fun v -> not (SSet.mem v bound)) vars in
  let bound_vs = List.filter (fun v -> SSet.mem v bound) vars in
  (unbound, bound_vs)

let is_expanddt_term_text text =
  let text = String.trim (strip_wrapping_parens text) in
  starts_with text "$expanddt"

let rec decompose_eq_expr (e : exp) : (exp * exp) option =
  let first_some xs =
    let rec go = function
      | [] -> None
      | y :: ys ->
          (match decompose_eq_expr y with
           | Some _ as hit -> hit
           | None -> go ys)
    in
    go xs
  in
  let exp_of_arg (a : arg) = match a.it with
    | ExpA e1 -> Some e1
    | _ -> None
  in
  match e.it with
  | CmpE (`EqOp, _, e1, ({it = BoolE true; _} as e2)) ->
      (match decompose_eq_expr e1 with
       | Some _ as hit -> hit
       | None -> Some (e1, e2))
  | CmpE (`EqOp, _, ({it = BoolE true; _} as e1), e2) ->
      (match decompose_eq_expr e2 with
       | Some (l, r) -> Some (l, r)
       | None -> Some (e1, e2))
  | BinE (`EquivOp, _, e1, ({it = BoolE true; _})) ->
      (match decompose_eq_expr e1 with
       | Some _ as hit -> hit
       | None -> None)
  | BinE (`EquivOp, _, ({it = BoolE true; _}), e2) ->
      (match decompose_eq_expr e2 with
       | Some _ as hit -> hit
       | None -> None)
  | CmpE (`EqOp, _, e1, e2) -> Some (e1, e2)
  | BinE (`EquivOp, _, e1, e2) -> Some (e1, e2)
  | CvtE (e1, _, _) | SubE (e1, _, _) | ProjE (e1, _) | UncaseE (e1, _)
  | TheE e1 | LiftE e1 | IterE (e1, _) ->
      decompose_eq_expr e1
  | OptE (Some e1) -> decompose_eq_expr e1
  | BinE ((`AndOp | `OrOp | `ImplOp), _, e1, e2) ->
      (match decompose_eq_expr e1 with
       | Some _ as hit -> hit
       | None -> decompose_eq_expr e2)
  | IfE (c, e1, e2) ->
      (match decompose_eq_expr c with
       | Some _ as hit -> hit
       | None ->
           match decompose_eq_expr e1 with
           | Some _ as hit -> hit
           | None -> decompose_eq_expr e2)
    | CallE (_, args) ->
      first_some (List.filter_map exp_of_arg args)
    | TupE es | ListE es ->
      first_some es
    | DotE (e1, _) | LenE e1 ->
      decompose_eq_expr e1
    | CatE (e1, e2) | MemE (e1, e2) | IdxE (e1, e2) | CompE (e1, e2)
    | UpdE (e1, _, e2) | ExtE (e1, _, e2) ->
      (match decompose_eq_expr e1 with
       | Some _ as hit -> hit
       | None -> decompose_eq_expr e2)
    | SliceE (e1, e2, e3) ->
      (match decompose_eq_expr e1 with
       | Some _ as hit -> hit
       | None ->
         match decompose_eq_expr e2 with
         | Some _ as hit -> hit
         | None -> decompose_eq_expr e3)
    | StrE fields ->
      first_some (List.map snd fields)
  | _ -> None

type map_call_occurrence = {
  map_helper : map_call_helper;
  map_start : int;
  map_end_excl : int;
  map_seq_var : string;
}

let replace_span text start_i end_i repl =
  let prefix = String.sub text 0 start_i in
  let suffix = String.sub text end_i (String.length text - end_i) in
  prefix ^ repl ^ suffix

let find_matching_paren text open_i =
  let len = String.length text in
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
  if open_i < len && text.[open_i] = '(' then loop open_i 0 else None

let find_unary_map_call_occurrence text =
  let helpers =
    !map_call_helpers
    |> List.filter (fun h -> h.map_arity = 1 && h.map_seq_index = 0)
    |> List.sort (fun a b -> compare a.map_helper_name b.map_helper_name)
  in
  let rec try_helpers = function
    | [] -> None
    | h :: rest ->
        (try
           let start_i =
             Str.search_forward (Str.regexp_string h.map_helper_name) text 0
           in
           let i = ref (start_i + String.length h.map_helper_name) in
           while !i < String.length text &&
                 (text.[!i] = ' ' || text.[!i] = '\t' ||
                  text.[!i] = '\n' || text.[!i] = '\r') do
             incr i
           done;
           if !i >= String.length text || text.[!i] <> '(' then try_helpers rest
           else
             match find_matching_paren text !i with
             | None -> try_helpers rest
             | Some close_i ->
                 let args_text =
                   String.sub text (!i + 1) (close_i - !i - 1)
                 in
                 (match split_top_level_commas args_text with
                  | [arg] ->
                      let arg = strip_wrapping_parens arg |> String.trim in
                      if is_plain_var_like arg then
                        Some { map_helper = h;
                               map_start = start_i;
                               map_end_excl = close_i + 1;
                               map_seq_var = arg }
                      else try_helpers rest
                  | _ -> try_helpers rest)
         with Not_found -> try_helpers rest)
  in
  try_helpers helpers

let map_call_prem_items (lhs : texpr) (rhs : texpr) =
  let make side_text other_t occ =
    let helper_stem =
      occ.map_helper.map_helper_name
      |> String.map (function
          | '$' -> 'S'
          | '-' | '_' -> '-'
          | c -> Char.uppercase_ascii c)
    in
    let mapped_var = occ.map_seq_var ^ "-" ^ helper_stem ^ "-MAPPED" in
    let replaced_text =
      replace_span side_text occ.map_start occ.map_end_excl mapped_var
    in
    let replaced_t =
      { text = replaced_text;
        vars = extract_vars_from_maude replaced_text }
    in
    let seq_t = texpr_with_var occ.map_seq_var occ.map_seq_var in
    let unmap_t =
      { text =
          Printf.sprintf "%s ( %s )"
            (unmap_call_helper_name occ.map_helper.map_helper_name)
            mapped_var;
        vars = [mapped_var] }
    in
    let guard_t =
      { text =
          Printf.sprintf "( %s ( %s ) == %s )"
            occ.map_helper.map_helper_name occ.map_seq_var mapped_var;
        vars = uniq_vars [occ.map_seq_var; mapped_var] }
    in
    replaced_t, seq_t, unmap_t, guard_t, other_t
  in
  match find_unary_map_call_occurrence lhs.text,
        find_unary_map_call_occurrence rhs.text with
  | Some occ, None ->
      let replaced_lhs, seq_t, unmap_t, guard_t, rhs_t =
        make lhs.text rhs occ
      in
      Some [ PremEq { lhs = replaced_lhs; rhs = rhs_t;
                      bool_t = { text = Printf.sprintf "( %s == %s )"
                                  replaced_lhs.text rhs_t.text;
                                 vars = uniq_vars (replaced_lhs.vars @ rhs_t.vars) } };
             PremMatch { lhs = seq_t; rhs = unmap_t; binds = [occ.map_seq_var] };
             PremBool guard_t ]
  | None, Some occ ->
      if is_plain_var_like lhs.text then None
      else
        let replaced_rhs, seq_t, unmap_t, guard_t, lhs_t =
          make rhs.text lhs occ
        in
        Some [ PremEq { lhs = lhs_t; rhs = replaced_rhs;
                        bool_t = { text = Printf.sprintf "( %s == %s )"
                                    lhs_t.text replaced_rhs.text;
                                   vars = uniq_vars (lhs_t.vars @ replaced_rhs.vars) } };
               PremMatch { lhs = seq_t; rhs = unmap_t; binds = [occ.map_seq_var] };
               PremBool guard_t ]
  | _ -> None

(** Collect individual prem_items from an expression, splitting AND conjunctions.
    Each equality sub-expression becomes its own PremEq so the scheduler can
    independently bind variables from each clause (fixes missing :=  bindings). *)
let rec collect_prem_items_of_exp vm e : prem_item list =
  match e.it with
  | BinE (`AndOp, _, e1, e2) ->
      collect_prem_items_of_exp vm e1 @ collect_prem_items_of_exp vm e2
  | BinE (`OrOp, _, _, _) ->
      (match category_disjunction_side_condition vm e with
       | Some t -> [PremBool t]
       | None ->
           let t = translate_exp BoolCtx e vm in
           if t.text = "" || t.text = "owise" then [] else [PremBool t])
  | CmpE (`EqOp, _, lhs_e, ({it = BoolE true; _} as _e2)) ->
      (* outer "= true" wrapper — recurse into lhs *)
      collect_prem_items_of_exp vm lhs_e
  | CmpE (`EqOp, _, lhs_e, rhs_e) ->
      let lhs = translate_exp TermCtx lhs_e vm in
      let rhs = translate_exp TermCtx rhs_e vm in
      (* For bool_t fallback, use BoolCtx so both sides stay as Bool (avoid w-bool/Bool mismatch) *)
      let lhs_b = translate_exp BoolCtx lhs_e vm in
      let rhs_b = translate_exp BoolCtx rhs_e vm in
      let bool_t = { text = Printf.sprintf "( %s == %s )" lhs_b.text rhs_b.text;
                     vars = uniq_vars (lhs_b.vars @ rhs_b.vars) } in
      (match inverse_prem_item_of_equality vm lhs_e rhs_e bool_t with
       | Some item -> [item]
       | None ->
           (match map_call_prem_items lhs rhs with
            | Some items -> items
            | None -> [PremEq { lhs; rhs; bool_t }]))
  | BinE (`EquivOp, _, lhs_e, rhs_e) ->
      let lhs = translate_exp TermCtx lhs_e vm in
      let rhs = translate_exp TermCtx rhs_e vm in
      let lhs_b = translate_exp BoolCtx lhs_e vm in
      let rhs_b = translate_exp BoolCtx rhs_e vm in
      let bool_t = { text = Printf.sprintf "( %s == %s )" lhs_b.text rhs_b.text;
                     vars = uniq_vars (lhs_b.vars @ rhs_b.vars) } in
      (match inverse_prem_item_of_equality vm lhs_e rhs_e bool_t with
       | Some item -> [item]
       | None ->
           (match map_call_prem_items lhs rhs with
            | Some items -> items
            | None -> [PremEq { lhs; rhs; bool_t }]))
  | MemE (lhs_e, rhs_e) ->
      (* c <- $f(...) : SpecTec set-membership / nondeterministic choice.
         Treat as a binding premise so classify_prem can emit "C := $f(...)"
         when C is a fresh variable and $f's arguments are already bound.
         bool_t fallback emits "(C <- $f(...)) = true" for the rare cases
         where C is already known (pure boolean membership test). *)
      let lhs = translate_exp TermCtx lhs_e vm in
      let rhs = translate_exp TermCtx rhs_e vm in
      let bool_t = { text = Printf.sprintf "( %s <- %s )" lhs.text rhs.text;
                     vars = uniq_vars (lhs.vars @ rhs.vars) } in
      [PremEq { lhs; rhs; bool_t }]
  | _ ->
      let t = translate_exp BoolCtx e vm in
      if t.text = "" || t.text = "owise" then []
      else [PremBool t]

let star_prefix_prem_items (lhs : texpr) (rhs : texpr) =
  match star_prefix_pattern lhs.text, star_prefix_pattern rhs.text with
  | Some (ctor, seq_var), None ->
      let seq_t = texpr_with_var seq_var seq_var in
      let unprefix_t =
        { text = star_unprefix_text ctor rhs.text; vars = rhs.vars }
      in
      let guard_t =
        { text = Printf.sprintf "( %s == %s )"
            (star_prefix_text ctor seq_var) rhs.text;
          vars = uniq_vars (seq_var :: rhs.vars) }
      in
      Some [ PremEq { lhs = seq_t; rhs = unprefix_t; bool_t = guard_t };
             PremBool guard_t ]
  | None, Some (ctor, seq_var) ->
      let seq_t = texpr_with_var seq_var seq_var in
      let unprefix_t =
        { text = star_unprefix_text ctor lhs.text; vars = lhs.vars }
      in
      let guard_t =
        { text = Printf.sprintf "( %s == %s )"
            lhs.text (star_prefix_text ctor seq_var);
          vars = uniq_vars (seq_var :: lhs.vars) }
      in
      Some [ PremEq { lhs = seq_t; rhs = unprefix_t; bool_t = guard_t };
             PremBool guard_t ]
  | _ -> None

let iter_rule_prem_item vm rel_id e xes =
  let rel_name = sanitize rel_id.it in
  let arg_ts : texpr list =
    match e.it with
    | TupE el -> List.map (fun x -> translate_exp TermCtx x vm) el
    | _ -> [translate_exp TermCtx e vm]
  in
  let iter_seq_texts =
    xes
    |> List.map (fun (_, seq_e) ->
         translate_exp TermCtx seq_e vm |> fun t ->
         strip_wrapping_parens t.text |> String.trim)
    |> List.sort_uniq String.compare
  in
  let split_positions =
    arg_ts
    |> List.map (fun (t : texpr) ->
         let text = strip_wrapping_parens t.text |> String.trim in
         List.mem text iter_seq_texts)
  in
  if not (List.exists (fun b -> b) split_positions) then None
  else
    let helper_name = register_iter_rel_helper rel_name split_positions in
    let call =
      Printf.sprintf "%s ( %s ) => valid"
        helper_name
        (String.concat " , " (List.map (fun (t : texpr) -> t.text) arg_ts))
    in
    Some (PremBool {
      text = call;
      vars = uniq_vars (List.concat_map (fun (t : texpr) -> t.vars) arg_ts);
    })

let rec prem_items_of_prem vm (p : prem) : prem_item list =
  match p.it with
  | RulePr (id, _, e) when sanitize id.it = "Expand" ->
      (match e.it with
       | TupE [dt_e; out_e] ->
           let dt = translate_exp TermCtx dt_e vm in
           let out = translate_exp TermCtx out_e vm in
           let expand_rhs =
             { text = Printf.sprintf "$expanddt ( %s )" dt.text;
               vars = dt.vars }
           in
           let bool_t = translate_prem p vm in
           [ PremEq { lhs = out; rhs = expand_rhs; bool_t } ]
       | _ ->
           let t = translate_prem p vm in
           if t.text = "" || t.text = "owise" then [] else [PremBool t])
  | RulePr (id, _, e) ->
      let args =
        match e.it with
        | TupE el -> List.map (fun x -> translate_exp TermCtx x vm) el
        | _ -> [translate_exp TermCtx e vm]
      in
      let t = translate_prem p vm in
      if t.text = "" || t.text = "owise" then []
      else [PremRel { rel_name = sanitize id.it; args; text = t.text }]
  | ElsePr -> []
  | IterPr ({ it = RulePr (rel_id, mixop, e); _ } as inner, (List, xes)) ->
      (match iter_rule_prem_item vm rel_id e xes with
       | Some item -> [item]
       | None -> prem_items_of_prem vm { inner with it = RulePr (rel_id, mixop, e) })
  | IterPr (inner, ((List | List1 | ListN _), _)) ->
      prem_items_of_prem vm inner
      |> List.concat_map (function
          | PremEq ({ lhs; rhs; _ } as eq) ->
              (match star_prefix_prem_items lhs rhs with
               | Some items -> items
               | None -> [PremEq eq])
          | item -> [item])
  | IterPr (inner, _) -> prem_items_of_prem vm inner
  | LetPr (e1, e2, _) ->
      let lhs = translate_exp TermCtx e1 vm in
      let rhs = translate_exp TermCtx e2 vm in
      let bool_t =
        { text = Printf.sprintf "( %s == %s )" lhs.text rhs.text;
          vars = uniq_vars (lhs.vars @ rhs.vars) }
      in
      (match map_call_prem_items lhs rhs with
       | Some items -> items
       | None -> [PremEq { lhs; rhs; bool_t }])
  | IfPr e ->
      let items = collect_prem_items_of_exp vm e in
      if items <> [] then items
      else
        (match decompose_eq_expr e with
         | Some (e1, e2) ->
             let lhs = translate_exp TermCtx e1 vm in
             let rhs = translate_exp TermCtx e2 vm in
             let bool_t = translate_exp BoolCtx e vm in
             (match map_call_prem_items lhs rhs with
              | Some items -> items
              | None -> [PremEq { lhs; rhs; bool_t }])
         | None ->
             let t = translate_prem p vm in
             if t.text = "" || t.text = "owise" then [] else [PremBool t])
  | NegPr inner ->
      let t = translate_prem inner vm in
      if t.text = "" || t.text = "owise" then [] else [PremBool t]

(* Legacy single-result wrapper kept for callers that haven't migrated *)
let prem_item_of_prem vm (p : prem) : prem_item option =
  match prem_items_of_prem vm p with
  | [] -> None
  | x :: _ -> Some x

let classify_prem bound = function
  | PremBool t ->
      let vars = vars_of_texpr t in
      let ready = subset_bound bound vars in
      (`Bool, { text = t.text; vars; binds = [] }, ready)
  | PremRel { text; args; _ } ->
      let vars =
        uniq_vars (extract_vars_from_maude text @ List.concat_map vars_of_texpr args)
      in
      let ready = subset_bound bound vars in
      (`Bool, { text; vars; binds = [] }, ready)
  | PremMatch { lhs; rhs; binds } ->
      let rhs_vars = vars_of_texpr rhs in
      let lhs_vars = vars_of_texpr lhs in
      let ready = subset_bound bound rhs_vars in
      (`Match,
       { text = Printf.sprintf "%s := %s" lhs.text rhs.text;
         vars = uniq_vars (lhs_vars @ rhs_vars);
         binds },
       ready)
  | PremEq { lhs; rhs; bool_t } ->
      let lhs_vars = vars_of_texpr lhs in
      let rhs_vars = vars_of_texpr rhs in
      let lhs_set = SSet.of_list lhs_vars in
      let rhs_set = SSet.of_list rhs_vars in
      let lhs_fresh =
        SSet.elements (SSet.diff lhs_set bound)
      in
      let rhs_fresh =
        SSet.elements (SSet.diff rhs_set bound)
      in
      let lhs_has_no_bound = SSet.is_empty (SSet.inter lhs_set bound) in
      let rhs_has_no_bound = SSet.is_empty (SSet.inter rhs_set bound) in
      let lhs_nonempty = not (SSet.is_empty lhs_set) in
      let rhs_nonempty = not (SSet.is_empty rhs_set) in
      if lhs_fresh <> [] && subset_bound bound rhs_vars then
        (`Match,
         { text = Printf.sprintf "%s := %s" lhs.text rhs.text;
           vars = uniq_vars (lhs_vars @ rhs_vars);
           binds = lhs_fresh },
         true)
      else if rhs_fresh <> [] && subset_bound bound lhs_vars then
        (`Match,
         { text = Printf.sprintf "%s := %s" rhs.text lhs.text;
           vars = uniq_vars (lhs_vars @ rhs_vars);
           binds = rhs_fresh },
         true)
      else if lhs_nonempty && lhs_has_no_bound && subset_bound bound rhs_vars then
        (`Match,
         { text = Printf.sprintf "%s := %s" lhs.text rhs.text;
           vars = uniq_vars (lhs_vars @ rhs_vars);
           binds = lhs_vars },
         true)
      else if rhs_nonempty && rhs_has_no_bound && subset_bound bound lhs_vars then
        (`Match,
         { text = Printf.sprintf "%s := %s" rhs.text lhs.text;
           vars = uniq_vars (lhs_vars @ rhs_vars);
           binds = rhs_vars },
         true)
      else if is_expanddt_term_text lhs.text && subset_bound bound lhs_vars then
        (`Match,
         { text = Printf.sprintf "%s := %s" rhs.text lhs.text;
           vars = uniq_vars (lhs_vars @ rhs_vars);
           binds = rhs_fresh },
         true)
      else if is_expanddt_term_text rhs.text && subset_bound bound rhs_vars then
        (`Match,
         { text = Printf.sprintf "%s := %s" lhs.text rhs.text;
           vars = uniq_vars (lhs_vars @ rhs_vars);
           binds = lhs_fresh },
         true)
      else
        let vars = vars_of_texpr bool_t in
        let ready = subset_bound bound vars in
        (`Bool, { text = bool_t.text; vars; binds = [] }, ready)

let infer_sched_for_rel bound rel_name (args : texpr list) =
  if not (has_infer_rel_rules rel_name) then None
  else
    let arg_vars_for_infer (arg : texpr) =
      uniq_vars (vars_of_texpr arg @ extract_vars_from_maude arg.text)
    in
    let candidates =
      args
      |> List.mapi (fun i arg ->
          let arg_vars = arg_vars_for_infer arg in
          let fresh = List.filter (fun v -> not (SSet.mem v bound)) arg_vars in
          let other_vars =
            args
            |> List.mapi (fun j a -> if i = j then [] else arg_vars_for_infer a)
            |> List.flatten
            |> uniq_vars
          in
          (i, arg, fresh, other_vars))
      |> List.filter (fun (_i, _arg, fresh, other_vars) ->
          fresh <> [] && subset_bound bound other_vars)
    in
    match candidates with
    | (i, arg, fresh, _other_vars) :: _ ->
        let helper_name = register_infer_rel_helper rel_name (List.length args) i in
        let helper_args =
          args
          |> List.mapi (fun j (a : texpr) -> if i = j then None else Some a.text)
          |> List.filter_map (fun x -> x)
          |> String.concat " , "
        in
        let rhs =
          if helper_args = "" then helper_name
          else Printf.sprintf "%s ( %s )" helper_name helper_args
        in
        let vars =
          uniq_vars (vars_of_texpr arg @ extract_vars_from_maude rhs)
        in
        Some { text = Printf.sprintf "%s => %s" rhs arg.text;
               vars;
               binds = fresh }
    | [] -> None

let rec schedule_prems bound acc items =
  match items with
  | [] -> List.rev acc
  | _ ->
      let rec pick prefix = function
        | [] -> None
        | it :: rest ->
            let (_kind, sched, ready) = classify_prem bound it in
            if ready then Some (List.rev prefix, sched, rest)
            else pick (it :: prefix) rest
      in
      match pick [] items with
      | Some (before, chosen, after) ->
          let chosen = normalize_assignment_sched bound chosen in
          let bound' = List.fold_left (fun b v -> SSet.add v b) bound chosen.binds in
          schedule_prems bound' (chosen :: acc) (before @ after)
      | None ->
          let rec pick_infer prefix = function
            | [] -> None
            | (PremRel { rel_name; args; _ } as it) :: rest ->
                (match infer_sched_for_rel bound rel_name args with
                 | Some sched -> Some (List.rev prefix, sched, it, rest)
                 | None -> pick_infer (it :: prefix) rest)
            | it :: rest -> pick_infer (it :: prefix) rest
          in
          (match pick_infer [] items with
           | Some (_before, inferred, _it, _after) ->
               let inferred = normalize_assignment_sched bound inferred in
               let bound' =
                 List.fold_left (fun b v -> SSet.add v b) bound inferred.binds
               in
               schedule_prems bound' (inferred :: acc) items
           | None ->
          let rec force bound2 acc2 = function
            | [] -> List.rev acc2
            | it :: rest ->
                let (_kind, sched, _ready) = classify_prem bound2 it in
                let sched = normalize_assignment_sched bound2 sched in
                let bound3 = List.fold_left (fun b v -> SSet.add v b) bound2 sched.binds in
                force bound3 (sched :: acc2) rest
          in
          List.rev_append acc (force bound [] items))

let split_top_level_eqeq text =
  let text = strip_wrapping_parens text |> String.trim in
  let len = String.length text in
  let rec loop i depth =
    if i + 1 >= len then None
    else
      match text.[i] with
      | '(' | '[' | '{' -> loop (i + 1) (depth + 1)
      | ')' | ']' | '}' -> loop (i + 1) (max 0 (depth - 1))
      | '=' when depth = 0 && text.[i + 1] = '=' ->
          let lhs = String.sub text 0 i |> String.trim in
          let rhs = String.sub text (i + 2) (len - i - 2) |> String.trim in
          Some (lhs, rhs)
      | _ -> loop (i + 1) depth
  in
  loop 0 0

let bind_fresh_var_bool_eq lhs_pattern_vars bound_vars (p : prem_sched) =
  if p.binds <> [] then p
  else
    match split_top_level_eqeq p.text with
    | Some (lhs, rhs)
        when is_plain_var_like lhs
             && not (List.mem lhs lhs_pattern_vars)
             && not (List.mem lhs bound_vars)
             && not (List.mem lhs (extract_vars_from_maude rhs)) ->
        { text = Printf.sprintf "%s := %s" lhs rhs;
          vars = uniq_vars (lhs :: extract_vars_from_maude rhs);
          binds = [lhs] }
    | Some (lhs, rhs)
        when is_plain_var_like rhs
             && not (List.mem rhs lhs_pattern_vars)
             && not (List.mem rhs bound_vars)
             && not (starts_with lhs "$map-")
             && not (List.mem rhs (extract_vars_from_maude lhs)) ->
        { text = Printf.sprintf "%s := %s" rhs lhs;
          vars = uniq_vars (rhs :: extract_vars_from_maude lhs);
          binds = [rhs] }
    | _ -> p

let vars_of_prem_item = function
  | PremBool t -> vars_of_texpr t
  | PremRel { args; text; _ } ->
      uniq_vars (extract_vars_from_maude text @ List.concat_map vars_of_texpr args)
  | PremMatch { lhs; rhs; binds } ->
      uniq_vars (vars_of_texpr lhs @ vars_of_texpr rhs @ binds)
  | PremEq { lhs; rhs; bool_t } ->
      uniq_vars (vars_of_texpr lhs @ vars_of_texpr rhs @ vars_of_texpr bool_t)

let hoist_lhs_value_projections prefix (lhs_t : texpr) =
  let re =
    Str.regexp "value[ \t]*( *'\\([A-Z0-9-]+\\),[ \t]*\\([A-Z][A-Z0-9-]*\\)[ \t]*)"
  in
  let b = Buffer.create (String.length lhs_t.text) in
  let items = ref [] in
  let rec loop pos idx =
    match (try Some (Str.search_forward re lhs_t.text pos) with Not_found -> None) with
    | None ->
        Buffer.add_substring b lhs_t.text pos (String.length lhs_t.text - pos);
        idx
    | Some start ->
        let stop = Str.match_end () in
        let field = Str.matched_group 1 lhs_t.text in
        let source_var = Str.matched_group 2 lhs_t.text in
        let matched = Str.matched_string lhs_t.text in
        let fresh =
          Printf.sprintf "%s-PROJ-%s-%d" prefix field idx
        in
        Buffer.add_substring b lhs_t.text pos (start - pos);
        Buffer.add_string b fresh;
        let bool_t =
          { text = Printf.sprintf "( %s == %s )" fresh matched;
            vars = [fresh; source_var] }
        in
        items := PremBool bool_t :: !items;
        loop stop (idx + 1)
  in
  let _ = loop 0 0 in
  if !items = [] then (lhs_t, [])
  else
    let text = Buffer.contents b in
    let vars =
      extract_vars_from_maude text
      |> List.filter is_bindable_name
      |> uniq_vars
    in
    ({ text; vars }, List.rev !items)

let iter_empty_var_groups vm typed_vars prem_list =
  let sort_of_var v = List.assoc_opt v typed_vars in
  let sequence_vars_of_texpr t =
    vars_of_texpr t
    |> List.filter (fun v -> sort_of_var v = Some "SpectecTerminals")
  in
  let rec collect_prem p =
    match p.it with
    | IterPr (inner, (List, xes)) ->
        let xes_vars =
          xes
          |> List.concat_map (fun (_, e) ->
              translate_exp TermCtx e vm |> sequence_vars_of_texpr)
        in
        let inner_vars =
          prem_items_of_prem vm inner
          |> List.concat_map vars_of_prem_item
          |> List.filter (fun v -> sort_of_var v = Some "SpectecTerminals")
        in
        let vars =
          List.sort_uniq String.compare (xes_vars @ inner_vars)
        in
        if vars = [] then [] else [vars]
    | IterPr (inner, _) -> collect_prem inner
    | NegPr inner -> collect_prem inner
    | _ -> []
  in
  prem_list
  |> List.concat_map collect_prem
  |> List.sort_uniq compare

let vars_of_maude_cond known_vars cond =
  extract_vars_from_maude cond
  |> List.filter is_bindable_name
  |> List.filter (fun v -> List.mem v known_vars)
  |> List.sort_uniq String.compare

let safe_to_drop_iter_empty_cond known_vars lhs_vars empty_vars cond =
  vars_of_maude_cond known_vars cond
  |> List.for_all (fun v -> List.mem v empty_vars || List.mem v lhs_vars)

(* --- DecD handler -------------------------------------------------------- *)

let is_maude_var_char c =
  (c >= 'A' && c <= 'Z')
  || (c >= 'a' && c <= 'z')
  || (c >= '0' && c <= '9')
  || c = '-'
  || c = '_'

let replace_maude_var text var repl =
  let n = String.length text in
  let m = String.length var in
  if m = 0 then text
  else
    let b = Buffer.create n in
    let rec loop i =
      if i >= n then ()
      else if i + m <= n && String.sub text i m = var
              && (i = 0 || not (is_maude_var_char text.[i - 1]))
              && (i + m = n || not (is_maude_var_char text.[i + m]))
      then (
        Buffer.add_string b repl;
        loop (i + m)
      ) else (
        Buffer.add_char b text.[i];
        loop (i + 1)
      )
    in
    loop 0;
    Buffer.contents b

let maude_var_occurs text var =
  replace_maude_var text var "\000" <> text

let optional_binder_vars binders vm =
  List.filter_map (fun b -> match b.it with
    | ExpB (v_id, t) ->
        (match t.it with
         | IterT (_, Opt) -> List.assoc_opt v_id.it vm
         | _ -> None)
    | _ -> None
  ) binders
  |> List.sort_uniq String.compare

let rec nonempty_subsets xs =
  match xs with
  | [] -> []
  | x :: rest ->
      let rest_subsets = nonempty_subsets rest in
      [ [x] ] @ rest_subsets @ List.map (fun ys -> x :: ys) rest_subsets

let apply_optional_empty_subst opt_vars text =
  List.fold_left (fun acc opt_v -> replace_maude_var acc opt_v "eps") text opt_vars

let optional_empty_substs binders vm lhs_texts =
  let opt_vars =
    optional_binder_vars binders vm
    |> List.filter (fun opt_v ->
        List.exists (fun s -> maude_var_occurs s opt_v) lhs_texts)
  in
  nonempty_subsets opt_vars

let cond_mentions_optional opt_vars cond =
  List.exists (fun opt_v -> maude_var_occurs cond opt_v) opt_vars

let optionalize_cond_parts opt_vars ~drop_guards conds =
  conds
  |> List.filter (fun cond ->
      not (List.mem cond drop_guards && cond_mentions_optional opt_vars cond))
  |> List.map (apply_optional_empty_subst opt_vars)

let cond_parts_of_text cond =
  let cond = String.trim cond in
  if cond = "" then []
  else Str.split (Str.regexp "[ \t\n]*/\\\\[ \t\n]*") cond

let optionalize_cond_text opt_vars ~drop_guards cond =
  let is_drop_guard cond =
    let cond = String.trim cond in
    List.exists (fun guard -> String.trim guard = cond) drop_guards
  in
  cond_parts_of_text cond
  |> List.filter (fun part ->
      not (is_drop_guard part && cond_mentions_optional opt_vars part))
  |> List.map (apply_optional_empty_subst opt_vars)
  |> cond_join

let translate_decd ss id params result_typ insts =
  let func_name = sanitize id.it in
  let maude_fn =
    if String.length func_name > 0 && func_name.[0] = '$' then func_name
    else "$" ^ func_name in
  let prefix =
    let base = String.uppercase_ascii func_name in
    let base =
      if String.length base > 0 && base.[0] = '$'
      then String.sub base 1 (String.length base - 1)
      else base
    in
    if base = "" then "FN" else base
  in
  let () =
    if debug_iter_enabled && String.length func_name >= 5
       && String.sub func_name 0 5 = "subst"
    then
      debug_iter "[DECD] func=%s maude_fn=%s prefix=%s insts=%d"
        func_name maude_fn prefix (List.length insts)
  in
  let rename_prem_sched_vars renames (p : prem_sched) =
    {
      text =
        List.fold_left (fun acc (src, dst) ->
          Str.global_replace (Str.regexp_string src) dst acc
        ) p.text renames;
      vars =
        p.vars
        |> List.map (fun v -> match List.assoc_opt v renames with Some v' -> v' | None -> v)
        |> List.sort_uniq String.compare;
      binds =
        p.binds
        |> List.map (fun v -> match List.assoc_opt v renames with Some v' -> v' | None -> v)
        |> List.sort_uniq String.compare;
    }
  in
  let param_sort (p : param) =
    match p.it with
    | ExpP (_, t) -> decd_sort_of_typ t
    | _ -> "SpectecTerminal"
  in
  let arg_sort_list = List.map param_sort params in
  let arg_sorts = String.concat " " arg_sort_list in
  let inferred_bool =
    List.exists (fun inst -> match inst.it with DefD (_, _, rhs, _) -> exp_is_boolish rhs) insts in
  let ret_sort =
    if inferred_bool || SSet.mem maude_fn ss.bool_calls
    then "Bool"
    else decd_sort_of_typ result_typ
  in
  let rhs_ctx = if ret_sort = "Bool" then BoolCtx else TermCtx in

  let all_bound = ref [] and all_free = ref [] and all_typed = ref [] in
  let seen_rewrite_clause = ref false in
  let eq_lines = List.mapi (fun eq_idx inst ->
    let (binders, lhs_args, rhs_exp, prem_list) =
      match inst.it with DefD (b, la, re, pl) -> (b, la, re, pl) in
    let vm = binder_to_var_map prefix eq_idx binders in
    reset_listn_pairs ();
    record_listn_pairs_from_binders binders vm;
    let bconds = binder_to_type_conds binders vm in
    let typed_vars = decd_binder_var_sorts binders vm in
    all_typed := List.sort_uniq compare (!all_typed @ typed_vars);

    let lhs_ts : texpr list = List.map (fun a -> translate_arg a vm) lhs_args in
    let lhs_strs : string list = List.map (fun (t : texpr) -> t.text) lhs_ts in
    let lhs_vars = List.concat_map (fun (t : texpr) -> t.vars) lhs_ts in

    let rhs_t0 = translate_exp rhs_ctx rhs_exp vm in

    let prem_items = List.concat_map (prem_items_of_prem vm) prem_list in
    let prem_scheduled0 = schedule_prems (SSet.of_list lhs_vars) [] prem_items in
    let prem_binds0 = List.concat_map (fun (p : prem_sched) -> p.binds) prem_scheduled0 in
    let vm_vars = List.map snd vm in
    let rhs_only_vm_vars =
      vm_vars
      |> List.filter (fun v ->
           List.mem v rhs_t0.vars
           && not (List.mem v lhs_vars)
           && not (List.mem v prem_binds0))
      |> List.sort_uniq String.compare
    in
    let free_vm_renames =
      List.map (fun v -> (v, "FREE-" ^ v)) rhs_only_vm_vars
    in
    let rhs_t = rename_texpr_vars free_vm_renames rhs_t0 in
    let prem_scheduled = List.map (rename_prem_sched_vars free_vm_renames) prem_scheduled0 in
    let prem_strs = List.map (fun (p : prem_sched) -> p.text) prem_scheduled in
    let prem_vars = List.concat_map (fun (p : prem_sched) -> p.vars @ p.binds) prem_scheduled in
    let prem_binds = List.concat_map (fun (p : prem_sched) -> p.binds) prem_scheduled in
    let bool_safety_conds =
      if rhs_ctx = BoolCtx then []
      else bool_sort_safety_conds_exp rhs_exp vm
    in

    let has_owise = List.exists (fun p -> match p.it with ElsePr -> true | _ -> false) prem_list in
    let all_collected = lhs_vars @ rhs_t.vars @ prem_vars in
    let all_texts = lhs_strs @ [rhs_t.text] @ prem_strs in
    let lhs_bound_seed = List.sort_uniq String.compare (lhs_vars @ prem_binds) in
    let (bound, free, lhs_set) = partition_vars lhs_bound_seed all_texts all_collected in

    let filtered_bconds =
      bconds
      |> List.filter (fun (mv, _) ->
          List.mem mv lhs_set
          && not (List.mem mv prem_binds)
          && not (List.mem mv lhs_vars))
      |> List.map snd in
    all_bound := List.sort_uniq String.compare (!all_bound @ bound);
    all_free := List.sort_uniq String.compare (!all_free @ free);

    let prem_conds, clause_uses_rewrite =
      prem_scheduled
      |> List.fold_left (fun (acc, uses_rewrite) (p : prem_sched) ->
          match rewriteify_prem_text ~extra_heads:[maude_fn] p.text with
          | Some rew ->
              (acc @ [rew], true)
          | None ->
              (acc @ [prem_cond p.text], uses_rewrite)
        ) ([], false)
    in
    let listn_len_conds = listn_len_conditions lhs_set in
    let all_conds =
      (prem_conds @ filtered_bconds @ listn_len_conds @ bool_safety_conds)
      |> List.map normalize_generated_free_const_assignment
    in
    let cond = cond_join all_conds in
    let cond_str = if cond = "" then "" else "\n      if " ^ cond in
    let clause_is_rewrite = clause_uses_rewrite in
    if clause_is_rewrite then seen_rewrite_clause := true;
    if clause_is_rewrite then
      Printf.sprintf "  %s [%s-r%d] :\n    %s\n    =>\n    %s%s ."
        (if cond = "" then "rl" else "crl")
        func_name eq_idx
        (format_call maude_fn lhs_strs) rhs_t.text cond_str
    else
      Printf.sprintf "  %s %s = %s%s%s ."
        (if cond = "" then "eq" else "ceq")
        (format_call maude_fn lhs_strs) rhs_t.text cond_str
        (if has_owise then " [owise]" else "")
  ) insts in

  let truly_free = List.filter (fun v -> not (List.mem v !all_bound)) !all_free in
  if !seen_rewrite_clause then
    rewrite_defs_seen := SSet.add maude_fn !rewrite_defs_seen;
  let op_decl = Printf.sprintf "\n\n  op %s : %s -> %s .\n" maude_fn arg_sorts ret_sort in
  let typed_decl = declare_vars_by_sort !all_typed in
  let bound_untyped =
    !all_bound
    |> List.filter (fun v -> not (List.mem_assoc v !all_typed))
    |> List.sort_uniq String.compare
  in
  let bound_decl = declare_vars_same_sort bound_untyped "SpectecTerminal" in
  let free_decl = declare_ops_const_list truly_free "SpectecTerminal" in
  "\n" ^ op_decl ^ typed_decl ^ bound_decl ^ free_decl
  ^ String.concat "\n" eq_lines ^ "\n"

(* --- Step execution relation helpers ------------------------------------- *)

(** True if the given relation name is one of the three execution Step variants. *)
let is_step_exec_rel name =
  name = "Step" || name = "Step-pure" || name = "Step-read"

let is_steps_rel name =
  name = "Steps"

(** Attempt to decompose a config expression  z ; instr*  into its two parts.
    Detects the  _;_  operator by checking that the CTOR name is CTORSEMICOLONA2. *)
let try_decompose_config (e : exp) : (exp * exp) option =
  match e.it with
  | CaseE (mixop, inner) ->
      let arity = match inner.it with TupE es -> List.length es | _ -> 1 in
      (match canonical_ctor_name_arity mixop arity with
       | Some name when name = "CTORSEMICOLONA2" ->
           (match inner.it with
            | TupE [z_e; instr_e] -> Some (z_e, instr_e)
            | _ -> None)
       | _ -> None)
  | _ -> None

(** Generate Maude step rewrite rules for Step-pure / Step-read / Step rules.
    Baseline pattern: translate the SpecTec conclusion directly:
      z ; lhs ~> z' ; rhs
    becomes
      step(< z | lhs >) => < z' | rhs >
    with no synthetic value-prefix or instruction-suffix context. Context
    closure is represented only by the SpecTec context rules themselves.
    Returns the generated Maude source fragment (declarations + rules). *)
let translate_step_reld rel_name rules =
  let rel_prefix       = String.uppercase_ascii (sanitize rel_name) in
  let all_bound        = ref [] in
  let all_is_vars      = ref [] in
  let all_val_seq_vars = ref [] in
  let all_val_term_seq_vars = ref [] in
  let all_typed_vars   = ref [] in

  let rule_lines = List.mapi (fun rule_idx r -> match r.it with
    | RuleD (case_id, binders, _, conclusion, prem_list) ->
        if rel_name = "Step" && bs_skip_ctxt_rule case_id.it then ""
        else begin
          let raw_prefix = String.uppercase_ascii (sanitize case_id.it) in
          let case_part =
            if raw_prefix = "" then Printf.sprintf "R%d" rule_idx else raw_prefix
          in
          let prefix = Printf.sprintf "%s-%s" rel_prefix case_part in
          let label_prefix = rule_label_prefix rel_name case_id.it rule_idx in
          let vm = binder_to_var_map prefix rule_idx binders in
          let typed_vars = binder_var_sorts binders vm in
          let bconds = binder_to_type_conds binders vm in
          let all_seq_vars =
            List.filter_map (fun b -> match b.it with
              | ExpB (v_id, t) ->
                  (match t.it with
                   | IterT (_, _) -> List.assoc_opt v_id.it vm
                   | _ -> None)
              | _ -> None) binders
            |> List.sort_uniq String.compare
          in
          let val_seq_vars =
            List.filter_map (fun b -> match b.it with
              | ExpB (v_id, t) ->
                  (match t.it with
                   | IterT (inner_t, _) ->
                       (match simple_sort_of_typ inner_t [] with
                        | Some s when s = "Val" -> List.assoc_opt v_id.it vm
                        | _ -> None)
                   | _ -> None)
              | _ -> None) binders
            |> List.sort_uniq String.compare
          in
          all_val_term_seq_vars := !all_val_term_seq_vars @ val_seq_vars;
          let bconds =
            List.filter (fun (mv, _) -> not (List.mem mv all_seq_vars)) bconds
          in
          all_val_seq_vars := !all_val_seq_vars @ all_seq_vars;
          reset_listn_pairs ();
          record_listn_pairs_from_binders binders vm;

          let decoded : (string * string list * texpr * string * string list * texpr) option =
            if rel_name = "Step-pure" then
              (match conclusion.it with
               | TupE [lhs; rhs] ->
                   let z_var = prefix ^ "-Z" in
                   Some (z_var, [z_var], translate_exp TermCtx lhs vm,
                         z_var, [z_var], translate_exp TermCtx rhs vm)
               | _ -> None)
            else if rel_name = "Step-read" then
              (match conclusion.it with
               | TupE [cfg_lhs; rhs] ->
                   (match try_decompose_config cfg_lhs with
                    | Some (z_e, lhs_e) ->
                        let z_t = translate_exp TermCtx z_e vm in
                        let lhs_t = translate_exp TermCtx lhs_e vm in
                        let rhs_t = translate_exp TermCtx rhs vm in
                        Some (z_t.text, z_t.vars, lhs_t, z_t.text, z_t.vars, rhs_t)
                    | None -> None)
               | _ -> None)
            else
              (match conclusion.it with
               | TupE [cfg_lhs; cfg_rhs] ->
                   (match try_decompose_config cfg_lhs,
                          try_decompose_config cfg_rhs with
                    | Some (z_e, lhs_e), Some (zp_e, rhs_e) ->
                        let z_t = translate_exp TermCtx z_e vm in
                        let lhs_t = translate_exp TermCtx lhs_e vm in
                        let zp_t = translate_exp TermCtx zp_e vm in
                        let rhs_t = translate_exp TermCtx rhs_e vm in
                        Some (z_t.text, z_t.vars, lhs_t, zp_t.text, zp_t.vars, rhs_t)
                    | _ -> None)
               | _ -> None)
          in
          match decoded with
          | None ->
              Printf.eprintf
                "[WARN] translate_step_reld: cannot decode %s rule %s (#%d)\n%!"
                rel_name prefix rule_idx;
              ""
          | Some (z_in, z_in_vars, lhs_t, z_out, z_out_vars, rhs_t) ->
              let vm_vars = List.map snd vm in
              let lhs_vars = vars_of_texpr lhs_t in
              let prem_items = List.concat_map (prem_items_of_prem vm) prem_list in
              let vm_var_set = SSet.of_list vm_vars in
              let lhs_t_var_set = SSet.of_list lhs_vars in
              let prem_binding_targets =
                List.concat_map (fun item ->
                  match item with
                  | PremEq { lhs; rhs; _ } ->
                      let pick side =
                        List.filter (fun v ->
                          SSet.mem v vm_var_set && not (SSet.mem v lhs_t_var_set))
                          (uniq_vars (vars_of_texpr side @ extract_vars_from_maude side.text))
                      in
                      pick lhs @ pick rhs
                  | PremRel { args; _ } ->
                      args
                      |> List.concat_map (fun a ->
                          uniq_vars (vars_of_texpr a @ extract_vars_from_maude a.text))
                      |> List.filter (fun v ->
                          SSet.mem v vm_var_set && not (SSet.mem v lhs_t_var_set))
                  | _ -> []) prem_items
                |> List.sort_uniq String.compare
              in
              let prem_binding_set = SSet.of_list prem_binding_targets in
              let lhs_set =
                SSet.of_list (z_in_vars @ lhs_vars @
                  List.filter (fun v -> not (SSet.mem v prem_binding_set)) vm_vars)
              in
              let prem_scheduled = schedule_prems lhs_set [] prem_items in
              let rhs_text_out, prem_scheduled =
                if rel_name = "Step-read"
                   && (case_id.it = "local-get" || case_id.it = "global-get")
                then rhs_inline_from_sched rhs_t.text prem_scheduled
                else (rhs_t.text, prem_scheduled)
              in
              let ctxt_focus_rewrite = None in
              let rewrite_ctxt_focus_text text =
                match ctxt_focus_rewrite with
                | None -> text
                | Some (focus, _head, _rest, focus_text) ->
                    replace_maude_var_token focus focus_text text
              in
              let lhs_text_out = rewrite_ctxt_focus_text lhs_t.text in
              let rhs_text_out = rewrite_ctxt_focus_text rhs_text_out in
              let prem_scheduled =
                match ctxt_focus_rewrite with
                | None -> prem_scheduled
                | Some (focus, head, rest, _focus_text) ->
                    List.map (fun (p : prem_sched) ->
                      { p with
                        text = rewrite_ctxt_focus_text p.text;
                        vars =
                          p.vars
                          |> List.filter (fun v -> v <> focus)
                          |> fun vs -> head :: rest :: vs
                          |> List.sort_uniq String.compare })
                      prem_scheduled
              in
              let lhs_pattern_seed =
                (z_in_vars @ lhs_vars @ extract_vars_from_maude (z_in ^ " " ^ lhs_text_out))
                |> List.sort_uniq String.compare
              in
              let prem_scheduled =
                let bound_ref = ref lhs_pattern_seed in
                List.map (fun p ->
                  let p = bind_fresh_var_bool_eq lhs_pattern_seed !bound_ref p in
                  let p = normalize_assignment_sched (SSet.of_list !bound_ref) p in
                  bound_ref := List.sort_uniq String.compare (!bound_ref @ p.binds);
                  p)
                  prem_scheduled
              in
              let prem_strs = List.map (fun (p : prem_sched) -> p.text) prem_scheduled in
              let prem_binds = List.concat_map (fun p -> p.binds) prem_scheduled in
              let prem_binds_seq =
                List.filter (fun v -> List.mem v all_seq_vars) prem_binds
              in
              all_val_seq_vars := !all_val_seq_vars @ prem_binds_seq;
              (match ctxt_focus_rewrite with
               | None -> ()
               | Some (_focus, head, rest, _focus_text) ->
                   all_bound := head :: !all_bound;
                   all_val_seq_vars := rest :: !all_val_seq_vars);

              let all_texts = [z_in; lhs_text_out; z_out; rhs_text_out] @ prem_strs in
              let all_cvars = (z_in_vars @ lhs_vars @ z_out_vars @ rhs_t.vars @ vm_vars) @
                List.concat_map (fun p -> p.vars @ p.binds) prem_scheduled in
              let lhs_seed =
                List.sort_uniq String.compare (z_in_vars @ lhs_vars @ prem_binds)
              in
              let (bound, _free, lhs_set2) = partition_vars lhs_seed all_texts all_cvars in
              all_bound := !all_bound @ bound @ vm_vars;
              let lhs_pattern_vars =
                z_in_vars @ lhs_vars @ extract_vars_from_maude (z_in ^ " " ^ lhs_text_out)
                |> List.sort_uniq String.compare
              in
              let typed_vars_for_decl, refined_lhs_pairs, refined_lhs_guards =
                widen_refined_lhs_typed_vars typed_vars lhs_pattern_vars
              in
              all_typed_vars := List.sort_uniq compare (!all_typed_vars @ typed_vars_for_decl);

              let has_numtype_guard cond =
                let s = String.trim cond in
                try
                  ignore (Str.search_forward (Str.regexp ": Numtype\\b") s 0);
                  true
                with Not_found -> false
              in
              let filtered_bconds =
                let guard_used_vars =
                  extract_vars_from_maude (String.concat " " all_texts)
                  |> List.sort_uniq String.compare
                in
                bconds
                |> List.filter (fun (mv, _) ->
                    List.mem mv guard_used_vars)
                |> List.map snd
                |> List.filter (fun cond ->
                    not (is_refined_exec_original_guard refined_lhs_pairs cond))
                |> List.filter (fun cond -> not (redundant_binder_guard typed_vars cond))
                |> fun conds ->
                     if rel_name = "Step-pure" then
                       List.filter (fun c -> not (has_numtype_guard c)) conds
                     else conds
              in
              let is_rewrite_cond text =
                try
                  ignore (Str.search_forward (Str.regexp_string "=>") text 0);
                  true
                with Not_found -> false
              in
              let prem_rewrite_conds =
                prem_scheduled |> List.filter_map (fun p ->
                  if is_rewrite_cond p.text then Some (prem_cond p.text) else None)
              in
              let prem_rewrite_bound_vars =
                prem_scheduled
                |> List.filter (fun p -> is_rewrite_cond p.text)
                |> List.concat_map (fun p -> p.binds)
                |> List.sort_uniq String.compare
              in
              let cond_mentions_any vars cond =
                let used =
                  extract_vars_from_maude cond
                  |> List.sort_uniq String.compare
                in
                List.exists (fun v -> List.mem v used) vars
              in
              let prem_match_conds =
                prem_scheduled |> List.filter_map (fun p ->
                  if p.binds = [] || is_rewrite_cond p.text then None else Some (prem_cond p.text))
              in
              let prem_bool_conds =
                prem_scheduled |> List.filter_map (fun p ->
                  if p.binds = [] && not (is_rewrite_cond p.text) then Some (prem_cond p.text) else None)
              in
              let allvals_conds =
                List.map val_seq_guard val_seq_vars
              in
              let listn_len_conds = listn_len_conditions lhs_set2 in
              let base_conds =
                if rel_name = "Step" && case_id.it = "ctxt-instrs" then
                  let before_rewrite_bconds, after_rewrite_bconds =
                    let rewrite_result_vars =
                      (prem_rewrite_bound_vars @ z_out_vars)
                      |> List.sort_uniq String.compare
                    in
                    List.partition
                      (fun cond -> not (cond_mentions_any rewrite_result_vars cond))
                      filtered_bconds
                  in
                  listn_len_conds @ allvals_conds @ prem_bool_conds @ before_rewrite_bconds
                  @ prem_match_conds @ prem_rewrite_conds @ after_rewrite_bconds
                else
                  prem_match_conds @ prem_rewrite_conds @ listn_len_conds @ allvals_conds
                  @ prem_bool_conds @ filtered_bconds
              in
              let all_conds =
                normalize_assignment_conditions_ordered lhs_pattern_vars
                  (base_conds @ refined_lhs_guards)
              in
              let cond = cond_join all_conds in
              let lhs_rel_text, rhs_rel_text =
                if rel_name = "Step-pure" then
                  (Printf.sprintf "step-pure ( %s )" lhs_text_out,
                   rhs_text_out)
                else if rel_name = "Step-read" then
                  (Printf.sprintf "step-read ( %s )" (config_text z_in lhs_text_out),
                   rhs_text_out)
                else
                  (Printf.sprintf "step ( %s )" (config_text z_in lhs_text_out),
                   config_text z_out rhs_text_out)
              in
              let emit_rule_with_cond label lhs rhs local_cond =
                let emit_one label lhs rhs local_cond =
                  if local_cond = "" then
                    Printf.sprintf "  rl [%s] :\n    %s\n    =>\n    %s ."
                      label lhs rhs
                  else
                    Printf.sprintf "  crl [%s] :\n    %s\n    =>\n    %s\n      if %s ."
                      label lhs rhs local_cond
                in
                emit_one label lhs rhs local_cond
              in
              let emit_rule label lhs rhs = emit_rule_with_cond label lhs rhs cond in
              let label = String.lowercase_ascii label_prefix in
              let primary_rule =
	                if true then
	                  if rel_name = "Step" && case_id.it = "pure" then
	                    emit_rule label lhs_rel_text rhs_rel_text
	                  else if rel_name = "Step" && case_id.it = "read" then
	                    emit_rule label lhs_rel_text rhs_rel_text
	                  else
	                    emit_rule label lhs_rel_text rhs_rel_text
                else
                let find_vm_suffix suffix =
                  List.find_opt (fun v -> ends_with v suffix) vm_vars
                in
                let before_result_bconds =
                  let result_vars = (z_out_vars @ rhs_t.vars) |> List.sort_uniq String.compare in
                  List.filter
                    (fun c -> not (cond_mentions_any result_vars c))
                    filtered_bconds
                in
                let cfg_rewrite_cond inner_z inner_instr =
                  prem_cond
                    (Printf.sprintf "step ( %s ) => EC"
                       (config_text inner_z inner_instr))
                in
                if rel_name = "Step" && case_id.it = "pure" then
                  ""
                else if rel_name = "Step" && case_id.it = "read" then
                  ""
                else if rel_name = "Step" && case_id.it = "ctxt-instrs" then
                  ""
                else if rel_name = "Step" && case_id.it = "ctxt-label" then
                  (match find_vm_suffix "-N",
                         find_vm_suffix "-INSTR0",
                         find_vm_suffix "-INSTR" with
                   | Some n_var, Some instr0_var, Some instr_var ->
                       let val_head = prefix ^ "-CTX-VAL-HEAD" in
                       let val_rest = prefix ^ "-CTX-VAL-REST" in
                       let suffix_head = prefix ^ "-CTX-SUFFIX-HEAD" in
                       let suffix_rest = prefix ^ "-CTX-SUFFIX-REST" in
                       all_bound := val_head :: suffix_head :: !all_bound;
                       all_val_seq_vars := val_rest :: suffix_rest :: !all_val_seq_vars;
                       let base_instr =
                         Printf.sprintf "CTORLABELLBRACERBRACEA3 ( %s, %s, %s )"
                           n_var instr0_var instr_var
                       in
                       let result_instr =
                         Printf.sprintf "CTORLABELLBRACERBRACEA3 ( %s, %s, $cfg-instrs ( EC ) )"
                           n_var instr0_var
                       in
                       let local_cond =
                         cond_join (cfg_rewrite_cond z_in instr_var :: before_result_bconds)
                       in
                       let lhs =
                         Printf.sprintf "step ( %s )"
                           (config_text z_in base_instr)
                       in
                       let rhs =
                         config_text "$cfg-state ( EC )" result_instr
                       in
                       let emit_ctx_bridge bridge_label lhs_instr rhs_instr extra_conds =
                         emit_rule_with_cond
                           bridge_label
                           (Printf.sprintf "step ( %s )" (config_text z_in lhs_instr))
                           (config_text "$cfg-state ( EC )" rhs_instr)
                           (cond_join (extra_conds @ [ local_cond ]))
                       in
                       String.concat "\n"
                         [ emit_rule_with_cond label lhs rhs local_cond;
                           emit_ctx_bridge
                             (label ^ "-ctx-suffix")
                             (Printf.sprintf "%s %s %s" base_instr suffix_head suffix_rest)
                             (Printf.sprintf "%s %s %s" result_instr suffix_head suffix_rest)
                             [];
                           emit_ctx_bridge
                             (label ^ "-ctx-prefix")
                             (Printf.sprintf "%s %s %s" val_head val_rest base_instr)
                             (Printf.sprintf "%s %s %s" val_head val_rest result_instr)
                             [ val_seq_guard (Printf.sprintf "%s %s" val_head val_rest) ];
                           emit_ctx_bridge
                             (label ^ "-ctx-prefix-suffix")
                             (Printf.sprintf "%s %s %s %s %s" val_head val_rest base_instr suffix_head suffix_rest)
                             (Printf.sprintf "%s %s %s %s %s" val_head val_rest result_instr suffix_head suffix_rest)
                             [ val_seq_guard (Printf.sprintf "%s %s" val_head val_rest) ] ]
                   | _ -> emit_rule label lhs_rel_text rhs_rel_text)
                else if rel_name = "Step" && case_id.it = "ctxt-handler" then
                  (match find_vm_suffix "-N",
                         find_vm_suffix "-CATCH",
                         find_vm_suffix "-INSTR" with
                   | Some n_var, Some catch_var, Some instr_var ->
                       let val_head = prefix ^ "-CTX-VAL-HEAD" in
                       let val_rest = prefix ^ "-CTX-VAL-REST" in
                       let suffix_head = prefix ^ "-CTX-SUFFIX-HEAD" in
                       let suffix_rest = prefix ^ "-CTX-SUFFIX-REST" in
                       all_bound := val_head :: suffix_head :: !all_bound;
                       all_val_seq_vars := val_rest :: suffix_rest :: !all_val_seq_vars;
                       let base_instr =
                         Printf.sprintf "CTORHANDLERLBRACERBRACEA3 ( %s, %s, %s )"
                           n_var catch_var instr_var
                       in
                       let result_instr =
                         Printf.sprintf "CTORHANDLERLBRACERBRACEA3 ( %s, %s, $cfg-instrs ( EC ) )"
                           n_var catch_var
                       in
                       let local_cond =
                         cond_join (cfg_rewrite_cond z_in instr_var :: before_result_bconds)
                       in
                       let lhs =
                         Printf.sprintf "step ( %s )"
                           (config_text z_in base_instr)
                       in
                       let rhs =
                         config_text "$cfg-state ( EC )" result_instr
                       in
                       let emit_ctx_bridge bridge_label lhs_instr rhs_instr extra_conds =
                         emit_rule_with_cond
                           bridge_label
                           (Printf.sprintf "step ( %s )" (config_text z_in lhs_instr))
                           (config_text "$cfg-state ( EC )" rhs_instr)
                           (cond_join (extra_conds @ [ local_cond ]))
                       in
                       String.concat "\n"
                         [ emit_rule_with_cond label lhs rhs local_cond;
                           emit_ctx_bridge
                             (label ^ "-ctx-suffix")
                             (Printf.sprintf "%s %s %s" base_instr suffix_head suffix_rest)
                             (Printf.sprintf "%s %s %s" result_instr suffix_head suffix_rest)
                             [];
                           emit_ctx_bridge
                             (label ^ "-ctx-prefix")
                             (Printf.sprintf "%s %s %s" val_head val_rest base_instr)
                             (Printf.sprintf "%s %s %s" val_head val_rest result_instr)
                             [ val_seq_guard (Printf.sprintf "%s %s" val_head val_rest) ];
                           emit_ctx_bridge
                             (label ^ "-ctx-prefix-suffix")
                             (Printf.sprintf "%s %s %s %s %s" val_head val_rest base_instr suffix_head suffix_rest)
                             (Printf.sprintf "%s %s %s %s %s" val_head val_rest result_instr suffix_head suffix_rest)
                             [ val_seq_guard (Printf.sprintf "%s %s" val_head val_rest) ] ]
                   | _ -> emit_rule label lhs_rel_text rhs_rel_text)
                else if rel_name = "Step" && case_id.it = "ctxt-frame" then
                  (match find_vm_suffix "-S",
                         find_vm_suffix "-F",
                         find_vm_suffix "-FQ",
                         find_vm_suffix "-N",
                         find_vm_suffix "-INSTR" with
                   | Some s_var, Some f_var, Some fq_var, Some n_var, Some instr_var ->
                       let val_head = prefix ^ "-CTX-VAL-HEAD" in
                       let val_rest = prefix ^ "-CTX-VAL-REST" in
                       let suffix_head = prefix ^ "-CTX-SUFFIX-HEAD" in
                       let suffix_rest = prefix ^ "-CTX-SUFFIX-REST" in
                       all_bound := val_head :: suffix_head :: !all_bound;
                       all_val_seq_vars := val_rest :: suffix_rest :: !all_val_seq_vars;
                       let outer_state = state_text s_var f_var in
                       let inner_state = state_text s_var fq_var in
                       let base_instr =
                         Printf.sprintf "CTORFRAMELBRACERBRACEA3 ( %s, %s, %s )"
                           n_var fq_var instr_var
                       in
                       let result_state =
                         state_text "$store ( $cfg-state ( EC ) )" f_var
                       in
                       let result_instr =
                         Printf.sprintf "CTORFRAMELBRACERBRACEA3 ( %s, $frame ( $cfg-state ( EC ) ), $cfg-instrs ( EC ) )"
                           n_var
                       in
                       let local_cond =
                         cond_join (cfg_rewrite_cond inner_state instr_var :: before_result_bconds)
                       in
                       let lhs =
                         Printf.sprintf "step ( %s )"
                           (config_text outer_state base_instr)
                       in
                       let rhs =
                         config_text result_state result_instr
                       in
                       let emit_ctx_bridge bridge_label lhs_instr rhs_instr extra_conds =
                         emit_rule_with_cond
                           bridge_label
                           (Printf.sprintf "step ( %s )" (config_text outer_state lhs_instr))
                           (config_text result_state rhs_instr)
                           (cond_join (extra_conds @ [ local_cond ]))
                       in
                       String.concat "\n"
                         [ emit_rule_with_cond label lhs rhs local_cond;
                           emit_ctx_bridge
                             (label ^ "-ctx-suffix")
                             (Printf.sprintf "%s %s %s" base_instr suffix_head suffix_rest)
                             (Printf.sprintf "%s %s %s" result_instr suffix_head suffix_rest)
                             [];
                           emit_ctx_bridge
                             (label ^ "-ctx-prefix")
                             (Printf.sprintf "%s %s %s" val_head val_rest base_instr)
                             (Printf.sprintf "%s %s %s" val_head val_rest result_instr)
                             [ val_seq_guard (Printf.sprintf "%s %s" val_head val_rest) ];
                           emit_ctx_bridge
                             (label ^ "-ctx-prefix-suffix")
                             (Printf.sprintf "%s %s %s %s %s" val_head val_rest base_instr suffix_head suffix_rest)
                             (Printf.sprintf "%s %s %s %s %s" val_head val_rest result_instr suffix_head suffix_rest)
                             [ val_seq_guard (Printf.sprintf "%s %s" val_head val_rest) ] ]
                   | _ -> emit_rule label lhs_rel_text rhs_rel_text)
                else
                  emit_rule label lhs_rel_text rhs_rel_text
              in
              if rel_name <> "Step-pure" then
                primary_rule
              else if rel_name = "Step-pure"
                      && (try ignore (Str.search_forward (Str.regexp_string "label") label 0); true
                          with Not_found -> false) then
                (* Temporary executable scaffolding, limited to label-related
                   Step-pure families.  These lifted Step rules are derived
                   shortcuts, not direct SpecTec rules; they remain only to
                   cover the known Step/ctxt-instrs executability gap for
                   label/br with a suffix. *)
                let bridge_lhs =
                  Printf.sprintf "step ( %s )" (config_text z_in lhs_text_out)
                in
                let bridge_rhs = config_text z_in rhs_text_out in
                let val_head = prefix ^ "-CTX-VAL-HEAD" in
                let val_rest = prefix ^ "-CTX-VAL-REST" in
                let suffix_head = prefix ^ "-CTX-SUFFIX-HEAD" in
                let suffix_rest = prefix ^ "-CTX-SUFFIX-REST" in
                all_bound := val_head :: suffix_head :: !all_bound;
                all_val_seq_vars := val_rest :: suffix_rest :: !all_val_seq_vars;
                let emit_ctx_bridge bridge_label lhs_instr rhs_instr extra_conds =
                  emit_rule_with_cond
                    bridge_label
                    (Printf.sprintf "step ( %s )" (config_text z_in lhs_instr))
                    (config_text z_in rhs_instr)
                    (cond_join (extra_conds @ all_conds))
                in
                String.concat "\n"
                  [ primary_rule;
                    emit_rule ("step-from-" ^ label) bridge_lhs bridge_rhs;
                    emit_ctx_bridge
                      ("step-from-" ^ label ^ "-ctx-suffix")
                      (Printf.sprintf "%s %s %s" lhs_text_out suffix_head suffix_rest)
                      (Printf.sprintf "%s %s %s" rhs_text_out suffix_head suffix_rest)
                      [];
                    emit_ctx_bridge
                      ("step-from-" ^ label ^ "-ctx-prefix")
                      (Printf.sprintf "%s %s %s" val_head val_rest lhs_text_out)
                      (Printf.sprintf "%s %s %s" val_head val_rest rhs_text_out)
                      [ val_seq_guard (Printf.sprintf "%s %s" val_head val_rest) ];
                    emit_ctx_bridge
                      ("step-from-" ^ label ^ "-ctx-prefix-suffix")
                      (Printf.sprintf "%s %s %s %s %s" val_head val_rest lhs_text_out suffix_head suffix_rest)
                      (Printf.sprintf "%s %s %s %s %s" val_head val_rest rhs_text_out suffix_head suffix_rest)
                      [ val_seq_guard (Printf.sprintf "%s %s" val_head val_rest) ] ]
              else if rel_name = "Step-read" then
                let bridge_lhs =
                  Printf.sprintf "step ( %s )" (config_text z_in lhs_text_out)
                in
                let bridge_rhs = config_text z_in rhs_text_out in
                let val_head = prefix ^ "-CTX-VAL-HEAD" in
                let val_rest = prefix ^ "-CTX-VAL-REST" in
                let suffix_head = prefix ^ "-CTX-SUFFIX-HEAD" in
                let suffix_rest = prefix ^ "-CTX-SUFFIX-REST" in
                all_bound := val_head :: suffix_head :: !all_bound;
                all_val_seq_vars := val_rest :: suffix_rest :: !all_val_seq_vars;
                let emit_ctx_bridge bridge_label lhs_instr rhs_instr extra_conds =
                  emit_rule_with_cond
                    bridge_label
                    (Printf.sprintf "step ( %s )" (config_text z_in lhs_instr))
                    (config_text z_in rhs_instr)
                    (cond_join (extra_conds @ all_conds))
                in
                String.concat "\n"
                  [ primary_rule;
                    emit_rule ("step-from-" ^ label) bridge_lhs bridge_rhs;
                    emit_ctx_bridge
                      ("step-from-" ^ label ^ "-ctx-suffix")
                      (Printf.sprintf "%s %s %s" lhs_text_out suffix_head suffix_rest)
                      (Printf.sprintf "%s %s %s" rhs_text_out suffix_head suffix_rest)
                      [];
                    emit_ctx_bridge
                      ("step-from-" ^ label ^ "-ctx-prefix")
                      (Printf.sprintf "%s %s %s" val_head val_rest lhs_text_out)
                      (Printf.sprintf "%s %s %s" val_head val_rest rhs_text_out)
                      [ val_seq_guard (Printf.sprintf "%s %s" val_head val_rest) ];
                    emit_ctx_bridge
                      ("step-from-" ^ label ^ "-ctx-prefix-suffix")
                      (Printf.sprintf "%s %s %s %s %s" val_head val_rest lhs_text_out suffix_head suffix_rest)
                      (Printf.sprintf "%s %s %s %s %s" val_head val_rest rhs_text_out suffix_head suffix_rest)
                      [ val_seq_guard (Printf.sprintf "%s %s" val_head val_rest) ] ]
              else if rel_name = "Step"
                      && not (List.mem case_id.it
                                [ "pure"; "read"; "ctxt-instrs"; "ctxt-label";
                                  "ctxt-handler"; "ctxt-frame" ]) then
                let val_head = prefix ^ "-CTX-VAL-HEAD" in
                let val_rest = prefix ^ "-CTX-VAL-REST" in
                let suffix_head = prefix ^ "-CTX-SUFFIX-HEAD" in
                let suffix_rest = prefix ^ "-CTX-SUFFIX-REST" in
                all_bound := val_head :: suffix_head :: !all_bound;
                all_val_seq_vars := val_rest :: suffix_rest :: !all_val_seq_vars;
                let emit_ctx_bridge bridge_label lhs_instr rhs_instr extra_conds =
                  emit_rule_with_cond
                    bridge_label
                    (Printf.sprintf "step ( %s )" (config_text z_in lhs_instr))
                    (config_text z_out rhs_instr)
                    (cond_join (extra_conds @ all_conds))
                in
                String.concat "\n"
                  [ primary_rule;
                    emit_ctx_bridge
                      (label ^ "-ctx-suffix")
                      (Printf.sprintf "%s %s %s" lhs_text_out suffix_head suffix_rest)
                      (Printf.sprintf "%s %s %s" rhs_text_out suffix_head suffix_rest)
                      [];
                    emit_ctx_bridge
                      (label ^ "-ctx-prefix")
                      (Printf.sprintf "%s %s %s" val_head val_rest lhs_text_out)
                      (Printf.sprintf "%s %s %s" val_head val_rest rhs_text_out)
                      [ val_seq_guard (Printf.sprintf "%s %s" val_head val_rest) ];
                    emit_ctx_bridge
                      (label ^ "-ctx-prefix-suffix")
                      (Printf.sprintf "%s %s %s %s %s" val_head val_rest lhs_text_out suffix_head suffix_rest)
                      (Printf.sprintf "%s %s %s %s %s" val_head val_rest rhs_text_out suffix_head suffix_rest)
                      [ val_seq_guard (Printf.sprintf "%s %s" val_head val_rest) ] ]
              else
                primary_rule
        end
  ) rules in

  let is_simple_var s =
    String.length s > 0
    && not (String.contains s '(')
    && not (String.contains s ')')
    && not (String.contains s ',')
    && not (String.contains s ' ')
  in
  let bound_vars_wt =
    List.filter (fun v -> not (List.mem v !all_val_seq_vars))
      (List.filter is_simple_var (List.sort_uniq String.compare !all_bound))
  in
  let bound_vars_wts =
    List.filter is_simple_var
      (List.sort_uniq String.compare !all_val_seq_vars)
    |> List.filter (fun v -> not (List.mem v !all_val_term_seq_vars))
  in
  let bound_vars_vals =
    List.filter is_simple_var
      (List.sort_uniq String.compare !all_val_term_seq_vars)
  in
  let typed_vars =
    !all_typed_vars
    |> List.filter (fun (v, _) -> is_simple_var v)
    |> List.sort_uniq compare
  in
  let typed_names = List.map fst typed_vars |> List.sort_uniq String.compare in
  let bound_vars_wt = List.filter (fun v -> not (List.mem v typed_names)) bound_vars_wt in
  let is_vars = List.sort_uniq String.compare !all_is_vars in
  let typed_decl = declare_vars_by_sort typed_vars in
  let bound_decl = declare_vars_same_sort bound_vars_wt "SpectecTerminal" in
  let val_terms_decl = declare_vars_same_sort bound_vars_vals "SpectecTerminals" in
  let vals_decl = declare_vars_same_sort bound_vars_wts "SpectecTerminals" in
  let is_decl = declare_vars_same_sort is_vars "SpectecTerminals" in
  let ctxt_instrs_extra = "" in
  let rule_block =
    typed_decl ^ bound_decl ^ val_terms_decl ^ vals_decl ^ is_decl
    ^ ctxt_instrs_extra
    ^ String.concat "\n" (List.filter (fun s -> s <> "") rule_lines)
    ^ "\n"
  in
  rule_block

(* --- RelD handler -------------------------------------------------------- *)

let translate_steps_reld rel_name rules =
  let rel_prefix = String.uppercase_ascii (sanitize rel_name) in
  let all_bound = ref [] in
  let all_free = ref [] in
  let all_seq_vars_acc = ref [] in
  let all_typed_vars = ref [] in

  let rule_lines = List.mapi (fun rule_idx r -> match r.it with
    | RuleD (case_id, binders, _, conclusion, prem_list) ->
        let raw_prefix = String.uppercase_ascii (sanitize case_id.it) in
        let case_part = if raw_prefix = "" then Printf.sprintf "R%d" rule_idx else raw_prefix in
        let prefix = Printf.sprintf "%s-%s" rel_prefix case_part in
        let label_prefix = rule_label_prefix rel_name case_id.it rule_idx in
        let vm = binder_to_var_map prefix rule_idx binders in
        let typed_vars = binder_var_sorts binders vm in
        all_typed_vars := List.sort_uniq compare (!all_typed_vars @ typed_vars);
        let bconds = binder_to_type_conds binders vm in
        let all_seq_vars =
          List.filter_map (fun b -> match b.it with
            | ExpB (v_id, t) ->
                (match t.it with
                 | IterT (_, _) -> List.assoc_opt v_id.it vm
                 | _ -> None)
            | _ -> None) binders
          |> List.sort_uniq String.compare
        in
        all_seq_vars_acc := !all_seq_vars_acc @ all_seq_vars;
        let bconds =
          List.filter (fun (mv, _) -> not (List.mem mv all_seq_vars)) bconds
        in
        let lhs_cfg, rhs_cfg, lhs_vars =
          match conclusion.it with
          | TupE [cfg_lhs; cfg_rhs] ->
              (match try_decompose_config cfg_lhs, try_decompose_config cfg_rhs with
               | Some (z_e, lhs_e), Some (zp_e, rhs_e) ->
                   let z_t = translate_exp TermCtx z_e vm in
                   let lhs_t = translate_exp TermCtx lhs_e vm in
                   let zp_t = translate_exp TermCtx zp_e vm in
                   let rhs_t = translate_exp TermCtx rhs_e vm in
                   (config_text z_t.text lhs_t.text,
                    config_text zp_t.text rhs_t.text,
                    z_t.vars @ lhs_t.vars)
               | _ ->
                   let lhs_t = translate_exp TermCtx conclusion vm in
                   (lhs_t.text, "valid", lhs_t.vars))
          | _ ->
              let lhs_t = translate_exp TermCtx conclusion vm in
              (lhs_t.text, "valid", lhs_t.vars)
        in
        let prem_items = List.concat_map (prem_items_of_prem vm) prem_list in
        let vm_vars = List.map snd vm in
        let vm_var_set = SSet.of_list vm_vars in
        let lhs_t_var_set = SSet.of_list lhs_vars in
        let prem_binding_targets =
          List.concat_map (fun item ->
            match item with
            | PremEq { lhs; rhs; _ } ->
                let pick side =
                  List.filter (fun v ->
                    SSet.mem v vm_var_set && not (SSet.mem v lhs_t_var_set))
                    (uniq_vars (vars_of_texpr side @ extract_vars_from_maude side.text))
                in
                pick lhs @ pick rhs
            | PremRel { args; _ } ->
                args
                |> List.concat_map (fun a ->
                    uniq_vars (vars_of_texpr a @ extract_vars_from_maude a.text))
                |> List.filter (fun v ->
                    SSet.mem v vm_var_set && not (SSet.mem v lhs_t_var_set))
            | _ -> []) prem_items
          |> List.sort_uniq String.compare
        in
        let prem_binding_set = SSet.of_list prem_binding_targets in
        let lhs_seed_set =
          SSet.union lhs_t_var_set
            (SSet.of_list (List.filter (fun v -> not (SSet.mem v prem_binding_set)) vm_vars))
        in
        let prem_scheduled = schedule_prems lhs_seed_set [] prem_items in
        let prem_strs = List.map (fun (p : prem_sched) -> p.text) prem_scheduled in
        let prem_vars = List.concat_map (fun (p : prem_sched) -> p.vars @ p.binds) prem_scheduled in
        let prem_binds = List.concat_map (fun (p : prem_sched) -> p.binds) prem_scheduled in
        let all_collected = lhs_vars @ prem_vars in
        let all_texts = [lhs_cfg; rhs_cfg] @ prem_strs in
        let lhs_bound_seed = List.sort_uniq String.compare (lhs_vars @ prem_binds) in
        let (bound, free, lhs_set) = partition_vars lhs_bound_seed all_texts all_collected in
        let is_state_guard cond =
          let s = String.trim cond in
          try ignore (Str.search_forward (Str.regexp ": State\\b") s 0); true
          with Not_found -> false
        in
        let filtered_bconds =
          bconds
          |> List.filter (fun (mv, _) -> List.mem mv lhs_set && not (List.mem mv prem_binds))
          |> List.map snd
          |> List.filter (fun cond -> not (is_state_guard cond))
          |> List.filter (fun cond -> not (redundant_binder_guard typed_vars cond))
        in
        all_bound := List.sort_uniq String.compare (!all_bound @ bound @ vm_vars);
        all_free := List.sort_uniq String.compare (!all_free @ free);
        let is_rewrite_cond text =
          try ignore (Str.search_forward (Str.regexp_string "=>") text 0); true
          with Not_found -> false
        in
        let prem_match_conds =
          prem_scheduled
          |> List.filter_map (fun (p : prem_sched) ->
              if p.binds = [] || is_rewrite_cond p.text then None else Some (prem_cond p.text))
        in
        let prem_rewrite_conds =
          prem_scheduled
          |> List.filter_map (fun (p : prem_sched) ->
              if is_rewrite_cond p.text then Some (prem_cond p.text) else None)
        in
        let prem_bool_conds =
          prem_scheduled
          |> List.filter_map (fun (p : prem_sched) ->
              if p.binds = [] && not (is_rewrite_cond p.text) then Some (prem_cond p.text) else None)
        in
        let all_conds = prem_match_conds @ prem_rewrite_conds @ prem_bool_conds @ filtered_bconds in
        let cond = cond_join all_conds in
        let emit_rule label lhs rhs local_cond =
          if local_cond = "" then
            Printf.sprintf "  rl [%s] :\n    steps ( %s )\n    =>\n    %s ."
              label lhs rhs
          else
            Printf.sprintf "  crl [%s] :\n    steps ( %s )\n    =>\n    %s\n      if %s ."
              label lhs rhs local_cond
        in
        let label = String.lowercase_ascii label_prefix in
        emit_rule label lhs_cfg rhs_cfg cond
  ) rules in
  let contains lit s =
    try ignore (Str.search_forward (Str.regexp_string lit) s 0); true
    with Not_found -> false
  in
  let rule_rank s =
    if contains "[steps-trans" s then 0
    else if contains "[steps-refl" s then 1
    else 2
  in
  let rule_lines =
    List.stable_sort (fun a b -> compare (rule_rank a) (rule_rank b)) rule_lines
  in
  let truly_free = List.filter (fun v -> not (List.mem v !all_bound)) !all_free in
  let seq_vars = List.sort_uniq String.compare !all_seq_vars_acc in
  let bound_vars =
    !all_bound
    |> List.filter (fun v -> not (List.mem v seq_vars))
    |> List.sort_uniq String.compare
  in
  let typed_vars = !all_typed_vars |> List.sort_uniq compare in
  let typed_names = List.map fst typed_vars |> List.sort_uniq String.compare in
  let bound_vars = List.filter (fun v -> not (List.mem v typed_names)) bound_vars in
  let typed_decl = declare_vars_by_sort typed_vars in
  let bound_decl = declare_vars_same_sort bound_vars "SpectecTerminal" in
  let seq_decl = declare_vars_same_sort seq_vars "SpectecTerminals" in
  let free_decl = declare_ops_const_list truly_free "SpectecTerminal" in
  typed_decl ^ bound_decl ^ seq_decl ^ free_decl ^ String.concat "\n" rule_lines ^ "\n"

let lower_all_reld_as_rewrite = true

let translate_reld _id rel_name rules =
  register_infer_rel_rules rel_name rules;
  let arity = match rules with
    | r :: _ -> (match r.it with RuleD (_, _, _, c, _) ->
        (match c.it with TupE el -> List.length el | _ -> 1))
    | [] -> 0 in
  let use_rewrite_judgement =
    (* C1 policy experiment:
       A SpecTec relation rule should be emitted as a Maude rl/crl,
       rather than as an equational validity test. *)
    lower_all_reld_as_rewrite
  in
  let op_decl = Printf.sprintf "\n  op %s : %s -> Judgement [ctor] .\n" rel_name
    (String.concat " " (List.init arity (fun _ -> "SpectecTerminals"))) in
  let rel_prefix = String.uppercase_ascii (sanitize rel_name) in

  let all_bound = ref [] and all_free = ref [] and all_typed_vars = ref [] in
  let rule_lines = List.mapi (fun rule_idx r -> match r.it with
    | RuleD (case_id, binders, _, conclusion, prem_list) ->
        let raw_prefix = String.uppercase_ascii (sanitize case_id.it) in
        let case_part = if raw_prefix = "" then Printf.sprintf "R%d" rule_idx else raw_prefix in
        let prefix = Printf.sprintf "%s-%s" rel_prefix case_part in
        let label_prefix = rule_label_prefix rel_name case_id.it rule_idx in

        let vm = binder_to_var_map prefix rule_idx binders in
        reset_listn_pairs ();
        record_listn_pairs_from_binders binders vm;
        let raw_typed_vars = binder_var_sorts binders vm in
        let bconds = binder_to_type_conds binders vm in

        let lhs_t = match conclusion.it with
          | TupE el -> tconcat " , " (List.map (fun x -> translate_exp TermCtx x vm) el)
          | _ -> translate_exp TermCtx conclusion vm in
        let lhs_t, lhs_projection_items =
          if use_rewrite_judgement then hoist_lhs_value_projections prefix lhs_t
          else (lhs_t, [])
        in

        let typed_vars, refined_pairs, refined_guards =
          if use_rewrite_judgement then
            widen_reld_lhs_typed_vars raw_typed_vars lhs_t.vars
          else
            (raw_typed_vars, [], [])
        in
        all_typed_vars := List.sort_uniq compare (!all_typed_vars @ typed_vars);

        (* Apply the same prem_binding_targets logic as translate_step_reld:
           only pre-mark vm_vars that are NOT binding targets of any PremEq as
           "already bound".  This allows existential variables (those that
           appear on the fresh side of an equality in a premise) to be bound
           via := rather than emitted as unbound free variables. *)
        let prem_items = lhs_projection_items @ List.concat_map (prem_items_of_prem vm) prem_list in
        let vm_vars = List.map snd vm in
        let vm_var_set = SSet.of_list vm_vars in
        let lhs_t_var_set = SSet.of_list lhs_t.vars in
        let prem_binding_targets =
          List.concat_map (fun item ->
            match item with
            | PremEq { lhs; rhs; _ } ->
                let pick side =
                  List.filter (fun v ->
                    SSet.mem v vm_var_set && not (SSet.mem v lhs_t_var_set))
                    (vars_of_texpr side) in
                pick lhs @ pick rhs
            | PremRel { args; _ } ->
                args
                |> List.concat_map vars_of_texpr
                |> List.filter (fun v ->
                    SSet.mem v vm_var_set && not (SSet.mem v lhs_t_var_set))
            | _ -> []) prem_items
          |> List.sort_uniq String.compare
        in
        let prem_binding_set = SSet.of_list prem_binding_targets in
        (* Seed: lhs conclusion vars + vm_vars that are NOT premise-binding targets *)
        let lhs_seed_set =
          SSet.union lhs_t_var_set
            (SSet.of_list (List.filter (fun v -> not (SSet.mem v prem_binding_set)) vm_vars))
        in
        let prem_scheduled = schedule_prems lhs_seed_set [] prem_items in
        let prem_strs = List.map (fun (p : prem_sched) -> p.text) prem_scheduled in
        let prem_vars = List.concat_map (fun (p : prem_sched) -> p.vars @ p.binds) prem_scheduled in
        let prem_binds = List.concat_map (fun (p : prem_sched) -> p.binds) prem_scheduled in

        let all_collected = lhs_t.vars @ prem_vars in
        let all_texts = [lhs_t.text] @ prem_strs in
        let lhs_bound_seed = List.sort_uniq String.compare (lhs_t.vars @ prem_binds) in
        let (bound, free, lhs_set) = partition_vars lhs_bound_seed all_texts all_collected in

        let replaced_source_category_guard cond =
          let cond = String.trim cond in
          raw_typed_vars
          |> List.exists (fun (mv, sort) ->
              not (preserve_narrow_lhs_sort sort)
              && cond = Printf.sprintf "%s : %s" (String.trim mv) (String.trim sort))
        in
        let filtered_bconds =
          bconds
          |> List.filter (fun (mv, _) -> List.mem mv lhs_set)
          |> List.map snd
          |> List.filter (fun cond ->
              not (redundant_binder_guard typed_vars cond)
              && not (is_refined_exec_original_guard refined_pairs cond)
              && not (replaced_source_category_guard cond))
        in
        let lhs_var_set = SSet.of_list lhs_t.vars in
        let bound_var_set = SSet.of_list bound in
        let premise_bound_refined_guards =
          raw_typed_vars
          |> List.filter (fun (v, sort) ->
              SSet.mem v bound_var_set
              && not (SSet.mem v lhs_var_set)
              && not (preserve_narrow_lhs_sort sort))
          |> List.map (fun (v, sort) ->
              if needs_source_category_predicate sort then
                reld_type_pred_sorts := SSet.add sort !reld_type_pred_sorts;
              refined_exec_guard v sort)
          |> List.sort_uniq String.compare
        in
        all_bound := List.sort_uniq String.compare (!all_bound @ bound);
        all_free := List.sort_uniq String.compare (!all_free @ free);

        let prem_match_conds =
          prem_scheduled
          |> List.filter_map (fun (p : prem_sched) ->
              if p.binds = [] then None else Some (prem_cond p.text))
        in
        let prem_bool_conds =
          prem_scheduled
          |> List.filter_map (fun (p : prem_sched) ->
              if p.binds = [] then Some (prem_cond p.text) else None)
          |> List.filter (fun cond -> not (replaced_source_category_guard cond))
        in
        let listn_len_conds = listn_len_conditions lhs_set in
        let all_conds =
          prem_match_conds @ listn_len_conds @ prem_bool_conds @ filtered_bconds
          @ refined_guards @ premise_bound_refined_guards
        in
        let cond = cond_join all_conds in
        let emit_rule ?(suffix="") lhs_text cond_text =
          if use_rewrite_judgement then
            let label = (String.lowercase_ascii label_prefix) ^ suffix in
            if cond_text = "" then
              Printf.sprintf "  rl [%s] :\n    %s ( %s )\n    =>\n    valid ."
                label rel_name lhs_text
            else
              Printf.sprintf "  crl [%s] :\n    %s ( %s )\n    =>\n    valid\n      if %s ."
                label rel_name lhs_text cond_text
          else if cond_text = "" then
            Printf.sprintf "  eq %s ( %s ) = valid ."
              rel_name lhs_text
          else
            Printf.sprintf "  ceq %s ( %s ) = valid\n      if %s ."
              rel_name lhs_text cond_text
        in
        let base_rule = emit_rule lhs_t.text cond in
        let is_tail_seq_var v =
          try
            ignore (Str.search_forward
              (Str.regexp ("[A-Z][A-Z0-9-_]*[ \t\n\r]+" ^ Str.quote v))
              lhs_t.text 0);
            true
          with Not_found -> false
        in
        let tail_seq_vars =
          typed_vars
          |> List.filter_map (fun (v, sort) ->
              if sort = "SpectecTerminals" && List.mem v lhs_t.vars && is_tail_seq_var v
              then Some v else None)
          |> List.sort_uniq String.compare
        in
        let exec_tail_rules =
          nonempty_subsets tail_seq_vars
          |> List.sort (fun a b -> compare (List.length b) (List.length a))
          |> List.mapi (fun i vs ->
              let replace_all text =
                List.fold_left (fun acc v -> replace_maude_var_token v "eps" acc)
                  text vs
              in
              let lhs_text = replace_all lhs_t.text in
              let cond_text = replace_all cond in
              emit_rule
                ~suffix:(Printf.sprintf "-exec-tail-empty%d" i)
                lhs_text cond_text)
        in
        String.concat "\n" (exec_tail_rules @ [base_rule])
  ) rules in

  let truly_free = List.filter (fun v -> not (List.mem v !all_bound)) !all_free in
  let typed_vars = !all_typed_vars |> List.sort_uniq compare in
  let typed_names = List.map fst typed_vars |> List.sort_uniq String.compare in
  let bound_vars =
    !all_bound
    |> List.filter (fun v -> not (List.mem v typed_names))
    |> List.sort_uniq String.compare
  in
  let typed_decl = declare_vars_by_sort typed_vars in
  let bound_decl = declare_vars_same_sort bound_vars "SpectecTerminal" in
  let free_decl = declare_ops_const_list truly_free "SpectecTerminal" in
  op_decl ^ typed_decl ^ bound_decl ^ free_decl ^ String.concat "\n" rule_lines ^ "\n"

(* --- Top-level definition dispatch --------------------------------------- *)

let rec translate_definition ss (d : def) = match d.it with
  | RecD defs -> String.concat "\n" (List.map (translate_definition ss) defs)
  | TypD (id, params, insts) -> translate_typd id params insts
  | DecD (id, params, result_typ, insts) -> translate_decd ss id params result_typ insts
  | RelD (id, _, _, rules) ->
      let name = sanitize id.it in
      if is_step_exec_rel name then translate_step_reld name rules
      else if is_steps_rel name then translate_steps_reld name rules
      else translate_reld id name rules
  | GramD _ | HintD _ -> ""

(* ========================================================================= *)
(* 9. Top-level: prescan → header → translate → reorder → emit              *)
(* ========================================================================= *)

let nat_subsort_decls () =
  let sorts = SSet.elements !nat_subsort_sorts in
  if sorts = [] then ""
  else
    "  --- Source-derived Nat subsorts from SpecTec alias declarations.\n"
    ^ (sorts
       |> List.map (fun sort -> Printf.sprintf "  subsort Nat < %s .\n" sort)
       |> String.concat "")
    ^ "\n"

type prelude_features = {
  uses_sequences : bool;
  uses_records : bool;
  uses_record_literal : bool;
  uses_record_projection : bool;
  uses_record_update : bool;
  uses_record_extend : bool;
  uses_sequence_update : bool;
  uses_step_relations : bool;
  exec_wrappers : exec_wrapper list;
  uses_bool_wrapper : bool;
  uses_has_type : bool;
  uses_sequence_index : bool;
  uses_typed_index : bool;
  uses_repeat : bool;
  uses_slice : bool;
  uses_star_prefix : bool;
  uses_set_membership : bool;
  uses_merge : bool;
  uses_any : bool;
  uses_exp_const : bool;
  seq_pred_sorts : string list;
}

and exec_wrapper = {
  exec_rel_name : string;
  exec_op_name : string;
  exec_wrapper_sort : string;
  exec_input_sort : string;
  exec_output_carrier : string;
  exec_frozen : bool;
}

let pascal_of_maude_name name =
  name
  |> String.split_on_char '-'
  |> List.filter (fun s -> s <> "")
  |> List.map String.capitalize_ascii
  |> String.concat ""

let exec_wrapper_of_relation_name name =
  if is_step_exec_rel name || is_steps_rel name then
    let exec_input_sort, exec_output_carrier =
      match name with
      | "Step-pure" -> ("SpectecTerminals", "SpectecTerminals")
      | "Step-read" -> ("Config", "SpectecTerminals")
      | "Step" | "Steps" -> ("Config", "Config")
      | _ -> ("SpectecTerminals", "SpectecTerminals")
    in
    Some {
      exec_rel_name = name;
      exec_op_name = String.lowercase_ascii name;
      exec_wrapper_sort = pascal_of_maude_name name ^ "Conf";
      exec_input_sort;
      exec_output_carrier;
      exec_frozen = not (is_steps_rel name);
    }
  else None

let source_execution_wrappers defs =
  let rec scan d =
    match d.it with
    | RecD ds -> List.concat_map scan ds
    | RelD (id, _, _, _) ->
        let name = sanitize id.it in
        (match exec_wrapper_of_relation_name name with
         | Some w -> [w]
         | None -> [])
    | _ -> []
  in
  defs
  |> List.concat_map scan
  |> List.sort_uniq (fun a b -> compare a.exec_rel_name b.exec_rel_name)

let prelude_features_of_source defs ss generated_text token_ops =
  let has lit =
    contains_substring generated_text lit || contains_substring token_ops lit
  in
  let has_source_records = !source_record_infos <> [] in
  let uses_record_projection =
    has_source_records || ss.scan_uses_record_projection || has "value("
    || has "value ("
  in
  let uses_record_update =
    has_source_records || ss.scan_uses_record_update || has " [. "
  in
  let uses_record_extend = ss.scan_uses_record_extend || has " =++ " in
  let uses_sequence_update = ss.scan_uses_sequence_update in
  let uses_record_literal =
    has_source_records || ss.scan_uses_record_literal || has "item("
    || has "item ("
  in
  let uses_records =
    uses_record_literal || uses_record_projection || uses_record_update
    || uses_record_extend || uses_sequence_update
  in
  let exec_wrappers = source_execution_wrappers defs in
  {
    uses_sequences =
      Hashtbl.length plural_types > 0
      || not (SSet.is_empty !sequence_alias_sorts);
    uses_records;
    uses_record_literal;
    uses_record_projection;
    uses_record_update;
    uses_record_extend;
    uses_sequence_update;
    uses_step_relations = exec_wrappers <> [];
    exec_wrappers;
    uses_bool_wrapper = !feature_uses_bool_wrapper;
    uses_has_type = !feature_uses_has_type;
    uses_sequence_index = ss.scan_uses_sequence_index || has "index (" || has "index(";
    uses_typed_index = has "$typed-index";
    uses_repeat = ss.scan_uses_repeat || has "$repeat";
    uses_slice = ss.scan_uses_slice || has "slice (" || has "slice(";
    uses_star_prefix = !feature_uses_star_prefix;
    uses_set_membership = ss.scan_uses_set_membership || has " <- ";
    uses_merge = ss.scan_uses_merge || has "merge (" || has "merge(";
    uses_any = ss.scan_uses_any || contains_substring token_ops "op any :";
    uses_exp_const = has "EXP";
    seq_pred_sorts = SSet.elements !source_seq_pred_sorts;
  }

let generated_term_prelude_module () =
  "mod DSL-TERM is \n" ^
  "  sort SpectecTerminal .\n" ^
  "  sort SpectecType .\n" ^
  "endm\n\n"

let generated_sequence_prelude_module (_features : prelude_features) =
  (* SpectecTerminals is currently the generic carrier for both singleton and
     iterated SpecTec terms.  We keep this module even for sequence-light specs,
     but it is emitted by the translator rather than loaded from a Wasm-specific
     hand-written file. *)
  "mod DSL-PRETYPE is\n" ^
  "  inc DSL-TERM .\n" ^
  "  inc NAT .\n" ^
  "  inc INT .\n" ^
  "  inc BOOL .\n" ^
  "  sort SpectecTerminals .\n" ^
  "  sort SpectecTypes .\n\n" ^
  "  subsort Nat < SpectecTerminal .\n" ^
  "  subsort SpectecTerminal < SpectecTerminals .\n" ^
  "  subsort SpectecType < SpectecTypes . \n" ^
  "  op eps : -> SpectecTerminals .\n" ^
  "  op _ _ : SpectecTerminals SpectecTerminals -> SpectecTerminals [ctor assoc id: eps] .\n\n" ^
  "  op len : SpectecTerminals -> Nat .\n" ^
  "  var W : SpectecTerminal .\n" ^
  "  var WTS : SpectecTerminals .\n\n" ^
  "  eq len(eps) = 0 .\n" ^
  "  eq len(W WTS) = 1 + len(WTS) .\n\n" ^
  "  var T : SpectecTerminal .\n" ^
  "  var TS : SpectecTerminals .\n\n" ^
  "  var N' : Nat .\n" ^
  "  op index : SpectecTerminals Nat -> SpectecTerminals .\n" ^
  "  eq index(eps, N') = eps .\n" ^
  "  eq index(T TS, 0) = T .\n" ^
  "  eq index(T TS, s(N')) = index(TS, N') .\n" ^
  "endm\n\n"

let generated_record_prelude_module features =
  let needs_record_items =
    features.uses_record_literal || features.uses_record_projection
    || features.uses_record_update || features.uses_record_extend
  in
  "mod DSL-RECORD is \n" ^
  "  inc DSL-PRETYPE .\n" ^
  "  inc QID .\n" ^
  "  sort RecordItem .\n" ^
  "  sort RecordItems .\n" ^
  "  subsort RecordItem < RecordItems . \n\n" ^
  "  op EMPTY : -> RecordItem .\n" ^
  "  op _;_ : RecordItems RecordItems -> RecordItems [ctor assoc id: EMPTY].\n" ^
  (if needs_record_items then
     "  op {_} : RecordItems -> SpectecTerminal .\n\n" ^
     "  op item : Qid SpectecTerminals -> RecordItem .\n\n"
   else "\n") ^
  "  vars RI RI' : RecordItems . var R : RecordItem .\n" ^
  "  vars F F' : Qid .\n" ^
  "  var REC : SpectecTerminal .\n" ^
  "  vars V V' : SpectecTerminals . \n\n" ^
  (if features.uses_record_projection || features.uses_record_extend then
     "  op value : Qid SpectecTerminal -> SpectecTerminal .\n" ^
     "  op value : Qid RecordItems -> SpectecTerminals .\n" ^
     "  eq value(F,{RI}) = value(F, RI) .\n" ^
     "  eq value(F, EMPTY) = eps . \n" ^
     "  eq value(F, item(F, V) ; RI) = V .\n" ^
     "  ceq value(F, R ; RI) = value(F, RI) if R =/= EMPTY .\n\n"
   else "") ^
  (if features.uses_record_update || features.uses_record_extend then
     "  op _++_ : RecordItems RecordItems -> SpectecTerminal .\n" ^
     "  eq RI ++ RI' = {RI ; RI'} .\n\n" ^
     "  op _[._<-_] : SpectecTerminal Qid SpectecTerminals -> SpectecTerminal . \n" ^
     "  op _[._<-_] : RecordItems Qid SpectecTerminals -> SpectecTerminal .\n" ^
     "  eq {item(F, V) ; RI} [. F <- V'] = {item(F, V') ; RI} .\n" ^
     "  ceq {item(F, V) ; RI} [. F' <- V'] = item(F, V) ++ RI[. F' <- V'] if F =/= F' .\n\n"
   else "") ^
  (if features.uses_record_extend then
     "  op _[._=++_] : SpectecTerminal Qid SpectecTerminals -> SpectecTerminal .\n" ^
     "  eq REC [. F =++ V'] = REC [. F <- (value(F, REC) V') ] .\n\n"
   else "") ^
  (if features.uses_sequence_update then
     "  op _[_<-_] : SpectecTerminals SpectecTerminal SpectecTerminal -> SpectecTerminals [prec 50] .\n\n" ^
     "  var H : SpectecTerminal .\n" ^
     "  vars L : SpectecTerminals .\n" ^
     "  vars IDX : Nat .\n" ^
     "  vars VALUE NEWVALUE : SpectecTerminal .\n\n" ^
     "  eq eps [ IDX <- NEWVALUE ] = eps .\n" ^
     "  eq (H L) [ 0 <- NEWVALUE ] = NEWVALUE L .\n" ^
     "  eq (H L) [ s(IDX) <- NEWVALUE ] = H (L [ IDX <- NEWVALUE ]) .\n"
   else "") ^
  "endm\n\n"

let generated_prelude_modules features =
  generated_term_prelude_module ()
  ^ generated_sequence_prelude_module features
  ^ (if features.uses_records then generated_record_prelude_module features else "")

let core_prelude_include features =
  if features.uses_records then "  inc DSL-RECORD .\n"
  else "  inc DSL-PRETYPE .\n"

let execution_wrapper_block wrappers =
  match wrappers with
  | [] -> ""
  | _ ->
      let wrapper_sorts =
        wrappers
        |> List.map (fun w -> w.exec_wrapper_sort)
        |> String.concat " "
      in
      let subsorts =
        wrappers
        |> List.map (fun w ->
            Printf.sprintf "  subsort %s < %s .\n"
              w.exec_output_carrier w.exec_wrapper_sort)
        |> String.concat ""
      in
      let op_decls =
        wrappers
        |> List.map (fun w ->
            Printf.sprintf "  op %s : %s -> %s%s .\n"
              w.exec_op_name w.exec_input_sort w.exec_wrapper_sort
              (if w.exec_frozen then " [frozen (1)]" else ""))
        |> String.concat ""
      in
      "  --- Execution wrappers generated from source Step relation declarations.\n" ^
      "  --- The wrapper result sorts prevent rewrite conditions from being\n" ^
      "  --- satisfied by zero-step matching an unreduced relation call.\n" ^
      Printf.sprintf "  sorts %s .\n" wrapper_sorts ^
      subsorts ^
      "  op _;_ : Store Frame -> State [ctor prec 55] .\n" ^
      "  op _;_ : State SpectecTerminals -> Config [ctor prec 60] .\n" ^
      op_decls ^
      "\n"

let header_prefix features =
  generated_prelude_modules features ^
  "mod SPECTEC-CORE is\n" ^
  core_prelude_include features ^
  "  inc BOOL .\n" ^
  "  inc INT .\n\n" ^
  "  --- Base Sorts\n" ^
  "  subsort Int < SpectecTerminal .\n" ^
  "  --- Nat < SpectecTerminal is provided by DSL-PRETYPE.\n\n" ^
  "  --- Allow type atoms to appear as terminals (for mixed AST encodings)\n" ^
  "  subsort SpectecType < SpectecTerminal .\n" ^
  "  subsort SpectecTypes < SpectecTerminals .\n\n" ^
  "  --- SpecTec terminal sequences use the single SpectecTerminals sequence sort.\n\n" ^
  (nat_subsort_decls ()) ^
  "  --- Syntax-category membership is represented by mb/cmb axioms, not by terminal subsorts.\n\n" ^
  (if features.uses_bool_wrapper then
     "  --- Bool wrapper emitted because source defs return Bool as a terminal.\n" ^
     "  op w-bool : Bool -> SpectecTerminal [ctor] .\n\n"
   else "") ^
  "  --- Source type constructors are generated from SpecTec declarations.\n\n" ^
  (if features.uses_has_type then
     "  --- Pair sort + well-typed witness for parametric type judgements.\n" ^
     "  --- Non-parametric types use direct `mb T : S .` memberships.\n" ^
     "  --- Parametric types emit `(mb|cmb) ( T hasType S ) : WellTyped [if ...] .`\n" ^
     "  sort TypedTerm .\n" ^
     "  sort WellTyped .\n" ^
     "  subsort WellTyped < TypedTerm .\n" ^
     "  op _hasType_ : SpectecTerminal SpectecType -> TypedTerm [ctor prec 95 gather (e e)] .\n"
   else "") ^
  "  --- Judgement sort for RelD relations.\n" ^
  "  --- Strict C1: source relation rules lower to primary `rl/crl => valid`.\n" ^
  "  --- Definitional equations remain `eq/ceq` when they translate source defs.\n" ^
  "  sort Judgement .\n" ^
  "  sort ValidJudgement .\n" ^
  "  subsort ValidJudgement < Judgement .\n" ^
  "  op valid : -> ValidJudgement [ctor] .\n" ^
  (if features.uses_sequence_index then
     "  op index : SpectecTerminals SpectecTerminals -> SpectecTerminals .\n"
   else "") ^
  (if features.uses_typed_index then
     "  op $typed-index : SpectecType SpectecTerminals Nat -> SpectecTerminals .\n" ^
     "  op $typed-index : SpectecType SpectecTerminals SpectecTerminals -> SpectecTerminals .\n"
   else "") ^
  (if features.uses_repeat then
     "  op $repeat : SpectecTerminal Int -> SpectecTerminals .\n"
   else "") ^
  (if features.uses_star_prefix then
     "  op $star-prefix : SpectecTerminal SpectecTerminals -> SpectecTerminals .\n" ^
     "  op $star-unprefix : SpectecTerminal SpectecTerminals -> SpectecTerminals .\n"
   else "") ^
  (if features.uses_slice then
     "  op slice : SpectecTerminals SpectecTerminal SpectecTerminal -> SpectecTerminals .\n"
   else "") ^
  (if features.uses_set_membership then
     "  op _<-_ : SpectecTerminal SpectecTerminals -> Bool .\n"
   else "") ^
  (if features.uses_merge || features.uses_any then "\n" else "") ^
  (if features.uses_merge then
     "  --- Generic record merge combinator emitted because source record composition uses it.\n" ^
     "  op merge : SpectecTerminal SpectecTerminal -> SpectecTerminal [ctor] .\n"
   else "") ^
  (if features.uses_any then
     "  --- Wildcard token emitted because the source uses `_` holes.\n" ^
     "  op any : -> SpectecTerminal [ctor] .\n"
   else "") ^
  (if features.uses_records then
     "\n  --- Record literals/updates come from DSL-RECORD and have sort SpectecTerminal.\n" ^
     "  --- This keeps the baseline surface aligned with the SpecTec terminal model.\n\n"
   else "\n") ^
  execution_wrapper_block features.exec_wrappers ^
  "  --- Common variables (declared once)\n" ^
  (if features.uses_step_relations then "  var EC : Config .\n" else "") ^
  (if features.uses_exp_const then "  op EXP : -> Int .\n" else "") ^
  (if features.uses_step_relations then "  var ZS : State .\n" else "") ^
  "  var T : SpectecTerminal .\n\n" ^
  (if features.uses_sequence_index then
     "  --- Generic SpecTec sequence indexing: xs[i*] maps scalar index over i*.\n" ^
     "  --- This is representation substrate for source meta-expressions, not a\n" ^
     "  --- judgement-specific executable shortcut.\n" ^
     "  var INDEX-I : Nat .\n" ^
     "  vars INDEX-TS INDEX-IS : SpectecTerminals .\n" ^
     "  eq index(INDEX-TS, eps) = eps .\n" ^
     "  eq index(INDEX-TS, INDEX-I INDEX-IS) = index(INDEX-TS, INDEX-I) index(INDEX-TS, INDEX-IS) .\n\n"
   else "") ^
  (if features.uses_typed_index then
     "  --- Type-aware SpecTec indexing for flat composite sequence elements.\n" ^
     "  --- Source fields like localtype* contain source elements such as SET i32,\n" ^
     "  --- which occupy multiple terminal tokens in the broad sequence carrier.\n" ^
     "  var TYPED-INDEX-TY : SpectecType .\n" ^
     "  var TYPED-INDEX-I : Nat .\n" ^
     "  vars TYPED-INDEX-TS TYPED-INDEX-IS : SpectecTerminals .\n" ^
     "  eq $typed-index(TYPED-INDEX-TY, TYPED-INDEX-TS, eps) = eps .\n" ^
     "  ceq $typed-index(TYPED-INDEX-TY, TYPED-INDEX-TS, TYPED-INDEX-I TYPED-INDEX-IS) =\n" ^
     "     $typed-index(TYPED-INDEX-TY, TYPED-INDEX-TS, TYPED-INDEX-I) $typed-index(TYPED-INDEX-TY, TYPED-INDEX-TS, TYPED-INDEX-IS)\n" ^
     "   if TYPED-INDEX-IS =/= eps .\n\n"
   else "") ^
  (if features.uses_set_membership then
     "  --- Generic SpecTec membership test: x <- xs.\n" ^
     "  vars MEMBER-X MEMBER-Y : SpectecTerminal .\n" ^
     "  var MEMBER-YS : SpectecTerminals .\n" ^
     "  eq MEMBER-X <- eps = false .\n" ^
     "  eq MEMBER-X <- MEMBER-X MEMBER-YS = true .\n" ^
     "  ceq MEMBER-X <- MEMBER-Y MEMBER-YS = MEMBER-X <- MEMBER-YS\n" ^
     "   if MEMBER-X =/= MEMBER-Y .\n\n"
   else "") ^
  (if features.uses_repeat then
     "  --- Generic SpecTec fixed repetition: e^n becomes $repeat(e,n).\n" ^
     "  var REPEAT_N : Int .\n" ^
     "  var REPEAT_ELEM : SpectecTerminal .\n" ^
     "  eq $repeat(REPEAT_ELEM, 0) = eps .\n" ^
     "  ceq $repeat(REPEAT_ELEM, REPEAT_N) = ( REPEAT_ELEM $repeat(REPEAT_ELEM, _-_ ( REPEAT_N, 1 )) )\n" ^
     "   if _>_ ( REPEAT_N, 0 ) .\n\n"
   else "") ^
  (if features.uses_slice then
     "  --- Generic SpecTec sequence slicing: xs[i : n].\n" ^
     "  vars SLICE_I SLICE_N : Int .\n" ^
     "  var SLICE_ELEM : SpectecTerminal .\n" ^
     "  var SLICE_REST : SpectecTerminals .\n" ^
     "  eq slice(SLICE_REST, SLICE_I, 0) = eps .\n" ^
     "  ceq slice(( SLICE_ELEM SLICE_REST ), 0, SLICE_N) = ( SLICE_ELEM slice(SLICE_REST, 0, _-_ ( SLICE_N, 1 )) )\n" ^
     "   if _>_ ( SLICE_N, 0 ) .\n" ^
     "  ceq slice(( SLICE_ELEM SLICE_REST ), SLICE_I, SLICE_N) = slice(SLICE_REST, _-_ ( SLICE_I, 1 ), SLICE_N)\n" ^
     "   if _>_ ( SLICE_I, 0 ) .\n\n"
   else "") ^
  (if features.uses_star_prefix then
     "  --- Generic SpecTec star-map lowering for flat prefix constructors.\n" ^
     "  --- Source shapes such as (SET t)* become $star-prefix(SET, t*), and\n" ^
     "  --- $star-unprefix recovers t* from a matching flat encoded sequence.\n" ^
     "  vars STAR-PREFIX STAR-ELEM : SpectecTerminal .\n" ^
     "  var STAR-REST : SpectecTerminals .\n" ^
     "  eq $star-prefix(STAR-PREFIX, eps) = eps .\n" ^
     "  eq $star-prefix(STAR-PREFIX, STAR-ELEM STAR-REST) = STAR-PREFIX STAR-ELEM $star-prefix(STAR-PREFIX, STAR-REST) .\n" ^
     "  eq $star-unprefix(STAR-PREFIX, eps) = eps .\n" ^
     "  eq $star-unprefix(STAR-PREFIX, STAR-PREFIX STAR-ELEM STAR-REST) = STAR-ELEM $star-unprefix(STAR-PREFIX, STAR-REST) .\n\n"
   else "")

let footer features =
  let seq_pred_blocks =
    features.seq_pred_sorts
    |> List.map (fun sort ->
        let pred = source_category_seq_pred sort in
        let lower = String.lowercase_ascii sort in
        Printf.sprintf
          "  --- Source-derived sequence-category predicate for SpecTec %s* premises.\n\
           \  eq  %s(eps) = true .\n\
           \  ceq %s(W TS) = %s(TS)\n\
           \   if W : %s .\n\
           \  eq  %s(TS) = false [owise] .\n"
          lower pred pred pred sort pred)
    |> String.concat "\n"
  in
  "\n" ^
  (if seq_pred_blocks = "" then "" else
     "  var W : SpectecTerminal .\n" ^
     "  var TS : SpectecTerminals .\n" ^
     seq_pred_blocks ^ "\n") ^
  (if features.uses_has_type then
     "  --- Generic SpecTec list type witness.\n" ^
     "  --- The source rule is polymorphic in the element type; this executable\n" ^
     "  --- variable form makes `eps hasType list(val)` and similar instances work.\n" ^
     "  var LIST-TY : SpectecTerminal .\n" ^
     "  var LIST-TS : SpectecTerminals .\n" ^
     "  cmb (LIST-TS hasType (list(LIST-TY))) : WellTyped\n" ^
     "   if (len(LIST-TS) < (2 ^ 32)) .\n\n"
   else "") ^
  "\nendm\n"

let prelude_helper_decls features =
  (features.seq_pred_sorts
   |> List.map (fun sort ->
       Printf.sprintf "  op %s : SpectecTerminals -> Bool .\n"
         (source_category_seq_pred sort))
   |> String.concat "")

let infer_rel_helper_block () =
  let current_helpers () =
    !infer_rel_helpers
    |> List.sort_uniq (fun a b ->
        compare
          (a.infer_rel_name, a.infer_arity, a.infer_arg_index)
          (b.infer_rel_name, b.infer_arity, b.infer_arg_index))
  in
  let helpers = current_helpers () in
  if helpers = [] then ""
  else
    let relation_args vm conclusion =
      match conclusion.it with
      | TupE el -> List.map (fun x -> translate_exp TermCtx x vm) el
      | _ -> [translate_exp TermCtx conclusion vm]
    in
    let except_nth xs i =
      xs
      |> List.mapi (fun j x -> if i = j then None else Some x)
      |> List.filter_map (fun x -> x)
    in
    let singleton_seq_input inputs =
      inputs
      |> List.mapi (fun i (t : texpr) ->
          let core = strip_wrapping_parens t.text |> String.trim in
          match Str.split (Str.regexp "[ \t\n\r]+") core with
          | [head; rest] when is_plain_var_like head && is_plain_var_like rest ->
              Some (i, head, rest)
          | _ -> None)
      |> List.find_map (fun x -> x)
    in
    let infer_lhs helper_name (inputs : texpr list) =
      let lhs_args = String.concat " , " (List.map (fun (t : texpr) -> t.text) inputs) in
      if lhs_args = "" then helper_name
      else Printf.sprintf "%s ( %s )" helper_name lhs_args
    in
    let compact_ws s =
      let b = Buffer.create (String.length s) in
      String.iter
        (function
          | ' ' | '\t' | '\n' | '\r' -> ()
          | c -> Buffer.add_char b c)
        s;
      Buffer.contents b
    in
    let starts_with s prefix =
      let n = String.length prefix in
      String.length s >= n && String.sub s 0 n = prefix
    in
    let has_immediate_self_infer helper_name inputs prem_scheduled =
      let lhs_prefix = compact_ws (infer_lhs helper_name inputs) ^ "=>" in
      prem_scheduled
      |> List.exists (fun (p : prem_sched) ->
          starts_with (compact_ws p.text) lhs_prefix)
    in
    let emit_infer_eq rule_label helper_name (inputs : texpr list) (target : texpr) cond =
      let lhs = infer_lhs helper_name inputs in
      let cond_has_rewrite_premise =
        try ignore (Str.search_forward (Str.regexp "=>") cond 0); true
        with Not_found -> false
      in
      if cond_has_rewrite_premise then
        if cond = "" then
          Printf.sprintf "  rl [%s] :\n    %s\n    =>\n    %s .\n"
            rule_label lhs target.text
        else
          Printf.sprintf "  crl [%s] :\n    %s\n    =>\n    %s\n      if %s .\n"
            rule_label lhs target.text cond
      else if cond = "" then
        Printf.sprintf "  eq %s = %s .\n" lhs target.text
      else
        Printf.sprintf "  ceq %s = %s\n      if %s .\n" lhs target.text cond
    in
    let op_decl_for h =
      let helper_name = infer_rel_helper_name h.infer_rel_name h.infer_arg_index in
      let op_args =
        if h.infer_arity <= 1 then ""
        else String.concat " "
          (List.init (h.infer_arity - 1) (fun _ -> "SpectecTerminals"))
      in
      if op_args = "" then
        Printf.sprintf "  op %s : -> SpectecTerminal .\n" helper_name
      else
        Printf.sprintf "  op %s : %s -> SpectecTerminal .\n"
          helper_name op_args
    in
    let emit_helper h =
      match List.assoc_opt h.infer_rel_name !infer_rel_rules with
      | None -> ""
      | Some rules ->
          let rel_prefix = String.uppercase_ascii (sanitize h.infer_rel_name) in
          let helper_name =
            infer_rel_helper_name h.infer_rel_name h.infer_arg_index
          in
          let eqs =
            rules
            |> List.mapi (fun rule_idx r ->
                match r.it with
                | RuleD (case_id, binders, _, conclusion, prem_list) ->
                    let raw_prefix = String.uppercase_ascii (sanitize case_id.it) in
                    let case_part =
                      if raw_prefix = "" then Printf.sprintf "R%d" rule_idx else raw_prefix
                    in
                    let prefix = Printf.sprintf "%s-%s" rel_prefix case_part in
                    let vm = binder_to_var_map prefix rule_idx binders in
                    let arg_ts = relation_args vm conclusion in
                    if List.length arg_ts <> h.infer_arity
                       || h.infer_arg_index < 0
                       || h.infer_arg_index >= List.length arg_ts
                    then ""
                    else
                      let target = List.nth arg_ts h.infer_arg_index in
                      let inputs = except_nth arg_ts h.infer_arg_index in
                      let input_vars =
                        inputs
                        |> List.concat_map vars_of_texpr
                        |> List.sort_uniq String.compare
                      in
                      let input_seed = SSet.of_list input_vars in
                      let prem_items = List.concat_map (prem_items_of_prem vm) prem_list in
                      let prem_scheduled = schedule_prems input_seed [] prem_items in
                      let prem_binds =
                        prem_scheduled
                        |> List.concat_map (fun (p : prem_sched) -> p.binds)
                        |> List.sort_uniq String.compare
                      in
                      let bound_after =
                        SSet.union input_seed (SSet.of_list prem_binds)
                      in
                        let target_vars = vars_of_texpr target in
                      if not (subset_bound bound_after target_vars) then ""
                      else if has_immediate_self_infer helper_name inputs prem_scheduled then ""
                      else
                        let prem_match_conds =
                          prem_scheduled
                          |> List.filter_map (fun (p : prem_sched) ->
                              if p.binds = [] then None else Some (prem_cond p.text))
                        in
                        let prem_bool_conds =
                          prem_scheduled
                          |> List.filter_map (fun (p : prem_sched) ->
                              if p.binds = [] then Some (prem_cond p.text) else None)
                        in
                        let guard_conds =
                          binder_var_sorts binders vm
                          |> List.filter (fun (v, _) -> SSet.mem v bound_after)
                          |> List.map (fun (v, sort) ->
                              if preserve_narrow_lhs_sort sort then
                                Printf.sprintf "%s : %s" v sort
                              else (
                                if needs_source_category_predicate sort then
                                  reld_type_pred_sorts := SSet.add sort !reld_type_pred_sorts;
                                refined_exec_guard v sort))
                        in
                        let cond =
                          cond_join (prem_match_conds @ prem_bool_conds @ guard_conds)
                        in
                        let rule_label =
                          Printf.sprintf "%s-r%d"
                            (String.sub helper_name 1 (String.length helper_name - 1))
                            rule_idx
                          |> String.lowercase_ascii
                        in
                        let base_eq = emit_infer_eq rule_label helper_name inputs target cond in
                        let singleton_eq =
                          match singleton_seq_input inputs with
                          | None -> ""
                          | Some (input_idx, head, rest) ->
                              let inputs' =
                                inputs
                                |> List.mapi (fun i (t : texpr) ->
                                    if i <> input_idx then t
                                    else { text = head; vars = [head] })
                              in
                              let target' =
                                { text = replace_maude_var_token rest "eps" target.text;
                                  vars = List.filter ((<>) rest) target.vars }
                              in
                              let cond' = replace_maude_var_token rest "eps" cond in
                              emit_infer_eq (rule_label ^ "-singleton") helper_name inputs' target' cond'
                          in
                          base_eq ^ singleton_eq)
            |> String.concat ""
          in
          eqs
    in
    let key h = (h.infer_rel_name, h.infer_arity, h.infer_arg_index) in
    let keys hs = List.map key hs in
    let rec discover_closure () =
      let before = current_helpers () in
      ignore (List.map emit_helper before);
      let after = current_helpers () in
      if keys before <> keys after then discover_closure ()
    in
    discover_closure ();
    let helpers = current_helpers () in
    "\n  --- Non-C1-final execution support for source relation premises with\n" ^
    "  --- witness variables that Maude rewriting cannot synthesize directly.\n" ^
    "  --- Helpers are generated from source RelD rules; primary rl/crl rules\n" ^
    "  --- remain the authoritative strict C1 translation.\n" ^
    String.concat "" (List.map op_decl_for helpers) ^
    "\n" ^
    String.concat "\n" (List.map emit_helper helpers) ^ "\n"

let iter_rel_helper_block () =
  let helpers =
    !iter_rel_helpers
    |> List.sort_uniq (fun a b -> compare a.iter_helper_name b.iter_helper_name)
  in
  if helpers = [] then ""
  else
    let direct_unroll_limit = 8 in
    let emit h =
      let label_base = iter_rel_label_base h.iter_helper_name in
      let base =
        h.iter_helper_name
        |> String.map (function
             | '$' | '-' -> '_'
             | c -> Char.uppercase_ascii c)
      in
      let arg_names =
        List.init h.iter_arity (fun i -> Printf.sprintf "%s-A%d" base i)
      in
      let elem_names =
        List.init h.iter_arity (fun i -> Printf.sprintf "%s-E%d" base i)
      in
      let rest_names =
        List.init h.iter_arity (fun i -> Printf.sprintf "%s-R%d" base i)
      in
      let split_elem_names =
        elem_names
        |> List.mapi (fun i v -> if List.nth h.iter_split_positions i then Some v else None)
        |> List.filter_map (fun x -> x)
      in
      let split_rest_names =
        rest_names
        |> List.mapi (fun i v -> if List.nth h.iter_split_positions i then Some v else None)
        |> List.filter_map (fun x -> x)
      in
      let finite_elem_name i n =
        Printf.sprintf "%s-U%d_%d" base i n
      in
      let finite_elem_names =
        List.init h.iter_arity (fun i ->
            if List.nth h.iter_split_positions i then
              List.init direct_unroll_limit (fun n -> finite_elem_name i (n + 1))
            else [])
        |> List.flatten
      in
      let args sorts =
        String.concat " , "
          (List.mapi (fun i is_split ->
             let a = List.nth arg_names i in
             let e = List.nth elem_names i in
             let r = List.nth rest_names i in
             match sorts, is_split with
             | `Empty, true -> "eps"
             | `Empty, false -> a
             | `Cons, true -> Printf.sprintf "%s %s" e r
             | `Cons, false -> a
             | `Rel, true -> e
             | `Rel, false -> a
             | `Rec, true -> r
             | `Rec, false -> a)
             h.iter_split_positions)
      in
      let finite_args n =
        String.concat " , "
          (List.mapi (fun i is_split ->
             let a = List.nth arg_names i in
             if is_split then
               List.init n (fun j -> finite_elem_name i (j + 1))
               |> String.concat " "
             else a)
             h.iter_split_positions)
      in
      let finite_rel_args j =
        String.concat " , "
          (List.mapi (fun i is_split ->
             let a = List.nth arg_names i in
             if is_split then finite_elem_name i j else a)
             h.iter_split_positions)
      in
      let finite_rule n =
        let cond =
          List.init n (fun j ->
              Printf.sprintf "%s ( %s ) => valid"
                h.iter_rel_name (finite_rel_args (j + 1)))
          |> String.concat " /\\ "
        in
        Printf.sprintf
          "\n  crl [%s-%d] :\n    %s ( %s )\n    =>\n    valid\n      if %s .\n"
          label_base n h.iter_helper_name (finite_args n) cond
      in
      let op_args =
        String.concat " " (List.init h.iter_arity (fun _ -> "SpectecTerminals"))
      in
      let var_decl =
        "  vars " ^ String.concat " " arg_names ^ " : SpectecTerminals .\n" ^
        (if split_elem_names = [] then ""
         else "  vars " ^ String.concat " " split_elem_names ^ " : SpectecTerminal .\n") ^
        (if split_rest_names = [] then ""
         else "  vars " ^ String.concat " " split_rest_names ^ " : SpectecTerminals .\n") ^
        (if finite_elem_names = [] then ""
         else "  vars " ^ String.concat " " finite_elem_names ^ " : SpectecTerminal .\n")
      in
      Printf.sprintf
        "  op %s : %s -> Judgement .\n%s\
         \n  rl [%s-empty] :\n    %s ( %s )\n    =>\n    valid .\n\
         %s\
         \n  crl [%s-cons] :\n    %s ( %s )\n    =>\n    valid\n      if %s ( %s ) => valid /\\ %s ( %s ) => valid .\n"
        h.iter_helper_name op_args var_decl
        label_base h.iter_helper_name (args `Empty)
        (String.concat "" (List.init direct_unroll_limit (fun n -> finite_rule (n + 1))))
        label_base h.iter_helper_name (args `Cons)
        h.iter_rel_name (args `Rel) h.iter_helper_name (args `Rec)
    in
    "\n  --- Source-style SpecTec relation-star lowering for source premises P*.\n" ^
    "  --- A source premise `(R(...))*` becomes a generated sequence judgement\n" ^
    "  --- such as `Valtype-oks(...)`, because Maude has no premise-star syntax.\n" ^
    String.concat "\n" (List.map emit helpers) ^ "\n"

let map_call_helper_block () =
  let helpers =
    !map_call_helpers
    |> List.sort_uniq (fun a b ->
        compare
          (a.map_helper_name, a.map_fn_name, a.map_arity, a.map_seq_index, a.map_arg_sorts)
          (b.map_helper_name, b.map_fn_name, b.map_arity, b.map_seq_index, b.map_arg_sorts))
  in
  if helpers = [] then ""
  else
    let emit h =
      let base =
        h.map_helper_name
        |> String.map (function '$' | '-' -> '_' | c -> Char.uppercase_ascii c)
      in
	      let arg_names =
	        List.init h.map_arity (fun i -> Printf.sprintf "%s_A%d" base i)
	      in
	      let seq = base ^ "_S" in
	      let op_sorts = String.concat " " h.map_arg_sorts in
      let call_args repl =
        arg_names
        |> List.mapi (fun i a -> if i = h.map_seq_index then repl else a)
        |> String.concat " , "
      in
      let helper_args repl = call_args repl in
      let direct_sequence_recursion =
        h.map_arg_sorts
        |> List.mapi (fun i sort -> i <> h.map_seq_index && sort = "SpectecTerminals")
        |> List.exists (fun x -> x)
      in
      let var_decl =
        let fixed =
          arg_names
          |> List.mapi (fun i a ->
              if i = h.map_seq_index then None
              else
                let sort =
                  try List.nth h.map_arg_sorts i
                  with _ -> "SpectecTerminal"
                in
                Some (a, sort))
          |> List.filter_map (fun x -> x)
        in
        (if fixed = [] then ""
         else
           fixed
           |> List.map (fun (v, sort) -> Printf.sprintf "  var %s : %s .\n" v sort)
           |> String.concat "") ^
        if direct_sequence_recursion then
          Printf.sprintf "  var %s_E : SpectecTerminal .\n  var %s : SpectecTerminals .\n"
            base seq
        else
          Printf.sprintf "  var %s : SpectecTerminals .\n" seq
      in
      let map_block =
        if direct_sequence_recursion then
          let elem = base ^ "_E" in
          Printf.sprintf
            "  op %s : %s -> SpectecTerminals .\n%s\
             \n  eq %s ( %s ) = eps .\n\
             \n  eq %s ( %s ) = %s ( %s ) .\n\
             \n  ceq %s ( %s ) = %s ( %s ) %s ( %s )\n\
               if %s =/= eps .\n"
            h.map_helper_name op_sorts var_decl
            h.map_helper_name (helper_args "eps")
            h.map_helper_name (helper_args elem)
            h.map_fn_name (call_args elem)
            h.map_helper_name (helper_args (Printf.sprintf "%s %s" elem seq))
            h.map_fn_name (call_args elem)
            h.map_helper_name (helper_args seq)
            seq
        else
          let head = Printf.sprintf "index ( %s, 0 )" seq in
          let tail =
            Printf.sprintf "slice ( %s, 1, _-_ ( len ( %s ), 1 ) )" seq seq
          in
          Printf.sprintf
            "  op %s : %s -> SpectecTerminals .\n%s\
             \n  eq %s ( %s ) = eps .\n\
             \n  ceq %s ( %s ) = %s ( %s ) %s ( %s )\n      if _>_ ( len ( %s ), 0 ) .\n"
            h.map_helper_name op_sorts var_decl
            h.map_helper_name (helper_args "eps")
            h.map_helper_name (helper_args seq)
            h.map_fn_name (call_args head)
            h.map_helper_name (helper_args tail)
            seq
      in
      let unmap_block =
        if h.map_arity = 1 && h.map_seq_index = 0 then
          let unmap_name = unmap_call_helper_name h.map_helper_name in
          let elem = base ^ "_E" in
          Printf.sprintf
            "\n  op %s : SpectecTerminals -> SpectecTerminals .\n\
             \n  var %s : SpectecTerminal .\n\
             \n  eq %s ( eps ) = eps .\n\
             \n  eq %s ( %s ( %s ) %s ) = %s %s ( %s ) .\n"
            unmap_name
            elem
            unmap_name
            unmap_name h.map_fn_name elem seq elem unmap_name seq
        else ""
      in
      map_block ^ unmap_block
    in
    "\n  --- Generic SpecTec expression-star lowering for source expressions e*.\n" ^
    "  --- Each helper maps one iterated source argument over a flat sequence.\n" ^
    String.concat "\n" (List.map emit helpers) ^ "\n"

let starts_with s pfx =
  String.length s >= String.length pfx && String.sub s 0 (String.length pfx) = pfx

let is_decl_line l =
  let s = String.trim l in
  starts_with s "op " || starts_with s "ops " ||
  starts_with s "var " || starts_with s "vars " ||
  starts_with s "subsort " || starts_with s "sort "

let is_canonical_ctor_decl_line l =
  let s = String.trim l in
  starts_with s "op CTOR" && String.contains s ':'

let zero_arity_ctor_sort_name ctor =
  "Sort" ^ ctor

let collect_zero_arity_ctor_memberships eq_lines =
  let re =
    Str.regexp "^[ \t]*mb[ \t]+([ \t]*\\(CTOR[A-Z0-9]+A0\\)[ \t]*)[ \t]*:[ \t]*\\([A-Za-z0-9_-]+\\)[ \t]*\\."
  in
  let tbl = Hashtbl.create 256 in
  List.iter (fun l ->
    if Str.string_match re l 0 then
      match str_matched_group_opt 1 l, str_matched_group_opt 2 l with
      | Some ctor, Some sort ->
          let sorts =
            match Hashtbl.find_opt tbl ctor with
            | Some xs -> xs
            | None -> []
          in
          Hashtbl.replace tbl ctor (sort :: sorts)
      | _ -> ())
	    eq_lines;
	  tbl

let collect_ctor_decl_lines eq_lines =
  let re = Str.regexp "CTOR[A-Z0-9]+A[0-9]+" in
  let seen = Hashtbl.create 512 in
  let zero_arity_memberships = collect_zero_arity_ctor_memberships eq_lines in
  let add_name nm =
    if not (Hashtbl.mem seen nm) then Hashtbl.add seen nm ()
  in
  let ctor_arity nm =
    let idx_a = try String.rindex nm 'A' with Not_found -> String.length nm - 1 in
    try int_of_string (String.sub nm (idx_a + 1) (String.length nm - idx_a - 1))
    with _ -> 0
  in
  let scan_line l =
    let rec loop pos =
      match (try Some (Str.search_forward re l pos) with Not_found -> None) with
      | None -> ()
      | Some _ ->
          let nm = Str.matched_string l in
          let next_pos = Str.match_end () in
          add_name nm;
          loop next_pos
    in
    loop 0
  in
  List.iter scan_line eq_lines;
  Hashtbl.to_seq_keys seen
  |> List.of_seq
  |> List.sort_uniq String.compare
  |> List.map (fun nm ->
       match nm with
       | "CTORLABELLBRACERBRACEA3" ->
           "  op CTORLABELLBRACERBRACEA3 : N SpectecTerminals SpectecTerminals -> Instr [ctor] ."
       | "CTORFRAMELBRACERBRACEA3" ->
           "  op CTORFRAMELBRACERBRACEA3 : N Frame SpectecTerminals -> Instr [ctor] ."
       | "CTORHANDLERLBRACERBRACEA3" ->
           "  op CTORHANDLERLBRACERBRACEA3 : N Catch SpectecTerminals -> Instr [ctor] ."
       | _ ->
           let arity = ctor_arity nm in
           if arity = 0 then
	             match Hashtbl.find_opt zero_arity_memberships nm with
	             | Some sorts ->
	                 let sorts = List.sort_uniq String.compare sorts in
	                 let ctor_sort = zero_arity_ctor_sort_name nm in
	                 Printf.sprintf
	                   "  sort %s .\n  subsort %s < %s .\n  op %s : -> %s [ctor] ."
	                   ctor_sort ctor_sort (String.concat " " sorts) nm ctor_sort
	             | None ->
	                 Printf.sprintf "  op %s :  -> SpectecTerminal [ctor] ." nm
	           else
	             let args =
                 match Hashtbl.find_opt ctor_arg_sort_hints nm with
                 | Some sorts when List.length sorts = arity -> String.concat " " sorts
                 | _ -> String.concat " " (List.init arity (fun _ -> "SpectecTerminal"))
               in
		             Printf.sprintf "  op %s : %s -> SpectecTerminal [ctor] ."
		               nm args)

let infer_category_subsort_decls eq_lines =
  let eq_lines = List.concat_map (String.split_on_char '\n') eq_lines in
  let re =
    Str.regexp
      "^[ \t]+\\(mb\\|cmb\\)[ \t]+( \\(.*\\) )[ \t]+:[ \t]+\\([A-Za-z][A-Za-z0-9-]*\\)\\([ \t]*\\.\\|[ \t]*$\\)"
  in
  let re_zero_ctor_subsort =
    Str.regexp
      "^[ \t]+subsort[ \t]+\\(SortCTOR[A-Za-z0-9]+\\)[ \t]+<[ \t]+\\(.*\\)[ \t]+\\."
  in
  let by_sort = Hashtbl.create 128 in
  let add sort lhs =
    let old =
      match Hashtbl.find_opt by_sort sort with
      | Some s -> s
      | None -> SSet.empty
    in
    Hashtbl.replace by_sort sort (SSet.add lhs old)
  in
  List.iter
    (fun line ->
      if Str.string_match re line 0 then
        match str_matched_group_opt 2 line, str_matched_group_opt 3 line with
        | Some lhs, Some sort when not (is_plain_var_like (String.trim lhs)) ->
            add sort (String.trim lhs)
        | _ -> ()
      else if Str.string_match re_zero_ctor_subsort line 0 then
        match str_matched_group_opt 1 line, str_matched_group_opt 2 line with
        | Some ctor_sort, Some sorts ->
            sorts
            |> String.split_on_char ' '
            |> List.map String.trim
            |> List.filter (fun s -> s <> "" && s <> "<")
            |> List.iter (fun sort -> add sort ctor_sort)
        | _ -> ())
    eq_lines;
  let pairs =
    Hashtbl.fold (fun s lhs acc -> (s, lhs) :: acc) by_sort []
  in
  pairs
  |> List.concat_map (fun (child, child_lhs) ->
       pairs
       |> List.filter_map (fun (parent, parent_lhs) ->
            if child <> parent
               && SSet.cardinal child_lhs > 0
               && SSet.cardinal child_lhs < SSet.cardinal parent_lhs
               && SSet.subset child_lhs parent_lhs
            then Some (Printf.sprintf "  subsort %s < %s ." child parent)
            else None))
  |> List.sort_uniq String.compare

let translate defs =
  iter_rel_helpers := [];
  infer_rel_helpers := [];
  infer_rel_rules := [];
  map_call_helpers := [];
  Hashtbl.clear ctor_arg_sort_hints;
  source_seq_pred_sorts := SSet.empty;
  feature_uses_bool_wrapper := false;
  feature_uses_has_type := false;
  feature_uses_star_prefix := false;
  build_type_env defs;
  init_declared_vars ();
  let ss = new_scan () in
  List.iter (scan_def ss) defs;
  known_call_names :=
    SSet.union
      ss.dec_funcs
      (SIPairSet.elements ss.calls |> List.map fst |> SSet.of_list);
  let token_ops = build_token_ops ss in
  let call_ops = build_call_ops ss in
  let translated_defs =
    String.concat "\n" (List.map (translate_definition ss) defs)
  in
  let body_without_prelude_helpers =
    translated_defs ^ infer_rel_helper_block () ^ iter_rel_helper_block ()
    ^ map_call_helper_block ()
  in
  let prelude_features =
    prelude_features_of_source defs ss body_without_prelude_helpers token_ops
  in
  let header =
    header_prefix prelude_features
    ^ "  --- Auto-collected tokens\n" ^ token_ops ^ call_ops
  in
  let body =
    prelude_helper_decls prelude_features ^ "\n" ^ body_without_prelude_helpers
  in
  let lines = String.split_on_char '\n' body in
  let eqs = List.filter (fun l -> not (is_decl_line l)) lines in
  let ctor_decl_lines = collect_ctor_decl_lines eqs in
  let inferred_category_subsort_decls =
    infer_category_subsort_decls (lines @ ctor_decl_lines)
  in
  let raw_decls =
    List.filter is_decl_line lines
    |> List.filter (fun l -> not (is_canonical_ctor_decl_line l))
    |> List.sort_uniq String.compare
    |> fun ds ->
        List.sort_uniq String.compare
          (ds @ ctor_decl_lines @ inferred_category_subsort_decls)
  in
  (* Post-processing fix 1: Remove 0-arity "op X :  -> SpectecType [ctor]" when a
     1-arity "op X : SpectecTerminal -> SpectecType [ctor]" for the SAME name exists.
     Avoids "multiple distinct parses" for names like num, vec. *)
  let re_zero_arity = Str.regexp "  op \\([^ (]+\\) :  -> \\(SpectecType\\|SpectecTerminal\\) \\[ctor\\] \\." in
  let re_higher_arity = Str.regexp "  op \\([^ (]+\\) : SpectecTerminal" in
  let higher_arity_names =
    List.filter_map (fun l ->
      if Str.string_match re_higher_arity l 0
      then str_matched_group_opt 1 l
      else None
    ) raw_decls
    |> List.sort_uniq String.compare
    |> fun ns -> List.fold_left (fun s n -> SSet.add n s) SSet.empty ns
  in
  (* Post-processing fix 2: Collect all var-declared names, then remove
     "op X : -> SpectecTerminal ." or "op X :  -> SpectecType [ctor]" when
     "var X : ..." already declared — prevents op/var ambiguity. *)
  let re_var_decl = Str.regexp "  var\\s+\\([A-Z][A-Z0-9-]*\\) :" in
  let var_names =
    List.filter_map (fun l ->
      if Str.string_match re_var_decl l 0
      then str_matched_group_opt 1 l
      else None
    ) raw_decls
    |> List.sort_uniq String.compare
    |> fun ns -> List.fold_left (fun s n -> SSet.add n s) SSet.empty ns
  in
  let decls =
    List.filter (fun l ->
      if Str.string_match re_zero_arity l 0 then
        match str_matched_group_opt 1 l with
        | Some nm ->
            (* keep if no higher-arity version and not a var *)
            not (SSet.mem nm higher_arity_names) && not (SSet.mem nm var_names)
        | None -> true
      else true
    ) raw_decls
    (* Also remove "op X : -> SpectecTerminal ." (single space) when var X exists *)
    |> List.filter (fun l ->
      let s = String.trim l in
      if starts_with s "op " then
        let re = Str.regexp "op \\([^ (]+\\) : -> SpectecTerminal \\." in
        if Str.string_match re s 0 then
          match str_matched_group_opt 1 s with
          | Some nm -> not (SSet.mem nm var_names)
          | None -> true
        else true
      else true
    )
    |> List.sort_uniq String.compare
  in
  let pred_sorts = exec_pred_sorts () |> SSet.of_list in
  let pred_var_decls, pred_eqs = refined_exec_pred_eqs pred_sorts eqs decls in
  let decls =
    List.sort_uniq String.compare (decls @ exec_pred_decls (SSet.elements pred_sorts) @ pred_var_decls)
  in
  let eqs = eqs @ pred_eqs in
  header ^ "\n  --- Declarations\n" ^ String.concat "\n" decls ^
  "\n\n  --- Equations\n" ^ String.concat "\n" eqs ^ footer prelude_features
