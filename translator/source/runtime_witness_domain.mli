type candidate =
  { relation_id : string
  ; premise : Il.Ast.prem
  ; prefix_arity : int
  ; witness_source_id : string
  ; source_echo : string option
  }

type candidate_source =
  | Query_inputs
  | Rule_head_closed_terms
  | Witness_category_zero_arity_constructors
  | Prefix_finite_indexed_fields
  | Deterministic_source_closure

type t =
  { proof : Runtime_witness_proof.closed_world_domain
  ; candidate : candidate
  ; cycle_rel_ids : string list
  ; fuel_source_ids : string list
  ; visited_key_source_ids : string list
  ; candidate_sources : candidate_source list
  }

type blocker =
  { origin : Origin.t
  ; constructor : string
  ; ast_constructor : string
  ; relation_id : string
  ; rule_id : string option
  ; premise_index : int option
  ; premise_context : string option
  ; reason : string
  ; suggestion : string
  ; source_echo : string option
  }

val prepare :
  Runtime_witness_proof.closed_world_domain ->
  (t, blocker list) result

val describe : t -> string
val describe_candidate_sources : t -> string
