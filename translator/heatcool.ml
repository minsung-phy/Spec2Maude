(* hint(k_heatcool): lowering of RuleD with execution premises by heating and
 * cooling (split/plug, K book 5.4.5). Hintd supplies the validated rule
 * shapes; this module constructs the statements.
 *
 * Every hinted rule  C ~> C'  -- R_1: c_1 ~> c_1' ... -- R_k: c_k ~> c_k'
 * heats by a rule into a request of its first execution premise and resumes
 * the next premise, then the conclusion, by equations:
 *   crl C => R_1(c_1) ~> hole_1 if <R_1 can start on c_1> .
 *   eq  c_1' ~> hole_1 = R_2(c_2) ~> hole_2 .   ...
 *   eq  c_k' ~> hole_k = C' .
 * A sequence context, hint(k_heatcool "x*"), heats through identifyFocus,
 * which finds an x* that the inner relation can step inside the sequence.
 * identifyFocus is defined by rules, one per rule of the inner relation, since
 * one sequence can be split in several ways (TRANSLATION.md). *)

open Util.Source
open Il.Ast
open Maude_il

let unsupported = Hintd.unsupported

let op ?(arrow = Total) ?(attrs = []) name domain codomain =
  OpDecl {name; domain; codomain; arrow; attrs}

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
  | Some (_, previous) when same_term (substitute bindings previous) term ->
      bindings
  | Some _ -> unsupported at "bridge input patterns do not unify"
  | None when same_term (Var variable) term -> bindings
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

let substitute_condition bindings =
  map_rule_condition_terms (substitute bindings)

(* Renames each variable whose name is in [taken] to a fresh generated
   variable whose name is not in [used], the same variable to the same one.
   Other variables keep their names. *)
let rename_apart taken used =
  let used = ref used in
  let renamed = ref [] in
  let rec fresh name count =
    let candidate = name ^ "-" ^ string_of_int count in
    if List.mem candidate !used then fresh name (count + 1) else candidate
  in
  fun variable ->
    match
      List.find_opt (fun (source, _) -> same_variable variable source) !renamed
    with
    | Some (_, target) -> target
    | None when not (List.mem variable.name taken) -> variable
    | None ->
        let name = fresh variable.name 1 in
        let target = generated_variable name variable.sort in
        used := name :: !used;
        renamed := (variable, target) :: !renamed;
        target

let variable_names = List.map (fun (variable : variable) -> variable.name)

let variable_terms = List.map (fun variable -> Var variable)

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

(* The request sort and input count of an execution relation. *)
let execution_shape index relation =
  match Prescan.relation_policy index relation with
  | Ok (Prescan.Execution {request_sort; input_count}) -> request_sort, input_count
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

(* A focus needs the boundaries of its parts, not the result of executing them.
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
    | CaseE (op, payload, check) -> CaseE (op, recurse payload, check)
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

   An identifyFocus rule only has to find where a focus starts and ends in a
   sequence. It is derived from a rule of an inner relation, but keeps only
   the premises that decide this extent:

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
   relation, whose rules check all their premises. For the same reason no
   execution premise is kept: the request executes it after heating. *)

type focus_dependency =
  { premise : prem
  ; writes : Il.Free.Set.t
  ; reads : Il.Free.Set.t
  ; retain : bool
  }

let focus_premises index initial needed prems =
  let module S = Il.Free.Set in
  let free premise = Il.Free.(free_prem premise).varid in
  let boundary_variable exp =
    match exp.it with
    | VarE id when S.mem id.it needed -> S.singleton id.it
    | _ -> S.empty
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
          | Ok (Prescan.Execution _) -> none
          | Ok (Prescan.Compute {subsume = Some _; _})
            when Prem.known_args bound args && Prem.known bound head ->
              (* A known result is the subsumption check, as for Check. *)
              none
          | Ok (Prescan.Compute {input_count; _}) ->
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
      | ElsePr -> none
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


(* Names *)

(* Generated statements are named <relation>-<rule> after their source rule.
   An unnamed rule is numbered only if its relation has other rules. *)
let rule_name index (relation : Hintd.relation) ordinal rule =
  let id = Hintd.rule_id rule in
  Prescan.rel_name index relation.id
  ^ (if id.it <> "" then "-" ^ Prescan.sanitize id.it
     else if List.length relation.rules = 1 then ""
     else "-" ^ string_of_int (ordinal + 1))

(* Statement labels: the lowercase rule name with -heat, -next, or -cool, and
   focus-<rule> for an identifyFocus rule. *)
let stage_label index (relation : Hintd.relation) ordinal rule stage =
  String.lowercase_ascii (rule_name index relation ordinal rule) ^ "-" ^ stage

let rule_label index (relation : Hintd.relation) ordinal rule =
  let id = Hintd.rule_id rule in
  if id.it <> "" then String.lowercase_ascii (Prescan.sanitize id.it)
  else String.lowercase_ascii (rule_name index relation ordinal rule)

let focus_label index (pattern : Hintd.focus_pattern) =
  "focus-" ^ rule_label index pattern.source pattern.ordinal pattern.rule

(* Sequence contexts *)

(* The sequence context of an execution relation, if it has one. *)
let sequence_context index relation =
  match
    Prescan.contexts index
    |> List.filter (fun (context : Hintd.context) ->
         context.source.id.it = relation.it)
  with
  | [] -> None
  | [context] -> Some context
  | context :: _ -> unsupported context.rule.at
      "relation has more than one sequence context"

(* The operators of a sequence context are named after its relation when the
   script has more than one sequence context. *)
let helper index (context : Hintd.context) name =
  match Prescan.contexts index with
  | [_] -> name
  | _ -> name ^ "-" ^ Prescan.rel_name index context.source.id

(* {_|...|_}: the context variables before the hole, the configuration with
   the focus, and the context variables after it. *)
let target_operator (context : Hintd.context) =
  let arity = List.length context.left + 1 + List.length context.right in
  "{" ^ String.concat "|" (List.init arity (fun _ -> "_")) ^ "}"

(* The sequence of a configuration term and the configuration with another
   sequence in its place. *)
let split_config index (frame : Hintd.frame) config at =
  let constructor = Prescan.mixop_name index frame.Hintd.mixop in
  match config with
  | App (name, components) when name = constructor ->
      begin match List.nth_opt components frame.sequence_position with
      | Some sequence ->
          sequence,
          (fun replacement ->
            App (name, List.mapi
                   (fun position component ->
                     if position = frame.sequence_position then replacement
                     else component)
                   components))
      | None -> unsupported at
          "focused input has no sequence at its configuration position"
      end
  | Var _ | Const _ | App _ -> unsupported at
      "focused input does not match its configuration"

let rec flatten operator = function
  | App (name, args) when name = operator -> List.concat_map (flatten operator) args
  | term -> [term]

(* The context variables and the hole: the source variables of the sequence
   context rule, e.g. val*, instr*, and instr_1* of z; val* instr* instr_1*. *)
type slots =
  { left : variable list
  ; focus : variable
  ; right : variable list
  }

let slots index (context : Hintd.context) =
  let source (id, typ) = Prescan.source_variable index id typ in
  { left = List.map source context.left
  ; focus = source context.hole
  ; right = List.map source context.right
  }

(* The slots renamed apart from the variables that a statement already has. *)
let slots_apart taken slots =
  let all = slots.left @ [slots.focus] @ slots.right in
  let rename =
    rename_apart (variable_names taken) (variable_names (taken @ all))
  in
  { left = List.map rename slots.left
  ; focus = rename slots.focus
  ; right = List.map rename slots.right
  }

let focus_target index (context : Hintd.context) slots config =
  App (helper index context (target_operator context),
       variable_terms slots.left @ [config] @ variable_terms slots.right)

(* The relation of [context] can start on [input]: identifyFocus finds a focus
   in it. Its slots keep apart from the variables in [taken]. *)
let focus_condition index (context : Hintd.context) taken input =
  let slots = slots_apart taken (slots index context) in
  let _, rebuild = split_config index context.frame input context.rule.at in
  RewriteCond
    ( App (helper index context "identifyFocus", [input])
    , focus_target index context slots (rebuild (Var slots.focus)) )

(* The one input of a call of an execution relation. *)
let call_input index relation call at =
  let metadata = Prescan.sort_metadata index in
  let source = Hintd.find_relation metadata.relations relation at in
  match call with
  | App (_, args) ->
      begin match Mixop.split (List.length source.params) args with
      | Some (_, [input]) -> input
      | _ -> unsupported at "identifyFocus requires one relation input"
      end
  | Var _ | Const _ -> unsupported at "execution premise is not a relation call"

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
  let needed = boundary_variables index pattern.parts in
  let needed, kept =
    focus_premises index bound needed prems
  in
  let premises =
    Prem.translate_all index ~bound:(Il.Free.Set.elements bound)
      ~bind_membership:true ~collect_outputs:true kept
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
        | Var variable when not (same_term term shape) -> Some (variable, shape)
        | _ -> None)
      terms shapes
    |> List.filter_map Fun.id
  in
  relation_call index pattern.source shapes,
  List.map (substitute_condition bindings) conditions

let lift_bridge cache index (call, conditions) (bridge : Hintd.bridge) =
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
        let _, input_count = execution_shape index id in
        let inputs, _ = Prem.split input_count (Prem.components mixop head) in
        let patterns, guards =
          inputs |> List.map (fun input ->
            match Prem.translate_pattern_parts index input with
            | Some (pattern, guards) ->
                let expression = Term.translate_exp index input in
                let checks =
                  if same_term expression pattern then guards
                  else guards @ [EqCond (expression, pattern)]
                in pattern, List.map (fun guard -> EqCondition guard) checks
            | None -> unsupported input.at "bridge input has no structural pattern")
          |> List.split
        in
        App (target, List.map (Term.translate_arg index) args @ patterns),
        List.concat guards
    | _ -> unsupported bridge.premise.at "bridge premise is not a relation"
  in
  (* The bridge's variables are renamed apart from the pattern's. *)
  let bridge_conditions =
    RewriteCond (delegated, result) :: input_guards @ bridge_conditions
  in
  let pattern_variables =
    List.fold_left condition_variables (term_variables [] call) conditions
  in
  let bridge_variables =
    List.fold_left condition_variables (term_variables [] lowered.left)
      bridge_conditions
  in
  let rename =
    rename_apart (variable_names pattern_variables)
      (variable_names (pattern_variables @ bridge_variables))
  in
  let outer = map_term_variables rename lowered.left in
  let bridge_conditions =
    List.map (map_rule_condition_variables rename) bridge_conditions
  in
  let (delegated, _), bridge_conditions =
    delegated_condition bridge.premise.at target bridge_conditions
  in
  let bindings = unify bridge.premise.at [] delegated call in
  ( substitute bindings outer
  , List.map (substitute_condition bindings) bridge_conditions @ conditions
  )

let outer_call cache index (pattern : Hintd.focus_pattern) =
  List.fold_left
    (lift_bridge cache index)
    (shaped_relation_call index pattern)
    (List.rev pattern.bridges)

(* The input of a call of the context's relation. *)
let relation_input index (context : Hintd.context) call =
  match call with
  | App (name, _) when name = Prescan.rel_name index context.source.id ->
      call_input index context.source.id call context.rule.at
  | Var _ | Const _ | App _ -> unsupported context.rule.at
      "bridge chain does not end at the hinted context relation"

let request_sort index (context : Hintd.context) =
  fst (execution_shape index context.source.id)

let context_hole index (context : Hintd.context) =
  "hole-" ^ rule_name index context.source context.ordinal context.rule

let declarations index (context : Hintd.context) =
  let name = helper index context in
  let sorts = List.map (fun (_, typ) -> Term.translate_sort index typ) in
  let config_sort = Term.translate_sort index context.frame.config_typ in
  let request_sort = request_sort index context in
  let hole = context_hole index context in
  let hole_sort = String.capitalize_ascii hole in
  [ SortDecl (name "FocusSearch")
  ; SortDecl (name "FocusTarget")
  ; SortDecl hole_sort
  ; SubsortDecl (name "FocusTarget", name "FocusSearch")
  ; op ~attrs:[Frozen [1]] (name "identifyFocus") [config_sort] (name "FocusSearch")
  ; op ~attrs:[Ctor] (name (target_operator context))
      (sorts context.left @ [config_sort] @ sorts context.right)
      (name "FocusTarget")
  ; op ~attrs:[Ctor] hole (sorts context.left @ sorts context.right) hole_sort
  ; op ~attrs:[Frozen [2]] "_~>_" [request_sort; hole_sort] request_sort
  ]

(* One identifyFocus rule per focus pattern: the pattern's input sequence
   anywhere in the context's sequence.
     rl identifyFocus(C[l p r]) => {l | C[p] | r} .                         *)
let translate_pattern cache index (context : Hintd.context)
    (pattern : Hintd.focus_pattern) =
  let name = helper index context in
  let call, conditions = outer_call cache index pattern in
  let focus, rebuild =
    split_config index context.frame (relation_input index context call)
      pattern.rule.at
  in
  let slots =
    slots_apart
      (List.fold_left condition_variables (term_variables [] call) conditions)
      (slots index context)
  in
  let hole_typ = snd context.hole in
  let concat = (Prescan.sequence_representation index hole_typ).concat in
  let sequence =
    Term.sequence_of_typ index hole_typ
      (variable_terms slots.left @ flatten concat focus @ variable_terms slots.right)
  in
  let left = App (name "identifyFocus", [rebuild sequence]) in
  let right = focus_target index context slots (rebuild focus) in
  let conditions =
    try schedule_rule_conditions left conditions with
    | Unsupported reason ->
        unsupported pattern.rule.at
          ("focus of " ^ (Hintd.rule_id pattern.rule).it ^ ": " ^ reason)
  in
  rule ~label:(focus_label index pattern) left right conditions

(* The sequence context rule itself: heat at the focus that identifyFocus
   finds, and plug the inner result back between the context variables.
     crl R(C[XS]) => R'(C[x]) ~> hole-R-r(l, r)
       if identifyFocus(C[XS]) => {l | C[x] | r} /\ ... .
     eq c' ~> hole-R-r(l, r) = C'[l x' r] .                                 *)
let context_transitions index (context : Hintd.context) =
  let lowered =
    Reld.lower_execution_rule index context.source.id context.source.params
      (execution_policy index context.source.id) [] context.ordinal context.rule
  in
  let (inner_call, inner_result), remaining =
    delegated_condition context.rule.at
      (Prescan.rel_name index context.inner_relation) lowered.conditions
  in
  let _, rebuild =
    split_config index context.frame (relation_input index context lowered.left)
      context.rule.at
  in
  let slots = slots index context in
  (* The whole sequence, named after its element type: INSTRS for instr*. *)
  let sequence =
    let typ = snd context.hole in
    let name =
      match typ.it with
      | IterT ({it = VarT (id, _); _}, _) ->
          String.uppercase_ascii (Prescan.sanitize id.it) ^ "S"
      | _ -> "SEQUENCE"
    in
    let taken =
      variable_names
        (List.fold_left condition_variables
           (term_variables (term_variables [] lowered.left) lowered.right)
           lowered.conditions)
    in
    Var (rename_apart taken taken
           (generated_variable name (Term.translate_sort index typ)))
  in
  let left = relation_call index context.source [rebuild sequence] in
  (* The context rule's own variables are the slots: nothing to rename. *)
  let identify = focus_condition index context [] (rebuild sequence) in
  let conditions = schedule_rule_conditions left (identify :: remaining) in
  let hole =
    App (context_hole index context,
         variable_terms slots.left @ variable_terms slots.right)
  in
  let label = stage_label index context.source context.ordinal context.rule in
  [ rule ~label:(label "heat") left (App ("_~>_", [inner_call; hole])) conditions
  ; Eq (App ("_~>_", [inner_result; hole]), lowered.right, [Label (label "cool")])
  ]

let unlabeled attrs =
  List.filter (function Label _ -> false | Owise -> true) attrs

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
      | Eq (left, right, attrs) -> Eq (left, right, unlabeled attrs)
      | Ceq (left, right, conditions, attrs) ->
          Ceq (left, right, conditions, unlabeled attrs)
      | _ -> raise (Unsupported "expected a focus candidate or an equation")
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

(* Heated rules *)

let equational at conditions =
  conditions |> List.map (function
    | EqCondition condition -> condition
    | RewriteCond _ -> unsupported at "identify equation has a rewrite condition")

(* The start condition of a premise whose relation has no sequence context:
 * identifyFocus<Rule>(inputs) = true for an input that some rule of the relation
 * matches and whose input guards hold, the equational premises over the input
 * variables only (e.g. c =/= 0 of if-true). On any other input it stays
 * unreduced and the condition fails. The rule itself checks its other
 * premises when the suspended request executes. Returns the statements and
 * the condition; the helper is named after the source rule. *)
let identify_statements cache index (heated : Hintd.heatcool) target args =
  let RuleD (id, _, _, _, _) = heated.rule.it in
  let metadata = Prescan.sort_metadata index in
  let relation = Hintd.find_relation metadata.relations target heated.rule.at in
  let name =
    "identifyFocus"
    ^ (if id.it <> "" then String.capitalize_ascii (Prescan.sanitize id.it)
       else rule_name index heated.source heated.ordinal heated.rule)
  in
  let params, _, typ, _ = Il.Env.find_rel metadata.type_env target in
  let _, count = execution_shape index target in
  let input_types, _ = Prem.split count (Reld.component_types typ) in
  let domain = Param.translate_sorts index params
    @ List.map (Term.translate_sort index) input_types in
  let input_guards (candidate : Reld.execution_rule) =
    let bound = term_variables [] candidate.left in
    candidate.conditions |> List.filter (fun condition ->
      match condition with
      | EqCondition _ ->
          List.for_all (fun variable -> List.exists (same_variable variable) bound)
            (condition_variables [] condition)
      | RewriteCond _ -> false)
  in
  let equation (candidate : Reld.execution_rule) =
    let label =
      "focus-" ^ rule_label index heated.source heated.ordinal heated.rule ^ "-"
      ^ rule_label index relation candidate.ordinal
          (List.nth relation.rules candidate.ordinal)
    in
    match candidate.left with
    | App (_, inputs) ->
        let left = App (name, inputs) in
        let guards = schedule_rule_conditions left (input_guards candidate) in
        Maude_il.equation ~attrs:[Label label] left (Const "true")
          (equational heated.rule.at guards)
    | Var _ | Const _ ->
        unsupported heated.rule.at "lowered rule input is not a relation call"
  in
  op name domain "Bool"
  :: unique_candidates (List.map equation (lower_relation cache index relation)),
  [EqCondition (BoolCond (App (name, args)))]

(* The first execution premise heats only where its relation can start:
 * identifyFocus of the relation's sequence context finds a focus, or else an
 * identifyFocus<Rule> equation matches. *)
let start_condition cache index (heated : Hintd.heatcool) taken target call =
  match sequence_context index target, call with
  | Some context, _ ->
      [], [focus_condition index context taken
             (call_input index target call heated.rule.at)]
  | None, App (_, args) -> identify_statements cache index heated target args
  | None, (Var _ | Const _) ->
      unsupported heated.rule.at "execution premise is not a relation call"

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
  let outer_sort, _ = execution_shape index source.id in
  let executions =
    prems |> List.filter_map (fun prem -> match prem.it with
      | RulePr (target, _, _, _) ->
          begin match Prescan.relation_policy index target with
          | Ok (Prescan.Execution {request_sort; _}) -> Some (target, request_sort)
          | _ -> None
          end
      | IfPr _ | LetPr _ ->
          if Prem.prem_has_rewrite_call index prem then
            fail "rewrite-backed expression requires a separate hint contract";
          None
      | ElsePr | IterPr _ ->
          fail "unsupported premise under k_heatcool")
  in
  let body =
    Reld.lower_rule_body ~head:(Prescan.rel_name index source.id)
      index source.id source.params policy heated.rule
  in
  if body.otherwise then fail "ElsePr requires an explicit complement";
  let suffix = rule_name index source heated.ordinal heated.rule in
  let label = stage_label index source heated.ordinal heated.rule in
  let bound_condition variables = function
    | RewriteCond (_, pattern) | EqCondition (MatchCond (pattern, _)) ->
        term_variables variables pattern
    | EqCondition _ -> variables
  in
  let rec before_execution equations = function
    | EqCondition condition :: rest -> before_execution (condition :: equations) rest
    | rest -> List.rev equations, rest
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
        [equation ~attrs:[Label (label "cool")] left body.right guards]
    | RewriteCond (call, result) :: rest, (target, inner_sort) :: targets ->
        if not (variables_bound bound call) then
          fail "RulePr input is not bound before split";
        let needed = List.fold_left condition_variables
            (term_variables (term_variables [] body.right) result) rest in
        let captures = List.filter
            (fun variable -> List.exists (same_variable variable) needed) bound in
        (* With several execution premises, a hole is named after the relation
           of the premise it waits for, numbered only if that repeats. *)
        let stage_suffix =
          let same (other, _) = other.it = target.it in
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
        let transition =
          if initial then
            let statements, start =
              start_condition cache index heated
                (term_variables (term_variables [] left) call) target call
            in
            statements
            @ [rule ~label:(label "heat") left suspended
                 (List.map (fun guard -> EqCondition guard) guards @ start)]
          else [equation ~attrs:[Label (label "next")] left suspended guards]
        in
        [ SortDecl sort
        ; op ~attrs:[Ctor] name (List.map (fun variable -> variable.sort) captures) sort
        ; op ~attrs:[Frozen [2]] "_~>_" [inner_sort; sort] outer_sort
        ] @ transition
        @ resume false (stage + 1) returned rest targets
    | _ -> fail "lowered execution conditions do not match direct RulePr premises"
  in
  resume true 1 body.left body.conditions executions

(* The statements for the hint(k_heatcool) rules of one relation. *)
let translate_relation index id =
  let cache = Hashtbl.create 4 in
  let sequence =
    match sequence_context index id with
    | None -> []
    | Some context ->
        declarations index context
        @ (context.patterns
           |> List.map (translate_pattern cache index context)
           |> unique_candidates)
        @ context_transitions index context
  in
  let heated =
    Prescan.heatcool index
    |> List.filter (fun (heated : Hintd.heatcool) ->
         heated.source.id.it = id.it
         && not (Prescan.is_context_rule index heated.source.id heated.rule))
    |> List.concat_map (heatcool_rule cache index)
  in
  sequence @ heated
