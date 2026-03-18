(* Spec2Maude: SpecTec AST → Maude Algebraic Specification Translator *)

open Util.Source
open Il.Ast

(* ------------------------------------------------------------------------- *)
(* Deduplicate Maude variable declarations within a module                    *)
(* ------------------------------------------------------------------------- *)

let declared_vars : (string, string) Hashtbl.t = Hashtbl.create 2048

let declare_var (name : string) (sort : string) : string =
  match Hashtbl.find_opt declared_vars name with
  | None ->
      Hashtbl.replace declared_vars name sort;
      Printf.sprintf "  var %s : %s .\n" name sort
  | Some _ -> ""

let declare_op_const (name : string) (sort : string) : string =
  match Hashtbl.find_opt declared_vars name with
  | None ->
      Hashtbl.replace declared_vars name sort;
      Printf.sprintf "  op %s : -> %s .\n" name sort
  | Some _ -> ""

let declare_vars_same_sort (names : string list) (sort : string) : string =
  let fresh =
    names
    |> List.sort_uniq String.compare
    |> List.filter (fun n -> not (Hashtbl.mem declared_vars n))
  in
  List.iter (fun n -> Hashtbl.replace declared_vars n sort) fresh;
  if fresh = [] then "" else "  vars " ^ String.concat " " fresh ^ " : " ^ sort ^ " .\n"

let declare_ops_const_list (names : string list) (sort : string) : string =
  let fresh =
    names
    |> List.sort_uniq String.compare
    |> List.filter (fun n -> not (Hashtbl.mem declared_vars n))
  in
  List.iter (fun n -> Hashtbl.replace declared_vars n sort) fresh;
  String.concat "" (List.map (fun n -> Printf.sprintf "  op %s : -> %s .\n" n sort) fresh)

let init_declared_vars () =
  Hashtbl.reset declared_vars;
  Hashtbl.replace declared_vars "I" "Int";
  List.iter (fun v -> Hashtbl.replace declared_vars v "Int") ["W-I"; "EXP"];
  List.iter (fun v -> Hashtbl.replace declared_vars v "Nat") ["W-N"; "W-M"];
  List.iter (fun v -> Hashtbl.replace declared_vars v "WasmTerminal") ["T"; "W"; "WW"; "W-X"];
  List.iter (fun v -> Hashtbl.replace declared_vars v "WasmTerminals") ["TS"; "W*"]

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

let sanitize name =
  let name = if name = "_" then "any" else name in
  let keywords = ["if"; "var"; "op"; "eq"; "sort"; "mod"; "quo"; "rem"; "or"; "and"; "not"] in
  let is_alpha_char c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') in
  let needs_prefix =
    String.length name = 1 ||
    (String.length name > 0 && name.[0] <> '$' && not (is_alpha_char name.[0])) ||
    List.mem (String.lowercase_ascii name) keywords
  in
  let base_name = if needs_prefix then "w-" ^ name else name in
  let mapped =
    String.map
      (fun c ->
        match c with
        | '.' | '_' | '\'' | '*' | '+' | '?' -> '-'
        | _ -> c)
      base_name
  in
  let buf = Buffer.create (String.length mapped) in
  let i = ref 0 in
  while !i < String.length mapped do
    let c = mapped.[!i] in
    if c = '-' && !i + 1 < String.length mapped then
      let c2 = mapped.[!i + 1] in
      if c2 >= '0' && c2 <= '9' then (
        Buffer.add_char buf 'N';
        Buffer.add_char buf c2;
        i := !i + 2
      ) else (
        Buffer.add_char buf c;
        i := !i + 1
      )
    else (
      Buffer.add_char buf c;
      i := !i + 1
    )
  done;
  let res = Buffer.contents buf in
  if String.length res > 0 && res.[String.length res - 1] = '-' then
    String.sub res 0 (String.length res - 1)
  else res

let to_var_name name = String.uppercase_ascii (sanitize name)

let plural_types : (string, bool) Hashtbl.t = Hashtbl.create 32
let build_type_env (defs : def list) =
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

let is_plural_type (type_name : string) : bool = Hashtbl.mem plural_types type_name

let mixop_sections (mixop_val : Xl.Mixop.mixop) : string list =
  List.map (fun atoms ->
    atoms |> List.map Xl.Atom.name |> String.concat "" |> sanitize
  ) mixop_val

let interleave_lhs (sections : string list) (vars : string list) : string =
  let rec go secs vs = match secs, vs with
    | [], vs_rest -> vs_rest
    | s :: ss, v :: vs' -> (if s <> "" then [s; v] else [v]) @ go ss vs'
    | [s], [] -> if s <> "" then [s] else []
    | _ :: ss, [] -> go ss []
  in
  String.concat " " (go sections vars)

let interleave_op (sections : string list) (n_vars : int) : string =
  let rec go secs remaining = match secs, remaining with
    | [], n -> List.init n (fun _ -> "_")
    | s :: ss, n when n > 0 -> (if s <> "" then [s; "_"] else ["_"]) @ go ss (n - 1)
    | [s], 0 -> if s <> "" then [s] else []
    | _ :: ss, 0 -> go ss 0
    | _, _ -> []
  in
  String.concat " " (go sections n_vars)

let find_opt_param_indices (case_typ : typ) : int list =
  let idx = ref 0 in
  let result = ref [] in
  let rec scan t is_opt = match t.it with
    | VarT _ -> if is_opt then result := !idx :: !result; idx := !idx + 1
    | IterT (inner, Opt) -> scan inner true
    | IterT (inner, _) -> scan inner is_opt
    | TupT fields -> List.iter (fun (_, ft) -> scan ft is_opt) fields
    | _ -> ()
  in
  scan case_typ false; List.rev !result

let undeclared_vars = ref []

let format_call (fn : string) (arg_strs : string list) : string =
  match arg_strs with
  | [] -> fn
  | _ -> Printf.sprintf "%s ( %s )" fn (String.concat ", " arg_strs)

type exp_ctx = BoolCtx | TermCtx

let is_upper_start (s : string) : bool =
  String.length s > 0 && s.[0] >= 'A' && s.[0] <= 'Z'

let wrap_bool_if_term (ctx : exp_ctx) (bexp : string) : string =
  match ctx with
  | BoolCtx -> bexp
  | TermCtx -> Printf.sprintf "w-bool ( %s )" bexp

(* ------------------------------------------------------------------------- *)
(* Option A: token pre-scan                                                   *)
(* ------------------------------------------------------------------------- *)

let token_set : (string, unit) Hashtbl.t = Hashtbl.create 1024
let call_sigs : ((string * int), unit) Hashtbl.t = Hashtbl.create 2048
let declared_decs : ((string * int), unit) Hashtbl.t = Hashtbl.create 2048
let bool_call_set : (string, unit) Hashtbl.t = Hashtbl.create 64
let ctor_names : (string, unit) Hashtbl.t = Hashtbl.create 512

let add_token_raw (raw : string) : unit =
  let low = String.lowercase_ascii raw in
  if low = "true" || low = "false" then ()
  else
    let tok = sanitize raw in
    if tok <> "" then Hashtbl.replace token_set tok ()

let is_token_like_id (raw : string) : bool =
  is_upper_start raw
  && String.length raw > 1
  && not (raw = "I" || raw = "T" || raw = "W")
  && not (String.length raw >= 2 && raw.[0] = 'W' && raw.[1] = '-')

let call_name (id : string) : string =
  let fname = sanitize id in
  if fname = "w-$" then fname
  else if String.length fname > 0 && fname.[0] = '$' then fname else "$" ^ fname

let rec prescan_exp (e : exp) : unit =
  match e.it with
  | VarE id ->
      if id.it = "_" then Hashtbl.replace token_set "any" ()
      else if is_token_like_id id.it then add_token_raw id.it
  | CaseE (_mixop, inner) -> prescan_exp inner
  | TupE es | ListE es -> List.iter prescan_exp es
  | UnE (_, _, e1) -> prescan_exp e1
  | BinE (_, _, e1, e2) | CmpE (_, _, e1, e2) | CatE (e1, e2) | MemE (e1, e2)
  | IdxE (e1, e2) | CompE (e1, e2) ->
      prescan_exp e1; prescan_exp e2
  | SliceE (e1, e2, e3) ->
      prescan_exp e1; prescan_exp e2; prescan_exp e3
  | UpdE (e1, _, e2) | ExtE (e1, _, e2) ->
      prescan_exp e1; prescan_exp e2
  | IfE (c, e1, e2) ->
      prescan_exp c; prescan_exp e1; prescan_exp e2
  | CvtE (e1, _, _) | SubE (e1, _, _) | ProjE (e1, _) | UncaseE (e1, _)
  | LenE e1 | OptE (Some e1) | TheE e1 | LiftE e1 | IterE (e1, _) ->
      prescan_exp e1
  | OptE None | BoolE _ | NumE _ | TextE _ -> ()
  | StrE fields -> List.iter (fun (_a, e1) -> prescan_exp e1) fields
  | DotE (e1, _a) -> prescan_exp e1
  | CallE (id, args) ->
      let cn = call_name id.it in
      let arity = List.length args in
      if cn <> "w-$" then Hashtbl.replace call_sigs (cn, arity) ();
      List.iter (fun a -> match a.it with ExpA e1 -> prescan_exp e1 | _ -> ()) args

let rec prescan_bool_exp (e : exp) : unit =
  match e.it with
  | CallE (id, args) ->
      let cn = call_name id.it in
      Hashtbl.replace bool_call_set cn ();
      List.iter (fun a -> match a.it with ExpA e1 -> prescan_exp e1 | _ -> ()) args
  | BinE ((`AndOp | `OrOp | `ImplOp), _, e1, e2) ->
      prescan_bool_exp e1; prescan_bool_exp e2
  | UnE (`NotOp, _, e1) -> prescan_bool_exp e1
  | _ -> prescan_exp e

let rec prescan_prem (p : prem) : unit =
  match p.it with
  | IfPr e -> prescan_bool_exp e
  | RulePr (_id, _, e) -> prescan_exp e
  | LetPr (e1, e2, _) -> prescan_exp e1; prescan_exp e2
  | ElsePr -> ()
  | IterPr (inner, _) | NegPr inner -> prescan_prem inner

let rec prescan_def (d : def) : unit =
  match d.it with
  | RecD ds -> List.iter prescan_def ds
  | TypD (_id, _params, insts) ->
      List.iter
        (fun inst ->
          match inst.it with
          | InstD (_binders, _args, deftyp) -> (
              match deftyp.it with
              | VariantT cases ->
                  List.iter
                    (fun (mixop_val, (_, _case_typ, prems), _) ->
                      (match List.flatten mixop_val with
                       | a :: _ ->
                           let cname = sanitize (Xl.Atom.name a) in
                           if cname <> "" then Hashtbl.replace ctor_names cname ()
                       | [] -> ());
                      List.iter prescan_prem prems)
                    cases
              | AliasT _ | StructT _ -> ()))
        insts
  | DecD (id, _params, _result_typ, insts) ->
      Hashtbl.replace declared_decs (call_name id.it, -1) ();
      List.iter
        (fun inst ->
          match inst.it with
          | DefD (_binders, lhs_args, rhs, prems) ->
              List.iter (fun a -> match a.it with ExpA e -> prescan_exp e | _ -> ()) lhs_args;
              prescan_exp rhs;
              List.iter prescan_prem prems)
        insts
  | RelD (_id, _params, _result_typ, rules) ->
      List.iter
        (fun r ->
          match r.it with
          | RuleD (_case_id, _binders, _args, concl, prems) ->
              prescan_exp concl;
              List.iter prescan_prem prems)
        rules
  | GramD _ | HintD _ -> ()

let build_token_ops_lines () : string =
  let toks = Hashtbl.to_seq_keys token_set |> List.of_seq
    |> List.filter (fun t -> not (Hashtbl.mem ctor_names t))
    |> List.sort_uniq String.compare in
  if toks = [] then ""
  else
    let rec take k acc ys =
      if k = 0 || ys = [] then (List.rev acc, ys)
      else take (k - 1) (List.hd ys :: acc) (List.tl ys)
    in
    let rec loop ys acc =
      if ys = [] then List.rev acc
      else
        let (hd, tl) = take 20 [] ys in
        loop tl (("  ops " ^ String.concat " " hd ^ " : -> WasmTerminal [ctor] .\n") :: acc)
    in
    String.concat "" (loop toks []) ^ "\n"

let build_missing_call_ops_lines () : string =
  let sigs =
    Hashtbl.to_seq_keys call_sigs |> List.of_seq |> List.sort_uniq compare
  in
  let lines =
    sigs
    |> List.filter (fun (name, arity) ->
      not (Hashtbl.mem declared_decs (name, -1)) && arity >= 0)
    |> List.map (fun (name, arity) ->
      let args = String.concat " " (List.init arity (fun _ -> "WasmTerminal")) in
      let ret = if Hashtbl.mem bool_call_set name then "Bool" else "WasmTerminal" in
      Printf.sprintf "  op %s : %s -> %s .\n" name args ret)
  in
  if lines = [] then "" else "\n  --- Auto-declared helper calls\n" ^ String.concat "" lines ^ "\n"

let extract_vars_from_maude (s : string) : string list =
  let re = Str.regexp "[A-Z][A-Z0-9-]*" in
  let excluded = ["WasmTerminal"; "WasmTerminals"; "WasmType"; "WasmTypes"; "Bool"; "Nat"; "Int";
                   "EMPTY"; "REC"; "FUNC"; "SUB"; "STRUCT"; "ARRAY"; "FIELD"] in
  let rec loop pos acc =
    try
      let _ = Str.search_forward re s pos in
      let tok = Str.matched_string s in
      let next = Str.match_end () in
      let acc' = if List.mem tok excluded then acc else tok :: acc in
      loop next acc'
    with Not_found -> acc
  in
  loop 0 [] |> List.sort_uniq String.compare

let rec exp_is_boolish (e : exp) : bool =
  match e.it with
  | BoolE _ -> true
  | CmpE _ -> true
  | MemE _ -> true
  | UnE (`NotOp, _, _) -> true
  | BinE ((`AndOp | `OrOp | `ImplOp | `EquivOp), _, _, _) -> true
  | IfE (_, e1, e2) -> exp_is_boolish e1 && exp_is_boolish e2
  | _ -> false

let rec translate_exp (ctx : exp_ctx) (e : exp) (v_map : (string * string) list) : string =
  match e.it with
  | VarE id ->
      (try
         let (_, mapped_v) = List.find (fun (k, _) -> String.lowercase_ascii k = String.lowercase_ascii id.it) v_map in
         undeclared_vars := mapped_v :: !undeclared_vars;
         mapped_v
       with Not_found ->
         let low = String.lowercase_ascii id.it in
         if low = "true" then wrap_bool_if_term ctx "true"
         else if low = "false" then wrap_bool_if_term ctx "false"
         else if is_token_like_id id.it then sanitize id.it
         else
           (* Try resolving suffixed names like "numtype_2" via base name "numtype" in v_map *)
           let resolved = ref None in
           let name = id.it in
           let len = String.length name in
           let rec find_split i =
             if i <= 0 then ()
             else if name.[i-1] >= '0' && name.[i-1] <= '9' then find_split (i-1)
             else if name.[i-1] = '_' && i < len then begin
               let base = String.sub name 0 (i-1) in
               let suffix = String.sub name i (len - i) in
               (try
                  let idx = int_of_string suffix in
                  let matches = List.filter (fun (k, _) -> String.lowercase_ascii k = String.lowercase_ascii base) v_map in
                  let matches_rev = List.rev matches in
                  if idx >= 1 && idx <= List.length matches_rev then
                    resolved := Some (snd (List.nth matches_rev (idx - 1)))
                with _ -> ())
             end
           in find_split len;
           (match !resolved with
            | Some v -> undeclared_vars := v :: !undeclared_vars; v
            | None ->
              let v = String.uppercase_ascii (sanitize id.it) in
              undeclared_vars := v :: !undeclared_vars;
              v))
  | CaseE (mixop, inner_exp) ->
      let op_name = try List.flatten mixop |> List.map Xl.Atom.name |> String.concat "" with _ -> "" in
      if op_name = "$" || op_name = "%" || op_name = "" then translate_exp ctx inner_exp v_map
      else if op_name = "shape-x" then
        let args = match inner_exp.it with TupE es -> List.map (fun e -> translate_exp TermCtx e v_map) es | _ -> [translate_exp TermCtx inner_exp v_map] in
        match args with [a; b] -> Printf.sprintf "( %s shape-x %s )" a b | _ -> "eps"
      else interleave_lhs (mixop_sections mixop) (match inner_exp.it with TupE es -> List.map (fun e -> translate_exp TermCtx e v_map) es | _ -> [translate_exp TermCtx inner_exp v_map])
  | NumE n -> (match n with `Nat z | `Int z -> Z.to_string z | `Rat q -> Z.to_string (Q.num q) ^ "/" ^ Z.to_string (Q.den q) | `Real r -> Printf.sprintf "%.17g" r)
  | CvtE (e1, _, _) | SubE (e1, _, _) | ProjE (e1, _) | UncaseE (e1, _) -> translate_exp ctx e1 v_map
  | UnE (op, _, e1) ->
      (match op with
       | `MinusOp -> Printf.sprintf " - ( %s ) " (translate_exp TermCtx e1 v_map)
       | `PlusOp -> translate_exp TermCtx e1 v_map
       | `NotOp -> wrap_bool_if_term ctx (Printf.sprintf "not ( %s )" (translate_exp BoolCtx e1 v_map)))
  | BinE (op, _, e1, e2) ->
      let (op_str, is_bool) =
        match (op : binop) with
        | `AddOp -> ("+", false)
        | `SubOp -> ("-", false)
        | `MulOp -> ("*", false)
        | `DivOp -> (" quo ", false)
        | `ModOp -> (" rem ", false)
        | `PowOp -> (" ^ ", false)
        | `AndOp -> (" and ", true)
        | `OrOp -> (" or ", true)
        | `ImplOp -> (" implies ", true)
        | `EquivOp -> (" == ", true)
      in
      if is_bool then
        wrap_bool_if_term ctx
          (Printf.sprintf "( %s %s %s )" (translate_exp BoolCtx e1 v_map) op_str (translate_exp BoolCtx e2 v_map))
      else
        Printf.sprintf "( %s %s %s )" (translate_exp TermCtx e1 v_map) op_str (translate_exp TermCtx e2 v_map)
  | CmpE (op, _, e1, e2) ->
      let op_str = (match (op : cmpop) with `LtOp -> "<" | `GtOp -> ">" | `LeOp -> "<=" | `GeOp -> ">=" | `EqOp -> "==" | `NeOp -> "=/=") in
      wrap_bool_if_term ctx (Printf.sprintf "( %s %s %s )" (translate_exp TermCtx e1 v_map) op_str (translate_exp TermCtx e2 v_map))
  | CallE (id, args) ->
      let arg_strs = List.map (fun a -> translate_arg a v_map) args in
      let fname = sanitize id.it in
      if fname = "w-$" then String.concat ", " arg_strs
      else
        let fn = if String.length fname > 0 && fname.[0] = '$' then fname else "$" ^ fname in
        format_call fn arg_strs
  | TupE [] | ListE [] -> "eps"
  | TupE [e1] -> translate_exp ctx e1 v_map
  | TupE el | ListE el -> String.concat " " (List.map (fun x -> translate_exp TermCtx x v_map) el)
  | BoolE b -> wrap_bool_if_term ctx (if b then "true" else "false")
  | TextE s -> "\"" ^ s ^ "\""
  | StrE fields -> "{" ^ String.concat " ; " (List.map (fun (atom, e1) -> Printf.sprintf "item('%s, %s)" (to_var_name (Xl.Atom.name atom)) (translate_exp TermCtx e1 v_map)) fields) ^ "}"
  | DotE (e1, atom) -> Printf.sprintf "value('%s, %s)" (to_var_name (Xl.Atom.name atom)) (translate_exp TermCtx e1 v_map)
  | CompE (e1, e2) -> Printf.sprintf "merge ( %s , %s )" (translate_exp TermCtx e1 v_map) (translate_exp TermCtx e2 v_map)
  | MemE (e1, e2) -> wrap_bool_if_term ctx (Printf.sprintf "( %s <- %s )" (translate_exp TermCtx e1 v_map) (translate_exp TermCtx e2 v_map))
  | LenE e1 -> Printf.sprintf "len ( %s )" (translate_exp TermCtx e1 v_map)
  | CatE (e1, e2) -> Printf.sprintf "%s %s" (translate_exp TermCtx e1 v_map) (translate_exp TermCtx e2 v_map)
  | IdxE (e1, e2) -> Printf.sprintf "index ( %s, %s )" (translate_exp TermCtx e1 v_map) (translate_exp TermCtx e2 v_map)
  | SliceE (e1, e2, e3) -> Printf.sprintf "slice ( %s, %s, %s )" (translate_exp TermCtx e1 v_map) (translate_exp TermCtx e2 v_map) (translate_exp TermCtx e3 v_map)
  | UpdE (e1, path, e2) ->
      let pstr = translate_path path v_map in
      if String.length pstr > 0 && pstr.[0] = '\''
      then Printf.sprintf "( %s [. %s <- %s ] )" (translate_exp TermCtx e1 v_map) pstr (translate_exp TermCtx e2 v_map)
      else Printf.sprintf "( %s [ %s <- %s ] )" (translate_exp TermCtx e1 v_map) pstr (translate_exp TermCtx e2 v_map)
  | ExtE (e1, path, e2) ->
      let pstr = translate_path path v_map in
      if String.length pstr > 0 && pstr.[0] = '\''
      then Printf.sprintf "( %s [. %s =++ %s ] )" (translate_exp TermCtx e1 v_map) pstr (translate_exp TermCtx e2 v_map)
      else Printf.sprintf "( %s [ %s =++ %s ] )" (translate_exp TermCtx e1 v_map) pstr (translate_exp TermCtx e2 v_map)
  | OptE (Some e1) | TheE e1 | LiftE e1 -> translate_exp ctx e1 v_map
  | OptE None -> "eps"
  | IterE (e1, (iter_type, _)) ->
      let suffix = match iter_type with List -> "*" | List1 -> "+" | Opt -> "?" | ListN _ -> "" in
      (match e1.it with
       | VarE id ->
           let full_id = id.it ^ suffix in
           (try List.assoc full_id v_map
            with Not_found ->
              let v = String.uppercase_ascii (sanitize full_id) in
              undeclared_vars := v :: !undeclared_vars;
              v)
       | _ -> translate_exp ctx e1 v_map)
  | IfE (c, e1, e2) -> Printf.sprintf "if %s then %s else %s fi" (translate_exp BoolCtx c v_map) (translate_exp ctx e1 v_map) (translate_exp ctx e2 v_map)

and translate_path (p : path) (v_map : (string * string) list) : string =
  match p.it with
  | RootP -> ""
  | IdxP (_p1, e) ->
      translate_exp TermCtx e v_map
  | SliceP (_p1, e1, e2) ->
      Printf.sprintf "%s %s" (translate_exp TermCtx e1 v_map) (translate_exp TermCtx e2 v_map)
  | DotP (p1, atom) ->
      let qid = "'" ^ String.uppercase_ascii (sanitize (Xl.Atom.name atom)) in
      let base = translate_path p1 v_map in
      if base = "" then qid else qid

and translate_arg (a : arg) (v_map : (string * string) list) : string =
  match a.it with
  | ExpA e -> translate_exp TermCtx e v_map
  | TypA t -> translate_typ t v_map
  | _ -> "eps"

and translate_prem (p : prem) (v_map : (string * string) list) : string =
  match p.it with
  | IfPr e -> translate_exp BoolCtx e v_map
  | RulePr (id, _, e) ->
      let arg_strs =
        match e.it with
        | TupE el -> List.map (fun x -> translate_exp TermCtx x v_map) el
        | _ -> [translate_exp TermCtx e v_map]
      in
      format_call (sanitize id.it) arg_strs
  | LetPr (e1, e2, _) -> Printf.sprintf "( %s == %s )" (translate_exp TermCtx e1 v_map) (translate_exp TermCtx e2 v_map)
  | ElsePr -> "owise"
  | IterPr (inner_p, _) | NegPr inner_p -> translate_prem inner_p v_map

and translate_typ (t : typ) (v_map : (string * string) list) : string =
  match t.it with
  | VarT (id, args) -> let name = try let mapped = List.assoc id.it v_map in if mapped = String.uppercase_ascii mapped then sanitize id.it else mapped with Not_found -> sanitize id.it in if args = [] then name else Printf.sprintf "%s ( %s )" name (String.concat " , " (List.map (fun a -> translate_arg a v_map) args))
  | IterT (inner, _) -> translate_typ inner v_map | _ -> "WasmType"

let is_bool_typ (t : typ) (v_map : (string * string) list) : bool =
  match t.it with
  | VarT (tid, _) ->
      let s = String.lowercase_ascii (translate_typ t v_map) in
      s = "bool" || s = "w-b" || String.lowercase_ascii tid.it = "bool" || String.lowercase_ascii tid.it = "b"
  | _ ->
      let s = String.lowercase_ascii (translate_typ t v_map) in
      s = "bool" || s = "w-b"

(* ------------------------------------------------------------------------- *)
(* Definition translation                                                     *)
(* ------------------------------------------------------------------------- *)

let rec translate_definition (d : def) : string =
  let base_types = ["w-N"; "w-M"; "w-K"; "w-n"; "w-m"; "w-X"; "w-C"; "w-I"; "w-S"; "w-T"; "w-V"; "w-b"; "w-z"; "w-L"; "w-E"] in
  match d.it with
  | RecD defs -> String.concat "\n" (List.map translate_definition defs)
  | TypD (id, params, insts) ->
      let name = sanitize id.it in
      let sig_types = String.concat " " (List.map (fun _ -> "WasmTerminal") params) in
      let op_decl = if List.mem name base_types then "" else Printf.sprintf "  op %s : %s -> WasmType [ctor] .\n" name sig_types in
      let res = List.map (fun inst -> match inst.it with
        | InstD (binders, args, deftyp) ->
            let v_map = List.filter_map (fun b -> match b.it with ExpB (tid, _) -> Some (tid.it, to_var_name tid.it) | _ -> None) binders in
            let binder_conds = List.filter_map (fun b -> match b.it with ExpB (tid, _) -> Some (Printf.sprintf "is-type ( %s , %s )" (to_var_name tid.it) (sanitize tid.it)) | _ -> None) binders in
            let args_str = String.concat " , " (List.map (fun a -> translate_arg a v_map) args) in
            let full_type_name = if args_str = "" then name else name ^ " ( " ^ args_str ^ " ) " in
            (match deftyp.it with
             | VariantT cases ->
                List.map (fun (mixop_val, (_, case_typ, prems), _) ->
                  if prems <> [] then begin
                    undeclared_vars := []; let conditions = List.filter_map (fun p -> match p.it with IfPr e -> Some (translate_exp BoolCtx e v_map) | _ -> None) prems in
                    let i_var = to_var_name "i" in let collected = List.filter (fun v -> v <> i_var && not (List.mem v ["I"; "T"; "TS"; "WW"; "W*"])) (List.sort_uniq String.compare !undeclared_vars) in
                    let decl = declare_ops_const_list collected "WasmTerminal" in
                    let i_decl = declare_var i_var "WasmTerminal" in
                    Printf.sprintf "%s%s  ceq is-type ( %s , %s ) = true \n   if %s ." decl i_decl i_var full_type_name (String.concat " and " (binder_conds @ conditions))
                  end else begin
                    let type_counters = ref [] in let get_count tname = let c = (try List.assoc tname !type_counters with Not_found -> 0) + 1 in type_counters := (tname, c) :: (List.remove_assoc tname !type_counters); c in
                    let rec collect_params current_v_map t is_list = match t.it with
                      | VarT (tid, _) ->
                          let v_base = to_var_name tid.it in
                          let count = get_count v_base in
                          let indexed_name = if is_list then v_base ^ "-" ^ (if iter_type_name tid.it = "Opt" then "OPT" else "LIST") else v_base ^ string_of_int count in
                          let new_vm = (tid.it, indexed_name) :: current_v_map in
                          ([(indexed_name, translate_typ t new_vm, if is_list || is_plural_type tid.it then "WasmTerminals" else "WasmTerminal")], new_vm)
                      | IterT (inner, iter) -> collect_params current_v_map inner (iter = List || iter = List1)
                      | TupT fields -> List.fold_left (fun (ps_acc, vm_acc) (_, ft) -> let (ps, new_vm) = collect_params vm_acc ft is_list in (ps_acc @ ps, new_vm)) ([], current_v_map) fields | _ -> ([], current_v_map)
                    and iter_type_name tid_it = if is_plural_type tid_it then "LIST" else "SINGLE" in
                    (* Map suffixed binder names (e.g. "numtype_2") to indexed param names (e.g. "NUMTYPE2") *)
                    let binder_suffix_map =
                      List.filter_map (fun b -> match b.it with
                        | ExpB (tid, _) ->
                            let name = tid.it in
                            let len = String.length name in
                            let rec find_split i =
                              if i <= 0 then None
                              else if name.[i-1] >= '0' && name.[i-1] <= '9' then find_split (i-1)
                              else if name.[i-1] = '_' && i < len then
                                let base = String.sub name 0 (i-1) in
                                let suffix = String.sub name i (len - i) in
                                Some (name, to_var_name base ^ suffix)
                              else None
                            in find_split len
                        | _ -> None) binders
                    in
                    let enriched_vm = binder_suffix_map @ v_map in
                    let (params, _collect_vm) = collect_params enriched_vm case_typ false in
                    let p_vars = List.map (fun (v, _, _) -> v) params in
                    let v_decl = String.concat "" (List.map (fun (v, _, ms) -> declare_var v ms) params) in
                    let binder_decl =
                      String.concat ""
                        (List.map
                           (fun b ->
                             match b.it with
                             | ExpB (tid, _) -> declare_var (to_var_name tid.it) "WasmTerminal"
                             | _ -> "")
                           binders)
                    in
                    let rhs = String.concat " and " (binder_conds @ List.map (fun (v, s, _) -> Printf.sprintf "is-type ( %s , %s )" v s) params) in
                    let sections = mixop_sections mixop_val in let lhs_usage = interleave_lhs sections p_vars in
                    let cons_name = (match List.flatten mixop_val with a :: _ -> Xl.Atom.name a | [] -> "") in
                    let main = if cons_name = "" then Printf.sprintf "\n%s%s  eq is-type ( %s , %s ) = %s ." binder_decl v_decl lhs_usage full_type_name (if rhs="" then "true" else rhs)
                               else Printf.sprintf "  op %s : %s -> WasmTerminal [ctor] .\n%s%s  eq is-type ( %s , %s ) = %s ." (interleave_op sections (List.length p_vars)) (String.concat " " (List.map (fun (_, _, ms) -> ms) params)) binder_decl v_decl lhs_usage full_type_name (if rhs="" then "true" else rhs) in
                    let opts = List.map (fun opt_idx -> let lhs_eps = interleave_lhs sections (List.mapi (fun i v -> if i = opt_idx then "eps" else v) p_vars) in
                               Printf.sprintf "\n  eq is-type ( %s , %s ) = %s ." lhs_eps full_type_name (let r = String.concat " and " (binder_conds @ List.filteri (fun i _ -> i <> opt_idx) (List.map (fun (v, s, _) -> Printf.sprintf "is-type ( %s , %s )" v s) params)) in if r="" then "true" else r)) (find_opt_param_indices case_typ) in
                    main ^ String.concat "" opts
                  end) cases |> List.filter ((<>) "") |> String.concat "\n"
             | AliasT typ ->
                let binder_decl_a = String.concat "" (List.map (fun b -> match b.it with ExpB (tid, _) -> declare_var (to_var_name tid.it) "WasmTerminal" | _ -> "") binders) in
                let rhs = match typ.it with IterT (inner, _) -> translate_typ inner v_map | _ -> translate_typ typ v_map in let var = match typ.it with IterT (_, (List | List1)) -> "TS" | _ -> "T" in
                let lhs_final = if List.mem name base_types then "T" else var in
                Printf.sprintf "%s  eq is-type ( %s , %s ) = %s ." binder_decl_a lhs_final full_type_name (if rhs="WasmType" then "true" else if binder_conds=[] then Printf.sprintf "is-type ( %s , %s )" lhs_final rhs else String.concat " and " binder_conds ^ " and " ^ Printf.sprintf "is-type ( %s , %s )" lhs_final rhs)
             | StructT fields ->
                let binder_decl_s = String.concat "" (List.map (fun b -> match b.it with ExpB (tid, _) -> declare_var (to_var_name tid.it) "WasmTerminal" | _ -> "") binders) in
                let info = List.mapi (fun i (atom, (_, ft, _), _) -> let fn = to_var_name (Xl.Atom.name atom) in let sn = translate_typ (match ft.it with IterT (inner, _) -> inner | _ -> ft) v_map in (fn, Printf.sprintf "F-%s-%d" fn i, sn, if (match ft.it with IterT (_, (List | List1)) -> true | _ -> false) || is_plural_type sn then "WasmTerminals" else "WasmTerminal")) fields in
                let decls = String.concat "" (List.map (fun (_, vn, _, ms) -> declare_var vn ms) info) in
                let rhs = String.concat " and " (binder_conds @ List.map (fun (_, vn, sn, _) -> Printf.sprintf "is-type ( %s , %s )" vn sn) info) in
                Printf.sprintf "%s%s  eq is-type ( {%s} , %s ) = %s ." binder_decl_s decls (String.concat " ; " (List.map (fun (f, vn, _, _) -> Printf.sprintf "item('%s, %s)" f vn) info)) full_type_name (if rhs="" then "true" else rhs))
      ) insts in op_decl ^ String.concat "\n" res

  | DecD (id, params, result_typ, insts) ->
    let func_name = sanitize id.it in
    let maude_func_name = if String.length func_name > 0 && func_name.[0] = '$' then func_name else "$" ^ func_name in
    let prefix = match String.split_on_char '-' (String.uppercase_ascii func_name) with
      | h :: _ ->
          let h = if String.length h > 0 && h.[0] = '$' then String.sub h 1 (String.length h - 1) else h in
          if h = "" then "FN" else h
      | [] -> "FN" in
    let arg_sorts =
      String.concat " "
        (List.map
           (fun p ->
             match p.it with
             | ExpP (_, t) -> if is_bool_typ t [] then "Bool" else "WasmTerminal"
             | _ -> "WasmTerminal")
           params)
    in
    let inferred_bool =
      List.exists (fun inst -> match inst.it with DefD (_, _, rhs_exp, _) -> exp_is_boolish rhs_exp) insts
    in
    let ret_sort =
      match result_typ.it with
      | IterT _ -> "WasmTerminals"
      | _ -> if is_bool_typ result_typ [] || inferred_bool || Hashtbl.mem bool_call_set maude_func_name then "Bool" else "WasmTerminal"
    in
    let eq_counter = ref 0 in
    let all_bound_vars = ref [] in
    let all_free_vars = ref [] in
    let rhs_ctx = if ret_sort = "Bool" then BoolCtx else TermCtx in
    let eq_lines =
      List.map
        (fun inst ->
          let eq_idx = !eq_counter in
          eq_counter := !eq_counter + 1;
          let (binders, lhs_args, rhs_exp, prem_list) =
            match inst.it with DefD (b, la, re, pl) -> (b, la, re, pl)
          in
          let v_map =
            List.filter_map
              (fun b ->
                match b.it with
                | ExpB (v_id, t) ->
                    let raw_v = v_id.it in
                    if is_bool_typ t [] || String.lowercase_ascii raw_v = "bool" then None
                    else
                      Some
                        ( raw_v,
                          Printf.sprintf "%s%d-%s" prefix eq_idx
                            (String.concat "" (String.split_on_char '-' (String.uppercase_ascii (sanitize raw_v)))) )
                | _ -> None)
              binders
          in
          let binder_conds =
            List.filter_map
              (fun b ->
                match b.it with
                | ExpB (v_id, t) ->
                    let t_s = translate_typ t [] in
                    if t_s = "WasmType" || is_bool_typ t [] || String.lowercase_ascii v_id.it = "bool"
                    then None
                    else
                      (match List.assoc_opt v_id.it v_map with
                       | Some mv -> Some (mv, Printf.sprintf "is-type ( %s , %s )" mv (translate_typ t v_map))
                       | None -> None)
                | _ -> None)
              binders
          in
          (* Translate LHS FIRST to determine bound variables *)
          undeclared_vars := [];
          let arg_strs =
            List.map
              (fun a -> match a.it with ExpA e -> translate_exp TermCtx e v_map | _ -> "eps")
              lhs_args
          in
          let lhs_vars = !undeclared_vars in
          (* Translate RHS *)
          undeclared_vars := [];
          let body = translate_exp rhs_ctx rhs_exp v_map in
          let rhs_vars = !undeclared_vars in
          (* Translate conditions *)
          undeclared_vars := [];
          let prem_conds =
            List.filter_map
              (fun p ->
                let s = translate_prem p v_map in
                if s = "" || s = "owise" then None else Some s)
              prem_list
          in
          let prem_vars = !undeclared_vars in
          let has_owise = List.exists (fun p -> match p.it with ElsePr -> true | _ -> false) prem_list in

          let extracted =
            extract_vars_from_maude (String.concat " " (arg_strs @ [body] @ prem_conds))
          in
          let all_used = List.sort_uniq String.compare (rhs_vars @ lhs_vars @ prem_vars @ extracted) in
          let lhs_set = List.sort_uniq String.compare lhs_vars in

          let bound = List.filter (fun v -> List.mem v lhs_set) all_used in
          let free = List.filter (fun v -> not (List.mem v lhs_set)) all_used in

          let binder_conds = binder_conds |> List.filter (fun (mv, _) -> List.mem mv lhs_set) |> List.map snd in

          all_bound_vars := List.sort_uniq String.compare (!all_bound_vars @ bound);
          all_free_vars := List.sort_uniq String.compare (!all_free_vars @ free);

          let all_conds = binder_conds @ prem_conds in
          let cond_str = if all_conds = [] then "" else " \n      if " ^ String.concat " and " all_conds in
          let lhs = format_call maude_func_name arg_strs in
          Printf.sprintf "  %s %s = %s%s%s ."
            (if all_conds = [] then "eq" else "ceq")
            lhs body cond_str (if has_owise then " [owise]" else ""))
        insts
    in
    let op_decl = Printf.sprintf "\n\n  op %s : %s -> %s .\n" maude_func_name arg_sorts ret_sort in
    let truly_free = List.filter (fun v -> not (List.mem v !all_bound_vars)) !all_free_vars in
    let bound_decl = declare_vars_same_sort !all_bound_vars "WasmTerminal" in
    let free_decl = declare_ops_const_list truly_free "WasmTerminal" in
    "\n" ^ op_decl ^ bound_decl ^ free_decl ^ String.concat "\n" eq_lines ^ "\n"

  | RelD (id, _, _, rules) ->
      let rel_name = sanitize id.it in
      let arity = match rules with
        | r :: _ -> (match r.it with RuleD (_, _, _, c, _) -> (match c.it with TupE el -> List.length el | _ -> 1))
        | [] -> 0
      in
      let op_decl = Printf.sprintf "\n  op %s : %s -> Bool .\n" rel_name
        (String.concat " " (List.init arity (fun _ -> "WasmTerminal"))) in

      let rel_prefix = String.uppercase_ascii (sanitize rel_name) in
      let rule_counter = ref 0 in
      let all_bound_vars = ref [] in
      let all_free_vars = ref [] in
      let rule_lines = List.map (fun r -> match r.it with
        | RuleD (case_id, binders, _, conclusion, prem_list) ->
            let rule_idx = !rule_counter in
            rule_counter := !rule_counter + 1;
            let raw_prefix = String.uppercase_ascii (sanitize case_id.it) in
            let case_part = if raw_prefix = "" then Printf.sprintf "R%d" rule_idx else raw_prefix in
            let prefix = Printf.sprintf "%s-%s" rel_prefix case_part in
            let v_map = List.filter_map (fun b -> match b.it with
              | ExpB (v_id, t) ->
                  let raw_v = v_id.it in
                  if is_bool_typ t [] || raw_v = "bool" then None
                  else Some (raw_v, Printf.sprintf "%s%d-%s" prefix rule_idx
                    (String.concat "" (String.split_on_char '-' (String.uppercase_ascii (sanitize raw_v)))))
              | _ -> None) binders in
            let binder_conds = List.filter_map (fun b -> match b.it with
              | ExpB (v_id, t) ->
                  let t_s = translate_typ t [] in
                  if t_s = "WasmType" || is_bool_typ t [] || v_id.it = "bool" then None
                  else
                    (match List.assoc_opt v_id.it v_map with
                     | Some mv -> Some (mv, Printf.sprintf "is-type ( %s , %s )" mv (translate_typ t v_map))
                     | None -> None)
              | _ -> None) binders in
            (* Translate LHS (conclusion) FIRST *)
            undeclared_vars := [];
            let lhs = match conclusion.it with
              | TupE el -> String.concat " , " (List.map (fun x -> translate_exp TermCtx x v_map) el)
              | _ -> translate_exp TermCtx conclusion v_map
            in
            let lhs_vars = !undeclared_vars in
            (* Translate conditions *)
            undeclared_vars := [];
            let prems = List.filter_map (fun p ->
              let s = translate_prem p v_map in
              if s = "" || s = "owise" then None else Some s) prem_list in
            let prem_vars = !undeclared_vars in
            let extracted = extract_vars_from_maude (lhs ^ " " ^ String.concat " " prems) in
            let all_used = List.sort_uniq String.compare (lhs_vars @ prem_vars @ extracted) in
            let lhs_set = List.sort_uniq String.compare lhs_vars in

            let bound = List.filter (fun v -> List.mem v lhs_set) all_used in
            let free = List.filter (fun v -> not (List.mem v lhs_set)) all_used in

            let binder_conds = binder_conds |> List.filter (fun (mv, _) -> List.mem mv lhs_set) |> List.map snd in

            all_bound_vars := List.sort_uniq String.compare (!all_bound_vars @ bound);
            all_free_vars := List.sort_uniq String.compare (!all_free_vars @ free);

            let all_conds = binder_conds @ prems in
            let cond_str = if all_conds = [] then ""
              else " \n      if " ^ String.concat " and " all_conds in
            Printf.sprintf "  %s %s ( %s ) = true%s ."
              (if all_conds = [] then "eq" else "ceq")
              rel_name lhs cond_str
      ) rules in

      let truly_free = List.filter (fun v -> not (List.mem v !all_bound_vars)) !all_free_vars in
      let bound_decl = declare_vars_same_sort !all_bound_vars "WasmTerminal" in
      let free_decl = declare_ops_const_list truly_free "WasmTerminal" in
      op_decl ^ bound_decl ^ free_decl ^ String.concat "\n" rule_lines ^ "\n"

  | GramD _ | HintD _ -> ""

(* ------------------------------------------------------------------------- *)
(* Top-level: prescan + header generation + reordered output                  *)
(* ------------------------------------------------------------------------- *)

let translate (defs : def list) : string =
  build_type_env defs;
  init_declared_vars ();
  Hashtbl.reset token_set;
  Hashtbl.reset call_sigs;
  Hashtbl.reset declared_decs;
  Hashtbl.reset bool_call_set;
  Hashtbl.reset ctor_names;
  List.iter prescan_def defs;
  let token_ops = build_token_ops_lines () in
  let call_ops = build_missing_call_ops_lines () in
  let header = header_prefix ^ "  --- Auto-collected tokens\n" ^ token_ops ^ call_ops in
  let body = String.concat "\n" (List.map translate_definition defs) in
  let lines = String.split_on_char '\n' body in
  let starts_with s pfx = String.length s >= String.length pfx && String.sub s 0 (String.length pfx) = pfx in
  let is_decl l =
    let s = String.trim l in
    starts_with s "op " || starts_with s "ops " ||
    starts_with s "var " || starts_with s "vars " ||
    starts_with s "subsort "
  in
  let decls = List.filter is_decl lines |> List.sort_uniq String.compare in
  let eqs = List.filter (fun l -> not (is_decl l)) lines in
  header ^ "\n  --- Declarations\n" ^ String.concat "\n" decls ^
  "\n\n  --- Equations\n" ^ String.concat "\n" eqs ^ footer
