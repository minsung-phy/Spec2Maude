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

type exp_ctx = BoolCtx | TermCtx

(** Translation result: Maude source text paired with collected variable names.
    Replaces the global [undeclared_vars] ref with a pure accumulator. *)
type texpr = { text : string; vars : string list }

let texpr s = { text = s; vars = [] }

let texpr_with_var s v = { text = s; vars = [v] }

let tconcat sep ts =
  { text = String.concat sep (List.map (fun t -> t.text) ts);
    vars = List.concat_map (fun t -> t.vars) ts }

let tmap f t = { t with text = f t.text }

let tjoin2 f t1 t2 =
  { text = f t1.text t2.text; vars = t1.vars @ t2.vars }

let tjoin3 f t1 t2 t3 =
  { text = f t1.text t2.text t3.text; vars = t1.vars @ t2.vars @ t3.vars }

let wrap_paren s = Printf.sprintf "( %s )" s

let debug_iter_enabled =
  match Sys.getenv_opt "SPEC2MAUDE_DEBUG_ITER" with
  | Some "1" | Some "true" | Some "TRUE" | Some "yes" | Some "YES" -> true
  | _ -> false

let debug_iter fmt =
  if debug_iter_enabled then Printf.eprintf (fmt ^^ "\n")
  else Printf.ifprintf stderr (fmt ^^ "\n")

let syntax_keywords =
  SSet.of_list
    ["semicolon"; "lbrace"; "rbrace"; "lbrack"; "rbrack";
     "arrow"; "dotdot"]

let wrap_mix_token s =
  s

let cond_join conds =
  conds
  |> List.map String.trim
  |> List.filter (fun c -> c <> "" && c <> "true" && c <> "( true )" && c <> "(true)")
  |> String.concat " /\\ "

let safe_term_text s =
  let t = String.trim s in
  if t = "" then "T" else t

let bool_cond s = Printf.sprintf "( %s ) = true" s

let prem_cond s =
  if String.contains s ':' && String.contains s '=' then s else bool_cond s

(* ========================================================================= *)
(* 2. Identifier sanitization                                                *)
(* ========================================================================= *)

let maude_keywords =
  SSet.of_list
    ["if"; "var"; "op"; "eq"; "sort"; "mod"; "quo"; "rem"; "or"; "and"; "not"]

let is_alpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')

let is_upper_start s = String.length s > 0 && s.[0] >= 'A' && s.[0] <= 'Z'

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

let is_trivial_true_cond s =
  let t = String.trim (strip_wrapping_parens s) in
  t = "" || t = "true"

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

let to_var_name name =
  String.uppercase_ascii (sanitize name)

let is_upper_token s =
  String.length s > 0 &&
  let c = s.[0] in c >= 'A' && c <= 'Z'

let sort_of_type_name raw =
  let s = sanitize raw in
  if String.length s >= 2 && String.sub s 0 2 = "w-" then "WasmTerminal"
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
  | IterT (inner, _) -> simple_sort_of_typ inner vm
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

(* ========================================================================= *)
(* 3. Type environment                                                       *)
(* ========================================================================= *)

let plural_types : (string, bool) Hashtbl.t = Hashtbl.create 32

let build_type_env defs =
  let rec scan d = match d.it with
    | RecD ds -> List.iter scan ds
    | TypD (id, _, insts) ->
        List.iter (fun inst -> match inst.it with
          | InstD (_, _, deftyp) -> (match deftyp.it with
              | AliasT typ -> (match typ.it with
                  | IterT (_, (List | List1)) -> Hashtbl.replace plural_types id.it true
                  | _ -> ())
              | _ -> ())
        ) insts
    | _ -> ()
  in
  List.iter scan defs

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

let init_declared_vars () =
  Hashtbl.reset declared_vars;
  List.iter (fun (v, s) -> Hashtbl.replace declared_vars v s)
    [ ("I", "Int"); ("W-I", "Int"); ("EXP", "Int");
      ("W-N", "Nat"); ("W-M", "Nat");
      ("T", "WasmTerminal"); ("W", "WasmTerminal");
      ("WW", "WasmTerminal");
      ("TS", "WasmTerminals"); ("W*", "WasmTerminals") ]

let declare_var name sort =
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
  List.iter (fun n -> Hashtbl.replace declared_vars n sort) fresh;
  match emit, fresh with
  | _, [] -> ""
  | `Vars, _ -> Printf.sprintf "  vars %s : %s .\n" (String.concat " " fresh) sort
  | `Ops, _ -> String.concat "" (List.map (fun n ->
      Printf.sprintf "  op %s : -> %s .\n" n sort) fresh)

let declare_vars_same_sort names sort = declare_batch `Vars names sort
let declare_ops_const_list names sort = declare_batch `Ops names sort

(* ========================================================================= *)
(* 6. Pre-scan phase                                                         *)
(* ========================================================================= *)

type scan_state = {
  mutable tokens    : SSet.t;
  mutable calls     : SIPairSet.t;
  mutable dec_funcs : SSet.t;
  mutable bool_calls: SSet.t;
  mutable ctors     : SSet.t;
}

let new_scan () = {
  tokens = SSet.empty; calls = SIPairSet.empty;
  dec_funcs = SSet.empty; bool_calls = SSet.empty;
  ctors = SSet.empty;
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
    if id.it = "_" then ss.tokens <- SSet.add "any" ss.tokens
  | CaseE (mixop, inner) ->
      scan_mixop_tokens ss mixop;
      scan_exp ss inner
  | TupE es | ListE es -> List.iter (scan_exp ss) es
  | UnE (_, _, e1) | CvtE (e1, _, _) | SubE (e1, _, _) | ProjE (e1, _)
  | UncaseE (e1, _) | LenE e1 | OptE (Some e1) | TheE e1
  | LiftE e1 | IterE (e1, _) | DotE (e1, _) -> scan_exp ss e1
  | BinE (_, _, e1, e2) | CmpE (_, _, e1, e2) | CatE (e1, e2)
  | MemE (e1, e2) | IdxE (e1, e2) | CompE (e1, e2)
  | UpdE (e1, _, e2) | ExtE (e1, _, e2) -> scan_exp ss e1; scan_exp ss e2
  | SliceE (e1, e2, e3) | IfE (e1, e2, e3) ->
      scan_exp ss e1; scan_exp ss e2; scan_exp ss e3
  | StrE fields -> List.iter (fun (_, e1) -> scan_exp ss e1) fields
  | CallE (id, args) ->
      let cn = call_name id.it in
      if cn <> "w-$" then ss.calls <- SIPairSet.add (cn, List.length args) ss.calls;
      List.iter (fun a -> match a.it with ExpA e1 -> scan_exp ss e1 | _ -> ()) args
  | OptE None | BoolE _ | NumE _ | TextE _ -> ()

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
          chunks (("  ops " ^ String.concat " " hd ^ " : -> WasmTerminal [ctor] .\n") :: acc) tl
    in
    String.concat "" (chunks [] toks) ^ "\n"

let build_call_ops ss =
  let lines = SIPairSet.elements ss.calls
    |> List.filter (fun (name, arity) ->
         not (SSet.mem name ss.dec_funcs) && arity >= 0)
    |> List.map (fun (name, arity) ->
         let args = String.concat " " (List.init arity (fun _ -> "WasmTerminal")) in
         let ret = if SSet.mem name ss.bool_calls then "Bool" else "WasmTerminal" in
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
  | TermCtx -> Printf.sprintf "w-bool ( %s )" s

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

(* Global accumulator: ListN count variable → sequence variable pairs.
   Populated by translate_exp when it encounters IterE with ListN iter.
   Reset at the start of each rule translation. *)
let g_listn_pairs : (string * string) list ref = ref []
let reset_listn_pairs () = g_listn_pairs := []
let record_listn_pair cnt seq =
  if not (List.mem_assoc cnt !g_listn_pairs) then
    g_listn_pairs := (cnt, seq) :: !g_listn_pairs

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
      | `MinusOp -> tmap (Printf.sprintf "( 0 - ( %s ) )") (translate_exp TermCtx e1 vm)
      | `PlusOp -> translate_exp TermCtx e1 vm
      | `NotOp ->
          let t = translate_exp BoolCtx e1 vm in
          { text = wrap_bool ctx (Printf.sprintf "not ( %s )" t.text); vars = t.vars })
  | BinE (op, _, e1, e2) -> translate_binop ctx op e1 e2 vm
  | CmpE (op, _, e1, e2) ->
      let op_str = match (op : cmpop) with
        | `LtOp -> "<" | `GtOp -> ">" | `LeOp -> "<=" | `GeOp -> ">="
        | `EqOp -> "==" | `NeOp -> "=/=" in
      let t1 = translate_exp TermCtx e1 vm and t2 = translate_exp TermCtx e2 vm in
      { text = wrap_bool ctx (Printf.sprintf "( %s %s %s )" t1.text op_str t2.text);
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
      let items = List.map (fun (atom, e1) ->
        let t = translate_exp TermCtx e1 vm in
        { t with text = Printf.sprintf "item('%s, %s)"
            (to_var_name (Xl.Atom.name atom)) t.text }
      ) fields in
      { text = "{" ^ String.concat " ; " (List.map (fun t -> t.text) items) ^ "}";
        vars = List.concat_map (fun t -> t.vars) items }
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
      tjoin2 (Printf.sprintf "index ( %s, %s )")
        (translate_exp TermCtx e1 vm) (translate_exp TermCtx e2 vm)
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
                (* Record count-sequence pair for ListN iters so that
                   translate_step_reld can later add N := len(seq) conditions. *)
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
                let v = String.uppercase_ascii (sanitize full) in
                debug_iter "[ITER-MAP] kind=%s raw=%s probe=%s mapped=<fallback:%s>"
                  suffix id.it full v;
                texpr_with_var v v)
       | _ -> translate_exp ctx e1 vm)
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
    | Some ctor ->
        { text = format_call ctor arg_texts;
          vars = List.concat_map (fun t -> t.vars) args }
    | None ->
        { text = interleave_lhs (mixop_sections mixop) arg_texts;
          vars = List.concat_map (fun t -> t.vars) args }

and translate_binop ctx op e1 e2 vm =
  let (op_str, is_bool) = match (op : binop) with
    | `AddOp -> ("+", false) | `SubOp -> ("-", false) | `MulOp -> ("*", false)
    | `DivOp -> (" quo ", false) | `ModOp -> (" rem ", false) | `PowOp -> (" ^ ", false)
    | `AndOp -> (" and ", true) | `OrOp -> (" or ", true)
    | `ImplOp -> (" implies ", true) | `EquivOp -> (" == ", true) in
  let sub_ctx = if is_bool then BoolCtx else TermCtx in
  let t1 = translate_exp sub_ctx e1 vm and t2 = translate_exp sub_ctx e2 vm in
  let text = Printf.sprintf "( %s %s %s )" t1.text op_str t2.text in
  { text = if is_bool then wrap_bool ctx text else text; vars = t1.vars @ t2.vars }

and translate_bracket_op op e1 path e2 vm =
  let t1 = translate_exp TermCtx e1 vm in
  let t2 = translate_exp TermCtx e2 vm in
  match path.it with
  | IdxP (inner, idx_e) ->
      let idx_t = translate_exp TermCtx idx_e vm in
      (match inner.it with
       | DotP (_, atom) ->
           (* Nested path .FIELD[idx]: e1[.FIELD[idx] op v]
              → e1 [. 'FIELD <- value('FIELD, e1)[idx op v]]
              Handles: f[.LOCALS[x] = v]  (spectec def $with_local) *)
           let fld = "'" ^ String.uppercase_ascii (sanitize (Xl.Atom.name atom)) in
           { text = Printf.sprintf "( %s [. %s <- ( value ( %s, %s ) [ %s %s %s ] ) ] )"
               t1.text fld fld t1.text idx_t.text op t2.text;
             vars = t1.vars @ idx_t.vars @ t2.vars }
       | _ ->
           (* Simple index: e1[idx op v] *)
           { text = Printf.sprintf "( %s [ %s %s %s ] )"
               t1.text idx_t.text op t2.text;
             vars = t1.vars @ idx_t.vars @ t2.vars })
  | _ ->
      let tp = translate_path path vm in
      let bracket = if String.length tp.text > 0 && tp.text.[0] = '\'' then "[." else "[" in
      { text = Printf.sprintf "( %s %s %s %s %s ] )" t1.text bracket tp.text op t2.text;
        vars = t1.vars @ tp.vars @ t2.vars }

and translate_path (p : path) vm : texpr = match p.it with
  | RootP -> texpr ""
  | IdxP (_, e) -> translate_exp TermCtx e vm
  | SliceP (_, e1, e2) ->
      tjoin2 (Printf.sprintf "%s %s") (translate_exp TermCtx e1 vm) (translate_exp TermCtx e2 vm)
  | DotP (p1, atom) ->
      let qid = "'" ^ String.uppercase_ascii (sanitize (Xl.Atom.name atom)) in
      let _base = translate_path p1 vm in
      texpr qid

and translate_arg (a : arg) vm : texpr = match a.it with
  | ExpA e -> translate_exp TermCtx e vm
  | TypA t -> texpr (translate_typ t vm)
  | _ -> texpr "eps"

and translate_prem (p : prem) vm : texpr = match p.it with
  | IfPr e -> translate_exp BoolCtx e vm
  | RulePr (id, _, e) ->
      let ts = match e.it with
        | TupE el -> List.map (fun x -> translate_exp TermCtx x vm) el
        | _ -> [translate_exp TermCtx e vm] in
      { text = format_call (sanitize id.it) (List.map (fun t -> t.text) ts);
        vars = List.concat_map (fun t -> t.vars) ts }
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
  | IterT (inner, _) -> translate_typ inner vm
  | _ -> "WasmType"

let type_guard term typ vm =
  match simple_sort_of_typ typ vm with
  | Some s -> Printf.sprintf "%s : %s" term s
  | None ->
      let ty = translate_typ typ vm in
      if ty = "WasmType" then "true"
      else
        let has_var_ref =
          try
            let _ = Str.search_forward (Str.regexp "[A-Z][A-Z0-9-]*") ty 0 in
            true
          with Not_found -> false
        in
        if has_var_ref then "true"
        else Printf.sprintf "type-ok ( %s , %s )" term ty

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

let base_types = SSet.of_list
  ["w-N"; "w-M"; "w-K"; "w-n"; "w-m"; "w-X"; "w-C"; "w-I";
   "w-S"; "w-T"; "w-V"; "w-b"; "w-z"; "w-L"; "w-E"]

(** Extract variable name from an [ExpB] binder. *)
let binder_var_map binders =
  List.filter_map (fun b -> match b.it with
    | ExpB (tid, _) -> Some (tid.it, to_var_name tid.it)
    | _ -> None
  ) binders

let binder_type_conds binders =
  List.filter_map (fun b -> match b.it with
    | ExpB (tid, t) ->
        Some (type_guard (to_var_name tid.it) t [])
    | _ -> None
  ) binders

let type_sort_of_typ (t : typ) vm : string option =
  simple_sort_of_typ t vm

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
  let sig_types = String.concat " " (List.map (fun _ -> "WasmTerminal") params) in
  let mk_type_term args v_map =
    let args_str = String.concat " , " (List.map (fun a -> (translate_arg a v_map).text) args) in
    if args_str = "" then name else Printf.sprintf "%s ( %s )" name args_str
  in
  (* Pure nat/integer meta-variable TYPES (N, M, K, n, m): Maude variables in
     equations conflict with constants "op X : -> WasmType [ctor]".  We suppress
     the CONSTANT declaration but keep "sort X . subsort X < WasmType ." so that
     membership axioms like "cmb T : N if ..." can still reference them as sorts. *)
  let pure_meta_var_names = SSet.of_list ["N"; "M"; "K"; "n"; "m"] in
  let is_pure_meta = SSet.mem id.it pure_meta_var_names in
  (* Sorts already declared in Maude built-in modules — skip sort/subsort declarations *)
  let maude_builtin_sorts = SSet.of_list ["Char"; "Zero"; "NzNat"; "Nat"; "Int"; "Bool"] in
  (* Sorts where instance axiom (cmb/mb) generation doesn't work — list-based or conflicting *)
  let skip_instance_sorts = SSet.of_list ["Char"; "Zero"; "NzNat"; "Nat"; "Int"; "Bool"; "Name"] in
  let sort_decl =
    if is_parametric || SSet.mem name base_types || type_sort = "WasmTerminal"
       || SSet.mem type_sort maude_builtin_sorts then ""
    else Printf.sprintf "  sort %s .\n  subsort %s < WasmType .\n" type_sort type_sort in
  let op_decl =
    if is_pure_meta || SSet.mem name base_types then ""
    else Printf.sprintf "  op %s : %s -> WasmType [ctor] .\n" name sig_types in
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
    && not (is_keywordish_token_local v)
  in
  let vars_of_texpr_local (t : texpr) =
    let extracted = extract_vars_local t.text |> List.filter is_bindable_name_local in
    uniq_vars_local (t.vars @ extracted)
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
            let (_, _, binds) = chosen in
            let bound' = List.fold_left (fun b v -> SSet.add v b) bound binds in
            schedule_prems_typd bound' (chosen :: acc) (before @ after)
        | None ->
            let rec force bound2 acc2 = function
              | [] -> List.rev acc2
              | it :: rest ->
                  let (_kind, sched, _ready) = classify_prem_typd bound2 it in
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
      let type_term = mk_type_term args v_map in
        let full_type_sort = type_sort in
        (match deftyp.it with
         | VariantT cases ->
             List.filter_map (fun (mixop_val, (_, case_typ, prems), _) ->
               let type_counters = ref [] in
               let get_count tname =
                 let c = (try List.assoc tname !type_counters with Not_found -> 0) + 1 in
                 type_counters := (tname, c) :: (List.remove_assoc tname !type_counters); c in
               let rec collect_params cur_vm t is_list = match t.it with
                 | VarT (tid, _) ->
                     let vb = to_var_name tid.it in
                     let count = get_count vb in
                     let indexed =
                       if is_list then
                         vb ^ "-LIST-" ^ String.uppercase_ascii (sanitize tid.it)
                       else vb ^ string_of_int count in
                     let new_vm = (tid.it, indexed) :: cur_vm in
                     let ms =
                       if is_list || is_plural_type tid.it then
                         match simple_sort_of_typ t new_vm with
                         | Some s when s <> "WasmTerminal" -> s
                         | _ -> "WasmTerminals"
                       else "WasmTerminal"
                     in
                     let guard = "true" in
                     ([(indexed, guard, ms)], new_vm)
                 | IterT (inner, iter) ->
                     collect_params cur_vm inner (iter = List || iter = List1)
                 | TupT fields ->
                     List.fold_left (fun (acc, vm) (_, ft) ->
                       let (ps, vm') = collect_params vm ft is_list in
                       (acc @ ps, vm')
                     ) ([], cur_vm) fields
                 | _ -> ([], cur_vm)
               in
               let enriched_vm = build_suffix_map binders @ v_map in
               let (params, param_vm) = collect_params enriched_vm case_typ false in
               let p_vars = List.map (fun (v, _, _) -> v) params in
               let v_decl = String.concat "" (List.map (fun (v, _, ms) -> declare_var v ms) params) in
               let binder_decl = String.concat "" (List.map (fun b -> match b.it with
                 | ExpB (tid, _) -> declare_var (to_var_name tid.it) "WasmTerminal"
                 | _ -> "") binders) in
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
               let rhs = cond_join (prem_match_strs @ prem_bool_strs @ binder_conds) in
                 let sections = mixop_sections mixop_val in
                 let lhs0 =
                   match canonical_ctor_name_arity mixop_val (List.length p_vars) with
                   | Some ctor -> format_call ctor p_vars
                   | None -> interleave_lhs sections p_vars
                 in
                 let lhs = safe_term_text lhs0
                 in
                 let cons_name = match List.flatten mixop_val with a :: _ -> Xl.Atom.name a | [] -> "" in
                 let main =
                   if cons_name = "" then
                     if is_parametric then
                       Printf.sprintf "\n%s%s  %s type-ok ( %s , %s ) = true%s ."
                         binder_decl v_decl (if rhs = "" then "eq" else "ceq") lhs type_term
                         (if rhs = "" then "" else "\n   if " ^ rhs)
                     else if is_plain_var_like lhs then
                       let () =
                         (* We skip emitting this clause; rollback side-effectful
                            var declarations so later emitted clauses can declare
                            the same names correctly (e.g. SHAPE1). *)
                         List.iter (fun (v, _, _) -> Hashtbl.remove declared_vars v) params;
                         List.iter (fun b -> match b.it with
                           | ExpB (tid, _) -> Hashtbl.remove declared_vars (to_var_name tid.it)
                           | _ -> ()) binders
                       in
                       "" (* Skip: "cmb (T) : X [if true]" would make ALL terms members of X *)
                     else
                       Printf.sprintf "\n%s%s  %s ( %s ) : %s%s ."
                         binder_decl v_decl (if rhs = "" then "mb" else "cmb") lhs full_type_sort
                         (if rhs = "" then "" else "\n   if " ^ rhs)
                   else
                     let canonical_name = canonical_ctor_name_arity mixop_val (List.length p_vars) in
                     let op_sig =
                       match canonical_name with
                       | Some ctor -> ctor
                       | None -> interleave_op sections (List.length p_vars)
                     in
                     let arg_sorts = String.concat " " (List.map (fun (_, _, ms) -> ms) params) in
                     let op_line =
                       match canonical_name with
                       | Some _ -> ""
                       | None ->
                           Printf.sprintf "  op %s : %s -> WasmTerminal [ctor] .\n" op_sig arg_sorts
                     in
                     if is_parametric then
                       Printf.sprintf "%s%s%s  %s type-ok ( %s , %s ) = true%s ."
                         op_line binder_decl v_decl (if rhs = "" then "eq" else "ceq") lhs type_term
                         (if rhs = "" then "" else "\n   if " ^ rhs)
                     else
                       Printf.sprintf "%s%s%s  %s ( %s ) : %s%s ."
                         op_line binder_decl v_decl (if rhs = "" then "mb" else "cmb") lhs full_type_sort
                         (if rhs = "" then "" else "\n   if " ^ rhs)
                 in
                 let opts =
                   if prems <> [] then []
                   else
                     List.map (fun opt_idx ->
                       let eps_args = List.mapi (fun i v -> if i = opt_idx then "eps" else v) p_vars in
                       let lhs_eps =
                         match canonical_ctor_name_arity mixop_val (List.length eps_args) with
                         | Some ctor -> format_call ctor eps_args
                         | None -> interleave_lhs sections eps_args in
                       let lhs_eps = safe_term_text lhs_eps in
                       let r = cond_join
                         (binder_conds @ List.filteri (fun i _ -> i <> opt_idx)
                           (List.map (fun (_, g, _) -> g) params)) in
                       if is_parametric then
                         Printf.sprintf "\n  %s type-ok ( %s , %s ) = true%s ."
                           (if r = "" then "eq" else "ceq") lhs_eps type_term
                           (if r = "" then "" else "\n   if " ^ r)
                       else
                         Printf.sprintf "\n  %s ( %s ) : %s%s ."
                           (if r = "" then "mb" else "cmb") lhs_eps full_type_sort
                           (if r = "" then "" else "\n   if " ^ r)
                     ) (find_opt_param_indices case_typ)
                 in
                 Some (main ^ String.concat "" opts)
             ) cases |> String.concat "\n"
         | AliasT typ ->
             let bd = String.concat "" (List.map (fun b -> match b.it with
               | ExpB (tid, _) -> declare_var (to_var_name tid.it) "WasmTerminal"
               | _ -> "") binders) in
             let list_alias_info =
               let low s = String.lowercase_ascii s in
               match typ.it with
               | IterT (inner, List) -> Some (inner, true)
               | IterT (inner, List1) -> Some (inner, false)
               | VarT (tid, [a]) when low tid.it = "list" ->
                   (match a.it with
                    | TypA inner -> Some (inner, true)
                    | _ -> None)
               | VarT (tid, [a]) when low tid.it = "list1" ->
                   (match a.it with
                    | TypA inner -> Some (inner, false)
                    | _ -> None)
               | _ -> None
             in
             let var =
               match list_alias_info with
               | Some _ -> "TS"
               | None -> "T"
             in
             let lhs = if SSet.mem name base_types then "T" else var in
             let alias_guard = type_guard lhs typ v_map in
             let force_unconditional_idx = String.lowercase_ascii id.it = "idx" in
             let cond =
               if force_unconditional_idx then ""
               else if binder_conds = [] then alias_guard
               else cond_join (binder_conds @ [alias_guard]) in
             if is_parametric then
               Printf.sprintf "%s  %s type-ok ( %s , %s ) = true%s ." bd
                 (if cond = "" then "eq" else "ceq") lhs type_term
                 (if cond = "" then "" else "\n   if " ^ cond)
            else
              (match list_alias_info with
               | Some (elem_typ, allow_empty) when is_plain_var_like lhs ->
                   let elem_guard = type_guard "T" elem_typ v_map in
                   let is_resulttype_alias = String.lowercase_ascii id.it = "resulttype" in
                   if is_resulttype_alias then
                     let single_cond = cond_join (binder_conds @ [elem_guard]) in
                     let base_clause =
                       if allow_empty then Printf.sprintf "%s  mb ( eps ) : %s .\n" bd full_type_sort
                       else ""
                     in
                     if single_cond = "" then
                       Printf.sprintf "%s%s  mb ( T ) : %s ."
                         base_clause bd full_type_sort
                     else
                       Printf.sprintf "%s%s  cmb ( T ) : %s\n   if %s ."
                         base_clause bd full_type_sort single_cond
                   else
                     let rec_cond =
                       cond_join (binder_conds @ [elem_guard; Printf.sprintf "TS : %s" full_type_sort])
                     in
                     let base_clause =
                       if allow_empty then Printf.sprintf "%s  mb ( eps ) : %s .\n" bd full_type_sort
                       else ""
                     in
                     Printf.sprintf "%s%s  cmb ( T TS ) : %s\n   if %s ."
                       base_clause bd full_type_sort rec_cond
               | _ ->
                   if is_plain_var_like lhs && is_trivial_true_cond cond then
                     let () =
                       List.iter (fun b -> match b.it with
                         | ExpB (tid, _) -> Hashtbl.remove declared_vars (to_var_name tid.it)
                         | _ -> ()) binders
                     in
                     "" (* Skip broad alias membership: cmb (T) : Sort if true *)
                   else
                     Printf.sprintf "%s  %s ( %s ) : %s%s ." bd
                       (if cond = "" then "mb" else "cmb") lhs full_type_sort
                       (if cond = "" then "" else "\n   if " ^ cond))
         | StructT fields ->
             let bd = String.concat "" (List.map (fun b -> match b.it with
               | ExpB (tid, _) -> declare_var (to_var_name tid.it) "WasmTerminal"
               | _ -> "") binders) in
             let info = List.mapi (fun i (atom, (_, ft, _), _) ->
               let fn = to_var_name (Xl.Atom.name atom) in
               let sn = translate_typ (match ft.it with IterT (inner, _) -> inner | _ -> ft) v_map in
               let ms =
                 if (match ft.it with IterT (_, (List | List1)) -> true | _ -> false) || is_plural_type sn
                 then "WasmTerminals" else "WasmTerminal" in
               (fn, Printf.sprintf "F-%s-%d" fn i, ft, ms)
             ) fields in
             let decls = String.concat "" (List.map (fun (_, vn, _, ms) -> declare_var vn ms) info) in
             let rhs = cond_join
               (binder_conds @ List.map (fun (_, vn, ft, _) -> type_guard vn ft v_map) info) in
             if is_parametric then
               Printf.sprintf "%s%s  %s type-ok ( {%s} , %s ) = true%s ." bd decls
                 (if rhs = "" then "eq" else "ceq")
                 (String.concat " ; " (List.map (fun (f, vn, _, _) ->
                     Printf.sprintf "item('%s, ( %s ))" f vn) info))
                 type_term (if rhs = "" then "" else "\n   if " ^ rhs)
             else
               Printf.sprintf "%s%s  %s ( {%s} ) : %s%s ." bd decls
                 (if rhs = "" then "mb" else "cmb")
                 (String.concat " ; " (List.map (fun (f, vn, _, _) ->
                     Printf.sprintf "item('%s, ( %s ))" f vn) info))
                 full_type_sort (if rhs = "" then "" else "\n   if " ^ rhs))
  ) insts in
  sort_decl ^ op_decl ^ String.concat "\n" res

(* --- Binding analysis (shared by DecD / RelD) ---------------------------- *)

let extract_vars_from_maude s =
  let re = Str.regexp "[A-Z][A-Z0-9-]*" in
  let excluded = SSet.of_list
    ["WasmTerminal"; "WasmTerminals"; "WasmType"; "WasmTypes"; "Bool"; "Nat"; "Int";
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
  let rec loop pos acc =
    match (try Some (Str.search_forward re s pos) with Not_found -> None) with
    | None -> acc
    | Some _ ->
        let tok = Str.matched_string s in
        loop (Str.match_end ())
          (if SSet.mem tok excluded || is_ctor_name tok then acc else tok :: acc)
  in
  loop 0 [] |> List.sort_uniq String.compare

(** Build a per-equation variable prefix from a case/rule identifier. *)
let make_var_prefix prefix eq_idx raw_v =
  let alpha_digit c =
    match c with
    | '0' -> 'P' | '1' -> 'Q' | '2' -> 'R' | '3' -> 'S' | '4' -> 'T'
    | '5' -> 'U' | '6' -> 'V' | '7' -> 'W' | '8' -> 'X' | '9' -> 'Y'
    | _ -> c
  in
  let normalized_raw =
    String.concat "" (String.split_on_char '-' (String.uppercase_ascii (sanitize raw_v)))
    |> String.map alpha_digit
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
  List.fold_left (fun acc b -> match b.it with
    | ExpB (v_id, t) ->
        if is_bool_typ t [] || String.lowercase_ascii v_id.it = "bool" then acc
        else
          let raw = v_id.it in
          let base = strip_iter_suffix raw in
          let mapped = make_var_prefix prefix eq_idx base in
          let iter_kind = match t.it with
            | IterT (_, List) -> "*"
            | IterT (_, List1) -> "+"
            | IterT (_, Opt) -> "?"
            | IterT (_, ListN _) -> "N"
            | _ -> "-" in
          debug_iter "[BINDER-MAP] eq=%d raw=%s base=%s kind=%s mapped=%s"
            eq_idx raw base iter_kind mapped;
          let acc = add_vm_alias raw mapped acc in
          let acc = add_vm_alias base mapped acc in
          let acc = add_vm_alias (base ^ "*") mapped acc in
          let acc = add_vm_alias (base ^ "+") mapped acc in
          let acc = add_vm_alias (base ^ "?") mapped acc in
          acc
    | _ -> acc
  ) [] binders

(** Create type-check conditions from binders, only for non-trivial types. *)
let binder_to_type_conds binders vm =
  List.filter_map (fun b -> match b.it with
    | ExpB (v_id, t) ->
        let ts = translate_typ t [] in
        if ts = "WasmType" || is_bool_typ t [] || String.lowercase_ascii v_id.it = "bool"
        then None
        else (match List.assoc_opt v_id.it vm with
          | Some mv -> Some (mv, type_guard mv t vm)
          | None -> None)
    | _ -> None
  ) binders

let declared_sort_of_typ t =
  if is_bool_typ t [] then "Bool"
  else match type_sort_of_typ t [] with
    | Some s when s <> "WasmTerminal" -> s
    | _ -> "WasmTerminal"

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
  | PremEq of { lhs : texpr; rhs : texpr; bool_t : texpr }

type prem_sched = { text : string; vars : string list; binds : string list }

let uniq_vars vs = List.sort_uniq String.compare vs

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

(** Collect individual prem_items from an expression, splitting AND conjunctions.
    Each equality sub-expression becomes its own PremEq so the scheduler can
    independently bind variables from each clause (fixes missing :=  bindings). *)
let rec collect_prem_items_of_exp vm e : prem_item list =
  match e.it with
  | BinE (`AndOp, _, e1, e2) ->
      collect_prem_items_of_exp vm e1 @ collect_prem_items_of_exp vm e2
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
      [PremEq { lhs; rhs; bool_t }]
  | BinE (`EquivOp, _, lhs_e, rhs_e) ->
      let lhs = translate_exp TermCtx lhs_e vm in
      let rhs = translate_exp TermCtx rhs_e vm in
      let lhs_b = translate_exp BoolCtx lhs_e vm in
      let rhs_b = translate_exp BoolCtx rhs_e vm in
      let bool_t = { text = Printf.sprintf "( %s == %s )" lhs_b.text rhs_b.text;
                     vars = uniq_vars (lhs_b.vars @ rhs_b.vars) } in
      [PremEq { lhs; rhs; bool_t }]
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

let prem_items_of_prem vm (p : prem) : prem_item list =
  match p.it with
  | ElsePr -> []
  | LetPr (e1, e2, _) ->
      let lhs = translate_exp TermCtx e1 vm in
      let rhs = translate_exp TermCtx e2 vm in
      let bool_t =
        { text = Printf.sprintf "( %s == %s )" lhs.text rhs.text;
          vars = uniq_vars (lhs.vars @ rhs.vars) }
      in
      [PremEq { lhs; rhs; bool_t }]
  | IfPr e ->
      let items = collect_prem_items_of_exp vm e in
      if items <> [] then items
      else
        let t = translate_prem p vm in
        if t.text = "" || t.text = "owise" then [] else [PremBool t]
  | _ ->
      let t = translate_prem p vm in
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
  | PremEq { lhs; rhs; bool_t } ->
      let lhs_vars = vars_of_texpr lhs in
      let rhs_vars = vars_of_texpr rhs in
      let lhs_set = SSet.of_list lhs_vars in
      let rhs_set = SSet.of_list rhs_vars in
      let lhs_has_no_bound = SSet.is_empty (SSet.inter lhs_set bound) in
      let rhs_has_no_bound = SSet.is_empty (SSet.inter rhs_set bound) in
      let lhs_nonempty = not (SSet.is_empty lhs_set) in
      let rhs_nonempty = not (SSet.is_empty rhs_set) in
      if lhs_nonempty && lhs_has_no_bound && subset_bound bound rhs_vars then
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
      else
        let vars = vars_of_texpr bool_t in
        let ready = subset_bound bound vars in
        (`Bool, { text = bool_t.text; vars; binds = [] }, ready)

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
          let bound' = List.fold_left (fun b v -> SSet.add v b) bound chosen.binds in
          schedule_prems bound' (chosen :: acc) (before @ after)
      | None ->
          let rec force bound2 acc2 = function
            | [] -> List.rev acc2
            | it :: rest ->
                let (_kind, sched, _ready) = classify_prem bound2 it in
                let bound3 = List.fold_left (fun b v -> SSet.add v b) bound2 sched.binds in
                force bound3 (sched :: acc2) rest
          in
          List.rev_append acc (force bound [] items)

(* --- DecD handler -------------------------------------------------------- *)

let translate_decd ss id params result_typ insts =
  let func_name = sanitize id.it in
  let maude_fn =
    if String.length func_name > 0 && func_name.[0] = '$' then func_name
    else "$" ^ func_name in
  let prefix = match String.split_on_char '-' (String.uppercase_ascii func_name) with
    | h :: _ ->
        let h = if String.length h > 0 && h.[0] = '$'
                then String.sub h 1 (String.length h - 1) else h in
        if h = "" then "FN" else h
    | [] -> "FN" in
  let param_sort (p : param) =
    match p.it with
    | ExpP (_, t) ->
        (match t.it with
         | IterT (_, (List | List1)) -> "WasmTerminals"
         | _ -> declared_sort_of_typ t)
    | _ -> "WasmTerminal"
  in
  let arg_sorts = String.concat " " (List.map param_sort params) in
  let inferred_bool =
    List.exists (fun inst -> match inst.it with DefD (_, _, rhs, _) -> exp_is_boolish rhs) insts in
  let ret_sort = match result_typ.it with
    | IterT (_, (List | List1)) -> "WasmTerminals"
    | _ ->
        if is_bool_typ result_typ [] || inferred_bool || SSet.mem maude_fn ss.bool_calls
        then "Bool" else declared_sort_of_typ result_typ in
  let rhs_ctx = if ret_sort = "Bool" then BoolCtx else TermCtx in

  let all_bound = ref [] and all_free = ref [] in
  let eq_lines = List.mapi (fun eq_idx inst ->
    let (binders, lhs_args, rhs_exp, prem_list) =
      match inst.it with DefD (b, la, re, pl) -> (b, la, re, pl) in
    let vm = binder_to_var_map prefix eq_idx binders in
    let bconds = binder_to_type_conds binders vm in

    let lhs_ts : texpr list = List.map (fun a -> match a.it with
      | ExpA e -> translate_exp TermCtx e vm | _ -> texpr "eps") lhs_args in
    let lhs_strs : string list = List.map (fun (t : texpr) -> t.text) lhs_ts in
    let lhs_vars = List.concat_map (fun (t : texpr) -> t.vars) lhs_ts in

    let rhs_t = translate_exp rhs_ctx rhs_exp vm in

    let prem_items = List.concat_map (prem_items_of_prem vm) prem_list in
    let prem_scheduled = schedule_prems (SSet.of_list lhs_vars) [] prem_items in
    let prem_strs = List.map (fun (p : prem_sched) -> p.text) prem_scheduled in
    let prem_vars = List.concat_map (fun (p : prem_sched) -> p.vars @ p.binds) prem_scheduled in
    let prem_binds = List.concat_map (fun (p : prem_sched) -> p.binds) prem_scheduled in

    let has_owise = List.exists (fun p -> match p.it with ElsePr -> true | _ -> false) prem_list in
    let vm_vars = List.map snd vm in
    let all_collected = lhs_vars @ rhs_t.vars @ prem_vars @ vm_vars in
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
    all_bound := List.sort_uniq String.compare (!all_bound @ bound @ vm_vars);
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
    in
    let all_conds = prem_match_conds @ prem_bool_conds @ filtered_bconds in
    let cond = cond_join all_conds in
    let cond_str = if cond = "" then "" else " \n      if " ^ cond in
    Printf.sprintf "  %s %s = %s%s%s ."
      (if cond = "" then "eq" else "ceq")
      (format_call maude_fn lhs_strs) rhs_t.text cond_str
      (if has_owise then " [owise]" else "")
  ) insts in

  let truly_free = List.filter (fun v -> not (List.mem v !all_bound)) !all_free in
  let op_decl = Printf.sprintf "\n\n  op %s : %s -> %s .\n" maude_fn arg_sorts ret_sort in
  let rollrt_bridge_decl =
    if maude_fn = "$rollrt" then
      "  op $rollrt : Int Rectype -> Rectype .\n"
    else ""
  in
  let bound_decl = declare_vars_same_sort !all_bound "WasmTerminal" in
  let rollrt_bridge_var =
    if maude_fn = "$rollrt" then "  var ROLLRT-BRIDGE-R : Rectype .\n" else ""
  in
  let rollrt_bridge_eq =
    if maude_fn = "$rollrt" then
      "  eq $rollrt ( I, ROLLRT-BRIDGE-R ) = $rollrt ( CTORWIDXA1 ( I ) , ROLLRT-BRIDGE-R ) .\n"
    else ""
  in
  let free_decl = declare_ops_const_list truly_free "WasmTerminal" in
  "\n" ^ op_decl ^ rollrt_bridge_decl ^ bound_decl ^ rollrt_bridge_var ^ free_decl
  ^ rollrt_bridge_eq ^ String.concat "\n" eq_lines ^ "\n"

(* --- Step execution relation helpers ------------------------------------- *)

(** True if the given relation name is one of the three execution Step variants. *)
let is_step_exec_rel name =
  name = "Step" || name = "Step-pure" || name = "Step-read"

(** True if a rule has any RulePr premise (bridge / context / recursive rule).
    We skip these: they're either handled by the heating/cooling pattern in
    wasm-exec.maude or bridge to another Step variant. *)
let has_rule_premise prems =
  List.exists (fun p -> match p.it with RulePr _ -> true | _ -> false) prems

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

(** Check if a rule is a context rule: has exactly one RulePr premise
    for a Step/Step-pure/Step-read relation. *)
let is_ctxt_rule prems =
  let rule_prems = List.filter (fun p -> match p.it with RulePr _ -> true | _ -> false) prems in
  match rule_prems with
  | [p] -> (match p.it with
      | RulePr (id, _, _) -> is_step_exec_rel (sanitize id.it)
      | _ -> false)
  | _ -> false

(** Try to extract context info from a context rule conclusion.
    Returns Some (ctor_name, stable_args_texts, inner_is_var, is_frame_ctxt).
    Handles both direct CaseE and ListE [CaseE ...] (elaborator wraps single-elem lists). *)
let try_decode_ctxt_conclusion rel_name prefix conclusion vm =
  let get_inner_expr cfg_expr =
    if rel_name = "Step-pure" then Some cfg_expr
    else match try_decompose_config cfg_expr with
         | Some (_, instr_e) -> Some instr_e
         | None -> None
  in
  (* Try to match a CaseE (or ListE [CaseE]) for LABEL/FRAME/HANDLER *)
  let try_match_ctor e =
    let try_case mixop inner =
      let arity = match inner.it with TupE es -> List.length es | _ -> 1 in
      match canonical_ctor_name_arity mixop arity with
      | Some ctor_name when
          (let low = String.lowercase_ascii ctor_name in
           let has sub = let n = String.length sub in
             String.length low >= n && String.sub low 0 n = sub in
           has "ctorlabel" || has "ctorframe" || has "ctorhandler") ->
          let args = match inner.it with TupE es -> es | e -> [{ inner with it = e }] in
          let n_args = List.length args in
          if n_args >= 2 then begin
            let stable_args = List.filteri (fun i _ -> i < n_args - 1) args in
            let stable_texts =
              List.map (fun a -> (translate_exp TermCtx a vm).text) stable_args in
            let inner_var = prefix ^ "-INNER-IS" in
            let low = String.lowercase_ascii ctor_name in
            let is_frame = String.length low >= 9 && String.sub low 0 9 = "ctorframe" in
            Some (ctor_name, stable_texts, inner_var, is_frame)
          end else None
      | _ -> None
    in
    match e.it with
    | CaseE (mixop, inner) -> try_case mixop inner
    | ListE [single] ->
        (match single.it with
         | CaseE (mixop, inner) -> try_case mixop inner
         | _ -> None)
    | _ -> None
  in
  match conclusion.it with
  | TupE [lhs_e; _rhs_e] ->
      (match get_inner_expr lhs_e with
       | Some instr_e -> try_match_ctor instr_e
       | None -> None)
  | _ -> None

(** Generate Maude  step  rewrite rules for Step-pure / Step-read / Step rules.
    Pattern: crl [name] : step(< Z | LHS IS >) => < Z' | RHS IS > [if COND] .
    Rules with RulePr premises (bridge / context rules) are handled specially.
    Returns the generated Maude source fragment (declarations + rules). *)
let translate_step_reld rel_name rules =
  let rel_prefix           = String.uppercase_ascii (sanitize rel_name) in
  let all_bound            = ref [] in
  let all_is_vars          = ref [] in
  let all_val_seq_vars     = ref [] in
  let ctxt_ops_emitted     = ref false in

  let rule_lines = List.mapi (fun rule_idx r -> match r.it with
    | RuleD (case_id, binders, _, conclusion, prem_list) ->
        (* Skip bridge/context rules that delegate via RulePr;
           but context rules (exactly one Step RulePr) get heat/cool rules. *)
        if has_rule_premise prem_list then
          if not (is_ctxt_rule prem_list) then ""
          else begin
            let raw_prefix = String.uppercase_ascii (sanitize case_id.it) in
            let case_part  =
              if raw_prefix = "" then Printf.sprintf "R%d" rule_idx else raw_prefix in
            let prefix = Printf.sprintf "%s-%s" rel_prefix case_part in
            let vm     = binder_to_var_map prefix rule_idx binders in
            let all_seq_vars_ctxt =
              List.filter_map (fun b -> match b.it with
                | ExpB (v_id, t) ->
                    (match t.it with
                     | IterT (_, _) -> List.assoc_opt v_id.it vm
                     | _ -> None)
                | _ -> None) binders
              |> List.sort_uniq String.compare
            in
            let vm_vars_ctxt = List.map snd vm |> List.sort_uniq String.compare in
            all_val_seq_vars := !all_val_seq_vars @ all_seq_vars_ctxt;
            all_bound := !all_bound @ List.filter (fun v -> not (List.mem v all_seq_vars_ctxt)) vm_vars_ctxt;
            let z_var        = prefix ^ "-Z" in
            let is_var       = prefix ^ "-IS" in
            let is_rest_var  = prefix ^ "-IS-REST" in
            let inner_is_var = prefix ^ "-INNER-IS" in
            let n_var        = prefix ^ "-N" in
            all_is_vars := is_var :: is_rest_var :: inner_is_var :: !all_is_vars;
            all_bound   := z_var :: n_var :: !all_bound;
            match try_decode_ctxt_conclusion rel_name prefix conclusion vm with
            | None ->
                (* Not a label/frame/handler context — silently skip (bridge rule or ctxt-instrs) *)
                ""
            | Some (ctor_name, stable_texts, _inner_var, is_frame) ->
                let stable_str = String.concat ", " stable_texts in
                let rule_name = String.lowercase_ascii prefix in
                let low = String.lowercase_ascii ctor_name in
                let restore_name =
                  if is_frame then "restore-frame"
                  else if String.length low >= 9 && String.sub low 0 9 = "ctorlabel" then "restore-label"
                  else "restore-handler"
                in
                let is_label_ctxt =
                  String.length low >= 9 && String.sub low 0 9 = "ctorlabel"
                in
                (* Emit restore-op declarations once *)
                let op_decls =
                  if !ctxt_ops_emitted then ""
                  else begin
                    ctxt_ops_emitted := true;
                    "  op restore-label   : ExecConf WasmTerminal WasmTerminals WasmTerminals -> ExecConf .\n\
                     \  op restore-frame   : ExecConf WasmTerminal WasmTerminal  WasmTerminals -> ExecConf .\n\
                     \  op restore-handler : ExecConf WasmTerminal WasmTerminals WasmTerminals -> ExecConf .\n"
                  end
                in
                let zn_var = prefix ^ "-ZN" in
                all_bound := zn_var :: !all_bound;
                (* For frame context, also declare the outer-store/outer-frame split vars *)
                if is_frame then begin
                  all_bound := (n_var ^ "-S")        :: !all_bound;
                  all_bound := (n_var ^ "-F")        :: !all_bound;
                  all_bound := (prefix ^ "-F-OUTER") :: !all_bound
                end;
                let heat =
                  if is_frame then
                    (* stable_texts = [n_text; fq_text]
                       n_text  = arity N from FRAME constructor (e.g. STEP-CTXT-FRAME5-N)
                       fq_text = inner frame F from FRAME constructor (e.g. STEP-CTXT-FRAME5-FQ)
                       n_var   = prefix^"-N" used to name outer-store/outer-frame vars *)
                    let inner_frame_text = if List.length stable_texts >= 2
                                           then List.nth stable_texts 1 else n_var ^ "-FQ" in
                    let n_arity_text     = if List.length stable_texts >= 1
                                           then List.nth stable_texts 0 else n_var in
                    Printf.sprintf
                      "  crl [heat-%s] :\n    step(< CTORSEMICOLONA2 ( %s-S, %s-F ) | %s ( %s, %s ) %s >)\n    => %s(step(< CTORSEMICOLONA2 ( %s-S, %s ) | %s >), %s, %s-F, %s)\n    if all-vals ( %s ) = false /\\ is-trap ( %s ) = false ."
                      rule_name n_var n_var ctor_name stable_str inner_is_var is_rest_var
                      restore_name n_var inner_frame_text inner_is_var n_arity_text n_var is_rest_var
                      inner_is_var inner_is_var
                  else
                    let extra_cond =
                      if is_label_ctxt
                      then Printf.sprintf " /\\ needs-label-ctxt ( %s ) = false" inner_is_var
                      else ""
                    in
                    Printf.sprintf
                      "  crl [heat-%s] :\n    step(< %s | %s ( %s, %s ) %s >)\n    => %s(step(< %s | %s >), %s)\n    if all-vals ( %s ) = false /\\ is-trap ( %s ) = false%s ."
                      rule_name z_var ctor_name stable_str inner_is_var is_rest_var
                      restore_name z_var inner_is_var
                      (stable_str ^ ", " ^ is_rest_var)
                      inner_is_var inner_is_var extra_cond
                in
                let cool =
                  if is_frame then
                    Printf.sprintf
                      "  rl [cool-%s] :\n    %s(< %s | %s >, %s, %s-F-OUTER, %s)\n    => < CTORSEMICOLONA2 ( $store ( %s ), %s-F-OUTER ) | %s ( %s, $frame ( %s ), %s ) %s > ."
                      rule_name restore_name zn_var is_var n_var prefix is_rest_var
                      zn_var prefix ctor_name n_var zn_var is_var is_rest_var
                  else
                    Printf.sprintf
                      "  rl [cool-%s] :\n    %s(< %s | %s >, %s)\n    => < %s | %s ( %s, %s ) %s > ."
                      rule_name restore_name zn_var is_var
                      (stable_str ^ ", " ^ is_rest_var)
                      zn_var ctor_name stable_str is_var is_rest_var
                in
                op_decls ^ heat ^ "\n" ^ cool
          end
        else begin
          let raw_prefix = String.uppercase_ascii (sanitize case_id.it) in
          let case_part  =
            if raw_prefix = "" then Printf.sprintf "R%d" rule_idx else raw_prefix in
          let prefix = Printf.sprintf "%s-%s" rel_prefix case_part in
          let vm     = binder_to_var_map prefix rule_idx binders in
          let bconds = binder_to_type_conds binders vm in

          (* Identify ALL sequence binders: IterT(any, any iter) including ListN.
             All of these become WasmTerminals variables (not WasmTerminal).
             Val-sort sequences additionally get all-vals guards. *)
          let all_seq_vars =
            List.filter_map (fun b -> match b.it with
              | ExpB (v_id, t) ->
                  (match t.it with
                   | IterT (_, _) -> List.assoc_opt v_id.it vm
                   | _ -> None)
              | _ -> None) binders
            |> List.sort_uniq String.compare
          in
          (* Val-sort sequence binders: also need all-vals guards *)
          let val_seq_vars =
            List.filter_map (fun b -> match b.it with
              | ExpB (v_id, t) ->
                  (match t.it with
                   | IterT (inner_t, _) ->
                       (match simple_sort_of_typ inner_t [] with
                        | Some s when s = "Val" ->
                            List.assoc_opt v_id.it vm
                        | _ -> None)
                   | _ -> None)
              | _ -> None) binders
            |> List.sort_uniq String.compare
          in
          (* Remove ALL seq vars from bconds (drop their type checks) *)
          let bconds =
            List.filter (fun (mv, _) -> not (List.mem mv all_seq_vars)) bconds
          in
          all_val_seq_vars := !all_val_seq_vars @ all_seq_vars;

          (* Reset the global ListN accumulator before translating this rule.
             translate_exp will populate it with count→sequence pairs found
             inside IterE(_, (ListN(count_e, _), _)) sub-expressions. *)
          reset_listn_pairs ();

          (* Unique continuation variable for this rule *)
          let is_var = prefix ^ "-IS" in
          all_is_vars := is_var :: !all_is_vars;

          (* ---- decode conclusion into (z_in, z_in_vars, lhs_t, z_out, rhs_t) --
             z_in      : Maude text that goes into the step(< Z | ...>) pattern
             z_in_vars : actual simple variable names inside z_in (used for var
                         tracking).  When z_in is a compound term like
                         CTORSEMICOLONA2(S,F), z_in_vars = [S; F] so that only
                         simple identifiers end up in the `vars` declaration.  *)
          let decoded : (string * string list * texpr * string * texpr) option =
            if rel_name = "Step-pure" then
              (* TupE [ lhs_instrs , rhs_instrs ]  — no state in spec rule *)
              (match conclusion.it with
               | TupE [lhs; rhs] ->
                   let z_var = prefix ^ "-Z" in
                   Some (z_var, [z_var],
                         translate_exp TermCtx lhs vm,
                         z_var, translate_exp TermCtx rhs vm)
               | _ -> None)
            else if rel_name = "Step-read" then
              (* TupE [ z;lhs_instrs , rhs_instrs ] *)
              (match conclusion.it with
               | TupE [cfg_lhs; rhs] ->
                   (match try_decompose_config cfg_lhs with
                    | Some (z_e, lhs_e) ->
                        let z_t   = translate_exp TermCtx z_e   vm in
                        let lhs_t = translate_exp TermCtx lhs_e vm in
                        let rhs_t = translate_exp TermCtx rhs   vm in
                        Some (z_t.text, z_t.vars, lhs_t, z_t.text, rhs_t)
                    | None -> None)
               | _ -> None)
            else
              (* Step:  TupE [ z;lhs , z';rhs ] *)
              (match conclusion.it with
               | TupE [cfg_lhs; cfg_rhs] ->
                   (match try_decompose_config cfg_lhs,
                          try_decompose_config cfg_rhs with
                    | Some (z_e, lhs_e), Some (zp_e, rhs_e) ->
                        let z_t   = translate_exp TermCtx z_e   vm in
                        let lhs_t = translate_exp TermCtx lhs_e vm in
                        let zp_t  = translate_exp TermCtx zp_e  vm in
                        let rhs_t = translate_exp TermCtx rhs_e vm in
                        Some (z_t.text, z_t.vars, lhs_t, zp_t.text, rhs_t)
                    | _ -> None)
               | _ -> None)
          in

          match decoded with
          | None ->
              Printf.eprintf
                "[WARN] translate_step_reld: cannot decode %s rule %s (#%d)\n%!"
                rel_name prefix rule_idx;
              ""
          | Some (z_in, z_in_vars, lhs_t, z_out, rhs_t) ->

            (* ---- schedule premises ------------------------------------ *)
            let vm_vars  = List.map snd vm in
            let lhs_vars = vars_of_texpr lhs_t in
            (* Collect premise items early so we know which vm_vars appear as
               binding targets on the LHS of a PremEq (e.g. "c <- $binop(...)"
               or "b* = $nbytes(...)").  Those variables must NOT be pre-marked
               as bound in lhs_set, otherwise classify_prem would emit a boolean
               test instead of a :=-binding.
               Variables that only appear in the RHS (like N in BLOCK) are NOT
               binding targets and stay in lhs_set via vm_vars; this preserves
               the old behaviour where their boolean conditions fail safely and
               the equation does not fire. *)
            let prem_items = List.concat_map (prem_items_of_prem vm) prem_list in
            let vm_var_set = SSet.of_list vm_vars in
            let lhs_t_var_set = SSet.of_list lhs_vars in
            (* Variables in vm_vars that appear as the LHS of some PremEq — these
               are the premise-binding targets that must be excluded from lhs_set. *)
            let prem_binding_targets =
              List.concat_map (fun item ->
                match item with
                | PremEq { lhs; rhs; _ } ->
                    (* Both lhs-side and rhs-side of an equality can be binding
                       targets: "c <- $f(...)" → PremEq{lhs=c, rhs=$f(...)},
                       "$g(...) = c"          → PremEq{lhs=$g(...), rhs=c},
                       "val = REF_NULL(ht)"   → PremEq{lhs=val, rhs=REF_NULL(ht)}
                       We collect every vm_var that appears on either side and
                       is not already present in the LHS pattern. *)
                    let pick side =
                      List.filter (fun v ->
                        SSet.mem v vm_var_set && not (SSet.mem v lhs_t_var_set))
                        (vars_of_texpr side) in
                    pick lhs @ pick rhs
                | _ -> []) prem_items
              |> List.sort_uniq String.compare
            in
            let prem_binding_set = SSet.of_list prem_binding_targets in
            (* lhs_set: start with LHS-pattern vars, plus those vm_vars that are
               NOT premise-binding targets (they stay "pre-bound" so their boolean
               conditions fail safely and the equation does not fire unexpectedly). *)
            let lhs_set =
              SSet.of_list (z_in_vars @ lhs_vars @
                List.filter (fun v -> not (SSet.mem v prem_binding_set)) vm_vars)
            in
            let prem_scheduled = schedule_prems lhs_set [] prem_items in
            let prem_strs      = List.map (fun (p : prem_sched) -> p.text) prem_scheduled in
            let prem_binds     = List.concat_map (fun p -> p.binds) prem_scheduled in
            (* Some premise-bound variables are true sequence binders, but many are
              scalar values (e.g. C in C := $binop(...)).  Promote only those
              premise binds that are known sequence binders for this rule. *)
            let prem_binds_seq =
              List.filter (fun v -> List.mem v all_seq_vars) prem_binds
            in
            all_val_seq_vars := !all_val_seq_vars @ prem_binds_seq;

            let all_texts = [lhs_t.text; rhs_t.text] @ prem_strs in
            let all_cvars = (z_in_vars @ lhs_vars @ vm_vars) @
              List.concat_map (fun p -> p.vars @ p.binds) prem_scheduled in
            let lhs_seed  = List.sort_uniq String.compare (z_in_vars @ lhs_vars @ prem_binds) in
            let (bound, _free, lhs_set2) = partition_vars lhs_seed all_texts all_cvars in
            all_bound := !all_bound @ bound @ vm_vars;

            let has_numtype_guard cond =
              let s = String.trim cond in
              try
                ignore (Str.search_forward (Str.regexp ": Numtype\\b") s 0);
                true
              with Not_found -> false
            in
            let filtered_bconds =
              bconds
              |> List.filter (fun (mv, _) ->
                  List.mem mv lhs_set2 && not (List.mem mv prem_binds))
              |> List.map snd
              |> fun conds ->
                   if rel_name = "Step-pure" then
                     List.filter (fun c -> not (has_numtype_guard c)) conds
                   else conds
            in
            let prem_match_conds =
              prem_scheduled |> List.filter_map (fun p ->
                if p.binds = [] then None else Some (prem_cond p.text)) in
            let prem_bool_conds =
              prem_scheduled |> List.filter_map (fun p ->
                if p.binds = [] then Some (prem_cond p.text) else None) in
            (* Add all-vals guards for val-sequence vars *)
            let allvals_conds =
              List.map (fun mv -> Printf.sprintf "all-vals ( %s ) = true" mv) val_seq_vars
            in
            (* Add len() bindings for ListN count variables.
               These must come AFTER the prem_match_conds that bind the
               sequence variables (e.g. TR from $blocktype binding).
               We only emit the binding if the count var is NOT already
               bound in the LHS pattern (to avoid double-binding).
               g_listn_pairs was populated by translate_exp during the
               translation of the RHS and premise expressions. *)
            let listn_len_conds =
              List.filter_map (fun (cnt_mv, seq_mv) ->
                if List.mem cnt_mv lhs_set2 then None  (* already bound in LHS *)
                else Some (Printf.sprintf "%s := len ( %s )" cnt_mv seq_mv)
              ) !g_listn_pairs
            in
            let all_conds = allvals_conds @ prem_match_conds @ listn_len_conds @ prem_bool_conds @ filtered_bconds in
            let cond     = cond_join all_conds in
            if cond = "" then
              Printf.sprintf "  rl [%s] :\n    step(< %s | %s %s >)\n    =>\n    < %s | %s %s > ."
                (String.lowercase_ascii prefix)
                z_in lhs_t.text is_var z_out rhs_t.text is_var
            else
              Printf.sprintf "  crl [%s] :\n    step(< %s | %s %s >)\n    =>\n    < %s | %s %s >\n      if %s ."
                (String.lowercase_ascii prefix)
                z_in lhs_t.text is_var z_out rhs_t.text is_var cond
        end
  ) rules in

  (* Safety filter: reject any accumulated string that is not a simple Maude
     identifier (e.g. compound terms like "CTORSEMICOLONA2(S,F)" must never
     appear as variable names in a `vars` declaration). *)
  let is_simple_var s =
    String.length s > 0
    && not (String.contains s '(')
    && not (String.contains s ')')
    && not (String.contains s ',')
    && not (String.contains s ' ')
  in
  let bound_vars_wt  = List.filter (fun v -> not (List.mem v !all_val_seq_vars))
                         (List.filter is_simple_var (List.sort_uniq String.compare !all_bound)) in
  let bound_vars_wts = List.filter is_simple_var
                         (List.sort_uniq String.compare !all_val_seq_vars) in
  let is_vars    = List.sort_uniq String.compare !all_is_vars in
  let bound_decl = declare_vars_same_sort bound_vars_wt  "WasmTerminal" in
  let vals_decl  = declare_vars_same_sort bound_vars_wts "WasmTerminals" in
  let is_decl    = declare_vars_same_sort is_vars        "WasmTerminals" in
  let ctxt_instrs_extra =
    if rel_name = "Step" then
      "  op restore-instrs : ExecConf WasmTerminals WasmTerminals -> ExecConf .\n" ^
      "  var STEP-CTXT-INSTRS-GEN-Z : WasmTerminal .\n" ^
      "  vars STEP-CTXT-INSTRS-GEN-VAL STEP-CTXT-INSTRS-GEN-REST STEP-CTXT-INSTRS-GEN-INNERQ : WasmTerminals .\n" ^
      "  vars STEP-CTXT-INSTRS-GEN-W STEP-CTXT-INSTRS-GEN-INNER : WasmTerminal .\n" ^
      "  crl [heat-step-ctxt-instrs] :\n" ^
      "    step(< STEP-CTXT-INSTRS-GEN-Z | STEP-CTXT-INSTRS-GEN-VAL STEP-CTXT-INSTRS-GEN-W STEP-CTXT-INSTRS-GEN-INNER STEP-CTXT-INSTRS-GEN-REST >)\n" ^
      "    => restore-instrs(step(< STEP-CTXT-INSTRS-GEN-Z | STEP-CTXT-INSTRS-GEN-INNER >), STEP-CTXT-INSTRS-GEN-VAL STEP-CTXT-INSTRS-GEN-W, STEP-CTXT-INSTRS-GEN-REST)\n" ^
      "    if all-vals ( STEP-CTXT-INSTRS-GEN-VAL ) = true /\\ is-val ( STEP-CTXT-INSTRS-GEN-W ) = true /\\ is-val ( STEP-CTXT-INSTRS-GEN-INNER ) = false /\\ is-trap ( STEP-CTXT-INSTRS-GEN-INNER ) = false .\n" ^
      "  rl [cool-step-ctxt-instrs] :\n" ^
      "    restore-instrs(< STEP-CTXT-INSTRS-GEN-Z | STEP-CTXT-INSTRS-GEN-INNERQ >, STEP-CTXT-INSTRS-GEN-VAL STEP-CTXT-INSTRS-GEN-W, STEP-CTXT-INSTRS-GEN-REST)\n" ^
      "    => < STEP-CTXT-INSTRS-GEN-Z | STEP-CTXT-INSTRS-GEN-VAL STEP-CTXT-INSTRS-GEN-W STEP-CTXT-INSTRS-GEN-INNERQ STEP-CTXT-INSTRS-GEN-REST > .\n"
    else ""
  in
  bound_decl ^ vals_decl ^ is_decl ^ ctxt_instrs_extra
  ^ String.concat "\n" (List.filter (fun s -> s <> "") rule_lines)
  ^ "\n"

(* --- RelD handler -------------------------------------------------------- *)

let translate_reld _id rel_name rules =
  let arity = match rules with
    | r :: _ -> (match r.it with RuleD (_, _, _, c, _) ->
        (match c.it with TupE el -> List.length el | _ -> 1))
    | [] -> 0 in
  let op_decl = Printf.sprintf "\n  op %s : %s -> Bool .\n" rel_name
    (String.concat " " (List.init arity (fun _ -> "WasmTerminal"))) in
  let rel_prefix = String.uppercase_ascii (sanitize rel_name) in

  (* True if any RulePr premise references a Step/Step-pure/Step-read relation.
     Such rules (e.g. the transitive case of Steps) cannot be expressed as a
     Bool ceq because Step is translated as an equational step() function, not
     a Bool op.  Skipping them eliminates the "bad token Step" parse errors. *)
  let has_step_exec_rule_premise prems =
    List.exists (fun p -> match p.it with
      | RulePr (id, _, _) -> is_step_exec_rel (sanitize id.it)
      | _ -> false) prems
  in

  let all_bound = ref [] and all_free = ref [] in
  let rule_lines = List.mapi (fun rule_idx r -> match r.it with
    | RuleD (case_id, binders, _, conclusion, prem_list) ->
        (* Skip rules whose premises reference Step/Step-pure/Step-read as a
           Bool predicate — those are untranslatable in the Bool-relation world. *)
        if has_step_exec_rule_premise prem_list then ""
        else begin
        let raw_prefix = String.uppercase_ascii (sanitize case_id.it) in
        let case_part = if raw_prefix = "" then Printf.sprintf "R%d" rule_idx else raw_prefix in
        let prefix = Printf.sprintf "%s-%s" rel_prefix case_part in
        let vm = binder_to_var_map prefix rule_idx binders in
        let bconds = binder_to_type_conds binders vm in

        let lhs_t = match conclusion.it with
          | TupE el -> tconcat " , " (List.map (fun x -> translate_exp TermCtx x vm) el)
          | _ -> translate_exp TermCtx conclusion vm in

        (* Apply the same prem_binding_targets logic as translate_step_reld:
           only pre-mark vm_vars that are NOT binding targets of any PremEq as
           "already bound".  This allows existential variables (those that
           appear on the fresh side of an equality in a premise) to be bound
           via := rather than emitted as unbound free variables. *)
        let prem_items = List.concat_map (prem_items_of_prem vm) prem_list in
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

        let all_collected = lhs_t.vars @ prem_vars @ vm_vars in
        let all_texts = [lhs_t.text] @ prem_strs in
        let lhs_bound_seed = List.sort_uniq String.compare (lhs_t.vars @ prem_binds) in
        let (bound, free, lhs_set) = partition_vars lhs_bound_seed all_texts all_collected in

        let filtered_bconds =
          bconds
          |> List.filter (fun (mv, _) -> List.mem mv lhs_set && not (List.mem mv prem_binds))
          |> List.map snd in
        all_bound := List.sort_uniq String.compare (!all_bound @ bound @ vm_vars);
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
        in
        let all_conds = prem_match_conds @ prem_bool_conds @ filtered_bconds in
        let cond = cond_join all_conds in
        let cond_str = if cond = "" then "" else " \n      if " ^ cond in
        Printf.sprintf "  %s %s ( %s ) = true%s ."
          (if cond = "" then "eq" else "ceq")
          rel_name lhs_t.text cond_str
        end
  ) rules in

  let truly_free = List.filter (fun v -> not (List.mem v !all_bound)) !all_free in
  let bound_decl = declare_vars_same_sort !all_bound "WasmTerminal" in
  let free_decl = declare_ops_const_list truly_free "WasmTerminal" in
  op_decl ^ bound_decl ^ free_decl ^ String.concat "\n" rule_lines ^ "\n"

(* --- Top-level definition dispatch --------------------------------------- *)

let rec translate_definition ss (d : def) = match d.it with
  | RecD defs -> String.concat "\n" (List.map (translate_definition ss) defs)
  | TypD (id, params, insts) -> translate_typd id params insts
  | DecD (id, params, result_typ, insts) -> translate_decd ss id params result_typ insts
  | RelD (id, _, _, rules) ->
      let name = sanitize id.it in
      if is_step_exec_rel name then translate_step_reld name rules
      else translate_reld id name rules
  | GramD _ | HintD _ -> ""

(* ========================================================================= *)
(* 9. Top-level: prescan → header → translate → reorder → emit              *)
(* ========================================================================= *)

let header_prefix =
  "load dsl/pretype \n\n" ^
  "mod SPECTEC-CORE is\n" ^
  "  inc DSL-RECORD .\n" ^
  "  inc BOOL .\n" ^
  "  inc INT .\n\n" ^
  "  --- Base Sorts\n" ^
  "  subsort Int < WasmTerminal .\n" ^
  "  subsort Nat < WasmTerminal .\n\n" ^
  "  --- Allow type atoms to appear as terminals (for mixed AST encodings)\n" ^
  "  subsort WasmType < WasmTerminal .\n" ^
  "  subsort WasmTypes < WasmTerminals .\n\n" ^
  "  --- Nat is a subtype of index-like and numeric-parameter sorts\n" ^
  "  --- (spectec idx = u32 = nat; N/M/K are nat-valued type parameters)\n" ^
  "  subsort Nat < N .\n" ^
  "  subsort Nat < M .\n" ^
  "  subsort Nat < K .\n" ^
  "  subsort Nat < Labelidx .\n" ^
  "  subsort Nat < Localidx .\n" ^
  "  subsort Nat < Typeidx .\n" ^
  "  subsort Nat < Funcidx .\n" ^
  "  subsort Nat < Globalidx .\n" ^
  "  subsort Nat < Tableidx .\n" ^
  "  subsort Nat < Memidx .\n" ^
  "  subsort Nat < Tagidx .\n" ^
  "  subsort Nat < Elemidx .\n" ^
  "  subsort Nat < Dataidx .\n" ^
  "  subsort Nat < Fieldidx .\n" ^
  "  subsort Nat < Addr .\n" ^
  "  subsort Nat < Idx .\n\n" ^
  "  --- Bool wrapper (avoid subsort Bool < WasmTerminal conflicts)\n" ^
  "  op w-bool : Bool -> WasmTerminal [ctor] .\n\n" ^
  "  --- Basic Wasm Types\n" ^
  "  ops w-N w-M w-K w-n w-m w-X w-C w-I w-S w-T w-V w-b w-z w-L w-E : -> WasmType [ctor] .\n\n" ^
  "  --- Special Operators\n" ^
  "  op type-ok : WasmTerminal WasmType -> Bool .\n" ^
  "  op _shape-x_ : WasmTerminal WasmTerminal -> WasmTerminal [ctor] .\n" ^
  "  op slice : WasmTerminals WasmTerminal WasmTerminal -> WasmTerminals .\n" ^
  "  op _<-_ : WasmTerminal WasmTerminals -> Bool .\n\n" ^
  "  --- Generic record/terminal combinators (parser support)\n" ^
  "  op merge : WasmTerminal WasmTerminal -> WasmTerminal [ctor] .\n" ^
  "  op _=++_ : WasmTerminal WasmTerminal -> WasmTerminal [ctor] .\n" ^
  "  op any : -> WasmTerminal [ctor] .\n\n" ^
  "  --- ExecConf: execution configuration for step-based semantics\n" ^
  "  sort ExecConf .\n" ^
  "  op <_|_> : WasmTerminal WasmTerminals -> ExecConf [ctor] .\n" ^
  "  op step : ExecConf -> ExecConf .\n\n" ^
  "  --- Execution predicates (used by step crl conditions)\n" ^
  "  op is-val : WasmTerminal -> Bool .\n" ^
  "  op all-vals : WasmTerminals -> Bool .\n" ^
  "  op is-trap : WasmTerminals -> Bool .\n\n" ^
  "  --- Context-sensitive control-flow detector\n" ^
  "  op needs-label-ctxt : WasmTerminals -> Bool .\n\n" ^
  "  --- Common variables (declared once)\n" ^
  "  var I : Int .\n" ^
  "  var W-I : Int .\n" ^
  "  op EXP : -> Int .\n" ^
  "  vars W-N W-M : Nat .\n" ^
  "  vars T W WW : WasmTerminal .\n" ^
  "  vars TS W* : WasmTerminals .\n\n"

let footer =
  "\n  --- Execution predicate equations (auto-added; use Val sort membership)\n" ^
  "  eq  is-val(CTORCONSTA2(T, W)) = true .\n" ^
  "  eq  is-val(CTORVCONSTA2(T, W)) = true .\n" ^
  "  ceq is-val(W) = true if W : Val .\n" ^
  "  eq  is-val(W) = false [owise] .\n\n" ^
  "  ceq all-vals(W TS) = all-vals(TS) if is-val(W) = true .\n" ^
  "  eq  all-vals(eps) = true .\n" ^
  "  eq  all-vals(TS) = false [owise] .\n\n" ^
  "  --- Label-context control-flow detector\n" ^
  "  eq  needs-label-ctxt(eps) = false .\n" ^
  "  ceq needs-label-ctxt(W TS) = needs-label-ctxt(TS) if is-val(W) = true .\n" ^
  "  eq  needs-label-ctxt(CTORBRA1(T) TS) = true .\n" ^
  "  eq  needs-label-ctxt(CTORRETURNA0 TS) = true .\n" ^
  "  eq  needs-label-ctxt(CTORRETURNCALLREFA1(T) TS) = true .\n" ^
  "  eq  needs-label-ctxt(CTORTHROWREFA0 TS) = true .\n" ^
  "  eq  needs-label-ctxt(TS) = false [owise] .\n\n" ^
  "  eq  is-trap(CTORTRAPA0 TS) = true .\n" ^
  "  eq  is-trap(TS) = false [owise] .\n" ^
  "\nendm\n"

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

let collect_ctor_decl_lines eq_lines =
  let re = Str.regexp "CTOR[A-Z0-9]+A[0-9]+" in
  let seen = Hashtbl.create 512 in
  let add_name nm =
    if not (Hashtbl.mem seen nm) then Hashtbl.add seen nm ()
  in
  let scan_line l =
    let rec loop pos =
      match (try Some (Str.search_forward re l pos) with Not_found -> None) with
      | None -> ()
      | Some _ ->
          let nm = Str.matched_string l in
          add_name nm;
          loop (Str.match_end ())
    in
    loop 0
  in
  List.iter scan_line eq_lines;
  Hashtbl.to_seq_keys seen
  |> List.of_seq
  |> List.sort_uniq String.compare
  |> List.map (fun nm ->
       let idx_a = try String.rindex nm 'A' with Not_found -> String.length nm - 1 in
       let arity =
         try int_of_string (String.sub nm (idx_a + 1) (String.length nm - idx_a - 1))
         with _ -> 0
       in
       (* Use WasmTerminals for all CTOR arguments: sequence arguments (valtype*, instr*, etc.)
          need WasmTerminals; single WasmTerminal values are also WasmTerminals via subsort. *)
       let args = if arity <= 0 then "" else String.concat " " (List.init arity (fun _ -> "WasmTerminals")) in
       Printf.sprintf "  op %s : %s -> WasmTerminal [ctor] ." nm args)

let collect_declared_identifiers decl_lines =
  let add_many set names = List.fold_left (fun s n -> if n = "" then s else SSet.add n s) set names in
  List.fold_left (fun acc l ->
    let s = String.trim l in
    if starts_with s "var " then
      let rest = String.sub s 4 (String.length s - 4) in
      let lhs = try String.sub rest 0 (String.index rest ':') with _ -> rest in
      add_many acc [String.trim lhs]
    else if starts_with s "vars " then
      let rest = String.sub s 5 (String.length s - 5) in
      let lhs = try String.sub rest 0 (String.index rest ':') with _ -> rest in
      add_many acc (String.split_on_char ' ' (String.trim lhs))
    else if starts_with s "op " then
      let rest = String.sub s 3 (String.length s - 3) in
      let nm = try String.sub rest 0 (String.index rest ' ') with _ -> rest in
      add_many acc [String.trim nm]
    else if starts_with s "ops " then
      let rest = String.sub s 4 (String.length s - 4) in
      let lhs = try String.sub rest 0 (String.index rest ':') with _ -> rest in
      add_many acc (String.split_on_char ' ' (String.trim lhs))
    else acc
  ) SSet.empty decl_lines

let chunk_list n xs =
  let rec go acc cur k = function
    | [] -> List.rev (if cur = [] then acc else List.rev cur :: acc)
    | x :: xt ->
        if k = n then go (List.rev cur :: acc) [x] 1 xt
        else go acc (x :: cur) (k + 1) xt
  in
  if n <= 0 then [xs] else go [] [] 0 xs

let collect_fallback_var_decl_lines eq_lines decl_lines =
  let declared = collect_declared_identifiers decl_lines in
  let extra_excluded =
    SSet.of_list
      ["EQ"; "CEQ"; "MB"; "CMB"; "RL"; "CRL"; "OWISE";
       "TRUE"; "FALSE"; "BOOL"; "INT"; "NAT"]
  in
  let all_vars = extract_vars_from_maude (String.concat "\n" eq_lines) in
  let missing =
    all_vars
    |> List.filter (fun v ->
         String.length v > 0
         && not (starts_with v "CTOR")
         && not (SSet.mem v declared)
         && not (SSet.mem v extra_excluded))
    |> List.sort_uniq String.compare
  in
  chunk_list 24 missing
  |> List.filter (fun xs -> xs <> [])
  |> List.map (fun xs -> Printf.sprintf "  vars %s : WasmTerminal ." (String.concat " " xs))

let translate defs =
  build_type_env defs;
  init_declared_vars ();
  let ss = new_scan () in
  List.iter (scan_def ss) defs;
  let token_ops = build_token_ops ss in
  let call_ops = build_call_ops ss in
  let header = header_prefix ^ "  --- Auto-collected tokens\n" ^ token_ops ^ call_ops in
  let body = String.concat "\n" (List.map (translate_definition ss) defs) in
  let lines = String.split_on_char '\n' body in
  let header_decl_lines =
    header
    |> String.split_on_char '\n'
    |> List.filter is_decl_line
    |> List.sort_uniq String.compare
  in
  let eqs = List.filter (fun l -> not (is_decl_line l)) lines in
  let ctor_decl_lines = collect_ctor_decl_lines eqs in
  let raw_decls =
    List.filter is_decl_line lines
    |> List.filter (fun l -> not (is_canonical_ctor_decl_line l))
    |> List.sort_uniq String.compare
    |> fun ds ->
         let base = List.sort_uniq String.compare (ds @ ctor_decl_lines) in
         let fallback_var_decls =
           collect_fallback_var_decl_lines eqs (base @ header_decl_lines)
         in
         List.sort_uniq String.compare (base @ fallback_var_decls)
  in
  (* Post-processing fix 1: Remove 0-arity "op X :  -> WasmType [ctor]" when a
     1-arity "op X : WasmTerminal -> WasmType [ctor]" for the SAME name exists.
     Avoids "multiple distinct parses" for names like num, vec. *)
  let re_zero_arity = Str.regexp "  op \\([^ (]+\\) :  -> \\(WasmType\\|WasmTerminal\\) \\[ctor\\] \\." in
  let re_higher_arity = Str.regexp "  op \\([^ (]+\\) : WasmTerminal" in
  let higher_arity_names =
    List.filter_map (fun l ->
      if Str.string_match re_higher_arity l 0
      then Some (Str.matched_group 1 l)
      else None
    ) raw_decls
    |> List.sort_uniq String.compare
    |> fun ns -> List.fold_left (fun s n -> SSet.add n s) SSet.empty ns
  in
  (* Post-processing fix 2: Collect all var-declared names, then remove
     "op X : -> WasmTerminal ." or "op X :  -> WasmType [ctor]" when
     "var X : ..." already declared — prevents op/var ambiguity. *)
  let re_var_decl = Str.regexp "  var\\s+\\([A-Z][A-Z0-9-]*\\) :" in
  let var_names =
    List.filter_map (fun l ->
      if Str.string_match re_var_decl l 0
      then Some (Str.matched_group 1 l)
      else None
    ) raw_decls
    |> List.sort_uniq String.compare
    |> fun ns -> List.fold_left (fun s n -> SSet.add n s) SSet.empty ns
  in
  let decls =
    List.filter (fun l ->
      if Str.string_match re_zero_arity l 0 then
        let nm = Str.matched_group 1 l in
        (* keep if no higher-arity version and not a var *)
        not (SSet.mem nm higher_arity_names) && not (SSet.mem nm var_names)
      else true
    ) raw_decls
    (* Also remove "op X : -> WasmTerminal ." (single space) when var X exists *)
    |> List.filter (fun l ->
      let s = String.trim l in
      if starts_with s "op " then
        let re = Str.regexp "op \\([^ (]+\\) : -> WasmTerminal \\." in
        if Str.string_match re s 0 then
          let nm = Str.matched_group 1 s in
          not (SSet.mem nm var_names)
        else true
      else true
    )
  in
  header ^ "\n  --- Declarations\n" ^ String.concat "\n" decls ^
  "\n\n  --- Equations\n" ^ String.concat "\n" eqs ^ footer
