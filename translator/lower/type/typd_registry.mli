val register_constructor :
  Context.t ->
  Origin.t ->
  ?status:Constructor_registry.status ->
  ?construction_domain:Constructor_registry.construction_domain ->
  ?payload_labels:Constructor_registry.payload_label list ->
  ?payload_witnesses:Maude_ir.term list ->
  ?payload_sorts:Maude_ir.sort list ->
  ?static_args_key:string ->
  source_category:string ->
  mixop:Il.Ast.mixop ->
  arity:int ->
  constructor_op:string ->
  projection_ops:string list ->
  unit ->
  Constructor_registry.registration

val register_inclusion :
  Context.t ->
  Origin.t ->
  reason:string ->
  key_env:Static_key.env ->
  ?parent_static_args_key:string ->
  parent_category:string ->
  Il.Ast.typ ->
  unit
