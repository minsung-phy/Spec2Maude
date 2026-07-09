open Maude_ir

include Type_support

let translate_alias env ctx origin seed key_env static_args_key target typ =
  let carrier_opt, carrier_diagnostics = carrier_sort_of_typ ctx origin "AliasT" typ in
  let witness_opt, witness_diagnostics = witness_of_typ env ctx origin "AliasT" typ in
  match carrier_opt, witness_opt with
  | Some carrier, Some witness ->
    register_category_inclusion
      ctx origin
      ~reason:"AliasT"
      ~key_env
      ?parent_static_args_key:static_args_key
      ~target
      typ;
    let variable = var_name seed "ALIAS" 1 in
    let variable_type =
      if sort_name carrier = sort_name spectec_terminals then sr carrier else kr spectec_terminal
    in
    let term = Var variable in
    let wrapper_variable = var_name seed "WRAP" 1 in
    let wrapper_arg = Var wrapper_variable in
    let wrapper_constructor =
      Naming.wrapper_constructor_in_category (category_name_of_target target)
    in
    let wrapper = app wrapper_constructor [ wrapper_arg ] in
    let wrapper_guards, wrapper_guard_diagnostics =
      guard_conditions_for_typ env ctx origin "AliasT" typ carrier wrapper_arg witness
    in
    let destructor =
      Naming.destructor_op_in_category
        (category_name_of_target target)
        alias_projection_mixop
        0
    in
    let destructor_app term = app destructor [ term ] in
    register_constructor
      ctx origin
      ?static_args_key
      ~target
      ~mixop:alias_projection_mixop
      ~arity:1
      ~constructor_op:wrapper_constructor
      ~projection_ops:[ destructor ]
      ~payload_witnesses:[ witness ]
      ~payload_sorts:[ carrier ]
      ();
    { statements =
        [ gen origin (var variable variable_type)
        ; gen origin (var wrapper_variable (sr carrier))
        ; gen origin
            (op wrapper_constructor [ sr carrier ] spectec_terminal
               ~kind:Partial ~attrs:[ Ctor ])
        ; gen origin (mb wrapper spectec_terminal)
        ; gen origin
            (eq
               (typecheck_for_sort carrier term target)
               (typecheck_for_sort carrier term witness))
        ; gen origin
            (ceq
               (typecheck wrapper target)
               (Const "true")
               (MembershipCond (wrapper, spectec_terminal) :: wrapper_guards))
        ; gen origin (op destructor [ sr spectec_terminal ] carrier ~kind:Partial)
        ; gen origin
            (ceq
               (destructor_app wrapper)
               wrapper_arg
               [ MembershipCond (wrapper, spectec_terminal) ])
        ]
    ; diagnostics =
        carrier_diagnostics @ witness_diagnostics @ wrapper_guard_diagnostics
    }
  | _ ->
    with_diagnostics (carrier_diagnostics @ witness_diagnostics)

let translate_category_union env ctx origin seed key_env static_args_key target child_typ =
  let carrier_opt, carrier_diagnostics =
    carrier_sort_of_typ ctx origin "VariantT/category-union" child_typ
  in
  let witness_opt, witness_diagnostics =
    witness_of_typ env ctx origin "VariantT/category-union" child_typ
  in
  match carrier_opt, witness_opt with
  | Some carrier, Some witness ->
    register_category_inclusion
      ctx origin
      ~reason:"VariantT/category-union"
      ~key_env
      ?parent_static_args_key:static_args_key
      ~target
      child_typ;
    let variable = var_name seed "UNION" 1 in
    let variable_type =
      if sort_name carrier = sort_name spectec_terminals then sr carrier else kr spectec_terminal
    in
    let term = Var variable in
    let union_guards, union_guard_diagnostics =
      guard_conditions_for_typ env ctx origin "VariantT/category-union" child_typ carrier term witness
    in
    { statements =
        [ gen origin (var variable variable_type)
        ; gen origin
            (ceq
               (typecheck_for_sort carrier term target)
               (Const "true")
               union_guards)
        ]
    ; diagnostics =
        carrier_diagnostics @ witness_diagnostics @ union_guard_diagnostics
    }
  | _ ->
    with_diagnostics (carrier_diagnostics @ witness_diagnostics)
