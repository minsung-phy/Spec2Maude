open Maude_ir

type result =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

type pattern_refuter =
  { declarations : Maude_ir.generated list
  ; branches : Maude_ir.eq_condition list list
  ; diagnostics : Diagnostics.t list
  }

let generated helper_name origin node =
  Maude_ir.generated ~provenance:(Maude_ir.Helper helper_name) ~origin node

let empty_pattern_refuter =
  { declarations = []; branches = []; diagnostics = [] }

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

let family_alternatives ctx target =
  Constructor_registry.entries (Context.constructors ctx)
  |> List.filter (fun entry ->
    String.equal
      entry.Constructor_registry.source_category
      target.Constructor_registry.source_category
    && entry.Constructor_registry.static_args_key = target.static_args_key
    && entry.Constructor_registry.status = Constructor_registry.Emitted
    && not
         (String.equal
            entry.Constructor_registry.constructor_op
            target.constructor_op))

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

let is_binding_refutation_pattern exp =
  match (strip_pattern_coercion exp).it with
  | Il.Ast.VarE _ | Il.Ast.ListE [] | Il.Ast.OptE None | Il.Ast.CaseE _ ->
    true
  | _ -> false

let rec pattern_false_branches
    ctx helper_name origin ~refuter_index ~prem_index ~depth subject exp
  =
  let exp = strip_pattern_coercion exp in
  match exp.it with
  | Il.Ast.VarE _ ->
    empty_pattern_refuter
  | Il.Ast.ListE [] | Il.Ast.OptE None ->
    { empty_pattern_refuter with
      branches = [ [ BoolCond (App ("_=/=_", [ subject; Const "eps" ])) ] ]
    }
  | Il.Ast.CaseE (mixop, arg) ->
    let payload_exps = case_payload_exps arg in
    let arity = List.length payload_exps in
    (match emitted_case_entry ctx exp mixop arity with
    | None -> empty_pattern_refuter
    | Some target ->
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
        empty_pattern_refuter
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
        let alternative_branches =
          family_alternatives ctx target
          |> List.mapi (fun alt_index entry ->
            constructor_entry_pattern
              helper_name
              origin
              ~refuter_index
              ~prem_index
              ~depth
              ~alt_index
              entry)
          |> List.filter_map Fun.id
        in
        let child_refuters =
          field_descriptors
          |> List.mapi (fun index (payload, _name, _sort, term) ->
            pattern_false_branches
              ctx
              helper_name
              origin
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
        })
  | _ ->
    empty_pattern_refuter

let append_prefix_conditions prefix conditions =
  prefix @ conditions

let refute
    ctx
    ~helper_name
    ~origin
    ~env
    ~refuter_index
    ~prem_index
    ~prefix_conditions
    ~lhs
    ~rhs
    ~left
    ~right
  =
  let try_orientation subject_exp pattern_exp =
    if not (is_binding_refutation_pattern pattern_exp) then
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
            ~refuter_index
            ~prem_index
            ~depth:0
            subject_term
            pattern_exp
        in
        if pattern_refuter.branches = [] && pattern_refuter.diagnostics = [] then
          Some { statements = []; diagnostics = subject.diagnostics }
        else if pattern_refuter.branches = [] then
          None
        else
          let statements =
            pattern_refuter.declarations
            @ (pattern_refuter.branches
               |> List.mapi (fun index branch ->
                 generated
                   helper_name
                   origin
                   (crl
                      ~label:
                        (helper_name
                         ^ "-rule-refuted-"
                         ^ string_of_int refuter_index
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
                            subject.guards
                          @ List.map
                              (fun condition -> EqCondition condition)
                              branch)))))
          in
          Some
            { statements
            ; diagnostics = subject.diagnostics @ pattern_refuter.diagnostics
            }
  in
  match try_orientation left right with
  | Some result -> Some result
  | None -> try_orientation right left
