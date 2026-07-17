open Il.Ast
open Maude_ir
open Util.Source

include Premise_result

let unsupported = Premise_diagnostic.unsupported
let source_echo_prem = Premise_diagnostic.source_echo_prem
let origin_for_premise = Premise_diagnostic.origin_for_premise
let unsupported_prem = Premise_diagnostic.unsupported_prem
let unsupported_rulepr_args = Premise_diagnostic.unsupported_rulepr_args

let conditions_bound_vars = Condition_closure.conditions_bound_vars

let with_conditions = Premise_state.with_conditions

let add_introduced_bindings = Premise_state.add_introduced_bindings

let align_source_conditions result =
  match result.enabledness_condition_blocks, result.eq_conditions with
  | [], _ :: _ ->
    { result with
      enabledness_condition_blocks =
        [ Source_conditions result.eq_conditions ]
    }
  | [], [] | _ :: _, _ -> result

let rec translate_premise_candidate
    names
    ?(allow_runtime_search = false)
    ?(discharge_static_validation = true)
    ?(future_prems = [])
    ?(escape_source_ids = [])
    ?(blocked_witness_source_ids = [])
    ?(factor_head_domains = false)
    ?lhs_bound_vars
    ctx
    env
    ~bound_vars
    parent_origin
    prem =
  let lhs_bound_vars = Option.value ~default:bound_vars lhs_bound_vars in
  let origin = origin_for_premise parent_origin prem in
  let env = Expr_env.with_condition_bound_vars env bound_vars in
  let result, names =
  match prem.it with
  | IfPr exp ->
    Premise_if.lower
      names ctx env ~bound_vars ~lhs_bound_vars ~future_prems
      ~factor_head_domains origin exp
  | LetPr (quants, lhs, rhs) ->
    let ids =
      quants
      |> List.filter_map (fun quant ->
        match quant.it with
        | ExpP (id, _) -> Some id.it
        | TypP _ | DefP _ | GramP _ -> None)
    in
    let lhs_result, names =
      Expr_translate.lower_pattern_with_bindings_named names ctx env origin lhs
    in
    let rhs_result = Expr_translate.lower_value ctx env origin rhs in
    (match lhs_result.pattern_term, rhs_result.term with
    | Some lhs_term, Some rhs ->
      let env_after =
        add_introduced_bindings ~ids env lhs_result.introduced_bindings
      in
      let conditions = rhs_result.guards @ [ MatchCond (lhs_term, rhs) ] @ lhs_result.pattern_guards in
      ( { (with_conditions ctx
           env_after
           bound_vars
           conditions
           (lhs_result.pattern_diagnostics @ rhs_result.diagnostics))
        with
        let_bound_ids = [ ids ]
        }
      , names )
    | _ ->
      ( { (empty_with_env ~bound_vars env) with
        let_bound_ids = [ ids ]
      ; diagnostics =
          lhs_result.pattern_diagnostics @ rhs_result.diagnostics
          @ [ unsupported
                ~ctx ~origin ~constructor:"Premise/LetPr"
                ~source_echo:(source_echo_prem prem)
                ~reason:
                  ("LetPr could not be lowered; outbound ids preserved in premise metadata: "
                   ^ String.concat ", " ids)
                ()
            ]
        }
      , names ))
  | ElsePr ->
    { (empty_with_env ~bound_vars env) with has_else = true }, names
  | RulePr (rel_id, args, mixop, _exp) ->
    if args <> [] then
      unsupported_rulepr_args ctx env ~bound_vars origin prem rel_id args, names
    else
    (match if discharge_static_validation then
       Premise_validation_skip
       .try_skip_rulepr_validation_witness
         ctx env ~bound_vars ~future_prems ~escape_source_ids origin prem rel_id mixop
     else None
     with
    | Some result -> result, names
    | None ->
      Premise_rule.lower
        names
        ctx
        env
        ~allow_runtime_search
        ~discharge_static_validation
        ~bound_vars
        ~blocked_witness_source_ids
        ~future_prems
        ~escape_source_ids
        ~factor_head_domains
        origin
        prem
        rel_id
        mixop)
  | IterPr (body, iterexp) ->
    Premise_iter.lower
      names
      ~lower_body:(fun names ctx env ~bound_vars origin prem ->
        translate_premise_candidate
          names
          ~allow_runtime_search
          ~discharge_static_validation
          ~lhs_bound_vars
          ~factor_head_domains
          ctx env ~bound_vars origin prem)
      ~discharge_static_validation
      ctx
      env
      ~bound_vars
      ~future_prems
      ~escape_source_ids
      origin
      ~prem
      ~body
      iterexp
  | NegPr _ ->
    ( unsupported_prem ctx env ~bound_vars origin "Premise/NegPr" prem
        "negated premises require a total Bool/complement helper, which is outside this pure DecD slice"
    , names )
  in
  let result = align_source_conditions result in
  { result with lhs_bound_vars = normalize_vars lhs_bound_vars }, names

let premise_source_names prem =
  let free = Il.Free.(free_prem prem).varid |> Il.Free.Set.elements in
  let bound = Il.Free.(bound_prem prem).varid |> Il.Free.Set.elements in
  List.sort_uniq String.compare (free @ bound)

let premise_block_source_names prems =
  prems |> List.concat_map premise_source_names
  |> List.sort_uniq String.compare

let eq_condition_vars = function
  | EqCond (left, right) | MatchCond (left, right) ->
    Condition_closure.term_vars left @ Condition_closure.term_vars right
  | MembershipCond (term, _) -> Condition_closure.term_vars term
  | BoolCond term -> Condition_closure.term_vars term

let reserve_enclosing names env bound_vars bound_terms bound_conditions =
  let existing =
    bound_vars @ Expr_env.bound_vars env
    @ List.concat_map Condition_closure.term_vars bound_terms
    @ List.concat_map eq_condition_vars bound_conditions
  in
  Local_name.reserve_existing_many names existing

let translate_premise_named
    names
    ?allow_runtime_search
    ?discharge_static_validation
    ?future_prems
    ?escape_source_ids
    ?blocked_witness_source_ids
    ?factor_head_domains
    ?lhs_bound_vars
    ctx env ~bound_vars origin prem =
  let incoming_names = names in
  let stage = Context.begin_stage ctx in
  let staged = Context.staged stage in
  let names = Local_name.reserve_sources names (premise_source_names prem) in
  let names = reserve_enclosing names env bound_vars [] [] in
  let result, names =
    translate_premise_candidate
    names
    ?allow_runtime_search
    ?discharge_static_validation
    ?future_prems
    ?escape_source_ids
    ?blocked_witness_source_ids
    ?factor_head_domains
    ?lhs_bound_vars
    staged env ~bound_vars origin prem
  in
  let outcome = Premise_result.classify result in
  match outcome with
  | Premise_result.Complete _ ->
    Context.commit_stage stage;
    outcome, names
  | Blocked _ | Deferred _ -> outcome, incoming_names

let translate_premise
    ?allow_runtime_search
    ?discharge_static_validation
    ?future_prems
    ?escape_source_ids
    ?blocked_witness_source_ids
    ?factor_head_domains
    ?lhs_bound_vars
    ctx env ~bound_vars origin prem =
  fst
    (translate_premise_named
       Local_name.empty
       ?allow_runtime_search
       ?discharge_static_validation
       ?future_prems
       ?escape_source_ids
       ?blocked_witness_source_ids
       ?factor_head_domains
       ?lhs_bound_vars
       ctx env ~bound_vars origin prem)

let translate_premises_named
    names
    ?(allow_runtime_search = false)
    ?(discharge_static_validation = true)
    ?(factor_head_domains = false)
    ?(condition_declarations = [])
    ctx env ?(bound_conditions = []) ?(escape_source_ids = []) ~bound_terms origin prems =
  let incoming_names = names in
  let names =
    Local_name.reserve_sources names (premise_block_source_names prems)
  in
  let names = reserve_enclosing names env [] bound_terms bound_conditions in
  let base_pattern_certificate =
    Condition_pattern_certificate.union
      (Condition_closure.source_constructor_certificate ctx)
      (Condition_pattern_certificate.generated condition_declarations)
  in
  let lhs_term_vars =
    bound_terms
    |> List.map Condition_closure.term_vars
    |> List.concat
    |> normalize_vars
  in
  let lhs_bound_vars =
    conditions_bound_vars
      ~constructor_op:base_pattern_certificate
      lhs_term_vars bound_conditions
  in
  let bound_vars = lhs_bound_vars in
  let stalled_fatal_diagnostics stalled =
    stalled
    |> List.concat_map (fun (_prem, diagnostics) ->
      List.filter Diagnostics.is_fatal diagnostics)
  in
  let no_progress_result acc stalled =
    match stalled_fatal_diagnostics stalled with
    | _ :: _ as diagnostics ->
      Premise_result.blocked (acc.diagnostics @ diagnostics)
    | [] ->
      (match stalled with
      | [] -> Premise_result.classify acc
      | (prem, diagnostics) :: _ ->
        let prem_origin = origin_for_premise origin prem in
        Premise_result.blocked
          (acc.diagnostics @ diagnostics
            @ [ unsupported
                  ~ctx
                  ~origin:prem_origin
                  ~constructor:"Premise/dependency-cycle"
                  ~source_echo:(source_echo_prem prem)
                  ~reason:
                    "premise conditions cannot be ordered so every generated Maude condition uses only variables bound by the enclosing lhs or earlier admissible premises"
                  ~suggestion:
                    "Keep this premise block Unsupported until the source dependency cycle is removed or a source-derived rewrite/search helper can introduce the witness"
                  ()
              ]))
  in
  let rec pass acc names progressed deferred = function
    | [] ->
      (match List.rev deferred with
      | [] -> Premise_result.classify acc, names
      | pending when progressed ->
        pass acc names false [] (List.map fst pending)
      | stalled -> no_progress_result acc stalled, names)
    | prem :: rest ->
      let future_prems = rest @ (List.rev_map fst deferred) in
      let stage = Context.begin_stage ctx in
      let staged = Context.staged stage in
      let result, candidate_names =
        translate_premise_candidate
          names
          ~allow_runtime_search
          ~discharge_static_validation
          ~future_prems
          ~escape_source_ids
          ~blocked_witness_source_ids:acc.blocked_witness_source_ids
          ~factor_head_domains
          ~lhs_bound_vars
          staged
          acc.env_after
          ~bound_vars:acc.bound_vars_after
          origin
          prem
      in
      (match Premise_result.classify result with
      | Complete result ->
        (* Candidate retries use the same declaration-backed pattern proof as
           final condition normalization.  Thus a committed producer extends
           the traversal bound set exactly when its emitted condition can be
           oriented soundly; source conjunction order remains irrelevant. *)
        let pattern_certificate =
          Condition_pattern_certificate.union
            base_pattern_certificate
            (Condition_pattern_certificate.union
               acc.pattern_certificate
               (Premise_result.pattern_certificate result))
        in
        let bound_vars_after =
          Condition_closure.conditions_bound_vars
            ~constructor_op:pattern_certificate
            acc.bound_vars_after (Premise_result.eq_conditions result)
          |> fun bound ->
          Condition_closure.rule_conditions_bound_vars
            ~constructor_op:pattern_certificate bound
            (Premise_result.rule_conditions result)
          |> normalize_vars
        in
        Context.commit_stage stage;
        let acc = append_complete acc result in
        pass { acc with bound_vars_after } candidate_names true deferred rest
      | Deferred (_, diagnostics) ->
        pass acc names progressed ((prem, diagnostics) :: deferred) rest
      | Blocked diagnostics ->
        Premise_result.blocked (acc.diagnostics @ diagnostics), names)
  in
  let outcome, names =
    pass (empty_with_env ~lhs_bound_vars ~bound_vars env) names false [] prems
  in
  match outcome with
  | Complete result -> Premise_result.finalize_condition_bound_vars result, names
  | Blocked _ as blocked -> blocked, incoming_names
  | Deferred (deferral, diagnostics) ->
    let deferral =
      match deferral with
      | ListN_premise_admissibility -> "ListN premise admissibility"
      | Binding_membership_admissibility -> "binding membership admissibility"
      | Runtime_predicate_binding_admissibility ->
        "runtime predicate binding admissibility"
    in
    let invariant_origin, source_echo =
      match prems with
      | [] -> origin, None
      | prem :: _ ->
        origin_for_premise origin prem, Some (source_echo_prem prem)
    in
    Premise_result.blocked
      (diagnostics
       @ [ unsupported
             ~ctx
             ~origin:invariant_origin
             ~constructor:"Premise/internal-invariant/deferred-after-fixpoint"
             ?source_echo
             ~reason:
               ("premise retry reached its fixpoint but returned an unresolved "
                ^ deferral ^ " deferral")
             ~suggestion:
               "Report this translator invariant; the retry loop must convert every stalled deferral into a structured Blocked result"
             ()
         ]),
    incoming_names

let translate_premises
    ?allow_runtime_search
    ?discharge_static_validation
    ?factor_head_domains
    ?condition_declarations
    ctx env ?bound_conditions ?escape_source_ids ~bound_terms origin prems =
  fst
    (translate_premises_named
       Local_name.empty
       ?allow_runtime_search
       ?discharge_static_validation
       ?factor_head_domains
       ?condition_declarations
       ctx env ?bound_conditions ?escape_source_ids ~bound_terms origin prems)
