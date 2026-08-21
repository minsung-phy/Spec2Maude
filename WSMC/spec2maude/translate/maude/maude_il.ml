(* Maude International Language *)

type name = string
type sort = string
type label = string


(* Terms *)

type variable =
  { name : name
  ; sort : sort
  ; source : bool
  }

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
