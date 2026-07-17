open Il.Ast
open Maude_ir
open Util.Source

open Expr_diagnostic
open Expr_result

let app name args = App (name, args)

let len term =
  app "len" [ term ]

let qid_of_atom atom =
  Qid (Xl.Atom.to_string atom)

let record_value atom record =
  app "value" [ qid_of_atom atom; record ]

type env = Expr_env.t

type callbacks =
  { lower_value : Context.t -> env -> Origin.t -> exp -> result
  ; lower_sequence : Context.t -> env -> Origin.t -> exp -> result
  }

let record_shape_diagnostic ctx origin constructor exp error =
  unsupported_exp ctx origin constructor exp (Record_shape.describe_error error)

let lower_record_literal callbacks ctx env origin (exp : exp) (fields : expfield list) =
  match Record_shape.of_typ ctx exp.note with
  | Error error -> record_shape_diagnostic ctx origin "Expr/StrE/type" exp error
  | Ok shape ->
    (match Record_shape.match_fields shape fields with
    | Error error -> record_shape_diagnostic ctx origin "Expr/StrE/fields" exp error
    | Ok fields ->
      let results =
        fields
        |> List.map (fun (_, (_, field_exp)) ->
          match Carrier_sort.for_expression field_exp.note with
          | Some sort when Carrier_sort.is_sequence_sort sort ->
            callbacks.lower_sequence ctx env origin field_exp
          | _ -> callbacks.lower_value ctx env origin field_exp)
      in
      let guards, diagnostics = append_result_metadata results in
      let terms = List.filter_map (fun result -> result.term) results in
      if List.length terms = List.length fields then
        { term = Some (app (Naming.record_constructor shape.id) terms)
        ; guards
        ; diagnostics
        }
      else
        { term = None; guards; diagnostics })

let lower_record_dot callbacks ctx env origin (record : exp) (atom : atom) =
  let record_result = callbacks.lower_value ctx env origin record in
  match record_result.term with
  | Some record_term ->
    { record_result with term = Some (record_value atom record_term) }
  | None -> record_result

let composition_error_origin origin error =
  List.fold_left
    (fun origin atom ->
      Origin.with_child origin (Xl.Atom.to_string atom)
        ~ast_constructor:"Expr/CompE/StructT-field" atom.at)
    origin (Record_shape.error_path error)

let rec dependency_path target plan =
  Record_certificate.plan_fields plan
  |> List.find_map (fun (atom, field) ->
       match field with
       | Record_certificate.Compose_record nested ->
         if Il.Eq.eq_id target (Record_certificate.plan_id nested) then
           Some [ atom ]
         else
           dependency_path target nested
           |> Option.map (fun path -> atom :: path)
       | Record_certificate.Append | Record_certificate.Compose_optional -> None)

let helper_error_origin origin plan = function
  | Record_certificate.Helper_unavailable (dependency :: _) ->
    dependency_path dependency plan
    |> Option.value ~default:[]
    |> List.fold_left
         (fun origin atom ->
           Origin.with_child origin (Xl.Atom.to_string atom)
             ~ast_constructor:"Expr/CompE/StructT-field" atom.at)
         origin
  | Record_certificate.Helper_emitted
  | Record_certificate.Helper_missing
  | Record_certificate.Helper_unavailable []
  | Record_certificate.Helper_incompatible -> origin

let helper_error_reason plan = function
  | Record_certificate.Helper_missing ->
    "the canonical StructT definition did not commit a record composition certificate"
  | Record_certificate.Helper_unavailable dependencies ->
    let helpers =
      match dependencies with
      | [] -> "its helper was not emitted"
      | _ ->
        "nested helpers are unavailable: "
        ^ (dependencies
           |> List.map Naming.record_composition
           |> String.concat ", ")
    in
    "the canonical helper `"
    ^ Naming.record_composition (Record_certificate.plan_id plan)
    ^ "` was not emitted because " ^ helpers
  | Record_certificate.Helper_incompatible ->
    "the elaborated StructT specialization disagrees with the committed record composition certificate"
  | Record_certificate.Helper_emitted ->
    "the emitted record composition helper was unexpectedly rejected"

let lower_comp callbacks ctx env origin (exp : exp) (left : exp) (right : exp) =
  let lower shape =
    let lower =
      match shape with
      | Record_shape.Sequence | Record_shape.Optional -> callbacks.lower_sequence
      | Record_shape.Record _ -> callbacks.lower_value
    in
    let left_result = lower ctx env origin left in
    let right_result = lower ctx env origin right in
    let term, shape_diagnostics =
      match shape, left_result.term, right_result.term with
      | Record_shape.Sequence, Some left, Some right ->
        Some (app "_ _" [ left; right ]), []
      | Record_shape.Optional, Some left, Some right ->
        Some (app "composeOpt" [ left; right ]), []
      | Record_shape.Record shape, Some left, Some right ->
        Some (app (Naming.record_composition shape.id) [ left; right ]), []
      | _ -> None, []
    in
    { term
    ; guards = left_result.guards @ right_result.guards
    ; diagnostics =
        left_result.diagnostics @ right_result.diagnostics @ shape_diagnostics
    }
  in
  match Record_shape.concatenable ctx exp.note with
  | Error error -> record_shape_diagnostic ctx origin "Expr/CompE/type" exp error
  | Ok (Record_shape.Record shape as composition) ->
    (match Record_shape.composition ctx shape with
    | Ok plan ->
      let status =
        Record_certificate.helper_status (Context.record_certificates ctx) plan
      in
      (match status with
      | Record_certificate.Helper_emitted -> lower composition
      | Record_certificate.Helper_missing
      | Record_certificate.Helper_unavailable _
      | Record_certificate.Helper_incompatible ->
        unsupported_exp ctx (helper_error_origin origin plan status)
          "Expr/CompE/composition-helper" exp
          (helper_error_reason plan status))
    | Error error ->
      record_shape_diagnostic ctx (composition_error_origin origin error)
        "Expr/CompE/field" exp error)
  | Ok composition -> lower composition

let lower_len callbacks ctx env origin (inner : exp) =
  let inner_result = callbacks.lower_sequence ctx env origin inner in
  match inner_result.term with
  | Some term -> { inner_result with term = Some (len term) }
  | None -> inner_result

let nat_index_diagnostics ctx origin constructor exp =
  if Carrier_sort.typ_is_nat ctx exp.note then
    []
  else
    [ unsupported
        ~ctx ~origin ~constructor
        ~source_echo:(source_echo_exp exp)
        ~reason:
          "sequence index/slice bound must have Nat type because the Maude prelude sequence operators use Nat positions"
        ~suggestion:
          "Lower a verified numeric conversion to Nat before using this expression as a sequence position"
        ()
    ]

let slice_bounds_guards sequence first count =
  [ BoolCond (app "_<=_" [ app "_+_" [ first; count ]; len sequence ]) ]

let index_op typ =
  match Carrier_sort.for_expression typ with
  | Some sort when Carrier_sort.is_sequence_sort sort -> Some "indexSeq"
  | Some _ -> Some "index"
  | None -> None

(* A nested sequence stores each sequence-valued element as [seq(s)].
   Indexing removes that boundary, so indexed update must restore it. *)
let index_element typ term =
  match Carrier_sort.for_expression typ with
  | Some sort when Carrier_sort.is_sequence_sort sort -> app "seq" [ term ]
  | _ -> term

let lower_index callbacks ctx env origin (exp : exp) (base : exp) (index : exp) =
  let base_result = callbacks.lower_sequence ctx env origin base in
  let index_result = callbacks.lower_value ctx env origin index in
  let index_sort_diagnostics =
    nat_index_diagnostics ctx origin "Expr/IdxE/index-sort" index
  in
  let op = index_op exp.note in
  match base_result.term, index_result.term, op with
  | Some base_term, Some index_term, Some op when index_sort_diagnostics = [] ->
    { term = Some (app op [ base_term; index_term ])
    ; guards =
        base_result.guards @ index_result.guards
        @ [ BoolCond (app "indexDefined" [ base_term; index_term ]) ]
    ; diagnostics = base_result.diagnostics @ index_result.diagnostics
    }
  | _ ->
    { term = None
    ; guards = base_result.guards @ index_result.guards
    ; diagnostics =
        base_result.diagnostics @ index_result.diagnostics @ index_sort_diagnostics
        @
        (match op with
        | Some _ -> []
        | None ->
          [ unsupported
              ~ctx ~origin ~constructor:"Expr/IdxE/result-sort"
              ~source_echo:(source_echo_exp exp)
              ~reason:"sequence index result has no supported Maude carrier"
              ~suggestion:
                "Keep this IdxE Unsupported until its result type has a verified Maude carrier"
              ()
          ])
    }

let lower_slice callbacks ctx env origin (base : exp) (first : exp) (count : exp) =
  let base_result = callbacks.lower_sequence ctx env origin base in
  let first_result = callbacks.lower_value ctx env origin first in
  let count_result = callbacks.lower_value ctx env origin count in
  let position_diagnostics =
    nat_index_diagnostics ctx origin "Expr/SliceE/first-sort" first
    @ nat_index_diagnostics ctx origin "Expr/SliceE/count-sort" count
  in
  match base_result.term, first_result.term, count_result.term with
  | Some base_term, Some first_term, Some count_term when position_diagnostics = [] ->
    { term = Some (app "slice" [ base_term; first_term; count_term ])
    ; guards =
        base_result.guards @ first_result.guards @ count_result.guards
        @ slice_bounds_guards base_term first_term count_term
    ; diagnostics =
        base_result.diagnostics @ first_result.diagnostics @ count_result.diagnostics
    }
  | _ ->
    { term = None
    ; guards = base_result.guards @ first_result.guards @ count_result.guards
    ; diagnostics =
        base_result.diagnostics @ first_result.diagnostics @ count_result.diagnostics
        @ position_diagnostics
    }

let combine_binary left right term =
  { term
  ; guards = left.guards @ right.guards
  ; diagnostics = left.diagnostics @ right.diagnostics
  }

let rec lower_path_select callbacks ctx env origin (path_source : path) record_term
    (path : path) =
  match path.it with
  | RootP -> with_term record_term
  | DotP (parent, atom) ->
    let parent_result =
      lower_path_select callbacks ctx env origin path_source record_term parent
    in
    (match parent_result.term with
    | Some parent_term ->
      { parent_result with term = Some (record_value atom parent_term) }
    | None -> parent_result)
  | IdxP (parent, index_exp) ->
    let parent_result =
      lower_path_select callbacks ctx env origin path_source record_term parent
    in
    let index_result = callbacks.lower_value ctx env origin index_exp in
    let index_diagnostics =
      nat_index_diagnostics ctx origin "Expr/Path/IdxP/index-sort" index_exp
    in
    let op = index_op path.note in
    (match parent_result.term, index_result.term, op with
    | Some parent_term, Some index_term, Some op when index_diagnostics = [] ->
      combine_binary parent_result index_result
        (Some (app op [ parent_term; index_term ]))
    | _ ->
      let result = combine_binary parent_result index_result None in
      { result with
        diagnostics =
          result.diagnostics @ index_diagnostics
          @
          (match op with
          | Some _ -> []
          | None ->
            [ unsupported
                ~ctx ~origin ~constructor:"Expr/Path/IdxP/result-sort"
                ~source_echo:(Il.Print.string_of_path path_source)
                ~reason:"indexed path result has no supported Maude carrier"
                ~suggestion:
                  "Keep this indexed path Unsupported until its result type has a verified Maude carrier"
                ()
            ])
      })
  | SliceP (parent, first, count) ->
    let parent_result =
      lower_path_select callbacks ctx env origin path_source record_term parent
    in
    let first_result = callbacks.lower_value ctx env origin first in
    let count_result = callbacks.lower_value ctx env origin count in
    let position_diagnostics =
      nat_index_diagnostics ctx origin "Expr/Path/SliceP/first-sort" first
      @ nat_index_diagnostics ctx origin "Expr/Path/SliceP/count-sort" count
    in
    (match parent_result.term, first_result.term, count_result.term with
    | Some parent_term, Some first_term, Some count_term when position_diagnostics = [] ->
      { term = Some (app "slice" [ parent_term; first_term; count_term ])
      ; guards =
          parent_result.guards @ first_result.guards @ count_result.guards
          @ slice_bounds_guards parent_term first_term count_term
      ; diagnostics =
          parent_result.diagnostics @ first_result.diagnostics
          @ count_result.diagnostics
      }
    | _ ->
      { term = None
      ; guards = parent_result.guards @ first_result.guards @ count_result.guards
      ; diagnostics =
          parent_result.diagnostics @ first_result.diagnostics
          @ count_result.diagnostics
          @ position_diagnostics
      })

let rec lower_path_update callbacks ctx env origin (exp : exp) record_term
    (path : path) replacement_term =
  match path.it with
  | RootP -> with_term replacement_term
  | DotP ({ it = RootP; _ }, atom) ->
    with_term (app "_[._<-_]" [ record_term; qid_of_atom atom; replacement_term ])
  | DotP (parent, atom) ->
    let parent_result =
      lower_path_select callbacks ctx env origin path record_term parent
    in
    (match parent_result.term with
    | Some parent_term ->
      let nested_update =
        app "_[._<-_]" [ parent_term; qid_of_atom atom; replacement_term ]
      in
      let updated_parent =
        lower_path_update callbacks ctx env origin exp record_term parent nested_update
      in
      { updated_parent with
        guards = parent_result.guards @ updated_parent.guards
      ; diagnostics = parent_result.diagnostics @ updated_parent.diagnostics
      }
    | None -> parent_result)
  | IdxP (parent, index_exp) ->
    let parent_result =
      lower_path_select callbacks ctx env origin path record_term parent
    in
    let index_result = callbacks.lower_value ctx env origin index_exp in
    let index_diagnostics =
      nat_index_diagnostics ctx origin "Expr/UpdE/IdxP/index-sort" index_exp
    in
    (match parent_result.term, index_result.term with
    | Some parent_term, Some index_term when index_diagnostics = [] ->
      let nested_update =
        app "_[_<-_]"
          [ parent_term; index_term; index_element path.note replacement_term ]
      in
      let updated_parent =
        lower_path_update callbacks ctx env origin exp record_term parent nested_update
      in
      { updated_parent with
        guards = parent_result.guards @ index_result.guards @ updated_parent.guards
      ; diagnostics =
          parent_result.diagnostics @ index_result.diagnostics
          @ updated_parent.diagnostics
      }
    | _ ->
      let result = combine_binary parent_result index_result None in
      { result with diagnostics = result.diagnostics @ index_diagnostics })
  | SliceP (parent, first, count) ->
    let parent_result =
      lower_path_select callbacks ctx env origin path record_term parent
    in
    let first_result = callbacks.lower_value ctx env origin first in
    let count_result = callbacks.lower_value ctx env origin count in
    let position_diagnostics =
      nat_index_diagnostics ctx origin "Expr/UpdE/SliceP/first-sort" first
      @ nat_index_diagnostics ctx origin "Expr/UpdE/SliceP/count-sort" count
    in
    (match parent_result.term, first_result.term, count_result.term with
    | Some parent_term, Some first_term, Some count_term when position_diagnostics = [] ->
      let nested_update =
        app "splice" [ parent_term; first_term; count_term; replacement_term ]
      in
      let updated_parent =
        lower_path_update callbacks ctx env origin exp record_term parent nested_update
      in
      { updated_parent with
        guards =
          parent_result.guards @ first_result.guards @ count_result.guards
          @ slice_bounds_guards parent_term first_term count_term
          @ updated_parent.guards
      ; diagnostics =
          parent_result.diagnostics @ first_result.diagnostics
          @ count_result.diagnostics @ updated_parent.diagnostics
      }
    | _ ->
      { term = None
      ; guards = parent_result.guards @ first_result.guards @ count_result.guards
      ; diagnostics =
          parent_result.diagnostics @ first_result.diagnostics
          @ count_result.diagnostics
          @ position_diagnostics
      })

let lower_path_extension callbacks ctx env origin (exp : exp) record_term
    (path : path) extension_term =
  match path.it with
  | RootP -> with_term (app "_ _" [ record_term; extension_term ])
  | DotP ({ it = RootP; _ }, atom) ->
    with_term (app "_[._=++_]" [ record_term; qid_of_atom atom; extension_term ])
  | DotP (parent, atom) ->
    let parent_result =
      lower_path_select callbacks ctx env origin path record_term parent
    in
    (match parent_result.term with
    | Some parent_term ->
      let nested_extension =
        app "_[._=++_]" [ parent_term; qid_of_atom atom; extension_term ]
      in
      let updated_parent =
        lower_path_update callbacks ctx env origin exp record_term parent nested_extension
      in
      { updated_parent with
        guards = parent_result.guards @ updated_parent.guards
      ; diagnostics = parent_result.diagnostics @ updated_parent.diagnostics
      }
    | None -> parent_result)
  | IdxP _ | SliceP _ ->
    with_diagnostics
      [ unsupported
          ~ctx ~origin ~constructor:"Expr/ExtE/path"
          ~source_echo:(source_echo_exp exp)
          ~reason:
            "ExtE over index or slice paths requires preserving the selected sequence and then writing it back; this slice only supports helper-free field extension"
          ~suggestion:
            "Keep this as an explicit Unsupported case until indexed/sliced ExtE is documented and tested separately"
          ()
      ]

let lower_record_update callbacks ctx env origin (exp : exp) (record : exp)
    (path : path) (replacement : exp) =
  let record_result = callbacks.lower_value ctx env origin record in
  let rec path_has_slice path =
    match path.it with
    | RootP -> false
    | DotP (parent, _) | IdxP (parent, _) -> path_has_slice parent
    | SliceP _ -> true
  in
  let replacement_result =
    if path_has_slice path then
      callbacks.lower_sequence ctx env origin replacement
    else
      callbacks.lower_value ctx env origin replacement
  in
  match record_result.term, replacement_result.term with
  | Some record_term, Some replacement_term ->
    let update_result =
      lower_path_update callbacks ctx env origin exp record_term path replacement_term
    in
    { update_result with
      guards = record_result.guards @ replacement_result.guards @ update_result.guards
    ; diagnostics =
        record_result.diagnostics @ replacement_result.diagnostics
        @ update_result.diagnostics
    }
  | _ ->
    { term = None
    ; guards = record_result.guards @ replacement_result.guards
    ; diagnostics = record_result.diagnostics @ replacement_result.diagnostics
    }

let lower_record_extension callbacks ctx env origin (exp : exp) (record : exp)
    (path : path) (extension : exp) =
  let record_result = callbacks.lower_value ctx env origin record in
  let extension_result = callbacks.lower_sequence ctx env origin extension in
  match record_result.term, extension_result.term with
  | Some record_term, Some extension_term ->
    let extension_result' =
      lower_path_extension callbacks ctx env origin exp record_term path extension_term
    in
    { extension_result' with
      guards = record_result.guards @ extension_result.guards @ extension_result'.guards
    ; diagnostics =
        record_result.diagnostics @ extension_result.diagnostics
        @ extension_result'.diagnostics
    }
  | _ ->
    { term = None
    ; guards = record_result.guards @ extension_result.guards
    ; diagnostics = record_result.diagnostics @ extension_result.diagnostics
    }
