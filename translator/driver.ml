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
  let helper_statements = Helper.materialize (Context.helpers ctx) in
  let statements =
    Prelude.statements @ translated.statements @ helper_statements
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
    @ constructor_registry_diagnostics @ registry_diagnostics
    |> Diagnostics.dedup
  in
  { module_; diagnostics; source_index; maude_registry; builtin_registry }

let emit result =
  Emit.render_module result.module_

let emit_builtins ?output_load result =
  Builtin_registry.render_maude_interface ?output_load result.builtin_registry

let emit_builtin_report result =
  Builtin_registry.render_markdown result.builtin_registry

let has_fatal_diagnostics result =
  List.exists Diagnostics.is_fatal result.diagnostics
