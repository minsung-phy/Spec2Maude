type t = Source_condition_certificate_internal.t

type lookup =
  | Missing
  | Found of int * Maude_ir.eq_condition list list
  | Ambiguous

type failure =
  { origin : Origin.t
  ; constructor : string
  ; reason : string
  ; source_echo : string option
  }

type proof_failure =
  { positive : Maude_ir.eq_condition list
  ; blockers : failure list
  }

let rec is_prefix prefix items =
  match prefix, items with
  | [], _ -> true
  | left :: prefix, right :: items when left = right -> is_prefix prefix items
  | _ -> false

let rec substitute_term subst = function
  | Maude_ir.Var name as term ->
    (match List.assoc_opt name subst with
    | Some replacement -> replacement
    | None -> term)
  | Maude_ir.Const _ | Maude_ir.Qid _ as term -> term
  | Maude_ir.App (name, args) ->
    Maude_ir.App (name, List.map (substitute_term subst) args)

let substitute_condition subst = function
  | Maude_ir.EqCond (left, right) ->
    Maude_ir.EqCond (substitute_term subst left, substitute_term subst right)
  | Maude_ir.MatchCond (left, right) ->
    Maude_ir.MatchCond (substitute_term subst left, substitute_term subst right)
  | Maude_ir.BoolCond term ->
    Maude_ir.BoolCond (substitute_term subst term)
  | Maude_ir.MembershipCond (term, sort) ->
    Maude_ir.MembershipCond (substitute_term subst term, sort)

let specialize subst (certificate : t) =
  { Source_condition_certificate_internal.positive =
      List.map (substitute_condition subst) certificate.positive
  ; failure =
      List.map (List.map (substitute_condition subst)) certificate.failure
  }

let lookup (certificates : t list) conditions =
  let matches =
    certificates
    |> List.filter_map (fun (certificate : t) ->
      if is_prefix certificate.positive conditions then
        Some (List.length certificate.positive, certificate.failure)
      else
        None)
    |> List.sort_uniq Stdlib.compare
    |> List.sort (fun (left, _) (right, _) -> Int.compare right left)
  in
  match matches with
  | [] -> Missing
  | (count, failure) :: rest ->
    let same_length =
      rest
      |> List.filter_map (fun (other_count, other_failure) ->
        if other_count = count then Some other_failure else None)
      |> List.sort_uniq Stdlib.compare
    in
    (match same_length with
    | [] -> Found (count, failure)
    | [ other ] when other = failure -> Found (count, failure)
    | _ -> Ambiguous)

let proof_failure ~positive blockers =
  match positive, blockers with
  | [], _ | _, [] -> None
  | _ -> Some { positive; blockers }

let failure ~origin ~constructor ~reason ?source_echo () =
  { origin; constructor; reason; source_echo }

let specialize_proof_failure subst failure =
  { failure with
    positive = List.map (substitute_condition subst) failure.positive
  }

let blockers failures conditions =
  failures
  |> List.filter (fun failure -> is_prefix failure.positive conditions)
  |> List.concat_map (fun failure -> failure.blockers)
  |> List.sort_uniq Stdlib.compare

let mismatch origin source reason =
  Error
    [ Runtime_truth_total_equality.source_condition_blocker
        origin source ~reason ]

let prove_if ctx env ~bound_vars origin ~(source : Il.Ast.exp) ~emitted =
  match source.it with
  | Il.Ast.CmpE (`EqOp, _, left, right) ->
    (match
       Runtime_truth_total_equality.source_equality_alternatives
         ~bound_vars ctx env origin left right
     with
    | Error blockers -> Error blockers
    | Ok (_, _, _, _, diagnostics)
      when List.exists Diagnostics.is_fatal diagnostics ->
      mismatch origin source
        "source equality totality proof retained a fatal lowering diagnostic"
    | Ok (left, right, requirements, failure, _) ->
      (match
         Source_condition_certificate_internal.certify_equality
           ~bound_vars ~left ~right ~requirements ~failure emitted
       with
      | Some certificate -> Ok certificate
      | None ->
        mismatch origin source
          "emitted equality conditions are not the exact LHS-bound image of the source IfPr equality proof"))
  | _ ->
    (match
       Runtime_truth_total_equality.source_boolean_alternatives
         ~bound_vars ctx env origin source
     with
    | Error blockers -> Error blockers
    | Ok (_, _, diagnostics)
      when List.exists Diagnostics.is_fatal diagnostics ->
      mismatch origin source
        "source Boolean totality proof retained a fatal lowering diagnostic"
    | Ok (positive, failure, _) ->
      (match
         Source_condition_certificate_internal.certify
           ~bound_vars ~positive ~failure
       with
      | Some certificate when positive = emitted -> Ok certificate
      | Some _ | None ->
        mismatch origin source
          "emitted Boolean conditions are not the exact LHS-bound image of the source IfPr observer proof"))

let prove_binding ctx env ~bound_vars origin ~(source : Il.Ast.exp) ~emitted =
  match
    Runtime_truth_total_equality.source_definedness_alternatives
      ~bound_vars ctx env origin source
  with
  | Error blockers -> Error blockers
  | Ok (_, _, diagnostics)
    when List.exists Diagnostics.is_fatal diagnostics ->
    mismatch origin source
      "source binding-domain proof retained a fatal lowering diagnostic"
  | Ok (positive, failure, _) when positive = emitted ->
    (match positive with
    | [] -> Ok None
    | _ ->
      (match
         Source_condition_certificate_internal.certify
           ~bound_vars ~positive ~failure
       with
      | Some certificate -> Ok (Some certificate)
      | None ->
        mismatch origin source
          "binding RHS domain conditions use variables outside the immutable source lhs"))
  | Ok _ ->
    mismatch origin source
      "emitted binding conditions are not the exact source-ordered RHS domain guards"
