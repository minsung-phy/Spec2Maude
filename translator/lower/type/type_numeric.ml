open Il.Ast
open Maude_ir
open Util.Source

open Type_diagnostic
open Type_result

let sr = sort_ref
let spectec_terminal = sort "SpectecTerminal"
let app name args = App (name, args)
let gen origin node = generated ~origin node

let numeric_literal_sort num =
  match Xl.Num.to_typ num with
  | `NatT | `IntT -> Some (Const (Xl.Num.to_string num))
  | `RatT | `RealT -> None

let exp_note_allows_nat_int_literal exp =
  match exp.note.it with
  | NumT (`RatT | `RealT) -> false
  | _ -> true

let alias_projection_mixop : mixop = Xl.Mixop.Arg ()

let term_of_numeric_literal_exp exp =
  match exp.it with
  | NumE n when exp_note_allows_nat_int_literal exp -> numeric_literal_sort n
  | _ -> None

let numeric_payload_sort typ =
  match typ.it with
  | NumT `NatT -> Some (sort "Nat")
  | NumT `IntT -> Some (sort "Int")
  | _ -> None

let eq_literal_for_payload payload_id exp =
  match exp.it with
  | CmpE (`EqOp, _, left, right) ->
    (match left.it, term_of_numeric_literal_exp right with
    | VarE id, Some term when id.it = payload_id -> Some term
    | _ ->
      (match right.it, term_of_numeric_literal_exp left with
      | VarE id, Some term when id.it = payload_id -> Some term
      | _ -> None))
  | _ -> None

let rec literal_terms_for_payload payload_id exp =
  match exp.it with
  | BinE (`OrOp, _, left, right) ->
    (match literal_terms_for_payload payload_id left, literal_terms_for_payload payload_id right with
    | Some left_terms, Some right_terms -> Some (left_terms @ right_terms)
    | _ -> None)
  | _ ->
    Option.map (fun term -> [ term ]) (eq_literal_for_payload payload_id exp)

let range_bound_for_payload payload_id exp =
  match exp.it with
  | CmpE ((`GeOp | `LeOp), _, left, right) ->
    (match left.it, term_of_numeric_literal_exp right with
    | VarE id, Some _ when id.it = payload_id -> true
    | _ ->
      (match right.it, term_of_numeric_literal_exp left with
      | VarE id, Some _ when id.it = payload_id -> true
      | _ -> false))
  | _ -> false

let rec is_range_predicate_for_payload payload_id exp =
  match exp.it with
  | BinE (`AndOp, _, left, right) ->
    is_range_predicate_for_payload payload_id left
    && is_range_predicate_for_payload payload_id right
  | _ -> range_bound_for_payload payload_id exp

let numeric_literal_bind_supported binds payload_id typ =
  match binds with
  | [] -> true
  | [ { it = ExpP (id, bind_typ); _ } ] ->
    id.it = payload_id && bind_typ.it = typ.it
  | _ -> false

let numeric_predicate_from_typcase binds typ prems =
  match Type_shape.typ_components typ, prems with
  | [ { it = VarE payload_id; _ }, payload_typ ], [ { it = IfPr predicate; _ } ] ->
    (match numeric_payload_sort payload_typ with
    | Some payload_sort when numeric_literal_bind_supported binds payload_id.it payload_typ ->
      Some (payload_id, payload_typ, payload_sort, predicate)
    | _ -> None)
  | _ -> None

let numeric_literal_terms_from_typcase binds typ prems =
  match Type_shape.typ_components typ with
  | [ payload, payload_typ ] ->
    (match numeric_payload_sort payload_typ with
    | None -> None
    | Some payload_sort ->
    (match payload.it, prems with
    | NumE _, [] ->
      Option.map
        (fun term -> `Literals (payload_sort, [ term ]))
        (term_of_numeric_literal_exp payload)
    | VarE payload_id, [ { it = IfPr exp; _ } ]
      when numeric_literal_bind_supported binds payload_id.it payload_typ ->
      (match literal_terms_for_payload payload_id.it exp with
      | Some terms -> Some (`Literals (payload_sort, terms))
      | None ->
        if is_range_predicate_for_payload payload_id.it exp then Some `Range else None)
    | _ -> None))
  | _ -> None

let register_numeric_wrapper
    ctx ?mixop origin static_args_key source_category target payload_sort =
  let constructor =
    Naming.wrapper_constructor_in_category source_category
  in
  let projection_ops =
    match mixop with
    | None -> []
    | Some mixop ->
      let destructor =
        Naming.destructor_op_in_category
          source_category
          mixop
          0
      in
      [ destructor ]
  in
  ignore
    (Typd_registry.register_constructor
       ctx origin
       ~construction_domain:
         Constructor_registry.Certified_representation_constructor
       ?static_args_key
       ~source_category
       ~mixop:(Option.value mixop ~default:alias_projection_mixop)
       ~arity:1
       ~constructor_op:constructor
       ~projection_ops
       ~payload_witnesses:[ target ]
       ~payload_sorts:[ payload_sort ]
       ());
  constructor, projection_ops

let numeric_wrapper_statements
    env ctx ?mixop origin static_args_key source_category target payload_sort =
  let names =
    Type_static_env.reserve_static_env Local_name.empty env
    |> fun names ->
       Local_name.reserve_existing_many names (Condition_closure.term_vars target)
  in
  let variable_term, _names =
    Local_name.fresh_qualified names Local_name.Value (sr payload_sort)
  in
  let constructor, projection_ops =
    register_numeric_wrapper
      ctx ?mixop origin static_args_key source_category target payload_sort
  in
  let wrapper = app constructor [ variable_term ] in
  let base =
    [ gen origin
        (op constructor [ sr payload_sort ] spectec_terminal
           ~kind:Partial ~attrs:[ Ctor ])
    ; gen origin (mb wrapper spectec_terminal)
    ; gen origin
        (ceq
           (Typecheck_term.typecheck wrapper target)
           (Const "true")
           [ MembershipCond (wrapper, spectec_terminal)
           ; BoolCond (Typecheck_term.typecheck variable_term target)
           ])
    ]
  in
  let destructor =
    projection_ops
    |> List.map (fun destructor ->
      [ gen origin (op destructor [ sr spectec_terminal ] payload_sort ~kind:Partial)
      ; gen origin
          (ceq
            (app destructor [ wrapper ])
            variable_term
            [ MembershipCond (wrapper, spectec_terminal) ])
      ])
    |> List.concat
  in
  base @ destructor

let translate_numeric_literal_case
    env ctx origin static_args_key source_category target mixop payload_sort literal_terms =
  { statements =
      (literal_terms
       |> List.map (fun literal ->
         gen origin (eq (Typecheck_term.typecheck literal target) (Const "true"))))
      @ numeric_wrapper_statements
          env ctx ~mixop origin static_args_key source_category target payload_sort
  ; diagnostics = []
  }

let translate_numeric_predicate_case
    env ctx origin static_args_key source_category target mixop
    payload_id payload_typ payload_sort predicate =
  let variable_term =
    Type_static_env.reserve_static_env Local_name.empty env
    |> fun names -> Local_name.reserve_sources names [ payload_id.it ]
    |> fun names -> Local_name.source_qualified names payload_id.it (sr payload_sort)
  in
  let expr_env =
    Expr_env.add
      (Type_static_env.to_expr_env env)
      payload_id.it
      { Expr_env.term = variable_term; sort = payload_sort; typ = payload_typ }
  in
  let lowered = Expr_translate.lower_bool_condition ctx expr_env origin predicate in
  match lowered.term with
  | Some predicate_term ->
    let conditions =
      lowered.guards
      @ (match predicate_term with
        | Const "true" -> []
        | _ -> [ BoolCond predicate_term ])
    in
    { statements =
        [ gen origin (ceq (Typecheck_term.typecheck variable_term target) (Const "true") conditions) ]
        @ numeric_wrapper_statements
            env ctx ~mixop origin static_args_key source_category target payload_sort
    ; diagnostics = lowered.diagnostics
    }
  | None ->
    let fallback =
      if lowered.diagnostics = [] then
        [ unsupported
            ~ctx ~origin ~constructor:"VariantT/numeric-predicate"
            ~source_echo:(Il.Print.string_of_exp predicate)
            ~reason:
              "numeric typcase IfPr predicate did not lower to a Bool condition"
            ~suggestion:
              "Extend Expr_translate.lower_bool_condition for this predicate constructor before emitting typecheck membership"
            ()
        ]
      else
        []
    in
    with_diagnostics (lowered.diagnostics @ fallback)

let unsupported_numeric_range ctx origin typcase =
  unsupported
    ~ctx ~origin ~constructor:"VariantT/numeric-range"
    ?source_echo:(source_echo_typcase typcase)
    ~reason:
      "numeric range or ellipsis typcase needs a verified range predicate/helper before it can be lowered without enumerating or guessing"
    ~suggestion:
      "Add a generic Nat/Int range membership helper before lowering this typcase"
    ()
