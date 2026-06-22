type sort
type kind

type type_ref =
  | SortRef of sort
  | KindRef of kind

type label = string

type term =
  | Var of string
  | Const of string
  | Qid of string
  | App of string * term list

type attr =
  | Assoc
  | Comm
  | Ctor
  | Id of term
  | Frozen of int list

type eq_attr =
  | Owise

type op_kind =
  | Total
  | Partial

type op_decl =
  { name : string
  ; args : type_ref list
  ; result : sort
  ; kind : op_kind
  ; attrs : attr list
  }

type var_decl =
  { name : string
  ; type_ref : type_ref
  }

type eq_condition =
  | EqCond of term * term
  | MatchCond of term * term
  | MembershipCond of term * sort
  | BoolCond of term

type rule_condition =
  | EqCondition of eq_condition
  | RewriteCond of term * term

type statement_node = private
  | SortDecl of sort
  | SubsortDecl of sort * sort
  | OpDecl of op_decl
  | VarDecl of var_decl
  | Mb of term * sort
  | Cmb of term * sort * eq_condition list
  | Eq of term * term * eq_attr list
  | Ceq of term * term * eq_condition list * eq_attr list
  | Rl of label option * term * term
  | Crl of label option * term * term * rule_condition list

type provenance =
  | Prelude
  | Source
  | Helper of string

type generated =
  { node : statement_node
  ; origin : Origin.t
  ; provenance : provenance
  }

type import =
  | Protecting of string
  | Including of string
  | Extending of string

type module_kind =
  | Functional
  | System

type module_ =
  { name : string
  ; kind : module_kind
  ; imports : import list
  ; statements : generated list
  }

val mixfix_placeholder_count : string -> int
val sanitize_label : label -> label

val sort : string -> sort
val kind_of_sort : sort -> kind
val sort_name : sort -> string
val kind_sort : kind -> sort
val sort_ref : sort -> type_ref
val kind_ref : kind -> type_ref

val sort_decl : sort -> statement_node
val subsort : sort -> sort -> statement_node
val op : ?kind:op_kind -> ?attrs:attr list -> string -> type_ref list -> sort -> statement_node
val var : string -> type_ref -> statement_node
val mb : term -> sort -> statement_node
val cmb : term -> sort -> eq_condition list -> statement_node
val eq : ?attrs:eq_attr list -> term -> term -> statement_node
val ceq : ?attrs:eq_attr list -> term -> term -> eq_condition list -> statement_node
val rl : ?label:label -> term -> term -> statement_node
val crl : ?label:label -> term -> term -> rule_condition list -> statement_node

val generated :
  ?provenance:provenance ->
  origin:Origin.t ->
  statement_node ->
  generated
