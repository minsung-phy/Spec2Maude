open Maude_ir
module Request = Helper_request
open Helper_emission

let materialize_optional_map_inverse entry (inverse : Request.optional_map_inverse) =
  let name = entry.Helper_registry.name in
  let origin = entry.request.Request.origin in
  let capture_sorts =
    inverse.captures |> List.map (fun capture -> sort_ref capture.Request.sort)
  in
  let formal_captures =
    inverse.captures |> List.map (fun capture -> Var capture.Request.formal_var)
  in
  let helper_on term =
    app name (term :: formal_captures)
  in
  let head = Var inverse.helper_head_var in
  let result_conditions =
    match
      Condition_schedule.schedule_eq_conditions
        (inverse.helper_head_var
         :: List.map (fun capture -> capture.Request.formal_var) inverse.captures)
        inverse.body_eq_conditions
    with
    | Some scheduled -> scheduled
    | None -> inverse.body_eq_conditions
  in
  let statement node = generated name origin node in
  [ statement
      (op name
         (sort_ref spectec_terminals :: capture_sorts)
         spectec_terminals)
  ]
  @ variable_declarations statement
      ((inverse.helper_head_var, sort_ref inverse.source_element_sort)
       :: (inverse.captures
           |> List.map (fun capture ->
             capture.Request.formal_var, sort_ref capture.Request.sort)))
  @ [ statement (eq (helper_on (Const "eps")) (Const "eps"))
    ; statement (ceq (helper_on inverse.lowered_body) head result_conditions)
    ]
