open Maude_ir
open Util.Source

type support =
  | Not_deterministic
  | Supported
  | Blocked of string list

type materialization =
  | Not_deterministic_materialization
  | Materialized of
      { statements : Maude_ir.generated list
      ; diagnostics : Diagnostics.t list
      }
  | Materialization_blocked of
      { diagnostics : Diagnostics.t list
      ; blockers : string list
      }

type constructor_family =
  { alternatives : Constructor_registry.entry list
  }

type family_result =
  | Family_supported of constructor_family
  | Family_blocked of string list

type deterministic_case =
  | Not_deterministic_case
  | Supported_case of
      { shape : Relation_shape.deterministic_shape
      ; inputs : Il.Ast.exp list
      ; family : constructor_family
      }
  | Blocked_case of string list

let generated helper_name origin node =
  Maude_ir.generated ~provenance:(Maude_ir.Helper helper_name) ~origin node

let blocked text =
  Blocked_case [ text ]

let family_blocked text =
  Family_blocked [ text ]

let split_prefix count items =
  let rec loop n left right =
    if n = 0 then Some (List.rev left, right)
    else
      match right with
      | [] -> None
      | item :: rest -> loop (n - 1) (item :: left) rest
  in
  loop count [] items

let case_arity arg =
  match arg.it with
  | Il.Ast.TupE exps -> List.length exps
  | _ -> 1

let compatible_static_key requested candidate =
  match requested, candidate with
  | Some _, None -> true
  | _ -> requested = candidate

let same_constructor_surface left right =
  String.equal
    left.Constructor_registry.constructor_op
    right.Constructor_registry.constructor_op

let unique_entries entries =
  entries
  |> List.fold_left
       (fun entries entry ->
         if List.exists (same_constructor_surface entry) entries then
           entries
         else
           entry :: entries)
       []
  |> List.rev

let registry_family_entries ctx source_category static_args_key =
  Constructor_registry.entries (Context.constructors ctx)
  |> List.filter (fun entry ->
    String.equal entry.Constructor_registry.source_category source_category
    && compatible_static_key
         static_args_key
         entry.Constructor_registry.static_args_key)

let has_child_inclusions ctx source_category static_args_key =
  Constructor_registry.inclusions (Context.constructors ctx)
  |> List.exists (fun inclusion ->
    String.equal inclusion.Constructor_registry.parent_category source_category
    && compatible_static_key
         static_args_key
         inclusion.Constructor_registry.parent_static_args_key)

let fresh_alternative_field helper_name constructor_op index _sort =
  Naming.maude_var
    (helper_name ^ "-det-alt-" ^ constructor_op ^ "-" ^ string_of_int index)

let constructor_pattern helper_name origin entry =
  Runtime_truth_constructor_pattern.build
    ~helper_name
    ~origin
    ~var_name:
      (fresh_alternative_field
         helper_name
         entry.Constructor_registry.constructor_op)
    entry

let output_constructor_family ctx output_exp =
  match output_exp.it with
  | Il.Ast.CaseE (mixop, arg) ->
    let key_env = Static_key.of_static_typ_env (Context.static_typ_env ctx) in
    (match Static_key.typ_ref ~env:key_env output_exp.note with
    | None ->
      family_blocked
        ("deterministic output pattern `"
         ^ Il.Print.string_of_exp output_exp
         ^ "` has no source TypD category witness")
    | Some { Static_key.category_id; static_args_key } ->
      let source_category = Naming.source_owner category_id in
      let arity = case_arity arg in
      if has_child_inclusions ctx source_category static_args_key then
        family_blocked
          ("deterministic output category `"
           ^ source_category
           ^ "` includes child categories, so constructor-disjoint refutation needs visible-family enumeration first")
      else
        match
          Constructor_registry.lookup_emitted
            (Context.constructors ctx)
            ~source_category
            ~static_args_key
            ~mixop
            ~arity
        with
        | Constructor_registry.Missing ->
          family_blocked
            ("deterministic output pattern `"
             ^ Il.Print.string_of_exp output_exp
             ^ "` has no emitted constructor registry entry")
        | Constructor_registry.Ambiguous entries ->
          Family_blocked
            [ "deterministic output pattern `"
              ^ Il.Print.string_of_exp output_exp
              ^ "` is ambiguous in constructor registry: "
              ^ (entries
                 |> List.map (fun entry ->
                   entry.Constructor_registry.constructor_op)
                 |> String.concat ", ")
            ]
        | Constructor_registry.Found target ->
          let entries =
            registry_family_entries ctx source_category static_args_key
          in
          let non_emitted =
            entries
            |> List.filter (fun entry ->
              entry.Constructor_registry.status <> Constructor_registry.Emitted)
          in
          if non_emitted <> [] then
            Family_blocked
              [ "deterministic output category `"
                ^ source_category
                ^ "` has non-emitted constructor entries, so constructor-disjoint refutation is not source-complete"
              ]
          else
            let alternatives =
              entries
              |> List.filter (fun entry ->
                not (same_constructor_surface entry target))
              |> unique_entries
            in
            if alternatives = [] then
              Family_blocked
                [ "deterministic output category `"
                  ^ source_category
                  ^ "` has no emitted alternative constructors to refute the requested constructor"
                ]
            else
              if
                alternatives
                |> List.exists (fun entry ->
                  not
                    (Runtime_truth_constructor_pattern.payload_sorts_complete
                       entry))
              then
                Family_blocked
                  [ "deterministic output category `"
                    ^ source_category
                    ^ "` has alternative constructors whose payload sorts are not materialized"
                  ]
              else
                Family_supported { alternatives })
  | _ ->
    family_blocked
      ("deterministic output component `"
       ^ Il.Print.string_of_exp output_exp
       ^ "` is not a top-level source constructor pattern")

let deterministic_case ctx rel_id exp =
  match Analysis.Function_graph.find_relation (Context.function_graph ctx) rel_id with
  | None -> Not_deterministic_case
  | Some relation ->
    let relation_shape = Relation_shape.of_relation relation in
    (match relation_shape.Relation_shape.decision with
    | Relation_shape.Deterministic_candidate shape ->
      let input_count = List.length shape.inputs in
      let expected_count = input_count + 1 in
      (match
         Analysis.Relation_graph.exp_components_for_count expected_count exp
       with
      | None ->
        blocked
          ("deterministic relation `"
           ^ rel_id
           ^ "` premise does not match the source relation arity")
      | Some components ->
        (match split_prefix input_count components with
        | Some (inputs, [ output ]) ->
          (match output_constructor_family ctx output with
          | Family_supported family ->
            Supported_case { shape; inputs; family }
          | Family_blocked blockers -> Blocked_case blockers)
        | Some _ | None ->
          blocked
            ("deterministic relation `"
             ^ rel_id
             ^ "` premise does not have exactly one output component")))
    | Relation_shape.Static_validation _
    | Relation_shape.Runtime_predicate _
    | Relation_shape.Execution _
    | Relation_shape.Unknown _ -> Not_deterministic_case)

let check ctx ~rel_id ~exp =
  match deterministic_case ctx rel_id exp with
  | Not_deterministic_case -> Not_deterministic
  | Supported_case _ -> Supported
  | Blocked_case blockers -> Blocked blockers

let relation_call rel_id inputs =
  App (Naming.relation_op rel_id, inputs)

let lower_input_values ctx env origin exps =
  let results = List.map (Expr_translate.lower_value ctx env origin) exps in
  let guards, diagnostics = Expr_result.append_result_metadata results in
  Expr_result.terms results, guards, diagnostics

let condition_vars = function
  | EqCondition (EqCond (left, right) | MatchCond (left, right))
  | RewriteCond (left, right) ->
    Condition_closure.term_vars left @ Condition_closure.term_vars right
  | EqCondition (MembershipCond (term, _) | BoolCond term) ->
    Condition_closure.term_vars term

let local_names env lhs rhs prefix_conditions exp =
  let source_names =
    Il.Free.(free_exp exp).varid |> Il.Free.Set.elements
  in
  Local_name.empty
  |> fun names -> Local_name.reserve_sources names source_names
  |> fun names ->
  Local_name.reserve_existing_many names
    (Expr_env.bound_vars env
     @ Condition_closure.term_vars lhs
     @ Condition_closure.term_vars rhs
     @ List.concat_map condition_vars prefix_conditions)

let alternative_rule
    ctx helper_name origin label lhs rhs prefix_conditions result_var input_guards entry =
  match constructor_pattern helper_name origin entry with
  | None -> None
  | Some pattern ->
    let conditions =
      (prefix_conditions
       @ List.map (fun condition -> EqCondition condition) input_guards
       @ [ EqCondition (MatchCond (pattern.term, result_var)) ])
      |> Condition_closure.normalize_rule_conditions
           ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
           [ lhs ]
    in
    Some
      (pattern.declarations
       @ [ generated
             helper_name
             origin
             (crl
                ~label:(label ^ "-" ^ entry.Constructor_registry.constructor_op)
                lhs
                rhs
                conditions)
         ])

let materialize
    ?(prefix_conditions = [])
    ctx
    ~helper_name
    ~origin
    ~env
    ~label
    ~lhs
    ~rhs
    ~rel_id
    ~exp
  =
  match deterministic_case ctx rel_id.it exp with
  | Not_deterministic_case -> Not_deterministic_materialization
  | Blocked_case blockers ->
    Materialization_blocked { diagnostics = []; blockers }
  | Supported_case { shape; inputs; family } ->
    let input_terms, input_guards, input_diagnostics =
      lower_input_values ctx env origin inputs
    in
    let output_sort = Expr_translate.carrier_sort_of_typ shape.output.typ in
    (match input_terms, output_sort with
    | Some input_terms, Some output_sort ->
      let names = local_names env lhs rhs prefix_conditions exp in
      let result_var, _ =
        Local_name.fresh_typed names Local_name.Result output_sort
      in
      let deterministic_call = relation_call rel_id input_terms in
      let input_guards =
        input_guards @ [ MatchCond (result_var, deterministic_call) ]
      in
      let statements =
        family.alternatives
        |> List.filter_map (fun entry ->
          alternative_rule
            ctx
            helper_name
            origin
            label
            lhs
            rhs
            prefix_conditions
            result_var
            input_guards
            entry)
        |> List.concat
      in
      if statements = [] then
        Materialization_blocked
          { diagnostics = input_diagnostics
          ; blockers =
              [ "deterministic premise has no materialized alternative-constructor refuter rules"
              ]
          }
      else
        let diagnostics =
          statements
          |> List.concat_map (fun statement ->
            match statement.Maude_ir.node with
            | Maude_ir.Crl (_label, lhs, rhs, conditions) ->
              Condition_admissibility.crl_admissibility_diagnostics
                ctx
                origin
                lhs
                rhs
                conditions
            | _ -> [])
        in
        Materialized
          { statements
          ; diagnostics = input_diagnostics @ diagnostics
          }
    | None, _ ->
      Materialization_blocked
        { diagnostics = input_diagnostics
        ; blockers =
            [ "deterministic relation input expressions did not lower to already-bound Maude values"
            ]
        }
    | _, None ->
      Materialization_blocked
        { diagnostics = input_diagnostics
        ; blockers =
            [ "deterministic relation output carrier sort is unknown"
            ]
        })
