val predecessor_matches_current :
  Maude_ir.term list -> Maude_ir.term list -> bool

val predecessor_refines_constructor :
  Maude_ir.term list -> Maude_ir.term list -> bool

val specialize_terms :
  Maude_ir.term list ->
  Maude_ir.term list ->
  Maude_ir.term list ->
  Maude_ir.term list option

type complement_result =
  | Complete of
      { alternatives : Maude_ir.rule_condition list list
      ; statements : Maude_ir.generated list
      }
  | Blocked of string list

type condition_block =
  | Source_conditions of Maude_ir.eq_condition list
  | Head_domain_conditions of Maude_ir.eq_condition list

val sequential_complement_alternatives :
  Maude_ir.term list ->
  Maude_ir.eq_condition list ->
  complement_result

val certified_sequential_complement_alternatives :
  ?lhs_conditions:Maude_ir.eq_condition list ->
  Constructor_registry.t ->
  origin:Origin.t ->
  helper_name:string ->
  condition_certificates:Source_condition_certificate.t list ->
  condition_failures:Source_condition_certificate.proof_failure list ->
  Maude_ir.term list ->
  Maude_ir.eq_condition list ->
  complement_result

val direct_complement_alternatives :
  Constructor_registry.t ->
  origin:Origin.t ->
  helper_name:string ->
  current_head_conditions:Maude_ir.eq_condition list ->
  predecessor_head_conditions:Maude_ir.eq_condition list ->
  condition_blocks:condition_block list ->
  head_domain_failures:string list ->
  condition_certificates:Source_condition_certificate.t list ->
  condition_failures:Source_condition_certificate.proof_failure list ->
  Maude_ir.term list ->
  Maude_ir.term list ->
  Maude_ir.eq_condition list ->
  complement_result
