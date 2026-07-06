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

let fixed_pair_sources = function
  | { it =
        IterE
          ( { it = ListE [ left; right ]; _ }
          , (List, [ (left_id, left_source); (right_id, right_source) ]) )
    ; _
    }
    when left_id.it <> right_id.it
         && same_var left_id left
         && same_var right_id right ->
    Some [ (left_id, left_source); (right_id, right_source) ]
  | _ -> None

let has_fixed_pair_source args =
  args
  |> List.exists (fun arg ->
    match arg.it with
    | ExpA exp -> Option.is_some (fixed_pair_sources exp)
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
    { Expr_translate.term = None
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
  { type_result : Expr_translate.result option
  ; pair_sources : (id * exp) list option
  }

let collect_call_shape ctx env origin params args =
  let rec loop type_result pair_sources params args =
    match params, args with
    | [], [] -> Ok { type_result; pair_sources }
    | Analysis.Function_graph.Static_typ :: params, arg :: args ->
      let result = lower_type_arg ctx env origin arg in
      (match type_result, result.term with
      | None, Some _ -> loop (Some result) pair_sources params args
      | None, None -> Error result.diagnostics
      | Some _, _ ->
        Error
          [ unsupported
              ~ctx
              ~origin
              ~constructor:"Premise/IfPr/fixed-inverse-concat/static-arg"
              ~source_echo:(Il.Print.string_of_arg arg)
              ~reason:"fixed inverse concat supports exactly one TypP static witness"
              ~suggestion:"Keep this equality Unsupported until the helper contract records multiple static type witnesses"
              ()
          ])
    | Runtime_exp :: params, { it = ExpA exp; _ } :: args ->
      (match pair_sources, fixed_pair_sources exp with
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
      | None, Some sources ->
        loop type_result (Some sources) params args
      | _, None ->
        loop type_result pair_sources params args)
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
  loop None None params args

let sequence_binding ctx env ~bound_vars origin source_exp =
  match unbound_var_binding env ~bound_vars source_exp with
  | Some (id, binding)
    when sort_name binding.Expr_translate.sort = "SpectecTerminals"
         && Condition_closure.is_match_pattern binding.term ->
    Ok (id, binding)
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

let bind_pair_sources ctx env ~bound_vars origin = function
  | [ (_left_id, left_source); (_right_id, right_source) ] ->
    (match
       sequence_binding ctx env ~bound_vars origin left_source,
       sequence_binding ctx env ~bound_vars origin right_source
     with
    | Ok left, Ok right -> Ok (left, right)
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

let lower ctx env ~bound_vars origin exp call_exp known_exp =
  match call_exp.it with
  | CallE (id, args) ->
    let graph = Context.function_graph ctx in
    let target_id = call_target_id ctx id in
    (match
       Analysis.Function_graph.find_definition graph target_id.it,
       Analysis.Function_graph.definition_inverse graph target_id.it
     with
    | Some definition, Some _inverse_id
      when List.length definition.params = List.length args ->
      if not (has_fixed_pair_source args) then
        None
      else
      (match collect_call_shape ctx env origin definition.params args with
      | Error diagnostics ->
        Some { (empty_with_env ~bound_vars env) with diagnostics }
      | Ok { type_result = Some type_result; pair_sources = Some pair_sources } ->
        (match bind_pair_sources ctx env ~bound_vars origin pair_sources with
        | Error diagnostics ->
          Some { (empty_with_env ~bound_vars env) with diagnostics }
        | Ok ((left_id, left_binding), (right_id, right_binding)) ->
          let known_result = lower_with_source_carrier ctx env origin known_exp in
          (match type_result.term, known_result.term with
          | Some type_term, Some known_term ->
            let prefix_conditions =
              type_result.guards @ known_result.guards
            in
            let prefix_bound =
              conditions_bound_vars bound_vars prefix_conditions
            in
            if not (vars_subset (Condition_closure.term_vars known_term) prefix_bound) then
              Some
                { (empty_with_env ~bound_vars env) with
                  diagnostics =
                    type_result.diagnostics @ known_result.diagnostics
                    @ [ unsupported_exp
                          ctx
                          origin
                          exp
                          "fixed inverse concat input uses variables that are not bound before this premise"
                          "Bind the known sequence through earlier source premises before splitting it"
                      ]
                }
            else
              let helper_request =
                Helper.fixed_inverse_concat2_request
                  ~origin
                  ~source:(source_echo_exp exp)
                  ~reason:
                    "fixed inverse concat over a source pair chunk from an inverse-hinted forward function"
              in
              let helper_name =
                Helper.request (Context.helpers ctx) helper_request
              in
              let split_match =
                Helper.fixed_concat2_match_condition
                  helper_name
                  ~type_witness:type_term
                  ~known:known_term
                  ~left:left_binding.term
                  ~right:right_binding.term
              in
              let env_after =
                Expr_translate.add_var
                  (Expr_translate.add_var env left_id left_binding)
                  right_id
                  right_binding
              in
              let original_result =
                Expr_translate.lower_value ctx env_after origin call_exp
              in
              (match original_result.term with
              | Some original_term ->
                let conditions =
                  prefix_conditions @ [ split_match ] @ original_result.guards
                  @ [ EqCond (original_term, known_term) ]
                in
                Some
                  (with_conditions
                     env_after
                     bound_vars
                     conditions
                     (type_result.diagnostics @ known_result.diagnostics
                      @ original_result.diagnostics))
              | None ->
                Some
                  { (empty_with_env ~bound_vars env) with
                    diagnostics =
                      type_result.diagnostics @ known_result.diagnostics
                      @ original_result.diagnostics
                  })
          | _ ->
            Some
              { (empty_with_env ~bound_vars env) with
                diagnostics = type_result.diagnostics @ known_result.diagnostics
              }))
      | Ok { type_result = None; pair_sources = Some _ } ->
        Some
          { (empty_with_env ~bound_vars env) with
            diagnostics =
              [ unsupported_exp
                  ctx
                  origin
                  exp
                  "fixed inverse concat found a pair source chunk but no TypP witness"
                  "Keep this equality Unsupported until the source type witness is preserved"
              ]
          }
      | Ok _ -> None)
    | _ -> None)
  | _ -> None
