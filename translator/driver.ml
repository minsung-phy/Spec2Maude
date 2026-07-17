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
  let naming_diagnostics = Naming_collision.diagnostics ctx source_index in
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
