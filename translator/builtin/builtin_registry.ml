open Util.Source

type status = Implemented | Obligation
type activity = Active | Dormant

type requirement_source =
  | Hint_builtin
  | Declaration_only
  | Equational_view
  | Relation_surface

type dec_signature =
  { params : string list
  ; result : string
  ; source_location : string
  ; origin : Origin.t
  ; source_clauses : int
  ; has_static_params : bool
  }

type entry =
  { source_id : string
  ; hint_location : string
  ; hint_origin : Origin.t
  ; generated_op_stem : string
  ; signature : dec_signature option
  ; status : status
  ; source_echo : string
  ; requirement_source : requirement_source
  ; activity : activity
  ; backend_requirement : Builtin_backend.requirement option
  ; backend_issue : string option
  }

type t = { entries : entry list }

let entries registry = registry.entries

let find registry source_id =
  List.find_opt (fun entry -> entry.source_id = source_id) registry.entries

let is_hint_builtin registry source_id =
  match find registry source_id with
  | Some entry -> entry.requirement_source = Hint_builtin
  | None -> false

let definition_op registry id =
  if is_hint_builtin registry id.it then
    Naming.builtin_definition_op id
  else Naming.definition_op id

let declaration_is_partial registry source_id =
  match find registry source_id with
  | Some { requirement_source = Hint_builtin
         ; backend_requirement = Some requirement; _ } ->
    Builtin_backend.totality requirement = Builtin_backend.Partial
  | Some _ | None -> false

let with_entries _registry entries = { entries }

let has_static_param params =
  List.exists (fun param ->
    match param.it with
    | Il.Ast.TypP _ | DefP _ | GramP _ -> true
    | ExpP _ -> false)
    params

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
  | TypD _ | RelD _ | GramD _ | RecD _ | HintD _ -> ()

let is_builtin_hint hint =
  hint.Il.Ast.hintid.it = "builtin"

let dec_hint_parts hintdef =
  match hintdef.it with
  | Il.Ast.DecH (id, hints) -> Some (id, hints)
  | TypH _ | RelH _ | GramH _ | RuleH _ -> None

let entry_of_hint signatures origin hintdef =
  match dec_hint_parts hintdef with
  | None -> None
  | Some (_, hints) when not (List.exists is_builtin_hint hints) -> None
  | Some (id, _) ->
    Some
      { source_id = id.it
      ; hint_location = string_of_region hintdef.at
      ; hint_origin = origin
      ; generated_op_stem = Naming.builtin_definition_op id
      ; signature = Hashtbl.find_opt signatures id.it
      ; status = Obligation
      ; source_echo = "def $" ^ id.it ^ " hint(builtin)"
      ; requirement_source = Hint_builtin
      ; activity = Dormant
      ; backend_requirement = None
      ; backend_issue = None
      }

let collect_entry signatures acc (entry : Analysis.Source_index.entry) =
  match entry.def.it with
  | Il.Ast.HintD hintdef ->
    (match entry_of_hint signatures entry.origin hintdef with
    | Some builtin -> builtin :: acc
    | None -> acc)
  | TypD _ | RelD _ | DecD _ | GramD _ | RecD _ -> acc

let resolve backend available entry =
  let backend_requirement = Builtin_backend.find backend entry.source_id in
  let status, backend_issue =
    match backend_requirement with
    | None ->
      Obligation,
      Some "source requirement is absent from the builtin backend ABI contract"
    | Some requirement
      when Builtin_backend.public_op requirement <> entry.generated_op_stem ->
      Obligation,
      Some
        ("source operator '" ^ entry.generated_op_stem
         ^ "' does not match backend ABI operator '"
         ^ Builtin_backend.public_op requirement ^ "'")
    | Some requirement
      when not (List.for_all available
                  (Builtin_backend.dependencies requirement)) ->
      Obligation,
      Some "backend ABI dependencies are absent from the translated source"
    | Some _ -> Implemented, None
  in
  { entry with status; backend_requirement; backend_issue }

let of_source_index ?backend source_index =
  let backend = Option.value ~default:(Builtin_backend.load ()) backend in
  let signatures = Hashtbl.create 127 in
  let source_entries = Analysis.Source_index.entries source_index in
  List.iter (collect_signature signatures) source_entries;
  let entries =
    source_entries |> List.fold_left (collect_entry signatures) [] |> List.rev
  in
  let available source_id =
    List.exists (fun entry -> entry.source_id = source_id) entries
  in
  { entries = List.map (resolve backend available) entries }
