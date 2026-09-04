open Util.Source
open Il.Ast
open Maude_il


let component_types typ =
  match typ.it with
  | TupT fields -> List.map snd fields
  | _ -> [typ]

let output_sort index = function
  | [typ] -> Term.translate_sort index typ
  | _ :: _ :: _ -> "SpectecTerminal"
  | [] -> invalid_arg "relation policy has no output component"

let translate_inputs index params inputs =
  let bound = Il.Free.(bound_params params).varid in
  let step (terms, conditions, bound) (position, exp) =
    match Prem.translate_pattern_parts index exp with
    | Some (term, guards) ->
        ( term :: terms
        , conditions @ List.map (fun guard -> EqCondition guard) guards
        , Prem.bind bound exp
        )
    | None ->
        let subject =
          Var
            (generated_variable
               ("REL-INPUT" ^ string_of_int (position + 1))
               (Term.translate_sort index exp.note))
        in
        let binding =
          Prem.bind_pattern index bound exp subject
            "relation input is not a structural pattern"
        in
        subject :: terms, conditions @ binding.conditions, binding.bound
  in
  List.mapi (fun position exp -> position, exp) inputs
  |> List.fold_left step ([], [], bound)
  |> fun (terms, conditions, bound) ->
       List.rev terms, conditions, bound

let has_else prems =
  let found = ref false in
  let module Visitor = Il.Iter.Make (struct
    include Il.Iter.Skip
    let visit_prem prem =
      match prem.it with ElsePr -> found := true | _ -> ()
  end)
  in
  Visitor.list Visitor.prem prems;
  !found

let add_variable variables variable =
  if List.exists (same_variable variable) variables then variables
  else variable :: variables

let rec term_variables variables = function
  | Var variable -> add_variable variables variable
  | Const _ -> variables
  | App (_, args) -> List.fold_left term_variables variables args

let variables_bound bound term =
  term_variables [] term
  |> List.for_all (fun variable -> List.exists (same_variable variable) bound)

let condition_ready bound = function
  | EqCondition (EqCond (left, right)) ->
      variables_bound bound left && variables_bound bound right
  | EqCondition (MatchCond (_, subject)) ->
      variables_bound bound subject
  | EqCondition (MembershipCond (term, _))
  | EqCondition (BoolCond term) ->
      variables_bound bound term
  | RewriteCond (call, _) ->
      variables_bound bound call

let take_ready select bound conditions =
  let rec take prefix = function
    | [] -> None
    | condition :: rest when select condition && condition_ready bound condition ->
        Some (condition, List.rev_append prefix rest)
    | condition :: rest -> take (condition :: prefix) rest
  in
  take [] conditions

let normalize_conditions left conditions =
  let rec normalize bound normalized pending =
    match pending with
    | [] -> List.rev normalized
    | _ ->
        let selected =
          match
            take_ready
              (function EqCondition _ -> true | RewriteCond _ -> false)
              bound pending
          with
          | Some selected -> Some selected
          | None -> take_ready (fun _ -> true) bound pending
        in
        begin match selected with
        | None -> invalid_arg "rule conditions have unresolved dependencies"
        | Some (condition, pending) ->
            begin match condition with
            | EqCondition (MatchCond (pattern, subject))
              when variables_bound bound pattern ->
                normalize bound
                  (EqCondition (EqCond (pattern, subject)) :: normalized)
                  pending
            | EqCondition (MatchCond (pattern, _))
            | RewriteCond (_, pattern) ->
                normalize (term_variables bound pattern)
                  (condition :: normalized) pending
            | EqCondition (EqCond _ | MembershipCond _ | BoolCond _) ->
                normalize bound (condition :: normalized) pending
            end
        end
  in
  normalize (term_variables [] left) [] conditions

let eq_conditions conditions =
  List.map
    (function
      | EqCondition condition -> condition
      | RewriteCond _ ->
          invalid_arg "an equation relation cannot use a rewrite condition")
    conditions

type rule_body =
  { input_terms : term list
  ; head_conditions : rule_condition list
  ; left : term
  ; right : term
  ; conditions : rule_condition list
  ; otherwise : bool
  }

let lower_rule_body ?request_output index id params policy rule =
  match rule.it with
  | RuleD (_, quants, mixop, exp, prems) ->
      let exps = Prem.components mixop exp in
      let inputs, outputs =
        match policy with
        | Prescan.Execution {input_count; _}
        | Prescan.Equation {input_count} -> Prem.split input_count exps
        | Prescan.Predicate | Prescan.BackendCheck ->
            exps, []
        | Prescan.BackendCompute {input_count} ->
            Prem.split input_count exps
      in
      let input_terms, head_conditions, bound =
        translate_inputs index params inputs
      in
      if not (List.for_all (Prem.known bound) inputs) then
        invalid_arg "relation rule has an unbound input";
      let left =
        App
          ( Prescan.rel_name index id
          , Param.translate_terms index params @ input_terms
          )
      in
      let premises =
        Prem.translate_all index
          ~bound:(Il.Free.Set.elements bound)
          ~bind_membership:(match policy with Prescan.Execution _ -> true | _ -> false)
          ?request_output
          prems
      in
      if not (List.for_all (Prem.known premises.bound) outputs) then
        invalid_arg "relation output contains an unbound variable";
      (* Reachable relation calls establish direct inputs and premise results. *)
      let proven = premises.bound in
      let conditions =
        head_conditions @ premises.conditions
        @ List.map
            (fun condition -> EqCondition condition)
            (Param.translate_eq_conditions ~proven index quants)
        |> normalize_conditions left
      in
      { input_terms
      ; head_conditions
      ; left
      ; right =
          Prem.tuple index outputs
            (List.map (Term.translate_exp index) outputs)
      ; conditions
      ; otherwise = premises.otherwise
      }

let translate_rule ?request_output index id params policy rule =
  let body = lower_rule_body ?request_output index id params policy rule in
  if body.otherwise then
    invalid_arg "ElsePr in a relation rule requires source complement lowering";
  match policy with
  | Prescan.Execution _ ->
      invalid_arg "execution relations require source-order lowering"
  | Prescan.Equation _ ->
      begin match eq_conditions body.conditions with
      | [] -> Eq (body.left, body.right, [])
      | conditions -> Ceq (body.left, body.right, conditions, [])
      end
  | Prescan.Predicate ->
      begin match eq_conditions body.conditions with
      | [] -> Eq (body.left, Const "true", [])
      | conditions -> Ceq (body.left, Const "true", conditions, [])
      end
  | Prescan.BackendCheck | Prescan.BackendCompute _ ->
      invalid_arg "manual relation rules are supplied by a Maude backend"

type execution_rule =
  { ordinal : int
  ; inputs : term list
  ; input_shapes : term list
  ; left : term
  ; right : term
  ; conditions : rule_condition list
  ; predecessors : int list
  }

let input_shapes conditions inputs =
  let binding variable =
    List.find_map
      (function
        | EqCondition (MatchCond (pattern, Var subject))
          when same_variable variable subject -> Some pattern
        | EqCondition _ | RewriteCond _ -> None)
      conditions
  in
  let rec expand seen = function
    | Var variable as term ->
        if List.exists (same_variable variable) seen then term
        else
          begin match binding variable with
          | Some pattern -> expand (variable :: seen) pattern
          | None -> term
          end
    | Const _ as term -> term
    | App (name, args) -> App (name, List.map (expand seen) args)
  in
  List.map (expand []) inputs

let rec may_overlap left right =
  match left, right with
  | Var _, _ | _, Var _ -> true
  | Const left, Const right -> left = right
  | App (left, left_args), App (right, right_args) ->
      left = right
      && List.length left_args = List.length right_args
      && List.for_all2 may_overlap left_args right_args
  | Const _, App _ | App _, Const _ -> false

let inputs_may_overlap left right =
  List.length left = List.length right
  && List.for_all2 may_overlap left right

let helper_call index id params ordinal inputs =
  App
    ( Prescan.relation_enabled_helper index id ordinal
    , Param.translate_terms index params @ inputs
    )

let complement_conditions index id params inputs predecessors =
  List.map
    (fun predecessor ->
      EqCondition
        (EqCond
           ( helper_call index id params predecessor.ordinal inputs
           , Const "false"
           )))
    predecessors

let lower_execution_rule ?request_output index id params policy
    previous ordinal rule =
  let prems =
    match rule.it with RuleD (_, _, _, _, prems) -> prems
  in
  begin match prems with
  | {it = ElsePr; _} :: prems when not (has_else prems) -> ()
  | _ when has_else prems ->
      invalid_arg "execution relation requires exactly one leading ElsePr"
  | _ -> ()
  end;
  let body = lower_rule_body ?request_output index id params policy rule in
  let input_shapes = input_shapes body.head_conditions body.input_terms in
  let predecessors =
    if body.otherwise then
      List.filter
        (fun predecessor ->
          inputs_may_overlap input_shapes predecessor.input_shapes)
        previous
    else []
  in
  if body.otherwise && predecessors = [] then
    invalid_arg "otherwise execution rule has no matching predecessor";
  { ordinal
  ; inputs = body.input_terms
  ; input_shapes
  ; left = body.left
  ; right = body.right
  ; conditions =
      complement_conditions index id params body.input_terms predecessors
      @ body.conditions
  ; predecessors = List.map (fun rule -> rule.ordinal) predecessors
  }

let execution_statement rule =
  match rule.conditions with
  | [] -> Rl (None, rule.left, rule.right)
  | conditions -> Crl (None, rule.left, rule.right, conditions)

let helper_conditions id rule =
  rule.conditions
  |> List.map
       (function
         | EqCondition condition -> condition
         | RewriteCond _ ->
             invalid_arg
               (Printf.sprintf
                  "otherwise predecessor in relation %s rule %d uses a rewrite condition"
                  id.it (rule.ordinal + 1)))

let helper_statements index id params input_sorts rule =
  let name = Prescan.relation_enabled_helper index id rule.ordinal in
  let parameter_sorts = Param.translate_sorts index params in
  let domain = parameter_sorts @ input_sorts in
  let declaration =
    OpDecl
      { name
      ; domain
      ; codomain = "Bool"
      ; arrow = Total
      ; attrs = frozen_all (List.length domain)
      }
  in
  let helper_inputs =
    List.mapi
      (fun position sort ->
        Var
          (generated_variable
             ("ENABLED-INPUT" ^ string_of_int (position + 1)) sort))
      input_sorts
  in
  let left =
    App (name, Param.translate_terms index params @ helper_inputs)
  in
  let conditions =
    List.map2
      (fun pattern subject -> MatchCond (pattern, subject))
      rule.inputs helper_inputs
    @ helper_conditions id rule
  in
  let enabled =
    match conditions with
    | [] -> Eq (left, Const "true", [])
    | conditions -> Ceq (left, Const "true", conditions, [])
  in
  [ declaration
  ; enabled
  ; Eq (left, Const "false", [Owise])
  ]

let lower_execution_rules ?request_output ?(include_rule = fun _ -> true)
    index id params policy rules =
  rules
  |> List.mapi (fun ordinal rule -> ordinal, rule)
  |> List.filter (fun (_, rule) -> include_rule rule)
  |> List.fold_left
       (fun previous (ordinal, rule) ->
         let lowered =
           lower_execution_rule ?request_output index id params policy
             (List.rev previous) ordinal rule
         in
         lowered :: previous)
       []
  |> List.rev

let translate_execution ?request_output ?include_rule
    index id params typ policy rules =
  let input_count =
    match policy with
    | Prescan.Execution {input_count; _} -> input_count
    | Prescan.Equation _ | Prescan.Predicate | Prescan.BackendCheck
    | Prescan.BackendCompute _ ->
        invalid_arg "expected an execution relation policy"
  in
  let lowered =
    lower_execution_rules ?request_output ?include_rule
      index id params policy rules
  in
  let referenced =
    lowered
    |> List.concat_map (fun rule -> rule.predecessors)
    |> List.sort_uniq compare
  in
  let input_sorts =
    component_types typ
    |> Prem.split input_count
    |> fst
    |> List.map (Term.translate_sort index)
  in
  let helpers =
    lowered
    |> List.filter (fun rule -> List.mem rule.ordinal referenced)
    |> List.concat_map (helper_statements index id params input_sorts)
  in
  helpers @ List.map execution_statement lowered

let translate_decl index id params typ policy =
  let types = component_types typ in
  let parameter_sorts = Param.translate_sorts index params in
  match policy with
  | Prescan.Execution {request_sort; input_count} ->
      let inputs, outputs = Prem.split input_count types in
      let result_sort = output_sort index outputs in
      [ SortDecl request_sort
      ; SubsortDecl (result_sort, request_sort)
      ; OpDecl
          { name = Prescan.rel_name index id
          ; domain = parameter_sorts @ List.map (Term.translate_sort index) inputs
          ; codomain = request_sort
          ; arrow = Total
          ; attrs = frozen_all (List.length params + List.length inputs)
          }
      ]
  | Prescan.Equation {input_count} ->
      let inputs, outputs = Prem.split input_count types in
      [ OpDecl
          { name = Prescan.rel_name index id
          ; domain = parameter_sorts @ List.map (Term.translate_sort index) inputs
          ; codomain = output_sort index outputs
          ; arrow = Partial
          ; attrs = []
          }
      ]
  | Prescan.Predicate ->
      [ OpDecl
          { name = Prescan.rel_name index id
          ; domain = parameter_sorts @ List.map (Term.translate_sort index) types
          ; codomain = "Bool"
          ; arrow = Partial
          ; attrs = []
          }
      ]
  | Prescan.BackendCheck ->
      [ OpDecl
          { name = Prescan.rel_name index id
          ; domain = parameter_sorts @ List.map (Term.translate_sort index) types
          ; codomain = "Bool"
          ; arrow = Total
          ; attrs = []
          }
      ]
  | Prescan.BackendCompute {input_count} ->
      let inputs, outputs = Prem.split input_count types in
      [ OpDecl
          { name = Prescan.rel_name index id
          ; domain = parameter_sorts @ List.map (Term.translate_sort index) inputs
          ; codomain = output_sort index outputs
          ; arrow = Partial
          ; attrs = []
          }
      ]

let translate ?request_output ?include_rule index id params _mixop typ rules =
  match Prescan.relation_policy index id with
  | Error _ -> []
  | Ok policy ->
      let declarations = translate_decl index id params typ policy in
      match policy with
      | Prescan.BackendCheck | Prescan.BackendCompute _ -> declarations
      | Prescan.Execution _ ->
          declarations
          @ translate_execution ?request_output ?include_rule index id params typ
              policy rules
      | Prescan.Equation _ | Prescan.Predicate ->
          declarations
          @ List.map
              (translate_rule ?request_output index id params policy)
              rules

(* maude_context is a RuleD lowering mode. Hintd supplies the validated
 * relation shape; this private module constructs identify-focus, heating,
 * and cooling statements. *)
module Context_rules = struct
  let unsupported at reason =
    Util.Error.error at "translation" ("Unsupported: maude_context " ^ reason)

  let op ?(arrow = Total) ?(attrs = []) name domain codomain =
    OpDecl {name; domain; codomain; arrow; attrs}

  let variable index name typ =
    Var (generated_variable name (Term.translate_sort index typ))

  let rule_id rule =
    let Il.Ast.RuleD (id, _, _, _, _) = rule.it in
    id

  let rec equal_term left right =
    match left, right with
    | Var left, Var right -> same_variable left right
    | Const left, Const right -> left = right
    | App (left, left_args), App (right, right_args) ->
        left = right
        && List.length left_args = List.length right_args
        && List.for_all2 equal_term left_args right_args
    | Var _, (Const _ | App _) | Const _, (Var _ | App _)
    | App _, (Var _ | Const _) -> false

  let rec occurs variable = function
    | Var candidate -> same_variable variable candidate
    | Const _ -> false
    | App (_, args) -> List.exists (occurs variable) args

  let rec substitute bindings = function
    | Var variable as term ->
        begin match
          List.find_opt (fun (bound, _) -> same_variable variable bound) bindings
        with
        | Some (_, replacement) -> substitute bindings replacement
        | None -> term
        end
    | Const _ as term -> term
    | App (name, args) -> App (name, List.map (substitute bindings) args)

  let bind at bindings variable term =
    match
      List.find_opt (fun (bound, _) -> same_variable variable bound) bindings
    with
    | Some (_, previous) when equal_term (substitute bindings previous) term ->
        bindings
    | Some _ -> unsupported at "bridge input patterns do not unify"
    | None when equal_term (Var variable) term -> bindings
    | None when occurs variable term -> unsupported at "bridge unification is cyclic"
    | None -> (variable, term) :: bindings

  let rec unify at bindings pattern subject =
    match substitute bindings pattern, subject with
    | Var variable, term -> bind at bindings variable term
    | Const left, Const right when left = right -> bindings
    | App (left, left_args), App (right, right_args)
      when left = right && List.length left_args = List.length right_args ->
        List.fold_left2 (unify at) bindings left_args right_args
    | _ -> unsupported at "bridge input does not match the delegated relation"

  let substitute_condition bindings = function
    | EqCondition (EqCond (left, right)) ->
        EqCondition (EqCond (substitute bindings left, substitute bindings right))
    | EqCondition (MatchCond (left, right)) ->
        EqCondition (MatchCond (substitute bindings left, substitute bindings right))
    | EqCondition (MembershipCond (term, sort)) ->
        EqCondition (MembershipCond (substitute bindings term, sort))
    | EqCondition (BoolCond term) ->
        EqCondition (BoolCond (substitute bindings term))
    | RewriteCond (left, right) ->
        RewriteCond (substitute bindings left, substitute bindings right)

  let freshen left conditions =
    let variables = ref [] in
    let fresh variable =
      match
        List.find_opt
          (fun (source, _) -> same_variable variable source) !variables
      with
      | Some (_, target) -> target
      | None ->
          let target = generated_variable ("BRIDGE-" ^ variable.name) variable.sort in
          variables := (variable, target) :: !variables;
          target
    in
    ( map_term_variables fresh left
    , List.map (map_rule_condition_variables fresh) conditions
    )

  let call_name = function
    | App (name, _) -> Some name
    | Var _ | Const _ -> None

  let delegated_condition at target conditions =
    let delegated, remaining =
      List.partition
        (function
          | RewriteCond (call, _) -> call_name call = Some target
          | EqCondition _ -> false)
        conditions
    in
    match delegated with
    | [RewriteCond (call, result)] -> (call, result), remaining
    | [] -> unsupported at "bridge has no delegated execution premise"
    | _ -> unsupported at "bridge has more than one delegated execution premise"

  let execution_policy index relation =
    match Prescan.relation_policy index relation with
    | Ok (Prescan.Execution _ as policy) -> policy
    | Ok (Prescan.Equation _ | Prescan.Predicate | Prescan.BackendCheck
         | Prescan.BackendCompute _)
    | Error _ -> unsupported relation.at
        "focus pattern refers to a non-execution relation"

  let relation_call index (source : Hintd.relation) inputs =
    App
      ( Prescan.rel_name index source.id
      , Param.translate_terms index source.params @ inputs
      )

  let lower_relation cache request_output index (source : Hintd.relation) =
    match Hashtbl.find_opt cache source.id.it with
    | Some rules -> rules
    | None ->
        let policy = execution_policy index source.id in
        let rules =
          lower_execution_rules ~request_output
            ~include_rule:(fun rule ->
              not (Prescan.is_context_rule index source.id rule))
            index source.id source.params policy source.rules
        in
        Hashtbl.add cache source.id.it rules;
        rules

  let lowered_rule cache request_output index source ordinal at =
    match
      lower_relation cache request_output index source
      |> List.find_opt (fun rule -> rule.ordinal = ordinal)
    with
    | Some rule -> rule
    | None -> unsupported at "focus pattern has an invalid source-rule ordinal"

  let shaped_relation_call index (pattern : Hintd.focus_pattern) lowered =
    let bindings =
      List.map2
        (fun input shape ->
          match input with
          | Var variable when not (equal_term input shape) -> Some (variable, shape)
          | Var _ | Const _ | App _ -> None)
        lowered.inputs lowered.input_shapes
      |> List.filter_map Fun.id
    in
    let call = relation_call index pattern.source lowered.input_shapes in
    let conditions =
      List.map (substitute_condition bindings) lowered.conditions
    in
    let conditions =
      match pattern.deferred_execution with
      | None -> conditions
      | Some relation ->
          (* Heating selects the wrapper; its ordinary execution rule discharges
             the recursive premise after the wrapper becomes the focus. *)
          let target = Prescan.rel_name index relation in
          delegated_condition pattern.rule.at target conditions |> snd
    in
    call, conditions

  let lift_bridge cache request_output index (call, conditions)
      (bridge : Hintd.bridge) =
    let lowered =
      lowered_rule cache request_output index bridge.Hintd.source
        bridge.ordinal bridge.rule.at
    in
    let outer, bridge_conditions = freshen lowered.left lowered.conditions in
    let target =
      match call_name call with
      | Some target -> target
      | None -> unsupported bridge.rule.at "delegated relation is not a call"
    in
    let (delegated, _), bridge_conditions =
      delegated_condition bridge.premise.at target bridge_conditions
    in
    let bindings = unify bridge.premise.at [] delegated call in
    ( substitute bindings outer
    , List.map (substitute_condition bindings) bridge_conditions @ conditions
    )

  let outer_call cache request_output index (pattern : Hintd.focus_pattern) =
    let lowered =
      lowered_rule cache request_output index pattern.Hintd.source
        pattern.ordinal pattern.rule.at
    in
    let call, conditions = shaped_relation_call index pattern lowered in
    List.fold_left
      (lift_bridge cache request_output index)
      (call, conditions)
      (List.rev pattern.bridges)

  let rec drop count values =
    match count, values with
    | 0, values -> values
    | count, _ :: values -> drop (count - 1) values
    | _, [] -> []

  let relation_input index (context : Hintd.context) call =
    let relation = Prescan.rel_name index context.Hintd.source.id in
    let parameter_count = List.length context.source.params in
    match call with
    | App (name, args) when name = relation ->
        begin match drop parameter_count args with
        | [input] -> input
        | _ -> unsupported context.rule.at
            "identifyFocus currently requires one context-relation input"
        end
    | Var _ | Const _ | App _ -> unsupported context.rule.at
        "bridge chain does not end at the hinted context relation"

  let replace position replacement values =
    List.mapi (fun index value -> if index = position then replacement else value)
      values

  let split_config index (frame : Hintd.frame) config at =
    let constructor = Prescan.mixop_name index frame.Hintd.mixop in
    match config with
    | App (name, components) when name = constructor && List.length components = 2 ->
        let sequence = List.nth components frame.sequence_position in
        let state = List.nth components (1 - frame.sequence_position) in
        state, sequence, (fun replacement ->
          App (name, replace frame.sequence_position replacement components))
    | Var _ | Const _ | App _ -> unsupported at
        "focused input does not match its state/sequence configuration"

  let rec flatten operator = function
    | App (name, args) when name = operator -> List.concat_map (flatten operator) args
    | term -> [term]

  let split_at at count values =
    let rec split count prefix = function
      | values when count = 0 -> List.rev prefix, values
      | value :: values -> split (count - 1) (value :: prefix) values
      | [] -> unsupported at "lowered focus has fewer terms than its source pattern"
    in
    split count [] values

  let focus_parts index (context : Hintd.context)
      (pattern : Hintd.focus_pattern) sequence =
    let representation = Prescan.sequence_representation index context.Hintd.focus_typ in
    let parts = flatten representation.concat sequence in
    let operands, rest = split_at pattern.rule.at (List.length pattern.operands) parts in
    match rest with
    | trigger :: trailing when List.length trailing = List.length pattern.trailing ->
        operands, trigger, trailing
    | _ -> unsupported pattern.rule.at
        "lowered focus does not preserve the extracted source-pattern boundary"

  let focus_label index (pattern : Hintd.focus_pattern) =
    let relation = Prescan.rel_name index pattern.Hintd.source.id in
    let rule = (rule_id pattern.rule).it |> Prescan.sanitize in
    "focus-" ^ relation ^ "-" ^ rule

  let request_sort index (context : Hintd.context) =
    match execution_policy index context.source.id with
    | Prescan.Execution {request_sort; _} -> request_sort
    | Prescan.Equation _ | Prescan.Predicate | Prescan.BackendCheck
    | Prescan.BackendCompute _ -> unsupported context.rule.at
        "context relation has no execution-request sort"

  let declarations index (context : Hintd.context) =
    let prefix_sort = Term.translate_sort index context.Hintd.prefix_typ in
    let postfix_sort = Term.translate_sort index context.postfix_typ in
    let state_sort = Term.translate_sort index context.frame.state_typ in
    let config_sort = Term.translate_sort index context.frame.config_typ in
    let proper_sort = context.Hintd.proper_sort in
    let request_sort = request_sort index context in
    [ SortDecl "FocusSearch"
    ; SortDecl "FocusTarget"
    ; SortDecl "Hole"
    ; SubsortDecl ("FocusTarget", "FocusSearch")
    ; op ~arrow:Partial ~attrs:(frozen_all 4) "identifyFocus"
        [state_sort; prefix_sort; proper_sort; postfix_sort] "FocusSearch"
    ; op ~attrs:[Ctor] "{_|_|_}"
        [prefix_sort; config_sort; postfix_sort] "FocusTarget"
    ; op ~attrs:[Ctor] "hole" [prefix_sort; postfix_sort] "Hole"
    ; op ~attrs:[Frozen [2]] "_~>_" [request_sort; "Hole"] request_sort
    ]

  let translate_pattern cache request_output index (context : Hintd.context)
      (pattern : Hintd.focus_pattern) =
    let call, conditions = outer_call cache request_output index pattern in
    let config = relation_input index context call in
    let state, focus, rebuild =
      split_config index context.Hintd.frame config pattern.rule.at
    in
    let operands, trigger, trailing = focus_parts index context pattern focus in
    let prefix = variable index "PREFIX" context.prefix_typ in
    let postfix = variable index "POSTFIX" context.postfix_typ in
    let stack =
      Term.sequence_of_typ index context.prefix_typ (prefix :: operands)
    in
    let rest =
      Term.sequence_of_typ index context.postfix_typ (trailing @ [postfix])
    in
    let left = App ("identifyFocus", [state; stack; trigger; rest]) in
    let right = App ("{_|_|_}", [prefix; rebuild focus; postfix]) in
    let conditions = normalize_conditions left conditions in
    let label = Some (focus_label index pattern) in
    match conditions with
    | [] -> Rl (label, left, right)
    | _ -> Crl (label, left, right, conditions)

  let context_transitions request_output index (context : Hintd.context) =
    let policy = execution_policy index context.source.id in
    let lowered =
      lower_execution_rule ~request_output index context.source.id
        context.source.params policy [] context.ordinal context.rule
    in
    let inner_name = Prescan.rel_name index context.inner_relation in
    let (inner_call, inner_result), remaining =
      delegated_condition context.rule.at inner_name lowered.conditions
    in
    let config = relation_input index context lowered.left in
    let state, _, rebuild =
      split_config index context.frame config context.rule.at
    in
    let prefix_sort = Term.translate_sort index context.prefix_typ in
    let focus_sort = Term.translate_sort index context.focus_typ in
    let postfix_sort = Term.translate_sort index context.postfix_typ in
    let generated name sort = Var (generated_variable name sort) in
    let prefix = generated "PREFIX" prefix_sort in
    let focus = generated "FOCUS" focus_sort in
    let postfix = generated "POSTFIX" postfix_sort in
    let stack = generated "STACK" prefix_sort in
    let trigger = Var (generated_variable "OP" context.Hintd.proper_sort) in
    let rest = generated "REST" postfix_sort in
    let sequence =
      Term.sequence_of_typ index context.focus_typ [stack; trigger; rest]
    in
    let input = rebuild sequence in
    let heat_left = relation_call index context.source [input] in
    let target = App ("{_|_|_}", [prefix; rebuild focus; postfix]) in
    let identify =
      RewriteCond
        (App ("identifyFocus", [state; stack; trigger; rest]), target)
    in
    let bindings =
      [ Prescan.source_variable index context.prefix context.prefix_typ, prefix
      ; Prescan.source_variable index context.focus context.focus_typ, focus
      ; Prescan.source_variable index context.postfix context.postfix_typ, postfix
      ]
    in
    let conditions =
      identify :: List.map (substitute_condition bindings) remaining
      |> normalize_conditions heat_left
    in
    let heat_right =
      App
        ( "_~>_"
        , [ substitute bindings inner_call
          ; App ("hole", [prefix; postfix])
          ]
        )
    in
    let label =
      Some
        ("heating-"
         ^ ((rule_id context.rule).it |> Prescan.sanitize))
    in
    let heating = Crl (label, heat_left, heat_right, conditions) in
    let cooling =
      Eq
        ( App
            ( "_~>_"
            , [ substitute bindings inner_result
              ; App ("hole", [prefix; postfix])
              ]
            )
        , substitute bindings lowered.right
        , []
        )
    in
    [heating; cooling]

  let translate ?request_output index =
    let request_output = Option.value request_output ~default:(fun _ _ -> ()) in
    match Prescan.contexts index with
    | [] -> []
    | [context] ->
        let cache = Hashtbl.create 4 in
        declarations index context
        @ List.map
            (translate_pattern cache request_output index context)
            context.Hintd.patterns
        @ context_transitions request_output index context
    | context :: _ -> unsupported context.Hintd.rule.at
        "multiple maude_context rules are not yet supported"

end

let translate_contexts = Context_rules.translate
