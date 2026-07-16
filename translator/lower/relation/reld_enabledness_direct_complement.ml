open Maude_ir

let terms_match_general = Head_specialization.terms_match_general
let term_vars = Head_specialization.term_vars
let substitute_term = Head_specialization.substitute_term
let substitute_condition = Head_specialization.substitute_condition
let collect_head_subst = Head_specialization.collect_head_subst
let specialize_terms = Head_specialization.specialize_terms

type complement_atom =
  | Tautology
  | Negated of eq_condition list list
  | Atom_blocked of string

type complement_result =
  | Complete of
      { alternatives : rule_condition list list
      ; statements : generated list
      }
  | Blocked of string list

type condition_block =
  | Source_conditions of eq_condition list
  | Head_domain_conditions of eq_condition list

let vars_subset vars bound =
  List.for_all (fun var -> List.mem var bound) vars

let add_vars vars bound =
  vars
  |> List.fold_left
       (fun bound var -> if List.mem var bound then bound else var :: bound)
       bound

let conditions_bound bound conditions =
  conditions
  |> List.concat_map (fun condition ->
    match condition with
    | EqCond (left, right) | MatchCond (left, right) ->
      term_vars left @ term_vars right
    | BoolCond term | MembershipCond (term, _) -> term_vars term)
  |> fun vars -> vars_subset vars bound

let complement_atom known condition =
  if List.mem condition known then Tautology else
  match condition with
  | EqCond _ ->
    Atom_blocked "lowered equality has no explicit source total-observer certificate"
  | BoolCond _ ->
    Atom_blocked "lowered Boolean observer has no explicit source total-observer certificate"
  | MatchCond _ ->
    Atom_blocked "lowered pattern match has no explicit source structural complement certificate"
  | MembershipCond _ ->
    Atom_blocked "membership failure has no certified total Boolean complement"

let positive_condition_bound bound = function
  | MatchCond (pattern, subject)
    when vars_subset (term_vars subject) bound ->
    Some (add_vars (term_vars pattern) bound)
  | EqCond (left, right)
    when vars_subset (term_vars left @ term_vars right) bound -> Some bound
  | BoolCond term when vars_subset (term_vars term) bound -> Some bound
  | MembershipCond (term, _) when vars_subset (term_vars term) bound -> Some bound
  | EqCond _ | BoolCond _ | MembershipCond _ | MatchCond _ -> None

let condition_source = function
  | EqCond (left, right) -> Emit.render_term left ^ " = " ^ Emit.render_term right
  | MatchCond (left, right) -> Emit.render_term left ^ " := " ^ Emit.render_term right
  | MembershipCond (term, sort) ->
    Emit.render_term term ^ " : " ^ Maude_ir.sort_name sort
  | BoolCond term -> Emit.render_term term

let first_condition_difference left right =
  let rec loop index left right =
    match left, right with
    | [], [] -> "no differing condition"
    | [], _ :: _ -> "aligned provenance ended before emitted conditions"
    | _ :: _, [] -> "emitted conditions ended before aligned provenance"
    | left :: lefts, right :: rights ->
      if left = right then loop (index + 1) lefts rights
      else
        Printf.sprintf
          "condition %d provenance=`%s`, emitted=`%s`"
          index (condition_source left) (condition_source right)
  in
  loop 1 left right

let condition_alternative (prefix, negated) =
  List.map (fun condition -> EqCondition condition) prefix
  @ List.map (fun condition -> EqCondition condition) negated

let proof_blocker_text blocker =
  blocker.Source_condition_certificate.constructor ^ " at "
  ^ Origin.summary blocker.origin ^ ": " ^ blocker.reason

let rec split_prefix count acc items =
  if count = 0 then Some (List.rev acc, items) else
  match items with
  | item :: rest -> split_prefix (count - 1) (item :: acc) rest
  | [] -> None

let sequential_condition_complements
    ?certificate_ctx ?certificate_origin ?certificate_helper
    condition_certificates condition_failures known bound conditions =
  let lhs_bound_vars = bound in
  let rec loop index bound prefix candidates blockers statements = function
    | [] ->
      (match List.rev blockers with
      | [] ->
        Complete
          { alternatives = List.rev candidates |> List.map condition_alternative
          ; statements = List.rev statements |> List.concat
          }
      | blockers -> Blocked blockers)
    | (condition :: rest as conditions) ->
      let repeated = List.mem condition known || List.mem condition prefix in
      let continue_repeated () =
        match positive_condition_bound bound condition with
        | Some bound ->
          loop (index + 1) bound (condition :: prefix)
            candidates blockers statements rest
        | None ->
          loop (index + 1) bound prefix candidates
            (("condition " ^ string_of_int index
              ^ ": repeated source guard is not source-ordered") :: blockers)
            statements rest
      in
      (match Source_condition_certificate.lookup condition_certificates conditions with
      | Found (1, _) when repeated -> continue_repeated ()
      | Found (count, failures) ->
        (match split_prefix count [] conditions with
        | None ->
          loop (index + 1) bound prefix candidates
            (("condition " ^ string_of_int index
              ^ ": malformed source observer certificate length") :: blockers)
            statements rest
        | Some (positive, rest) ->
          if not (List.for_all (conditions_bound lhs_bound_vars) failures) then
            loop (index + count) bound prefix candidates
              (("condition " ^ string_of_int index
                ^ ": certified source observer complement uses a variable not bound by the immutable lhs")
               :: blockers)
              statements rest
          else
            let bound_after =
              List.fold_left
                (fun bound condition ->
                  Option.bind bound (fun bound ->
                    positive_condition_bound bound condition))
                (Some bound) positive
            in
            (match bound_after with
            | None ->
              loop (index + count) bound prefix candidates
                (("condition " ^ string_of_int index
                  ^ ": certified source observer block is not source-ordered")
                 :: blockers)
                statements rest
            | Some bound ->
              let candidates =
                failures
                |> List.fold_left
                     (fun candidates failure ->
                       (List.rev prefix, failure) :: candidates)
                     candidates
              in
              loop (index + count) bound
                (List.rev_append positive prefix)
                candidates blockers statements rest))
      | Ambiguous ->
        loop (index + 1) bound prefix candidates
          (("condition " ^ string_of_int index
            ^ ": source observer has ambiguous totality provenance") :: blockers)
          statements rest
      | Missing when repeated -> continue_repeated ()
      | Missing ->
      let atom, support =
        match complement_atom known condition with
        | (Atom_blocked _ as blocked) ->
          (match certificate_ctx, certificate_origin, certificate_helper, condition with
          | Some constructors, Some origin, Some helper_name,
            MatchCond (pattern, subject) ->
          (match
             Reld_match_complement_certificate.certify
               constructors ~origin ~helper_name ~index ~bound ~pattern ~subject
           with
          | Irrefutable -> Tautology, []
          | Certified certificate ->
            Negated [ [ certificate.failure ] ], certificate.statements
          | Blocked reason -> Atom_blocked reason, [])
          | _ -> blocked, [])
        | atom -> atom, []
      in
      let candidates, blockers =
        match atom with
        | Negated failures ->
          let candidates =
            failures
            |> List.fold_left
                 (fun candidates failure ->
                   (List.rev prefix, failure) :: candidates)
                 candidates
          in
          candidates, blockers
        | Tautology -> candidates, blockers
        | Atom_blocked reason ->
          let proof_reasons =
            Source_condition_certificate.blockers condition_failures conditions
            |> List.map proof_blocker_text
          in
          let reason =
            match proof_reasons with
            | [] -> reason
            | reasons -> reason ^ "; structural proof blockers: "
                         ^ String.concat "; " reasons
          in
          candidates,
          ("condition " ^ string_of_int index ^ " (`"
           ^ condition_source condition ^ "`): " ^ reason) :: blockers
      in
      let bound, prefix =
        match atom, positive_condition_bound bound condition with
        | Atom_blocked _, _ -> bound, prefix
        | (Tautology | Negated _), Some bound -> bound, condition :: prefix
        | (Tautology | Negated _), None -> bound, prefix
      in
      loop (index + 1) bound prefix candidates blockers
        (support :: statements) rest)
  in
  loop 1 bound [] [] [] [] conditions

(* not (c1 /\ ... /\ cn) is the disjunction of the source-ordered
   first-failure cases: not c1, c1 /\ not c2, ..., c1 /\ ... /\ not cn. *)
let sequential_complement_alternatives lhs_terms eq_conditions =
  let bound =
    lhs_terms
    |> List.concat_map term_vars
    |> List.sort_uniq String.compare
  in
  sequential_condition_complements [] [] [] bound eq_conditions

let certified_sequential_complement_alternatives
    ?(lhs_conditions = [])
    ctx ~origin ~helper_name ~condition_certificates ~condition_failures
    lhs_terms eq_conditions =
  let initial_bound =
    lhs_terms
    |> List.concat_map term_vars
    |> List.sort_uniq String.compare
  in
  let bound =
    List.fold_left
      (fun bound condition ->
        Option.bind bound (fun bound -> positive_condition_bound bound condition))
      (Some initial_bound) lhs_conditions
  in
  match bound with
  | None -> Blocked [ "lhs guards are not source-ordered over the immutable lhs" ]
  | Some bound ->
    sequential_condition_complements
      ~certificate_ctx:ctx ~certificate_origin:origin
      ~certificate_helper:helper_name condition_certificates condition_failures
      lhs_conditions bound eq_conditions

let direct_complement_alternatives
    ctx ~origin ~helper_name ~current_head_conditions:_
    ~predecessor_head_conditions
    ~condition_blocks ~head_domain_failures
    ~condition_certificates ~condition_failures
    current_terms predecessor_terms premise_conditions =
  match collect_head_subst current_terms predecessor_terms with
  | None -> Blocked [ "predecessor head specialization is ambiguous or incomplete" ]
  | Some subst ->
    let specialized_terms = List.map (substitute_term subst) predecessor_terms in
    if specialized_terms <> current_terms then
      Blocked
        [ "predecessor/current lhs difference requires an explicit structural match-complement certificate" ]
    else
      let predecessor_head_conditions =
        List.map (substitute_condition subst) predecessor_head_conditions
      in
      let condition_blocks =
        condition_blocks
        |> List.map (function
          | Source_conditions conditions ->
            Source_conditions
              (List.map (substitute_condition subst) conditions)
          | Head_domain_conditions conditions ->
            Head_domain_conditions
              (List.map (substitute_condition subst) conditions))
      in
      let specialized_premise_conditions =
        List.map (substitute_condition subst) premise_conditions
      in
      let aligned_conditions =
        condition_blocks
        |> List.concat_map (function
          | Source_conditions conditions
          | Head_domain_conditions conditions -> conditions)
      in
      let source_conditions =
        condition_blocks
        |> List.concat_map (function
          | Source_conditions conditions -> conditions
          | Head_domain_conditions _ -> [])
      in
      let head_domain_conditions =
        condition_blocks
        |> List.concat_map (function
          | Source_conditions _ -> []
          | Head_domain_conditions conditions -> conditions)
      in
      let condition_certificates =
        condition_certificates
        |> List.map (Source_condition_certificate.specialize subst)
      in
      let condition_failures =
        condition_failures
        |> List.map
             (Source_condition_certificate.specialize_proof_failure subst)
      in
      let initial_bound =
        current_terms
        |> List.concat_map term_vars
        |> List.sort_uniq String.compare
      in
      let bound =
        List.fold_left
          (fun bound condition ->
            Option.bind bound (fun bound ->
              positive_condition_bound bound condition))
          (Some initial_bound) predecessor_head_conditions
      in
      let bound =
        List.fold_left
          (fun bound condition ->
            Option.bind bound (fun bound ->
              positive_condition_bound bound condition))
          bound head_domain_conditions
      in
      let candidates =
        if aligned_conditions <> specialized_premise_conditions then
          Blocked
            [ Printf.sprintf
                "source-condition provenance is not exactly aligned with the emitted premise conditions (%d provenance condition(s), %d emitted condition(s)); %s"
                (List.length aligned_conditions)
                (List.length specialized_premise_conditions)
                (first_condition_difference
                   aligned_conditions specialized_premise_conditions)
            ]
        else match bound with
        | None -> Blocked [ "predecessor lhs guards are not source-ordered" ]
        | Some bound ->
          sequential_condition_complements
            ~certificate_ctx:ctx ~certificate_origin:origin
            ~certificate_helper:helper_name condition_certificates
            condition_failures [] bound source_conditions
      in
      (match candidates with
      | Blocked reasons -> Blocked (head_domain_failures @ reasons)
      | Complete complete ->
        let head_constraints =
          List.map (fun condition -> EqCondition condition)
            (predecessor_head_conditions @ head_domain_conditions)
        in
        Complete
          { complete with
            alternatives =
              complete.alternatives
              |> List.map (fun alternative -> head_constraints @ alternative)
          })

let rec has_constructor_refinement current previous =
  match current, previous with
  | Var _, App _ -> true
  | App (current_op, current_args), App (previous_op, previous_args)
    when String.equal current_op previous_op
         && List.length current_args = List.length previous_args ->
    List.exists2 has_constructor_refinement current_args previous_args
  | Var _, _ | Const _, _ | Qid _, _ | App _, _ -> false

let has_constructor_refinement_terms current previous =
  List.length current = List.length previous
  && List.exists2 has_constructor_refinement current previous

let predecessor_matches_current current predecessor =
  terms_match_general current predecessor

let predecessor_refines_constructor current predecessor =
  has_constructor_refinement_terms current predecessor
