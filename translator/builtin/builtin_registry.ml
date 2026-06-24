open Util.Source

type status = Builtin_types.status =
  | Implemented
  | Obligation

type dec_signature = Builtin_types.dec_signature =
  { params : string list
  ; result : string
  ; source_location : string
  ; origin : Origin.t
  ; source_clauses : int
  ; has_static_params : bool
  }

type entry = Builtin_types.entry =
  { source_id : string
  ; hint_location : string
  ; hint_origin : Origin.t
  ; generated_op_stem : string
  ; signature : dec_signature option
  ; status : status
  ; official_semantics_source : string
  ; smoke_test : string option
  ; source_echo : string
  }

type t = Builtin_types.t

let count = Builtin_types.count
let implemented_count = Builtin_types.implemented_count
let obligation_count = Builtin_types.obligation_count

let has_static_param params =
  params
  |> List.exists (fun param ->
    match param.it with
    | Il.Ast.TypP _ | DefP _ | GramP _ -> true
    | ExpP _ -> false)

let add_signature table origin id params result_typ clauses def =
  let signature =
    { params = List.map Il.Print.string_of_param params
    ; result = Il.Print.string_of_typ result_typ
    ; source_location = string_of_region def.at
    ; origin
    ; source_clauses = List.length clauses
    ; has_static_params = has_static_param params
    }
  in
  Hashtbl.replace table id.it signature

let collect_signature table (entry : Analysis.Source_index.entry) =
  match entry.def.it with
  | Il.Ast.DecD (id, params, result_typ, clauses) ->
    add_signature table entry.origin id params result_typ clauses entry.def
  | TypD _ | RelD _ | GramD _ | RecD _ | HintD _ ->
    ()

let is_builtin_hint hint =
  match Analysis.Hint_policy.classify hint with
  | Analysis.Hint_policy.Semantic_obligation ->
    hint.Il.Ast.hintid.it = "builtin"
  | Analysis.Hint_policy.Presentation
  | Analysis.Hint_policy.Translator_annotation
  | Analysis.Hint_policy.Unknown ->
    false

let dec_hint_parts hintdef =
  match hintdef.it with
  | Il.Ast.DecH (id, hints) -> Some (id, hints)
  | TypH _ | RelH _ | GramH _ -> None

let entry_of_hint signatures origin hintdef =
  match dec_hint_parts hintdef with
  | None -> None
  | Some (_id, hints) when not (List.exists is_builtin_hint hints) -> None
  | Some (id, _hints) ->
    let signature = Hashtbl.find_opt signatures id.it in
    Some
      { source_id = id.it
      ; hint_location = string_of_region hintdef.at
      ; hint_origin = origin
      ; generated_op_stem = Naming.definition_op id
      ; signature
      ; status = Builtin_spec.status_of_source_id id.it
      ; official_semantics_source =
          Builtin_spec.semantics_source_for_source_id id.it
      ; smoke_test = Builtin_spec.smoke_test_for_source_id id.it
      ; source_echo = "def $" ^ id.it ^ " hint(builtin)"
      }

let collect_entry signatures acc (source_entry : Analysis.Source_index.entry) =
  match source_entry.def.it with
  | Il.Ast.HintD hintdef ->
    (match entry_of_hint signatures source_entry.origin hintdef with
    | None -> acc
    | Some entry -> entry :: acc)
  | TypD _ | RelD _ | DecD _ | GramD _ | RecD _ ->
    acc

let of_source_index source_index =
  let signatures = Hashtbl.create 127 in
  let entries = Analysis.Source_index.entries source_index in
  List.iter (collect_signature signatures) entries;
  entries
  |> List.fold_left (collect_entry signatures) []
  |> List.rev

let render_markdown = Builtin_report.render_markdown
let render_maude_interface = Builtin_maude_renderer.render_maude_interface
