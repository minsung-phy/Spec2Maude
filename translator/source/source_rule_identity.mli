type relation
type rule

val relation : source_id:string -> source_ordinal:int -> relation
val rule :
  ?specialization_key:string list ->
  relation ->
  source_rule_index:int ->
  rule

val relation_source_id : relation -> string
val relation_source_ordinal : relation -> int
val rule_relation : rule -> relation
val rule_source_index : rule -> int
val rule_specialization_key : rule -> string list
val equal_rule : rule -> rule -> bool
val compare_rule : rule -> rule -> int
val rule_key : rule -> string
