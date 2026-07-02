type source_rule =
  { relation_id : string
  ; rule_id : string option
  ; origin : Origin.t
  ; source_echo : string option
  ; head : Il.Ast.exp
  ; prems : Il.Ast.prem list
  }

type transitive_domain =
  { rule : source_rule
  ; domain_rel_id : string
  ; witness_source_id : string
  ; prefix_arity : int
  ; domain_premise : Il.Ast.prem
  ; left_premise : Il.Ast.prem
  ; right_premise : Il.Ast.prem
  }

type finite_domain_plan =
  { cycle_rel_ids : string list
  ; candidate_source_ids : string list
  ; domain_premise : Il.Ast.prem
  ; fuel_measure : string
  ; visited_key_source_ids : string list
  }

type closed_world_domain =
  { transitive : transitive_domain
  ; domain_plan : finite_domain_plan
  ; policy : string
  ; fuel_source_ids : string list
  ; visited_key_source_ids : string list
  }

type target_chain =
  { rule : source_rule
  ; target_rel_id : string
  ; witness_source_id : string
  ; prefix_arity : int
  ; recursive_premise : Il.Ast.prem
  ; target_premise : Il.Ast.prem
  ; guard_premises : Il.Ast.prem list
  }

type recursion =
  | Acyclic
  | Finite_transitive of closed_world_domain
  | Target_guided_self of target_chain

type t

val acyclic : t
val finite_transitive : closed_world_domain -> t
val target_guided_self : target_chain -> t
val closed_world_domain :
  ?cycle_rel_ids:string list ->
  transitive_domain ->
  closed_world_domain
val key : t -> string
val recursion : t -> recursion

val transitive_domain : source_rule -> transitive_domain option
val has_transitive_domain : source_rule list -> bool
val target_chain : source_rule -> target_chain option
