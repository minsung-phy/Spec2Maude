type phase =
  | Goal
  | Optional
  | List
  | List1
  | List_indexed

type blocker =
  { relation_id : string
  ; rule_id : string option
  ; origin : Origin.t
  ; constructor : string
  ; reason : string
  ; suggestion : string
  ; source_echo : string option
  }

type premise =
  | Finite_rule_call of
      { relation_id : string
      ; premise : Il.Ast.prem
      }
  | Finite_domain_call of Il.Ast.prem
  | Finite_successor_call of
      { relation_id : string
      ; introduced : string list
      ; premise : Il.Ast.prem
      }
  | Deterministic_total of Il.Ast.prem
  | Externally_validated of Il.Ast.prem
  | Source_boolean of Il.Ast.prem
  | Deterministic_binding_iter of Il.Ast.prem
  | Finite_iter of
      { phase : phase
      ; premise : Il.Ast.prem
      ; body : premise list
      }

type rule =
  { source : Analysis.Function_graph.runtime_search_rule
  ; premises : premise list
  ; schedule : int list
  }

type scc =
  { index : int
  ; relations : string list
  ; rules : rule list
  }

type t =
  { root_relation : string
  ; closure : string list
  ; sccs : scc list
  ; successor_domains : Runtime_truth_successor_domain.t list
  ; blockers : blocker list
  }

val plan :
  ?total_value:(bound:string list -> Il.Ast.exp -> bool) ->
  ?total_value_with_facts:
    (facts:Runtime_truth_successor_domain.total_fact list ->
     bound:string list -> Il.Ast.exp -> bool) ->
  ?constructors:Constructor_registry.t ->
  ?resolve_constructor:
    (Il.Ast.typ -> Il.Ast.mixop -> int -> Constructor_registry.entry option) ->
  Analysis.Function_graph.t -> string -> t
val complete : t -> bool
val decision_complete : t -> bool
val find_scc : t -> string -> scc option
val scheduled_premises : rule -> (int * premise) list
val successor_domain :
  t ->
  Runtime_witness_proof.transitive_domain ->
  Runtime_truth_successor_domain.t option
val phase_key : phase -> string
