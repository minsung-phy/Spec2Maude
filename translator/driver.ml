open Util.Source

type result =
  { module_ : Maude_ir.module_
  ; diagnostics : Diagnostics.t list
  ; source_index : Analysis.Source_index.t
  ; maude_registry : Maude_registry.t
  ; builtin_registry : Builtin_registry.t
  }

let dedup_var_declarations statements =
  let _seen, statements =
    statements
    |> List.fold_left
         (fun (seen, acc) statement ->
           match statement.Maude_ir.node with
           | VarDecl { name; type_ref } ->
             let key = name, type_ref in
             if List.exists (( = ) key) seen then
               seen, acc
             else
               key :: seen, statement :: acc
           | _ -> seen, statement :: acc)
         ([], [])
  in
  List.rev statements

type runtime_materialization =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

let runtime_search_item_id name = "search:" ^ name
let runtime_truth_search_item_id name = "truth:" ^ name
let runtime_truth_decision_item_id name = "truth-decision:" ^ name
let runtime_enabledness_item_id name = "enabledness:" ^ name

let pending_runtime_search_items ctx processed =
  Context.helpers ctx
  |> Helper.runtime_predicate_search_requests
  |> List.filter_map (fun (name, origin, request) ->
    let id = runtime_search_item_id name in
    if List.mem id processed then
      None
    else
      Some (id, { Runtime_search_materializer.name; origin; request }))

let pending_runtime_truth_search_items ctx processed =
  Context.helpers ctx
  |> Helper.runtime_predicate_truth_search_requests
  |> List.filter_map (fun (name, origin, request) ->
    let id = runtime_truth_search_item_id name in
    if List.mem id processed then
      None
    else
      Some (id, { Runtime_truth_search_materializer.name; origin; request }))

let pending_runtime_truth_decision_items ctx processed =
  Context.helpers ctx
  |> Helper.runtime_predicate_truth_decision_requests
  |> List.filter_map (fun (name, origin, request) ->
    let id = runtime_truth_decision_item_id name in
    if List.mem id processed then
      None
    else
      Some (id, { Runtime_truth_decision_materializer.name; origin; request }))

let pending_runtime_enabledness_items ctx processed =
  Context.helpers ctx
  |> Helper.runtime_enabledness_requests
  |> List.filter_map (fun (name, origin, request) ->
    let id = runtime_enabledness_item_id name in
    if List.mem id processed then
      None
    else
      Some (id, { Runtime_enabledness_materializer.name; origin; request }))

let materialize_runtime_helpers ctx =
  let rec loop fuel processed statements diagnostics =
    let search_items = pending_runtime_search_items ctx processed in
    let truth_items = pending_runtime_truth_search_items ctx processed in
    let truth_decision_items =
      pending_runtime_truth_decision_items ctx processed
    in
    let enabledness_items = pending_runtime_enabledness_items ctx processed in
    match search_items, truth_items, truth_decision_items, enabledness_items with
    | [], [], [], [] -> { statements; diagnostics }
    | _ when fuel = 0 -> { statements; diagnostics }
    | _ ->
      let processed =
        List.map fst search_items
        @ List.map fst truth_items
        @ List.map fst truth_decision_items
        @ List.map fst enabledness_items
        @ processed
      in
      let search_materialization =
        search_items
        |> List.map snd
        |> Runtime_search_materializer.materialize ctx
      in
      let truth_materialization =
        truth_items
        |> List.map snd
        |> Runtime_truth_search_materializer.materialize ctx
      in
      let truth_decision_materialization =
        truth_decision_items
        |> List.map snd
        |> Runtime_truth_decision_materializer.materialize ctx
      in
      let enabledness_materialization =
        enabledness_items
        |> List.map snd
        |> Runtime_enabledness_materializer.materialize ctx
      in
      loop
        (fuel - 1)
        processed
        (statements @ search_materialization.statements
         @ truth_materialization.statements
         @ truth_decision_materialization.statements
         @ enabledness_materialization.statements)
        (diagnostics @ search_materialization.diagnostics
         @ truth_materialization.diagnostics
         @ truth_decision_materialization.diagnostics
         @ enabledness_materialization.diagnostics)
  in
  loop 32 [] [] []

let category_slug_collision_diagnostics ctx source_index =
  let seen = Hashtbl.create 127 in
  Analysis.Source_index.entries source_index
  |> List.filter_map (fun (entry : Analysis.Source_index.entry) ->
    match entry.def.it with
    | Il.Ast.TypD (id, _, _) ->
      let slug = Naming.category_slug id in
      (match Hashtbl.find_opt seen slug with
      | None ->
        Hashtbl.add seen slug (id.it, entry.origin);
        None
      | Some (existing_id, _) when existing_id = id.it ->
        None
      | Some (existing_id, existing_origin) ->
        Some
          (Diagnostics.make
             ~category:Diagnostics.Unsupported
             ~origin:entry.origin
             ~constructor:"Naming/category-slug-collision"
             ~enclosing:(Context.enclosing_path ctx)
             ~profile:(Context.profile_name ctx)
             ~reason:
               (Printf.sprintf
                  "source category ids `%s` and `%s` both emit as `syn-%s`; silently merging them would break source-to-Maude isomorphism"
                  existing_id id.it slug)
             ~suggestion:
               (Printf.sprintf
                  "Make Naming.source_slug injective for these ids or add an origin-derived stable suffix; first origin was %s"
                  (Origin.summary existing_origin))
             ~source_echo:(Il.Print.string_of_def entry.def)
             ()))
    | Il.Ast.DecD _ | Il.Ast.RelD _ | Il.Ast.GramD _ | Il.Ast.RecD _ | Il.Ast.HintD _ ->
      None)

let translate ?(profile = Context.Runtime_after_external_validation) script =
  let source_index = Analysis.Source_index.of_script script in
  let builtin_registry = Builtin_registry.of_source_index source_index in
  let ctx = Context.create ~profile source_index in
  let naming_diagnostics =
    category_slug_collision_diagnostics ctx source_index
  in
  let translated = Def_translate.translate_script ctx script in
  let runtime_materialization = materialize_runtime_helpers ctx in
  let helper_statements = Helper.materialize (Context.helpers ctx) in
  let helper_diagnostics =
    runtime_materialization.diagnostics
    @ Helper.unmaterialized_diagnostics
      ~profile:(Context.profile_name ctx)
      (Context.helpers ctx)
  in
  let statements =
    Prelude.statements @ translated.statements @ helper_statements
    @ runtime_materialization.statements
    |> dedup_var_declarations
  in
  let module_ =
    { Maude_ir.name = "SPEC2MAUDE-GENERATED"
    ; kind = Maude_ir.System
    ; imports = Prelude.imports
    ; statements
    }
  in
  let maude_registry, _ = Maude_registry.build statements in
  let registry_violations =
    Maude_registry.validate_module module_
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
    naming_diagnostics @ function_graph_diagnostics @ translated.diagnostics
    @ helper_diagnostics @ constructor_registry_diagnostics @ registry_diagnostics
    |> Diagnostics.dedup
  in
  { module_; diagnostics; source_index; maude_registry; builtin_registry }

let emit result =
  Emit.render_module result.module_

let emit_builtins ?output_load result =
  Builtin_registry.render_maude_interface ?output_load result.builtin_registry

let emit_builtin_report result =
  Builtin_registry.render_markdown result.builtin_registry

let has_fatal_diagnostics (result : result) =
  List.exists Diagnostics.is_fatal result.diagnostics
