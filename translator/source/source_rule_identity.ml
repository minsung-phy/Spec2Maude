type relation =
  { source_id : string
  ; source_ordinal : int
  }

type rule =
  { relation : relation
  ; source_rule_index : int
  ; specialization_key : string list
  }

let relation ~source_id ~source_ordinal =
  { source_id; source_ordinal }

let rule ?(specialization_key = []) relation ~source_rule_index =
  { relation; source_rule_index; specialization_key }

let relation_source_id relation = relation.source_id
let relation_source_ordinal relation = relation.source_ordinal
let rule_relation rule = rule.relation
let rule_source_index rule = rule.source_rule_index
let rule_specialization_key rule = rule.specialization_key
let equal_rule left right = left = right
let compare_rule left right = compare left right

let rule_key rule =
  String.concat "\000"
    [ rule.relation.source_id
    ; string_of_int rule.relation.source_ordinal
    ; string_of_int rule.source_rule_index
    ; String.concat "\000" rule.specialization_key
    ]
