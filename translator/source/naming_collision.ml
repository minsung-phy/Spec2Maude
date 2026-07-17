open Util.Source

let category_param_signature params =
  params
  |> List.map (fun param ->
    match param.it with
    | Il.Ast.ExpP (_, typ) -> "exp:" ^ Il.Print.string_of_typ typ
    | Il.Ast.TypP _ -> "typ"
    | Il.Ast.DefP (_, params, typ) ->
      "def:" ^ Il.Print.string_of_params params ^ ":" ^ Il.Print.string_of_typ typ
    | Il.Ast.GramP (_, params, typ) ->
      "gram:" ^ Il.Print.string_of_params params ^ ":" ^ Il.Print.string_of_typ typ)
  |> String.concat ","

let category_slug_diagnostics ctx source_index =
  let seen = Hashtbl.create 127 in
  Analysis.Source_index.entries source_index
  |> List.filter_map (fun (entry : Analysis.Source_index.entry) ->
    match entry.def.it with
    | Il.Ast.TypD (id, params, _) ->
      let candidate = Naming.category_witness id in
      let signature = category_param_signature params in
      let key = candidate ^ "\000" ^ signature in
      (match Hashtbl.find_opt seen key with
      | None ->
        Hashtbl.add seen key (id.it, entry.origin);
        None
      | Some (existing_id, _) when existing_id = id.it -> None
      | Some (existing_id, existing_origin) ->
        Some
          (Diagnostics.make
             ~category:Diagnostics.Unsupported
             ~origin:entry.origin
             ~constructor:"Unsupported/NamingCollision/category"
             ~enclosing:
               (Diagnostic_provenance.enclosing
                  ~context:(Context.enclosing_path ctx) entry.origin)
             ~profile:(Context.profile_name ctx)
             ~reason:
               (Printf.sprintf
                  "distinct source category ids `%s` and `%s` both emit as `%s` with domain signature (%s)"
                  existing_id id.it candidate signature)
             ~suggestion:
               (Printf.sprintf
                  "Rename one source owner or make its Maude domain structurally distinct; visible hashes and source-location suffixes are forbidden (first origin: %s)"
                  (Origin.summary existing_origin))
             ~source_echo:(Il.Print.string_of_def entry.def)
             ()))
    | Il.Ast.DecD _ | Il.Ast.RelD _ | Il.Ast.GramD _ | Il.Ast.RecD _
    | Il.Ast.HintD _ -> None)

let definition_domain_signature params =
  params
  |> List.filter_map (fun param ->
    match param.it with
    | Il.Ast.ExpP (_, typ) ->
      Expr_translate.carrier_sort_of_typ typ
      |> Option.map Maude_ir.sort_name
    | Il.Ast.TypP _ -> Some "SpectecType"
    | Il.Ast.DefP _ | Il.Ast.GramP _ -> None)
  |> String.concat ","

let definition_diagnostic
    ctx (entry : Analysis.Source_index.entry)
    candidate signature existing_id existing_origin id =
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin:entry.Analysis.Source_index.origin
    ~constructor:"Unsupported/NamingCollision/definition"
    ~enclosing:
      (Diagnostic_provenance.enclosing
         ~context:(Context.enclosing_path ctx) entry.origin)
    ~profile:(Context.profile_name ctx)
    ~reason:
      (Printf.sprintf
         "distinct source definition identities `%s` and `%s` both emit as `%s` with domain signature (%s)"
         existing_id id candidate signature)
    ~suggestion:
      (Printf.sprintf
         "Rename one source owner or make its Maude domain structurally distinct; visible hashes and source-location suffixes are forbidden (first origin: %s)"
         (Origin.summary existing_origin))
    ~source_echo:(Il.Print.string_of_def entry.def)
    ()

let definition_name_diagnostics ctx source_index =
  let seen = Hashtbl.create 127 in
  let check entry candidate signature identity =
    let key = candidate ^ "\000" ^ signature in
    match Hashtbl.find_opt seen key with
    | None ->
      Hashtbl.add seen key (identity, entry.Analysis.Source_index.origin);
      []
    | Some (existing_id, _) when existing_id = identity -> []
    | Some (existing_id, existing_origin) ->
      [ definition_diagnostic
          ctx entry candidate signature existing_id existing_origin identity
      ]
  in
  Analysis.Source_index.entries source_index
  |> List.concat_map (fun (entry : Analysis.Source_index.entry) ->
    match entry.def.it with
    | Il.Ast.DecD (id, params, _, _) ->
      let signature = definition_domain_signature params in
      if
        List.exists
          (fun param -> match param.it with Il.Ast.DefP _ -> true | _ -> false)
          params
      then
        Analysis.Function_graph.specializations_for
          (Context.function_graph ctx) id.it
        |> List.concat_map (fun specialization ->
          let candidate =
            Context.specialized_definition_op ctx id specialization
          in
          let identity =
            id.it ^ "[" ^ String.concat "," specialization.key_components ^ "]"
          in
          check entry candidate signature identity)
      else
        check entry (Context.definition_op ctx id) signature id.it
    | Il.Ast.TypD _ | Il.Ast.RelD _ | Il.Ast.GramD _
    | Il.Ast.RecD _ | Il.Ast.HintD _ -> [])

let carrier_signature typ =
  match Expr_translate.carrier_sort_of_typ typ with
  | Some sort -> Maude_ir.sort_name sort
  | None -> "unsupported:" ^ Il.Print.string_of_typ typ

let relation_domain_signature params mixop result =
  let shape = Relation_shape.of_reld params mixop result in
  let components =
    match shape.Relation_shape.decision with
    | Static_validation _ | Runtime_predicate _ | Unknown _ -> shape.components
    | Deterministic_candidate deterministic -> deterministic.inputs
    | Execution execution -> execution.inputs
  in
  Relation_shape.component_typs components
  |> List.map carrier_signature
  |> String.concat ","

let record_domain_signature fields =
  fields
  |> List.map (fun (_, (typ, _, _), _) -> carrier_signature typ)
  |> String.concat ","

let visible_surface_diagnostic
    ctx (entry : Analysis.Source_index.entry)
    constructor kind candidate signature existing_id existing_origin id =
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin:entry.Analysis.Source_index.origin
    ~constructor
    ~enclosing:
      (Diagnostic_provenance.enclosing
         ~context:(Context.enclosing_path ctx) entry.origin)
    ~profile:(Context.profile_name ctx)
    ~reason:
      (Printf.sprintf
         "distinct raw %s owners `%s` and `%s` both emit as `%s` with domain signature (%s)"
         kind existing_id id candidate signature)
    ~suggestion:
      (Printf.sprintf
         "Rename one source owner or make its Maude domain structurally distinct; visible hashes and source-location suffixes are forbidden (first origin: %s)"
         (Origin.summary existing_origin))
    ~source_echo:(Il.Print.string_of_def entry.def)
    ()

let visible_surface_diagnostics ctx source_index =
  let relations = Hashtbl.create 127 in
  let records = Hashtbl.create 127 in
  let check table entry constructor kind candidate signature id =
    let key = candidate ^ "\000" ^ signature in
    match Hashtbl.find_opt table key with
    | None ->
      Hashtbl.add table key (id, entry.Analysis.Source_index.origin);
      []
    | Some (existing_id, _) when existing_id = id -> []
    | Some (existing_id, existing_origin) ->
      [ visible_surface_diagnostic
          ctx entry constructor kind candidate signature
          existing_id existing_origin id
      ]
  in
  Analysis.Source_index.entries source_index
  |> List.concat_map (fun (entry : Analysis.Source_index.entry) ->
    match entry.def.it with
    | Il.Ast.RelD (id, params, mixop, result, _) ->
      check relations entry
        "Unsupported/NamingCollision/relation"
        "relation" (Naming.relation_op id)
        (relation_domain_signature params mixop result) id.it
    | Il.Ast.TypD (id, _, instances) ->
      instances
      |> List.concat_map (fun instance ->
        match instance.it with
        | Il.Ast.InstD (_, _, { it = StructT fields; _ }) ->
          check records entry
            "Unsupported/NamingCollision/record-constructor"
            "record constructor" (Naming.record_constructor id)
            (record_domain_signature fields) id.it
        | Il.Ast.InstD (_, _, { it = AliasT _ | VariantT _; _ }) -> [])
    | Il.Ast.DecD _ | Il.Ast.GramD _ | Il.Ast.RecD _ | Il.Ast.HintD _ -> [])

let config_sort_diagnostic
    ctx (entry : Analysis.Source_index.entry)
    constructor kind candidate existing_id existing_origin id =
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin:entry.Analysis.Source_index.origin
    ~constructor
    ~enclosing:
      (Diagnostic_provenance.enclosing
         ~context:(Context.enclosing_path ctx) entry.origin)
    ~profile:(Context.profile_name ctx)
    ~reason:
      (Printf.sprintf
         "distinct raw %s owners `%s` and `%s` both require generated configuration sort `%s`"
         kind existing_id id candidate)
    ~suggestion:
      (Printf.sprintf
         "Rename one source owner; generated sort names remain readable and may not use hashes or source locations (first origin: %s)"
         (Origin.summary existing_origin))
    ~source_echo:(Il.Print.string_of_def entry.def)
    ()

let config_sort_diagnostics ctx source_index =
  let definitions = Hashtbl.create 31 in
  let relations = Hashtbl.create 31 in
  let check table entry constructor kind candidate identity =
    match Hashtbl.find_opt table candidate with
    | None ->
      Hashtbl.add table candidate (identity, entry.Analysis.Source_index.origin);
      []
    | Some (existing_id, _) when existing_id = identity -> []
    | Some (existing_id, existing_origin) ->
      [ config_sort_diagnostic
          ctx entry constructor kind candidate existing_id existing_origin identity
      ]
  in
  let graph = Context.function_graph ctx in
  Analysis.Source_index.entries source_index
  |> List.concat_map (fun (entry : Analysis.Source_index.entry) ->
    match entry.def.it with
    | Il.Ast.DecD (id, params, _, _) ->
      if
        List.exists
          (fun param -> match param.it with Il.Ast.DefP _ -> true | _ -> false)
          params
      then
        Analysis.Function_graph.specializations_for graph id.it
        |> List.concat_map (fun specialization ->
          let identity =
            Analysis.Function_graph.identity_of_specialization specialization
          in
          if Analysis.Function_graph.identity_is_rewrite_backed graph identity then
            let targets =
              specialization.static_defs
              |> List.map (fun binding ->
                binding.Analysis.Function_graph.target_id)
            in
            check definitions entry
              "Unsupported/NamingCollision/definition-config-sort"
              "definition" (Naming.definition_config_sort id targets)
              (id.it ^ "[" ^ String.concat "," specialization.key_components ^ "]")
          else [])
      else if Analysis.Function_graph.definition_is_rewrite_backed graph id.it then
        check definitions entry
          "Unsupported/NamingCollision/definition-config-sort"
          "definition" (Naming.definition_config_sort id []) id.it
      else []
    | Il.Ast.RelD (id, params, mixop, result, _) ->
      let shape = Relation_shape.of_reld params mixop result in
      (match shape.Relation_shape.decision with
      | Execution _ ->
        check relations entry
          "Unsupported/NamingCollision/relation-config-sort"
          "relation" (Naming.relation_config_sort id) id.it
      | Static_validation _ | Runtime_predicate _
      | Deterministic_candidate _ | Unknown _ -> [])
    | Il.Ast.TypD _ | Il.Ast.GramD _ | Il.Ast.RecD _ | Il.Ast.HintD _ -> [])

let diagnostics ctx source_index =
  category_slug_diagnostics ctx source_index
  @ definition_name_diagnostics ctx source_index
  @ visible_surface_diagnostics ctx source_index
  @ config_sort_diagnostics ctx source_index
