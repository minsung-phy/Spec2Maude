open Util.Source
open Il.Ast
open Maude_il


(*
 * Mutually recursive translation of SpecTec IL types, arguments,
 * expressions, and paths to Maude terms.
 *)


(* Primitive values *)

let app name args = App (name, args)


(* Sorts *)

let translate_sort index typ =
  Prescan.sort_of_typ index typ

let translate_number = function
  | `Nat n | `Int n -> Const (Z.to_string n)
  | `Rat q when Q.is_real q -> Const (Q.to_string q)
  | `Rat _ -> invalid_arg "nonfinite IL Rat literal is not implemented"
  | `Real _ -> invalid_arg "IL Real literal is not implemented"

let translate_text text =
  let buffer = Buffer.create (String.length text + 2) in
  Buffer.add_char buffer '"';
  String.iter
    (function
      | ('"' | '\\') as c ->
          Buffer.add_char buffer '\\'; Buffer.add_char buffer c
      | ' '..'~' as c -> Buffer.add_char buffer c
      | c ->
          (* Maude string escapes use three octal digits, not OCaml decimal. *)
          Buffer.add_string buffer (Printf.sprintf "\\%03o" (Char.code c)))
    text;
  Buffer.add_char buffer '"';
  Const (Buffer.contents buffer)

let qid text =
  Const ("'" ^ text)

let qid_of_atom atom =
  qid (Il.Print.string_of_atom atom)

(* Primitive operators *)

let translate_unop (op : unop) (optyp : optyp) =
  match op, optyp with
  | _, `RealT -> invalid_arg "IL Real operation is not implemented"
  | `NotOp, _ -> "not_"
  | `PlusOp, _ -> "+_"
  | `MinusOp, _ -> "-_"

let translate_binop op optyp =
  match op, optyp with
  | _, `RealT -> invalid_arg "IL Real operation is not implemented"
  | `PowOp, `RatT -> invalid_arg "IL Rat power is not implemented"
  | `AndOp, `BoolT -> "_and_"
  | `OrOp, `BoolT -> "_or_"
  | `ImplOp, `BoolT -> "_implies_"
  | `EquivOp, `BoolT -> "_==_"
  | `AddOp, #Xl.Num.typ -> "_+_"
  | `SubOp, #Xl.Num.typ -> "_-_"
  | `MulOp, #Xl.Num.typ -> "_*_"
  | `DivOp, #Xl.Num.typ -> "_/_"
  | `ModOp, (`NatT | `IntT) -> "_rem_"
  | `PowOp, #Xl.Num.typ -> "_^_"
  | _ -> invalid_arg "malformed BinE operator annotation"

let translate_comparison (op : cmpop) (optyp : optyp) left right =
  match op, optyp with
  | _, `RealT -> invalid_arg "IL Real comparison is not implemented"
  | `EqOp, _ -> app "_==_" [left; right]
  | `NeOp, _ -> app "_=/=_" [left; right]
  | `LtOp, _ -> app "_<_" [left; right]
  | `GtOp, _ -> app "_>_" [left; right]
  | `LeOp, _ -> app "_<=_" [left; right]
  | `GeOp, _ -> app "_>=_" [left; right]

(* Sequences, tuples, and records *)

let sequence = Iter.sequence
let sequence_of_typ = Iter.sequence_of_typ

let sequence_operator index typ field =
  let representation = Prescan.sequence_representation index typ in
  field representation

let unsupported_typed_sequence index operation typ =
  let representation = Prescan.sequence_representation index typ in
  if representation.typed then
    invalid_arg
      (operation ^ " is unsupported for typed list sort "
       ^ representation.sort)

let rec record_fields = function
  | [] -> Const "EMPTY"
  | [field] -> field
  | field :: fields -> app "_;_" [field; record_fields fields]

let as_sequence_element = Iter.as_sequence_element

let from_sequence_element index typ term =
  match Hintd.sequence_element_wrappers (Prescan.sort_metadata index) typ with
  | Some (_, unbox) -> app unbox [term]
  | None -> term

(* Recursive translation *)

let rec translate_typ index typ =
  match typ.it with
  | VarT (id, args) ->
      begin match Prescan.type_parameter index id, args with
      | Some variable, [] -> Var variable
      | Some _, _ -> invalid_arg "TypP type variable cannot have arguments"
      | None, _ ->
          app (Prescan.typ_name index id) (List.map (translate_arg index) args)
      end
  | BoolT ->
      Const "bool"
  | NumT numtyp ->
      Const (Xl.Num.string_of_typ numtyp)
  | TextT ->
      Const "text"
  | TupT _ ->
      invalid_arg "TupT must be translated by translate_components"
  | IterT (typ, _) ->
      translate_typ index typ

and translate_arg index arg =
  match arg.it with
  | ExpA exp ->
      translate_exp index exp
  | TypA typ ->
      translate_check_typ index typ
  | DefA id ->
      begin match Prescan.definition_argument index arg with
      | Some parameter -> Var (Prescan.definition_variable index parameter)
      | None ->
          Prescan.require_definition_body index "DefA" id;
          Const (Prescan.def_name index id)
      end
  | GramA _ ->
      invalid_arg "GramA is not translated"

and translate_check_typ index typ =
  match typ.it with
  | VarT (id, _) when Prescan.type_parameter index id = None ->
      let expanded = Il.Eval.reduce_typ index.Prescan.type_env typ in
      if Il.Eq.eq_typ expanded typ then translate_typ index typ
      else translate_check_typ index expanded
  | IterT (element, Opt) ->
      app "iterOpt" [translate_check_typ index element]
  | IterT (element, List) ->
      app "iterList" [translate_check_typ index element]
  | IterT (_, List1) ->
      invalid_arg "IterT List1 as a type value is not supported"
  | IterT (_, ListN _) ->
      invalid_arg "IterT ListN as a type value is not supported"
  | VarT _ | BoolT | NumT _ | TextT | TupT _ ->
      translate_typ index typ

and translate_exp index exp =
  match exp.it with
  | VarE id ->
      Var (Prescan.source_variable index id exp.note)

  | BoolE value ->
      Const (string_of_bool value)

  | NumE value ->
      translate_number value

  | TextE value ->
      translate_text value

  | UnE (`PlusOp, _, inner) ->
      translate_exp index inner

  | UnE (op, optyp, inner) ->
      let operand = translate_exp index inner in
      app (translate_unop op optyp) [operand]

  | BinE (op, optyp, left, right) ->
      let left = translate_exp index left in
      let right = translate_exp index right in
      app (translate_binop op optyp) [left; right]

  | CmpE (op, optyp, left, right) ->
      let left = translate_exp index left in
      let right = translate_exp index right in
      translate_comparison op optyp left right

  | TupE exps ->
      exps
      |> List.map (fun exp ->
           translate_exp index exp |> as_sequence_element index exp.note)
      |> sequence
      |> fun terms -> app "tuple" [terms]

  | ProjE ({it = UncaseE (case, mixop); _}, 0)
    when Mixop.is_hole_only mixop && Xl.Mixop.arity mixop = 1 ->
      translate_exp index case

  | ProjE (tuple, field_index) ->
      app "_._"
        [translate_exp index tuple; Const (string_of_int field_index)]
      |> from_sequence_element index exp.note

  | CaseE (mixop, payload) ->
      (* Type premises are invariants, not guards on value construction. *)
      if Mixop.is_hole_only mixop then
        begin match payload.it with
        | TupE [single] -> translate_exp index single
        | _ -> translate_exp index payload
        end
      else
        let args =
          match payload.it with
          | TupE exps -> List.map (translate_exp index) exps
          | _ -> [translate_exp index payload]
        in
        app (Prescan.mixop_name index mixop) args

  | UncaseE (case, mixop) ->
      if Mixop.is_hole_only mixop then
        translate_exp index case
      else
        invalid_arg "named UncaseE is not supported"

  | OptE None ->
      Const "eps"

  | OptE (Some inner) ->
      app "_?"
        [translate_exp index inner |> as_sequence_element index inner.note]

  | TheE _ ->
      invalid_arg "TheE option extraction is not supported"

  | StrE fields ->
      fields
      |> List.map (fun (atom, field) ->
           app "field" [qid_of_atom atom; translate_exp index field])
      |> record_fields
      |> fun fields -> app "{_}" [fields]

  | DotE (record, atom) ->
      app "_._" [translate_exp index record; qid_of_atom atom]

  | CompE (left, right) ->
      translate_composition index exp.note
        (translate_exp index left) (translate_exp index right)

  | ListE exps ->
      exps
      |> List.map (fun exp ->
           translate_exp index exp |> as_sequence_element index exp.note)
      |> sequence_of_typ index exp.note

  | LiftE inner ->
      let operator =
        sequence_operator index exp.note (fun sequence -> sequence.lift)
      in
      app operator [translate_exp index inner]

  | MemE (element, collection) ->
      let operator =
        sequence_operator index collection.note (fun sequence -> sequence.occurs)
      in
      app operator
        [ translate_exp index element |> as_sequence_element index element.note
        ; translate_exp index collection
        ]

  | LenE collection ->
      let operator =
        sequence_operator index collection.note (fun sequence -> sequence.size)
      in
      app operator [translate_exp index collection]

  | CatE (left, right) ->
      let operator =
        sequence_operator index exp.note (fun sequence -> sequence.concat)
      in
      app operator [translate_exp index left; translate_exp index right]

  | IdxE (sequence, element_index) ->
      unsupported_typed_sequence index "IdxE" sequence.note;
      app "_`[_`]"
        [translate_exp index sequence; translate_exp index element_index]
      |> from_sequence_element index exp.note

  | SliceE (sequence, start, length) ->
      unsupported_typed_sequence index "SliceE" sequence.note;
      app "_`[_:_`]"
        [ translate_exp index sequence
        ; translate_exp index start
        ; translate_exp index length
        ]

  | UpdE (base, path, replacement) ->
      translate_update
        index (translate_exp index base) path (translate_exp index replacement)

  | ExtE (base, path, extension) ->
      translate_extension
        index (translate_exp index base) path (translate_exp index extension)

  | IfE (condition, then_exp, else_exp) ->
      app "if_then_else_fi"
        [ translate_exp index condition
        ; translate_exp index then_exp
        ; translate_exp index else_exp
        ]

  | CallE (id, args) ->
      begin match Prescan.definition_call index exp with
      | Some parameter ->
          app "apply"
            (Var (Prescan.definition_variable index parameter)
             :: List.map (translate_arg index) args)
      | None ->
          Prescan.require_definition_body index "CallE" id;
          app (Prescan.def_name index id) (List.map (translate_arg index) args)
      end

  | IterE (body, (iter, generators)) ->
      Iter.translate_term
        index (translate_exp index) body (iter, generators)

  | CvtE (_, `RealT, _) | CvtE (_, _, `RealT) ->
      invalid_arg "IL Real conversion is not implemented"

  | CvtE (inner, source, target) ->
      app "_:_<:>_"
        [ translate_exp index inner
        ; Const (Xl.Num.string_of_typ source)
        ; Const (Xl.Num.string_of_typ target)
        ]

  | SubE (inner, source, target) ->
      if Prescan.same_representation index source target then
        translate_exp index inner
      else
        invalid_arg
          ("Unsupported SubE representation: " ^ Il.Print.string_of_typ source
           ^ " -> " ^ Il.Print.string_of_typ target
           ^ " at " ^ string_of_region source.at)

and translate_select index base path =
  match path.it with
  | RootP ->
      base

  | IdxP (parent, element_index) ->
      unsupported_typed_sequence index "IdxP" parent.note;
      app "_`[_`]"
        [ translate_select index base parent
        ; translate_exp index element_index
        ]
      |> from_sequence_element index path.note

  | SliceP (parent, start, length) ->
      unsupported_typed_sequence index "SliceP" parent.note;
      app "_`[_:_`]"
        [ translate_select index base parent
        ; translate_exp index start
        ; translate_exp index length
        ]

  | DotP (parent, atom) ->
      app "_._"
        [ translate_select index base parent
        ; qid_of_atom atom
        ]


and translate_update index base path replacement =
  match path.it with
  | RootP ->
      replacement

  | IdxP (parent, element_index) ->
      unsupported_typed_sequence index "UpdE/IdxP" parent.note;
      let parent_value = translate_select index base parent in
      let replacement =
        as_sequence_element index path.note replacement
      in
      let updated_parent =
        app "_`[_=_`]"
          [parent_value; translate_exp index element_index; replacement]
      in
      translate_update index base parent updated_parent

  | SliceP (parent, start, length) ->
      unsupported_typed_sequence index "UpdE/SliceP" parent.note;
      let parent_value = translate_select index base parent in
      let updated_parent =
        app "_`[_:_=_`]"
          [ parent_value
          ; translate_exp index start
          ; translate_exp index length
          ; replacement
          ]
      in
      translate_update index base parent updated_parent

  | DotP (parent, atom) ->
      let parent_value = translate_select index base parent in
      let updated_parent =
        app "_`[._=_`]" [parent_value; qid_of_atom atom; replacement]
      in
      translate_update index base parent updated_parent


and translate_extension index base path extension =
  (* EXT e p e' = UPD e p (CAT (ACC e p) e').  The existing path
   * translation unboxes the selected value and reboxes it on update. *)
  let operator =
    sequence_operator index path.note (fun sequence -> sequence.concat)
  in
  let extended = app operator [translate_select index base path; extension] in
  translate_update index base path extended

and translate_composition index typ left right =
  (* Expand declarations and type arguments only; do not evaluate the operands. *)
  match (Il.Eval.reduce_typdef index.Prescan.type_env typ).it with
  | AliasT {it = IterT (_, Opt); _} ->
      app "optionConcat" [left; right]
  | AliasT {it = IterT (_, (List | List1 | ListN _)); _} ->
      let operator =
        sequence_operator index typ (fun sequence -> sequence.concat)
      in
      app operator [left; right]
  | StructT _ ->
      if not (Prescan.record_composition_available index typ) then
        invalid_arg
          ("Unsupported CompE for " ^ Il.Print.string_of_typ typ
           ^ " at " ^ string_of_region typ.at
           ^ ": record composition requires a monomorphic StructT declaration");
      app "recordConcat" [left; right; translate_typ index typ]
  | AliasT _ | VariantT _ ->
      invalid_arg ("non-composable CompE type: " ^ Il.Print.string_of_typ typ)


(* Constructor components *)

let translate_bool = translate_exp

let rec translate_typ_conditions index value typ =
  match translate_sort index typ, typ.it with
  | _, NumT (`NatT | `IntT) ->
      []
  | _, TupT fields ->
      let rec check bindings position = function
        | [] -> [], []
        | (id, typ) :: fields ->
            let variable =
              generated_variable
                ("TUPLE-CHECK" ^ string_of_int position) (translate_sort index typ)
            in
            let component = Var variable in
            let substitute variable =
              match
                List.find_opt (fun (source, _) -> same_variable source variable) bindings
              with
              | Some (_, target) -> target
              | None -> variable
            in
            let conditions =
              translate_typ_conditions index component typ
              |> List.map (map_eq_condition_variables substitute)
            in
            let bindings =
              if id.it = "_" then bindings
              else (Prescan.source_variable index id typ, variable) :: bindings
            in
            let values, rest = check bindings (position + 1) fields in
            as_sequence_element index typ component :: values, conditions @ rest
      in
      let values, conditions = check [] 1 fields in
      MatchCond (app "tuple" [sequence values], value) :: conditions
  | _, IterT (element_typ, iter) ->
      let representation = Prescan.sequence_representation index typ in
      if representation.typed then
        let length = app representation.size [value] in
        begin match iter with
        | Opt | List -> []
        | List1 -> [BoolCond (app "_<_" [Const "0"; length])]
        | ListN (count, _) ->
            [EqCond (length, translate_exp index count)]
        end
      else
        Iter.translate_conditions
          (translate_exp index) value (translate_check_typ index element_typ) iter
  | _, _ ->
      [BoolCond (app "typecheck" [value; translate_typ index typ])]

and make_component index field_index repeated id typ =
  let sort = translate_sort index typ in
  let variable =
    if id.it = "_" then
      generated_variable ("VALUE" ^ string_of_int (field_index + 1)) sort
    else if repeated then
      let source = Prescan.source_variable index id typ in
      generated_variable source.name sort
    else
      Prescan.source_variable index id typ
  in
  let value = Var variable in
  let conditions = translate_typ_conditions index value typ in
  value, sort, conditions

and translate_components index typ =
  match typ.it with
  | TupT fields ->
      let rec translate_fields seen field_index = function
        | [] -> []
        | (id, typ) :: fields ->
            let repeated = id.it <> "_" && List.mem id.it seen in
            let component =
              make_component index field_index repeated id typ
            in
            let seen = if id.it = "_" then seen else id.it :: seen in
            component :: translate_fields seen (field_index + 1) fields
      in
      translate_fields [] 0 fields
  | _ ->
      let sort = translate_sort index typ in
      let value = Var (generated_variable "VALUE" sort) in
      [value, sort, translate_typ_conditions index value typ]


(* Decompose declared input types along their source patterns.
   Only common memberships of all possible branches may omit a guard. *)
let rec source_value exp = match exp.it with
  | SubE (inner, _, _) -> source_value inner
  | CaseE (Xl.Mixop.Arg (), payload) ->
      let inner = match payload.it with TupE [inner] -> inner | _ -> payload in
      source_value inner
  | _ -> exp
let same_source_value a b = Il.Eq.eq_exp (source_value a) (source_value b)
let type_substitution params args =
  if List.length params <> List.length args then None else
  List.fold_left2 (fun result param arg ->
    Option.bind result (fun subst ->
      match param.it, arg.it with
      | ExpP (id, _), ExpA value -> Some (Il.Subst.add_varid subst id value)
      | TypP id, TypA typ -> Some (Il.Subst.add_typid subst id typ)
      | DefP (id, _, _), DefA target -> Some (Il.Subst.add_defid subst id target)
      | _ -> None)) (Some Il.Subst.empty) params args

let fresh_type_instance inst =
  let InstD (quants, args, body) = inst.it in
  let subst = List.fold_left (fun subst quant -> match quant.it with
    | ExpP (id, typ) ->
        let fresh = Il.Fresh.refresh_varid id in
        Il.Subst.add_varid subst id (VarE fresh $$ id.at % typ)
    | TypP id -> Il.Subst.add_typid subst id (VarT (Il.Fresh.refresh_typid id, []) $ id.at)
    | DefP _ | GramP _ -> subst) Il.Subst.empty quants in
  let quants = List.map (fun quant -> match quant.it with
    | ExpP (id, typ) ->
        let value = Il.Subst.subst_exp subst (VarE id $$ id.at % typ) in
        let id = match value.it with VarE id -> id | _ -> assert false in
        ExpP (id, Il.Subst.subst_typ subst typ) $ quant.at
    | _ -> quant) quants in
  quants, Il.Subst.subst_args subst args, Il.Subst.subst_deftyp subst body

(* Argument matching retains constraints from the original instance pattern.
   A narrow note on the caller's pattern is never such a constraint. *)
let rec match_type_pattern quants subst constraints pattern actual =
  let actual = source_value actual in
  match pattern.it, actual.it with
  | SubE (inner, source, _), _ ->
      match_type_pattern quants subst ((actual, source) :: constraints) inner actual
  | VarE id, _ ->
      let constraints = match List.find_opt (fun q -> match q.it with ExpP (x, _) -> x.it = id.it | _ -> false) quants with
        | Some {it = ExpP (_, typ); _} -> (actual, typ) :: constraints
        | _ -> constraints in
      begin match Il.Subst.Map.find_opt id.it subst.Il.Subst.varid with
      | Some previous when not (same_source_value previous actual) -> None
      | _ -> Some (Il.Subst.add_varid subst id actual, constraints)
      end
  | CaseE (Xl.Mixop.Arg (), payload), _ ->
      let inner = match payload.it with TupE [inner] -> inner | _ -> payload in
      match_type_pattern quants subst constraints inner actual
  | CaseE (op, payload), CaseE (op', payload') when Il.Eq.eq_mixop op op' ->
      match_type_pattern quants subst constraints payload payload'
  | TupE xs, TupE ys | ListE xs, ListE ys when List.length xs = List.length ys ->
      List.fold_left2 (fun result x y -> Option.bind result (fun (s, cs) -> match_type_pattern quants s cs x y))
        (Some (subst, constraints)) xs ys
  | OptE (Some x), OptE (Some y) -> match_type_pattern quants subst constraints x y
  | _, VarE _ -> Some (subst, constraints) (* unknown, not an impossible branch *)
  | _ when Il.Eq.eq_exp pattern actual -> Some (subst, constraints)
  | (CaseE _ | TupE _ | ListE _ | OptE _ | NumE _ | BoolE _ | TextE _),
    (CaseE _ | TupE _ | ListE _ | OptE _ | NumE _ | BoolE _ | TextE _) -> None
  | _ -> Some (subst, constraints) (* unknown argument shape remains possible *)

let match_type_arguments quants patterns actuals =
  if List.length patterns <> List.length actuals then None else
  List.fold_left2 (fun result pattern actual -> Option.bind result (fun (subst, cs) ->
    match pattern.it, actual.it with
    | ExpA x, ExpA y -> match_type_pattern quants subst cs x y
    | TypA {it = VarT (id, []); _}, TypA typ -> Some (Il.Subst.add_typid subst id typ, cs)
    | _ when Il.Eq.eq_arg pattern actual -> Some (subst, cs)
    | _ -> None)) (Some (Il.Subst.empty, [])) patterns actuals

let type_instances index typ = match typ.it with
  | VarT (id, args) ->
      begin match Il.Env.find_opt_typ index.Prescan.type_env id with
      | None -> []
      | Some (params, insts) -> List.filter_map (fun inst ->
          let quants, patterns, body = fresh_type_instance inst in
          let matched = if patterns = [] then Option.map (fun s -> s, []) (type_substitution params args)
            else match_type_arguments quants patterns args in
          Option.map (fun (s, cs) ->
            Il.Subst.subst_deftyp s body,
            List.map (fun (v, t) -> v, Il.Subst.subst_typ s t) cs) matched) insts
      end
  | _ -> []

let rec type_alias index seen typ =
  if List.exists (Il.Eq.eq_typ typ) seen then typ else
  match type_instances index typ with
  | [({it = AliasT inner; _}, [])] -> type_alias index (typ :: seen) inner
  | _ -> typ
let rec identity_exp exp =
  let it = match exp.it with
    | SubE (inner, _, _) -> (identity_exp inner).it
    | CallE (id, args) -> CallE (id, List.map identity_arg args)
    | TupE xs -> TupE (List.map identity_exp xs)
    | CaseE (Xl.Mixop.Arg (), _) -> (identity_exp (source_value exp)).it
    | CaseE (op, body) -> CaseE (op, identity_exp body)
    | _ -> exp.it in
  {exp with it}
and identity_arg arg = match arg.it with
  | ExpA exp -> {arg with it = ExpA (identity_exp exp)}
  | TypA typ -> {arg with it = TypA (identity_typ typ)}
  | DefA _ | GramA _ -> arg
and identity_typ typ =
  let it = match typ.it with
    | VarT (id, args) -> VarT (id, List.map identity_arg args)
    | IterT (inner, iter) -> IterT (identity_typ inner, iter)
    | TupT fields -> TupT (List.map (fun (id, typ) -> id, identity_typ typ) fields)
    | _ -> typ.it in
  {typ with it}
let same_source_type index a b = Il.Eq.eq_typ
  (identity_typ (type_alias index [] a)) (identity_typ (type_alias index [] b))
let membership_type typ = match typ.it with IterT (inner, _) -> inner | _ -> typ
let same_membership index source target =
  let source = membership_type (type_alias index [] source) in
  let target = membership_type (type_alias index [] target) in
  same_source_type index source target

(* A source declaration may promise a narrowing of a structural projection.
   Only a complete, unconditional DefD projection is unfolded here. *)
let source_projection index exp =
  match (source_value exp).it with
  | CallE (id, args) ->
      begin match Il.Env.find_opt_def index.Prescan.type_env id with
      | Some (_, _, clauses) ->
          let results = List.map (fun clause ->
            let DefD (quants, patterns, body, prems) = clause.it in
            if prems <> [] then None else
            match match_type_arguments quants patterns args, body.it with
            | Some (subst, _), VarE field when Il.Subst.mem_varid subst field ->
                Some (source_value (Il.Subst.subst_exp subst body))
            | _ -> None) clauses in
          begin match results with
          | Some first :: rest when List.for_all (function Some next -> same_source_value first next | None -> false) rest -> first
          | _ -> exp
          end
      | None -> exp
      end
  | _ -> exp

let payload_substitution typ value =
  match typ.it, value.it with
  | TupT fields, TupE values when List.length fields = List.length values ->
      List.fold_left2 (fun s (id, _) v -> Il.Subst.add_varid s id v) Il.Subst.empty fields values
  | TupT [(id, _)], _ -> Il.Subst.add_varid Il.Subst.empty id value
  | _ -> Il.Subst.empty
let declaration_types index payload value prems =
  let subst = payload_substitution payload value in
  List.filter_map (fun prem ->
    match (Il.Subst.subst_prem subst prem).it with
    | IfPr {it = CmpE (`EqOp, _, left, {it = SubE (_, narrow, _); _}); _} ->
        Some (source_value (source_projection index left), narrow)
    | IfPr {it = CmpE (`EqOp, _, {it = SubE (_, narrow, _); _}, right); _} ->
        Some (source_value (source_projection index right), narrow)
    | _ -> None) prems

(* Complete alternatives are inspected in source order. Unknown cases contribute
   an empty implication, so they cannot make another branch look exclusive. *)
let rec input_type_branches index facts seen value typ =
  let value = source_value value in
  if List.exists (fun (v, t) -> same_source_value v value && Il.Eq.eq_typ t typ) seen then [[]] else
  let seen = (value, typ) :: seen in
  let root = value, typ in
  let add_root = List.map (fun fs -> root :: fs) in
  let combine alternatives next =
    List.concat_map (fun fs -> List.map (fun more -> fs @ more) next) alternatives in
  match typ.it, value.it with
  | IterT (_, _), CatE (a, b) ->
      add_root (combine (input_type_branches index facts seen a typ) (input_type_branches index facts seen b typ))
  | IterT (element, Opt), OptE (Some inner) -> add_root (input_type_branches index facts seen inner element)
  | IterT (element, _), ListE xs ->
      add_root (List.fold_left (fun acc x -> combine acc (input_type_branches index facts seen x element)) [[]] xs)
  | IterT (element, _), IterE (body, (_, generators)) ->
      let branches = input_type_branches index facts seen body element in
      add_root (List.map (fun fs -> fs @ List.filter_map (fun (id, source) ->
        match List.find_opt (fun f -> match (fst f).it with VarE x -> x.it = id.it | _ -> false) fs with
        | Some f -> Some (source_value source, IterT (snd f, List) $ source.at)
        | None -> None) generators) branches)
  | TupT [(_, inner)], _ when (match value.it with TupE _ -> false | _ -> true) ->
      add_root (input_type_branches index facts seen value inner)
  | TupT fields, TupE xs when List.length fields = List.length xs ->
      let rec fields_ subst acc fields xs = match fields, xs with
        | [], [] -> acc
        | (id, t) :: ts, x :: xs ->
            let t = Il.Subst.subst_typ subst t in
            fields_ (Il.Subst.add_varid subst id x) (combine acc (input_type_branches index facts seen x t)) ts xs
        | _ -> [[]] in
      add_root (fields_ Il.Subst.empty [[]] fields xs)
  | VarT (_, []), VarE _ -> [[root]]
  | VarT _, _ ->
      let insts = type_instances index typ in
      if insts = [] then [[root]] else
      List.concat_map (fun (body, constraints) ->
        let constraints_possible = List.for_all (fun (v, t) -> possible_input_type index facts seen v t) constraints in
        if not constraints_possible then [] else
        let branches = match body.it with
          | AliasT inner -> input_type_branches index facts seen value inner
          | StructT fields ->
              begin match value.it with
              | StrE values -> List.fold_left (fun acc (atom, (t, _, _), _) ->
                  match List.find_opt (fun (a, _) -> Il.Eq.eq_atom a atom) values with
                  | Some (_, v) -> combine acc (input_type_branches index facts seen v t)
                  | None -> acc) [[]] fields
              | _ -> [[]]
              end
          | VariantT cases -> List.concat_map (fun (op, (payload, _, prems), _) ->
              if op = Xl.Mixop.Arg () then
                List.map (fun fs -> declaration_types index payload value prems @ fs)
                  (input_type_branches index facts seen value payload)
              else
              match value.it with
              | CaseE (actual, inner) when Il.Eq.eq_mixop op actual -> input_type_branches index facts seen inner payload
              | VarE _ when translate_sort index value.note <> "Nat" -> [[]]
              | CaseE _ | NumE _ | BoolE _ | TextE _ | ListE _ | OptE _ | StrE _ | TupE _ -> []
              | VarE _ -> []
              | _ -> [[]]) cases in
        List.map (fun fs -> root :: List.map (fun (v, t) -> source_value v, t) constraints @ fs) branches) insts
  | NumT _, CaseE _ | BoolT, CaseE _ | TextT, CaseE _ -> []
  | _, _ -> [[root]]
and possible_input_type index facts seen value typ =
  let known = List.filter (fun f -> same_source_value (fst f) value) facts in
  let structural = input_type_branches index [] seen value typ <> [] in
  structural && List.for_all (fun f ->
    let literals t =
      let rec collect seen t =
        if List.exists (Il.Eq.eq_typ t) seen then None else
        match type_instances index t with
        | [(body, [])] -> begin match body.it with
            | AliasT inner -> collect (t :: seen) inner
            | VariantT cases ->
                if List.for_all (fun (op, (t, _, prems), _) -> op <> Xl.Mixop.Arg () && prems = [] && t.it = TupT []) cases
                then Some (List.map (fun (op, _, _) -> op) cases) else None
            | _ -> None end
        | _ -> None in collect [] t in
    match literals (snd f), literals typ with
    | Some xs, Some ys -> List.exists (fun x -> List.exists (Il.Eq.eq_mixop x) ys) xs
    | _ -> true) known

let add_input_type index known value typ =
  match input_type_branches index !known [] value typ with
  | [] -> ()
  | first :: rest -> List.iter (fun (v, t) ->
      let same (v', t') = same_source_value v v' && same_membership index t' t in
      if List.for_all (List.exists same) rest
         && not (List.exists (fun (v', t') -> same_source_value v v' && Il.Eq.eq_typ t' t) !known)
      then known := (v, t) :: !known) first

let refine_input_types index known =
  List.iter (fun (value, typ) -> add_input_type index known value typ) !known

let with_parameter_types index params args =
  let known = ref [] in
  let index = {index with Prescan.input_types = Some known} in
  Option.iter (fun subst -> List.iter2 (fun param arg -> match param.it, arg.it with
    | ExpP (_, typ), ExpA value -> add_input_type index known value (Il.Subst.subst_typ subst typ)
    | _ -> ()) params args) (type_substitution params args);
  refine_input_types index known;
  index

let with_relation_types index id params inputs =
  let known = ref [] in
  let index = {index with Prescan.input_types = Some known} in
  begin match Il.Env.find_opt_rel index.Prescan.type_env id with
  | None -> ()
  | Some (_, _, schema, _) ->
      List.iter (fun param -> match param.it with
        | ExpP (id, typ) -> add_input_type index known (VarE id $$ id.at % typ) typ
        | _ -> ()) params;
      let fields = match schema.it with TupT fields -> fields | _ -> [("_" $ schema.at), schema] in
      let rec fields_ subst fields inputs = match fields, inputs with
        | (id, typ) :: fields, value :: inputs ->
            add_input_type index known value (Il.Subst.subst_typ subst typ);
            fields_ (Il.Subst.add_varid subst id value) fields inputs
        | _ -> () in
      fields_ Il.Subst.empty fields inputs;
      refine_input_types index known
  end;
  index

let translate_guard_conditions index value typ =
  let conditions = translate_typ_conditions index value typ in
  match index.Prescan.input_types with
  | None -> conditions
  | Some known ->
      let matching = List.filter (fun (v, _) -> translate_exp index v = value) !known in
      let native = match value, (type_alias index [] typ).it with
        | Var v, NumT `NatT -> v.sort = "Nat"
        | Var v, VarT (id, []) -> id.it = v.sort
            && List.mem id.it (Hintd.annotated_sorts (Prescan.sort_metadata index))
        | _ -> false in
      let implied = native || List.exists (fun (_, t) -> same_membership index t typ) matching in
      List.filter (function
        | BoolCond (App ("typecheck", _)) when implied -> false
        | BoolCond (App ("typecheck", _)) ->
            begin match matching with
            | (v, _) :: _ -> add_input_type index known v typ; refine_input_types index known
            | [] -> ()
            end;
            true
        | _ -> true) conditions
