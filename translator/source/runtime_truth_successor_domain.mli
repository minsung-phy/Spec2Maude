type binding_domain =
  | Total
  | Zero_or_one

type binding =
  { premise : Il.Ast.prem
  ; pattern : Il.Ast.exp
  ; value : Il.Ast.exp
  ; domain : binding_domain
  }

type producer =
  | Direct of
      { rule : Analysis.Function_graph.runtime_search_rule
      ; successor : Il.Ast.exp
      }
  | Query_endpoint of
      { rule : Analysis.Function_graph.runtime_search_rule
      ; successor : Il.Ast.exp
      }
  | Projection of
      { rule : Analysis.Function_graph.runtime_search_rule
      ; premise : Il.Ast.prem
      ; successor : Il.Ast.exp
      }
  | Indexed of
      { entry_rule : Analysis.Function_graph.runtime_search_rule
      ; rule : Analysis.Function_graph.runtime_search_rule
      ; prefix : Il.Ast.prem list
      ; bindings : binding list
      ; source : Il.Ast.exp
      ; index_source_id : string
      ; successor : Il.Ast.exp
      }
  | Indexed_constructor of
      { rule : Analysis.Function_graph.runtime_search_rule
      ; prefix : Il.Ast.prem list
      ; source : Il.Ast.exp
      ; index_source_id : string
      ; index_typ : Il.Ast.typ
      ; successor : Il.Ast.exp
      }
  | Delegated of
      { entry_rule : Analysis.Function_graph.runtime_search_rule
      ; premise : Il.Ast.prem
      ; relation_id : string
      ; producers : producer list
      }

type domain_candidate =
  | Closed_term of Il.Ast.exp
  | Closed_constructor of string
  | Indexed_domain of
      { source : Il.Ast.exp
      ; index_source_id : string
      ; index_typ : Il.Ast.typ
      ; index_constructor : string option
      ; witness : Il.Ast.exp
      }

type total_fact =
  | Validated_sequence_index of
      { source : Il.Ast.exp
      ; index_source_id : string
      ; index_typ : Il.Ast.typ
      ; index_constructor : string option
      ; witness : Il.Ast.exp
      }

type coverage =
  { relation_id : string
  ; source_rules : Source_rule_identity.rule list
  }

type t =
  { transitive : Runtime_witness_proof.transitive_domain
  ; producers : producer list
  ; domain_candidates : domain_candidate list
  ; total_facts : total_fact list
  ; decision_coverage : coverage option
  }

type blocker =
  { relation_id : string
  ; rule_id : string option
  ; origin : Origin.t
  ; constructor : string
  ; reason : string
  ; suggestion : string
  ; source_echo : string option
  }

type decision =
  | Materialized of t
  | Blocked of blocker list

val certify :
  ?source_total:(bound:string list -> Il.Ast.exp -> bool) ->
  ?source_zero_or_one:(bound:string list -> Il.Ast.exp -> bool) ->
  ?source_total_with_facts:
    (facts:total_fact list -> bound:string list -> Il.Ast.exp -> bool) ->
  ?constructors:Constructor_registry.t ->
  ?resolve_constructor:
    (Il.Ast.typ -> Il.Ast.mixop -> int -> Constructor_registry.entry option) ->
  Analysis.Function_graph.t ->
  Runtime_witness_proof.transitive_domain ->
  decision

val matches : t -> Runtime_witness_proof.transitive_domain -> bool
val decision_complete : t -> bool
val key : t -> string
