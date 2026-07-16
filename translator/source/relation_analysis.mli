type relation =
  { identity : Source_rule_identity.relation
  ; id : string
  ; origin : Origin.t
  ; source_params : Il.Ast.param list
  ; kind : Relation_graph.relation_kind
  ; mixop : Il.Ast.mixop
  ; result : Il.Ast.typ
  ; rule_count : int
  ; hints : string list
  ; maude_equational_view : bool
  ; external_validation_shape : bool
  }

type rule_hint =
  { relation_id : string
  ; rule_id : string
  ; origin : Origin.t
  ; hints : Il.Ast.hint list
  }

type runtime_search_blocker =
  { relation_id : string
  ; rule_id : string option
  ; origin : Origin.t option
  ; constructor : string
  ; reason : string
  ; suggestion : string
  ; source_echo : string option
  ; premise_origin : Origin.t option
  ; premise_constructor : string option
  ; premise_source_echo : string option
  }

type runtime_search_rule =
  { identity : Source_rule_identity.rule
  ; relation_id : string
  ; relation_result : Il.Ast.typ
  ; rule_id : string option
  ; origin : Origin.t
  ; source_echo : string option
  ; binds : Il.Ast.quant list
  ; mixop : Il.Ast.mixop
  ; head : Il.Ast.exp
  ; prems : Il.Ast.prem list
  }

type runtime_predicate_search_plan =
  | Runtime_search_no_shape_blockers of
      { closure : string list
      ; rules : runtime_search_rule list
      }
  | Runtime_search_blocked_plan of
      { closure : string list
      ; rules : runtime_search_rule list
      ; blockers : runtime_search_blocker list
      }

type runtime_predicate_dependency_completeness =
  | Runtime_predicate_dependencies_complete of
      { closure : string list
      }
  | Runtime_predicate_dependencies_incomplete of
      { closure : string list
      ; rules : runtime_search_rule list
      ; blockers : runtime_search_blocker list
      }

type relation_body =
  { relation_id : Il.Ast.id
  ; relation_origin : Origin.t
  ; relation_params : Il.Ast.param list
  ; relation_rules : Il.Ast.rule list
  }

type t

val build : Source_index.t -> t
val relations : t -> relation list
val relation_bodies : t -> relation_body list
val find_relation : t -> string -> relation option
val rule_hints : t -> relation_id:string -> rule_id:string -> rule_hint option
val relation_has_maude_equational_view : relation -> bool
val compute_runtime_demands : t -> (string * string) list -> unit
val relation_runtime_demand_reason : t -> string -> string option
val relation_is_runtime_demanded : t -> string -> bool
val runtime_predicate_search_plan : t -> string -> runtime_predicate_search_plan
val runtime_predicate_truth_plan : t -> string -> runtime_predicate_search_plan
val runtime_relation_rules : t -> string -> runtime_search_rule list option
val runtime_predicate_dependency_completeness :
  t -> string -> runtime_predicate_dependency_completeness
