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
    ; partial : bool
    }

  type definition_identity =
    { def_id : string
    ; specialization_key : string list
    }

  type emitted_definition =
    { identity : definition_identity
    ; source_id : string
    ; op_name : string
    ; result : Il.Ast.typ
    ; rewrite_backed : bool
    }

  type inverse_status =
    | No_inverse
    | Valid_inverse of string
    | Invalid_inverse of
        { reason : string
        ; hint_origin : Origin.t
        }

  type relation =
    { identity : Source_rule_identity.relation
    ; id : string
    ; origin : Origin.t
    ; source_params : Il.Ast.param list
    ; kind : Relation_graph.relation_kind
    ; mixop : Il.Ast.mixop
    ; result : Il.Ast.typ
    ; rule_count : int
    ; hints : string list
    ; maude_equational_view : bool
    ; external_validation_shape : bool
    }

  type relation_demand =
    { id : string
    ; reason : string
    }

  type rule_hint =
    { relation_id : string
    ; rule_id : string
    ; origin : Origin.t
    ; hints : Il.Ast.hint list
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

  type runtime_search_capability =
    | Runtime_search_candidate of string list
    | Runtime_search_blocked of
        { closure : string list
        ; blockers : string list
        }

  type runtime_search_blocker =
    { relation_id : string
    ; rule_id : string option
    ; origin : Origin.t option
    ; constructor : string
    ; reason : string
    ; suggestion : string
    ; source_echo : string option
    ; premise_origin : Origin.t option
    ; premise_constructor : string option
    ; premise_source_echo : string option
    }

  type runtime_search_rule =
    { identity : Source_rule_identity.rule
    ; relation_id : string
    ; relation_result : Il.Ast.typ
    ; rule_id : string option
    ; origin : Origin.t
    ; source_echo : string option
    ; binds : Il.Ast.quant list
    ; mixop : Il.Ast.mixop
    ; head : Il.Ast.exp
    ; prems : Il.Ast.prem list
    }

  type runtime_predicate_search_plan =
    | Runtime_search_no_shape_blockers of
        { closure : string list
        ; rules : runtime_search_rule list
        }
    | Runtime_search_blocked_plan of
        { closure : string list
        ; rules : runtime_search_rule list
        ; blockers : runtime_search_blocker list
        }

  type runtime_predicate_dependency_completeness =
    | Runtime_predicate_dependencies_complete of
        { closure : string list
        }
    | Runtime_predicate_dependencies_incomplete of
        { closure : string list
        ; rules : runtime_search_rule list
        ; blockers : runtime_search_blocker list
        }

  type t

  val build : Source_index.t -> t
  val diagnostics : profile:string -> t -> Diagnostics.t list
  val definitions : t -> definition list
  val find_definition : t -> string -> definition option
  val definition_inverse : t -> string -> string option
  val definition_is_partial : t -> string -> bool
  val definition_is_rewrite_backed : t -> string -> bool
  val plain_identity : string -> definition_identity
  val identity_of_specialization : specialization -> definition_identity
  val identity_is_rewrite_backed : t -> definition_identity -> bool
  val definition_is_runtime_entry : t -> string -> bool
  val emitted_definition : t -> definition_identity -> emitted_definition option
  val definition_inverse_status : t -> string -> inverse_status
  val find_relation : t -> string -> relation option
  val rule_hints :
    t -> relation_id:string -> rule_id:string -> rule_hint option
  val relation_has_maude_equational_view : relation -> bool
  val relation_runtime_demand_reason : t -> string -> string option
  val relation_is_runtime_demanded : t -> string -> bool
  val runtime_predicate_search_plan : t -> string -> runtime_predicate_search_plan
  val runtime_predicate_truth_plan : t -> string -> runtime_predicate_search_plan
  val runtime_relation_rules : t -> string -> runtime_search_rule list option
  val runtime_predicate_dependency_completeness :
    t -> string -> runtime_predicate_dependency_completeness
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
    | Translator_annotation
    | Unknown

  val classify_hint_name : string -> classification
  val classify : Il.Ast.hint -> classification
  val string_of_classification : classification -> string
end
