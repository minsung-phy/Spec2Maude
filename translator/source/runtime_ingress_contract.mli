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

type relation_identity = private
  { source_id : string
  ; source_ordinal : int
  }

type definition_identity = private
  { source_id : string
  ; source_ordinal : int
  }

type attestation
type provenance = private
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
type error
type t

val empty : t
val expected_source_digest :
  Analysis.Source_index.t -> spec -> (string, string) result
val expected_formula_digest : capability -> string
val resolve : Analysis.Source_index.t -> spec list -> (t, error list) result
val find :
  t ->
  definition:definition_identity ->
  clause_index:int ->
  producer_premise_index:int ->
  consumer_premise_index:int ->
  producer:relation_identity ->
  consumer:relation_identity ->
  capability:capability ->
  attestation option

val definition_identity :
  Analysis.Source_index.t -> string -> definition_identity option
val relation_identity :
  Analysis.Source_index.t -> string -> relation_identity option
val producer_output_indices : attestation -> int list
val attestation_key : attestation -> string
val attestation_origin : attestation -> string
val attestation_provenance : attestation -> provenance
val error_provenance : error -> provenance
val error_previous_provenance : error -> provenance option
val error_reason : error -> string
val provenance_source_echo : provenance -> string
val attestations : t -> attestation list
val capability_name : capability -> string
