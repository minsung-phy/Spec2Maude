open Maude_ir
open Il.Ast
open Util.Source

type item =
  { name : string
  ; origin : Origin.t
  ; request : Runtime_truth_search_helper.request
  }

type result =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

type rule_surface =
  { search_op : string
  ; ok_op : string
  ; extra_lhs_terms : Maude_ir.term list
  }

type indexed_head =
  { source_exp : exp
  ; target_term : Maude_ir.term
  ; index_source_id : string
  ; indexed_origin : Origin.t
  }

let generated name origin node =
  Maude_ir.generated ~provenance:(Maude_ir.Helper name) ~origin node

let truth_sort name =
  Maude_ir.sort ("RuntimeTruthSearch" ^ name ^ "Conf")

let loop_op name =
  "runtimeTruthLoop" ^ name

let candidates_op name =
  "runtimeTruthCandidates" ^ name

let candidate_op name =
  "runtimeTruthCandidate" ^ name

let visited_key_op name =
  "runtimeTruthVisitedKey" ^ name

let candidates_var_name name =
  "RTCANDS" ^ name

let seed_search_op name =
  "runtimeTruthSeedSearch" ^ name

let seed_hit_op name =
  "runtimeTruthSeedHit" ^ name

let visited_var_name name =
  "RTVIS" ^ name

let pre_var_name name =
  "RTPRE" ^ name

let post_var_name name =
  "RTPOST" ^ name

let witness_var_name item source_id =
  Naming.maude_var (item.name ^ "-witness-" ^ source_id)

let rec term_key = function
  | Var name -> "V:" ^ name
  | Const name -> "C:" ^ name
  | Qid text -> "Q:" ^ text
  | App (op, args) -> "A:" ^ op ^ "(" ^ String.concat "," (List.map term_key args) ^ ")"

let dedup_terms terms =
  let _seen, terms =
    terms
    |> List.fold_left
         (fun (seen, acc) term ->
           let key = term_key term in
           if List.mem key seen then
             seen, acc
           else
             key :: seen, term :: acc)
         ([], [])
  in
  List.rev terms

let terminal_sequence terms =
  List.fold_right
    (fun term rest ->
      match rest with
      | Const "eps" -> term
      | _ -> App ("_ _", [ term; rest ]))
    terms
    (Const "eps")

let rec path_source_ids path =
  match path.it with
  | RootP -> []
  | IdxP (path, exp) -> path_source_ids path @ exp_source_ids exp
  | SliceP (path, first, last) ->
    path_source_ids path @ exp_source_ids first @ exp_source_ids last
  | DotP (path, _) -> path_source_ids path

and arg_source_ids arg =
  match arg.it with
  | ExpA exp -> exp_source_ids exp
  | TypA typ -> typ_source_ids typ
  | DefA _ | GramA _ -> []

and typ_source_ids typ =
  match typ.it with
  | VarT (_, args) -> List.concat_map arg_source_ids args
  | TupT components ->
    components
    |> List.concat_map (fun (id, typ) -> id.it :: typ_source_ids typ)
  | IterT (typ, ListN (exp, index)) ->
    let ids = typ_source_ids typ @ exp_source_ids exp in
    (match index with
    | None -> ids
    | Some id -> id.it :: ids)
  | IterT (typ, _) -> typ_source_ids typ
  | BoolT | NumT _ | TextT -> []

and exp_source_ids exp =
  match exp.it with
  | VarE id -> [ id.it ]
  | BoolE _ | NumE _ | TextE _ -> []
  | UnE (_, _, exp) | OptE (Some exp) | TheE exp | LiftE exp
  | LenE exp | UncaseE (exp, _) ->
    exp_source_ids exp
  | OptE None -> []
  | BinE (_, _, left, right) | CmpE (_, _, left, right)
  | CompE (left, right) | CatE (left, right) ->
    exp_source_ids left @ exp_source_ids right
  | TupE exps | ListE exps -> List.concat_map exp_source_ids exps
  | ProjE (exp, _) | DotE (exp, _) | CaseE (_, exp) -> exp_source_ids exp
  | StrE fields ->
    fields |> List.concat_map (fun (_atom, exp) -> exp_source_ids exp)
  | MemE (left, right) | IdxE (left, right) ->
    exp_source_ids left @ exp_source_ids right
  | SliceE (base, first, last) ->
    exp_source_ids base @ exp_source_ids first @ exp_source_ids last
  | UpdE (base, path, value) | ExtE (base, path, value) ->
    exp_source_ids base @ path_source_ids path @ exp_source_ids value
  | CallE (_, args) -> List.concat_map arg_source_ids args
  | IterE (body, (_iter, generators)) ->
    exp_source_ids body
    @ (generators
       |> List.concat_map (fun (id, source) ->
         id.it :: exp_source_ids source))
  | CvtE (exp, _, _) -> exp_source_ids exp
  | SubE (exp, from_typ, to_typ) ->
    exp_source_ids exp @ typ_source_ids from_typ @ typ_source_ids to_typ
  | IfE (test, then_, else_) ->
    exp_source_ids test @ exp_source_ids then_ @ exp_source_ids else_

let is_closed_exp exp =
  exp_source_ids exp = []

let split_exps prefix_arity exps =
  let rec take n acc rest =
    if n = 0 then Some (List.rev acc, rest)
    else
      match rest with
      | [] -> None
      | exp :: rest -> take (n - 1) (exp :: acc) rest
  in
  match take prefix_arity [] exps with
  | Some (_prefix, [ left; right ]) -> Some (left, right)
  | Some _ | None -> None

let lower_closed_candidate ctx origin exp =
  if not (is_closed_exp exp) then
    None, []
  else
    let result = Expr_translate.lower_value ctx Expr_translate.empty_env origin exp in
    match result.term with
    | Some term -> Some term, result.diagnostics
    | None -> None, result.diagnostics

let finite_query_candidates plan input_vars =
  let prefix_arity = plan.Runtime_witness_domain.candidate.prefix_arity in
  let rec drop n vars =
    if n = 0 then vars
    else
      match vars with
      | [] -> []
      | _ :: vars -> drop (n - 1) vars
  in
  match drop prefix_arity input_vars with
  | left :: right :: _ -> [ left; right ]
  | _ -> []

let early_child_origin parent segment ast_constructor region source_echo =
  Origin.with_child ?source_echo parent segment ~ast_constructor region

let early_rule_origin
    parent
    index
    (rule : Analysis.Function_graph.runtime_search_rule)
  =
  early_child_origin
    parent
    (Printf.sprintf "RuleD[%d]" index)
    "RuleD"
    rule.origin.region
    rule.source_echo

let finite_rule_head_candidates ctx item plan rules =
  let prefix_arity = plan.Runtime_witness_domain.candidate.prefix_arity in
  let input_count = List.length item.request.input_sorts in
  let rec loop index terms diagnostics = function
    | [] -> List.rev terms, List.rev diagnostics
    | rule :: rules ->
      let origin = early_rule_origin item.origin index rule in
      let candidates =
        match
          Analysis.Relation_graph.exp_components_for_count input_count rule.head
        with
        | None -> []
        | Some exps ->
          (match split_exps prefix_arity exps with
          | None -> []
          | Some (left, right) -> [ left; right ])
      in
      let terms, diagnostics =
        candidates
        |> List.fold_left
             (fun (terms, diagnostics) exp ->
               let candidate_origin =
                 early_child_origin
                   origin
                   "finite-candidate"
                   "RuntimeTruthSearch/Candidate"
                   exp.at
                   (Some (Il.Print.string_of_exp exp))
               in
               match lower_closed_candidate ctx candidate_origin exp with
               | Some term, new_diagnostics ->
                 term :: terms, List.rev_append new_diagnostics diagnostics
               | None, new_diagnostics ->
                 terms, List.rev_append new_diagnostics diagnostics)
             (terms, diagnostics)
      in
      loop (index + 1) terms diagnostics rules
  in
  loop 1 [] [] rules

let public_rule_surface item =
  { search_op = Runtime_truth_search_helper.search_op ~helper_name:item.name
  ; ok_op = Runtime_truth_search_helper.ok_op ~helper_name:item.name
  ; extra_lhs_terms = []
  }

let loop_rule_surface item =
  { search_op = loop_op item.name
  ; ok_op = Runtime_truth_search_helper.ok_op ~helper_name:item.name
  ; extra_lhs_terms =
      [ Var (candidates_var_name item.name); Var (visited_var_name item.name) ]
  }

let seed_rule_surface item =
  { search_op = seed_search_op item.name
  ; ok_op = seed_hit_op item.name
  ; extra_lhs_terms = []
  }

let frozen_all sorts =
  match sorts with
  | [] -> []
  | _ ->
    let rec range acc index = function
      | [] -> List.rev acc
      | _ :: rest -> range (index :: acc) (index + 1) rest
    in
    [ Maude_ir.Frozen (range [] 1 sorts) ]

let helper_surface item =
  let request = item.request in
  let result_sort = truth_sort item.name in
  let search_op = Runtime_truth_search_helper.search_op ~helper_name:item.name in
  let ok_op = Runtime_truth_search_helper.ok_op ~helper_name:item.name in
  [ generated item.name item.origin (Maude_ir.sort_decl result_sort)
  ; generated
      item.name
      item.origin
      (Maude_ir.op
         search_op
         (List.map Maude_ir.sort_ref request.input_sorts)
         result_sort
         ~attrs:(frozen_all request.input_sorts))
  ; generated
      item.name
      item.origin
      (Maude_ir.op ok_op [] result_sort ~attrs:[ Maude_ir.Ctor ])
  ]

let target_guided_helper_surface item target =
  let request = item.request in
  let result_sort = truth_sort item.name in
  let spectec_terminal = Maude_ir.sort "SpectecTerminal" in
  let seed_input_sorts =
    let rec take n acc sorts =
      if n = 0 then List.rev acc
      else
        match sorts with
        | [] -> List.rev acc
        | sort :: sorts -> take (n - 1) (sort :: acc) sorts
    in
    take (target.Runtime_witness_proof.prefix_arity + 1) [] request.input_sorts
  in
  helper_surface item
  @ [ generated
        item.name
        item.origin
        (Maude_ir.op
           (seed_search_op item.name)
           (List.map Maude_ir.sort_ref seed_input_sorts)
           result_sort
           ~attrs:(frozen_all seed_input_sorts))
    ; generated
        item.name
        item.origin
        (Maude_ir.op
           (seed_hit_op item.name)
           [ Maude_ir.sort_ref spectec_terminal ]
           result_sort
           ~attrs:[ Maude_ir.Ctor ])
    ; generated
        item.name
        item.origin
        (Maude_ir.var
           (witness_var_name item target.Runtime_witness_proof.witness_source_id)
           (Maude_ir.sort_ref spectec_terminal))
    ]

let finite_helper_surface ctx item (plan : Runtime_witness_domain.t) rules =
  let request = item.request in
  let result_sort = truth_sort item.name in
  let spectec_terminal = Maude_ir.sort "SpectecTerminal" in
  let spectec_terminals = Maude_ir.sort "SpectecTerminals" in
  let public_search_op =
    Runtime_truth_search_helper.search_op ~helper_name:item.name
  in
  let loop_search_op = loop_op item.name in
  let candidates_op = candidates_op item.name in
  let candidate_op = candidate_op item.name in
  let visited_key_op = visited_key_op item.name in
  let candidates_var = candidates_var_name item.name in
  let visited_var = visited_var_name item.name in
  let pre_var = pre_var_name item.name in
  let post_var = post_var_name item.name in
  let input_var index =
    Var ("RTIN" ^ item.name ^ string_of_int (index + 1))
  in
  let input_vars = List.mapi (fun index _ -> input_var index) request.input_sorts in
  let rule_candidates, _candidate_diagnostics =
    finite_rule_head_candidates ctx item plan rules
  in
  let candidate_terms =
    finite_query_candidates plan input_vars @ rule_candidates
    |> dedup_terms
    |> List.map (fun term -> App (candidate_op, [ term ]))
  in
  let input_var_decls =
    request.input_sorts
    |> List.mapi (fun index sort ->
      generated
        item.name
        item.origin
        (Maude_ir.var
           ("RTIN" ^ item.name ^ string_of_int (index + 1))
           (Maude_ir.sort_ref sort)))
  in
  helper_surface item
  @ [ generated
        item.name
        item.origin
        (Maude_ir.op
           loop_search_op
           (List.map Maude_ir.sort_ref request.input_sorts
            @ [ Maude_ir.sort_ref spectec_terminals
              ; Maude_ir.sort_ref spectec_terminals
              ])
           result_sort
           ~attrs:(frozen_all (request.input_sorts @ [ spectec_terminals; spectec_terminals ])))
    ; generated
        item.name
        item.origin
        (Maude_ir.op
           candidates_op
           (List.map Maude_ir.sort_ref request.input_sorts)
           spectec_terminals)
    ; generated
        item.name
        item.origin
        (Maude_ir.op
           candidate_op
           [ Maude_ir.sort_ref spectec_terminal ]
           spectec_terminal
           ~attrs:[ Maude_ir.Ctor ])
    ; generated
        item.name
        item.origin
        (Maude_ir.op
           visited_key_op
           (List.map Maude_ir.sort_ref request.input_sorts)
           spectec_terminal
           ~attrs:[ Maude_ir.Ctor ])
    ; generated
        item.name
        item.origin
        (Maude_ir.var candidates_var (Maude_ir.sort_ref spectec_terminals))
    ; generated
        item.name
        item.origin
        (Maude_ir.var visited_var (Maude_ir.sort_ref spectec_terminals))
    ; generated
        item.name
        item.origin
        (Maude_ir.var pre_var (Maude_ir.sort_ref spectec_terminals))
    ; generated
        item.name
        item.origin
        (Maude_ir.var post_var (Maude_ir.sort_ref spectec_terminals))
    ; generated
        item.name
        item.origin
        (Maude_ir.var
           (witness_var_name item plan.candidate.witness_source_id)
           (Maude_ir.sort_ref spectec_terminal))
    ]
  @ input_var_decls
  @ [ generated
        item.name
        item.origin
        (Maude_ir.eq
           (App (candidates_op, input_vars))
           (terminal_sequence candidate_terms))
    ; generated
        item.name
        item.origin
        (Maude_ir.crl
           ~label:(item.name ^ "-finite-entry")
           (App (public_search_op, input_vars))
           (App (loop_search_op, input_vars @ [ Var candidates_var; Const "eps" ]))
           [ EqCondition
               (MatchCond (Var candidates_var, App (candidates_op, input_vars)))
           ])
    ]

let diagnostic ctx item origin constructor reason suggestion =
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin
    ~constructor
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason
    ~suggestion
    ~source_echo:(Runtime_truth_search_helper.reason item.request)
    ()

let unsupported ctx item origin constructor reason suggestion =
  diagnostic ctx item origin constructor reason suggestion

let child_origin parent segment ast_constructor region source_echo =
  Origin.with_child ?source_echo parent segment ~ast_constructor region

let rule_origin parent index (rule : Analysis.Function_graph.runtime_search_rule) =
  child_origin
    parent
    (Printf.sprintf "RuleD[%d]" index)
    "RuleD"
    rule.origin.region
    rule.source_echo

let add_binding env (id, (binding : Expr_translate.binding)) =
  Expr_translate.add_var env id binding

let typ_is_iter = Type_shape.typ_is_iter

let flat_list_element_typ typ =
  match typ.it with
  | IterT (element_typ, (List | List1 | ListN _))
    when not (typ_is_iter element_typ) ->
    Some element_typ
  | _ -> None

let rec indexed_head_source exp =
  match exp.it with
  | SubE (inner, _, _) | CvtE (inner, _, _) ->
    indexed_head_source inner
  | IdxE (source_exp, index_exp) ->
    (match index_exp.it with
    | VarE index_id -> Some (index_id.it, source_exp)
    | _ -> None)
  | _ -> None

let typecheck_for_indexed_head ctx env origin exp target target_sort =
  let witness =
    Expr_translate.lower_type_witness
      ctx
      env
      origin
      ~constructor:"RuntimeTruthSearch/head-indexed"
      exp.note
  in
  match witness.term with
  | None -> [], witness.diagnostics
  | Some witness_term ->
    ( witness.guards
      @ Expr_translate.typecheck_conditions_for_typ
          exp.note
          target_sort
          target
          witness_term
    , witness.diagnostics )

let lower_indexed_head ctx env origin position exp =
  match indexed_head_source exp, Expr_translate.carrier_sort_of_typ exp.note with
  | Some (index_source_id, source_exp), Some target_sort ->
    let raw_var =
      Naming.maude_var
        ~fallback:"TARGET"
        (Naming.helper_local_var_stem origin ^ "-head-" ^ string_of_int position)
    in
    let target_term = Var (raw_var ^ ":" ^ Maude_ir.sort_name target_sort) in
    let guards, diagnostics =
      typecheck_for_indexed_head ctx env origin exp target_term target_sort
    in
    Some
        ( target_term
      , { source_exp
        ; target_term
        ; index_source_id
        ; indexed_origin = origin
        }
      , guards
      , diagnostics )
  | _ -> None

let lower_patterns ctx origin exps =
  let rec loop env terms indexed_heads guards diagnostics = function
    | [] ->
      ( Some (List.rev terms)
      , env
      , List.rev indexed_heads
      , List.rev guards
      , List.rev diagnostics )
    | exp :: exps ->
      let position = List.length terms + 1 in
      let exp_origin =
        child_origin
          origin
          (Printf.sprintf "head[%d]" position)
          "RuntimeTruthSearch/Head"
          exp.at
          (Some (Il.Print.string_of_exp exp))
      in
      match lower_indexed_head ctx env exp_origin position exp with
      | Some (term, indexed_head, new_guards, new_diagnostics) ->
        loop
          env
          (term :: terms)
          (indexed_head :: indexed_heads)
          (List.rev_append new_guards guards)
          (List.rev_append new_diagnostics diagnostics)
          exps
      | None ->
        let result =
          Expr_translate.lower_pattern_with_bindings ctx env exp_origin exp
        in
        let env =
          List.fold_left add_binding env result.introduced_bindings
        in
        (match result.pattern_term with
      | Some term ->
        loop
          env
          (term :: terms)
          indexed_heads
          (List.rev_append result.pattern_guards guards)
          (List.rev_append result.pattern_diagnostics diagnostics)
          exps
      | None ->
        loop
          env
          terms
          indexed_heads
          (List.rev_append result.pattern_guards guards)
          (List.rev_append result.pattern_diagnostics diagnostics)
          exps)
  in
  loop Expr_translate.empty_env [] [] [] [] exps

let vars_subset vars bound =
  List.for_all (fun var -> List.mem var bound) vars

let lower_indexed_head_unsupported ctx item indexed constructor reason suggestion =
  [ unsupported ctx item indexed.indexed_origin constructor reason suggestion ]

let lower_indexed_head_contains ctx item premise_result indexed =
  match flat_list_element_typ indexed.source_exp.note with
  | None ->
    [], lower_indexed_head_unsupported
          ctx
          item
          indexed
          "RuntimeTruthSearch/head-indexed/source-shape"
          "indexed relation-head target comes from a source expression that is not a flat list"
          "Keep this truth helper Unsupported until the indexed-head source can be lowered as a flat sequence membership"
  | Some _ ->
    let env =
      Expr_translate.with_condition_bound_vars
        premise_result.Premise_result.env_after
        premise_result.Premise_result.bound_vars_after
    in
    let source_result =
      Expr_translate.lower_sequence ctx env indexed.indexed_origin indexed.source_exp
    in
    (match source_result.term with
    | None ->
      [], source_result.diagnostics
          @ lower_indexed_head_unsupported
              ctx
              item
              indexed
              "RuntimeTruthSearch/head-indexed/source-lowering"
              "indexed relation-head source list could not be lowered after the source premises"
              "Do not silently drop the indexed-head membership; keep the helper Unsupported"
    | Some source_term ->
      let bound_after_source =
        Condition_closure.conditions_admissible_bound
          premise_result.Premise_result.bound_vars_after
          source_result.guards
      in
      (match bound_after_source with
      | None ->
        [], source_result.diagnostics
            @ lower_indexed_head_unsupported
                ctx
                item
                indexed
                "RuntimeTruthSearch/head-indexed/source-admissibility"
                "indexed relation-head source list needs variables that are not bound before its guards"
                "Keep this helper Unsupported until the source premise order binds the indexed source sequence"
      | Some bound_after_source
        when not
               (vars_subset
                  (Condition_closure.term_vars source_term)
                  bound_after_source) ->
        [], source_result.diagnostics
            @ lower_indexed_head_unsupported
                ctx
                item
                indexed
                "RuntimeTruthSearch/head-indexed/source-vars"
                "indexed relation-head source list still contains variables that are not bound after source guards"
                "Keep this helper Unsupported until all variables used by the indexed source sequence are bound"
      | Some _ ->
        ( source_result.guards
          @ [ BoolCond (App ("contains", [ indexed.target_term; source_term ])) ]
        , source_result.diagnostics )))

let lower_indexed_head_conditions ctx item premise_result indexed_heads =
  indexed_heads
  |> List.fold_left
       (fun (conditions, diagnostics) indexed ->
         let new_conditions, new_diagnostics =
           lower_indexed_head_contains ctx item premise_result indexed
         in
         conditions @ new_conditions, diagnostics @ new_diagnostics)
       ([], [])

let rule_label item (rule : Analysis.Function_graph.runtime_search_rule) index =
  let rule_id =
    Option.value ~default:("rule-" ^ string_of_int index) rule.rule_id
  in
  Some
    (Maude_ir.sanitize_label
       (item.name ^ "-" ^ rule.relation_id ^ "-" ^ rule_id))

let dedup_rule_conditions conditions =
  List.fold_right
    (fun condition acc ->
      if List.exists (( = ) condition) acc then acc else condition :: acc)
    conditions
    []

let add_bound_vars vars bound =
  List.fold_left
    (fun bound var -> if List.mem var bound then bound else var :: bound)
    bound
    vars

let witness_binding_equalities lhs_terms before_conditions witness_terms conditions =
  let witness_vars =
    witness_terms
    |> List.concat_map Condition_closure.term_vars
    |> List.sort_uniq String.compare
  in
  let initial_bound =
    lhs_terms
    |> List.concat_map Condition_closure.term_vars
    |> List.sort_uniq String.compare
  in
  let bound =
    Condition_closure.rule_conditions_bound_vars initial_bound before_conditions
  in
  let bind_if_witness bound subject name =
    if List.mem name witness_vars
       && not (List.mem name bound)
       && Condition_closure.vars_subset
            (Condition_closure.term_vars subject)
            bound
    then
      Some
        ( add_bound_vars [ name ] bound
        , MatchCond (Var name, subject) )
    else
      None
  in
  let rec loop bound acc = function
    | [] -> List.rev acc
    | BoolCond (App ("_==_", [ subject; Var name ])) :: rest ->
      (match bind_if_witness bound subject name with
      | Some (bound, condition) -> loop bound (condition :: acc) rest
      | None ->
        loop
          (Condition_closure.conditions_bound_vars bound [ BoolCond (App ("_==_", [ subject; Var name ])) ])
          (BoolCond (App ("_==_", [ subject; Var name ])) :: acc)
          rest)
    | BoolCond (App ("_==_", [ Var name; subject ])) :: rest ->
      (match bind_if_witness bound subject name with
      | Some (bound, condition) -> loop bound (condition :: acc) rest
      | None ->
        loop
          (Condition_closure.conditions_bound_vars bound [ BoolCond (App ("_==_", [ Var name; subject ])) ])
          (BoolCond (App ("_==_", [ Var name; subject ])) :: acc)
          rest)
    | condition :: rest ->
      loop
        (Condition_closure.conditions_bound_vars bound [ condition ])
        (condition :: acc)
        rest
  in
  loop bound [] conditions

let lower_rule_with_surface
    ctx
    item
    surface
    index
    (rule : Analysis.Function_graph.runtime_search_rule)
  =
  let request = item.request in
  let origin = rule_origin item.origin index rule in
  if not (String.equal rule.relation_id request.rel_id) then
    Error
      [ unsupported
          ctx
          item
          origin
          "RuntimeTruthSearch/materializer/relation-local-interface"
          ("runtime truth-search closure contains dependent relation `"
           ^ rule.relation_id
           ^ "`, but this materializer slice only emits source rules for the requested relation `"
           ^ request.rel_id
           ^ "`")
          "Add relation-local truth/search interfaces before materializing closure dependencies; do not inline another relation by name"
      ]
  else
    match
      Analysis.Relation_graph.exp_components_for_count
        (List.length request.input_sorts)
        rule.head
    with
    | None ->
      Error
        [ unsupported
            ctx
            item
            origin
            "RuntimeTruthSearch/materializer/head-arity"
            "source RuleD head does not match the requested relation arity without flattening"
            "Preserve the source relation component structure before emitting a runtime truth-search rule"
        ]
    | Some components ->
      let terms_opt, env, indexed_heads, head_guards, head_diags =
        lower_patterns ctx origin components
      in
      (match terms_opt with
      | None -> Error head_diags
      | Some input_terms ->
        let premise_result =
          Premise_translate.translate_premises
            ~allow_runtime_search:true
            ctx
            env
            ~bound_conditions:head_guards
            ~escape_source_ids:[]
            ~bound_terms:input_terms
            origin
            rule.prems
        in
        let indexed_conditions, indexed_diags =
          lower_indexed_head_conditions ctx item premise_result indexed_heads
        in
        let diagnostics =
          head_diags @ premise_result.diagnostics @ indexed_diags
        in
        if premise_result.has_else then
          Error
            (diagnostics
             @ [ unsupported
                   ctx
                   item
                   origin
                   "RuntimeTruthSearch/materializer/ElsePr"
                   "runtime truth-search helper rule contains ElsePr, which needs a source-derived enabledness complement"
                   "Keep this truth helper Unsupported until otherwise complement lowering exists for this source shape"
               ])
        else if List.exists Diagnostics.is_fatal diagnostics then
          Error diagnostics
        else
          let lhs =
            App (surface.search_op, input_terms @ surface.extra_lhs_terms)
          in
          let rhs = Const surface.ok_op in
          let conditions =
            List.map (fun condition -> EqCondition condition) head_guards
            @ premise_result.rule_conditions
            @ List.map
                (fun condition -> EqCondition condition)
                (premise_result.eq_conditions @ indexed_conditions)
            |> Condition_closure.normalize_rule_conditions [ lhs ]
            |> dedup_rule_conditions
          in
          let admissibility_diags =
            Condition_closure.crl_admissibility_diagnostics
              ctx
              origin
              lhs
              rhs
              conditions
          in
          if List.exists Diagnostics.is_fatal admissibility_diags then
            Error (diagnostics @ admissibility_diags)
          else
            Ok
              (generated
                 item.name
                 origin
                 (crl ?label:(rule_label item rule index) lhs rhs conditions)))

let local_rules item =
  item.request.rules
  |> List.filter (fun rule ->
    String.equal rule.Analysis.Function_graph.relation_id item.request.rel_id)

let lower_rules_with_surface ctx item surface surface_statements rules =
  let rec loop index statements diagnostics = function
    | [] ->
      if List.exists Diagnostics.is_fatal diagnostics then
        { statements = []; diagnostics }
      else
        { statements = surface_statements @ List.rev statements; diagnostics }
    | rule :: rules ->
      (match lower_rule_with_surface ctx item surface index rule with
      | Ok statement -> loop (index + 1) (statement :: statements) diagnostics rules
      | Error new_diagnostics ->
        loop (index + 1) statements (diagnostics @ new_diagnostics) rules)
  in
  loop 1 [] [] rules

let lower_acyclic_item ctx item =
  let local_rules = local_rules item in
  match local_rules with
  | [] ->
    { statements = []
    ; diagnostics =
        [ unsupported
            ctx
            item
            item.origin
            "RuntimeTruthSearch/materializer/no-local-rules"
            ("runtime truth-search closure for `"
             ^ item.request.rel_id
             ^ "` has no source RuleD clauses for that relation")
            "Keep this helper Unsupported until the referenced relation body is available in the source index"
        ]
    }
  | _ ->
    lower_rules_with_surface
      ctx
      item
      (public_rule_surface item)
      (helper_surface item)
      local_rules

let same_source_rule
    (source_rule : Runtime_witness_proof.source_rule)
    (rule : Analysis.Function_graph.runtime_search_rule)
  =
  let same_exp left right =
    String.equal (Il.Print.string_of_exp left) (Il.Print.string_of_exp right)
  in
  let same_prem left right =
    String.equal (Il.Print.string_of_prem left) (Il.Print.string_of_prem right)
  in
  let same_prems =
    List.length source_rule.prems = List.length rule.prems
    && List.for_all2 same_prem source_rule.prems rule.prems
  in
  let same_rule_id =
    match source_rule.rule_id, rule.rule_id with
    | Some source_id, Some rule_id -> String.equal source_id rule_id
    | Some _, None | None, Some _ | None, None -> false
  in
  let same_source_echo =
    match source_rule.source_echo, rule.source_echo with
    | Some source_echo, Some rule_echo -> String.equal source_echo rule_echo
    | Some _, None | None, Some _ | None, None -> false
  in
  String.equal source_rule.relation_id rule.relation_id
  && (same_rule_id
      || same_source_echo
      || (same_exp source_rule.head rule.head && same_prems)
      || String.equal
           (Origin.source_location source_rule.origin)
           (Origin.source_location rule.origin))

let find_runtime_rule
    (source_rule : Runtime_witness_proof.source_rule)
    rules
  =
  rules |> List.find_opt (same_source_rule source_rule)

let contains_source_premise source_premise prems =
  let source = Il.Print.string_of_prem source_premise in
  prems
  |> List.exists (fun prem ->
    String.equal source (Il.Print.string_of_prem prem))

let is_target_guided_source_rule
    (target : Runtime_witness_proof.target_chain)
    (rule : Analysis.Function_graph.runtime_search_rule)
  =
  contains_source_premise target.recursive_premise rule.prems
  && contains_source_premise target.target_premise rule.prems

let exp_binding_type source_id binds =
  binds
  |> List.find_map (fun quant ->
    match quant.it with
    | ExpP (id, typ) when String.equal id.it source_id -> Some typ
    | ExpP _ | TypP _ | DefP _ | GramP _ -> None)

let split_target_terms prefix_arity terms =
  let rec take n acc rest =
    if n = 0 then Some (List.rev acc, rest)
    else
      match rest with
      | [] -> None
      | term :: rest -> take (n - 1) (term :: acc) rest
  in
  match take prefix_arity [] terms with
  | Some (prefix, [ left; right ]) -> Some (prefix, left, right)
  | Some _ | None -> None

let add_witness_binding env source_id typ witness =
  Expr_translate.add_var
    env
    source_id
    { Expr_translate.term = witness
    ; sort = Maude_ir.sort "SpectecTerminal"
    ; typ
    }

let lower_target_rule_head ctx item target runtime_rule =
  let origin =
    child_origin
      item.origin
      "target-guided"
      "RuleD"
      target.Runtime_witness_proof.rule.origin.region
      target.Runtime_witness_proof.rule.source_echo
  in
  match
    Analysis.Relation_graph.exp_components_for_count
      (List.length item.request.input_sorts)
      target.Runtime_witness_proof.rule.head
  with
  | None ->
    Error
      [ unsupported
          ctx
          item
          origin
          "RuntimeTruthSearch/materializer/target-guided/head-arity"
          "target-guided source RuleD head does not match the requested relation arity without flattening"
          "Preserve the source relation component structure before emitting the target-guided truth helper"
      ]
  | Some components ->
    let terms_opt, env, _indexed_heads, head_guards, head_diags =
      lower_patterns ctx origin components
    in
    match terms_opt with
    | None -> Error head_diags
    | Some input_terms ->
      (match
         split_target_terms
           target.Runtime_witness_proof.prefix_arity
           input_terms,
         exp_binding_type
           target.Runtime_witness_proof.witness_source_id
           runtime_rule.Analysis.Function_graph.binds
       with
      | Some (prefix, left, right), Some witness_typ ->
        let witness =
          Var
            (witness_var_name
               item
               target.Runtime_witness_proof.witness_source_id)
        in
        let env =
          add_witness_binding
            env
            target.Runtime_witness_proof.witness_source_id
            witness_typ
            witness
        in
        Ok (origin, input_terms, prefix, left, right, witness, env, head_guards, head_diags)
      | None, _ ->
        Error
          (head_diags
           @ [ unsupported
                 ctx
                 item
                 origin
                 "RuntimeTruthSearch/materializer/target-guided/input-shape"
                 "target-guided source head is not prefix plus two endpoints after pattern lowering"
                 "Keep this helper Unsupported until the IL relation head has the proven R(prefix, left, target) shape"
             ])
      | _, None ->
        Error
          (head_diags
           @ [ unsupported
                 ctx
                 item
                 origin
                 "RuntimeTruthSearch/materializer/target-guided/witness-type"
                 ("target-guided witness `"
                  ^ target.Runtime_witness_proof.witness_source_id
                  ^ "` is not present as an ExpP binding in the source RuleD")
                 "Keep this helper Unsupported until the source RuleD binding gives the witness type"
             ]))

let split_transitive_terms prefix_arity terms =
  let rec take n acc rest =
    if n = 0 then Some (List.rev acc, rest)
    else
      match rest with
      | [] -> None
      | term :: rest -> take (n - 1) (term :: acc) rest
  in
  match take prefix_arity [] terms with
  | Some (prefix, [ left; right ]) -> Some (prefix, left, right)
  | Some _ | None -> None

let transitive_candidate_pattern item witness =
  let pre = Var (pre_var_name item.name) in
  let post = Var (post_var_name item.name) in
  let candidate = App (candidate_op item.name, [ witness ]) in
  App ("_ _", [ pre; App ("_ _", [ candidate; post ]) ])

let visited_key item input_terms =
  App (visited_key_op item.name, input_terms)

let append_visited item input_terms =
  App ("_ _", [ Var (visited_var_name item.name); visited_key item input_terms ])

let loop_call item input_terms candidates visited =
  App (loop_op item.name, input_terms @ [ candidates; visited ])

let lower_transitive_step ctx item domain =
  let request = item.request in
  let transitive = domain.Runtime_witness_proof.transitive in
  let source_rule = transitive.rule in
  let origin =
    child_origin
      item.origin
      "finite-transitive"
      "RuleD"
      source_rule.origin.region
      source_rule.source_echo
  in
  match
    Analysis.Relation_graph.exp_components_for_count
      (List.length request.input_sorts)
      source_rule.head
  with
  | None ->
    Error
      [ unsupported
          ctx
          item
          origin
          "RuntimeTruthSearch/materializer/finite-transitive/head-arity"
          "source transitive RuleD head does not match the requested relation arity without flattening"
          "Preserve the source relation component structure before emitting the finite-transitive CRL step"
      ]
  | Some components ->
    let terms_opt, _env, _indexed_heads, head_guards, head_diags =
      lower_patterns ctx origin components
    in
    (match terms_opt with
    | None -> Error head_diags
    | Some input_terms ->
      (match split_transitive_terms transitive.prefix_arity input_terms with
      | None ->
        Error
          (head_diags
           @ [ unsupported
                 ctx
                 item
                 origin
                 "RuntimeTruthSearch/materializer/finite-transitive/input-shape"
                 "finite-transitive source head is not prefix plus two endpoints after pattern lowering"
                 "Keep this helper Unsupported until the IL relation head has the proven R(prefix, left, right) shape"
             ])
      | Some (prefix_terms, left_term, right_term) ->
        let candidates = Var (candidates_var_name item.name) in
        let visited = Var (visited_var_name item.name) in
        let witness =
          Var (witness_var_name item transitive.witness_source_id)
        in
        let current_input = prefix_terms @ [ left_term; right_term ] in
        let next_visited = append_visited item current_input in
        let lhs = loop_call item current_input candidates visited in
        let rhs =
          Const (Runtime_truth_search_helper.ok_op ~helper_name:item.name)
        in
        let left_input = prefix_terms @ [ left_term; witness ] in
        let right_input = prefix_terms @ [ witness; right_term ] in
        let conditions =
          List.map (fun condition -> EqCondition condition) head_guards
          @ [ EqCondition
                (BoolCond
                   (App
                      ( "_=/=_"
                      , [ App ("contains", [ visited_key item current_input; visited ])
                        ; Const "true"
                        ] )))
            ; EqCondition
                (MatchCond (transitive_candidate_pattern item witness, candidates))
            ; RewriteCond
                (loop_call item left_input candidates next_visited, rhs)
            ; RewriteCond
                (loop_call item right_input candidates next_visited, rhs)
            ]
          |> Condition_closure.normalize_rule_conditions [ lhs ]
          |> dedup_rule_conditions
        in
        let admissibility_diags =
          Condition_closure.crl_admissibility_diagnostics
            ctx
            origin
            lhs
            rhs
            conditions
        in
        if List.exists Diagnostics.is_fatal (head_diags @ admissibility_diags) then
          Error (head_diags @ admissibility_diags)
        else
          Ok
            (generated
               item.name
               origin
               (crl
                  ~label:(item.name ^ "-finite-transitive")
                  lhs
                  rhs
                  conditions))))

let lower_finite_transitive_item ctx item domain =
  match Runtime_witness_domain.prepare domain with
  | Error blockers ->
    let reason =
      blockers
      |> List.map (fun blocker -> blocker.Runtime_witness_domain.reason)
      |> String.concat "; "
    in
    let suggestion =
      blockers
      |> List.map (fun blocker -> blocker.Runtime_witness_domain.suggestion)
      |> String.concat "; "
    in
    { statements = []
    ; diagnostics =
        [ unsupported
            ctx
            item
            item.origin
            "RuntimeTruthSearch/materializer/finite-domain-blocked"
            reason
            suggestion
        ]
    }
  | Ok plan ->
    let transitive_rule = domain.Runtime_witness_proof.transitive.rule in
    let base_rules =
      local_rules item
      |> List.filter (fun rule -> not (same_source_rule transitive_rule rule))
    in
    let base_result =
      match base_rules with
      | [] ->
        { statements = []
        ; diagnostics =
            [ unsupported
                ctx
                item
                item.origin
                "RuntimeTruthSearch/materializer/finite-transitive/no-base-rules"
                ("finite-transitive truth helper for `"
                 ^ item.request.rel_id
                 ^ "` has no non-recursive source RuleD clauses to materialize")
                "Keep this helper Unsupported until the source relation exposes at least one non-transitive rule or a domain-derived base case"
            ]
        }
      | _ ->
        lower_rules_with_surface
          ctx
          item
          (loop_rule_surface item)
          (finite_helper_surface ctx item plan base_rules)
          base_rules
    in
    if List.exists Diagnostics.is_fatal base_result.diagnostics then
      base_result
    else
      let transitive_result = lower_transitive_step ctx item domain in
      (match transitive_result with
      | Error transitive_diagnostics ->
        { statements = []
        ; diagnostics = base_result.diagnostics @ transitive_diagnostics
        }
      | Ok transitive_statement ->
        { statements = base_result.statements @ [ transitive_statement ]
        ; diagnostics = base_result.diagnostics
        })

let lower_seed_rule_with_surface
    ctx
    item
    target
    surface
    index
    (rule : Analysis.Function_graph.runtime_search_rule)
  =
  let origin = rule_origin item.origin index rule in
  match
    Analysis.Relation_graph.exp_components_for_count
      (List.length item.request.input_sorts)
      rule.head
  with
  | None ->
    Error
      [ unsupported
          ctx
          item
          origin
          "RuntimeTruthSearch/materializer/target-guided/seed-head-arity"
          "source RuleD head does not match the requested relation arity without flattening"
          "Preserve the source relation component structure before emitting a target-guided seed rule"
      ]
  | Some components ->
    match split_exps target.Runtime_witness_proof.prefix_arity components with
    | None ->
      Error
        [ unsupported
            ctx
            item
            origin
            "RuntimeTruthSearch/materializer/target-guided/seed-input-shape"
            "source RuleD head is not prefix plus left endpoint plus witness endpoint"
            "Keep this helper Unsupported until the IL relation head has the proven R(prefix, left, witness) shape"
        ]
    | Some (_left_exp, _right_exp) ->
      let seed_count = List.length item.request.input_sorts - 1 in
      let rec take n acc rest =
        if n = 0 then Some (List.rev acc, rest)
        else
          match rest with
          | [] -> None
          | exp :: rest -> take (n - 1) (exp :: acc) rest
      in
      match take seed_count [] components with
      | Some (seed_exps, [ witness_exp ]) ->
        let terms_opt, env, _indexed_heads, head_guards, head_diags =
          lower_patterns ctx origin seed_exps
        in
        (match terms_opt with
        | None -> Error head_diags
        | Some seed_terms ->
          let witness_origin =
            child_origin
              origin
              "target-guided-seed-witness"
              "RuntimeTruthSearch/Witness"
              witness_exp.at
              (Some (Il.Print.string_of_exp witness_exp))
          in
          let witness_result =
            Expr_translate.lower_pattern_with_bindings
              ctx
              env
              witness_origin
              witness_exp
          in
          (match witness_result.pattern_term with
          | Some witness_term ->
          let premise_env =
            List.fold_left add_binding env witness_result.introduced_bindings
          in
          let premise_result =
            Premise_translate.translate_premises
              ~allow_runtime_search:true
              ctx
              premise_env
              ~bound_conditions:head_guards
              ~escape_source_ids:[]
              ~bound_terms:seed_terms
              origin
              rule.prems
          in
          let diagnostics =
            head_diags
            @ witness_result.pattern_diagnostics
            @ premise_result.diagnostics
          in
          if premise_result.has_else then
            Error
              (diagnostics
               @ [ unsupported
                     ctx
                     item
                     origin
                     "RuntimeTruthSearch/materializer/target-guided/seed-ElsePr"
                     "target-guided seed rule contains ElsePr, which needs a source-derived enabledness complement"
                     "Keep this truth helper Unsupported until otherwise complement lowering exists for this source shape"
                 ])
          else if List.exists Diagnostics.is_fatal diagnostics then
            Error diagnostics
          else
            let lhs = App (surface.search_op, seed_terms) in
            let rhs = App (surface.ok_op, [ witness_term ]) in
            let before_eq_conditions =
              List.map (fun condition -> EqCondition condition) head_guards
              @ premise_result.rule_conditions
            in
            let eq_conditions =
              witness_binding_equalities
                seed_terms
                before_eq_conditions
                [ witness_term ]
                premise_result.eq_conditions
            in
            let conditions =
              before_eq_conditions
              @ List.map
                  (fun condition -> EqCondition condition)
                  eq_conditions
              @ List.map
                  (fun condition -> EqCondition condition)
                  witness_result.pattern_guards
              |> Condition_closure.normalize_rule_conditions [ lhs ]
              |> dedup_rule_conditions
            in
            let admissibility_diags =
              Condition_closure.crl_admissibility_diagnostics
                ctx
                origin
                lhs
                rhs
                conditions
            in
            if List.exists Diagnostics.is_fatal admissibility_diags then
              Error (diagnostics @ admissibility_diags)
            else
              Ok
                (generated
                   item.name
                   origin
                   (crl ?label:(rule_label item rule index) lhs rhs conditions))
          | None ->
          Error
            (witness_result.pattern_diagnostics
             @ [ unsupported
                ctx
                item
                witness_origin
                "RuntimeTruthSearch/materializer/target-guided/seed-witness-shape"
                "target-guided seed witness component did not lower to exactly one Maude pattern term"
                "Keep this helper Unsupported until the source witness component has a single carrier pattern"
            ])))
      | Some _ | None ->
        Error
          [ unsupported
              ctx
              item
              origin
              "RuntimeTruthSearch/materializer/target-guided/seed-witness-shape"
              "target-guided seed rule head did not split into seed input components plus one witness component"
              "Keep this helper Unsupported until the source head has the expected seed/witness shape"
          ]

let lower_target_guided_rule ctx item target runtime_rule =
  match lower_target_rule_head ctx item target runtime_rule with
  | Error diagnostics -> Error diagnostics
  | Ok (origin, input_terms, prefix, left, _right, witness, env, head_guards, head_diags) ->
    let premise_result =
      Premise_translate.translate_premises
        ~allow_runtime_search:true
        ctx
        env
        ~bound_conditions:head_guards
        ~escape_source_ids:[]
        ~bound_terms:(input_terms @ [ witness ])
        origin
        (target.Runtime_witness_proof.guard_premises
         @ [ target.Runtime_witness_proof.target_premise ])
    in
    let diagnostics = head_diags @ premise_result.diagnostics in
    if premise_result.has_else then
      Error
        (diagnostics
         @ [ unsupported
               ctx
               item
               origin
               "RuntimeTruthSearch/materializer/target-guided/ElsePr"
               "target-guided source rule contains ElsePr, which needs a source-derived enabledness complement"
               "Keep this truth helper Unsupported until otherwise complement lowering exists for this source shape"
           ])
    else if List.exists Diagnostics.is_fatal diagnostics then
      Error diagnostics
    else
      let seed_lhs = App (seed_search_op item.name, prefix @ [ left ]) in
      let seed_rhs = App (seed_hit_op item.name, [ witness ]) in
      let lhs =
        App
          ( Runtime_truth_search_helper.search_op ~helper_name:item.name
          , input_terms )
      in
      let rhs =
        Const (Runtime_truth_search_helper.ok_op ~helper_name:item.name)
      in
      let conditions =
        RewriteCond (seed_lhs, seed_rhs)
        :: (List.map (fun condition -> EqCondition condition) head_guards
            @ premise_result.rule_conditions
            @ List.map
                (fun condition -> EqCondition condition)
                premise_result.eq_conditions)
        |> Condition_closure.normalize_rule_conditions [ lhs ]
        |> dedup_rule_conditions
      in
      let admissibility_diags =
        Condition_closure.crl_admissibility_diagnostics
          ctx
          origin
          lhs
          rhs
          conditions
      in
      if List.exists Diagnostics.is_fatal admissibility_diags then
        Error (diagnostics @ admissibility_diags)
      else
        Ok
          (generated
             item.name
             origin
             (crl
                ~label:(item.name ^ "-target-guided")
                lhs
                rhs
                conditions))

let lower_target_guided_item ctx item target =
  match find_runtime_rule target.Runtime_witness_proof.rule item.request.rules with
  | None ->
    { statements = []
    ; diagnostics =
        [ unsupported
            ctx
            item
            item.origin
            "RuntimeTruthSearch/materializer/target-guided/source-rule"
            "target-guided proof source rule is not present in the runtime-search rule set"
            "Keep this helper Unsupported until proof and materializer rule sets are aligned"
        ]
    }
  | Some runtime_rule ->
    let seed_rules =
      local_rules item
      |> List.filter (fun rule ->
        not
          (same_source_rule target.Runtime_witness_proof.rule rule
           || is_target_guided_source_rule target rule))
    in
    let surface = seed_rule_surface item in
    let rec lower_seed_rules index statements diagnostics = function
      | [] ->
        if List.exists Diagnostics.is_fatal diagnostics then
          { statements = []; diagnostics }
        else
          { statements = List.rev statements; diagnostics }
      | rule :: rules ->
        (match lower_seed_rule_with_surface ctx item target surface index rule with
        | Ok statement ->
          lower_seed_rules (index + 1) (statement :: statements) diagnostics rules
        | Error new_diagnostics ->
          lower_seed_rules
            (index + 1)
            statements
            (diagnostics @ new_diagnostics)
            rules)
    in
    let seed_result = lower_seed_rules 1 [] [] seed_rules in
    if List.exists Diagnostics.is_fatal seed_result.diagnostics then
      seed_result
    else
      match lower_target_guided_rule ctx item target runtime_rule with
      | Error diagnostics ->
        { statements = []; diagnostics = seed_result.diagnostics @ diagnostics }
      | Ok target_statement ->
        { statements =
            target_guided_helper_surface item target
            @ seed_result.statements
            @ [ target_statement ]
        ; diagnostics = seed_result.diagnostics
        }

let materialize_item ctx item =
  match item.request.recursion with
  | Runtime_truth_search_helper.Acyclic -> lower_acyclic_item ctx item
  | Runtime_truth_search_helper.Finite_transitive domain ->
    lower_finite_transitive_item ctx item domain
  | Runtime_truth_search_helper.Target_guided_self target ->
    lower_target_guided_item ctx item target
  | Runtime_truth_search_helper.Recursive cycle ->
    { statements = []
    ; diagnostics =
        [ unsupported
            ctx
            item
            item.origin
            "RuntimeTruthSearch/materializer/recursive-unimplemented"
            ("runtime truth-search closure contains recursive predicate dependency cycle `"
             ^ String.concat " -> " cycle
             ^ "`; this materializer currently emits only acyclic source-complete truth helpers")
            "Implement finite-domain fuel/visited materialization before emitting recursive runtime truth-search helpers"
        ]
    }

let materialize ctx items =
  let results = List.map (materialize_item ctx) items in
  { statements = List.concat_map (fun result -> result.statements) results
  ; diagnostics = List.concat_map (fun result -> result.diagnostics) results
  }
