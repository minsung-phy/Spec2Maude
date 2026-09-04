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

let translate_number num =
  let text = Xl.Num.to_string num in
  let text =
    if String.length text > 0 && text.[0] = '+' then
      String.sub text 1 (String.length text - 1)
    else
      text
  in
  match num with
  | `Nat _ | `Int _ -> Const text
  | `Rat _ -> app "rat" [Const text]
  | `Real _ -> app "float" [Const text]

let translate_text text =
  app "text" [Const ("\"" ^ String.escaped text ^ "\"")]

let qid text =
  Const ("'" ^ text)

let qid_of_atom atom =
  qid (Il.Print.string_of_atom atom)

(* Primitive operators *)

let translate_unop = function
  | `NotOp -> "not_"
  | `PlusOp -> "+_"
  | `MinusOp -> "-_"

let translate_binop op optyp =
  match op, optyp with
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

let translate_cmpop = function
  | `EqOp -> "_==_"
  | `NeOp -> "_=/=_"
  | `LtOp -> "_<_"
  | `GtOp -> "_>_"
  | `LeOp -> "_<=_"
  | `GeOp -> "_>=_"

let unwrap typ term =
  match typ.it with
  | BoolT -> app "isTrue" [term]
  | NumT `RatT -> app "ratValue" [term]
  | NumT `RealT -> app "floatValue" [term]
  | VarT _ | NumT (`NatT | `IntT) | TextT | TupT _ | IterT _ -> term

let wrap typ term =
  match typ.it with
  | BoolT -> app "bool" [term]
  | NumT `RatT -> app "rat" [term]
  | NumT `RealT -> app "float" [term]
  | VarT _ | NumT (`NatT | `IntT) | TextT | TupT _ | IterT _ -> term


(* Sequences, tuples, and records *)

let rec sequence = function
  | [] -> Const "eps"
  | [term] -> term
  | term :: terms -> app "_ _" [term; sequence terms]

let rec sequence_with representation = function
  | [] -> Const representation.Hintd.empty
  | [term] -> term
  | term :: terms ->
      app representation.Hintd.concat
        [term; sequence_with representation terms]

let sequence_of_typ index typ terms =
  sequence_with (Prescan.sequence_representation index typ) terms

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

let as_sequence_element index typ term =
  match
    Hintd.sequence_element_wrappers
      (Prescan.sort_metadata index) typ
  with
  | Some (box, _) -> app box [term]
  | None -> term

let from_sequence_element index typ term =
  match
    Hintd.sequence_element_wrappers
      (Prescan.sort_metadata index) typ
  with
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
      translate_typ index typ
  | DefA id ->
      begin match Prescan.definition_argument index arg with
      | Some parameter -> Var (Prescan.definition_variable index parameter)
      | None -> Const (Prescan.def_name index id)
      end
  | GramA _ ->
      invalid_arg "GramA is not translated"

and translate_check_typ index typ =
  match typ.it with
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
      app "bool" [Const (string_of_bool value)]

  | NumE value ->
      translate_number value

  | TextE value ->
      translate_text value

  | UnE (`PlusOp, _, inner) ->
      translate_exp index inner

  | UnE (op, _, inner) ->
      let operand = translate_exp index inner |> unwrap inner.note in
      app (translate_unop op) [operand]
      |> wrap exp.note

  | BinE (op, optyp, left, right) ->
      let left = translate_exp index left |> unwrap left.note in
      let right = translate_exp index right |> unwrap right.note in
      app (translate_binop op optyp) [left; right]
      |> wrap exp.note

  | CmpE (op, _, left, right) ->
      let left = translate_exp index left |> unwrap left.note in
      let right = translate_exp index right |> unwrap right.note in
      app (translate_cmpop op) [left; right]
      |> wrap exp.note

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
      let operator =
        match Prescan.composition_kind index exp.note with
        | Prescan.SequenceComposition ->
            sequence_operator index exp.note (fun sequence -> sequence.append)
        | Prescan.RecordComposition -> "recordConcat"
      in
      app operator [translate_exp index left; translate_exp index right]

  | ListE exps ->
      let terms =
        exps
        |> List.map (fun exp ->
             translate_exp index exp |> as_sequence_element index exp.note)
        |> sequence_of_typ index exp.note
      in
      let representation = Prescan.sequence_representation index exp.note in
      if representation.typed then terms else app "`[_`]" [terms]

  | LiftE inner ->
      let operator =
        sequence_operator index exp.note (fun sequence -> sequence.lift)
      in
      app operator [translate_exp index inner]

  | MemE (element, collection) ->
      let operator =
        sequence_operator index collection.note (fun sequence -> sequence.occurs)
      in
      app operator [translate_exp index element; translate_exp index collection]
      |> wrap exp.note

  | LenE collection ->
      let operator =
        sequence_operator index collection.note (fun sequence -> sequence.size)
      in
      app operator [translate_exp index collection]

  | CatE (left, right) ->
      let operator =
        sequence_operator index exp.note (fun sequence -> sequence.append)
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
        [ translate_exp index condition |> unwrap condition.note
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
          app (Prescan.def_name index id) (List.map (translate_arg index) args)
      end

  | IterE (body, (iter, generators)) ->
      Iter.translate_term
        index (translate_exp index) body (iter, generators)

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
          ("SubE changes the Maude representation sort: "
           ^ Il.Print.string_of_typ source ^ " -> "
           ^ Il.Print.string_of_typ target)


and translate_bool index exp =
  match exp.it with
  | BoolE value ->
      Const (string_of_bool value)

  | UnE (`NotOp, _, inner) ->
      app "not_" [translate_bool index inner]

  | BinE (`ImplOp, `BoolT, left, right) ->
      app "_implies_" [translate_bool index left; translate_bool index right]

  | BinE ((`AndOp | `OrOp | `EquivOp) as op,
          `BoolT, left, right) ->
      app (translate_binop op `BoolT)
        [translate_bool index left; translate_bool index right]

  | CmpE (op, _, left, right) ->
      app (translate_cmpop op)
        [ translate_exp index left |> unwrap left.note
        ; translate_exp index right |> unwrap right.note
        ]

  | MemE (element, collection) ->
      let operator =
        sequence_operator index collection.note (fun sequence -> sequence.occurs)
      in
      app operator
        [translate_exp index element; translate_exp index collection]

  | _ ->
      translate_exp index exp |> unwrap exp.note


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
        app "_`[._=_`]"
          [parent_value; qid_of_atom atom; replacement]
      in
      translate_update index base parent updated_parent


and translate_extension index base path extension =
  match path.it with
  | RootP ->
      let operator =
        sequence_operator index path.note (fun sequence -> sequence.append)
      in
      app operator [base; extension]

  | IdxP (parent, element_index) ->
      unsupported_typed_sequence index "ExtE/IdxP" parent.note;
      let parent_value = translate_select index base parent in
      let extended_parent =
        app "_`[_=++_`]"
          [parent_value; translate_exp index element_index; extension]
      in
      translate_update index base parent extended_parent

  | SliceP (parent, start, length) ->
      unsupported_typed_sequence index "ExtE/SliceP" parent.note;
      let parent_value = translate_select index base parent in
      let extended_parent =
        app "_`[_:_=++_`]"
          [ parent_value
          ; translate_exp index start
          ; translate_exp index length
          ; extension
          ]
      in
      translate_update index base parent extended_parent

  | DotP (parent, atom) ->
      let parent_value = translate_select index base parent in
      let extended_parent =
        app "_`[._=++_`]"
          [parent_value; qid_of_atom atom; extension]
      in
      translate_update index base parent extended_parent


(* Constructor components *)

let translate_typ_conditions index value typ =
  match translate_sort index typ, typ.it with
  | ("Nat" | "Int"), _ ->
      []
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

let make_component index field_index repeated id typ =
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

let translate_components index typ =
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
