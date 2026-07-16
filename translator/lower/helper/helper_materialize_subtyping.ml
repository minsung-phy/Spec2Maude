open Maude_ir
open Helper_emission

let constructor op args =
  match args with
  | [] -> Const op
  | _ -> App (op, args)

let case_variables names case =
  Subtype_injection.payload_sorts case
  |> List.fold_left
       (fun (variables, names) sort ->
         let variable, names =
           Local_name.fresh_qualified_name
             names Local_name.Component (sort_ref sort)
         in
         (variable, sort) :: variables, names)
       ([], names)
  |> fun (variables, names) -> List.rev variables, names

let materialize entry injection =
  let name = entry.Helper_registry.name in
  let origin = entry.request.origin in
  let project = Subtype_injection.projection_name ~forward:name in
  let project_seq = Subtype_injection.sequence_projection_name ~forward:name in
  let statement node = generated name origin node in
  let cases = Subtype_injection.cases injection in
  let cases, names =
    cases
    |> List.fold_left
         (fun (cases, names) case ->
           let variables, names = case_variables names case in
           (case, variables) :: cases, names)
         ([], Local_name.empty)
    |> fun (cases, names) -> List.rev cases, names
  in
  let tail_var, _ =
    Local_name.fresh_qualified_name
      names Local_name.Tail (sort_ref spectec_terminals)
  in
  let equations =
    cases
    |> List.map (fun (case, variables) ->
      let args =
        variables
        |> List.map (fun (variable, _sort) -> Var variable)
      in
      let source = constructor (Subtype_injection.source_op case) args in
      let target = constructor (Subtype_injection.target_op case) args in
      let tail = Var tail_var in
      (* [Subtype_plan] proves a one-to-one constructor map.  These equations
         therefore define a partial retraction: project(forward(x)) = x.  The
         sequence operator is its pointwise lift and stays undefined as soon as
         one target element lies outside the source image. *)
      [ statement (eq (App (name, [ source ])) target)
      ; statement (eq (App (project, [ target ])) source)
      ; statement (eq (App (project_seq, [ target ])) source)
      ; statement
          (ceq
             (App (project_seq, [ concat target tail ]))
             (concat source (App (project_seq, [ tail ])))
             [ not_eps tail_var ])
      ])
    |> List.concat
  in
  [ statement
      (op name [ sort_ref spectec_terminal ] spectec_terminal)
  ; statement
      (op ~kind:Partial project [ sort_ref spectec_terminal ] spectec_terminal)
  ; statement
      (op ~kind:Partial project_seq [ sort_ref spectec_terminals ] spectec_terminals)
  ]
  @ [ statement (eq (App (project_seq, [ Const "eps" ])) (Const "eps")) ]
  @ equations
