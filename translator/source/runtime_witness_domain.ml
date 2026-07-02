open Il.Ast
open Util.Source

type candidate =
  { relation_id : string
  ; premise : prem
  ; prefix_arity : int
  ; witness_source_id : string
  ; source_echo : string option
  }

type candidate_source =
  | Query_inputs
  | Rule_head_closed_terms
  | Witness_category_zero_arity_constructors
  | Prefix_finite_indexed_fields
  | Deterministic_source_closure

type t =
  { proof : Runtime_witness_proof.closed_world_domain
  ; candidate : candidate
  ; cycle_rel_ids : string list
  ; fuel_source_ids : string list
  ; visited_key_source_ids : string list
  ; candidate_sources : candidate_source list
  }

type blocker =
  { constructor : string
  ; reason : string
  ; suggestion : string
  }

let blocker constructor reason suggestion =
  { constructor; reason; suggestion }

let default_candidate_sources =
  [ Query_inputs
  ; Rule_head_closed_terms
  ; Witness_category_zero_arity_constructors
  ; Prefix_finite_indexed_fields
  ; Deterministic_source_closure
  ]

let describe_candidate_source = function
  | Query_inputs -> "query inputs/endpoints"
  | Rule_head_closed_terms -> "closed terms from reachable source RuleD heads"
  | Witness_category_zero_arity_constructors ->
    "zero-arity constructors from the witness syntax category"
  | Prefix_finite_indexed_fields ->
    "finite indexed field terms derived from the source prefix"
  | Deterministic_source_closure ->
    "deterministic source closure of already-derived candidates"

let exp_components exp =
  match exp.it with
  | TupE components -> components
  | _ -> [ exp ]

let direct_var_source_id exp =
  match exp.it with
  | VarE id -> Some id.it
  | _ -> None

let domain_candidate
    (domain : Runtime_witness_proof.closed_world_domain)
  =
  let transitive = domain.transitive in
  match transitive.domain_premise.it with
  | RulePr (rel_id, [], _mixop, exp) ->
    let components = exp_components exp in
    let candidate =
      let rec split n acc components =
        if n = 0 then
          Some (List.rev acc, components)
        else
          match components with
          | [] -> None
          | component :: components -> split (n - 1) (component :: acc) components
      in
      match split transitive.prefix_arity [] components with
      | Some (prefix, [ witness ]) -> Some (prefix, witness)
      | Some _ | None -> None
    in
    (match candidate with
    | Some (_prefix, witness) ->
      (match direct_var_source_id witness with
      | Some witness_source_id
        when String.equal witness_source_id transitive.witness_source_id ->
        Ok
          { relation_id = rel_id.it
          ; premise = transitive.domain_premise
          ; prefix_arity = transitive.prefix_arity
          ; witness_source_id
          ; source_echo = Some (Il.Print.string_of_prem transitive.domain_premise)
          }
      | Some witness_source_id ->
        Error
          [ blocker
              "RuntimeWitnessDomain/witness-source"
              ("finite-domain premise introduces witness `"
               ^ witness_source_id
               ^ "`, but the transitive proof expects `"
               ^ transitive.witness_source_id
               ^ "`")
              "Keep this recursive predicate Unsupported until the domain premise witness matches the transitive source rule"
          ]
      | None ->
        Error
          [ blocker
              "RuntimeWitnessDomain/witness-shape"
              "finite-domain premise does not end in a direct VarE witness"
              "Materialize only source domains whose candidate witness is a direct IL variable"
          ])
    | _ ->
      Error
        [ blocker
            "RuntimeWitnessDomain/domain-arity"
            "finite-domain premise does not have the same prefix arity plus one witness component as the transitive rule"
            "Keep this recursive predicate Unsupported until the domain premise can be mapped to a finite candidate sequence"
        ])
  | RulePr (_, _ :: _, _, _) | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ ->
    Error
      [ blocker
          "RuntimeWitnessDomain/domain-premise"
          "finite transitive proof domain is not a RulePr premise"
          "Closed-world witness domains must come from a source predicate premise D(prefix, witness)"
      ]

let prepare domain =
  match domain_candidate domain with
  | Error blockers -> Error blockers
  | Ok candidate ->
    Ok
      { proof = domain
      ; candidate
      ; cycle_rel_ids = domain.domain_plan.cycle_rel_ids
      ; fuel_source_ids = domain.fuel_source_ids
      ; visited_key_source_ids = domain.visited_key_source_ids
      ; candidate_sources = default_candidate_sources
      }

let describe plan =
  "candidate relation `"
  ^ plan.candidate.relation_id
  ^ "` introduces witness `"
  ^ plan.candidate.witness_source_id
  ^ "`; cycle: "
  ^ String.concat " -> " plan.cycle_rel_ids

let describe_candidate_sources plan =
  plan.candidate_sources
  |> List.map describe_candidate_source
  |> String.concat ", "
