open Maude_ir

type result =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

type pattern_refuter =
  { declarations : Maude_ir.generated list
  ; branches : Maude_ir.eq_condition list list
  ; diagnostics : Diagnostics.t list
  ; complete : bool
  }

let generated helper_name origin node =
  Maude_ir.generated ~provenance:(Maude_ir.Helper helper_name) ~origin node

let empty_pattern_refuter =
  { declarations = []; branches = []; diagnostics = []; complete = true }

let incomplete_pattern_refuter =
  { empty_pattern_refuter with complete = false }

let append_pattern_refuter prefix refuter =
  { refuter with
    branches =
      refuter.branches
      |> List.map (fun branch -> prefix @ branch)
  }

let case_payload_exps (arg : Il.Ast.exp) =
  match arg.it with
  | Il.Ast.TupE exps -> exps
  | _ -> [ arg ]

let constructor_family ctx typ =
  let key_env = Static_key.of_static_typ_env (Context.static_typ_env ctx) in
  match Static_key.typ_ref ~env:key_env typ with
  | None -> None
  | Some { Static_key.category_id; static_args_key } ->
    let source_category = Naming.source_owner category_id in
    Some (source_category, static_args_key)

let emitted_case_entry ctx (exp : Il.Ast.exp) mixop arity =
  match constructor_family ctx exp.note with
  | None -> None
  | Some (source_category, static_args_key) ->
    (match
       Constructor_registry.lookup_emitted
         (Context.constructors ctx)
         ~source_category
         ~static_args_key
         ~mixop
         ~arity
     with
    | Constructor_registry.Found entry -> Some entry
    | Constructor_registry.Missing | Constructor_registry.Ambiguous _ -> None)

let fresh_alternative_field
    helper_name refuter_index prem_index depth alt_index field_index =
  "RTALT"
  ^ helper_name
  ^ string_of_int refuter_index
  ^ "x"
  ^ string_of_int prem_index
  ^ "x"
  ^ string_of_int depth
  ^ "x"
  ^ string_of_int alt_index
  ^ "x"
  ^ string_of_int field_index

let constructor_entry_pattern
    helper_name origin ~refuter_index ~prem_index ~depth ~alt_index entry =
  Runtime_truth_constructor_pattern.build
    ~helper_name
    ~origin
    ~var_name:
      (fun field_index _sort ->
        fresh_alternative_field
          helper_name
          refuter_index
          prem_index
          depth
          alt_index
          field_index)
    entry

let closed_family ctx target =
  match
    Constructor_registry.family_coverage
      (Context.constructors ctx)
      ~source_category:target.Constructor_registry.source_category
      ~static_args_key:target.static_args_key
  with
  | Constructor_registry.Open _ -> None
  | Constructor_registry.Closed entries ->
    if
      List.exists
        (fun entry ->
          String.equal
            entry.Constructor_registry.constructor_op
            target.constructor_op)
        entries
    then Some entries
    else None

let fresh_pattern_field helper_name refuter_index prem_index depth index =
  "RTPAT"
  ^ helper_name
  ^ string_of_int refuter_index
  ^ "x"
  ^ string_of_int prem_index
  ^ "x"
  ^ string_of_int depth
  ^ "x"
  ^ string_of_int index

let rec strip_pattern_coercion (exp : Il.Ast.exp) =
  match exp.it with
  | Il.Ast.SubE (inner, _, _) | Il.Ast.CvtE (inner, _, _) ->
    strip_pattern_coercion inner
  | _ -> exp

let binding_is_bound bound_vars (binding : Expr_env.binding) =
  Condition_closure.vars_subset
    (Condition_closure.term_vars binding.term)
    bound_vars

let is_binding_refutation_pattern env bound_vars exp =
  match (strip_pattern_coercion exp).it with
  | Il.Ast.VarE id ->
    (match Expr_env.find env id.it with
    | None -> true
    | Some binding -> not (binding_is_bound bound_vars binding))
  | Il.Ast.ListE [] | Il.Ast.OptE None | Il.Ast.CaseE _ ->
    true
  | _ -> false

let source_is_binding env bound_vars id =
  id <> "_"
  && match Expr_env.find env id with
     | None -> true
     | Some binding -> not (binding_is_bound bound_vars binding)

let irrefutable_iter_binding env bound_vars (exp : Il.Ast.exp) =
  match exp.it with
  | Il.Ast.IterE
      ( { it = Il.Ast.VarE body; _ }
      , ((Il.Ast.List | Il.Ast.Opt),
         [ generator, { it = Il.Ast.VarE source; _ } ]) ) ->
    body.it = generator.it
    && source_is_binding env bound_vars source.it
  | Il.Ast.IterE
      ( { it = Il.Ast.VarE body; _ }
      , (Il.Ast.ListN ({ it = Il.Ast.VarE count; _ }, None),
         [ generator, { it = Il.Ast.VarE source; _ } ]) ) ->
    body.it = generator.it
    && count.it <> source.it
    && source_is_binding env bound_vars source.it
    && source_is_binding env bound_vars count.it
  | _ -> false

let bound_iter_source env bound_vars (exp : Il.Ast.exp) =
  match exp.it with
  | Il.Ast.IterE
      ( { it = Il.Ast.VarE body; _ }
      , ((Il.Ast.List | Il.Ast.Opt),
         [ generator, { it = Il.Ast.VarE source; _ } ]) )
    when body.it = generator.it ->
    (match Expr_env.find env source.it with
    | Some binding when binding_is_bound bound_vars binding -> Some binding.term
    | None | Some _ -> None)
  | _ -> None

let rec pattern_false_branches
    ctx helper_name origin ~env ~bound_vars
    ~refuter_index ~prem_index ~depth subject exp
  =
  let exp = strip_pattern_coercion exp in
  match exp.it with
  | Il.Ast.VarE id ->
    (match Expr_env.find env id.it with
    | Some binding when binding_is_bound bound_vars binding ->
      { empty_pattern_refuter with
        branches =
          [ [ BoolCond (App ("_=/=_", [ subject; binding.term ])) ] ]
      }
    | None | Some _ -> empty_pattern_refuter)
  | Il.Ast.ListE [] | Il.Ast.OptE None ->
    { empty_pattern_refuter with
      branches = [ [ BoolCond (App ("_=/=_", [ subject; Const "eps" ])) ] ]
    }
  | Il.Ast.IterE _ when irrefutable_iter_binding env bound_vars exp ->
    empty_pattern_refuter
  | Il.Ast.IterE _ ->
    (match bound_iter_source env bound_vars exp with
    | Some expected ->
      { empty_pattern_refuter with
        branches = [ [ BoolCond (App ("_=/=_", [ subject; expected ])) ] ]
      }
    | None -> incomplete_pattern_refuter)
  | Il.Ast.CaseE (mixop, arg) ->
    let payload_exps = case_payload_exps arg in
    let arity = List.length payload_exps in
    (match emitted_case_entry ctx exp mixop arity with
    | None -> incomplete_pattern_refuter
    | Some target ->
      let family = closed_family ctx target in
      let field_descriptors =
        payload_exps
        |> List.mapi (fun index (payload : Il.Ast.exp) ->
          match Expr_translate.carrier_sort_of_typ payload.note with
          | None -> None
          | Some sort ->
            let name =
              fresh_pattern_field
                helper_name
                refuter_index
                prem_index
                depth
                index
            in
            Some (payload, name, sort, Var name))
      in
      if List.exists Option.is_none field_descriptors then
        incomplete_pattern_refuter
      else
        let field_descriptors = List.filter_map Fun.id field_descriptors in
        let field_terms =
          field_descriptors
          |> List.map (fun (_payload, _name, _sort, term) -> term)
        in
        let declarations =
          field_descriptors
          |> List.map (fun (_payload, name, sort, _term) ->
            generated helper_name origin (var name (sort_ref sort)))
        in
        let same_constructor =
          match field_terms with
          | [] -> Const target.constructor_op
          | _ -> App (target.constructor_op, field_terms)
        in
        let same_prefix = [ MatchCond (same_constructor, subject) ] in
        let alternative_entries =
          match family with
          | None -> []
          | Some entries ->
            entries
            |> List.filter (fun entry ->
              not
                (String.equal
                   entry.Constructor_registry.constructor_op
                   target.constructor_op))
        in
        let alternative_patterns =
          alternative_entries
          |> List.mapi (fun alt_index entry ->
            constructor_entry_pattern
              helper_name
              origin
              ~refuter_index
              ~prem_index
              ~depth
              ~alt_index
              entry)
        in
        let alternative_branches = List.filter_map Fun.id alternative_patterns in
        let child_refuters =
          field_descriptors
          |> List.mapi (fun index (payload, _name, _sort, term) ->
            pattern_false_branches
              ctx
              helper_name
              origin
              ~env
              ~bound_vars
              ~refuter_index
              ~prem_index
              ~depth:(depth + index + 1)
              term
              payload)
        in
        let declarations =
          declarations
          @ List.concat_map
              (fun (pattern : Runtime_truth_constructor_pattern.t) ->
                pattern.declarations)
              alternative_branches
          @ List.concat_map
              (fun (refuter : pattern_refuter) -> refuter.declarations)
              child_refuters
        in
        let diagnostics =
          List.concat_map
            (fun (refuter : pattern_refuter) -> refuter.diagnostics)
            child_refuters
        in
        let complete =
          Option.is_some family
          && List.for_all Option.is_some alternative_patterns
          && List.for_all (fun refuter -> refuter.complete) child_refuters
        in
        let child_branches =
          child_refuters
          |> List.concat_map (fun refuter ->
            (append_pattern_refuter same_prefix refuter).branches)
        in
        { declarations
        ; branches =
            (alternative_branches
             |> List.map (fun (pattern : Runtime_truth_constructor_pattern.t) ->
               [ MatchCond (pattern.term, subject) ]))
            @ child_branches
        ; diagnostics
        ; complete
        })
  | _ ->
    incomplete_pattern_refuter

let append_prefix_conditions prefix conditions =
  prefix @ conditions

let refute
    ctx
    ~helper_name
    ~origin
    ~env
    ~bound_vars
    ~label_prefix
    ~refuter_index
    ~prem_index
    ~prefix_conditions
    ~lhs
    ~rhs
    ~left
    ~right
  =
  let try_orientation subject_exp pattern_exp =
    if not (is_binding_refutation_pattern env bound_vars pattern_exp) then
      None
    else
      let subject = Expr_translate.lower_value ctx env origin subject_exp in
      match subject.term with
      | None -> None
      | Some subject_term ->
        let pattern_refuter =
          pattern_false_branches
            ctx
            helper_name
            origin
            ~env
            ~bound_vars
            ~refuter_index
            ~prem_index
            ~depth:0
            subject_term
            pattern_exp
        in
        if not pattern_refuter.complete then None
        else (match
           Runtime_truth_condition_complement.source_definedness_alternatives
             ~bound_vars
             ~assumed:
               (prefix_conditions
                |> List.filter_map (function
                  | Maude_ir.EqCondition condition -> Some condition
                  | Maude_ir.RewriteCond _ -> None))
             ctx env origin subject_exp
         with
        | Error _ -> None
        | Ok definedness ->
          let branches =
            definedness.failures
            @ List.map
                (fun branch -> definedness.positive @ branch)
                pattern_refuter.branches
          in
          if branches = [] && pattern_refuter.diagnostics = [] then
            Some
              { statements = []
              ; diagnostics =
                  subject.diagnostics @ definedness.diagnostics
              }
          else if branches = [] then
            None
          else
          let statements =
            pattern_refuter.declarations
            @ (branches
               |> List.mapi (fun index branch ->
                 generated
                   helper_name
                   origin
                   (crl
                      ~label:
                        (label_prefix
                         ^ "-eq-pattern-"
                         ^ string_of_int prem_index
                         ^ "-"
                         ^ string_of_int (index + 1))
                      lhs
                      rhs
                      (append_prefix_conditions
                         prefix_conditions
                         (List.map
                              (fun condition -> EqCondition condition)
                              branch)))))
          in
          Some
            { statements
            ; diagnostics =
                subject.diagnostics @ definedness.diagnostics
                @ pattern_refuter.diagnostics
            })
  in
  match try_orientation left right with
  | Some result -> Some result
  | None -> try_orientation right left
