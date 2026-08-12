open Il.Ast

type construction_domain =
  | Total_constructor
  | Certified_representation_constructor
  | Length_guarded_representation_constructor of
      { payload_index : int
      ; closed_bound : exp
      ; guard_origin : Origin.t
      }
  | Guarded_constructor of string

type source_case =
  { payload_typ : typ
  ; case_binds : quant list
  ; case_prems : prem list
  ; instance_binds : quant list
  ; instance_args : arg list
  ; static_args_key : string option
  ; construction_domain : construction_domain
  }

type entry =
  { source_category : string
  ; static_args_key : string option
  ; mixop : mixop
  ; arity : int
  ; payload_typs : typ list
  ; payload_witnesses : Maude_ir.term list
  ; payload_sorts : Maude_ir.sort list
  ; source_case : source_case option
  ; origin : Origin.t
  ; emitted : bool
  }

type t = { classes : entry list list }

let same_origin left right =
  left.Origin.region = right.Origin.region
  && left.path = right.path
  && left.ast_constructor = right.ast_constructor
  && left.source_echo = right.source_echo

let same_entry left right =
  left.source_category = right.source_category
  && left.static_args_key = right.static_args_key
  && Il.Eq.eq_mixop left.mixop right.mixop
  && left.arity = right.arity
  && left.payload_sorts = right.payload_sorts
  && same_origin left.origin right.origin

let same_construction_domain left right =
  match left, right with
  | Total_constructor, Total_constructor
  | Certified_representation_constructor,
    Certified_representation_constructor -> true
  | Length_guarded_representation_constructor left,
    Length_guarded_representation_constructor right ->
    left.payload_index = right.payload_index
    && Il.Eq.eq_exp left.closed_bound right.closed_bound
    && same_origin left.guard_origin right.guard_origin
  | Guarded_constructor left, Guarded_constructor right -> left = right
  | Total_constructor, _
  | Certified_representation_constructor, _
  | Length_guarded_representation_constructor _, _
  | Guarded_constructor _, _ -> false

let same_source_case left right =
  Il.Eq.eq_typ left.payload_typ right.payload_typ
  && Il.Eq.eq_list Il.Eq.eq_param left.case_binds right.case_binds
  && Il.Eq.eq_list Il.Eq.eq_prem left.case_prems right.case_prems
  && Il.Eq.eq_list Il.Eq.eq_param left.instance_binds right.instance_binds
  && Il.Eq.eq_list Il.Eq.eq_arg left.instance_args right.instance_args
  && left.static_args_key = right.static_args_key
  && same_construction_domain
       left.construction_domain right.construction_domain

(* A [CaseE] constructor is identified by its mixop and payload schema; its
   enclosing syntax category is a static membership, not part of the runtime
   term.  Category-specific premises remain in separate typecheck equations. *)
let same_representation left right =
  left.emitted
  && right.emitted
  && Il.Eq.eq_mixop left.mixop right.mixop
  && left.arity = right.arity
  && List.length left.payload_typs = List.length right.payload_typs
  && List.for_all2 Il.Eq.eq_typ left.payload_typs right.payload_typs
  && left.payload_witnesses = right.payload_witnesses
  && left.payload_sorts = right.payload_sorts
  && Option.equal same_source_case left.source_case right.source_case

let analyze ~entries =
  let classes =
    List.fold_left
      (fun classes candidate ->
        let rec place preceding = function
          | [] -> List.rev_append preceding [ [ candidate ] ]
          | [] :: rest -> place preceding rest
          | (representative :: _ as class_) :: rest ->
            if same_representation representative candidate then
              List.rev_append preceding ((candidate :: class_) :: rest)
            else
              place (class_ :: preceding) rest
        in
        place [] classes)
      []
      entries
  in
  { classes }

let class_of analysis entry =
  analysis.classes
  |> List.find_opt (List.exists (same_entry entry))
  |> Option.value ~default:[ entry ]

let compare_origin left right =
  match String.compare (Origin.source_location left) (Origin.source_location right) with
  | 0 ->
    (match List.compare String.compare left.Origin.path right.Origin.path with
    | 0 ->
      (match String.compare left.ast_constructor right.ast_constructor with
      | 0 -> Option.compare String.compare left.source_echo right.source_echo
      | order -> order)
    | order -> order)
  | order -> order

let compare_entry left right =
  match String.compare left.source_category right.source_category with
  | 0 ->
    (match Option.compare String.compare left.static_args_key right.static_args_key with
    | 0 -> compare_origin left.origin right.origin
    | order -> order)
  | order -> order

let canonical_entry analysis entry =
  match class_of analysis entry with
  | [] -> Some entry
  | first :: rest ->
    Some
      (List.fold_left
         (fun least candidate ->
           if compare_entry candidate least < 0 then candidate else least)
         first
         rest)

let shared analysis entry =
  class_of analysis entry
  |> List.map (fun entry -> entry.source_category)
  |> List.sort_uniq String.compare
  |> fun categories -> List.length categories > 1

let equivalent analysis left right =
  match canonical_entry analysis left, canonical_entry analysis right with
  | Some left, Some right -> same_entry left right
  | None, _ | _, None -> false
