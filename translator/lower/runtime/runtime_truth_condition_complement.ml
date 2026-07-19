open Il.Ast
open Util.Source

type proof =
  { positive : Maude_ir.eq_condition list
  ; failures : Maude_ir.eq_condition list list
  ; diagnostics : Diagnostics.t list
  }

type equality_proof =
  { left : Maude_ir.term
  ; right : Maude_ir.term
  ; conditions : proof
  }

let source_condition_blocker origin exp ~reason =
  Runtime_truth_totality.blocker
    origin exp "source-condition-certificate" reason

let false_conditions ?bound_vars ctx env origin op left_exp right_exp =
  match
    Runtime_truth_totality.check ?bound_vars ctx env origin left_exp,
    Runtime_truth_totality.check ?bound_vars ctx env origin right_exp
  with
  | Ok (), Ok () ->
    let left = Expr_translate.lower_value ctx env origin left_exp in
    let right = Expr_translate.lower_value ctx env origin right_exp in
    (match left.term, right.term, op with
    | Some left_term, Some right_term, (`EqOp | `NeOp) ->
      let false_op = if op = `EqOp then "_=/=_" else "_==_" in
      Ok
        ( left.guards @ right.guards
          @ [ Maude_ir.BoolCond
                (Maude_ir.App (false_op, [ left_term; right_term ]))
            ]
        , left.diagnostics @ right.diagnostics )
    | _ ->
      Error
        [ Runtime_truth_totality.blocker origin left_exp "lowering"
            "certified operand did not lower to an equality-comparable Maude term"
        ])
  | Error left, Error right -> Error (left @ right)
  | Error blockers, Ok () | Ok (), Error blockers -> Error blockers

let index_domain_blocker origin exp reason =
  Runtime_truth_totality.blocker origin exp "index-domain" reason

let result_has_fatal (result : Expr_result.result) =
  List.exists Diagnostics.is_fatal result.diagnostics

let first_failure_alternatives domains final_condition =
  let rec loop prefix alternatives = function
    | [] -> List.rev (List.rev_append prefix [ final_condition ] :: alternatives)
    | domain :: rest ->
      let failure =
        List.rev_append prefix
          [ Maude_ir.BoolCond (Maude_ir.App ("not_", [ domain ])) ]
      in
      loop (Maude_ir.BoolCond domain :: prefix) (failure :: alternatives) rest
  in
  loop [] [] domains

let equality_operands = function
  | Maude_ir.App ("_==_", [ left; right ]) -> Some (left, right)
  | Maude_ir.Var _ | Maude_ir.Const _ | Maude_ir.Qid _ | Maude_ir.App _ -> None

let same_equality (left, right) (actual_left, actual_right) =
  (left = actual_left && right = actual_right)
  || (left = actual_right && right = actual_left)

let condition_matches_domain domain = function
  | Maude_ir.BoolCond term ->
    term = domain
    || (match equality_operands domain, equality_operands term with
        | Some expected, Some actual -> same_equality expected actual
        | None, _ | _, None -> false)
  | Maude_ir.EqCond (left, right)
  | Maude_ir.MatchCond (left, right) ->
    (match equality_operands domain with
    | Some expected -> same_equality expected (left, right)
    | None -> false)
  | Maude_ir.MembershipCond _ -> false

let condition_is_domain domains condition =
  List.exists (fun domain -> condition_matches_domain domain condition) domains

let constrained_first_failures constraints domains final_condition =
  first_failure_alternatives domains final_condition
  |> List.map (fun failure -> constraints @ failure)

let stable_unique items =
  List.fold_left
    (fun unique item -> if List.mem item unique then unique else item :: unique)
    [] items
  |> List.rev

let false_condition_alternatives
    ?bound_vars ctx env origin op left_exp right_exp =
  match
    Runtime_truth_totality.definedness ?bound_vars ctx env origin left_exp,
    Runtime_truth_totality.definedness ?bound_vars ctx env origin right_exp
  with
  | Error left, Error right -> Error (left @ right)
  | Error blockers, Ok _ | Ok _, Error blockers -> Error blockers
  | Ok
      { domains = left_domains
      ; guards = left_guards
      ; diagnostics = left_diagnostics
      },
    Ok
      { domains = right_domains
      ; guards = right_guards
      ; diagnostics = right_diagnostics
      } ->
    let domains = left_domains @ right_domains in
    if domains = [] && left_guards = [] && right_guards = [] then
      (match
         false_conditions ?bound_vars ctx env origin op left_exp right_exp
       with
      | Ok (conditions, diagnostics) -> Ok ([ conditions ], diagnostics)
      | Error blockers -> Error blockers)
    else
      let left = Expr_translate.lower_value ctx env origin left_exp in
      let right = Expr_translate.lower_value ctx env origin right_exp in
      (match left.term, right.term, op with
      | Some left_term, Some right_term, (`EqOp | `NeOp)
        when left.guards = [] && right.guards = []
             && not (result_has_fatal left) && not (result_has_fatal right) ->
        let false_op = if op = `EqOp then "_=/=_" else "_==_" in
        let final_condition =
          Maude_ir.BoolCond
            (Maude_ir.App (false_op, [ left_term; right_term ]))
        in
        Ok
          ( constrained_first_failures [] domains final_condition
          , left_diagnostics @ right_diagnostics
            @ left.diagnostics @ right.diagnostics )
      | Some left_term, Some right_term, (`EqOp | `NeOp)
        when not (result_has_fatal left) && not (result_has_fatal right) ->
        let false_op = if op = `EqOp then "_=/=_" else "_==_" in
        let final_condition =
          Maude_ir.BoolCond
            (Maude_ir.App (false_op, [ left_term; right_term ]))
        in
        let constraints =
          (left.guards @ right.guards)
          |> List.filter (fun condition -> not (condition_is_domain domains condition))
        in
        Ok
          ( constrained_first_failures constraints domains final_condition
          , left_diagnostics @ right_diagnostics
            @ left.diagnostics @ right.diagnostics )
      | _ ->
        Error
          [ index_domain_blocker origin left_exp
              "indexed equality operands did not lower to guard-free equality-comparable Maude terms"
          ])

let source_equality_alternatives
    ?bound_vars ctx env origin left_exp right_exp =
  match
    Runtime_truth_totality.definedness ?bound_vars ctx env origin left_exp,
    Runtime_truth_totality.definedness ?bound_vars ctx env origin right_exp
  with
  | Error left, Error right -> Error (left @ right)
  | Error blockers, Ok _ | Ok _, Error blockers -> Error blockers
  | Ok
      { domains = left_domains
      ; guards = _
      ; diagnostics = left_diagnostics
      },
    Ok
      { domains = right_domains
      ; guards = _
      ; diagnostics = right_diagnostics
      } ->
    let left = Expr_translate.lower_value ctx env origin left_exp in
    let right = Expr_translate.lower_value ctx env origin right_exp in
    (match left.term, right.term with
    | Some left_term, Some right_term
      when not (result_has_fatal left) && not (result_has_fatal right) ->
      let requirements =
        left.guards @ right.guards |> stable_unique
      in
      let domains = left_domains @ right_domains in
      let constraints =
        requirements
        |> List.filter (fun condition -> not (condition_is_domain domains condition))
      in
      let failure =
        constrained_first_failures constraints domains
          (Maude_ir.BoolCond
             (Maude_ir.App ("_=/=_", [ left_term; right_term ])))
      in
      Ok
        { left = left_term
        ; right = right_term
        ; conditions =
            { positive = requirements
            ; failures = failure
            ; diagnostics =
                left_diagnostics @ right_diagnostics
                @ left.diagnostics @ right.diagnostics
            }
        }
    | _ ->
      Error
        [ index_domain_blocker origin left_exp
            "structurally total source equality operands did not lower to comparable Maude terms"
        ])

let domain_first_failures domains =
  let rec loop prefix failures = function
    | [] -> List.rev failures
    | domain :: rest ->
      let failure =
        List.rev_append prefix
          [ Maude_ir.BoolCond (Maude_ir.App ("not_", [ domain ])) ]
      in
      loop (Maude_ir.BoolCond domain :: prefix) (failure :: failures) rest
  in
  loop [] [] domains

let source_definedness_alternatives
    ?bound_vars ?(assumed = []) ctx env origin exp =
  match Runtime_truth_totality.definedness ?bound_vars ctx env origin exp with
  | Error blockers -> Error blockers
  | Ok { domains; guards; diagnostics = domain_diagnostics } ->
    let lowered = Expr_translate.lower_value ctx env origin exp in
    (match lowered.term with
    | Some _ when not (result_has_fatal lowered) ->
      let emitted = stable_unique lowered.guards in
      let domains = stable_unique domains in
      let guards = stable_unique guards in
      let unproved_guards =
        emitted
        |> List.filter (fun condition ->
          not (condition_is_domain domains condition)
          && (not (List.mem condition guards)
              || not (List.mem condition assumed)))
      in
      if unproved_guards <> []
      then
        Error
          [ Runtime_truth_totality.blocker origin exp "binding-domain"
              "binding RHS has a non-domain guard that is not established by earlier source conditions"
          ]
      else
        let positive =
          stable_unique
            (emitted
             @ List.map (fun domain -> Maude_ir.BoolCond domain) domains)
        in
        Ok
          { positive
          ; failures = domain_first_failures domains
          ; diagnostics = domain_diagnostics @ lowered.diagnostics
          }
    | Some _ | None ->
      Error
        [ Runtime_truth_totality.blocker origin exp "binding-domain"
            "binding RHS did not lower to a total value with explicit source-definedness guards"
        ])

let dual_relational_comparison = function
  | `LtOp -> Some "_>=_"
  | `GtOp -> Some "_<=_"
  | `LeOp -> Some "_>_"
  | `GeOp -> Some "_<_"
  | `EqOp | `NeOp -> None

let rec structural_boolean_proof ?bound_vars ctx env origin exp =
  let lowered = Expr_translate.lower_bool_condition ctx env origin exp in
  let lowering_blocker () =
    Error
      [ Runtime_truth_totality.blocker origin exp "source-boolean-structure"
          "source Boolean structure did not lower without fatal diagnostics" ]
  in
  match exp.it with
  | CmpE (op, (`NatT | `IntT | `RatT | `RealT), left, right) ->
    (match dual_relational_comparison op with
    | None -> Error []
    | Some dual ->
      (match
         Runtime_truth_totality.definedness ?bound_vars ctx env origin left,
         Runtime_truth_totality.definedness ?bound_vars ctx env origin right
       with
      | Error left, Error right -> Error (left @ right)
      | Error blockers, Ok _ | Ok _, Error blockers -> Error blockers
      | Ok
          { domains = left_domains
          ; guards = left_guards
          ; diagnostics = left_diagnostics
          },
        Ok
          { domains = right_domains
          ; guards = right_guards
          ; diagnostics = right_diagnostics
          } ->
        let left_result = Expr_translate.lower_value ctx env origin left in
        let right_result = Expr_translate.lower_value ctx env origin right in
        (match lowered.term, left_result.term, right_result.term with
        | Some positive_term, Some left_term, Some right_term
          when not
            (List.exists Diagnostics.is_fatal
               (lowered.diagnostics @ left_result.diagnostics
                @ right_result.diagnostics)) ->
          let domains = left_domains @ right_domains in
          let guards =
            left_guards @ right_guards @ lowered.guards
            |> stable_unique
          in
          let constraints =
            guards
            |> List.filter (fun condition ->
              not (condition_is_domain domains condition))
          in
          let final_condition =
            Maude_ir.BoolCond
              (Maude_ir.App (dual, [ left_term; right_term ]))
          in
          Ok
            { positive = lowered.guards @ [ Maude_ir.BoolCond positive_term ]
            ; failures =
                constrained_first_failures constraints domains final_condition
            ; diagnostics =
                left_diagnostics @ right_diagnostics @ lowered.diagnostics
                @ left_result.diagnostics @ right_result.diagnostics
            }
        | _ -> lowering_blocker ())))
  | BinE ((`AndOp | `OrOp as op), `BoolT, left, right) ->
    (match
       structural_boolean_proof ?bound_vars ctx env origin left,
       structural_boolean_proof ?bound_vars ctx env origin right,
       lowered.term
     with
    | Ok left_proof, Ok right_proof, Some positive_term
      when not (List.exists Diagnostics.is_fatal lowered.diagnostics) ->
      let failure =
        match op with
        | `OrOp ->
          left_proof.failures
          |> List.concat_map (fun left_failure ->
            right_proof.failures
            |> List.map (fun right_failure ->
              left_failure @ right_failure))
        | `AndOp ->
          left_proof.failures
          @ (right_proof.failures
             |> List.map (fun right_failure ->
               left_proof.positive @ right_failure))
        | _ -> []
      in
      Ok
        { positive = lowered.guards @ [ Maude_ir.BoolCond positive_term ]
        ; failures = failure
        ; diagnostics =
            lowered.diagnostics @ left_proof.diagnostics
            @ right_proof.diagnostics
        }
    | Error (_ :: _ as blockers), _, _ -> Error blockers
    | _, Error (_ :: _ as blockers), _ -> Error blockers
    | _ -> lowering_blocker ())
  | _ -> Error []

let source_boolean_alternatives ?bound_vars ctx env origin exp =
  match structural_boolean_proof ?bound_vars ctx env origin exp with
  | Ok proof -> Ok proof
  | Error (_ :: _ as structural_blockers) -> Error structural_blockers
  | Error [] ->
  (match exp.it with
  | CmpE ((`EqOp | `NeOp as op), _, left, right) ->
    let lowered = Expr_translate.lower_bool_condition ctx env origin exp in
    (match lowered.term with
    | None ->
      Error
        [ Runtime_truth_totality.blocker origin exp "lowering"
            "source equality observer did not lower to a Maude Bool term"
        ]
    | Some _ when result_has_fatal lowered ->
      Error
        [ Runtime_truth_totality.blocker origin exp "lowering"
            "source equality observer retained a fatal lowering diagnostic"
        ]
    | Some term ->
      (match
         false_condition_alternatives
           ?bound_vars ctx env origin op left right
       with
      | Error blockers -> Error blockers
      | Ok (failures, diagnostics) ->
        Ok
          { positive = lowered.guards @ [ Maude_ir.BoolCond term ]
          ; failures
          ; diagnostics = lowered.diagnostics @ diagnostics
          }))
  | _ ->
    (match Runtime_truth_totality.check ?bound_vars ctx env origin exp with
    | Error blockers -> Error blockers
    | Ok () ->
      let lowered = Expr_translate.lower_bool_condition ctx env origin exp in
      (match lowered.term with
      | None ->
        Error
          [ Runtime_truth_totality.blocker origin exp "lowering"
              "structurally total source Boolean observer did not lower to a Maude Bool term"
          ]
      | Some _ when result_has_fatal lowered ->
        Error
          [ Runtime_truth_totality.blocker origin exp "lowering"
              "structurally total source Boolean observer retained a fatal lowering diagnostic"
          ]
      | Some term ->
        let positive = lowered.guards @ [ Maude_ir.BoolCond term ] in
        if lowered.guards = [] then
          Ok
            { positive
            ; failures =
                [ [ Maude_ir.BoolCond (Maude_ir.App ("not_", [ term ])) ] ]
            ; diagnostics = lowered.diagnostics
            }
        else
          Error
            [ Runtime_truth_totality.blocker origin exp "guarded-boolean"
                "generic Boolean complement requires a guard-free total source observer or an explicit source-ordered guard-domain proof"
            ])))
