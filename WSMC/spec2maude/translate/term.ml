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

let translate_sort typ =
  match typ.it with
  | NumT `NatT -> "Nat"
  | NumT `IntT -> "Int"
  | IterT _ -> "SpectecTerminals"
  | VarT _
  | BoolT
  | NumT (`RatT | `RealT)
  | TextT
  | TupT _ -> "SpectecTerminal"

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
  qid (Mixop.name mixop)

let source_name id =
  Prescan.sanitize id.it


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


(* Recursive translation *)

let rec translate_typ typ =
  match typ.it with
  | VarT (id, args) ->
      app (source_name id) (List.map translate_arg args)
  | BoolT ->
      Const "bool"
  | NumT numtyp ->
      Const (Xl.Num.string_of_typ numtyp)
  | TextT ->
      Const "text"
  | TupT _ ->
      invalid_arg "TupT must be translated by translate_components"
  | IterT (typ, _) ->
      translate_typ typ

and translate_arg arg =
  match arg.it with
  | ExpA exp ->
      translate_exp exp
  | TypA typ ->
      translate_typ typ
  | DefA id ->
      Const (source_name id)
  | GramA _ ->
      invalid_arg "GramA is not translated"

and translate_exp exp =
  match exp.it with
  | VarE id ->
      Var
        { name = String.uppercase_ascii id.it
        ; sort = translate_sort exp.note
        }

  | BoolE value ->
      app "bool" [Const (string_of_bool value)]

  | NumE value ->
      translate_number value

  | TextE value ->
      translate_text value

  | UnE (`PlusOp, _, inner) ->
      translate_exp inner

  | UnE (op, _, inner) ->
      let operand = translate_exp inner |> unwrap inner.note in
      app (translate_unop op) [operand]
      |> wrap exp.note

  | BinE (op, optyp, left, right) ->
      let left = translate_exp left |> unwrap left.note in
      let right = translate_exp right |> unwrap right.note in
      app (translate_binop op optyp) [left; right]
      |> wrap exp.note

  | CmpE (op, _, left, right) ->
      let left = translate_exp left |> unwrap left.note in
      let right = translate_exp right |> unwrap right.note in
      app (translate_cmpop op) [left; right]
      |> wrap exp.note

  | TupE exps ->
      exps
      |> List.map (fun exp ->
           translate_exp exp |> as_sequence_element exp.note)
      |> sequence
      |> fun terms -> app "tuple" [terms]

  | ProjE (tuple, index) ->
      app "_._" [translate_exp tuple; Const (string_of_int index)]
      |> from_sequence_element exp.note

  | CaseE (mixop, payload) ->
      if is_hole_only mixop then
        translate_exp payload
      else
        let args =
          match payload.it with
          | TupE exps -> List.map translate_exp exps
          | _ -> [translate_exp payload]
        in
        app (Mixop.name mixop) args

  | UncaseE (case, mixop) ->
      app "_!_" [translate_exp case; qid_of_mixop mixop]
      |> from_sequence_element exp.note

  | OptE None ->
      Const "eps"

  | OptE (Some inner) ->
      app "_?" [translate_exp inner |> as_sequence_element inner.note]

  | TheE option ->
      app "_!" [translate_exp option]
      |> from_sequence_element exp.note

  | StrE fields ->
      fields
      |> List.map (fun (atom, field) ->
           app "item" [qid_of_atom atom; translate_exp field])
      |> record_items
      |> fun items -> app "{_}" [items]

  | DotE (record, atom) ->
      app "_._" [translate_exp record; qid_of_atom atom]

  | CompE (left, right) ->
      app "_++_" [translate_exp left; translate_exp right]

  | ListE exps ->
      exps
      |> List.map (fun exp ->
           translate_exp exp |> as_sequence_element exp.note)
      |> sequence
      |> fun terms -> app "`[_`]" [terms]

  | LiftE inner ->
      app "lift" [translate_exp inner]

  | MemE (element, collection) ->
      app "_<-_" [translate_exp element; translate_exp collection]
      |> wrap exp.note

  | LenE sequence ->
      app "|_|" [translate_exp sequence]

  | CatE (left, right) ->
      app "_++_" [translate_exp left; translate_exp right]

  | IdxE (sequence, index) ->
      app "_`[_`]" [translate_exp sequence; translate_exp index]
      |> from_sequence_element exp.note

  | SliceE (sequence, index, length) ->
      app "_`[_:_`]"
        [ translate_exp sequence
        ; translate_exp index
        ; translate_exp length
        ]

  | UpdE (base, path, replacement) ->
      translate_update
        (translate_exp base) path (translate_exp replacement)

  | ExtE (base, path, extension) ->
      translate_extension
        (translate_exp base) path (translate_exp extension)

  | IfE (condition, then_exp, else_exp) ->
      app "if_then_else_fi"
        [ translate_exp condition |> unwrap condition.note
        ; translate_exp then_exp
        ; translate_exp else_exp
        ]

  | CallE (id, args) ->
      app (source_name id) (List.map translate_arg args)

  | IterE (body, (iter, generators)) ->
      Iter.translate_term
        translate_exp translate_sort body (iter, generators)

  | CvtE (inner, source, target) ->
      app "_:_<:>_"
        [ translate_exp inner
        ; Const (Xl.Num.string_of_typ source)
        ; Const (Xl.Num.string_of_typ target)
        ]

  | SubE (inner, source, target) ->
      app "_:_<:_"
        [ translate_exp inner
        ; translate_typ source
        ; translate_typ target
        ]


and translate_bool exp =
  match exp.it with
  | BoolE value ->
      Const (string_of_bool value)

  | UnE (`NotOp, _, inner) ->
      app "~_" [translate_bool inner]

  | BinE (`ImplOp, `BoolT, left, right) ->
      app "_implies_" [translate_bool left; translate_bool right]

  | BinE ((`AndOp | `OrOp | `EquivOp) as op,
          `BoolT, left, right) ->
      app (translate_binop op `BoolT)
        [translate_bool left; translate_bool right]

  | CmpE (op, _, left, right) ->
      app (translate_cmpop op)
        [ translate_exp left |> unwrap left.note
        ; translate_exp right |> unwrap right.note
        ]

  | MemE (element, collection) ->
      app "_<-_" [translate_exp element; translate_exp collection]

  | _ ->
      translate_exp exp |> unwrap exp.note


and translate_select base path =
  match path.it with
  | RootP ->
      base

  | IdxP (parent, index) ->
      app "_`[_`]"
        [ translate_select base parent
        ; translate_exp index
        ]
      |> from_sequence_element path.note

  | SliceP (parent, index, length) ->
      app "_`[_:_`]"
        [ translate_select base parent
        ; translate_exp index
        ; translate_exp length
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
          [parent_value; translate_exp index; replacement]
      in
      translate_update base parent updated_parent

  | SliceP (parent, index, length) ->
      let parent_value = translate_select base parent in
      let updated_parent =
        app "_`[_:_=_`]"
          [ parent_value
          ; translate_exp index
          ; translate_exp length
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
          [parent_value; translate_exp index; extension]
      in
      translate_update base parent extended_parent

  | SliceP (parent, index, length) ->
      let parent_value = translate_select base parent in
      let extended_parent =
        app "_`[_:_=++_`]"
          [ parent_value
          ; translate_exp index
          ; translate_exp length
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


(* Constructor components *)

let translate_typ_conditions value typ =
  match typ.it with
  | NumT (`NatT | `IntT) ->
      []
  | IterT (element_typ, iter) ->
      Iter.translate_conditions
        translate_exp value (translate_typ element_typ) iter
  | _ ->
      [BoolCond (app "typecheck" [value; translate_typ typ])]

let make_component name typ =
  let sort = translate_sort typ in
  let value = Var {name; sort} in
  let conditions = translate_typ_conditions value typ in
  value, sort, conditions

let component_name index id =
  if id.it = "_" then
    "VALUE" ^ string_of_int (index + 1)
  else
    String.uppercase_ascii id.it

let translate_components typ =
  match typ.it with
  | TupT fields ->
      fields
      |> List.mapi (fun index (id, typ) ->
           make_component (component_name index id) typ)
  | _ ->
      [make_component "VALUE" typ]
