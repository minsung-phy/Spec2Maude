open Maude_ir

open Type_result

let sr = sort_ref
let kr sort = kind_ref (kind_of_sort sort)
let spectec_terminal = sort "SpectecTerminal"
let spectec_terminals = sort "SpectecTerminals"
let gen origin node = generated ~origin node

let typd_carrier ctx origin constructor typ =
  match Carrier_sort.for_typd ctx typ with
  | Ok sort -> Some sort, []
  | Error error ->
    None, [ Type_diagnostic.unsupported_carrier ~ctx ~origin ~constructor typ error ]

let local_value env target type_ref =
  Type_static_env.reserve_static_env Local_name.empty env
  |> fun names ->
     Local_name.reserve_existing_many names (Condition_closure.term_vars target)
  |> fun names -> Local_name.fresh_qualified names Local_name.Value type_ref

let translate_alias env ctx origin key_env static_args_key source_category target typ =
  let carrier_opt, carrier_diagnostics = typd_carrier ctx origin "AliasT" typ in
  let witness_opt, witness_diagnostics =
    Typd_witness.of_typ env ctx origin ~constructor:"AliasT" typ
  in
  match carrier_opt, witness_opt with
  | Some carrier, Some witness ->
    Typd_registry.register_inclusion
      ctx origin
      ~reason:"AliasT"
      ~key_env
      ?parent_static_args_key:static_args_key
      ~parent_category:source_category
      typ;
    let variable_type =
      if sort_name carrier = sort_name spectec_terminals then sr carrier else kr spectec_terminal
    in
    let term, _names = local_value env target variable_type in
    { statements =
        [ gen origin
            (eq
               (Typecheck_term.typecheck_for_sort carrier term target)
               (Typecheck_term.typecheck_for_sort carrier term witness))
        ]
    ; diagnostics = carrier_diagnostics @ witness_diagnostics
    }
  | _ ->
    with_diagnostics (carrier_diagnostics @ witness_diagnostics)

let translate_category_union
    env ctx origin key_env static_args_key source_category target child_typ =
  let carrier_opt, carrier_diagnostics =
    typd_carrier ctx origin "VariantT/category-union" child_typ
  in
  let witness_opt, witness_diagnostics =
    Typd_witness.of_typ
      env ctx origin ~constructor:"VariantT/category-union" child_typ
  in
  match carrier_opt, witness_opt with
  | Some carrier, Some witness ->
    Typd_registry.register_inclusion
      ctx origin
      ~reason:"VariantT/category-union"
      ~key_env
      ?parent_static_args_key:static_args_key
      ~parent_category:source_category
      child_typ;
    let variable_type =
      if sort_name carrier = sort_name spectec_terminals then sr carrier else kr spectec_terminal
    in
    let term, _names = local_value env target variable_type in
    let union_guards =
      Typecheck_guard.for_typ child_typ carrier term witness
    in
    { statements =
        [ gen origin
            (ceq
               (Typecheck_term.typecheck_for_sort carrier term target)
               (Const "true")
               union_guards)
        ]
    ; diagnostics = carrier_diagnostics @ witness_diagnostics
    }
  | _ ->
    with_diagnostics (carrier_diagnostics @ witness_diagnostics)

let translate_subtype_membership env ctx origin target child_typ =
  let carrier_opt, carrier_diagnostics =
    typd_carrier ctx origin "VariantT/subtype-membership" child_typ
  in
  let witness_opt, witness_diagnostics =
    Typd_witness.of_typ
      env ctx origin ~constructor:"VariantT/subtype-membership" child_typ
  in
  match carrier_opt, witness_opt with
  | Some carrier, Some witness ->
    let variable_type =
      if sort_name carrier = sort_name spectec_terminals then sr carrier
      else kr spectec_terminal
    in
    let term, _names = local_value env target variable_type in
    let guards =
      Typecheck_guard.for_typ child_typ carrier term witness
    in
    { statements =
        [ gen origin
            (ceq
               (Typecheck_term.typecheck_for_sort carrier term target)
               (Const "true")
               guards)
        ]
    ; diagnostics = carrier_diagnostics @ witness_diagnostics
    }
  | _ ->
    with_diagnostics (carrier_diagnostics @ witness_diagnostics)
