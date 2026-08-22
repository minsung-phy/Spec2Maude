(* Maude International Language *)

type name = string
type sort = string
type label = string


(* Terms *)

type variable_origin =
  | Source
  | Generated of int

type variable =
  { name : name
  ; sort : sort
  ; origin : variable_origin
  }

let generated_variable_count = ref 0

let source_variable name sort =
  {name; sort; origin = Source}

let generated_variable name sort =
  incr generated_variable_count;
  {name; sort; origin = Generated !generated_variable_count}

let same_variable left right =
  match left.origin, right.origin with
  | Source, Source -> left.name = right.name && left.sort = right.sort
  | Generated left, Generated right -> left = right
  | Source, Generated _ | Generated _, Source -> false

type term =
  | Var of variable
  | Const of string
  | App of name * term list


(* Operator declarations *)

type arrow =
  | Total
  | Partial

type op_attr =
  | Ctor
  | Assoc
  | Comm
  | Id of term
  | Frozen of int list

type op_decl =
  { name : name
  ; domain : sort list
  ; codomain : sort
  ; arrow : arrow
  ; attrs : op_attr list
  }


(* Conditions for equations and memberships *)

type eq_condition =
  | EqCond of term * term
  | MatchCond of term * term
  | MembershipCond of term * sort
  | BoolCond of term


(* Conditions for rewrite rules *)

type rule_condition =
  | EqCondition of eq_condition
  | RewriteCond of term * term


(* Equation attributes *)

type eq_attr =
  | Owise


(* Maude statements *)

type statement =
  | SortDecl of sort
  | SubsortDecl of sort * sort
  | VarDecl of name list * sort

  | OpDecl of op_decl

  | Mb of term * sort
  | Cmb of term * sort * eq_condition list

  | Eq of term * term * eq_attr list
  | Ceq of term * term * eq_condition list * eq_attr list

  | Rl of label option * term * term
  | Crl of label option * term * term * rule_condition list


(* Variable traversal *)

let rec map_term_variables map = function
  | Var variable -> Var (map variable)
  | Const _ as term -> term
  | App (name, args) -> App (name, List.map (map_term_variables map) args)

let map_eq_condition_variables map = function
  | EqCond (left, right) ->
      EqCond (map_term_variables map left, map_term_variables map right)
  | MatchCond (left, right) ->
      MatchCond (map_term_variables map left, map_term_variables map right)
  | MembershipCond (term, sort) ->
      MembershipCond (map_term_variables map term, sort)
  | BoolCond term -> BoolCond (map_term_variables map term)

let map_rule_condition_variables map = function
  | EqCondition condition ->
      EqCondition (map_eq_condition_variables map condition)
  | RewriteCond (left, right) ->
      RewriteCond (map_term_variables map left, map_term_variables map right)

let map_statement_variables map = function
  | (SortDecl _ | SubsortDecl _ | VarDecl _) as statement -> statement
  | OpDecl declaration ->
      let attrs =
        List.map
          (function
            | Id term -> Id (map_term_variables map term)
            | (Ctor | Assoc | Comm | Frozen _) as attr -> attr)
          declaration.attrs
      in
      OpDecl {declaration with attrs}
  | Mb (term, sort) -> Mb (map_term_variables map term, sort)
  | Cmb (term, sort, conditions) ->
      Cmb
        ( map_term_variables map term
        , sort
        , List.map (map_eq_condition_variables map) conditions
        )
  | Eq (left, right, attrs) ->
      Eq (map_term_variables map left, map_term_variables map right, attrs)
  | Ceq (left, right, conditions, attrs) ->
      Ceq
        ( map_term_variables map left
        , map_term_variables map right
        , List.map (map_eq_condition_variables map) conditions
        , attrs
        )
  | Rl (label, left, right) ->
      Rl (label, map_term_variables map left, map_term_variables map right)
  | Crl (label, left, right, conditions) ->
      Crl
        ( label
        , map_term_variables map left
        , map_term_variables map right
        , List.map (map_rule_condition_variables map) conditions
        )


(* Maude modules *)

type import =
  | Protecting of name
  | Including of name
  | Extending of name

type module_kind =
  | Functional
  | System

type modul =
  { name : name
  ; kind : module_kind
  ; imports : import list
  ; statements : statement list
  }


(* Translation result *)

type t = statement list

let empty = []

let concat results =
  List.concat results
