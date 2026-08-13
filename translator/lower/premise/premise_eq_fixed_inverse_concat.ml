open Il.Ast
open Maude_ir
open Util.Source

open Premise_result

let unsupported = Premise_diagnostic.unsupported
let source_echo_exp = Premise_diagnostic.source_echo_exp
let conditions_bound_vars = Condition_closure.conditions_bound_vars
let vars_subset = Condition_closure.vars_subset
let with_conditions = Premise_state.with_conditions
let unbound_var_binding = Premise_state.unbound_var_binding
let lower_with_source_carrier = Premise_shape.lower_with_source_carrier

let app name args =
  App (name, args)

let concat left right =
  app "_ _" [ left; right ]

let call_target_id ctx id =
  match Context.find_static_def ctx id.it with
  | Some target_id -> { id with it = target_id }
  | None -> id

let unsupported_exp ctx origin exp reason suggestion =
  unsupported
    ~ctx
    ~origin
    ~constructor:"Premise/IfPr/fixed-inverse-concat"
    ~source_echo:(source_echo_exp exp)
    ~reason
    ~suggestion
    ()

let same_var expected exp =
  match exp.it with
  | VarE actual -> actual.it = expected.it
  | _ -> false

type pair_shape =
  { pattern : exp
  ; body : exp
  ; sources : (id * exp) list
  }

let fixed_pair_shape = function
  | { it =
        IterE
          ( ({ it = ListE [ left; right ]; _ } as body)
          , (List, [ (left_id, left_source); (right_id, right_source) ]) )
    ; _
    } as pattern
    when left_id.it <> right_id.it
         && same_var left_id left
         && same_var right_id right ->
    Some
      { pattern
      ; body
      ; sources = [ left_id, left_source; right_id, right_source ]
      }
  | _ -> None

let has_unbound_pair_source names env ~bound_vars args =
  args
  |> List.exists (fun arg ->
    match arg.it with
    | ExpA exp ->
      (match fixed_pair_shape exp with
      | Some shape ->
        shape.sources
        |> List.exists (fun (_, source) ->
          Option.is_some
            (unbound_var_binding names env ~bound_vars source))
      | None -> false)
    | TypA _ | DefA _ | GramA _ -> false)

let lower_type_arg ctx env origin = function
  | { it = TypA typ; _ } ->
    Expr_translate.lower_type_witness
      ctx
      env
      origin
      ~constructor:"Premise/IfPr/fixed-inverse-concat/static-arg"
      typ
  | arg ->
    { Expr_result.term = None
    ; guards = []
    ; diagnostics =
        [ unsupported
            ~ctx
            ~origin
            ~constructor:"Premise/IfPr/fixed-inverse-concat/static-arg"
            ~source_echo:(Il.Print.string_of_arg arg)
            ~reason:"fixed inverse concat requires the forward TypP argument as a TypA witness"
            ~suggestion:"Keep this equality Unsupported until the static syntax argument is preserved"
            ()
        ]
    }

type call_shape =
  { known_terms : term list
  ; guards : eq_condition list
  ; diagnostics : Diagnostics.t list
  ; pair_shape : pair_shape option
  ; pair_param_index : int option
  }

let collect_call_shape ctx env origin params args =
  let rec loop index known_terms guards diagnostics pair_shape pair_param_index params args =
    match params, args with
    | [], [] ->
      Ok
        { known_terms = List.rev known_terms
        ; guards = List.rev guards
        ; diagnostics = List.rev diagnostics
        ; pair_shape
        ; pair_param_index
        }
    | Analysis.Function_graph.Static_typ :: params, arg :: args ->
      let result = lower_type_arg ctx env origin arg in
      (match result.term with
      | Some term ->
        loop (index + 1) (term :: known_terms)
          (List.rev_append result.guards guards)
          (List.rev_append result.diagnostics diagnostics)
          pair_shape pair_param_index params args
      | None -> Error result.diagnostics)
    | Runtime_exp :: params, { it = ExpA exp; _ } :: args ->
      (match pair_shape, fixed_pair_shape exp with
      | Some _, Some _ ->
        Error
          [ unsupported
              ~ctx
              ~origin
              ~constructor:"Premise/IfPr/fixed-inverse-concat/runtime-arg"
              ~reason:"fixed inverse concat found more than one runtime argument with a fixed pair source shape"
              ~suggestion:"Keep this equality Unsupported until the source identifies exactly one fixed pair split argument"
              ()
          ]
      | None, Some shape ->
        loop (index + 1) known_terms guards diagnostics
          (Some shape) (Some index) params args
      | _, None ->
        let result = lower_with_source_carrier ctx env origin exp in
        (match result.term with
        | Some term ->
          loop (index + 1) (term :: known_terms)
            (List.rev_append result.guards guards)
            (List.rev_append result.diagnostics diagnostics)
            pair_shape pair_param_index params args
        | None -> Error result.diagnostics))
    | (Static_def | Static_gram) :: _, arg :: _ ->
      Error
        [ unsupported
            ~ctx
            ~origin
            ~constructor:"Premise/IfPr/fixed-inverse-concat/static-arg"
            ~source_echo:(Il.Print.string_of_arg arg)
            ~reason:"fixed inverse concat currently supports only TypP static arguments"
            ~suggestion:"Keep this equality Unsupported until DefP/GramP static arguments are represented in the helper contract"
            ()
        ]
    | Runtime_exp :: _, ({ it = TypA _ | DefA _ | GramA _; _ } as arg) :: _ ->
      Error
        [ unsupported
            ~ctx
            ~origin
            ~constructor:"Premise/IfPr/fixed-inverse-concat/runtime-arg"
            ~source_echo:(Il.Print.string_of_arg arg)
            ~reason:"runtime concat argument position received a static argument"
            ~suggestion:"Preserve source parameter kinds before using fixed inverse concat"
            ()
        ]
    | [], _ :: _ | _ :: _, [] ->
      Error
        [ unsupported
            ~ctx
            ~origin
            ~constructor:"Premise/IfPr/fixed-inverse-concat/arity"
            ~reason:"source-declared inverse call arity changed during fixed concat lowering"
            ~suggestion:"Keep this equality Unsupported until the forward definition parameters and call arguments align"
            ()
        ]
  in
  loop 0 [] [] [] None None params args

let inverse_definition_implemented
    ctx
    (inverse : Analysis.Function_graph.definition) =
  inverse.clause_count > 0
  ||
  match Builtin_registry.find (Context.builtins ctx) inverse.id with
  | Some { status = Builtin_registry.Implemented; _ } -> true
  | Some { status = Obligation; _ } | None -> false

let inverse_result_is_chunks
    (inverse : Analysis.Function_graph.definition) =
  match Expr_translate.carrier_sort_of_typ inverse.result with
  | Some sort -> sort_name sort = "SpectecTerminals"
  | None -> false

let sequence_binding names ctx env ~bound_vars origin source_exp =
  match unbound_var_binding names env ~bound_vars source_exp with
  | Some (id, binding)
    when sort_name binding.Expr_env.sort = "SpectecTerminals"
         && Condition_closure.is_match_pattern
              ~constructor_op:
                (Condition_closure.source_constructor_certificate ctx)
              binding.term ->
    (match Premise_shape.zip_source_descriptor source_exp.note with
    | Some (item_shape, _element_typ) -> Ok (id, binding, item_shape)
    | None ->
      Error
        (unsupported_exp
           ctx
           origin
           source_exp
           "fixed inverse concat source has no supported repeated-element carrier"
           "Keep this IterE binding Unsupported until its source sequence shape is represented"))
  | Some (id, _binding) ->
    Error
      (unsupported_exp
         ctx
         origin
         source_exp
         ("fixed inverse concat source `" ^ id
          ^ "` is not an unbound sequence match pattern")
         "Bind fixed inverse concat outputs only to source sequence variables")
  | None ->
    Error
      (unsupported_exp
         ctx
         origin
         source_exp
         "fixed inverse concat source is already bound or has no sequence carrier"
         "Use ordinary equality if the source sequence is already available")

let bind_pair_sources names ctx env ~bound_vars origin = function
  | [ (left_generator, left_source); (right_generator, right_source) ] ->
    (match
       sequence_binding names ctx env ~bound_vars origin left_source,
       sequence_binding names ctx env ~bound_vars origin right_source
     with
    | Ok (left_id, left_binding, left_item_shape),
      Ok (right_id, right_binding, right_item_shape) ->
      Ok
        ( (left_generator, left_id, left_source, left_binding, left_item_shape)
        , (right_generator, right_id, right_source, right_binding, right_item_shape) )
    | Error diagnostic, Ok _ | Ok _, Error diagnostic -> Error [ diagnostic ]
    | Error left, Error right -> Error [ left; right ])
  | _ ->
    Error
      [ unsupported
          ~ctx
          ~origin
          ~constructor:"Premise/IfPr/fixed-inverse-concat"
          ~reason:"fixed inverse concat currently supports only a two-variable source chunk"
          ~suggestion:"Keep wider chunks Unsupported until the prelude contract returns that arity explicitly"
          ()
      ]

let lower names ctx env ~bound_vars origin exp call_exp known_exp =
  match call_exp.it with
  | CallE (id, args) ->
    let graph = Context.function_graph ctx in
    let target_id = call_target_id ctx id in
    if not (has_unbound_pair_source names env ~bound_vars args) then None else
    (match Analysis.Function_graph.find_definition graph target_id.it,
           Analysis.Function_graph.definition_inverse_status graph target_id.it with
    | Some definition, Invalid_inverse { reason; hint_origin }
      when List.length definition.params = List.length args ->
      Some
        { (empty_with_env ~bound_vars env) with
          diagnostics =
            [ unsupported_exp ctx origin exp
                (reason ^ "; inverse hint declared at " ^ Origin.summary hint_origin)
                "Correct the source inverse metadata or keep this pair reconstruction Unsupported"
            ]
        }
    | Some definition, Valid_inverse inverse
      when List.length definition.params = List.length args ->
      (match collect_call_shape ctx env origin definition.params args with
      | Error diagnostics ->
        Some { (empty_with_env ~bound_vars env) with diagnostics }
      | Ok { pair_shape = Some _; pair_param_index = Some pair_param_index; _ }
        when pair_param_index <> inverse.omitted_param_index ->
        Some
          { (empty_with_env ~bound_vars env) with
            diagnostics =
              [ unsupported_exp ctx origin exp
                  "fixed pair source is not the runtime parameter omitted by the validated inverse declaration"
                  "Keep this equality Unsupported unless the pair structure occupies the declared inverse output position"
              ]
          }
      | Ok ({ pair_shape = Some pair; _ } as shape) ->
        (match bind_pair_sources names ctx env ~bound_vars origin pair.sources with
        | Error diagnostics ->
          Some { (empty_with_env ~bound_vars env) with diagnostics }
        | Ok
            ( (left_generator, left_id, left_source, left_binding, left_item_shape)
            , (right_generator, right_id, right_source, right_binding, right_item_shape) ) ->
          (match Analysis.Function_graph.find_definition graph inverse.inverse_id with
          | None ->
            Some
              { (empty_with_env ~bound_vars env) with
                diagnostics =
                  shape.diagnostics
                  @ [ unsupported_exp ctx origin exp
                        ("source-declared inverse target `" ^ inverse.inverse_id
                         ^ "` has no DecD declaration")
                        "Declare the inverse function before using pair reconstruction"
                    ]
              }
          | Some inverse_definition
            when not (inverse_definition_implemented ctx inverse_definition) ->
            Some
              { (empty_with_env ~bound_vars env) with
                diagnostics =
                  shape.diagnostics
                  @ [ unsupported_exp ctx origin exp
                        ("source-declared inverse `" ^ inverse.inverse_id
                         ^ "` has no implemented source or builtin contract")
                        "Implement the declared inverse before using pair reconstruction"
                    ]
              }
          | Some inverse_definition when not (inverse_result_is_chunks inverse_definition) ->
            Some
              { (empty_with_env ~bound_vars env) with
                diagnostics =
                  shape.diagnostics
                  @ [ unsupported_exp ctx origin exp
                        "declared outer inverse does not return a sequence of reconstructed chunks"
                        "Keep this pair reconstruction Unsupported until the inverse result preserves chunk boundaries"
                    ]
              }
          | Some inverse_definition ->
            let known_result = lower_with_source_carrier ctx env origin known_exp in
            match known_result.term with
            | None ->
              Some
                { (empty_with_env ~bound_vars env) with
                  diagnostics = shape.diagnostics @ known_result.diagnostics
                }
            | Some known_term ->
              let inverse_terms = shape.known_terms @ [ known_term ] in
              let inverse_call =
                App
                  ( Context.definition_op ctx
                      { id with it = inverse.inverse_id }
                  , inverse_terms )
              in
              let prefix_conditions = shape.guards @ known_result.guards in
              let prefix_bound =
                conditions_bound_vars bound_vars prefix_conditions
              in
              if
                List.length inverse_definition.params
                <> List.length inverse_terms
              then
                Some
                  { (empty_with_env ~bound_vars env) with
                    diagnostics =
                      shape.diagnostics @ known_result.diagnostics
                      @ [ unsupported_exp ctx origin exp
                            "declared outer inverse arity does not match the pair reconstruction call"
                            "Keep this equality Unsupported until inverse metadata and call arguments agree"
                        ]
                  }
              else if
                not
                  (vars_subset
                     (Condition_closure.term_vars inverse_call)
                     prefix_bound)
              then
                Some
                  { (empty_with_env ~bound_vars env) with
                    diagnostics =
                      shape.diagnostics @ known_result.diagnostics
                      @ [ unsupported_exp
                            ctx
                            origin
                            exp
                            "declared outer inverse uses variables that are not bound before pair reconstruction"
                            "Bind every inverse input through earlier source premises"
                        ]
                  }
              else
                let chunks, names =
                  Local_name.fresh_qualified names Local_name.Chunk
                    (sort_ref (sort "SpectecTerminals"))
                in
                let left_head, names =
                  Local_name.fresh_qualified names Local_name.Head
                    (sort_ref (sort "SpectecTerminal"))
                in
                let right_head, names =
                  Local_name.fresh_qualified names Local_name.Head
                    (sort_ref (sort "SpectecTerminal"))
                in
                let subject_tail_var, names =
                  Local_name.fresh_qualified_name names Local_name.Tail
                    (sort_ref (sort "SpectecTerminals"))
                in
                let left_tail_var, names =
                  Local_name.fresh_qualified_name names Local_name.Tail
                    (sort_ref (sort "SpectecTerminals"))
                in
                let right_tail_var, _ =
                  Local_name.fresh_qualified_name names Local_name.Tail
                    (sort_ref (sort "SpectecTerminals"))
                in
                let sources : Premise_inverse_pattern.source list =
                  [ { generator_id = left_generator
                    ; source_exp = left_source
                    ; binding = left_binding
                    ; item_shape = left_item_shape
                    ; head_term = left_head
                    ; tail_var = left_tail_var
                    }
                  ; { generator_id = right_generator
                    ; source_exp = right_source
                    ; binding = right_binding
                    ; item_shape = right_item_shape
                    ; head_term = right_head
                    ; tail_var = right_tail_var
                    }
                  ]
                in
                let pattern_match =
                  Premise_inverse_pattern.match_condition
                    ctx
                    origin
                    ~pattern_exp:pair.pattern
                    ~body_exp:pair.body
                    ~iter:List
                    ~subject_item:(app "seq" [ concat left_head right_head ])
                    ~subject_tail_var
                    ~sources
                    ~captures:[]
                    ~body_conditions:[]
                    ~subject:chunks
                in
                Context.record_definition_call ctx inverse_call
                  (Analysis.Function_graph.plain_identity inverse.inverse_id);
                let env_after =
                  Expr_env.add
                    (Expr_env.add env left_id left_binding)
                    right_id
                    right_binding
                in
                let conditions =
                  prefix_conditions
                  @ [ MatchCond (chunks, inverse_call); pattern_match ]
                in
                Some
                  (with_conditions
                     ctx
                     env_after
                     bound_vars
                     conditions
                     (shape.diagnostics @ known_result.diagnostics))
          ))
      | Ok _ -> None)
    | Some _, No_inverse | Some _, Invalid_inverse _ | Some _, Valid_inverse _ | None, _ -> None)
  | _ -> None
