open Util.Source

type result =
  { module_ : Maude_ir.module_
  ; diagnostics : Diagnostics.t list
  ; source_index : Analysis.Source_index.t
  ; maude_registry : Maude_registry.t
  ; builtin_backend : Builtin_backend.t
  ; builtin_registry : Builtin_registry.t
  }

let retain_atomic_statements ~blocked_declarations statements =
  (Generated_reachability.retain ~blocked_declarations statements).statements

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

let category_slug_collision_diagnostics ctx source_index =
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
      | Some (existing_id, _) when existing_id = id.it ->
        None
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
    | Il.Ast.DecD _ | Il.Ast.RelD _ | Il.Ast.GramD _ | Il.Ast.RecD _ | Il.Ast.HintD _ ->
      None)

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

let definition_collision_diagnostic
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

let definition_name_collision_diagnostics ctx source_index =
  let seen = Hashtbl.create 127 in
  let check entry candidate signature identity =
    let key = candidate ^ "\000" ^ signature in
    match Hashtbl.find_opt seen key with
    | None ->
      Hashtbl.add seen key (identity, entry.Analysis.Source_index.origin);
      []
    | Some (existing_id, _) when existing_id = identity -> []
    | Some (existing_id, existing_origin) ->
      [ definition_collision_diagnostic
          ctx entry candidate signature existing_id existing_origin identity
      ]
  in
  Analysis.Source_index.entries source_index
  |> List.concat_map (fun (entry : Analysis.Source_index.entry) ->
    match entry.def.it with
    | Il.Ast.DecD (id, params, _, _) ->
      let signature = definition_domain_signature params in
      if List.exists (fun param -> match param.it with Il.Ast.DefP _ -> true | _ -> false) params
      then
        Analysis.Function_graph.specializations_for
          (Context.function_graph ctx) id.it
        |> List.concat_map (fun specialization ->
          let candidate = Context.specialized_definition_op ctx id specialization in
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

let visible_surface_collision_diagnostic
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

let visible_surface_collision_diagnostics ctx source_index =
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
      [ visible_surface_collision_diagnostic
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

let config_sort_collision_diagnostic
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

let config_sort_collision_diagnostics ctx source_index =
  let definitions = Hashtbl.create 31 in
  let relations = Hashtbl.create 31 in
  let check table entry constructor kind candidate identity =
    match Hashtbl.find_opt table candidate with
    | None ->
      Hashtbl.add table candidate (identity, entry.Analysis.Source_index.origin);
      []
    | Some (existing_id, _) when existing_id = identity -> []
    | Some (existing_id, existing_origin) ->
      [ config_sort_collision_diagnostic
          ctx entry constructor kind candidate existing_id existing_origin identity
      ]
  in
  let graph = Context.function_graph ctx in
  Analysis.Source_index.entries source_index
  |> List.concat_map (fun (entry : Analysis.Source_index.entry) ->
    match entry.def.it with
    | Il.Ast.DecD (id, params, _, _) ->
      if List.exists (fun param -> match param.it with Il.Ast.DefP _ -> true | _ -> false) params
      then
        Analysis.Function_graph.specializations_for graph id.it
        |> List.concat_map (fun specialization ->
          let identity = Analysis.Function_graph.identity_of_specialization specialization in
          if Analysis.Function_graph.identity_is_rewrite_backed graph identity then
            let targets =
              specialization.static_defs
              |> List.map (fun binding -> binding.Analysis.Function_graph.target_id)
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

let runtime_ingress_origin provenance constructor =
  Origin.synthetic
    ~path:
      [ "runtime-ingress-contract"
      ; provenance.Runtime_ingress_contract.definition_id
      ; Printf.sprintf "clause[%d]" provenance.clause_index
      ]
    ~ast_constructor:constructor
    provenance.origin

let runtime_ingress_enclosing provenance =
  [ "runtime-ingress-contract"
  ; "definition " ^ provenance.Runtime_ingress_contract.definition_id
  ; Printf.sprintf "clause %d" provenance.clause_index
  ; Printf.sprintf
      "source premises %d,%d"
      provenance.producer_premise_index provenance.consumer_premise_index
  ; "producer " ^ provenance.producer_relation_id
  ; "consumer " ^ provenance.consumer_relation_id
  ]

let translate
    ?(runtime_ingress_specs = [])
    script =
  let builtin_backend = Builtin_backend.load () in
  let source_index = Analysis.Source_index.of_script script in
  let builtin_registry =
    Builtin_registry.of_source_index ~backend:builtin_backend source_index
  in
  let runtime_ingress_contract, contract_errors =
    match Runtime_ingress_contract.resolve source_index runtime_ingress_specs with
    | Ok contract -> contract, []
    | Error errors -> Runtime_ingress_contract.empty, errors
  in
  let ctx =
    Context.create
      ~runtime_ingress_contract
      ~backend_name:(Builtin_backend.name builtin_backend)
      source_index builtin_registry
  in
  let contract_diagnostics =
    contract_errors
    |> List.map (fun error ->
      let provenance = Runtime_ingress_contract.error_provenance error in
      let previous =
        Runtime_ingress_contract.error_previous_provenance error
        |> Option.map Runtime_ingress_contract.provenance_source_echo
      in
      Diagnostics.make
        ~category:Diagnostics.Unsupported
        ~origin:
          (runtime_ingress_origin provenance "RuntimeIngressContract/resolve")
        ~constructor:"RuntimeIngressContract/resolve"
        ~enclosing:(runtime_ingress_enclosing provenance)
        ~profile:(Context.profile_name ctx)
        ~reason:
          ("contract attestation at " ^ provenance.origin ^ ": "
           ^ Runtime_ingress_contract.error_reason error
           ^ Option.fold ~none:""
               ~some:(fun source -> "; first attestation: " ^ source)
               previous)
        ~suggestion:
          "Correct the exact definition/relation identities and zero-based source indices in the supplied ingress contract"
        ~source_echo:
          (Runtime_ingress_contract.provenance_source_echo provenance)
        ())
  in
  let naming_diagnostics =
    category_slug_collision_diagnostics ctx source_index
    @ definition_name_collision_diagnostics ctx source_index
    @ visible_surface_collision_diagnostics ctx source_index
    @ config_sort_collision_diagnostics ctx source_index
  in
  let translated = Def_translate.translate_script ctx script in
  let unused_ingress_diagnostics =
    Context.unused_runtime_ingress_attestations ctx
    |> List.map (fun attestation ->
      let provenance =
        Runtime_ingress_contract.attestation_provenance attestation
      in
      Diagnostics.make
        ~category:Diagnostics.Unsupported
        ~origin:
          (runtime_ingress_origin
             provenance "RuntimeIngressContract/unused-attestation")
        ~constructor:"RuntimeIngressContract/unused-attestation"
        ~enclosing:(runtime_ingress_enclosing provenance)
        ~profile:(Context.profile_name ctx)
        ~reason:
          ("runtime ingress attestation from `"
           ^ Runtime_ingress_contract.attestation_origin attestation
           ^ "` did not certify and discharge its exact source slice")
        ~suggestion:
          "Remove the unused attestation or update its exact source digest and structural slice only after re-establishing the external validation theorem"
        ~source_echo:
          (Runtime_ingress_contract.provenance_source_echo provenance)
        ())
  in
  let ctx = Context.with_builtins ctx builtin_registry in
  let runtime_materialization = Runtime_materialize.run ctx in
  let helper_statements = Helper.materialize_static (Context.helpers ctx) in
  let helper_diagnostics =
    runtime_materialization.diagnostics
    @ Helper.unmaterialized_diagnostics
      ~profile:(Context.profile_name ctx)
      (Context.helpers ctx)
  in
  let reachability =
    Prelude.statements @ translated.statements @ helper_statements
    @ runtime_materialization.statements
    |> Generated_reachability.retain
         ~blocked_declarations:runtime_materialization.blocked_declarations
  in
  let statements =
    reachability.statements
    |> Maude_registry.dedup_var_declarations
  in
  let reachability_diagnostics =
    reachability.violations
    |> List.map (fun (violation : Generated_reachability.violation) ->
      Diagnostics.make
        ~category:Diagnostics.Unsupported
        ~origin:violation.origin
        ~constructor:violation.constructor
        ~enclosing:
          (Diagnostic_provenance.enclosing
             ~context:(Context.enclosing_path ctx) violation.origin)
        ~profile:(Context.profile_name ctx)
        ~reason:violation.reason
        ~suggestion:
          "Roll back the enclosing source definition and all transitive helper state before retaining the module"
        ())
  in
  let builtin_registry, builtin_representation_error, builtin_usage_diagnostics =
    Builtin_usage.analyze
      ~profile:(Context.profile_name ctx)
      builtin_backend
      (Context.function_graph ctx)
      source_index
      statements
      (Context.constructors ctx)
      builtin_registry
  in
  let builtin_representation_diagnostics =
    match builtin_representation_error with
    | None -> []
    | Some _ when Builtin_registry.entries builtin_registry = [] -> []
    | Some reason ->
      let origin =
        Builtin_backend.representation_requirements builtin_backend
        |> List.find_opt (fun representation ->
             Builtin_backend.representation_scope representation
             = Builtin_backend.Global)
        |> Option.map Builtin_backend.representation_category
        |> Option.to_list
        |> List.concat_map (Analysis.Source_index.find_by_id source_index)
        |> List.find_map (fun entry ->
          match entry.Analysis.Source_index.def.it with
          | Il.Ast.TypD _ -> Some entry.origin
          | _ -> None)
        |> Option.value
             ~default:
               (Origin.make
                  ~path:[ "builtin-backend" ]
                  ~ast_constructor:"BuiltinRepresentation"
                  Util.Source.no_region)
      in
      [ Diagnostics.make
          ~category:Diagnostics.Unsupported
          ~origin
          ~constructor:"BuiltinBackend/representation"
          ~enclosing:(Diagnostic_provenance.enclosing ~context:[] origin)
          ~profile:(Context.profile_name ctx)
          ~reason
          ~suggestion:
            "Emit the canonical constructor required by the global backend representation contract"
          ()
      ]
  in
  let module_ =
    { Maude_ir.name = "SPEC2MAUDE-GENERATED"
    ; kind = Maude_ir.System
    ; imports = Prelude.imports
    ; statements
    }
  in
  let ambient_patterns =
    Condition_closure.source_constructor_certificate ctx
  in
  let maude_registry, _ =
    Maude_registry.build ~ambient_patterns statements
  in
  let registry_violations =
    Maude_registry.validate_module ~ambient_patterns module_
  in
  let registry_diagnostics =
    Maude_registry.diagnostics
      ~profile:(Context.profile_name ctx)
      registry_violations
  in
  let constructor_registry_diagnostics =
    Constructor_registry.diagnostics
      ~profile:(Context.profile_name ctx)
      (Context.constructors ctx)
  in
  let function_graph_diagnostics =
    Analysis.Function_graph.diagnostics
      ~profile:(Context.profile_name ctx)
      (Context.function_graph ctx)
  in
  let diagnostics =
    contract_diagnostics @ unused_ingress_diagnostics
    @ naming_diagnostics @ function_graph_diagnostics
    @ builtin_representation_diagnostics @ translated.diagnostics
    @ helper_diagnostics @ builtin_usage_diagnostics
    @ reachability_diagnostics @ constructor_registry_diagnostics
    @ registry_diagnostics
    |> Diagnostics.dedup
  in
  { module_; diagnostics; source_index; maude_registry; builtin_backend
  ; builtin_registry
  }

let require_nonfatal operation (result : result) =
  if List.exists Diagnostics.is_fatal result.diagnostics then
    invalid_arg
      ("Driver." ^ operation
       ^ " refuses to render a module with fatal translation diagnostics")

let render_module ?marker result =
  String.concat "\n"
    (Option.to_list marker
     @ [ "--- Backend semantics: "
         ^ Builtin_backend.name result.builtin_backend ^ "."
       ; "--- Backend contract: "
         ^ Builtin_backend.description result.builtin_backend ^ "."
       ; Emit.render_module result.module_
       ])

let emit result =
  require_nonfatal "emit" result;
  render_module result

let emit_partial result =
  render_module
    ~marker:
      "--- PARTIAL/INCOMPLETE VERIFICATION OUTPUT: fatal diagnostics remain; this module is not a complete translation."
    result

let emit_builtins ?output_load result =
  require_nonfatal "emit_builtins" result;
  Builtin_backend.render ?output_load result.builtin_backend

let emit_partial_builtins ?output_load result =
  let marker =
    "--- PARTIAL/INCOMPLETE VERIFICATION BUILTINS: the loaded generated module has fatal translation diagnostics.\n"
  in
  marker ^ Builtin_backend.render ?output_load result.builtin_backend

let emit_builtin_report result =
  Builtin_report.render_markdown
    result.builtin_backend result.builtin_registry

let has_fatal_diagnostics (result : result) =
  List.exists Diagnostics.is_fatal result.diagnostics
