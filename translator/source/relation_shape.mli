type component =
  { payload : Il.Ast.exp option
  ; typ : Il.Ast.typ
  }

type deterministic_shape =
  { inputs : component list
  ; output : component
  }

type execution_shape =
  { star : bool
  ; inputs : component list
  ; outputs : component list
  }

type decision =
  | Static_validation of string
  | Runtime_predicate of string
  | Deterministic_candidate of deterministic_shape
  | Execution of execution_shape
  | Unknown of string

type t =
  { marker : Analysis.Relation_graph.relation_kind
  ; marker_text : string
  ; mixop : Il.Ast.mixop option
  ; result : Il.Ast.typ
  ; components : component list
  ; decision : decision
  }

val of_kind : Analysis.Relation_graph.relation_kind -> Il.Ast.typ -> t
val of_relation : Analysis.Function_graph.relation -> t
val of_reld : Il.Ast.mixop -> Il.Ast.typ -> t
val component_typs : component list -> Il.Ast.typ list
val decision_name : decision -> string
