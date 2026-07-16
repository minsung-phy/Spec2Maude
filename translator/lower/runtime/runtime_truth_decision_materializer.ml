open Maude_ir

type item =
  { name : string
  ; origin : Origin.t
  ; request : Runtime_truth_decision_helper.request
  }

type complete =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

type result =
  | Complete of complete
  | Blocked of Diagnostics.t list

let complete_statements complete = complete.statements
let complete_diagnostics complete = complete.diagnostics

let generated name origin node =
  Maude_ir.generated ~provenance:(Maude_ir.Helper name) ~origin node

let helper_surface item =
  Runtime_truth_decision_helper.surface
    ~helper_name:item.name ~origin:item.origin item.request

let true_rule ctx item =
  let call =
    Runtime_truth_decision_helper.invocation ~helper_name:item.name item.request
  in
  let truth_condition =
    Runtime_truth_search_helper.rewrite_condition
      ~helper_name:item.request.truth_helper_name
      item.request.truth_request
  in
  let conditions =
    [ truth_condition ]
    |> Condition_closure.normalize_rule_conditions
         ~constructor_op:
           (Condition_pattern_certificate.generated
              (helper_surface item
               @ Runtime_truth_search_helper.surface
                   ~helper_name:item.request.truth_helper_name
                   ~origin:item.origin item.request.truth_request))
         [ call.lhs ]
  in
  let diagnostics =
    Condition_closure.crl_admissibility_diagnostics
      ~constructor_op:
        (Condition_pattern_certificate.generated
           (helper_surface item
            @ Runtime_truth_search_helper.surface
                ~helper_name:item.request.truth_helper_name
                ~origin:item.origin item.request.truth_request))
      ctx
      item.origin
      call.lhs
      call.true_rhs
      conditions
  in
  if List.exists Diagnostics.is_fatal diagnostics then
    [], diagnostics
  else
    ( [ generated
          item.name
          item.origin
          (crl
             ~label:(item.name ^ "-decision-true")
             call.lhs
             call.true_rhs
             conditions)
      ]
    , diagnostics )

let false_rule ctx item =
  let call =
    Runtime_truth_decision_helper.invocation ~helper_name:item.name item.request
  in
  let refutation =
    Runtime_truth_decision_refutation.materialize
      ctx
      ~helper_name:item.name
      ~origin:item.origin
      item.request
  in
  if List.exists Diagnostics.is_fatal refutation.diagnostics then
    [], [], refutation.diagnostics
  else
    let conditions =
      refutation.conditions
      |> Condition_closure.normalize_rule_conditions
           ~constructor_op:
             (Condition_pattern_certificate.generated
                (helper_surface item @ refutation.statements))
           [ call.lhs ]
    in
    match conditions with
    | [] -> [], refutation.statements, refutation.diagnostics
    | _ ->
      let diagnostics =
        Condition_closure.crl_admissibility_diagnostics
          ~constructor_op:
            (Condition_pattern_certificate.generated
               (helper_surface item @ refutation.statements))
          ctx
          item.origin
          call.lhs
          call.false_rhs
          conditions
      in
      if List.exists Diagnostics.is_fatal diagnostics then
        [], [], refutation.diagnostics @ diagnostics
      else
        ( [ generated
              item.name
              item.origin
              (crl
                 ~label:(item.name ^ "-decision-false")
                 call.lhs
                 call.false_rhs
                 conditions)
          ]
        , refutation.statements
        , refutation.diagnostics @ diagnostics )

let unsupported_false ctx item =
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin:item.origin
    ~constructor:"RuntimeTruthDecision/materializer/false-unimplemented"
    ~enclosing:
      (Diagnostic_provenance.enclosing
         ~context:(Context.enclosing_path ctx) item.origin)
    ~profile:(Context.profile_name ctx)
    ~reason:
      "runtime truth decision needs a source-complete false proof, but the refuter did not produce a usable false rule"
    ~suggestion:
      "Do not emit a partial truth decision surface; implement a source-complete no-hit/refutation helper before using runtimeTruthFalse"
    ~source_echo:(Runtime_truth_decision_helper.reason item.request)
    ()

let materialize_item ctx item =
  let true_statements, true_diagnostics = true_rule ctx item in
  let false_statements, refutation_statements, false_diagnostics =
    false_rule ctx item
  in
  let false_missing =
    match false_statements with
    | [] -> true
    | _ :: _ -> false
  in
  let diagnostics =
    true_diagnostics
    @ false_diagnostics
    @ (if false_missing then [ unsupported_false ctx item ] else [])
  in
  if false_missing || List.exists Diagnostics.is_fatal diagnostics then
    Blocked diagnostics
  else
    Complete
      { statements =
          helper_surface item @ true_statements
          @ refutation_statements @ false_statements
      ; diagnostics
      }

let materialize ctx items =
  let rec collect statements diagnostics = function
    | [] -> Complete { statements = List.rev statements |> List.concat;
                       diagnostics = List.rev diagnostics |> List.concat }
    | item :: rest ->
      (match materialize_item ctx item with
      | Complete complete ->
        collect
          (complete.statements :: statements)
          (complete.diagnostics :: diagnostics)
          rest
      | Blocked blocked ->
        let diagnostics =
          List.rev diagnostics |> List.concat |> fun complete -> complete @ blocked
        in
        Blocked diagnostics)
  in
  collect [] [] items
