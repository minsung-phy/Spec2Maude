open Builtin_registry
open Maude_ir
open Util.Source

module StringSet = Set.Make (String)

let representation_prefix = "representation certificate unavailable: "

let rec collect_term used = function
  | Var _ | Const _ | Qid _ -> used
  | App (op, args) ->
    List.fold_left collect_term (StringSet.add op used) args

let collect_eq_condition used = function
  | EqCond (left, right) | MatchCond (left, right) ->
    collect_term (collect_term used left) right
  | MembershipCond (term, _) | BoolCond term -> collect_term used term

let collect_rule_condition used = function
  | EqCondition condition -> collect_eq_condition used condition
  | RewriteCond (left, right) ->
    collect_term (collect_term used left) right

let collect_statement (used, declared, defined) statement =
  let used =
    match statement.node with
    | SortDecl _ | SubsortDecl _ | OpDecl _ | VarDecl _ -> used
    | Mb (term, _) -> collect_term used term
    | Cmb (term, _, conditions) ->
      List.fold_left collect_eq_condition (collect_term used term) conditions
    | Eq (left, right, _) ->
      collect_term (collect_term used left) right
    | Ceq (left, right, conditions, _) ->
      List.fold_left collect_eq_condition
        (collect_term (collect_term used left) right) conditions
    | Rl (_, left, right) ->
      collect_term (collect_term used left) right
    | Crl (_, left, right, conditions) ->
      List.fold_left collect_rule_condition
        (collect_term (collect_term used left) right) conditions
  in
  let declared =
    match statement.node with
    | OpDecl declaration -> StringSet.add declaration.name declared
    | _ -> declared
  in
  let defined =
    match statement.node with
    | Eq (App (op, _), _, _) | Ceq (App (op, _), _, _, _)
    | Rl (_, App (op, _), _) | Crl (_, App (op, _), _, _) ->
      StringSet.add op defined
    | _ -> defined
  in
  used, declared, defined

let statement_inventory statements =
  List.fold_left collect_statement
    (StringSet.empty, StringSet.empty, StringSet.empty) statements

let has_static_param params =
  List.exists (fun (param : Il.Ast.param) ->
    match param.it with
    | Il.Ast.TypP _ | DefP _ | GramP _ -> true
    | ExpP _ -> false)
    params

let signature origin def params result clauses =
  { params = List.map Il.Print.string_of_param params
  ; result = Il.Print.string_of_typ result
  ; source_location = string_of_region def.at
  ; origin
  ; source_clauses = List.length clauses
  ; has_static_params = has_static_param params
  }

let direct_decd_entry source_index registry op_name =
  Analysis.Source_index.entries source_index
  |> List.find_map (fun source_entry ->
    match source_entry.Analysis.Source_index.def.it with
    | Il.Ast.DecD (id, params, result, clauses)
      when Builtin_registry.definition_op registry id = op_name ->
      Some
        ( id.it
        , Some (signature source_entry.origin source_entry.def params result clauses)
        , source_entry.origin
        , Il.Print.string_of_def source_entry.def )
    | DecD _ | TypD _ | RelD _ | GramD _ | RecD _ | HintD _ -> None)

let backend_resolution backend source_id op_name =
  match Builtin_backend.find backend source_id with
  | Some requirement when Builtin_backend.public_op requirement = op_name ->
    Implemented, Some requirement, None
  | Some requirement ->
    Obligation, Some requirement,
    Some
      ("generated operator '" ^ op_name ^ "' does not match backend ABI operator '"
       ^ Builtin_backend.public_op requirement ^ "'")
  | None ->
    Obligation, None,
    Some "source declaration has no defining clause or backend ABI requirement"

let generated_decd_entries
    backend source_index statements registry used defined =
  statements
  |> List.filter_map (fun generated ->
    match generated.node with
    | OpDecl declaration
      when generated.origin.Origin.ast_constructor = "DecD"
           && not (StringSet.mem declaration.name defined)
           && not
                (Builtin_registry.entries registry
                 |> List.exists (fun entry ->
                   entry.generated_op_stem = declaration.name)) ->
      let source_id, signature, origin, source_echo =
        match direct_decd_entry source_index registry declaration.name with
        | Some metadata -> metadata
        | None ->
          ( declaration.name
          , None
          , generated.origin
          , Option.value
              ~default:("generated declaration " ^ declaration.name)
              generated.origin.source_echo )
      in
      let status, backend_requirement, backend_issue =
        backend_resolution backend source_id declaration.name
      in
      Some
        { source_id
        ; hint_location = Origin.source_location origin
        ; hint_origin = origin
        ; generated_op_stem = declaration.name
        ; signature
        ; status
        ; source_echo
        ; requirement_source = Declaration_only
        ; activity =
            if StringSet.mem declaration.name used then Active else Dormant
        ; backend_requirement
        ; backend_issue
        }
    | _ -> None)

let relation_surface_entries graph source_index used declared defined =
  Analysis.Source_index.entries source_index
  |> List.filter_map (fun source_entry ->
    match source_entry.Analysis.Source_index.def.it with
    | Il.Ast.RelD (id, _, _, _, _) ->
      let op_name = Naming.relation_op id in
      if Option.is_none (Analysis.Function_graph.find_relation graph id.it)
         || not (StringSet.mem op_name declared)
         || StringSet.mem op_name defined
      then None
      else
        Some
          { source_id = id.it
          ; hint_location = Origin.source_location source_entry.origin
          ; hint_origin = source_entry.origin
          ; generated_op_stem = op_name
          ; signature = None
          ; status = Obligation
          ; source_echo = Il.Print.string_of_def source_entry.def
          ; requirement_source = Relation_surface
          ; activity = if StringSet.mem op_name used then Active else Dormant
          ; backend_requirement = None
          ; backend_issue =
              Some
                "emitted RelD operator has no emitted truth equation or rewrite rule"
          }
    | DecD _ | TypD _ | GramD _ | RecD _ | HintD _ -> None)

let update_hint_activity used entry =
  let activity =
    match entry.backend_requirement with
    | Some requirement
      when Builtin_backend.demand requirement = Builtin_backend.Indirect ->
      Active
    | Some _ | None ->
      if StringSet.mem entry.generated_op_stem used then Active else Dormant
  in
  { entry with activity }

let representation_candidates constructors representation =
  Constructor_registry.entries constructors
  |> List.filter (fun entry ->
    entry.Constructor_registry.source_category
      = Builtin_backend.representation_category representation
    && entry.status = Constructor_registry.Emitted
    && entry.arity = Builtin_backend.representation_arity representation
    && entry.payload_sorts
       = [ Maude_ir.sort
             (Builtin_backend.representation_payload_sort representation) ])

let representation_error constructors representation =
  let key = Builtin_backend.representation_key representation in
  match representation_candidates constructors representation with
  | [] ->
    Some
      (key,
       "canonical '" ^ Builtin_backend.representation_category representation
       ^ "' constructor is not registered")
  | [ entry ]
    when entry.constructor_op
         <> Builtin_backend.representation_constructor representation ->
    Some
      (key,
       "registered constructor '" ^ entry.constructor_op
       ^ "' does not match backend ABI constructor '"
       ^ Builtin_backend.representation_constructor representation ^ "'")
  | [ entry ] ->
    (match Builtin_backend.representation_witness representation with
    | Some witness
      when Naming.primitive_witness entry.source_category <> witness ->
      Some
        (key,
         "registered witness does not match backend ABI witness '" ^ witness ^ "'")
    | Some _ | None -> None)
  | _ ->
    Some
      (key,
       "canonical '" ^ Builtin_backend.representation_category representation
       ^ "' constructor is ambiguous")

let representation_errors backend constructors =
  Builtin_backend.requirements backend
  |> List.concat_map (fun requirement ->
    Builtin_backend.representations requirement
    |> List.filter_map (Builtin_backend.representation backend))
  |> List.sort_uniq (fun left right ->
       String.compare
         (Builtin_backend.representation_key left)
         (Builtin_backend.representation_key right))
  |> List.filter_map (representation_error constructors)

let global_representation_errors backend constructors =
  Builtin_backend.representation_requirements backend
  |> List.filter (fun representation ->
       Builtin_backend.representation_scope representation
       = Builtin_backend.Global)
  |> List.filter_map (representation_error constructors)

let apply_representation_errors errors entry =
  match entry.backend_requirement with
  | None -> entry
  | Some requirement ->
    let reasons =
      Builtin_backend.representations requirement
      |> List.filter_map (fun key -> List.assoc_opt key errors)
    in
    match reasons with
    | [] -> entry
    | _ ->
      { entry with
        status = Obligation
      ; backend_issue = Some (representation_prefix ^ String.concat "; " reasons)
      }

let diagnostic profile entry =
  let category, constructor, reason, suggestion =
    match entry.status, entry.activity, entry.requirement_source with
    | Obligation, Active, _
      when Option.fold ~none:false
             ~some:(String.starts_with ~prefix:representation_prefix)
             entry.backend_issue ->
      ( Diagnostics.Obligation
      , "Backend/representation-certificate"
      , Option.get entry.backend_issue
      , "Emit the exact constructor and witness required by the backend ABI contract before enabling this primitive" )
    | Obligation, Active, Hint_builtin ->
      ( Diagnostics.Obligation
      , "Backend/hint-builtin-active"
      , "generated Maude calls backend primitive '" ^ entry.generated_op_stem
        ^ "', which the selected backend ABI does not implement"
      , "Select a backend contract that implements this primitive or provide source-complete backend semantics" )
    | Obligation, Active, Declaration_only ->
      ( Diagnostics.Obligation
      , "Backend/declaration-only-active"
      , "generated Maude calls declaration-only operator '"
        ^ entry.generated_op_stem ^ "', but no defining equation was emitted"
      , "Implement its source clauses or provide an explicit backend contract" )
    | Obligation, Active, Equational_view ->
      ( Diagnostics.Obligation
      , "Backend/equational-view-active"
      , "generated DecD equations call equational-view operator '"
        ^ entry.generated_op_stem ^ "', but the view has no defining equations"
      , "Implement the annotated relation view under an explicit backend contract or keep its consumers non-equational" )
    | Obligation, Active, Relation_surface ->
      ( Diagnostics.Obligation
      , "Backend/relation-surface-active"
      , "generated Maude calls relation operator '" ^ entry.generated_op_stem
        ^ "', but no defining truth equation or rewrite rule was emitted"
      , "Materialize the relation source-completely or remove the generated call at its consuming boundary" )
    | Obligation, Dormant, _ ->
      ( Diagnostics.Skipped
      , "Backend/obligation-dormant"
      , "unimplemented backend operator '" ^ entry.generated_op_stem
        ^ "' is not called by emitted Maude"
      , "Keep it visible as dormant metadata; promote it if generated runtime code begins calling it" )
    | Implemented, Active, _ ->
      ( Diagnostics.Skipped
      , "Backend/implemented-active"
      , "active backend operator '" ^ entry.generated_op_stem
        ^ "' is implemented by the selected backend"
      , "Retain its ABI provenance and test-owned smoke coverage" )
    | Implemented, Dormant, _ ->
      ( Diagnostics.Skipped
      , "Backend/implemented-dormant"
      , "backend operator '" ^ entry.generated_op_stem
        ^ "' is implemented by the selected backend but dormant in generated Maude"
      , "Retain the implementation as backend metadata without counting it as an active obligation" )
  in
  Diagnostics.make
    ~category
    ~origin:entry.hint_origin
    ~constructor
    ~enclosing:
      (Diagnostic_provenance.enclosing ~context:entry.hint_origin.Origin.path
         entry.hint_origin)
    ~profile
    ~reason
    ~suggestion
    ~source_echo:entry.source_echo
    ()

let dedup_entries entries =
  entries
  |> List.fold_left (fun acc entry ->
    if List.exists (fun old ->
         old.source_id = entry.source_id
         && old.requirement_source = entry.requirement_source) acc then
      acc
    else
      entry :: acc)
    []
  |> List.rev

let dedup_representation_diagnostics diagnostics =
  diagnostics
  |> List.fold_left (fun kept diagnostic ->
    let duplicate =
      diagnostic.Diagnostics.constructor = "Backend/representation-certificate"
      && List.exists (fun previous ->
        previous.Diagnostics.constructor = diagnostic.constructor
        && previous.reason = diagnostic.reason) kept
    in
    if duplicate then kept else diagnostic :: kept)
    []
  |> List.rev

let analyze
    ~profile backend graph source_index statements constructors registry =
  let used, declared, defined = statement_inventory statements in
  let entries =
    (Builtin_registry.entries registry
     |> List.map (update_hint_activity used))
    @ generated_decd_entries
        backend source_index statements registry used defined
    @ relation_surface_entries graph source_index used declared defined
    |> dedup_entries
  in
  let errors = representation_errors backend constructors in
  let entries = List.map (apply_representation_errors errors) entries in
  let registry = Builtin_registry.with_entries registry entries in
  let diagnostics =
    entries |> List.map (diagnostic profile)
    |> dedup_representation_diagnostics
  in
  let global_error =
    match global_representation_errors backend constructors with
    | [] -> None
    | errors -> Some (String.concat "; " (List.map snd errors))
  in
  registry, global_error, diagnostics
