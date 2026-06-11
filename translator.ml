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
let feature_uses_steps_final_predicate : bool ref = ref false
let unsupported_syntax_families : SSet.t ref = ref SSet.empty

type star_ctor_unzip_helper = {
  star_unzip_ctor : string;
  star_unzip_arity : int;
}

type opt_ctor_helper = {
  opt_ctor : string;
  opt_arity : int;
}

type source_compound_case = {
  compound_parent_sort : string;
  compound_ctor : string;
  compound_fields : (string option * typ) list;
  compound_prems : prem list;
}

let star_ctor_unzip_helpers : star_ctor_unzip_helper list ref = ref []
let opt_ctor_helpers : opt_ctor_helper list ref = ref []
let source_compound_cases : source_compound_case list ref = ref []

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

let contains_ws s =
  String.exists
    (function ' ' | '\t' | '\n' | '\r' -> true | _ -> false)
    s

let relation_mixop_is_execution mixop =
  let s = Xl.Mixop.to_string mixop in
  contains_substring s "~>" || contains_substring s "~>*"

let relation_mixop_is_star_execution mixop =
  contains_substring (Xl.Mixop.to_string mixop) "~>*"

let wrap_paren s = Printf.sprintf "( %s )" s

let debug_iter_enabled =
  match Sys.getenv_opt "SPEC2MAUDE_DEBUG_ITER" with
  | Some "1" | Some "true" | Some "TRUE" | Some "yes" | Some "YES" -> true
  | _ -> false

let debug_iter fmt =
  if debug_iter_enabled then Printf.eprintf (fmt ^^ "\n")
  else Printf.ifprintf stderr (fmt ^^ "\n")

(* C1 runtime-cleanup experiment:
   The generated runtime assumes the input Wasm program has already been
   validated, so source category/typecheck guards should not be required for
   execution.  We still keep source syntax/category labels as data when source
   meta-functions need them, but we drop the executable membership/typecheck
   layer from the generated core. *)
let drop_runtime_typecheck_guards = true

let record_unsupported_syntax_family name reason =
  unsupported_syntax_families :=
    SSet.add (name ^ ": " ^ reason) !unsupported_syntax_families

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
  let re = Str.regexp "^\\(.*[^=<>/]\\)[ \t]*=[ \t]*true[ \t]*$" in
  if Str.string_match re t 0 then
    match str_matched_group_opt 1 t with
    | Some lhs -> String.trim lhs
    | None -> t
  else t

let strip_trailing_dot s =
  let t = String.trim s in
  let len = String.length t in
  if len > 0 && t.[len - 1] = '.'
  then String.trim (String.sub t 0 (len - 1))
  else t

let replace_first_literal needle repl s =
  Str.replace_first (Str.regexp_string needle) repl s

let cond_join conds =
  conds
  |> List.map String.trim
  |> List.map strip_trailing_dot
  |> List.map strip_trailing_eq_true
  |> List.map strip_trailing_dot
  |> List.filter (fun c -> c <> "" && c <> "true" && c <> "( true )" && c <> "(true)")
  |> String.concat " /\\ "

let cond_join_preserve_eq_true conds =
  conds
  |> List.map String.trim
  |> List.map strip_trailing_dot
  |> List.map strip_trailing_dot
  |> List.filter (fun c ->
       c <> "" && c <> "true" && c <> "( true )" && c <> "(true)")
  |> String.concat " /\\ "

let safe_term_text s =
  let t = String.trim s in
  if t = "" then "T" else t

let rec strip_wrapping_parens s =
  let t = String.trim s in
  let n = String.length t in
  let outer_parens_enclose_all () =
    let rec scan i depth =
      if i >= n then depth = 0
      else
        let depth' =
          match t.[i] with
          | '(' -> depth + 1
          | ')' -> depth - 1
          | _ -> depth
        in
        depth' >= 0 && not (depth' = 0 && i < n - 1) && scan (i + 1) depth'
    in
    n >= 2 && t.[0] = '(' && t.[n - 1] = ')' && scan 0 0
  in
  if outer_parens_enclose_all ()
  then strip_wrapping_parens (String.sub t 1 (n - 2))
  else t

let is_plain_var_like s =
  let b = strip_wrapping_parens s in
  String.length b > 0
  && b.[0] >= 'A' && b.[0] <= 'Z'
  && not (String.contains b ' ')
  && not (String.contains b '(')
  && not (String.contains b ')')

let rec typ_is_raw_numeric_payload (t : typ) =
  match t.it with
  | NumT (`NatT | `IntT) -> true
  | VarT (id, []) ->
      let raw = String.lowercase_ascii id.it in
      raw = "nat" || raw = "int"
  | TupT [(_, inner)] -> typ_is_raw_numeric_payload inner
  | IterT (inner, Opt) -> typ_is_raw_numeric_payload inner
  | _ -> false

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
      || SSet.mem name maude_keywords
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

let spectec_term_var = "T_SPECTEC"
let spectec_nat_var = "N_SPECTEC"
let spectec_int_var = "I_SPECTEC"

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

type source_ctor_info = {
  source_ctor_name : string;
  source_ctor_arity : int;
  source_ctor_key : string;
  source_ctor_category : string option;
  source_ctor_original_sections : string list;
  source_ctor_sections : string list;
}

let source_ctor_by_key : (string, source_ctor_info) Hashtbl.t =
  Hashtbl.create 512
let source_ctor_by_name : (string, source_ctor_info) Hashtbl.t =
  Hashtbl.create 512
let source_ctor_by_surface_head_arity : (string, source_ctor_info) Hashtbl.t =
  Hashtbl.create 512
let source_ctor_by_original_head_arity : (string, source_ctor_info list) Hashtbl.t =
  Hashtbl.create 512
let source_ctor_name_counts : (string, int) Hashtbl.t =
  Hashtbl.create 512
let source_ctor_head_categories : (string, SSet.t) Hashtbl.t =
  Hashtbl.create 512
let source_ctor_head_occurrences : (string, (int * string * string) list) Hashtbl.t =
  Hashtbl.create 512
let source_ctor_head_category_arities : (string, int list) Hashtbl.t =
  Hashtbl.create 512
let source_ctor_heads_requiring_category_suffix : SSet.t ref = ref SSet.empty
let source_ctor_head_categories_requiring_arg_suffix : SSet.t ref = ref SSet.empty
let source_ctor_blocked_var_names : SSet.t ref = ref SSet.empty

let trim_tail_hyphen s =
  let rec go x =
    let n = String.length x in
    if n > 0 && x.[n - 1] = '-' then go (String.sub x 0 (n - 1)) else x
  in
  go s

let trim_tail_underscore s =
  let rec go x =
    let n = String.length x in
    if n > 0 && x.[n - 1] = '_' then go (String.sub x 0 (n - 1)) else x
  in
  go s

let maude_source_op_token name =
  let lowered = String.lowercase_ascii (sanitize name |> trim_tail_hyphen) in
  if lowered = "" then lowered
  else if SSet.mem lowered maude_keywords then "w-" ^ lowered
  else lowered

let source_ctor_component s =
  let b = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      if (c >= 'a' && c <= 'z')
         || (c >= 'A' && c <= 'Z')
         || (c >= '0' && c <= '9')
      then Buffer.add_char b c)
    s;
  String.uppercase_ascii (Buffer.contents b)

let source_ctor_sections_from_mixop mixop =
  mixop
  |> List.map (fun atoms ->
       atoms
       |> List.map Xl.Atom.name
       |> String.concat ""
       |> sanitize
       |> trim_tail_hyphen)

let source_ctor_components_from_sections sections =
  sections
  |> List.filter (fun s -> s <> "")
  |> List.filter (fun s -> s <> "%" && s <> "$")
  |> List.map source_ctor_component
  |> List.filter (fun s -> s <> "")

let source_ctor_key sections arity =
  Printf.sprintf "%s#%d" (String.concat "\x1f" sections) arity

let source_ctor_mixfix_name base suffix arity =
  let stem = if suffix = "" then base else base ^ suffix in
  if arity <= 0 then stem else stem ^ String.make arity '_'

let source_ctor_surface_head_arity_key head arity =
  head ^ "#" ^ string_of_int arity

let source_ctor_interleave_op sections n_vars =
  let rec go secs n = match secs, n with
    | [], n -> List.init n (fun _ -> "_")
    | s :: ss, n when n > 0 ->
        (if s <> "" then [maude_source_op_token s; "_"] else ["_"]) @ go ss (n - 1)
    | [s], 0 -> if s <> "" then [maude_source_op_token s] else []
    | _ :: ss, 0 -> go ss 0
    | _, _ -> []
  in
  String.concat " " (go sections n_vars)

let source_ctor_suffix_sections sections suffix =
  if suffix = "" then sections
  else
    let rec go = function
      | [] -> [suffix]
      | s :: rest when s <> "" -> (s ^ suffix) :: rest
      | s :: rest -> s :: go rest
    in
    go sections

let source_ctor_surface_head sections =
  sections |> List.find_opt (fun s -> String.trim s <> "")

let source_ctor_surface_op_head sections =
  source_ctor_surface_head sections |> Option.map maude_source_op_token

let source_ctor_head_category_key head category =
  head ^ "\x1e" ^ maude_source_op_token category

let register_source_ctor_head_category sections category =
  match source_ctor_surface_op_head sections with
  | None -> ()
  | Some head ->
      let category = maude_source_op_token category in
      let old =
        match Hashtbl.find_opt source_ctor_head_categories head with
        | Some cats -> cats
        | None -> SSet.empty
      in
      Hashtbl.replace source_ctor_head_categories head (SSet.add category old)

let source_ctor_head_needs_category_suffix sections =
  match source_ctor_surface_op_head sections with
  | None -> false
  | Some head -> SSet.mem head !source_ctor_heads_requiring_category_suffix

let source_ctor_head_category_needs_arg_suffix sections category arity =
  arity > 0
  &&
  match source_ctor_surface_op_head sections with
  | None -> false
  | Some head ->
      SSet.mem
        (source_ctor_head_category_key head category)
        !source_ctor_head_categories_requiring_arg_suffix

let source_ctor_strip_index_suffix raw =
  let re = Str.regexp "^\\(.+\\)_[0-9]+$" in
  if Str.string_match re raw 0 then
    match str_matched_group_opt 1 raw with Some s -> s | None -> raw
  else raw

let rec source_ctor_arg_shape_component_of_typ (t : typ) =
  match t.it with
  | VarT (id, []) ->
      maude_source_op_token (source_ctor_strip_index_suffix id.it)
  | VarT (id, args) ->
      let base = maude_source_op_token (source_ctor_strip_index_suffix id.it) in
      let arg_parts =
        args
        |> List.filter_map (fun arg ->
             match arg.it with
             | TypA t -> Some (source_ctor_arg_shape_component_of_typ t)
             | ExpA e -> (
                 match e.it with
                 | VarE id -> Some (maude_source_op_token (source_ctor_strip_index_suffix id.it))
                 | _ -> None)
             | DefA _ | GramA _ -> None)
        |> List.filter (fun s -> s <> "")
      in
      if arg_parts = [] then base else base ^ "-" ^ String.concat "-" arg_parts
  | IterT (inner, iter) ->
      let base = source_ctor_arg_shape_component_of_typ inner in
      (match iter with
       | List | List1 | ListN _ -> base ^ "s"
       | Opt -> base)
  | TupT fields ->
      fields
      |> List.map (fun (_field_exp, field_typ) ->
           source_ctor_arg_shape_component_of_typ field_typ)
      |> List.filter (fun s -> s <> "")
      |> String.concat "-"
  | BoolT -> "bool"
  | NumT _ -> "num"
  | TextT -> "text"

let source_ctor_arg_shape_suffix_of_typ (t : typ) =
  match t.it with
  | TupT fields ->
      fields
      |> List.map (fun (_field_exp, field_typ) ->
           source_ctor_arg_shape_component_of_typ field_typ)
      |> List.filter (fun s -> s <> "")
      |> String.concat "-"
      |> fun s -> if s = "" then None else Some s
  | _ ->
      let s = source_ctor_arg_shape_component_of_typ t in
      if s = "" then None else Some s

let source_ctor_effective_sections ?category ?arg_shape sections arity =
  let arg_suffix =
    match category, arg_shape with
    | Some category, Some arg_shape
        when source_ctor_head_category_needs_arg_suffix sections category arity ->
        "-" ^ maude_source_op_token arg_shape
    | _ -> ""
  in
  let category_suffix =
    match category with
    | Some category when source_ctor_head_needs_category_suffix sections ->
        "-" ^ maude_source_op_token category
    | _ -> ""
  in
  source_ctor_suffix_sections sections (arg_suffix ^ category_suffix)

let register_source_ctor key base ?category original_sections sections arity =
  match Hashtbl.find_opt source_ctor_by_key key with
  | Some info -> info.source_ctor_name
  | None ->
      let count_key = base ^ "/" ^ string_of_int arity in
      let count =
        match Hashtbl.find_opt source_ctor_name_counts count_key with
        | Some n -> n + 1
        | None -> 1
      in
      Hashtbl.replace source_ctor_name_counts count_key count;
      let suffix = if count = 1 then "" else "C" ^ string_of_int count in
      let name = source_ctor_mixfix_name base suffix arity in
      let sections = source_ctor_suffix_sections sections suffix in
      let info =
        { source_ctor_name = name;
          source_ctor_arity = arity;
          source_ctor_key = key;
          source_ctor_category = Option.map maude_source_op_token category;
          source_ctor_original_sections = original_sections;
          source_ctor_sections = sections }
      in
      Hashtbl.replace source_ctor_by_key key info;
      Hashtbl.replace source_ctor_by_name name info;
	      (match source_ctor_surface_head sections with
	       | Some head ->
	           Hashtbl.replace source_ctor_by_surface_head_arity
	             (source_ctor_surface_head_arity_key head arity)
	             info
	       | None -> ());
	      (match source_ctor_surface_op_head sections with
	       | Some head ->
	           Hashtbl.replace source_ctor_by_surface_head_arity
	             (source_ctor_surface_head_arity_key head arity)
	             info
	       | None -> ());
	      (match source_ctor_surface_op_head original_sections with
	       | Some head ->
	           let key = source_ctor_surface_head_arity_key head arity in
	           let old =
	             match Hashtbl.find_opt source_ctor_by_original_head_arity key with
	             | Some xs -> xs
	             | None -> []
	           in
	           if not (List.exists (fun i -> i.source_ctor_key = info.source_ctor_key) old) then
	             Hashtbl.replace source_ctor_by_original_head_arity key (info :: old)
	       | None -> ());
      source_ctor_blocked_var_names :=
        !source_ctor_blocked_var_names
        |> SSet.add name
        |> SSet.add (String.trim (Str.global_replace (Str.regexp "_+") "" name));
      name

let source_ctor_candidates_by_original_head_arity head arity =
  match Hashtbl.find_opt source_ctor_by_original_head_arity
          (source_ctor_surface_head_arity_key head arity)
  with
  | Some infos -> infos
  | None -> []

let source_ctor_name_from_sections ?category ?case_typ sections arity =
  let original_sections = sections in
  (match category, source_ctor_head_needs_category_suffix sections with
   | None, true ->
       (match source_ctor_surface_op_head sections with
        | Some head ->
            (match source_ctor_candidates_by_original_head_arity head arity with
             | [info] -> Some info.source_ctor_name
             | _ -> None)
        | None -> None)
   | _ ->
  let arg_shape = Option.bind case_typ source_ctor_arg_shape_suffix_of_typ in
  let sections = source_ctor_effective_sections ?category ?arg_shape sections arity in
  match source_ctor_components_from_sections sections with
  | [] -> None
  | components ->
      let base = String.concat "" components in
      let key = source_ctor_key sections arity in
      Some (register_source_ctor key base ?category original_sections sections arity))

let source_ctor_name_from_mixop ?category ?case_typ mixop arity =
  source_ctor_name_from_sections ?category ?case_typ (source_ctor_sections_from_mixop mixop) arity

let source_mixop_has_constructor_name mixop =
  source_ctor_sections_from_mixop mixop
  |> source_ctor_components_from_sections
  |> fun components -> components <> []

let source_nullary_ctor_name_from_id raw =
  let sections = [sanitize raw |> trim_tail_hyphen] in
  source_ctor_name_from_sections sections 0

let source_ctor_arity name =
  match Hashtbl.find_opt source_ctor_by_name name with
  | Some info -> Some info.source_ctor_arity
  | None -> None

let is_source_ctor_name name =
  Hashtbl.mem source_ctor_by_name name

let source_ctor_op_name info =
  match
    info.source_ctor_sections
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
  with
  | [single] -> maude_source_op_token single
  | _ -> maude_source_op_token (trim_tail_underscore info.source_ctor_name)

let source_ctor_op_key op_name arity =
  op_name ^ "#" ^ string_of_int arity

let source_ctor_info_by_op_name_arity op_name arity =
  let found = ref None in
  Hashtbl.iter
    (fun _ info ->
       if !found = None
          && info.source_ctor_arity = arity
          && source_ctor_op_name info = op_name
       then found := Some info)
    source_ctor_by_name;
  !found

let is_source_ctor_var_token name =
  SSet.mem name !source_ctor_blocked_var_names

let source_ctor_suffix ctor =
  let b = Buffer.create (String.length ctor) in
  String.iter
    (fun c ->
      if (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
      then Buffer.add_char b c
      else if c >= 'a' && c <= 'z' then Buffer.add_char b (Char.uppercase_ascii c))
    ctor;
  let s = Buffer.contents b in
  if s = "" then String.uppercase_ascii (sanitize ctor) else s

let rule_label_prefix rel_name case_id rule_idx =
  let rel_part = String.uppercase_ascii (sanitize_rule_label_part rel_name) in
  let case_part_raw = String.uppercase_ascii (sanitize_rule_label_part case_id) in
  let case_part = if case_part_raw = "" then Printf.sprintf "R%d" rule_idx else case_part_raw in
  Printf.sprintf "%s-%s" rel_part case_part

let skipped_relation_names : SSet.t ref = ref SSet.empty

let is_skipped_relation_name rel_name =
  SSet.mem (sanitize rel_name) !skipped_relation_names

let valid_rel_mirrors : SSet.t ref = ref SSet.empty

let valid_mirror_name rel_name =
  "$valid-" ^ String.lowercase_ascii (sanitize rel_name)

let register_valid_rel_mirror rel_name =
  if not (is_skipped_relation_name rel_name) then
    valid_rel_mirrors := SSet.add (sanitize rel_name) !valid_rel_mirrors

let valid_mirror_call_of_rewrite_text text =
  match split_once "=> valid" text with
  | None -> None
  | Some (call, rest) when String.trim rest = "" ->
      let call = strip_wrapping_parens call |> String.trim in
      (match head_symbol_of_text call with
       | None -> None
       | Some rel_name ->
           if is_skipped_relation_name rel_name then None else
           let mirror = valid_mirror_name rel_name in
           register_valid_rel_mirror rel_name;
           let n = String.length rel_name in
           if String.length call < n then None
           else
             let suffix = String.sub call n (String.length call - n) in
             Some (Printf.sprintf "( %s%s == true )" mirror suffix))
  | _ -> None

let avoid_source_ctor_var_name name =
  if is_source_ctor_var_token name || is_source_ctor_name name then name ^ "-V"
  else name

let to_var_name name =
  String.uppercase_ascii (sanitize name)

let source_var_component name =
  let normalized =
    String.concat "" (String.split_on_char '-' (String.uppercase_ascii (sanitize name)))
  in
  let normalized = if normalized = "" then "V" else normalized in
  if String.length name = 1 && name.[0] >= 'a' && name.[0] <= 'z'
  then "LOW" ^ normalized
  else normalized

let to_source_var_name name =
  source_var_component name

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
      when (match source_ctor_arity ctor with Some 0 -> true | _ -> false)
           && is_plain_var_like seq_var ->
      Some (ctor, strip_wrapping_parens seq_var)
  | _ -> None

let star_prefix_text ctor seq =
  feature_uses_star_prefix := true;
  Printf.sprintf "$star-prefix ( %s, %s )" ctor seq

let star_unprefix_text ctor seq =
  feature_uses_star_prefix := true;
  Printf.sprintf "$star-unprefix ( %s, %s )" ctor seq

let star_ctor_unzip_name ctor i =
  Printf.sprintf "$unzip-%s-%d" (String.lowercase_ascii (sanitize ctor)) i

let register_star_ctor_unzip ctor arity =
  let helper = { star_unzip_ctor = ctor; star_unzip_arity = arity } in
  if not (List.exists (fun h ->
      h.star_unzip_ctor = ctor && h.star_unzip_arity = arity)
      !star_ctor_unzip_helpers)
  then star_ctor_unzip_helpers := helper :: !star_ctor_unzip_helpers

let opt_prefix_name ctor =
  Printf.sprintf "$opt-prefix-%s" (String.lowercase_ascii (sanitize ctor))

let opt_unzip_name ctor i =
  Printf.sprintf "$opt-unzip-%s-%d" (String.lowercase_ascii (sanitize ctor)) i

let register_opt_ctor_helper ctor arity =
  let helper = { opt_ctor = ctor; opt_arity = arity } in
  if not (List.exists (fun h ->
      h.opt_ctor = ctor && h.opt_arity = arity)
      !opt_ctor_helpers)
  then opt_ctor_helpers := helper :: !opt_ctor_helpers

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

let source_ctor_surface_head_exists head =
  let surface_head sections =
    sections |> List.find_opt (fun s -> String.trim s <> "")
  in
  Hashtbl.fold
    (fun _ info found ->
	       found ||
	       match surface_head info.source_ctor_sections with
	       | Some h -> h = head || maude_source_op_token h = head
	       | None -> false)
    source_ctor_by_name
    false

let token_can_head_prefix_call token =
  let token = String.trim token in
  let len = String.length token in
  len > 0
  &&
  (token.[0] = '$'
   || token.[0] = '_'
   || (token.[0] >= 'a' && token.[0] <= 'z')
   || String.exists (fun c -> c >= 'a' && c <= 'z') token)

let split_top_level_terms ?(drop_eps=true) s =
  let s = strip_wrapping_parens s |> String.trim in
  let len = String.length s in
  let rec loop i depth start acc =
    if i >= len then
      let part = String.sub s start (len - start) |> String.trim in
      List.rev
        (if part = "" || (drop_eps && part = "eps") then acc else part :: acc)
    else
      match s.[i] with
      | '(' | '[' | '{' -> loop (i + 1) (depth + 1) start acc
      | ')' | ']' | '}' -> loop (i + 1) (max 0 (depth - 1)) start acc
      | ' ' | '\t' | '\n' | '\r' when depth = 0 ->
          let part = String.sub s start (i - start) |> String.trim in
          let rec skip_ws j =
            if j < len then
              match s.[j] with
              | ' ' | '\t' | '\n' | '\r' -> skip_ws (j + 1)
              | _ -> j
            else j
          in
          let j = skip_ws (i + 1) in
          if part <> "" && j < len && s.[j] = '[' then
            loop j depth start acc
          else if part <> "" && j < len && s.[j] = '('
             && not (String.contains part ' ')
             && token_can_head_prefix_call part
             && not (source_ctor_surface_head_exists part) then
            loop j depth start acc
          else
            let acc =
              if part = "" || (drop_eps && part = "eps") then acc else part :: acc
            in
            loop j depth j acc
      | _ -> loop (i + 1) depth start acc
  in
  if s = "" || (drop_eps && s = "eps") then []
  else
    loop 0 0 0 []
    |> List.filter (fun term ->
         let term = String.trim term in
         term <> "" && ((not drop_eps) || term <> "eps"))

let split_top_level_terms_preserve_eps s =
  split_top_level_terms ~drop_eps:false s

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

let parse_source_ctor_surface_text text =
  let text = strip_wrapping_parens text |> String.trim in
  match parse_call_text text with
  | Some (head, args) ->
      (match Hashtbl.find_opt source_ctor_by_surface_head_arity
               (source_ctor_surface_head_arity_key head (List.length args))
       with
       | Some info -> Some (info.source_ctor_name, args)
       | None ->
           (match Hashtbl.find_opt source_ctor_by_name head with
            | Some info when info.source_ctor_arity = List.length args ->
                Some (info.source_ctor_name, args)
            | _ ->
                (match source_ctor_info_by_op_name_arity head (List.length args) with
                 | Some info -> Some (info.source_ctor_name, args)
                 | None -> None)))
  | None ->
  match split_top_level_terms_preserve_eps text with
  | [] -> None
	  | [head] ->
	      (match Hashtbl.find_opt source_ctor_by_surface_head_arity
	               (source_ctor_surface_head_arity_key head 0) with
	       | Some info -> Some (info.source_ctor_name, [])
	       | None ->
	           (match source_ctor_info_by_op_name_arity head 0 with
	            | Some info -> Some (info.source_ctor_name, [])
	            | None -> None))
	  | head :: args ->
	      (match Hashtbl.find_opt source_ctor_by_surface_head_arity
	               (source_ctor_surface_head_arity_key head (List.length args)) with
	       | Some info -> Some (info.source_ctor_name, args)
	       | None ->
	           (match source_ctor_info_by_op_name_arity head (List.length args) with
	            | Some info -> Some (info.source_ctor_name, args)
	            | None -> None))

let section_top_terms section =
  if String.trim section = "" then []
  else split_top_level_terms_preserve_eps section

let source_ctor_args_for_terms info terms =
  let consume_section section terms =
    let section_terms = section_top_terms section in
    let rec loop ss ts =
      match ss, ts with
      | [], rest -> Some rest
      | s :: ss, t :: ts when s = t -> loop ss ts
      | _ -> None
    in
    loop section_terms terms
  in
  let rec consume_sections sections terms =
    match sections with
    | [] -> Some terms
    | section :: rest ->
        (match consume_section section terms with
         | Some terms -> consume_sections rest terms
         | None -> None)
  in
  let rec go sections remaining terms acc =
    if remaining = 0 then
      match consume_sections sections terms with
      | Some [] -> Some (List.rev acc)
      | _ -> None
    else
      let sections, terms =
        match sections with
        | [] -> ([], Some terms)
        | section :: rest -> (rest, consume_section section terms)
      in
      match terms with
      | Some (arg :: rest_terms) -> go sections (remaining - 1) rest_terms (arg :: acc)
      | _ -> None
  in
  go info.source_ctor_sections info.source_ctor_arity terms []

let source_ctor_info_matches_terms info terms =
  match source_ctor_args_for_terms info terms with
  | Some _ -> true
  | None -> false

let source_ctor_fixed_section_term_count info =
  info.source_ctor_sections
  |> List.concat_map section_top_terms
  |> List.length

let best_source_ctor_match_for_terms terms =
  let terms = List.map String.trim terms |> List.filter (fun t -> t <> "") in
  Hashtbl.to_seq_values source_ctor_by_name
  |> List.of_seq
  |> List.filter_map (fun info ->
       if info.source_ctor_arity <= 0 then None
       else
         match source_ctor_args_for_terms info terms with
         | Some args -> Some (info, args)
         | None -> None)
  |> List.sort (fun (a, _) (b, _) ->
       compare
         (-(source_ctor_fixed_section_term_count a), a.source_ctor_arity, a.source_ctor_name)
         (-(source_ctor_fixed_section_term_count b), b.source_ctor_arity, b.source_ctor_name))
  |> function
     | (info, args) :: _ -> Some (info, args)
     | [] -> None

let strict_source_ctor_terms terms =
  let terms = List.map String.trim terms |> List.filter (fun t -> t <> "") in
  let all_registered_match () =
    match best_source_ctor_match_for_terms terms with
    | Some (info, args) -> Some (info.source_ctor_name, args)
    | None -> None
  in
  match terms with
  | [] -> None
  | [single] ->
      (match parse_source_ctor_surface_text single with
       | Some (ctor, (_ :: _ as args)) -> Some (ctor, args)
       | _ -> all_registered_match ())
  | head :: _ ->
      Hashtbl.to_seq_values source_ctor_by_name
	      |> Seq.find_map (fun info ->
	           match source_ctor_surface_head info.source_ctor_sections with
	           | Some h when (h = head || maude_source_op_token h = head)
	                && info.source_ctor_arity > 0
	               ->
	               (match source_ctor_args_for_terms info terms with
	                | Some args -> Some (info.source_ctor_name, args)
	                | None -> None)
	           | _ -> None)
      |> (function
          | Some _ as found -> found
          | None -> all_registered_match ())

let safe_strip_source_syntax_wrapping_parens text =
  let rec loop text =
    let text = String.trim text in
    let len = String.length text in
    if len >= 2 && text.[0] = '(' && text.[len - 1] = ')' then
      let rec scan i depth =
        if i >= len then true
        else
          let depth =
            match text.[i] with
            | '(' -> depth + 1
            | ')' -> depth - 1
            | _ -> depth
          in
          if depth = 0 && i < len - 1 then false
          else scan (i + 1) depth
      in
      if scan 0 0 then
        loop (String.sub text 1 (len - 2))
      else text
    else text
  in
  loop text

let parse_full_call_text text =
  let text = safe_strip_source_syntax_wrapping_parens text in
  try
    let open_i = String.index text '(' in
    let close_i = String.rindex text ')' in
    if close_i <> String.length text - 1 || close_i <= open_i then None
    else
      let fn = String.sub text 0 open_i |> String.trim in
      if fn = "" || String.contains fn ' ' then None
      else
        let args =
          String.sub text (open_i + 1) (close_i - open_i - 1)
          |> split_top_level_commas
        in
        Some (fn, args)
  with Not_found -> None

let pretty_source_call_text fn args =
  let args = List.map String.trim args in
  let norm_arg arg =
    let arg = String.trim arg in
    if arg = "" then arg
    else if String.contains arg ' ' then Printf.sprintf "( %s )" arg
    else arg
  in
  match fn, args with
  | _, [] -> fn
  | "typecheck", _ ->
      Printf.sprintf "typecheck(%s)"
        (String.concat ", " (List.map String.trim args))
  | _ ->
      Printf.sprintf "%s ( %s )" fn
        (String.concat ", " (List.map norm_arg args))

let rec pretty_source_syntax_expr text =
  let core = safe_strip_source_syntax_wrapping_parens text in
  let bin sym a b =
    Printf.sprintf "( %s %s %s )"
      (pretty_source_syntax_expr a) sym (pretty_source_syntax_expr b)
  in
  let bool_bin sym a b =
    Printf.sprintf "( %s %s %s )"
      (pretty_source_syntax_expr a) sym (pretty_source_syntax_expr b)
  in
  match parse_full_call_text core with
  | Some ("$raw-lit", [arg]) -> pretty_source_syntax_expr arg
  | Some ("$wrap-lit", [_typ; arg]) -> pretty_source_syntax_expr arg
  | Some ("_and_", [a; b]) -> bool_bin "and" a b
  | Some ("_or_", [a; b]) -> bool_bin "or" a b
  | Some ("_==_", [a; b]) -> bin "==" a b
  | Some ("_=/=_", [a; b]) -> bin "=/=" a b
  | Some ("_<_", [a; b]) -> bin "<" a b
  | Some ("_<=_", [a; b]) -> bin "<=" a b
  | Some ("_>_", [a; b]) -> bin ">" a b
  | Some ("_>=_", [a; b]) -> bin ">=" a b
  | Some ("_+_", [a; b]) -> bin "+" a b
  | Some ("_-_", [a; b]) -> bin "-" a b
  | Some ("_*_", [a; b]) -> bin "*" a b
  | Some ("_^_", [a; b]) -> bin "^" a b
  | Some ("_quo_", [a; b]) -> bin "quo" a b
  | Some ("_rem_", [a; b]) -> bin "rem" a b
  | Some (fn, args) ->
      pretty_source_call_text fn (List.map pretty_source_syntax_expr args)
  | None -> core

let pretty_source_syntax_condition_atom cond =
  let cond = String.trim cond in
  let core = strip_trailing_eq_true cond in
  if core <> cond then
    pretty_source_syntax_expr core
  else
    pretty_source_syntax_expr cond

let rec pretty_source_syntax_condition_conjuncts cond =
  let core =
    strip_trailing_eq_true cond
    |> safe_strip_source_syntax_wrapping_parens
  in
  match parse_full_call_text core with
  | Some ("_and_", [a; b]) ->
      pretty_source_syntax_condition_conjuncts a
      @ pretty_source_syntax_condition_conjuncts b
  | _ -> [pretty_source_syntax_condition_atom cond]

let pretty_source_syntax_condition_text cond =
  cond
  |> String.trim
  |> pretty_source_syntax_condition_conjuncts
  |> List.map String.trim
  |> List.filter (fun c -> c <> "")
  |> String.concat " /\\ "

let ctor_call_pattern text =
  match parse_call_text text with
  | Some (ctor, args) when is_source_ctor_name ctor ->
      Some (ctor, List.map (fun s -> strip_wrapping_parens s |> String.trim) args)
  | Some (head, args) ->
      (match Hashtbl.find_opt source_ctor_by_surface_head_arity
               (source_ctor_surface_head_arity_key head (List.length args))
       with
       | Some info ->
           Some (info.source_ctor_name,
                 List.map (fun s -> strip_wrapping_parens s |> String.trim) args)
       | None ->
           (match source_ctor_info_by_op_name_arity head (List.length args) with
            | Some info ->
                Some (info.source_ctor_name,
                      List.map (fun s -> strip_wrapping_parens s |> String.trim) args)
            | None ->
           (match parse_source_ctor_surface_text text with
            | Some (ctor, args) ->
                Some (ctor, List.map (fun s -> strip_wrapping_parens s |> String.trim) args)
            | None -> None)))
  | _ ->
      (match parse_source_ctor_surface_text text with
       | Some (ctor, args) ->
           Some (ctor, List.map (fun s -> strip_wrapping_parens s |> String.trim) args)
       | None -> None)

let opt_prefix_call_pattern text =
  match parse_call_text text with
  | Some (name, [arg]) when starts_with name "$opt-prefix-" ->
      Some (name, strip_wrapping_parens arg |> String.trim)
  | _ -> None

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

type result_rel_helper = {
  result_rel_name : string;
  result_arity : int;
  result_arg_indices : int list;
}

let result_rel_helpers : result_rel_helper list ref = ref []
let ref_subtype_decision_fragments : string list ref = ref []
let heaptype_decision_ground_edges : (string * string) list ref = ref []

type map_call_helper = {
  map_helper_name : string;
  map_fn_name : string;
  map_arity : int;
  map_seq_index : int;
  map_arg_sorts : string list;
  map_preserve_nested : bool;
}

type zip_map_call_helper = {
  zip_map_helper_name : string;
  zip_map_fn_name : string;
  zip_map_arity : int;
  zip_map_seq_indices : int list;
  zip_map_arg_sorts : string list;
  zip_map_preserve_nested : bool;
}

type expr_map_helper = {
  expr_map_helper_name : string;
  expr_map_body : string;
  expr_map_seq_vars : string list;
  expr_map_fixed_vars : (string * string) list;
}

type otherwise_match_helper = {
  otherwise_match_name : string;
  otherwise_match_pattern : string;
}

let map_call_helpers : map_call_helper list ref = ref []
let zip_map_call_helpers : zip_map_call_helper list ref = ref []
let expr_map_helpers : expr_map_helper list ref = ref []
let otherwise_match_helpers : otherwise_match_helper list ref = ref []
let optional_literal_terms : SSet.t ref = ref SSet.empty
let optional_literal_empty_indices : int list ref = ref []
let optional_literal_seen : int ref = ref 0

let with_optional_literal_empty_indices indices f =
  let old_indices = !optional_literal_empty_indices in
  let old_seen = !optional_literal_seen in
  optional_literal_empty_indices := List.sort_uniq compare indices;
  optional_literal_seen := 0;
  try
    let result = f () in
    optional_literal_empty_indices := old_indices;
    optional_literal_seen := old_seen;
    result
  with exn ->
    optional_literal_empty_indices := old_indices;
    optional_literal_seen := old_seen;
    raise exn
let known_call_names : SSet.t ref = ref SSet.empty
let g_sequence_binder_vars : SSet.t ref = ref SSet.empty
let listn_index_vars : SSet.t ref = ref SSet.empty
let ctor_arg_sort_hints : (string, string list) Hashtbl.t = Hashtbl.create 512
let ctor_arg_membership_sort_hints : (string, string list) Hashtbl.t = Hashtbl.create 512
let ctor_result_sort_hints : (string, SSet.t) Hashtbl.t = Hashtbl.create 512
let ctor_arg_literal_type_dependencies : (string, (int * int) list) Hashtbl.t =
  Hashtbl.create 128

let ctor_decl_arg_sort s =
  if s = "SpectecTerminals" || s = "SpectecTerminal" then s
  else if s = "Nat" || s = "Int" || s = "Bool" then s
  else if ends_with s "Seq" then "SpectecTerminals"
  else "SpectecTerminal"

let register_ctor_arg_sorts ctor sorts =
  let sorts = List.map ctor_decl_arg_sort sorts in
  let merge old fresh =
    if List.length old <> List.length fresh then old
    else
      List.map2
        (fun a b ->
          if a = b then a
          else if a = "SpectecTerminals" || b = "SpectecTerminals" then
            "SpectecTerminals"
          else if a = "SpectecTerminal" || b = "SpectecTerminal" then
            "SpectecTerminal"
          else if ends_with a "Seq" && ends_with b "Seq" then
            "SpectecTerminals"
          else "SpectecTerminal")
        old fresh
  in
  match Hashtbl.find_opt ctor_arg_sort_hints ctor with
  | None -> Hashtbl.replace ctor_arg_sort_hints ctor sorts
  | Some old -> Hashtbl.replace ctor_arg_sort_hints ctor (merge old sorts)

let register_ctor_arg_membership_sorts ctor sorts =
  match Hashtbl.find_opt ctor_arg_membership_sort_hints ctor with
  | None -> Hashtbl.replace ctor_arg_membership_sort_hints ctor sorts
  | Some old ->
      if List.length old <> List.length sorts then ()
      else
        let merged =
          List.map2
            (fun a b -> if a = b then a else "SpectecTerminal")
            old sorts
        in
        Hashtbl.replace ctor_arg_membership_sort_hints ctor merged

let register_ctor_arg_literal_type_dependencies ctor deps =
  if deps <> [] then begin
    let old =
      match Hashtbl.find_opt ctor_arg_literal_type_dependencies ctor with
      | Some deps -> deps
      | None -> []
    in
    Hashtbl.replace ctor_arg_literal_type_dependencies ctor
      (List.sort_uniq compare (old @ deps))
  end

let register_ctor_result_sort ctor sort =
  let old =
    match Hashtbl.find_opt ctor_result_sort_hints ctor with
    | Some sorts -> sorts
    | None -> SSet.empty
  in
  Hashtbl.replace ctor_result_sort_hints ctor (SSet.add sort old)

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
  if not (is_skipped_relation_name rel_name) then
    infer_rel_rules :=
      (rel_name, rules) ::
      List.remove_assoc rel_name !infer_rel_rules

let has_infer_rel_rules rel_name =
  List.mem_assoc (sanitize rel_name) !infer_rel_rules

let find_iter_rel_helper_for_name rel_name =
  let rel_name = sanitize rel_name in
  !iter_rel_helpers
  |> List.find_opt (fun h -> sanitize h.iter_helper_name = rel_name)

let has_infer_rel_source rel_name =
  has_infer_rel_rules rel_name || find_iter_rel_helper_for_name rel_name <> None

let register_infer_rel_helper rel_name arity arg_index =
  if is_skipped_relation_name rel_name then
    failwith (Printf.sprintf "skipped non-execution relation cannot register infer helper: %s" rel_name)
  else
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

let result_rel_helper_name rel_name arg_indices =
  let suffix =
    arg_indices
    |> List.map string_of_int
    |> String.concat "-"
  in
  Printf.sprintf "$result-%s-args%s"
    (String.lowercase_ascii (sanitize rel_name))
    suffix

let otherwise_match_helper_name rel_name case_id =
  Printf.sprintf "$matches-%s-%s"
    (String.lowercase_ascii (sanitize rel_name))
    (String.lowercase_ascii (sanitize case_id))

let register_otherwise_match_helper name pattern =
  let helper = {
    otherwise_match_name = name;
    otherwise_match_pattern = pattern;
  } in
  if not (List.exists (fun h ->
      h.otherwise_match_name = helper.otherwise_match_name
      && h.otherwise_match_pattern = helper.otherwise_match_pattern)
      !otherwise_match_helpers)
  then otherwise_match_helpers := helper :: !otherwise_match_helpers

let register_result_rel_helper rel_name arity arg_indices =
  if is_skipped_relation_name rel_name then
    failwith (Printf.sprintf "skipped non-execution relation cannot register result helper: %s" rel_name)
  else
  let arg_indices = List.sort_uniq compare arg_indices in
  let helper =
    { result_rel_name = sanitize rel_name;
      result_arity = arity;
      result_arg_indices = arg_indices }
  in
  if arg_indices <> []
     && not (List.exists (fun h ->
         h.result_rel_name = helper.result_rel_name
         && h.result_arity = helper.result_arity
         && h.result_arg_indices = helper.result_arg_indices)
         !result_rel_helpers)
  then result_rel_helpers := helper :: !result_rel_helpers;
  result_rel_helper_name rel_name arg_indices

let pluralize_map_suffix s =
  match s with
  | _ when ends_with s "idx" -> s ^ "s"
  | _ when ends_with s "ch" || ends_with s "sh" -> s ^ "es"
  | _ when ends_with s "s" || ends_with s "x" || ends_with s "z" -> s ^ "es"
  | _ when ends_with s "type" -> s ^ "s"
  | _ when ends_with s "y" ->
      String.sub s 0 (String.length s - 1) ^ "ies"
  | _ -> s ^ "s"

let friendly_map_call_helper_name fn arity seq_index =
  let fn = sanitize fn in
  let strip_prefix pfx =
    if starts_with fn pfx then
      Some (String.sub fn (String.length pfx) (String.length fn - String.length pfx))
    else None
  in
  match strip_prefix "$subst-all-" with
  | Some stem when arity = 2 && seq_index = 0 ->
      Some ("$subst-all-" ^ pluralize_map_suffix stem)
  | _ ->
      (match strip_prefix "$subst-" with
       | Some stem when arity = 3 && seq_index = 0 ->
           Some ("$subst-" ^ pluralize_map_suffix stem)
       | _ ->
           (match strip_prefix "$free-" with
            | Some stem when arity = 1 && seq_index = 0 ->
                Some ("$free-" ^ pluralize_map_suffix stem)
            | _ -> None))

let fallback_map_call_helper_name ?(preserve_nested=false) fn arity seq_index =
  let stem =
    fn
    |> String.lowercase_ascii
    |> String.map (function '$' -> 'S' | '-' -> '-' | c -> c)
  in
  Printf.sprintf "$map-%s-a%d-s%d%s" stem arity seq_index
    (if preserve_nested then "-nested" else "")

let map_call_helper_name ?(preserve_nested=false) fn arity seq_index =
  match friendly_map_call_helper_name fn arity seq_index with
  | Some name -> if preserve_nested then name ^ "-nested" else name
  | None -> fallback_map_call_helper_name ~preserve_nested fn arity seq_index

let zip_map_call_helper_name ?(preserve_nested=false) fn arity seq_indices =
  let stem =
    fn
    |> String.lowercase_ascii
    |> String.map (function '$' -> 'S' | '-' -> '-' | c -> c)
  in
  let suffix = seq_indices |> List.map string_of_int |> String.concat "-" in
  Printf.sprintf "$zipmap-%s-a%d-s%s%s" stem arity suffix
    (if preserve_nested then "-nested" else "")

let source_def_arg_sorts_lookup : (string -> string list option) ref =
  ref (fun _ -> None)
let source_var_sort_lookup : (string -> string option) ref = ref (fun _ -> None)

let register_map_call_helper ?(preserve_nested=false) fn arity seq_index arg_sorts =
  let is_sequence_sort sort =
    sort = "SpectecTerminals" || ends_with sort "Seq"
  in
  let canonical_arg_sorts =
    match !source_def_arg_sorts_lookup fn with
    | Some signature_sorts when List.length signature_sorts = arity ->
        arg_sorts
        |> List.mapi (fun i current ->
            if i = seq_index then
              if is_sequence_sort current && current <> "SpectecTerminals" then current
              else
                match List.nth_opt signature_sorts i with
                | Some sort when is_sequence_sort sort -> sort
                | Some sort when sort <> "SpectecTerminal" ->
                    sort ^ "Seq"
                | _ -> current
            else
              match List.nth_opt signature_sorts i with
              | Some sort -> sort
              | None -> current)
    | _ -> arg_sorts
  in
  let same_shape h =
    h.map_fn_name = fn
    && h.map_arity = arity
    && h.map_seq_index = seq_index
    && h.map_preserve_nested = preserve_nested
  in
  let merge_sort a b =
    if a = b then a
    else if a = "SpectecTerminal" then b
    else if b = "SpectecTerminal" then a
    else if a = "SpectecTerminals" then b
    else if b = "SpectecTerminals" then a
    else if ends_with a "Seq" && ends_with b "Seq" then "SpectecTerminals"
    else "SpectecTerminal"
  in
  match List.find_opt same_shape !map_call_helpers with
  | Some old ->
      let merged_sorts =
        try List.map2 merge_sort old.map_arg_sorts canonical_arg_sorts
        with Invalid_argument _ -> old.map_arg_sorts
      in
      if merged_sorts <> old.map_arg_sorts then begin
        let widened = { old with map_arg_sorts = merged_sorts } in
        map_call_helpers :=
          widened :: List.filter (fun h -> not (same_shape h)) !map_call_helpers
      end;
      old.map_helper_name
  | None ->
  let helper = {
    map_helper_name = map_call_helper_name ~preserve_nested fn arity seq_index;
    map_fn_name = fn;
    map_arity = arity;
    map_seq_index = seq_index;
    map_arg_sorts = canonical_arg_sorts;
    map_preserve_nested = preserve_nested;
  } in
  map_call_helpers := helper :: !map_call_helpers;
  helper.map_helper_name

let register_zip_map_call_helper ?(preserve_nested=false) fn arity seq_indices arg_sorts =
  let seq_indices = List.sort_uniq compare seq_indices in
  let same_shape h =
    h.zip_map_fn_name = fn
    && h.zip_map_arity = arity
    && h.zip_map_seq_indices = seq_indices
    && h.zip_map_preserve_nested = preserve_nested
  in
  let merge_sort a b =
    if a = b then a
    else if a = "SpectecTerminal" then b
    else if b = "SpectecTerminal" then a
    else if a = "SpectecTerminals" || b = "SpectecTerminals" then "SpectecTerminals"
    else if ends_with a "Seq" && ends_with b "Seq" then "SpectecTerminals"
    else "SpectecTerminal"
  in
  match List.find_opt same_shape !zip_map_call_helpers with
  | Some old ->
      let merged_sorts =
        try List.map2 merge_sort old.zip_map_arg_sorts arg_sorts
        with Invalid_argument _ -> old.zip_map_arg_sorts
      in
      if merged_sorts <> old.zip_map_arg_sorts then begin
        let widened = { old with zip_map_arg_sorts = merged_sorts } in
        zip_map_call_helpers :=
          widened :: List.filter (fun h -> not (same_shape h)) !zip_map_call_helpers
      end;
      old.zip_map_helper_name
  | None ->
      let helper = {
        zip_map_helper_name =
          zip_map_call_helper_name ~preserve_nested fn arity seq_indices;
        zip_map_fn_name = fn;
        zip_map_arity = arity;
        zip_map_seq_indices = seq_indices;
        zip_map_arg_sorts = arg_sorts;
        zip_map_preserve_nested = preserve_nested;
      } in
      zip_map_call_helpers := helper :: !zip_map_call_helpers;
      helper.zip_map_helper_name

let friendly_expr_map_helper_name body seq_vars fixed_vars =
  match seq_vars, fixed_vars, parse_call_text body with
  | [seq_var], [], Some (ctor, [arg])
      when is_source_ctor_name ctor
           && (strip_wrapping_parens arg |> String.trim) = seq_var ->
      Some
        (Printf.sprintf "$map-%s-a1-s0"
           (String.lowercase_ascii (sanitize ctor)))
  | _ -> None

let expr_map_helper_name body seq_vars fixed_vars =
  match friendly_expr_map_helper_name body seq_vars fixed_vars with
  | Some name -> name
  | None ->
  let key =
    body ^ "\x1f" ^ String.concat "," seq_vars ^ "\x1f"
    ^ (fixed_vars
       |> List.map (fun (v, s) -> v ^ ":" ^ s)
       |> String.concat ",")
  in
  "$mapexpr-" ^ String.sub (Digest.to_hex (Digest.string key)) 0 12

let register_expr_map_helper body seq_vars fixed_vars =
  let seq_vars = List.sort_uniq String.compare seq_vars in
  let fixed_vars =
    fixed_vars
    |> List.sort_uniq (fun (a, _) (b, _) -> String.compare a b)
  in
  match
    List.find_opt
      (fun h ->
        h.expr_map_body = body
        && h.expr_map_seq_vars = seq_vars
        && h.expr_map_fixed_vars = fixed_vars)
      !expr_map_helpers
  with
  | Some h -> h.expr_map_helper_name
  | None ->
      let helper =
        {
          expr_map_helper_name =
            expr_map_helper_name body seq_vars fixed_vars;
          expr_map_body = body;
          expr_map_seq_vars = seq_vars;
          expr_map_fixed_vars = fixed_vars;
        }
      in
      expr_map_helpers := helper :: !expr_map_helpers;
      helper.expr_map_helper_name

let unmap_call_helper_name map_helper_name =
  if starts_with map_helper_name "$map-" then
    "$unmap-" ^ String.sub map_helper_name 5 (String.length map_helper_name - 5)
  else if starts_with map_helper_name "$mapexpr-" then
    "$unmap-" ^ String.sub map_helper_name 1 (String.length map_helper_name - 1)
  else
    map_helper_name ^ "-unmap"

let expr_map_tuple_helper_name map_helper_name =
  let stem =
    if String.length map_helper_name > 0 && map_helper_name.[0] = '$'
    then String.sub map_helper_name 1 (String.length map_helper_name - 1)
    else map_helper_name
  in
  "$tuple-" ^ stem

let expr_map_tuple_body_order h =
  if h.expr_map_fixed_vars <> [] then None
  else
    let tokens =
      h.expr_map_body
      |> strip_wrapping_parens
      |> String.trim
      |> Str.split (Str.regexp "[ \t\r\n]+")
    in
    let seq_vars = h.expr_map_seq_vars in
    if List.length tokens <= 1 || List.length tokens <> List.length seq_vars then None
    else if List.sort_uniq String.compare tokens
            <> List.sort_uniq String.compare seq_vars
    then None
    else Some tokens

let literal_family_roots : SSet.t ref = ref SSet.empty

type literal_family_info = {
  literal_family_raw : string;
  literal_family_sort : string;
  literal_family_nullary_prefix : string;
  literal_family_concrete_prefix : string;
}

let literal_family_infos : (string, literal_family_info) Hashtbl.t =
  Hashtbl.create 16

let source_ground_int_call_values : (string, string) Hashtbl.t =
  Hashtbl.create 128

let source_unary_int_functions : SSet.t ref = ref SSet.empty

type source_unary_int_alias = {
  source_alias_fn : string;
  source_alias_arg_sort : string;
  source_alias_target_fn : string;
}

let source_unary_int_aliases : source_unary_int_alias list ref = ref []

let is_literal_family_root sort = SSet.mem sort !literal_family_roots

let source_ground_int_key fn arg =
  fn ^ "\x1f" ^ (strip_wrapping_parens arg |> String.trim)

let register_source_ground_int_value fn arg value =
  Hashtbl.replace source_ground_int_call_values
    (source_ground_int_key fn arg)
    value

let find_source_ground_int_value fn arg =
  Hashtbl.find_opt source_ground_int_call_values
    (source_ground_int_key fn arg)

let maude_builtin_sort_names =
  SSet.of_list ["Char"; "Zero"; "NzNat"; "Nat"; "Int"; "Bool"]

let source_sort_name_overrides : (string, string) Hashtbl.t = Hashtbl.create 32

let source_sort_base_name raw =
  let s = sanitize raw in
  if String.length s >= 2 && String.sub s 0 2 = "w-" then "SpectecTerminal"
  else
    let hyphen_to_under = String.map (fun c -> if c = '-' then '_' else c) s in
    (* Maude sort names must start with uppercase *)
    if String.length hyphen_to_under > 0
       && hyphen_to_under.[0] >= 'a' && hyphen_to_under.[0] <= 'z'
    then String.capitalize_ascii hyphen_to_under
    else hyphen_to_under

let sort_of_type_name raw =
  match Hashtbl.find_opt source_sort_name_overrides raw with
  | Some override -> override
  | None -> source_sort_base_name raw

let pre_elab_source_category_edges : (string * string) list ref = ref []
let pre_elab_meta_numeric_aliases : (string * string) list ref = ref []
let source_meta_numeric_alias_carriers : (string, string) Hashtbl.t =
  Hashtbl.create 32

let meta_numeric_carrier_sort sort =
  Hashtbl.find_opt source_meta_numeric_alias_carriers sort

let is_meta_numeric_alias_sort sort =
  Hashtbl.mem source_meta_numeric_alias_carriers sort

let is_pure_meta_category_sort sort =
  is_meta_numeric_alias_sort sort

let semantic_sort_of_source_sort sort =
  match meta_numeric_carrier_sort sort with
  | Some carrier -> carrier
  | None -> sort

let raw_source_name_of_type_var v =
  let base =
    let re = Str.regexp "^\\([A-Za-z]+\\)[0-9]+$" in
    if Str.string_match re v 0 then
      match str_matched_group_opt 1 v with
      | Some s -> s
      | None -> v
    else v
  in
  let lower = String.lowercase_ascii base in
  if ends_with lower "type" then lower
  else String.capitalize_ascii lower

let decl_sort_of_type_term_var v =
  let source_sort = sort_of_type_name (raw_source_name_of_type_var v) in
  match meta_numeric_carrier_sort source_sort with
  | Some carrier -> carrier
  | None -> "SpectecTerminal"

let set_pre_elab_source_category_edges (defs : El.Ast.script) =
  let module E = El.Ast in
  let collect_type_names acc (d : E.def) =
    match d.it with
    | E.FamD (id, _params, _hints) ->
        SSet.add id.it acc
    | E.TypD (id, _frag, _args, _typ, _hints) ->
        SSet.add id.it acc
    | _ -> acc
  in
  let type_names = List.fold_left collect_type_names SSet.empty defs in
  let nl_items xs =
    xs
    |> List.filter_map (function
         | E.Elem x -> Some x
         | E.Nl -> None)
  in
  let nl_empty xs = nl_items xs = [] in
  let rec direct_category_ref (t : E.typ) =
    match t.it with
    | E.VarT (id, []) when SSet.mem id.it type_names -> Some id.it
    | E.ParenT inner -> direct_category_ref inner
    | E.ConT ((inner, prems), _hints) when nl_empty prems ->
        direct_category_ref inner
    | E.TupT [inner] -> direct_category_ref inner
    | _ -> None
  in
  let refs_in_rhs (t : E.typ) =
    match t.it with
    | E.CaseT (_dots1, typ_alts, _typcases, _dots2) ->
        typ_alts |> nl_items |> List.filter_map direct_category_ref
    | _ ->
        (match direct_category_ref t with
         | Some raw -> [raw]
         | None -> [])
  in
  let collect_edges acc (d : E.def) =
    match d.it with
    | E.TypD (parent, _frag, _args, rhs, _hints) ->
        refs_in_rhs rhs
        |> List.fold_left
             (fun acc child ->
                if child = parent.it then acc else (child, parent.it) :: acc)
             acc
    | _ -> acc
  in
  let hint_is_macro_none (hint : E.hint) =
    String.lowercase_ascii hint.hintid.it = "macro"
    &&
    match hint.hintexp.it with
    | E.VarE (id, []) -> String.lowercase_ascii id.it = "none"
    | E.TextE text -> String.lowercase_ascii text = "none"
    | E.AtomE atom -> String.lowercase_ascii (Xl.Atom.name atom) = "none"
    | _ -> String.lowercase_ascii (El.Print.string_of_exp hint.hintexp) = "none"
  in
  let rec builtin_numeric_alias_rhs (t : E.typ) =
    match t.it with
    | E.NumT `NatT -> Some "Nat"
    | E.NumT `IntT -> Some "Int"
    | E.ParenT inner -> builtin_numeric_alias_rhs inner
    | E.ConT ((inner, prems), _hints) when nl_empty prems ->
        builtin_numeric_alias_rhs inner
    | _ -> None
  in
  let collect_meta_aliases acc (d : E.def) =
    match d.it with
    | E.TypD (id, _frag, _args, rhs, hints)
        when List.exists hint_is_macro_none hints ->
        (match builtin_numeric_alias_rhs rhs with
         | Some carrier -> (id.it, carrier) :: acc
         | None -> acc)
    | _ -> acc
  in
  pre_elab_source_category_edges :=
    defs
    |> List.fold_left collect_edges []
    |> List.sort_uniq compare;
  pre_elab_meta_numeric_aliases :=
    defs
    |> List.fold_left collect_meta_aliases []
    |> List.sort_uniq compare

let rec simple_sort_of_typ (t : typ) vm : string option =
  match t.it with
  | VarT (id, args) ->
      let resolved = match List.assoc_opt id.it vm with
        | Some mapped when mapped <> String.uppercase_ascii mapped -> mapped
        | _ -> sanitize id.it
      in
      let source_sort = sort_of_type_name resolved in
      if is_meta_numeric_alias_sort source_sort then Some source_sort
      else if is_upper_token resolved then None
      else if String.lowercase_ascii id.it = "list" && args <> [] then None
      else Some source_sort
  | IterT (_, (List | List1 | ListN _)) -> None
  | IterT (inner, Opt) -> simple_sort_of_typ inner vm
  | NumT `NatT -> Some "Nat"
  | NumT `IntT -> Some "Int"
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

let maude_symbol_component s =
  let s = sanitize s in
  let s =
    if String.length s > 0 && s.[0] = '$'
    then String.sub s 1 (String.length s - 1)
    else s
  in
  let s =
    String.map
      (fun c ->
        if (c >= 'A' && c <= 'Z')
           || (c >= 'a' && c <= 'z')
           || (c >= '0' && c <= '9')
        then c
        else '-')
      s
  in
  let s = String.trim s in
  if s = "" then "def" else s

let def_tag_name fn =
  "$def-" ^ String.lowercase_ascii (maude_symbol_component fn)

let def_apply_name owner_fn param_raw =
  "$apply-" ^ String.lowercase_ascii (maude_symbol_component owner_fn)
  ^ "-" ^ String.lowercase_ascii (maude_symbol_component param_raw)

let def_param_var_component raw =
  maude_symbol_component raw |> String.uppercase_ascii

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
let sequence_alias_elem_sorts : (string, string) Hashtbl.t = Hashtbl.create 32
let flat_sequence_source_sorts : SSet.t ref = ref SSet.empty
let simple_alias_source_sorts : SSet.t ref = ref SSet.empty
let source_membership_sorts : SSet.t ref = ref SSet.empty
let nat_subsort_sorts : SSet.t ref = ref SSet.empty
let int_subsort_sorts : SSet.t ref = ref SSet.empty

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
let source_sort_type_atoms_by_arity : (string, string) Hashtbl.t = Hashtbl.create 128
let source_type_atom_arities : (string, int) Hashtbl.t = Hashtbl.create 128
let source_var_sorts : (string, string) Hashtbl.t = Hashtbl.create 512
let source_var_seq_elem_sorts : (string, string) Hashtbl.t = Hashtbl.create 512
let source_var_optional_elem_sorts : (string, string) Hashtbl.t = Hashtbl.create 256

let source_record_field_name_exists name =
  !source_record_infos
  |> List.exists (fun info -> List.mem name info.rec_fields)

let source_protected_nonvariable_token name =
  is_source_ctor_var_token name
  || is_source_ctor_name name
  || source_record_field_name_exists name
let source_def_arg_sorts : (string, string list) Hashtbl.t = Hashtbl.create 256
let source_def_arg_wrap_sorts : (string, string list) Hashtbl.t = Hashtbl.create 256
let source_def_arg_sequence_depths : (string, int list) Hashtbl.t =
  Hashtbl.create 256
let source_def_return_sorts : (string, string) Hashtbl.t = Hashtbl.create 256
let source_def_return_optionals : (string, bool) Hashtbl.t = Hashtbl.create 256
type source_def_param_info = {
  def_param_position : int;
  def_param_apply_name : string;
  def_param_arg_sorts : string list;
  def_param_return_sort : string;
}
let source_def_param_infos : (string, source_def_param_info list) Hashtbl.t =
  Hashtbl.create 128

let sort_is_sequence_carrier sort =
  sort = "SpectecTerminals" || ends_with sort "Seq"

let source_def_returns_sequence fn =
  match Hashtbl.find_opt source_def_return_sorts fn with
  | Some sort -> sort_is_sequence_carrier sort
  | None -> false

let source_def_returns_optional fn =
  match Hashtbl.find_opt source_def_return_optionals fn with
  | Some optional -> optional
  | None -> false

let preserve_nested_sequence_iters : bool ref = ref false

let with_preserve_nested_sequence_iters preserve f =
  let old = !preserve_nested_sequence_iters in
  preserve_nested_sequence_iters := preserve;
  Fun.protect f ~finally:(fun () -> preserve_nested_sequence_iters := old)

let preserve_nested_sequence_call preserve fn call =
  if preserve && source_def_returns_sequence fn then
    Printf.sprintf "$seq ( %s )" call
  else call
let source_typ_param_positions : (string, int list) Hashtbl.t = Hashtbl.create 64
let () =
  source_var_sort_lookup :=
    (fun var -> Hashtbl.find_opt source_var_sorts var);
  source_def_arg_sorts_lookup :=
    (fun fn -> Hashtbl.find_opt source_def_arg_sorts fn)
let typed_index_helper_sorts : SSet.t ref = ref SSet.empty
let used_unmap_helper_names : SSet.t ref = ref SSet.empty
let mark_unmap_helper_used name =
  used_unmap_helper_names := SSet.add name !used_unmap_helper_names
let unmap_helper_is_used name =
  SSet.mem name !used_unmap_helper_names
let source_seq_pred_sorts : SSet.t ref = ref SSet.empty
let source_category_subsort_edges : (string, SSet.t) Hashtbl.t = Hashtbl.create 128
let source_conditional_alias_edges : (string, SSet.t) Hashtbl.t = Hashtbl.create 64
let source_alias_subsort_edges : (string, SSet.t) Hashtbl.t = Hashtbl.create 64

let record_source_alias_subsort child parent =
  if child <> parent then
    let old =
      match Hashtbl.find_opt source_alias_subsort_edges child with
      | Some parents -> parents
      | None -> SSet.empty
    in
    Hashtbl.replace source_alias_subsort_edges child (SSet.add parent old)

let source_alias_subsort_edge child parent =
  match Hashtbl.find_opt source_alias_subsort_edges child with
  | Some parents -> SSet.mem parent parents
  | None -> false
let native_sequence_source_sorts : SSet.t ref = ref SSet.empty
let source_nullary_terms_by_sort : (string, SSet.t) Hashtbl.t = Hashtbl.create 128
let generated_zero_arity_ctor_names : SSet.t ref = ref SSet.empty
let literal_family_parent_sorts : SSet.t ref = ref SSet.empty
let literal_family_alias_edges : (string, SSet.t) Hashtbl.t = Hashtbl.create 16
let specialized_syntax_sort_decls : SSet.t ref = ref SSet.empty
let specialized_syntax_sort_names : SSet.t ref = ref SSet.empty
let specialized_syntax_sort_type_terms : (string, string) Hashtbl.t =
  Hashtbl.create 256
let def_apply_op_decls : SSet.t ref = ref SSet.empty
let def_apply_dispatches : SSet.t ref = ref SSet.empty
let def_tag_decls : SSet.t ref = ref SSet.empty
let literal_wrapper_syntax_decls : SSet.t ref = ref SSet.empty
let literal_wrapper_memberships : SSet.t ref = ref SSet.empty
let literal_wrapper_payload_sorts : (string, string) Hashtbl.t = Hashtbl.create 16
let literal_wrapper_by_type_term : (string, string) Hashtbl.t = Hashtbl.create 16
let source_literal_wrapper_by_sort : (string, string) Hashtbl.t = Hashtbl.create 32
let spectec_type_prefix = "syn-"

let raw_payload_type_terms : SSet.t ref =
  ref (SSet.of_list [spectec_type_prefix ^ "nat"; spectec_type_prefix ^ "int"])

let jhs_type_term_key text =
  strip_wrapping_parens text |> String.trim

let spectec_type_constructor_head raw arity =
  let base = sanitize raw |> trim_tail_hyphen in
  let _ = arity in
  spectec_type_prefix ^ base

let source_name_of_spectec_type_head head =
  if starts_with head spectec_type_prefix then
    String.sub head (String.length spectec_type_prefix)
      (String.length head - String.length spectec_type_prefix)
  else head

let ensure_spectec_type_term text =
  let t = strip_wrapping_parens text |> String.trim in
  let len = String.length t in
  if t = "" || starts_with t spectec_type_prefix then t
  else
    let rec head_end i =
      if i >= len then len
      else match t.[i] with
      | ' ' | '\t' | '\n' | '\r' | '(' -> i
      | _ -> head_end (i + 1)
    in
    let i = head_end 0 in
    if i = 0 then t
    else
      let head = String.sub t 0 i in
      spectec_type_prefix ^ head ^ String.sub t i (len - i)

let source_sort_type_atom_arity_key source_sort arity =
  source_sort ^ "#" ^ string_of_int arity

let register_source_sort_type_atom source_sort atom arity =
  Hashtbl.replace source_type_atom_arities atom arity;
  Hashtbl.replace source_sort_type_atoms_by_arity
    (source_sort_type_atom_arity_key source_sort arity)
    atom;
  if arity = 0 || not (Hashtbl.mem source_sort_type_atoms source_sort) then
    Hashtbl.replace source_sort_type_atoms source_sort atom

let source_sort_type_atom_for_arity source_sort arity =
  match Hashtbl.find_opt source_sort_type_atoms_by_arity
          (source_sort_type_atom_arity_key source_sort arity) with
  | Some atom -> Some atom
  | None when arity = 0 -> Hashtbl.find_opt source_sort_type_atoms source_sort
  | None -> None

let format_spectec_type_term head args =
  match args with
  | [] -> head
  | _ -> Printf.sprintf "%s(%s)" head (String.concat ", " args)

let spectec_type_term_of_name raw arg_texts =
  let head = spectec_type_constructor_head raw (List.length arg_texts) in
  format_spectec_type_term head arg_texts

let record_raw_payload_type_alias lhs rhs =
  let lhs = jhs_type_term_key lhs in
  let rhs = jhs_type_term_key rhs in
  if lhs <> "" && SSet.mem rhs !raw_payload_type_terms then
    raw_payload_type_terms := SSet.add lhs !raw_payload_type_terms
let wrap_generic_const_payloads : bool ref = ref false

let source_type_atom_tokens () =
  Hashtbl.fold
    (fun _ atom acc -> SSet.add atom acc)
    source_sort_type_atoms SSet.empty

let with_generic_const_payload_wrapping f =
  let old = !wrap_generic_const_payloads in
  wrap_generic_const_payloads := true;
  Fun.protect f ~finally:(fun () -> wrap_generic_const_payloads := old)

let record_shape_key fields = String.concat "\x1f" fields

let source_record_ctor_name sort arity =
  Printf.sprintf "REC%sA%d" sort arity

let native_sequence_sort_name sort =
  sort ^ "Seq"

let sequence_nil_name seq_sort =
  "eps" ^ seq_sort

let sequence_cons_name seq_sort =
  "cons" ^ seq_sort

let sequence_single_name seq_sort =
  "one" ^ seq_sort

let sequence_concat_name seq_sort =
  "_++" ^ seq_sort ^ "_"

let sequence_sort_of_concat_name name =
  if starts_with name "_++" && ends_with name "_" && String.length name > 4 then
    let seq_sort = String.sub name 3 (String.length name - 4) in
    if ends_with seq_sort "Seq" then Some seq_sort else None
  else None

let register_native_sequence_sort sort =
  if sort <> ""
     && sort <> "SpectecTerminal"
     && sort <> "SpectecTerminals"
     && not (List.mem sort ["Bool"; "Nat"; "Int"; "Char"; "Zero"; "NzNat"])
  then
    native_sequence_source_sorts :=
      SSet.add sort !native_sequence_source_sorts

let sequence_sort_of_elem_sort sort =
  if sort <> ""
     && sort <> "SpectecTerminal"
     && sort <> "SpectecTerminals"
     && not (List.mem sort ["Bool"; "Nat"; "Int"; "Char"; "Zero"; "NzNat"])
  then begin
    register_native_sequence_sort sort;
    Some (native_sequence_sort_name sort)
  end else None

let source_record_empty_const_name source_name =
  "$empty-" ^ String.lowercase_ascii (sanitize source_name)

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

let source_record_by_sort_and_fields sort fields =
  List.find_opt
    (fun info -> info.rec_sort = sort && info.rec_fields = fields)
    !source_record_infos

let rec source_record_empty_term_for_sort seen sort =
  if sort = "SpectecTerminals" then Some "eps"
  else if List.mem sort seen then None
  else
    match List.find_opt (fun info -> info.rec_sort = sort) !source_record_infos with
    | None -> None
    | Some info ->
        let seen = sort :: seen in
        let field_term field =
          match Hashtbl.find_opt source_record_field_sorts
                  (source_record_field_key info.rec_sort field) with
          | Some "SpectecTerminals" -> Some "eps"
          | Some field_sort -> source_record_empty_term_for_sort seen field_sort
          | None -> None
        in
        let terms = List.map field_term info.rec_fields in
        if List.for_all Option.is_some terms then
          Some (source_record_empty_const_name info.rec_source_name)
        else None

let source_record_empty_terms info =
  let field_term field =
    match Hashtbl.find_opt source_record_field_sorts
            (source_record_field_key info.rec_sort field) with
    | Some "SpectecTerminals" -> Some "eps"
    | Some field_sort -> source_record_empty_term_for_sort [info.rec_sort] field_sort
    | None -> None
  in
  let terms = List.map field_term info.rec_fields in
  if List.for_all Option.is_some terms then
    Some (List.map Option.get terms)
  else None

let rec source_type_term_of_typ_simple (t : typ) : string option =
  match t.it with
  | VarT (id, []) -> Some (spectec_type_term_of_name id.it [])
  | VarT (id, args) when String.lowercase_ascii id.it = "list" ->
      args
      |> List.find_map (fun arg ->
           match arg.it with
           | TypA inner -> source_type_term_of_typ_simple inner
           | _ -> None)
  | IterT (inner, (List | List1 | ListN _)) ->
      source_type_term_of_typ_simple inner
  | IterT (inner, Opt) -> source_type_term_of_typ_simple inner
  | _ -> None

let rec typ_ref_sort (t : typ) : string option =
  match t.it with
  | VarT (id, []) -> Some (sort_of_type_name id.it)
  | TupT [(_, inner)] -> typ_ref_sort inner
  | IterT (inner, Opt) -> typ_ref_sort inner
  | _ -> None

let rec sequence_sort_of_typ (t : typ) vm : string option =
  match t.it with
  | IterT (inner, (List | List1 | ListN _)) ->
      sequence_sort_of_inner_typ inner vm
  | IterT (inner, Opt) ->
      sequence_sort_of_inner_typ inner vm
  | VarT (id, args) when String.lowercase_ascii id.it = "list" && args <> [] ->
      args |> List.find_map (fun a -> sequence_sort_of_arg a vm)
  | VarT (id, []) ->
      let alias_sort = sort_of_type_name id.it in
      (match Hashtbl.find_opt sequence_alias_elem_sorts alias_sort with
       | Some elem_sort -> sequence_sort_of_elem_sort elem_sort
       | None -> None)
  | TupT [(_, inner)] -> sequence_sort_of_typ inner vm
  | _ -> None

and sequence_sort_of_inner_typ (inner : typ) vm : string option =
  match inner.it with
  | IterT (inner', Opt) -> sequence_sort_of_inner_typ inner' vm
  | _ ->
      (match simple_sort_of_typ inner vm with
       | Some elem_sort -> sequence_sort_of_elem_sort elem_sort
       | None -> sequence_sort_of_typ inner vm)

and sequence_sort_of_arg (a : arg) vm : string option =
  match a.it with
  | TypA t -> sequence_sort_of_inner_typ t vm
  | ExpA {it = VarE id; _} ->
      sequence_sort_of_elem_sort (sort_of_type_name id.it)
  | _ -> None

let optional_empty_term_for_typ (t : typ) vm =
  match sequence_sort_of_typ t vm with
  | Some _seq_sort -> "eps"
  | None -> "eps"

let rec semantic_result_sort_of_typ (t : typ) vm =
  match sequence_sort_of_typ t vm with
  | Some seq_sort -> Some seq_sort
  | None ->
      (match t.it with
       | IterT (inner, Opt) -> semantic_result_sort_of_typ inner vm
       | TupT _ -> None
       | _ ->
           match simple_sort_of_typ t vm with
           | Some sort -> Some sort
           | None -> None)

let typ_is_optional_result (t : typ) =
  match t.it with
  | IterT (_, Opt) -> true
  | _ -> false

let build_type_env defs =
  Hashtbl.reset plural_types;
  Hashtbl.reset source_sort_name_overrides;
  Hashtbl.reset source_meta_numeric_alias_carriers;
  Hashtbl.reset source_record_shape_counts;
  Hashtbl.reset source_category_subsort_edges;
  Hashtbl.reset source_conditional_alias_edges;
  Hashtbl.reset source_alias_subsort_edges;
  source_compound_cases := [];
  Hashtbl.reset sequence_alias_type_terms;
  Hashtbl.reset sequence_alias_elem_sorts;
  Hashtbl.reset source_record_field_sorts;
  Hashtbl.reset source_record_field_seq_elem_sorts;
  Hashtbl.reset source_sort_type_atoms;
  Hashtbl.reset source_sort_type_atoms_by_arity;
  Hashtbl.reset source_type_atom_arities;
  Hashtbl.reset source_nullary_terms_by_sort;
  Hashtbl.reset literal_family_alias_edges;
  Hashtbl.reset literal_family_infos;
  Hashtbl.reset source_ground_int_call_values;
  Hashtbl.reset source_var_sorts;
  Hashtbl.reset source_var_seq_elem_sorts;
  Hashtbl.reset source_var_optional_elem_sorts;
  Hashtbl.reset source_def_arg_sorts;
  Hashtbl.reset source_def_arg_wrap_sorts;
  Hashtbl.reset source_def_arg_sequence_depths;
  Hashtbl.reset source_def_return_sorts;
  Hashtbl.reset source_def_return_optionals;
  Hashtbl.reset source_def_param_infos;
  Hashtbl.reset source_typ_param_positions;
  zero_arity_source_sorts := SSet.empty;
  sequence_alias_sorts := SSet.empty;
  flat_sequence_source_sorts := SSet.empty;
  simple_alias_source_sorts := SSet.empty;
  source_membership_sorts := SSet.empty;
  nat_subsort_sorts := SSet.empty;
  int_subsort_sorts := SSet.empty;
  native_sequence_source_sorts := SSet.empty;
  literal_family_parent_sorts := SSet.empty;
  literal_family_roots := SSet.empty;
  source_unary_int_functions := SSet.empty;
  source_unary_int_aliases := [];
  optional_literal_terms := SSet.empty;
  source_record_infos := [];
  typed_index_helper_sorts := SSet.empty;
  used_unmap_helper_names := SSet.empty;
  let rec collect_source_sort_name_overrides d =
    match d.it with
    | RecD ds -> List.iter collect_source_sort_name_overrides ds
    | TypD (id, _params, _insts) ->
        let base = source_sort_base_name id.it in
        if SSet.mem base maude_builtin_sort_names then
          Hashtbl.replace source_sort_name_overrides id.it ("Source" ^ base)
    | _ -> ()
  in
  List.iter collect_source_sort_name_overrides defs;
  List.iter
    (fun (raw, carrier) ->
       Hashtbl.replace source_meta_numeric_alias_carriers
         (sort_of_type_name raw) carrier)
    !pre_elab_meta_numeric_aliases;
  let rec scan d = match d.it with
    | RecD ds -> List.iter scan ds
    | TypD (id, params, insts) ->
        let arity = List.length params in
        let atom = spectec_type_constructor_head id.it arity in
        let source_sort = sort_of_type_name id.it in
        register_source_sort_type_atom source_sort atom arity;
        List.iter (fun inst -> match inst.it with
          | InstD (_, _, deftyp) -> (match deftyp.it with
              | AliasT typ -> (match typ.it with
                  | TupT (_ :: _ :: _) ->
                      let alias_sort = sort_of_type_name id.it in
                      flat_sequence_source_sorts :=
                        SSet.add alias_sort !flat_sequence_source_sorts
                  | TupT _ -> ()
	                  | IterT (_, (List | List1 | ListN _)) ->
                      let alias_sort = sort_of_type_name id.it in
	                      Hashtbl.replace plural_types id.it true;
	                      sequence_alias_sorts :=
	                        SSet.add alias_sort !sequence_alias_sorts;
                      (match source_type_term_of_typ_simple typ with
                       | Some ty -> Hashtbl.replace sequence_alias_type_terms alias_sort ty
                       | None -> ());
                      (match sequence_sort_of_typ typ [] with
                       | Some seq_sort when ends_with seq_sort "Seq" ->
                           let elem_sort =
                             String.sub seq_sort 0 (String.length seq_sort - 3)
                           in
                           Hashtbl.replace sequence_alias_elem_sorts alias_sort elem_sort
                       | _ -> ())
	                  | VarT (tid, args)
	                    when String.lowercase_ascii tid.it = "list" && args <> [] ->
                      let alias_sort = sort_of_type_name id.it in
	                      Hashtbl.replace plural_types id.it true;
	                      sequence_alias_sorts :=
	                        SSet.add alias_sort !sequence_alias_sorts;
                      (match source_type_term_of_typ_simple typ with
                       | Some ty -> Hashtbl.replace sequence_alias_type_terms alias_sort ty
                       | None -> ());
                      (match sequence_sort_of_typ typ [] with
                       | Some seq_sort when ends_with seq_sort "Seq" ->
                           let elem_sort =
                             String.sub seq_sort 0 (String.length seq_sort - 3)
                           in
                           Hashtbl.replace sequence_alias_elem_sorts alias_sort elem_sort
                       | _ -> ())
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
    | DecD (id, params, _result_typ, _insts) ->
        let positions =
          params
          |> List.mapi (fun i p -> match p.it with TypP _ -> Some i | _ -> None)
          |> List.filter_map (fun x -> x)
        in
        if positions <> [] then
          Hashtbl.replace source_typ_param_positions (call_name id.it) positions
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
  let rec raw_payload_key_of_typ t =
    match t.it with
    | NumT `NatT -> Some (spectec_type_term_of_name "nat" [])
    | NumT `IntT -> Some (spectec_type_term_of_name "int" [])
    | VarT (id, []) -> Some (spectec_type_term_of_name id.it [])
    | IterT (inner, Opt) -> raw_payload_key_of_typ inner
    | _ -> None
  in
  let collect_raw_payload_aliases () =
    let changed = ref true in
    while !changed do
      changed := false;
      List.iter
        (fun (_sort, raw, params, insts) ->
          if params = [] then
            List.iter
              (fun inst ->
                match inst.it with
                | InstD (binders, args, { it = AliasT typ; _ })
                    when binders = [] && args = [] ->
                    (match raw_payload_key_of_typ typ with
                     | Some rhs
                         when SSet.mem (jhs_type_term_key rhs) !raw_payload_type_terms ->
                         let before = !raw_payload_type_terms in
                         record_raw_payload_type_alias (sanitize raw) rhs;
                         if not (SSet.equal before !raw_payload_type_terms) then
                           changed := true
                     | _ -> ())
                | _ -> ())
              insts)
        typ_defs
    done
  in
  collect_raw_payload_aliases ();
  let literal_family_candidate raw params =
    params <> []
    &&
    let s = sanitize raw in
    ends_with s "N"
    && String.exists (fun c -> c >= 'a' && c <= 'z') s
  in
  let concrete_prefix_of_family_sort sort =
    if ends_with sort "N" && String.length sort > 1 then
      let stem = String.sub sort 0 (String.length sort - 1) in
      (* If the family has its own non-conflicting concrete aliases, prefer
         their compact prefix (uN -> U32, sN -> S33).  Families whose compact
         prefix collides with source type names keep the family prefix
         (iN -> IN32, fN -> FN32, vN -> VN128). *)
      if stem = "U" || stem = "S" then stem else sort
    else sort
  in
  let nullary_prefix_of_family_raw raw sort =
    let s = sanitize raw in
    match String.index_opt s 'N' with
    | Some idx when idx > 0 ->
        String.sub s 0 idx |> String.uppercase_ascii
    | _ -> concrete_prefix_of_family_sort sort
  in
  typ_defs
  |> List.iter (fun (sort, raw, params, _insts) ->
      if literal_family_candidate raw params then begin
        let info = {
          literal_family_raw = raw;
          literal_family_sort = sort;
          literal_family_nullary_prefix = nullary_prefix_of_family_raw raw sort;
          literal_family_concrete_prefix = concrete_prefix_of_family_sort sort;
        } in
        Hashtbl.replace literal_family_infos sort info;
        literal_family_roots := SSet.add sort !literal_family_roots
      end);
  let rec typ_is_nat_carrier t =
    match t.it with
    | VarT (id, _) ->
        let raw = String.lowercase_ascii id.it in
        raw = "nat"
    | IterT (inner, Opt) -> typ_is_nat_carrier inner
    | NumT `NatT -> true
    | _ -> false
  in
  let inst_is_nat_alias inst =
    match inst.it with
    | InstD (binders, args, deftyp) ->
        binders = [] && args = [] &&
        (match deftyp.it with
         | AliasT typ -> typ_is_nat_carrier typ
         | _ -> false)
  in
  nat_subsort_sorts :=
    typ_defs
    |> List.fold_left (fun acc (sort, _raw, params, insts) ->
         if params = [] && insts <> [] && List.for_all inst_is_nat_alias insts
         then SSet.add sort acc
         else acc)
       SSet.empty
    |> SSet.remove "Nat";
  let rec typ_is_int_carrier t =
    match t.it with
    | VarT (id, _) ->
        let raw = String.lowercase_ascii id.it in
        raw = "int"
    | IterT (inner, Opt) -> typ_is_int_carrier inner
    | NumT `IntT -> true
    | _ -> false
  in
  let inst_is_int_alias inst =
    match inst.it with
    | InstD (binders, args, deftyp) ->
        binders = [] && args = [] &&
        (match deftyp.it with
         | AliasT typ -> typ_is_int_carrier typ
         | _ -> false)
  in
  int_subsort_sorts :=
    typ_defs
    |> List.fold_left (fun acc (sort, _raw, params, insts) ->
         if params = [] && insts <> [] && List.for_all inst_is_int_alias insts
         then SSet.add sort acc
         else acc)
       SSet.empty
    |> SSet.remove "Int";
  source_membership_sorts :=
    typ_defs
    |> List.fold_left (fun acc (sort, _raw, params, _insts) ->
        if params = []
           && not (SSet.mem sort !sequence_alias_sorts)
           && not (is_meta_numeric_alias_sort sort)
        then SSet.add sort acc
        else acc)
      SSet.empty;
  let add_literal_family_alias_edge child parent =
    if child <> parent then
      let children =
        match Hashtbl.find_opt literal_family_alias_edges parent with
        | Some children -> children
        | None -> SSet.empty
      in
      Hashtbl.replace literal_family_alias_edges parent (SSet.add child children)
  in
  typ_defs
  |> List.iter (fun (parent_sort, _raw, params, insts) ->
      if params <> [] && is_literal_family_root parent_sort then
        List.iter
          (fun inst ->
            let (InstD (_binders, _args, deftyp)) = inst.it in
            match deftyp.it with
            | AliasT {it = VarT (child_id, child_args); _}
                when child_args <> [] ->
                let child_sort = sort_of_type_name child_id.it in
                if is_literal_family_root child_sort then
                  add_literal_family_alias_edge child_sort parent_sort
            | _ -> ())
          insts);
  let rec typ_ref_sort t =
    match t.it with
    | VarT (id, []) -> Some (sort_of_type_name id.it)
    | TupT [(_, inner)] -> typ_ref_sort inner
    | IterT (inner, Opt) -> typ_ref_sort inner
    | _ -> None
  in
  let source_type_names =
    typ_defs
    |> List.fold_left (fun acc (_sort, raw, _params, _insts) -> SSet.add raw acc) SSet.empty
  in
  let mixop_category_ref_sort mixop_val =
    let atoms =
      mixop_val
      |> List.flatten
      |> List.map Xl.Atom.name
      |> List.map String.trim
      |> List.filter (fun s -> s <> "" && s <> "%" && s <> "$")
    in
    match atoms with
    | [raw] when SSet.mem raw source_type_names -> Some (sort_of_type_name raw)
    | _ -> None
  in
  let typ_is_empty_payload t =
    match t.it with
    | TupT [] -> true
    | _ -> false
  in
  let source_category_reaches start target =
    let rec go seen sort =
      sort = target
      || (not (SSet.mem sort seen)
          &&
          let seen = SSet.add sort seen in
          let parents =
            match Hashtbl.find_opt source_category_subsort_edges sort with
            | Some ps -> ps
            | None -> SSet.empty
          in
          SSet.exists (go seen) parents)
    in
    go SSet.empty start
  in
  let add_source_category_subsort child parent =
    if child <> parent then
      if source_category_reaches parent child then
        record_unsupported_syntax_family parent
          (Printf.sprintf "cyclic category inclusion %s < %s" child parent)
      else
        let parents =
          match Hashtbl.find_opt source_category_subsort_edges child with
          | Some ps -> ps
          | None -> SSet.empty
        in
        Hashtbl.replace source_category_subsort_edges child (SSet.add parent parents)
  in
	  let add_source_conditional_alias child parent =
	    if child <> parent then
	      let children =
	        match Hashtbl.find_opt source_conditional_alias_edges parent with
	        | Some children -> children
        | None -> SSet.empty
	      in
	      Hashtbl.replace source_conditional_alias_edges parent (SSet.add child children)
	  in
  !pre_elab_source_category_edges
  |> List.iter (fun (child_raw, parent_raw) ->
       add_source_category_subsort
         (sort_of_type_name child_raw)
         (sort_of_type_name parent_raw));
	  let mixop_is_empty mixop_val =
	    mixop_val
	    |> List.flatten
	    |> List.for_all (fun atom -> Xl.Atom.name atom = "")
	  in
  let canonical_ctor_name_arity_local ?category ?case_typ mixop_val arity =
    source_ctor_name_from_mixop ?category ?case_typ mixop_val arity
  in
  let format_call_local fn args =
    match args with
    | [] -> fn
    | _ -> Printf.sprintf "%s ( %s )" fn (String.concat " , " args)
  in
  let rec source_term_of_exp_for_static e =
    match e.it with
    | CaseE (mixop_val, payload) ->
        let fields =
          match payload.it with
          | TupE es -> es
          | OptE None -> []
          | _ -> [payload]
        in
        (match canonical_ctor_name_arity_local mixop_val (List.length fields) with
         | Some ctor when fields = [] -> Some ctor
         | Some ctor ->
             let args = List.filter_map source_term_of_exp_for_static fields in
             if List.length args = List.length fields then
               Some (format_call_local ctor args)
             else None
         | None -> None)
    | VarE id when is_upper_start id.it ->
        source_nullary_ctor_name_from_id id.it
    | NumE (`Nat z | `Int z) -> Some (Z.to_string z)
    | CvtE (inner, _, _) | SubE (inner, _, _) | LiftE inner
    | TheE inner | OptE (Some inner) ->
        source_term_of_exp_for_static inner
    | _ -> None
  in
  let source_int_of_exp e =
    match e.it with
    | NumE (`Nat z | `Int z) -> Some (Z.to_string z)
    | _ -> None
  in
  let source_call_alias_of_exp e =
    match e.it with
    | CallE (target_id, [{it = ExpA {it = VarE arg_id; _}; _}]) ->
        Some (call_name target_id.it, arg_id.it)
    | _ -> None
  in
  let rec typ_is_nat_or_int_result t =
    match t.it with
    | NumT (`NatT | `IntT) -> true
    | VarT (id, _) ->
        let raw = String.lowercase_ascii id.it in
        raw = "nat" || raw = "int"
    | IterT (inner, Opt) -> typ_is_nat_or_int_result inner
    | _ -> false
  in
  let register_source_unary_int_alias fn arg_sort target_fn =
    let rule = {
      source_alias_fn = fn;
      source_alias_arg_sort = arg_sort;
      source_alias_target_fn = target_fn;
    } in
    if not (List.exists ((=) rule) !source_unary_int_aliases) then
      source_unary_int_aliases := rule :: !source_unary_int_aliases
  in
  let collect_source_ground_int_defs d =
    let rec go d =
      match d.it with
      | RecD ds -> List.iter go ds
      | DecD (id, params, _result_typ, insts) ->
          let fn = call_name id.it in
          if List.length params = 1 && typ_is_nat_or_int_result _result_typ then
            source_unary_int_functions := SSet.add fn !source_unary_int_functions;
          let param_sorts =
            params
            |> List.filter_map (fun p ->
                 match p.it with
                 | ExpP (pid, t) ->
                     let sort =
                       match simple_sort_of_typ t [] with
                       | Some s -> s
                       | None -> "SpectecTerminal"
                     in
                     Some (pid.it, sort)
                 | TypP _ | DefP _ | GramP _ -> None)
          in
          List.iter
            (fun inst ->
              match inst.it with
              | DefD ([], [{it = ExpA lhs_e; _}], rhs_e, []) ->
                  (match source_term_of_exp_for_static lhs_e, source_int_of_exp rhs_e with
                   | Some lhs_term, Some rhs_int when not (is_plain_var_like lhs_term) ->
                       register_source_ground_int_value fn lhs_term rhs_int
                   | _ -> ());
                  (match lhs_e.it, source_call_alias_of_exp rhs_e with
                   | VarE lhs_id, Some (target_fn, rhs_arg)
                       when lhs_id.it = rhs_arg ->
                       (match List.assoc_opt lhs_id.it param_sorts with
                        | Some arg_sort ->
                            register_source_unary_int_alias fn arg_sort target_fn
                        | None -> ())
                   | _ -> ())
              | _ -> ())
            insts
      | TypD _ | RelD _ | GramD _ | HintD _ -> ()
    in
    go d
  in
  List.iter collect_source_ground_int_defs defs;
  let add_source_nullary_term_local sort term =
    let old =
      match Hashtbl.find_opt source_nullary_terms_by_sort sort with
      | Some terms -> terms
      | None -> SSet.empty
    in
    Hashtbl.replace source_nullary_terms_by_sort sort (SSet.add term old)
  in
  let field_name_of_exp e =
    match e.it with
    | VarE id -> Some id.it
    | _ -> None
  in
  let compound_fields_of_typ t =
    match t.it with
    | TupT fields ->
        Some (List.map (fun (fe, ft) -> (field_name_of_exp fe, ft)) fields)
    | VarT _ | IterT _ | BoolT | NumT _ | TextT ->
        Some [(None, t)]
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
	                      | Some child ->
                          record_source_alias_subsort child parent_sort;
                          add_source_category_subsort child parent_sort
	                      | None -> ())
                 | VariantT cases ->
                     List.iter
                       (fun (mixop_val, (_, case_typ, prems), _) ->
                         if prems = [] then
                           if mixop_is_empty mixop_val then
                             match typ_ref_sort case_typ with
                             | Some child -> add_source_category_subsort child parent_sort
                             | None -> ()
                           else if typ_is_empty_payload case_typ then
                             match mixop_category_ref_sort mixop_val with
                             | Some child -> add_source_category_subsort child parent_sort
                             | None -> ()
                         else if mixop_is_empty mixop_val then
                           match typ_ref_sort case_typ with
                           | Some child -> add_source_conditional_alias child parent_sort
                           | None -> ())
	                       cases
	                 | StructT _ -> ())
	            | _ -> ())
	          insts)
	    typ_defs;
  List.iter
    (fun (parent_sort, _raw, params, insts) ->
      if params = [] then
        List.iter
          (fun inst -> match inst.it with
            | InstD (binders, args, deftyp)
              when binders = [] && args = [] ->
                (match deftyp.it with
                 | VariantT cases ->
                     List.iter
                       (fun (mixop_val, (_, case_typ, prems), _) ->
                         let arity =
                           match case_typ.it with
                           | TupT fields -> List.length fields
                           | _ -> 1
                         in
                         match canonical_ctor_name_arity_local ~category:_raw ~case_typ mixop_val arity with
                         | Some ctor ->
                             let has_payload =
                               match case_typ.it with
                               | TupT [] -> false
                               | _ -> true
                             in
                             if not has_payload then begin
                               if prems = [] then
                                 add_source_nullary_term_local parent_sort ctor
                             end else
                               (match compound_fields_of_typ case_typ with
                                | Some fields ->
                                    source_compound_cases :=
                                      { compound_parent_sort = parent_sort;
                                        compound_ctor = ctor;
                                        compound_fields = fields;
                                        compound_prems = prems;
                                      } :: !source_compound_cases
                                | None -> ())
                         | None -> ())
                       cases
                 | AliasT _ | StructT _ -> ())
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
	  simple_alias_source_sorts := fix_alias SSet.empty;

  let rec typ_uses_literal_family known t =
    match t.it with
    | VarT (id, _) ->
        let sort = sort_of_type_name id.it in
        is_literal_family_root sort || SSet.mem sort known
    | IterT (inner, _) -> typ_uses_literal_family known inner
    | TupT fields ->
        List.exists (fun (_e, t) -> typ_uses_literal_family known t) fields
    | _ -> false
  in
  let inst_uses_literal_family known inst =
    match inst.it with
    | InstD (_binders, _args, deftyp) ->
        (match deftyp.it with
         | AliasT typ -> typ_uses_literal_family known typ
         | _ -> false)
  in
  let rec fix_literal_parents known =
    let next =
      List.fold_left
        (fun acc (sort, _raw, params, insts) ->
          if params <> [] && insts <> []
             && List.exists (inst_uses_literal_family known) insts
          then SSet.add sort acc
          else acc)
        known typ_defs
    in
    if SSet.equal known next then known else fix_literal_parents next
  in
	  literal_family_parent_sorts :=
	    fix_literal_parents !literal_family_roots
	;
  let rec collect_source_def_return_sorts d =
    match d.it with
    | RecD ds -> List.iter collect_source_def_return_sorts ds
    | DecD (id, params, result_typ, _insts) ->
        let maude_fn = call_name id.it in
        let arg_sort p =
          match p.it with
          | ExpP (_, t) ->
              (match sequence_sort_of_typ t [] with
               | Some _ -> "SpectecTerminals"
               | None ->
	                   (match simple_sort_of_typ t [] with
	                    | Some sort when SSet.mem sort !sequence_alias_sorts ->
	                        "SpectecTerminals"
	                    | Some sort when SSet.mem sort !flat_sequence_source_sorts ->
	                        "SpectecTerminals"
	                    | Some sort -> semantic_sort_of_source_sort sort
	                    | None -> "SpectecTerminal"))
          | TypP _ -> ""
          | DefP _ | GramP _ -> "SpectecTerminal"
        in
        let rec arg_wrap_sort_of_typ t =
          match sequence_sort_of_typ t [] with
          | Some _ -> "SpectecTerminals"
          | None ->
	              (match simple_sort_of_typ t [] with
	               | Some sort -> semantic_sort_of_source_sort sort
	               | None ->
	                   match t.it with
                   | NumT `NatT -> "Nat"
                   | NumT `IntT -> "Int"
                   | VarT (tid, []) ->
                       let sort = sort_of_type_name tid.it in
	                       if is_pure_meta_category_sort sort then semantic_sort_of_source_sort sort
	                       else if Hashtbl.mem source_sort_type_atoms sort then sort
	                       else "SpectecTerminal"
                   | IterT (inner, Opt) -> arg_wrap_sort_of_typ inner
                   | _ -> "SpectecTerminal")
        in
        let arg_wrap_sort p =
          match p.it with
          | ExpP (_, t) -> arg_wrap_sort_of_typ t
          | TypP _ -> ""
          | DefP _ | GramP _ -> "SpectecTerminal"
        in
        let rec sequence_list_depth_of_typ t =
          match t.it with
          | IterT (inner, (List | List1 | ListN _)) ->
              1 + sequence_list_depth_of_typ inner
          | IterT (inner, Opt) -> sequence_list_depth_of_typ inner
          | _ -> 0
        in
        let arg_sequence_depth p =
          match p.it with
          | ExpP (_, t) -> sequence_list_depth_of_typ t
          | TypP _ | DefP _ | GramP _ -> 0
        in
        let def_param_sort_of_typ t =
          match sequence_sort_of_typ t [] with
          | Some _ -> "SpectecTerminals"
          | None ->
              (match t.it with
	               | NumT `NatT -> "Nat"
	               | NumT `IntT -> "Int"
               | IterT (_, (List | List1 | ListN _ | Opt)) -> "SpectecTerminals"
               | _ ->
                   match simple_sort_of_typ t [] with
                   | Some sort when SSet.mem sort !sequence_alias_sorts ->
                       "SpectecTerminals"
                   | Some sort when SSet.mem sort !flat_sequence_source_sorts ->
                       "SpectecTerminals"
                   | Some ("Bool") -> "Bool"
	                   | Some sort when is_pure_meta_category_sort sort ->
	                       semantic_sort_of_source_sort sort
		                   | Some s when s = "Nat" || s = "Int" -> s
                   | Some sort when List.mem sort ["Config"; "State"; "Store"; "Frame"; "Judgement"] ->
                       sort
                   | Some _ | None -> "SpectecTerminal")
        in
        let arg_sorts =
          params
          |> List.filter_map (fun p ->
              match p.it with
              | TypP _ -> None
              | _ ->
                  let sort = arg_sort p in
                  if sort = "" then None else Some sort)
        in
        let arg_wrap_sorts =
          params
          |> List.filter_map (fun p ->
              match p.it with
              | TypP _ -> None
              | _ ->
                  let sort = arg_wrap_sort p in
                  if sort = "" then None else Some sort)
        in
        Hashtbl.replace source_def_arg_sorts maude_fn arg_sorts;
        Hashtbl.replace source_def_arg_wrap_sorts maude_fn arg_wrap_sorts;
        Hashtbl.replace source_def_arg_sequence_depths maude_fn
          (List.map arg_sequence_depth params);
        let def_param_infos =
          params
          |> List.mapi (fun i p ->
              match p.it with
              | DefP (def_id, def_params, def_result_typ) ->
                  let def_arg_sorts =
                    def_params
                    |> List.filter_map (fun p ->
                        match p.it with
                        | TypP _ -> None
                        | ExpP (_, t) -> Some (def_param_sort_of_typ t)
                        | DefP _ | GramP _ -> Some "SpectecTerminal")
                  in
                  Some {
                    def_param_position = i;
                    def_param_apply_name = def_apply_name maude_fn def_id.it;
                    def_param_arg_sorts = def_arg_sorts;
                    def_param_return_sort = def_param_sort_of_typ def_result_typ;
                  }
              | ExpP _ | TypP _ | GramP _ -> None)
          |> List.filter_map (fun x -> x)
        in
        if def_param_infos <> [] then
          Hashtbl.replace source_def_param_infos maude_fn def_param_infos;
        Hashtbl.replace source_def_return_optionals maude_fn
          (typ_is_optional_result result_typ);
        (match semantic_result_sort_of_typ result_typ [] with
         | Some sort -> Hashtbl.replace source_def_return_sorts maude_fn sort
         | None -> ())
    | _ -> ()
  in
  List.iter collect_source_def_return_sorts defs

let source_nullary_terms sort =
  match Hashtbl.find_opt source_nullary_terms_by_sort sort with
  | Some terms -> terms
  | None -> SSet.empty

let add_source_nullary_term sort term =
  let old =
    match Hashtbl.find_opt source_nullary_terms_by_sort sort with
    | Some terms -> terms
    | None -> SSet.empty
  in
  Hashtbl.replace source_nullary_terms_by_sort sort (SSet.add term old)

let finite_source_terms_for_sort sort =
  let rec go seen sort =
    if SSet.mem sort seen then SSet.empty
    else
      let seen = SSet.add sort seen in
      let direct = source_nullary_terms sort in
      let child_terms =
        Hashtbl.fold
          (fun child parents acc ->
            if SSet.mem sort parents then SSet.union acc (go seen child)
            else acc)
          source_category_subsort_edges
          SSet.empty
      in
      SSet.union direct child_terms
  in
  go SSet.empty sort

let source_sort_reaches start target =
  let rec go seen sort =
    sort = target
    || (not (SSet.mem sort seen)
        &&
        let seen = SSet.add sort seen in
        let parents =
          match Hashtbl.find_opt source_category_subsort_edges sort with
          | Some ps -> ps
          | None -> SSet.empty
        in
        SSet.exists (go seen) parents)
  in
  go SSet.empty start

let source_ctor_category_sort info =
  info.source_ctor_category |> Option.map sort_of_type_name

let choose_most_specific_source_ctor infos =
  let infos =
    infos
    |> List.sort (fun a b -> String.compare a.source_ctor_name b.source_ctor_name)
  in
  let is_ancestor a b =
    match source_ctor_category_sort a, source_ctor_category_sort b with
    | Some a_sort, Some b_sort ->
        a_sort <> b_sort && source_sort_reaches b_sort a_sort
    | _ -> false
  in
  infos
  |> List.filter (fun info ->
       not (List.exists (fun other -> is_ancestor info other) infos))
  |> function
     | [info] -> Some info
     | _ -> None

let filter_source_ctor_candidates_by_expected_sort expected_sort infos =
  match expected_sort with
  | None -> infos
  | Some expected ->
      let filtered =
        infos
        |> List.filter (fun info ->
             match source_ctor_category_sort info with
             | Some category ->
                 category = expected || source_sort_reaches category expected
             | None -> false)
      in
      if filtered = [] then infos else filtered

let source_nullary_ctor_name_if_registered ?expected_sort raw =
  let sections = [sanitize raw |> trim_tail_hyphen] in
  match Hashtbl.find_opt source_ctor_by_key (source_ctor_key sections 0) with
  | Some info -> Some info.source_ctor_name
  | None ->
      (match source_ctor_surface_op_head sections with
       | None -> None
       | Some head ->
           source_ctor_candidates_by_original_head_arity head 0
           |> filter_source_ctor_candidates_by_expected_sort expected_sort
           |> choose_most_specific_source_ctor
           |> Option.map (fun info -> info.source_ctor_name))

let source_field_sort_reaches typ target_sort =
  match simple_sort_of_typ typ [] with
  | Some sort -> source_sort_reaches sort target_sort
  | None -> false

let source_field_sort_is_meta_numeric typ =
  match simple_sort_of_typ typ [] with
  | Some sort ->
      is_meta_numeric_alias_sort sort
      || sort = "Nat"
      || sort = "Int"
      || source_sort_reaches sort (sort_of_type_name "nat")
      || source_sort_reaches sort (sort_of_type_name "int")
  | None -> false

let source_ctors_by_compound_case pred =
  !source_compound_cases
  |> List.filter pred
  |> List.map (fun c -> c.compound_ctor)
  |> List.sort_uniq String.compare

let source_index_wrapper_ctor () =
  let typevar_sort = sort_of_type_name "typevar" in
  source_ctors_by_compound_case (fun c ->
      source_sort_reaches c.compound_parent_sort typevar_sort
      &&
      match c.compound_fields with
      | [(_, field_typ)] -> not (source_field_sort_is_meta_numeric field_typ)
      | _ -> false)
  |> function
     | ctor :: _ -> Some ctor
     | [] -> None

let source_recursive_typevar_ctor () =
  let typevar_sort = sort_of_type_name "typevar" in
  source_ctors_by_compound_case (fun c ->
      source_sort_reaches c.compound_parent_sort typevar_sort
      &&
      match c.compound_fields with
      | [(_, field_typ)] -> source_field_sort_is_meta_numeric field_typ
      | _ -> false)
  |> function
     | ctor :: _ -> Some ctor
     | [] -> None

let source_indexed_deftype_ctor () =
  let deftype_sort = sort_of_type_name "deftype" in
  source_ctors_by_compound_case (fun c ->
      source_sort_reaches c.compound_parent_sort deftype_sort
      &&
      match c.compound_fields with
      | [_; (_, index_typ)] -> source_field_sort_is_meta_numeric index_typ
      | _ -> false)
  |> function
     | ctor :: _ -> Some ctor
     | [] -> None

let rec nullary_ctor_suffix term =
  let term = strip_wrapping_parens term |> String.trim in
  if is_source_ctor_name term then
    source_ctor_suffix term
  else
    match parse_call_text term with
    | Some (ctor, args) when is_source_ctor_name ctor ->
        source_ctor_suffix ctor ^ String.concat "" (List.map nullary_ctor_suffix args)
    | _ ->
        (match parse_source_ctor_surface_text term with
         | Some (ctor, args) ->
             source_ctor_suffix ctor ^ String.concat "" (List.map nullary_ctor_suffix args)
         | None ->
    match parse_call_text term with
    | Some (lit, [payload]) when starts_with lit "lit" ->
        let stem =
          String.sub lit 3 (String.length lit - 3)
          |> String.uppercase_ascii
        in
        let payload =
          strip_wrapping_parens payload
          |> String.trim
          |> String.map (function
               | '0' .. '9' as c -> c
               | _ -> '_')
          |> String.split_on_char '_'
          |> List.filter (fun s -> s <> "")
          |> String.concat ""
        in
        stem ^ payload
    | _ ->
        let b = Buffer.create (String.length term) in
        String.iter
          (fun c ->
            if (c >= 'a' && c <= 'z')
               || (c >= 'A' && c <= 'Z')
               || (c >= '0' && c <= '9')
            then Buffer.add_char b c)
          term;
        let cleaned = Buffer.contents b in
        if cleaned = "" then "TERM" else String.uppercase_ascii cleaned)

let concrete_literal_family_sort family_sort numeric_tail =
  match Hashtbl.find_opt literal_family_infos family_sort with
  | Some info -> info.literal_family_concrete_prefix ^ numeric_tail
  | None ->
      if ends_with family_sort "N" && String.length family_sort > 1 then
        let stem = String.sub family_sort 0 (String.length family_sort - 1) in
        (if stem = "U" || stem = "S" then stem else family_sort) ^ numeric_tail
      else family_sort ^ numeric_tail

let literal_family_of_nullary_suffix suffix =
  let len = String.length suffix in
  if len < 2 then None
  else
    Hashtbl.to_seq_values literal_family_infos
    |> Seq.filter_map (fun info ->
         let prefix = info.literal_family_nullary_prefix in
         let plen = String.length prefix in
         if plen > 0 && len > plen && String.sub suffix 0 plen = prefix then
           let numeric_tail = String.sub suffix plen (len - plen) in
           if numeric_tail <> ""
              && String.for_all (fun c -> c >= '0' && c <= '9') numeric_tail
           then Some (info.literal_family_sort, numeric_tail)
           else None
         else None)
    |> List.of_seq
    |> List.sort_uniq compare
    |> (function
        | [one] -> Some one
        | _ -> None)

let literal_family_of_concrete_sort sort =
  Hashtbl.to_seq_values literal_family_infos
  |> Seq.filter_map (fun info ->
       let prefix = info.literal_family_concrete_prefix in
       let plen = String.length prefix in
       if plen > 0 && String.length sort > plen
          && String.sub sort 0 plen = prefix then
         let numeric_tail = String.sub sort plen (String.length sort - plen) in
         if numeric_tail <> ""
            && String.for_all (fun c -> c >= '0' && c <= '9') numeric_tail
         then Some (info.literal_family_sort, numeric_tail)
         else None
       else None)
  |> List.of_seq
  |> List.sort_uniq compare
  |> (function
      | [one] -> Some one
      | _ -> None)

let decimal_double digits =
  let carry = ref 0 in
  let chars =
    digits
    |> List.rev
    |> List.map (fun d ->
         let n = ((Char.code d - Char.code '0') * 2) + !carry in
         carry := n / 10;
         Char.chr (Char.code '0' + (n mod 10)))
    |> List.rev
  in
  let chars = if !carry = 0 then chars else Char.chr (Char.code '0' + !carry) :: chars in
  String.of_seq (List.to_seq chars)

let decimal_decrement s =
  let bytes = Bytes.of_string s in
  let rec borrow i =
    if i < 0 then ()
    else
      let c = Bytes.get bytes i in
      if c > '0' then Bytes.set bytes i (Char.chr (Char.code c - 1))
      else begin
        Bytes.set bytes i '9';
        borrow (i - 1)
      end
  in
  borrow (Bytes.length bytes - 1);
  let raw = Bytes.to_string bytes in
  let rec first_non_zero i =
    if i >= String.length raw - 1 then i
    else if raw.[i] = '0' then first_non_zero (i + 1)
    else i
  in
  String.sub raw (first_non_zero 0) (String.length raw - first_non_zero 0)

let decimal_pow2 bits =
  let rec loop i acc =
    if i <= 0 then acc else loop (i - 1) (decimal_double (List.of_seq (String.to_seq acc)))
  in
  loop bits "1"

let decimal_pow2_minus_one bits =
  decimal_decrement (decimal_pow2 bits)

let int_of_numeric_tail_opt tail =
  try Some (int_of_string tail) with Failure _ -> None

let literal_wrapper_name family_sort numeric_tail =
  let _ = family_sort in
  let _ = numeric_tail in
  None

let source_literal_wrapper_name sort =
  "lit" ^ sort

let finite_numeric_literals_from_condition var cond =
  let cond_without_var =
    Str.global_replace (Str.regexp_string var) "" cond
  in
  let has_range_or_arithmetic =
    List.exists
      (fun needle -> contains_substring cond_without_var needle)
      ["<"; ">"; "^"; "_<_"; "_<=_"; "_>_"; "_>=_"]
  in
  let collect_numbers () =
    let re = Str.regexp "-?[0-9]+" in
    let numeric_compare a b =
      let parse s = try Some (int_of_string s) with Failure _ -> None in
      match parse a, parse b with
      | Some ai, Some bi -> compare ai bi
      | _ -> String.compare a b
    in
    let rec loop pos acc =
      match (try Some (Str.search_forward re cond pos) with Not_found -> None) with
      | None -> List.rev acc |> List.sort_uniq numeric_compare
      | Some _ ->
          let lit = Str.matched_string cond in
          loop (Str.match_end ()) (lit :: acc)
    in
    loop 0 []
  in
  if not has_range_or_arithmetic
     && (contains_substring cond_without_var "_==_"
         || contains_substring cond_without_var "==")
  then collect_numbers ()
  else
  let cleaned =
    cond_without_var
    |> Str.global_replace (Str.regexp_string "_or_") ""
    |> Str.global_replace (Str.regexp_string "_==_") ""
    |> Str.global_replace (Str.regexp_string "or") ""
    |> Str.global_replace (Str.regexp_string "==") ""
    |> Str.global_replace (Str.regexp "[0-9]+") ""
    |> Str.global_replace (Str.regexp "[(), \t\n\r]") ""
    |> String.trim
  in
  if cleaned <> "" then []
  else
    collect_numbers ()

let register_source_literal_wrapper_for_sort sort payload_sort cond_template =
  let wrapper = source_literal_wrapper_name sort in
  let var =
    String.uppercase_ascii wrapper ^
    (if payload_sort = "Nat" then "-N" else "-I")
  in
  let cond =
    replace_maude_var_token "$LIT" var cond_template
  in
  Hashtbl.replace literal_wrapper_payload_sorts wrapper payload_sort;
  Hashtbl.replace source_literal_wrapper_by_sort sort wrapper;
  literal_wrapper_syntax_decls :=
    SSet.add
      (Printf.sprintf "  op %s : %s -> SpectecTerminal [ctor] ."
         wrapper payload_sort)
      (SSet.add (Printf.sprintf "  var %s : %s ." var payload_sort)
         !literal_wrapper_syntax_decls);
  literal_wrapper_memberships :=
    SSet.add
      (Printf.sprintf "  cmb ( %s ( %s ) ) : %s\n   if %s ."
         wrapper var sort cond)
      !literal_wrapper_memberships;
  wrapper

let source_literal_membership_for_numeric_condition sort type_term lhs rhs =
  let lhs = strip_wrapping_parens lhs |> String.trim in
  if lhs = "" || rhs = "" || not (is_plain_var_like lhs) then None
  else
    let raw_pat = Printf.sprintf "$raw-lit ( %s )" lhs in
    let cond_template =
      if contains_substring rhs raw_pat then
        Some (Str.global_replace (Str.regexp_string raw_pat) "$LIT" rhs)
      else
        let replaced = replace_maude_var_token lhs "$LIT" rhs in
        if replaced <> rhs then Some replaced else None
    in
    match cond_template with
    | None -> None
    | Some cond_template ->
      let cond_without_lit =
        Str.global_replace (Str.regexp_string "$LIT") "" cond_template
      in
      let other_vars =
        let re = Str.regexp "[A-Z][A-Z0-9-]*" in
        let rec loop pos acc =
          match (try Some (Str.search_forward re cond_without_lit pos)
                 with Not_found -> None) with
          | None -> List.sort_uniq String.compare acc
          | Some _ ->
              loop (Str.match_end ()) (Str.matched_string cond_without_lit :: acc)
        in
        loop 0 []
        |> List.filter (fun v -> v <> lhs)
      in
      let compact text =
        text
        |> Str.global_replace (Str.regexp "[ \t\n\r]") ""
      in
      let type_witness_for_raw_param raw =
        let source_sort = sort_of_type_name raw in
        if is_meta_numeric_alias_sort source_sort then
          Some (spectec_type_constructor_head raw 0)
        else
          match Hashtbl.find_opt source_sort_type_atoms source_sort with
          | Some atom -> Some atom
          | None ->
              if SSet.mem source_sort !source_membership_sorts then
                Some (spectec_type_constructor_head raw 0)
              else None
      in
      let readable_param_guard param_var raw =
        match type_witness_for_raw_param raw with
        | Some atom -> Some (Printf.sprintf "typecheck(%s, %s)" param_var atom)
        | None -> None
      in
      let readable_type_term param_substs =
        param_substs
        |> List.fold_left
             (fun acc (src, dst) -> replace_maude_var_token src dst acc)
             type_term
      in
      let readable_numeric_membership () =
        let finite_lits =
          finite_numeric_literals_from_condition "$LIT" cond_template
        in
        match finite_lits with
        | _ :: _ ->
            let var = "I" in
            let finite_cond =
              finite_lits
              |> List.map (fun lit -> Printf.sprintf "%s == %s" var lit)
              |> String.concat " or "
            in
            Some
              (Printf.sprintf
                 "  var %s : Int .\n  ceq typecheck(%s, %s) = true\n   if %s ."
                 var var type_term finite_cond)
        | [] ->
            (match other_vars with
             | [raw_param] ->
                 let suffix =
                   sort |> sanitize |> trim_tail_hyphen |> String.uppercase_ascii
                 in
                 let param_var =
                   Printf.sprintf "%s_%s"
                     (String.uppercase_ascii (sanitize raw_param))
                     suffix
                 in
                 let param_sort =
                   sort_of_type_name raw_param
                   |> semantic_sort_of_source_sort
                 in
                 let param_sort =
                   match param_sort with
                   | "Nat" | "Int" -> param_sort
                   | _ -> "SpectecTerminal"
                 in
                 let payload_var = "I" in
                 let type_term =
                   readable_type_term [(raw_param, param_var)]
                 in
                 let pretty_template =
                   pretty_source_syntax_condition_text cond_template
                 in
                 let compact_raw = compact cond_template in
                 let compact_pretty = compact pretty_template in
                 let has_pow =
                   contains_substring compact_raw "^"
                   || contains_substring compact_pretty "^"
                 in
                 let nonnegative_lower =
                   contains_substring compact_raw "_>=_($LIT,0)"
                   || contains_substring compact_raw "_<=_(0,$LIT)"
                   || contains_substring compact_pretty "$LIT>=0"
                   || contains_substring compact_pretty "0<=$LIT"
                 in
                 let signed_lower =
                   contains_substring compact_raw "_-_(0"
                   || contains_substring compact_pretty "0-("
                   || contains_substring compact_pretty "-(2^"
                 in
                 let param_guard =
                   readable_param_guard param_var raw_param
                   |> Option.to_list
                 in
                 let range_conds =
                   if has_pow && signed_lower then
                     [Printf.sprintf "(-2 ^ (%s + - 1) <= %s)"
                        param_var payload_var;
                      Printf.sprintf "(%s <= (2 ^ (%s + - 1)) + - 1)"
                        payload_var param_var]
                   else if has_pow && nonnegative_lower then
                     [Printf.sprintf "0 <= %s" payload_var;
                      Printf.sprintf "%s < 2 ^ %s"
                        payload_var param_var]
                   else []
                 in
                 if range_conds = [] then None
                 else
                   Some
                     (Printf.sprintf
                        "  var %s : %s .\n  var %s : Int .\n  ceq typecheck(%s, %s) = true\n   if %s ."
                        param_var param_sort payload_var payload_var type_term
                        (String.concat " /\\ " (param_guard @ range_conds)))
             | _ -> None)
      in
      match readable_numeric_membership () with
      | Some stmt -> Some stmt
      | None ->
      let number_re = Str.regexp "-?[0-9]+" in
      let rec collect pos acc =
        match (try Some (Str.search_forward number_re cond_template pos)
               with Not_found -> None) with
        | None -> List.rev acc
        | Some _ ->
            let n = Str.matched_string cond_template in
            collect (Str.match_end ()) (n :: acc)
      in
	      let payload_sort =
	        let has_negative_range =
	          contains_substring cond_template "_-_ ( 0,"
	          || contains_substring cond_template "_-_(0,"
	          || contains_substring cond_template " - 0"
	        in
	        match literal_family_of_concrete_sort sort with
	        | Some (family_sort, _numeric_tail) ->
	            (match Hashtbl.find_opt literal_family_infos family_sort with
	             | Some info when info.literal_family_concrete_prefix = "FN" -> "Int"
	             | _ ->
	                 if has_negative_range
	                    || List.exists (fun n -> starts_with n "-") (collect 0 [])
	                 then "Int"
	                 else "Nat")
	        | None ->
	            if has_negative_range
	               || List.exists (fun n -> starts_with n "-") (collect 0 [])
	            then "Int"
	            else "Nat"
	      in
      let var =
        Printf.sprintf "RAW-%s-%s"
          (String.uppercase_ascii (sanitize sort))
          (if payload_sort = "Nat" then "N" else "I")
      in
      let param_substs =
        other_vars
        |> List.map (fun v ->
             (v,
              Printf.sprintf "RAW-%s-P-%s"
                (String.uppercase_ascii (sanitize sort))
                v))
      in
	      let cond =
	        let raw_cond = replace_maude_var_token "$LIT" var cond_template in
	        param_substs
	        |> List.fold_left
	             (fun acc (src, dst) -> replace_maude_var_token src dst acc)
	             raw_cond
	        |> pretty_source_syntax_condition_text
	      in
      let type_term =
        param_substs
        |> List.fold_left
             (fun acc (src, dst) -> replace_maude_var_token src dst acc)
             type_term
      in
      let param_decls =
        param_substs
        |> List.map (fun (_, v) -> Printf.sprintf "  var %s : Nat .\n" v)
        |> String.concat ""
      in
      Some
        (Printf.sprintf
           "%s  var %s : %s .\n  ceq typecheck(( %s ), %s) = true\n   if %s ."
           param_decls var payload_sort var type_term cond)

let literal_wrapper_direct_spec sort =
  match literal_family_of_concrete_sort sort with
  | Some (family_sort, numeric_tail) ->
      (match Hashtbl.find_opt literal_family_infos family_sort with
       | Some info when info.literal_family_concrete_prefix = "U" ->
           Option.map (fun wrapper -> (wrapper, "Nat", numeric_tail))
             (literal_wrapper_name family_sort numeric_tail)
       | Some info
           when info.literal_family_concrete_prefix = "FN"
                && (numeric_tail = "32" || numeric_tail = "64") ->
           Option.map (fun wrapper -> (wrapper, "Int", numeric_tail))
             (literal_wrapper_name family_sort numeric_tail)
       | _ -> None)
  | _ -> None

let register_literal_wrapper_for_sort sort =
  match literal_wrapper_direct_spec sort with
  | Some (wrapper, "Nat", numeric_tail) ->
      (match int_of_numeric_tail_opt numeric_tail with
       | Some bits ->
           let var = String.uppercase_ascii wrapper ^ "-N" in
           let max = decimal_pow2_minus_one bits in
           Hashtbl.replace literal_wrapper_payload_sorts wrapper "Nat";
           literal_wrapper_syntax_decls :=
             SSet.add (Printf.sprintf "  op %s : Nat -> SpectecTerminal [ctor] ." wrapper)
               (SSet.add (Printf.sprintf "  var %s : Nat ." var)
                  !literal_wrapper_syntax_decls);
           literal_wrapper_memberships :=
             SSet.add
               (Printf.sprintf "  cmb ( %s ( %s ) ) : %s\n   if %s <= %s = true ."
                  wrapper var sort var max)
               !literal_wrapper_memberships
       | _ -> ())
  | Some (wrapper, "Int", ("32" | "64" as numeric_tail)) ->
           let var = String.uppercase_ascii wrapper ^ "-I" in
           let min_bound, max_bound =
             if numeric_tail = "32" then
               ("-2147483648", "2147483647")
             else
               ("-9223372036854775808", "9223372036854775807")
           in
           Hashtbl.replace literal_wrapper_payload_sorts wrapper "Int";
           literal_wrapper_syntax_decls :=
             SSet.add (Printf.sprintf "  op %s : Int -> SpectecTerminal [ctor] ." wrapper)
               (SSet.add (Printf.sprintf "  var %s : Int ." var)
                  !literal_wrapper_syntax_decls);
           literal_wrapper_memberships :=
             SSet.add
               (Printf.sprintf "  cmb ( %s ( %s ) ) : %s\n   if %s >= %s = true /\\ %s <= %s = true ."
                  wrapper var sort var min_bound var max_bound)
               !literal_wrapper_memberships
  | _ -> ()

let add_generated_source_subsort child parent =
  if child <> parent then begin
    let parents =
      match Hashtbl.find_opt source_category_subsort_edges child with
      | Some parents -> parents
      | None -> SSet.empty
    in
    Hashtbl.replace source_category_subsort_edges child (SSet.add parent parents)
  end

let literal_wrapper_for_sort ?(register=false) sort =
  let rec go seen sort =
    if SSet.mem sort seen then None
    else
      let seen = SSet.add sort seen in
      match Hashtbl.find_opt source_literal_wrapper_by_sort sort with
      | Some wrapper ->
          let payload_sort =
            match Hashtbl.find_opt literal_wrapper_payload_sorts wrapper with
            | Some s -> s
            | None -> "SpectecTerminal"
          in
          Some (wrapper, payload_sort)
      | None ->
      match literal_wrapper_direct_spec sort with
      | Some (wrapper, payload_sort, _numeric_tail) ->
          if register then register_literal_wrapper_for_sort sort;
          Some (wrapper, payload_sort)
      | None ->
          let literal_children =
            match literal_family_of_concrete_sort sort with
            | Some (parent_family, numeric_tail) ->
                (match Hashtbl.find_opt literal_family_alias_edges parent_family with
                 | Some children ->
                     children
                     |> SSet.elements
                     |> List.map (fun child_family ->
                          concrete_literal_family_sort child_family numeric_tail)
                 | None -> [])
            | None -> []
          in
          let category_children =
            Hashtbl.fold
              (fun child parents acc ->
                if SSet.mem sort parents then child :: acc else acc)
              source_category_subsort_edges
              []
          in
          let candidates =
            (literal_children @ category_children)
            |> List.filter_map (go seen)
            |> List.sort_uniq compare
          in
          (match candidates with
           | [one] -> Some one
           | _ -> None)
  in
  go SSet.empty sort

let syntax_wrapper_helper_name sort = "$wrap-" ^ sort

let syntax_wrapper_helper_for_sort sort =
  match literal_wrapper_for_sort ~register:true sort with
  | Some (wrapper, payload_sort) ->
      Some (syntax_wrapper_helper_name sort, wrapper, payload_sort)
  | None -> None

let all_source_category_sorts () =
  Hashtbl.fold
    (fun child parents acc ->
      SSet.union (SSet.add child acc) parents)
    source_category_subsort_edges
    !source_membership_sorts
  |> SSet.union !zero_arity_source_sorts
  |> SSet.union !simple_alias_source_sorts

let literal_wrapper_runtime_helper_block () =
  let syntax_wrapper_helper_block =
    let sorts =
      all_source_category_sorts ()
      |> SSet.elements
      |> List.filter (fun sort -> sort <> "SpectecTerminal" && sort <> "SpectecTerminals")
    in
    sorts
    |> List.filter_map (fun sort ->
         match syntax_wrapper_helper_for_sort sort with
         | Some (helper, wrapper, payload_sort) ->
             let var = if payload_sort = "Nat" then "WRAP-LIT-N" else "WRAP-LIT-I" in
             Some
               (Printf.sprintf
                  "  op %s : %s -> SpectecTerminal .\n  eq %s(%s) = %s(%s) ."
                  helper payload_sort helper var wrapper var)
         | None -> None)
    |> List.sort_uniq String.compare
    |> String.concat "\n"
  in
  let wrap_lit_eqs =
	      Hashtbl.fold
	        (fun type_term wrapper acc ->
	          let payload_sort =
	            match Hashtbl.find_opt literal_wrapper_payload_sorts wrapper with
	            | Some sort -> sort
	            | None -> "SpectecTerminal"
	          in
	          let payload =
	            if payload_sort = "Nat" then "$raw-nat-lit(WRAP-LIT-C)"
	            else if payload_sort = "Int" then "$raw-int-lit(WRAP-LIT-C)"
	            else "WRAP-LIT-C"
	          in
	          Printf.sprintf "  eq $wrap-lit(%s, %s) = %s(%s) ."
	            type_term "WRAP-LIT-C" wrapper payload
	          :: acc)
	        literal_wrapper_by_type_term
	        []
      |> List.sort_uniq String.compare
      |> String.concat "\n"
    in
    let raw_lit_eqs =
      Hashtbl.fold
        (fun wrapper payload_sort acc ->
          let var = if payload_sort = "Nat" then "WRAP-LIT-N" else "WRAP-LIT-I" in
          Printf.sprintf "  eq $raw-lit(%s(%s)) = %s ." wrapper var var
          :: acc)
        literal_wrapper_payload_sorts
        []
      |> List.sort_uniq String.compare
      |> String.concat "\n"
    in
    let raw_nat_lit_eqs =
      Hashtbl.fold
        (fun wrapper payload_sort acc ->
          if payload_sort = "Nat" then
            Printf.sprintf "  eq $raw-nat-lit(%s(WRAP-LIT-N)) = WRAP-LIT-N ."
              wrapper
            :: acc
          else acc)
        literal_wrapper_payload_sorts
        []
      |> List.sort_uniq String.compare
      |> String.concat "\n"
    in
	    let raw_int_lit_eqs =
	      Hashtbl.fold
	        (fun wrapper payload_sort acc ->
	          if payload_sort = "Int" then
	            Printf.sprintf "  eq $raw-int-lit(%s(WRAP-LIT-I)) = WRAP-LIT-I ."
	              wrapper
	            :: acc
	          else acc)
	        literal_wrapper_payload_sorts
	        []
	      |> List.sort_uniq String.compare
	      |> String.concat "\n"
	    in
	    let wrapper_payload_typecheck_eqs =
	      Hashtbl.fold
	        (fun wrapper payload_sort acc ->
	          match payload_sort with
	          | "Nat" ->
	              Printf.sprintf "  eq typecheck(%s(WRAP-LIT-N), %s) = true ."
	                wrapper
                  (spectec_type_term_of_name "nat" [])
	              :: acc
	          | "Int" ->
	              Printf.sprintf "  eq typecheck(%s(WRAP-LIT-I), %s) = true ."
	                wrapper
                  (spectec_type_term_of_name "int" [])
	              :: acc
	          | _ -> acc)
	        literal_wrapper_payload_sorts
	        []
	      |> List.sort_uniq String.compare
	      |> String.concat "\n"
	    in
	    "\n  --- Object-level numeric literal boundary plumbing.\n"
	    ^ "  vars WRAP-LIT-N : Nat .\n"
	    ^ "  vars WRAP-LIT-I : Int .\n"
	    ^ "  vars WRAP-LIT-NT WRAP-LIT-C : SpectecTerminal .\n"
	    ^ "  op $wrap-lit : SpectecTerminal SpectecTerminal -> SpectecTerminal .\n"
	    ^ (if wrap_lit_eqs = "" then "" else wrap_lit_eqs ^ "\n")
	    ^ "  eq $wrap-lit(WRAP-LIT-NT, WRAP-LIT-C) = WRAP-LIT-C [owise] .\n"
	    ^ "  op $raw-lit : SpectecTerminal -> SpectecTerminal .\n"
	    ^ (if raw_lit_eqs = "" then "" else raw_lit_eqs ^ "\n")
	    ^ "  eq $raw-lit(WRAP-LIT-N) = WRAP-LIT-N .\n"
	    ^ "  eq $raw-lit(WRAP-LIT-I) = WRAP-LIT-I .\n"
	    ^ "  eq $raw-lit(WRAP-LIT-C) = WRAP-LIT-C [owise] .\n"
	    ^ "  op $raw-nat-lit : SpectecTerminal -> Nat .\n"
	    ^ (if raw_nat_lit_eqs = "" then "" else raw_nat_lit_eqs ^ "\n")
	    ^ "  eq $raw-nat-lit(WRAP-LIT-N) = WRAP-LIT-N .\n"
		    ^ "  op $raw-int-lit : SpectecTerminal -> Int .\n"
		    ^ (if raw_int_lit_eqs = "" then "" else raw_int_lit_eqs ^ "\n")
		    ^ "  eq $raw-int-lit(WRAP-LIT-I) = WRAP-LIT-I .\n"
	    ^ (if wrapper_payload_typecheck_eqs = "" then "" else
	         wrapper_payload_typecheck_eqs ^ "\n")
	            ^ (if syntax_wrapper_helper_block = "" then ""
	       else "\n  --- Source-category immediate boundary helpers.\n"
	            ^ syntax_wrapper_helper_block ^ "\n")

let specialized_syntax_sort_name parent_sort terms =
  let literal_sort_from_single_axis term =
    let suffix = nullary_ctor_suffix term in
    match literal_family_of_nullary_suffix suffix with
    | Some (family_sort, numeric_tail) ->
        Some (concrete_literal_family_sort family_sort numeric_tail)
    | None -> None
  in
  match terms with
  | [term] when is_literal_family_root parent_sort ->
      (match literal_sort_from_single_axis term with
       | Some sort -> sort
       | None -> parent_sort ^ nullary_ctor_suffix term)
  | _ ->
      parent_sort ^ String.concat "" (List.map nullary_ctor_suffix terms)

let register_literal_family_alias_subsorts spec_sort =
  match literal_family_of_concrete_sort spec_sort with
  | None -> ()
  | Some (parent_family, numeric_tail) ->
      let children =
        match Hashtbl.find_opt literal_family_alias_edges parent_family with
        | Some children -> SSet.elements children
        | None -> []
      in
      List.iter
        (fun child_family ->
	          let child_sort = concrete_literal_family_sort child_family numeric_tail in
	          if child_sort <> spec_sort then
	            (specialized_syntax_sort_decls :=
	              SSet.add (Printf.sprintf "  sort %s ." child_sort)
	                (SSet.add
	                   (Printf.sprintf "  subsort %s < SpectecTerminal ." child_sort)
	                   (SSet.add
	                      (Printf.sprintf "  subsort %s < %s ." child_sort spec_sort)
	                      !specialized_syntax_sort_decls));
               add_generated_source_subsort child_sort spec_sort;
	             register_literal_wrapper_for_sort child_sort))
	        children

let register_specialized_syntax_sort parent_sort terms =
  let spec_sort = specialized_syntax_sort_name parent_sort terms in
  let parent_type_atom =
    let arity = List.length terms in
    match source_sort_type_atom_for_arity parent_sort arity with
    | Some atom -> atom
    | None ->
        (match Hashtbl.find_opt source_sort_type_atoms parent_sort with
         | Some atom -> atom
         | None -> parent_sort)
  in
  let type_term =
    match terms with
    | [] -> parent_type_atom
    | _ -> format_spectec_type_term parent_type_atom terms
  in
  Hashtbl.replace specialized_syntax_sort_type_terms spec_sort type_term;
  specialized_syntax_sort_names := SSet.add spec_sort !specialized_syntax_sort_names;
  register_literal_wrapper_for_sort spec_sort;
  specialized_syntax_sort_decls :=
    SSet.add (Printf.sprintf "  sort %s ." spec_sort)
      (SSet.add (Printf.sprintf "  subsort %s < %s ." spec_sort parent_sort)
         !specialized_syntax_sort_decls);
  add_generated_source_subsort spec_sort parent_sort;
  register_literal_family_alias_subsorts spec_sort;
  (match terms, literal_wrapper_for_sort ~register:true spec_sort with
   | [type_term], Some (wrapper, _payload_sort) ->
       Hashtbl.replace literal_wrapper_by_type_term
         (strip_wrapping_parens type_term |> String.trim)
         wrapper
   | _ -> ());
  spec_sort

let register_symbolic_syntax_type_sort parent_sort type_term =
  let key =
    Printf.sprintf "%sParam%s" parent_sort
      (String.sub (Digest.to_hex (Digest.string type_term)) 0 12)
  in
  Hashtbl.replace specialized_syntax_sort_type_terms key type_term;
  specialized_syntax_sort_names := SSet.add key !specialized_syntax_sort_names;
  key

let is_plural_type name = Hashtbl.mem plural_types name

(* ========================================================================= *)
(* 4. Mixfix operator interleaving                                           *)
(* ========================================================================= *)

let mixop_sections (mixop : Xl.Mixop.mixop) =
  source_ctor_sections_from_mixop mixop

let canonical_ctor_name_arity (mixop : Xl.Mixop.mixop) arity =
  source_ctor_name_from_mixop mixop arity

let mixop_is_source_semicolon_pair (mixop : Xl.Mixop.mixop) arity =
  arity = 2
  && List.exists (fun section -> section = "semicolon") (mixop_sections mixop)

let format_source_semicolon_pair arg_texts =
  match arg_texts with
  | [lhs; rhs] -> Some (Printf.sprintf "( %s ; %s )" lhs rhs)
  | _ -> None

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
  source_ctor_interleave_op sections n_vars

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

let flat_source_param_typs case_typ =
  let rec scan t =
    match t.it with
    | TupT fields ->
        fields |> List.concat_map (fun (_, ft) -> scan ft)
    | IterT (_, Opt) -> [t]
    | IterT (_, (List | List1 | ListN _)) -> [t]
    | VarT _ -> [t]
    | _ -> []
  in
  scan case_typ

let optional_empty_term_for_param_index case_typ index vm =
  match List.nth_opt (flat_source_param_typs case_typ) index with
  | Some typ -> optional_empty_term_for_typ typ vm
  | None -> "eps"

(* ========================================================================= *)
(* 5. Declaration management                                                 *)
(*                                                                           *)
(* [declared_vars] is intentionally mutable shared state:  declarations are  *)
(* global within a single Maude module and must be deduplicated.             *)
(* ========================================================================= *)

let declared_vars : (string, string) Hashtbl.t = Hashtbl.create 2048

let helper_sort_of_var v =
  match Hashtbl.find_opt source_var_sorts v with
  | Some sort -> semantic_sort_of_source_sort sort
  | None ->
      (match Hashtbl.find_opt declared_vars v with
       | Some sort -> semantic_sort_of_source_sort sort
       | None -> "SpectecTerminal")

let normalize_decl_sort name sort =
  match !source_var_sort_lookup name with
  | Some source_sort -> semantic_sort_of_source_sort source_sort
  | None ->
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

let typed_index_pattern full_type_sort lhs rhs preserve_source_sort_indices params =
  let broad_of i _v =
    "TYPED-INDEX-" ^ String.uppercase_ascii full_type_sort ^ "-P" ^
    string_of_int i
  in
  let replacements =
    params
    |> List.mapi (fun i (v, _, ms) -> (v, broad_of i v, ms))
  in
  let replace_all text =
    List.fold_left
      (fun acc (old_v, broad_v, _) -> replace_maude_var_token old_v broad_v acc)
      text replacements
  in
  let decls =
    replacements
    |> List.mapi (fun i (_, broad_v, ms) ->
         let sort =
           if List.mem i preserve_source_sort_indices then ms
           else "SpectecTerminal"
         in
         declare_var broad_v sort)
    |> String.concat ""
  in
  let rhs' = replace_all rhs in
  (* $typed-index is a representation helper for source meta-expressions like
     xs[i] when xs is a flat sequence of composite source elements.  The type
     tag (for example tabletype) determines the element width.  Re-checking
     each component with membership conditions makes legacy prefix-call
     renderings fail to match because many source
     categories are represented by membership axioms over the broad terminal
     carrier rather than by constructor result sorts.  Optional-prefix
     positions are the exception: keeping their source sort prevents the
     non-optional typed-index equation from swallowing the optional-empty
     case after eps is normalized away. *)
  let cond = cond_join [rhs'] in
  (decls, replace_all lhs, cond)

let _declare_op_const name sort =
  if Hashtbl.mem declared_vars name then ""
  else (Hashtbl.replace declared_vars name sort;
        Printf.sprintf "  op %s : -> %s .\n" name sort)

let declare_batch emit names sort =
  let listn_decl_sort name default_sort =
    let source_name =
      if starts_with name "FREE-"
      then String.sub name 5 (String.length name - 5)
      else name
    in
    if SSet.mem source_name !listn_index_vars then "Nat" else default_sort
  in
  let fresh = names
    |> List.sort_uniq String.compare
    |> List.filter (fun n -> not (Hashtbl.mem declared_vars n))
  in
  let fresh = List.map (fun n -> (n, normalize_decl_sort n sort)) fresh in
  List.iter (fun (n, s) -> Hashtbl.replace declared_vars n s) fresh;
  match emit, fresh with
  | _, [] -> ""
  | `Vars, _ ->
      let op_consts, vars =
        fresh
        |> List.partition (fun (n, _) -> SSet.mem n !listn_index_vars)
      in
      let groups =
        List.fold_left (fun acc (n, s) ->
          let existing = match List.assoc_opt s acc with Some vs -> vs | None -> [] in
          (s, n :: existing) :: List.remove_assoc s acc
        ) [] vars
      in
      let var_decls =
        groups
        |> List.map (fun (s, vs) ->
             Printf.sprintf "  vars %s : %s .\n" (String.concat " " (List.rev vs)) s)
        |> String.concat ""
      in
      let op_decls =
        op_consts
        |> List.map (fun (n, s) ->
             Printf.sprintf "  op %s : -> %s .\n" n (listn_decl_sort n s))
        |> String.concat ""
      in
      var_decls ^ op_decls
  | `Ops, _ -> String.concat "" (List.map (fun (n, s) ->
      let s = listn_decl_sort n s in
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

let collect_source_ctor_head_categories defs =
  let arity_of_typ t =
    match t.it with
    | TupT fields -> List.length fields
    | _ -> 1
  in
  let signature_of_typ t =
    Il.Print.string_of_typ t
  in
  let add_occurrence sections category case_typ =
    register_source_ctor_head_category sections category;
    match source_ctor_surface_op_head sections with
    | None -> ()
    | Some head ->
        let arity = arity_of_typ case_typ in
        let category_key = source_ctor_head_category_key head category in
        let arities =
          match Hashtbl.find_opt source_ctor_head_category_arities category_key with
          | Some xs -> xs
          | None -> []
        in
        if not (List.mem arity arities) then
          Hashtbl.replace source_ctor_head_category_arities category_key (arity :: arities);
        let old =
          match Hashtbl.find_opt source_ctor_head_occurrences head with
          | Some xs -> xs
          | None -> []
        in
        Hashtbl.replace source_ctor_head_occurrences head
          ((arity, signature_of_typ case_typ,
            maude_source_op_token category) :: old)
  in
  let rec scan d =
    match d.it with
    | RecD ds -> List.iter scan ds
    | TypD (id, _params, insts) ->
        List.iter
          (fun inst ->
            match inst.it with
            | InstD (_, _, deftyp) ->
                (match deftyp.it with
                 | VariantT cases ->
                     List.iter
                       (fun (mixop_val, (_, case_typ, _prems), _) ->
                         let sections = source_ctor_sections_from_mixop mixop_val in
                         if source_ctor_components_from_sections sections <> [] then
                           add_occurrence sections id.it case_typ)
                       cases
                 | AliasT _ | StructT _ -> ())
          )
          insts
    | DecD _ | RelD _ | GramD _ | HintD _ -> ()
  in
  List.iter scan defs;
  Hashtbl.iter
    (fun head occs ->
       let categories =
         occs
         |> List.map (fun (_, _, category) -> category)
         |> List.sort_uniq String.compare
       in
       let arities =
         occs
         |> List.map (fun (arity, _, _) -> arity)
         |> List.sort_uniq compare
       in
       let signature_conflict =
         arities
         |> List.exists (fun arity ->
              occs
              |> List.filter (fun (a, _, _) -> a = arity)
              |> List.map (fun (_, signature, _) -> signature)
              |> List.sort_uniq String.compare
              |> List.length
              |> fun n -> n > 1)
       in
       let multi_shape =
         List.length categories > 1 && List.length arities > 1
       in
       if signature_conflict || multi_shape then
         source_ctor_heads_requiring_category_suffix :=
           SSet.add head !source_ctor_heads_requiring_category_suffix)
    source_ctor_head_occurrences
  ;
  Hashtbl.iter
    (fun key arities ->
       if List.mem 0 arities && List.exists (fun arity -> arity > 0) arities then
         source_ctor_head_categories_requiring_arg_suffix :=
           SSet.add key !source_ctor_head_categories_requiring_arg_suffix)
    source_ctor_head_category_arities

let build_token_ops ss =
  let source_type_atoms = source_type_atom_tokens () in
  let toks =
    SSet.diff ss.tokens ss.ctors
    |> fun toks -> SSet.diff toks source_type_atoms
    |> SSet.elements
    |> List.filter (fun t ->
         not (is_source_ctor_var_token t || is_source_ctor_name t))
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
         not (SSet.mem name ss.dec_funcs)
         && not (SSet.mem name ss.ctors)
         && arity >= 0)
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
      Printf.sprintf "%s(%s)" fn (String.concat ", " (List.map norm_arg args))

let erase_source_typ_param_args fn args =
  match Hashtbl.find_opt source_typ_param_positions fn with
  | None -> args
  | Some positions ->
      args
      |> List.mapi (fun i arg -> if List.mem i positions then None else Some arg)
      |> List.filter_map (fun x -> x)

let format_source_call fn args =
  format_call fn (erase_source_typ_param_args fn args)

let is_literal_wrapper_call text =
  let text = strip_wrapping_parens text |> String.trim in
  let dynamic_wrappers =
    Hashtbl.to_seq_keys literal_wrapper_payload_sorts |> List.of_seq
  in
  let fallback_literal_wrapper =
    match head_symbol_of_text text with
    | Some head ->
        let re = Str.regexp "^lit[UF][0-9]+$" in
        Str.string_match re head 0
    | None -> false
  in
  fallback_literal_wrapper
  || List.exists
       (fun prefix -> starts_with text (prefix ^ " (") || starts_with text (prefix ^ "("))
       dynamic_wrappers

let is_category_wrapper_call text =
  match head_symbol_of_text text with
  | Some head -> starts_with head "$wrap-"
  | None -> false

let is_sequence_ctor_call text =
  match head_symbol_of_text text with
  | Some head ->
      starts_with head "nil"
      || starts_with head "cons"
      || starts_with head "one"
      || (starts_with head "_++" && ends_with head "Seq_")
  | None -> false

let is_sequence_map_call text =
  match head_symbol_of_text text with
  | Some head ->
      List.exists (fun h -> h.map_helper_name = head) !map_call_helpers
      || List.exists (fun h -> h.zip_map_helper_name = head) !zip_map_call_helpers
  | None -> false

let is_raw_numeric_text text =
  let text = strip_wrapping_parens text |> String.trim in
  let is_int_lit =
    Str.string_match (Str.regexp "^-?[0-9]+$") text 0
  in
  is_int_lit
  || List.exists (fun prefix -> starts_with text prefix)
       ["_+_"; "_-_"; "_*_"; "_quo_"; "_rem_"]
  ||
  match head_symbol_of_text text with
  | Some head ->
      List.mem head ["_+_"; "_-_"; "_*_"; "_quo_"; "_rem_"; "len"; "$raw-lit"]
  | None -> false

let source_sort_of_plain_text_var text =
  let core = strip_wrapping_parens text |> String.trim in
	  if is_plain_var_like core then
	    match Hashtbl.find_opt declared_vars core with
	    | Some sort -> Some (semantic_sort_of_source_sort sort)
	    | None ->
	        Option.map semantic_sort_of_source_sort
	          (Hashtbl.find_opt source_var_sorts core)
	  else None

let declared_sequence_sort_matches declared_sort seq_sort =
  declared_sort = seq_sort
  ||
  (match Hashtbl.find_opt sequence_alias_elem_sorts declared_sort with
   | Some elem_sort -> native_sequence_sort_name elem_sort = seq_sort
   | None -> false)

let source_sequence_sort_of_plain_text_var text =
  let core = strip_wrapping_parens text |> String.trim in
  if is_plain_var_like core then
    match Hashtbl.find_opt source_var_seq_elem_sorts core with
    | Some elem_sort -> Some (native_sequence_sort_name elem_sort)
    | None ->
        (match source_sort_of_plain_text_var core with
         | Some declared_sort when ends_with declared_sort "Seq" -> Some declared_sort
         | Some declared_sort ->
             (match Hashtbl.find_opt sequence_alias_elem_sorts declared_sort with
              | Some elem_sort -> Some (native_sequence_sort_name elem_sort)
              | None -> None)
         | None -> None)
  else None

let elem_sort_of_sequence_sort seq_sort =
  if ends_with seq_sort "Seq" && String.length seq_sort > 3 then
    Some (String.sub seq_sort 0 (String.length seq_sort - 3))
  else None

let rec source_subsort_transitively child parent =
  child = parent
  ||
  match Hashtbl.find_opt source_category_subsort_edges child with
  | None -> false
  | Some parents ->
      SSet.mem parent parents
      || SSet.exists (fun p -> source_subsort_transitively p parent) parents

let sequence_sort_compatible child_seq parent_seq =
  child_seq = parent_seq
  ||
  match elem_sort_of_sequence_sort child_seq, elem_sort_of_sequence_sort parent_seq with
  | Some child, Some parent -> source_subsort_transitively child parent
  | _ -> false

let registered_sequence_sort seq_sort =
  if not (ends_with seq_sort "Seq") then false
  else
    let source_sort =
      String.sub seq_sort 0 (String.length seq_sort - 3)
    in
    SSet.mem source_sort !native_sequence_source_sorts

let sequence_sort_for_elem_sort elem_sort =
  let seq_sort = native_sequence_sort_name elem_sort in
  if registered_sequence_sort seq_sort then Some seq_sort else None

let scalar_result_sort_of_call fn =
  match Hashtbl.find_opt source_def_return_sorts fn with
  | Some sort -> Some sort
  | None ->
      (match Hashtbl.find_opt ctor_result_sort_hints fn with
       | None -> None
       | Some sorts ->
           let candidates =
             sorts
             |> SSet.elements
             |> List.filter (fun sort ->
                 sort <> "SpectecTerminal"
                 && sequence_sort_for_elem_sort sort <> None)
           in
           match candidates with
           | [sort] -> Some sort
           | sort :: _ ->
               (* Prefer the most specific known result sort.  Constructor result
                  hints can include inherited categories such as Instr/Val; the
                  source constructor category is the one that is not merely an
                  ancestor of another candidate. *)
               let is_ancestor a b = a <> b && source_subsort_transitively b a in
               let chosen =
                 candidates
                 |> List.find_opt (fun sort ->
                     not (List.exists (fun other -> is_ancestor sort other) candidates))
                 |> Option.value ~default:sort
               in
               Some chosen
           | [] -> None)

let map_helper_output_seq_sort h =
  match Hashtbl.find_opt source_def_return_sorts h.map_helper_name with
  | Some seq_sort when registered_sequence_sort seq_sort -> Some seq_sort
  | _ ->
      (match scalar_result_sort_of_call h.map_fn_name with
       | Some seq_sort when registered_sequence_sort seq_sort -> Some seq_sort
       | Some sort -> sequence_sort_for_elem_sort sort
       | None -> None)

let sequence_sort_of_call_text fn =
  match List.find_opt (fun h -> h.map_helper_name = fn) !map_call_helpers with
  | Some h -> map_helper_output_seq_sort h
  | None ->
      (match Hashtbl.find_opt source_def_return_sorts fn with
       | Some seq_sort when registered_sequence_sort seq_sort -> Some seq_sort
       | Some sort -> sequence_sort_for_elem_sort sort
       | None ->
           (match scalar_result_sort_of_call fn with
            | Some seq_sort when registered_sequence_sort seq_sort -> Some seq_sort
            | Some sort -> sequence_sort_for_elem_sort sort
            | None -> None))

let sequence_sort_of_text text =
  let text = strip_wrapping_parens text |> String.trim in
  if text = "eps" then None
  else
    let nil_sort =
      !native_sequence_source_sorts
      |> SSet.elements
      |> List.find_map (fun source_sort ->
           let seq_sort = native_sequence_sort_name source_sort in
           if text = sequence_nil_name seq_sort then Some seq_sort else None)
    in
    match nil_sort with
    | Some seq_sort -> Some seq_sort
    | None ->
    match source_sequence_sort_of_plain_text_var text with
    | Some seq_sort -> Some seq_sort
    | None ->
        (match parse_call_text text with
         | Some (fn, _) -> sequence_sort_of_call_text fn
         | None -> None)

let rec source_sequence_items_from_terms terms =
  let take_drop n xs =
    let rec loop i taken rest =
      if i = 0 then (List.rev taken, rest)
      else match rest with
        | [] -> (List.rev taken, [])
        | y :: ys -> loop (i - 1) (y :: taken) ys
    in
    loop n [] xs
  in
  let source_typ_is_sequence_field (t : typ) =
    match t.it with
    | IterT (_, (List | List1 | ListN _ | Opt)) -> true
    | TupT _ -> true
    | _ ->
        (match simple_sort_of_typ t [] with
         | Some s ->
             ends_with s "Seq"
             || SSet.mem s !sequence_alias_sorts
             || SSet.mem s !flat_sequence_source_sorts
         | None -> false)
  in
  let source_sort_is_sequence_field sort =
    sort = "SpectecTerminals"
    || ends_with sort "Seq"
    || SSet.mem sort !sequence_alias_sorts
    || SSet.mem sort !flat_sequence_source_sorts
  in
  let source_ctor_fields_are_nonsequence ctor arity =
    let from_sorts sorts =
      if List.length sorts = arity then
        Some (not (List.exists source_sort_is_sequence_field sorts))
      else None
    in
    match
      match Hashtbl.find_opt ctor_arg_membership_sort_hints ctor with
      | Some sorts -> from_sorts sorts
      | None -> None
    with
    | Some result -> result
    | None ->
        (match
           match Hashtbl.find_opt ctor_arg_sort_hints ctor with
           | Some sorts -> from_sorts sorts
           | None -> None
         with
         | Some result -> result
         | None ->
             !source_compound_cases
             |> List.find_map (fun c ->
                  if c.compound_ctor = ctor
                     && List.length c.compound_fields = arity
                  then
                    Some
                      (not
                         (List.exists
                            (fun (_, field_typ) ->
                              source_typ_is_sequence_field field_typ)
                            c.compound_fields))
                  else None)
             |> Option.value ~default:false)
  in
  let split_wrapped_ctor_prefix term =
    let term = String.trim term in
    let inner = strip_wrapping_parens term |> String.trim in
    if inner = term then None
    else
      let inner_terms = split_top_level_terms_preserve_eps inner in
      let rec find_prefix n =
        if n >= List.length inner_terms then None
        else
          let prefix_terms, rest_terms = take_drop n inner_terms in
          match strict_source_ctor_terms prefix_terms with
          | Some (ctor, args)
              when args <> []
                   && source_ctor_fields_are_nonsequence ctor (List.length args)
                   && rest_terms <> [] ->
              let prefix = String.concat " " prefix_terms |> String.trim in
              Some (wrap_paren prefix, rest_terms)
          | _ -> find_prefix (n + 1)
      in
      find_prefix 1
  in
  let rec find_ctor_prefix n =
    if n > List.length terms then None
    else
      let prefix_terms, rest = take_drop n terms in
      let prefix = String.concat " " prefix_terms |> String.trim in
      match strict_source_ctor_terms prefix_terms with
      | Some (_, _ :: _) -> Some (prefix, rest)
      | _ -> find_ctor_prefix (n + 1)
  in
  match terms with
  | [] -> []
  | term :: rest ->
      (match split_wrapped_ctor_prefix term with
       | Some (prefix, rest_terms) ->
           prefix :: source_sequence_items_from_terms (rest_terms @ rest)
       | None ->
      (match find_ctor_prefix 1 with
       | Some (prefix, rest_terms) ->
           let already_wrapped =
             String.length prefix >= 2 && prefix.[0] = '('
             && prefix.[String.length prefix - 1] = ')'
           in
           (if already_wrapped then prefix else wrap_paren prefix)
           :: source_sequence_items_from_terms rest_terms
       | None ->
           term :: source_sequence_items_from_terms rest))

let source_sequence_item_text text =
  let text = String.trim text in
  let terms = split_top_level_terms_preserve_eps text in
  match source_sequence_items_from_terms terms with
  | [] -> text
  | [single] -> single
  | items ->
      String.concat " " items

let source_sequence_concat_texprs ts =
  { text =
      ts
      |> List.map (fun t -> source_sequence_item_text t.text)
      |> String.concat " ";
    vars = List.concat_map (fun t -> t.vars) ts }

let concat_sequence_text seq_sort left right =
  let left = strip_wrapping_parens left |> String.trim in
  let right = strip_wrapping_parens right |> String.trim in
  let is_nil_for_seq term =
    term = "" || term = "eps" ||
    (starts_with term "eps"
     && ends_with term "Seq"
     && String.length term > 3) ||
    match sequence_sort_of_text term with
    | Some term_seq_sort ->
        term = sequence_nil_name term_seq_sort
        && sequence_sort_compatible term_seq_sort seq_sort
    | None -> false
  in
  if is_nil_for_seq left then right
  else if is_nil_for_seq right then left
  else
    Printf.sprintf "%s %s"
      (source_sequence_item_text left)
      (source_sequence_item_text right)

let concat_texprs_preserving_sequence t1 t2 =
  { text =
      Printf.sprintf "%s %s"
        (source_sequence_item_text t1.text)
        (source_sequence_item_text t2.text);
    vars = t1.vars @ t2.vars }

let sequence_term_for_sort seq_sort arg =
  let core = String.trim arg in
  if core = "" || core = "eps" then "eps"
  else if core = sequence_nil_name seq_sort then "eps"
  else source_sequence_item_text core

let rec normalize_sequence_concats_in_text seq_sort text =
  let core = String.trim text in
  match parse_call_text core with
  | Some (fn, [left; right]) when fn = sequence_concat_name seq_sort ->
      concat_sequence_text seq_sort
        (normalize_sequence_concats_in_text seq_sort left)
        (normalize_sequence_concats_in_text seq_sort right)
  | Some (fn, [left; right]) when sequence_sort_of_concat_name fn <> None ->
      concat_sequence_text seq_sort
        (normalize_sequence_concats_in_text seq_sort left)
        (normalize_sequence_concats_in_text seq_sort right)
  | None -> core
  | _ -> core

let is_typed_sequence_nil_text text =
  let text = strip_wrapping_parens text |> String.trim in
  starts_with text "eps" && ends_with text "Seq" && String.length text > 3

let rec normalize_empty_sequence_nil_conditions text =
  let core = strip_wrapping_parens text |> String.trim in
  if contains_substring core ":=" || contains_substring core "=>" then core
  else match parse_call_text core with
  | Some (fn, [left; right]) when fn = "_=/=_" || fn = "_==_" ->
      let left = normalize_empty_sequence_nil_conditions left in
      let right = normalize_empty_sequence_nil_conditions right in
      if (is_typed_sequence_nil_text left && String.trim right = "eps")
         || (String.trim left = "eps" && is_typed_sequence_nil_text right)
      then if fn = "_=/=_" then "false" else "true"
      else format_call fn [left; right]
  | Some (fn, args) when fn = "_or_" || fn = "_and_" ->
      let args =
        List.map normalize_empty_sequence_nil_conditions args
        |> List.map String.trim
      in
      (match fn, args with
       | "_or_", ["false"; "false"] -> "false"
       | "_or_", ["false"; x] | "_or_", [x; "false"] -> x
       | "_or_", ["true"; _] | "_or_", [_; "true"] -> "true"
       | "_and_", ["false"; _] | "_and_", [_; "false"] -> "false"
       | "_and_", ["true"; x] | "_and_", [x; "true"] -> x
       | _ -> format_call fn args)
  | Some (_fn, args) ->
      let _ = args in
      core
  | None -> core

let normalize_sequence_eps_conditions typed_vars text =
  let is_seq_var text =
    let text = strip_wrapping_parens text |> String.trim in
    match List.assoc_opt text typed_vars with
    | Some sort -> sort = "SpectecTerminals" || ends_with sort "Seq"
    | None -> false
  in
  let rec go text =
    let core = strip_wrapping_parens text |> String.trim in
    if contains_substring core ":=" || contains_substring core "=>" then core
    else match parse_call_text core with
    | Some (fn, [left; right]) when fn = "_=/=_" || fn = "_==_" ->
        let left = go left in
        let right = go right in
        let left_is_eps = String.trim left = "eps" in
        let right_is_eps = String.trim right = "eps" in
        if (is_typed_sequence_nil_text left && right_is_eps)
           || (left_is_eps && is_typed_sequence_nil_text right)
        then if fn = "_=/=_" then "false" else "true"
        else if is_seq_var left && right_is_eps then
          if fn = "_=/=_" then format_call "_>_" [format_call "len" [left]; "0"]
          else format_call "_==_" [format_call "len" [left]; "0"]
        else if left_is_eps && is_seq_var right then
          if fn = "_=/=_" then format_call "_>_" [format_call "len" [right]; "0"]
          else format_call "_==_" [format_call "len" [right]; "0"]
        else format_call fn [left; right]
    | Some (fn, args) when fn = "_or_" || fn = "_and_" ->
        let args = List.map go args |> List.map String.trim in
        (match fn, args with
         | "_or_", ["false"; "false"] -> "false"
         | "_or_", ["false"; x] | "_or_", [x; "false"] -> x
         | "_or_", ["true"; _] | "_or_", [_; "true"] -> "true"
         | "_and_", ["false"; _] | "_and_", [_; "false"] -> "false"
         | "_and_", ["true"; x] | "_and_", [x; "true"] -> x
         | _ -> format_call fn args)
    | Some (_fn, _args) -> core
    | None -> core
  in
  go text

let wrap_const_payload_for_type nt payload =
  if is_literal_wrapper_call payload then payload
  else
    let nt_key = strip_wrapping_parens nt |> String.trim in
    if !wrap_generic_const_payloads then
      format_call "$wrap-lit" [nt; payload]
    else
    match Hashtbl.find_opt literal_wrapper_by_type_term nt_key with
    | Some wrapper -> format_call wrapper [payload]
    | None -> payload

let apply_ctor_literal_type_dependencies ctor args =
  match Hashtbl.find_opt ctor_arg_literal_type_dependencies ctor with
  | None -> args
  | Some deps ->
      List.mapi
        (fun arg_index arg ->
          match List.find_opt (fun (payload_i, _) -> payload_i = arg_index) deps with
          | Some (_, type_i) ->
              (match List.nth_opt args type_i with
               | Some nt -> wrap_const_payload_for_type nt arg
	               | None -> arg)
	          | None -> arg)
	        args

let broad_source_ctor_field_sort_of_typ (t : typ) =
  match t.it with
  | IterT (_, (List | List1 | ListN _ | Opt)) -> "SpectecTerminals"
  | TupT _ -> "SpectecTerminals"
  | _ ->
      (match simple_sort_of_typ t [] with
       | Some s when SSet.mem s !flat_sequence_source_sorts -> "SpectecTerminals"
       | Some s when SSet.mem s !sequence_alias_sorts -> "SpectecTerminals"
       | Some ("Nat" | "Int" | "Bool" as s) -> s
       | Some s when ends_with s "Seq" -> "SpectecTerminals"
       | _ -> "SpectecTerminal")

let ctor_arg_source_sorts ctor =
  let arity = source_ctor_arity ctor in
  let from_membership = Hashtbl.find_opt ctor_arg_membership_sort_hints ctor in
  let from_decl = Hashtbl.find_opt ctor_arg_sort_hints ctor in
  let from_source_case =
    match arity with
    | Some n ->
        !source_compound_cases
        |> List.find_map (fun c ->
             if c.compound_ctor = ctor && List.length c.compound_fields = n then
               Some
                 (c.compound_fields
                  |> List.map (fun (_, field_typ) ->
                       broad_source_ctor_field_sort_of_typ field_typ))
             else None)
    | None -> None
  in
  match arity, from_membership, from_decl with
  | Some n, Some sorts, _ when List.length sorts = n -> Some sorts
  | Some n, _, Some sorts when List.length sorts = n -> Some sorts
  | Some n, _, _ ->
      (match from_source_case with
       | Some sorts when List.length sorts = n -> Some sorts
       | _ -> None)
  | _, Some sorts, _ -> Some sorts
  | _, _, Some sorts -> Some sorts
  | _, _, _ -> from_source_case

let ctor_arg_sort_can_default_to_eps sort =
  sort = "SpectecTerminals"
  || ends_with sort "Seq"
  || SSet.mem sort !sequence_alias_sorts
  || SSet.mem sort !flat_sequence_source_sorts

let pad_omitted_ctor_sequence_args ctor args =
  match source_ctor_arity ctor, ctor_arg_source_sorts ctor with
  | Some arity, Some sorts
      when List.length sorts = arity && List.length args < arity ->
      let rec required_non_default = function
        | [] -> 0
        | sort :: rest ->
            (if ctor_arg_sort_can_default_to_eps sort then 0 else 1)
            + required_non_default rest
      in
      let rec fill sorts args =
        match sorts, args with
        | [], [] -> Some []
        | [], _ :: _ -> None
        | sort :: rest_sorts, _ ->
            let can_default = ctor_arg_sort_can_default_to_eps sort in
            let required_after = required_non_default rest_sorts in
            if can_default && List.length args <= required_after then
              (match fill rest_sorts args with
               | Some filled -> Some ("eps" :: filled)
               | None -> None)
            else
              (match args with
               | arg :: rest_args ->
                   (match fill rest_sorts rest_args with
                    | Some filled -> Some (arg :: filled)
                    | None -> None)
               | [] when can_default ->
                   (match fill rest_sorts [] with
                    | Some filled -> Some ("eps" :: filled)
                    | None -> None)
               | [] -> None)
      in
      (match fill sorts args with
       | Some padded when List.length padded = arity -> padded
       | _ -> args)
  | _ -> args

let split_ctor_nonsequence_arg_tails ctor args =
  match ctor_arg_source_sorts ctor with
  | Some sorts when List.length sorts = List.length args ->
      let arg_is_complete_source_ctor arg =
        parse_source_ctor_surface_text arg <> None
        ||
        match split_top_level_terms_preserve_eps arg |> strict_source_ctor_terms with
        | Some _ -> true
        | None -> false
      in
      let split_one sort arg =
        let arg = String.trim arg in
        let wrapped =
          arg <> "" && strip_wrapping_parens arg <> arg
        in
        if wrapped
           || ctor_arg_sort_can_default_to_eps sort
           || arg_is_complete_source_ctor arg
        then (arg, [])
        else
          match split_top_level_terms_preserve_eps arg with
          | first :: (_ :: _ as rest) -> (first, rest)
          | _ -> (arg, [])
      in
      let args, tails =
        List.map2 split_one sorts args
        |> List.split
      in
      (args, List.concat tails)
  | _ -> (args, [])

let arg_is_already_object_level_for_sort sort arg =
  let arg = strip_wrapping_parens arg |> String.trim in
  is_literal_wrapper_call arg
  || is_category_wrapper_call arg
  || (is_plain_var_like arg
      &&
      match source_sort_of_plain_text_var arg with
      | Some ("Nat" | "Int" | "SpectecTerminal") | None -> false
      | Some declared_sort -> declared_sort = sort || literal_wrapper_for_sort declared_sort <> None)

let sort_denotes_raw_numeric_payload sort =
  sort = "Nat"
  || sort = "Int"
  || literal_wrapper_for_sort sort <> None
  ||
  let type_atom =
    match Hashtbl.find_opt source_sort_type_atoms sort with
    | Some atom -> atom
    | None -> sort
  in
  SSet.mem sort !raw_payload_type_terms
  || SSet.mem type_atom !raw_payload_type_terms

let rec raw_literal_text_for_numeric_context text =
  let core = strip_wrapping_parens text |> String.trim in
  let numeric_call fn =
    List.mem fn ["_+_"; "_-_"; "_*_"; "_quo_"; "_rem_"; "_^_"]
  in
  let sort_is_sequence_like sort =
    sort = "SpectecTerminals"
    || ends_with sort "Seq"
    || SSet.mem sort !sequence_alias_sorts
    || SSet.mem sort !flat_sequence_source_sorts
  in
  if core = "eps"
     || is_typed_sequence_nil_text core
     || sequence_sort_of_text core <> None
  then text
  else match parse_call_text core with
  | Some (fn, args) when numeric_call fn ->
      format_call fn (List.map raw_literal_text_for_numeric_context args)
  | _ when is_plain_var_like core ->
    (match source_sort_of_plain_text_var core with
    | _ when Hashtbl.mem source_var_optional_elem_sorts core ->
        format_call "$raw-lit" [format_call "index" [core; "0"]]
    | _ when
        (match Hashtbl.find_opt source_var_seq_elem_sorts core with
         | Some elem_sort when sort_denotes_raw_numeric_payload elem_sort -> true
         | _ -> false) ->
        format_call "$raw-lit" [format_call "index" [core; "0"]]
    | Some sort when sort_is_sequence_like sort -> text
    | _ when Hashtbl.mem source_var_seq_elem_sorts core -> text
    | Some sort when literal_wrapper_for_sort sort <> None ->
        format_call "$raw-lit" [core]
	    | Some "SpectecTerminal" ->
	        format_call "$raw-lit" [core]
	    | None ->
	        format_call "$raw-lit" [core]
	    | Some ("Nat" | "Int") -> text
    | Some sort ->
        let type_atom =
          match Hashtbl.find_opt source_sort_type_atoms sort with
          | Some atom -> atom
          | None -> sort
        in
        if SSet.mem sort !raw_payload_type_terms
           || SSet.mem type_atom !raw_payload_type_terms
        then format_call "$raw-lit" [core]
        else format_call "$raw-lit" [core])
  | _ when is_literal_wrapper_call core || is_category_wrapper_call core ->
    format_call "$raw-lit" [core]
  | _ when starts_with core "value(" || starts_with core "value (" ->
    format_call "$raw-lit" [core]
  | _ -> text

let raw_literal_texpr_for_numeric_context t =
  { t with text = raw_literal_text_for_numeric_context t.text }

let source_sort_of_plain_texpr_var (t : texpr) =
  let core = strip_wrapping_parens t.text |> String.trim in
  if is_plain_var_like core then source_sort_of_plain_text_var core else None

let wrap_numeric_texpr_for_source_target (target : texpr) (value : texpr) =
  let raw_value = raw_literal_texpr_for_numeric_context value in
  match source_sort_of_plain_texpr_var target with
  | Some ("Nat" | "Int") | None -> raw_value
  | Some sort ->
      (match syntax_wrapper_helper_for_sort sort with
       | Some (helper, _wrapper, _payload_sort) ->
           { raw_value with text = format_call helper [raw_value.text] }
       | None -> raw_value)

let wrap_source_arg_for_sort sort arg =
  if ends_with sort "Seq" then
    sequence_term_for_sort sort arg
  else
  match syntax_wrapper_helper_for_sort sort with
  | Some (helper, _wrapper, _payload_sort)
      when (not (arg_is_already_object_level_for_sort sort arg))
           && (is_raw_numeric_text arg
               || (is_plain_var_like arg
                   &&
                   match source_sort_of_plain_text_var arg with
                   | Some ("Nat" | "Int") -> true
                   | _ -> false)) ->
      format_call helper [arg]
  | _ -> arg

let wrap_source_def_arg_for_sort sort arg =
  if ends_with sort "Seq" then
    sequence_term_for_sort sort arg
  else if sort_denotes_raw_numeric_payload sort then
    raw_literal_text_for_numeric_context arg
  else
    wrap_source_arg_for_sort sort arg

let format_source_ctor_call ctor args =
  let args = pad_omitted_ctor_sequence_args ctor args in
  let args = apply_ctor_literal_type_dependencies ctor args in
  let args =
    match Hashtbl.find_opt ctor_arg_membership_sort_hints ctor with
    | Some sorts when List.length sorts = List.length args ->
        List.map2 wrap_source_arg_for_sort sorts args
    | _ -> args
  in
  match Hashtbl.find_opt source_ctor_by_name ctor with
  | None -> format_call ctor args
  | Some info -> format_call (source_ctor_op_name info) args

let format_source_def_call fn args =
  let args = erase_source_typ_param_args fn args in
  let args =
    match Hashtbl.find_opt source_def_arg_wrap_sorts fn with
    | Some sorts when List.length sorts = List.length args ->
        List.map2 wrap_source_def_arg_for_sort sorts args
    | _ -> args
  in
  format_call fn args

let register_def_apply_op apply_name arg_sorts ret_sort =
  Hashtbl.replace source_def_return_sorts apply_name ret_sort;
  let op_arg_sorts = "SpectecTerminal" :: arg_sorts in
  let decl =
    Printf.sprintf "  op %s : %s -> %s ."
      apply_name (String.concat " " op_arg_sorts) ret_sort
  in
  def_apply_op_decls := SSet.add decl !def_apply_op_decls

let register_def_tag tag =
  def_tag_decls :=
    SSet.add (Printf.sprintf "  op %s : -> SpectecTerminal [ctor] ." tag)
      !def_tag_decls

let register_def_apply_dispatch info actual_fn =
  let tag = def_tag_name actual_fn in
  register_def_tag tag;
  register_def_apply_op
    info.def_param_apply_name info.def_param_arg_sorts info.def_param_return_sort;
  let base =
    maude_symbol_component (info.def_param_apply_name ^ "-" ^ actual_fn)
    |> String.uppercase_ascii
  in
  let vars =
    List.mapi (fun i _ -> Printf.sprintf "DEFAPPLY-%s-%d" base i)
      info.def_param_arg_sorts
  in
  let var_decls =
    List.combine vars info.def_param_arg_sorts
    |> declare_vars_by_sort
  in
  let lhs = format_call info.def_param_apply_name (tag :: vars) in
  let rhs = format_source_def_call actual_fn vars in
  let eq = Printf.sprintf "%s  eq %s = %s ." var_decls lhs rhs in
  def_apply_dispatches := SSet.add eq !def_apply_dispatches

let def_apply_dispatch_block () =
  let decls =
    SSet.union !def_tag_decls !def_apply_op_decls
    |> SSet.elements
    |> String.concat "\n"
  in
  let eqs = !def_apply_dispatches |> SSet.elements |> String.concat "\n" in
  if decls = "" && eqs = "" then ""
  else
    "\n  --- Source-derived def-parameter dispatch.\n"
    ^ (if decls = "" then "" else decls ^ "\n")
    ^ (if eqs = "" then "" else eqs ^ "\n")

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

let strip_source_index_suffix raw =
  let re = Str.regexp "^\\(.+\\)_[0-9]+$" in
  if Str.string_match re raw 0 then
    match str_matched_group_opt 1 raw with Some s -> s | None -> raw
  else raw

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
  let raw0 = strip_iter_suffix raw in
  let raw =
    let carrier =
      simple_sort_of_typ typ []
      |> Option.map semantic_sort_of_source_sort
    in
    let strip_prefixed_meta_name prefix expected_carrier =
      let plen = String.length prefix in
      let lower = String.lowercase_ascii raw0 in
      if starts_with lower prefix && String.length raw0 > plen then
        let tail = String.sub raw0 plen (String.length raw0 - plen) in
        let tail_source, tail_suffix = split_numeric_suffix tail in
        let tail_sort = sort_of_type_name tail_source in
        let matches_source_decl =
          match meta_numeric_carrier_sort tail_sort with
          | Some carrier -> carrier = expected_carrier
          | None -> false
        in
        let matches_binder_type =
          match carrier with
          | Some carrier -> carrier = expected_carrier
          | None -> false
        in
        if matches_source_decl || matches_binder_type
        then tail_source ^ tail_suffix
        else raw0
      else raw0
    in
    match carrier with
    | Some "Nat" -> strip_prefixed_meta_name "nat-" "Nat"
    | Some "Int" -> strip_prefixed_meta_name "int-" "Int"
    | _ ->
        let nat = strip_prefixed_meta_name "nat-" "Nat" in
        if nat <> raw0 then nat
        else
          let int_ = strip_prefixed_meta_name "int-" "Int" in
          if int_ <> raw0 then int_ else raw0
  in
  if is_sequence_typ typ then pluralize_sequence_var_source_name raw
  else raw

let find_vm_case_insensitive name vm =
  match List.find_opt (fun (k, _) -> k = name) vm with
  | Some (_, mapped) -> Some mapped
  | None ->
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

let record_listn_index_var vm id =
  match resolve_var_name id.it vm with
  | Some mapped -> listn_index_vars := SSet.add mapped !listn_index_vars
  | None -> ()

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

let source_expected_sort_of_typ typ vm =
  let meaningful = function
    | Some ("SpectecTerminal" | "SpectecTerminals") -> None
    | other -> other
  in
  match sequence_sort_of_typ typ vm with
  | Some seq_sort -> meaningful (Some seq_sort)
  | None -> meaningful (simple_sort_of_typ typ vm)

let precise_source_sort_of_field_typ typ =
  match sequence_sort_of_typ typ [] with
  | Some seq_sort -> Some seq_sort
  | None ->
      (match simple_sort_of_typ typ [] with
       | Some ("SpectecTerminal" | "SpectecTerminals") -> None
       | other -> other)

let source_sort_is_sequence_like sort =
  sort = "SpectecTerminals"
  || ends_with sort "Seq"
  || SSet.mem sort !sequence_alias_sorts
  || SSet.mem sort !flat_sequence_source_sorts

let source_sort_compatible_for_ctor_arg actual expected =
  actual = expected
  || expected = "SpectecTerminal"
  || (source_sort_is_sequence_like expected
      && source_sort_is_sequence_like actual
      && sequence_sort_compatible actual expected)
  || (not (source_sort_is_sequence_like expected)
      && not (source_sort_is_sequence_like actual)
      && source_sort_reaches actual expected)

let source_sort_of_numeric_exp e =
  match (unwrap_exp_for_source_sort e).it with
  | NumE (`Nat _) -> Some "Nat"
  | NumE (`Int _) -> Some "Int"
  | _ -> None

let source_sort_of_case_arg e t vm =
  let text = strip_wrapping_parens t.text |> String.trim in
  match sequence_sort_of_text text with
  | Some seq_sort -> Some seq_sort
  | None ->
      (match source_sort_of_exp e vm with
       | Some sort -> Some sort
       | None ->
           (match source_sort_of_plain_text_var text with
            | Some sort -> Some sort
            | None -> source_sort_of_numeric_exp e))

let source_ctor_precise_field_sorts info =
  !source_compound_cases
  |> List.filter (fun c ->
       c.compound_ctor = info.source_ctor_name
       && List.length c.compound_fields = info.source_ctor_arity)
  |> List.filter_map (fun c ->
       let sorts =
         c.compound_fields
         |> List.map (fun (_, field_typ) -> precise_source_sort_of_field_typ field_typ)
       in
       if List.exists Option.is_none sorts then None
       else Some (List.map Option.get sorts))

let source_ctor_candidate_score expected_sort arg_sorts info =
  let category_score =
    match expected_sort, source_ctor_category_sort info with
    | Some expected, Some category when category = expected -> Some 32
    | Some expected, Some category when source_sort_reaches category expected -> Some 24
    | Some _, Some _ -> None
    | Some _, None -> None
    | None, _ -> Some 0
  in
  match category_score with
  | None -> None
  | Some base ->
      let field_sorts = source_ctor_precise_field_sorts info in
      let score_for_fields expected_fields =
        if List.length expected_fields <> List.length arg_sorts then None
        else
          List.fold_left2
            (fun acc actual_opt expected ->
               match acc with
               | None -> None
               | Some score ->
                   (match actual_opt with
                    | Some actual when source_sort_compatible_for_ctor_arg actual expected ->
                        Some (score + 4)
                    | Some _ -> None
                    | None -> Some score))
            (Some base) arg_sorts expected_fields
      in
      (match field_sorts with
       | [] -> Some base
       | _ ->
           field_sorts
           |> List.filter_map score_for_fields
           |> List.sort_uniq compare
           |> List.rev
           |> function
              | best :: _ -> Some best
              | [] -> None)

let choose_source_ctor_for_case expected_sort mixop field_exps arg_ts vm =
  let sections = source_ctor_sections_from_mixop mixop in
  match source_ctor_surface_op_head sections with
  | None -> None
  | Some head ->
      let arity = List.length arg_ts in
      let candidates =
        source_ctor_candidates_by_original_head_arity head arity
        |> filter_source_ctor_candidates_by_expected_sort expected_sort
      in
      let arg_sorts =
        List.map2 (fun e t -> source_sort_of_case_arg e t vm) field_exps arg_ts
      in
      let scored =
        candidates
        |> List.filter_map (fun info ->
             source_ctor_candidate_score expected_sort arg_sorts info
             |> Option.map (fun score -> (score, info)))
      in
      match scored with
      | [] ->
          candidates
          |> choose_most_specific_source_ctor
          |> Option.map (fun info -> info.source_ctor_name)
      | _ ->
          let best_score =
            scored |> List.map fst |> List.fold_left max min_int
          in
          let best =
            scored
            |> List.filter (fun (score, _) -> score = best_score)
            |> List.map snd
          in
          choose_most_specific_source_ctor best
          |> Option.map (fun info -> info.source_ctor_name)

let typed_index_helper_name ?(index_kind = `Nat) sort =
  "$typed-index-" ^ sort ^
  match index_kind with
  | `Nat -> "-nat"
  | `Seq -> "-seq"

let typed_index_index_kind (idx_t : texpr) =
  let core = strip_wrapping_parens idx_t.text |> String.trim in
  let var_sort v =
    match Hashtbl.find_opt declared_vars v with
    | Some sort -> Some sort
    | None -> source_sort_of_plain_text_var v
  in
  if core = "eps" then `Seq
  else if is_raw_numeric_text core
          || starts_with core "$raw-lit"
          || starts_with core "$raw-nat-lit"
  then `Nat
  else if is_plain_var_like core then
    match var_sort core with
    | Some "SpectecTerminals" -> `Seq
    | _ -> `Nat
  else if
    List.exists
      (fun v ->
         match var_sort v with
         | Some "SpectecTerminals" -> true
         | _ -> Hashtbl.mem source_var_seq_elem_sorts v)
      idx_t.vars
  then `Seq
  else `Nat

let typed_index_nat_arg idx_text =
  let core = strip_wrapping_parens idx_text |> String.trim in
  if core = "" || is_raw_numeric_text core || starts_with core "$raw-nat-lit"
  then idx_text
  else
    match
      if is_plain_var_like core then Hashtbl.find_opt declared_vars core else None
    with
    | Some "Nat" -> idx_text
    | _ -> format_call "$raw-nat-lit" [idx_text]

let typed_index_call elem_sort base_text idx_t =
  let index_kind = typed_index_index_kind idx_t in
  let idx_text =
    match index_kind with
    | `Nat -> typed_index_nat_arg idx_t.text
    | `Seq -> idx_t.text
  in
  Printf.sprintf "%s ( %s, %s )"
    (typed_index_helper_name ~index_kind elem_sort) base_text idx_text

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
           let signature_sorts =
             match Hashtbl.find_opt source_def_arg_sorts fn with
             | Some sorts when List.length sorts = List.length args -> Some sorts
             | _ -> None
           in
           let arg_sorts =
             List.init (List.length args) (fun i ->
                 if i = seq_i then
                   let seq_sort_opt =
                     match List.nth_opt args i with
                     | Some arg -> sequence_sort_of_text arg
                     | None -> None
                   in
                   (match seq_sort_opt with
                    | Some seq_sort -> seq_sort
                    | None ->
                        (match signature_sorts with
                         | Some sorts ->
                             (match List.nth_opt sorts i with
                              | Some sort when registered_sequence_sort sort -> sort
                              | Some sort ->
                                  (match sequence_sort_for_elem_sort sort with
                                   | Some seq_sort -> seq_sort
                                   | None -> "SpectecTerminals")
                              | None -> "SpectecTerminals")
                         | None -> "SpectecTerminals"))
                 else
                   match signature_sorts with
                   | Some sorts ->
                       (match List.nth_opt sorts i with
                        | Some sort -> sort
                        | None -> "SpectecTerminal")
                   | None -> "SpectecTerminal")
           in
           let helper =
             register_map_call_helper
               ~preserve_nested:!preserve_nested_sequence_iters
               fn (List.length args) seq_i arg_sorts
           in
           Some { text = format_call helper args; vars = inner.vars }
       | _ -> None)
  | None -> None

let texpr_looks_sequence (t : texpr) =
  let text = strip_wrapping_parens t.text |> String.trim in
  let sort_is_sequence = function
    | Some sort -> sort = "SpectecTerminals" || ends_with sort "Seq"
    | None -> false
  in
  text = "eps"
  || sort_is_sequence (Hashtbl.find_opt declared_vars text)
  || List.exists (fun v ->
      sort_is_sequence (Hashtbl.find_opt declared_vars v))
      t.vars

let expression_map_texpr (t : texpr) =
  let text = strip_wrapping_parens t.text |> String.trim in
  let seq_vars =
    t.vars
    |> List.filter (fun v ->
        match helper_sort_of_var v with
        | sort -> sort_is_sequence_carrier sort)
    |> List.sort_uniq String.compare
  in
  match seq_vars with
  | [] -> None
  | _ ->
      let fixed_vars =
        t.vars
        |> List.filter (fun v -> not (List.mem v seq_vars))
        |> List.sort_uniq String.compare
        |> List.map (fun v -> (v, helper_sort_of_var v))
      in
      let helper = register_expr_map_helper text seq_vars fixed_vars in
      let args =
        (fixed_vars |> List.map fst) @ seq_vars
      in
      Some { text = format_call helper args; vars = args }

let sequence_lift_arg_sorts_multi fn seq_indices arg_ts =
  let signature_sorts =
    match Hashtbl.find_opt source_def_arg_sorts fn with
    | Some sorts when List.length sorts = List.length arg_ts -> Some sorts
    | _ -> None
  in
  let sort_from_term i t =
    if List.mem i seq_indices || texpr_looks_sequence t then
      match sequence_sort_of_text t.text with
      | Some seq_sort -> seq_sort
      | None ->
          (match signature_sorts with
           | Some sorts ->
               (match List.nth_opt sorts i with
                | Some sort when registered_sequence_sort sort -> sort
                | Some sort ->
                    (match sequence_sort_for_elem_sort sort with
                     | Some seq_sort -> seq_sort
                     | None -> "SpectecTerminals")
                | None -> "SpectecTerminals")
           | None -> "SpectecTerminals")
    else
      match signature_sorts with
      | Some sorts ->
          (match List.nth_opt sorts i with
           | Some sort -> sort
           | None -> "SpectecTerminal")
      | None -> "SpectecTerminal"
  in
  List.mapi sort_from_term arg_ts

let sequence_lift_arg_sorts fn seq_i arg_ts =
  sequence_lift_arg_sorts_multi fn [seq_i] arg_ts

let source_call_sequence_positions args arg_ts vm =
  let direct_positions =
    args
    |> List.mapi (fun i a ->
        match a.it, List.nth arg_ts i with
        | ExpA { it = VarE vid; _ }, ({ text; vars = [v] } as _t) ->
            (match find_vm_case_insensitive (vid.it ^ "*") vm with
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
  | VarE id -> translate_var ctx id.it vm (source_expected_sort_of_typ e.note vm)
  | CaseE (mixop, inner) ->
      translate_case ctx mixop inner vm (source_expected_sort_of_typ e.note vm)
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
      let t1 =
        translate_exp TermCtx e1 vm |> raw_literal_texpr_for_numeric_context
      and t2 =
        translate_exp TermCtx e2 vm |> raw_literal_texpr_for_numeric_context
      in
      { text = wrap_bool ctx (Printf.sprintf "%s ( %s, %s )" op_str t1.text t2.text);
        vars = t1.vars @ t2.vars }
  | CallE (id, args) ->
      let fn = call_name id.it in
      let arg_nested i =
        match Hashtbl.find_opt source_def_arg_sequence_depths fn with
        | Some depths ->
            (match List.nth_opt depths i with
             | Some depth -> depth >= 2
             | None -> false)
        | None -> false
      in
      let ts =
        args
        |> List.mapi (fun i a ->
            translate_arg ~preserve_nested:(arg_nested i) a vm)
      in
      let fname = sanitize id.it in
      let strs = List.map (fun t -> t.text) ts in
      let all_v = List.concat_map (fun t -> t.vars) ts in
      if fname = "w-$" then { text = String.concat ", " strs; vars = all_v }
      else
        (match List.assoc_opt (id.it ^ "#apply") vm,
               List.assoc_opt id.it vm with
         | Some apply_name, Some def_tag_var ->
             { text = format_call apply_name (def_tag_var :: strs);
               vars = def_tag_var :: all_v }
         | _ ->
             (match Hashtbl.find_opt source_def_param_infos fn with
              | Some infos ->
                  List.iter
                    (fun info ->
                      match List.nth_opt args info.def_param_position with
                      | Some { it = DefA actual_id; _ }
                          when List.assoc_opt actual_id.it vm = None ->
                          register_def_apply_dispatch info (call_name actual_id.it)
                      | _ -> ())
                    infos
              | None -> ());
             { text = format_source_def_call fn strs; vars = all_v })
  | TupE [] | ListE [] -> texpr "eps"
  | TupE [e1] -> translate_exp ctx e1 vm
  | TupE el | ListE el ->
      source_sequence_concat_texprs
        (List.map (fun x -> translate_exp TermCtx x vm) el)
  | BoolE b -> texpr (wrap_bool ctx (if b then "true" else "false"))
  | TextE s -> texpr ("\"" ^ s ^ "\"")
  | StrE fields -> translate_record_expr fields vm None
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
      concat_texprs_preserving_sequence
        (translate_exp TermCtx e1 vm) (translate_exp TermCtx e2 vm)
  | IdxE (e1, e2) ->
      let base_t = translate_exp TermCtx e1 vm in
      let idx_t =
        translate_exp TermCtx e2 vm |> raw_literal_texpr_for_numeric_context
      in
      { text = Printf.sprintf "index ( %s, %s )" base_t.text idx_t.text;
        vars = base_t.vars @ idx_t.vars }
  | SliceE (e1, e2, e3) ->
      tjoin3 (Printf.sprintf "slice ( %s, %s, %s )")
        (translate_exp TermCtx e1 vm)
        (translate_exp TermCtx e2 vm |> raw_literal_texpr_for_numeric_context)
        (translate_exp TermCtx e3 vm |> raw_literal_texpr_for_numeric_context)
  | UpdE (e1, path, e2) -> translate_bracket_op "<-" e1 path e2 vm
  | ExtE (e1, path, e2) -> translate_bracket_op "=++" e1 path e2 vm
  | OptE (Some e1) | TheE e1 | LiftE e1 -> translate_exp ctx e1 vm
  | OptE None -> texpr "eps"
  | IterE (e1, (iter_type, _)) ->
    let listn_index_var =
      match iter_type with
      | ListN (_, Some index_id) ->
          record_listn_index_var vm index_id;
          resolve_var_name index_id.it vm
      | _ -> None
    in
    let suffix = match iter_type with
      | List -> "*" | List1 -> "+" | Opt -> "?" | ListN _ -> "" in
    let iter_inner_exp = unwrap_exp_for_source_sort e1 in
    let iter_call_translation id args =
      let arg_ts = List.map (fun a -> translate_arg a vm) args in
      match List.assoc_opt (id.it ^ "#apply") vm,
            List.assoc_opt id.it vm with
      | Some apply_name, Some def_tag_var ->
          let tag_t = texpr_with_var def_tag_var def_tag_var in
          let effective_args = tag_t :: arg_ts in
          let source_seq_positions =
            source_call_sequence_positions args arg_ts vm
            |> List.map (fun i -> i + 1)
          in
          let seq_positions =
            match source_seq_positions with
            | _ :: _ -> source_seq_positions
            | [] ->
                effective_args
                |> List.mapi (fun i t -> if texpr_looks_sequence t then Some i else None)
                |> List.filter_map (fun x -> x)
          in
          (apply_name, effective_args, seq_positions)
      | _ ->
          (call_name id.it, arg_ts, source_call_sequence_positions args arg_ts vm)
    in
    (match iter_inner_exp.it with
     | VarE id ->
         let repeat_of_scalar mapped =
           match iter_type with
           | ListN (count_e, _) ->
               let count_t =
                 translate_exp TermCtx count_e vm
                 |> raw_literal_texpr_for_numeric_context
               in
               Some
                 { text = Printf.sprintf "$repeat ( %s, %s )" mapped count_t.text;
                   vars = List.sort_uniq String.compare (mapped :: count_t.vars) }
           | _ -> None
         in
         let full =
           match iter_type with
           | ListN _ -> id.it ^ "*"
           | _ -> id.it ^ suffix
         in
         let resolved_full =
           match iter_type with
           | ListN _ -> find_vm_case_insensitive full vm
           | _ -> resolve_var_name full vm
         in
         (match resolved_full with
          | Some mapped
            when (match iter_type with
                  | ListN _ ->
                      (match Hashtbl.find_opt source_var_sorts mapped with
                       | Some "SpectecTerminals" -> true
                       | _ -> false)
                  | _ -> true) ->
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
          | Some mapped ->
              (match repeat_of_scalar mapped with
               | Some repeated -> repeated
               | None -> texpr_with_var mapped mapped)
          | None ->
              (match iter_type, resolve_var_name id.it vm with
               | ListN _, Some mapped ->
                   (match repeat_of_scalar mapped with
                    | Some repeated -> repeated
                    | None -> texpr_with_var mapped mapped)
               | _ ->
                   let fallback_raw =
                     match iter_type with
                     | List | List1 | ListN _ -> pluralize_sequence_var_source_name id.it
                     | Opt -> id.it ^ "?"
                   in
                   let v = String.uppercase_ascii (sanitize fallback_raw) in
                   texpr_with_var v v))
     | _ ->
         let inner = translate_exp ctx e1 vm in
         (match iter_type, e1.it with
          | ListN (count_e, _), _ ->
              (match count_e.it with
               | VarE _ ->
                   let count_var_t = translate_exp TermCtx count_e vm in
                   let count_t =
                     count_var_t |> raw_literal_texpr_for_numeric_context
                   in
                   record_listn_pair_if_sequence_var count_var_t inner;
                   let indexed_listn () =
                     let norm_ws s =
                       Str.global_replace (Str.regexp "[ \t\n\r]+") " " (String.trim s)
                     in
                     let text = norm_ws inner.text in
                     let count_text =
                       let s = String.trim count_t.text |> strip_wrapping_parens |> String.trim in
                       if contains_substring s "FREE-" then
                         Str.replace_first (Str.regexp_string "FREE-") "" s
                       else
                         s
                     in
                     let vars_without_index idx =
                       inner.vars
                       |> List.filter (fun v -> v <> idx)
                       |> fun vs -> count_t.vars @ vs
                       |> List.sort_uniq String.compare
                     in
                     let exact s = norm_ws s = text in
                     let extract_between prefix suffix =
                       let prefix = norm_ws prefix in
                       let suffix = norm_ws suffix in
                       if starts_with text prefix && ends_with text suffix then
                         let start = String.length prefix in
                         let len = String.length text - start - String.length suffix in
                         if len >= 0 then Some (String.trim (String.sub text start len)) else None
                       else None
                     in
                     let extract_between_text haystack prefix suffix =
                       let haystack = norm_ws haystack in
                       let prefix = norm_ws prefix in
                       let suffix = norm_ws suffix in
                       if starts_with haystack prefix && ends_with haystack suffix then
                         let start = String.length prefix in
                         let len = String.length haystack - start - String.length suffix in
                         if len >= 0 then Some (String.trim (String.sub haystack start len)) else None
                       else None
                     in
                     let ctor_args ctor =
                       match ctor_call_pattern text with
                       | Some (found, args) when found = ctor ->
                           Some args
                       | _ -> None
                     in
                     let same_arg arg expected =
                       norm_ws (strip_wrapping_parens arg) = norm_ws expected
                     in
                     match listn_index_var with
                     | None -> None
                     | Some idx ->
                         let widx_ctor =
                           Option.value (source_index_wrapper_ctor ())
                             ~default:""
                         in
                         let rec_ctor =
                           Option.value (source_recursive_typevar_ctor ())
                             ~default:""
                         in
                         let wdef_ctor =
                           Option.value (source_indexed_deftype_ctor ())
                             ~default:""
                         in
                         if exact (format_source_ctor_call widx_ctor [idx])
                            || (match ctor_args widx_ctor with
                                | Some [arg] when same_arg arg idx -> true
                                | _ -> false)
                         then
                           Some { text = Printf.sprintf "$idx-range ( %s )" count_text;
                                  vars = vars_without_index idx }
                         else if exact (format_source_ctor_call rec_ctor [idx])
                                 || (match ctor_args rec_ctor with
                                     | Some [arg] when same_arg arg idx -> true
                                     | _ -> false)
                         then
                           Some { text = Printf.sprintf "$rec-range ( %s )" count_text;
                                  vars = vars_without_index idx }
                         else
                           (match extract_between
                                    "_+_ ( "
                                    (Printf.sprintf ", %s )" idx)
                            with
                           | Some start ->
                               Some { text = Printf.sprintf "$nat-range-from ( %s, %s )" start count_text;
                                       vars = vars_without_index idx }
                           | None ->
                           (match extract_between
                                    (Printf.sprintf "%s ( ( _+_ ( " widx_ctor)
                                    (Printf.sprintf ", %s ) ) )" idx)
                            with
                            | Some start ->
                                Some { text = Printf.sprintf "$idx-range-from ( %s, %s )" start count_text;
                                       vars = vars_without_index idx }
                            | None ->
                                (match ctor_args widx_ctor with
                                 | Some [arg] ->
                                     (match extract_between_text arg "_+_ ( " (Printf.sprintf ", %s )" idx) with
                                      | Some start ->
                                          Some { text = Printf.sprintf "$idx-range-from ( %s, %s )" start count_text;
                                                 vars = vars_without_index idx }
                                      | None -> None)
                                 | _ -> None)
                                |> (function
                                    | Some _ as found -> found
                                    | None ->
                                (match extract_between
                                         (Printf.sprintf "%s ( " wdef_ctor)
                                         (Printf.sprintf ", %s )" idx)
                                 with
                                 | Some rt ->
                                     Some { text = Printf.sprintf "$def-range ( %s, %s )" rt count_text;
                                            vars = vars_without_index idx }
                                 | None ->
                                     (match ctor_args wdef_ctor with
                                      | Some [rt; arg] when same_arg arg idx ->
                                          Some { text = Printf.sprintf "$def-range ( %s, %s )" rt count_text;
                                                 vars = vars_without_index idx }
                                      | _ -> None)))))
                   in
                   (match indexed_listn () with
                    | Some t -> t
                    | None ->
                   (match e1.it with
                    | CallE (id, args) ->
                        let fn, arg_ts, seq_positions =
                          iter_call_translation id args
                        in
                        (match seq_positions with
                         | [] -> inner
                         | [seq_i] ->
                             let arg_sorts = sequence_lift_arg_sorts fn seq_i arg_ts in
                             let helper =
                               register_map_call_helper
                                 ~preserve_nested:!preserve_nested_sequence_iters
                                 fn (List.length arg_ts) seq_i arg_sorts
                             in
                             { text = format_call helper (List.map (fun (t : texpr) -> t.text) arg_ts);
                               vars =
                                 List.sort_uniq String.compare
                                   (List.concat_map (fun (t : texpr) -> t.vars) arg_ts) }
                         | seq_indices ->
                             let arg_sorts =
                               sequence_lift_arg_sorts_multi fn seq_indices arg_ts
                             in
                             let helper =
                               register_zip_map_call_helper
                                 ~preserve_nested:!preserve_nested_sequence_iters
                                 fn (List.length arg_ts) seq_indices arg_sorts
                             in
                             { text = format_call helper (List.map (fun (t : texpr) -> t.text) arg_ts);
                               vars =
                                 List.sort_uniq String.compare
                                   (List.concat_map (fun (t : texpr) -> t.vars) arg_ts) })
                    | _ ->
                        (match expression_map_texpr inner with
                         | Some mapped -> mapped
                         | None -> inner)))
	               | _ ->
	                   let count_t =
	                     translate_exp TermCtx count_e vm
	                     |> raw_literal_texpr_for_numeric_context
	                   in
	                   let indexed_listn () =
	                     let norm_ws s =
	                       Str.global_replace (Str.regexp "[ \t\n\r]+") " " (String.trim s)
	                     in
	                     let text = norm_ws inner.text in
	                     let count_text =
	                       let s = String.trim count_t.text |> strip_wrapping_parens |> String.trim in
	                       if contains_substring s "FREE-" then
	                         Str.replace_first (Str.regexp_string "FREE-") "" s
	                       else
	                         s
	                     in
	                     let vars_without_index idx =
	                       inner.vars
	                       |> List.filter (fun v -> v <> idx)
	                       |> fun vs -> vs @ count_t.vars
	                       |> List.sort_uniq String.compare
	                     in
	                     let exact s = norm_ws s = text in
	                     let extract_between prefix suffix =
	                       let prefix = norm_ws prefix in
	                       let suffix = norm_ws suffix in
	                       if starts_with text prefix && ends_with text suffix then
	                         let start = String.length prefix in
	                         let len = String.length text - start - String.length suffix in
	                         if len >= 0 then Some (String.trim (String.sub text start len)) else None
	                       else None
	                     in
	                     let extract_between_text haystack prefix suffix =
	                       let haystack = norm_ws haystack in
	                       let prefix = norm_ws prefix in
	                       let suffix = norm_ws suffix in
	                       if starts_with haystack prefix && ends_with haystack suffix then
	                         let start = String.length prefix in
	                         let len = String.length haystack - start - String.length suffix in
	                         if len >= 0 then Some (String.trim (String.sub haystack start len)) else None
	                       else None
	                     in
	                     let ctor_args ctor =
	                       match ctor_call_pattern text with
	                       | Some (found, args) when found = ctor ->
	                           Some args
	                       | _ -> None
	                     in
	                     let same_arg arg expected =
	                       norm_ws (strip_wrapping_parens arg) = norm_ws expected
	                     in
	                     match listn_index_var with
	                     | None -> None
	                     | Some idx ->
	                         let widx_ctor =
	                           Option.value (source_index_wrapper_ctor ())
	                             ~default:""
	                         in
	                         let rec_ctor =
	                           Option.value (source_recursive_typevar_ctor ())
	                             ~default:""
	                         in
	                         let wdef_ctor =
	                           Option.value (source_indexed_deftype_ctor ())
	                             ~default:""
	                         in
	                         if exact (format_source_ctor_call widx_ctor [idx])
	                            || (match ctor_args widx_ctor with
	                                | Some [arg] when same_arg arg idx -> true
	                                | _ -> false)
	                         then
	                           Some { text = Printf.sprintf "$idx-range ( %s )" count_text;
	                                  vars = vars_without_index idx }
	                         else if exact (format_source_ctor_call rec_ctor [idx])
	                                 || (match ctor_args rec_ctor with
	                                     | Some [arg] when same_arg arg idx -> true
	                                     | _ -> false)
	                         then
	                           Some { text = Printf.sprintf "$rec-range ( %s )" count_text;
	                                  vars = vars_without_index idx }
	                         else
	                           (match extract_between
	                                    "_+_ ( "
	                                    (Printf.sprintf ", %s )" idx)
	                            with
	                            | Some start ->
	                                Some { text = Printf.sprintf "$nat-range-from ( %s, %s )" start count_text;
	                                       vars = vars_without_index idx }
	                            | None ->
	                                (match extract_between
	                                         (Printf.sprintf "%s ( ( _+_ ( " widx_ctor)
	                                         (Printf.sprintf ", %s ) ) )" idx)
	                                 with
	                                 | Some start ->
	                                     Some { text = Printf.sprintf "$idx-range-from ( %s, %s )" start count_text;
	                                            vars = vars_without_index idx }
	                                 | None ->
	                                     (match ctor_args widx_ctor with
	                                      | Some [arg] ->
	                                          (match extract_between_text arg "_+_ ( " (Printf.sprintf ", %s )" idx) with
	                                           | Some start ->
	                                               Some { text = Printf.sprintf "$idx-range-from ( %s, %s )" start count_text;
	                                                      vars = vars_without_index idx }
	                                           | None -> None)
	                                      | _ -> None)
	                                     |> (function
	                                         | Some _ as found -> found
	                                         | None ->
	                                     (match extract_between
	                                              (Printf.sprintf "%s ( " wdef_ctor)
	                                              (Printf.sprintf ", %s )" idx)
	                                      with
	                                      | Some rt ->
	                                          Some { text = Printf.sprintf "$def-range ( %s, %s )" rt count_text;
	                                                 vars = vars_without_index idx }
	                                      | None ->
	                                          (match ctor_args wdef_ctor with
	                                           | Some [rt; arg] when same_arg arg idx ->
	                                               Some { text = Printf.sprintf "$def-range ( %s, %s )" rt count_text;
	                                                      vars = vars_without_index idx }
	                                           | _ -> None)))))
	                   in
	                   (match indexed_listn () with
	                    | Some t -> t
	                    | None ->
	                        { text = Printf.sprintf "$repeat ( %s, %s )" inner.text count_t.text;
	                          vars = List.sort_uniq String.compare (inner.vars @ count_t.vars) }) )
          | (List | List1), CallE (id, args) ->
              let fn, arg_ts, seq_positions =
                iter_call_translation id args
              in
              (match seq_positions with
               | [seq_i] ->
                   let arg_sorts = sequence_lift_arg_sorts fn seq_i arg_ts in
                   let helper =
                     register_map_call_helper
                       ~preserve_nested:!preserve_nested_sequence_iters
                       fn (List.length arg_ts) seq_i arg_sorts
                   in
                   { text = format_call helper (List.map (fun (t : texpr) -> t.text) arg_ts);
                     vars =
                       List.sort_uniq String.compare
                         (List.concat_map (fun (t : texpr) -> t.vars) arg_ts) }
               | _ :: _ :: _ as seq_indices ->
                   let arg_sorts =
                     sequence_lift_arg_sorts_multi fn seq_indices arg_ts
                   in
                   let helper =
                     register_zip_map_call_helper
                       ~preserve_nested:!preserve_nested_sequence_iters
                       fn (List.length arg_ts) seq_indices arg_sorts
                   in
                   { text = format_call helper (List.map (fun (t : texpr) -> t.text) arg_ts);
                     vars =
                       List.sort_uniq String.compare
                         (List.concat_map (fun (t : texpr) -> t.vars) arg_ts) }
               | _ ->
                   (match expression_map_texpr inner with
                    | Some mapped -> mapped
                    | None ->
	                   (match map_call_texpr_from_text inner, star_prefix_pattern inner.text with
	                    | Some mapped, _ -> mapped
	                    | None, Some (ctor, seq_var) ->
	                        { text = star_prefix_text ctor seq_var; vars = [seq_var] }
	                    | None, None -> inner)))
          | (List | List1), _ ->
              (match expression_map_texpr inner with
               | Some mapped -> mapped
               | None ->
	              (match map_call_texpr_from_text inner, star_prefix_pattern inner.text with
	               | Some mapped, _ -> mapped
	               | None, Some (ctor, seq_var) ->
	                   { text = star_prefix_text ctor seq_var; vars = [seq_var] }
	               | None, None -> inner))
	          | Opt, _ ->
	              if inner.vars = [] && String.trim inner.text <> "eps" then (
	                let idx = !optional_literal_seen in
	                incr optional_literal_seen;
	                optional_literal_terms := SSet.add inner.text !optional_literal_terms;
	                if List.mem idx !optional_literal_empty_indices then texpr "eps"
	                else inner
	              ) else inner))
  | IfE (c, e1, e2) ->
      tjoin3 (Printf.sprintf "if %s then %s else %s fi")
        (translate_exp BoolCtx c vm) (translate_exp ctx e1 vm) (translate_exp ctx e2 vm)

and translate_record_expr fields vm sort_hint =
  let field_values = List.map (fun (atom, e1) ->
    let name = to_var_name (Xl.Atom.name atom) in
    let t = translate_exp TermCtx e1 vm in
    (name, t)
  ) fields in
  let field_names = List.map fst field_values in
  let record_info =
    match sort_hint with
    | Some sort ->
        (match source_record_by_sort_and_fields sort field_names with
         | Some _ as hit -> hit
         | None -> unique_source_record_by_fields field_names)
    | None -> unique_source_record_by_fields field_names
  in
  match record_info with
  | Some info ->
      let args =
        List.map (fun (name, t) ->
          match Hashtbl.find_opt source_record_field_sorts
                  (source_record_field_key info.rec_sort name) with
          | Some sort ->
              { t with text = wrap_source_arg_for_sort sort t.text }
          | None -> t)
          field_values
      in
      { text = format_source_ctor_call info.rec_ctor (List.map (fun t -> t.text) args);
        vars = List.concat_map (fun t -> t.vars) args }
  | None ->
      let items = List.map (fun (name, t) ->
        { t with text = Printf.sprintf "item('%s, %s)" name t.text }
      ) field_values in
      { text = "{" ^ String.concat " ; " (List.map (fun t -> t.text) items) ^ "}";
        vars = List.concat_map (fun t -> t.vars) items }

and translate_exp_with_record_sort_hint ctx e vm sort_hint =
  match e.it with
  | StrE fields -> translate_record_expr fields vm sort_hint
  | _ -> translate_exp ctx e vm

and translate_var ctx name vm expected_sort =
  match resolve_var_name name vm with
  | Some mapped -> texpr_with_var mapped mapped
  | None ->
      let low = String.lowercase_ascii name in
      if low = "true" then texpr (wrap_bool ctx "true")
      else if low = "false" then texpr (wrap_bool ctx "false")
      else
        match source_nullary_ctor_name_if_registered ?expected_sort name with
        | Some ctor -> texpr ctor
        | None ->
            if is_lower_token_id name then texpr (sanitize name)
            else let v = to_var_name name in texpr_with_var v v

and translate_case ctx mixop inner vm expected_sort =
  let op_name =
    try List.flatten mixop |> List.map Xl.Atom.name |> String.concat ""
    with _ -> "" in
  if op_name = "$" || op_name = "%" || op_name = "" then
    translate_exp ctx inner vm
  else
    let field_exps = match inner.it with
      | TupE es -> es
      | _ -> [inner] in
    let args = List.map (fun e -> translate_exp TermCtx e vm) field_exps in
    let arg_texts = List.map (fun t -> t.text) args in
    match format_source_semicolon_pair arg_texts with
    | Some text when mixop_is_source_semicolon_pair mixop (List.length arg_texts) ->
        { text; vars = List.concat_map (fun t -> t.vars) args }
    | _ ->
	    match
        match canonical_ctor_name_arity mixop (List.length arg_texts) with
        | Some _ as hit -> hit
        | None -> choose_source_ctor_for_case expected_sort mixop field_exps args vm
      with
	    | Some ctor ->
	        let arg_texts, tail_texts =
	          split_ctor_nonsequence_arg_tails ctor arg_texts
	        in
	        let ctor_text = format_source_ctor_call ctor arg_texts in
	        let text =
	          match tail_texts with
	          | [] -> ctor_text
	          | _ ->
	              source_sequence_item_text
	                (String.concat " " (ctor_text :: tail_texts))
	        in
	        { text;
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
  let t1, t2 =
    if is_bool then (t1, t2)
    else
      (raw_literal_texpr_for_numeric_context t1,
       raw_literal_texpr_for_numeric_context t2)
  in
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
        let it =
          translate_exp TermCtx idx vm |> raw_literal_texpr_for_numeric_context
        in
        vars_acc := !vars_acc @ it.vars;
        Printf.sprintf "index(%s, %s)" pa it.text
    | SliceP (parent, e_s, e_e) ->
        let pa = path_access parent in
        let es =
          translate_exp TermCtx e_s vm |> raw_literal_texpr_for_numeric_context
        in
        let ee =
          translate_exp TermCtx e_e vm |> raw_literal_texpr_for_numeric_context
        in
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
        let it =
          translate_exp TermCtx idx vm |> raw_literal_texpr_for_numeric_context
        in
        vars_acc := !vars_acc @ it.vars;
        let parent_text = path_access parent in
        let this_upd =
          Printf.sprintf "( %s [ %s %s %s ] )" parent_text it.text inner_op v_text in
        update_at parent this_upd "<-"
    | SliceP (parent, e_s, e_e) ->
        let es =
          translate_exp TermCtx e_s vm |> raw_literal_texpr_for_numeric_context
        in
        let ee =
          translate_exp TermCtx e_e vm |> raw_literal_texpr_for_numeric_context
        in
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

and translate_arg ?(preserve_nested=false) (a : arg) vm : texpr = match a.it with
  | ExpA e ->
      with_preserve_nested_sequence_iters preserve_nested
        (fun () -> translate_exp TermCtx e vm)
  | TypA t -> translate_typ_texpr t vm
  | DefA id ->
      (match List.assoc_opt id.it vm with
       | Some mapped -> texpr_with_var mapped mapped
       | None ->
           let tag = def_tag_name (call_name id.it) in
           register_def_tag tag;
           texpr tag)
  | _ -> texpr "eps"

and wrap_texpr_for_source_typ (t : typ) vm (texp : texpr) : texpr =
  match t.it with
  | IterT (_, (List | List1 | ListN _ | Opt)) ->
      (match sequence_sort_of_typ t vm with
       | Some seq_sort -> { texp with text = sequence_term_for_sort seq_sort texp.text }
       | None -> texp)
  | _ -> texp

and translate_exp_for_result_typ ctx (result_typ : typ) (e : exp) vm : texpr =
  match result_typ.it, e.it with
  | TupT fields, TupE es when List.length fields = List.length es ->
      let parts =
        List.map2
          (fun (_field_exp, field_typ) field_exp ->
             translate_exp TermCtx field_exp vm
             |> wrap_texpr_for_source_typ field_typ vm)
          fields es
      in
      source_sequence_concat_texprs parts
  | _ ->
      (match sequence_sort_of_typ result_typ vm with
       | Some seq_sort ->
           let t = translate_exp ctx e vm in
           { t with text = sequence_term_for_sort seq_sort t.text }
       | None ->
      (match simple_sort_of_typ result_typ vm with
       | Some "Config" -> translate_exp_for_expected_sort "Config" e vm
       | Some sort when ends_with sort "Seq" ->
           let t = translate_exp ctx e vm in
           { t with text = sequence_term_for_sort sort t.text }
       | _ -> translate_exp ctx e vm))

and translate_exp_for_expected_sort sort e vm : texpr =
  match sort, e.it with
  | "Config", CaseE (mixop, inner) ->
      let arity = match inner.it with TupE es -> List.length es | _ -> 1 in
      if mixop_is_source_semicolon_pair mixop arity then
        match inner.it with
        | TupE [state_e; instrs_e] ->
            let state_t = translate_exp TermCtx state_e vm in
            let instrs_t = translate_exp TermCtx instrs_e vm in
            { text = config_text state_t.text (sequence_term_for_sort "InstrSeq" instrs_t.text);
              vars = state_t.vars @ instrs_t.vars }
        | _ -> translate_exp TermCtx e vm
      else translate_exp TermCtx e vm
  | _ when ends_with sort "Seq" ->
      let t = translate_exp TermCtx e vm in
      { t with text = sequence_term_for_sort sort t.text }
  | _ -> translate_exp TermCtx e vm

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
  let _ = name in
  false

and config_text z instr =
  Printf.sprintf "( %s ; %s )" z instr

and state_text store frame =
  Printf.sprintf "( %s ; %s )" store frame

and translate_prem (p : prem) vm : texpr = match p.it with
  | IfPr e -> translate_exp BoolCtx e vm
  | RulePr (id, prem_mixop, e) ->
      let decompose_cfg exp =
        match exp.it with
        | CaseE (mixop, inner) ->
            let arity = match inner.it with TupE es -> List.length es | _ -> 1 in
            if mixop_is_source_semicolon_pair mixop arity then
                 (match inner.it with
                  | TupE [z_e; instr_e] -> Some (z_e, instr_e)
                  | _ -> None)
            else None
        | _ -> None
      in
      let ts = match e.it with
        | TupE el -> List.map (fun x -> translate_exp TermCtx x vm) el
        | _ -> [translate_exp TermCtx e vm] in
      let name = sanitize id.it in
      let all_vars = List.concat_map (fun t -> t.vars) ts in
      let text =
        if relation_mixop_is_execution prem_mixop then
          let op_name =
            match e.it with
            | TupE [_; _; _; _] -> name
            | _ -> String.lowercase_ascii name
          in
          match e.it with
          | TupE [lhs; rhs] ->
              (match decompose_cfg lhs, decompose_cfg rhs with
               | Some (z_e, lhs_e), Some (zq_e, rhs_e) ->
                   let z_t = translate_exp TermCtx z_e vm in
                   let lhs_t = translate_exp TermCtx lhs_e vm in
                   let zq_t = translate_exp TermCtx zq_e vm in
                   let rhs_t = translate_exp TermCtx rhs_e vm in
                   Printf.sprintf "%s ( %s ) => %s"
                     op_name
                     (config_text z_t.text (sequence_term_for_sort "InstrSeq" lhs_t.text))
                     (config_text zq_t.text (sequence_term_for_sort "InstrSeq" rhs_t.text))
               | Some (z_e, lhs_e), None ->
                   let z_t = translate_exp TermCtx z_e vm in
                   let lhs_t = translate_exp TermCtx lhs_e vm in
                   let rhs_t = translate_exp TermCtx rhs vm in
                   Printf.sprintf "%s ( %s ) => %s"
                     op_name
                     (config_text z_t.text (sequence_term_for_sort "InstrSeq" lhs_t.text))
                     rhs_t.text
               | None, None ->
                   let lhs_t = translate_exp TermCtx lhs vm in
                   let rhs_t = translate_exp TermCtx rhs vm in
                   Printf.sprintf "%s ( %s ) => %s" op_name lhs_t.text rhs_t.text
               | None, Some _ ->
                   let call = format_call name (List.map (fun t -> t.text) ts) in
                   Printf.sprintf "%s => valid" call)
          | TupE [z; instrs; zq; vals] ->
              let z_t = translate_exp TermCtx z vm in
              let instrs_t = translate_exp TermCtx instrs vm in
              let zq_t = translate_exp TermCtx zq vm in
              let vals_t = translate_exp TermCtx vals vm in
              Printf.sprintf "%s ( %s ) => %s %s"
                op_name
                (config_text z_t.text (sequence_term_for_sort "InstrSeq" instrs_t.text))
                zq_t.text
                (sequence_term_for_sort "ValSeq" vals_t.text)
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
      if String.lowercase_ascii id.it = "list" && args <> [] then
        match args with
        | { it = TypA inner; _ } :: _ -> translate_typ inner vm
        | arg :: _ -> (translate_arg arg vm).text
        | [] -> spectec_type_term_of_name id.it []
      else
      let mapped = List.assoc_opt id.it vm in
      if args = [] then
        match mapped with
        | Some mapped -> mapped
        | None -> spectec_type_term_of_name id.it []
      else
        let head =
          match mapped with
          | Some mapped when mapped <> String.uppercase_ascii mapped -> mapped
          | _ -> spectec_type_constructor_head id.it (List.length args)
        in
        format_spectec_type_term head
          (List.map (fun a -> (translate_arg a vm).text) args)
  | IterT (inner, (List | List1 | ListN _)) ->
      translate_typ inner vm
  | IterT (inner, Opt) -> translate_typ inner vm
  | _ -> "SpectecTerminal"

and translate_typ_texpr (t : typ) vm : texpr =
  match t.it with
  | VarT (id, args) ->
      if String.lowercase_ascii id.it = "list" && args <> [] then
        match args with
        | { it = TypA inner; _ } :: _ -> translate_typ_texpr inner vm
        | arg :: _ -> translate_arg arg vm
        | [] -> texpr (spectec_type_term_of_name id.it [])
      else
      let mapped = List.assoc_opt id.it vm in
      let arg_ts = List.map (fun a -> translate_arg a vm) args in
	      let text =
	        if arg_ts = [] then
            match mapped with
            | Some mapped -> mapped
            | None -> spectec_type_term_of_name id.it []
	        else
	          let head =
	            match mapped with
	            | Some mapped when mapped <> String.uppercase_ascii mapped -> mapped
	            | _ -> spectec_type_constructor_head id.it (List.length args)
	          in
	          format_spectec_type_term head (List.map (fun a -> a.text) arg_ts)
	      in
      let own_vars =
        match arg_ts, mapped with
        | [], Some mapped when is_upper_token mapped -> [mapped]
        | _ -> []
      in
      { text; vars = own_vars @ List.concat_map (fun a -> a.vars) arg_ts }
  | IterT (inner, (List | List1 | ListN _)) ->
      translate_typ_texpr inner vm
  | IterT (inner, Opt) -> translate_typ_texpr inner vm
  | _ -> texpr "SpectecTerminal"

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
  match sequence_sort_of_typ typ vm with
  | Some seq_sort ->
      Printf.sprintf "%s : %s" term seq_sort
  | None ->
  let parametric_source_guard () =
    match typ.it with
    | VarT (id, args) when args <> []
                         && String.lowercase_ascii id.it <> "list" ->
        let parent_sort = sort_of_type_name id.it in
        let type_term =
          translate_typ_texpr typ vm
          |> fun tx -> strip_wrapping_parens tx.text |> String.trim
        in
        if type_term = "" then None
        else
          Some
            (Printf.sprintf "%s : %s" term
               (register_symbolic_syntax_type_sort parent_sort type_term))
    | _ -> None
  in
  match parametric_source_guard () with
  | Some guard -> guard
  | None ->
	  match simple_sort_of_typ typ vm with
	  | Some s when is_pure_meta_category_sort s ->
	      Printf.sprintf "%s : %s" term (semantic_sort_of_source_sort s)
	  | Some s when SSet.mem s !sequence_alias_sorts ->
	      (match Hashtbl.find_opt sequence_alias_elem_sorts s with
	       | Some elem_sort ->
           let seq_sort = native_sequence_sort_name elem_sort in
           register_native_sequence_sort elem_sort;
           Printf.sprintf "%s : %s" term seq_sort
       | None -> Printf.sprintf "%s : SpectecTerminals" term)
  | Some s -> Printf.sprintf "%s : %s" term s
  | None ->
      let ty = translate_typ typ vm in
      record_unsupported_syntax_family ty
        ("non-sort type guard for " ^ term);
      "true"

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
    | ExpB (tid, t) -> Some (tid.it, to_source_var_name (source_name_for_binder tid.it t))
    | TypB tid -> Some (tid.it, to_var_name tid.it)
    | _ -> None
  ) binders

let binder_type_conds binders =
  let has_lowercase s =
    String.exists (fun c -> c >= 'a' && c <= 'z') s
  in
  List.filter_map (fun b -> match b.it with
    | ExpB (tid, t) ->
        Some (type_guard (to_source_var_name (source_name_for_binder tid.it t)) t [])
	    | TypB tid ->
	        let source_sort = sort_of_type_name tid.it in
	        let var = to_var_name tid.it in
	        let guard_for_atom atom =
	          if SSet.mem (jhs_type_term_key atom) !raw_payload_type_terms then None
	          else Some (Printf.sprintf "typecheck(%s, %s) = true" var atom)
	        in
	        if is_pure_meta_category_sort source_sort then None
	        else
	        (match Hashtbl.find_opt source_sort_type_atoms source_sort with
	         | Some type_atom -> guard_for_atom type_atom
	         | None ->
	             if SSet.mem source_sort !source_membership_sorts then
               guard_for_atom (spectec_type_constructor_head tid.it 0)
             else if String.length tid.it > 1 && has_lowercase tid.it then
               guard_for_atom (spectec_type_constructor_head tid.it 0)
             else None)
    | _ -> None
  ) binders

let type_sort_of_typ (t : typ) vm : string option =
  simple_sort_of_typ t vm

let declared_sort_of_typ t =
  if is_bool_typ t [] then "Bool"
  else match type_sort_of_typ t [] with
    | Some s when is_pure_meta_category_sort s -> semantic_sort_of_source_sort s
    | Some s when s <> "SpectecTerminal" -> s
    | _ -> "SpectecTerminal"

let seq_decl_sort_of_inner_typ (inner : typ) =
  match sequence_sort_of_inner_typ inner [] with
  | Some seq_sort -> seq_sort
  | None -> "SpectecTerminals"

let decl_sort_of_typ (t : typ) =
  match t.it with
  | IterT (inner, (List | List1 | ListN _)) ->
      seq_decl_sort_of_inner_typ inner
  | _ ->
      (match sequence_sort_of_typ t [] with
       | Some seq_sort -> seq_sort
       | None ->
      match type_sort_of_typ t [] with
      | Some s when SSet.mem s !sequence_alias_sorts -> "SpectecTerminals"
      | _ -> declared_sort_of_typ t)

let source_carrier_sort_of_typ (t : typ) vm =
  match sequence_sort_of_typ t vm with
  | Some seq_sort -> seq_sort
  | None ->
		    match simple_sort_of_typ t vm with
		    | Some s when is_pure_meta_category_sort s -> semantic_sort_of_source_sort s
		    | Some s when SSet.mem s !sequence_alias_sorts ->
	          (match Hashtbl.find_opt sequence_alias_elem_sorts s with
	           | Some elem_sort ->
               register_native_sequence_sort elem_sort;
               native_sequence_sort_name elem_sort
           | None -> "SpectecTerminals")
	    | Some s when SSet.mem s !flat_sequence_source_sorts -> "SpectecTerminals"
	    | Some s when s <> "SpectecTerminal" -> s
	    | _ -> "SpectecTerminal"

let source_param_sort_of_typ (t : typ) vm =
  match t.it with
  | VarT (id, []) ->
      let sort = sort_of_type_name id.it in
      if Hashtbl.mem source_sort_type_atoms sort then sort
      else source_carrier_sort_of_typ t vm
  | _ -> source_carrier_sort_of_typ t vm

let source_param_sort (p : param) =
  match p.it with
  | ExpP (_, t) ->
      if is_bool_typ t [] then "Bool" else source_param_sort_of_typ t []
  | TypP _ -> "SpectecTerminal"
  | DefP _ | GramP _ -> "SpectecTerminal"

let source_param_var_sort (p : param) =
  match p.it with
  | ExpP (id, _) -> Some (to_var_name id.it, source_param_sort p)
  | TypP id -> Some (sanitize id.it, "SpectecTerminal")
  | DefP _ | GramP _ -> None

let source_nullary_term_has_sort term target =
  Hashtbl.fold
    (fun sort terms acc ->
      acc || (SSet.mem term terms && source_sort_reaches sort target))
    source_nullary_terms_by_sort false

let source_compound_cases_for_ctor ctor =
  !source_compound_cases
  |> List.filter (fun c -> c.compound_ctor = ctor)

let source_ctor_has_parent_sort ctor target_sort =
  source_compound_cases_for_ctor ctor
  |> List.exists (fun c -> source_sort_reaches c.compound_parent_sort target_sort)

let source_final_trap_instr_term () =
  let instr_sort = sort_of_type_name "instr" in
  finite_source_terms_for_sort instr_sort
  |> SSet.elements
  |> List.find_opt (fun term ->
       let suffix = source_ctor_suffix term |> String.lowercase_ascii in
       contains_substring suffix "trap")

let source_shape_constructor_matches ctor =
  source_ctor_has_parent_sort ctor (sort_of_type_name "shape")

let ctor_numeric_suffix term =
  let t = strip_wrapping_parens term |> String.trim in
  let re = Str.regexp "CTOR[A-Z]*\\([0-9]+\\)A0" in
  if is_source_ctor_name t then
    let suffix = source_ctor_suffix t in
    let digit_re = Str.regexp ".*?\\([0-9]+\\)$" in
    if Str.string_match digit_re suffix 0 then
      try Some (int_of_string (Str.matched_group 1 suffix)) with _ -> None
    else None
  else if Str.string_match re t 0 then
    try Some (int_of_string (Str.matched_group 1 t)) with _ -> None
  else None

let source_byte_lane_term term =
  match ctor_numeric_suffix term with
  | Some 8 -> true
  | _ -> false

let int_of_string_opt s =
  try Some (int_of_string s) with Failure _ -> None

let source_int_function_candidates fn =
  let strip_trailing_digits s =
    let rec loop i =
      if i > 0 then
        match s.[i - 1] with
        | '0' .. '9' -> loop (i - 1)
        | _ -> i
      else i
    in
    let n = loop (String.length s) in
    if n = String.length s then s else String.sub s 0 n
  in
  let strip_nn_suffix s =
    if ends_with s "nn" && String.length s > 2 then
      String.sub s 0 (String.length s - 2)
    else s
  in
  [fn; strip_trailing_digits fn; strip_nn_suffix (strip_trailing_digits fn)]
  |> List.sort_uniq String.compare

let rec eval_source_ground_unary_int_call seen fn arg =
  let arg = strip_wrapping_parens arg |> String.trim in
  if SSet.mem fn seen then None
  else
    let seen = SSet.add fn seen in
    let candidates = source_int_function_candidates fn in
    let direct =
      candidates
      |> List.find_map (fun candidate ->
           match find_source_ground_int_value candidate arg with
           | Some value -> int_of_string_opt value
           | None -> None)
    in
    match direct with
    | Some _ as result -> result
    | None ->
        candidates
        |> List.find_map (fun candidate ->
             !source_unary_int_aliases
             |> List.find_map (fun rule ->
                  if rule.source_alias_fn = candidate
                     && source_nullary_term_has_sort arg rule.source_alias_arg_sort
                  then
                    eval_source_ground_unary_int_call
                      seen rule.source_alias_target_fn arg
                  else None))

let source_int_function_known fn =
  let candidates = source_int_function_candidates fn in
  candidates
  |> List.exists (fun candidate ->
       SSet.mem candidate !source_unary_int_functions
       ||
       Hashtbl.to_seq_keys source_ground_int_call_values
       |> Seq.exists (fun key ->
            starts_with key (candidate ^ "\x1f"))
       || List.exists
            (fun rule -> rule.source_alias_fn = candidate)
            !source_unary_int_aliases)

let rec eval_ground_int_expr text =
  let text = strip_wrapping_parens text |> String.trim in
  if text = "" then None
  else
    try Some (int_of_string text)
    with Failure _ ->
      match parse_call_text text with
      | Some (fn, [arg]) when starts_with fn "lit" ->
          eval_ground_int_expr arg
      | Some (("$raw-lit" | "$raw-nat-lit" | "$raw-int-lit"), [arg]) ->
          eval_ground_int_expr arg
      | Some (fn, [arg]) ->
          (match eval_source_ground_unary_int_call SSet.empty fn arg with
           | Some _ as result -> result
           | None when source_int_function_known fn -> ctor_numeric_suffix arg
           | None -> None)
      | Some ("_+_", [a; b]) ->
          Option.bind (eval_ground_int_expr a)
            (fun x -> Option.map (fun y -> x + y) (eval_ground_int_expr b))
      | Some ("_-_", [a; b]) ->
          Option.bind (eval_ground_int_expr a)
            (fun x -> Option.map (fun y -> x - y) (eval_ground_int_expr b))
      | Some ("_*_", [a; b]) ->
          Option.bind (eval_ground_int_expr a)
            (fun x -> Option.map (fun y -> x * y) (eval_ground_int_expr b))
      | Some ("_quo_", [a; b]) ->
          Option.bind (eval_ground_int_expr a)
            (fun x ->
              match eval_ground_int_expr b with
              | Some y when y <> 0 -> Some (x / y)
              | _ -> None)
      | _ -> None

let rec eval_ground_bool_expr text =
  let text = strip_trailing_eq_true (strip_wrapping_parens text |> String.trim) in
  let eval_infix re pred =
    match split_once_re (Str.regexp re) text with
    | Some (a, b) ->
        Option.bind (eval_ground_int_expr a)
          (fun x -> Option.map (fun y -> pred x y) (eval_ground_int_expr b))
    | None -> None
  in
  match eval_infix "[ \t]+==[ \t]+" ( = ) with
  | Some _ as r -> r
  | None ->
  match eval_infix "[ \t]+=/=[ \t]+" ( <> ) with
  | Some _ as r -> r
  | None ->
  match eval_infix "[ \t]+<=[ \t]+" ( <= ) with
  | Some _ as r -> r
  | None ->
  match eval_infix "[ \t]+>=[ \t]+" ( >= ) with
  | Some _ as r -> r
  | None ->
  match eval_infix "[ \t]+<[ \t]+" ( < ) with
  | Some _ as r -> r
  | None ->
  match eval_infix "[ \t]+>[ \t]+" ( > ) with
  | Some _ as r -> r
  | None ->
  match parse_call_text text with
  | Some (("_and_" | "and"), [a; b]) ->
      (match eval_ground_bool_expr a, eval_ground_bool_expr b with
       | Some false, _ | _, Some false -> Some false
       | Some true, Some true -> Some true
       | _ -> None)
  | Some (("_or_" | "or"), [a; b]) ->
      (match eval_ground_bool_expr a, eval_ground_bool_expr b with
       | Some true, _ | _, Some true -> Some true
       | Some false, Some false -> Some false
       | _ -> None)
  | Some (("_==_" | "=="), [a; b]) ->
      Option.bind (eval_ground_int_expr a)
        (fun x -> Option.map (fun y -> x = y) (eval_ground_int_expr b))
  | Some (("_=/=_" | "=/="), [a; b]) ->
      Option.bind (eval_ground_int_expr a)
        (fun x -> Option.map (fun y -> x <> y) (eval_ground_int_expr b))
  | Some (("_<_" | "<"), [a; b]) ->
      Option.bind (eval_ground_int_expr a)
        (fun x -> Option.map (fun y -> x < y) (eval_ground_int_expr b))
  | Some (("_<=_" | "<="), [a; b]) ->
      Option.bind (eval_ground_int_expr a)
        (fun x -> Option.map (fun y -> x <= y) (eval_ground_int_expr b))
  | Some (("_>_" | ">"), [a; b]) ->
      Option.bind (eval_ground_int_expr a)
        (fun x -> Option.map (fun y -> x > y) (eval_ground_int_expr b))
  | Some (("_>=_" | ">="), [a; b]) ->
      Option.bind (eval_ground_int_expr a)
        (fun x -> Option.map (fun y -> x >= y) (eval_ground_int_expr b))
  | _ -> None

let ground_compound_membership_status term sort =
  match ctor_call_pattern term with
  | Some (ctor, [lane; dim])
      when source_shape_constructor_matches ctor
           && (sort = "Shape" || sort = "Ishape" || sort = "Bshape") ->
      let shape_ok =
        match ctor_numeric_suffix lane, eval_ground_int_expr dim with
        | Some lane_size, Some dim_n -> lane_size * dim_n = 128
        | _ -> false
      in
      if not shape_ok then Some false
      else if sort = "Shape" then Some true
      else if sort = "Ishape" then
        Some (source_nullary_term_has_sort lane "Jnn")
      else
        Some (source_byte_lane_term lane)
  | _ -> None

let eval_ground_condition text =
  let text = strip_trailing_eq_true (strip_wrapping_parens text |> String.trim) in
  match split_once_re (Str.regexp "[ \t]+:[ \t]+") text with
  | Some (term, sort) ->
      ground_compound_membership_status term (String.trim sort)
  | None -> eval_ground_bool_expr text

let simplify_static_conditions conds =
  let rec go acc = function
    | [] -> Some (List.rev acc)
    | cond :: rest ->
        (match eval_ground_condition cond with
         | Some true -> go acc rest
         | Some false -> None
         | None -> go (cond :: acc) rest)
  in
  go [] conds

let compound_term_allowed_for_sort term sort =
  match ground_compound_membership_status term sort with
  | Some false -> false
  | _ -> true

let finite_terms_for_sort sort =
  let max_terms = 2048 in
  let cartesian lists =
    List.fold_right
      (fun xs acc ->
        List.concat_map (fun x -> List.map (fun ys -> x :: ys) acc) xs)
      lists
      [[]]
  in
  let limit xs =
    let rec take n acc = function
      | [] -> List.rev acc
      | _ when n <= 0 -> List.rev acc
      | x :: rest -> take (n - 1) (x :: acc) rest
    in
    take max_terms [] xs
  in
  let rec go seen sort =
    if SSet.mem sort seen then []
    else
      let seen = SSet.add sort seen in
      let direct = finite_source_terms_for_sort sort |> SSet.elements in
      let conditional_alias_terms =
        match Hashtbl.find_opt source_conditional_alias_edges sort with
        | None -> []
        | Some children ->
            children
            |> SSet.elements
            |> List.concat_map (go seen)
      in
      let compound_terms =
        !source_compound_cases
        |> List.filter (fun c -> c.compound_parent_sort = sort)
        |> List.concat_map (fun c ->
             let per_field =
               c.compound_fields
               |> List.map (fun (_raw, ft) ->
                    match simple_sort_of_typ ft [] with
                    | Some field_sort -> go seen field_sort
                    | None -> [])
             in
             if per_field = [] || List.exists ((=) []) per_field then []
             else
	               cartesian per_field
               |> List.map (fun args -> format_source_ctor_call c.compound_ctor args)
             |> List.filter (fun term -> compound_term_allowed_for_sort term sort))
      in
      direct @ conditional_alias_terms @ compound_terms
      |> List.sort_uniq String.compare
      |> limit
  in
  go SSet.empty sort

let finite_axis_terms_for_sort sort =
  let terms = finite_terms_for_sort sort in
  if terms <> [] then terms
  else
    let max_terms = 2048 in
    let cartesian lists =
      List.fold_right
        (fun xs acc ->
          List.concat_map (fun x -> List.map (fun ys -> x :: ys) acc) xs)
        lists
        [[]]
    in
    let limit xs =
      let rec take n acc = function
        | [] -> List.rev acc
        | _ when n <= 0 -> List.rev acc
        | x :: rest -> take (n - 1) (x :: acc) rest
      in
      take max_terms [] xs
    in
    !source_compound_cases
    |> List.concat_map (fun c ->
         let per_field =
           c.compound_fields
           |> List.map (fun (_raw, ft) ->
                match simple_sort_of_typ ft [] with
                | Some field_sort -> finite_terms_for_sort field_sort
                | None -> [])
         in
         if per_field = [] || List.exists ((=) []) per_field then []
         else
           cartesian per_field
           |> List.filter_map (fun args ->
                let term = format_source_ctor_call c.compound_ctor args in
                match ground_compound_membership_status term sort with
                | Some true -> Some term
                | _ -> None))
    |> List.sort_uniq String.compare
    |> limit

let eval_ground_condition_with_source_membership text =
  let text = strip_trailing_eq_true (strip_wrapping_parens text |> String.trim) in
  match split_once_re (Str.regexp "[ \t]+:[ \t]+") text with
  | Some (term, sort) ->
      let term = strip_wrapping_parens term |> String.trim in
      let sort = String.trim sort in
      (match ground_compound_membership_status term sort with
       | Some _ as status -> status
       | None ->
           if List.mem term (finite_terms_for_sort sort) then Some true
           else None)
  | None -> eval_ground_bool_expr text

let simplify_static_conditions_with_source_membership conds =
  let rec go acc = function
    | [] -> Some (List.rev acc)
    | cond :: rest ->
        (match eval_ground_condition_with_source_membership cond with
         | Some true -> go acc rest
         | Some false -> None
         | None -> go (cond :: acc) rest)
  in
  go [] conds

let compound_arg_choices_for_declared_sort declared_sort actual_typ v_map =
  let cartesian lists =
    List.fold_right
      (fun xs acc ->
        List.concat_map (fun x -> List.map (fun ys -> x :: ys) acc) xs)
      lists
      [[]]
  in
  let actual_fields =
    match actual_typ.it with
    | TupT fields -> fields
    | _ -> []
  in
  if actual_fields = [] then []
  else
    let candidate_parent_sorts =
      let direct = [declared_sort] in
      let conditional =
        match Hashtbl.find_opt source_conditional_alias_edges declared_sort with
        | Some children -> SSet.elements children
        | None -> []
      in
      direct @ conditional
    in
    let case_has_ground_status c =
      let sample_args =
        c.compound_fields
        |> List.filter_map (fun (_raw, ft) ->
             match simple_sort_of_typ ft [] with
             | Some field_sort ->
                 finite_terms_for_sort field_sort
                 |> List.find_opt (fun _ -> true)
             | None -> None)
      in
      List.length sample_args = List.length c.compound_fields
      &&
      match
        ground_compound_membership_status
          (format_source_ctor_call c.compound_ctor sample_args)
          declared_sort
      with
      | Some _ -> true
      | None -> false
    in
    let direct_cases =
      candidate_parent_sorts
      |> List.concat_map (fun parent_sort ->
           !source_compound_cases
           |> List.filter (fun c ->
                c.compound_parent_sort = parent_sort
                && List.length c.compound_fields = List.length actual_fields))
    in
    let candidate_cases =
      if direct_cases <> [] then direct_cases
      else
        !source_compound_cases
        |> List.filter (fun c ->
             List.length c.compound_fields = List.length actual_fields
             && case_has_ground_status c)
    in
    candidate_cases
    |> List.concat_map (fun c ->
              let per_field =
                List.map2
                  (fun (actual_exp, _actual_ft) (_decl_raw, decl_ft) ->
                    let raw_opt =
                      match actual_exp.it with
                      | VarE id -> Some id.it
                      | _ -> None
                    in
	                    match simple_sort_of_typ decl_ft [] with
	                    | Some field_sort ->
	                        finite_axis_terms_for_sort field_sort
                        |> List.map (fun term ->
                             let assigns =
                               match raw_opt with
                               | None -> []
                               | Some raw ->
                                   let subst_var =
                                     match List.assoc_opt raw v_map with
                                     | Some mv -> mv
                                     | None -> to_var_name raw
                                   in
                                   [(subst_var, term)]
                             in
                             (term, assigns))
                    | None -> [])
                  actual_fields c.compound_fields
              in
              if per_field = [] || List.exists ((=) []) per_field then []
              else
	                cartesian per_field
		                |> List.map (fun selected ->
		                     let terms = List.map fst selected in
		                     let assignments = List.concat_map snd selected in
		                     let term = format_source_ctor_call c.compound_ctor terms in
                     (term, assignments, [Printf.sprintf "%s : %s" term declared_sort]))
                |> List.filter (fun (term, _, _) ->
                     compound_term_allowed_for_sort term declared_sort))
	    |> List.sort_uniq compare

let compound_arg_choices_for_declared_sort_from_exp
    declared_sort actual_exp v_map binder_sort_of_raw =
  let cartesian lists =
    List.fold_right
      (fun xs acc ->
        List.concat_map (fun x -> List.map (fun ys -> x :: ys) acc) xs)
      lists
      [[]]
  in
  let payload_exps e =
    match e.it with
    | TupE es -> es
    | OptE None -> []
    | _ -> [e]
  in
  let rec choices_for_sort expected_sort e =
    match e.it with
    | VarE id ->
        let raw = id.it in
        let domain_sort =
          match binder_sort_of_raw raw with
          | Some sort when finite_axis_terms_for_sort sort <> [] -> sort
          | _ -> expected_sort
        in
        let subst_var =
          match List.assoc_opt raw v_map with
          | Some mv -> mv
          | None -> to_var_name raw
        in
        finite_axis_terms_for_sort domain_sort
        |> List.map (fun term -> (term, [(subst_var, term)], []))
    | NumE _ ->
        let raw = translate_exp TermCtx e v_map |> fun t -> t.text in
        (match literal_wrapper_for_sort ~register:true expected_sort with
         | Some (wrapper, _) -> [(Printf.sprintf "%s(%s)" wrapper raw, [], [])]
         | None -> [(raw, [], [])])
    | SubE (inner, _, _)
    | CvtE (inner, _, _)
    | LiftE inner
    | TheE inner
    | OptE (Some inner) ->
        choices_for_sort expected_sort inner
    | CaseE (mixop_arg, payload) ->
        let fields = payload_exps payload in
        let ctor_opt = canonical_ctor_name_arity mixop_arg (List.length fields) in
        let compound_choices =
          match ctor_opt with
          | Some ctor -> choices_for_compound expected_sort ctor fields
          | None -> []
        in
        if compound_choices <> [] then compound_choices
        else
          (match fields, ctor_opt with
           | [], Some ctor -> [(ctor, [], [])]
           | [inner], _ -> choices_for_sort expected_sort inner
           | _ -> [])
    | TupE fields ->
        choices_for_compound expected_sort "" fields
    | _ -> []
  and choices_for_compound expected_sort actual_ctor actual_fields =
    let candidate_parent_sorts =
      let conditional =
        match Hashtbl.find_opt source_conditional_alias_edges expected_sort with
        | Some children -> SSet.elements children
        | None -> []
      in
      expected_sort :: conditional
    in
    let direct_cases =
      candidate_parent_sorts
      |> List.concat_map (fun parent_sort ->
           !source_compound_cases
           |> List.filter (fun c ->
                c.compound_parent_sort = parent_sort
                && List.length c.compound_fields = List.length actual_fields
                && (actual_ctor = "" || c.compound_ctor = actual_ctor)))
    in
    let candidate_cases =
      if direct_cases <> [] then direct_cases
      else
        !source_compound_cases
        |> List.filter (fun c ->
             List.length c.compound_fields = List.length actual_fields
             && (actual_ctor = "" || c.compound_ctor = actual_ctor))
    in
    candidate_cases
    |> List.concat_map (fun c ->
         let per_field =
           List.map2
             (fun actual_e (_decl_raw, decl_ft) ->
               match simple_sort_of_typ decl_ft [] with
               | Some field_sort -> choices_for_sort field_sort actual_e
               | None -> [])
             actual_fields c.compound_fields
         in
         if per_field = [] || List.exists ((=) []) per_field then []
         else
           cartesian per_field
           |> List.map (fun selected ->
                let terms = List.map (fun (term, _, _) -> term) selected in
                let assignments = List.concat_map (fun (_, assigns, _) -> assigns) selected in
                let guards = List.concat_map (fun (_, _, guards) -> guards) selected in
                let term = format_source_ctor_call c.compound_ctor terms in
                (term, assignments, guards @ [Printf.sprintf "%s : %s" term expected_sort]))
           |> List.filter (fun (term, _, _) ->
                compound_term_allowed_for_sort term expected_sort))
    |> List.sort_uniq compare
  in
  choices_for_sort declared_sort actual_exp

let compound_binder_choices_for_declared_sort declared_sort binders v_map =
  let cartesian lists =
    List.fold_right
      (fun xs acc ->
        List.concat_map (fun x -> List.map (fun ys -> x :: ys) acc) xs)
      lists
      [[]]
  in
  let binder_domain_sort bt =
    match bt.it with
    | VarT (tid, []) -> Some (sort_of_type_name tid.it)
    | IterT (inner, Opt) -> simple_sort_of_typ inner []
    | _ -> simple_sort_of_typ bt []
  in
  let exp_binders =
    binders
    |> List.filter_map (fun b -> match b.it with
         | ExpB (bid, bt) -> Some (bid.it, bt)
         | _ -> None)
  in
  if exp_binders = [] then []
  else
    let candidate_parent_sorts =
      let direct = [declared_sort] in
      let conditional =
        match Hashtbl.find_opt source_conditional_alias_edges declared_sort with
        | Some children -> SSet.elements children
        | None -> []
      in
      direct @ conditional
    in
    let case_has_ground_status c =
      let sample_args =
        c.compound_fields
        |> List.filter_map (fun (_raw, ft) ->
             match simple_sort_of_typ ft [] with
             | Some field_sort ->
                 finite_terms_for_sort field_sort
                 |> List.find_opt (fun _ -> true)
             | None -> None)
      in
      List.length sample_args = List.length c.compound_fields
      &&
      match
        ground_compound_membership_status
          (format_source_ctor_call c.compound_ctor sample_args)
          declared_sort
      with
      | Some _ -> true
      | None -> false
    in
    let direct_cases =
      candidate_parent_sorts
      |> List.concat_map (fun parent_sort ->
           !source_compound_cases
           |> List.filter (fun c ->
                c.compound_parent_sort = parent_sort
                && List.length c.compound_fields = List.length exp_binders))
    in
    let candidate_cases =
      if direct_cases <> [] then direct_cases
      else
        !source_compound_cases
        |> List.filter (fun c ->
             List.length c.compound_fields = List.length exp_binders
             && case_has_ground_status c)
    in
    candidate_cases
    |> List.concat_map (fun c ->
              let per_field =
                List.map2
                  (fun (raw, bt) (_decl_raw, decl_ft) ->
                    let domain_sort =
	                      match binder_domain_sort bt with
	                      | Some binder_sort
	                          when finite_axis_terms_for_sort binder_sort <> [] ->
	                          binder_sort
                      | _ ->
                          (match simple_sort_of_typ decl_ft [] with
                           | Some field_sort -> field_sort
                           | None -> "SpectecTerminal")
                    in
	                    let terms = finite_axis_terms_for_sort domain_sort in
                    let subst_var =
                      match List.assoc_opt raw v_map with
                      | Some mv -> mv
                      | None -> to_var_name raw
                    in
                    terms
                    |> List.map (fun term -> (term, [(subst_var, term)])))
                  exp_binders c.compound_fields
              in
              if per_field = [] || List.exists ((=) []) per_field then []
              else
	                cartesian per_field
	                |> List.map (fun selected ->
	                     let terms = List.map fst selected in
	                     let assignments = List.concat_map snd selected in
	                     let term = format_source_ctor_call c.compound_ctor terms in
	                     (term, assignments, []))
                |> List.filter (fun (term, _, _) ->
                     compound_term_allowed_for_sort term declared_sort))
    |> List.sort_uniq compare

(* DecD helper functions operate on C1's coarse CTOR carrier, but must
   preserve runtime structural sorts used by generated configs/states. *)
let structural_decd_sorts =
  ["Config"; "State"; "Store"; "Frame"; "Judgement"]

let decd_sort_of_typ (t : typ) =
  match t.it with
  | IterT (_, (List | List1 | ListN _)) -> "SpectecTerminals"
  | IterT (_, Opt) -> "SpectecTerminals"
  | TupT _ -> "SpectecTerminals"
  | _ ->
      if is_bool_typ t [] then "Bool"
      else
        match type_sort_of_typ t [] with
        | Some s when SSet.mem s !flat_sequence_source_sorts -> "SpectecTerminals"
        | Some s when SSet.mem s !sequence_alias_sorts -> "SpectecTerminals"
        | Some s when List.mem s structural_decd_sorts -> s
        | Some s when is_pure_meta_category_sort s -> semantic_sort_of_source_sort s
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
  let typd_params = params in
  let is_parametric = params <> [] in
  let type_sort = sort_of_type_name id.it in
  let canonical_ctor_name_arity ?case_typ mixop arity =
    source_ctor_name_from_mixop ~category:id.it ?case_typ mixop arity
  in
  let is_meta_numeric_alias = is_meta_numeric_alias_sort type_sort in
  let mk_type_term_texpr args v_map =
    let arg_ts = List.map (fun a -> translate_arg a v_map) args in
    let text =
      match String.lowercase_ascii name, arg_ts with
      | "list", [arg_t] -> ensure_spectec_type_term arg_t.text
      | _ ->
          spectec_type_term_of_name id.it (List.map (fun a -> a.text) arg_ts)
    in
    { text;
      vars = List.concat_map (fun a -> a.vars) arg_ts }
  in
  (* Sorts where instance axiom (cmb/mb) generation doesn't work — list-based or conflicting *)
  let skip_instance_sorts = SSet.of_list ["Char"; "Zero"; "NzNat"; "Nat"; "Int"; "Bool"] in
  let sort_decl =
    if SSet.mem name base_types || type_sort = "SpectecTerminal"
       || SSet.mem type_sort maude_builtin_sort_names
       || is_meta_numeric_alias then ""
    else
      Printf.sprintf "  sort %s .\n  subsort %s < SpectecTerminal .\n"
        type_sort type_sort in
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
  let op_decl = "" in
  let unsupported_parametric_membership detail =
    record_unsupported_syntax_family name detail;
    ""
  in
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
    && not (source_protected_nonvariable_token v)
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
  let finite_pattern_sort_of_var v =
    !source_membership_sorts
    |> SSet.elements
    |> List.find_opt (fun sort ->
         to_var_name sort = v && finite_axis_terms_for_sort sort <> [])
  in
  let category_pattern_bool var term =
    match finite_pattern_sort_of_var var with
    | None -> None
    | Some sort ->
        Some (`Bool,
              (Printf.sprintf "%s : %s" term.text sort,
               vars_of_texpr_local term,
               []),
              true)
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
        let default_bool () =
          let vars = vars_of_texpr_local bool_t in
          let ready = subset_bound_local bound vars in
          (`Bool, (bool_t.text, vars, []), ready)
        in
        if is_plain_var_like lhs.text
           && lhs_nonempty && lhs_has_no_bound && subset_bound_local bound rhs_vars then
          match lhs_vars with
          | [v] ->
              (match category_pattern_bool v rhs with
               | Some classified -> classified
               | None ->
                   (`Match,
                    (Printf.sprintf "%s := %s" lhs.text rhs.text,
                     uniq_vars_local (lhs_vars @ rhs_vars),
                     lhs_vars),
                    true))
          | _ ->
              (`Match,
               (Printf.sprintf "%s := %s" lhs.text rhs.text,
                uniq_vars_local (lhs_vars @ rhs_vars),
                lhs_vars),
               true)
        else if is_plain_var_like rhs.text
                && rhs_nonempty && rhs_has_no_bound && subset_bound_local bound lhs_vars then
          match rhs_vars with
          | [v] ->
              (match category_pattern_bool v lhs with
               | Some classified -> classified
               | None ->
                   (`Match,
                    (Printf.sprintf "%s := %s" rhs.text lhs.text,
                     uniq_vars_local (lhs_vars @ rhs_vars),
                     rhs_vars),
                    true))
          | _ ->
              (`Match,
               (Printf.sprintf "%s := %s" rhs.text lhs.text,
                uniq_vars_local (lhs_vars @ rhs_vars),
                rhs_vars),
               true)
        else default_bool ()
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
                  if is_source_ctor_var_token tok || is_source_ctor_name tok
                  then acc
                  else tok :: acc
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
			                 List.mem (String.lowercase_ascii id.it)
		                       ["bit"; "byte"; "un"; "sn"; "uN"; "sN"; "vunop"; "vbinop"]
	               in
               let type_counters = ref [] in
               let get_count tname =
                 let c = (try List.assoc tname !type_counters with Not_found -> 0) + 1 in
                 type_counters := (tname, c) :: (List.remove_assoc tname !type_counters); c in
               let fresh_param_name base =
                 let count = get_count base in
                 if count = 1 then base else base ^ string_of_int count
               in
               let rec typ_base_name_for_var t vm fallback =
                 let arg_base_name a =
                   match a.it with
                   | TypA t -> Some (typ_base_name_for_var t vm "TYPE")
                   | ExpA e ->
                       (match e.it with
                        | VarE tid ->
                            let raw =
                              match List.assoc_opt tid.it vm with
                              | Some mapped -> raw_source_name_of_type_var mapped
                              | None -> tid.it
                            in
                            Some (source_var_component raw)
                        | NumE (`Nat z | `Int z) -> Some (Z.to_string z)
                        | NumE (`Rat q) ->
                            Some (Z.to_string (Q.num q) ^ "_" ^ Z.to_string (Q.den q))
                        | NumE (`Real r) ->
                            Some (sanitize (Printf.sprintf "%.17g" r))
                        | _ -> None)
                   | _ -> None
                 in
                 match t.it with
                 | VarT (tid, args)
                     when args <> []
                          && String.lowercase_ascii tid.it <> "list" ->
                     let head =
                       tid.it |> sanitize |> trim_tail_hyphen |> source_var_component
                     in
                     let comps = args |> List.filter_map arg_base_name in
                     if comps = [] then head
                     else head ^ "_" ^ String.concat "_" comps
                 | VarT (tid, []) ->
                     tid.it |> sanitize |> trim_tail_hyphen |> source_var_component
                 | _ -> fallback
               in
	               let broad_ctor_arg_sort sort =
                 match sort with
                 | "SpectecTerminals" -> "SpectecTerminals"
                 | "Nat" | "Int" | "Bool" -> sort
                 | _ when is_pure_meta_category_sort sort ->
                     semantic_sort_of_source_sort sort
                 | _ when ends_with sort "Seq" -> "SpectecTerminals"
                 | _ -> "SpectecTerminal"
               in
	               let guard_for_sort v sort =
	                 match sort with
	                 | "SpectecTerminal" | "SpectecTerminals" -> "true"
	                 | _ -> Printf.sprintf "%s : %s" v sort
	               in
               let rec collect_params cur_vm t is_list = match t.it with
	                 | VarT (tid, args) ->
                     let vb =
                       typ_base_name_for_var t cur_vm (to_var_name tid.it)
                     in
                     let sequence_param =
                       is_list || is_plural_type tid.it
                       || (String.lowercase_ascii tid.it = "list" && args <> [])
                     in
	                     let prelim_indexed =
	                       if sequence_param then
	                         vb ^ "-LIST-" ^ String.uppercase_ascii (sanitize tid.it)
	                         ^ string_of_int (get_count vb)
	                       else fresh_param_name vb in
                     let prelim_vm = (tid.it, prelim_indexed) :: cur_vm in
	                     let ms =
	                       if sequence_param then
                         (match sequence_sort_of_typ t cur_vm with
                          | Some seq_sort -> seq_sort
                          | None ->
                              (match simple_sort_of_typ t prelim_vm with
                               | Some elem_sort ->
                                   (match sequence_sort_of_elem_sort elem_sort with
                                    | Some seq_sort -> seq_sort
                                    | None -> "SpectecTerminals")
	                               | None -> "SpectecTerminals"))
		                       else source_carrier_sort_of_typ t cur_vm
	                     in
                       let indexed =
	                         if sequence_param then
                           let base = String.uppercase_ascii (sanitize ms) in
                           fresh_param_name base
                         else prelim_indexed
                       in
                       let new_vm = (tid.it, indexed) :: cur_vm in
	                    Hashtbl.replace source_var_sorts indexed ms;
	                    let guard =
	                      if sequence_param
                      then guard_for_sort indexed ms
                      else type_guard indexed t cur_vm
                    in
                    ([(indexed, guard, ms)], new_vm)
	                 | IterT (inner, iter) ->
	                     let sequence_like =
	                       match iter with
	                       | List | List1 | ListN _ | Opt -> true
	                     in
	                     collect_params cur_vm inner sequence_like
	                 | TupT fields ->
                     List.fold_left (fun (acc, vm) (fe, ft) ->
                       match fe.it with
                       | VarE tid when tid.it <> "_" ->
                           let vb =
                             typ_base_name_for_var ft vm (to_var_name tid.it)
                           in
	                           let prelim_indexed =
	                             if is_list then
	                               vb ^ "-LIST-" ^ String.uppercase_ascii (sanitize tid.it)
	                               ^ string_of_int (get_count vb)
	                             else fresh_param_name vb in
                       let prelim_vm = (tid.it, prelim_indexed) :: vm in
	                       let ms =
	                             if is_list then
	                               (match sequence_sort_of_inner_typ ft prelim_vm with
	                                | Some seq_sort -> seq_sort
	                                | None -> "SpectecTerminals")
	                             else
			                               source_carrier_sort_of_typ ft prelim_vm
		                        in
                          let indexed =
                            if is_list then
                              let base = String.uppercase_ascii (sanitize ms) in
                              fresh_param_name base
                            else prelim_indexed
                          in
                          let vm' = (tid.it, indexed) :: vm in
		                        Hashtbl.replace source_var_sorts indexed ms;
		                        let guard =
	                          if is_list then guard_for_sort indexed ms
	                          else type_guard indexed ft vm'
	                        in
	                        (acc @ [(indexed, guard, ms)], vm')
                       | _ ->
                           let (ps, vm') = collect_params vm ft is_list in
                           (acc @ ps, vm')
                     ) ([], cur_vm) fields
                 | _ -> ([], cur_vm)
               in
               let enriched_vm = build_suffix_map binders @ v_map in
               let rec ctor_arg_sorts cur_vm t is_list =
                 let seq_or_broad sort =
                   if ends_with sort "Seq" then sort
                   else match sequence_sort_of_elem_sort sort with
                   | Some seq_sort -> seq_sort
                   | None -> "SpectecTerminals"
                 in
                 match t.it with
                 | VarT (tid, args) ->
                     let base_sort = source_carrier_sort_of_typ t cur_vm in
                     let ms =
                       if is_list || is_plural_type tid.it
                          || (String.lowercase_ascii tid.it = "list" && args <> [])
                       then
                         (match sequence_sort_of_typ t cur_vm with
                          | Some seq_sort -> seq_sort
                          | None -> seq_or_broad base_sort)
                       else base_sort
                     in
                     [ms]
                 | IterT (inner, Opt) ->
                     (match sequence_sort_of_typ t cur_vm with
                      | Some seq_sort -> [seq_sort]
                      | None ->
                          (* Fallback only when the optional element has no
                             source syntax sequence sort. *)
                          List.map (fun _ -> "SpectecTerminals")
                            (ctor_arg_sorts cur_vm inner false))
                 | IterT (inner, (List | List1 | ListN _)) ->
                     ctor_arg_sorts cur_vm inner true
                 | TupT fields ->
                     fields
                     |> List.concat_map (fun (fe, ft) ->
                          match fe.it with
                          | VarE tid when tid.it <> "_" ->
                              let vm' = (tid.it, to_var_name tid.it) :: cur_vm in
                              let base_sort = source_carrier_sort_of_typ ft vm' in
                              if is_list then [seq_or_broad base_sort]
                              else [base_sort]
                          | _ -> ctor_arg_sorts cur_vm ft is_list)
                 | _ -> []
               in
               let (params0, param_vm) = collect_params enriched_vm case_typ false in
               let params =
	                 if params0 <> [] || source_mixop_has_constructor_name mixop_val then params0
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
		                         Hashtbl.replace source_var_sorts mv ms;
		                         Some (mv, type_guard mv t param_vm, ms)
                     | _ -> None
	                   ) binders
	               in
               let params =
                 let ctor_sorts = ctor_arg_sorts param_vm case_typ false in
                 if List.length ctor_sorts = List.length params then
                   List.map2
                     (fun (v, g, ms) ctor_sort ->
                       let broad = broad_ctor_arg_sort ctor_sort in
                       if broad = "SpectecTerminals" && ms <> "SpectecTerminals"
                       then begin
                         Hashtbl.replace source_var_sorts v "SpectecTerminals";
                         (v, g, "SpectecTerminals")
                       end else (v, g, ms))
                     params ctor_sorts
                 else params
               in
               let rec collect_param_sources t is_list =
                 match t.it with
                 | VarT (tid, _) -> [(Some tid.it, Some t, is_list)]
                 | IterT (inner, iter) ->
                     let sequence_like =
                       match iter with
                       | List | List1 | ListN _ -> true
                       | Opt -> is_list
                     in
                     collect_param_sources inner sequence_like
                 | TupT fields ->
                     fields
                     |> List.concat_map (fun (fe, ft) ->
                          match fe.it with
                          | VarE tid when tid.it <> "_" ->
                              [(Some tid.it, Some ft, is_list)]
                          | _ -> collect_param_sources ft is_list)
                 | _ -> []
               in
               let param_sources = collect_param_sources case_typ false in
               let param_infos =
                 List.mapi
                   (fun i (v, g, ms) ->
                     let raw_opt, typ_opt, _ =
                       match List.nth_opt param_sources i with
                       | Some src -> src
                       | None -> (None, None, false)
                     in
                     (i, v, g, ms, raw_opt, typ_opt))
                   params
               in
		               let p_vars = List.map (fun (v, _, _) -> v) params in
		               let v_decl () =
		                 String.concat "" (List.map (fun (v, _, ms) -> declare_var v ms) params)
		               in
               let binder_decl () =
                 binders
                 |> List.filter_map (fun b -> match b.it with
                      | ExpB (tid, t) ->
                          let source_name = source_name_for_binder tid.it t in
                          let var =
                            match List.assoc_opt tid.it param_vm with
                            | Some mapped -> mapped
                            | None -> to_source_var_name source_name
                          in
                          let sort =
                            source_carrier_sort_of_typ t param_vm
                            |> semantic_sort_of_source_sort
                          in
                          Some (var, sort)
                      | _ -> None)
                 |> declare_vars_by_sort
               in
               let type_term_decl () =
                 let param_decl =
                   typd_params
                   |> List.filter_map source_param_var_sort
                   |> declare_vars_by_sort
                 in
                 let declared_param_vars =
                   typd_params
                   |> List.filter_map source_param_var_sort
                   |> List.map fst
                 in
	                 let fallback_vars =
	                   vars_of_texpr_local type_term_t
	                   |> List.filter (fun v -> not (List.mem v declared_param_vars))
	                 in
	                 let fallback_decl =
	                   fallback_vars
	                   |> List.map (fun v -> (v, decl_sort_of_type_term_var v))
	                   |> declare_vars_by_sort
	                 in
	                 param_decl ^ fallback_decl
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
                           if is_source_ctor_var_token tok || is_source_ctor_name tok
                           then acc
                           else tok :: acc
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
               let strip_source_index_suffix raw =
                 let re = Str.regexp "^\\(.+\\)_[0-9]+$" in
                 if Str.string_match re raw 0 then
                   match str_matched_group_opt 1 raw with Some s -> s | None -> raw
                 else raw
               in
               let has_source_index_suffix raw =
                 let re = Str.regexp "^.+_[0-9]+$" in
                 Str.string_match re raw 0
               in
               let type_term_arg_guards =
                 let guard_for_var_raw var raw =
                   let raw = strip_source_index_suffix raw in
                   let source_sort = sort_of_type_name raw in
                   let type_atom =
                     match Hashtbl.find_opt source_sort_type_atoms source_sort with
                     | Some atom -> Some atom
                     | None ->
                         if SSet.mem source_sort !source_membership_sorts then
                           Some (spectec_type_constructor_head raw 0)
                         else if String.length raw > 1
                                 && String.exists
                                      (fun c -> c >= 'a' && c <= 'z')
                                      raw
                         then Some (spectec_type_constructor_head raw 0)
                         else None
                   in
                   match type_atom with
                   | Some atom
                       when is_plain_var_like var
                            && var <> atom
                            && not
                                 (SSet.mem (jhs_type_term_key atom)
                                    !raw_payload_type_terms) ->
                       Some (Printf.sprintf "%s : %s" var source_sort)
                   | _ -> None
                 in
                 let guards_from_args =
                   args
                   |> List.filter_map (fun arg ->
                      match arg.it with
                      | ExpA {it = VarE eid; _} ->
                          let tx = translate_arg arg v_map in
                          let var =
                            strip_wrapping_parens tx.text |> String.trim
                          in
                          guard_for_var_raw var eid.it
                      | TypA {it = VarT (tid, []); _} ->
                          let tx = translate_arg arg v_map in
                          let var =
                            strip_wrapping_parens tx.text |> String.trim
                          in
                          guard_for_var_raw var tid.it
                      | _ -> None)
                 in
	                 let guards_from_type_term =
	                   vars_of_texpr_local type_term_t
		                   |> List.filter (fun v -> v <> spectec_term_var)
                   |> List.filter_map (fun v ->
                        guard_for_var_raw v (raw_source_name_of_type_var v))
                 in
                 guards_from_args @ guards_from_type_term
                 |> List.sort_uniq String.compare
               in
               let sort_and_raw_of_family_arg arg =
                 match arg.it with
                 | TypA t ->
                     (match t.it with
                      | VarT (tid, []) ->
                          let raw = tid.it in
                          let sort =
                            sort_of_type_name (strip_source_index_suffix raw)
                          in
                          Some (sort, Some raw)
                      | _ ->
                          (match simple_sort_of_typ t param_vm with
                           | Some sort -> Some (sort, None)
                           | None -> None))
                 | ExpA e ->
                     (match e.it with
                      | VarE eid ->
                          let raw = eid.it in
                          let sort = sort_of_type_name (strip_source_index_suffix raw) in
                          Some (sort, Some raw)
                      | CaseE (mixop_arg, payload) ->
                          let has_payload =
                            match payload.it with
                            | OptE None | TupE [] -> false
                            | _ -> true
                          in
                          if has_payload then None
                          else
                            (match canonical_ctor_name_arity mixop_arg 0 with
                             | Some ctor ->
                                 let suffix = nullary_ctor_suffix ctor in
                                 Some (suffix, Some ctor)
                             | None -> None)
                      | _ -> None)
                 | DefA _ | GramA _ -> None
               in
	               let find_axis_param before_index domain_sort raw_opt =
	                 let exact_raw_match raw (_, _, _, _, p_raw, _) =
	                   match p_raw with
	                   | Some p_raw ->
	                       p_raw = raw
	                       || ((not (has_source_index_suffix raw))
	                           && (not (has_source_index_suffix p_raw))
	                           && strip_source_index_suffix p_raw = strip_source_index_suffix raw)
	                   | None -> false
	                 in
                 let candidates =
                   param_infos
                   |> List.filter (fun (i, _, _, _, _, _) -> i < before_index)
                 in
	                 match raw_opt with
	                 | Some raw ->
	                     (match List.find_opt (exact_raw_match raw) candidates with
	                      | Some hit -> Some hit
	                      | None when not (has_source_index_suffix raw) ->
	                          let by_sort =
	                            candidates
	                            |> List.filter (fun (_, _, _, ms, _, _) -> ms = domain_sort)
	                          in
	                          (match by_sort with [hit] -> Some hit | _ -> None)
	                      | None -> None)
                 | None ->
                     let by_sort =
                       candidates
                       |> List.filter (fun (_, _, _, ms, _, _) -> ms = domain_sort)
                     in
                     (match by_sort with [hit] -> Some hit | _ -> None)
               in
               let cartesian lists =
                 List.fold_right
                   (fun xs acc ->
                     List.concat_map (fun x -> List.map (fun ys -> x :: ys) acc) xs)
                   lists
                   [[]]
               in
	               let parametric_arg_specializations () =
	                 param_infos
	                 |> List.filter_map
	                      (fun (i, dep_v, _dep_g, _dep_ms, _raw_opt, typ_opt) ->
                        match typ_opt with
                        | Some {it = VarT (family_id, family_args); _}
                            when family_args <> [] ->
                            let family_sort = sort_of_type_name family_id.it in
                            let axes =
                              family_args
                              |> List.filter_map (fun arg ->
                                   match sort_and_raw_of_family_arg arg with
                                   | None -> None
                                   | Some (domain_sort, raw_opt) ->
                                       let terms =
                                         finite_axis_terms_for_sort domain_sort
                                       in
                                       match terms, find_axis_param i domain_sort raw_opt with
                                       | [], _ -> None
                                       | _, Some (_, axis_v, axis_g, axis_sort, _, _) ->
                                           Some (axis_v, axis_g, axis_sort, terms)
                                       | _, None -> None)
                            in
                            if List.length axes = List.length family_args && axes <> [] then
                              Some (dep_v, family_sort, axes)
                            else begin
                              record_unsupported_syntax_family family_sort
                                ("cannot derive finite constructor specialization in " ^ full_type_sort);
                              None
	                            end
	                        | _ -> None)
	               in
	               let parametric_literal_type_dependencies () =
	                 param_infos
	                 |> List.filter_map
	                      (fun (i, _dep_v, _dep_g, _dep_ms, _raw_opt, typ_opt) ->
	                        match typ_opt with
	                        | Some {it = VarT (family_id, family_args); _}
	                            when family_args <> [] ->
	                            let family_sort = sort_of_type_name family_id.it in
	                            if not (SSet.mem family_sort !literal_family_parent_sorts) then None
	                            else
	                              let axes =
	                                family_args
	                                |> List.filter_map (fun arg ->
	                                     match sort_and_raw_of_family_arg arg with
	                                     | None -> None
	                                     | Some (domain_sort, raw_opt) ->
	                                         let terms =
	                                           finite_axis_terms_for_sort domain_sort
	                                         in
	                                         match terms, find_axis_param i domain_sort raw_opt with
	                                         | [], _ -> None
	                                         | _, Some (axis_i, _axis_v, _axis_g, _axis_sort, _, _) ->
	                                             Some axis_i
	                                         | _, None -> None)
	                              in
	                              (match axes with
	                               | [axis_i] when axis_i <> i -> Some (i, axis_i)
	                               | _ -> None)
	                        | _ -> None)
	               in
	               let compatible_assignments a b =
	                 List.for_all
	                   (fun (v, t) ->
                     match List.assoc_opt v b with
                     | Some t' -> t = t'
                     | None -> true)
                   a
               in
               let merge_assignments a b =
                 List.fold_left
                   (fun acc (v, t) ->
                     match List.assoc_opt v acc with
                     | Some _ -> acc
                     | None -> (v, t) :: acc)
                   a b
               in
	               let finite_guard_choice_lists conds =
	                 conds
	                 |> List.filter_map (fun cond ->
	                      let cond =
	                        strip_trailing_eq_true
	                          (strip_wrapping_parens cond |> String.trim)
	                      in
	                      match split_once_re (Str.regexp "[ \t]+:[ \t]+") cond with
	                      | Some (term, sort) ->
	                          let term = strip_wrapping_parens term |> String.trim in
	                          let sort = String.trim sort in
	                          if is_plain_var_like term then Some (term, sort) else None
	                      | None -> None)
	                 |> List.sort_uniq compare
	                 |> List.filter_map (fun (v, sort) ->
	                      let terms = finite_axis_terms_for_sort sort in
	                      if terms = [] then None
	                      else
	                        Some
	                          (terms
	                           |> List.map (fun term ->
	                                ([(v, term)], [],
	                                 [Printf.sprintf "%s : %s" v sort]))))
	               in
	               let membership_scope_vars =
	                 p_vars
	                 @ (binders
	                    |> List.filter_map (fun b -> match b.it with
	                         | ExpB (tid, _) -> Some (to_var_name tid.it)
	                         | _ -> None))
	               in
	               let contains_maude_var_token text v =
	                 replace_maude_var_token v ("__" ^ v ^ "__") text <> text
	               in
	               let is_ground_membership_lhs text =
	                 not
	                   (List.exists
	                      (fun v -> contains_maude_var_token text v)
	                      membership_scope_vars)
	               in
	               let _specialized_membership_statements op_line lhs rhs_conds =
	                 let apps = parametric_arg_specializations () in
	                 let finite_guard_choices = [] in
	                 let finite_guard_specs =
	                   rhs_conds
	                   |> List.filter_map (fun cond ->
	                        let cond =
	                          strip_trailing_eq_true
	                            (strip_wrapping_parens cond |> String.trim)
	                        in
	                        match split_once_re (Str.regexp "[ \t]+:[ \t]+") cond with
	                        | Some (term, sort) ->
	                            let term = strip_wrapping_parens term |> String.trim in
	                            let sort = String.trim sort in
	                            if is_plain_var_like term
	                               && finite_axis_terms_for_sort sort <> []
	                            then Some (term, sort) else None
	                        | None -> None)
	                   |> List.sort_uniq compare
	                 in
	                 let finite_guard_vars =
	                   finite_guard_specs
	                   |> List.map fst
	                   |> SSet.of_list
	                 in
	                 let finite_axis_choices =
	                   param_infos
	                   |> List.filter_map
	                        (fun (_i, v, _g, ms, _raw_opt, _typ_opt) ->
	                          let direct_terms = finite_terms_for_sort ms in
	                          let axis_terms = finite_axis_terms_for_sort ms in
	                          if (not (SSet.mem v finite_guard_vars))
	                             && direct_terms = [] && axis_terms <> [] then
	                            Some
	                              (axis_terms
	                               |> List.map (fun term ->
	                                    ([(v, term)], [],
	                                     [Printf.sprintf "%s : %s" v ms])))
	                          else None)
	                 in
	                 if apps = [] && finite_guard_choices = [] && finite_axis_choices = [] then None
	                 else
			                 let app_choices =
			                   apps
			                   |> List.map (fun (dep_v, family_sort, axes) ->
			                        let axis_term_choices =
			                          axes
	                            |> List.map (fun (axis_v, _axis_g, _axis_sort, terms) ->
	                                 List.map (fun term -> (axis_v, term)) terms)
                          in
                          cartesian axis_term_choices
                          |> List.map (fun assignments ->
                               let terms =
                                 axes
                                 |> List.map (fun (axis_v, _, _, _) ->
                                      match List.assoc_opt axis_v assignments with
                                      | Some term -> term
                                      | None -> "")
                               in
		                            let spec_sort =
		                              register_specialized_syntax_sort family_sort terms
		                            in
		                            (assignments,
                                 [Printf.sprintf "%s : %s" dep_v spec_sort],
                                 [Printf.sprintf "%s : %s" dep_v family_sort])))
		                 in
			                 let initial_choice_lists = app_choices @ finite_axis_choices in
			                 let combined =
			                   if initial_choice_lists = [] then [([], [], [])]
			                   else
			                     List.fold_left
			                       (fun acc choices ->
			                         List.concat_map
			                           (fun (acc_assigns, acc_guards, acc_removable) ->
			                             choices
			                             |> List.filter_map
			                                  (fun (assigns, guards, removable) ->
			                                    if compatible_assignments acc_assigns assigns then
			                                      Some (merge_assignments acc_assigns assigns,
			                                            acc_guards @ guards,
			                                            acc_removable @ removable)
			                                    else None))
			                           acc)
			                       [([], [], [])]
			                       initial_choice_lists
		                 in
                   let apply_assignments text assignments =
                     List.fold_left
                       (fun acc (v, term) -> replace_maude_var_token v term acc)
                       text assignments
                   in
                      let is_replaced_axis_guard _cond _assignments = false in
			                 let body =
			                   combined
			                   |> List.concat_map
			                        (fun (assignments, extra_guards, removable_guards) ->
			                          let lhs' = apply_assignments lhs assignments in
			                          let base_conds =
			                            (rhs_conds
			                             |> List.filter (fun c ->
			                                  not
			                                    (List.mem (String.trim c)
			                                       removable_guards)
			                                  && not
			                                       (is_replaced_axis_guard c
			                                          assignments))
			                             |> List.map (fun c ->
			                                  apply_assignments c assignments))
			                            @ extra_guards
			                          in
			                          let guard_choice_lists =
			                            []
			                          in
			                          let guard_combinations =
			                            if guard_choice_lists = [] then [([], [], [])]
			                            else
			                              List.fold_left
			                                (fun acc choices ->
			                                  List.concat_map
			                                    (fun (acc_assigns, acc_guards, acc_removable) ->
			                                      choices
			                                      |> List.filter_map
			                                           (fun (assigns, guards, removable) ->
			                                             if compatible_assignments
			                                                  acc_assigns assigns
			                                             then
			                                               Some
			                                                 (merge_assignments
			                                                    acc_assigns assigns,
			                                                  acc_guards @ guards,
			                                                  acc_removable @ removable)
			                                             else None))
			                                    acc)
			                                [([], [], [])]
			                                guard_choice_lists
			                          in
			                          guard_combinations
			                          |> List.filter_map
			                               (fun (guard_assignments, guard_extra_guards,
			                                     guard_removable) ->
			                                 let lhs'' =
			                                   apply_assignments lhs' guard_assignments
			                                 in
			                                 let conds'' =
			                                   base_conds
			                                   |> List.filter (fun c ->
			                                        not
			                                          (List.mem (String.trim c)
			                                             guard_removable))
			                                   |> List.map (fun c ->
			                                        apply_assignments c guard_assignments)
			                                 in
			                                 match
			                                   simplify_static_conditions_with_source_membership
			                                     (conds'' @ guard_extra_guards)
			                                 with
			                                 | None -> None
			                                 | Some simplified_conds ->
			                                     let rhs' = cond_join simplified_conds in
			                                     if rhs' = ""
			                                        && is_ground_membership_lhs lhs''
			                                     then
			                                       add_source_nullary_term
			                                         full_type_sort lhs'';
			                                     Some
			                                       (Printf.sprintf
			                                          "%s  %s ( %s ) : %s%s ."
			                                          (decl_prefix ())
			                                          (if rhs' = "" then "mb" else "cmb")
			                                          lhs'' full_type_sort
			                                          (if rhs' = "" then ""
			                                           else "\n   if " ^ rhs'))))
			                   |> String.concat "\n"
                   in
                   Some (op_line ^ body)
               in
	               let parametric_inst_arg_choices () =
                 let declared_sort_for_arg index =
                   match List.nth_opt typd_params index with
                 | Some p -> Some (source_param_sort p)
                 | None -> None
                 in
                 let compound_binder_choices () =
                   let exp_binders =
                     binders
                     |> List.filter (fun b -> match b.it with
                          | ExpB _ -> true
                          | _ -> false)
                   in
                   let candidate_parent_sorts declared_sort =
                     let conditional =
                       match Hashtbl.find_opt source_conditional_alias_edges
                               declared_sort with
                       | Some children -> SSet.elements children
                       | None -> []
                     in
                     declared_sort :: conditional
                   in
                   let compound_arity_for_declared_sort declared_sort =
                     let arities_for_cases cases =
                       cases
                       |> List.filter_map (fun c ->
                            let arity = List.length c.compound_fields in
                            if arity > 0 then Some arity else None)
                       |> List.sort_uniq compare
                     in
                     let direct_cases =
                       candidate_parent_sorts declared_sort
                       |> List.concat_map (fun parent_sort ->
                            !source_compound_cases
                            |> List.filter (fun c ->
                                 c.compound_parent_sort = parent_sort))
                     in
                     let fallback_cases =
                       if direct_cases <> [] then []
                       else
                         !source_compound_cases
                         |> List.filter (fun c ->
                              c.compound_fields
                              |> List.exists (fun (_raw, ft) ->
                                   match simple_sort_of_typ ft [] with
                                   | Some field_sort ->
                                       finite_terms_for_sort field_sort <> []
                                   | None -> false)
                              &&
                              let sample_args =
                                c.compound_fields
                                |> List.filter_map (fun (_raw, ft) ->
                                     match simple_sort_of_typ ft [] with
                                     | Some field_sort ->
                                         finite_terms_for_sort field_sort
                                         |> List.find_opt (fun _ -> true)
                                     | None -> None)
                              in
                              List.length sample_args = List.length c.compound_fields
                              &&
                              match
                                ground_compound_membership_status
                                  (format_source_ctor_call c.compound_ctor sample_args)
                                  declared_sort
                              with
                              | Some _ -> true
                              | None -> false)
                     in
                     arities_for_cases
                       (if direct_cases <> [] then direct_cases else fallback_cases)
                     |> List.sort_uniq compare
                     |> function
                        | [n] when n > 0 -> Some n
                        | _ -> None
                   in
                   let rec split_groups specs bs =
                     match specs with
                     | [] -> if bs = [] then Some [] else None
                     | n :: rest ->
                         let rec take i acc remaining =
                           if i = 0 then Some (List.rev acc, remaining)
                           else
                             match remaining with
                             | [] -> None
                             | b :: tl -> take (i - 1) (b :: acc) tl
                         in
                         (match take n [] bs with
                          | None -> None
                          | Some (group, tail) ->
                              Option.map
                                (fun groups -> group :: groups)
                                (split_groups rest tail))
                   in
                   let declared_sorts = List.map source_param_sort typd_params in
                   let arity_options =
                     List.map compound_arity_for_declared_sort declared_sorts
                   in
                   match
                     List.fold_right
                          (fun arity acc ->
                            match arity, acc with
                            | Some n, Some ns -> Some (n :: ns)
                            | _ -> None)
                          arity_options
                          (Some [])
                   with
                   | None -> []
                   | Some arities ->
                       (match split_groups arities exp_binders with
                        | None -> []
                        | Some groups ->
                            let per_group =
                              List.map2
                                (fun declared_sort group ->
                                  compound_binder_choices_for_declared_sort
                                    declared_sort group v_map)
                                declared_sorts groups
                            in
                            if per_group = [] || List.exists ((=) []) per_group then []
                            else
                              cartesian per_group
                              |> List.map (fun selected ->
                                   let terms =
                                     List.map
                                       (fun (term, _, _) -> term)
                                       selected
                                   in
                                   let assignments =
                                     List.concat_map
                                       (fun (_, a, _) -> a)
                                       selected
                                   in
                                   let guards =
                                     List.concat_map
                                       (fun (_, _, g) -> g)
                                       selected
                                   in
                                   (register_specialized_syntax_sort
                                      full_type_sort terms,
                                    assignments,
                                    guards)))
                 in
		                 let binder_choices () =
	                   let rec binder_domain_sort bt =
	                     match bt.it with
	                     | VarT (tid, []) -> Some (sort_of_type_name tid.it)
	                     | IterT (inner, Opt) -> binder_domain_sort inner
                     | _ -> simple_sort_of_typ bt param_vm
                   in
                   let exp_binders =
                     binders
                     |> List.filter_map (fun b -> match b.it with
                          | ExpB (bid, bt) -> Some (bid.it, bt)
                          | _ -> None)
                   in
                   if List.length exp_binders <> List.length typd_params then []
                   else
                     let per_binder =
                       exp_binders
                       |> List.map (fun (raw, bt) ->
                            match binder_domain_sort bt with
                            | Some domain_sort ->
                                let terms = finite_axis_terms_for_sort domain_sort in
                                let subst_var =
                                  match List.assoc_opt raw v_map with
                                  | Some mv -> mv
                                  | None -> to_var_name raw
                                in
                                List.map (fun term -> (term, [(subst_var, term)], [])) terms
                            | None -> [])
                     in
                     if per_binder = [] || List.exists ((=) []) per_binder then []
                     else
                       cartesian per_binder
		                       |> List.map (fun selected ->
		                            let terms = List.map (fun (t, _, _) -> t) selected in
                            let assignments =
                              List.concat_map (fun (_, a, _) -> a) selected
                            in
                            let guards =
                              List.concat_map (fun (_, _, g) -> g) selected
	                            in
		                            (register_specialized_syntax_sort full_type_sort terms,
		                             assignments,
		                             guards))
		                 in
		                 let binder_sort_of_raw raw =
		                   let base = strip_source_index_suffix raw in
		                   binders
		                   |> List.find_map (fun b ->
		                        match b.it with
		                        | ExpB (bid, bt)
		                            when strip_source_index_suffix bid.it = base ->
		                            let sort = source_param_sort_of_typ bt param_vm in
		                            if sort = "SpectecTerminal" then None else Some sort
		                        | _ -> None)
		                 in
			                 let choice_for_arg index arg =
	                   let singleton_declared_choices () =
	                     match declared_sort_for_arg index with
	                     | Some declared_sort ->
	                         let terms = finite_axis_terms_for_sort declared_sort in
	                         if List.length terms = 1 then
	                           terms
	                           |> List.map (fun term -> (term, [], []))
	                         else []
	                     | None -> []
	                   in
	                   match arg.it with
	                   | ExpA e ->
	                       let compound_choices =
	                         match declared_sort_for_arg index with
	                         | Some declared_sort ->
	                             compound_arg_choices_for_declared_sort_from_exp
	                               declared_sort e v_map binder_sort_of_raw
	                             |> List.map (fun (term, assignments, guards) ->
	                                  (term, assignments, guards))
	                         | None -> []
	                       in
	                       if compound_choices <> [] then compound_choices
	                       else
	                       (match e.it with
                        | VarE eid ->
                            let raw = eid.it in
                            let domain_sort =
                              sort_of_type_name (strip_source_index_suffix raw)
                            in
                            let terms = finite_axis_terms_for_sort domain_sort in
                            let subst_var =
                              match List.assoc_opt raw v_map with
                              | Some mv -> mv
                              | None -> to_var_name raw
                            in
                            if terms = [] then begin
                              record_unsupported_syntax_family full_type_sort
                                ("cannot derive finite domain for parameter " ^ raw);
                              []
                            end else
                              List.map (fun term -> (term, [(subst_var, term)], [])) terms
	                        | CaseE (mixop_arg, payload) ->
	                            let has_payload =
	                              match payload.it with
	                              | OptE None | TupE [] -> false
	                              | _ -> true
	                            in
	                            if not has_payload then
	                              (match canonical_ctor_name_arity mixop_arg 0 with
	                               | Some ctor -> [(ctor, [], [])]
	                               | None -> singleton_declared_choices ())
	                            else singleton_declared_choices ()
	                        | _ ->
	                            singleton_declared_choices ())
                   | TypA t ->
                       (match declared_sort_for_arg index with
                        | Some declared_sort ->
                            let compound_choices =
                              compound_arg_choices_for_declared_sort
                                declared_sort t v_map
                            in
	                            if compound_choices <> [] then compound_choices
	                            else
	                              let declared_terms =
	                                finite_axis_terms_for_sort declared_sort
	                              in
	                              if List.length declared_terms = 1 then
	                                declared_terms
	                                |> List.map (fun term -> (term, [], []))
	                              else
	                                (match simple_sort_of_typ t param_vm with
	                                 | Some domain_sort ->
	                                     finite_axis_terms_for_sort domain_sort
	                                     |> List.map (fun term -> (term, [], []))
	                                 | None -> [])
                        | None ->
                            (match simple_sort_of_typ t param_vm with
                             | Some domain_sort ->
                                 finite_axis_terms_for_sort domain_sort
                                 |> List.map (fun term -> (term, [], []))
                             | None -> []))
                   | DefA _ | GramA _ -> []
                 in
                 if args = [] then
                   let direct = binder_choices () in
                   if direct <> [] then direct else compound_binder_choices ()
                 else
                   let per_arg = List.mapi choice_for_arg args in
                   if List.exists ((=) []) per_arg then
                     let direct = binder_choices () in
                     if direct <> [] then direct else compound_binder_choices ()
                   else
                     cartesian per_arg
                     |> List.map (fun selected ->
                          let terms = List.map (fun (t, _, _) -> t) selected in
                          let assignments =
                            List.concat_map (fun (_, a, _) -> a) selected
                          in
                          let guards =
                            List.concat_map (fun (_, _, g) -> g) selected
                          in
                          (register_specialized_syntax_sort full_type_sort terms,
                           assignments,
                           guards))
               in
	               let parametric_specialized_memberships op_line lhs rhs_conds =
	                 let choices = parametric_inst_arg_choices () in
	                 if choices = [] then None
                 else
                   let apply_assignments text assignments =
                     List.fold_left
                       (fun acc (v, term) -> replace_maude_var_token v term acc)
                       text assignments
                   in
	                   let body =
	                     choices
	                     |> List.concat_map (fun (target_sort, assignments, extra_guards) ->
	                          let lhs' = apply_assignments lhs assignments in
	                          let conds' =
	                            (rhs_conds
	                             |> List.map (fun c -> apply_assignments c assignments))
	                            @ extra_guards
	                          in
	                          let guard_choice_lists =
	                            finite_guard_choice_lists conds'
	                          in
	                          let guard_combinations =
	                            if guard_choice_lists = [] then [([], [], [])]
	                            else
	                              List.fold_left
	                                (fun acc choices ->
	                                  List.concat_map
	                                    (fun (acc_assigns, acc_guards, acc_removable) ->
	                                      choices
	                                      |> List.filter_map
	                                           (fun (assigns, guards, removable) ->
	                                             if compatible_assignments
	                                                  acc_assigns assigns
	                                             then
	                                               Some
	                                                 (merge_assignments
	                                                    acc_assigns assigns,
	                                                  acc_guards @ guards,
	                                                  acc_removable @ removable)
	                                             else None))
	                                    acc)
	                                [([], [], [])]
	                                guard_choice_lists
	                          in
	                          guard_combinations
	                          |> List.filter_map
	                               (fun (guard_assignments, guard_extra_guards,
	                                     removable_guards) ->
	                                 let lhs'' =
	                                   apply_assignments lhs' guard_assignments
	                                 in
	                                 let conds'' =
	                                   conds'
	                                   |> List.filter (fun c ->
	                                        not
	                                          (List.mem (String.trim c)
	                                             removable_guards))
	                                   |> List.map (fun c ->
	                                        apply_assignments c guard_assignments)
	                                 in
	                                 match
	                                   simplify_static_conditions_with_source_membership
	                                     (conds'' @ guard_extra_guards)
	                                 with
	                                 | None -> None
	                                 | Some simplified_conds ->
	                                     let rhs' = cond_join simplified_conds in
	                                     if rhs' = ""
	                                        && is_ground_membership_lhs lhs''
	                                     then
	                                       add_source_nullary_term
	                                         target_sort lhs'';
	                                     Some
	                                       (Printf.sprintf
	                                          "%s  %s ( %s ) : %s%s ."
	                                          (decl_prefix ())
	                                          (if rhs' = "" then "mb" else "cmb")
	                                          lhs'' target_sort
	                                          (if rhs' = "" then ""
	                                           else "\n   if " ^ rhs'))))
	                     |> String.concat "\n"
                   in
                   Some (op_line ^ body)
               in
               let parametric_membership_sort =
                 if is_parametric then
                   register_symbolic_syntax_type_sort full_type_sort type_term
                 else full_type_sort
               in
	               let rhs_conds =
	                 let typd_seed_vars =
	                   p_vars @
	                   List.filter_map (fun b -> match b.it with
                     | ExpB (tid, _) -> Some (to_var_name tid.it)
                     | _ -> None) binders
                 in
                 let param_guards =
                   params
                   |> List.map (fun (_, g, _) -> g)
                   |> List.filter (fun g -> g <> "true")
                 in
	                 normalize_typd_condition_assignments typd_seed_vars
	                   (prem_match_strs @ prem_bool_strs @ binder_conds
                      @ param_guards @ type_term_arg_guards)
	               in
               let rhs = cond_join rhs_conds in
               let generic_membership_statement op_line lhs rhs =
                 Printf.sprintf "%s%s  %s ( %s ) : %s%s ."
                   op_line (decl_prefix ()) (if rhs = "" then "mb" else "cmb")
                   lhs parametric_membership_sort
                   (if rhs = "" then "" else "\n   if " ^ rhs)
               in
               ignore parametric_specialized_memberships;
                 let sections = mixop_sections mixop_val in
               let lhs0 =
                 match format_source_semicolon_pair p_vars with
                 | Some text when mixop_is_source_semicolon_pair mixop_val (List.length p_vars) ->
                     text
                 | _ ->
	                     (match canonical_ctor_name_arity ~case_typ mixop_val (List.length p_vars) with
	                      | Some ctor -> format_source_ctor_call ctor p_vars
                      | None -> interleave_lhs sections p_vars)
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
                   let opt_param_indices =
                     if prems <> [] then [] else find_opt_param_indices case_typ
                   in
                   let typed_index_block = ""
                   in
	                 let main =
		                   if cons_name = "" then
                         if is_plain_var_like lhs then
                           (match
                              if typ_is_raw_numeric_payload case_typ then
                                source_literal_membership_for_numeric_condition
                                  full_type_sort type_term lhs rhs
                              else None
                            with
                            | Some note -> note ^ "\n"
                            | None ->
                                if is_parametric then
                                  generic_membership_statement "" lhs rhs
                                else
                                  let finite_lits =
                                    finite_numeric_membership_literals lhs rhs
                                  in
                                  if finite_lits <> [] then
                                    finite_lits
                                    |> List.map (fun lit ->
                                         Printf.sprintf "  mb ( %s ) : %s ."
                                           lit full_type_sort)
                                    |> String.concat "\n"
                                    |> fun s -> s ^ "\n"
                                  else if rhs = "" then
                                    let () =
                                      List.iter
                                        (fun (v, _, _) ->
                                          Hashtbl.remove declared_vars v)
                                        params;
                                      List.iter
                                        (fun b -> match b.it with
                                          | ExpB (tid, _) ->
                                              Hashtbl.remove declared_vars
                                                (to_var_name tid.it)
                                          | _ -> ())
                                        binders
                                    in
                                    ""
                                  else
                                    let finite_terms =
                                      if prems = [] then []
                                      else finite_axis_terms_for_sort full_type_sort
                                    in
                                    if finite_terms <> [] then
                                      finite_terms
                                      |> List.map (fun term ->
                                           Printf.sprintf "  mb ( %s ) : %s ."
                                             term full_type_sort)
                                      |> String.concat "\n"
                                      |> fun s -> s ^ "\n"
                                    else
                                      Printf.sprintf
                                        "\n%s  cmb ( %s ) : %s\n   if %s ."
                                        (decl_prefix ()) lhs full_type_sort rhs)
                         else if is_parametric then
                           generic_membership_statement "" lhs rhs
		                       else
		                         Printf.sprintf "\n%s  %s ( %s ) : %s%s ."
	                         (decl_prefix ()) (if rhs = "" then "mb" else "cmb") lhs full_type_sort
	                         (if rhs = "" then "" else "\n   if " ^ rhs)
	                   else
                           let canonical_name = canonical_ctor_name_arity ~case_typ mixop_val (List.length p_vars) in
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
	                           register_ctor_arg_sorts ctor
	                             (List.map broad_ctor_arg_sort op_sorts);
	                           register_ctor_arg_membership_sorts ctor op_sorts;
	                           register_ctor_arg_literal_type_dependencies ctor
	                             (parametric_literal_type_dependencies ());
	                           register_ctor_result_sort ctor full_type_sort
	                       | None -> ()
                     in
	                     let arg_sorts =
                       param_sorts
                       |> List.map broad_ctor_arg_sort
                       |> String.concat " "
                     in
                     let op_line =
                       match canonical_name with
                       | Some _ -> ""
                       | None ->
                           Printf.sprintf "  op %s : %s -> SpectecTerminal [ctor] .\n" op_sig arg_sorts
	                     in
	                     if is_parametric then
                         generic_membership_statement op_line lhs rhs
	                     else
	                       Printf.sprintf "%s%s  %s ( %s ) : %s%s ."
	                         op_line (decl_prefix ()) (if rhs = "" then "mb" else "cmb") lhs full_type_sort
	                         (if rhs = "" then "" else "\n   if " ^ rhs)
                 in
                 let opts =
                   if prems <> [] then []
                   else
                     List.map (fun opt_idx ->
                       let empty_arg =
                         optional_empty_term_for_param_index case_typ opt_idx param_vm
                       in
                       let eps_args =
                         List.mapi (fun i v -> if i = opt_idx then empty_arg else v) p_vars
                       in
                       let lhs_eps =
                         match format_source_semicolon_pair eps_args with
                         | Some text when mixop_is_source_semicolon_pair mixop_val (List.length eps_args) ->
                             text
                         | _ ->
	                             (match canonical_ctor_name_arity ~case_typ mixop_val (List.length eps_args) with
                              | Some ctor -> format_source_ctor_call ctor eps_args
                              | None -> interleave_lhs sections eps_args) in
                       let lhs_eps = safe_term_text lhs_eps in
                       let r = cond_join
                         (binder_conds @ List.filteri (fun i _ -> i <> opt_idx)
                           (List.map (fun (_, g, _) -> g) params)) in
                       if is_parametric then
                         unsupported_parametric_membership
                           ("optional constructor membership for " ^ type_term)
	                       else
                         let membership =
	                         Printf.sprintf "\n  %s ( %s ) : %s%s ."
	                           (if r = "" then "mb" else "cmb") lhs_eps full_type_sort
	                           (if r = "" then "" else "\n   if " ^ r)
                         in
                         let typed_index_opt_block = ""
                         in
                         membership ^ typed_index_opt_block
	                     ) opt_param_indices
                 in
                 Some (main ^ typed_index_block ^ String.concat "" opts)
             ) cases |> String.concat "\n"
	         | AliasT typ ->
             let concrete_literal_alias_sort typ =
               match typ.it with
               | VarT (tid, args) when args <> [] ->
                   let family_sort = sort_of_type_name tid.it in
                   if is_literal_family_root family_sort then
                     let arg_texts =
                       List.map (fun a -> translate_arg a v_map |> fun t -> t.text) args
                     in
                     (match arg_texts with
                      | [arg] ->
                          let numeric_tail =
                            strip_wrapping_parens arg |> String.trim
                          in
                          if numeric_tail <> ""
                             && String.for_all
                                  (fun c -> c >= '0' && c <= '9')
                                  numeric_tail
                          then
                            Some (concrete_literal_family_sort family_sort numeric_tail)
                          else None
                      | _ -> None)
                   else None
               | _ -> None
             in
			             let register_literal_alias child parent =
			               register_literal_wrapper_for_sort child;
			               register_literal_family_alias_subsorts child;
                     record_source_alias_subsort child parent;
				               if child <> parent then begin
	                   specialized_syntax_sort_names :=
	                     SSet.add child !specialized_syntax_sort_names;
	                 specialized_syntax_sort_decls :=
	                   SSet.add (Printf.sprintf "  sort %s ." child)
                     (SSet.add
                        (Printf.sprintf "  subsort %s < SpectecTerminal ." child)
                        (SSet.add
                           (Printf.sprintf "  subsort %s < %s ." child parent)
                           !specialized_syntax_sort_decls));
		                   add_generated_source_subsort child parent
		               end
		             in
		             let apply_alias_assignments text assignments =
		               List.fold_left
		                 (fun acc (v, term) -> replace_maude_var_token v term acc)
		                 text assignments
		             in
		             let strip_source_index_suffix_alias raw =
		               let re = Str.regexp "^\\(.+\\)_[0-9]+$" in
		               if Str.string_match re raw 0 then
		                 match str_matched_group_opt 1 raw with Some s -> s | None -> raw
		               else raw
		             in
			             let finite_source_sort_alias sort =
			               if finite_axis_terms_for_sort sort <> [] then Some sort else None
			             in
		             let source_sort_from_text_alias text =
		               let text = strip_wrapping_parens text |> String.trim in
		               let ident = "[A-Za-z][A-Za-z0-9_/-]*" in
		               let annotated =
		                 Str.regexp
		                   (".*:[ \t]*\\(" ^ ident ^ "\\)[ \t]*<:.*")
		               in
		               let plain = Str.regexp ("^\\(" ^ ident ^ "\\)$") in
		               let candidates =
		                 if Str.string_match annotated text 0 then
		                   match str_matched_group_opt 1 text with
		                   | Some raw -> [raw; String.lowercase_ascii raw]
		                   | None -> []
		                 else if Str.string_match plain text 0 then
		                   match str_matched_group_opt 1 text with
		                   | Some raw -> [raw; String.lowercase_ascii raw]
		                   | None -> []
		                 else []
		               in
		               candidates
		               |> List.sort_uniq String.compare
		               |> List.find_map (fun raw ->
		                    finite_source_sort_alias (sort_of_type_name raw))
		             in
			             let source_sort_of_binder_typ_alias bt =
			               match simple_sort_of_typ bt v_map with
			               | Some sort when finite_axis_terms_for_sort sort <> [] -> Some sort
		               | _ ->
		                   (match
		                      finite_source_sort_alias
		                        (source_param_sort_of_typ bt v_map)
		                    with
		                    | Some _ as hit -> hit
		                    | None ->
		                        source_sort_from_text_alias
		                          (Il.Print.string_of_typ bt))
		             in
		             let binder_sort_for_raw_alias raw =
		               let base = strip_source_index_suffix_alias raw in
		               binders
		               |> List.find_map (fun b ->
		                    match b.it with
		                    | ExpB (bid, bt)
		                        when strip_source_index_suffix_alias bid.it = base ->
		                        source_sort_of_binder_typ_alias bt
		                    | _ -> None)
		             in
			             let source_sort_of_type_arg_alias t =
			               match simple_sort_of_typ t v_map with
			               | Some sort when finite_axis_terms_for_sort sort <> [] -> Some sort
		               | _ ->
		                   (match
		                      source_sort_from_text_alias
		                        (Il.Print.string_of_typ t)
		                    with
		                    | Some _ as hit -> hit
		                    | None ->
		                        let text =
		                          translate_typ_texpr t v_map
		                          |> fun tx ->
		                          strip_wrapping_parens tx.text |> String.trim
		                        in
		                        source_sort_from_text_alias text)
		             in
		             let source_sort_of_exp_arg_raw_alias raw =
		               match binder_sort_for_raw_alias raw with
		               | Some _ as hit -> hit
		               | None ->
		                   let base = strip_source_index_suffix_alias raw in
		                   let candidates =
		                     [base; String.lowercase_ascii base]
		                     |> List.sort_uniq String.compare
		                   in
		                   candidates
		                   |> List.find_map (fun candidate ->
		                        finite_source_sort_alias
		                          (sort_of_type_name candidate))
		             in
		             let parametric_alias_choices () =
		               let cartesian lists =
		                 List.fold_right
		                   (fun xs acc ->
		                     List.concat_map
		                       (fun x -> List.map (fun ys -> x :: ys) acc)
		                       xs)
		                   lists
		                   [[]]
		               in
		               let declared_sort_for_arg index =
		                 match List.nth_opt typd_params index with
		                 | Some p -> Some (source_param_sort p)
		                 | None -> None
		               in
		               let choice_for_arg index arg =
		                 match arg.it with
		                 | ExpA e ->
		                     (match e.it with
		                      | VarE eid ->
		                          let raw = eid.it in
		                          let domain_sort =
		                            match source_sort_of_exp_arg_raw_alias raw with
		                            | Some actual_sort -> actual_sort
		                            | None ->
		                              match declared_sort_for_arg index with
		                              | Some sort -> sort
		                              | None ->
		                                  sort_of_type_name
		                                    (strip_source_index_suffix_alias raw)
		                          in
		                          let subst_var =
		                            match List.assoc_opt raw v_map with
		                            | Some mv -> mv
		                            | None -> to_var_name raw
		                          in
		                          finite_axis_terms_for_sort domain_sort
		                          |> List.map (fun term -> (term, [(subst_var, term)]))
		                      | CaseE (mixop_arg, payload) ->
		                          let has_payload =
		                            match payload.it with
		                            | OptE None | TupE [] -> false
		                            | _ -> true
		                          in
		                          if has_payload then []
		                          else
		                            (match canonical_ctor_name_arity mixop_arg 0 with
		                             | Some ctor -> [(ctor, [])]
		                             | None -> [])
		                      | _ ->
		                          let t = translate_exp TermCtx e v_map in
		                          (match eval_ground_int_expr t.text with
		                           | Some _ -> [(t.text, [])]
		                           | None -> []))
		                 | TypA t ->
		                     let domain_sort =
		                       match source_sort_of_type_arg_alias t with
		                       | Some sort -> Some sort
		                       | None -> declared_sort_for_arg index
		                     in
		                     (match domain_sort with
		                      | Some sort ->
		                          finite_axis_terms_for_sort sort
		                          |> List.map (fun term -> (term, []))
		                      | None -> [])
		                 | DefA _ | GramA _ -> []
		               in
		               let choices_from_args () =
		                 if args = [] then []
		                 else
		                   let per_arg = List.mapi choice_for_arg args in
		                   if per_arg = [] || List.exists ((=) []) per_arg then []
		                   else
		                     cartesian per_arg
		                     |> List.map (fun selected ->
		                          let terms = List.map fst selected in
		                          let assignments = List.concat_map snd selected in
		                          (register_specialized_syntax_sort full_type_sort terms,
		                           terms,
		                           assignments))
		               in
		               let choices_from_binders () =
		                 let exp_binders =
		                   binders
		                   |> List.filter_map (fun b -> match b.it with
		                        | ExpB (bid, bt) -> Some (bid.it, bt)
		                        | _ -> None)
		                 in
		                 if List.length exp_binders <> List.length typd_params then []
		                 else
		                   let per_binder =
		                     exp_binders
		                     |> List.mapi (fun i (raw, bt) ->
		                          let domain_sort =
		                            match source_sort_of_binder_typ_alias bt with
		                            | Some _ as hit -> hit
		                            | None ->
		                                (match declared_sort_for_arg i with
		                                 | Some sort
		                                     when finite_axis_terms_for_sort sort <> [] ->
		                                     Some sort
		                                 | _ -> None)
		                          in
		                          match domain_sort with
		                          | None -> []
		                          | Some sort ->
		                              let subst_var =
		                                match List.assoc_opt raw v_map with
		                                | Some mv -> mv
		                                | None -> to_var_name raw
		                              in
		                              finite_axis_terms_for_sort sort
		                              |> List.map (fun term -> (term, [(subst_var, term)])))
		                   in
		                   if per_binder = [] || List.exists ((=) []) per_binder then []
		                   else
		                     cartesian per_binder
		                     |> List.map (fun selected ->
		                          let terms = List.map fst selected in
		                          let assignments = List.concat_map snd selected in
		                          (register_specialized_syntax_sort full_type_sort terms,
		                           terms,
		                           assignments))
		               in
		               match choices_from_args () with
		               | [] -> choices_from_binders ()
		               | choices -> choices
		             in
		             let parametric_alias_rhs_sort selected_terms assignments rhs_typ =
		               let selected_term_for_arg index arg =
		                 match arg.it with
		                 | ExpA {it = VarE eid; _} ->
		                     let subst_var =
		                       match List.assoc_opt eid.it v_map with
		                       | Some mv -> mv
		                       | None -> to_var_name eid.it
		                     in
		                     List.assoc_opt subst_var assignments
		                 | TypA t ->
		                     let domain_sort_opt = source_sort_of_type_arg_alias t in
		                     (match domain_sort_opt with
		                      | None -> List.nth_opt selected_terms index
		                      | Some domain_sort ->
		                          let matching =
		                            typd_params
		                            |> List.mapi (fun i p -> (i, source_param_sort p))
		                            |> List.filter (fun (_i, sort) -> sort = domain_sort)
		                          in
		                          (match matching with
		                           | [(i, _)] -> List.nth_opt selected_terms i
		                           | _ -> List.nth_opt selected_terms index))
		                 | _ -> None
		               in
		               match rhs_typ.it with
		               | VarT (tid, []) -> Some (sort_of_type_name tid.it)
		               | VarT (tid, rhs_args) when rhs_args <> [] ->
		                   let family_sort = sort_of_type_name tid.it in
		                   let rhs_arg_terms =
		                     rhs_args
		                     |> List.mapi (fun i arg ->
		                          match selected_term_for_arg i arg with
		                          | Some term -> term
		                          | None ->
		                              translate_arg arg v_map
		                              |> fun t ->
		                              apply_alias_assignments t.text assignments)
		                   in
		                   (match family_sort, rhs_arg_terms with
		                    | _, [arg_text] when is_literal_family_root family_sort ->
		                        (match eval_ground_int_expr arg_text with
		                         | Some n ->
		                             Some
		                               (concrete_literal_family_sort family_sort
		                                  (string_of_int n))
		                         | None -> None)
		                    | _, _ when SSet.mem family_sort !literal_family_parent_sorts ->
		                        Some (register_specialized_syntax_sort family_sort rhs_arg_terms)
		                    | _, _ ->
		                        Some (register_specialized_syntax_sort family_sort rhs_arg_terms))
		               | _ ->
		                   (match simple_sort_of_typ rhs_typ v_map with
		                    | Some sort -> Some sort
		                    | None -> None)
		             in
		             let parametric_alias_membership () =
		               if not is_parametric then None
		               else
		                 match parametric_alias_choices () with
		                 | [] -> None
		                 | choices ->
		                     let statements =
		                       choices
		                       |> List.filter_map
		                            (fun (target_sort, selected_terms, assignments) ->
		                              match
		                                parametric_alias_rhs_sort
		                                  selected_terms assignments typ
		                              with
		                              | None ->
		                                  record_unsupported_syntax_family name
		                                    ("cannot derive parametric alias target for "
		                                     ^ type_term);
		                                  None
		                              | Some child_sort ->
		                                  register_literal_alias child_sort target_sort;
		                                  None)
		                     in
		                     Some (String.concat "\n" statements)
		             in
		             let complex_alias_membership () =
	               let cartesian lists =
	                 List.fold_right
	                   (fun xs acc ->
	                     List.concat_map
	                       (fun x -> List.map (fun ys -> x :: ys) acc)
	                       xs)
	                   lists
	                   [[]]
	               in
	               let counters = ref [] in
	               let fresh_var_for_typ t =
	                 let base =
	                   match simple_sort_of_typ t v_map with
	                   | Some s -> String.uppercase_ascii (sanitize s)
	                   | None -> "ALIAS"
	                 in
	                 let n =
	                   (try List.assoc base !counters with Not_found -> 0) + 1
	                 in
	                 counters := (base, n) :: List.remove_assoc base !counters;
	                 base ^ string_of_int n
	               in
	               let rec alts t =
	                 match t.it with
	                 | TupT fields ->
	                     let per_field =
	                       fields |> List.map (fun (_fe, ft) -> alts ft)
	                     in
	                     if per_field = [] || List.exists ((=) []) per_field then []
	                     else cartesian per_field |> List.map List.concat
	                 | IterT (inner, Opt) ->
	                     [] :: alts inner
	                 | IterT (_, (List | List1 | ListN _))
	                 | VarT _ ->
	                     let v = fresh_var_for_typ t in
	                     [[(v, t)]]
	                 | _ -> []
	               in
	               let is_complex =
	                 match typ.it with
	                 | TupT _ | IterT (_, Opt) -> true
	                 | _ -> false
	               in
	               if not is_complex then None
	               else
	                 match alts typ with
	                 | [] -> None
	                 | alternatives ->
	                     alternatives
	                     |> List.map (fun comps ->
	                          let decls =
	                            comps
	                            |> List.map (fun (v, t) ->
	                                 declare_var v
	                                   (source_carrier_sort_of_typ t v_map))
	                            |> String.concat ""
	                          in
	                          let lhs =
	                            match List.map fst comps with
	                            | [] -> optional_empty_term_for_typ typ v_map
	                            | vars -> String.concat " " vars
	                          in
	                          let cond =
	                            comps
	                            |> List.map (fun (v, t) -> type_guard v t v_map)
	                            |> List.filter (fun g -> g <> "true")
	                            |> fun guards ->
	                              if binder_conds = [] then cond_join guards
	                              else cond_join (binder_conds @ guards)
	                          in
	                          Printf.sprintf "%s  %s ( %s ) : %s%s ."
	                            decls (if cond = "" then "mb" else "cmb")
	                            lhs full_type_sort
	                            (if cond = "" then "" else "\n   if " ^ cond))
	                     |> String.concat "\n"
	                     |> fun s -> Some s
	             in
	             let var = match typ.it with IterT (_, (List | List1)) -> "TS" | _ -> "T" in
	             let lhs = if SSet.mem name base_types then "T" else var in
	             let alias_guard_opt =
	               match typ.it with
	               | NumT `NatT -> Some (Printf.sprintf "%s : Nat" lhs)
	               | NumT `IntT -> Some (Printf.sprintf "%s : Int" lhs)
	               | VarT (tid, _) ->
	                   (match meta_numeric_carrier_sort (sort_of_type_name tid.it) with
	                    | Some ("Nat" | "Int" as carrier) ->
	                        Some (Printf.sprintf "%s : %s" lhs carrier)
	                    | _ -> Some (type_guard lhs typ v_map))
	               | _ -> Some (type_guard lhs typ v_map)
	             in
             let alias_param_typecheck_guards =
               let type_atom_for_source_sort source_sort raw =
                 let has_lowercase s =
                   String.exists (fun c -> c >= 'a' && c <= 'z') s
                 in
                 match Hashtbl.find_opt source_sort_type_atoms source_sort with
                 | Some atom -> Some atom
                 | None ->
                     if SSet.mem source_sort !source_membership_sorts then
                       Some (spectec_type_constructor_head raw 0)
                     else if String.length raw > 1 && has_lowercase raw then
                       Some (spectec_type_constructor_head raw 0)
                     else None
               in
	               let guard_for_var_and_raw var raw =
	                 let source_sort = sort_of_type_name raw in
	                 if is_meta_numeric_alias_sort source_sort then None
	                 else match type_atom_for_source_sort source_sort raw with
	                 | Some atom
	                     when is_plain_var_like var
                          && var <> atom
                          && not (SSet.mem (jhs_type_term_key atom) !raw_payload_type_terms) ->
                     Some
                       (Printf.sprintf "typecheck(%s, %s) = true" var atom)
                 | _ -> None
               in
               let guards_from_args =
                 args
                 |> List.filter_map (fun arg ->
                    match arg.it with
                    | TypA {it = VarT (tid, []); _} ->
                        let arg_text =
                          translate_arg arg v_map
                          |> fun tx -> strip_wrapping_parens tx.text |> String.trim
                        in
                        guard_for_var_and_raw arg_text tid.it
                    | _ -> None)
               in
	               let guards_from_type_term =
	                 vars_of_texpr_local type_term_t
		                 |> List.filter (fun v -> v <> spectec_term_var)
	                 |> List.filter_map (fun v ->
	                      guard_for_var_and_raw v (raw_source_name_of_type_var v))
               in
               guards_from_args @ guards_from_type_term
               |> List.sort_uniq String.compare
             in
             let alias_typecheck_eq =
               let rhs_t =
                 match typ.it with
                 | NumT `NatT -> { text = spectec_type_term_of_name "nat" []; vars = [] }
                 | NumT `IntT -> { text = spectec_type_term_of_name "int" []; vars = [] }
                 | _ -> translate_typ_texpr typ v_map
               in
               let rhs = strip_wrapping_parens rhs_t.text |> String.trim in
               if rhs = "" || rhs = "SpectecTerminal" then ""
               else
                 let () = record_raw_payload_type_alias type_term rhs in
	                 let vars =
	                   uniq_vars_local (type_term_t.vars @ rhs_t.vars)
		                   |> List.filter (fun v -> v <> spectec_term_var)
	                 in
		                 let decls =
		                   vars
		                   |> List.map (fun v -> (v, decl_sort_of_type_term_var v))
		                   |> declare_vars_by_sort
		                 in
                 let alias_eq_conds =
                   (binder_conds @ alias_param_typecheck_guards)
                   |> List.filter (fun cond ->
                        let cond =
                          strip_trailing_eq_true
                            (strip_wrapping_parens cond |> String.trim)
                        in
                        match split_once_re (Str.regexp "[ \t]+:[ \t]+") cond with
                        | Some (term, sort) ->
                            let term =
                              strip_wrapping_parens term |> String.trim
                            in
                            let sort = String.trim sort in
                            not (is_plain_var_like term && sort <> "")
                        | None -> true)
                 in
                 let cond = cond_join alias_eq_conds in
                 Printf.sprintf "%s  %s typecheck(%s, %s) = typecheck(%s, %s)%s ."
	                   decls
	                   (if cond = "" then "eq" else "ceq")
	                   spectec_term_var type_term spectec_term_var rhs
	                   (if cond = "" then "" else "\n   if " ^ cond)
             in
             let alias_membership =
               ignore alias_guard_opt;
               ignore complex_alias_membership;
               ignore parametric_alias_membership;
               (match concrete_literal_alias_sort typ, typ_ref_sort typ with
	                | Some child, _ when not is_parametric ->
	                    register_literal_alias child full_type_sort
	                | _, Some child when not is_parametric ->
                      record_source_alias_subsort child full_type_sort;
	                    add_generated_source_subsort child full_type_sort
                | _ -> ());
               ""
             in
             String.concat "\n"
               (List.filter (fun s -> String.trim s <> "")
                  [alias_typecheck_eq; alias_membership])
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
               let ms = "SpectecTerminals" in
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
                 unsupported_parametric_membership
                   ("record membership for " ^ type_term)
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
                     let record_call vars = format_source_ctor_call ri.rec_ctor vars in
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
	                     let record_ctor_membership empty_vns =
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
	                       Printf.sprintf "  %s ( %s ) : %s%s ."
	                         (if rhs_conds = "" then "mb" else "cmb")
	                         (record_call lhs_vars) full_type_sort
	                         (if rhs_conds = "" then "" else "\n   if " ^ rhs_conds)
	                     in
	                     let record_ctor_memberships =
	                       record_ctor_membership [] ::
	                       List.map record_ctor_membership (nonempty_subsets optional_vns)
	                       |> String.concat "\n"
	                     in
	                     let projections =
	                       List.map2 (fun f v ->
	                         Printf.sprintf "  eq value('%s, %s) = %s ."
	                           f (record_call vars) v)
	                         field_names vars
	                       |> String.concat "\n"
	                     in
	                     let empty_terms_opt = source_record_empty_terms ri in
	                     let empty_const_membership =
	                       match empty_terms_opt with
	                       | None -> ""
	                       | Some empty_terms ->
	                           let cname = source_record_empty_const_name ri.rec_source_name in
	                           let replacements =
	                             List.map2
	                               (fun (_, vn, _, _) term -> (vn, term))
	                               info empty_terms
	                           in
	                           let replace_all text =
	                             List.fold_left
	                               (fun acc (v, term) ->
	                                 replace_maude_var_token v term acc)
	                               text replacements
	                           in
	                           let rhs_conds =
	                             field_guards
	                             |> List.map snd
	                             |> List.map replace_all
	                             |> fun guards ->
	                                  cond_join (List.map replace_all binder_conds @ guards)
	                           in
	                           Printf.sprintf "  %s ( %s ) : %s%s .\n"
	                             (if rhs_conds = "" then "mb" else "cmb")
	                             cname full_type_sort
	                             (if rhs_conds = "" then "" else "\n   if " ^ rhs_conds)
	                     in
	                     let empty_record_block =
	                       match empty_terms_opt with
	                       | None -> ""
	                       | Some empty_terms ->
	                           let cname = source_record_empty_const_name ri.rec_source_name in
	                           let empty_record = record_call empty_terms in
                           let empty_projections =
                             List.map2 (fun f v ->
                               Printf.sprintf "  eq value('%s, %s) = %s ."
                                 f cname v)
                               field_names empty_terms
                             |> String.concat "\n"
                           in
                           let empty_merge_var =
                             Printf.sprintf "MERGE-EMPTY-%s"
                               (String.uppercase_ascii (sanitize ri.rec_source_name))
                           in
                           let empty_update_eqs =
                             field_names
                             |> List.mapi (fun i f ->
                                 let uv =
                                   Printf.sprintf "U-EMPTY-%s-%s-%d" record_var_prefix f i
                                 in
                                 let updated =
                                   List.mapi
                                     (fun j v -> if i = j then uv else v)
                                     empty_terms
                                 in
                                 Printf.sprintf
                                   "%s  eq %s [. '%s <- %s] = %s ."
                                   (declare_var uv "SpectecTerminals")
                                   cname f uv (record_call updated))
                             |> String.concat "\n"
                           in
                           Printf.sprintf
                             "  op %s : -> SpectecTerminal [ctor] .\n  eq %s = %s .\n%s\n%s  eq merge ( %s , %s ) = %s .\n  eq merge ( %s , %s ) = %s .\n%s\n"
                             cname empty_record cname empty_projections
                             (declare_var empty_merge_var full_type_sort)
                             cname empty_merge_var empty_merge_var
                             empty_merge_var cname empty_merge_var
                             empty_update_eqs
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
		                     ^ Printf.sprintf "  op %s : %s -> SpectecTerminal [ctor] .\n"
		                         ri.rec_ctor arg_sorts
	                     ^ record_ctor_memberships ^ "\n"
	                     ^ empty_const_membership
		                     ^ (if canonicalizations = [] then ""
		                        else String.concat "\n" canonicalizations ^ "\n")
		                     ^ projections ^ "\n" ^ empty_record_block ^ update_eqs ^ "\n" ^ merge_eq
	             in
             bd ^ decls ^ source_record_block ^ "\n" ^ String.concat "\n" memberships)
  ) insts in
  sort_decl ^ source_category_subsort_decl ^ op_decl ^ String.concat "\n" res

(* --- Binding analysis (shared by DecD / RelD) ---------------------------- *)

let extract_vars_from_maude s =
  let re = Str.regexp "[A-Z][A-Z0-9-]*" in
  let excluded = SSet.of_list
    ["SpectecTerminal"; "SpectecTerminals"; "Bool"; "Nat"; "Int";
     "EMPTY"; "REC"; "FUNC"; "SUB"; "STRUCT"; "ARRAY"; "FIELD";
     (* Maude DSL-RECORD atom labels — these appear in value('FOO, ...) and must not
        be treated as free variables when deciding := vs == in condition scheduling *)
     "TYPES"; "TAGS"; "GLOBALS"; "LOCALS"; "MEMS"; "TABLES"; "FUNCS"; "DATAS"; "ELEMS";
     "STRUCTS"; "ARRAYS"; "EXNS"; "EXPORTS"; "LABELS"; "RETURN"; "MODULE"; "OFFSET";
     "ALIGN"; "BYTES"; "CODE"; "REFS"; "RECS"; "FIELDS"; "TAG"; "TYPE"; "VALUE"; "NAME";
     "ADDR"; "LABEL"; "LABEL"; "LABEL"; "IMPORT"] in
  (* Also exclude generated/source constructor ops, not variables. *)
  let is_ctor_name t =
    is_source_ctor_var_token t
    || is_source_ctor_name t
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
  let normalized_raw = source_var_component raw_v in
  Printf.sprintf "%s%d-%s" prefix eq_idx
    normalized_raw

let add_vm_alias key value acc =
  if key = "" then acc
  else if List.exists (fun (k, _) -> k = key) acc
  then acc
  else (key, value) :: acc

(** Create [var_map] from binders, filtering out Bool-typed bindings. *)
let binder_to_var_map prefix eq_idx binders =
  let sequence_vars = ref SSet.empty in
  let sequence_inner_typ (t : typ) =
    match t.it with
    | IterT (inner, (List | List1 | ListN _)) -> Some inner
    | IterT (inner, Opt) -> Some inner
    | _ -> None
  in
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
          (match sequence_inner_typ t with
           | Some _ -> sequence_vars := SSet.add mapped !sequence_vars
           | None -> ());
          (match simple_sort_of_typ t [] with
           | Some sort ->
               Hashtbl.replace source_var_sorts mapped
                 (semantic_sort_of_source_sort sort)
           | None -> ());
          (match sequence_inner_typ t with
           | Some inner ->
               (match simple_sort_of_typ inner [] with
                | Some elem_sort ->
                    Hashtbl.replace source_var_sorts mapped "SpectecTerminals";
                    Hashtbl.replace source_var_seq_elem_sorts mapped elem_sort;
                    (match t.it with
                     | IterT (_, Opt) ->
                         Hashtbl.replace source_var_optional_elem_sorts mapped elem_sort
                     | _ -> ())
                | None -> ())
           | None -> ());
          debug_iter "[BINDER-MAP] eq=%d raw=%s base=%s kind=%s mapped=%s sort=%s"
            eq_idx raw base iter_kind mapped
            (match simple_sort_of_typ t [] with Some s -> s | None -> "?");
          let acc = add_vm_alias raw mapped acc in
          let acc = add_vm_alias base mapped acc in
          let acc = add_vm_alias named_base mapped acc in
          let acc =
            match t.it with
            | IterT (_, List) ->
                add_vm_alias (base ^ "*") mapped acc
            | IterT (_, List1) ->
                add_vm_alias (base ^ "+") mapped acc
            | IterT (_, ListN _) ->
                add_vm_alias (base ^ "*") mapped acc
            | IterT (_, Opt) ->
                add_vm_alias (base ^ "?") mapped acc
            | _ -> acc
          in
          acc
    | DefB (def_id, def_params, def_result_typ) ->
        let owner_fn = "$" ^ String.lowercase_ascii prefix in
        let mapped =
          Printf.sprintf "%s%d-%s" prefix eq_idx
            (def_param_var_component def_id.it)
        in
        let apply_name = def_apply_name owner_fn def_id.it in
        let arg_sorts =
          def_params
          |> List.filter_map (fun p ->
              match p.it with
              | TypP _ -> None
              | ExpP (_, t) -> Some (decd_sort_of_typ t)
              | DefP _ | GramP _ -> Some "SpectecTerminal")
        in
        let ret_sort = decd_sort_of_typ def_result_typ in
        register_def_apply_op apply_name arg_sorts ret_sort;
        add_vm_alias def_id.it mapped acc
        |> add_vm_alias (sanitize def_id.it) mapped
        |> add_vm_alias (call_name def_id.it) mapped
        |> add_vm_alias (def_id.it ^ "#apply") apply_name
        |> add_vm_alias ((sanitize def_id.it) ^ "#apply") apply_name
        |> add_vm_alias ((call_name def_id.it) ^ "#apply") apply_name
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
        if is_bool_typ t [] || String.lowercase_ascii v_id.it = "bool"
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

let executable_binder_var_sorts binders vm =
  List.filter_map (fun b -> match b.it with
    | ExpB (v_id, t) ->
        let ts = translate_typ t [] in
        if ts = "SpectecType" || is_bool_typ t [] || String.lowercase_ascii v_id.it = "bool"
        then None
        else (match List.assoc_opt v_id.it vm with
          | Some mv ->
              let sort = binder_decl_sort t in
              Some (mv, if ends_with sort "Seq" then "SpectecTerminals" else sort)
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
  || SSet.mem sort !source_membership_sorts
  || (match Hashtbl.find_opt source_category_subsort_edges sort with
      | Some parents -> SSet.mem "SpectecTerminal" parents
      | None -> false)
  || SSet.exists
       (fun source_sort -> sort = native_sequence_sort_name source_sort)
       !native_sequence_source_sorts
  || SSet.mem sort !zero_arity_source_sorts
  || SSet.mem sort !simple_alias_source_sorts
  || List.exists (fun ri -> ri.rec_sort = sort) !source_record_infos

let has_narrow_runtime_sort sort =
  (* Source category memberships are emitted as mb/cmb axioms in the core, but
     executable rules still avoid relying on them for runtime matching. *)
  (not (SSet.mem sort !flat_sequence_source_sorts))
  && has_representation_narrow_sort sort

let has_runtime_lhs_match_sort sort =
  (* Rewriting rules should only keep sorts that are structural or builtin at
     the pattern boundary.  Source syntax categories such as Idx/Typeuse/Instr
     are encoded by membership/typecheck axioms; using them directly on the
     LHS makes raw source terms fail to match before the rule condition is
     even considered. *)
  List.mem sort
      [ "SpectecTerminal"; "SpectecTerminals";
        "Bool"; "Nat"; "Int";
        "Config"; "State"; "Store"; "Frame"; "Judgement" ]

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

let register_exec_guard_pred sort =
  if needs_source_category_predicate sort then
    reld_type_pred_sorts := SSet.add sort !reld_type_pred_sorts

let exec_binder_guard var sort =
  register_exec_guard_pred sort;
  refined_exec_guard var sort

let is_sequence_shape_predicate cond =
  let cond = String.trim cond |> strip_wrapping_parens |> String.trim in
  starts_with cond "$is-spectec-" && contains_substring cond "-seq"

let is_jhs_typecheck_guard cond =
  let cond =
    cond
    |> strip_trailing_eq_true
    |> strip_wrapping_parens
    |> String.trim
  in
  match parse_call_text cond with
  | Some ("typecheck", [_term; _typ]) -> true
  | _ -> starts_with cond "typecheck("
       || starts_with cond "typecheck ("

let is_execution_category_guard cond =
  let cond = String.trim cond |> strip_wrapping_parens |> String.trim in
  let matches re =
    try ignore (Str.search_forward (Str.regexp re) cond 0); true
    with Not_found -> false
  in
  let is_simple_sort_guard =
    matches "^[A-Z][A-Za-z0-9-]*[A-Za-z0-9_'-]*[ \t]*:[ \t]*[A-Z][A-Za-z0-9-]*$"
    ||
    match String.split_on_char ':' cond with
    | [lhs; rhs] ->
        let lhs = String.trim lhs in
        let rhs = String.trim rhs in
        lhs <> "" && rhs <> ""
        && not (contains_substring lhs "(")
        && not (contains_substring lhs ")")
        && not (contains_substring rhs "(")
        && not (contains_substring rhs ")")
        && not (contains_substring rhs " ")
    | _ -> false
  in
  let is_source_category_pred =
    starts_with cond "$is-spectec-" && not (is_sequence_shape_predicate cond)
  in
  is_simple_sort_guard
  || is_source_category_pred
  || (contains_substring cond "$is-spectec-" && not (contains_substring cond "-seq"))
  || contains_substring cond " hasType "
  || contains_substring cond " : WellTyped"

let drop_execution_category_guards conds =
  List.filter (fun cond -> not (is_execution_category_guard cond)) conds

let is_runtime_typecheck_guard cond =
  let cond = String.trim cond |> strip_wrapping_parens |> String.trim in
  (starts_with cond "$is-spectec-" && not (is_sequence_shape_predicate cond))
  || (contains_substring cond "$is-spectec-" && not (contains_substring cond "-seq"))
  || contains_substring cond " hasType "
  || contains_substring cond " : WellTyped"

let drop_typecheck_guard_conds conds =
  if drop_runtime_typecheck_guards then
    List.filter
      (fun cond -> not (is_runtime_typecheck_guard cond))
      conds
  else conds

let contains_maude_call name text =
  contains_substring text (name ^ " (")
  || contains_substring text (name ^ "(")

let is_execution_rewrite_premise_text text =
  contains_substring text "=>"
  && List.exists
       (fun op -> contains_maude_call op text)
       ["step"; "step-pure"; "step-read"; "steps"]

let uses_execution_rewrite_premise texts =
  List.exists is_execution_rewrite_premise_text texts

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
  (not (ends_with sort "Seq")) && has_runtime_lhs_match_sort sort

let runtime_rule_decl_sort sort =
  if ends_with sort "Seq" then "SpectecTerminals"
  else if preserve_narrow_lhs_sort sort then sort
  else "SpectecTerminal"

let widen_reld_lhs_typed_vars typed_vars lhs_vars =
  let _lhs_set = SSet.of_list lhs_vars in

  let predicate_pairs = [] in

  List.iter
    (fun (_, sort) ->
      if needs_source_category_predicate sort then
        reld_type_pred_sorts := SSet.add sort !reld_type_pred_sorts)
    predicate_pairs;

  let typed_vars_for_decl =
    typed_vars
    |> List.map (fun (v, s) ->
         if ends_with s "Seq" then (v, "SpectecTerminals")
         else if not (preserve_narrow_lhs_sort s)
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

let source_subsort_edge_exists child parent =
  child = parent
  || (child = "Nat" && SSet.mem parent !nat_subsort_sorts)
  || (child = "Int" && SSet.mem parent !int_subsort_sorts)
  || (match Hashtbl.find_opt source_category_subsort_edges child with
      | Some parents -> SSet.mem parent parents
      | None -> false)

let source_subsort_reachable child parent =
  let rec go seen child =
    child = parent
    || (not (SSet.mem child seen)
        &&
        let seen = SSet.add child seen in
        let direct_parents =
          match Hashtbl.find_opt source_category_subsort_edges child with
          | Some parents -> parents
          | None -> SSet.empty
        in
        let direct_parents =
          if child = "Nat" then SSet.union direct_parents !nat_subsort_sorts
          else if child = "Int" then SSet.union direct_parents !int_subsort_sorts
          else direct_parents
        in
        SSet.exists (fun next -> next = parent || go seen next) direct_parents)
  in
  go SSet.empty child

let most_specific_source_sort sorts =
  let sorts =
    sorts
    |> SSet.filter (fun sort -> SSet.mem sort !source_membership_sorts)
  in
  let candidates =
    sorts
    |> SSet.filter (fun sort ->
         SSet.for_all (fun other -> source_subsort_reachable sort other) sorts)
  in
  if SSet.cardinal candidates = 1 then Some (SSet.choose candidates)
  else None

let parse_simple_sort_guard cond =
  let cond = Str.global_replace (Str.regexp "[ \t\n\r]+") " " (String.trim cond) in
  let re = Str.regexp "^\\([A-Z][A-Za-z0-9-]*\\)[ \t]*:[ \t]*\\([A-Za-z][A-Za-z0-9-]*\\)$" in
  if Str.string_match re cond 0 then
    Some (Str.matched_group 1 cond, Str.matched_group 2 cond)
  else None

let membership_var_guard_pairs stmt =
  match parse_membership_statement stmt with
  | None -> []
  | Some (_, _pattern, None) -> []
  | Some (_, _pattern, Some cond) ->
      Str.split (Str.regexp "[ \t\n\r]*/\\\\[ \t\n\r]*") cond
      |> List.filter_map parse_simple_sort_guard

let declared_var_sort_map decls =
  let tbl = Hashtbl.create 1024 in
  let re =
    Str.regexp "^  vars?[ \t]+\\(.+\\)[ \t]+:[ \t]+\\([A-Za-z][A-Za-z0-9-]*\\)[ \t]*\\."
  in
  List.iter
    (fun line ->
       if Str.string_match re line 0 then
         let names = Str.matched_group 1 line in
         let sort = Str.matched_group 2 line in
         names
         |> Str.split (Str.regexp "[ \t]+")
         |> List.iter (fun name ->
              if name <> "" then Hashtbl.replace tbl name sort))
    decls;
  tbl

let rename_conflicting_membership_vars decls memberships =
  let var_sorts = declared_var_sort_map decls in
  let extra_decls = ref [] in
  let add_decl name sort =
    if Hashtbl.find_opt var_sorts name <> Some sort then begin
      Hashtbl.replace var_sorts name sort;
      extra_decls := Printf.sprintf "  var %s : %s ." name sort :: !extra_decls
    end
  in
  let source_guard_sort_is_terminal sort =
    SSet.mem sort !source_membership_sorts
    || SSet.mem sort !zero_arity_source_sorts
    || SSet.mem sort !simple_alias_source_sorts
    || Hashtbl.mem source_category_subsort_edges sort
    || Hashtbl.mem source_sort_type_atoms sort
    || Hashtbl.mem specialized_syntax_sort_type_terms sort
    || literal_family_of_concrete_sort sort <> None
  in
  let source_guard_sort_is_sequence sort =
    SSet.mem sort !native_sequence_source_sorts
    || SSet.mem sort !sequence_alias_sorts
    || SSet.mem sort !flat_sequence_source_sorts
    || (ends_with sort "Seq"
        && source_guard_sort_is_terminal
             (String.sub sort 0 (String.length sort - 3)))
  in
  let rename_one stmt =
    membership_var_guard_pairs stmt
    |> List.fold_left
         (fun acc (var, sort) ->
            if SSet.mem var !generated_zero_arity_ctor_names then acc
            else
            match Hashtbl.find_opt var_sorts var with
            | Some "SpectecTerminal" when source_guard_sort_is_terminal sort ->
                acc
            | Some "SpectecTerminals" when source_guard_sort_is_sequence sort ->
                acc
            | Some existing when existing = sort -> acc
            | Some _different ->
                let renamed =
                  Printf.sprintf "%s-%s"
                    (String.uppercase_ascii (sanitize sort)) var
                in
                add_decl renamed sort;
                replace_maude_var_token var renamed acc
            | None ->
                add_decl var sort;
                acc)
         stmt
  in
  let memberships = List.map rename_one memberships in
  (List.sort_uniq String.compare !extra_decls, memberships)

let redundant_or_warning_prone_category_membership stmt =
	  let pattern_is_plain_variable pattern =
	    let p = strip_wrapping_parens pattern |> String.trim in
	    let re = Str.regexp "^[A-Z][A-Z0-9-]*$" in
	    Str.string_match re p 0
      && not (is_source_ctor_var_token p || is_source_ctor_name p)
  in
  let pattern_is_numeric_literal pattern =
    let p = strip_wrapping_parens pattern |> String.trim in
    let re = Str.regexp "^[0-9]+$" in
    Str.string_match re p 0
  in
		  match parse_membership_statement stmt with
	  | Some ("Nonfuncs", pattern, None)
	      when contains_substring pattern "GLOBAL-LIST-GLOBAL"
	        && contains_substring pattern "MEM-LIST-MEM"
	        && contains_substring pattern "TABLE-LIST-TABLE"
	        && contains_substring pattern "ELEM-LIST-ELEM" ->
	      true
	  | Some (_, pattern, None)
	      when pattern_is_plain_variable pattern ->
	      true
  | Some (_, pattern, None)
      when pattern_is_numeric_literal pattern ->
      true
	  | Some (target_sort, pattern, Some cond) ->
      let pat_var = strip_wrapping_parens pattern |> String.trim in
      (match parse_simple_sort_guard cond with
       | Some (guard_var, source_sort)
           when pat_var = guard_var
             && source_subsort_edge_exists source_sort target_sort ->
           true
       | _ -> false)
  | _ -> false

let category_var_sort_map decls =
  let map = Hashtbl.create 512 in
  let add_line line =
    let s = String.trim line in
    let re = Str.regexp "^var[s]?[ \t]+\\(.+\\)[ \t]+:[ \t]+\\([A-Za-z][A-Za-z0-9-]*\\)[ \t]*\\.$" in
    if Str.string_match re s 0 then begin
      let vars = Str.matched_group 1 s in
      let sort = Str.matched_group 2 s in
      vars
      |> Str.split (Str.regexp "[ \t]+")
      |> List.filter (fun v -> v <> "")
      |> List.iter (fun v -> Hashtbl.replace map v sort)
    end
  in
  List.iter add_line decls;
  map

let sort_is_numeric_like sort =
  sort = "Nat"
  || sort = "Int"
  || SSet.mem sort !nat_subsort_sorts
  || SSet.mem sort !int_subsort_sorts

let membership_uses_numeric_like_vars var_sorts stmt =
  let re = Str.regexp "[A-Z][A-Z0-9-]*" in
  let rec loop pos =
    match (try Some (Str.search_forward re stmt pos) with Not_found -> None) with
    | None -> false
    | Some _ ->
        let tok = Str.matched_string stmt in
        match Hashtbl.find_opt var_sorts tok with
        | Some sort when sort_is_numeric_like sort -> true
        | _ -> loop (Str.match_end ())
  in
  loop 0

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

let partition_membership_statements lines =
  let rec finish non_memberships memberships cur = function
    | [] ->
        let non_memberships =
          match cur with
          | None -> non_memberships
          | Some chunks -> (String.concat "\n" (List.rev chunks)) :: non_memberships
        in
        (List.rev non_memberships, List.rev memberships)
    | line :: rest ->
        let s = String.trim line in
        let starts_membership = starts_with s "mb " || starts_with s "cmb " in
        let ends_stmt = ends_with s "." in
        match cur with
        | None when starts_membership && ends_stmt ->
            finish non_memberships (line :: memberships) None rest
        | None when starts_membership ->
            finish non_memberships memberships (Some [line]) rest
        | None ->
            finish (line :: non_memberships) memberships None rest
        | Some chunks when ends_stmt ->
            finish non_memberships
              (String.concat "\n" (List.rev (line :: chunks)) :: memberships)
              None rest
        | Some chunks ->
            finish non_memberships memberships (Some (line :: chunks)) rest
  in
  finish [] [] None lines

let normalize_ws s =
  Str.global_replace (Str.regexp "[ \t\n\r]+") " " (String.trim s)

let find_matching_paren text open_pos =
  let len = String.length text in
  let rec loop i depth =
    if i >= len then None
    else
      match text.[i] with
      | '(' -> loop (i + 1) (depth + 1)
      | ')' ->
          if depth = 1 then Some i else loop (i + 1) (depth - 1)
      | _ -> loop (i + 1) depth
  in
  if open_pos < len && text.[open_pos] = '(' then loop open_pos 0 else None

let parse_category_membership_statement stmt =
  let s = normalize_ws stmt in
  let kind, rest =
    if starts_with s "mb " then Some "mb", String.sub s 3 (String.length s - 3)
    else if starts_with s "cmb " then Some "cmb", String.sub s 4 (String.length s - 4)
    else None, s
  in
  match kind with
  | None -> None
  | Some kind ->
      let fallback rest =
        let rest = String.trim rest in
        let rest =
          if ends_with rest "." then
            String.sub rest 0 (String.length rest - 1) |> String.trim
          else rest
        in
        let body, conds =
          match Str.bounded_split (Str.regexp "[ \t]+if[ \t]+") rest 2 with
          | [body; cond] ->
              (String.trim body,
               Str.split (Str.regexp "[ \t]*/\\\\[ \t]*") cond
               |> List.map String.trim
               |> List.filter (fun c -> c <> ""))
          | _ -> (rest, [])
        in
        let re =
          Str.regexp
            "^\\(.*\\)[ \t]+:[ \t]+\\([A-Za-z][A-Za-z0-9_-]*\\)$"
        in
        if Str.string_match re body 0 then
          let lhs =
            Str.matched_group 1 body
            |> strip_wrapping_parens
            |> String.trim
          in
          let sort = Str.matched_group 2 body |> String.trim in
          if lhs = "" || sort = "" then None else Some (kind, lhs, sort, conds)
        else None
      in
      let rest = String.trim rest in
      if rest = "" || rest.[0] <> '(' then fallback rest
      else
        match find_matching_paren rest 0 with
        | None -> fallback rest
        | Some close_idx ->
            let lhs =
              String.sub rest 1 (close_idx - 1)
              |> strip_wrapping_parens
              |> String.trim
            in
            let tail =
              String.sub rest (close_idx + 1)
                (String.length rest - close_idx - 1)
              |> String.trim
            in
            if not (starts_with tail ":") then fallback rest
            else
              let tail =
                String.sub tail 1 (String.length tail - 1) |> String.trim
              in
              let sort, tail =
                match Str.bounded_split (Str.regexp "[ \t]+") tail 2 with
                | [sort] -> sort, ""
                | [sort; tail] -> sort, String.trim tail
                | _ -> "", ""
              in
              if sort = "" then None
              else
                let conds =
                  if tail = "." || tail = "" then []
                  else if starts_with tail "if " then
                    let cond =
                      String.sub tail 3 (String.length tail - 3)
                      |> String.trim
                    in
                    let cond =
                      if ends_with cond "." then
                        String.sub cond 0 (String.length cond - 1)
                      else cond
                    in
                    Str.split (Str.regexp "[ \t]*/\\\\[ \t]*") cond
                    |> List.map String.trim
                    |> List.filter (fun c -> c <> "")
                  else []
                in
                Some (kind, lhs, sort, conds)

let simplify_trivial_membership_statement stmt =
  let is_true_cond cond =
    let c = normalize_ws cond in
    c = "true = true" || c = "( true = true )" || c = "true"
  in
  match parse_category_membership_statement stmt with
  | Some ("cmb", lhs, sort, conds)
      when conds <> [] && List.for_all is_true_cond conds ->
      Printf.sprintf "  mb ( %s ) : %s ." lhs sort
  | _ -> stmt

let structural_runtime_sorts =
  SSet.of_list
    [ "SpectecTerminal"; "SpectecTerminals"; "SpectecType"; "SpectecTypes";
      "Bool"; "Nat"; "Int"; "Char"; "Zero"; "NzNat";
      "Config"; "State"; "Store"; "Frame"; "Judgement"; "ValidJudgement";
      "Env"; "Stage"; "Context"; "InstrsContext";
      "LabelContext"; "LabelContexts"; "FrameContext"; "FrameContexts";
      "RecordItem"; "RecordItems"; "Addr" ]

let is_structural_runtime_sort sort =
  SSet.mem sort structural_runtime_sorts
  || ends_with sort "addr"
  || ends_with sort "Conf"

let source_seq_elem_sort_name sort =
  if ends_with sort "Seq" && String.length sort > 3 then
    Some (String.sub sort 0 (String.length sort - 3))
  else None

let rec is_source_syntax_sort sort =
  if is_structural_runtime_sort sort then false
  else if is_meta_numeric_alias_sort sort then false
  else
    Hashtbl.mem source_sort_type_atoms sort
    || SSet.mem sort !source_membership_sorts
    || SSet.mem sort !zero_arity_source_sorts
    || SSet.mem sort !simple_alias_source_sorts
    || SSet.mem sort !sequence_alias_sorts
    || SSet.mem sort !flat_sequence_source_sorts
    || SSet.mem sort !specialized_syntax_sort_names
    || Hashtbl.mem specialized_syntax_sort_type_terms sort
    || Hashtbl.mem source_category_subsort_edges sort
    || (match source_seq_elem_sort_name sort with
        | Some elem -> is_source_syntax_sort elem
        | None -> false)

let jhs_carrier_sort_for_source_sort sort =
  if is_structural_runtime_sort sort then None
  else if is_meta_numeric_alias_sort sort then None
  else
    match source_seq_elem_sort_name sort with
    | Some elem when is_structural_runtime_sort elem -> Some "SpectecTerminals"
    | Some elem when is_source_syntax_sort elem -> Some "SpectecTerminals"
    | _ when SSet.mem sort !flat_sequence_source_sorts -> Some "SpectecTerminals"
    | _ when is_source_syntax_sort sort -> Some "SpectecTerminal"
    | _ -> None

let rec source_type_term_for_sort sort =
  if is_meta_numeric_alias_sort sort then None
  else
  match source_seq_elem_sort_name sort with
  | Some elem when is_source_syntax_sort elem -> source_type_term_for_sort elem
  | _ ->
      (match Hashtbl.find_opt specialized_syntax_sort_type_terms sort with
       | Some term -> Some term
       | None ->
	           match literal_family_of_concrete_sort sort with
	           | Some (family_sort, numeric_tail) ->
	               let family_atom =
	                 match source_sort_type_atom_for_arity family_sort 1 with
	                 | Some atom -> atom
	                 | None ->
	                     (match Hashtbl.find_opt source_sort_type_atoms family_sort with
	                      | Some atom -> atom
	                      | None -> family_sort)
	               in
	               Some (format_spectec_type_term family_atom [numeric_tail])
           | None ->
               match Hashtbl.find_opt source_sort_type_atoms sort with
               | Some atom ->
                   let arity =
                     match Hashtbl.find_opt source_type_atom_arities atom with
                     | Some n -> n
                     | None -> 0
                   in
                   if arity = 0 then Some atom else None
               | None ->
                   let parents =
                     match Hashtbl.find_opt source_category_subsort_edges sort with
                     | Some ps -> SSet.elements ps
                     | None -> []
                   in
                   parents
                   |> List.find_map (fun parent ->
                        if parent = sort then None else source_type_term_for_sort parent)
                   |> (function
                       | Some _ as hit -> hit
                       | None ->
                           if is_source_syntax_sort sort then Some sort else None))

let parse_sort_guard_condition cond =
  let cond =
    strip_trailing_eq_true (strip_wrapping_parens cond |> String.trim)
  in
  match split_once_re (Str.regexp "[ \t]+:[ \t]+") cond with
  | Some (term, sort) ->
      let term = strip_wrapping_parens term |> String.trim in
      let sort = String.trim sort in
      if term <> "" && sort <> "" && not (contains_substring sort " ")
      then Some (term, sort)
      else None
  | None -> None

let jhs_condition_of_source_guard cond =
  match parse_sort_guard_condition cond with
  | Some (term, sort) ->
      (match source_type_term_for_sort sort with
       | Some type_term when jhs_carrier_sort_for_source_sort sort <> None ->
           Some (Printf.sprintf "typecheck(%s, %s) = true" term type_term)
       | _ when jhs_carrier_sort_for_source_sort sort <> None -> None
       | _ -> Some cond)
  | None -> Some cond

let jhs_convert_conditions conds =
  conds
  |> List.filter_map jhs_condition_of_source_guard
  |> List.map String.trim
  |> List.filter (fun c -> c <> "" && c <> "true" && c <> "( true )")

let jhs_cond_join conds =
  conds
  |> List.map String.trim
  |> List.map strip_trailing_dot
  |> List.map strip_trailing_eq_true
  |> List.map strip_trailing_dot
  |> List.filter (fun c -> c <> "" && c <> "true" && c <> "( true )")
  |> String.concat " /\\ "

let source_ctor_lhs_head_arity lhs =
  let lhs = strip_wrapping_parens lhs |> String.trim in
  match parse_call_text lhs with
  | Some (head, args)
      when is_source_ctor_name head || starts_with head "REC" ->
      Some (head, List.length args)
  | Some (head, args) ->
      (match Hashtbl.find_opt source_ctor_by_surface_head_arity
               (source_ctor_surface_head_arity_key head (List.length args))
       with
       | Some info -> Some (info.source_ctor_name, List.length args)
       | None ->
           (match source_ctor_info_by_op_name_arity head (List.length args) with
            | Some info -> Some (info.source_ctor_name, List.length args)
            | None -> None))
	  | _ ->
	      (match strict_source_ctor_terms (split_top_level_terms_preserve_eps lhs) with
	       | Some (head, args) -> Some (head, List.length args)
	       | None ->
	      (match parse_source_ctor_surface_text lhs with
	       | Some (head, args) -> Some (head, List.length args)
	       | None ->
	           match source_ctor_arity lhs with
	           | Some arity -> Some (lhs, arity)
	           | None -> None))

let rec source_ctor_lhs_is_ground lhs =
  let lhs = strip_wrapping_parens lhs |> String.trim in
  if lhs = "" then false
  else if lhs = "eps" then true
  else if is_raw_numeric_text lhs then true
  else
    match parse_call_text lhs with
    | Some (head, args) when is_source_ctor_name head || starts_with head "REC"
                              || starts_with head "$" ->
        List.for_all source_ctor_lhs_is_ground args
    | Some (head, args) when starts_with head "_" ->
        List.for_all source_ctor_lhs_is_ground args
	    | _ ->
	        (match strict_source_ctor_terms (split_top_level_terms_preserve_eps lhs) with
	         | Some (_head, args) -> List.for_all source_ctor_lhs_is_ground args
	         | None ->
	        (match parse_source_ctor_surface_text lhs with
	         | Some (_head, args) -> List.for_all source_ctor_lhs_is_ground args
	         | None ->
	             match source_ctor_arity lhs with
	             | Some 0 -> true
	             | Some _ -> false
	             | None -> not (is_plain_var_like lhs)))

let non_ground_total_constructor_membership stmt =
  match parse_category_membership_statement stmt with
  | Some ("mb", lhs, "SpectecTerminal", []) ->
      (match source_ctor_lhs_head_arity lhs with
       | Some (_head, arity) when arity > 0 ->
           not (source_ctor_lhs_is_ground lhs)
       | _ -> false)
  | _ -> false

let conditional_source_ctor_heads_from_memberships memberships =
  memberships
  |> List.fold_left
       (fun acc stmt ->
         match parse_category_membership_statement stmt with
         | Some (_kind, lhs, sort, conds)
             when jhs_carrier_sort_for_source_sort sort <> None ->
             let rhs = jhs_cond_join (jhs_convert_conditions conds) in
             (match source_ctor_lhs_head_arity lhs with
              | Some (head, arity) when arity > 0 && rhs <> "" ->
                  SSet.add head acc
              | _ -> acc)
         | _ -> acc)
       SSet.empty

let is_keywordish_jhs_membership_token v =
  source_protected_nonvariable_token v

let is_upper_initial_jhs_membership_var v =
  String.length v > 0 &&
  let c = v.[0] in
  c >= 'A' && c <= 'Z'

let is_hyphen_jhs_membership_var_like v =
  if not (String.contains v '-') then true
  else
    let parts = String.split_on_char '-' v |> List.filter (fun s -> s <> "") in
    match List.rev parts with
    | [] -> false
    | last :: _ ->
        String.exists (fun c -> c >= '0' && c <= '9') v || String.length last <= 2

let is_bindable_jhs_membership_var v =
  v <> ""
  && is_upper_initial_jhs_membership_var v
  && is_hyphen_jhs_membership_var_like v
  && not (is_keywordish_jhs_membership_token v)

let jhs_membership_lhs_vars lhs =
  extract_vars_from_maude lhs
  |> List.filter is_bindable_jhs_membership_var
  |> List.filter (fun v ->
       not (is_source_ctor_var_token v)
       && not (is_source_ctor_name v)
       && not (SSet.mem v !generated_zero_arity_ctor_names))
  |> SSet.of_list

let jhs_kind_terminal_vars_from_memberships memberships =
  let partial_heads = conditional_source_ctor_heads_from_memberships memberships in
  memberships
  |> List.fold_left
       (fun acc stmt ->
         match parse_category_membership_statement stmt with
         | Some (_kind, lhs, sort, _conds)
             when jhs_carrier_sort_for_source_sort sort <> None ->
             (match source_ctor_lhs_head_arity lhs with
              | Some (head, arity)
                  when arity > 0 && SSet.mem head partial_heads ->
                  SSet.union acc (jhs_membership_lhs_vars lhs)
              | _ -> acc)
         | _ -> acc)
       SSet.empty

let jhs_type_head type_term =
  let t = strip_wrapping_parens type_term |> String.trim in
  let len = String.length t in
  let rec loop i =
    if i >= len then len
    else match t.[i] with
      | ' ' | '\t' | '\n' | '\r' | '(' -> i
      | _ -> loop (i + 1)
  in
  String.sub t 0 (loop 0)

let literal_payload_wrapped_terms_in_text text =
  let add_payload var wrapped acc =
    match List.assoc_opt var acc with
    | Some existing when existing = wrapped -> acc
    | Some _ -> acc
    | None -> (var, wrapped) :: acc
  in
  let scan_wrapper wrapper acc =
    let re =
      Str.regexp
        (Str.quote wrapper
         ^ "[ \t\n\r]*([ \t\n\r]*\\([A-Z][A-Z0-9_-]*\\)[ \t\n\r]*)")
    in
    let rec loop pos acc =
      match (try Some (Str.search_forward re text pos) with Not_found -> None) with
      | None -> acc
      | Some _ ->
          let var = Str.matched_group 1 text |> String.trim in
          let wrapped = format_call wrapper [var] in
          loop (Str.match_end ()) (add_payload var wrapped acc)
    in
    loop 0 acc
  in
  let acc =
    Hashtbl.fold
    (fun wrapper _payload_sort acc -> scan_wrapper wrapper acc)
    literal_wrapper_payload_sorts
    []
  in
  let wrap_lit_re =
    Str.regexp
      (Str.quote "$wrap-lit"
       ^ "[ \t\n\r]*([ \t\n\r]*\\([^,() \t\n\r]+\\)[ \t\n\r]*,[ \t\n\r]*\\([A-Z][A-Z0-9_-]*\\)[ \t\n\r]*)")
  in
  let rec scan_wrap_lit pos acc =
    match (try Some (Str.search_forward wrap_lit_re text pos) with Not_found -> None) with
    | None -> acc
    | Some _ ->
        let type_term = Str.matched_group 1 text |> String.trim in
        let var = Str.matched_group 2 text |> String.trim in
        let wrapped = format_call "$wrap-lit" [type_term; var] in
        scan_wrap_lit (Str.match_end ()) (add_payload var wrapped acc)
  in
  scan_wrap_lit 0 acc

let rewrite_literal_payload_typecheck_cond payload_wrapped_terms cond =
  let core =
    strip_trailing_eq_true (strip_wrapping_parens cond |> String.trim)
  in
  match parse_call_text core with
  | Some ("typecheck", [term; type_term]) ->
      let term = strip_wrapping_parens term |> String.trim in
      let type_term = jhs_type_term_key type_term in
      if is_plain_var_like term
         && not (SSet.mem type_term !raw_payload_type_terms)
      then
        (match List.assoc_opt term payload_wrapped_terms with
         | Some wrapped ->
             format_call "typecheck" [wrapped; type_term]
         | None -> cond)
      else cond
  | _ -> cond

let rewrite_literal_payload_typecheck_conds pattern_text conds =
  let payload_wrapped_terms = literal_payload_wrapped_terms_in_text pattern_text in
  if payload_wrapped_terms = [] then conds
  else List.map (rewrite_literal_payload_typecheck_cond payload_wrapped_terms) conds

let rec collect_typd_type_constructor_heads defs =
  defs
  |> List.fold_left
       (fun acc d ->
	      match d.it with
		      | RecD ds -> SSet.union acc (collect_typd_type_constructor_heads ds)
		      | TypD (id, params, _insts) ->
		          if String.lowercase_ascii (sanitize id.it) = "list"
		          then acc
		          else
		            let name = spectec_type_constructor_head id.it (List.length params) in
		            SSet.add name acc
          | _ -> acc)
       (SSet.of_list
          [spectec_type_term_of_name "nat" []; spectec_type_term_of_name "int" []])

let spectec_type_param_sort (p : param) =
  let _ = p in
  "SpectecTerminal"

let spectec_type_constructor_decls defs =
  let rec collect acc d =
    match d.it with
		    | RecD ds -> List.fold_left collect acc ds
		    | TypD (id, params, _insts) ->
		        if String.lowercase_ascii (sanitize id.it) = "list"
		        then acc else
		        let name = spectec_type_constructor_head id.it (List.length params) in
        let arg_sorts = List.map spectec_type_param_sort params in
        let decl =
          match arg_sorts with
          | [] -> Printf.sprintf "  op %s : -> SpectecType ." name
          | _ ->
              Printf.sprintf "  op %s : %s -> SpectecType ."
                name (String.concat " " arg_sorts)
        in
        decl :: acc
    | _ -> acc
  in
  defs
  |> List.fold_left collect []
  |> List.sort_uniq String.compare

let jhs_membership_statements memberships =
  let conditional_ctor_heads =
    conditional_source_ctor_heads_from_memberships memberships
  in
  let used_type_terms = ref SSet.empty in
  let remember_type_term t =
    used_type_terms := SSet.add t !used_type_terms
  in
  let typecheck_lhs lhs = wrap_paren lhs in
  let lhs_head lhs =
    let t = strip_wrapping_parens lhs |> String.trim in
    let len = String.length t in
    let rec loop i =
      if i >= len then i
      else
        match t.[i] with
        | ' ' | '\t' | '\n' | '\r' | '(' | ',' -> i
        | _ -> loop (i + 1)
    in
    let stop = loop 0 in
    if stop = 0 then None else Some (String.sub t 0 stop)
  in
  let lhs_is_constructor_shaped lhs =
    match source_ctor_lhs_head_arity lhs with
    | Some _ -> true
    | None ->
    match lhs_head lhs with
    | Some head ->
        is_source_ctor_name head
        || starts_with head "$"
        || starts_with head "REC"
    | None -> false
  in
  let lhs_is_raw_sequence lhs =
    let lhs_trimmed = strip_wrapping_parens lhs |> String.trim in
    match source_ctor_lhs_head_arity lhs with
    | Some _ -> false
    | None ->
        starts_with lhs_trimmed "eps "
        || starts_with lhs_trimmed "eps("
        || starts_with lhs_trimmed "eps\t"
        ||
        match split_top_level_terms lhs with
        | _ :: _ :: _ -> true
        | _ -> false
  in
  let terminal_membership lhs rhs =
    if lhs_is_raw_sequence lhs || not (lhs_is_constructor_shaped lhs) then []
    else
      match source_ctor_lhs_head_arity lhs with
      | Some (_head, 0) -> []
      | Some (_head, arity) when arity > 0 && rhs <> "" ->
          [Printf.sprintf "  cmb ( %s ) : SpectecTerminal\n   if %s ." lhs rhs]
      | Some (head, arity)
          when arity > 0
            && SSet.mem head conditional_ctor_heads
            && source_ctor_lhs_is_ground lhs ->
          [Printf.sprintf "  mb ( %s ) : SpectecTerminal ." lhs]
      | _ -> []
  in
  let is_keywordish_membership_token v =
    source_protected_nonvariable_token v
  in
  let is_upper_initial_membership v =
    String.length v > 0 &&
    let c = v.[0] in
    c >= 'A' && c <= 'Z'
  in
  let is_hyphen_var_like_membership v =
    if not (String.contains v '-') then true
    else
      let parts = String.split_on_char '-' v |> List.filter (fun s -> s <> "") in
      match List.rev parts with
      | [] -> false
      | last :: _ ->
          String.exists (fun c -> c >= '0' && c <= '9') v || String.length last <= 2
  in
  let is_bindable_membership_var v =
    v <> ""
    && is_upper_initial_membership v
    && is_hyphen_var_like_membership v
    && not (is_keywordish_membership_token v)
  in
  let membership_lhs_vars lhs =
    extract_vars_from_maude lhs
    |> List.filter is_bindable_membership_var
    |> List.filter (fun v ->
         not (is_source_ctor_var_token v)
         && not (is_source_ctor_name v)
         && not (SSet.mem v !generated_zero_arity_ctor_names))
    |> SSet.of_list
  in
  let condition_vars cond =
    extract_vars_from_maude cond
    |> List.filter is_bindable_membership_var
    |> List.filter (fun v ->
         not (is_source_ctor_var_token v)
         && not (is_source_ctor_name v)
         && not (SSet.mem v !generated_zero_arity_ctor_names))
  in
  let is_redundant_builtin_membership_guard cond =
    match parse_sort_guard_condition cond with
    | Some (term, ("Nat" | "Int" | "Bool")) ->
        is_plain_var_like (strip_wrapping_parens term |> String.trim)
    | _ -> false
  in
  let terminal_membership_conds lhs conds =
    let lhs_vars = membership_lhs_vars lhs in
    conds
    |> List.filter (fun cond -> not (is_redundant_builtin_membership_guard cond))
    |> List.filter (fun cond ->
         condition_vars cond
         |> List.for_all (fun v -> SSet.mem v lhs_vars))
  in
  let terminal_membership_rhs lhs conds =
    terminal_membership_conds lhs conds
    |> jhs_cond_join
  in
  let normalize_condition_key cond =
    cond
    |> String.trim
    |> strip_trailing_dot
    |> strip_trailing_eq_true
    |> strip_trailing_dot
    |> normalize_ws
  in
  let typecheck_constructor_condition_lhs lhs =
    Printf.sprintf "%s : SpectecTerminal" (typecheck_lhs lhs)
  in
  let terminal_membership_is_relevant lhs membership_rhs =
    if lhs_is_raw_sequence lhs || not (lhs_is_constructor_shaped lhs) then false
    else
      match source_ctor_lhs_head_arity lhs with
      | Some (_head, 0) -> false
      | Some (_head, arity) when arity > 0 && membership_rhs <> "" -> true
      | Some (head, arity)
          when arity > 0
            && SSet.mem head conditional_ctor_heads
            && source_ctor_lhs_is_ground lhs ->
          true
      | _ -> false
  in
  let typecheck_rhs_conds lhs conds membership_rhs =
    if terminal_membership_is_relevant lhs membership_rhs then
      let membership_cond_keys =
        terminal_membership_conds lhs conds
        |> List.map normalize_condition_key
        |> SSet.of_list
      in
      let external_conds =
        conds
        |> List.filter (fun cond ->
             not (SSet.mem (normalize_condition_key cond) membership_cond_keys))
      in
      typecheck_constructor_condition_lhs lhs :: external_conds
    else conds
  in
  let lhs_membership_key lhs =
    strip_wrapping_parens lhs |> String.trim |> normalize_ws
  in
  let category_reference_inclusion lhs parent_sort conds =
    let lhs_key = lhs_membership_key lhs in
    if not (is_plain_var_like lhs_key) then None
    else
      match conds with
      | [cond] ->
          (match parse_sort_guard_condition cond with
           | Some (term, child_sort)
               when lhs_membership_key term = lhs_key
                 && child_sort <> parent_sort
                 && jhs_carrier_sort_for_source_sort child_sort <> None ->
               (match source_type_term_for_sort child_sort,
                      source_type_term_for_sort parent_sort with
                | Some _, Some _ -> Some child_sort
                | _ -> None)
           | _ -> None)
      | _ -> None
  in
  let add_category_reference_edge child parent =
    if child <> parent && not (source_subsort_reachable parent child) then
      let old =
        match Hashtbl.find_opt source_category_subsort_edges child with
        | Some parents -> parents
        | None -> SSet.empty
      in
      Hashtbl.replace source_category_subsort_edges child (SSet.add parent old)
  in
  memberships
  |> List.iter (fun stmt ->
       match parse_category_membership_statement stmt with
       | Some (_kind, lhs, parent_sort, conds)
           when jhs_carrier_sort_for_source_sort parent_sort <> None ->
           (match category_reference_inclusion lhs parent_sort conds with
            | Some child_sort -> add_category_reference_edge child_sort parent_sort
            | None -> ())
       | _ -> ());
  let lhs_membership_sorts : (string, SSet.t) Hashtbl.t = Hashtbl.create 1024 in
  let remember_lhs_sort lhs sort =
    let key = lhs_membership_key lhs in
    let old =
      match Hashtbl.find_opt lhs_membership_sorts key with
      | Some sorts -> sorts
      | None -> SSet.empty
    in
    Hashtbl.replace lhs_membership_sorts key (SSet.add sort old)
  in
  memberships
  |> List.iter (fun stmt ->
       match parse_category_membership_statement stmt with
       | Some (_kind, lhs, sort, _conds)
           when jhs_carrier_sort_for_source_sort sort <> None ->
           remember_lhs_sort lhs sort
       | _ -> ());
  let inherited_parent_membership lhs sort =
    match Hashtbl.find_opt lhs_membership_sorts (lhs_membership_key lhs) with
    | None -> false
    | Some sorts ->
        SSet.exists
          (fun child ->
             child <> sort && source_subsort_reachable child sort)
          sorts
  in
  let converted =
    memberships
    |> List.concat_map (fun stmt ->
         match parse_category_membership_statement stmt with
         | Some (_kind, lhs, sort, conds)
             when jhs_carrier_sort_for_source_sort sort <> None ->
             if category_reference_inclusion lhs sort conds <> None
                || inherited_parent_membership lhs sort then []
             else
             (match source_type_term_for_sort sort with
              | None ->
                  let conds = jhs_convert_conditions conds in
                  let membership_rhs = terminal_membership_rhs lhs conds in
                  terminal_membership lhs membership_rhs
              | Some type_term ->
	                  remember_type_term type_term;
	                  let conds = jhs_convert_conditions conds in
	                  let membership_rhs = terminal_membership_rhs lhs conds in
	                  let rhs =
	                    typecheck_rhs_conds lhs conds membership_rhs
	                    |> jhs_cond_join
	                  in
	                  let typecheck_stmt =
	                    if rhs = "" then
	                      Printf.sprintf
                        "  eq typecheck(%s, %s) = true ."
                        (typecheck_lhs lhs) type_term
                    else
                      Printf.sprintf
                        "  ceq typecheck(%s, %s) = true\n   if %s ."
                        (typecheck_lhs lhs) type_term rhs
                  in
                  typecheck_stmt :: terminal_membership lhs membership_rhs)
         | _ -> [stmt])
  in
  (converted |> List.sort_uniq String.compare, !used_type_terms)

let jhs_subsort_typecheck_eqs () =
  let used_type_terms = ref SSet.empty in
  let remember t = used_type_terms := SSet.add t !used_type_terms in
  let eqs =
    Hashtbl.fold
      (fun child parents acc ->
         if is_structural_runtime_sort child then acc
         else
           match source_type_term_for_sort child with
           | None -> acc
           | Some child_ty ->
               remember child_ty;
               parents
               |> SSet.elements
               |> List.fold_left
                    (fun acc parent ->
                       if is_structural_runtime_sort parent then acc
                       else
	                         match source_type_term_for_sort parent with
	                         | None -> acc
	                         | Some parent_ty when parent_ty = child_ty -> acc
                         | Some _ when source_alias_subsort_edge child parent -> acc
	                         | Some parent_ty ->
	                             remember parent_ty;
		                             Printf.sprintf
	                               "  ceq typecheck(%s, %s) = true\n   if typecheck(%s, %s) ."
	                               spectec_term_var parent_ty spectec_term_var child_ty
                             :: acc)
                    acc)
      source_category_subsort_edges
      []
    |> List.sort_uniq String.compare
  in
  (eqs, !used_type_terms)

let jhs_membership_lhs_head lhs =
  let t = strip_wrapping_parens lhs |> String.trim in
  let len = String.length t in
  let rec loop i =
    if i >= len then i
    else
      match t.[i] with
      | ' ' | '\t' | '\n' | '\r' | '(' | ',' -> i
      | _ -> loop (i + 1)
  in
  let stop = loop 0 in
  if stop = 0 then None else Some (String.sub t 0 stop)

let jhs_partial_constructor_ops memberships =
  memberships
  |> List.filter_map (fun stmt ->
	       match parse_category_membership_statement stmt with
	       | Some ("cmb", lhs, "SpectecTerminal", _conds) ->
	           (match best_source_ctor_match_for_terms
	                    (split_top_level_terms_preserve_eps
	                       (strip_wrapping_parens lhs |> String.trim)) with
	            | Some (info, _args) when info.source_ctor_arity > 0 ->
	                Some (source_ctor_op_key (source_ctor_op_name info |> String.trim) info.source_ctor_arity)
	            | _ ->
	           (match source_ctor_lhs_head_arity lhs with
	            | Some (name, arity) when arity > 0 ->
	                let op_name =
	                  match Hashtbl.find_opt source_ctor_by_name name with
	                  | Some info -> source_ctor_op_name info
                  | None -> name
                in
	                Some (source_ctor_op_key (op_name |> String.trim) arity)
	            | _ -> None))
	       | _ -> None)
  |> List.filter (fun op -> op <> "" && op <> "eps")
  |> List.fold_left (fun acc op -> SSet.add op acc) SSet.empty

let jhs_op_decl_arity line =
  try
    let colon = String.index line ':' in
    let arrow =
      try Str.search_forward (Str.regexp "[ \t]+\\(~>\\|->\\)[ \t]+") line colon
      with Not_found -> String.length line
    in
    let sorts =
      String.sub line (colon + 1) (arrow - colon - 1)
      |> String.trim
      |> Str.split (Str.regexp "[ \t\n\r]+")
      |> List.filter (fun s -> s <> "")
    in
    List.length sorts
  with Not_found -> 0

let jhs_partialize_decl_line partial_ops line =
  let s = String.trim line in
  if starts_with s "op " then
    match (try Some (String.index line ':') with Not_found -> None) with
    | Some colon ->
        let before_colon = String.sub line 0 colon in
        let op_part =
          let prefix = "op " in
          let trimmed = String.trim before_colon in
          if starts_with trimmed prefix then
            String.sub trimmed (String.length prefix)
              (String.length trimmed - String.length prefix)
            |> String.trim
          else ""
        in
        let key = source_ctor_op_key op_part (jhs_op_decl_arity line) in
        if SSet.mem key partial_ops
           && contains_substring line " -> SpectecTerminal"
        then
          Str.replace_first
            (Str.regexp_string " -> SpectecTerminal")
            " ~> SpectecTerminal"
            line
        else line
    | None -> line
  else line

let partialize_cmb_constructor_ops_in_output text =
  let lines = String.split_on_char '\n' text in
  let memberships = collect_membership_statements lines in
  let partial_ops =
    memberships
    |> List.filter_map (fun stmt ->
         match parse_category_membership_statement stmt with
         | Some ("cmb", lhs, "SpectecTerminal", _conds) ->
             (match best_source_ctor_match_for_terms
                      (split_top_level_terms_preserve_eps
                         (strip_wrapping_parens lhs |> String.trim)) with
              | Some (info, _args) when info.source_ctor_arity > 0 ->
                  Some (source_ctor_op_key (source_ctor_op_name info |> String.trim) info.source_ctor_arity)
              | _ ->
                  (match source_ctor_lhs_head_arity lhs with
                   | Some (name, arity) when arity > 0 ->
                       let op_name =
                         match Hashtbl.find_opt source_ctor_by_name name with
                         | Some info -> source_ctor_op_name info
                         | None -> name
                       in
                       Some (source_ctor_op_key (op_name |> String.trim) arity)
                   | _ -> None))
         | _ -> None)
    |> List.fold_left (fun acc op -> if op = "" then acc else SSet.add op acc) SSet.empty
  in
  lines
  |> List.map (jhs_partialize_decl_line partial_ops)
  |> String.concat "\n"

let jhs_extra_type_constructor_decls declared_heads used_type_terms =
  used_type_terms
  |> SSet.elements
  |> List.map jhs_type_head
  |> List.map ensure_spectec_type_term
  |> List.filter (fun h ->
       h <> ""
       && h <> "list"
       && h <> "SpectecTerminal"
       && not (SSet.mem h declared_heads))
  |> List.sort_uniq String.compare
  |> List.map (fun h -> Printf.sprintf "  op %s : -> SpectecType ." h)

let rewrite_sort_tokens text =
  let len = String.length text in
  let buf = Buffer.create len in
  let is_sort_char = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' -> true
    | _ -> false
  in
  let rec loop i =
    if i >= len then ()
    else if is_sort_char text.[i] then
      let j = ref i in
      while !j < len && is_sort_char text.[!j] do
        incr j
      done;
      let tok = String.sub text i (!j - i) in
      let tok' =
        match jhs_carrier_sort_for_source_sort tok with
        | Some carrier -> carrier
        | None -> tok
      in
      Buffer.add_string buf tok';
      loop !j
    else begin
      Buffer.add_char buf text.[i];
      loop (i + 1)
    end
  in
  loop 0;
  Buffer.contents buf

let jhs_rewrite_decl_line line =
  let s = String.trim line in
  if starts_with s "sorts " && ends_with s "." then
    let payload =
      String.sub s 6 (String.length s - 7)
      |> Str.split (Str.regexp "[ \t]+")
      |> List.filter (fun sort -> jhs_carrier_sort_for_source_sort sort = None)
    in
    (match payload with
     | [] -> None
     | sorts -> Some ("  sorts " ^ String.concat " " sorts ^ " ."))
  else if starts_with s "sort " && ends_with s "." then
    let sort = String.sub s 5 (String.length s - 7) |> String.trim in
    if jhs_carrier_sort_for_source_sort sort <> None then None else Some line
  else if starts_with s "subsort " then
    let re =
      Str.regexp
        "^subsort[ \t]+\\([A-Za-z][A-Za-z0-9_-]*\\)[ \t]+<[ \t]+\\([A-Za-z][A-Za-z0-9_-]*\\)[ \t]*\\."
    in
    if Str.string_match re s 0 then
      let child = Str.matched_group 1 s in
      let parent = Str.matched_group 2 s in
      if jhs_carrier_sort_for_source_sort child <> None
         || jhs_carrier_sort_for_source_sort parent <> None
      then None
      else Some line
    else Some line
  else if starts_with s "op " || starts_with s "ops "
          || starts_with s "var " || starts_with s "vars " then
    (match String.index_opt line ':' with
     | None -> Some line
     | Some idx ->
         let prefix = String.sub line 0 (idx + 1) in
         let suffix =
           String.sub line (idx + 1) (String.length line - idx - 1)
         in
         Some (prefix ^ rewrite_sort_tokens suffix))
  else Some line

let expand_finite_membership_statements memberships =
  let direct_terms : (string, SSet.t) Hashtbl.t = Hashtbl.create 256 in
  let add_term sort term =
    let old =
      match Hashtbl.find_opt direct_terms sort with
      | Some terms -> terms
      | None -> SSet.empty
    in
    Hashtbl.replace direct_terms sort (SSet.add term old)
  in
  memberships
  |> List.iter (fun stmt ->
       match parse_category_membership_statement stmt with
       | Some ("mb", lhs, sort, []) -> add_term sort lhs
       | _ -> ());
  let rec finite_terms seen sort =
    if SSet.mem sort seen then SSet.empty
    else
      let seen = SSet.add sort seen in
      let direct =
        match Hashtbl.find_opt direct_terms sort with
        | Some terms -> terms
        | None -> SSet.empty
      in
      let child_terms =
        Hashtbl.fold
          (fun child parents acc ->
            if SSet.mem sort parents then
              SSet.union acc (finite_terms seen child)
            else acc)
          source_category_subsort_edges
          SSet.empty
      in
      SSet.union direct child_terms
  in
  let finite_terms_list sort =
    finite_terms SSet.empty sort |> SSet.elements
  in
  let guard_of_cond cond =
    let cond =
      strip_trailing_eq_true (strip_wrapping_parens cond |> String.trim)
    in
    match split_once_re (Str.regexp "[ \t]+:[ \t]+") cond with
    | Some (term, sort) ->
        let term = strip_wrapping_parens term |> String.trim in
        let sort = String.trim sort in
        if is_plain_var_like term then Some (term, sort) else None
    | None -> None
  in
  let cartesian lists =
    List.fold_right
      (fun xs acc ->
        List.concat_map (fun x -> List.map (fun ys -> x :: ys) acc) xs)
      lists
      [[]]
  in
  let apply_assignments text assignments =
    List.fold_left
      (fun acc (v, term) -> replace_maude_var_token v term acc)
      text assignments
  in
  let ground_membership_status cond =
    let cond =
      strip_trailing_eq_true (strip_wrapping_parens cond |> String.trim)
    in
    match split_once_re (Str.regexp "[ \t]+:[ \t]+") cond with
    | Some (term, sort) ->
        let term = strip_wrapping_parens term |> String.trim in
        let sort = String.trim sort in
        if SSet.mem term (finite_terms SSet.empty sort) then Some true
        else None
    | None -> eval_ground_bool_expr cond
  in
  let simplify conds =
    let rec go acc = function
      | [] -> Some (List.rev acc)
      | cond :: rest ->
          (match ground_membership_status cond with
           | Some true -> go acc rest
           | Some false -> None
           | None -> go (cond :: acc) rest)
    in
    go [] conds
  in
  memberships
  |> List.concat_map (fun stmt ->
       match parse_category_membership_statement stmt with
       | Some ("cmb", lhs, sort, conds) ->
           let guard_specs =
             conds
             |> List.filter_map guard_of_cond
             |> List.filter_map (fun (v, guard_sort) ->
                  let terms = finite_terms_list guard_sort in
                  if terms = [] || List.length terms > 512 then None
                  else Some (v, guard_sort, terms))
           in
           if guard_specs = [] then [stmt]
           else
             let choices =
               guard_specs
               |> List.map (fun (v, _sort, terms) ->
                    terms |> List.map (fun term -> (v, term)))
               |> cartesian
             in
             choices
             |> List.filter_map (fun assignments ->
                  let removable =
                    guard_specs
                    |> List.map (fun (v, guard_sort, _) ->
                         Printf.sprintf "%s : %s" v guard_sort)
                  in
                  let lhs' = apply_assignments lhs assignments in
                  let conds' =
                    conds
                    |> List.filter (fun c ->
                         not (List.mem (String.trim c) removable))
                    |> List.map (fun c -> apply_assignments c assignments)
                  in
                  match simplify conds' with
                  | None -> None
                  | Some conds'' ->
                      let rhs = cond_join conds'' in
                      Some
                        (Printf.sprintf "  %s ( %s ) : %s%s ."
                           (if rhs = "" then "mb" else "cmb")
                           lhs' sort
                           (if rhs = "" then "" else "\n   if " ^ rhs)))
       | _ -> [stmt])
  |> List.sort_uniq String.compare

let last_non_space_index s =
  let rec loop i =
    if i < 0 then None
    else
      match s.[i] with
      | ' ' | '\t' | '\n' | '\r' -> loop (i - 1)
      | _ -> Some i
  in
  loop (String.length s - 1)

let last_condition_if stmt =
  let re = Str.regexp "[ \t\n\r]+if[ \t\n\r]+" in
  let rec loop start last =
    try
      let pos = Str.search_forward re stmt start in
      let matched = Str.matched_string stmt in
      loop (pos + 1) (Some (pos, pos + String.length matched))
    with Not_found -> last
  in
  loop 0 None

let split_condition_conjuncts cond =
  Str.split (Str.regexp_string "/\\") cond
  |> List.map String.trim
  |> List.filter (fun s -> s <> "")

let condition_has_numeric_signal cond =
  contains_substring cond "^"
  || contains_substring cond " quo "
  || contains_substring cond " rem "
  || contains_substring cond "$raw-"
  || Str.string_match
       (Str.regexp ".*\\(^\\|[^A-Za-z0-9_'$-]\\)[0-9]+\\([^A-Za-z0-9_'$-]\\|$\\).*")
       cond 0

let condition_has_top_level_comparator cond =
  let len = String.length cond in
  let rec loop i depth =
    if i >= len then false
    else
      let depth =
        match cond.[i] with
        | '(' -> depth + 1
        | ')' -> max 0 (depth - 1)
        | _ -> depth
      in
      if depth = 0 then
        let has_next c = i + 1 < len && cond.[i + 1] = c in
        match cond.[i] with
        | '<' | '>' -> true
        | '=' when has_next '=' -> true
        | '=' when has_next '/' -> true
        | _ -> loop (i + 1) depth
      else loop (i + 1) depth
  in
  loop 0 0

let condition_is_fully_parenthesized cond =
  let cond = String.trim cond in
  let stripped = safe_strip_source_syntax_wrapping_parens cond in
  stripped <> cond

let parenthesize_numeric_condition_conjunct cond =
  let cond = String.trim cond in
  if cond = ""
     || not (condition_has_numeric_signal cond)
     || not (condition_has_top_level_comparator cond)
  then cond
  else if condition_is_fully_parenthesized cond then cond
  else "( " ^ cond ^ " )"

let parenthesize_numeric_condition_conjuncts_in_statement stmt =
  match last_condition_if stmt, last_non_space_index stmt with
  | Some (if_pos, cond_start), Some dot_pos
      when dot_pos > cond_start && stmt.[dot_pos] = '.' ->
      let first_nonempty =
        stmt
        |> String.split_on_char '\n'
        |> List.map String.trim
        |> List.find_opt (fun line -> line <> "")
      in
      let is_source_syntax_head =
        match first_nonempty with
        | Some head ->
            starts_with head "ceq typecheck("
            || starts_with head "cmb "
        | None -> false
      in
      if not is_source_syntax_head
      then stmt
      else
      let prefix = String.sub stmt 0 if_pos in
      let cond = String.sub stmt cond_start (dot_pos - cond_start) in
      let suffix = String.sub stmt dot_pos (String.length stmt - dot_pos) in
      let conds = split_condition_conjuncts cond in
      let wrapped = List.map parenthesize_numeric_condition_conjunct conds in
      if wrapped = conds then stmt
      else
        let suffix =
          if starts_with (String.trim suffix) "." then " " ^ String.trim suffix
          else suffix
        in
        prefix ^ "\n      if " ^ String.concat " /\\ " wrapped ^ suffix
  | _ -> stmt

let parenthesize_numeric_condition_conjuncts_in_output text =
  let flush current acc =
    match current with
    | [] -> acc
    | _ ->
        let stmt = List.rev current |> String.concat "\n" in
        parenthesize_numeric_condition_conjuncts_in_statement stmt :: acc
  in
  let rec loop current acc = function
    | [] -> List.rev (flush current acc)
    | line :: rest ->
        let current' = line :: current in
        if ends_with (String.trim line) "." then
          loop [] (flush current' acc) rest
        else
          loop current' acc rest
  in
  text
  |> String.split_on_char '\n'
  |> loop [] []
  |> String.concat "\n"

let strip_source_sort_guards_from_statement stmt =
  match last_condition_if stmt, last_non_space_index stmt with
  | Some (if_pos, cond_start), Some dot_pos
      when dot_pos > cond_start && stmt.[dot_pos] = '.' ->
      let prefix = String.sub stmt 0 if_pos in
      let cond = String.sub stmt cond_start (dot_pos - cond_start) in
      let suffix = String.sub stmt dot_pos (String.length stmt - dot_pos) in
      let suffix =
        if starts_with suffix "." then " " ^ suffix else suffix
      in
      let conds = split_condition_conjuncts cond in
      let kept =
        conds
        |> List.filter (fun cond ->
             match parse_sort_guard_condition cond with
             | Some (_term, sort) ->
                 jhs_carrier_sort_for_source_sort sort = None
             | None -> true)
      in
      if List.length kept = List.length conds then stmt
      else
        let kept_cond =
          match kept with
          | [] -> ""
          | _ -> String.concat " /\\ " kept
        in
        if kept_cond = "" then
          let trimmed_prefix = String.trim prefix in
          if starts_with trimmed_prefix "cmb " then
            let prefix =
              Str.replace_first (Str.regexp "cmb") "mb" prefix
            in
            prefix ^ suffix
          else if starts_with trimmed_prefix "ceq " then
            let prefix =
              Str.replace_first (Str.regexp "ceq") "eq" prefix
            in
            prefix ^ suffix
          else
            prefix ^ suffix
        else
          let kept_cond =
            kept_cond
          in
          prefix ^ "\n      if " ^ kept_cond ^ suffix
  | _ -> stmt

let strip_source_sort_guards_from_output text =
  text
  |> String.split_on_char '\n'
  |> List.map strip_source_sort_guards_from_statement
  |> String.concat "\n"

let strip_redundant_builtin_sort_guards_from_statement stmt =
  let first_nonempty =
    stmt
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.find_opt (fun line -> line <> "")
  in
  let is_source_syntax_head head =
    starts_with head "ceq typecheck("
    || starts_with head "cmb "
  in
  match first_nonempty with
  | Some head when is_source_syntax_head head ->
      (match last_condition_if stmt, last_non_space_index stmt with
       | Some (if_pos, cond_start), Some dot_pos
           when dot_pos > cond_start && stmt.[dot_pos] = '.' ->
           let prefix = String.sub stmt 0 if_pos in
           let cond = String.sub stmt cond_start (dot_pos - cond_start) in
           let suffix = String.sub stmt dot_pos (String.length stmt - dot_pos) in
           let conds = split_condition_conjuncts cond in
           let kept =
             conds
             |> List.filter (fun cond ->
                  match parse_sort_guard_condition cond with
                  | Some (term, ("Nat" | "Int" | "Bool")) ->
                      let term = strip_wrapping_parens term |> String.trim in
                      not (is_plain_var_like term)
                  | _ -> true)
           in
           if List.length kept = List.length conds then stmt
           else
             let suffix =
               if starts_with (String.trim suffix) "." then " " ^ String.trim suffix
               else suffix
             in
             (match kept with
              | [] -> prefix ^ suffix
              | _ -> prefix ^ "\n      if " ^ String.concat " /\\ " kept ^ suffix)
       | _ -> stmt)
  | _ -> stmt

let strip_redundant_builtin_sort_guards_from_output text =
  let flush current acc =
    match current with
    | [] -> acc
    | _ ->
        let stmt = List.rev current |> String.concat "\n" in
        strip_redundant_builtin_sort_guards_from_statement stmt :: acc
  in
  let rec loop current acc = function
    | [] -> List.rev (flush current acc)
    | line :: rest ->
        let current' = line :: current in
        if ends_with (String.trim line) "." then
          loop [] (flush current' acc) rest
        else
          loop current' acc rest
  in
  text
  |> String.split_on_char '\n'
  |> loop [] []
  |> String.concat "\n"

let strip_condition_eq_true_from_statement stmt =
  match last_condition_if stmt, last_non_space_index stmt with
  | Some (if_pos, cond_start), Some dot_pos
      when dot_pos > cond_start && stmt.[dot_pos] = '.' ->
      let prefix = String.sub stmt 0 if_pos in
      let cond = String.sub stmt cond_start (dot_pos - cond_start) in
      let suffix = String.sub stmt dot_pos (String.length stmt - dot_pos) in
      let conds = split_condition_conjuncts cond in
      let stripped =
        conds
        |> List.map (fun c ->
             strip_trailing_eq_true (strip_wrapping_parens c |> String.trim))
        |> List.filter (fun c -> c <> "")
      in
      if stripped = conds then stmt
      else
        let suffix =
          if starts_with (String.trim suffix) "." then " " ^ String.trim suffix
          else suffix
        in
        (match stripped with
         | [] -> prefix ^ suffix
         | _ -> prefix ^ "\n      if " ^ String.concat " /\\ " stripped ^ suffix)
  | _ -> stmt

let strip_condition_eq_true_from_output text =
  text
  |> String.split_on_char '\n'
  |> List.map strip_condition_eq_true_from_statement
  |> String.concat "\n"

let strip_typecheck_guards_from_statement stmt =
  if not drop_runtime_typecheck_guards then stmt
  else if contains_substring stmt "$is-spectec-" && contains_substring stmt "-seq" then stmt
  else if contains_substring stmt "$is-spectec-" && contains_substring stmt "(W)" then stmt
  else
    match last_condition_if stmt, last_non_space_index stmt with
    | Some (if_pos, cond_start), Some dot_pos
      when dot_pos > cond_start && stmt.[dot_pos] = '.' ->
        let prefix = String.sub stmt 0 if_pos in
        let cond =
          String.sub stmt cond_start (dot_pos - cond_start)
        in
        let suffix =
          String.sub stmt dot_pos (String.length stmt - dot_pos)
        in
        let suffix =
          if starts_with suffix "." then " " ^ suffix else suffix
        in
        let conds = split_condition_conjuncts cond in
        let kept = drop_typecheck_guard_conds conds in
        if List.length kept = List.length conds then stmt
        else
        (match kept with
         | [] ->
             let trimmed_prefix = String.trim prefix in
             if starts_with trimmed_prefix "cmb " then
               let prefix =
                 Str.replace_first (Str.regexp "cmb") "mb" prefix
               in
               prefix ^ suffix
             else if starts_with trimmed_prefix "ceq " then
               let prefix =
                 Str.replace_first (Str.regexp "ceq") "eq" prefix
               in
               prefix ^ suffix
             else
               prefix ^ suffix
         | _ ->
             let kept_cond = String.concat " /\\ " kept in
             prefix ^ "\n      if " ^ kept_cond ^ suffix)
    | _ -> stmt

let strip_typecheck_guards_from_output text =
  if not drop_runtime_typecheck_guards then text
  else
    text
    |> String.split_on_char '\n'
    |> List.map strip_typecheck_guards_from_statement
    |> String.concat "\n"

let normalize_numeric_sequence_comparator_condition cond =
  let numeric_comparator fn =
    List.mem fn ["_<_"; "_<=_"; "_>_"; "_>=_"; "<"; "<="; ">"; ">="]
  in
  let numeric_context_text text =
    let core = strip_wrapping_parens text |> String.trim in
    is_raw_numeric_text core || contains_substring core "$raw-lit"
  in
  let sequence_var_text text =
    let core = strip_wrapping_parens text |> String.trim in
    if not (is_plain_var_like core) then None
    else
      match source_sort_of_plain_text_var core with
      | Some sort
          when sort = "SpectecTerminals"
            || ends_with sort "Seq"
            || Hashtbl.mem source_var_seq_elem_sorts core ->
          Some core
      | _ when Hashtbl.mem source_var_seq_elem_sorts core -> Some core
      | _ -> None
  in
  let normalize_arg other arg =
    match sequence_var_text arg with
    | Some var when numeric_context_text other ->
        format_call "$raw-lit" [format_call "index" [var; "0"]]
    | _ -> arg
  in
  let normalize_core core =
    let core = strip_trailing_eq_true (strip_wrapping_parens core |> String.trim) in
    match parse_call_text core with
    | Some (fn, [a; b]) when numeric_comparator fn ->
        let a' = normalize_arg b a in
        let b' = normalize_arg a b in
        let text' = format_call fn [a'; b'] in
        if text' = core then None else Some text'
    | _ -> None
  in
  match parse_sort_guard_condition cond with
  | Some (term, sort) ->
      (match normalize_core term with
       | Some term' -> Printf.sprintf "%s : %s" term' sort
       | None -> cond)
  | None ->
      (match normalize_core cond with
       | Some cond' -> cond'
       | None -> cond)

let normalize_numeric_sequence_comparators_in_statement stmt =
  match last_condition_if stmt, last_non_space_index stmt with
  | Some (if_pos, cond_start), Some dot_pos
      when dot_pos > cond_start && stmt.[dot_pos] = '.' ->
      let prefix = String.sub stmt 0 if_pos in
      let cond = String.sub stmt cond_start (dot_pos - cond_start) in
      let suffix = String.sub stmt dot_pos (String.length stmt - dot_pos) in
      let conds = split_condition_conjuncts cond in
      let normalized =
        List.map normalize_numeric_sequence_comparator_condition conds
      in
      if normalized = conds then stmt
      else
        let kept =
          normalized
          |> List.map String.trim
          |> List.filter (fun c -> c <> "")
        in
        let suffix =
          if starts_with (String.trim suffix) "." then " " ^ String.trim suffix
          else suffix
        in
        if kept = [] then prefix ^ suffix
        else prefix ^ "\n      if " ^ String.concat " /\\ " kept ^ suffix
  | _ -> stmt

let normalize_numeric_sequence_comparators_in_output text =
  text
  |> String.split_on_char '\n'
  |> List.map normalize_numeric_sequence_comparators_in_statement
  |> String.concat "\n"

let is_source_syntax_typecheck_statement_head line =
  let trimmed = String.trim line in
  starts_with trimmed "ceq typecheck("
  || starts_with trimmed "cmb "

let pretty_source_syntax_conditions_in_statement stmt =
  match last_condition_if stmt, last_non_space_index stmt with
  | Some (if_pos, cond_start), Some dot_pos
      when dot_pos > cond_start && stmt.[dot_pos] = '.' ->
      let first_nonempty =
        stmt
        |> String.split_on_char '\n'
        |> List.map String.trim
        |> List.find_opt (fun line -> line <> "")
      in
      (match first_nonempty with
       | Some head when is_source_syntax_typecheck_statement_head head ->
           let prefix = String.sub stmt 0 if_pos in
           let cond = String.sub stmt cond_start (dot_pos - cond_start) in
           let suffix = String.sub stmt dot_pos (String.length stmt - dot_pos) in
           let conds =
             split_condition_conjuncts cond
             |> List.concat_map pretty_source_syntax_condition_conjuncts
             |> List.map String.trim
             |> List.filter (fun c -> c <> "")
           in
           let suffix =
             if starts_with (String.trim suffix) "." then " " ^ String.trim suffix
             else suffix
           in
           if conds = [] then prefix ^ suffix
           else prefix ^ "\n      if " ^ String.concat " /\\ " conds ^ suffix
       | _ -> stmt)
  | _ -> stmt

let pretty_source_syntax_conditions_in_output text =
  let statement_ends line =
    let trimmed = String.trim line in
    String.length trimmed > 0
    && trimmed.[String.length trimmed - 1] = '.'
  in
  let process target lines =
    let stmt = String.concat "\n" lines in
    if target then pretty_source_syntax_conditions_in_statement stmt else stmt
  in
  let rec loop acc current target = function
    | [] ->
        let acc =
          match current with
          | [] -> acc
          | _ -> process target (List.rev current) :: acc
        in
        List.rev acc |> String.concat "\n"
    | line :: rest ->
        (match current with
         | [] ->
             if is_source_syntax_typecheck_statement_head line then
               if statement_ends line then
                 loop (process true [line] :: acc) [] false rest
               else
                 loop acc [line] true rest
             else
               loop (line :: acc) [] false rest
         | _ ->
             let current = line :: current in
             if statement_ends line then
               loop (process target (List.rev current) :: acc) [] false rest
             else
               loop acc current target rest)
  in
  loop [] [] false (String.split_on_char '\n' text)

let leading_whitespace_len s =
  let len = String.length s in
  let rec loop i =
    if i < len && (s.[i] = ' ' || s.[i] = '\t') then loop (i + 1) else i
  in
  loop 0

let rewrite_empty_condition_statement_head line =
  let trimmed = String.trim line in
  let replacement =
    if starts_with trimmed "cmb " then Some ("cmb", "mb")
    else if starts_with trimmed "ceq " then Some ("ceq", "eq")
    else if starts_with trimmed "crl " then Some ("crl", "rl")
    else None
  in
  match replacement with
  | None -> line
  | Some (old_head, new_head) ->
      let indent_len = leading_whitespace_len line in
      let indent = String.sub line 0 indent_len in
      let rest = String.sub line indent_len (String.length line - indent_len) in
      if starts_with rest old_head then
        indent ^ new_head
        ^ String.sub rest (String.length old_head)
            (String.length rest - String.length old_head)
      else line

let normalize_empty_condition_statements text =
  let is_conditional_head_text stmt =
    let first_nonempty =
      stmt
      |> String.split_on_char '\n'
      |> List.map String.trim
      |> List.find_opt (fun line -> line <> "")
    in
    match first_nonempty with
    | Some line ->
        starts_with line "cmb "
        || starts_with line "ceq "
        || starts_with line "crl "
    | None -> false
  in
  let has_if_condition stmt =
    let re = Str.regexp "\\(^\\|[ \t\n\r]\\)if\\([ \t\n\r]\\|$\\)" in
    try ignore (Str.search_forward re stmt 0); true with Not_found -> false
  in
  let rewrite_stmt stmt =
    if is_conditional_head_text stmt && not (has_if_condition stmt) then
      let rec rewrite_first_nonempty acc = function
        | [] -> List.rev acc
        | line :: rest when String.trim line = "" ->
            rewrite_first_nonempty (line :: acc) rest
        | line :: rest ->
            List.rev_append acc
              (rewrite_empty_condition_statement_head line :: rest)
      in
      stmt
      |> String.split_on_char '\n'
      |> rewrite_first_nonempty []
      |> String.concat "\n"
    else stmt
  in
  let flush current acc =
    match current with
    | [] -> acc
    | _ ->
        let stmt = List.rev current |> String.concat "\n" in
        rewrite_stmt stmt :: acc
  in
  let rec loop current acc = function
    | [] -> List.rev (flush current acc)
    | line :: rest ->
        let current' = line :: current in
        if ends_with (String.trim line) "." then
          loop [] (flush current' acc) rest
        else
          loop current' acc rest
  in
  text
  |> String.split_on_char '\n'
  |> loop [] []
  |> String.concat "\n"

let trim_trailing_whitespace_from_output text =
  let trim_right_spaces line =
    let rec loop i =
      if i < 0 then ""
      else
        match line.[i] with
        | ' ' | '\t' -> loop (i - 1)
        | _ -> String.sub line 0 (i + 1)
    in
    loop (String.length line - 1)
  in
  text
  |> String.split_on_char '\n'
  |> List.map trim_right_spaces
  |> String.concat "\n"

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

let normalize_unbound_free_list_star_maps lhs rhs =
  let lhs_vars = extract_vars_from_maude lhs in
  let candidate_sequence_var scalar =
    let suffixes = [scalar ^ "S"; scalar ^ "SQ"; scalar ^ "QS"] in
    lhs_vars
    |> List.find_opt (fun v -> List.exists (ends_with v) suffixes)
  in
  let re =
    Str.regexp
      "\\$free-list[ \t\n\r]*([ \t\n\r]*\\$\\(free-[A-Za-z0-9-]+\\)[ \t\n\r]*([ \t\n\r]*\\([A-Z][A-Z0-9-]*\\)[ \t\n\r]*)[ \t\n\r]*)"
  in
  Str.global_substitute re
    (fun s ->
      let fn_stem = Str.matched_group 1 s in
      let scalar = Str.matched_group 2 s in
      match candidate_sequence_var scalar with
      | Some seq_var when not (List.mem scalar lhs_vars) ->
          let helper =
            register_map_call_helper ("$" ^ fn_stem) 1 0 ["SpectecTerminals"]
          in
          Printf.sprintf "$free-list(%s(%s))" helper seq_var
      | _ -> Str.matched_string s)
    rhs

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
	                 let is_syntax_category_arg =
	                   i = 0 &&
	                   (fn = "$concat" || fn = "$concatn" || fn = "$concatopt")
	                 in
	                 let other_vars =
	                   arg_ts
	                   |> List.mapi (fun j (u : texpr) -> if i = j then [] else u.vars)
	                   |> List.flatten
	                 in
	                 if is_syntax_category_arg || t.vars = [] then None
	                 else if List.for_all
	                           (fun v ->
	                             not (List.mem v rhs_t.vars)
	                             && not (List.mem v other_vars))
	                           t.vars
	                 then Some i
	                 else None)
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
                  { text = format_source_def_call inv_fn (List.map (fun (t : texpr) -> t.text) inv_args);
                    vars = uniq_vars (List.concat_map (fun (t : texpr) -> t.vars) inv_args) }
                in
                Some (PremEq { lhs = target; rhs = inv_rhs; bool_t })
            | _ -> None))
  | _ -> None

let is_keywordish_token v =
  source_protected_nonvariable_token v

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
  && not (is_source_ctor_var_token v || is_source_ctor_name v)

let vars_of_texpr (t : texpr) =
  let extracted = extract_vars_from_maude t.text |> List.filter is_bindable_name in
  uniq_vars (t.vars @ extracted)

let is_scheduler_known bound v =
  SSet.mem v bound
  || is_generated_free_const_name v
  || SSet.mem v !listn_index_vars

let subset_bound bound vars =
  List.for_all (is_scheduler_known bound) vars

let clos_wrapper_inner_target bound (target : texpr) =
  match parse_call_text target.text with
  | Some (fn, [_ctx; inner]) when starts_with fn "$clos-" ->
      let inner_text = strip_wrapping_parens inner |> String.trim in
      let inner_vars = extract_vars_from_maude inner_text in
      if subset_bound bound inner_vars then
        Some { text = inner_text; vars = inner_vars }
      else None
  | _ -> None

let split_unbound bound vars =
  let unbound = List.filter (fun v -> not (is_scheduler_known bound v)) vars in
  let bound_vs = List.filter (is_scheduler_known bound) vars in
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

type expr_map_tuple_occurrence = {
  expr_tuple_helper : expr_map_helper;
  expr_tuple_args : string list;
}

let find_expr_map_tuple_occurrence text =
  let text = strip_wrapping_parens text |> String.trim in
  match parse_call_text text with
  | Some (name, args) ->
      !expr_map_helpers
      |> List.find_opt (fun h ->
           h.expr_map_helper_name = name
           && expr_map_tuple_body_order h <> None
           && List.length args = List.length h.expr_map_seq_vars
           && List.for_all is_plain_var_like args)
      |> Option.map (fun h ->
           { expr_tuple_helper = h;
             expr_tuple_args =
               List.map (fun arg -> strip_wrapping_parens arg |> String.trim) args })
  | None -> None

let inverse_concat_payload text =
  match parse_call_text text with
  | Some (name, args)
      when (name = "$inv-concat" || name = "$inv-concatn") && args <> [] ->
      Some (List.hd (List.rev args))
  | _ -> None

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
    Hashtbl.replace source_var_sorts mapped_var "SpectecTerminals";
    let replaced_text =
      replace_span side_text occ.map_start occ.map_end_excl mapped_var
    in
    let replaced_t =
      { text = replaced_text;
        vars = extract_vars_from_maude replaced_text }
    in
    let seq_t = texpr_with_var occ.map_seq_var occ.map_seq_var in
    let unmap_t =
      let unmap_name = unmap_call_helper_name occ.map_helper.map_helper_name in
      mark_unmap_helper_used unmap_name;
      { text =
          Printf.sprintf "%s ( %s )"
            unmap_name
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

let star_ctor_unzip_prem_items (lhs : texpr) (rhs : texpr) =
  let make seq_text ctor args =
    if not (is_plain_var_like seq_text) then None
    else if not (List.for_all is_plain_var_like args) then None
    else
      let seq_var = strip_wrapping_parens seq_text |> String.trim in
      let arity = List.length args in
      register_star_ctor_unzip ctor arity;
      Some
        (args
         |> List.mapi (fun i arg ->
              let arg = strip_wrapping_parens arg |> String.trim in
              let lhs_t = texpr_with_var arg arg in
              let rhs_t =
                { text = Printf.sprintf "%s ( %s )"
                    (star_ctor_unzip_name ctor i) seq_var;
                  vars = [seq_var] }
              in
              PremEq {
                lhs = lhs_t;
                rhs = rhs_t;
                bool_t = {
                  text = Printf.sprintf "( %s == %s )" lhs_t.text rhs_t.text;
                  vars = uniq_vars (lhs_t.vars @ rhs_t.vars);
                };
              }))
  in
  match ctor_call_pattern lhs.text, ctor_call_pattern rhs.text with
  | Some (ctor, args), None -> make rhs.text ctor args
  | None, Some (ctor, args) -> make lhs.text ctor args
  | _ -> None

let opt_ctor_prem_items (lhs : texpr) (rhs : texpr) =
  let make seq_text ctor args =
    match args with
    | [arg] when is_plain_var_like seq_text && is_plain_var_like arg ->
        let seq_var = strip_wrapping_parens seq_text |> String.trim in
        let arg = strip_wrapping_parens arg |> String.trim in
        register_opt_ctor_helper ctor 1;
        let lhs_t = texpr_with_var seq_var seq_var in
        let rhs_t =
          { text = format_call (opt_prefix_name ctor) [arg];
            vars = [arg] }
        in
        Some [PremEq {
          lhs = lhs_t;
          rhs = rhs_t;
          bool_t = {
            text = Printf.sprintf "( %s == %s )" lhs_t.text rhs_t.text;
            vars = uniq_vars (lhs_t.vars @ rhs_t.vars);
          };
        }]
    | _ -> None
  in
  match ctor_call_pattern lhs.text, ctor_call_pattern rhs.text with
  | Some (ctor, args), None -> make rhs.text ctor args
  | None, Some (ctor, args) -> make lhs.text ctor args
  | _ -> None

let record_sort_hint_of_exp vm e =
  match (unwrap_exp_for_meta e).it with
  | VarE id ->
      let t =
        translate_var TermCtx id.it vm (source_expected_sort_of_typ e.note vm)
      in
      (match source_sort_of_plain_texpr_var t with
       | Some sort when
           List.exists (fun info -> info.rec_sort = sort) !source_record_infos ->
           Some sort
       | _ -> None)
  | _ -> None

let translate_equality_side_with_record_hint vm side_e other_e =
  let hint =
    match (unwrap_exp_for_meta side_e).it with
    | StrE _ -> record_sort_hint_of_exp vm other_e
    | _ -> None
  in
  translate_exp_with_record_sort_hint TermCtx side_e vm hint

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
	      let lhs = translate_equality_side_with_record_hint vm lhs_e rhs_e in
	      let rhs = translate_equality_side_with_record_hint vm rhs_e lhs_e in
	      (* For bool_t fallback, keep BoolCtx for ordinary equalities, but
	         unwrap object-level numeric/category literals when the equality is
	         really a numeric guard such as l == 0 or c == 0. *)
	      let lhs_raw = raw_literal_texpr_for_numeric_context lhs in
	      let rhs_raw = raw_literal_texpr_for_numeric_context rhs in
	      let bool_t =
	        if lhs_raw.text <> lhs.text || rhs_raw.text <> rhs.text then
	          { text = Printf.sprintf "( %s == %s )" lhs_raw.text rhs_raw.text;
	            vars = uniq_vars (lhs_raw.vars @ rhs_raw.vars) }
	        else
	          let lhs_b = translate_exp BoolCtx lhs_e vm in
	          let rhs_b = translate_exp BoolCtx rhs_e vm in
	          { text = Printf.sprintf "( %s == %s )" lhs_b.text rhs_b.text;
	            vars = uniq_vars (lhs_b.vars @ rhs_b.vars) }
	      in
      let source_numeric_target (t : texpr) =
        let core = strip_wrapping_parens t.text |> String.trim in
        is_plain_var_like core
        &&
        match source_sort_of_plain_text_var core with
        | Some ("Nat" | "Int") -> true
        | Some sort -> literal_wrapper_for_sort sort <> None
        | None -> false
      in
      let numeric_call_text (t : texpr) =
        match parse_call_text t.text with
        | Some (fn, _) -> List.mem fn ["_+_"; "_-_"; "_*_"; "_quo_"; "_rem_"; "_^_"]
        | None -> false
      in
      let lhs_for_bind, rhs_for_bind =
        if source_numeric_target lhs then
          (lhs, wrap_numeric_texpr_for_source_target lhs rhs)
        else if source_numeric_target rhs then
          (wrap_numeric_texpr_for_source_target rhs lhs, rhs)
        else if numeric_call_text rhs then
          (lhs, raw_literal_texpr_for_numeric_context rhs)
        else (lhs, rhs)
      in
      let iter_kind e =
        match e.it with
        | IterE (_, (iter, _)) -> Some iter
        | _ -> None
      in
      let iter_items =
        match iter_kind lhs_e, iter_kind rhs_e with
        | Some (List | List1 | ListN _), _
        | _, Some (List | List1 | ListN _) ->
            (match star_prefix_prem_items lhs rhs with
             | Some items -> Some items
             | None -> star_ctor_unzip_prem_items lhs rhs)
        | Some Opt, _
        | _, Some Opt -> opt_ctor_prem_items lhs rhs
        | _ -> None
      in
      (match iter_items with
       | Some items -> items
       | None ->
      (match inverse_prem_item_of_equality vm lhs_e rhs_e bool_t with
       | Some item -> [item]
       | None ->
           (match map_call_prem_items lhs rhs with
            | Some items -> items
            | None -> [PremEq { lhs = lhs_for_bind; rhs = rhs_for_bind; bool_t }])))
  | BinE (`EquivOp, _, lhs_e, rhs_e) ->
      let lhs = translate_equality_side_with_record_hint vm lhs_e rhs_e in
      let rhs = translate_equality_side_with_record_hint vm rhs_e lhs_e in
      let lhs_b = translate_exp BoolCtx lhs_e vm in
      let rhs_b = translate_exp BoolCtx rhs_e vm in
      let bool_t = { text = Printf.sprintf "( %s == %s )" lhs_b.text rhs_b.text;
                     vars = uniq_vars (lhs_b.vars @ rhs_b.vars) } in
      let iter_kind e =
        match e.it with
        | IterE (_, (iter, _)) -> Some iter
        | _ -> None
      in
      let iter_items =
        match iter_kind lhs_e, iter_kind rhs_e with
        | Some (List | List1 | ListN _), _
        | _, Some (List | List1 | ListN _) ->
            (match star_prefix_prem_items lhs rhs with
             | Some items -> Some items
             | None -> star_ctor_unzip_prem_items lhs rhs)
        | Some Opt, _
        | _, Some Opt -> opt_ctor_prem_items lhs rhs
        | _ -> None
      in
      (match iter_items with
       | Some items -> items
       | None ->
      (match inverse_prem_item_of_equality vm lhs_e rhs_e bool_t with
       | Some item -> [item]
       | None ->
           (match map_call_prem_items lhs rhs with
            | Some items -> items
            | None -> [PremEq { lhs; rhs; bool_t }])))
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
    Some (PremRel {
      rel_name = helper_name;
      args = arg_ts;
      text = call;
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
  | RulePr (id, _, _) when is_skipped_relation_name id.it ->
      []
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
      if sanitize rel_id.it = "Expand" then
        prem_items_of_prem vm { inner with it = RulePr (rel_id, mixop, e) }
      else if is_skipped_relation_name rel_id.it then []
      else
      (match iter_rule_prem_item vm rel_id e xes with
       | Some item -> [item]
       | None -> prem_items_of_prem vm { inner with it = RulePr (rel_id, mixop, e) })
  | IterPr (inner, ((ListN (_, Some index_id), _))) ->
      record_listn_index_var vm index_id;
      prem_items_of_prem vm inner
      |> List.concat_map (function
          | PremEq ({ lhs; rhs; _ } as eq) ->
              (match star_prefix_prem_items lhs rhs with
               | Some items -> items
               | None ->
                   (match star_ctor_unzip_prem_items lhs rhs with
                    | Some items -> items
                    | None -> [PremEq eq]))
          | item -> [item])
  | IterPr (inner, ((List | List1 | ListN _), _)) ->
      prem_items_of_prem vm inner
      |> List.concat_map (function
          | PremEq ({ lhs; rhs; _ } as eq) ->
              (match star_prefix_prem_items lhs rhs with
               | Some items -> items
               | None ->
                   (match star_ctor_unzip_prem_items lhs rhs with
                    | Some items -> items
                    | None -> [PremEq eq]))
          | item -> [item])
  | IterPr (inner, (Opt, _)) ->
      prem_items_of_prem vm inner
      |> List.concat_map (function
          | PremEq ({ lhs; rhs; _ } as eq) ->
              (match opt_ctor_prem_items lhs rhs with
               | Some items -> items
               | None -> [PremEq eq])
          | item -> [item])
  | LetPr (e1, e2, _) ->
      let lhs = translate_equality_side_with_record_hint vm e1 e2 in
      let rhs = translate_equality_side_with_record_hint vm e2 e1 in
      let bool_t =
        { text = Printf.sprintf "( %s == %s )" lhs.text rhs.text;
          vars = uniq_vars (lhs.vars @ rhs.vars) }
      in
      let iter_kind e =
        match e.it with
        | IterE (_, (iter, _)) -> Some iter
        | _ -> None
      in
      let iter_items =
        match iter_kind e1, iter_kind e2 with
        | Some (List | List1 | ListN _), _
        | _, Some (List | List1 | ListN _) ->
            (match star_prefix_prem_items lhs rhs with
             | Some items -> Some items
             | None -> star_ctor_unzip_prem_items lhs rhs)
        | Some Opt, _
        | _, Some Opt -> opt_ctor_prem_items lhs rhs
        | _ -> None
      in
      (match iter_items with
       | Some items -> items
       | None ->
      (match map_call_prem_items lhs rhs with
       | Some items -> items
       | None -> [PremEq { lhs; rhs; bool_t }]))
  | IfPr e ->
      let items = collect_prem_items_of_exp vm e in
      if items <> [] then items
      else
        (match decompose_eq_expr e with
         | Some (e1, e2) ->
             let lhs = translate_equality_side_with_record_hint vm e1 e2 in
             let rhs = translate_equality_side_with_record_hint vm e2 e1 in
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
      let opt_prefix_match =
        if is_plain_var_like lhs.text then
          match opt_prefix_call_pattern rhs.text with
          | Some (prefix_name, arg)
              when is_plain_var_like arg ->
              let seq_var = strip_wrapping_parens lhs.text |> String.trim in
              let arg_var = strip_wrapping_parens arg |> String.trim in
              (match List.find_opt
                       (fun h -> opt_prefix_name h.opt_ctor = prefix_name)
                       !opt_ctor_helpers
               with
               | Some h when SSet.mem seq_var bound
                             && not (SSet.mem arg_var bound) ->
                   let rhs_text =
                     format_call (opt_unzip_name h.opt_ctor 0) [seq_var]
                   in
                   Some (`Match,
                    { text = Printf.sprintf "%s := %s" arg_var rhs_text;
                      vars = uniq_vars [arg_var; seq_var];
                      binds = [arg_var] },
                    true)
               | Some _ when not (SSet.mem seq_var bound)
                             && SSet.mem arg_var bound ->
                   Some (`Match,
                    { text = Printf.sprintf "%s := %s" seq_var rhs.text;
                      vars = uniq_vars [seq_var; arg_var];
                      binds = [seq_var] },
                    true)
               | _ -> None)
          | _ -> None
        else None
      in
      let whole_unary_map_occ text =
        let trimmed = String.trim text in
        match find_unary_map_call_occurrence trimmed with
        | Some occ when occ.map_start = 0
                        && occ.map_end_excl = String.length trimmed ->
            Some occ
        | _ -> None
      in
      let map_inverse_match =
        match whole_unary_map_occ lhs.text, whole_unary_map_occ rhs.text with
        | Some occ, None
            when subset_bound bound rhs_vars
                 && not (SSet.mem occ.map_seq_var bound) ->
            let rhs_text =
              let unmap_name =
                unmap_call_helper_name occ.map_helper.map_helper_name
              in
              mark_unmap_helper_used unmap_name;
              Printf.sprintf "%s ( %s )" unmap_name rhs.text
            in
            Some (`Match,
             { text = Printf.sprintf "%s := %s" occ.map_seq_var rhs_text;
               vars = uniq_vars (occ.map_seq_var :: rhs_vars);
               binds = [occ.map_seq_var] },
             true)
        | None, Some occ
            when subset_bound bound lhs_vars
                 && not (SSet.mem occ.map_seq_var bound) ->
            let rhs_text =
              let unmap_name =
                unmap_call_helper_name occ.map_helper.map_helper_name
              in
              mark_unmap_helper_used unmap_name;
              Printf.sprintf "%s ( %s )" unmap_name lhs.text
            in
            Some (`Match,
             { text = Printf.sprintf "%s := %s" occ.map_seq_var rhs_text;
               vars = uniq_vars (occ.map_seq_var :: lhs_vars);
               binds = [occ.map_seq_var] },
             true)
        | _ -> None
      in
      let expr_tuple_inverse_match =
        let make occ (other_t : texpr) other_vars =
          match inverse_concat_payload other_t.text with
          | Some payload
              when subset_bound bound other_vars
                   && List.for_all
                        (fun v -> not (SSet.mem v bound))
                        occ.expr_tuple_args ->
              let helper_name = occ.expr_tuple_helper.expr_map_helper_name in
              let tuple_name = expr_map_tuple_helper_name helper_name in
              let unmap_name = unmap_call_helper_name helper_name in
              mark_unmap_helper_used unmap_name;
              Some (`Match,
               { text =
                   Printf.sprintf "%s ( %s ) := %s ( %s )"
                     tuple_name
                     (String.concat " , " occ.expr_tuple_args)
                     unmap_name
                     payload;
                 vars =
                   uniq_vars
                     (occ.expr_tuple_args @ extract_vars_from_maude payload);
                 binds = occ.expr_tuple_args },
               true)
          | _ -> None
        in
        match find_expr_map_tuple_occurrence lhs.text,
              find_expr_map_tuple_occurrence rhs.text with
        | Some occ, None -> make occ rhs rhs_vars
        | None, Some occ -> make occ lhs lhs_vars
        | _ -> None
      in
      match opt_prefix_match with
      | Some sched -> sched
      | None ->
      (match map_inverse_match with
       | Some sched -> sched
       | None ->
      (match expr_tuple_inverse_match with
       | Some sched -> sched
       | None when lhs_fresh <> [] && subset_bound bound rhs_vars ->
        (`Match,
         { text = Printf.sprintf "%s := %s" lhs.text rhs.text;
           vars = uniq_vars (lhs_vars @ rhs_vars);
           binds = lhs_fresh },
         true)
      | None when rhs_fresh <> [] && subset_bound bound lhs_vars ->
        (`Match,
         { text = Printf.sprintf "%s := %s" rhs.text lhs.text;
           vars = uniq_vars (lhs_vars @ rhs_vars);
           binds = rhs_fresh },
         true)
      | None when lhs_nonempty && lhs_has_no_bound && subset_bound bound rhs_vars ->
        (`Match,
         { text = Printf.sprintf "%s := %s" lhs.text rhs.text;
           vars = uniq_vars (lhs_vars @ rhs_vars);
           binds = lhs_vars },
         true)
      | None when rhs_nonempty && rhs_has_no_bound && subset_bound bound lhs_vars ->
        (`Match,
         { text = Printf.sprintf "%s := %s" rhs.text lhs.text;
           vars = uniq_vars (lhs_vars @ rhs_vars);
           binds = rhs_vars },
         true)
      | None when is_expanddt_term_text lhs.text && subset_bound bound lhs_vars ->
        (`Match,
         { text = Printf.sprintf "%s := %s" rhs.text lhs.text;
           vars = uniq_vars (lhs_vars @ rhs_vars);
           binds = rhs_fresh },
         true)
      | None when is_expanddt_term_text rhs.text && subset_bound bound rhs_vars ->
        (`Match,
         { text = Printf.sprintf "%s := %s" lhs.text rhs.text;
           vars = uniq_vars (lhs_vars @ rhs_vars);
           binds = lhs_fresh },
         true)
      | None ->
        let vars = vars_of_texpr bool_t in
        let ready = subset_bound bound vars in
        (`Bool, { text = bool_t.text; vars; binds = [] }, ready)))

let infer_sched_for_rel bound rel_name (args : texpr list) =
  if is_skipped_relation_name rel_name || not (has_infer_rel_source rel_name) then None
  else
    let rel_low = String.lowercase_ascii (sanitize rel_name) in
    let relation_first_arg_is_context_like =
      ends_with rel_low "-ok"
      || ends_with rel_low "-oks"
      || ends_with rel_low "-sub"
      || ends_with rel_low "-subs"
    in
    let inferable_arg_index i =
      not (relation_first_arg_is_context_like && i = 0)
    in
    let arg_vars_for_infer (arg : texpr) =
      uniq_vars (vars_of_texpr arg @ extract_vars_from_maude arg.text)
    in
    let arg_infos =
      args
      |> List.mapi (fun i arg ->
          let arg_vars = arg_vars_for_infer arg in
          let fresh = List.filter (fun v -> not (SSet.mem v bound)) arg_vars in
          (i, arg, fresh, arg_vars))
    in
    let multi_fresh : (int * texpr * string list) list =
      arg_infos
      |> List.filter_map (fun (i, arg, fresh, _arg_vars) ->
          if fresh = [] || not (inferable_arg_index i) then None
          else Some (i, arg, fresh))
    in
    let multi_sched : prem_sched option =
      if List.length multi_fresh <= 1 || not (ends_with rel_low "-oks") then None
      else
        let fresh_indices = List.map (fun (i, _, _) -> i) multi_fresh in
        let other_vars =
          arg_infos
          |> List.filter_map (fun (i, _arg, _fresh, arg_vars) ->
              if List.mem i fresh_indices then None else Some arg_vars)
          |> List.flatten
          |> uniq_vars
        in
        if not (subset_bound bound other_vars) then None
        else
          let helper_name =
            register_result_rel_helper rel_name (List.length args) fresh_indices
          in
          let helper_args =
            args
            |> List.mapi (fun j (a : texpr) ->
                if List.mem j fresh_indices then None else Some a.text)
            |> List.filter_map (fun x -> x)
            |> String.concat " , "
          in
          let rhs =
            if helper_args = "" then helper_name
            else Printf.sprintf "%s ( %s )" helper_name helper_args
          in
          let outputs =
            multi_fresh
            |> List.map (fun (_i, (arg : texpr), _fresh) -> arg.text)
            |> String.concat " "
          in
          let binds =
            multi_fresh
            |> List.concat_map (fun (_i, _arg, fresh) -> fresh)
            |> uniq_vars
          in
          let vars = uniq_vars (binds @ extract_vars_from_maude rhs) in
          Some { text = Printf.sprintf "%s => %s" rhs outputs;
                 vars;
                 binds }
    in
    match multi_sched with
    | Some sched -> Some sched
    | None ->
    let candidates =
      arg_infos
      |> List.map (fun (i, arg, fresh, _arg_vars) ->
          let other_vars =
            args
            |> List.mapi (fun j a -> if i = j then [] else arg_vars_for_infer a)
            |> List.flatten
            |> uniq_vars
          in
          (i, arg, fresh, other_vars))
      |> List.filter (fun (_i, _arg, fresh, other_vars) ->
          fresh <> [] && inferable_arg_index _i && subset_bound bound other_vars)
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
    let bound_set = SSet.of_list bound_vars in
    let rhs_known rhs =
      extract_vars_from_maude rhs |> subset_bound bound_set
    in
    match split_top_level_eqeq p.text with
    | Some (lhs, rhs)
        when is_plain_var_like lhs
             && not (List.mem lhs lhs_pattern_vars)
             && not (List.mem lhs bound_vars)
             && not (List.mem lhs (extract_vars_from_maude rhs))
             && rhs_known rhs ->
        { text = Printf.sprintf "%s := %s" lhs rhs;
          vars = uniq_vars (lhs :: extract_vars_from_maude rhs);
          binds = [lhs] }
    | Some (lhs, rhs)
        when is_plain_var_like rhs
             && not (List.mem rhs lhs_pattern_vars)
             && not (List.mem rhs bound_vars)
             && not (starts_with lhs "$map-")
             && not (List.mem rhs (extract_vars_from_maude lhs))
             && rhs_known lhs ->
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
        let fresh_t = { text = fresh; vars = [fresh] } in
        let matched_t = { text = matched; vars = [source_var] } in
        let bool_t =
          { text = Printf.sprintf "( %s == %s )" fresh matched;
            vars = [fresh; source_var] }
        in
        items := PremEq { lhs = fresh_t; rhs = matched_t; bool_t } :: !items;
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

let find_balanced_call_args text open_pos =
  let len = String.length text in
  let rec loop i depth =
    if i >= len then None
    else
      match text.[i] with
      | '(' -> loop (i + 1) (depth + 1)
      | ')' ->
          if depth = 0 then
            Some (String.sub text (open_pos + 1) (i - open_pos - 1), i + 1)
          else
            loop (i + 1) (depth - 1)
      | _ -> loop (i + 1) depth
  in
  loop (open_pos + 1) 0

let hoist_lhs_computed_calls prefix (lhs_t : texpr) =
  (* Maude matches rule heads by pattern.  A source expression such as
     `$minat(at1, at2)` in a relation conclusion is a computed value, not a
     constructor pattern, so we bind a fresh pattern variable and check the
     computation in the condition.  This is generic over source def-calls whose
     generated Maude name starts with `$`; it is not tied to a Wasm rule name. *)
  let is_call_name_char = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' | '?' -> true
    | _ -> false
  in
  let find_next pos =
    let rec loop i =
      if i >= String.length lhs_t.text then None
      else if lhs_t.text.[i] = '$' then
        let j = ref (i + 1) in
        while !j < String.length lhs_t.text
              && is_call_name_char lhs_t.text.[!j] do
          incr j
        done;
        if !j = i + 1 then loop (i + 1)
        else
          let name = String.sub lhs_t.text i (!j - i) in
          let tag =
            (if starts_with name "$" then
               String.sub name 1 (String.length name - 1)
             else
               name)
            |> sanitize
            |> String.uppercase_ascii
          in
          Some (i, name, tag)
      else if i + 5 <= String.length lhs_t.text
              && String.sub lhs_t.text i 5 = "index"
              && (i = 0 || not (is_call_name_char lhs_t.text.[i - 1]))
              && (i + 5 = String.length lhs_t.text
                  || not (is_call_name_char lhs_t.text.[i + 5]))
      then
        Some (i, "index", "INDEX")
      else loop (i + 1)
    in
    loop pos
  in
  let len = String.length lhs_t.text in
  let b = Buffer.create len in
  let items = ref [] in
  let rec skip_spaces i =
    if i < len && (lhs_t.text.[i] = ' ' || lhs_t.text.[i] = '\t') then
      skip_spaces (i + 1)
    else
      i
  in
  let rec loop pos idx =
    match find_next pos with
    | None ->
        Buffer.add_substring b lhs_t.text pos (len - pos);
        idx
    | Some (start, name, tag) ->
        let after_name = start + String.length name |> skip_spaces in
        if after_name >= len || lhs_t.text.[after_name] <> '(' then begin
          Buffer.add_substring b lhs_t.text pos (start + String.length name - pos);
          loop (start + String.length name) idx
        end else
          match find_balanced_call_args lhs_t.text after_name with
          | None ->
              Buffer.add_substring b lhs_t.text pos (start + String.length name - pos);
              loop (start + String.length name) idx
          | Some (_args_text, stop) ->
              let matched = String.sub lhs_t.text start (stop - start) |> String.trim in
              let matched_vars =
                extract_vars_from_maude matched
                |> List.filter is_bindable_name
                |> uniq_vars
              in
              let outside_text =
                (String.sub lhs_t.text 0 start)
                ^ (String.sub lhs_t.text stop (len - stop))
              in
              let outside_vars =
                extract_vars_from_maude outside_text
                |> List.filter is_bindable_name
                |> SSet.of_list
              in
              let should_hoist =
                name = "index"
                || List.for_all (fun v -> SSet.mem v outside_vars) matched_vars
              in
              if should_hoist then begin
                let fresh = Printf.sprintf "%s-%s%d" prefix tag idx in
                Buffer.add_substring b lhs_t.text pos (start - pos);
                Buffer.add_string b fresh;
                let fresh_t = { text = fresh; vars = [fresh] } in
                let matched_t = { text = matched; vars = matched_vars } in
                let bool_t =
                  { text = Printf.sprintf "( %s == %s )" fresh matched;
                    vars = fresh :: matched_vars }
                in
                items := PremEq { lhs = fresh_t; rhs = matched_t; bool_t } :: !items;
                loop stop (idx + 1)
              end else begin
                Buffer.add_substring b lhs_t.text pos (stop - pos);
                loop stop idx
              end
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

let hoist_lhs_unary_map_calls prefix (lhs_t : texpr) =
  let b = Buffer.create (String.length lhs_t.text) in
  let items = ref [] in
  let pairs = ref [] in
  let rec loop idx text =
    match find_unary_map_call_occurrence text with
    | None ->
        Buffer.add_string b text;
        idx
    | Some occ ->
        let fresh = Printf.sprintf "%s-MAP%d" prefix idx in
        let before = String.sub text 0 occ.map_start in
        let after =
          String.sub text occ.map_end_excl
            (String.length text - occ.map_end_excl)
        in
        Buffer.add_string b before;
        Buffer.add_string b fresh;
        let seq_var = occ.map_seq_var in
        pairs := (fresh, seq_var) :: !pairs;
        let unmap_t =
          Printf.sprintf "%s ( %s )"
            (unmap_call_helper_name occ.map_helper.map_helper_name)
            fresh
        in
        items := PremMatch {
          lhs = texpr_with_var seq_var seq_var;
          rhs = { text = unmap_t; vars = [fresh] };
          binds = [seq_var];
        } :: !items;
        items := PremBool {
          text = Printf.sprintf "( %s ( %s ) == %s )"
            occ.map_helper.map_helper_name seq_var fresh;
          vars = [seq_var; fresh];
        } :: !items;
        loop (idx + 1) after
  in
  let _ = loop 0 lhs_t.text in
  if !items = [] then (lhs_t, [], [])
  else
    let text = Buffer.contents b in
    let vars =
      extract_vars_from_maude text
      |> List.filter is_bindable_name
      |> uniq_vars
    in
    ({ text; vars }, List.rev !items, List.rev !pairs)

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

let replace_maude_vars_with_eps vars text =
  List.fold_left (fun acc v -> replace_maude_var acc v "eps") text vars

let cond_mentions_any_var vars cond =
  List.exists (fun v -> maude_var_occurs cond v) vars

let optional_binder_vars binders vm =
  List.filter_map (fun b -> match b.it with
    | ExpB (v_id, t) ->
        (match t.it with
         | IterT (_, Opt) -> List.assoc_opt v_id.it vm
         | _ -> None)
    | _ -> None
  ) binders
  |> List.sort_uniq String.compare

let optional_binder_empty_terms binders vm =
  List.filter_map (fun b -> match b.it with
    | ExpB (v_id, t) ->
        (match t.it with
         | IterT (_, Opt) ->
             (match List.assoc_opt v_id.it vm with
              | Some mv -> Some (mv, optional_empty_term_for_typ t vm)
              | None -> None)
         | _ -> None)
    | _ -> None
  ) binders
  |> List.sort_uniq compare

let star_binder_vars binders vm =
  List.filter_map (fun b -> match b.it with
    | ExpB (v_id, t) ->
        (match t.it with
         | IterT (_, List) -> List.assoc_opt v_id.it vm
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

let apply_optional_empty_subst opt_subst text =
  List.fold_left
    (fun acc (opt_v, empty_term) -> replace_maude_var acc opt_v empty_term)
    text opt_subst

let optional_empty_substs binders vm lhs_texts =
  let opt_substs =
    optional_binder_empty_terms binders vm
    |> List.filter (fun (opt_v, _) ->
        List.exists (fun s -> maude_var_occurs s opt_v) lhs_texts)
  in
  nonempty_subsets opt_substs

let cond_mentions_optional opt_subst cond =
  List.exists (fun (opt_v, _) -> maude_var_occurs cond opt_v) opt_subst

let typed_index_last_arg_vars cond =
  try
    let comma = String.rindex cond ',' in
    let tail =
      String.sub cond (comma + 1) (String.length cond - comma - 1)
      |> Str.global_replace (Str.regexp "[). \t\n\r]+$") ""
    in
    extract_vars_from_maude tail |> List.filter is_bindable_name
  with Not_found -> []

let typed_index_empty_substs binders vm conds =
  let star_vars = star_binder_vars binders vm in
  conds
  |> List.filter_map (fun cond ->
      let cond = String.trim cond in
      if not (contains_substring cond "$typed-index") then None
      else
        let index_vars = typed_index_last_arg_vars cond in
        match
          List.find_opt
            (fun v ->
              List.mem v star_vars || Hashtbl.mem source_var_seq_elem_sorts v)
            index_vars
        with
        | None -> None
        | Some index_v ->
            (try
               let pos = Str.search_forward (Str.regexp_string ":=") cond 0 in
               let lhs = String.sub cond 0 pos in
               let rhs =
                 String.sub cond (pos + 2) (String.length cond - pos - 2)
                 |> String.trim
               in
               if not (starts_with rhs "$typed-index") then None else
               let lhs_vars =
                 extract_vars_from_maude lhs
                 |> List.filter is_bindable_name
               in
               Some (cond, List.sort_uniq String.compare (index_v :: lhs_vars))
             with Not_found -> None))
  |> List.sort_uniq compare

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

let optional_literal_terms_in text =
  SSet.elements !optional_literal_terms
  |> List.filter (fun term ->
      let term = String.trim term in
      term <> "" && contains_substring text term)
  |> List.sort_uniq String.compare

let replace_optional_literal_terms terms text =
  List.fold_left (fun acc term ->
    Str.global_replace (Str.regexp_string term) "eps" acc)
    text terms

let sequence_prefix_lhs_progress_conds lhs_ts =
  lhs_ts
  |> List.filter_map (fun (t : texpr) ->
      let core = strip_wrapping_parens t.text |> String.trim in
      match Str.split (Str.regexp "[ \t\n\r]+") core with
      | [head; _rest]
          when is_plain_var_like head
	               && Hashtbl.mem source_var_seq_elem_sorts head ->
	          Some (Printf.sprintf "_=/=_ ( %s, eps )" head)
      | _ -> None)
  |> List.sort_uniq String.compare

let source_pattern_typecheck_guard raw term =
  let term = strip_wrapping_parens term |> String.trim in
  if not (is_plain_var_like term) then None
  else
    let candidates =
      [raw; strip_iter_suffix raw; strip_source_index_suffix raw;
       raw |> strip_iter_suffix |> strip_source_index_suffix]
      |> List.map sort_of_type_name
      |> List.sort_uniq String.compare
    in
    candidates
    |> List.find_map (fun sort ->
        match source_type_term_for_sort sort with
        | Some type_term when jhs_carrier_sort_for_source_sort sort <> None ->
            Some (Printf.sprintf "typecheck(%s, %s) = true" term type_term)
        | _ -> None)

let lhs_pattern_typecheck_conds lhs_args vm =
  let rec of_exp (e : exp) =
    match (unwrap_exp_for_source_sort e).it with
    | VarE id ->
        let t =
          translate_var TermCtx id.it vm (source_expected_sort_of_typ e.note vm)
        in
        (match source_pattern_typecheck_guard id.it t.text with
         | Some cond when List.mem t.text t.vars -> [cond]
         | _ -> [])
    | CaseE (_, inner) -> of_exp inner
    | TupE es | ListE es -> List.concat_map of_exp es
    | OptE (Some inner) | TheE inner | LiftE inner
    | CvtE (inner, _, _) | SubE (inner, _, _) | ProjE (inner, _)
    | UncaseE (inner, _) | DotE (inner, _) | LenE inner ->
        of_exp inner
    | IterE (inner, (iter, _)) ->
        let iter_conds =
          match iter with
          | ListN (count_e, _) -> of_exp count_e
          | List | List1 | Opt -> []
        in
        of_exp inner @ iter_conds
    | UnE (_, _, inner) -> of_exp inner
    | BinE (_, _, left, right) | CmpE (_, _, left, right)
    | CatE (left, right) | MemE (left, right) | IdxE (left, right)
    | CompE (left, right) ->
        of_exp left @ of_exp right
    | SliceE (base, first, last) | IfE (base, first, last) ->
        of_exp base @ of_exp first @ of_exp last
    | UpdE (base, _, value) | ExtE (base, _, value) ->
        of_exp base @ of_exp value
    | CallE (_, args) -> List.concat_map of_arg args
    | StrE fields -> fields |> List.concat_map (fun (_, e) -> of_exp e)
    | OptE None | BoolE _ | NumE _ | TextE _ -> []
  and of_typ (t : typ) term =
    match t.it with
    | VarT (id, []) ->
        (match source_pattern_typecheck_guard id.it term with
         | Some cond -> [cond]
         | None -> [])
    | VarT (_, args) -> List.concat_map of_arg args
    | IterT (inner, _) -> of_typ inner term
    | TupT fields ->
        fields |> List.concat_map (fun (field_e, field_t) ->
          of_exp field_e @ of_typ field_t term)
    | BoolT | NumT _ | TextT -> []
  and of_arg (a : arg) =
    match a.it with
    | ExpA e -> of_exp e
    | TypA t ->
        let tt = translate_arg a vm in
        if List.mem tt.text tt.vars then of_typ t tt.text else []
    | DefA _ | GramA _ -> []
  in
  lhs_args
  |> List.concat_map of_arg
  |> List.sort_uniq String.compare

let source_ctor_field_sorts ctor arity =
  match Hashtbl.find_opt ctor_arg_sort_hints ctor,
        Hashtbl.find_opt ctor_arg_membership_sort_hints ctor with
  | Some sorts, _ when List.length sorts = arity ->
      Some (List.map ctor_decl_arg_sort sorts)
  | _, Some sorts when List.length sorts = arity ->
      Some (List.map ctor_decl_arg_sort sorts)
  | _ ->
      !source_compound_cases
      |> List.find_map (fun c ->
           if c.compound_ctor = ctor && List.length c.compound_fields = arity then
             Some
               (c.compound_fields
                |> List.map (fun (_, field_typ) -> decd_sort_of_typ field_typ))
           else None)

let rhs_computed_sequence_ctor_arg_bindings prefix eq_idx (rhs_t : texpr) =
  let contains_generated_call text =
    contains_substring text "$"
  in
  match ctor_call_pattern rhs_t.text with
  | None -> (rhs_t, [], [])
  | Some (ctor, args) ->
      match source_ctor_field_sorts ctor (List.length args) with
      | None -> (rhs_t, [], [])
      | Some field_sorts ->
          let changed = ref false in
          let scheds = ref [] in
          let typed_vars = ref [] in
          let args' =
            List.mapi
              (fun i arg ->
                 let arg = strip_wrapping_parens arg |> String.trim in
                 let field_sort =
                   match List.nth_opt field_sorts i with
                   | Some s -> s
                   | None -> "SpectecTerminal"
                 in
                 if field_sort = "SpectecTerminals"
                    && contains_generated_call arg
                    && not (is_plain_var_like arg)
                 then begin
                   changed := true;
                   let fresh =
                     Printf.sprintf "%s-RHS%d-%d" prefix eq_idx i
                   in
                   let vars = uniq_vars (fresh :: extract_vars_from_maude arg) in
                   scheds := {
                     text = Printf.sprintf "%s := %s" fresh arg;
                     vars;
                     binds = [fresh];
                   } :: !scheds;
                   typed_vars := (fresh, field_sort) :: !typed_vars;
                   fresh
                 end else arg)
              args
          in
          if not !changed then (rhs_t, [], [])
          else
            ({ text = format_source_ctor_call ctor args';
               vars = uniq_vars (extract_vars_from_maude (format_source_ctor_call ctor args')) },
             List.rev !scheds,
             List.rev !typed_vars)

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
    | TypP _ -> failwith "TypP parameters are erased from Maude source defs"
    | DefP _ | GramP _ -> "SpectecTerminal"
  in
  let typ_param_positions =
    params
    |> List.mapi (fun i p -> match p.it with TypP _ -> Some i | _ -> None)
    |> List.filter_map (fun x -> x)
  in
  let value_params =
    params
    |> List.mapi (fun i p -> if List.mem i typ_param_positions then None else Some p)
    |> List.filter_map (fun x -> x)
  in
  let arg_sort_list = List.map param_sort value_params in
  let arg_sorts = String.concat " " arg_sort_list in
  let inferred_bool =
    List.exists (fun inst -> match inst.it with DefD (_, _, rhs, _) -> exp_is_boolish rhs) insts in
  let ret_sort =
    if inferred_bool || SSet.mem maude_fn ss.bool_calls
    then "Bool"
    else decd_sort_of_typ result_typ
  in
  (match semantic_result_sort_of_typ result_typ [] with
   | Some semantic_sort -> Hashtbl.replace source_def_return_sorts maude_fn semantic_sort
   | None -> Hashtbl.replace source_def_return_sorts maude_fn ret_sort);
  Hashtbl.replace source_def_return_optionals maude_fn
    (typ_is_optional_result result_typ);
  let rhs_ctx = if ret_sort = "Bool" then BoolCtx else TermCtx in
  let result_has_raw_payload =
    let rec by_typ t =
      match t.it with
      | NumT (`NatT | `IntT) -> true
      | IterT (inner, Opt) -> by_typ inner
      | _ -> false
    in
    let by_sort =
      match semantic_result_sort_of_typ result_typ [] with
      | Some sort -> sort_denotes_raw_numeric_payload sort
      | None -> false
    in
    let by_type_term =
      let type_term =
        (translate_typ_texpr result_typ []).text
        |> jhs_type_term_key
      in
      SSet.mem type_term !raw_payload_type_terms
    in
    by_typ result_typ || by_sort || by_type_term
  in

  let all_bound = ref [] and all_free = ref [] and all_typed = ref [] in
  all_typed :=
    value_params
    |> List.filter_map (fun p ->
        match p.it with
        | ExpP (id, _) -> Some (to_var_name id.it, param_sort p)
        | TypP _ -> None
        | DefP _ | GramP _ -> None);
  let relation_result_rewrite bound text =
    match split_once "=> valid" text with
    | None -> None
    | Some (call, rest) when String.trim rest = "" ->
        let call = strip_wrapping_parens call |> String.trim in
        (match parse_call_text call with
         | None -> None
         | Some (rel_name, arg_texts) ->
             let arg_vars =
               List.map extract_vars_from_maude arg_texts
             in
             let out_indices =
               arg_vars
               |> List.mapi (fun i vs ->
                   let fresh =
                     vs
                     |> List.filter (fun v ->
                         not (SSet.mem v bound) || is_generated_free_const_name v)
                   in
                   if fresh = [] then None else Some i)
               |> List.filter_map (fun x -> x)
             in
             if out_indices = [] then None
             else
               let helper =
                 register_result_rel_helper rel_name (List.length arg_texts) out_indices
               in
               let inputs =
                 arg_texts
                 |> List.mapi (fun i a -> if List.mem i out_indices then None else Some a)
                 |> List.filter_map (fun x -> x)
               in
               let outputs =
                 arg_texts
                 |> List.mapi (fun i a -> if List.mem i out_indices then Some a else None)
                 |> List.filter_map (fun x -> x)
               in
               let redex =
                 if inputs = [] then helper
                 else Printf.sprintf "%s ( %s )" helper (String.concat " , " inputs)
               in
               Some (redex, String.concat " " outputs))
    | _ -> None
  in
  let relation_has_fresh_result bound text =
    match split_once "=> valid" text with
    | None -> false
    | Some (call, rest) when String.trim rest = "" ->
        let call = strip_wrapping_parens call |> String.trim in
        (match parse_call_text call with
         | None -> false
         | Some (_rel_name, arg_texts) ->
             arg_texts
             |> List.exists (fun arg ->
                 extract_vars_from_maude arg
                 |> List.exists (fun v ->
                     not (SSet.mem v bound) || is_generated_free_const_name v)))
    | _ -> false
  in
  let scheduled_has_delayed_result lhs_seed prem_scheduled =
    prem_scheduled
    |> List.exists (fun (p : prem_sched) ->
        relation_has_fresh_result lhs_seed p.text
        ||
        match rewriteify_prem_text ~extra_heads:[maude_fn] p.text with
        | Some _ -> true
        | None -> contains_substring p.text "=>")
  in
  let eq_lines = List.mapi (fun eq_idx inst ->
    let (binders, lhs_args, rhs_exp, prem_list) =
      match inst.it with DefD (b, la, re, pl) -> (b, la, re, pl) in
    let vm = binder_to_var_map prefix eq_idx binders in
    reset_listn_pairs ();
    record_listn_pairs_from_binders binders vm;
    let bconds =
      binder_to_type_conds binders vm
      |> List.filter_map (fun (mv, cond) ->
          match jhs_condition_of_source_guard cond with
          | Some cond' -> Some (mv, cond')
          | None -> None)
    in
    let typed_vars = decd_binder_var_sorts binders vm in
    all_typed := List.sort_uniq compare (!all_typed @ typed_vars);

    let lhs_args =
      lhs_args
      |> List.mapi (fun i a -> if List.mem i typ_param_positions then None else Some a)
      |> List.filter_map (fun x -> x)
    in
    let lhs_ts_raw : texpr list = List.map (fun a -> translate_arg a vm) lhs_args in
    let lhs_ts : texpr list =
      List.mapi
        (fun i (t : texpr) ->
           match List.nth_opt arg_sort_list i with
           | Some seq_sort when ends_with seq_sort "Seq" ->
               { t with text = sequence_term_for_sort seq_sort t.text }
           | _ -> t)
        lhs_ts_raw
    in
    let lhs_strs : string list = List.map (fun (t : texpr) -> t.text) lhs_ts in
    let lhs_vars = List.concat_map (fun (t : texpr) -> t.vars) lhs_ts in

    let rhs_t0_raw =
      with_generic_const_payload_wrapping
        (fun () -> translate_exp_for_result_typ rhs_ctx result_typ rhs_exp vm)
    in
    let rhs_t0 = rhs_t0_raw in

    let prem_items = List.concat_map (prem_items_of_prem vm) prem_list in
    let prem_scheduled0 = schedule_prems (SSet.of_list lhs_vars) [] prem_items in
    let prem_binds0 = List.concat_map (fun (p : prem_sched) -> p.binds) prem_scheduled0 in
    let vm_vars = List.map snd vm in
    let preserve_rhs_witness_vars =
      scheduled_has_delayed_result (SSet.of_list lhs_vars) prem_scheduled0
    in
    let listn_count_vars =
      !g_listn_pairs
      |> List.map fst
      |> List.map (fun v -> strip_wrapping_parens v |> String.trim)
      |> List.sort_uniq String.compare
    in
    let rhs_only_vm_vars =
      vm_vars
      |> List.filter (fun v ->
           List.mem v rhs_t0.vars
           && not (List.mem v lhs_vars)
           && not (List.mem v prem_binds0)
           && not (List.mem v listn_count_vars))
      |> List.sort_uniq String.compare
    in
    let free_vm_renames =
      if preserve_rhs_witness_vars then []
      else List.map (fun v -> (v, "FREE-" ^ v)) rhs_only_vm_vars
    in
	    let rhs_t =
	      let t = rename_texpr_vars free_vm_renames rhs_t0 in
	      let t =
	        if result_has_raw_payload then raw_literal_texpr_for_numeric_context t
	        else t
	      in
	      if ends_with ret_sort "Seq" then
	        { t with text = sequence_term_for_sort ret_sort t.text }
	      else t
	    in
	    let prem_scheduled = List.map (rename_prem_sched_vars free_vm_renames) prem_scheduled0 in
	    let rhs_t, rhs_arg_scheds, rhs_arg_typed =
	      rhs_computed_sequence_ctor_arg_bindings prefix eq_idx rhs_t
	    in
	    all_typed := List.sort_uniq compare (!all_typed @ rhs_arg_typed);
	    let prem_strs = List.map (fun (p : prem_sched) -> p.text) prem_scheduled in
	    let rhs_arg_strs = List.map (fun (p : prem_sched) -> p.text) rhs_arg_scheds in
	    let rhs_arg_vars =
	      List.concat_map (fun (p : prem_sched) -> p.vars @ p.binds) rhs_arg_scheds
	    in
	    let prem_vars =
	      List.concat_map (fun (p : prem_sched) -> p.vars @ p.binds) prem_scheduled
	      @ rhs_arg_vars
	    in
	    let prem_binds = List.concat_map (fun (p : prem_sched) -> p.binds) prem_scheduled in
	    let optional_prem_drop_texts =
	      let item_drop_texts = function
	        | PremBool t -> [t.text]
	        | PremRel { text; _ } -> [text]
	        | PremMatch { lhs; rhs; _ } ->
	            [Printf.sprintf "%s := %s" lhs.text rhs.text]
	        | PremEq { bool_t; _ } -> [bool_t.text]
	      in
	      let rec collect (p : prem) =
	        match p.it with
	        | IterPr (inner, (Opt, _)) ->
	            prem_items_of_prem vm inner
	            |> List.concat_map item_drop_texts
	        | IterPr (inner, _) | NegPr inner -> collect inner
	        | _ -> []
	      in
	      prem_list
	      |> List.concat_map collect
	      |> List.map (fun text ->
	          (rename_texpr_vars free_vm_renames { text; vars = extract_vars_from_maude text }).text)
	      |> List.map (fun text -> String.trim text)
	      |> List.filter (fun text -> text <> "")
	      |> List.sort_uniq String.compare
	    in
	    let bool_safety_conds =
	      if rhs_ctx = BoolCtx then []
	      else bool_sort_safety_conds_exp rhs_exp vm
	    in

    let has_owise = List.exists (fun p -> match p.it with ElsePr -> true | _ -> false) prem_list in
    let all_collected = lhs_vars @ rhs_t.vars @ prem_vars in
    let all_texts = lhs_strs @ [rhs_t.text] @ prem_strs @ rhs_arg_strs in
    let lhs_bound_seed = List.sort_uniq String.compare (lhs_vars @ prem_binds) in
    let (bound, free, lhs_set) = partition_vars lhs_bound_seed all_texts all_collected in

    let filtered_bconds =
      bconds
      |> List.filter (fun (mv, cond) ->
          List.mem mv lhs_set
          && not (List.mem mv prem_binds)
          && (not (List.mem mv lhs_vars) || is_jhs_typecheck_guard cond))
      |> List.map snd
      |> rewrite_literal_payload_typecheck_conds
           (String.concat " " (lhs_strs @ [rhs_t.text] @ prem_strs)) in
    all_bound := List.sort_uniq String.compare (!all_bound @ bound);
    all_free := List.sort_uniq String.compare (!all_free @ free);

	    let listn_len_conds = listn_len_conditions lhs_set in
	    let lhs_pattern_conds =
	      lhs_pattern_typecheck_conds lhs_args vm
	      |> List.filter (fun cond ->
	          extract_vars_from_maude cond
	          |> List.for_all (fun v -> List.mem v lhs_set))
	      |> List.filter (fun cond -> not (List.mem cond filtered_bconds))
	    in
	    let final_tail_conds =
	      filtered_bconds @ lhs_pattern_conds @ listn_len_conds
	      @ rhs_arg_strs @ bool_safety_conds
	    in
	    let progress_conds = [] in
	    let format_eq lhs rhs conds =
	      let conds =
	        conds
	        |> List.map normalize_generated_free_const_assignment
	      in
	      let rhs = normalize_unbound_free_list_star_maps lhs rhs in
	      let cond = cond_join conds in
	      let cond_str = if cond = "" then "" else "\n      if " ^ cond in
	      Printf.sprintf "  %s %s = %s%s%s ."
        (if cond = "" then "eq" else "ceq")
        lhs rhs cond_str
        (if has_owise then " [owise]" else "")
    in
	    let continuation_lines =
      let parse_rewrite rw =
        match split_once "=>" rw with
        | Some (lhs, rhs) -> Some (String.trim lhs, String.trim rhs)
        | None -> None
      in
      let cond_for_sched bound (p : prem_sched) =
        if contains_substring p.text ":=" then prem_cond p.text
        else
          match split_once "==" (strip_wrapping_parens p.text |> String.trim) with
          | Some (lhs, rhs) ->
              let lhs = String.trim lhs in
              let rhs = String.trim rhs in
              let lhs_vars = extract_vars_from_maude lhs in
              let rhs_vars = extract_vars_from_maude rhs in
              let lhs_fresh =
                lhs_vars |> List.filter (fun v -> not (SSet.mem v bound))
              in
              let rhs_fresh =
                rhs_vars |> List.filter (fun v -> not (SSet.mem v bound))
              in
              if p.binds <> [] && List.for_all (fun v -> List.mem v lhs_vars) p.binds then
                Printf.sprintf "%s := %s" lhs rhs
              else if p.binds <> [] && List.for_all (fun v -> List.mem v rhs_vars) p.binds then
                Printf.sprintf "%s := %s" rhs lhs
              else if lhs_fresh <> [] && subset_bound bound rhs_vars then
                Printf.sprintf "%s := %s" lhs rhs
              else if rhs_fresh <> [] && subset_bound bound lhs_vars then
                Printf.sprintf "%s := %s" rhs lhs
              else prem_cond p.text
          | None -> prem_cond p.text
      in
	      let rec loop current_lhs bound pending_conds items =
	        match items with
	        | [] ->
	            [format_eq current_lhs rhs_t.text (pending_conds @ final_tail_conds)]
        | p :: rest ->
            let mirror_cond =
              if subset_bound bound p.vars then
                valid_mirror_call_of_rewrite_text p.text
              else None
            in
            (match mirror_cond with
             | Some cond ->
                 loop current_lhs bound (pending_conds @ [cond]) rest
             | None ->
                 let rewrite =
                   match relation_result_rewrite bound p.text with
                   | Some (redex, target) -> Some (redex, target)
                   | None ->
                       if contains_substring p.text "=>" then
                         parse_rewrite p.text
                       else
                         (match rewriteify_prem_text ~extra_heads:[maude_fn] p.text with
                          | Some rw -> parse_rewrite rw
                          | None -> None)
	                 in
	                 match rewrite with
	                 | Some (redex, target) ->
	                     let cond = Printf.sprintf "%s := %s" target redex in
	                     let target_vars = extract_vars_from_maude target in
	                     let bound' =
	                       List.fold_left (fun b v -> SSet.add v b) bound
	                         target_vars
	                     in
	                     loop current_lhs bound' (pending_conds @ [cond]) rest
                 | None ->
                     let cond = cond_for_sched bound p in
                     let cond_binds =
                       if p.binds <> [] then p.binds
                       else
                         match assignment_lhs_vars cond with
                         | Some (_lhs, _rhs, lhs_vars) -> lhs_vars
                         | None -> []
                     in
                     let bound' =
                       List.fold_left (fun b v -> SSet.add v b) bound cond_binds
	                     in
	                     loop current_lhs bound' (pending_conds @ [cond]) rest)
	      in
	      let base_lhs = format_call maude_fn lhs_strs in
	      let base_lines = loop base_lhs (SSet.of_list lhs_vars) progress_conds prem_scheduled in
	      let optional_empty_lines =
	        if optional_prem_drop_texts = []
	           || List.exists (fun (p : prem_sched) -> contains_substring p.text "=>") prem_scheduled
	        then []
	        else
	          let optional_substs =
	            optional_binder_empty_terms binders vm
	            |> List.filter (fun (opt_v, _) ->
	                optional_prem_drop_texts
	                |> List.exists (fun text -> maude_var_occurs text opt_v))
	            |> nonempty_subsets
	          in
	          optional_substs
	          |> List.mapi (fun i opt_vars ->
	              let should_drop cond =
	                let cond = String.trim cond in
	                cond_mentions_optional opt_vars cond
	                && List.exists
	                     (fun optional_text ->
	                        cond = optional_text || cond = prem_cond optional_text)
	                     optional_prem_drop_texts
	              in
	              let lhs = apply_optional_empty_subst opt_vars base_lhs in
	              let rhs = apply_optional_empty_subst opt_vars rhs_t.text in
	              let conds =
	                prem_scheduled
	                |> List.map (fun (p : prem_sched) -> p.text)
	                |> List.filter (fun cond -> not (should_drop cond))
	                |> List.map (apply_optional_empty_subst opt_vars)
	              in
	              let final_conds =
	                final_tail_conds
	                |> List.filter (fun cond -> not (should_drop cond))
	                |> List.map (apply_optional_empty_subst opt_vars)
	              in
	              "  --- optional-empty DefD variant "
	              ^ string_of_int i ^ "\n"
	              ^ format_eq lhs rhs (conds @ final_conds))
	      in
	      base_lines @ optional_empty_lines
	    in
    String.concat "\n" continuation_lines
  ) insts in

  let truly_free = List.filter (fun v -> not (List.mem v !all_bound)) !all_free in
  let saw_rewrite_clause =
    List.exists
      (fun line ->
        contains_substring line "\n    =>\n")
      eq_lines
  in
  if saw_rewrite_clause then
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

type execution_relation_kind =
  | ExecTermToTerm
  | ExecConfigToTerm
  | ExecConfigToConfig
  | ExecConfigClosure
  | ExecResultConfigToTerms

(** Attempt to decompose a config expression  z ; instr*  into its two parts.
    Detects the source  _;_  operator from the mixfix token, not from a
    generated CTOR name. *)
let try_decompose_config (e : exp) : (exp * exp) option =
  match e.it with
  | CaseE (mixop, inner) ->
      let arity = match inner.it with TupE es -> List.length es | _ -> 1 in
      if mixop_is_source_semicolon_pair mixop arity then
           (match inner.it with
            | TupE [z_e; instr_e] -> Some (z_e, instr_e)
            | _ -> None)
      else None
  | _ -> None

let relation_execution_kind mixop rules =
  if not (relation_mixop_is_execution mixop) then None
  else
    let first_conclusion =
      rules
      |> List.find_map (fun r ->
           match r.it with
           | RuleD (_, _, _, conclusion, _) -> Some conclusion)
    in
    match first_conclusion with
    | None -> None
    | Some conclusion ->
        (match conclusion.it with
         | TupE [lhs; rhs] ->
             (match try_decompose_config lhs, try_decompose_config rhs with
              | Some _, Some _ ->
                  if relation_mixop_is_star_execution mixop
                  then Some ExecConfigClosure
                  else Some ExecConfigToConfig
              | Some _, None -> Some ExecConfigToTerm
              | None, None -> Some ExecTermToTerm
              | None, Some _ -> None)
         | TupE [_z; _instrs; _zq; _vals] ->
             Some ExecResultConfigToTerms
         | _ -> None)

let collect_skipped_relation_names defs =
  skipped_relation_names := SSet.empty;
  let rec collect d =
    match d.it with
    | RecD ds -> List.iter collect ds
    | RelD (id, mixop, _, rules) ->
        if relation_execution_kind mixop rules = None then
          skipped_relation_names :=
            SSet.add (sanitize id.it) !skipped_relation_names
    | TypD _ | DecD _ | GramD _ | HintD _ -> ()
  in
  List.iter collect defs

let collect_native_sequence_sorts_from_source defs =
  let add_native_sequence_sort sort =
    register_native_sequence_sort sort
  in
  let rec collect_typ_sequences t =
    (match sequence_sort_of_typ t [] with
     | Some seq_sort when ends_with seq_sort "Seq" ->
         add_native_sequence_sort
           (String.sub seq_sort 0 (String.length seq_sort - 3))
     | _ -> ());
    match t.it with
    | VarT (_, args) ->
        List.iter collect_arg_sequences args
    | TupT fields ->
        List.iter (fun (_e, ft) -> collect_typ_sequences ft) fields
    | IterT (inner, _) ->
        collect_typ_sequences inner
    | BoolT | NumT _ | TextT -> ()
  and collect_arg_sequences a =
    match a.it with
    | TypA t -> collect_typ_sequences t
    | ExpA _ | DefA _ | GramA _ -> ()
  in
  let collect_deftyp_sequences deftyp =
    match deftyp.it with
    | AliasT t -> collect_typ_sequences t
    | StructT fields ->
        List.iter (fun (_atom, (_binders, ft, _prems), _hints) ->
          collect_typ_sequences ft
        ) fields
    | VariantT cases ->
        List.iter (fun (_mixop, (_binders, case_typ, _prems), _hints) ->
          collect_typ_sequences case_typ
        ) cases
  in
  let rec exp_var_names (e : exp) =
    match e.it with
    | VarE id -> [id.it]
    | TupE es | ListE es -> List.concat_map exp_var_names es
    | CaseE (_, inner) -> exp_var_names inner
    | IterE (inner, _) -> exp_var_names inner
    | CallE (_, args) ->
        args
        |> List.concat_map (fun a -> match a.it with ExpA e -> exp_var_names e | _ -> [])
    | IdxE (e1, e2) | CompE (e1, e2) | CatE (e1, e2) | MemE (e1, e2) ->
        exp_var_names e1 @ exp_var_names e2
    | SliceE (e1, e2, e3) -> exp_var_names e1 @ exp_var_names e2 @ exp_var_names e3
    | BinE (_, _, e1, e2) | CmpE (_, _, e1, e2) -> exp_var_names e1 @ exp_var_names e2
    | UnE (_, _, e) -> exp_var_names e
    | IfE (e1, e2, e3) -> exp_var_names e1 @ exp_var_names e2 @ exp_var_names e3
    | CvtE (e, _, _) | SubE (e, _, _) | ProjE (e, _)
    | UncaseE (e, _) | LenE e | OptE (Some e) | TheE e
    | LiftE e | DotE (e, _) -> exp_var_names e
    | UpdE (e1, _, e2) | ExtE (e1, _, e2) -> exp_var_names e1 @ exp_var_names e2
    | StrE fields ->
        fields |> List.concat_map (fun (_, e) -> exp_var_names e)
    | _ -> []
  in
  let sequence_binder_sorts binders =
    let strip_iter_marks s =
      let rec loop i =
        if i > 0 && s.[i - 1] = '*' then loop (i - 1) else i
      in
      let len = loop (String.length s) in
      String.sub s 0 len
    in
    binders
    |> List.filter_map (fun b ->
         match b.it with
         | ExpB (id, t) ->
             (match t.it with
              | IterT (inner, (List | List1 | ListN _)) ->
                  let sort_opt = simple_sort_of_typ inner [] in
                  Option.map (fun sort -> (strip_iter_marks id.it, sort)) sort_opt
              | _ -> None)
         | _ -> None)
  in
  let add_sorts_from_config binders cfg_exp =
    match try_decompose_config cfg_exp with
    | None -> ()
    | Some (_state, instrs) ->
        let used = exp_var_names instrs |> SSet.of_list in
        sequence_binder_sorts binders
        |> List.iter (fun (source_var, sort) ->
             if SSet.mem source_var used then
               add_native_sequence_sort sort)
  in
  let scan_rule (mixop : Xl.Mixop.mixop) (r : rule) =
    if relation_mixop_is_execution mixop then
      match r.it with
      | RuleD (_, binders, _, conclusion, _) ->
        let used = exp_var_names conclusion |> SSet.of_list in
        sequence_binder_sorts binders
        |> List.iter (fun (source_var, sort) ->
             if SSet.mem source_var used then
               add_native_sequence_sort sort);
        (match conclusion.it with
         | TupE [lhs; rhs] ->
             add_sorts_from_config binders lhs;
             add_sorts_from_config binders rhs
         | TupE [z; instrs; zq; vals] ->
             List.iter (add_sorts_from_config binders) [z; instrs; zq; vals]
         | _ -> ())
  in
  let rec scan_def d =
    match d.it with
    | RecD ds -> List.iter scan_def ds
    | TypD (_, _, insts) ->
        List.iter
          (fun inst ->
            let (InstD (_binders, _args, deftyp)) = inst.it in
            collect_deftyp_sequences deftyp)
          insts
    | RelD (_, mixop, _, rules) -> List.iter (scan_rule mixop) rules
    | _ -> ()
  in
  List.iter scan_def defs

(** Generate Maude step rewrite rules for Step-pure / Step-read / Step rules.
    Baseline pattern: translate the SpecTec conclusion directly:
      z ; lhs ~> z' ; rhs
    becomes
      step(< z | lhs >) => < z' | rhs >
    with no synthetic value-prefix or instruction-suffix context. Context
    closure is represented only by the SpecTec context rules themselves.
    Returns the generated Maude source fragment (declarations + rules). *)
let translate_step_reld exec_kind rel_name rules =
  let rel_prefix       = String.uppercase_ascii (sanitize rel_name) in
  let all_bound        = ref [] in
  let all_is_vars      = ref [] in
  let all_val_seq_vars = ref [] in
  let all_val_term_seq_vars = ref [] in
  let all_typed_vars   = ref [] in

  let has_otherwise_prem prem_list =
    List.exists (fun p -> match p.it with ElsePr -> true | _ -> false) prem_list
  in
  let decode_lhs_for_rule local_rule_idx r =
    match r.it with
    | RuleD (case_id, binders, _, conclusion, prem_list) ->
        if exec_kind = ExecConfigToConfig && bs_skip_ctxt_rule case_id.it then None
        else
          let raw_prefix = String.uppercase_ascii (sanitize case_id.it) in
          let case_part =
            if raw_prefix = "" then Printf.sprintf "R%d" local_rule_idx else raw_prefix
          in
          let prefix = Printf.sprintf "%s-%s" rel_prefix case_part in
          let vm = binder_to_var_map prefix local_rule_idx binders in
          let decoded =
            if exec_kind = ExecTermToTerm then
              (match conclusion.it with
               | TupE [lhs; _rhs] ->
                   let z_var = prefix ^ "-Z" in
                   Some ([z_var], translate_exp TermCtx lhs vm)
               | _ -> None)
            else if exec_kind = ExecConfigToTerm then
              (match conclusion.it with
               | TupE [cfg_lhs; _rhs] ->
                   (match try_decompose_config cfg_lhs with
                    | Some (z_e, lhs_e) ->
                        let z_t = translate_exp TermCtx z_e vm in
                        let lhs_t = translate_exp TermCtx lhs_e vm in
                        Some (z_t.vars, lhs_t)
                    | None -> None)
               | _ -> None)
            else
              (match conclusion.it with
               | TupE [cfg_lhs; _cfg_rhs] ->
                   (match try_decompose_config cfg_lhs with
                    | Some (z_e, lhs_e) ->
                        let z_t = translate_exp TermCtx z_e vm in
                        let lhs_t = translate_exp TermCtx lhs_e vm in
                        Some (z_t.vars, lhs_t)
                    | None -> None)
               | _ -> None)
          in
          (match decoded with
           | Some (z_vars, lhs_t) ->
               Some (case_id.it, vm, z_vars, lhs_t, prem_list)
           | None -> None)
  in
  let pattern_assignment_from_sched lhs_vars (p : prem_sched) =
    match split_once_re (Str.regexp "[ \t]+:=[ \t]+") p.text with
    | Some (lhs, rhs) ->
        let lhs = strip_wrapping_parens lhs |> String.trim in
        let rhs = strip_wrapping_parens rhs |> String.trim in
        if is_plain_var_like rhs && List.mem rhs lhs_vars && not (is_plain_var_like lhs)
        then Some (rhs, lhs)
        else if is_plain_var_like lhs && List.mem lhs lhs_vars && not (is_plain_var_like rhs)
        then Some (lhs, rhs)
        else None
    | None -> None
  in
  let current_var_for_previous_lhs prev_lhs prev_var current_lhs current_vars =
    let marker = "$OTHERWISE-FOCUS" in
    let prev_shape = replace_maude_var_token prev_var marker prev_lhs in
    current_vars
    |> List.find_opt (fun cur_var ->
         replace_maude_var_token cur_var marker current_lhs = prev_shape)
  in
  let generic_otherwise_conds rule_idx current_lhs current_lhs_vars current_typed_vars prem_list =
    if not (has_otherwise_prem prem_list) then []
    else
      let previous =
        rules
        |> List.mapi (fun i r -> (i, r))
        |> List.filter (fun (i, _) -> i < rule_idx)
        |> List.rev
      in
      let rec try_previous = function
        | [] -> []
        | (prev_idx, prev_rule) :: rest ->
            (match decode_lhs_for_rule prev_idx prev_rule with
             | None -> try_previous rest
             | Some (prev_case_id, prev_vm, prev_z_vars, prev_lhs_t, prev_prem_list) ->
                 if has_otherwise_prem prev_prem_list then try_previous rest
                 else
                   let prev_lhs_vars = vars_of_texpr prev_lhs_t in
                   let prev_lhs_seed = SSet.of_list (prev_z_vars @ prev_lhs_vars) in
                   let prev_prem_items =
                     List.concat_map (prem_items_of_prem prev_vm) prev_prem_list
                   in
                   let prev_sched = schedule_prems prev_lhs_seed [] prev_prem_items in
                   let rec try_sched = function
                     | [] -> try_previous rest
                     | p :: ps ->
                         (match pattern_assignment_from_sched prev_lhs_vars p with
                          | None -> try_sched ps
                          | Some (prev_var, pattern) ->
                              (match current_var_for_previous_lhs
                                       prev_lhs_t.text prev_var current_lhs current_lhs_vars
                               with
                               | None -> try_sched ps
                               | Some current_var ->
                                   let helper =
                                     otherwise_match_helper_name rel_name prev_case_id
                                   in
                                   register_otherwise_match_helper helper pattern;
                                   let sort_guard =
                                     match List.assoc_opt current_var current_typed_vars with
                                     | Some sort when sort <> "SpectecTerminal" ->
                                         [Printf.sprintf "%s : %s" current_var sort]
                                     | _ -> []
                                   in
                                   sort_guard @
                                   [Printf.sprintf "( %s ( %s ) == false )"
                                      helper current_var]))
                   in
                   try_sched prev_sched)
      in
      try_previous previous
  in

  let rule_lines = List.mapi (fun rule_idx r -> match r.it with
    | RuleD (case_id, binders, _, conclusion, prem_list) ->
        if exec_kind = ExecConfigToConfig && bs_skip_ctxt_rule case_id.it then ""
        else begin
          let raw_prefix = String.uppercase_ascii (sanitize case_id.it) in
          let case_part =
            if raw_prefix = "" then Printf.sprintf "R%d" rule_idx else raw_prefix
          in
          let prefix = Printf.sprintf "%s-%s" rel_prefix case_part in
          let label_prefix = rule_label_prefix rel_name case_id.it rule_idx in
          let vm = binder_to_var_map prefix rule_idx binders in
          let raw_typed_vars = binder_var_sorts binders vm in
          let typed_vars = raw_typed_vars |> List.sort_uniq compare in
          let exec_source_guard cond =
            match parse_sort_guard_condition cond with
            | Some (_term, sort) ->
                (match source_type_term_for_sort sort with
                 | Some type_term
                     when jhs_carrier_sort_for_source_sort sort <> None
                          && source_name_of_spectec_type_head (jhs_type_head type_term) = "instr" ->
                     None
                 | _ -> jhs_condition_of_source_guard cond)
            | None -> Some cond
          in
          let bconds =
            binder_to_type_conds binders vm
            |> List.filter_map (fun (mv, cond) ->
                 match exec_source_guard cond with
                 | Some cond' -> Some (mv, cond')
                 | None -> None)
          in
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
          let _ = val_seq_vars in
          let _ = all_seq_vars in
          reset_listn_pairs ();
          record_listn_pairs_from_binders binders vm;

          let decoded : (string * string list * texpr * string * string list * texpr) option =
            if exec_kind = ExecTermToTerm then
              (match conclusion.it with
               | TupE [lhs; rhs] ->
                   let z_var = prefix ^ "-Z" in
                   Some (z_var, [z_var], translate_exp TermCtx lhs vm,
                         z_var, [z_var],
                         with_generic_const_payload_wrapping
                           (fun () -> translate_exp TermCtx rhs vm))
               | _ -> None)
            else if exec_kind = ExecConfigToTerm then
              (match conclusion.it with
               | TupE [cfg_lhs; rhs] ->
                   (match try_decompose_config cfg_lhs with
                    | Some (z_e, lhs_e) ->
                        let z_t = translate_exp TermCtx z_e vm in
                        let lhs_t = translate_exp TermCtx lhs_e vm in
                        let rhs_t =
                          with_generic_const_payload_wrapping
                            (fun () -> translate_exp TermCtx rhs vm)
                        in
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
                        let rhs_t =
                          with_generic_const_payload_wrapping
                            (fun () -> translate_exp TermCtx rhs_e vm)
                        in
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
              let rhs_text_out, prem_scheduled = (rhs_t.text, prem_scheduled) in
              let ctxt_focus_rewrite = None in
              let rewrite_ctxt_focus_text text =
                match ctxt_focus_rewrite with
                | None -> text
                | Some (focus, _head, _rest, focus_text) ->
                    replace_maude_var_token focus focus_text text
              in
              let lhs_text_out = rewrite_ctxt_focus_text lhs_t.text in
              let rhs_text_out = rewrite_ctxt_focus_text rhs_text_out in
              let lhs_text_out =
                sequence_term_for_sort "InstrSeq" lhs_text_out
                |> normalize_sequence_concats_in_text "InstrSeq"
              in
              let rhs_text_out =
                sequence_term_for_sort "InstrSeq" rhs_text_out
                |> normalize_sequence_concats_in_text "InstrSeq"
              in
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
              let _ = all_seq_vars in
              (match ctxt_focus_rewrite with
               | None -> ()
               | Some (_focus, head, _rest, _focus_text) ->
                   all_bound := head :: !all_bound);

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
                widen_reld_lhs_typed_vars typed_vars lhs_pattern_vars
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
                     let conds =
                       rewrite_literal_payload_typecheck_conds
                         (String.concat " " (lhs_text_out :: rhs_text_out :: prem_strs))
                         conds
                     in
                     if exec_kind = ExecTermToTerm then
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
	                  if is_rewrite_cond p.text then
	                    let cond = prem_cond p.text in
	                    Some cond
	                  else None)
	              in
		              let recursive_step_focus_nonempty_conds =
		                if exec_kind = ExecConfigToConfig && case_id.it = "ctxt-instrs" then
		                  let focus_var_of_step_cond cond =
		                    let re =
		                      Str.regexp
	                        "step[ \t\n]*( *( *[^;]+;[ \t\n]*\\([A-Z][A-Za-z0-9_'-]*\\)[ \t\n]*)[ \t\n]*)[ \t\n]*=>"
	                    in
	                    try
	                      ignore (Str.search_forward re cond 0);
	                      Some (Str.matched_group 1 cond)
		                    with Not_found -> None
		                  in
		                  prem_rewrite_conds
		                  |> List.filter_map focus_var_of_step_cond
		                  |> List.filter (fun v ->
		                      match List.assoc_opt v raw_typed_vars with
		                      | Some sort -> sort = "SpectecTerminals" || ends_with sort "Seq"
	                      | None -> false)
	                  |> List.sort_uniq String.compare
	                  |> List.map (fun v ->
	                      Printf.sprintf "_>_ ( ( len ( %s ) ), 0 )" v)
	                else []
	              in
              let has_recursive_step_focus =
                recursive_step_focus_nonempty_conds <> []
              in
	              let prem_match_conds =
	                prem_scheduled |> List.filter_map (fun p ->
	                  if p.binds = [] || is_rewrite_cond p.text then None else Some (prem_cond p.text))
	              in
              let prem_bool_conds =
                prem_scheduled |> List.filter_map (fun p ->
                  if p.binds = [] && not (is_rewrite_cond p.text) then Some (prem_cond p.text) else None)
              in
              let allvals_conds = [] in
              let listn_len_conds = listn_len_conditions lhs_set2 in
              let base_conds =
                if exec_kind = ExecConfigToConfig && has_recursive_step_focus then
                  let before_rewrite_bconds, after_rewrite_bconds =
                    let lhs_available_vars =
                      lhs_pattern_vars
                      |> List.sort_uniq String.compare
                    in
                    List.partition
                      (fun cond ->
                         let used =
                           extract_vars_from_maude cond
                           |> List.sort_uniq String.compare
                         in
                         List.for_all
                           (fun v ->
                              List.mem v lhs_available_vars
                              || is_generated_free_const_name v)
                           used)
                      filtered_bconds
                  in
	                  listn_len_conds @ allvals_conds @ prem_bool_conds
	                  @ recursive_step_focus_nonempty_conds @ before_rewrite_bconds
	                  @ prem_match_conds
	                  @ prem_rewrite_conds @ after_rewrite_bconds
                else
                  prem_match_conds @ prem_rewrite_conds @ listn_len_conds @ allvals_conds
                  @ prem_bool_conds @ filtered_bconds
              in
	              let all_conds =
	                normalize_assignment_conditions_ordered lhs_pattern_vars
	                  (drop_execution_category_guards (base_conds @ refined_lhs_guards))
	              in
              let label = String.lowercase_ascii label_prefix in
              let all_conds =
                let source_otherwise_conds =
                  generic_otherwise_conds rule_idx lhs_text_out lhs_vars typed_vars prem_list
                in
                (source_otherwise_conds @ all_conds)
                |> List.map (normalize_sequence_eps_conditions raw_typed_vars)
              in
              let cond = cond_join all_conds in
              let lhs_rel_text, rhs_rel_text =
                if exec_kind = ExecTermToTerm then
                  (Printf.sprintf "step-pure ( %s )" lhs_text_out,
                   rhs_text_out)
                else if exec_kind = ExecConfigToTerm then
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
              let primary_rule = emit_rule label lhs_rel_text rhs_rel_text in
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
    |> List.map (fun (v, sort) -> (v, runtime_rule_decl_sort sort))
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
  let rule_block =
    typed_decl ^ bound_decl ^ val_terms_decl ^ vals_decl ^ is_decl
    ^ String.concat "\n" (List.filter (fun s -> s <> "") rule_lines)
    ^ "\n"
  in
  rule_block

(* --- RelD handler -------------------------------------------------------- *)

let translate_steps_reld rel_name rules =
  let rel_prefix = String.uppercase_ascii (sanitize rel_name) in
  let all_bound = ref [] in
  let all_free = ref [] in
  let all_typed_vars = ref [] in
  let current_closure_op = String.lowercase_ascii (sanitize rel_name) in

  let rule_lines = List.mapi (fun rule_idx r -> match r.it with
    | RuleD (case_id, binders, _, conclusion, prem_list) ->
        let raw_prefix = String.uppercase_ascii (sanitize case_id.it) in
        let case_part = if raw_prefix = "" then Printf.sprintf "R%d" rule_idx else raw_prefix in
        let prefix = Printf.sprintf "%s-%s" rel_prefix case_part in
        let label_prefix = rule_label_prefix rel_name case_id.it rule_idx in
        let vm = binder_to_var_map prefix rule_idx binders in
        let typed_vars =
          binder_var_sorts binders vm
          |> List.sort_uniq compare
        in
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
        let _ = all_seq_vars in
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
                   let rhs_t =
                     with_generic_const_payload_wrapping
                       (fun () -> translate_exp TermCtx rhs_e vm)
                   in
                   (config_text z_t.text (sequence_term_for_sort "InstrSeq" lhs_t.text),
                    config_text zp_t.text (sequence_term_for_sort "InstrSeq" rhs_t.text),
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
          |> rewrite_literal_payload_typecheck_conds
               (String.concat " " (lhs_cfg :: rhs_cfg :: prem_strs))
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
		        let all_conds =
		          prem_match_conds @ prem_rewrite_conds @ prem_bool_conds
		          @ filtered_bconds
		        in
		        let cond = cond_join all_conds in
	        let emit_rule label lhs rhs local_cond =
	          if local_cond = "" then
	            Printf.sprintf "  rl [%s] :\n    %s ( %s )\n    =>\n    %s ."
	              label current_closure_op lhs rhs
	          else
		          Printf.sprintf "  crl [%s] :\n    %s ( %s )\n    =>\n    %s\n      if %s ."
	              label current_closure_op lhs rhs local_cond
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
  let seq_vars = [] in
  let bound_vars =
    !all_bound
    |> List.filter (fun v -> not (List.mem v seq_vars))
    |> List.sort_uniq String.compare
  in
  let typed_vars =
    !all_typed_vars
    |> List.map (fun (v, sort) -> (v, runtime_rule_decl_sort sort))
    |> List.sort_uniq compare
  in
  let typed_names = List.map fst typed_vars |> List.sort_uniq String.compare in
  let bound_vars = List.filter (fun v -> not (List.mem v typed_names)) bound_vars in
  let typed_decl = declare_vars_by_sort typed_vars in
  let bound_decl = declare_vars_same_sort bound_vars "SpectecTerminal" in
  let seq_decl = declare_vars_same_sort seq_vars "SpectecTerminals" in
  let free_decl = declare_ops_const_list truly_free "SpectecTerminal" in
  typed_decl ^ bound_decl ^ seq_decl ^ free_decl ^ String.concat "\n" rule_lines ^ "\n"

let lower_all_reld_as_rewrite = true

let maude_ceq_supports_condition_text cond =
  let cond = String.trim cond in
  cond <> "owise" && not (contains_substring cond "=>")

let maude_ceq_supports_condition_texts conds =
  List.for_all maude_ceq_supports_condition_text conds

let condition_rewrite_parts cond =
  match split_once "=>" (String.trim cond) with
  | Some (lhs, rhs) -> Some (String.trim lhs, String.trim rhs)
  | None -> None

let same_maude_surface a b =
  let normalize s =
    s
    |> strip_wrapping_parens
    |> String.trim
    |> Str.global_replace (Str.regexp "[ \t\n\r]+") " "
  in
  normalize a = normalize b

let translate_reld ?(result_execution=false) _id rel_name rules =
  register_infer_rel_rules rel_name rules;
  let translate_result_execution_reld () =
    let try_equational = true in
    let op_decl =
      Printf.sprintf "\n  op %s : Config -> SpectecTerminals [frozen (1)] .\n" rel_name
    in
    let all_bound = ref [] and all_free = ref [] and all_typed_vars = ref [] in
    let relation_args vm conclusion =
      match conclusion.it with
      | TupE el -> List.map (fun x -> translate_exp TermCtx x vm) el
      | _ -> [translate_exp TermCtx conclusion vm]
    in
    let rule_lines =
      rules
      |> List.mapi (fun rule_idx r ->
          match r.it with
          | RuleD (case_id, binders, _, conclusion, prem_list) ->
              let prefix =
                let raw_prefix = String.uppercase_ascii (sanitize case_id.it) in
                let case_part =
                  if raw_prefix = "" then Printf.sprintf "R%d" rule_idx else raw_prefix
                in
                Printf.sprintf "%s-%s" (String.uppercase_ascii rel_name) case_part
              in
              let label = String.lowercase_ascii (rule_label_prefix rel_name case_id.it rule_idx) in
              let vm = binder_to_var_map prefix rule_idx binders in
              reset_listn_pairs ();
              record_listn_pairs_from_binders binders vm;
              let typed_vars = binder_var_sorts binders vm in
              all_typed_vars := List.sort_uniq compare (!all_typed_vars @ typed_vars);
              let args = relation_args vm conclusion in
              (match args with
               | [z_t; instrs_t; zq_t; vals_t] ->
                   let prem_items = List.concat_map (prem_items_of_prem vm) prem_list in
                   let lhs_seed =
                     SSet.of_list (vars_of_texpr z_t @ vars_of_texpr instrs_t)
                   in
                   let prem_scheduled = schedule_prems lhs_seed [] prem_items in
                   let prem_strs = List.map (fun (p : prem_sched) -> p.text) prem_scheduled in
                   let prem_vars =
                     List.concat_map (fun (p : prem_sched) -> p.vars @ p.binds) prem_scheduled
                   in
                   let all_collected =
                     z_t.vars @ instrs_t.vars @ zq_t.vars @ vals_t.vars @ prem_vars
                   in
                   let all_texts =
                     [z_t.text; instrs_t.text; zq_t.text; vals_t.text] @ prem_strs
                   in
                   let (bound, free, _lhs_set) =
                     partition_vars
                       (List.sort_uniq String.compare (z_t.vars @ instrs_t.vars @ prem_vars))
                       all_texts all_collected
                   in
                   all_bound := List.sort_uniq String.compare (!all_bound @ bound);
                   all_free := List.sort_uniq String.compare (!all_free @ free);
                   let cond = cond_join prem_strs in
                   let lhs =
                     Printf.sprintf "%s ( %s )" rel_name
                       (config_text z_t.text instrs_t.text)
                   in
                   let rhs = Printf.sprintf "%s %s" zq_t.text vals_t.text in
                   if try_equational then
                     match prem_strs with
                     | [] ->
                         Printf.sprintf "  eq %s = %s ." lhs rhs
                     | [prem] -> (
                         match condition_rewrite_parts prem with
                         | Some (steps_term, target)
                             when same_maude_surface target
                                    (config_text zq_t.text vals_t.text) ->
                             Printf.sprintf
                               "  ceq %s = %s\n      if %s := %s ."
                               lhs rhs target steps_term
                         | _ when maude_ceq_supports_condition_texts prem_strs ->
                             if cond = "" then
                               Printf.sprintf "  eq %s = %s ." lhs rhs
                             else
                               Printf.sprintf "  ceq %s = %s\n      if %s ." lhs rhs cond
                         | _ ->
                             let fallback_comment =
                               "  --- equational lowering skipped for [" ^ label ^
                               "]: unsupported condition shape for deterministic result projection.\n"
                             in
                             if cond = "" then
                               Printf.sprintf "%s  rl [%s] :\n    %s\n    =>\n    %s ."
                                 fallback_comment label lhs rhs
                             else
                               Printf.sprintf "%s  crl [%s] :\n    %s\n    =>\n    %s\n      if %s ."
                                 fallback_comment label lhs rhs cond)
                     | _ when maude_ceq_supports_condition_texts prem_strs ->
                         if cond = "" then
                           Printf.sprintf "  eq %s = %s ." lhs rhs
                         else
                           Printf.sprintf "  ceq %s = %s\n      if %s ." lhs rhs cond
                     | _ ->
                         let fallback_comment =
                           "  --- equational lowering skipped for [" ^ label ^
                           "]: unsupported condition shape for deterministic result projection.\n"
                         in
                         if cond = "" then
                           Printf.sprintf "%s  rl [%s] :\n    %s\n    =>\n    %s ."
                             fallback_comment label lhs rhs
                         else
                           Printf.sprintf "%s  crl [%s] :\n    %s\n    =>\n    %s\n      if %s ."
                             fallback_comment label lhs rhs cond
                   else
                     let fallback_comment =
                       if try_equational then
                         "  --- equational lowering skipped for [" ^ label ^
                         "]: Maude ceq conditions cannot contain rewrite conditions.\n"
                       else
                         ""
                     in
                     if cond = "" then
                       Printf.sprintf "%s  rl [%s] :\n    %s\n    =>\n    %s ."
                         fallback_comment label lhs rhs
                     else
                       Printf.sprintf "%s  crl [%s] :\n    %s\n    =>\n    %s\n      if %s ."
                         fallback_comment label lhs rhs cond
               | _ ->
                   let lhs =
                     args |> List.map (fun (t : texpr) -> t.text) |> String.concat " , "
                   in
                   Printf.sprintf "  --- unsupported result-execution relation shape for %s: %s" rel_name lhs))
    in
    let typed_decl = declare_vars_by_sort (!all_typed_vars |> List.sort_uniq compare) in
    let typed_names =
      !all_typed_vars |> List.map fst |> List.sort_uniq String.compare
    in
    let bound_decl =
      !all_bound
      |> List.filter (fun v -> not (List.mem v typed_names))
      |> List.sort_uniq String.compare
      |> fun vs -> declare_vars_same_sort vs "SpectecTerminal"
    in
	    let free_decl =
	      !all_free
	      |> List.filter (fun v -> not (List.mem v !all_bound))
	      |> List.filter (fun v -> not (List.mem v typed_names))
	      |> List.sort_uniq String.compare
	      |> fun vs -> declare_ops_const_list vs "SpectecTerminal"
	    in
    op_decl ^ typed_decl ^ bound_decl ^ free_decl ^ String.concat "\n" rule_lines ^ "\n"
  in
  if result_execution then translate_result_execution_reld ()
  else
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

	        let raw_lhs_t () =
	          match conclusion.it with
	          | TupE el -> tconcat " , " (List.map (fun x -> translate_exp TermCtx x vm) el)
	          | _ -> translate_exp TermCtx conclusion vm
	        in
	        let translate_lhs_for_optional_indices indices =
	          with_optional_literal_empty_indices indices (fun () ->
	              let lhs_t = raw_lhs_t () in
	              let lhs_t, lhs_projection_items =
	                if use_rewrite_judgement then hoist_lhs_value_projections prefix lhs_t
	                else (lhs_t, [])
	              in
	              let lhs_t, lhs_map_items, lhs_map_pairs =
	                if use_rewrite_judgement then hoist_lhs_unary_map_calls prefix lhs_t
	                else (lhs_t, [], [])
	              in
	              let lhs_t, lhs_computed_items =
	                if use_rewrite_judgement then hoist_lhs_computed_calls prefix lhs_t
	                else (lhs_t, [])
	              in
	              (lhs_t, lhs_projection_items, lhs_map_items, lhs_map_pairs,
	               lhs_computed_items, !optional_literal_seen))
	        in
	        let (lhs_t, lhs_projection_items, lhs_map_items, lhs_map_pairs,
	             lhs_computed_items, optional_literal_count) =
	          translate_lhs_for_optional_indices []
	        in
	        let optional_literal_indices =
	          List.init optional_literal_count (fun i -> i)
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
        let prem_items =
          lhs_projection_items @ lhs_map_items @ lhs_computed_items
          @ List.concat_map (prem_items_of_prem vm) prem_list
        in
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
          |> rewrite_literal_payload_typecheck_conds (String.concat " " all_texts)
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
        let all_conds =
          if uses_execution_rewrite_premise prem_strs then
            drop_execution_category_guards all_conds
          else
            all_conds
        in
        let lower_rule_label = String.lowercase_ascii label_prefix in
        let progress_conds_before =
          let generated_base = Printf.sprintf "%s%d" prefix rule_idx in
          if lower_rule_label = "instrs-ok-frame" then
            let arrow_term =
              let args =
                [
                  generated_base ^ "-TS1";
                  generated_base ^ "-XS";
                  generated_base ^ "-TS2";
                ]
              in
              match source_ctor_name_from_sections [ ""; "arrow"; ""; "" ] 3 with
              | Some ctor -> format_source_ctor_call ctor args
              | None ->
                  Printf.sprintf "%s-TS1 arrow %s-XS %s-TS2"
                    generated_base generated_base generated_base
            in
            [
              Printf.sprintf "%s-TS =/= eps" generated_base;
              Printf.sprintf
                "$infer-instrs-ok-arg2 ( %s-C , %s-INSTRS ) => %s"
                generated_base generated_base arrow_term;
            ]
          else
            []
        in
        let all_conds =
          if lower_rule_label = "instrs-ok-sub" then
            let generated_base = Printf.sprintf "%s%d" prefix rule_idx in
            let guard =
              Printf.sprintf "%s-IT =/= %s-ITQ" generated_base generated_base
            in
            (* The first premise is the infer premise binding IT.  Put the
               progress guard immediately after it and before the recursive
               Instrs-ok premise. *)
            match all_conds with
            | infer_cond :: rest -> infer_cond :: guard :: rest
            | [] -> [guard]
          else
            all_conds
        in
        let cond = cond_join (progress_conds_before @ all_conds) in
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
        let emit_exec_tail_specializations =
          (* The generic exec-tail-empty expansion is useful for some sequence
             rules, but for Instrs_ok/frame it creates several t* = eps cases
             that re-enter the same Instrs-ok goal.  The base frame rule above
             is enough once it has a progress guard. *)
          String.lowercase_ascii label_prefix <> "instrs-ok-frame"
        in
        let exec_tail_rules =
          if not emit_exec_tail_specializations then []
          else
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
	        let optional_literal_rules =
	          optional_literal_indices
	          |> nonempty_subsets
	          |> List.sort (fun a b -> compare (List.length b) (List.length a))
	          |> List.mapi (fun i indices ->
	              let lhs_t, _, _, _, _, _ =
	                translate_lhs_for_optional_indices indices
	              in
	              let lhs_text = lhs_t.text in
	              let cond_text = cond in
	              emit_rule
	                ~suffix:(Printf.sprintf "-opt-empty%d" i)
	                lhs_text cond_text)
        in
        let optional_binder_rules =
          optional_empty_substs binders vm [lhs_t.text]
          |> List.mapi (fun i opt_vars ->
              let lhs_text = apply_optional_empty_subst opt_vars lhs_t.text in
              let conds =
                all_conds
                |> List.filter (fun c -> not (cond_mentions_optional opt_vars c))
                |> List.map (apply_optional_empty_subst opt_vars)
              in
              emit_rule
                ~suffix:(Printf.sprintf "-opt-var-empty%d" i)
                lhs_text (cond_join conds))
        in
        let typed_index_empty_rules =
          typed_index_empty_substs binders vm all_conds
          |> List.mapi (fun i (drop_cond, empty_vars) ->
              let lhs_text = replace_maude_vars_with_eps empty_vars lhs_t.text in
              let conds =
                all_conds
                |> List.filter (fun c -> String.trim c <> String.trim drop_cond)
                |> List.map (replace_maude_vars_with_eps empty_vars)
              in
              emit_rule
                ~suffix:(Printf.sprintf "-typed-index-empty%d" i)
                lhs_text (cond_join conds))
        in
	        let iter_empty_rules =
	          let optional_subsets =
	            [] :: (optional_literal_indices |> nonempty_subsets)
	          in
          let iter_groups = iter_empty_var_groups vm raw_typed_vars prem_list in
          lhs_map_pairs
          |> List.filter_map (fun (fresh, seq_var) ->
              let related_groups =
                iter_groups |> List.filter (fun group -> List.mem seq_var group)
              in
              if related_groups = [] then None
              else
                let related_vars =
                  related_groups |> List.concat |> List.sort_uniq String.compare
                in
                Some (List.sort_uniq String.compare (fresh :: related_vars)))
          |> List.sort_uniq compare
          |> List.mapi (fun group_i empty_vars ->
              optional_subsets
	              |> List.mapi (fun opt_i opt_terms ->
	                  let lhs_text =
	                    let opt_lhs_t =
	                      if opt_terms = [] then lhs_t
	                      else
	                        let t, _, _, _, _, _ =
	                          translate_lhs_for_optional_indices opt_terms
	                        in
	                        t
	                    in
	                    opt_lhs_t.text |> replace_maude_vars_with_eps empty_vars
	                  in
	                  let conds =
	                    all_conds
	                    |> List.filter (fun c -> not (cond_mentions_any_var empty_vars c))
	                    |> List.map (replace_maude_vars_with_eps empty_vars)
	                  in
                  emit_rule
                    ~suffix:(Printf.sprintf "-iter-empty%d-%d" group_i opt_i)
                    lhs_text (cond_join conds)))
          |> List.concat
        in
        String.concat "\n"
          (exec_tail_rules @ optional_literal_rules @ optional_binder_rules
           @ typed_index_empty_rules @ iter_empty_rules @ [base_rule])
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
  | RelD (id, mixop, _, rules) ->
      let name = sanitize id.it in
      if is_skipped_relation_name name then ""
      else
      (match relation_execution_kind mixop rules with
       | Some (ExecTermToTerm as kind)
       | Some (ExecConfigToTerm as kind)
       | Some (ExecConfigToConfig as kind) ->
           translate_step_reld kind name rules
       | Some ExecConfigClosure ->
           translate_steps_reld name rules
       | Some ExecResultConfigToTerms ->
           translate_reld ~result_execution:true id name rules
       | None ->
           translate_reld ~result_execution:false id name rules)
  | GramD _ | HintD _ -> ""

let rec pre_register_relation_rules (d : def) =
  match d.it with
  | RecD defs -> List.iter pre_register_relation_rules defs
  | RelD (id, mixop, _, rules) ->
      let name = sanitize id.it in
      if is_skipped_relation_name name then ()
      else
      (match relation_execution_kind mixop rules with
       | Some ExecTermToTerm
       | Some ExecConfigToTerm
       | Some ExecConfigToConfig
       | Some ExecConfigClosure -> ()
       | Some ExecResultConfigToTerms
       | None -> register_infer_rel_rules name rules)
  | TypD _ | DecD _ | GramD _ | HintD _ -> ()

(* ========================================================================= *)
(* 9. Top-level: prescan → header → translate → reorder → emit              *)
(* ========================================================================= *)

let nat_subsort_decls () =
  ""

let int_subsort_decls () =
  ""

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
  uses_ref_subtype_decision : bool;
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

let exec_wrapper_of_relation name mixop rules =
  match relation_execution_kind mixop rules with
  | Some ExecTermToTerm
  | Some ExecConfigToTerm
  | Some ExecConfigToConfig
  | Some ExecConfigClosure ->
    let exec_input_sort, exec_output_carrier, exec_frozen =
      match relation_execution_kind mixop rules with
      | Some ExecTermToTerm -> ("SpectecTerminals", "SpectecTerminals", true)
      | Some ExecConfigToTerm -> ("Config", "SpectecTerminals", true)
      | Some ExecConfigToConfig -> ("Config", "Config", true)
      | Some ExecConfigClosure -> ("Config", "Config", false)
      | _ -> ("SpectecTerminals", "SpectecTerminals", true)
    in
    Some {
      exec_rel_name = name;
      exec_op_name = String.lowercase_ascii name;
      exec_wrapper_sort = pascal_of_maude_name name ^ "Conf";
      exec_input_sort;
      exec_output_carrier;
      exec_frozen;
    }
  | Some ExecResultConfigToTerms | None -> None

let source_execution_wrappers defs =
  let rec scan d =
    match d.it with
    | RecD ds -> List.concat_map scan ds
    | RelD (id, mixop, _, rules) ->
        let name = sanitize id.it in
        (match exec_wrapper_of_relation name mixop rules with
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
    uses_has_type =
      (not drop_runtime_typecheck_guards) && !feature_uses_has_type;
    uses_sequence_index = ss.scan_uses_sequence_index || has "index (" || has "index(";
    uses_typed_index = has "$typed-index";
    uses_repeat = ss.scan_uses_repeat || has "$repeat";
    uses_slice = ss.scan_uses_slice || has "slice (" || has "slice(";
    uses_star_prefix = !feature_uses_star_prefix;
    uses_set_membership = ss.scan_uses_set_membership || has " <- ";
    uses_merge = ss.scan_uses_merge || has "merge (" || has "merge(";
    uses_any = ss.scan_uses_any || contains_substring token_ops "op any :";
    uses_exp_const = has "EXP";
    uses_ref_subtype_decision = false;
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
  "  sort SpectecTypes .\n" ^
  "\n" ^
  "  subsort Nat < SpectecTerminal .\n" ^
  "  subsort SpectecTerminal < SpectecTerminals .\n" ^
  "  subsort SpectecType < SpectecTypes .\n" ^
  "  op eps : -> SpectecTerminals .\n" ^
  "  op _ _ : SpectecTerminals SpectecTerminals -> SpectecTerminals [ctor assoc id: eps] .\n\n" ^
  Printf.sprintf "  op %s : -> SpectecType .\n"
    (spectec_type_term_of_name "nat" []) ^
  Printf.sprintf "  op %s : -> SpectecType .\n"
    (spectec_type_term_of_name "int" []) ^
  "  op typecheck : SpectecTerminal SpectecType -> Bool .\n" ^
  "  op typecheck : SpectecTerminals SpectecType -> Bool .\n" ^
  "  op typecheck : SpectecTerminals SpectecTypes -> Bool .\n\n" ^
  "  op len : SpectecTerminals -> Nat .\n" ^
  "  var W : SpectecTerminal .\n" ^
  "  var WTS : SpectecTerminals .\n\n" ^
  "  eq len(eps) = 0 .\n" ^
  "  eq len(W WTS) = 1 + len(WTS) .\n\n" ^
  "  var T : SpectecTerminal .\n" ^
  "  var TS : SpectecTerminals .\n\n" ^
  "  var WT : SpectecType .\n" ^
  Printf.sprintf "  var %s : Nat .\n" spectec_nat_var ^
  Printf.sprintf "  var %s : Int .\n" spectec_int_var ^
  Printf.sprintf "  eq typecheck(%s, %s) = true .\n"
    spectec_nat_var (spectec_type_term_of_name "nat" []) ^
  Printf.sprintf "  eq typecheck(%s, %s) = true .\n"
    spectec_int_var (spectec_type_term_of_name "int" []) ^
  "  eq typecheck(eps, WT) = true .\n" ^
  "  ceq typecheck(T TS, WT) = typecheck(TS, WT) if TS =/= eps /\\ typecheck(T, WT) .\n" ^
  "  eq typecheck(T, WT) = false [owise] .\n" ^
  "  eq typecheck(TS, WT) = false [owise] .\n\n" ^
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

let native_sequence_sort_decls () =
  ""

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
	      "  op _;_ : Store Frame -> SpectecTerminal [ctor prec 55] .\n" ^
	      "  op _;_ : State SpectecTerminals -> SpectecTerminal [ctor prec 60] .\n" ^
      op_decls ^
	      "\n"

let source_compound_unary_field_sort ctor =
  !source_compound_cases
  |> List.find_map (fun c ->
       if c.compound_ctor = ctor then
         match c.compound_fields with
         | [(_, field_typ)] -> simple_sort_of_typ field_typ []
         | _ -> None
       else None)

let source_literal_wrapped_payload sort payload =
  match literal_wrapper_for_sort ~register:false sort with
  | Some (_wrapper, ("Nat" | "Int")) ->
      Printf.sprintf "%s ( %s )" (syntax_wrapper_helper_name sort) payload
  | _ -> payload

let idx_range_ctor_term payload =
  match source_index_wrapper_ctor () with
  | Some widx_ctor ->
      let payload =
        match source_compound_unary_field_sort widx_ctor with
        | Some field_sort -> source_literal_wrapped_payload field_sort payload
        | None -> payload
      in
      format_source_ctor_call widx_ctor [payload]
  | None -> payload

let header_prefix features =
  let sequence_elem text =
    Printf.sprintf "( %s )" text
  in
  let idx_range_prev = idx_range_ctor_term "_-_ ( LISTN-N, 1 )" in
  let idx_range_from_next =
    idx_range_ctor_term "_+_ ( LISTN-START, _-_ ( LISTN-N, 1 ) )"
  in
  let rec_range_next =
    match source_recursive_typevar_ctor () with
    | Some rec_ctor ->
        format_source_ctor_call rec_ctor ["_-_ ( LISTN-N, 1 )"]
    | None -> "_-_ ( LISTN-N, 1 )"
  in
  let def_range_next =
    match source_indexed_deftype_ctor () with
    | Some wdef_ctor ->
        format_source_ctor_call wdef_ctor ["LISTN-RT"; "_-_ ( LISTN-N, 1 )"]
    | None -> "LISTN-RT _-_ ( LISTN-N, 1 )"
  in
  generated_prelude_modules features ^
  "mod SPECTEC-CORE is\n" ^
  core_prelude_include features ^
  "  inc BOOL .\n" ^
  "  inc INT .\n\n" ^
  "  --- Base Sorts\n" ^
  "  subsort Int < SpectecTerminal .\n" ^
  "  --- Nat < SpectecTerminal is provided by DSL-PRETYPE.\n\n" ^
  "  --- Source category/type tags are represented as SpectecType terms.\n" ^
  "  --- Source syntax constructors live on the broad SpectecTerminal carrier.\n\n" ^
  (native_sequence_sort_decls ()) ^
  (nat_subsort_decls ()) ^
  (int_subsort_decls ()) ^
  "  --- Syntax-category membership is represented by typecheck plus mb/cmb axioms.\n\n" ^
  (if features.uses_bool_wrapper then
     "  --- Bool wrapper emitted because source defs return Bool as a terminal.\n" ^
     "  op w-bool : Bool -> SpectecTerminal [ctor] .\n\n" ^
     "  --- Internal placeholder for an empty source optional inside an iterated field.\n" ^
     "  --- It preserves sequence positions but is not a source value/category witness.\n" ^
     "  op $none : -> SpectecTerminal [ctor] .\n\n"
   else "") ^
  "  --- Source category names are not emitted as Maude syntax sorts.\n\n" ^
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
	  (if features.uses_repeat then
	     "  op $repeat : SpectecTerminals Int -> SpectecTerminals .\n"
	   else "") ^
	  "  op $nat-range-from : SpectecTerminal SpectecTerminal -> SpectecTerminals .\n" ^
	  "  op $idx-range : SpectecTerminal -> SpectecTerminals .\n" ^
	  "  op $idx-range-from : SpectecTerminal SpectecTerminal -> SpectecTerminals .\n" ^
	  "  op $rec-range : SpectecTerminal -> SpectecTerminals .\n" ^
	  "  op $def-range : SpectecTerminal SpectecTerminal -> SpectecTerminals .\n" ^
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
  "\n" ^
  (if features.uses_sequence_index then
     "  --- Generic SpecTec sequence indexing: xs[i*] maps scalar index over i*.\n" ^
     "  --- This is representation substrate for source meta-expressions, not a\n" ^
     "  --- judgement-specific executable shortcut.\n" ^
     "  var INDEX-I : Nat .\n" ^
     "  vars INDEX-TS INDEX-IS : SpectecTerminals .\n" ^
     "  eq index(INDEX-TS, eps) = eps .\n" ^
     "  ceq index(INDEX-TS, INDEX-I INDEX-IS) = index(INDEX-TS, INDEX-I) index(INDEX-TS, INDEX-IS)\n" ^
     "   if INDEX-IS =/= eps .\n\n"
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
	     "  var REPEAT_ELEM : SpectecTerminals .\n" ^
	     "  var REPEAT_REST : SpectecTerminals .\n" ^
	     "  var REPEAT_SINGLE : SpectecTerminal .\n" ^
	     "  var REPEAT_WT : SpectecType .\n" ^
	     "  vars REPEAT_I REPEAT_COUNT : Int .\n" ^
	     "  var REPEAT_KIND_ELEM : [SpectecTerminals] .\n" ^
	     "  eq $repeat(REPEAT_KIND_ELEM, 0) = eps .\n" ^
	     "  eq $repeat(REPEAT_ELEM, 0) = eps .\n" ^
	     "  eq len($repeat(REPEAT_ELEM, 0) REPEAT_REST) = len(REPEAT_REST) .\n" ^
	     "  ceq len($repeat(REPEAT_ELEM, REPEAT_N) REPEAT_REST) = _+_ ( _*_ ( REPEAT_N, len(REPEAT_ELEM) ), len(REPEAT_REST) )\n" ^
	     "   if _>_ ( REPEAT_N, 0 ) .\n" ^
	     "  eq typecheck($repeat(REPEAT_ELEM, 0) REPEAT_REST, REPEAT_WT) = typecheck(REPEAT_REST, REPEAT_WT) .\n" ^
	     "  ceq typecheck($repeat(REPEAT_ELEM, REPEAT_N) REPEAT_REST, REPEAT_WT) = typecheck(REPEAT_REST, REPEAT_WT)\n" ^
	     "   if _>_ ( REPEAT_N, 0 ) /\\ typecheck(REPEAT_ELEM, REPEAT_WT) .\n" ^
	     "  eq slice($repeat(REPEAT_SINGLE, REPEAT_N), REPEAT_I, 0) = eps .\n" ^
	     "  ceq slice($repeat(REPEAT_SINGLE, REPEAT_N), 0, REPEAT_COUNT) = REPEAT_SINGLE slice($repeat(REPEAT_SINGLE, _-_ ( REPEAT_N, 1 )), 0, _-_ ( REPEAT_COUNT, 1 ))\n" ^
	     "   if _>_ ( REPEAT_N, 0 ) /\\ _>_ ( REPEAT_COUNT, 0 ) .\n" ^
	     "  ceq slice($repeat(REPEAT_SINGLE, REPEAT_N), REPEAT_I, REPEAT_COUNT) = slice($repeat(REPEAT_SINGLE, _-_ ( REPEAT_N, REPEAT_I )), 0, REPEAT_COUNT)\n" ^
	     "   if _>_ ( REPEAT_I, 0 ) /\\ _>=_ ( REPEAT_N, REPEAT_I ) .\n" ^
	     "  ceq $repeat(REPEAT_ELEM, REPEAT_N) = ( REPEAT_ELEM $repeat(REPEAT_ELEM, _-_ ( REPEAT_N, 1 )) )\n" ^
	     "   if _>_ ( REPEAT_N, 0 ) /\\ _<=_ ( REPEAT_N, 1024 ) .\n\n"
	   else "") ^
	  "  --- Generic SpecTec indexed repetition: e^(i<n) for source index i.\n" ^
		  "  vars LISTN-N LISTN-START : Nat .\n" ^
		  "  var LISTN-RT : SpectecTerminal .\n" ^
		  "  eq $nat-range-from(LISTN-START, 0) = eps .\n" ^
		  "  ceq $nat-range-from(LISTN-START, LISTN-N) = $nat-range-from(LISTN-START, _-_ ( LISTN-N, 1 )) _+_ ( LISTN-START, _-_ ( LISTN-N, 1 ) )\n" ^
		  "   if _>_ ( LISTN-N, 0 ) .\n" ^
		  "  eq $idx-range(0) = eps .\n" ^
		  Printf.sprintf "  ceq $idx-range(LISTN-N) = $idx-range(_-_ ( LISTN-N, 1 )) %s\n" (sequence_elem idx_range_prev) ^
		  "   if _>_ ( LISTN-N, 0 ) .\n" ^
		  "  eq $idx-range-from(LISTN-START, 0) = eps .\n" ^
		  Printf.sprintf "  ceq $idx-range-from(LISTN-START, LISTN-N) = $idx-range-from(LISTN-START, _-_ ( LISTN-N, 1 )) %s\n" (sequence_elem idx_range_from_next) ^
		  "   if _>_ ( LISTN-N, 0 ) .\n" ^
	  "  eq $rec-range(0) = eps .\n" ^
	  Printf.sprintf "  ceq $rec-range(LISTN-N) = %s $rec-range(_-_ ( LISTN-N, 1 ))\n" (sequence_elem rec_range_next) ^
	  "   if _>_ ( LISTN-N, 0 ) .\n" ^
	  "  eq $def-range(LISTN-RT, 0) = eps .\n" ^
	  Printf.sprintf "  ceq $def-range(LISTN-RT, LISTN-N) = %s $def-range(LISTN-RT, _-_ ( LISTN-N, 1 ))\n" (sequence_elem def_range_next) ^
	  "   if _>_ ( LISTN-N, 0 ) .\n\n" ^
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
        let elem_pred = refined_exec_pred sort in
        let lower = String.lowercase_ascii sort in
        Printf.sprintf
          "  --- Source-derived sequence-category predicate for SpecTec %s* premises.\n\
           \  eq  %s(eps) = true .\n\
           \  ceq %s(W TS) = %s(TS)\n\
           \   if %s(W) == true .\n\
           \  eq  %s(TS) = false [owise] .\n"
          lower pred pred pred elem_pred pred)
	    |> String.concat "\n"
  in
  let steps_final_block =
    if not !feature_uses_steps_final_predicate then ""
    else
      let trap_eq =
        match source_final_trap_instr_term () with
        | Some trap_ctor ->
            Printf.sprintf "  eq $is-final-steps-instrs(%s) = true .\n" trap_ctor
        | None -> ""
      in
      "  --- Executable finality for source ~>* closures: stop only at values/trap.\n" ^
      "  var FINAL-Z : State .\n" ^
      "  var FINAL-C : Config .\n" ^
      "  var FINAL-W : SpectecTerminal .\n" ^
      "  var FINAL-TS : SpectecTerminals .\n" ^
      "  eq $is-final-steps-instrs(eps) = true .\n" ^
      trap_eq ^
      "  ceq $is-final-steps-instrs(FINAL-W FINAL-TS) = $is-final-steps-instrs(FINAL-TS)\n" ^
      "   if FINAL-W : Val .\n" ^
      "  eq $is-final-steps-instrs(FINAL-TS) = false [owise] .\n" ^
      "  ceq $is-final-steps-config((FINAL-Z ; FINAL-TS)) = true\n" ^
      "   if $is-final-steps-instrs(FINAL-TS) == true .\n" ^
      "  eq $is-final-steps-config(FINAL-C) = false [owise] .\n\n"
  in
  let validation_optional_premise_block = "" in
  let memory_size_bridge = "" in
  (* Old focused $instantiate bridge strings were removed. The generated
     runtime now calls the source-translated $instantiate from output.maude. *)
  "\n" ^
  validation_optional_premise_block ^
  memory_size_bridge ^
	  (if seq_pred_blocks = "" then "" else
	     "  var W : SpectecTerminal .\n" ^
	     "  var TS : SpectecTerminals .\n" ^
	     seq_pred_blocks ^ "\n") ^
  steps_final_block ^
	  (if features.uses_has_type then
		     "  --- Generic SpecTec list type witness is disabled in the membership-sort encoding.\n\n"
	   else "") ^
  "\nendm\n"

let prelude_helper_decls features =
  let nested_sequence_block =
    "  --- Generic carrier for source nested sequences such as (X*)*.\n" ^
    "  op $seq : SpectecTerminals -> SpectecTerminal [ctor] .\n" ^
    "  op $setproduct-nested : SpectecTerminals -> SpectecTerminals .\n" ^
    "  op $setproduct1-nested : SpectecTerminals SpectecTerminals -> SpectecTerminals .\n" ^
    "  op $setproduct2-nested : SpectecTerminal SpectecTerminals -> SpectecTerminals .\n" ^
    "  var NESTED-W : SpectecTerminal .\n" ^
    "  vars NESTED-HEAD NESTED-REST NESTED-PRODUCTS NESTED-TAIL : SpectecTerminals .\n" ^
    "  eq $setproduct($seq(NESTED-HEAD) NESTED-REST) = $setproduct-nested($seq(NESTED-HEAD) NESTED-REST) .\n" ^
    "  eq $setproduct-nested(eps) = $seq(eps) .\n" ^
    "  eq $setproduct-nested($seq(NESTED-HEAD) NESTED-REST) = $setproduct1-nested(NESTED-HEAD, $setproduct-nested(NESTED-REST)) .\n" ^
    "  eq $setproduct1-nested(eps, NESTED-PRODUCTS) = eps .\n" ^
    "  eq $setproduct1-nested(NESTED-W NESTED-TAIL, NESTED-PRODUCTS) = $setproduct2-nested(NESTED-W, NESTED-PRODUCTS) $setproduct1-nested(NESTED-TAIL, NESTED-PRODUCTS) .\n" ^
    "  eq $setproduct2-nested(NESTED-W, eps) = eps .\n" ^
    "  eq $setproduct2-nested(NESTED-W, $seq(NESTED-HEAD) NESTED-REST) = $seq(NESTED-W NESTED-HEAD) $setproduct2-nested(NESTED-W, NESTED-REST) .\n"
  in
  nested_sequence_block ^
  (if !feature_uses_steps_final_predicate then
     "  op $is-final-steps-config : Config -> Bool .\n" ^
     "  op $is-final-steps-instrs : SpectecTerminals -> Bool .\n"
   else "") ^
  (features.seq_pred_sorts
	   |> List.map (fun sort ->
	       Printf.sprintf "  op %s : SpectecTerminals -> Bool .\n"
	         (source_category_seq_pred sort))
	   |> String.concat "")
  ^
  ""

let star_ctor_unzip_helper_block () =
  let helpers =
    !star_ctor_unzip_helpers
    |> List.sort_uniq (fun a b ->
        compare (a.star_unzip_ctor, a.star_unzip_arity)
          (b.star_unzip_ctor, b.star_unzip_arity))
  in
  if helpers = [] then ""
  else
    helpers
    |> List.map (fun h ->
        let stem = String.uppercase_ascii (sanitize h.star_unzip_ctor) in
        let args =
          List.init h.star_unzip_arity
            (fun i -> Printf.sprintf "UNZIP-%s-A%d" stem i)
        in
        let rest = Printf.sprintf "UNZIP-%s-REST" stem in
        let var_decl =
          Printf.sprintf "  vars %s %s : SpectecTerminals .\n"
            (String.concat " " args) rest
        in
        let op_decls =
          args
          |> List.mapi (fun i _ ->
              Printf.sprintf "  op %s : SpectecTerminals -> SpectecTerminals .\n"
                (star_ctor_unzip_name h.star_unzip_ctor i))
          |> String.concat ""
        in
        let eqs =
          args
          |> List.mapi (fun i arg ->
              let helper = star_ctor_unzip_name h.star_unzip_ctor i in
              let ctor_call = format_source_ctor_call h.star_unzip_ctor args in
              Printf.sprintf
                "  eq %s(eps) = eps .\n  eq %s(%s %s) = %s %s(%s) .\n"
                helper helper ctor_call rest arg helper rest)
          |> String.concat ""
        in
        var_decl ^ op_decls ^ eqs)
    |> String.concat ""

let opt_ctor_helper_block () =
  let helpers =
    !opt_ctor_helpers
    |> List.sort_uniq (fun a b ->
        compare (a.opt_ctor, a.opt_arity) (b.opt_ctor, b.opt_arity))
  in
  if helpers = [] then ""
  else
    helpers
    |> List.filter (fun h -> h.opt_arity = 1)
    |> List.map (fun h ->
        let stem = String.uppercase_ascii (sanitize h.opt_ctor) in
        let arg = Printf.sprintf "OPT-%s-A0" stem in
        let prefix = opt_prefix_name h.opt_ctor in
        let unzip = opt_unzip_name h.opt_ctor 0 in
        let ctor_call = format_source_ctor_call h.opt_ctor [arg] in
        Printf.sprintf
          "  var %s : SpectecTerminal .\n  op %s : SpectecTerminals -> SpectecTerminals .\n  op %s : SpectecTerminals -> SpectecTerminals .\n  eq %s(eps) = eps .\n  eq %s(%s) = %s .\n  eq %s(eps) = eps .\n  eq %s(%s) = %s .\n"
          arg prefix unzip prefix prefix arg ctor_call unzip unzip
          ctor_call arg)
    |> String.concat ""

let result_rel_helper_block () =
  let helpers =
    !result_rel_helpers
    |> List.sort_uniq (fun a b ->
        compare
          (a.result_rel_name, a.result_arity, a.result_arg_indices)
          (b.result_rel_name, b.result_arity, b.result_arg_indices))
  in
  if helpers = [] then ""
  else
    let relation_args vm conclusion =
      match conclusion.it with
      | TupE el -> List.map (fun x -> translate_exp TermCtx x vm) el
      | _ -> [translate_exp TermCtx conclusion vm]
    in
    let is_result_index h i = List.mem i h.result_arg_indices in
    let inputs_for h args =
      args
      |> List.mapi (fun i a -> if is_result_index h i then None else Some a)
      |> List.filter_map (fun x -> x)
    in
    let targets_for h args =
      args
      |> List.mapi (fun i a -> if is_result_index h i then Some a else None)
      |> List.filter_map (fun x -> x)
    in
    let helper_lhs helper_name (inputs : texpr list) =
      let lhs_args =
        inputs
        |> List.map (fun (t : texpr) -> t.text)
        |> String.concat " , "
      in
      if lhs_args = "" then helper_name
      else Printf.sprintf "%s ( %s )" helper_name lhs_args
    in
    let emit_result_rule rule_label helper_name (inputs : texpr list) (target : texpr) cond =
      let lhs = helper_lhs helper_name inputs in
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
      let helper_name =
        result_rel_helper_name h.result_rel_name h.result_arg_indices
      in
      let input_count = h.result_arity - List.length h.result_arg_indices in
      let op_args =
        if input_count <= 0 then ""
        else String.concat " " (List.init input_count (fun _ -> "SpectecTerminals"))
      in
      if op_args = "" then
        Printf.sprintf "  op %s : -> SpectecTerminals .\n" helper_name
      else
        Printf.sprintf "  op %s : %s -> SpectecTerminals .\n"
          helper_name op_args
    in
    let emit_helper h =
      match List.assoc_opt h.result_rel_name !infer_rel_rules with
      | None -> ""
      | Some rules ->
          let rel_prefix = String.uppercase_ascii (sanitize h.result_rel_name) in
          let helper_name =
            result_rel_helper_name h.result_rel_name h.result_arg_indices
          in
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
                  let args = relation_args vm conclusion in
                  if List.length args <> h.result_arity then ""
                  else
                    let inputs = inputs_for h args in
                    let targets = targets_for h args in
                    if targets = [] then ""
                    else
                      let target =
                        { text =
                            targets
                            |> List.map (fun (t : texpr) -> t.text)
                            |> String.concat " ";
                          vars =
                            targets
                            |> List.concat_map vars_of_texpr
                            |> List.sort_uniq String.compare }
                      in
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
                      let prem_conds =
                          prem_scheduled
                          |> List.map (fun (p : prem_sched) ->
                              match valid_mirror_call_of_rewrite_text p.text with
                              | Some mirror -> mirror
                              | None ->
                                  (match rewriteify_prem_text p.text with
                                   | Some rew -> rew
                                   | None -> prem_cond p.text))
                      in
                      let prem_cond_text = String.concat " " prem_conds in
                      if not (subset_bound bound_after target.vars)
                         && not (subset_bound (SSet.of_list (extract_vars_from_maude prem_cond_text)) target.vars)
                      then ""
                      else
                        let guard_conds =
                          if drop_runtime_typecheck_guards then []
                          else
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
                        let conds = prem_conds @ guard_conds in
                        let conds =
                          if uses_execution_rewrite_premise conds then
                            drop_execution_category_guards conds
                          else
                            conds
                        in
                        let cond = cond_join conds in
                        let rule_label =
                          Printf.sprintf "%s-r%d"
                            (String.sub helper_name 1 (String.length helper_name - 1))
                            rule_idx
                          |> String.lowercase_ascii
                        in
                        emit_result_rule rule_label helper_name inputs target cond)
          |> String.concat ""
    in
    "\n  --- Source-derived result mirrors for relation premises inside source defs.\n" ^
    "  --- They expose relation output witnesses to equational `def` clauses;\n" ^
    "  --- primary relation rl/crl rules remain the authoritative translation.\n" ^
    String.concat "" (List.map op_decl_for helpers) ^
    "\n" ^
    String.concat "\n" (List.map emit_helper helpers) ^ "\n"

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
	          if parse_source_ctor_surface_text core <> None then None
	          else match Str.split (Str.regexp "[ \t\n\r]+") core with
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
    let self_infer_forwards_target helper_name (target : texpr) prem_scheduled =
      let self_prefix = compact_ws helper_name in
      let target_text = compact_ws target.text in
      prem_scheduled
      |> List.exists (fun (p : prem_sched) ->
          let text = compact_ws p.text in
          starts_with text self_prefix
          &&
          try
            let i = Str.search_forward (Str.regexp_string "=>") text 0 in
            let rhs =
              String.sub text (i + 2) (String.length text - i - 2)
            in
            rhs = target_text
          with Not_found -> false)
    in
    let maude_var_token_occurs v text =
      replace_maude_var_token v "\000" text <> text
    in
    let self_recursive_progress_guards helper_name inputs prem_scheduled =
      let input_text = String.concat " " (List.map (fun (t : texpr) -> t.text) inputs) in
      let self_prefix = compact_ws helper_name in
      let self_prems =
        prem_scheduled
        |> List.filter (fun (p : prem_sched) ->
            starts_with (compact_ws p.text) self_prefix)
      in
      if self_prems = [] then []
      else
        inputs
        |> List.concat_map vars_of_texpr
        |> List.sort_uniq String.compare
        |> List.filter (fun v ->
            Hashtbl.mem source_var_seq_elem_sorts v
            && maude_var_token_occurs v input_text
            && List.exists
                 (fun (p : prem_sched) -> not (maude_var_token_occurs v p.text))
                 self_prems)
        |> List.map (fun v -> Printf.sprintf "_=/=_ ( %s, eps )" v)
	    in
	    let emit_infer_eq rule_label helper_name (inputs : texpr list) (target : texpr) cond =
	      let lhs = infer_lhs helper_name inputs in
	      let target_text = source_sequence_item_text target.text in
	      if cond = "" then
	        Printf.sprintf "  rl [%s] :\n    %s\n    =>\n    %s .\n"
	          rule_label lhs target_text
	      else
	        Printf.sprintf "  crl [%s] :\n    %s\n    =>\n    %s\n      if %s .\n"
	          rule_label lhs target_text cond
	    in
    let op_decl_for h =
      let helper_name = infer_rel_helper_name h.infer_rel_name h.infer_arg_index in
      let op_args =
        if h.infer_arity <= 1 then ""
        else String.concat " "
          (List.init (h.infer_arity - 1) (fun _ -> "SpectecTerminals"))
      in
      if op_args = "" then
        Printf.sprintf "  op %s : -> SpectecTerminals .\n" helper_name
      else
        Printf.sprintf "  op %s : %s -> SpectecTerminals .\n"
          helper_name op_args
    in
    let emit_iter_helper h =
      match find_iter_rel_helper_for_name h.infer_rel_name with
      | None -> ""
      | Some iter_h ->
          if h.infer_arg_index < 0
             || h.infer_arg_index >= iter_h.iter_arity
             || not (List.nth iter_h.iter_split_positions h.infer_arg_index)
          then ""
          else
            let helper_name =
              infer_rel_helper_name h.infer_rel_name h.infer_arg_index
            in
            let label_base =
              String.sub helper_name 1 (String.length helper_name - 1)
              |> String.lowercase_ascii
            in
            let base =
              iter_h.iter_helper_name
              |> String.map (function
                   | '$' | '-' -> '_'
                   | c -> Char.uppercase_ascii c)
              |> fun s -> Printf.sprintf "%s_INFER_ARG%d" s h.infer_arg_index
            in
            let arg_names =
              List.init iter_h.iter_arity (fun i ->
                  Printf.sprintf "%s-INFER-A%d" base i)
            in
            let elem_names =
              List.init iter_h.iter_arity (fun i ->
                  Printf.sprintf "%s-INFER-E%d" base i)
            in
            let rest_names =
              List.init iter_h.iter_arity (fun i ->
                  Printf.sprintf "%s-INFER-R%d" base i)
            in
            let split_elem_names =
              elem_names
              |> List.mapi (fun i v ->
                  if List.nth iter_h.iter_split_positions i then Some (i, v) else None)
              |> List.filter_map (fun x -> x)
            in
            let split_elem_terminal_names =
              split_elem_names
              |> List.filter_map (fun (i, v) ->
                  if i = h.infer_arg_index then None else Some v)
            in
            let split_elem_sequence_names =
              split_elem_names
              |> List.filter_map (fun (i, v) ->
                  if i = h.infer_arg_index then Some v else None)
            in
            let split_rest_names =
              rest_names
              |> List.mapi (fun i v ->
                  if List.nth iter_h.iter_split_positions i then Some v else None)
              |> List.filter_map (fun x -> x)
            in
            let texpr_of_text text =
              { text; vars = extract_vars_from_maude text }
            in
            let arg_text mode i =
              let a = List.nth arg_names i in
              let e = List.nth elem_names i in
              let r = List.nth rest_names i in
              match mode, List.nth iter_h.iter_split_positions i with
              | `Empty, true -> "eps"
              | `Empty, false -> a
              | `Cons, true -> Printf.sprintf "%s %s" e r
              | `Cons, false -> a
              | `Rel, true -> e
              | `Rel, false -> a
              | `Rec, true -> r
              | `Rec, false -> a
            in
            let inputs mode =
              List.init iter_h.iter_arity (fun i ->
                  if i = h.infer_arg_index then None
                  else Some (texpr_of_text (arg_text mode i)))
              |> List.filter_map (fun x -> x)
            in
            let rel_args mode =
              List.init iter_h.iter_arity (arg_text mode)
              |> String.concat " , "
            in
            let target_elem = List.nth elem_names h.infer_arg_index in
            let target_rest =
              Printf.sprintf "%s ( %s )" helper_name
                (inputs `Rec
                 |> List.map (fun (t : texpr) -> t.text)
                 |> String.concat " , ")
            in
            let target_rest =
              if inputs `Rec = [] then helper_name else target_rest
            in
            let source_helper =
              register_infer_rel_helper
                iter_h.iter_rel_name iter_h.iter_arity h.infer_arg_index
            in
            let source_helper_call =
              let source_inputs = inputs `Rel in
              if source_inputs = [] then source_helper
              else
                Printf.sprintf "%s ( %s )"
                  source_helper
                  (source_inputs
                   |> List.map (fun (t : texpr) -> t.text)
                   |> String.concat " , ")
            in
            let empty_eq =
              emit_infer_eq
                (label_base ^ "-empty")
                helper_name
                (inputs `Empty)
                (texpr_of_text "eps")
                ""
            in
            let cons_cond =
              cond_join [
                Printf.sprintf "%s => %s" source_helper_call target_elem;
                Printf.sprintf "%s ( %s ) => valid"
                  iter_h.iter_rel_name (rel_args `Rel);
              ]
            in
            let cons_target =
              texpr_of_text (Printf.sprintf "%s %s" target_elem target_rest)
            in
            let cons_eq =
              emit_infer_eq
                (label_base ^ "-cons")
                helper_name
                (inputs `Cons)
                cons_target
                cons_cond
            in
            let var_decl =
              "  vars " ^ String.concat " " arg_names ^ " : SpectecTerminals .\n" ^
              (if split_elem_terminal_names = [] then ""
               else
                 "  vars " ^ String.concat " " split_elem_terminal_names ^
                 " : SpectecTerminal .\n") ^
              (if split_elem_sequence_names = [] then ""
               else
                 "  vars " ^ String.concat " " split_elem_sequence_names ^
                 " : SpectecTerminals .\n") ^
              (if split_rest_names = [] then ""
               else
                 "  vars " ^ String.concat " " split_rest_names ^
                 " : SpectecTerminals .\n")
            in
            var_decl ^ empty_eq ^ cons_eq
    in
    let emit_helper h =
      match List.assoc_opt h.infer_rel_name !infer_rel_rules with
      | None -> emit_iter_helper h
      | Some rules ->
          let rel_prefix = String.uppercase_ascii (sanitize h.infer_rel_name) in
          let helper_name =
            infer_rel_helper_name h.infer_rel_name h.infer_arg_index
          in
          let infer_chunk_priority text =
            let s = String.trim text in
            let has_condition =
              try ignore (Str.search_forward (Str.regexp "\n[ \t]*if[ \t]+") s 0); true
              with Not_found -> false
            in
            if s <> "" && not has_condition then 1 else 0
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
                      let raw_target = target in
                      let target =
                        let target_vars = vars_of_texpr raw_target in
                        match clos_wrapper_inner_target bound_after raw_target with
                        | Some inner -> Some inner
                        | None ->
                            if subset_bound bound_after target_vars then Some raw_target
                            else None
                      in
                      match target with
                      | None ->
                          debug_iter "[INFER-SKIP] helper=%s target=%s bound=%s"
                            helper_name raw_target.text
                            (String.concat "," (SSet.elements bound_after));
                          ""
                      | Some target ->
                      if false then ""
                      else if has_immediate_self_infer helper_name inputs prem_scheduled then ""
                      else if self_infer_forwards_target helper_name target prem_scheduled then ""
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
                          if drop_runtime_typecheck_guards then []
                          else
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
                        let progress_conds =
                          self_recursive_progress_guards helper_name inputs prem_scheduled
                        in
                        let conds =
                          prem_match_conds @ prem_bool_conds @
                          progress_conds @ guard_conds
                        in
                        let conds =
                          if uses_execution_rewrite_premise
                               (List.map (fun (p : prem_sched) -> p.text) prem_scheduled)
                             || uses_execution_rewrite_premise conds
                          then drop_execution_category_guards conds
                          else conds
                        in
                        let cond =
                          cond_join conds
                        in
                        let rule_label =
                          Printf.sprintf "%s-r%d"
                            (String.sub helper_name 1 (String.length helper_name - 1))
                            rule_idx
                          |> String.lowercase_ascii
                        in
                        let base_eq = emit_infer_eq rule_label helper_name inputs target cond in
                        let optional_binder_eqs =
                          let lhs_texts =
                            (List.map (fun (t : texpr) -> t.text) inputs) @
                            [target.text]
                          in
                          optional_empty_substs binders vm lhs_texts
                          |> List.mapi (fun opt_i opt_vars ->
                              let rewrite_texpr (t : texpr) =
                                let text = apply_optional_empty_subst opt_vars t.text in
                                { text;
                                  vars =
                                    extract_vars_from_maude text
                                    |> List.filter is_bindable_name
                                    |> uniq_vars }
                              in
                              let inputs' = List.map rewrite_texpr inputs in
                              let target' = rewrite_texpr target in
                              let cond' =
                                cond_parts_of_text cond
                                |> List.filter (fun c ->
                                    not (cond_mentions_optional opt_vars c))
                                |> List.map (apply_optional_empty_subst opt_vars)
                                |> cond_join
                              in
                              emit_infer_eq
                                (rule_label ^
                                 Printf.sprintf "-opt-var-empty%d" opt_i)
                                helper_name inputs' target' cond')
                          |> String.concat ""
                        in
                        let typed_index_empty_eqs =
                          let cond_parts = cond_parts_of_text cond in
                          typed_index_empty_substs binders vm cond_parts
                          |> List.mapi (fun empty_i (drop_cond, empty_vars) ->
                              let rewrite_texpr (t : texpr) =
                                let text = replace_maude_vars_with_eps empty_vars t.text in
                                { text;
                                  vars =
                                    extract_vars_from_maude text
                                    |> List.filter is_bindable_name
                                    |> uniq_vars }
                              in
                              let inputs' = List.map rewrite_texpr inputs in
                              let target' = rewrite_texpr target in
                              let cond' =
                                cond_parts
                                |> List.filter (fun c ->
                                    String.trim c <> String.trim drop_cond)
                                |> List.map (replace_maude_vars_with_eps empty_vars)
                                |> cond_join
                              in
                              emit_infer_eq
                                (rule_label ^
                                 Printf.sprintf "-typed-index-empty%d" empty_i)
                                helper_name inputs' target' cond')
                          |> String.concat ""
                        in
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
                          base_eq ^ optional_binder_eqs ^ typed_index_empty_eqs ^ singleton_eq)
            |> List.mapi (fun order text -> (infer_chunk_priority text, order, text))
            |> List.sort (fun (pa, oa, _) (pb, ob, _) -> compare (pa, oa) (pb, ob))
            |> List.map (fun (_, _, text) -> text)
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
    let split_position_needs_sequence_chunk h i =
      !infer_rel_helpers
      |> List.exists (fun infer_h ->
          sanitize infer_h.infer_rel_name = sanitize h.iter_helper_name
          && infer_h.infer_arg_index = i)
    in
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
      let split_elem_name_pairs =
        elem_names
        |> List.mapi (fun i v ->
            if List.nth h.iter_split_positions i then Some (i, v) else None)
        |> List.filter_map (fun x -> x)
      in
      let split_elem_terminal_names =
        split_elem_name_pairs
        |> List.filter_map (fun (i, v) ->
            if split_position_needs_sequence_chunk h i then None else Some v)
      in
      let split_elem_sequence_names =
        split_elem_name_pairs
        |> List.filter_map (fun (i, v) ->
            if split_position_needs_sequence_chunk h i then Some v else None)
      in
      let split_rest_names =
        rest_names
        |> List.mapi (fun i v -> if List.nth h.iter_split_positions i then Some v else None)
        |> List.filter_map (fun x -> x)
      in
      let finite_elem_name i n =
        Printf.sprintf "%s-U%d_%d" base i n
      in
      let finite_elem_name_pairs =
        List.init h.iter_arity (fun i ->
            if List.nth h.iter_split_positions i then
              List.init direct_unroll_limit (fun n -> (i, finite_elem_name i (n + 1)))
            else [])
        |> List.flatten
      in
      let finite_elem_terminal_names =
        finite_elem_name_pairs
        |> List.filter_map (fun (i, v) ->
            if split_position_needs_sequence_chunk h i then None else Some v)
      in
      let finite_elem_sequence_names =
        finite_elem_name_pairs
        |> List.filter_map (fun (i, v) ->
            if split_position_needs_sequence_chunk h i then Some v else None)
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
        (if split_elem_terminal_names = [] then ""
         else "  vars " ^ String.concat " " split_elem_terminal_names ^ " : SpectecTerminal .\n") ^
        (if split_elem_sequence_names = [] then ""
         else "  vars " ^ String.concat " " split_elem_sequence_names ^ " : SpectecTerminals .\n") ^
        (if split_rest_names = [] then ""
         else "  vars " ^ String.concat " " split_rest_names ^ " : SpectecTerminals .\n") ^
        (if finite_elem_terminal_names = [] then ""
         else "  vars " ^ String.concat " " finite_elem_terminal_names ^ " : SpectecTerminal .\n") ^
        (if finite_elem_sequence_names = [] then ""
         else "  vars " ^ String.concat " " finite_elem_sequence_names ^ " : SpectecTerminals .\n")
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

let valid_rel_mirror_block () =
  let current_mirrors () = SSet.elements !valid_rel_mirrors |> List.sort_uniq compare in
  let raw_var_decl names sort =
    let names = names |> List.sort_uniq String.compare in
    if names = [] then "" else Printf.sprintf "  vars %s : %s .\n" (String.concat " " names) sort
  in
  let raw_typed_var_decls pairs =
    pairs
    |> List.sort_uniq compare
    |> List.fold_left (fun acc (v, s) ->
        let vs = match List.assoc_opt s acc with Some xs -> xs | None -> [] in
        (s, v :: vs) :: List.remove_assoc s acc)
      []
    |> List.map (fun (s, vs) -> raw_var_decl (List.rev vs) s)
    |> String.concat ""
  in
  let relation_args vm conclusion =
    match conclusion.it with
    | TupE el -> List.map (fun x -> translate_exp TermCtx x vm) el
    | _ -> [translate_exp TermCtx conclusion vm]
  in
  let contains_rewrite s =
    try ignore (Str.search_forward (Str.regexp_string "=>") s 0); true
    with Not_found -> false
  in
  let op_decl rel arity =
    Printf.sprintf "  op %s : %s -> Bool .\n"
      (valid_mirror_name rel)
      (String.concat " " (List.init arity (fun _ -> "SpectecTerminals")))
  in
  let emit_iter_mirror h =
    let rel = h.iter_helper_name in
    let mirror = valid_mirror_name rel in
    let base = String.uppercase_ascii (sanitize rel) in
    let arg_names = List.init h.iter_arity (fun i -> Printf.sprintf "%s-VALID-A%d" base i) in
    let elem_names = List.init h.iter_arity (fun i -> Printf.sprintf "%s-VALID-E%d" base i) in
    let rest_names = List.init h.iter_arity (fun i -> Printf.sprintf "%s-VALID-R%d" base i) in
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
    register_valid_rel_mirror h.iter_rel_name;
    let var_decl =
      raw_var_decl arg_names "SpectecTerminals" ^
      raw_var_decl split_elem_names "SpectecTerminal" ^
      raw_var_decl split_rest_names "SpectecTerminals"
    in
    Printf.sprintf
      "%s  eq %s ( %s ) = true .\n\
       \  ceq %s ( %s ) = %s ( %s )\n\
       \      if %s ( %s ) == true .\n"
      var_decl
      mirror (args `Empty)
      mirror (args `Cons) mirror (args `Rec)
      (valid_mirror_name h.iter_rel_name) (args `Rel)
  in
  let emit_source_mirror rel rules =
    let mirror = valid_mirror_name rel in
    let rel_prefix = String.uppercase_ascii (sanitize rel) in
    rules
    |> List.mapi (fun rule_idx r ->
        match r.it with
        | RuleD (case_id, binders, _, conclusion, prem_list) ->
            let raw_prefix = String.uppercase_ascii (sanitize case_id.it) in
            let case_part =
              if raw_prefix = "" then Printf.sprintf "R%d" rule_idx else raw_prefix
            in
            let prefix = Printf.sprintf "VALID-%s-%s" rel_prefix case_part in
	            let vm = binder_to_var_map prefix rule_idx binders in
	            reset_listn_pairs ();
	            record_listn_pairs_from_binders binders vm;
	            let relation_args_for_optional_indices indices =
	              with_optional_literal_empty_indices indices (fun () ->
	                  let arg_ts = relation_args vm conclusion in
	                  (arg_ts, !optional_literal_seen))
	            in
	            let arg_ts, optional_literal_count =
	              relation_args_for_optional_indices []
	            in
	            let optional_literal_indices =
	              List.init optional_literal_count (fun i -> i)
	            in
	            let seed =
	              arg_ts
              |> List.concat_map vars_of_texpr
              |> List.sort_uniq String.compare
              |> SSet.of_list
            in
            let prem_items = List.concat_map (prem_items_of_prem vm) prem_list in
            let prem_scheduled = schedule_prems seed [] prem_items in
            let prem_binds =
              prem_scheduled
              |> List.concat_map (fun (p : prem_sched) -> p.binds)
              |> List.sort_uniq String.compare
            in
            let bound_after = SSet.union seed (SSet.of_list prem_binds) in
            let cond_parts_opt =
              prem_scheduled
              |> List.fold_left (fun acc (p : prem_sched) ->
                  match acc with
                  | None -> None
                  | Some parts ->
                      (match valid_mirror_call_of_rewrite_text p.text with
                       | Some c -> Some (parts @ [c])
                       | None ->
                           if contains_rewrite p.text then None
                           else Some (parts @ [prem_cond p.text])))
                (Some [])
            in
            (match cond_parts_opt with
             | None -> ""
	             | Some cond_parts ->
	                 let bconds =
	                   executable_binder_var_sorts binders vm
	                   |> List.filter (fun (mv, _) -> SSet.mem mv bound_after)
	                   |> List.map (fun (mv, sort) -> exec_binder_guard mv sort)
	                   |> List.sort_uniq String.compare
	                 in
	                 let cond = cond_join (cond_parts @ bconds) in
	                 let emit_eq arg_ts =
	                   let lhs =
	                     Printf.sprintf "%s ( %s )"
	                       mirror
	                       (String.concat " , "
	                          (List.map (fun (t : texpr) -> t.text) arg_ts))
	                   in
	                   let all_vars =
	                     vm
	                     |> List.map snd
	                     |> List.sort_uniq String.compare
	                   in
	                   let typed_vars =
	                     executable_binder_var_sorts binders vm
	                     |> List.filter (fun (v, _) -> List.mem v all_vars)
	                     |> List.sort_uniq compare
	                   in
	                   let typed_vars_for_decl =
	                     typed_vars
	                     |> List.map (fun (v, sort) ->
	                         if preserve_narrow_lhs_sort sort then (v, sort)
	                         else (v, "SpectecTerminal"))
	                     |> List.sort_uniq compare
	                   in
	                   let typed_names = List.map fst typed_vars in
	                   let untyped =
	                     all_vars
	                     |> List.filter (fun v -> not (List.mem v typed_names))
	                     |> List.sort_uniq String.compare
	                   in
	                   let decls =
	                     raw_typed_var_decls typed_vars_for_decl
	                     ^ raw_var_decl untyped "SpectecTerminal"
	                   in
	                   if cond = "" then
	                     Printf.sprintf "%s  eq %s = true .\n" decls lhs
	                   else
	                     Printf.sprintf "%s  ceq %s = true\n      if %s .\n"
	                       decls lhs cond
	                 in
	                 let optional_eqs =
	                   optional_literal_indices
	                   |> nonempty_subsets
	                   |> List.map (fun indices ->
	                       let args, _ = relation_args_for_optional_indices indices in
	                       emit_eq args)
	                   |> String.concat ""
	                 in
	                 emit_eq arg_ts ^ optional_eqs))
    |> String.concat ""
  in
  let emit_one rel =
    match
      !iter_rel_helpers
      |> List.find_opt (fun h -> sanitize h.iter_helper_name = sanitize rel)
    with
    | Some h -> emit_iter_mirror h
    | None ->
        (match List.assoc_opt (sanitize rel) !infer_rel_rules with
         | Some rules -> emit_source_mirror rel rules
         | None -> "")
  in
  let rec discover_closure () =
    let before = current_mirrors () in
    ignore (List.map emit_one before);
    let after = current_mirrors () in
    if before <> after then discover_closure ()
  in
  discover_closure ();
  let mirrors = current_mirrors () in
  if mirrors = [] then ""
  else
    let op_decls =
      mirrors
      |> List.map (fun rel ->
          match
            !iter_rel_helpers
            |> List.find_opt (fun h -> sanitize h.iter_helper_name = sanitize rel)
          with
          | Some h -> op_decl rel h.iter_arity
          | None ->
              let arity =
                match List.assoc_opt (sanitize rel) !infer_rel_rules with
                | Some (r :: _) ->
                    (match r.it with
                     | RuleD (_, _, _, conclusion, _) ->
                         (match conclusion.it with TupE el -> List.length el | _ -> 1))
                | _ -> 0
              in
              op_decl rel arity)
      |> String.concat ""
    in
    "\n  --- Source-derived Boolean mirrors for relation premises inside source defs.\n" ^
    "  --- These let `def` clauses remain equations when their premises only\n" ^
    "  --- need to check an already-bound relation judgement.\n" ^
    op_decls ^ "\n" ^
    (mirrors |> List.map emit_one |> String.concat "\n") ^ "\n"

let otherwise_match_helper_block () =
  let helpers =
    !otherwise_match_helpers
    |> List.sort_uniq (fun a b ->
        compare
          (a.otherwise_match_name, a.otherwise_match_pattern)
          (b.otherwise_match_name, b.otherwise_match_pattern))
  in
  if helpers = [] then ""
  else
    let emit h =
      let base =
        h.otherwise_match_name
        |> String.map (function '$' | '-' -> '_' | c -> Char.uppercase_ascii c)
      in
      let miss_var = base ^ "_OTHER" in
      let pattern_vars =
        extract_vars_from_maude h.otherwise_match_pattern
        |> List.filter (fun v -> not (is_generated_free_const_name v))
        |> List.sort_uniq String.compare
      in
      let vars_decl =
        declare_vars_same_sort (miss_var :: pattern_vars) "SpectecTerminal"
      in
      Printf.sprintf
        "  op %s : SpectecTerminal -> Bool .\n%s\
         \n  eq %s ( %s ) = true .\n\
         \n  eq %s ( %s ) = false [owise] .\n"
        h.otherwise_match_name
        vars_decl
        h.otherwise_match_name h.otherwise_match_pattern
        h.otherwise_match_name miss_var
    in
    "\n  --- Source-derived decision predicates for `-- otherwise` rules.\n" ^
    "  --- Each predicate mirrors the positive pattern that the otherwise\n" ^
    "  --- rule must exclude; the original source rules remain rl/crl.\n" ^
    String.concat "\n" (List.map emit helpers) ^ "\n"

let map_call_helper_block () =
  let helpers =
    !map_call_helpers
    |> List.sort_uniq (fun a b ->
        compare
          (a.map_helper_name, a.map_fn_name, a.map_arity, a.map_seq_index,
           a.map_arg_sorts, a.map_preserve_nested)
          (b.map_helper_name, b.map_fn_name, b.map_arity, b.map_seq_index,
           b.map_arg_sorts, b.map_preserve_nested))
  in
  if helpers = [] then ""
  else
    let singularize_source_plural name =
      if ends_with name "uses" then
        String.sub name 0 (String.length name - 1)
      else if ends_with name "ies" && String.length name > 3 then
        String.sub name 0 (String.length name - 3) ^ "y"
      else if ends_with name "s" && String.length name > 1 then
        String.sub name 0 (String.length name - 1)
      else name
    in
    let infer_explicit_map_seq_sort h =
      match map_helper_output_seq_sort h with
      | Some seq_sort -> Some seq_sort
      | None ->
          let prefix = "$subst-" in
          if starts_with h.map_helper_name prefix then
            let plural =
              String.sub h.map_helper_name (String.length prefix)
                (String.length h.map_helper_name - String.length prefix)
            in
            let source_sort =
              plural |> singularize_source_plural |> sort_of_type_name
            in
            sequence_sort_for_elem_sort source_sort
          else None
    in
	    let emit h =
	      let base =
	        let raw =
	          h.map_helper_name
	          |> sanitize
	          |> String.map (function '$' -> 'S' | c -> Char.uppercase_ascii c)
	        in
	        if raw = "" then "MAP"
	        else
	          match raw.[0] with
	          | 'A' .. 'Z' -> raw
	          | _ -> "MAP" ^ raw
	      in
		      let arg_names =
		        List.init h.map_arity (fun i -> Printf.sprintf "%s-A%d" base i)
		      in
		      let seq = base ^ "-S" in
	      let op_sorts = String.concat " " h.map_arg_sorts in
      let call_arg_list repl =
        arg_names
        |> List.mapi (fun i a -> if i = h.map_seq_index then repl else a)
      in
      let call_args repl =
        call_arg_list repl |> String.concat " , "
      in
      let helper_args repl = call_args repl in
      let source_call repl =
        format_source_def_call h.map_fn_name (call_arg_list repl)
        |> preserve_nested_sequence_call h.map_preserve_nested h.map_fn_name
      in
      let optional_result_map = source_def_returns_optional h.map_fn_name in
      let direct_sequence_recursion =
        h.map_arg_sorts
        |> List.mapi (fun i sort -> i <> h.map_seq_index && sort = "SpectecTerminals")
        |> List.exists (fun x -> x)
      in
      let explicit_seq_sort = infer_explicit_map_seq_sort h in
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
	          Printf.sprintf "  var %s-E : SpectecTerminal .\n  var %s : SpectecTerminals .\n"
	            base seq
        else
          Printf.sprintf "  var %s : SpectecTerminals .\n" seq
      in
      let map_block =
        if direct_sequence_recursion then
	          let elem = base ^ "-E" in
          if optional_result_map then
            Printf.sprintf
              "  op %s : %s -> SpectecTerminals .\n%s%s\
               \n  eq %s ( %s ) = eps .\n\
               \n  ceq %s ( %s ) = $none\n\
                 if %s == eps .\n\
               \n  ceq %s ( %s ) = %s\n\
                 if %s =/= eps .\n\
               \n  ceq %s ( %s ) = $none %s ( %s )\n\
                 if %s =/= eps /\\ %s == eps .\n\
               \n  ceq %s ( %s ) = %s %s ( %s )\n\
                 if %s =/= eps /\\ %s =/= eps .\n"
              h.map_helper_name op_sorts var_decl ""
              h.map_helper_name (helper_args "eps")
              h.map_helper_name (helper_args elem)
              (source_call elem)
              h.map_helper_name (helper_args elem)
              (source_call elem)
              (source_call elem)
              h.map_helper_name (helper_args (Printf.sprintf "%s %s" elem seq))
              h.map_helper_name (helper_args seq)
              seq
              (source_call elem)
              h.map_helper_name (helper_args (Printf.sprintf "%s %s" elem seq))
              (source_call elem)
              h.map_helper_name (helper_args seq)
              seq
              (source_call elem)
          else
            Printf.sprintf
              "  op %s : %s -> SpectecTerminals .\n%s%s\
               \n  eq %s ( %s ) = eps .\n\
               %s\
               \n  eq %s ( %s ) = %s .\n\
               \n  ceq %s ( %s ) = %s %s ( %s )\n\
                 if %s =/= eps .\n"
              h.map_helper_name op_sorts var_decl ""
              h.map_helper_name (helper_args "eps")
              ""
              h.map_helper_name (helper_args elem)
              (source_call elem)
              h.map_helper_name (helper_args (Printf.sprintf "%s %s" elem seq))
              (source_call elem)
              h.map_helper_name (helper_args seq)
              seq
        else
          let head = Printf.sprintf "index ( %s, 0 )" seq in
          let tail =
            Printf.sprintf "slice ( %s, 1, _-_ ( len ( %s ), 1 ) )" seq seq
          in
          if optional_result_map then
            Printf.sprintf
              "  op %s : %s -> SpectecTerminals .\n%s\
               \n  eq %s ( %s ) = eps .\n\
               \n  ceq %s ( %s ) = $none %s ( %s )\n\
                    if _>_ ( len ( %s ), 0 ) /\\ %s == eps .\n\
               \n  ceq %s ( %s ) = %s %s ( %s )\n\
                    if _>_ ( len ( %s ), 0 ) /\\ %s =/= eps .\n"
              h.map_helper_name op_sorts var_decl
              h.map_helper_name (helper_args "eps")
              h.map_helper_name (helper_args seq)
              h.map_helper_name (helper_args tail)
              seq
              (source_call head)
              h.map_helper_name (helper_args seq)
              (source_call head)
              h.map_helper_name (helper_args tail)
              seq
              (source_call head)
          else
            Printf.sprintf
              "  op %s : %s -> SpectecTerminals .\n%s\
               \n  eq %s ( %s ) = eps .\n\
               \n  ceq %s ( %s ) = %s %s ( %s )\n      if _>_ ( len ( %s ), 0 ) .\n"
              h.map_helper_name op_sorts var_decl
              h.map_helper_name (helper_args "eps")
              h.map_helper_name (helper_args seq)
              (source_call head)
              h.map_helper_name (helper_args tail)
              seq
      in
      let explicit_seq_block =
        ""
      in
      let unmap_block =
        let unmap_name = unmap_call_helper_name h.map_helper_name in
        if h.map_arity = 1 && h.map_seq_index = 0
           && unmap_helper_is_used unmap_name then
          match explicit_seq_sort,
                List.nth_opt h.map_arg_sorts h.map_seq_index with
          | Some _out_seq_sort, Some _in_seq_sort when false ->
	              let elem = base ^ "-UNMAP-E" in
	              let left = base ^ "-UNMAP-LEFT" in
	              let right = base ^ "-UNMAP-RIGHT" in
              let out_concat = sequence_concat_name _out_seq_sort in
              let in_concat = sequence_concat_name _in_seq_sort in
              let elem_sort =
                match elem_sort_of_sequence_sort _in_seq_sort with
                | Some sort -> sort
                | None -> "SpectecTerminal"
              in
              Printf.sprintf
                "\n  op %s : %s -> %s .\n\
                 \n  var %s : %s .\n  vars %s %s : %s .\n\
                 \n  eq %s ( eps ) = eps .\n\
                 \n  eq %s ( %s ( %s ) ) = %s .\n\
                 \n  eq %s ( %s ( %s, %s ) ) = %s ( %s ( %s ), %s ( %s ) ) .\n"
                unmap_name _out_seq_sort _in_seq_sort
                elem elem_sort left right _out_seq_sort
                unmap_name
                unmap_name h.map_fn_name elem elem
                unmap_name out_concat left right in_concat
                unmap_name left unmap_name right
          | _ ->
	              let elem = base ^ "-E" in
              let mapped_elem =
                format_source_def_call h.map_fn_name [elem]
                |> preserve_nested_sequence_call
                     h.map_preserve_nested h.map_fn_name
              in
              Printf.sprintf
                "\n  op %s : SpectecTerminals -> SpectecTerminals .\n\
                 \n  var %s : SpectecTerminal .\n\
                 \n  eq %s ( eps ) = eps .\n\
                 \n  eq %s ( %s %s ) = %s %s ( %s ) .\n"
                unmap_name
                elem
                unmap_name
                unmap_name mapped_elem seq elem unmap_name seq
        else ""
      in
      map_block ^ explicit_seq_block ^ unmap_block
    in
    "\n  --- Generic SpecTec expression-star lowering for source expressions e*.\n" ^
    "  --- Each helper maps one iterated source argument over a flat sequence.\n" ^
    String.concat "\n" (List.map emit helpers) ^ "\n"

let expr_map_helper_block () =
  let helpers =
    !expr_map_helpers
    |> List.sort_uniq (fun a b ->
        compare
          (a.expr_map_helper_name, a.expr_map_body, a.expr_map_seq_vars,
           a.expr_map_fixed_vars)
          (b.expr_map_helper_name, b.expr_map_body, b.expr_map_seq_vars,
           b.expr_map_fixed_vars))
  in
  if helpers = [] then ""
  else
    let unary_ctor_map h =
      match h.expr_map_seq_vars, h.expr_map_fixed_vars,
            parse_call_text h.expr_map_body with
      | [seq_var], [], Some (ctor, [arg])
          when is_source_ctor_name ctor
               && (strip_wrapping_parens arg |> String.trim) = seq_var ->
          Some ctor
      | _ -> None
    in
    let emit h =
      let base =
        h.expr_map_helper_name
        |> sanitize
        |> String.map (function '$' -> 'S' | c -> Char.uppercase_ascii c)
      in
      let elem_names =
        h.expr_map_seq_vars
        |> List.mapi (fun i _ -> Printf.sprintf "%s-E%d" base i)
      in
      let rest_names =
        h.expr_map_seq_vars
        |> List.mapi (fun i _ -> Printf.sprintf "%s-R%d" base i)
      in
      let arg_sorts =
        (h.expr_map_fixed_vars |> List.map snd)
        @ (h.expr_map_seq_vars |> List.map (fun _ -> "SpectecTerminals"))
      in
      let op_sorts = String.concat " " arg_sorts in
      let fixed_args = h.expr_map_fixed_vars |> List.map fst in
      let call_args seq_args = String.concat " , " (fixed_args @ seq_args) in
      let empty_eqs =
        h.expr_map_seq_vars
        |> List.mapi (fun i _ ->
            let seq_args =
              h.expr_map_seq_vars
              |> List.mapi (fun j v -> if i = j then "eps" else v)
            in
            Printf.sprintf "  eq %s ( %s ) = eps ."
              h.expr_map_helper_name (call_args seq_args))
        |> String.concat "\n"
      in
      let head_seq_args =
        List.map2 (fun e r -> Printf.sprintf "%s %s" e r) elem_names rest_names
      in
      let body =
        let renames = List.combine h.expr_map_seq_vars elem_names in
        (rename_texpr_vars renames { text = h.expr_map_body; vars = h.expr_map_seq_vars }).text
      in
      let rest_seq_args = rest_names in
      let fixed_decl = declare_vars_by_sort h.expr_map_fixed_vars in
      let seq_decl =
        h.expr_map_seq_vars
        |> List.map (fun v -> (v, "SpectecTerminals"))
        |> declare_vars_by_sort
      in
      let elem_decl =
        elem_names
        |> List.map (fun v -> (v, "SpectecTerminal"))
        |> declare_vars_by_sort
      in
      let rest_decl =
        rest_names
        |> List.map (fun v -> (v, "SpectecTerminals"))
        |> declare_vars_by_sort
      in
      let unmap_block =
        match unary_ctor_map h with
        | None ->
            (match expr_map_tuple_body_order h with
             | None -> ""
             | Some body_order ->
                 let arity = List.length h.expr_map_seq_vars in
                 let tuple_name =
                   expr_map_tuple_helper_name h.expr_map_helper_name
                 in
                 let unmap_name =
                   unmap_call_helper_name h.expr_map_helper_name
                 in
                 if not (unmap_helper_is_used unmap_name) then ""
                 else
                 let unmap_elem_names =
                   List.init arity
                     (fun i -> Printf.sprintf "%s-UNMAP-E%d" base i)
                 in
                 let unmap_state_names =
                   List.init arity
                     (fun i -> Printf.sprintf "%s-UNMAP-S%d" base i)
                 in
                 let unmap_rest = base ^ "-UNMAP-REST" in
                 let index_of x xs =
                   let rec loop i = function
                     | [] -> 0
                     | y :: ys -> if x = y then i else loop (i + 1) ys
                   in
                   loop 0 xs
                 in
                 let tuple_sorts =
                   List.init arity (fun _ -> "SpectecTerminals")
                   |> String.concat " "
                 in
                 let tuple_empty_args =
                   List.init arity (fun _ -> "eps") |> String.concat ", "
                 in
                 let tuple_state_args = String.concat ", " unmap_state_names in
                 let unmap_pattern =
                   String.concat " " (unmap_elem_names @ [unmap_rest])
                 in
                 let result_args =
                   h.expr_map_seq_vars
                   |> List.mapi (fun seq_i seq_var ->
                        let body_i = index_of seq_var body_order in
                        Printf.sprintf "%s %s"
                          (List.nth unmap_elem_names body_i)
                          (List.nth unmap_state_names seq_i))
                   |> String.concat ", "
                 in
                 let elem_decl =
                   unmap_elem_names
                   |> List.map (fun v -> (v, "SpectecTerminal"))
                   |> declare_vars_by_sort
                 in
                 let state_decl =
                   (unmap_rest, "SpectecTerminals")
                   :: (unmap_state_names
                       |> List.map (fun v -> (v, "SpectecTerminals")))
                   |> declare_vars_by_sort
                 in
                 Printf.sprintf
                   "\n  op %s : %s -> SpectecTerminal [ctor] .\n\
                    \n  op %s : SpectecTerminals -> SpectecTerminal .\n%s%s\
                    \n  eq %s ( eps ) = %s ( %s ) .\n\
                    \n  ceq %s ( %s ) = %s ( %s )\n\
                    \      if %s ( %s ) := %s ( %s ) .\n"
                   tuple_name tuple_sorts
                   unmap_name elem_decl state_decl
                   unmap_name tuple_name tuple_empty_args
                   unmap_name unmap_pattern tuple_name result_args
                   tuple_name tuple_state_args unmap_name unmap_rest)
        | Some ctor ->
            let unmap_name = unmap_call_helper_name h.expr_map_helper_name in
            if not (unmap_helper_is_used unmap_name) then ""
            else
            let elem = base ^ "-UNMAP-E" in
            let rest = base ^ "-UNMAP-R" in
            let unmap_decl =
              declare_vars_by_sort
                [ (elem, "SpectecTerminal"); (rest, "SpectecTerminals") ]
            in
            Printf.sprintf
              "\n  op %s : SpectecTerminals -> SpectecTerminals .\n%s\
               \n  eq %s ( eps ) = eps .\n\
               \n  eq %s ( %s ( %s ) %s ) = %s %s ( %s ) .\n"
              unmap_name unmap_decl
              unmap_name
              unmap_name ctor elem rest elem unmap_name rest
      in
      Printf.sprintf
        "  op %s : %s -> SpectecTerminals .\n%s%s%s%s\n%s\n\
         \n  eq %s ( %s ) = %s %s ( %s ) .\n"
        h.expr_map_helper_name op_sorts
        fixed_decl seq_decl elem_decl rest_decl
        empty_eqs
        h.expr_map_helper_name (call_args head_seq_args)
        body
        h.expr_map_helper_name (call_args rest_seq_args)
      ^ unmap_block
    in
    "\n  --- Generic SpecTec expression-star lowering for nested e* bodies.\n" ^
    String.concat "\n" (List.map emit helpers) ^ "\n"

let zip_map_call_helper_block () =
  let helpers =
    !zip_map_call_helpers
    |> List.sort_uniq (fun a b ->
        compare
          (a.zip_map_helper_name, a.zip_map_fn_name, a.zip_map_arity,
           a.zip_map_seq_indices, a.zip_map_arg_sorts,
           a.zip_map_preserve_nested)
          (b.zip_map_helper_name, b.zip_map_fn_name, b.zip_map_arity,
           b.zip_map_seq_indices, b.zip_map_arg_sorts,
           b.zip_map_preserve_nested))
  in
  if helpers = [] then ""
  else
    let emit h =
      let base =
        let raw =
          h.zip_map_helper_name
          |> sanitize
          |> String.map (function '$' -> 'S' | c -> Char.uppercase_ascii c)
        in
        if raw = "" then "ZIPMAP"
        else match raw.[0] with 'A' .. 'Z' -> raw | _ -> "ZIPMAP" ^ raw
      in
      let arg_names =
        List.init h.zip_map_arity (fun i -> Printf.sprintf "%s-A%d" base i)
      in
      let seq_elem i = Printf.sprintf "%s-E%d" base i in
      let seq_rest i = Printf.sprintf "%s-R%d" base i in
      let op_sorts = String.concat " " h.zip_map_arg_sorts in
      let arg_sort i =
        match List.nth_opt h.zip_map_arg_sorts i with
        | Some sort -> sort
        | None -> "SpectecTerminal"
      in
      let call_arg_list repl =
        arg_names
        |> List.mapi (fun i a ->
            match List.assoc_opt i repl with
            | Some r -> r
            | None -> a)
      in
      let call_args repl = call_arg_list repl |> String.concat " , " in
      let source_call repl =
        format_source_def_call h.zip_map_fn_name (call_arg_list repl)
        |> preserve_nested_sequence_call
             h.zip_map_preserve_nested h.zip_map_fn_name
      in
      let optional_result_map = source_def_returns_optional h.zip_map_fn_name in
      let fixed_decl =
        arg_names
        |> List.mapi (fun i a ->
            if List.mem i h.zip_map_seq_indices then None
            else Some (a, arg_sort i))
        |> List.filter_map (fun x -> x)
        |> declare_vars_by_sort
      in
      let seq_arg_decl =
        h.zip_map_seq_indices
        |> List.map (fun i -> (List.nth arg_names i, "SpectecTerminals"))
        |> declare_vars_by_sort
      in
      let elem_decl =
        h.zip_map_seq_indices
        |> List.map (fun i -> (seq_elem i, "SpectecTerminal"))
        |> declare_vars_by_sort
      in
      let rest_decl =
        h.zip_map_seq_indices
        |> List.map (fun i -> (seq_rest i, "SpectecTerminals"))
        |> declare_vars_by_sort
      in
      let empty_eqs =
        h.zip_map_seq_indices
        |> List.map (fun i ->
            let repl = [(i, "eps")] in
            Printf.sprintf "  eq %s ( %s ) = eps ."
              h.zip_map_helper_name (call_args repl))
        |> String.concat "\n"
      in
      let head_repl =
        h.zip_map_seq_indices
        |> List.map (fun i -> (i, Printf.sprintf "%s %s" (seq_elem i) (seq_rest i)))
      in
      let elem_repl =
        h.zip_map_seq_indices
        |> List.map (fun i -> (i, seq_elem i))
      in
      let rest_repl =
        h.zip_map_seq_indices
        |> List.map (fun i -> (i, seq_rest i))
      in
      if optional_result_map then
        Printf.sprintf
          "  op %s : %s -> SpectecTerminals .\n%s%s%s%s\n%s\n\
           \n  ceq %s ( %s ) = $none %s ( %s )\n\
                if %s == eps .\n\
           \n  ceq %s ( %s ) = %s %s ( %s )\n\
                if %s =/= eps .\n"
          h.zip_map_helper_name op_sorts
          fixed_decl seq_arg_decl elem_decl rest_decl
          empty_eqs
          h.zip_map_helper_name (call_args head_repl)
          h.zip_map_helper_name (call_args rest_repl)
          (source_call elem_repl)
          h.zip_map_helper_name (call_args head_repl)
          (source_call elem_repl)
          h.zip_map_helper_name (call_args rest_repl)
          (source_call elem_repl)
      else
        Printf.sprintf
          "  op %s : %s -> SpectecTerminals .\n%s%s%s%s\n%s\n\
           \n  eq %s ( %s ) = %s %s ( %s ) .\n"
          h.zip_map_helper_name op_sorts
          fixed_decl seq_arg_decl elem_decl rest_decl
          empty_eqs
          h.zip_map_helper_name (call_args head_repl)
          (source_call elem_repl)
          h.zip_map_helper_name (call_args rest_repl)
    in
    "\n  --- Source-derived zip lowering for source expressions e* with multiple\n" ^
    "  --- iterated arguments consumed in lockstep.\n" ^
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
  if not (starts_with s "op ") || not (String.contains s ':') then false
  else
    let rest = String.sub s 3 (String.length s - 3) |> String.trim in
    match Str.split (Str.regexp "[ \t]+") rest with
    | name :: _ -> is_source_ctor_name name
    | [] -> false

let zero_arity_ctor_sort_name ctor =
  "Sort" ^ ctor

let collect_zero_arity_ctor_memberships eq_lines =
  let re =
    Str.regexp "^[ \t]*mb[ \t]+([ \t]*\\([A-Za-z0-9_'-]+\\)[ \t]*)[ \t]*:[ \t]*\\([A-Za-z0-9_-]+\\)[ \t]*\\."
  in
  let tbl = Hashtbl.create 256 in
  List.iter (fun l ->
    if Str.string_match re l 0 then
      match str_matched_group_opt 1 l, str_matched_group_opt 2 l with
      | Some ctor, Some sort
          when (match source_ctor_arity ctor with Some 0 -> true | Some _ | None -> false) ->
          let sorts =
            match Hashtbl.find_opt tbl ctor with
            | Some xs -> xs
            | None -> []
          in
          Hashtbl.replace tbl ctor (sort :: sorts)
      | _ -> ())
	    eq_lines;
	  tbl

let collect_ctor_decl_lines _eq_lines =
  Hashtbl.to_seq_values source_ctor_by_name
  |> List.of_seq
  |> List.sort_uniq (fun a b ->
       compare
         (a.source_ctor_name, a.source_ctor_arity, a.source_ctor_key)
         (b.source_ctor_name, b.source_ctor_arity, b.source_ctor_key))
  |> List.map (fun info ->
       let nm = info.source_ctor_name in
       let op_nm = source_ctor_op_name info in
       let arity = info.source_ctor_arity in
       let arrow = "->" in
       if arity = 0 then
         Printf.sprintf "  op %s : -> SpectecTerminal [ctor] ." op_nm
       else
         let refine_arg_sort decl membership =
           let membership_decl = ctor_decl_arg_sort membership in
           if decl = membership_decl then decl
           else if decl = "SpectecTerminals" || membership_decl = "SpectecTerminals" then
             "SpectecTerminals"
           else if ends_with decl "Seq" && ends_with membership_decl "Seq" then
             "SpectecTerminals"
           else if decl = "SpectecTerminal" || membership_decl = "SpectecTerminal" then
             "SpectecTerminal"
           else "SpectecTerminal"
         in
         let args =
           match Hashtbl.find_opt ctor_arg_sort_hints nm,
                 Hashtbl.find_opt ctor_arg_membership_sort_hints nm with
           | Some sorts, Some membership_sorts
             when List.length sorts = arity
                  && List.length membership_sorts = arity ->
               List.map2 refine_arg_sort sorts membership_sorts
               |> fun sorts -> sorts
           | Some sorts, _ when List.length sorts = arity ->
               sorts
           | _, Some membership_sorts when List.length membership_sorts = arity ->
               membership_sorts
               |> List.map ctor_decl_arg_sort
               |> fun sorts -> sorts
           | _ ->
               List.init arity (fun _ -> "SpectecTerminal")
         in
        Printf.sprintf "  op %s : %s %s SpectecTerminal [ctor] ."
          op_nm (String.concat " " args) arrow)

let infer_category_subsort_decls eq_lines =
  let eq_lines = List.concat_map (String.split_on_char '\n') eq_lines in
  let re =
    Str.regexp
      "^[ \t]+\\(mb\\|cmb\\)[ \t]+( \\(.*\\) )[ \t]+:[ \t]+\\([A-Za-z][A-Za-z0-9-]*\\)\\([ \t]*\\.\\|[ \t]*$\\)"
  in
  let collectable_pattern lhs =
    let pattern = strip_wrapping_parens lhs |> String.trim in
    let head =
      match Str.split (Str.regexp "[ \t\n\r(,]+") pattern with
      | h :: _ -> Some h
      | [] -> None
    in
    (match head with
     | Some head when is_source_ctor_name head -> true
     | _ -> not (is_plain_var_like pattern))
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
        | Some lhs, Some sort when collectable_pattern lhs ->
            add sort (String.trim lhs)
        | _ -> ()
      else ())
    eq_lines;
  let pairs =
    Hashtbl.fold (fun s lhs acc -> (s, lhs) :: acc) by_sort []
  in
  pairs
  |> List.concat_map (fun (child, child_lhs) ->
       pairs
       |> List.filter_map (fun (parent, parent_lhs) ->
	            if child <> parent
                 && not (SSet.mem child !specialized_syntax_sort_names)
                 && not (SSet.mem parent !specialized_syntax_sort_names)
	               && SSet.cardinal child_lhs > 0
               && SSet.cardinal child_lhs < SSet.cardinal parent_lhs
               && SSet.subset child_lhs parent_lhs
            then Some (Printf.sprintf "  subsort %s < %s ." child parent)
            else None))
  |> List.sort_uniq String.compare

let record_inferred_category_subsorts subsort_decls =
  let re =
    Str.regexp
      "^[ \t]*subsort[ \t]+\\([A-Za-z][A-Za-z0-9-]*\\)[ \t]+<[ \t]+\\([A-Za-z][A-Za-z0-9-]*\\)[ \t]*\\."
  in
  List.iter
    (fun line ->
      if Str.string_match re line 0 then
        match str_matched_group_opt 1 line, str_matched_group_opt 2 line with
        | Some child, Some parent ->
            let old =
              match Hashtbl.find_opt source_category_subsort_edges child with
              | Some parents -> parents
              | None -> SSet.empty
            in
            Hashtbl.replace source_category_subsort_edges child
              (SSet.add parent old)
        | _ -> ())
    subsort_decls

let lift_category_subsorts_to_sequence_subsorts subsort_decls =
  let re =
    Str.regexp
      "^[ \t]*subsort[ \t]+\\([A-Za-z][A-Za-z0-9-]*\\)[ \t]+<[ \t]+\\([A-Za-z][A-Za-z0-9-]*\\)[ \t]*\\."
  in
  subsort_decls
  |> List.filter_map (fun line ->
       if Str.string_match re line 0 then
         match str_matched_group_opt 1 line, str_matched_group_opt 2 line with
         | Some child, Some parent
             when SSet.mem child !native_sequence_source_sorts
               && SSet.mem parent !native_sequence_source_sorts ->
             Some (Printf.sprintf "  subsort %s < %s ."
                     (native_sequence_sort_name child)
                     (native_sequence_sort_name parent))
         | _ -> None
       else None)
  |> List.sort_uniq String.compare

let translate defs =
  iter_rel_helpers := [];
  infer_rel_helpers := [];
  result_rel_helpers := [];
  listn_index_vars := SSet.empty;
  infer_rel_rules := [];
  valid_rel_mirrors := SSet.empty;
  ref_subtype_decision_fragments := [];
  heaptype_decision_ground_edges := [];
  map_call_helpers := [];
  zip_map_call_helpers := [];
  expr_map_helpers := [];
  otherwise_match_helpers := [];
  star_ctor_unzip_helpers := [];
  opt_ctor_helpers := [];
  Hashtbl.clear source_ctor_by_key;
  Hashtbl.clear source_ctor_by_name;
  Hashtbl.clear source_ctor_by_surface_head_arity;
  Hashtbl.clear source_ctor_by_original_head_arity;
  Hashtbl.clear source_ctor_name_counts;
  Hashtbl.clear source_ctor_head_categories;
  Hashtbl.clear source_ctor_head_occurrences;
  Hashtbl.clear source_ctor_head_category_arities;
  source_ctor_heads_requiring_category_suffix := SSet.empty;
  source_ctor_head_categories_requiring_arg_suffix := SSet.empty;
  source_ctor_blocked_var_names := SSet.empty;
  Hashtbl.clear ctor_arg_sort_hints;
  Hashtbl.clear ctor_arg_membership_sort_hints;
  Hashtbl.clear ctor_arg_literal_type_dependencies;
  Hashtbl.clear ctor_result_sort_hints;
  source_seq_pred_sorts := SSet.empty;
	  feature_uses_bool_wrapper := false;
	  feature_uses_has_type := false;
	  feature_uses_star_prefix := false;
	  feature_uses_steps_final_predicate := false;
  unsupported_syntax_families := SSet.empty;
  specialized_syntax_sort_decls := SSet.empty;
  specialized_syntax_sort_names := SSet.empty;
  Hashtbl.clear specialized_syntax_sort_type_terms;
  literal_wrapper_syntax_decls := SSet.empty;
  literal_wrapper_memberships := SSet.empty;
  raw_payload_type_terms :=
    SSet.of_list [spectec_type_term_of_name "nat" []; spectec_type_term_of_name "int" []];
  generated_zero_arity_ctor_names := SSet.empty;
  Hashtbl.clear literal_wrapper_payload_sorts;
  Hashtbl.clear literal_wrapper_by_type_term;
  Hashtbl.clear source_literal_wrapper_by_sort;
  def_apply_op_decls := SSet.empty;
  def_apply_dispatches := SSet.empty;
  def_tag_decls := SSet.empty;
  collect_source_ctor_head_categories defs;
  build_type_env defs;
  collect_native_sequence_sorts_from_source defs;
  collect_skipped_relation_names defs;
  init_declared_vars ();
  let ss = new_scan () in
  List.iter (scan_def ss) defs;
  List.iter pre_register_relation_rules defs;
  known_call_names :=
    SSet.union
      ss.dec_funcs
      (SIPairSet.elements ss.calls |> List.map fst |> SSet.of_list);
  let token_ops = build_token_ops ss in
  let call_ops = build_call_ops ss in
  let translated_defs =
    String.concat "\n" (List.map (translate_definition ss) defs)
  in
  let infer_rel_helpers = infer_rel_helper_block () in
  let result_rel_helpers = result_rel_helper_block () in
  let valid_rel_mirrors = valid_rel_mirror_block () in
  let body_without_prelude_helpers =
    translated_defs
    ^ "\n"
    ^ valid_rel_mirrors ^ result_rel_helpers
    ^ infer_rel_helpers ^ iter_rel_helper_block () ^ map_call_helper_block ()
    ^ expr_map_helper_block ()
    ^ zip_map_call_helper_block ()
    ^ star_ctor_unzip_helper_block () ^ opt_ctor_helper_block ()
    ^ otherwise_match_helper_block ()
    ^ def_apply_dispatch_block ()
    ^ literal_wrapper_runtime_helper_block ()
    ^ (if SSet.is_empty !literal_wrapper_memberships then ""
       else "\n  --- Object-level numeric literal boundary memberships.\n"
            ^ String.concat "\n" (SSet.elements !literal_wrapper_memberships)
            ^ "\n")
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
  let inferred_category_subsort_decls = [] in
  let inferred_sequence_subsort_decls =
    lift_category_subsorts_to_sequence_subsorts inferred_category_subsort_decls
  in
	  let raw_decls =
	    List.filter is_decl_line lines
	    |> List.filter (fun l -> not (is_canonical_ctor_decl_line l))
	    |> List.sort_uniq String.compare
	    |> fun ds ->
	        List.sort_uniq String.compare
	          (ds @ SSet.elements !specialized_syntax_sort_decls
               @ SSet.elements !literal_wrapper_syntax_decls
		             @ ctor_decl_lines @ inferred_category_subsort_decls
			           @ inferred_sequence_subsort_decls)
  in
	  (* Post-processing fix 1: Remove 0-arity "op X :  -> SpectecTerminal [ctor]" when a
     higher-arity "op X : ... -> SpectecTerminal [ctor]" for the SAME name exists.
     Avoids "multiple distinct parses" for names like num, vec. *)
  let re_zero_arity = Str.regexp "  op \\([^ (]+\\) :  -> SpectecTerminal \\[ctor\\] \\." in
  let higher_arity_names =
    List.filter_map (fun l ->
      let s = String.trim l in
      if starts_with s "op "
         && contains_substring s " SpectecTerminal [ctor"
         && (contains_substring s " ~> SpectecTerminal"
             || contains_substring s " -> SpectecTerminal")
      then
        match split_once_re (Str.regexp "[ \t]+:[ \t]+") s with
        | Some (lhs, _) ->
            let op_surface =
              String.sub lhs 3 (String.length lhs - 3) |> String.trim
            in
            let parts =
              Str.split (Str.regexp "[ \t]+") op_surface
              |> List.filter (fun p -> p <> "")
            in
            (match parts with
             | name :: _ :: _ -> Some name
             | _ -> None)
        | None -> None
      else None
    ) raw_decls
    |> List.sort_uniq String.compare
    |> fun ns -> List.fold_left (fun s n -> SSet.add n s) SSet.empty ns
  in
  (* Post-processing fix 2: Collect all var-declared names, then remove
     "op X : -> SpectecTerminal ." or "op X :  -> SpectecTerminal [ctor]" when
     "var X : ..." already declared — prevents op/var ambiguity. *)
  let re_zero_arity_ctor =
    Str.regexp "  op \\([^ (]+\\) :  -> SpectecTerminal \\[ctor\\] \\."
  in
  let zero_arity_ctor_names =
    raw_decls
    |> List.filter_map (fun l ->
         if Str.string_match re_zero_arity_ctor l 0 then
           str_matched_group_opt 1 l
         else None)
    |> List.fold_left (fun acc n -> SSet.add n acc) SSet.empty
  in
  generated_zero_arity_ctor_names := zero_arity_ctor_names;
  let re_var_decl =
    Str.regexp "^  var[s]?[ \t]+\\(.+\\)[ \t]+:[ \t]+\\(\\[[A-Za-z][A-Za-z0-9-]*\\]\\|[A-Za-z][A-Za-z0-9-]*\\)[ \t]*\\.$"
  in
  let mark_flat_sequence_sorts_from_typecheck lines =
    let re_typecheck =
      Str.regexp
        ".*typecheck[ \t]*(\\(.*\\),[ \t]*\\([A-Za-z][A-Za-z0-9-]*\\))[ \t]*=[ \t]*true.*"
    in
    let re_free_flat =
      Str.regexp
        "^  op \\$free-\\([A-Za-z][A-Za-z0-9-]*\\)[ \t]+:[ \t]+SpectecTerminals[ \t]+->.*"
    in
    let lhs_is_raw_sequence lhs =
      let lhs_trimmed = strip_wrapping_parens lhs |> String.trim in
      starts_with lhs_trimmed "eps "
      || starts_with lhs_trimmed "eps("
      || starts_with lhs_trimmed "eps\t"
      ||
      match split_top_level_terms lhs with
      | _ :: _ :: _ -> true
      | _ -> false
    in
    lines
    |> List.iter (fun line ->
         if Str.string_match re_free_flat line 0 then
           (match str_matched_group_opt 1 line with
            | Some type_atom ->
                flat_sequence_source_sorts :=
                  SSet.add
                    (sort_of_type_name (source_name_of_spectec_type_head type_atom))
                    !flat_sequence_source_sorts
            | None -> ());
         if Str.string_match re_typecheck line 0 then
           match str_matched_group_opt 1 line, str_matched_group_opt 2 line with
           | Some lhs, Some type_atom when lhs_is_raw_sequence lhs ->
               flat_sequence_source_sorts :=
                 SSet.add
                   (sort_of_type_name (source_name_of_spectec_type_head type_atom))
                   !flat_sequence_source_sorts
           | _ -> ())
  in
  mark_flat_sequence_sorts_from_typecheck raw_decls;
  let source_sort_of_generated_var_name name =
    match String.index_opt name '-' with
    | None -> None
    | Some idx when idx > 0 ->
        let prefix = String.sub name 0 idx |> String.lowercase_ascii in
        Some (sort_of_type_name prefix)
    | _ -> None
  in
	  let preserve_final_var_sort sort =
	    List.mem sort
	      [ "SpectecTerminal"; "SpectecTerminals";
	        "Bool"; "Nat"; "Int";
	        "Config"; "State"; "Store"; "Frame"; "Judgement";
	        "RecordItem"; "RecordItems" ]
    || sort = "Addr"
    || ends_with sort "addr"
  in
  let drop_seq_suffix sort =
    if ends_with sort "Seq" then
      String.sub sort 0 (String.length sort - 3)
    else sort
  in
	  let final_var_decl_sort sort =
	    if ends_with sort "Seq"
       && (SSet.mem (drop_seq_suffix sort) !source_membership_sorts
           || SSet.mem sort !native_sequence_source_sorts
           || SSet.mem sort !sequence_alias_sorts
           || SSet.mem sort !flat_sequence_source_sorts)
	    then "SpectecTerminals"
	    else if is_meta_numeric_alias_sort sort then semantic_sort_of_source_sort sort
	    else if preserve_final_var_sort sort then sort
    else if SSet.mem sort !source_membership_sorts
         || SSet.mem sort !zero_arity_source_sorts
         || SSet.mem sort !simple_alias_source_sorts
         || Hashtbl.mem source_category_subsort_edges sort
         || List.exists (fun ri -> ri.rec_sort = sort) !source_record_infos
    then "SpectecTerminal"
    else sort
  in
  let _core_eqs_for_jhs_decl, category_memberships_for_jhs_decl =
    partition_membership_statements eqs
  in
  let jhs_kind_terminal_var_names =
    jhs_kind_terminal_vars_from_memberships category_memberships_for_jhs_decl
  in
  let final_var_decl_sort_for_name name sort =
    if sort = "Frame"
       && (starts_with name "STEP-READ-" || starts_with name "STEP-PURE-")
    then "SpectecTerminal"
	    else (
	      match source_sort_of_generated_var_name name with
	      | Some source_sort when is_meta_numeric_alias_sort source_sort ->
	          semantic_sort_of_source_sort source_sort
	      | Some source_sort when SSet.mem source_sort !flat_sequence_source_sorts ->
	          "SpectecTerminals"
      | _ ->
          let sort' = final_var_decl_sort sort in
          if sort' = "SpectecTerminal"
             && SSet.mem name jhs_kind_terminal_var_names
          then "[SpectecTerminal]"
          else sort')
  in
  let normalize_source_category_var_decl line =
    if Str.string_match re_var_decl line 0 then
      let names = Str.matched_group 1 line in
      let sort = Str.matched_group 2 line in
      let grouped =
        names
        |> Str.split (Str.regexp "[ \t]+")
        |> List.filter (fun name -> name <> "")
        |> List.fold_left
             (fun acc name ->
                let sort' = final_var_decl_sort_for_name name sort in
                let old = match List.assoc_opt sort' acc with Some xs -> xs | None -> [] in
                (sort', name :: old) :: List.remove_assoc sort' acc)
             []
      in
      grouped
      |> List.map (fun (sort', ns) ->
           let ns = List.rev ns in
           match ns with
           | [] -> ""
           | [name] -> Printf.sprintf "  var %s : %s ." name sort'
           | _ -> Printf.sprintf "  vars %s : %s ." (String.concat " " ns) sort')
      |> List.filter (fun s -> s <> "")
    else [line]
  in
  let filter_ctor_conflicting_var_decl line =
    if Str.string_match re_var_decl line 0 then
      let names = Str.matched_group 1 line in
      let sort = Str.matched_group 2 line in
      let kept =
        names
        |> Str.split (Str.regexp "[ \t]+")
        |> List.filter (fun name ->
             name <> "" && not (SSet.mem name zero_arity_ctor_names))
      in
      match kept with
      | [] -> None
      | [name] -> Some (Printf.sprintf "  var %s : %s ." name sort)
        | _ -> Some (Printf.sprintf "  vars %s : %s ." (String.concat " " kept) sort)
    else Some line
  in
  let collapse_var_decls lines =
    let terminalish sort =
      sort = "SpectecTerminal" || sort = "[SpectecTerminal]"
      || sort = "SpectecTerminals"
    in
    let prefer_sort old_sort new_sort =
      if old_sort = new_sort then old_sort
      else if terminalish old_sort && terminalish new_sort then
        if old_sort = "SpectecTerminals" || new_sort = "SpectecTerminals" then
          "SpectecTerminals"
        else if old_sort = "[SpectecTerminal]" || new_sort = "[SpectecTerminal]" then
          "[SpectecTerminal]"
        else "SpectecTerminal"
      else old_sort
    in
    let vars = Hashtbl.create 256 in
    let others = ref [] in
    List.iter
      (fun line ->
        if Str.string_match re_var_decl line 0 then
          let names = Str.matched_group 1 line in
          let sort = Str.matched_group 2 line in
          names
          |> Str.split (Str.regexp "[ \t]+")
          |> List.iter (fun name ->
               if name <> "" then
                 let sort' =
                   match Hashtbl.find_opt vars name with
                   | Some old_sort -> prefer_sort old_sort sort
                   | None -> sort
                 in
                 Hashtbl.replace vars name sort')
        else others := line :: !others)
      lines;
    let var_lines =
      Hashtbl.fold
        (fun name sort acc -> Printf.sprintf "  var %s : %s ." name sort :: acc)
        vars
        []
    in
    List.sort_uniq String.compare (List.rev !others @ var_lines)
  in
	  let raw_decls =
	    raw_decls
	    |> List.filter_map filter_ctor_conflicting_var_decl
	    |> List.concat_map normalize_source_category_var_decl
	    |> List.filter_map jhs_rewrite_decl_line
	    |> List.concat_map (fun line ->
	         if Str.string_match re_var_decl line 0 then
	           let names = Str.matched_group 1 line in
	           let sort = Str.matched_group 2 line in
	           names
	           |> Str.split (Str.regexp "[ \t]+")
	           |> List.filter (fun name -> name <> "")
	           |> List.map (fun name ->
	                Printf.sprintf "  var %s : %s ." name sort)
	         else [line])
	    |> List.sort_uniq String.compare
	    |> collapse_var_decls
	  in
  let var_names =
    raw_decls
    |> List.filter_map (fun l ->
         if Str.string_match re_var_decl l 0 then
           Some (Str.matched_group 1 l)
         else None)
    |> List.concat_map (Str.split (Str.regexp "[ \t]+"))
    |> List.sort_uniq String.compare
    |> fun ns -> List.fold_left (fun s n -> SSet.add n s) SSet.empty ns
  in
  let decls =
    List.filter (fun l ->
      if Str.string_match re_zero_arity l 0 then
        match str_matched_group_opt 1 l with
        | Some nm ->
            (* Keep source nullary constructors even if a stale variable with the
               same generated name was seen earlier.  For non-constructor token
               atoms, prefer the variable and drop the ambiguous op. *)
            (SSet.mem nm zero_arity_ctor_names ||
             (not (SSet.mem nm higher_arity_names) && not (SSet.mem nm var_names)))
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
          | Some nm -> not (SSet.mem nm var_names || SSet.mem nm higher_arity_names)
          | None -> true
        else true
      else true
    )
    |> List.sort_uniq String.compare
  in
  let pred_sorts =
    let seq_pred_sorts = prelude_features.seq_pred_sorts |> SSet.of_list in
    if drop_runtime_typecheck_guards then seq_pred_sorts
    else
      List.fold_left
        (fun acc sort -> SSet.add sort acc)
        (exec_pred_sorts () |> SSet.of_list)
        prelude_features.seq_pred_sorts
  in
  let pred_var_decls, pred_eqs = refined_exec_pred_eqs pred_sorts eqs decls in
  let core_eqs, category_memberships = partition_membership_statements eqs in
  let decls =
    List.sort_uniq String.compare (decls @ exec_pred_decls (SSet.elements pred_sorts) @ pred_var_decls)
  in
  let category_memberships =
    let is_helper_type_witness stmt =
      contains_substring stmt " hasType "
      || contains_substring stmt "WellTyped"
    in
	    category_memberships
	    |> List.filter (fun stmt -> not (is_helper_type_witness stmt))
	    |> List.filter (fun stmt -> not (redundant_or_warning_prone_category_membership stmt))
	  in
  let conflict_var_decls, category_memberships =
    rename_conflicting_membership_vars decls category_memberships
  in
  let conflict_var_decls =
    conflict_var_decls
    |> List.filter_map jhs_rewrite_decl_line
  in
  let jhs_category_memberships, membership_type_terms =
    jhs_membership_statements category_memberships
  in
  let jhs_category_memberships =
    jhs_category_memberships
    |> List.filter (fun stmt -> not (non_ground_total_constructor_membership stmt))
  in
  let jhs_partial_ops =
    jhs_partial_constructor_ops jhs_category_memberships
  in
  let jhs_subsort_eqs, subsort_type_terms =
    jhs_subsort_typecheck_eqs ()
  in
  let used_type_terms =
    SSet.union membership_type_terms subsort_type_terms
  in
  let declared_type_heads = collect_typd_type_constructor_heads defs in
  let type_constructor_decls =
    spectec_type_constructor_decls defs
    @ jhs_extra_type_constructor_decls declared_type_heads used_type_terms
    @ [Printf.sprintf "  var %s : [SpectecTerminal] ." spectec_term_var]
  in
  let decls =
    List.sort_uniq String.compare
      (decls @ conflict_var_decls @ type_constructor_decls)
    |> List.map (jhs_partialize_decl_line jhs_partial_ops)
    |> collapse_var_decls
  in
  let eqs =
    core_eqs @ pred_eqs @ jhs_subsort_eqs @ jhs_category_memberships
    |> List.map simplify_trivial_membership_statement
  in
  header ^ "\n  --- Declarations\n" ^ String.concat "\n" decls ^
  "\n\n  --- Equations\n" ^
  String.concat "\n" (List.map strip_typecheck_guards_from_statement eqs) ^
  footer prelude_features
  |> normalize_numeric_sequence_comparators_in_output
	  |> strip_typecheck_guards_from_output
	  |> strip_source_sort_guards_from_output
		  |> strip_redundant_builtin_sort_guards_from_output
		  |> pretty_source_syntax_conditions_in_output
		  |> strip_condition_eq_true_from_output
		  |> parenthesize_numeric_condition_conjuncts_in_output
		  |> partialize_cmb_constructor_ops_in_output
		  |> normalize_empty_condition_statements
		  |> trim_trailing_whitespace_from_output
