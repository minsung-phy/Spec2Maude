open Util.Source
open Il.Ast
open Maude_il


(* Primitive values *)

let app name args = App (name, args)

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

let qid_of_mixop mixop =
  qid (Il.Print.string_of_mixop mixop)

let source_name id =
  id.it


(* Primitive operators *)

let translate_unop = function
  | `NotOp -> "~_"
  | `PlusOp -> "+_"
  | `MinusOp -> "-_"

let translate_binop op optyp =
  match op, optyp with
  | `AndOp, `BoolT -> "_/\\_"
  | `OrOp, `BoolT -> "_\\/_"
  | `ImplOp, `BoolT -> "_=>_"
  | `EquivOp, `BoolT -> "_<=>_"
  | `AddOp, #Xl.Num.typ -> "_+_"
  | `SubOp, #Xl.Num.typ -> "_-_"
  | `MulOp, #Xl.Num.typ -> "_*_"
  | `DivOp, #Xl.Num.typ -> "_/_"
  | `ModOp, `NatT -> "_\\_"
  | `ModOp, `IntT -> "int-rem"
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

let rec record_items = function
  | [] -> Const "EMPTY"
  | [item] -> item
  | item :: items -> app "_;_" [item; record_items items]

let as_sequence_element typ term =
  match typ.it with
  | IterT _ -> app "seq" [term]
  | _ -> term

let from_sequence_element typ term =
  match typ.it with
  | IterT _ -> app "unseq" [term]
  | _ -> term

let is_hole_only mixop =
  Xl.Mixop.flatten mixop |> List.for_all (( = ) [])


(* Expressions *)

let rec translate_term exp =
  match exp.it with
  | VarE id ->
      Var
        { name = String.uppercase_ascii id.it
        ; sort = Typ.translate_sort exp.note
        }

  | BoolE value ->
      app "bool" [Const (string_of_bool value)]

  | NumE value ->
      translate_number value

  | TextE value ->
      translate_text value

  | UnE (`PlusOp, _, inner) ->
      translate_term inner

  | UnE (op, _, inner) ->
      let operand = translate_term inner |> unwrap inner.note in
      app (translate_unop op) [operand]
      |> wrap exp.note

  | BinE (op, optyp, left, right) ->
      let left = translate_term left |> unwrap left.note in
      let right = translate_term right |> unwrap right.note in
      app (translate_binop op optyp) [left; right]
      |> wrap exp.note

  | CmpE (op, _, left, right) ->
      let left = translate_term left |> unwrap left.note in
      let right = translate_term right |> unwrap right.note in
      app (translate_cmpop op) [left; right]
      |> wrap exp.note

  | TupE exps ->
      exps
      |> List.map (fun exp ->
           translate_term exp |> as_sequence_element exp.note)
      |> sequence
      |> fun terms -> app "tuple" [terms]

  | ProjE (tuple, index) ->
      app "_._" [translate_term tuple; Const (string_of_int index)]
      |> from_sequence_element exp.note

  | CaseE (mixop, payload) ->
      if is_hole_only mixop then
        translate_term payload
      else
        let args =
          match payload.it with
          | TupE exps -> List.map translate_term exps
          | _ -> [translate_term payload]
        in
        app (Il.Print.string_of_mixop mixop) args

  | UncaseE (case, mixop) ->
      app "_!_" [translate_term case; qid_of_mixop mixop]
      |> from_sequence_element exp.note

  | OptE None ->
      Const "eps"

  | OptE (Some inner) ->
      app "_?" [translate_term inner |> as_sequence_element inner.note]

  | TheE option ->
      app "_!" [translate_term option]
      |> from_sequence_element exp.note

  | StrE fields ->
      fields
      |> List.map (fun (atom, field) ->
           app "item" [qid_of_atom atom; translate_term field])
      |> record_items
      |> fun items -> app "{_}" [items]

  | DotE (record, atom) ->
      app "_._" [translate_term record; qid_of_atom atom]

  | CompE (left, right) ->
      app "_++_" [translate_term left; translate_term right]

  | ListE exps ->
      exps
      |> List.map (fun exp ->
           translate_term exp |> as_sequence_element exp.note)
      |> sequence
      |> fun terms -> app "`[_`]" [terms]

  | LiftE inner ->
      app "lift" [translate_term inner]

  | MemE (element, collection) ->
      app "_<-_" [translate_term element; translate_term collection]
      |> wrap exp.note

  | LenE sequence ->
      app "|_|" [translate_term sequence]

  | CatE (left, right) ->
      app "_++_" [translate_term left; translate_term right]

  | IdxE (sequence, index) ->
      app "_`[_`]" [translate_term sequence; translate_term index]
      |> from_sequence_element exp.note

  | SliceE (sequence, index, length) ->
      app "_`[_:_`]"
        [ translate_term sequence
        ; translate_term index
        ; translate_term length
        ]

  | UpdE (base, path, replacement) ->
      translate_update
        (translate_term base) path (translate_term replacement)

  | ExtE (base, path, extension) ->
      translate_extension
        (translate_term base) path (translate_term extension)

  | IfE (condition, then_exp, else_exp) ->
      app "if_then_else_fi"
        [ translate_term condition |> unwrap condition.note
        ; translate_term then_exp
        ; translate_term else_exp
        ]

  | CallE (id, args) ->
      app (source_name id) (List.map Arg.translate_term args)

  | IterE (body, (iter, generators)) ->
      Iter.translate_term
        translate_term Typ.translate_sort body (iter, generators)

  | CvtE (inner, source, target) ->
      app "_:_<:>_"
        [ translate_term inner
        ; Const (Xl.Num.string_of_typ source)
        ; Const (Xl.Num.string_of_typ target)
        ]

  | SubE (inner, source, target) ->
      app "_:_<:_"
        [ translate_term inner
        ; Typ.translate_term source
        ; Typ.translate_term target
        ]


and translate_select base path =
  match path.it with
  | RootP ->
      base

  | IdxP (parent, index) ->
      app "_`[_`]"
        [ translate_select base parent
        ; translate_term index
        ]
      |> from_sequence_element path.note

  | SliceP (parent, index, length) ->
      app "_`[_:_`]"
        [ translate_select base parent
        ; translate_term index
        ; translate_term length
        ]

  | DotP (parent, atom) ->
      app "_._"
        [ translate_select base parent
        ; qid_of_atom atom
        ]


and translate_update base path replacement =
  match path.it with
  | RootP ->
      replacement

  | IdxP (parent, index) ->
      let parent_value = translate_select base parent in
      let updated_parent =
        app "_`[_=_`]"
          [parent_value; translate_term index; replacement]
      in
      translate_update base parent updated_parent

  | SliceP (parent, index, length) ->
      let parent_value = translate_select base parent in
      let updated_parent =
        app "_`[_:_=_`]"
          [ parent_value
          ; translate_term index
          ; translate_term length
          ; replacement
          ]
      in
      translate_update base parent updated_parent

  | DotP (parent, atom) ->
      let parent_value = translate_select base parent in
      let updated_parent =
        app "_`[._=_`]"
          [parent_value; qid_of_atom atom; replacement]
      in
      translate_update base parent updated_parent


and translate_extension base path extension =
  match path.it with
  | RootP ->
      app "_++_" [base; extension]

  | IdxP (parent, index) ->
      let parent_value = translate_select base parent in
      let extended_parent =
        app "_`[_=++_`]"
          [parent_value; translate_term index; extension]
      in
      translate_update base parent extended_parent

  | SliceP (parent, index, length) ->
      let parent_value = translate_select base parent in
      let extended_parent =
        app "_`[_:_=++_`]"
          [ parent_value
          ; translate_term index
          ; translate_term length
          ; extension
          ]
      in
      translate_update base parent extended_parent

  | DotP (parent, atom) ->
      let parent_value = translate_select base parent in
      let extended_parent =
        app "_`[._=++_`]"
          [parent_value; qid_of_atom atom; extension]
      in
      translate_update base parent extended_parent


let translate = translate_term
