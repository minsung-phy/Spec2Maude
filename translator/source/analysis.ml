let source_echo_of_def = Source_index.source_echo_of_def
let constructor_of_def = Source_index.constructor_of_def
let id_of_def = Source_index.id_of_def

module Source_index = Source_index
module Relation_graph = Relation_graph

module Function_graph = struct
  type param_kind = Definition_analysis.param_kind =
    | Runtime_exp
    | Static_typ
    | Static_def
    | Static_gram

  type definition = Definition_analysis.definition =
    { id : string
    ; origin : Origin.t
    ; params : param_kind list
    ; result : Il.Ast.typ
    ; clause_count : int
    ; partial : bool
    }

  type definition_identity = Definition_analysis.definition_identity =
    { def_id : string
    ; specialization_key : string list
    }

  type emitted_definition = Definition_analysis.emitted_definition =
    { identity : definition_identity
    ; source_id : string
    ; op_name : string
    ; result : Il.Ast.typ
    ; rewrite_backed : bool
    }

  type inverse_status = Definition_analysis.inverse_status =
    | No_inverse
    | Valid_inverse of string
    | Invalid_inverse of
        { reason : string
        ; hint_origin : Origin.t
        }

  type relation = Relation_analysis.relation =
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

  type rule_hint = Relation_analysis.rule_hint =
    { relation_id : string
    ; rule_id : string
    ; origin : Origin.t
    ; hints : Il.Ast.hint list
    }

  type static_typ_binding = Definition_analysis.static_typ_binding =
    { param_id : string
    ; typ : Il.Ast.typ
    ; key : string
    }

  type static_def_binding = Definition_analysis.static_def_binding =
    { param_id : string
    ; target_id : string
    ; key : string
    }

  type specialization = Definition_analysis.specialization =
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

  type call_resolution = Definition_analysis.call_resolution =
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

  type runtime_search_blocker = Relation_analysis.runtime_search_blocker =
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

  type runtime_search_rule = Relation_analysis.runtime_search_rule =
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
    Relation_analysis.runtime_predicate_search_plan =
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
    Relation_analysis.runtime_predicate_dependency_completeness =
    | Runtime_predicate_dependencies_complete of
        { closure : string list
        }
    | Runtime_predicate_dependencies_incomplete of
        { closure : string list
        ; rules : runtime_search_rule list
        ; blockers : runtime_search_blocker list
        }

  type t = Definition_analysis.t

  let build = Definition_analysis.build
  let diagnostics = Definition_analysis.diagnostics
  let definitions = Definition_analysis.definitions
  let find_definition = Definition_analysis.find_definition
  let definition_inverse = Definition_analysis.definition_inverse
  let definition_is_partial = Definition_analysis.definition_is_partial
  let definition_is_rewrite_backed = Definition_analysis.definition_is_rewrite_backed
  let plain_identity = Definition_analysis.plain_identity
  let identity_of_specialization = Definition_analysis.identity_of_specialization
  let identity_is_rewrite_backed = Definition_analysis.identity_is_rewrite_backed
  let definition_is_runtime_entry = Definition_analysis.definition_is_runtime_entry
  let emitted_definition = Definition_analysis.emitted_definition
  let definition_inverse_status = Definition_analysis.definition_inverse_status
  let specializations_for = Definition_analysis.specializations_for
  let has_specialization = Definition_analysis.has_specialization
  let resolve_call = Definition_analysis.resolve_call

  let relation_analysis t = Definition_analysis.relation_analysis t

  let find_relation t id =
    Relation_analysis.find_relation (relation_analysis t) id

  let rule_hints t ~relation_id ~rule_id =
    Relation_analysis.rule_hints (relation_analysis t) ~relation_id ~rule_id

  let relation_has_maude_equational_view =
    Relation_analysis.relation_has_maude_equational_view

  let relation_runtime_demand_reason t id =
    Relation_analysis.relation_runtime_demand_reason (relation_analysis t) id

  let relation_is_runtime_demanded t id =
    Relation_analysis.relation_is_runtime_demanded (relation_analysis t) id

  let runtime_predicate_search_plan t id =
    Relation_analysis.runtime_predicate_search_plan (relation_analysis t) id

  let runtime_predicate_truth_plan t id =
    Relation_analysis.runtime_predicate_truth_plan (relation_analysis t) id

  let runtime_relation_rules t id =
    Relation_analysis.runtime_relation_rules (relation_analysis t) id

  let runtime_predicate_dependency_completeness t id =
    Relation_analysis.runtime_predicate_dependency_completeness
      (relation_analysis t) id
end

module Profile_policy = struct
  type runtime_skip =
    { reason : string
    ; suggestion : string option
    }

  let gramd_skip =
    { reason =
        "runtime Maude is not the SpecTec text parser; grammar definitions have already been consumed by the frontend"
    ; suggestion = Some "Keep the origin in diagnostics and do not emit runtime Maude for GramD in this profile"
    }
end

module Hint_policy = struct
  type classification =
    | Presentation
    | Semantic_obligation
    | Translator_annotation
    | Unknown

  let string_has_prefix ~prefix text =
    let prefix_len = String.length prefix in
    String.length text >= prefix_len
    && String.sub text 0 prefix_len = prefix

  let classify_hint_name = function
    | "desc" | "show" | "name" | "macro" | "tabular" ->
      Presentation
    | "maude_equational_view" | "partial" | "inverse" ->
      Translator_annotation
    | "builtin" ->
      Semantic_obligation
    | name when string_has_prefix ~prefix:"prose" name -> Presentation
    | _ -> Unknown

  let classify hint =
    classify_hint_name hint.Il.Ast.hintid.it

  let string_of_classification = function
    | Presentation -> "presentation"
    | Semantic_obligation -> "semantic-obligation"
    | Translator_annotation -> "translator-annotation"
    | Unknown -> "unknown"
end
