open Il.Ast

type plan =
  { id : id
  ; fields : (atom * field_plan) list
  }

and field_plan =
  | Append
  | Compose_optional
  | Compose_record of plan

type definition =
  { origin : Origin.t
  ; id : id
  ; fields : (atom * Maude_ir.sort) list
  ; composition : plan option
  ; surface : Maude_ir.statement_node list
  }

type helper_state =
  | No_helper
  | Pending of id list
  | Emitted

type entry =
  { definition : definition
  ; helper_state : helper_state
  }

type conflict =
  { existing : definition
  ; incoming : definition
  ; reason : string
  }

type constructor = definition

type t =
  { mutable entries : entry list
  }

type registration =
  | Fresh
  | Duplicate
  | Conflict of conflict

type helper_status =
  | Helper_emitted
  | Helper_missing
  | Helper_unavailable of id list
  | Helper_incompatible

let create () =
  { entries = [] }

let copy registry =
  { entries = registry.entries }

let replace ~target ~source =
  target.entries <- source.entries

let plan id fields =
  { id; fields }

let plan_id (plan : plan) =
  plan.id

let plan_fields (plan : plan) =
  plan.fields

let definition ~origin ~id ~fields ~composition ~surface =
  { origin; id; fields; composition; surface }

let constructor_surface (definition : definition) =
  Naming.record_constructor definition.id

let same_atom (left, _) (right, _) =
  Il.Eq.eq_atom left right

let same_sort (_, left) (_, right) =
  Maude_ir.sort_name left = Maude_ir.sort_name right

let rec same_plan (left : plan) (right : plan) =
  Il.Eq.eq_id left.id right.id
  && List.length left.fields = List.length right.fields
  && List.for_all2 same_plan_field left.fields right.fields

and same_plan_field
    (left_atom, (left : field_plan))
    (right_atom, (right : field_plan)) =
  Il.Eq.eq_atom left_atom right_atom
  && match left, right with
     | Append, Append | Compose_optional, Compose_optional -> true
     | Compose_record left, Compose_record right -> same_plan left right
     | Append, (Compose_optional | Compose_record _)
     | Compose_optional, (Append | Compose_record _)
     | Compose_record _, (Append | Compose_optional) -> false

let same_composition left right =
  match left, right with
  | None, None -> true
  | Some left, Some right -> same_plan left right
  | None, Some _ | Some _, None -> false

let same_definition (left : definition) (right : definition) =
  Il.Eq.eq_id left.id right.id
  && List.length left.fields = List.length right.fields
  && List.for_all2
       (fun left right -> same_atom left right && same_sort left right)
       left.fields right.fields
  && same_composition left.composition right.composition
  && left.surface = right.surface

let conflict_reason existing incoming =
  if not (Il.Eq.eq_id existing.id incoming.id) then
    "distinct nominal record owners share one canonical constructor surface"
  else if List.length existing.fields <> List.length incoming.fields
          || not (List.for_all2 same_atom existing.fields incoming.fields) then
    "specialized StructT instances disagree on field identity or arity"
  else if not (List.for_all2 same_sort existing.fields incoming.fields) then
    "specialized StructT instances disagree on canonical field carriers"
  else if existing.surface <> incoming.surface then
    "specialized StructT instances disagree on their typed Maude record surface"
  else
    "specialized StructT instances disagree on recursive composition plan"

let register registry incoming =
  match
    List.find_opt
      (fun entry ->
        constructor_surface entry.definition = constructor_surface incoming)
      registry.entries
  with
  | None ->
    let helper_state =
      match incoming.composition with None -> No_helper | Some _ -> Pending []
    in
    registry.entries <- { definition = incoming; helper_state } :: registry.entries;
    Fresh
  | Some entry when same_definition entry.definition incoming -> Duplicate
  | Some entry ->
    Conflict
      { existing = entry.definition
      ; incoming
      ; reason = conflict_reason entry.definition incoming
      }

let helper_status registry (plan : plan) =
  match
    List.find_opt
      (fun entry ->
        constructor_surface entry.definition = Naming.record_constructor plan.id)
      registry.entries
  with
  | None -> Helper_missing
  | Some { definition = { composition = Some existing; _ }; helper_state }
    when same_plan existing plan ->
    (match helper_state with
    | Emitted -> Helper_emitted
    | Pending dependencies -> Helper_unavailable dependencies
    | No_helper -> Helper_incompatible)
  | Some _ -> Helper_incompatible

let missing_dependencies registry (plan : plan) =
  plan.fields
  |> List.filter_map (function
       | _, Compose_record nested ->
         (match helper_status registry nested with
         | Helper_emitted -> None
         | Helper_missing | Helper_unavailable _ | Helper_incompatible ->
           Some nested.id)
       | _, Append | _, Compose_optional -> None)
  |> List.sort_uniq (fun (left : id) (right : id) ->
       String.compare left.it right.it)

let update_helper_state registry (plan : plan) helper_state =
  registry.entries <-
    registry.entries
    |> List.map (fun entry ->
      match entry.definition.composition with
      | Some existing when same_plan existing plan -> { entry with helper_state }
      | None | Some _ -> entry)

let note_helper_unavailable registry (plan : plan) dependencies =
  update_helper_state registry plan (Pending dependencies)

let note_helper_emitted registry (plan : plan) =
  update_helper_state registry plan Emitted

let describe_fields definition =
  definition.fields
  |> List.map (fun (atom, sort) ->
       Xl.Atom.to_string atom ^ ":" ^ Maude_ir.sort_name sort)
  |> String.concat ", "

let describe_conflict conflict =
  Printf.sprintf
    "%s for `%s`; first definition at %s has fields [%s], conflicting definition at %s has fields [%s]"
    conflict.reason
    (constructor_surface conflict.incoming)
    (Origin.summary conflict.existing.origin)
    (describe_fields conflict.existing)
    (Origin.summary conflict.incoming.origin)
    (describe_fields conflict.incoming)

let constructors registry =
  List.map (fun entry -> entry.definition) registry.entries

let constructor_name constructor =
  constructor_surface constructor

let constructor_payload_sorts constructor =
  List.map snd constructor.fields
