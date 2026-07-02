type profile =
  | Runtime_after_external_validation

type t

val string_of_profile : profile -> string
val create : ?profile:profile -> Analysis.Source_index.t -> t
val profile_name : t -> string
val helpers : t -> Helper.t
val constructors : t -> Constructor_registry.t
val source_index : t -> Analysis.Source_index.t
val function_graph : t -> Analysis.Function_graph.t
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
val with_def : t -> string -> t
val with_rule : t -> string -> t
val with_clause : t -> string -> t
val enclosing_path : t -> string list
