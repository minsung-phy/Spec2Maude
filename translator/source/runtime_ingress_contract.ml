open Il.Ast

type capability =
  | Linking
  | Invocation

type spec =
  { capability : capability
  ; origin : string
  ; definition_id : string
  ; clause_index : int
  ; producer_premise_index : int
  ; consumer_premise_index : int
  ; producer_relation_id : string
  ; consumer_relation_id : string
  ; producer_output_indices : int list
  ; source_digest : string
  ; trusted_formula_digest : string
  }

type relation_identity =
  { source_id : string
  ; source_ordinal : int
  }

type definition_identity =
  { source_id : string
  ; source_ordinal : int
  }

type attestation =
  { capability : capability
  ; origin : string
  ; definition : definition_identity
  ; clause_index : int
  ; producer_premise_index : int
  ; consumer_premise_index : int
  ; producer : relation_identity
  ; consumer : relation_identity
  ; producer_output_indices : int list
  ; source_digest : string
  ; trusted_formula_digest : string
  }

type provenance =
  { capability : capability
  ; origin : string
  ; definition_id : string
  ; definition_ordinal : int option
  ; clause_index : int
  ; producer_premise_index : int
  ; consumer_premise_index : int
  ; producer_relation_id : string
  ; producer_relation_ordinal : int option
  ; consumer_relation_id : string
  ; consumer_relation_ordinal : int option
  ; producer_output_indices : int list
  }

type error =
  { provenance : provenance
  ; previous : provenance option
  ; reason : string
  }

type t = attestation list

let empty = []

let capability_name = function
  | Linking -> "linking"
  | Invocation -> "invocation"

let digest value =
  Digest.to_hex
    (Digest.string (Marshal.to_string value [ Marshal.No_sharing ]))

let trusted_formula = function
  | Linking ->
    ( "source-contiguous-prefix"
    , "linking-validation-producer-declared-outputs"
    , "iterated-validation-consumer-inputs-bound"
    , "producer-witnesses-consumed-only-in-slice"
    , "no-rhs-or-suffix-escape" )
  | Invocation ->
    ( "source-contiguous-prefix"
    , "invocation-deterministic-final-output"
    , "iterated-validation-consumer-inputs-bound"
    , "producer-witnesses-consumed-only-in-slice"
    , "no-rhs-or-suffix-escape" )

let expected_formula_digest capability =
  digest (trusted_formula capability)

(* Attest IL structure, not the path used to load it.  [Il.Print] emits source
   regions as [;; ...] lines, so discard only those printer-added comments. *)
let source_text text =
  text
  |> String.split_on_char '\n'
  |> List.filter (fun line ->
       not (String.starts_with ~prefix:";; " (String.trim line)))
  |> String.concat "\n"

let find_unique source_index id predicate =
  Analysis.Source_index.find_by_id source_index id
  |> List.filter (fun entry -> predicate entry.Analysis.Source_index.def)
  |> function
  | [ entry ] -> Some entry
  | [] | _ :: _ :: _ -> None

let definition_entry source_index id =
  find_unique source_index id (fun def ->
    match def.it with DecD _ -> true | _ -> false)

let relation_entry source_index id =
  find_unique source_index id (fun def ->
    match def.it with RelD _ -> true | _ -> false)

let definition_identity source_index id : definition_identity option =
  definition_entry source_index id
  |> Option.map (fun entry ->
    ({ source_id = id; source_ordinal = entry.Analysis.Source_index.ordinal }
      : definition_identity))

let relation_identity source_index id : relation_identity option =
  relation_entry source_index id
  |> Option.map (fun entry ->
    ({ source_id = id; source_ordinal = entry.Analysis.Source_index.ordinal }
      : relation_identity))

let provenance_of_spec source_index (spec : spec) =
  let definition_ordinal id =
    definition_identity source_index id
    |> Option.map (fun (identity : definition_identity) ->
         identity.source_ordinal)
  in
  let relation_ordinal id =
    relation_identity source_index id
    |> Option.map (fun (identity : relation_identity) ->
         identity.source_ordinal)
  in
  { capability = spec.capability
  ; origin = spec.origin
  ; definition_id = spec.definition_id
  ; definition_ordinal = definition_ordinal spec.definition_id
  ; clause_index = spec.clause_index
  ; producer_premise_index = spec.producer_premise_index
  ; consumer_premise_index = spec.consumer_premise_index
  ; producer_relation_id = spec.producer_relation_id
  ; producer_relation_ordinal = relation_ordinal spec.producer_relation_id
  ; consumer_relation_id = spec.consumer_relation_id
  ; consumer_relation_ordinal = relation_ordinal spec.consumer_relation_id
  ; producer_output_indices = spec.producer_output_indices
  }

let provenance_of_attestation (attestation : attestation) =
  { capability = attestation.capability
  ; origin = attestation.origin
  ; definition_id = attestation.definition.source_id
  ; definition_ordinal = Some attestation.definition.source_ordinal
  ; clause_index = attestation.clause_index
  ; producer_premise_index = attestation.producer_premise_index
  ; consumer_premise_index = attestation.consumer_premise_index
  ; producer_relation_id = attestation.producer.source_id
  ; producer_relation_ordinal = Some attestation.producer.source_ordinal
  ; consumer_relation_id = attestation.consumer.source_id
  ; consumer_relation_ordinal = Some attestation.consumer.source_ordinal
  ; producer_output_indices = attestation.producer_output_indices
  }

let make_error ?previous provenance reason =
  { provenance; previous; reason }

let nth_opt items index =
  if index < 0 then None else List.nth_opt items index

let exact_source source_index (spec : spec) =
  match
    definition_entry source_index spec.definition_id,
    relation_entry source_index spec.producer_relation_id,
    relation_entry source_index spec.consumer_relation_id
  with
  | Some definition, Some producer, Some consumer ->
    (match definition.def.it with
    | DecD (_, _, _, clauses) ->
      (match nth_opt clauses spec.clause_index with
      | None ->
        Error
          (Printf.sprintf
             "%s: DecD `%s` has no zero-based clause index %d"
             spec.origin spec.definition_id spec.clause_index)
      | Some clause ->
        (match clause.it with
        | DefD (_, _, _, prems) ->
          (match
             nth_opt prems spec.producer_premise_index,
             nth_opt prems spec.consumer_premise_index
           with
          | Some producer_premise, Some consumer_premise ->
            Ok
              ( definition, clause, producer_premise, consumer_premise
              , producer, consumer )
          | _ ->
            Error
              (Printf.sprintf
                 "%s: DefD `%s` clause %d does not contain premise indices %d and %d"
                 spec.origin spec.definition_id spec.clause_index
                 spec.producer_premise_index spec.consumer_premise_index))))
    | TypD _ | RelD _ | GramD _ | RecD _ | HintD _ ->
      Error
        (spec.origin ^ ": runtime-ingress definition is not a DecD after lookup"))
  | None, _, _ ->
    Error (spec.origin ^ ": ingress contract has no unique DecD `" ^ spec.definition_id ^ "`")
  | _, None, _ ->
    Error
      (spec.origin ^ ": ingress contract has no unique producer RelD `"
       ^ spec.producer_relation_id ^ "`")
  | _, _, None ->
    Error
      (spec.origin ^ ": ingress contract has no unique consumer RelD `"
       ^ spec.consumer_relation_id ^ "`")

let expected_source_digest source_index spec =
  match exact_source source_index spec with
  | Error _ as error -> error
  | Ok (definition, clause, producer_premise, consumer_premise,
        producer, consumer) ->
    (match definition.def.it with
    | DecD (id, _, _, _) ->
      Ok
        (digest
           ( capability_name spec.capability
           , definition.ordinal, spec.clause_index
           , source_text (Il.Print.string_of_clause ~suppress_pos:true id clause)
           , spec.producer_premise_index, Il.Print.string_of_prem producer_premise
           , spec.consumer_premise_index, Il.Print.string_of_prem consumer_premise
           , producer.ordinal,
             source_text (Il.Print.string_of_def ~suppress_pos:true producer.def)
           , consumer.ordinal,
             source_text (Il.Print.string_of_def ~suppress_pos:true consumer.def)
           , spec.producer_output_indices ))
    | TypD _ | RelD _ | GramD _ | RecD _ | HintD _ ->
      Error
        (spec.origin ^ ": runtime-ingress definition is not a DecD after exact-source resolution"))

let resolve_one source_index (spec : spec) =
  if spec.producer_premise_index <> 0
     || spec.consumer_premise_index <> spec.producer_premise_index + 1
  then
    Error
      (Printf.sprintf
         "%s: %s ingress for `%s` must attest the source prefix premise indices 0 and 1"
         spec.origin (capability_name spec.capability) spec.definition_id)
  else if List.length (List.sort_uniq Int.compare spec.producer_output_indices)
          <> List.length spec.producer_output_indices
  then
    Error
      (spec.origin ^ ": ingress producer output indices contain duplicates")
  else
    match exact_source source_index spec with
    | Error _ as error -> error
    | Ok (definition_entry, _, _, _, producer_entry, consumer_entry) ->
      let definition : definition_identity =
        { source_id = spec.definition_id; source_ordinal = definition_entry.ordinal }
      in
      let producer : relation_identity =
        { source_id = spec.producer_relation_id; source_ordinal = producer_entry.ordinal }
      in
      let consumer : relation_identity =
        { source_id = spec.consumer_relation_id; source_ordinal = consumer_entry.ordinal }
      in
      (match expected_source_digest source_index spec with
      | Error _ as error -> error
      | Ok expected_source ->
        let expected_formula = expected_formula_digest spec.capability in
        if not (String.equal spec.source_digest expected_source) then
          Error
            (Printf.sprintf
               "%s: stale ingress source digest `%s`; expected `%s` for the exact DefD clause/premises and producer/consumer RelD bodies"
               spec.origin spec.source_digest expected_source)
        else if not (String.equal spec.trusted_formula_digest expected_formula) then
          Error
            (Printf.sprintf
               "%s: stale ingress trusted-formula digest `%s`; expected `%s`"
               spec.origin spec.trusted_formula_digest expected_formula)
        else
          Ok
            { capability = spec.capability
            ; origin = spec.origin
            ; definition
            ; clause_index = spec.clause_index
            ; producer_premise_index = spec.producer_premise_index
            ; consumer_premise_index = spec.consumer_premise_index
            ; producer
            ; consumer
            ; producer_output_indices = spec.producer_output_indices
            ; source_digest = spec.source_digest
            ; trusted_formula_digest = spec.trusted_formula_digest
            })

let attestation_key attestation =
  String.concat "\000"
    [ attestation.definition.source_id
    ; string_of_int attestation.definition.source_ordinal
    ; string_of_int attestation.clause_index
    ; string_of_int attestation.producer_premise_index
    ; string_of_int attestation.consumer_premise_index
    ]

let spec_key (spec : spec) =
  String.concat "\000"
    [ spec.definition_id
    ; string_of_int spec.clause_index
    ; string_of_int spec.producer_premise_index
    ; string_of_int spec.consumer_premise_index
    ]

let resolve source_index specs =
  let seen = Hashtbl.create 7 in
  let rec loop attestations errors = function
    | [] ->
      if errors = [] then Ok (List.rev attestations)
      else Error (List.rev errors)
    | spec :: rest ->
      let provenance = provenance_of_spec source_index spec in
      let key = spec_key spec in
      (match Hashtbl.find_opt seen key with
      | Some previous ->
        loop attestations
          (make_error ~previous provenance
             "duplicate runtime-ingress attestation for the same exact definition/clause/premise-prefix key; every attested source slice must occur exactly once"
           :: errors)
          rest
      | None ->
        Hashtbl.add seen key provenance;
        (match resolve_one source_index spec with
        | Ok attestation -> loop (attestation :: attestations) errors rest
        | Error reason ->
          loop attestations (make_error provenance reason :: errors) rest))
  in
  loop [] [] specs

let same_relation (left : relation_identity) (right : relation_identity) =
  left.source_ordinal = right.source_ordinal
  && String.equal left.source_id right.source_id

let same_definition (left : definition_identity) (right : definition_identity) =
  left.source_ordinal = right.source_ordinal
  && String.equal left.source_id right.source_id

let find
    contract
    ~definition
    ~clause_index
    ~producer_premise_index
    ~consumer_premise_index
    ~producer
    ~consumer
    ~capability =
  List.find_opt
    (fun (attestation : attestation) ->
      attestation.capability = capability
      && same_definition attestation.definition definition
      && attestation.clause_index = clause_index
      && attestation.producer_premise_index = producer_premise_index
      && attestation.consumer_premise_index = consumer_premise_index
      && same_relation attestation.producer producer
      && same_relation attestation.consumer consumer)
    contract

let producer_output_indices (attestation : attestation) =
  attestation.producer_output_indices

let attestation_origin (attestation : attestation) = attestation.origin
let attestation_provenance = provenance_of_attestation
let error_provenance (error : error) = error.provenance
let error_previous_provenance (error : error) = error.previous
let error_reason (error : error) = error.reason

let identity_text id = function
  | None -> id ^ "#<unresolved>"
  | Some ordinal -> id ^ "#" ^ string_of_int ordinal

let provenance_source_echo provenance =
  Printf.sprintf
    "contract-origin=%s; capability=%s; definition=%s; clause=%d; producer-premise=%d; producer=%s; producer-outputs=[%s]; consumer-premise=%d; consumer=%s"
    provenance.origin
    (capability_name provenance.capability)
    (identity_text provenance.definition_id provenance.definition_ordinal)
    provenance.clause_index
    provenance.producer_premise_index
    (identity_text provenance.producer_relation_id
       provenance.producer_relation_ordinal)
    (String.concat "," (List.map string_of_int provenance.producer_output_indices))
    provenance.consumer_premise_index
    (identity_text provenance.consumer_relation_id
       provenance.consumer_relation_ordinal)

let attestations contract = contract
