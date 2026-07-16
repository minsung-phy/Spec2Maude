open Maude_ir

type capture =
  { call_term : term
  ; formal_var : string
  ; sort : sort
  }

type request =
  { helper_name : string
  ; origin : Origin.t
  ; index : int
  ; source_term : term
  ; captures : capture list
  ; index_var : string
  ; head_var : string
  ; tail_var : string
  ; successor_term : term
  ; successor_guards : eq_condition list
  }

type result =
  { term : term
  ; statements : generated list
  }

let op_name request =
  "runtimeTruthIndexedConstructors" ^ request.helper_name
  ^ "x" ^ string_of_int request.index

let generated request node =
  Maude_ir.generated ~provenance:(Helper request.helper_name)
    ~origin:request.origin node

let materialize request =
  let name = op_name request in
  let terminals = sort "SpectecTerminals" in
  let nat = sort "Nat" in
  let head = Var request.head_var and tail = Var request.tail_var in
  let index = Var request.index_var in
  let formals = List.map (fun capture -> Var capture.formal_var) request.captures in
  let call source index = App (name, source :: index :: formals) in
  let nonempty = App ("_ _", [ head; tail ]) in
  let recursive =
    App ("_ _", [ request.successor_term; call tail (App ("s_", [ index ])) ])
  in
  let args =
    sort_ref terminals :: sort_ref nat
    :: List.map (fun capture -> sort_ref capture.sort) request.captures
  in
  { term =
      App
        ( name
        , request.source_term :: Const "0"
          :: List.map (fun capture -> capture.call_term) request.captures )
  ; statements =
      [ generated request (op name args terminals)
      ]
      @ [ generated request (ceq (call (Const "eps") index) (Const "eps") [])
        ; generated request
            (ceq (call head index) request.successor_term request.successor_guards)
        ; generated request
            (ceq (call nonempty index) recursive
               (BoolCond (App ("_=/=_", [ tail; Const "eps" ]))
                :: request.successor_guards))
        ]
  }
