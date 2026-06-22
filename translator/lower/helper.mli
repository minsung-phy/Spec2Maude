type iter_map_call_shape =
  | Source_then_captures
  | Count_then_captures

type iter_map_source_shape =
  { iter_source : string
  ; body_source : string
  ; source_source : string
  ; output_typ_source : string
  ; source_typ_source : string
  }

type iter_map_source_item_shape =
  | Source_flat_terminal
  | Source_nested_seq

type iter_map_output_item_shape =
  | Output_flat_terminal
  | Output_nested_seq

type capture =
  { source_id : string
  ; call_term : Maude_ir.term
  ; formal_var : string
  ; sort : Maude_ir.sort
  ; typ : Il.Ast.typ
  }

type iter_map =
  { source_shape : iter_map_source_shape
  ; call_shape : iter_map_call_shape
  ; generator_var : string
  ; helper_head_var : string
  ; source_tail_var : string
  ; body_result_var : string
  ; source_item_shape : iter_map_source_item_shape
  ; output_item_shape : iter_map_output_item_shape
  ; source_element_sort : Maude_ir.sort
  ; captures : capture list
  ; lowered_body : Maude_ir.term
  ; body_eq_conditions : Maude_ir.eq_condition list
  }

type iter_zip_source_shape =
  { generator_source_id : string
  ; source_source : string
  ; source_typ_source : string
  }

type iter_zip_source =
  { source_shape : iter_zip_source_shape
  ; source_item_shape : iter_map_source_item_shape
  ; helper_head_var : string
  ; source_tail_var : string
  ; source_element_sort : Maude_ir.sort
  }

type iter_zip_map_source_shape =
  { iter_source : string
  ; body_source : string
  ; output_typ_source : string
  ; sources : iter_zip_source_shape list
  }

type iter_zip_map =
  { source_shape : iter_zip_map_source_shape
  ; call_shape : iter_map_call_shape
  ; sources : iter_zip_source list
  ; body_result_var : string
  ; output_item_shape : iter_map_output_item_shape
  ; captures : capture list
  ; lowered_body : Maude_ir.term
  ; body_eq_conditions : Maude_ir.eq_condition list
  }

type iter_listn_mode =
  | Repeat_count
  | Indexed_from_zero

type iter_listn_shape =
  { iter_source : string
  ; body_source : string
  ; count_source : string
  ; count_typ_source : string
  ; output_typ_source : string
  ; mode : iter_listn_mode
  }

type iter_listn =
  { source_shape : iter_listn_shape
  ; call_shape : iter_map_call_shape
  ; count_var : string
  ; index_var : string option
  ; body_result_var : string
  ; output_item_shape : iter_map_output_item_shape
  ; captures : capture list
  ; lowered_body : Maude_ir.term
  ; body_eq_conditions : Maude_ir.eq_condition list
  }

type iter_listn_source_shape =
  { iter_source : string
  ; body_source : string
  ; source_source : string
  ; count_source : string
  ; count_typ_source : string
  ; output_typ_source : string
  ; source_typ_source : string
  }

type iter_listn_source =
  { source_shape : iter_listn_source_shape
  ; count_var : string
  ; index_var : string
  ; generator_var : string
  ; helper_head_var : string
  ; source_tail_var : string
  ; body_result_var : string
  ; source_item_shape : iter_map_source_item_shape
  ; output_item_shape : iter_map_output_item_shape
  ; source_element_sort : Maude_ir.sort
  ; captures : capture list
  ; lowered_body : Maude_ir.term
  ; body_eq_conditions : Maude_ir.eq_condition list
  }

type iter_premise_opt_bool_shape =
  { prem_source : string
  ; body_source : string
  ; source_source : string
  ; source_typ_source : string
  }

type iter_premise_opt_bool =
  { source_shape : iter_premise_opt_bool_shape
  ; generator_var : string
  ; helper_head_var : string
  ; source_tail_var : string
  ; body_result_var : string
  ; source_element_sort : Maude_ir.sort
  ; captures : capture list
  ; lowered_body : Maude_ir.term
  ; body_eq_conditions : Maude_ir.eq_condition list
  }

type request_kind =
  | Iter_map of iter_map
  | Iter_zip_map of iter_zip_map
  | Iter_listn of iter_listn
  | Iter_listn_source of iter_listn_source
  | Iter_premise_opt_bool of iter_premise_opt_bool
  | Optional_branch of { shape : string }
  | List1_guard of { shape : string }
  | Listn_indexed of { shape : string }
  | Membership_binding of { shape : string }
  | Sequence_splice of { shape : string }
  | Enabledness_complement of { shape : string }
  | Rewrite_dependent of { shape : string }

type request =
  { kind : request_kind
  ; reason : string
  ; origin : Origin.t
  }

type t

val create : unit -> t
val request : t -> request -> string
val requests : t -> request list
val key_of_kind : request_kind -> string
val materialize : t -> Maude_ir.generated list
