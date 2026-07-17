open Il.Ast
open Util.Source

type output =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

let empty = { statements = []; diagnostics = [] }

let append left right =
  { statements = left.statements @ right.statements
  ; diagnostics = left.diagnostics @ right.diagnostics
  }

let skipped ?suggestion ~ctx ~origin ~constructor ~reason () =
  Diagnostics.make
    ?suggestion
    ?source_echo:origin.Origin.source_echo
    ~category:Diagnostics.Skipped
    ~origin
    ~constructor
    ~enclosing:
      (Diagnostic_provenance.enclosing ~context:(Context.enclosing_path ctx) origin)
    ~profile:(Context.profile_name ctx)
    ~reason
    ()

let has_fatal diagnostics =
  List.exists Diagnostics.is_fatal diagnostics

let origin_for_def path ordinal def =
  let constructor = Analysis.constructor_of_def def in
  let id_suffix =
    match Analysis.id_of_def def with
    | None -> ""
    | Some id -> "-" ^ Naming.sanitize id
  in
  let segment = Printf.sprintf "%04d-%s%s" ordinal constructor id_suffix in
  Origin.make
    ~source_echo:(Analysis.source_echo_of_def def)
    ~path:(path @ [ segment ])
    ~ast_constructor:constructor def.Util.Source.at

let rec translate_def ctx path ordinal def =
  let origin = origin_for_def path ordinal def in
  match def.it with
  | TypD (id, params, insts) ->
    let ctx = Context.with_def ctx id.it in
    let stage = Context.begin_stage ctx in
    let translated =
      Type_translate.translate_typd
        (Context.staged stage) origin id params insts
    in
    if has_fatal translated.diagnostics then
      { statements = []; diagnostics = translated.diagnostics }
    else (
      Context.commit_stage stage;
      { statements = translated.statements; diagnostics = translated.diagnostics })
  | DecD (id, params, result_typ, clauses) ->
    let ctx = Context.with_def ctx id.it in
    let stage = Context.begin_stage ctx in
    let translated =
      Decd_translate.translate
        (Context.staged stage) origin id params result_typ clauses
    in
    if has_fatal translated.diagnostics then
      { statements = []; diagnostics = translated.diagnostics }
    else (
      Context.commit_stage stage;
      { statements = translated.statements; diagnostics = translated.diagnostics })
  | RelD (id, params, mixop, result_typ, rules) ->
    let ctx = Context.with_def ctx id.it in
    let stage = Context.begin_stage ctx in
    let translated =
      Reld_translate.translate
        (Context.staged stage) origin id params mixop result_typ rules
    in
    if has_fatal translated.diagnostics then
      { statements = []; diagnostics = translated.diagnostics }
    else (
      Context.commit_stage stage;
      { statements = translated.statements; diagnostics = translated.diagnostics })
  | GramD (id, _, _, _) ->
    let ctx = Context.with_def ctx id.it in
    let skip = Analysis.Profile_policy.gramd_skip in
    { empty with
      diagnostics =
        [ skipped
            ?suggestion:skip.suggestion
            ~ctx ~origin ~constructor:"GramD"
            ~reason:skip.reason
            ()
        ]
    }
  | HintD hintdef ->
    { empty with diagnostics = Hint_translate.translate ctx origin hintdef }
  | RecD defs ->
    List.mapi
      (fun index child ->
        translate_def
          ctx
          (origin.Origin.path @ [ Printf.sprintf "RecD[%d]" index ])
          (index + 1)
          child)
      defs
    |> List.fold_left append empty

let rec preload_typd_registry_def ctx path ordinal def =
  let origin = origin_for_def path ordinal def in
  match def.it with
  | TypD (id, params, insts) ->
    let ctx = Context.with_def ctx id.it in
    Type_translate.preload_typd_registry ctx origin id params insts
  | RecD defs ->
    defs
    |> List.iteri (fun index child ->
      preload_typd_registry_def
        ctx
        (origin.Origin.path @ [ Printf.sprintf "RecD[%d]" index ])
        (index + 1)
        child)
  | DecD _ | RelD _ | GramD _ | HintD _ -> ()

let preload_typd_registry ctx script =
  script
  |> List.iteri (fun index def ->
    preload_typd_registry_def
      ctx
      [ Printf.sprintf "script[%d]" index ]
      (index + 1)
      def)

let translate_script ctx script =
  preload_typd_registry ctx script;
  Constructor_registry.resolve_surfaces (Context.constructors ctx);
  List.mapi
    (fun index def ->
      translate_def ctx [ Printf.sprintf "script[%d]" index ] (index + 1) def)
    script
  |> List.fold_left append empty
