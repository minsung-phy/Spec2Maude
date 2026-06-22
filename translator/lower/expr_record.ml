open Il.Ast
open Util.Source

include Expr_support

type callbacks =
  { lower_value : Context.t -> env -> Origin.t -> exp -> result
  ; lower_sequence : Context.t -> env -> Origin.t -> exp -> result
  }

let lower_record_literal callbacks ctx env origin (_exp : exp) (fields : expfield list) =
  let results =
    fields
    |> List.map (fun (atom, field_exp) ->
      let result =
        match carrier_sort_of_typ field_exp.note with
        | Some sort when is_sequence_sort sort ->
          callbacks.lower_sequence ctx env origin field_exp
        | _ -> callbacks.lower_value ctx env origin field_exp
      in
      atom, result)
  in
  let guards =
    results
    |> List.map (fun (_atom, result) -> result.guards)
    |> List.concat
  in
  let diagnostics =
    results
    |> List.map (fun (_atom, result) -> result.diagnostics)
    |> List.concat
  in
  let items =
    results
    |> List.filter_map (fun (atom, result) ->
      match result.term with
      | Some term -> Some (record_item atom term)
      | None -> None)
  in
  if List.length items = List.length fields then
    { term = Some (record_literal (record_items items)); guards; diagnostics }
  else
    { term = None; guards; diagnostics }

let lower_record_dot callbacks ctx env origin (record : exp) (atom : atom) =
  let record_result = callbacks.lower_value ctx env origin record in
  match record_result.term with
  | Some record_term ->
    { record_result with term = Some (record_value atom record_term) }
  | None -> record_result

let lower_comp callbacks ctx env origin (left : exp) (right : exp) =
  let left_result = callbacks.lower_value ctx env origin left in
  let right_result = callbacks.lower_value ctx env origin right in
  match left_result.term, right_result.term with
  | Some left_term, Some right_term ->
    { term = Some (app "merge" [ left_term; right_term ])
    ; guards = left_result.guards @ right_result.guards
    ; diagnostics = left_result.diagnostics @ right_result.diagnostics
    }
  | _ ->
    { term = None
    ; guards = left_result.guards @ right_result.guards
    ; diagnostics = left_result.diagnostics @ right_result.diagnostics
    }

let lower_len callbacks ctx env origin (inner : exp) =
  let inner_result = callbacks.lower_sequence ctx env origin inner in
  match inner_result.term with
  | Some term -> { inner_result with term = Some (len term) }
  | None -> inner_result

let lower_index callbacks ctx env origin (base : exp) (index : exp) =
  let base_result = callbacks.lower_sequence ctx env origin base in
  let index_result = callbacks.lower_value ctx env origin index in
  let index_sort_diagnostics =
    if typ_is_nat ctx index.note then
      []
    else
      [ unsupported
          ~ctx ~origin ~constructor:"Expr/IdxE/index-sort"
          ~source_echo:(source_echo_exp index)
          ~reason:
            "IdxE requires a Nat index because Maude prelude declares index : SpectecTerminals Nat -> SpectecTerminal"
          ~suggestion:
            "Keep this expression Unsupported until the source index type is known to be Nat or a source-preserving numeric conversion is available"
          ()
      ]
  in
  match base_result.term, index_result.term with
  | Some base_term, Some index_term when index_sort_diagnostics = [] ->
    { term = Some (app "index" [ base_term; index_term ])
    ; guards = base_result.guards @ index_result.guards
    ; diagnostics = base_result.diagnostics @ index_result.diagnostics
    }
  | _ ->
    { term = None
    ; guards = base_result.guards @ index_result.guards
    ; diagnostics =
        base_result.diagnostics @ index_result.diagnostics @ index_sort_diagnostics
    }

let lower_slice callbacks ctx env origin (base : exp) (first : exp) (last : exp) =
  let base_result = callbacks.lower_sequence ctx env origin base in
  let first_result = callbacks.lower_value ctx env origin first in
  let last_result = callbacks.lower_value ctx env origin last in
  match base_result.term, first_result.term, last_result.term with
  | Some base_term, Some first_term, Some last_term ->
    { term = Some (app "slice" [ base_term; first_term; last_term ])
    ; guards = base_result.guards @ first_result.guards @ last_result.guards
    ; diagnostics =
        base_result.diagnostics @ first_result.diagnostics @ last_result.diagnostics
    }
  | _ ->
    { term = None
    ; guards = base_result.guards @ first_result.guards @ last_result.guards
    ; diagnostics =
        base_result.diagnostics @ first_result.diagnostics @ last_result.diagnostics
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
    (match parent_result.term, index_result.term with
    | Some parent_term, Some index_term ->
      combine_binary parent_result index_result
        (Some (app "index" [ parent_term; index_term ]))
    | _ -> combine_binary parent_result index_result None)
  | SliceP (parent, first, last) ->
    let parent_result =
      lower_path_select callbacks ctx env origin path_source record_term parent
    in
    let first_result = callbacks.lower_value ctx env origin first in
    let last_result = callbacks.lower_value ctx env origin last in
    (match parent_result.term, first_result.term, last_result.term with
    | Some parent_term, Some first_term, Some last_term ->
      { term = Some (app "slice" [ parent_term; first_term; last_term ])
      ; guards = parent_result.guards @ first_result.guards @ last_result.guards
      ; diagnostics =
          parent_result.diagnostics @ first_result.diagnostics
          @ last_result.diagnostics
      }
    | _ ->
      { term = None
      ; guards = parent_result.guards @ first_result.guards @ last_result.guards
      ; diagnostics =
          parent_result.diagnostics @ first_result.diagnostics
          @ last_result.diagnostics
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
    (match parent_result.term, index_result.term with
    | Some parent_term, Some index_term ->
      let nested_update =
        app "_[_<-_]" [ parent_term; index_term; replacement_term ]
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
    | _ -> combine_binary parent_result index_result None)
  | SliceP _ ->
    unsupported_exp ctx origin "Expr/UpdE/SliceP" exp
      "path update through SliceP needs a splice helper; direct source-shaped update is not implemented"

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
    unsupported_exp ctx origin "Expr/ExtE/path" exp
      "path extension is implemented only for direct record fields because index/slice extension needs a sequence splice helper"

let lower_record_update callbacks ctx env origin (exp : exp) (record : exp)
    (path : path) (replacement : exp) =
  let record_result = callbacks.lower_value ctx env origin record in
  let replacement_result = callbacks.lower_value ctx env origin replacement in
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
