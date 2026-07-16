open Maude_ir

type request =
  { helper_name : string
  ; origin : Origin.t
  ; identity : Runtime_truth_worklist_indexed.identity
  ; mode : Runtime_truth_worklist_indexed.mode
  ; candidates : term
  ; captures : Runtime_truth_worklist_indexed.capture list
  ; support_head_var : string
  ; support_tail_var : string
  ; indexed_head_var : string
  ; indexed_tail_var : string
  ; domain_true : rule_condition list
  ; domain_false : rule_condition list list
  ; left_true : rule_condition
  ; right_true : rule_condition
  ; left_false : rule_condition
  ; right_false : rule_condition
  ; result_sort : sort
  ; proved : term
  ; refuted : term
  }

let generated request node =
  Maude_ir.generated ~provenance:(Helper request.helper_name)
    ~origin:request.origin node

let support_op request =
  "runtimeTruthSupport" ^ request.helper_name
  ^ Runtime_truth_worklist_indexed.identity_name request.identity

let support_surface request =
  let op_name = support_op request in
  let sequence = sort "SpectecTerminals" in
  let head = Var request.support_head_var in
  let tail = Var request.support_tail_var in
  let call term = App (op_name, [ term ]) in
  let cons = App ("_ _", [ head; tail ]) in
  [ generated request (op op_name [ sort_ref sequence ] sequence ~attrs:[ Frozen [ 1 ] ])
  ; generated request (eq (call (Const "eps")) (Const "eps"))
  ; generated request
      (ceq (call cons) (call tail)
         [ BoolCond (App ("contains", [ head; tail ])) ])
  ; generated request
      (ceq (call cons) (App ("_ _", [ head; call tail ]))
         [ EqCond (App ("contains", [ head; tail ]), Const "false") ])
  ]

let materialize request =
  let source_term = App (support_op request, [ request.candidates ]) in
  let indexed =
    Runtime_truth_worklist_indexed.materialize
      { helper_name = request.helper_name
      ; origin = request.origin
      ; identity = request.identity
      ; mode = request.mode
      ; source_term
      ; captures = request.captures
      ; head_var = request.indexed_head_var
      ; tail_var = request.indexed_tail_var
      ; body_true = request.domain_true @ [ request.left_true; request.right_true ]
      ; body_false =
          request.domain_false
          @ [ request.domain_true @ [ request.left_false ]
            ; request.domain_true @ [ request.left_true; request.right_false ]
            ]
      ; result_sort = request.result_sort
      ; proved = request.proved
      ; refuted = request.refuted
      }
  in
  { indexed with statements = support_surface request @ indexed.statements }
