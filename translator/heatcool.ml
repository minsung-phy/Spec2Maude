(* hint(k_heatcool): lowering of RuleD with execution premises.
 * Hintd supplies the validated relation shape; this module constructs the
 * identify-focus, split, and plug statements (equations for a ~> relation,
 * rules for a ~>* relation) and the K embedding of context rules. *)

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

(* Renames the selected variables to fresh BRIDGE- variables, the same
   variable to the same one. *)
let renaming selected =
  let variables = ref [] in
  fun variable ->
    if not (selected variable) then variable
    else
      match
        List.find_opt
          (fun (source, _) -> same_variable variable source) !variables
      with
      | Some (_, target) -> target
      | None ->
          let target = generated_variable ("BRIDGE-" ^ variable.name) variable.sort in
          variables := (variable, target) :: !variables;
          target

let freshen left conditions =
  let fresh = renaming (fun _ -> true) in
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

(* Heating a ~> relation only takes its configuration apart, so it is an
   equation and the inner relation's rule is the one step. A ~>* relation
   keeps rules: its reflexive and transitive rules apply to the same request. *)
let heats_by_equation (relation : Hintd.relation) =
  Mixop.marker_positions Xl.Atom.[SqArrowStar; SqArrowStarSub] relation.mixop = []

let equational at conditions =
  conditions |> List.map (function
    | EqCondition condition -> condition
    | RewriteCond _ -> unsupported at "heating equation has a rewrite condition")

(* A heating transition: an equation for a ~> relation, a rule otherwise. *)
let heating (relation : Hintd.relation) at label left right conditions =
  match heats_by_equation relation, conditions with
  | true, [] -> Eq (left, right, [])
  | true, _ -> Ceq (left, right, equational at conditions, [])
  | false, [] -> Rl (label, left, right)
  | false, _ -> Crl (label, left, right, conditions)

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
   - a premise is kept if it binds a needed variable or is an equality on a
     boundary variable; a kept premise makes its own inputs needed;
   - this is repeated until no new variable becomes needed (close).
   Input guards of the source pattern are kept on the same terms
   (boundary_guards).

   Dropped premises only choose between inner rules with the same focus.
   They are not lost: the focus is executed as a request of the inner
   relation, whose rules check all their premises. The execution premise
   named by the bridge (deferred) is always dropped, since it is the step
   that the focus will take.

   For a ~> relation identifyFocus and the splits are equations, so every
   input must split in exactly one way. A pattern whose extent is not fixed
   (unbounded_extent) splits in several ways and is a rule instead
   (absorbed_rules). *)

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
  let none = S.empty, S.empty, false in
  let describe bound premise =
    let writes, reads, retain =
      match premise.it with
      | RulePr (id, args, mixop, head) ->
          let parts = Prem.components mixop head in
          begin match Prescan.relation_policy index id with
          | Ok (Prescan.Execution _) when is_deferred id -> none
          | Ok (Prescan.Compute {subsume = Some _; _})
            when Prem.known_args bound args && Prem.known bound head ->
              (* A known result is the subsumption check, as for Check. *)
              none
          | Ok (Prescan.Execution {input_count; _}
               | Prescan.Compute {input_count; _}) ->
              let inputs, outputs = Prem.split input_count parts in
              let writes = List.fold_left Prem.bind S.empty outputs in
              let reads =
                List.fold_left Prem.bind Il.Free.(free_args args).varid inputs
              in
              writes, S.union reads (S.inter bound writes), false
          | Ok (Prescan.Check _) -> none
          | Error reason -> unsupported premise.at reason
          end
      | LetPr (quants, left, right) ->
          let writes, reads, _ = binding bound left right in
          writes, S.union Il.Free.(free_quants quants).varid reads, false
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
          else none
      | ElsePr | NegPr _ -> none
      | IfPr exp ->
          (* Sequence and cardinality guards constrain the boundary. *)
          S.inter needed (Prem.variables exp), Prem.variables exp, false
      | IterPr _ -> S.diff (free premise) bound, free premise, false
    in
    {premise; writes; reads; retain}
  in
  (* A conjunction is kept or dropped per conjunct (a = |s| /\ ai = {..^n}
     only uses n), as Prem translates it. *)
  let rec conjuncts premise =
    match premise.it with
    | IfPr {it = BinE (`AndOp, `BoolT, left, right); _} ->
        conjuncts {premise with it = IfPr left}
        @ conjuncts {premise with it = IfPr right}
    | _ -> [premise]
  in
  let _, dependencies =
    List.fold_left
      (fun (bound, dependencies) premise ->
        let dependency = describe bound premise in
        S.union bound dependency.writes, dependency :: dependencies)
      (initial, []) (List.concat_map conjuncts prems)
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
  needed,
  List.rev dependencies
  |> List.filter_map (fun dependency ->
       if required needed dependency then
         Some (project_focus_premise index needed dependency.premise)
       else None)

let condition_variables variables = function
  | RewriteCond (left, right)
  | EqCondition (EqCond (left, right) | MatchCond (left, right)) ->
      term_variables (term_variables variables left) right
  | EqCondition (MembershipCond (term, _) | BoolCond term) ->
      term_variables variables term

(* An input guard is kept if it mentions a needed source variable (the
   length check of val^n) or a variable of a kept premise. Other guards
   (e.g. a ref typecheck of a single operand) only choose an inner rule,
   like a dropped premise. *)
let boundary_guards index needed inputs premises guards =
  let relevant = ref (List.fold_left condition_variables [] premises) in
  let module Visitor = Il.Iter.Make (struct
    include Il.Iter.Skip
    let visit_exp exp =
      match exp.it with
      | VarE id when Il.Free.Set.mem id.it needed ->
          relevant := Prescan.source_variable index id exp.note :: !relevant
      | _ -> ()
  end)
  in
  Visitor.list Visitor.exp inputs;
  let mentioned variable = List.exists (same_variable variable) !relevant in
  List.filter
    (fun guard -> List.exists mentioned (condition_variables [] guard))
    guards

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
  let needed, prems =
    focus_premises index bound needed pattern.deferred_execution prems
  in
  let premises =
    Prem.translate_all index ~bound:(Il.Free.Set.elements bound)
      ~bind_membership:true ~collect_outputs:true prems
  in
  let guards = boundary_guards index needed inputs premises.conditions guards in
  let conditions = guards @ premises.conditions in
  (* A kept premise may also bind what the focus does not use (n of
     t_1^m -> t_2^n); such a binding of a lone variable is dropped. *)
  let rec live conditions =
    let unused = function
      | EqCondition (MatchCond (Var variable, _)) as condition ->
          let others = List.filter (fun other -> other != condition) conditions in
          let used = List.fold_left condition_variables
              (List.fold_left term_variables [] terms) others in
          not (List.exists (same_variable variable) used)
      | _ -> false
    in
    match List.find_opt unused conditions with
    | Some dead -> live (List.filter (fun condition -> condition != dead) conditions)
    | None -> conditions
  in
  let conditions = live conditions in
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

(* Generated statements are named <relation>-<rule> after their source rule.
   An unnamed rule is numbered only if its relation has other rules. *)
let rule_name index (relation : Hintd.relation) ordinal rule =
  let id = Hintd.rule_id rule in
  Prescan.rel_name index relation.id
  ^ (if id.it <> "" then "-" ^ Prescan.sanitize id.it
     else if List.length relation.rules = 1 then ""
     else "-" ^ string_of_int (ordinal + 1))

let focus_label index (pattern : Hintd.focus_pattern) =
  "focus-" ^ rule_name index pattern.source pattern.ordinal pattern.rule

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

(* An operand of the prefix sequence sort (val* of val^n) can start anywhere
   in the stack. Matched on the left side, every split is enumerated before
   any condition runs, so a condition that fixes n (e.g. a type lookup) is
   repeated per split. Such operands and those before them are matched by a
   condition instead; scheduling places it after the conditions that do not
   read them. *)
let split_stack index (context : Hintd.context) prefix operands =
  let sequence = Term.sequence_of_typ index context.prefix_typ in
  let prefix_sort = Term.translate_sort index context.prefix_typ in
  let rec split = function
    | [] -> None
    | operand :: rest ->
        begin match split rest, operand with
        | Some (leading, trailing), _ -> Some (operand :: leading, trailing)
        | None, Var variable when variable.sort = prefix_sort ->
            Some ([operand], rest)
        | None, _ -> None
        end
  in
  match split operands with
  | None -> sequence (prefix :: operands), []
  | Some (leading, trailing) ->
      let stack = variable index "STACK" context.prefix_typ in
      ( sequence (stack :: trailing)
      , [EqCondition (MatchCond (sequence (prefix :: leading), stack))] )

(* The focused input of a focus pattern: the state, the operands before its
   trigger instruction, the trigger, and the instructions after it. *)
type focused =
  { conditions : rule_condition list
  ; state : term
  ; focus : term
  ; rebuild : term -> term
  ; operands : term list
  ; trigger : term
  ; trailing : term list
  }

let focused cache index (context : Hintd.context) (pattern : Hintd.focus_pattern) =
  let call, conditions = outer_call cache index pattern in
  let config = relation_input index context call in
  let state, focus, rebuild =
    split_config index context.Hintd.frame config pattern.rule.at
  in
  let operands, trigger, trailing = focus_parts index context pattern focus in
  {conditions; state; focus; rebuild; operands; trigger; trailing}

let translate_pattern cache index (context : Hintd.context)
    (pattern : Hintd.focus_pattern) =
  let name = helper index context in
  let {conditions; state; focus; rebuild; operands; trigger; trailing} =
    focused cache index context pattern
  in
  let prefix = variable index "PREFIX" context.prefix_typ in
  let postfix = variable index "POSTFIX" context.postfix_typ in
  let stack, conditions =
    match conditions with
    | [] -> Term.sequence_of_typ index context.prefix_typ (prefix :: operands), []
    | _ ->
        let stack, split = split_stack index context prefix operands in
        stack, conditions @ split
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
  heating context.source pattern.rule.at label left right conditions

(* The variables of the sequence context val* instr* instr_1*, renamed
   PREFIX, FOCUS, POSTFIX, and the bindings from the source variables. *)
let context_variables index (context : Hintd.context) =
  let generated name typ =
    Var (generated_variable name (Term.translate_sort index typ))
  in
  let prefix = generated "PREFIX" context.prefix_typ in
  let focus = generated "FOCUS" context.focus_typ in
  let postfix = generated "POSTFIX" context.postfix_typ in
  ( prefix, focus, postfix,
    [ Prescan.source_variable index context.prefix context.prefix_typ, prefix
    ; Prescan.source_variable index context.focus context.focus_typ, focus
    ; Prescan.source_variable index context.postfix context.postfix_typ, postfix
    ] )

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
  let postfix_sort = Term.translate_sort index context.postfix_typ in
  let generated name sort = Var (generated_variable name sort) in
  let prefix, focus, postfix, bindings = context_variables index context in
  let stack = generated "STACK" prefix_sort in
  let trigger = Var (generated_variable "OP" context.Hintd.proper_sort) in
  let rest = generated "REST" postfix_sort in
  let sequence =
    Term.sequence_of_typ index context.focus_typ [stack; trigger; rest]
  in
  let input = rebuild sequence in
  let split_left = relation_call index context.source [input] in
  let target = App (name "{_|_|_}", [prefix; rebuild focus; postfix]) in
  let search = App (name "identifyFocus", [state; stack; trigger; rest]) in
  let identify =
    if heats_by_equation context.source then EqCondition (MatchCond (target, search))
    else RewriteCond (search, target)
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
    |> schedule_rule_conditions split_left
  in
  let hole = App (name "hole", [prefix; postfix]) in
  let split_right =
    App (name "_~>_", [substitute bindings inner_call; hole])
  in
  let label =
    Some ("split-" ^ rule_name index context.source context.ordinal context.rule)
  in
  let split =
    heating context.source context.rule.at label split_left split_right conditions
  in
  let plug_left =
    App (name "_~>_", [substitute bindings inner_result; hole])
  in
  let result = substitute bindings lowered.right in
  let plug = Eq (plug_left, result, []) in
  let unheat =
    if heats_by_equation context.source then
      let request = Var (generated_variable "R" (request_sort index context)) in
      [Eq (App ("unheat", [App (name "_~>_", [request; hole])]),
           App (name "_~>_", [App ("unheat", [request]); hole]), [])]
    else []
  in
  [split; plug] @ unheat

(* The extent of a focus pattern is not fixed when an operand or trailing part
   is a sequence whose length no other part of the rule determines (val*, or
   val^n with n nowhere else). It overlaps the prefix or postfix of the
   sequence context, so an input splits in several ways, each a different
   source successor: by trap-instrs (val* TRAP instr* ~> TRAP), a b TRAP
   steps to TRAP and to a TRAP. An equation would keep one of them. *)
let unbounded_extent (pattern : Hintd.focus_pattern) =
  let occurrences name =
    let count = ref 0 in
    let module Visitor = Il.Iter.Make (struct
      include Il.Iter.Skip
      let visit_exp exp =
        match exp.it with
        | VarE id when id.it = name -> incr count
        | _ -> ()
    end)
    in
    Visitor.rule pattern.rule;
    !count
  in
  let unbounded exp =
    let exp = Hintd.strip_subtype exp in
    match exp.it, exp.note.it with
    | IterE (_, ((Opt | List | List1), _)), _
    | VarE _, IterT (_, (Opt | List | List1)) -> true
    | IterE (_, (ListN (count, _), _)), _ ->
        Il.Free.Set.exists (fun name -> occurrences name < 2) (Prem.variables count)
    | _ -> false
  in
  List.exists unbounded (pattern.operands @ pattern.trailing)

let absorbed (context : Hintd.context) pattern =
  heats_by_equation context.source && unbounded_extent pattern

(* The focus pattern of an inner relation's rule, with its context. *)
let focus_pattern index rule =
  Prescan.contexts index |> List.find_map (fun (context : Hintd.context) ->
    context.patterns
    |> List.find_opt (fun (pattern : Hintd.focus_pattern) -> pattern.rule == rule)
    |> Option.map (fun pattern -> context, pattern))

let is_absorbed index rule =
  match focus_pattern index rule with
  | Some (context, pattern) -> absorbed context pattern
  | None -> false

(* The outer rule with its execution premise on the inner rule's relation
   replaced by the inner rule: the premise's call is unified with the inner
   left side and its result with the inner right side, and the inner
   conditions take the premise's place. Outer variables that also occur in
   the inner rule are renamed first. *)
let inline at (outer_left, outer_right, outer_conditions)
    (inner_left, inner_right, inner_conditions) =
  let inner_variables =
    List.fold_left condition_variables
      (term_variables (term_variables [] inner_left) inner_right)
      inner_conditions
  in
  let rename =
    renaming (fun variable -> List.exists (same_variable variable) inner_variables)
  in
  let outer_left = map_term_variables rename outer_left in
  let outer_right = map_term_variables rename outer_right in
  let outer_conditions =
    List.map (map_rule_condition_variables rename) outer_conditions
  in
  let target = call_name inner_left in
  let rec split before = function
    | RewriteCond (call, result) :: after when call_name call = target ->
        List.rev before, call, result, after
    | condition :: rest -> split (condition :: before) rest
    | [] -> unsupported at "absorbed rule has no premise on the inner relation"
  in
  let before, call, result, after = split [] outer_conditions in
  let bindings = unify at (unify at [] call inner_left) result inner_right in
  ( substitute bindings outer_left
  , substitute bindings outer_right
  , List.map (substitute_condition bindings) (before @ inner_conditions @ after) )

(* An absorbed pattern is one rule per source derivation: its rule through the
   bridges (pure, read) to the context relation, and that inside the sequence
   context. As rules, all splits are kept:
     crl Step(Z ; VAL* TRAP INSTR* ) => Z ; TRAP if ... .
     crl Step(Z ; PREFIX VAL* TRAP INSTR* POSTFIX) => Z ; PREFIX TRAP POSTFIX
       if PREFIX =/= nil or POSTFIX =/= nil /\ ... .
   Without a bridge the first is the source rule itself, translated as such. *)
let absorbed_rules cache index (context : Hintd.context)
    (pattern : Hintd.focus_pattern) =
  let at = pattern.rule.at in
  let parts (rule : Reld.execution_rule) =
    if not rule.structural_right then
      unsupported at "absorbed rule has a computed result";
    rule.left, rule.right, Reld.typecheck_guards rule @ rule.conditions
  in
  let lowered (source : Hintd.relation) ordinal =
    parts (lowered_rule cache index source ordinal at)
  in
  let direct =
    List.fold_left
      (fun rule (bridge : Hintd.bridge) ->
        inline at (lowered bridge.source bridge.ordinal) rule)
      (lowered pattern.source pattern.ordinal)
      (List.rev pattern.bridges)
  in
  let context_rule =
    let left, right, conditions =
      parts (Reld.lower_execution_rule index context.source.id context.source.params
               (execution_policy index context.source.id) [] context.ordinal context.rule)
    in
    let _, _, _, bindings = context_variables index context in
    ( substitute bindings left
    , substitute bindings right
    , List.map (substitute_condition bindings) conditions )
  in
  let statement label (left, right, conditions) =
    match conditions with
    | [] -> Rl (Some label, left, right)
    | conditions ->
        Crl (Some label, left, right, schedule_rule_conditions left conditions)
  in
  let inner = rule_name index pattern.source pattern.ordinal pattern.rule in
  let outer = rule_name index context.source context.ordinal context.rule in
  (if pattern.bridges = [] then [] else [statement inner direct])
  @ [statement (outer ^ "-" ^ Prescan.sanitize (Hintd.rule_id pattern.rule).it)
       (inline at context_rule direct)]

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
      | Eq _ | Ceq _ as statement -> statement
      | _ -> invalid_arg "expected a focus candidate or an equation"
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

(* The split guard of a k_heatcool rule whose inner relation computes a
 * sequence: one rl per rule of the inner relation, matching that rule's
 * input pattern (TRANSLATION_MAP.md, section 2). Returns the statements and
 * the split condition. The helper is named after the source rule. *)
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
     other premises once, when the suspended request executes. *)
  (* Each rl is labeled after its inner rule, like the focus rules. *)
  let label (candidate : Reld.execution_rule) =
    "identify-" ^ rule_name index relation candidate.ordinal
      (List.nth relation.Hintd.rules candidate.ordinal)
  in
  (* identifyI(ins) = true for an input that some inner rule matches and whose
     input guards hold: the equational premises over the input variables only
     (e.g. val* =/= eps \/ instr* =/= eps). On any other input it stays
     unreduced, so the split condition fails. The split is an equation for a
     ~> relation, so an input that no inner rule can step must stay unsplit. *)
  let input_guards (candidate : Reld.execution_rule) =
    let bound = term_variables [] candidate.left in
    candidate.conditions |> List.filter (fun condition ->
      match condition with
      | EqCondition _ ->
          List.for_all (fun variable -> List.exists (same_variable variable) bound)
            (condition_variables [] condition)
      | RewriteCond _ -> false)
  in
  (* An absorbed rule is a rule of its own (absorbed_rules), never split. *)
  let candidates = candidates |> List.filter (fun (candidate : Reld.execution_rule) ->
    not (is_absorbed index (List.nth relation.Hintd.rules candidate.ordinal)))
  in
  (* The split is an equation only if no other split applies to the same
     input: the premises that fix the rule's extent (val^m by the block type)
     are checked as in identifyFocus. Otherwise c1 c2 BLOCK, whose block takes
     no value, is split here as a whole and by identifyFocus around BLOCK. *)
  let boundary (candidate : Reld.execution_rule) =
    match focus_pattern index (List.nth relation.Hintd.rules candidate.ordinal) with
    | Some (_, pattern) -> snd (shaped_relation_call index pattern)
    | None -> []
  in
  let equations = candidates |> List.map (fun (candidate : Reld.execution_rule) ->
    let guards = input_guards candidate in
    let boundary = boundary candidate |> List.filter (fun condition ->
      not (List.exists (Reld.same_condition condition) guards)) in
    match candidate.left, guards @ boundary with
    | App (_, inputs), [] ->
        Rl (Some (label candidate), App (name, inputs), Const "true")
    | App (_, inputs), guards ->
        let left = App (name, inputs) in
        Crl (Some (label candidate), left, Const "true",
             schedule_rule_conditions left guards)
    | _ -> assert false)
    |> unique_candidates
    |> List.map (function
         | Rl (_, left, right) -> Eq (left, right, [])
         | Crl (_, left, right, guards) ->
             Ceq (left, right, equational heated.rule.at guards, [])
         | _ -> assert false)
  in
  op name domain "Bool" :: equations,
  [EqCondition (BoolCond (App (name, args)))]

(* A RulePr suspends this rule. Its result pattern resumes the remaining
   premises in source order; only live, already-bound variables enter a hole. *)
let heatcool_rule ~observed cache index (heated : Hintd.heatcool) =
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
  let suffix = rule_name index source heated.ordinal heated.rule in
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
          fail "plug has an unbound output";
        [equation left body.right guards]
    | RewriteCond (call, result) :: rest, (target, inner_sort, outputs) :: targets ->
        if not (variables_bound bound call) then
          fail "RulePr input is not bound before split";
        let needed = List.fold_left condition_variables
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
        (* The request's own input, not unheat of it: that request would be
           heated again by this equation's left side. *)
        let unheat =
          match left with
          | App (_, [input]) when initial && observed -> [Eq (App ("unheat", [suspended]), input, [])]
          | _ -> []
        in
        let conditions = List.map (fun guard -> EqCondition guard) guards @ checks in
        let transition =
          if initial then
            heating source heated.rule.at (Some ("split-" ^ suffix))
              left suspended conditions
          else equation left suspended guards
        in
        [ SortDecl sort
        ; op ~attrs:[Ctor] name (List.map (fun variable -> variable.sort) captures) sort
        ; op ~attrs:[Frozen [2]] "_~>_" [inner_sort; sort] outer_sort
        ] @ identification @ [transition] @ unheat
        @ resume false (stage + 1) returned rest targets
    | _ -> fail "lowered execution conditions do not match direct RulePr premises"
  in
  resume true 1 body.left body.conditions executions

(* hint(k_heatcool) on a context rule: its K embedding (K book, 5.4.6).
 * The driver state kstate(c, K) holds the configuration c around the next
 * redex and the list K of holes taken off it. For a rule
 *   R: C[x] ~> C'[x']  -- R: x ~> x'
 * whose conclusion input is one element E of the sequence context's sequence:
 *   kstate(C[x], K) = kstate(x, hole-R(..) K)                  if closed-R(x) = false
 *   kstate(x', hole-R(..) K) = kstate(C'[x'], K)               if closed-R(x') = true
 *   kstate(z; PREFIX E POSTFIX, K) = kstate(z; E, hole(PREFIX, POSTFIX) K)
 *                                    if the nonempty condition of the sequence context
 *                                    /\ closed-R(x) = false
 *   kstate(z; s, hole(PREFIX, POSTFIX) K) = kstate(z; PREFIX s POSTFIX, K)  [owise]
 * cool-all(c, K) cools every hole: the configuration of the source relation
 * that kstate(c, K) stands for.
 * closed-R holds for the bodies that a focus pattern of the sequence context
 * matches inside E: rules that consume E itself. Assumed (TRANSLATION.md): no
 * step of R applies to such a body alone, so keeping E closed loses no step. *)
let kembedding_fail (kept : Hintd.heatcool) reason =
  Util.Error.error kept.rule.at "translation"
    ("Unsupported: k_heatcool RuleD " ^ kept.source.id.it ^ "/"
     ^ (Hintd.rule_id kept.rule).it ^ ": " ^ reason)

let kstate config holes = App ("kstate", [config; holes])

let cool_all config holes = App ("cool-all", [config; holes])

let holes hole rest = App ("_ _", [hole; rest])

let make_config index (frame : Hintd.frame) state sequence =
  let components =
    if frame.Hintd.sequence_position = 0 then [sequence; state]
    else [state; sequence]
  in
  App (Prescan.mixop_name index frame.mixop, components)

(* One-way matching: the bindings of pattern variables that make pattern equal
   to subject, if any. *)
let rec matches bindings pattern subject =
  match pattern, subject with
  | Var variable, _ ->
      begin match
        List.find_opt (fun (bound, _) -> same_variable variable bound) bindings
      with
      | Some (_, previous) when Reld.same_term previous subject -> Some bindings
      | Some _ -> None
      | None -> Some ((variable, subject) :: bindings)
      end
  | Const left, Const right when left = right -> Some bindings
  | App (left, left_args), App (right, right_args)
    when left = right && List.length left_args = List.length right_args ->
      List.fold_left2
        (fun bindings pattern subject ->
          Option.bind bindings (fun bindings -> matches bindings pattern subject))
        (Some bindings) left_args right_args
  | _ -> None

(* A kept rule R/r: C[x] ~> C'[x']  -- R: x ~> x', lowered and checked. *)
type kept_rule =
  { suffix : string                (* R-r, after the source rule *)
  ; input : term                   (* C[x], the conclusion input configuration *)
  ; rebuild : term -> term         (* C[x] with another sequence *)
  ; ctor : name                    (* E, the one element of that sequence *)
  ; arguments : term list
  ; position : int                 (* the argument of E that is x *)
  ; inner : term                   (* the premise input configuration *)
  ; body : variable                (* x *)
  ; result : term                  (* the premise output configuration *)
  ; result_body : variable         (* x' *)
  ; output : term                  (* C'[x'], the conclusion output configuration *)
  ; captures : variable list       (* the variables the hole keeps *)
  }

let kept_rule index (context : Hintd.context) (kept : Hintd.heatcool) =
  let fail = kembedding_fail kept in
  let source = kept.source in
  let lowered =
    Reld.lower_rule_body ~head:(Prescan.rel_name index source.id)
      index source.id source.params (execution_policy index source.id) kept.rule
  in
  let call, result =
    match lowered.conditions with
    | [RewriteCond (call, result)] -> call, result
    | _ -> fail "the premise does not lower to one rewrite condition"
  in
  let split config = split_config index context.Hintd.frame config kept.rule.at in
  let sequence_variable config what =
    match split config with
    | _, Var variable, _ -> variable
    | _ -> fail ("the " ^ what ^ " is not a sequence variable")
  in
  let input = relation_input index context lowered.left in
  let inner = relation_input index context call in
  let _, sequence, rebuild = split input in
  let representation = Prescan.sequence_representation index context.focus_typ in
  let ctor, arguments =
    match flatten representation.concat sequence with
    | [App (ctor, arguments)] -> ctor, arguments
    | _ -> fail "the conclusion input is not one sequence element"
  in
  let body = sequence_variable inner "premise input" in
  let position =
    match
      List.mapi (fun position argument -> position, argument) arguments
      |> List.filter (fun (_, argument) -> Reld.same_term argument (Var body))
    with
    | [(position, _)] -> position
    | _ -> fail "the stepped sequence is not one argument of the context element"
  in
  (* The context does not change while its inside steps: the premise input
     put into the conclusion output gives back the conclusion input. *)
  begin match matches [] result inner with
  | Some bindings when Reld.same_term (substitute bindings lowered.right) input -> ()
  | _ -> fail "the context changes when its inside steps"
  end;
  let needed = term_variables (term_variables [] lowered.right) result in
  { suffix = rule_name index source kept.ordinal kept.rule
  ; input; rebuild; ctor; arguments; position; inner; body; result
  ; result_body = sequence_variable result "premise output"
  ; output = lowered.right
  ; captures =
      term_variables [] lowered.left
      |> List.filter (fun variable -> List.exists (same_variable variable) needed)
  }

(* The bodies x of E that a rule consuming E itself matches: those whose focus
   pattern has E's constructor as its trigger. *)
let closed_bodies cache index (context : Hintd.context) rule =
  context.Hintd.patterns
  |> List.filter_map (fun pattern ->
       match (focused cache index context pattern).trigger with
       | App (name, args)
         when name = rule.ctor && List.length args = List.length rule.arguments ->
           Some (List.nth args rule.position)
       | _ -> None)

(* What every kept rule of one sequence context shares. *)
type kept_context =
  { holes_var : term               (* K *)
  ; prefix : term
  ; postfix : term
  ; sequence : term list -> term
  ; sequence_hole : term           (* hole(PREFIX, POSTFIX) of the sequence context *)
  ; nonempty : eq_condition        (* its PREFIX =/= eps \/ POSTFIX =/= eps *)
  }

let kembedding_rule cache index context shared (kept : Hintd.heatcool) =
  let rule = kept_rule index context kept in
  let closed = "closed-" ^ rule.suffix in
  let is_closed body value = EqCond (App (closed, [Var body]), Const value) in
  let sort = "Hole-" ^ rule.suffix in
  let hole =
    holes (App ("hole-" ^ rule.suffix, List.map (fun v -> Var v) rule.captures))
      shared.holes_var
  in
  let element = App (rule.ctor, rule.arguments) in
  let surrounded =
    rule.rebuild (shared.sequence [shared.prefix; element; shared.postfix])
  in
  let bodies =
    match closed_bodies cache index context rule with
    | [] -> kembedding_fail kept "no rule consumes the context element"
    | bodies -> bodies
  in
  [ SortDecl sort
  ; SubsortDecl (sort, "Holes")
  ; op ~attrs:[Ctor] ("hole-" ^ rule.suffix)
      (List.map (fun variable -> variable.sort) rule.captures) sort
  ; op closed [rule.body.sort] "Bool"
  ; Ceq (kstate surrounded shared.holes_var,
         kstate rule.input (holes shared.sequence_hole shared.holes_var),
         [shared.nonempty; is_closed rule.body "false"], [])
  ; Ceq (kstate rule.input shared.holes_var, kstate rule.inner hole,
         [is_closed rule.body "false"], [])
  ; Ceq (kstate rule.result hole, kstate rule.output shared.holes_var,
         [is_closed rule.result_body "true"], [])
  ; Eq (cool_all rule.result hole, cool_all rule.output shared.holes_var, [])
  ]
  @ unique_candidates
      (List.map (fun body -> Eq (App (closed, [body]), Const "true", [])) bodies)
  @ [ Eq (App (closed, [Var (generated_variable "INSTR" rule.body.sort)]),
          Const "false", [Owise]) ]

(* The declarations, the cool-all and [owise] instrs-cooling equations of the
   sequence context, and the equations of each kept rule. *)
let kembedding_statements cache index (context : Hintd.context) kept =
  let nonempty premise =
    match premise.it with
    | IfPr exp -> Hintd.nonempty_context context.prefix.it context.postfix.it exp
    | _ -> false
  in
  let RuleD (_, _, _, _, prems) = context.rule.it in
  if not (List.exists nonempty prems) then
    kembedding_fail (List.hd kept)
      "the sequence context has no nonempty condition on its prefix and postfix";
  let name = helper index context in
  let empty typ = Const (Prescan.sequence_representation index typ).empty in
  let prefix = variable index "PREFIX" context.prefix_typ in
  let postfix = variable index "POSTFIX" context.postfix_typ in
  let shared =
    { holes_var = Var (generated_variable "K" "Holes")
    ; prefix; postfix
    ; sequence = Term.sequence_of_typ index context.focus_typ
    ; sequence_hole = App (name "hole", [prefix; postfix])
    ; nonempty =
        BoolCond (App ("_or_",
          [ App ("_=/=_", [prefix; empty context.prefix_typ])
          ; App ("_=/=_", [postfix; empty context.postfix_typ]) ]))
    }
  in
  let config_sort = Term.translate_sort index context.frame.config_typ in
  let whole = Var (generated_variable "C" config_sort) in
  let state = variable index "Z" context.frame.state_typ in
  let config = make_config index context.frame state in
  let inner = variable index "INSTR" context.focus_typ in
  let around = holes shared.sequence_hole shared.holes_var in
  let surrounded = config (shared.sequence [prefix; inner; postfix]) in
  (* When no context equation applies and no sequence hole waits to be
     plugged, the configuration becomes a request of its relation. The
     heating equations focus it and one rule of the relation steps it. *)
  let plug_first = "plug-first" in
  [ SortDecl "Holes"
  ; SortDecl "KState"
  ; SubsortDecl (name "Hole", "Holes")
  ; op ~attrs:[Ctor] "none" [] "Holes"
  ; op ~attrs:[Ctor; Assoc; Id (Const "none")] "__" ["Holes"; "Holes"] "Holes"
  ; op ~attrs:[Ctor; Frozen [2]] "kstate"
      [request_sort index context; "Holes"] "KState"
  ; op "cool-all" [config_sort; "Holes"] config_sort
  ; op plug_first ["Holes"] "Bool"
  ; Eq (cool_all whole (Const "none"), whole, [])
  ; Eq (cool_all (config inner) around, cool_all surrounded shared.holes_var, [])
  ; Eq (App (plug_first, [around]), Const "true", [])
  ; Eq (App (plug_first, [shared.holes_var]), Const "false", [Owise])
  ]
  @ List.concat_map (kembedding_rule cache index context shared) kept
  @ [ Eq (kstate (config inner) around, kstate surrounded shared.holes_var, [Owise])
    ; Ceq (kstate whole shared.holes_var,
           kstate (relation_call index context.source [whole]) shared.holes_var,
           [EqCond (App (plug_first, [shared.holes_var]), Const "false")], [Owise])
    ]

(* The statements for the hint(k_heatcool) rules of
   one relation. *)
let translate_relation index id =
  let cache = Hashtbl.create 4 in
  let kept =
    Prescan.kembedding index
    |> List.filter (fun (kept : Hintd.heatcool) -> kept.source.id.it = id.it)
  in
  let contexts = Prescan.contexts index
  |> List.filter (fun (context : Hintd.context) -> context.source.id.it = id.it)
  in
  let sequences = contexts |> List.concat_map (fun context ->
       let rules, patterns =
         List.partition (absorbed context) context.Hintd.patterns
       in
       declarations index context
       @ (patterns
          |> List.map (translate_pattern cache index context)
          |> unique_candidates)
       @ context_transitions index context
       @ List.concat_map (absorbed_rules cache index context) rules
       @ (if kept = [] then [] else kembedding_statements cache index context kept))
  in
  if kept <> [] && List.length contexts <> 1 then
    kembedding_fail (List.hd kept)
      "the relation needs exactly one k_heatcool sequence context";
  (* unheat(r): the configuration that a request r of a ~> relation with a
     sequence context stands for after its split equations. Drivers that
     observe a configuration between steps read it; each split adds one
     equation for its own request. Declared once per relation. *)
  let observed, unheat =
    match contexts with
    | context :: _ when heats_by_equation context.source ->
        let request_sort = request_sort index context in
        let config =
          Var (generated_variable "C"
                 (Term.translate_sort index context.frame.config_typ))
        in
        ( true
        , [ op ~arrow:Partial "unheat" [request_sort] request_sort
          ; Eq (App ("unheat", [relation_call index context.source [config]]), config, [])
          ] )
    | _ -> false, []
  in
  let nested = Prescan.heatcool index
    |> List.filter (fun (heated : Hintd.heatcool) ->
         heated.source.id.it = id.it
         && not (Prescan.is_context_rule index heated.source.id heated.rule))
    |> List.concat_map (heatcool_rule ~observed cache index)
  in
  unheat @ sequences @ nested
