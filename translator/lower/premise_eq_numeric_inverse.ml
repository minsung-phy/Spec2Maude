open Il.Ast
open Maude_ir
open Util.Source

open Premise_result

let unsupported = Premise_diagnostic.unsupported
let source_echo_exp = Premise_diagnostic.source_echo_exp
let vars_subset = Condition_closure.vars_subset
let with_conditions = Premise_state.with_conditions
let unbound_direct_var = Premise_state.unbound_direct_var
let typed_var_for_exp = Premise_state.typed_var_for_exp

let app name args =
  App (name, args)

let unsupported_exp ctx origin exp reason suggestion =
  unsupported
    ~ctx
    ~origin
    ~constructor:"Premise/IfPr/numeric-inverse-binding"
    ~source_echo:(source_echo_exp exp)
    ~reason
    ~suggestion
    ()

let target_numeric_var env ~bound_vars exp =
  match unbound_direct_var env ~bound_vars exp with
  | None -> None
  | Some id ->
    (match typed_var_for_exp id exp with
    | Some (_term, binding)
      when List.mem (sort_name binding.Expr_translate.sort) [ "Nat"; "Int" ] ->
      Some (id.it, binding)
    | Some _ | None -> None)

let multiplication_target ctx env ~bound_vars origin product_exp =
  let lower_factor exp =
    Expr_translate.lower_numeric_guard_value ctx env origin exp
  in
  let candidate target_exp factor_exp product =
    match target_numeric_var env ~bound_vars target_exp with
    | None -> None
    | Some (id, binding) ->
      let factor = lower_factor factor_exp in
      Some (id, binding, factor, product)
  in
  match product_exp.it with
  | BinE (`MulOp, _, left, right) ->
    (match candidate left right (fun target factor -> app "_*_" [ target; factor ]) with
    | Some _ as result -> result
    | None -> candidate right left (fun target factor -> app "_*_" [ factor; target ]))
  | _ -> None

let lower ctx env ~bound_vars origin exp product_exp known_exp =
  match multiplication_target ctx env ~bound_vars origin product_exp with
  | None -> None
  | Some (target_id, target_binding, factor_result, product_term) ->
    let known_result =
      Expr_translate.lower_numeric_guard_value ctx env origin known_exp
    in
    (match factor_result.term, known_result.term with
    | Some factor_term, Some known_term ->
      let prefix_conditions = factor_result.guards @ known_result.guards in
      (match
         Condition_closure.conditions_admissible_bound
           bound_vars
           prefix_conditions
       with
      | None ->
        Some
          { (empty_with_env ~bound_vars env) with
            diagnostics =
              factor_result.diagnostics @ known_result.diagnostics
              @ [ unsupported_exp
                    ctx
                    origin
                    exp
                    "numeric inverse binding arguments are not admissible from the lhs or earlier premise conditions"
                    "Bind the multiplication factor and known value before solving the numeric target variable"
                ]
          }
      | Some bound_after_prefix ->
        let needed =
          Condition_closure.term_vars factor_term
          @ Condition_closure.term_vars known_term
          |> List.sort_uniq String.compare
        in
        if not (vars_subset needed bound_after_prefix) then
          Some
            { (empty_with_env ~bound_vars env) with
              diagnostics =
                factor_result.diagnostics @ known_result.diagnostics
                @ [ unsupported_exp
                      ctx
                      origin
                      exp
                      "numeric inverse binding would use a factor or known value before it is bound"
                      "Keep this equality Unsupported until the source provides earlier binding conditions"
                  ]
            }
        else
          let quotient = app "_quo_" [ known_term; factor_term ] in
          let conditions =
            prefix_conditions
            @ [ BoolCond (app "_=/=_" [ factor_term; Const "0" ])
              ; MatchCond (target_binding.term, quotient)
              ; EqCond (product_term target_binding.term factor_term, known_term)
              ]
          in
          let env_after =
            Expr_translate.add_var env target_id target_binding
          in
          Some
            (with_conditions
               env_after
               bound_vars
               conditions
               (factor_result.diagnostics @ known_result.diagnostics)))
    | _ ->
      Some
        { (empty_with_env ~bound_vars env) with
          diagnostics =
            factor_result.diagnostics @ known_result.diagnostics
            @ [ unsupported_exp
                  ctx
                  origin
                  exp
                  "numeric inverse binding could not lower the multiplication factor or known side as a numeric guard term"
                  "Keep this equality Unsupported until both sides have numeric Maude carrier terms"
              ]
        })
