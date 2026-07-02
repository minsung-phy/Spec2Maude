open Il.Ast
open Util.Source

type component =
  { payload : exp option
  ; typ : typ
  }

type deterministic_shape =
  { inputs : component list
  ; output : component
  }

type execution_shape =
  { star : bool
  ; inputs : component list
  ; outputs : component list
  }

type decision =
  | Static_validation of string
  | Runtime_predicate of string
  | Deterministic_candidate of deterministic_shape
  | Execution of execution_shape
  | Unknown of string

type t =
  { marker : Analysis.Relation_graph.relation_kind
  ; marker_text : string
  ; params : param list
  ; mixop : mixop option
  ; result : typ
  ; components : component list
  ; decision : decision
  }

let components_of_typ typ =
  match typ.it with
  | TupT components ->
    List.map
      (fun (id, typ) ->
        let payload = VarE id $$ id.at % typ in
        { payload = Some payload; typ })
      components
  | _ -> [ { payload = None; typ } ]

let component_typs components =
  List.map (fun component -> component.typ) components

let split_at count items =
  let rec loop n left right =
    if n = 0 then Some (List.rev left, right)
    else
      match right with
      | [] -> None
      | item :: rest -> loop (n - 1) (item :: left) rest
  in
  loop count [] items

let deterministic_shape components =
  match List.rev components with
  | output :: reversed_inputs ->
    Some { inputs = List.rev reversed_inputs; output }
  | [] -> None

let execution_shape ~star components =
  let length = List.length components in
  if length > 0 && length mod 2 = 0 then
    match split_at (length / 2) components with
    | Some (inputs, outputs) -> Some { star; inputs; outputs }
    | None -> None
  else
    None

let decide marker _result components =
  match marker with
  | Analysis.Relation_graph.Predicate_candidate ->
    Static_validation
      "predicate relation has judgement/subtyping marker and is treated as external-validator validation unless runtime-demand propagation requires it"
  | Analysis.Relation_graph.Deterministic_candidate ->
    (match deterministic_shape components with
    | Some shape -> Deterministic_candidate shape
    | None ->
      Unknown
        "deterministic candidate relation has no source component to use as output")
  | Analysis.Relation_graph.Execution ->
    (match execution_shape ~star:false components with
    | Some shape -> Execution shape
    | None ->
      Unknown
        "execution relation requires an even source signature split into input and output components")
  | Analysis.Relation_graph.Execution_star ->
    (match execution_shape ~star:true components with
    | Some shape -> Execution shape
    | None ->
      Unknown
        "execution-star relation requires an even source signature split into input and output components")
  | Analysis.Relation_graph.Unknown ->
    Unknown
      "relation marker is not classified as validation, deterministic, or execution"

let make ?(params = []) ?mixop marker result =
  let components = components_of_typ result in
  { marker
  ; marker_text = Analysis.Relation_graph.string_of_relation_kind marker
  ; params
  ; mixop
  ; result
  ; components
  ; decision = decide marker result components
  }

let of_kind marker result =
  make marker result

let of_relation (relation : Analysis.Function_graph.relation) =
  make ~params:relation.source_params ~mixop:relation.mixop relation.kind relation.result

let of_reld params mixop result =
  Analysis.Relation_graph.classify_mixop mixop
  |> fun marker -> make ~params ~mixop marker result

let decision_name = function
  | Static_validation _ -> "static-validation"
  | Runtime_predicate _ -> "runtime-predicate"
  | Deterministic_candidate _ -> "deterministic-candidate"
  | Execution { star; _ } -> if star then "execution-star" else "execution"
  | Unknown _ -> "unknown"
