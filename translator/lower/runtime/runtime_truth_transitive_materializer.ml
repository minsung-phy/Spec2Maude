open Maude_ir

type worklist =
  { helper_name : string
  ; identity : Runtime_truth_worklist_indexed.identity
  ; captures : Runtime_truth_worklist_indexed.capture list
  ; indexed_head_var : string
  ; indexed_tail_var : string
  ; current_var : string
  ; queue_var : string
  ; seen_var : string
  ; successors_var : string
  }

type scope =
  { formals : term list
  ; witness : term
  ; current : term
  }

type request =
  { worklist : worklist
  ; origin : Origin.t
  ; mode : Runtime_truth_worklist_indexed.mode
  ; candidates : term list
  ; certified_successors : term list
  ; start : term
  ; target : term
  ; domain_true : rule_condition list
  ; domain_false : rule_condition list list
  ; direct_true : rule_condition
  ; direct_false : rule_condition
  ; result_sort : sort
  ; proved : term
  ; refuted : term
  }

let scope_formals scope = scope.formals
let scope_witness scope = scope.witness
let scope_current scope = scope.current

let request ~worklist ~origin ~mode ~candidates ~certified_successors
    ~start ~target ~domain_true ~domain_false ~direct_true ~direct_false
    ~result_sort ~proved ~refuted =
  { worklist; origin; mode; candidates; certified_successors; start; target
  ; domain_true; domain_false; direct_true; direct_false; result_sort
  ; proved; refuted }

type surface_var =
  | Source
  | Count
  | Head
  | Value
  | Tail

let surface_var role sort =
  let name =
    match role with
    | Source -> "RTSOURCE"
    | Count -> "RTCOUNT"
    | Head -> "RTHEAD"
    | Value -> "RTVALUE"
    | Tail -> "RTTAIL"
  in
  Var (name ^ ":" ^ sort_name sort)

let closure_list_sort ~helper_name identity =
  let identity = Runtime_truth_worklist_indexed.identity_name identity in
  sort (Naming.runtime_truth_list_sort ~helper_name ~identity)

let create ~helper_name ~identity ~env ~terms ~sorts ~history =
  let names =
    Runtime_truth_worklist_core.reserve_names env [] (terms @ [ history ])
  in
  let captures, names =
    List.map2 (fun term sort -> term, sort) terms sorts
    @ [ history, Runtime_truth_worklist_core.terminals ]
    |> List.fold_left
         (fun (captures, names) (call_term, sort) ->
           let formal_var, names =
             Local_name.fresh_qualified_name
               names Local_name.Capture (sort_ref sort)
           in
           ( { Runtime_truth_worklist_indexed.call_term; formal_var; sort }
             :: captures
           , names ))
         ([], names)
    |> fun (captures, names) -> List.rev captures, names
  in
  let fresh role sort names =
    Local_name.fresh_qualified_name names role (sort_ref sort)
  in
  let indexed_head_var, names =
    fresh Local_name.Head Runtime_truth_worklist_core.terminal names
  in
  let list = closure_list_sort ~helper_name identity in
  let indexed_tail_var, names = fresh Local_name.Tail list names in
  let current_var, names =
    fresh Local_name.Component Runtime_truth_worklist_core.terminal names
  in
  let queue_var, names = fresh Local_name.Tail list names in
  let seen_var, names = fresh Local_name.History list names in
  let successors_var, _ = fresh Local_name.Stream list names in
  let worklist =
    { helper_name; identity; captures; indexed_head_var; indexed_tail_var
    ; current_var; queue_var; seen_var; successors_var }
  in
  ( worklist
  , { formals =
        List.map
          (fun capture ->
            Var capture.Runtime_truth_worklist_indexed.formal_var)
          captures
    ; witness = Var indexed_head_var
    ; current = Var current_var
    } )

let generated request node =
  Maude_ir.generated ~provenance:(Helper request.worklist.helper_name)
    ~origin:request.origin node

let closure_op request role =
  let identity =
    Runtime_truth_worklist_indexed.identity_name request.worklist.identity
  in
  Naming.runtime_truth_companion
    ~helper_name:request.worklist.helper_name ~identity ~role

let list_op request role = closure_op request ("List" ^ role)

let list_surface request =
  let list =
    closure_list_sort ~helper_name:request.worklist.helper_name
      request.worklist.identity
  in
  let sequence = sort "SpectecTerminals" in
  let terminal = sort "SpectecTerminal" in
  let nat = sort "Nat" in
  let nil = Const (list_op request "Nil") in
  let cons head tail = App (list_op request "Cons", [ head; tail ]) in
  let prepend source tail = App (list_op request "Prepend", [ source; tail ]) in
  let seq head tail = App ("_ _", [ head; tail ]) in
  let repeat count value = App ("repeatSeq", [ count; value ]) in
  let member value values = App (list_op request "Member", [ value; values ]) in
  let source = surface_var Source sequence in
  let count = surface_var Count nat in
  let head = surface_var Head terminal in
  let value = surface_var Value terminal in
  let tail = surface_var Tail list in
  [ generated request (sort_decl list)
  ; generated request (op (list_op request "Nil") [] list ~attrs:[ Ctor ])
  ; generated request
      (op (list_op request "Cons") [ sort_ref terminal; sort_ref list ] list
         ~attrs:[ Ctor ])
  ; generated request
      (op (list_op request "Prepend") [ sort_ref sequence; sort_ref list ] list)
  ; generated request
      (op (list_op request "Member") [ sort_ref terminal; sort_ref list ]
         (sort "Bool"))
  ; generated request (eq (prepend (Const "eps") tail) tail)
  ; generated request
      (eq
         (prepend (repeat (App ("s_", [ count ])) head) tail)
         (cons head (prepend (repeat count head) tail)))
  ; generated request
      (ceq
         (prepend (seq (repeat (App ("s_", [ count ])) head) source) tail)
         (cons head
            (prepend (seq (repeat count head) source) tail))
         [ BoolCond (App ("_=/=_", [ source; Const "eps" ])) ])
  ; generated request
      (eq
         (prepend (seq head source) tail)
         (cons head (prepend source tail)))
  ; generated request (eq (member value nil) (Const "false"))
  ; generated request
      (eq
         (member value (cons head tail))
         (App ("_or_", [ App ("_==_", [ value; head ]); member value tail ])))
  ]

let stable_sequence calls =
  let calls =
    calls
    |> List.fold_left
         (fun unique call ->
           if List.exists (( = ) call) unique then unique else call :: unique)
         []
    |> List.rev
  in
  match calls with
  | [] -> Const "eps"
  | call :: calls ->
    List.fold_left (fun left right -> App ("_ _", [ left; right ])) call calls

let materialize_prove request =
  let worklist = request.worklist in
  let list = closure_list_sort ~helper_name:worklist.helper_name worklist.identity in
  let choice = sort (sort_name list ^ "Choice") in
  let captures =
    List.map
      (fun capture -> Var capture.Runtime_truth_worklist_indexed.formal_var)
      worklist.captures
  in
  let actual_captures =
    List.map
      (fun capture -> capture.Runtime_truth_worklist_indexed.call_term)
      worklist.captures
  in
  let capture_sorts =
    List.map
      (fun capture -> capture.Runtime_truth_worklist_indexed.sort)
      worklist.captures
  in
  let current = Var worklist.current_var in
  let candidate = Var worklist.indexed_head_var in
  let candidates = Var worklist.indexed_tail_var in
  let seen = Var worklist.seen_var in
  let nil = Const (list_op request "Nil") in
  let cons head tail = App (list_op request "Cons", [ head; tail ]) in
  let member value values = App (list_op request "Member", [ value; values ]) in
  let prepend source = App (list_op request "Prepend", [ source; nil ]) in
  let candidates_value = prepend (stable_sequence request.candidates) in
  let successors_value = prepend (stable_sequence request.certified_successors) in
  let choose = closure_op request "Choose" in
  let reach = closure_op request "ProveReach" in
  let choose_call values = App (choose, [ values ]) in
  let reach_call current seen captures =
    App (reach, current :: seen :: captures)
  in
  let args =
    List.map sort_ref (sort "SpectecTerminal" :: list :: capture_sorts)
  in
  let frozen count =
    if count = 0 then []
    else [ Frozen (List.init count (fun index -> index + 1)) ]
  in
  let unseen = EqCondition (EqCond (member candidate seen, Const "false")) in
  let choose_candidate = RewriteCond (choose_call candidates_value, candidate) in
  let certified =
    EqCondition (EqCond (member candidate successors_value, Const "true"))
  in
  let uncertified =
    EqCondition (EqCond (member candidate successors_value, Const "false"))
  in
  let same_target = EqCondition (EqCond (candidate, request.target)) in
  let other_target =
    EqCondition
      (BoolCond (App ("_=/=_", [ candidate; request.target ])))
  in
  let actual_call =
    reach_call request.start (cons request.start nil) actual_captures
  in
  let recurse =
    RewriteCond
      ( reach_call candidate (cons candidate seen) captures
      , request.proved )
  in
  let prove_rule role conditions =
    generated request
      (crl ~label:(String.lowercase_ascii (reach ^ role))
         (reach_call current seen captures) request.proved
         conditions)
  in
  let statements =
    list_surface request
    @ [ generated request (sort_decl choice)
      ; generated request (subsort (sort "SpectecTerminal") choice)
      ; generated request
          (op choose [ sort_ref list ] choice ~attrs:[ Frozen [ 1 ] ])
      ; generated request
          (rl ~label:(String.lowercase_ascii (choose ^ "-head"))
             (choose_call (cons candidate candidates)) candidate)
      ; generated request
          (rl ~label:(String.lowercase_ascii (choose ^ "-tail"))
             (choose_call (cons candidate candidates))
             (choose_call candidates))
      ; generated request
          (op reach args request.result_sort
             ~attrs:(frozen (List.length args)))
      ; prove_rule "-source-hit"
          ([ choose_candidate; same_target ]
           @ request.domain_true @ [ certified ])
      ; prove_rule "-direct-hit"
          ([ choose_candidate; same_target ]
           @ request.domain_true @ [ uncertified; request.direct_true ])
      ; prove_rule "-source-next"
          ([ choose_candidate; other_target; unseen ]
           @ request.domain_true @ [ certified; recurse ])
      ; prove_rule "-direct-next"
          ([ choose_candidate; other_target; unseen ]
           @ request.domain_true
           @ [ uncertified; request.direct_true; recurse ])
      ]
  in
  { Runtime_truth_worklist_indexed.statements
  ; true_condition = RewriteCond (actual_call, request.proved)
  ; false_condition = None
  }

let closure_surface request list reach expand =
  let terminal = sort "SpectecTerminal" in
  let capture_sorts =
    List.map (fun capture -> capture.Runtime_truth_worklist_indexed.sort)
      request.worklist.captures
  in
  let frozen count =
    if count = 0 then []
    else [ Frozen (List.init count (fun index -> index + 1)) ]
  in
  [ generated request
      (op reach
         (List.map sort_ref (list :: list :: capture_sorts))
         request.result_sort
         ~attrs:(frozen (2 + List.length capture_sorts)))
  ; generated request
      (op expand
         (List.map sort_ref
            (terminal :: list :: list :: list :: list
             :: capture_sorts))
         request.result_sort
         ~attrs:(frozen (5 + List.length capture_sorts)))
  ]

let materialize_decide request =
  let worklist = request.worklist in
  let list = closure_list_sort ~helper_name:worklist.helper_name worklist.identity in
  let captures =
    List.map
      (fun capture -> Var capture.Runtime_truth_worklist_indexed.formal_var)
      worklist.captures
  in
  let current = Var worklist.current_var in
  let candidate = Var worklist.indexed_head_var in
  let candidates = Var worklist.indexed_tail_var in
  let queue = Var worklist.queue_var in
  let seen = Var worklist.seen_var in
  let successors = Var worklist.successors_var in
  let nil = Const (list_op request "Nil") in
  let cons head tail = App (list_op request "Cons", [ head; tail ]) in
  let member value values = App (list_op request "Member", [ value; values ]) in
  let frontier = cons request.start nil in
  let prepend source = App (list_op request "Prepend", [ source; nil ]) in
  let candidates_value = prepend (stable_sequence request.candidates) in
  let successors_value = prepend (stable_sequence request.certified_successors) in
  let actual_captures =
    List.map
      (fun capture -> capture.Runtime_truth_worklist_indexed.call_term)
      worklist.captures
  in
  let visited = EqCond (member candidate seen, Const "true") in
  let unseen = EqCond (member candidate seen, Const "false") in
  let certified = EqCond (member candidate successors, Const "true") in
  (* Exact false is required here: a stuck membership test is not evidence
     that the source-derived successor list excludes the candidate. *)
  let uncertified = EqCond (member candidate successors, Const "false") in
  let same_target = EqCond (candidate, request.target) in
  let other_target = BoolCond (App ("_=/=_", [ candidate; request.target ])) in
  let machine role ~emit_hit =
    let name suffix = role ^ suffix in
    let reach = closure_op request (name "Reach") in
    let expand = closure_op request (name "Expand") in
    let reach_call queue seen =
      App (reach, queue :: seen :: captures)
    in
    let expand_call current candidates successors queue seen =
      App (expand, current :: candidates :: successors :: queue :: seen :: captures)
    in
    let step label lhs rhs =
      generated request
        (rl ~label:(String.lowercase_ascii (closure_op request (name label)))
           lhs rhs)
    in
    let actual_call =
      App (reach, frontier :: frontier :: actual_captures)
    in
    let reach_empty =
      generated request
        (rl ~label:(String.lowercase_ascii (closure_op request (name "Empty")))
           (reach_call nil seen) request.refuted)
    in
    let reach_cons =
      let lhs = reach_call (cons current queue) seen in
      step "Next" lhs
        (expand_call current candidates_value successors_value queue seen)
    in
    let expand_empty =
      let lhs = expand_call current nil successors queue seen in
      step "Expanded" lhs (reach_call queue seen)
    in
    let tail_call = expand_call current candidates successors queue seen in
    let cons_lhs =
      expand_call current (cons candidate candidates) successors queue seen
    in
    let skip_visited =
      generated request
        (crl ~label:(String.lowercase_ascii (closure_op request (name "Seen")))
           cons_lhs tail_call
           [ EqCondition other_target; EqCondition visited ])
    in
    let skip_outside_domain =
      request.domain_false
      |> List.mapi (fun index conditions ->
           generated request
             (crl
                ~label:
                  (String.lowercase_ascii
                     (closure_op request
                        (name ("DomainMiss" ^ string_of_int (index + 1)))))
                cons_lhs tail_call
                conditions))
    in
    let hit evidence role =
      if not emit_hit then []
      else
        [ generated request
            (crl
               ~label:
                 (String.lowercase_ascii (closure_op request (name role)))
               cons_lhs request.proved
               (EqCondition same_target :: evidence)) ]
    in
    (* The worklist computes finite graph reachability, so DFS and BFS have the
       same result.  Pushing at the front is constant-time; appending with Snoc
       repeatedly traversed the queue without changing the reachable set. *)
    let enqueue_call =
      expand_call current candidates successors (cons candidate queue)
        (cons candidate seen)
    in
    let enqueue evidence role =
      let prefix =
        [ EqCondition other_target; EqCondition unseen ]
        @ request.domain_true @ evidence
      in
      generated request
        (crl
           ~label:(String.lowercase_ascii (closure_op request (name role)))
           cons_lhs enqueue_call prefix)
    in
    let skip_non_edge role prefix =
      generated request
        (crl ~label:(String.lowercase_ascii (closure_op request (name role)))
           cons_lhs tail_call prefix)
    in
    ( closure_surface request list reach expand
      @ [ reach_empty; reach_cons; expand_empty; skip_visited ]
      @ skip_outside_domain
      @ hit (request.domain_true @ [ EqCondition certified ]) "SourceHit"
      @ hit
          (request.domain_true
           @ [ EqCondition uncertified; request.direct_true ])
          "DirectHit"
      @ [ enqueue [ EqCondition certified ] "SourceEnqueue"
        ; enqueue
            [ EqCondition uncertified; request.direct_true ] "DirectEnqueue"
        ; skip_non_edge "TargetNoEdge"
            ([ EqCondition same_target ]
             @ request.domain_true
             @ [ EqCondition uncertified; request.direct_false ])
        ; skip_non_edge "NoEdge"
            ([ EqCondition other_target; EqCondition unseen ]
             @ request.domain_true
             @ [ EqCondition uncertified; request.direct_false ])
        ]
    , actual_call )
  in
  (* Both machines compute reachability over the same finite source-certified
     graph.  The target remains eligible even when it is the initial node: a
     reflexive source edge must block the negative machine. *)
  let prove_statements, prove_call = machine "" ~emit_hit:true in
  match request.mode with
  | Runtime_truth_worklist_indexed.Prove ->
    { Runtime_truth_worklist_indexed.statements =
        list_surface request @ prove_statements
    ; true_condition = RewriteCond (prove_call, request.proved)
    ; false_condition = None
    }
  | Decide ->
    let refute_statements, refute_call = machine "Refute" ~emit_hit:false in
    { Runtime_truth_worklist_indexed.statements =
        list_surface request @ prove_statements @ refute_statements
    ; true_condition = RewriteCond (prove_call, request.proved)
    ; false_condition = Some (RewriteCond (refute_call, request.refuted))
    }

let materialize request =
  match request.mode with
  | Runtime_truth_worklist_indexed.Prove -> materialize_prove request
  | Decide -> materialize_decide request
