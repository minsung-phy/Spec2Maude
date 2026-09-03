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

let context_candidates : term list ref = ref []
let public_step_rules : execution_rule list ref = ref []

let reset_optimization () =
  context_candidates := [];
  public_step_rules := []

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

let execution_label id rule =
  Some
    (String.lowercase_ascii (Prescan.sanitize id.it)
     ^ "-" ^ string_of_int (rule.ordinal + 1))

let execution_statement id rule =
  match rule.conditions with
  | [] -> Rl (execution_label id rule, rule.left, rule.right)
  | conditions ->
      Crl (execution_label id rule, rule.left, rule.right, conditions)

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

let translate_execution ?request_output index id params typ policy rules =
  let input_count =
    match policy with
    | Prescan.Execution {input_count; _} -> input_count
    | Prescan.Equation _ | Prescan.Predicate | Prescan.BackendCheck
    | Prescan.BackendCompute _ ->
        invalid_arg "expected an execution relation policy"
  in
  let lowered =
    rules
    |> List.mapi (fun ordinal rule -> ordinal, rule)
    |> List.fold_left
         (fun previous (ordinal, rule) ->
           let lowered =
             lower_execution_rule ?request_output index id params policy
               (List.rev previous) ordinal rule
           in
           lowered :: previous)
         []
    |> List.rev
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
  let first_shape rule =
    match rule.input_shapes with
    | [shape] -> shape
    | _ -> invalid_arg "context optimization expects one relation input"
  in
  begin match id.it with
  | "Step_pure" ->
      List.iter
        (fun rule ->
          let z = Var (generated_variable "ENABLE-Z" "SpectecTerminal") in
          context_candidates :=
            App ("_;_", [z; first_shape rule]) :: !context_candidates)
        lowered
  | "Step_read" ->
      List.iter
        (fun rule -> context_candidates := first_shape rule :: !context_candidates)
        lowered
  | "Step" ->
      public_step_rules := lowered;
      lowered
      |> List.filter (fun rule -> rule.ordinal >= 3)
      |> List.iter (fun rule ->
           context_candidates := first_shape rule :: !context_candidates)
  | _ -> ()
  end;
  let public_rules =
    if id.it = "Step" then
      List.filter (fun rule -> rule.ordinal <> 2) lowered
    else lowered
  in
  helpers @ List.map (execution_statement id) public_rules

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

let rec rename_step_call name = function
  | (Var _ | Const _) as term -> term
  | App ("Step", args) -> App (name, List.map (rename_step_call name) args)
  | App (op, args) -> App (op, List.map (rename_step_call name) args)

let rename_step_condition name = function
  | EqCondition (EqCond (left, right)) ->
      EqCondition
        (EqCond (rename_step_call name left, rename_step_call name right))
  | EqCondition (MatchCond (left, right)) ->
      EqCondition
        (MatchCond (rename_step_call name left, rename_step_call name right))
  | EqCondition (MembershipCond (term, sort)) ->
      EqCondition (MembershipCond (rename_step_call name term, sort))
  | EqCondition (BoolCond term) ->
      EqCondition (BoolCond (rename_step_call name term))
  | RewriteCond (left, right) ->
      RewriteCond (rename_step_call name left, rename_step_call name right)

let optimization_statements () =
  let var name sort = Var (generated_variable name sort) in
  let z = var "FOCUS-Z" "SpectecTerminal" in
  let z2 = var "FOCUS-Z2" "SpectecTerminal" in
  let config = var "FOCUS-CONFIG" "SpectecTerminal" in
  let result_config = var "FOCUS-RESULT-CONFIG" "SpectecTerminal" in
  let n = var "FOCUS-NUM" "Num" in
  let v = var "FOCUS-VEC" "Vec" in
  let r = var "FOCUS-REF" "Ref" in
  let i = var "FOCUS-INSTR" "Instr" in
  let prefix = var "FOCUS-PREFIX" "ValList" in
  let all = var "FOCUS-ALL" "InstrList" in
  let focus = var "FOCUS-BODY" "InstrList" in
  let rest = var "FOCUS-REST" "InstrList" in
  let suffix = var "FOCUS-SUFFIX" "InstrList" in
  let hole = var "FOCUS-HOLE" "ContextHole" in
  let enable term = App ("enable-step-direct", [term]) in
  let config_of state instrs = App ("_;_", [state; instrs]) in
  let start state values instrs = App ("scanStart", [state; values; instrs]) in
  let finish state values body remaining =
    App ("scanEnd", [state; values; body; remaining])
  in
  let target values state body remaining =
    App ("focusTarget", [values; state; body; remaining])
  in
  let candidates =
    List.rev !context_candidates
    |> List.map (fun candidate -> Eq (enable candidate, Const "true", []))
  in
  let private_rules =
    !public_step_rules
    |> List.filter (fun rule -> rule.ordinal <> 2)
    |> List.map (fun rule ->
         let left =
           match rule.left with
           | App ("Step", args) -> App ("fire-step", args)
           | _ -> invalid_arg "private Step rule has an unexpected head"
         in
         let right = rule.right in
         let conditions =
           if rule.ordinal >= 3 && rule.ordinal <= 5 then
             (* These are ctxt-label/handler/frame.  Their recursive Step
                premise is over the nested body, not the already-selected
                outer flat list, so retain the public atomic Step there. *)
             rule.conditions
           else
             List.map (rename_step_condition "fire-step") rule.conditions
         in
         let label = Some ("fire-step-" ^ string_of_int (rule.ordinal + 1)) in
         match conditions with
         | [] -> Rl (label, left, right)
         | _ -> Crl (label, left, right, conditions))
  in
  [ SortDecl "FireStepRequest"
  ; SubsortDecl ("SpectecTerminal", "FireStepRequest")
  ; OpDecl
      { name = "fire-step"; domain = ["SpectecTerminal"]
      ; codomain = "FireStepRequest"; arrow = Total; attrs = [Frozen [1]] }
  ; OpDecl
      { name = "enable-step-direct"; domain = ["SpectecTerminal"]
      ; codomain = "Bool"; arrow = Total; attrs = [Frozen [1]] }
  ]
  @ candidates
  @ [ Eq (enable config, Const "false", [Owise])
    ; SortDecl "FocusSearch"
    ; SortDecl "FocusTarget"
    ; SubsortDecl ("FocusTarget", "FocusSearch")
    ; OpDecl
        { name = "find-focus"; domain = ["SpectecTerminal"]
        ; codomain = "FocusSearch"; arrow = Total; attrs = [Frozen [1]] }
    ; OpDecl
        { name = "scanStart"
        ; domain = ["SpectecTerminal"; "ValList"; "InstrList"]
        ; codomain = "FocusSearch"; arrow = Total; attrs = [Ctor] }
    ; OpDecl
        { name = "scanEnd"
        ; domain =
            ["SpectecTerminal"; "ValList"; "InstrList"; "InstrList"]
        ; codomain = "FocusSearch"; arrow = Total; attrs = [Ctor] }
    ; OpDecl
        { name = "focusTarget"
        ; domain =
            ["ValList"; "SpectecTerminal"; "InstrList"; "InstrList"]
        ; codomain = "FocusTarget"; arrow = Total; attrs = [Ctor] }
    ; Rl
        ( Some "focus-init"
        , App ("find-focus", [config_of z all])
        , start z (Const "valNil") all )
    ; Rl
        ( Some "focus-start-here"
        , start z prefix (App ("instrConcat", [i; rest]))
        , finish z prefix i rest )
    ; Rl
        ( Some "focus-skip-one-num"
        , start z prefix (App ("instrConcat", [n; rest]))
        , start z (App ("valConcat", [prefix; n])) rest )
    ; Rl
        ( Some "focus-skip-one-vec"
        , start z prefix (App ("instrConcat", [v; rest]))
        , start z (App ("valConcat", [prefix; v])) rest )
    ; Rl
        ( Some "focus-skip-one-ref"
        , start z prefix (App ("instrConcat", [r; rest]))
        , start z (App ("valConcat", [prefix; r])) rest )
    ; Rl
        ( Some "focus-extend-one"
        , finish z prefix focus (App ("instrConcat", [i; suffix]))
        , finish z prefix (App ("instrConcat", [focus; i])) suffix )
    ; Crl
        ( Some "focus-found"
        , finish z prefix focus suffix
        , target prefix z focus suffix
        , [ EqCondition
              (EqCond (enable (config_of z focus), Const "true"))
          ; EqCondition
              (BoolCond
                 (App
                    ( "_or_"
                    , [ App ("_=/=_", [prefix; Const "valNil"])
                      ; App ("_=/=_", [suffix; Const "instrNil"])
                      ] )))
          ] )
    ; SortDecl "ContextHole"
    ; SortDecl "HeatSearch"
    ; SortDecl "Heated"
    ; SubsortDecl ("Heated", "HeatSearch")
    ; OpDecl
        { name = "contextHole"; domain = ["ValList"; "InstrList"]
        ; codomain = "ContextHole"; arrow = Total; attrs = [Ctor] }
    ; OpDecl
        { name = "heat"; domain = ["SpectecTerminal"]
        ; codomain = "HeatSearch"; arrow = Total; attrs = [Frozen [1]] }
    ; OpDecl
        { name = "_~>_"; domain = ["SpectecTerminal"; "ContextHole"]
        ; codomain = "Heated"; arrow = Total; attrs = [Ctor; Frozen [2]] }
    ; Crl
        ( Some "heating-ctxt-instrs"
        , App ("heat", [config_of z all])
        , App ("_~>_", [config_of z focus; App ("contextHole", [prefix; suffix])])
        , [ RewriteCond
              ( App ("find-focus", [config_of z all])
              , target prefix z focus suffix ) ] )
    ; OpDecl
        { name = "cool"; domain = ["ContextHole"; "SpectecTerminal"]
        ; codomain = "SpectecTerminal"; arrow = Partial; attrs = [] }
    ; Eq
        ( App
            ( "cool"
            , [App ("contextHole", [prefix; suffix]); config_of z2 rest] )
        , config_of z2
            (App
               ( "instrConcat"
               , [ App ("valsToInstrs", [prefix])
                 ; App ("instrConcat", [rest; suffix])
                 ] ))
        , [] )
    ]
  @ private_rules
  @ [ Crl
        ( Some "step-ctxt-instrs-optimized"
        , App ("Step", [config])
        , App ("cool", [hole; result_config])
        , [ RewriteCond
              ( App ("heat", [config])
              , App ("_~>_", [config_of z focus; hole]) )
          ; RewriteCond
              ( App ("fire-step", [config_of z focus])
              , result_config )
          ] )
    ]
let translate ?request_output index id params _mixop typ rules =
  match Prescan.relation_policy index id with
  | Error _ -> []
  | Ok policy ->
      let declarations = translate_decl index id params typ policy in
      match policy with
      | Prescan.BackendCheck | Prescan.BackendCompute _ -> declarations
      | Prescan.Execution _ ->
          declarations
          @ translate_execution ?request_output index id params typ
              policy rules
      | Prescan.Equation _ | Prescan.Predicate ->
          declarations
          @ List.map
              (translate_rule ?request_output index id params policy)
              rules
