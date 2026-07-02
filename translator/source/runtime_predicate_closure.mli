open Il.Ast

type use =
  | Search_helper
  | Truth_helper
  | Positive_predicate

type relation_kind =
  | Predicate_candidate
  | Deterministic_candidate
  | Execution
  | Execution_star
  | Unknown of string

type rule =
  { rule_id : string option
  ; origin : Origin.t
  ; source_echo : string option
  ; binds : quant list
  ; mixop : mixop
  ; head : exp
  ; prems : prem list
  }

type relation =
  { id : string
  ; origin : Origin.t
  ; source_params : param list
  ; kind : relation_kind
  ; mixop : mixop
  ; result : typ
  ; rules : rule list option
  ; runtime_demanded : bool
  }

type search_rule =
  { relation_id : string
  ; relation_result : typ
  ; rule : rule
  }

type graph

type blocker =
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

type plan =
  | Complete of
      { closure : string list
      ; rules : search_rule list
      }
  | Blocked of
      { closure : string list
      ; rules : search_rule list
      ; blockers : blocker list
      }

val make :
  find_relation:(string -> relation option) ->
  dependencies:(string -> string list) ->
  mixop_equal:(mixop -> mixop -> bool) ->
  graph

val plan : graph -> use -> string -> plan
val dependency_completeness : graph -> string -> plan
