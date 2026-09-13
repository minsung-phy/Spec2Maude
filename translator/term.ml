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
  | `Rat _ -> invalid_arg "nonfinite IL Rat literal is outside the Wasm scope"
  | `Real _ -> invalid_arg "IL Real literal is outside the Wasm scope"

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
  | _, `RealT -> invalid_arg "IL Real operation is outside the Wasm scope"
  | `NotOp, _ -> "not_"
  | `PlusOp, _ -> "+_"
  | `MinusOp, _ -> "-_"

let translate_binop op optyp =
  match op, optyp with
  | _, `RealT -> invalid_arg "IL Real operation is outside the Wasm scope"
  | `PowOp, `RatT -> invalid_arg "IL Rat power is outside the Wasm scope"
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
  | _, `RealT -> invalid_arg "IL Real comparison is outside the Wasm scope"
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

let rec record_items = function
  | [] -> Const "EMPTY"
  | [item] -> item
  | item :: items -> app "_;_" [item; record_items items]

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
  | IterT (element, List1) ->
      app "iterList1" [translate_check_typ index element]
  | IterT (element, ListN (count, _)) ->
      app "iterListN"
        [translate_check_typ index element; translate_exp index count]
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

  | TheE option ->
      app "_!" [translate_exp index option]
      |> from_sequence_element index exp.note

  | StrE fields ->
      fields
      |> List.map (fun (atom, field) ->
           app "item" [qid_of_atom atom; translate_exp index field])
      |> record_items
      |> fun items -> app "{_}" [items]

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
      invalid_arg "IL Real conversion is outside the Wasm scope"

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
