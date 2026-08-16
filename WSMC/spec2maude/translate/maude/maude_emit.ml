open Maude_il


(* Common *)

let join separator strings =
  String.concat separator strings

let indent text =
  text
  |> String.split_on_char '\n'
  |> List.map (fun line -> "  " ^ line)
  |> join "\n"


(* Terms *)

let emit_variable (variable : variable) =
  variable.name ^ ":" ^ variable.sort

let rec emit_term = function
  | Var variable ->
      emit_variable variable

  | Const text ->
      text

  | App ("_ _", terms) ->
      terms
      |> List.map emit_term
      |> join " "

  | App (name, []) ->
      name

  | App (name, args) ->
      let args =
        args
        |> List.map emit_term
        |> join ", "
      in
      name ^ "(" ^ args ^ ")"


(* Operator declarations *)

let emit_arrow = function
  | Total -> "->"
  | Partial -> "~>"

let emit_op_attr = function
  | Ctor ->
      "ctor"

  | Assoc ->
      "assoc"

  | Comm ->
      "comm"

  | Id term ->
      "id: " ^ emit_term term

  | Frozen positions ->
      let positions =
        positions
        |> List.map string_of_int
        |> join " "
      in
      "frozen (" ^ positions ^ ")"

let emit_op_attrs attrs =
  match attrs with
  | [] ->
      ""

  | _ ->
      let attrs =
        attrs
        |> List.map emit_op_attr
        |> join " "
      in
      " [" ^ attrs ^ "]"

let emit_op_decl (decl : op_decl) =
  let domain =
    match decl.domain with
    | [] ->
        ""

    | sorts ->
        join " " sorts ^ " "
  in
  "op " ^ decl.name
  ^ " : "
  ^ domain
  ^ emit_arrow decl.arrow
  ^ " "
  ^ decl.codomain
  ^ emit_op_attrs decl.attrs
  ^ " ."


(* Conditions *)

let emit_eq_condition = function
  | EqCond (left, right) ->
      emit_term left ^ " = " ^ emit_term right

  | MatchCond (pattern, subject) ->
      emit_term pattern ^ " := " ^ emit_term subject

  | MembershipCond (term, sort) ->
      emit_term term ^ " : " ^ sort

  | BoolCond term ->
      "(" ^ emit_term term ^ ") = true"

let emit_rule_condition = function
  | EqCondition condition ->
      emit_eq_condition condition

  | RewriteCond (left, right) ->
      emit_term left ^ " => " ^ emit_term right

let emit_conditions emit_condition conditions =
  conditions
  |> List.map emit_condition
  |> join "\n    /\ "


(* Equation attributes *)

let emit_eq_attr = function
  | Owise ->
      "owise"

let emit_eq_attrs attrs =
  match attrs with
  | [] ->
      ""

  | _ ->
      let attrs =
        attrs
        |> List.map emit_eq_attr
        |> join " "
      in
      " [" ^ attrs ^ "]"


(* Rule labels *)

let emit_rule_head keyword = function
  | None ->
      keyword

  | Some label ->
      keyword ^ " [" ^ label ^ "] :"


(* Statements *)

let rec emit_statement = function
  | SortDecl sort ->
      "sort " ^ sort ^ " ."

  | SubsortDecl (lower, upper) ->
      "subsort " ^ lower ^ " < " ^ upper ^ " ."

  | VarDecl (names, sort) ->
      let keyword =
        match names with
        | [_] -> "var"
        | _ -> "vars"
      in
      keyword ^ " " ^ join " " names ^ " : " ^ sort ^ " ."

  | OpDecl decl ->
      emit_op_decl decl

  | Mb (term, sort) ->
      "mb " ^ emit_term term ^ " : " ^ sort ^ " ."

  | Cmb (term, sort, []) ->
      emit_statement (Mb (term, sort))

  | Cmb (term, sort, conditions) ->
      "cmb " ^ emit_term term ^ " : " ^ sort
      ^ "\n  if "
      ^ emit_conditions emit_eq_condition conditions
      ^ " ."

  | Eq (left, right, attrs) ->
      "eq " ^ emit_term left
      ^ " = " ^ emit_term right
      ^ emit_eq_attrs attrs
      ^ " ."

  | Ceq (left, right, [], attrs) ->
      emit_statement (Eq (left, right, attrs))

  | Ceq (left, right, conditions, attrs) ->
      "ceq " ^ emit_term left
      ^ " = " ^ emit_term right
      ^ "\n  if "
      ^ emit_conditions emit_eq_condition conditions
      ^ emit_eq_attrs attrs
      ^ " ."

  | Rl (label, left, right) ->
      emit_rule_head "rl" label
      ^ " "
      ^ emit_term left
      ^ " => "
      ^ emit_term right
      ^ " ."

  | Crl (label, left, right, []) ->
      emit_statement (Rl (label, left, right))

  | Crl (label, left, right, conditions) ->
      emit_rule_head "crl" label
      ^ " "
      ^ emit_term left
      ^ " => "
      ^ emit_term right
      ^ "\n  if "
      ^ emit_conditions emit_rule_condition conditions
      ^ " ."


(* Imports *)

let emit_import = function
  | Protecting name ->
      "protecting " ^ name ^ " ."

  | Including name ->
      "including " ^ name ^ " ."

  | Extending name ->
      "extending " ^ name ^ " ."


(* Statement lists *)

let emit statements =
  statements
  |> List.map emit_statement
  |> join "\n\n"


(* Modules *)

let emit_module (modul : modul) =
  let opening, closing =
    match modul.kind with
    | Functional -> "fmod", "endfm"
    | System -> "mod", "endm"
  in

  let imports =
    modul.imports
    |> List.map emit_import
    |> join "\n"
  in

  let statements =
    emit modul.statements
  in

  let body =
    [imports; statements]
    |> List.filter (fun text -> text <> "")
    |> join "\n\n"
    |> indent
  in

  if body = "" then
    opening ^ " " ^ modul.name ^ " is\n"
    ^ closing
  else
    opening ^ " " ^ modul.name ^ " is\n"
    ^ body ^ "\n"
    ^ closing
