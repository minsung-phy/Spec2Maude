open Il.Ast
open Util.Source

type t =
  { first_index : int
  ; last_index : int
  ; introduced_source_ids : string list
  ; source_echo : string
  ; origin : Origin.t
  ; contract_origin : string option
  }

type discharge =
  { retained : prem list
  ; certificates : t list
  ; blockers : blocker list
  }

and blocker =
  { origin : Origin.t
  ; reason : string
  ; suggestion : string
  ; source_echo : string
  }

let first_index certificate = certificate.first_index
let last_index certificate = certificate.last_index
let introduced_source_ids certificate = certificate.introduced_source_ids
let source_echo (certificate : t) = certificate.source_echo
let origin (certificate : t) = certificate.origin
let contract_origin (certificate : t) = certificate.contract_origin
let blocker_origin (blocker : blocker) = blocker.origin
let blocker_reason (blocker : blocker) = blocker.reason
let blocker_suggestion (blocker : blocker) = blocker.suggestion
let blocker_source_echo (blocker : blocker) = blocker.source_echo

let var_ids sets =
  sets.Il.Free.varid |> Il.Free.Set.elements

let free_prem prem = var_ids (Il.Free.free_prem prem)
let free_exp exp = var_ids (Il.Free.free_exp exp)
let free_args args = var_ids (Il.Free.free_args args)
let free_prems prems = var_ids (Il.Free.free_prems prems)

let difference left right =
  List.filter (fun id -> not (List.mem id right)) left

let intersects left right =
  List.exists (fun id -> List.mem id right) left

let relation ctx id =
  Analysis.Function_graph.find_relation (Context.function_graph ctx) id.it

let plain_relation ctx id args mixop =
  match args, relation ctx id with
  | [], Some relation ->
    relation.source_params = [] && Il.Eq.eq_mixop relation.mixop mixop
  | _ -> false

let producer ctx prem =
  match prem.it with
  | RulePr (id, args, mixop, _) when plain_relation ctx id args mixop ->
    (match relation ctx id with
    | Some relation ->
      (match (Relation_shape.of_relation relation).decision with
      | Relation_shape.Static_validation _ ->
        Some (relation, Runtime_ingress_contract.Linking)
      | Relation_shape.Deterministic_candidate _ ->
        Some (relation, Runtime_ingress_contract.Invocation)
      | Relation_shape.Runtime_predicate _
      | Relation_shape.Execution _
      | Relation_shape.Unknown _ -> None)
    | None -> None)
  | RulePr _ | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> None

let consumer ctx prem =
  match prem.it with
  | IterPr ({ it = RulePr (id, args, mixop, _); _ }, (_, _ :: _))
    when plain_relation ctx id args mixop ->
    (match relation ctx id with
    | Some relation ->
      if relation.kind = Analysis.Relation_graph.Predicate_candidate
      then Some relation
      else None
    | None -> None)
  | IterPr _ | RulePr _ | IfPr _ | LetPr _ | ElsePr | NegPr _ -> None

let runtime_entry_discovered ctx definition_id =
  Analysis.Function_graph.definition_is_runtime_entry
    (Context.function_graph ctx) definition_id

let same_vars left right =
  List.sort_uniq String.compare left = List.sort_uniq String.compare right

let vars_subset vars bound =
  List.for_all (fun var -> List.mem var bound) vars

let source_complete_relation ctx (relation : Analysis.Function_graph.relation) =
  match
    Analysis.Function_graph.runtime_relation_rules
      (Context.function_graph ctx) relation.Analysis.Function_graph.id
  with
  | Some (_ :: _ as rules) -> List.length rules = relation.rule_count
  | Some [] | None -> false

let relation_identity ctx (relation : Analysis.Function_graph.relation) =
  Runtime_ingress_contract.relation_identity
    (Context.source_index ctx) relation.Analysis.Function_graph.id

let producer_components relation prem =
  match prem.it with
  | RulePr (_, [], _, exp) ->
    Analysis.Relation_graph.exp_components_for_count
      (List.length (Relation_shape.of_relation relation).components) exp
  | RulePr _ | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> None

let nth_opt items index =
  let rec nth items index =
    match items, index with
    | item :: _, 0 -> Some item
    | _ :: rest, index when index > 0 -> nth rest (index - 1)
    | [], _ | _, _ -> None
  in
  nth items index

let producer_witnesses relation capability output_indices bound prem =
  match producer_components relation prem with
  | None -> Error "validation producer components do not match its RelD signature"
  | Some components ->
    let expected_indices =
      match capability, (Relation_shape.of_relation relation).decision with
      | Runtime_ingress_contract.Invocation,
        Relation_shape.Deterministic_candidate shape ->
        Some [ List.length shape.inputs ]
      | Runtime_ingress_contract.Linking, Static_validation _ -> Some output_indices
      | Runtime_ingress_contract.Invocation, _
      | Runtime_ingress_contract.Linking, _ -> None
    in
    (match expected_indices with
    | None -> Error "ingress capability does not match the producer relation shape"
    | Some expected_indices when expected_indices <> output_indices ->
      Error
        "attested producer output component indices do not match the relation's declared deterministic output"
    | Some [] -> Error "ingress contract attests no producer output component"
    | Some indices ->
      let outputs = List.map (nth_opt components) indices in
      if List.exists Option.is_none outputs then
        Error "ingress contract names an out-of-range producer output component"
      else
        let output_vars =
          outputs
          |> List.filter_map Fun.id
          |> List.concat_map free_exp
          |> fun vars -> difference vars bound
        in
        let fresh = difference (free_prem prem) bound in
        if output_vars = [] || not (same_vars output_vars fresh) then
          Error
            "fresh validation witnesses are not exactly the variables of the attested producer output components"
        else Ok (List.sort_uniq String.compare output_vars))

let consumer_inputs_bound bound prem =
  match prem.it with
  | IterPr (body, (_, generators)) ->
    let generator_ids = List.map (fun (id, _) -> id.it) generators in
    let source_vars = generators |> List.concat_map (fun (_, exp) -> free_exp exp) in
    vars_subset source_vars bound
    && vars_subset (free_prem body) (generator_ids @ bound)
  | RulePr _ | IfPr _ | LetPr _ | ElsePr | NegPr _ -> false

let certificate ?contract_origin definition_id index introduced first second =
  let source_echo =
    Il.Print.string_of_prem first ^ "\n" ^ Il.Print.string_of_prem second
  in
  let origin =
    Origin.make
      ~ast_constructor:"RuntimeIngressValidationSlice"
      ~source_echo
      first.at
  in
  { first_index = index
  ; last_index = index + 1
  ; introduced_source_ids = introduced
  ; source_echo
  ; contract_origin
  ; origin =
      Origin.with_child
        ~source_echo origin ("DefD/" ^ definition_id)
        ~ast_constructor:"PremiseSlice" second.at
  }

type prefix_result =
  | Not_applicable
  | Certified of t
  | Rejected of blocker

let rejected definition_id first second reason =
  let certificate = certificate definition_id 0 [] first second in
  Rejected
    { origin = certificate.origin
    ; reason
    ; suggestion =
        "Keep the complete source validation prefix Unsupported until its ingress capability and witness non-escape proof are re-established"
    ; source_echo = certificate.source_echo
    }

let certify_prefix
    ctx definition_id clause_index bound rhs rest first second =
  match producer ctx first, consumer ctx second with
  | Some (producer, capability), Some consumer ->
    let source_index = Context.source_index ctx in
    let contract = Context.runtime_ingress_contract ctx in
    let identities =
      Runtime_ingress_contract.definition_identity source_index definition_id,
      relation_identity ctx producer,
      relation_identity ctx consumer
    in
    (match identities with
    | Some definition, Some producer_identity, Some consumer_identity ->
      (match
         Runtime_ingress_contract.find
           contract
           ~definition
           ~clause_index
           ~producer_premise_index:0
           ~consumer_premise_index:1
           ~producer:producer_identity
           ~consumer:consumer_identity
           ~capability
       with
      | None ->
        rejected definition_id first second
          "source validation prefix has no exact externally supplied runtime-ingress attestation"
      | Some attestation ->
        if not (source_complete_relation ctx producer
                && source_complete_relation ctx consumer)
        then
          rejected definition_id first second
            "attested producer or consumer RelD has no non-empty source-complete RuleD body"
        else
          (match
             producer_witnesses
               producer capability
               (Runtime_ingress_contract.producer_output_indices attestation)
               bound first
           with
          | Error reason -> rejected definition_id first second reason
          | Ok introduced ->
            let consumed = intersects introduced (free_prem second) in
            let escapes = intersects introduced (free_exp rhs @ free_prems rest) in
            if not (consumer_inputs_bound (bound @ introduced) second) then
              rejected definition_id first second
                "attested validation consumer has an input not bound by the DefD lhs, producer outputs, or IterPr generators"
            else if not consumed then
              rejected definition_id first second
                "runtime-ingress validation consumer does not consume a witness introduced by its producer"
            else if escapes then
              rejected definition_id first second
                "runtime-ingress validation witness escapes into the DefD rhs or retained premise suffix"
            else
              let contract_origin =
                Runtime_ingress_contract.attestation_origin attestation
              in
              Context.use_runtime_ingress_attestation ctx attestation;
              Certified
                (certificate ~contract_origin definition_id 0 introduced first second)))
    | None, _, _ ->
      rejected definition_id first second
        "runtime entry has no unique source-indexed DecD identity"
    | _, None, _ | _, _, None ->
      rejected definition_id first second
        "validation prefix relation has no unique source-indexed RelD identity")
  | Some _, None | None, Some _ | None, None -> Not_applicable

let certify ctx ~definition_id ~clause_index ~lhs_args ~rhs prems =
  if not (runtime_entry_discovered ctx definition_id) then
    { retained = prems; certificates = []; blockers = [] }
  else
    (match prems with
    | first :: second :: rest ->
      (match
         certify_prefix
           ctx definition_id clause_index (free_args lhs_args) rhs rest first second
       with
      | Certified certificate ->
        { retained = rest; certificates = [ certificate ]; blockers = [] }
      | Rejected blocker ->
        { retained = prems; certificates = []; blockers = [ blocker ] }
      | Not_applicable -> { retained = prems; certificates = []; blockers = [] })
    | [] | [ _ ] -> { retained = prems; certificates = []; blockers = [] })
