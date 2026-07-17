type t
type stage

val create :
  ?runtime_ingress_contract:Runtime_ingress_contract.t ->
  ?backend_name:string ->
  Analysis.Source_index.t ->
  Builtin_registry.t ->
  t
val profile_name : t -> string
val runtime_ingress_contract : t -> Runtime_ingress_contract.t
val helpers : t -> Helper.t
val begin_stage : t -> stage
val staged : stage -> t
val commit_stage : stage -> unit
val constructors : t -> Constructor_registry.t
val builtins : t -> Builtin_registry.t
val definition_op : t -> Il.Ast.id -> string
val specialized_definition_op :
  t -> Il.Ast.id -> Analysis.Function_graph.specialization -> string
val with_builtins : t -> Builtin_registry.t -> t
val source_index : t -> Analysis.Source_index.t
val il_env : t -> Il.Env.t
val function_graph : t -> Analysis.Function_graph.t
val runtime_ingress_validation : t -> Runtime_ingress_validation.t
val use_runtime_ingress_attestation :
  t -> Runtime_ingress_contract.attestation -> unit
val unused_runtime_ingress_attestations :
  t -> Runtime_ingress_contract.attestation list
val static_typ_env : t -> (string * Il.Ast.typ) list
val with_static_typ : t -> string -> Il.Ast.typ -> t
val find_static_typ : t -> string -> Il.Ast.typ option
val static_def_env : t -> (string * string) list
val with_static_def : t -> string -> string -> t
val find_static_def : t -> string -> string option
val with_phantom_typ : t -> string -> string -> t
val find_phantom_typ : t -> string -> string option
val with_specialization : t -> Analysis.Function_graph.specialization -> t
val current_specialization : t -> Analysis.Function_graph.specialization option
val with_runtime_relation_use : t -> string -> string -> t
val runtime_relation_use_reason : t -> string -> string option
val record_definition_call :
  t -> Maude_ir.term -> Analysis.Function_graph.definition_identity -> unit
val definition_call_identities :
  t -> Maude_ir.term -> Analysis.Function_graph.definition_identity list
val emitted_definition_operator : t -> string -> bool
val record_certificates : t -> Record_certificate.t
val with_def : t -> string -> t
val with_rule : t -> string -> t
val with_clause : t -> string -> t
val enclosing_path : t -> string list
