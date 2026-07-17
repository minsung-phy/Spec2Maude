open Maude_ir
open Util.Source

type item =
  { name : string
  ; origin : Origin.t
  ; request : Runtime_truth_worklist_helper.request
  }

type relation =
  { id : string
  ; sorts : sort list
  ; rules : Runtime_truth_scc.rule list
  }

type positive_phase = Ordinary | Transitive

let generated item origin node =
  Maude_ir.generated ~provenance:(Helper item.name) ~origin node

let result_sort item =
  sort ("RuntimeTruthWorklist" ^ Naming.sort_token item.name ^ "Conf")
let terminal = sort "SpectecTerminal"
let terminals = sort "SpectecTerminals"

let role source role = role ^ "-" ^ Naming.source_slug ~lower:true source
let prove_op item id = Naming.helper_companion ~role:(role id "truth-prove") item.name
let positive_worker_op item id =
  Naming.helper_companion ~role:(role id "truth-positive-worker") item.name
let refute_op item id = Naming.helper_companion ~role:(role id "truth-refute") item.name
let all_op item id = Naming.helper_companion ~role:(role id "truth-all") item.name
let goal_op item id = Naming.helper_companion ~role:(role id "truth-goal") item.name
let match_op item index =
  Naming.helper_companion
    ~role:("truth-rule-match-" ^ string_of_int index) item.name

let rule_refute_op item index =
  Naming.helper_companion
    ~role:("truth-rule-refute-" ^ string_of_int index) item.name

let positive_phase_sort item =
  sort
    ("RuntimeTruthWorklist" ^ Naming.sort_token item.name ^ "PositivePhase")

let positive_phase_op item = function
  | Ordinary -> Naming.helper_companion ~role:"truth-positive-ordinary" item.name
  | Transitive -> Naming.helper_companion ~role:"truth-positive-transitive" item.name

let positive_phase_term item phase = Const (positive_phase_op item phase)

let frozen_all sorts =
  match sorts with
  | [] -> []
  | _ -> [ Frozen (List.mapi (fun index _ -> index + 1) sorts) ]

let indexed_mode item =
  match item.request.mode with
  | Runtime_truth_worklist_helper.Prove -> Runtime_truth_worklist_indexed.Prove
  | Decide -> Runtime_truth_worklist_indexed.Decide

let input_vars names sorts =
  sorts
  |> List.fold_left
       (fun (vars, names) sort ->
         let var, names =
           Local_name.fresh_qualified
             names Local_name.Component (sort_ref sort)
         in
         var :: vars, names)
       ([], names)
  |> fun (vars, names) -> List.rev vars, names

let public_vars item =
  input_vars Local_name.empty item.request.input_sorts

let public_lhs item =
  let invocation =
    Runtime_truth_worklist_helper.invocation
      ~helper_name:item.name item.request
  in
  let vars, _ = public_vars item in
  App (invocation.worklist_op, vars)

let history_var names =
  Local_name.fresh_qualified
    names Local_name.History (sort_ref terminals)

let reserve_names env source_ids terms =
  Local_name.reserve_sources Local_name.empty source_ids
  |> fun names ->
  Local_name.reserve_existing_many names
    (Expr_env.bound_vars env
     @ List.concat_map Condition_closure.term_vars terms)

let goal item relation terms = App (goal_op item relation.id, terms)
let visited item relation terms history =
  App ("contains", [ goal item relation terms; history ])
let push item relation terms history =
  App ("_ _", [ history; goal item relation terms ])

let relation_of_rules id rules =
  match rules with
  | [] -> None
  | rule :: _ ->
    let components = Analysis.Relation_graph.exp_components rule.Runtime_truth_scc.source.head in
    let sorts = List.map (fun exp -> Expr_translate.carrier_sort_of_typ exp.note) components in
    if List.for_all Option.is_some sorts then
      Some { id; sorts = List.filter_map Fun.id sorts; rules }
    else
      None

let relations (plan : Runtime_truth_scc.t) =
  plan.Runtime_truth_scc.closure
  |> List.filter_map (fun id ->
    plan.sccs
    |> List.concat_map (fun scc -> scc.Runtime_truth_scc.rules)
    |> List.filter (fun (rule : Runtime_truth_scc.rule) ->
      String.equal rule.source.relation_id id)
    |> relation_of_rules id)

let diagnostic ctx _item origin constructor reason suggestion source_echo =
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin
    ~constructor
    ~enclosing:(Diagnostic_provenance.enclosing ~context:(Context.enclosing_path ctx) origin)
    ~profile:(Context.profile_name ctx)
    ~reason
    ~suggestion
    ?source_echo
    ()

let planner_diagnostic ctx item blocker =
  diagnostic ctx item blocker.Runtime_truth_scc.origin blocker.constructor
    blocker.reason blocker.suggestion blocker.source_echo

let helper_surface item =
  Runtime_truth_worklist_helper.surface
    ~helper_name:item.name ~origin:item.origin item.request

let positive_phase_surface item =
  let phase_sort = positive_phase_sort item in
  [ generated item item.origin (sort_decl phase_sort)
  ; generated item item.origin
      (op (positive_phase_op item Ordinary) [] phase_sort ~attrs:[ Ctor ])
  ; generated item item.origin
      (op (positive_phase_op item Transitive) [] phase_sort ~attrs:[ Ctor ])
  ]

let surface_pattern_certificate ctx statements =
  Condition_pattern_certificate.union
    (Condition_closure.source_constructor_certificate ctx)
    (Condition_pattern_certificate.generated statements)

let helper_pattern_certificate ctx item =
  surface_pattern_certificate ctx (helper_surface item)

let relation_surface item relation =
  let result = result_sort item in
  let internal_sorts = relation.sorts @ [ terminals ] in
  [ generated item item.origin
      (op (prove_op item relation.id) (List.map sort_ref internal_sorts) result
         ~attrs:(frozen_all internal_sorts))
  ; generated item item.origin
      (op (positive_worker_op item relation.id)
         (sort_ref (positive_phase_sort item)
          :: List.map sort_ref internal_sorts)
         result
         ~attrs:(frozen_all (positive_phase_sort item :: internal_sorts)))
  ; generated item item.origin
      (op (goal_op item relation.id) (List.map sort_ref relation.sorts) terminal ~attrs:[ Ctor ])
  ]
  @ match item.request.mode with
    | Runtime_truth_worklist_helper.Prove -> []
    | Decide ->
      [ generated item item.origin
          (op (refute_op item relation.id) (List.map sort_ref internal_sorts) result
             ~attrs:(frozen_all internal_sorts))
      ; generated item item.origin
          (op (all_op item relation.id) (List.map sort_ref internal_sorts) result
             ~attrs:(frozen_all internal_sorts))
      ]

let positive_dispatcher item relation =
  let invocation =
    Runtime_truth_worklist_helper.invocation
      ~helper_name:item.name item.request
  in
  let args, names = input_vars Local_name.empty relation.sorts in
  let history, _ = history_var names in
  let lhs = App (prove_op item relation.id, args @ [ history ]) in
  let dispatch phase label =
    generated item item.origin
      (crl
         ~label:
           (item.name ^ "-positive-" ^ label ^ "-"
            ^ Naming.sanitize relation.id)
         lhs invocation.proved_rhs
         [ RewriteCond
             ( App
                 ( positive_worker_op item relation.id
                 , positive_phase_term item phase :: args @ [ history ] )
             , invocation.proved_rhs ) ])
  in
  [ dispatch Ordinary "ordinary"; dispatch Transitive "transitive" ]

let rule_surface item relation index =
  let result = result_sort item in
  let sorts = relation.sorts @ [ terminals ] in
  match item.request.mode with
  | Runtime_truth_worklist_helper.Prove -> []
  | Decide ->
    [ generated item item.origin
        (op (match_op item index) (List.map sort_ref relation.sorts) (sort "Bool"))
    ; generated item item.origin
        (op (rule_refute_op item index) (List.map sort_ref sorts) result
           ~attrs:(frozen_all sorts))
    ]

let find_relation relations id =
  List.find_opt (fun relation -> String.equal relation.id id) relations
