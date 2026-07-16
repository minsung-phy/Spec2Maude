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
  { origin : Origin.t
  ; constructor : string
  ; ast_constructor : string
  ; relation_id : string
  ; rule_id : string option
  ; premise_index : int option
  ; premise_context : string option
  ; reason : string
  ; suggestion : string
  ; source_echo : string option
  }

let blocker domain ?premise ast_constructor constructor reason suggestion =
  let rule = domain.Runtime_witness_proof.transitive.rule in
  let premise_index =
    let rec find index = function
      | [] -> None
      | candidate :: rest ->
        (match premise with
        | Some premise when Il.Eq.eq_prem candidate premise -> Some index
        | Some _ | None -> find (index + 1) rest)
    in
    find 0 rule.prems
  in
  { origin = rule.origin
  ; constructor
  ; ast_constructor
  ; relation_id = rule.relation_id
  ; rule_id = rule.rule_id
  ; premise_index
  ; premise_context = Option.map Il.Print.string_of_prem premise
  ; reason
  ; suggestion
  ; source_echo =
      (match premise with
      | Some premise -> Some (Il.Print.string_of_prem premise)
      | None -> rule.source_echo)
  }

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
          [ blocker domain ~premise:transitive.domain_premise "VarE"
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
          [ blocker domain ~premise:transitive.domain_premise "VarE"
              "RuntimeWitnessDomain/witness-shape"
              "finite-domain premise does not end in a direct VarE witness"
              "Materialize only source domains whose candidate witness is a direct IL variable"
          ])
    | _ ->
      Error
        [ blocker domain ~premise:transitive.domain_premise "RulePr"
            "RuntimeWitnessDomain/domain-arity"
            "finite-domain premise does not have the same prefix arity plus one witness component as the transitive rule"
            "Keep this recursive predicate Unsupported until the domain premise can be mapped to a finite candidate sequence"
        ])
  | RulePr (_, _ :: _, _, _) | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ ->
    Error
      [ blocker domain ~premise:transitive.domain_premise "RulePr"
          "RuntimeWitnessDomain/domain-premise"
          "finite transitive proof domain is not a RulePr premise"
          "Closed-world witness domains must come from a source predicate premise D(prefix, witness)"
      ]

let prepare domain =
  match domain_candidate domain with
  | Error blockers -> Error blockers
  | Ok _candidate ->
    (* The proof domain is an SCC-wide AND/OR graph, not a flat closure over
       trans-free rules: a non-transitive RuleD may itself have a recursive
       subtype premise. Every node is the complete concrete relation goal and
       every RuleD contributes all premises as AND children. Query endpoints
       and closed heads do not prove this successor graph finite or complete. *)
    Error
      [ blocker domain "RuntimeWitnessDomain"
          "RuntimeWitnessDomain/unproved-successor-closure"
          "the source transitivity shape is recognized, but the available endpoint and closed-head candidates do not form a source-complete witness domain"
          "Implement a finitely branching source-derived AND/OR SCC worklist keyed by the complete ground goal, with separate positive and total-false proofs"
      ]

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
