val source_echo_of_def : Il.Ast.def -> string
val constructor_of_def : Il.Ast.def -> string
val id_of_def : Il.Ast.def -> string option

module Source_index : sig
  type entry =
    { ordinal : int
    ; id : string option
    ; constructor : string
    ; origin : Origin.t
    ; def : Il.Ast.def
    }

  type t

  val of_script : Il.Ast.script -> t
  val entries : t -> entry list
  val find_by_id : t -> string -> entry list
end

module Relation_graph : sig
  type relation_kind =
    | Execution
    | Execution_star
    | Deterministic_candidate
    | Predicate_candidate
    | Unknown

  val string_of_relation_kind : relation_kind -> string
  val classify_mixop : Il.Ast.mixop -> relation_kind
  val string_of_mixop : Il.Ast.mixop -> string
  val eq_mixop : Il.Ast.mixop -> Il.Ast.mixop -> bool
  val mixop_shape_text : Il.Ast.mixop -> string
  val exp_components : Il.Ast.exp -> Il.Ast.exp list
  val exp_components_for_count : int -> Il.Ast.exp -> Il.Ast.exp list option
end

module Function_graph : sig
  type param_kind =
    | Runtime_exp
    | Static_typ
    | Static_def
    | Static_gram

  type definition =
    { id : string
    ; origin : Origin.t
    ; params : param_kind list
    ; result : Il.Ast.typ
    ; clause_count : int
    }

  type relation =
    { id : string
    ; origin : Origin.t
    ; kind : Relation_graph.relation_kind
    ; mixop : Il.Ast.mixop
    ; result : Il.Ast.typ
    ; rule_count : int
    }

  type relation_demand =
    { id : string
    ; reason : string
    }

  type static_typ_binding =
    { param_id : string
    ; typ : Il.Ast.typ
    ; key : string
    }

  type static_def_binding =
    { param_id : string
    ; target_id : string
    ; key : string
    }

  type specialization =
    { def_id : string
    ; key_components : string list
    ; static_typs : static_typ_binding list
    ; static_defs : static_def_binding list
    ; origin : Origin.t
    }

  type violation =
    { origin : Origin.t
    ; constructor : string
    ; reason : string
    ; suggestion : string option
    ; source_echo : string option
    }

  type call_resolution =
    | Plain_call
    | Specialized_call of specialization
    | Unsupported_call of string
    | Prelude_gap_call of string

  type t

  val build : Source_index.t -> t
  val violations : t -> violation list
  val diagnostics : profile:string -> t -> Diagnostics.t list
  val definitions : t -> definition list
  val relations : t -> relation list
  val find_definition : t -> string -> definition option
  val find_relation : t -> string -> relation option
  val relation_runtime_demand_reason : t -> string -> string option
  val relation_is_runtime_demanded : t -> string -> bool
  val definition_has_static_params : definition -> bool
  val specializations_for : t -> string -> specialization list
  val has_specialization : t -> specialization -> bool
  val resolve_call :
    t ->
    static_typ_env:(string * Il.Ast.typ) list ->
    static_def_env:(string * string) list ->
    origin:Origin.t ->
    Il.Ast.id ->
    Il.Ast.arg list ->
    call_resolution
  val typ_static_key : Il.Ast.typ -> string option
  val typ_static_key_with_env : (string * Il.Ast.typ) list -> Il.Ast.typ -> string option
end

module Profile_policy : sig
  type runtime_skip =
    { reason : string
    ; suggestion : string option
    }

  val gramd_skip : runtime_skip
end

module Hint_policy : sig
  type classification =
    | Presentation
    | Semantic_obligation
    | Unknown

  val classify_hint_name : string -> classification
  val classify : Il.Ast.hint -> classification
  val string_of_classification : classification -> string
end
