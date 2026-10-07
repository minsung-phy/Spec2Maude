(* hint(k_heatcool): lowering of RuleD with execution premises.
 * Hintd supplies the validated relation shape; this module constructs the
 * identify-focus, heating, and cooling statements. *)

open Util.Source
open Il.Ast
open Maude_il

let unsupported at reason =
  Util.Error.error at "translation" ("Unsupported: k_heatcool " ^ reason)

let op ?(arrow = Total) ?(attrs = []) name domain codomain =
  OpDecl {name; domain; codomain; arrow; attrs}

let variable index name typ =
  Var (generated_variable name (Term.translate_sort index typ))

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
  | Some (_, previous) when Reld.same_term (substitute bindings previous) term ->
      bindings
  | Some _ -> unsupported at "bridge input patterns do not unify"
  | None when Reld.same_term (Var variable) term -> bindings
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
  | Ok (Prescan.Compute _ | Prescan.Check _)
  | Error _ -> unsupported relation.at
      "focus pattern refers to a non-execution relation"

let relation_call index (source : Hintd.relation) inputs =
  App
    ( Prescan.rel_name index source.id
    , Param.translate_terms index source.params @ inputs
    )

let lower_relation cache index (source : Hintd.relation) =
  match Hashtbl.find_opt cache source.id.it with
  | Some rules -> rules
  | None ->
      let policy = execution_policy index source.id in
      let rules =
        Reld.lower_execution_rules
          ~include_rule:(fun rule ->
            not (Prescan.is_context_rule index source.id rule))
          index source.id source.params policy source.rules
      in
      Hashtbl.add cache source.id.it rules;
      rules

let lowered_rule cache index source ordinal at =
  match
    lower_relation cache index source
    |> List.find_opt (fun rule -> rule.Reld.ordinal = ordinal)
  with
  | Some rule -> rule
  | None -> unsupported at "focus pattern has an invalid source-rule ordinal"

(* A candidate needs operand boundaries, not the result of executing them.
   Slice source premises before lowering; the ordinary RuleD is untouched. *)
let boundary_variables index exps =
  let names = ref Il.Free.Set.empty in
  let module Visitor = Il.Iter.Make (struct
    include Il.Iter.Skip
    let visit_exp exp =
      match exp.it with
      | IterE (_, (ListN (count, _), _)) ->
          names := Il.Free.Set.union !names (Prem.variables count)
      | _ -> ()
  end)
  in
  Visitor.list Visitor.exp exps;
  (* Unbounded sequence slots can change the focus extent without a ListN
     count. Keep their source guards, but not scalar operand branch tests. *)
  List.iter
    (fun exp ->
      let source =
        match exp.it, exp.note.it with
        | IterE (body, ((List, _) as iteration)), _ ->
            Iter.identity_source index body iteration
        | VarE _, IterT (_, List) -> Some exp
        | _ -> None
      in
      match source with
      | Some {it = VarE id; _} ->
          names := Il.Free.Set.add id.it !names
      | _ -> ())
    exps;
  !names

let rec focus_output index needed exp =
  let recurse = focus_output index needed in
  let it =
    match exp.it with
    | IterE (body, ((ListN ({it = VarE count; _}, None), _) as iteration))
      when not (Il.Free.Set.mem count.it needed)
        && Iter.identity_requirements index body = [] ->
        begin match Iter.identity_source index body iteration with
        | Some source -> source.it
        | None -> exp.it
        end
    | CaseE (op, payload) -> CaseE (op, recurse payload)
    | TupE fields -> TupE (List.map recurse fields)
    | ListE fields -> ListE (List.map recurse fields)
    | CatE (left, right) -> CatE (recurse left, recurse right)
    | _ -> exp.it
  in
  {exp with it}

let project_focus_premise index needed premise =
  match premise.it with
  | RulePr (id, args, mixop, head) ->
      begin match Prescan.relation_policy index id with
      | Ok (Prescan.Execution {input_count; _} | Prescan.Compute {input_count; _}) ->
          let inputs, outputs =
            Prem.split input_count (Prem.components mixop head)
          in
          let parts = inputs @ List.map (focus_output index needed) outputs in
          let head =
            match head.it with
            | TupE _ -> {head with it = TupE parts}
            | _ -> List.hd parts
          in
          {premise with it = RulePr (id, args, mixop, head)}
      | _ -> premise
      end
  | _ -> premise

(* Premise slicing for identifyFocus.

   An identifyFocus rule only has to split the instruction sequence into
   PREFIX | focus | POSTFIX. It is derived from a rule of an inner relation,
   but keeps only the premises that decide this split:

   - needed variables start as the boundary variables: the counts of ^n
     iterations and the unbounded sequence slots of the focus
     (boundary_variables);
   - a premise is kept if it binds a needed variable, or if it must be kept
     as a whole (a checked relation, a subsumption check, an IterPr or NegPr,
     a LetPr whose right side is not yet known, or an equality on a boundary
     variable); a kept premise makes its own inputs needed;
   - this is repeated until no new variable becomes needed (close).

   Dropped premises are the scalar guards that choose between inner rules
   with the same focus. They are not lost: the focus is executed as a request
   of the inner relation, whose rules check all their premises. This assumes
   that a dropped premise never changes where the focus ends. The execution
   premise named by the bridge (deferred) is always dropped, since it is the
   step that the focus will take. *)

type focus_dependency =
  { premise : prem
  ; writes : Il.Free.Set.t
  ; reads : Il.Free.Set.t
  ; retain : bool
  }

let focus_premises index initial needed deferred prems =
  let module S = Il.Free.Set in
  let free premise = Il.Free.(free_prem premise).varid in
  let boundary_variable exp =
    match exp.it with
    | VarE id when S.mem id.it needed -> S.singleton id.it
    | _ -> S.empty
  in
  let is_deferred id =
    match deferred with
    | Some target -> target.it = id.it
    | None -> false
  in
  let binding bound pattern subject =
    let writes = Prem.variables pattern in
    let reads = S.union (Prem.variables subject) (S.inter bound writes) in
    writes, reads, false
  in
  let describe bound premise =
    let writes, reads, retain =
      match premise.it with
      | RulePr (id, args, mixop, head) ->
          let parts = Prem.components mixop head in
          begin match Prescan.relation_policy index id with
          | Ok (Prescan.Execution _) when is_deferred id ->
              S.empty, S.empty, false
          | Ok (Prescan.Compute {subsume = Some _; _})
            when Prem.known_args bound args && Prem.known bound head ->
              (* A known result is the subsumption check, as for Check. *)
              S.empty, free premise, true
          | Ok (Prescan.Execution {input_count; _}
               | Prescan.Compute {input_count; _}) ->
              let inputs, outputs = Prem.split input_count parts in
              let writes = List.fold_left Prem.bind S.empty outputs in
              let reads =
                List.fold_left Prem.bind Il.Free.(free_args args).varid inputs
              in
              writes, S.union reads (S.inter bound writes), false
          | Ok (Prescan.Check _) ->
              S.empty, free premise, true
          | Error reason -> unsupported premise.at reason
          end
      | LetPr (quants, left, right) ->
          let writes, reads, _ = binding bound left right in
          let reads = S.union Il.Free.(free_quants quants).varid reads in
          if Prem.known bound right then writes, reads, false
          else S.empty, S.union reads (free premise), true
      | IfPr {it = CmpE (`EqOp, _, left, right); _} ->
          let boundary =
            if Prem.known bound left && Prem.known bound right then
              S.inter needed (free premise)
            else
              S.union (boundary_variable left) (boundary_variable right)
          in
          if not (S.is_empty boundary) then boundary, free premise, true
          else if Prem.known bound right then binding bound left right
          else if Prem.known bound left then binding bound right left
          else S.empty, free premise, true
      | ElsePr -> S.empty, S.empty, false
      | IfPr exp ->
          (* Sequence and cardinality guards constrain the boundary. Other
             guards belong to execution; opaque/iterated premises stay. *)
          S.inter needed (Prem.variables exp), Prem.variables exp, false
      | IterPr _ | NegPr _ -> S.empty, free premise, true
    in
    {premise; writes; reads; retain}
  in
  let _, dependencies =
    List.fold_left
      (fun (bound, dependencies) premise ->
        let dependency = describe bound premise in
        S.union bound dependency.writes, dependency :: dependencies)
      (initial, []) prems
  in
  let required needed dependency =
    dependency.retain || not (S.is_empty (S.inter needed dependency.writes))
  in
  let rec close needed =
    let next =
      List.fold_left
        (fun names dependency ->
          if required names dependency then S.union names dependency.reads
          else names)
        needed dependencies
    in
    if S.equal next needed then needed else close next
  in
  let needed = close needed in
  List.rev dependencies
  |> List.filter_map (fun dependency ->
       if required needed dependency then
         Some (project_focus_premise index needed dependency.premise)
       else None)

let shaped_relation_call index (pattern : Hintd.focus_pattern) =
  let RuleD (_, _, mixop, head, prems) = pattern.rule.it in
  let policy = execution_policy index pattern.source.id in
  let inputs =
    match policy with
    | Prescan.Execution {input_count; _} ->
        fst (Prem.split input_count (Prem.components mixop head))
    | _ -> unsupported pattern.rule.at
        "focus source must be an execution relation"
  in
  let index = Term.with_relation_types index
    pattern.source.id pattern.source.params inputs in
  let terms, guards, bound, _ =
    Reld.translate_inputs ~defer:false index pattern.source.params inputs
  in
  let needed = boundary_variables index (pattern.operands @ pattern.trailing) in
  let prems =
    focus_premises index bound needed pattern.deferred_execution prems
  in
  let premises =
    Prem.translate_all index ~bound:(Il.Free.Set.elements bound)
      ~bind_membership:true ~collect_outputs:true prems
  in
  let conditions = guards @ premises.conditions in
  let shapes = Reld.input_shapes conditions terms in
  let bindings =
    List.map2
      (fun term shape ->
        match term with
        | Var variable when not (Reld.same_term term shape) -> Some (variable, shape)
        | _ -> None)
      terms shapes
    |> List.filter_map Fun.id
  in
  relation_call index pattern.source shapes,
  List.map (substitute_condition bindings) conditions

let lift_bridge cache index (call, conditions)
    (bridge : Hintd.bridge) =
  let lowered =
    lowered_rule cache index bridge.Hintd.source
      bridge.ordinal bridge.rule.at
  in
  let target =
    match call_name call with
    | Some target -> target
    | None -> unsupported bridge.rule.at "delegated relation is not a call"
  in
  let (_, result), bridge_conditions =
    delegated_condition bridge.premise.at target lowered.conditions
  in
  (* Focus unifies the source input shape, while the equality guards retain
     the checks performed when that input is constructed. *)
  let delegated, input_guards =
    match bridge.premise.it with
    | RulePr (id, args, mixop, head) ->
        let input_count =
          match execution_policy index id with
          | Prescan.Execution {input_count; _} -> input_count
          | _ -> assert false
        in
        let inputs, _ = Prem.split input_count (Prem.components mixop head) in
        let patterns, guards =
          inputs |> List.map (fun input ->
            match Prem.translate_pattern_parts index input with
            | Some (pattern, guards) ->
                let expression = Term.translate_exp index input in
                let checks =
                  if Reld.same_term expression pattern then guards
                  else guards @ [EqCond (expression, pattern)]
                in pattern, List.map (fun guard -> EqCondition guard) checks
            | None -> unsupported input.at "bridge input has no structural pattern")
          |> List.split
        in
        App (target, List.map (Term.translate_arg index) args @ patterns),
        List.concat guards
    | _ -> unsupported bridge.premise.at "bridge premise is not a relation"
  in
  let outer, bridge_conditions =
    freshen lowered.left
      (RewriteCond (delegated, result) :: input_guards @ bridge_conditions)
  in
  let (delegated, _), bridge_conditions =
    delegated_condition bridge.premise.at target bridge_conditions
  in
  let bindings = unify bridge.premise.at [] delegated call in
  ( substitute bindings outer
  , List.map (substitute_condition bindings) bridge_conditions @ conditions
  )

let outer_call cache index (pattern : Hintd.focus_pattern) =
  let call, conditions = shaped_relation_call index pattern in
  List.fold_left
    (lift_bridge cache index)
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
  let rule = (Hintd.rule_id pattern.rule).it |> Prescan.sanitize in
  "focus-" ^ relation ^ "-" ^ rule

let request_sort index (context : Hintd.context) =
  match execution_policy index context.source.id with
  | Prescan.Execution {request_sort; _} -> request_sort
  | Prescan.Compute _ | Prescan.Check _ -> unsupported context.rule.at
      "context relation has no execution-request sort"

let helper index (context : Hintd.context) name =
  match Prescan.contexts index with
  | [_] -> name
  | _ -> name ^ "-" ^ Prescan.rel_name index context.source.id
      ^ "-" ^ Prescan.sanitize (Hintd.rule_id context.rule).it

let declarations index (context : Hintd.context) =
  let name = helper index context in
  let prefix_sort = Term.translate_sort index context.Hintd.prefix_typ in
  let postfix_sort = Term.translate_sort index context.postfix_typ in
  let state_sort = Term.translate_sort index context.frame.state_typ in
  let config_sort = Term.translate_sort index context.frame.config_typ in
  let proper_sort = context.Hintd.proper_sort in
  let request_sort = request_sort index context in
  [ SortDecl (name "FocusSearch")
  ; SortDecl (name "FocusTarget")
  ; SortDecl (name "Hole")
  ; SubsortDecl (name "FocusTarget", name "FocusSearch")
  ; op ~arrow:Partial ~attrs:(frozen_all 4) (name "identifyFocus")
      [state_sort; prefix_sort; proper_sort; postfix_sort] (name "FocusSearch")
  ; op ~attrs:[Ctor] (name "{_|_|_}")
      [prefix_sort; config_sort; postfix_sort] (name "FocusTarget")
  ; op ~attrs:[Ctor] (name "hole") [prefix_sort; postfix_sort] (name "Hole")
  ; op ~attrs:[Frozen [2]] (name "_~>_") [request_sort; name "Hole"] request_sort
  ]

let translate_pattern cache index (context : Hintd.context)
    (pattern : Hintd.focus_pattern) =
  let name = helper index context in
  let call, conditions = outer_call cache index pattern in
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
  let left = App (name "identifyFocus", [state; stack; trigger; rest]) in
  let right = App (name "{_|_|_}", [prefix; rebuild focus; postfix]) in
  let conditions =
    try schedule_rule_conditions left conditions with
    | Invalid_argument reason ->
        unsupported pattern.rule.at
          ("focus of " ^ (Hintd.rule_id pattern.rule).it ^ ": " ^ reason)
  in
  let label = Some (name (focus_label index pattern)) in
  match conditions with
  | [] -> Rl (label, left, right)
  | _ -> Crl (label, left, right, conditions)

let context_transitions index (context : Hintd.context) =
  let name = helper index context in
  let policy = execution_policy index context.source.id in
  let RuleD (id, quants, mixop, head, prems) = context.rule.it in
  let is_nonempty premise =
    match premise.it with
    | IfPr exp -> Hintd.nonempty_context context.prefix.it context.postfix.it exp
    | _ -> false
  in
  let nonempty = List.exists is_nonempty prems in
  let rule =
    let prems = List.filter (fun premise -> not (is_nonempty premise)) prems in
    {context.rule with it = RuleD (id, quants, mixop, head, prems)}
  in
  let lowered =
    Reld.lower_execution_rule index context.source.id
      context.source.params policy [] context.ordinal rule
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
  let target = App (name "{_|_|_}", [prefix; rebuild focus; postfix]) in
  let identify =
    RewriteCond
      (App (name "identifyFocus", [state; stack; trigger; rest]), target)
  in
  let bindings =
    [ Prescan.source_variable index context.prefix context.prefix_typ, prefix
    ; Prescan.source_variable index context.focus context.focus_typ, focus
    ; Prescan.source_variable index context.postfix context.postfix_typ, postfix
    ]
  in
  let different left right =
    EqCondition (BoolCond (App ("_=/=_", [left; right])))
  in
  let guards =
    if nonempty then
      let whole =
        Term.sequence_of_typ index context.focus_typ [prefix; focus; postfix]
      in
      [different sequence trigger; identify; different focus whole]
    else [identify]
  in
  let conditions =
    guards @ List.map (substitute_condition bindings) remaining
    |> schedule_rule_conditions heat_left
  in
  let hole = App (name "hole", [prefix; postfix]) in
  let heat_right =
    App (name "_~>_", [substitute bindings inner_call; hole])
  in
  let label =
    Some (name ("heating-" ^ Prescan.sanitize (Hintd.rule_id context.rule).it))
  in
  let heating = Crl (label, heat_left, heat_right, conditions) in
  let cool_left =
    App (name "_~>_", [substitute bindings inner_result; hole])
  in
  let result = substitute bindings lowered.right in
  let cooling = Eq (cool_left, result, []) in
  [heating; cooling]

let unique_candidates candidates =
  let key statement =
    let names = ref [] in
    let rename variable =
      let existing =
        List.find_opt (fun (original, _) -> same_variable original variable) !names
      in
      match existing with
      | Some (_, canonical) -> canonical
      | None ->
          let canonical =
            source_variable (string_of_int (List.length !names)) variable.sort
          in
          names := (variable, canonical) :: !names;
          canonical
    in
    let statement =
      match statement with
      | Rl (_, left, right) -> Rl (None, left, right)
      | Crl (_, left, right, conditions) -> Crl (None, left, right, conditions)
      | _ -> invalid_arg "expected a focus candidate"
    in
    map_statement_variables rename statement
  in
  let _, kept =
    List.fold_left
      (fun (seen, kept) candidate ->
        let canonical = key candidate in
        if List.mem canonical seen then seen, kept
        else canonical :: seen, candidate :: kept)
      ([], []) candidates
  in
  List.rev kept

(* The heating guard of a k_heatcool rule whose inner relation computes a
 * sequence: one rl per rule of the inner relation, matching that rule's
 * input pattern (TRANSLATION_MAP.md, section 2). Returns the statements and
 * the heating condition. The helper is named after the source rule. *)
let identify_statements cache index (heated : Hintd.heatcool) target args =
  let RuleD (id, _, _, _, _) = heated.rule.it in
  let metadata = Prescan.sort_metadata index in
  let relation = Hintd.find_relation metadata.relations target heated.rule.at in
  let candidates = lower_relation cache index relation in
  let name = "identify" ^ String.capitalize_ascii (Prescan.sanitize id.it) in
  let params, _, typ, _ = Il.Env.find_rel metadata.type_env target in
  let count = match execution_policy index target with
    | Prescan.Execution {input_count; _} -> input_count
    | _ -> assert false
  in
  let input_types, _ = Prem.split count (Reld.component_types typ) in
  let domain = Param.translate_sorts index params
    @ List.map (Term.translate_sort index) input_types in
  (* Input patterns identify candidates. The original target rule checks its
     premises once, when the suspended request executes. *)
  (* Each rl is labeled after its inner rule, like the focus rules. *)
  let label (candidate : Reld.execution_rule) =
    let rule_id = Hintd.rule_id (List.nth relation.Hintd.rules candidate.ordinal) in
    "identify-" ^ Prescan.rel_name index target ^ "-"
    ^ (if rule_id.it = "" then string_of_int (candidate.ordinal + 1)
       else Prescan.sanitize rule_id.it)
  in
  (* identifyI(ins) = true for an input that some inner rule matches; on
     any other input it stays unreduced, so the heating condition fails. *)
  let equations = candidates |> List.map (fun (candidate : Reld.execution_rule) ->
    match candidate.left with
    | App (_, inputs) ->
        Rl (Some (label candidate), App (name, inputs), Const "true")
    | _ -> assert false)
    |> unique_candidates
    |> List.map (function
         | Rl (_, left, right) -> Eq (left, right, [])
         | _ -> assert false)
  in
  op name domain "Bool" :: equations,
  [EqCondition (BoolCond (App (name, args)))]

(* A RulePr suspends this rule. Its result pattern resumes the remaining
   premises in source order; only live, already-bound variables enter a hole. *)
let heatcool_rule cache index (heated : Hintd.heatcool) =
  let source = heated.source in
  let RuleD (id, _, _, _, prems) = heated.rule.it in
  let fail reason =
    unsupported heated.rule.at
      ("RuleD " ^ source.id.it ^ "/" ^ id.it ^ ": " ^ reason)
  in
  let policy = execution_policy index source.id in
  let outer_sort = match policy with
    | Prescan.Execution {request_sort; _} -> request_sort
    | _ -> assert false
  in
  let executions =
    prems |> List.filter_map (fun prem -> match prem.it with
      | RulePr (target, _, mixop, exp) ->
          begin match Prescan.relation_policy index target with
          | Ok (Prescan.Execution {request_sort; input_count}) ->
              let _, outputs = Prem.split input_count (Prem.components mixop exp) in
              Some (target, request_sort, outputs)
          | _ -> None
          end
      | IfPr _ | LetPr _ ->
          if Prem.prem_has_rewrite_call index prem then
            fail "rewrite-backed expression requires a separate hint contract";
          None
      | ElsePr | IterPr _ | NegPr _ ->
          fail "unsupported premise under k_heatcool")
  in
  let body =
    Reld.lower_rule_body ~head:(Prescan.rel_name index source.id)
      index source.id source.params policy heated.rule
  in
  if body.otherwise then fail "ElsePr requires an explicit complement";
  (* An unnamed rule is numbered only if its relation has other rules. *)
  let suffix =
    Prescan.rel_name index source.id
    ^ (if id.it <> "" then "-" ^ Prescan.sanitize id.it
       else if List.length source.Hintd.rules = 1 then ""
       else "-" ^ string_of_int (heated.ordinal + 1))
  in
  let vars_condition variables = function
    | RewriteCond (left, right)
    | EqCondition (EqCond (left, right) | MatchCond (left, right)) ->
        term_variables (term_variables variables left) right
    | EqCondition (MembershipCond (term, _) | BoolCond term) ->
        term_variables variables term
  in
  let bound_condition variables = function
    | RewriteCond (_, pattern) | EqCondition (MatchCond (pattern, _)) ->
        term_variables variables pattern
    | EqCondition _ -> variables
  in
  let rec before_execution equations = function
    | EqCondition condition :: rest -> before_execution (condition :: equations) rest
    | rest -> List.rev equations, rest
  in
  let equation left right conditions =
    match conditions with
    | [] -> Eq (left, right, [])
    | _ -> Ceq (left, right, conditions, [])
  in
  (* Identify sequence-result relation bridges from their result type, never
     from Wasm relation names. *)
  let identify target outputs call =
    match executions, outputs, call with
    | [_], [{note = {it = IterT _; _}; _}], App (_, args)
      when target.it <> source.id.it ->
        identify_statements cache index heated target args
    | _ -> [], []
  in
  let rec resume initial stage left conditions remaining =
    let guards, pending = before_execution [] conditions in
    let bound = List.fold_left bound_condition (term_variables [] left)
        (List.map (fun guard -> EqCondition guard) guards) in
    match pending, remaining with
    | [], [] ->
        if initial then fail "hint has no execution condition";
        if not (variables_bound bound body.right) then
          fail "cooling has an unbound output";
        [equation left body.right guards]
    | RewriteCond (call, result) :: rest, (target, inner_sort, outputs) :: targets ->
        if not (variables_bound bound call) then
          fail "RulePr input is not bound before heating";
        let needed = List.fold_left vars_condition
            (term_variables (term_variables [] body.right) result) rest in
        let captures = List.filter
            (fun variable -> List.exists (same_variable variable) needed) bound in
        (* With several execution premises, a hole is named after the relation
           of the premise it waits for, numbered only if that repeats. *)
        let stage_suffix =
          let same (other, _, _) = other.it = target.it in
          match List.length executions, List.length (List.filter same executions) with
          | 1, _ -> ""
          | _, 1 -> "-" ^ Prescan.rel_name index target
          | _ -> "-" ^ Prescan.rel_name index target ^ "-" ^ string_of_int stage
        in
        let name = "hole-" ^ suffix ^ stage_suffix in
        let sort = "Hole-" ^ suffix ^ stage_suffix in
        let hole = App (name, List.map (fun variable -> Var variable) captures) in
        let suspended = App ("_~>_", [call; hole]) in
        let returned = App ("_~>_", [result; hole]) in
        let identification, checks =
          if initial then identify target outputs call else [], [] in
        let conditions = List.map (fun guard -> EqCondition guard) guards @ checks in
        let transition =
          if initial then
            let label = Some ("heating-" ^ suffix) in
            match conditions with
            | [] -> Rl (label, left, suspended)
            | _ -> Crl (label, left, suspended, conditions)
          else equation left suspended guards
        in
        [ SortDecl sort
        ; op ~attrs:[Ctor] name (List.map (fun variable -> variable.sort) captures) sort
        ; op ~attrs:[Frozen [2]] "_~>_" [inner_sort; sort] outer_sort
        ] @ identification @ [transition]
        @ resume false (stage + 1) returned rest targets
    | _ -> fail "lowered execution conditions do not match direct RulePr premises"
  in
  resume true 1 body.left body.conditions executions

(* The statements for the hint(k_heatcool) rules of one relation. *)
let translate_relation index id =
  let cache = Hashtbl.create 4 in
  let sequences = Prescan.contexts index
  |> List.filter (fun (context : Hintd.context) -> context.source.id.it = id.it)
  |> List.concat_map (fun context ->
       declarations index context
       @ (context.Hintd.patterns
          |> List.map (translate_pattern cache index context)
          |> unique_candidates)
       @ context_transitions index context)
  in
  let nested = Prescan.heatcool index
    |> List.filter (fun (heated : Hintd.heatcool) ->
         heated.source.id.it = id.it
         && not (Prescan.is_context_rule index heated.source.id heated.rule))
    |> List.concat_map (heatcool_rule cache index)
  in
  sequences @ nested
