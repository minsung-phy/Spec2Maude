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
      String.length name = 1
      || (String.length name > 0 && name.[0] <> '$' && not (is_alpha name.[0]))
      || SSet.mem (String.lowercase_ascii name) maude_keywords
    in
    let base = if needs_prefix then "w-" ^ name else name in
    let mapped = String.map (function
      | '.' | '_' | '\'' | '*' | '+' | '?' -> '-'
      | c -> c) base
    in
    let buf = Buffer.create (String.length mapped) in
    let len = String.length mapped in
    let rec scan i =
      if i >= len then ()
      else if mapped.[i] = '-' && i + 1 < len
           && mapped.[i + 1] >= '0' && mapped.[i + 1] <= '9' then
        (Buffer.add_char buf 'N'; Buffer.add_char buf mapped.[i + 1]; scan (i + 2))
      else
        (Buffer.add_char buf mapped.[i]; scan (i + 1))
    in
    scan 0;
    let res = Buffer.contents buf in
    if String.length res > 0 && res.[String.length res - 1] = '-'
    then String.sub res 0 (String.length res - 1)
    else res

let to_var_name name = String.uppercase_ascii (sanitize name)

let is_token_like_id raw =
  is_upper_start raw
  && String.length raw > 1
  && not (raw = "I" || raw = "T" || raw = "W")
  && not (String.length raw >= 2 && raw.[0] = 'W' && raw.[1] = '-')

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
  List.map (fun atoms ->
    atoms |> List.map Xl.Atom.name |> String.concat "" |> sanitize
  ) mixop

let interleave_lhs sections vars =
  let rec go secs vs = match secs, vs with
    | [], rest -> rest
    | s :: ss, v :: vs' -> (if s <> "" then [s; v] else [v]) @ go ss vs'
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
      ("WW", "WasmTerminal"); ("W-X", "WasmTerminal");
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

let rec scan_exp ss (e : exp) = match e.it with
  | VarE id ->
      if id.it = "_" then ss.tokens <- SSet.add "any" ss.tokens
      else if is_token_like_id id.it then scan_add_token ss id.it
  | CaseE (_, inner) -> scan_exp ss inner
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
  let toks = SSet.diff ss.tokens ss.ctors |> SSet.elements in
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
  | args -> Printf.sprintf "%s ( %s )" fn (String.concat ", " args)

let wrap_bool ctx s = match ctx with
  | BoolCtx -> s
  | TermCtx -> Printf.sprintf "w-bool ( %s )" s

let rec exp_is_boolish (e : exp) = match e.it with
  | BoolE _ | CmpE _ | MemE _ | UnE (`NotOp, _, _) -> true
  | BinE ((`AndOp | `OrOp | `ImplOp | `EquivOp), _, _, _) -> true
  | IfE (_, e1, e2) -> exp_is_boolish e1 && exp_is_boolish e2
  | _ -> false

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
      | `MinusOp -> tmap (Printf.sprintf " - ( %s ) ") (translate_exp TermCtx e1 vm)
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
           (match List.assoc_opt full vm with
            | Some mapped -> texpr mapped
            | None -> let v = String.uppercase_ascii (sanitize full) in texpr_with_var v v)
       | _ -> translate_exp ctx e1 vm)
  | IfE (c, e1, e2) ->
      tjoin3 (Printf.sprintf "if %s then %s else %s fi")
        (translate_exp BoolCtx c vm) (translate_exp ctx e1 vm) (translate_exp ctx e2 vm)

and translate_var ctx name vm =
  match List.find_opt (fun (k, _) ->
    String.lowercase_ascii k = String.lowercase_ascii name) vm
  with
  | Some (_, mapped) -> texpr_with_var mapped mapped
  | None ->
      let low = String.lowercase_ascii name in
      if low = "true" then texpr (wrap_bool ctx "true")
      else if low = "false" then texpr (wrap_bool ctx "false")
      else if is_token_like_id name then texpr (sanitize name)
      else match resolve_suffixed name vm with
        | Some v -> texpr_with_var v v
        | None -> let v = to_var_name name in texpr_with_var v v

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
    if op_name = "shape-x" then
      match args with
      | [a; b] -> tjoin2 (Printf.sprintf "( %s shape-x %s )") a b
      | _ -> texpr "eps"
    else
      { text = interleave_lhs (mixop_sections mixop) (List.map (fun t -> t.text) args);
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
  let tp = translate_path path vm in
  let t2 = translate_exp TermCtx e2 vm in
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
      tjoin2 (Printf.sprintf "( %s == %s )")
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
    | ExpB (tid, _) ->
        Some (Printf.sprintf "is-type ( %s , %s )" (to_var_name tid.it) (sanitize tid.it))
    | _ -> None
  ) binders

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
  let sig_types = String.concat " " (List.map (fun _ -> "WasmTerminal") params) in
  let op_decl =
    if SSet.mem name base_types then ""
    else Printf.sprintf "  op %s : %s -> WasmType [ctor] .\n" name sig_types in
  let res = List.map (fun inst -> match inst.it with
    | InstD (binders, args, deftyp) ->
        let v_map = binder_var_map binders in
        let binder_conds = binder_type_conds binders in
        let args_str = String.concat " , " (List.map (fun a -> (translate_arg a v_map).text) args) in
        let full_type_name =
          if args_str = "" then name else name ^ " ( " ^ args_str ^ " ) " in
        (match deftyp.it with
         | VariantT cases ->
             List.filter_map (fun (mixop_val, (_, case_typ, prems), _) ->
               if prems <> [] then begin
                 let cond_ts = List.filter_map (fun p -> match p.it with
                   | IfPr e -> Some (translate_exp BoolCtx e v_map)
                   | _ -> None) prems in
                 let conditions = List.map (fun t -> t.text) cond_ts in
                 let all_vars = List.concat_map (fun t -> t.vars) cond_ts in
                 let i_var = to_var_name "i" in
                 let collected = all_vars
                   |> List.sort_uniq String.compare
                   |> List.filter (fun v -> v <> i_var && not (List.mem v ["I"; "T"; "TS"; "WW"; "W*"])) in
                 let decl = declare_ops_const_list collected "WasmTerminal" in
                 let i_decl = declare_var i_var "WasmTerminal" in
                 Some (Printf.sprintf "%s%s  ceq is-type ( %s , %s ) = true \n   if %s ."
                   decl i_decl i_var full_type_name
                   (String.concat " and " (binder_conds @ conditions)))
               end else begin
                 let type_counters = ref [] in
                 let get_count tname =
                   let c = (try List.assoc tname !type_counters with Not_found -> 0) + 1 in
                   type_counters := (tname, c) :: (List.remove_assoc tname !type_counters); c in
                 let rec collect_params cur_vm t is_list = match t.it with
                   | VarT (tid, _) ->
                       let vb = to_var_name tid.it in
                       let count = get_count vb in
                       let indexed =
                         if is_list then vb ^ "-LIST"
                         else vb ^ string_of_int count in
                       let new_vm = (tid.it, indexed) :: cur_vm in
                       let ms = if is_list || is_plural_type tid.it then "WasmTerminals" else "WasmTerminal" in
                       ([(indexed, translate_typ t new_vm, ms)], new_vm)
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
                 let (params, _) = collect_params enriched_vm case_typ false in
                 let p_vars = List.map (fun (v, _, _) -> v) params in
                 let v_decl = String.concat "" (List.map (fun (v, _, ms) -> declare_var v ms) params) in
                 let binder_decl = String.concat "" (List.map (fun b -> match b.it with
                   | ExpB (tid, _) -> declare_var (to_var_name tid.it) "WasmTerminal"
                   | _ -> "") binders) in
                 let rhs = String.concat " and "
                   (binder_conds @ List.map (fun (v, s, _) ->
                     Printf.sprintf "is-type ( %s , %s )" v s) params) in
                 let sections = mixop_sections mixop_val in
                 let lhs = interleave_lhs sections p_vars in
                 let cons_name = match List.flatten mixop_val with a :: _ -> Xl.Atom.name a | [] -> "" in
                 let main =
                   if cons_name = "" then
                     Printf.sprintf "\n%s%s  eq is-type ( %s , %s ) = %s ."
                       binder_decl v_decl lhs full_type_name (if rhs = "" then "true" else rhs)
                   else
                     let op_sig = interleave_op sections (List.length p_vars) in
                     let arg_sorts = String.concat " " (List.map (fun (_, _, ms) -> ms) params) in
                     Printf.sprintf "  op %s : %s -> WasmTerminal [ctor] .\n%s%s  eq is-type ( %s , %s ) = %s ."
                       op_sig arg_sorts binder_decl v_decl lhs full_type_name
                       (if rhs = "" then "true" else rhs)
                 in
                 let opts = List.map (fun opt_idx ->
                   let lhs_eps = interleave_lhs sections
                     (List.mapi (fun i v -> if i = opt_idx then "eps" else v) p_vars) in
                   let r = String.concat " and "
                     (binder_conds @ List.filteri (fun i _ -> i <> opt_idx)
                       (List.map (fun (v, s, _) -> Printf.sprintf "is-type ( %s , %s )" v s) params)) in
                   Printf.sprintf "\n  eq is-type ( %s , %s ) = %s ."
                     lhs_eps full_type_name (if r = "" then "true" else r)
                 ) (find_opt_param_indices case_typ) in
                 Some (main ^ String.concat "" opts)
               end
             ) cases |> String.concat "\n"
         | AliasT typ ->
             let bd = String.concat "" (List.map (fun b -> match b.it with
               | ExpB (tid, _) -> declare_var (to_var_name tid.it) "WasmTerminal"
               | _ -> "") binders) in
             let rhs = match typ.it with IterT (inner, _) -> translate_typ inner v_map | _ -> translate_typ typ v_map in
             let var = match typ.it with IterT (_, (List | List1)) -> "TS" | _ -> "T" in
             let lhs = if SSet.mem name base_types then "T" else var in
             let cond =
               if rhs = "WasmType" then "true"
               else if binder_conds = [] then Printf.sprintf "is-type ( %s , %s )" lhs rhs
               else String.concat " and " binder_conds ^ " and " ^ Printf.sprintf "is-type ( %s , %s )" lhs rhs in
             Printf.sprintf "%s  eq is-type ( %s , %s ) = %s ." bd lhs full_type_name cond
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
               (fn, Printf.sprintf "F-%s-%d" fn i, sn, ms)
             ) fields in
             let decls = String.concat "" (List.map (fun (_, vn, _, ms) -> declare_var vn ms) info) in
             let rhs = String.concat " and "
               (binder_conds @ List.map (fun (_, vn, sn, _) ->
                 Printf.sprintf "is-type ( %s , %s )" vn sn) info) in
             Printf.sprintf "%s%s  eq is-type ( {%s} , %s ) = %s ." bd decls
               (String.concat " ; " (List.map (fun (f, vn, _, _) ->
                 Printf.sprintf "item('%s, %s)" f vn) info))
               full_type_name (if rhs = "" then "true" else rhs))
  ) insts in
  op_decl ^ String.concat "\n" res

(* --- Binding analysis (shared by DecD / RelD) ---------------------------- *)

let extract_vars_from_maude s =
  let re = Str.regexp "[A-Z][A-Z0-9-]*" in
  let excluded = SSet.of_list
    ["WasmTerminal"; "WasmTerminals"; "WasmType"; "WasmTypes"; "Bool"; "Nat"; "Int";
     "EMPTY"; "REC"; "FUNC"; "SUB"; "STRUCT"; "ARRAY"; "FIELD"] in
  let rec loop pos acc =
    match (try Some (Str.search_forward re s pos) with Not_found -> None) with
    | None -> acc
    | Some _ ->
        let tok = Str.matched_string s in
        loop (Str.match_end ()) (if SSet.mem tok excluded then acc else tok :: acc)
  in
  loop 0 [] |> List.sort_uniq String.compare

(** Build a per-equation variable prefix from a case/rule identifier. *)
let make_var_prefix prefix eq_idx raw_v =
  Printf.sprintf "%s%d-%s" prefix eq_idx
    (String.concat "" (String.split_on_char '-' (String.uppercase_ascii (sanitize raw_v))))

(** Create [var_map] from binders, filtering out Bool-typed bindings. *)
let binder_to_var_map prefix eq_idx binders =
  List.filter_map (fun b -> match b.it with
    | ExpB (v_id, t) ->
        if is_bool_typ t [] || String.lowercase_ascii v_id.it = "bool" then None
        else Some (v_id.it, make_var_prefix prefix eq_idx v_id.it)
    | _ -> None
  ) binders

(** Create type-check conditions from binders, only for non-trivial types. *)
let binder_to_type_conds binders vm =
  List.filter_map (fun b -> match b.it with
    | ExpB (v_id, t) ->
        let ts = translate_typ t [] in
        if ts = "WasmType" || is_bool_typ t [] || String.lowercase_ascii v_id.it = "bool"
        then None
        else (match List.assoc_opt v_id.it vm with
          | Some mv -> Some (mv, Printf.sprintf "is-type ( %s , %s )" mv (translate_typ t vm))
          | None -> None)
    | _ -> None
  ) binders

(** Partition variables into bound (in LHS) and free (not in LHS). *)
let partition_vars lhs_vars all_texts all_collected_vars =
  let extracted = extract_vars_from_maude (String.concat " " all_texts) in
  let all_used = List.sort_uniq String.compare (all_collected_vars @ extracted) in
  let lhs_set = List.sort_uniq String.compare lhs_vars in
  let bound = List.filter (fun v -> List.mem v lhs_set) all_used in
  let free = List.filter (fun v -> not (List.mem v lhs_set)) all_used in
  (bound, free, lhs_set)

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
  let arg_sorts = String.concat " " (List.map (fun p -> match p.it with
    | ExpP (_, t) -> if is_bool_typ t [] then "Bool" else "WasmTerminal"
    | _ -> "WasmTerminal") params) in
  let inferred_bool =
    List.exists (fun inst -> match inst.it with DefD (_, _, rhs, _) -> exp_is_boolish rhs) insts in
  let ret_sort = match result_typ.it with
    | IterT _ -> "WasmTerminals"
    | _ ->
        if is_bool_typ result_typ [] || inferred_bool || SSet.mem maude_fn ss.bool_calls
        then "Bool" else "WasmTerminal" in
  let rhs_ctx = if ret_sort = "Bool" then BoolCtx else TermCtx in

  let all_bound = ref [] and all_free = ref [] in
  let eq_lines = List.mapi (fun eq_idx inst ->
    let (binders, lhs_args, rhs_exp, prem_list) =
      match inst.it with DefD (b, la, re, pl) -> (b, la, re, pl) in
    let vm = binder_to_var_map prefix eq_idx binders in
    let bconds = binder_to_type_conds binders vm in

    let lhs_ts = List.map (fun a -> match a.it with
      | ExpA e -> translate_exp TermCtx e vm | _ -> texpr "eps") lhs_args in
    let lhs_strs = List.map (fun t -> t.text) lhs_ts in
    let lhs_vars = List.concat_map (fun t -> t.vars) lhs_ts in

    let rhs_t = translate_exp rhs_ctx rhs_exp vm in

    let prem_ts = List.filter_map (fun p ->
      let t = translate_prem p vm in
      if t.text = "" || t.text = "owise" then None else Some t
    ) prem_list in
    let prem_strs = List.map (fun t -> t.text) prem_ts in
    let prem_vars = List.concat_map (fun t -> t.vars) prem_ts in

    let has_owise = List.exists (fun p -> match p.it with ElsePr -> true | _ -> false) prem_list in
    let all_collected = lhs_vars @ rhs_t.vars @ prem_vars in
    let all_texts = lhs_strs @ [rhs_t.text] @ prem_strs in
    let (bound, free, lhs_set) = partition_vars lhs_vars all_texts all_collected in

    let filtered_bconds = bconds |> List.filter (fun (mv, _) -> List.mem mv lhs_set) |> List.map snd in
    all_bound := List.sort_uniq String.compare (!all_bound @ bound);
    all_free := List.sort_uniq String.compare (!all_free @ free);

    let all_conds = filtered_bconds @ prem_strs in
    let cond_str =
      if all_conds = [] then ""
      else " \n      if " ^ String.concat " and " all_conds in
    Printf.sprintf "  %s %s = %s%s%s ."
      (if all_conds = [] then "eq" else "ceq")
      (format_call maude_fn lhs_strs) rhs_t.text cond_str
      (if has_owise then " [owise]" else "")
  ) insts in

  let truly_free = List.filter (fun v -> not (List.mem v !all_bound)) !all_free in
  let op_decl = Printf.sprintf "\n\n  op %s : %s -> %s .\n" maude_fn arg_sorts ret_sort in
  let bound_decl = declare_vars_same_sort !all_bound "WasmTerminal" in
  let free_decl = declare_ops_const_list truly_free "WasmTerminal" in
  "\n" ^ op_decl ^ bound_decl ^ free_decl ^ String.concat "\n" eq_lines ^ "\n"

(* --- RelD handler -------------------------------------------------------- *)

let translate_reld _id rel_name rules =
  let arity = match rules with
    | r :: _ -> (match r.it with RuleD (_, _, _, c, _) ->
        (match c.it with TupE el -> List.length el | _ -> 1))
    | [] -> 0 in
  let op_decl = Printf.sprintf "\n  op %s : %s -> Bool .\n" rel_name
    (String.concat " " (List.init arity (fun _ -> "WasmTerminal"))) in
  let rel_prefix = String.uppercase_ascii (sanitize rel_name) in

  let all_bound = ref [] and all_free = ref [] in
  let rule_lines = List.mapi (fun rule_idx r -> match r.it with
    | RuleD (case_id, binders, _, conclusion, prem_list) ->
        let raw_prefix = String.uppercase_ascii (sanitize case_id.it) in
        let case_part = if raw_prefix = "" then Printf.sprintf "R%d" rule_idx else raw_prefix in
        let prefix = Printf.sprintf "%s-%s" rel_prefix case_part in
        let vm = binder_to_var_map prefix rule_idx binders in
        let bconds = binder_to_type_conds binders vm in

        let lhs_t = match conclusion.it with
          | TupE el -> tconcat " , " (List.map (fun x -> translate_exp TermCtx x vm) el)
          | _ -> translate_exp TermCtx conclusion vm in

        let prem_ts = List.filter_map (fun p ->
          let t = translate_prem p vm in
          if t.text = "" || t.text = "owise" then None else Some t
        ) prem_list in
        let prem_strs = List.map (fun t -> t.text) prem_ts in
        let prem_vars = List.concat_map (fun t -> t.vars) prem_ts in

        let all_collected = lhs_t.vars @ prem_vars in
        let all_texts = [lhs_t.text] @ prem_strs in
        let (bound, free, lhs_set) = partition_vars lhs_t.vars all_texts all_collected in

        let filtered_bconds = bconds |> List.filter (fun (mv, _) -> List.mem mv lhs_set) |> List.map snd in
        all_bound := List.sort_uniq String.compare (!all_bound @ bound);
        all_free := List.sort_uniq String.compare (!all_free @ free);

        let all_conds = filtered_bconds @ prem_strs in
        let cond_str =
          if all_conds = [] then ""
          else " \n      if " ^ String.concat " and " all_conds in
        Printf.sprintf "  %s %s ( %s ) = true%s ."
          (if all_conds = [] then "eq" else "ceq")
          rel_name lhs_t.text cond_str
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
  | RelD (id, _, _, rules) -> translate_reld id (sanitize id.it) rules
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
  "  --- Bool wrapper (avoid subsort Bool < WasmTerminal conflicts)\n" ^
  "  op w-bool : Bool -> WasmTerminal [ctor] .\n\n" ^
  "  --- Basic Wasm Types\n" ^
  "  ops w-N w-M w-K w-n w-m w-X w-C w-I w-S w-T w-V w-b w-z w-L w-E : -> WasmType [ctor] .\n\n" ^
  "  --- Special Operators\n" ^
  "  op _shape-x_ : WasmTerminal WasmTerminal -> WasmTerminal [ctor] .\n" ^
  "  op slice : WasmTerminals WasmTerminal WasmTerminal -> WasmTerminals .\n" ^
  "  op _<-_ : WasmTerminal WasmTerminals -> Bool .\n\n" ^
  "  --- Generic record/terminal combinators (parser support)\n" ^
  "  op merge : WasmTerminal WasmTerminal -> WasmTerminal [ctor] .\n" ^
  "  op _=++_ : WasmTerminal WasmTerminal -> WasmTerminal [ctor] .\n" ^
  "  op any : -> WasmTerminal [ctor] .\n\n" ^
  "  --- Common variables (declared once)\n" ^
  "  var I : Int .\n" ^
  "  vars W-I EXP : Int .\n" ^
  "  vars W-N W-M : Nat .\n" ^
  "  vars T W WW W-X : WasmTerminal .\n" ^
  "  vars TS W* : WasmTerminals .\n\n"

let footer = "\nendm\n"

let starts_with s pfx =
  String.length s >= String.length pfx && String.sub s 0 (String.length pfx) = pfx

let is_decl_line l =
  let s = String.trim l in
  starts_with s "op " || starts_with s "ops " ||
  starts_with s "var " || starts_with s "vars " ||
  starts_with s "subsort "

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
  let decls = List.filter is_decl_line lines |> List.sort_uniq String.compare in
  let eqs = List.filter (fun l -> not (is_decl_line l)) lines in
  header ^ "\n  --- Declarations\n" ^ String.concat "\n" decls ^
  "\n\n  --- Equations\n" ^ String.concat "\n" eqs ^ footer
