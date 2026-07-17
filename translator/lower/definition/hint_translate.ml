open Il.Ast
open Util.Source

let source_echo origin =
  origin.Origin.source_echo

let diagnostic ?suggestion ?source_echo ~category ~ctx ~origin ~constructor ~reason () =
  Diagnostics.make
    ?suggestion ?source_echo
    ~category
    ~origin
    ~constructor
    ~enclosing:
      (Diagnostic_provenance.enclosing ~context:(Context.enclosing_path ctx) origin)
    ~profile:(Context.profile_name ctx)
    ~reason
    ()

let unsupported ?suggestion ?source_echo:diagnostic_source_echo ~ctx ~origin ~constructor ~reason () =
  let source_echo =
    match diagnostic_source_echo with
    | Some source_echo -> Some source_echo
    | None -> source_echo origin
  in
  diagnostic
    ?suggestion
    ?source_echo
    ~category:Diagnostics.Unsupported
    ~ctx ~origin ~constructor ~reason ()

let skipped ?suggestion ?source_echo:diagnostic_source_echo ~ctx ~origin ~constructor ~reason () =
  let source_echo =
    match diagnostic_source_echo with
    | Some source_echo -> Some source_echo
    | None -> source_echo origin
  in
  diagnostic
    ?suggestion
    ?source_echo
    ~category:Diagnostics.Skipped
    ~ctx ~origin ~constructor ~reason ()

let hintdef_parts hintdef =
  match hintdef.it with
  | TypH (id, hints) -> "TypH", id, hints
  | RelH (id, hints) -> "RelH", id, hints
  | DecH (id, hints) -> "DecH", id, hints
  | GramH (id, hints) -> "GramH", id, hints
  | RuleH (rel_id, rule_id, hints) ->
    "RuleH", { rel_id with it = rel_id.it ^ "/" ^ rule_id.it }, hints

let translate ctx origin hintdef =
  let hintdef_constructor, target_id, hints = hintdef_parts hintdef in
  let ctx = Context.with_def ctx target_id.it in
  match hints with
  | [] ->
    [ skipped
        ~ctx ~origin ~constructor:hintdef_constructor
        ~reason:"empty HintD carries no runtime Maude statement but its origin is recorded"
        ()
    ]
  | _ ->
    hints
    |> List.map (fun hint ->
      let hint_name = hint.hintid.it in
      let constructor = hintdef_constructor ^ "/hint(" ^ hint_name ^ ")" in
      match Analysis.Hint_policy.classify hint with
      | Presentation ->
        skipped
          ~ctx ~origin ~constructor
          ~reason:"presentation hint has no runtime rewrite meaning after validated initial configuration construction"
          ~suggestion:"Keep the hint in diagnostics/metadata rather than emitting a Maude statement"
          ()
      | Semantic_obligation ->
        (match Builtin_registry.find (Context.builtins ctx) target_id.it with
        | Some { Builtin_registry.status = Implemented; _ } ->
          skipped
            ~ctx ~origin ~constructor
            ~reason:
              "builtin metadata is satisfied by the implemented builtin backend registry entry"
            ~suggestion:
              "Keep the source hint as consumed metadata and verify its generated adapter and smoke term"
            ()
        | Some { status = Obligation; _ } ->
          skipped
            ~ctx ~origin ~constructor
            ~reason:
              "builtin metadata is recorded for post-translation active-call analysis; the official builtin backend does not implement it"
            ~suggestion:
              "Use the backend report and active Obligation diagnostic to distinguish runtime demand from dormant metadata"
            ()
        | None ->
          unsupported
            ~ctx ~origin ~constructor
            ~reason:
              "hint(builtin) has no structurally indexed builtin registry entry"
            ~suggestion:
              "Index the DecD signature and builtin hint before classifying its backend status"
            ())
      | Translator_annotation ->
        (match hint_name with
        | "partial" when
            Analysis.Function_graph.definition_is_partial
              (Context.function_graph ctx) target_id.it ->
          skipped
            ~ctx ~origin ~constructor
            ~reason:
              "partial metadata is consumed by the DecD declaration, which uses Maude's partial arrow"
            ~suggestion:
              "Keep the hint in provenance; the generated operator kind carries its semantics"
            ()
        | "partial" ->
          unsupported
            ~ctx ~origin ~constructor
            ~reason:
              "partial metadata does not resolve to a structurally indexed DecD declaration"
            ~suggestion:
              "Attach hint(partial) to a declared DecD before lowering its operator"
            ()
        | "inverse" ->
          (match
             Analysis.Function_graph.definition_inverse_status
               (Context.function_graph ctx) target_id.it
           with
          | Valid_inverse inverse_id ->
            skipped
              ~ctx ~origin ~constructor
              ~reason:
                ("inverse metadata was structurally validated and consumed; target is `"
                 ^ inverse_id ^ "`")
              ~suggestion:
                "Use the validated inverse only at source-shaped inverse binding sites"
              ()
          | Invalid_inverse { reason; _ } ->
            skipped
              ~ctx ~origin ~constructor
              ~reason:("inverse metadata is unavailable: " ^ reason)
              ~suggestion:
                "Forward translation remains valid; an active inverse-binding demand will be Unsupported"
              ()
          | No_inverse ->
            skipped
              ~ctx ~origin ~constructor
              ~reason:
                "inverse metadata is unavailable because analysis recorded no inverse target"
              ~suggestion:
                "Forward translation remains valid; do not infer an inverse target from its name"
              ())
        | _ ->
          skipped
            ~ctx ~origin ~constructor
            ~reason:
              "translator annotation has been consumed by analysis and emits no runtime Maude statement"
            ~suggestion:
              "Keep the annotation in source/provenance metadata; do not turn it into a Maude equation"
            ())
      | Unknown ->
        unsupported
          ~ctx ~origin ~constructor
          ~reason:"hint classification is unknown, so the translator refuses to erase it silently"
          ~suggestion:"Classify the hint as presentation metadata, semantic obligation, or a documented unsupported case"
          ())
