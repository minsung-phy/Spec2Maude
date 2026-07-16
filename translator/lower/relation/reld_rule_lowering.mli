val gen : Origin.t -> Maude_ir.statement_node -> Maude_ir.generated
val app : string -> Maude_ir.term list -> Maude_ir.term

val rule_origin : Origin.t -> int -> Il.Ast.rule -> Origin.t
val rule_label : Il.Ast.id -> Il.Ast.id -> int -> string

val validate_rule_marker :
  Context.t ->
  Origin.t ->
  expected_kind:Analysis.Relation_graph.relation_kind ->
  expected_mixop:Il.Ast.mixop ->
  Il.Ast.rule ->
  Diagnostics.t list

val validate_rule_premise_marker :
  Context.t ->
  Origin.t ->
  expected_kind:Analysis.Relation_graph.relation_kind ->
  expected_mixop:Il.Ast.mixop ->
  Il.Ast.prem ->
  Il.Ast.mixop ->
  Diagnostics.t list

val component_sort :
  Context.t ->
  Origin.t ->
  string ->
  Il.Ast.typ ->
  Maude_ir.sort option * Diagnostics.t list

val component_sorts :
  Context.t ->
  Origin.t ->
  string ->
  Il.Ast.typ list ->
  Maude_ir.sort list option * Diagnostics.t list

val tuple_carrier : Maude_ir.sort list -> Maude_ir.term list -> Maude_ir.term
val execution_output_sort : Maude_ir.sort list -> Maude_ir.sort
val relation_conf_sort : Il.Ast.id -> Maude_ir.sort
val frozen_all : int -> Maude_ir.attr list

val translate_rule_binds :
  Context.t ->
  Origin.t ->
  Local_name.t ->
  Il.Ast.quant list ->
  Expr_env.t * Maude_ir.generated list * Diagnostics.t list * Local_name.t

val add_introduced_bindings :
  Expr_env.t ->
  (string * Expr_env.binding) list ->
  Expr_env.t

val add_safe_introduced_bindings :
  Expr_env.t ->
  Maude_ir.term list ->
  Maude_ir.eq_condition list ->
  (string * Expr_env.binding) list ->
  Expr_env.t

val exp_components_match :
  Context.t ->
  Origin.t ->
  string ->
  Il.Ast.typ list ->
  Il.Ast.exp ->
  Il.Ast.exp list option * Diagnostics.t list

val local_names_for_rule : Il.Ast.rule -> Local_name.t
val local_names_for_rule_parts :
  Il.Ast.quant list -> Il.Ast.exp -> Il.Ast.prem list -> Local_name.t

val lower_pattern_components_named :
  Local_name.t ->
  Context.t ->
  Expr_env.t ->
  Origin.t ->
  Il.Ast.exp list ->
  (Maude_ir.term list option
   * Maude_ir.eq_condition list
   * (string * Expr_env.binding) list
   * Diagnostics.t list)
  * Local_name.t

val lower_value_components :
  Context.t ->
  Expr_env.t ->
  Origin.t ->
  string ->
  Il.Ast.exp list ->
  Maude_ir.term list option * Maude_ir.eq_condition list * Diagnostics.t list

val relation_call : string -> Maude_ir.term list -> Maude_ir.term

val generated_statement_diagnostics :
  ?pattern_certificate:Condition_pattern_certificate.t ->
  Context.t -> Maude_ir.generated -> Diagnostics.t list

val rule_hint_diagnostics :
  Context.t -> Origin.t -> string -> Il.Ast.id -> Diagnostics.t list
