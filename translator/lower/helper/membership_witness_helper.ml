open Maude_ir

type request =
  { source : string
  ; element_sort : sort
  ; head_var : string
  ; tail_var : string
  ; witness_var : string
  }

let key request =
  String.concat "\000"
    [ request.source
    ; sort_name request.element_sort
    ; request.head_var
    ; request.tail_var
    ; request.witness_var
    ]

let call name source =
  App (name, [ source ])

let result name witness =
  App (Naming.helper_companion ~role:"membership-result" name, [ witness ])

let variable_declarations statement variables =
  variables
  |> List.filter_map (fun (name, type_ref) ->
    if String.contains name ':' then None
    else Some (statement (var name type_ref)))

let materialize ~name origin request =
  let result_sort = sort ("MembershipWitness" ^ Naming.sort_token name ^ "Conf") in
  let result_op = Naming.helper_companion ~role:"membership-result" name in
  let head = Var request.head_var in
  let tail = Var request.tail_var in
  let witness = Var request.witness_var in
  let source = App ("_ _", [ head; tail ]) in
  let statement node =
    generated ~provenance:(Helper name) ~origin node
  in
  [ statement (sort_decl result_sort)
  ; statement (op name [ sort_ref (sort "SpectecTerminals") ] result_sort
                 ~attrs:[ Frozen [ 1 ] ])
  ; statement
      (op result_op [ sort_ref request.element_sort ] result_sort
         ~attrs:[ Ctor; Frozen [ 1 ] ])
  ]
  @ variable_declarations statement
      [ request.head_var, sort_ref request.element_sort
      ; request.tail_var, sort_ref (sort "SpectecTerminals")
      ; request.witness_var, sort_ref request.element_sort
      ]
  @ [ statement (rl (call name source) (result name head))
    ; statement
      (crl
         (call name source)
         (result name witness)
         [ RewriteCond (call name tail, result name witness) ])
  ]
