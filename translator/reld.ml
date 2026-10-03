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

(* Keep constructors around computed fields. A function call is checked only
 * after its arguments and its result field are bound by the input pattern. *)
let translate_input_pattern index exp =
  match Prem.translate_pattern index exp with
  | Some pattern -> Some pattern
  | None ->
      let deferred = ref [] in
      let computed exp =
        if Prem.has_rewrite_call index exp then None
        else
          let subject =
            Var
              (generated_variable "INPUT-FIELD"
                 (Term.translate_sort index exp.note))
          in
          deferred := (exp, subject) :: !deferred;
          Some (Prem.pattern subject)
      in
      match Prem.translate_pattern ~computed index exp with
      | None -> None
      | Some pattern ->
          let bound = term_variables [] pattern.term in
          let equalities =
            List.rev !deferred
            |> List.map (fun (exp, subject) -> Term.translate_exp index exp, subject)
          in
          if List.for_all
              (fun (value, subject) ->
                variables_bound bound value && variables_bound bound subject)
              equalities then
            Some
              { pattern with
                guards = pattern.guards
                  @ List.map (fun (value, subject) -> EqCond (value, subject))
                      equalities
              }
          else None

(* With defer, an input that is no pattern over the earlier inputs is
 * compared with its value after the premises have bound its variables. *)
let translate_inputs ~defer index params inputs =
  let bound = Il.Free.(bound_params params).varid in
  let step (terms, conditions, bound, deferred) (position, exp) =
    match translate_input_pattern index exp with
    | Some {term; guards} ->
        ( term :: terms
        , conditions @ List.map (fun guard -> EqCondition guard) guards
        , Prem.bind bound exp
        , deferred )
    | None ->
        let subject =
          Var
            (generated_variable
               ("REL-INPUT" ^ string_of_int (position + 1))
               (Term.translate_sort index exp.note))
        in
        match
          Prem.bind_pattern index bound exp subject
            "relation input is not a structural pattern"
        with
        | binding ->
            subject :: terms, conditions @ binding.conditions, binding.bound, deferred
        | exception Invalid_argument _ when defer ->
            subject :: terms, conditions, bound, (exp, subject) :: deferred
  in
  List.mapi (fun position exp -> position, exp) inputs
  |> List.fold_left step ([], [], bound, [])
  |> fun (terms, conditions, bound, deferred) ->
       List.rev terms, conditions, bound, List.rev deferred

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

(* Equational conditions are evaluated before rewrite conditions when both
 * are ready. *)
let schedule_rule_conditions =
  schedule_conditions (fun _ -> function
    | EqCondition _ -> true
    | RewriteCond _ -> false)

let eq_conditions conditions =
  List.map
    (function
      | EqCondition condition -> condition
      | RewriteCond _ ->
          invalid_arg "an equation relation cannot use a rewrite condition")
    conditions

type rule_body =
  { input_exps : exp list
  ; input_terms : term list
  ; head_conditions : rule_condition list
  ; guard_conditions : rule_condition list
  ; left : term
  ; right : term
  ; conditions : rule_condition list
  ; otherwise : bool
  }

let lower_rule_body ~head index id params policy rule =
  match rule.it with
  | RuleD (_, quants, mixop, exp, prems) ->
      let exps = Prem.components mixop exp in
      let inputs, outputs =
        match policy with
        | Prescan.Execution {input_count; _}
        | Prescan.Compute {input_count; _} -> Prem.split input_count exps
        | Prescan.Check _ -> exps, []
      in
      let index = Term.with_relation_types index id params inputs in
      let defer = match policy with Prescan.Check _ -> true | _ -> false in
      let input_terms, head_conditions, bound, deferred =
        translate_inputs ~defer index params inputs
      in
      let immediate =
        List.filter (fun exp -> not (List.exists (fun (e, _) -> e == exp) deferred)) inputs
      in
      if not (List.for_all (Prem.known bound) immediate) then
        invalid_arg "relation rule has an unbound input";
      let left =
        App
          ( head
          , Param.translate_terms index params @ input_terms
          )
      in
      let premises =
        Prem.translate_all index
          ~bound:(Il.Free.Set.elements bound)
          ~bind_membership:(match policy with Prescan.Execution _ -> true | _ -> false)
          ~collect_outputs:true
          prems
      in
      if not (List.for_all (Prem.known premises.bound) outputs) then
        invalid_arg "relation output contains an unbound variable";
      let deferred_conditions =
        List.concat_map
          (fun (exp, subject) ->
            let bound, choices =
              Prem.bind_free_indices index premises.bound [] exp
            in
            if not (Prem.known bound exp) then
              invalid_arg "relation input is not a structural pattern";
            choices
            @ [EqCondition (EqCond (Term.translate_exp index exp, subject))])
          deferred
      in
      (* Reachable relation calls establish direct inputs and premise results. *)
      let proven = premises.bound in
      let quant_conditions =
        List.map (fun condition -> EqCondition condition)
          (Param.translate_eq_conditions ~proven index quants)
      in
      let guard_conditions = head_conditions @ quant_conditions in
      let conditions =
        head_conditions @ premises.conditions @ deferred_conditions
        @ quant_conditions
      in
      { input_exps = inputs
      ; input_terms
      ; head_conditions
      ; guard_conditions
      ; left
      ; right =
          Prem.tuple index outputs
            (List.map (Term.translate_exp index) outputs)
      ; conditions
      ; otherwise = premises.otherwise
      }

let translate_rule ~head index id params policy rule =
  let body = lower_rule_body ~head index id params policy rule in
  if body.otherwise then
    invalid_arg "ElsePr in a relation rule requires source complement lowering";
  let right =
    match policy with
    | Prescan.Execution _ ->
        invalid_arg "execution relations require source-order lowering"
    | Prescan.Compute _ -> body.right
    | Prescan.Check _ -> Const "true"
  in
  match eq_conditions (schedule_rule_conditions body.left body.conditions) with
  | [] -> Eq (body.left, right, [])
  | conditions -> Ceq (body.left, right, conditions, [])


type execution_rule =
  { ordinal : int
  ; input_exps : exp list
  ; inputs : term list
  ; input_shapes : term list
  ; left : term
  ; right : term
  ; conditions : rule_condition list
  ; guard_conditions : rule_condition list
  ; predecessors : int list
  }

(* A typed sequence variable cannot absorb a constructor outside its source
 * element type. Keep unknown/type-parameter cases conservative. *)
let rec source_constructors index seen typ =
  let collect types =
    List.fold_left
      (fun known typ ->
        match known, source_constructors index seen typ with
        | Some left, Some right -> Some (left @ right)
        | _ -> None)
      (Some []) types
  in
  match typ.it with
  | VarT (id, [])
    when not (List.mem id.it seen)
      && not (List.exists (( == ) id) index.Prescan.type_parameters) ->
      begin match List.assoc_opt id.it index.Prescan.type_definitions with
      | None -> None
      | Some insts ->
          List.fold_left
            (fun known inst ->
              let constructors =
                match inst.it with
                | InstD (_, _, {it = AliasT typ; _}) ->
                    source_constructors index (id.it :: seen) typ
                | InstD (_, _, {it = StructT _; _}) -> Some []
                | InstD (_, _, {it = VariantT cases; _}) ->
                    List.fold_left
                      (fun known (mixop, (typ, _, _), _) ->
                        let constructors =
                          if Mixop.is_hole_only mixop then
                            source_constructors index (id.it :: seen) typ
                          else Some [mixop]
                        in
                        match known, constructors with
                        | Some left, Some right -> Some (left @ right)
                        | _ -> None)
                      (Some []) cases
              in
              match known, constructors with
              | Some left, Some right -> Some (left @ right)
              | _ -> None)
            (Some []) insts
      end
  | VarT _ -> None
  | IterT (typ, _) -> source_constructors index seen typ
  | TupT fields -> collect (List.map snd fields)
  | BoolT | NumT _ | TextT -> Some []

let rec source_pattern exp =
  match exp.it with
  | SubE (inner, _, _) -> source_pattern inner
  | CaseE (mixop, {it = TupE [inner]; _}) when Mixop.is_hole_only mixop ->
      source_pattern inner
  | CaseE (mixop, inner) when Mixop.is_hole_only mixop -> source_pattern inner
  | _ -> exp

let source_accepts index typ mixop =
  match source_constructors index [] typ with
  | None -> true
  | Some constructors -> List.exists (Il.Eq.eq_mixop mixop) constructors

let rec source_overlap index left right =
  let left, right = source_pattern left, source_pattern right in
  match left.it, right.it with
  | CaseE (op, payload), CaseE (op', payload') ->
      Il.Eq.eq_mixop op op' && source_overlap index payload payload'
  | TupE lefts, TupE rights when List.length lefts = List.length rights ->
      List.for_all2 (source_overlap index) lefts rights
  | _ when (match left.note.it, right.note.it with
             | IterT _, IterT _ -> true | _ -> false) ->
      let lefts, rights = source_elements left, source_elements right in
      let covered elements = function
        | None, _ -> true
        | Some exp, _ -> List.exists (source_element_overlap index (Some exp, exp.note)) elements
      in
      List.for_all (covered rights) lefts && List.for_all (covered lefts) rights
  | VarE _, CaseE (mixop, _) -> source_accepts index left.note mixop
  | CaseE (mixop, _), VarE _ -> source_accepts index right.note mixop
  | _ -> true

and source_elements exp =
  let exp = source_pattern exp in
  match exp.it with
  | ListE exps -> List.map (fun exp -> Some exp, exp.note) exps
  | CatE (left, right) -> source_elements left @ source_elements right
  | OptE None -> []
  | OptE (Some inner) -> [Some inner, inner.note]
  | IterE (inner, _) -> [None, inner.note]
  | _ ->
      begin match exp.note.it with
      | IterT (typ, _) -> [None, typ]
      | _ -> [Some exp, exp.note]
      end

and source_element_overlap index (left, left_typ) (right, right_typ) =
  match left, right with
  | Some left, Some right -> source_overlap index left right
  | Some exp, None | None, Some exp ->
      let exp = source_pattern exp in
      begin match exp.it with
      | CaseE (mixop, _) ->
          source_accepts index (if Option.is_none left then left_typ else right_typ) mixop
      | _ -> true
      end
  | None, None -> true

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

let rec may_overlap sequences left right =
  let is_sequence name = List.mem_assoc name sequences in
  let rec parts = function
    | App (name, args) when is_sequence name -> List.concat_map parts args
    | Const name when List.exists (fun (_, empty) -> name = empty) sequences -> []
    | term -> [term]
  in
  let rec fixed_prefix left right =
    match left, right with
    | [], _ | _, [] | Var _ :: _, _ | _, Var _ :: _ -> true
    | left :: lefts, right :: rights ->
        may_overlap sequences left right && fixed_prefix lefts rights
  in
  match left, right with
  | Var _, _ | _, Var _ -> true
  (* A sequence pattern can match across argument boundaries, including the
   * empty sequence. Only compare fixed prefixes/suffixes up to a variable. *)
  | _ when List.exists
      (function App (name, _) -> is_sequence name | Const _ | Var _ -> false)
      [left; right] ->
      let lefts, rights = parts left, parts right in
      fixed_prefix lefts rights
      && fixed_prefix (List.rev lefts) (List.rev rights)
  | Const left, Const right -> left = right
  | App (left, left_args), App (right, right_args) ->
      left = right
      && List.length left_args = List.length right_args
      && List.for_all2 (may_overlap sequences) left_args right_args
  | Const _, App _ | App _, Const _ -> false

let inputs_may_overlap index left right =
  let metadata = index.Prescan.sort_metadata in
  let sequences =
    ("_ _", "eps") :: List.map
      (fun owner ->
        let representation = Hintd.typed_sequence_representation metadata owner in
        representation.concat, representation.empty)
      (Hintd.typed_list_sorts metadata)
  in
  List.length left = List.length right
  && List.for_all2 (may_overlap sequences) left right

let helper_call index id params ordinal inputs =
  App
    ( Prescan.relation_enabled_helper index id ordinal
    , Param.translate_terms index params @ inputs
    )

let rec same_term left right =
  match left, right with
  | Var left, Var right -> same_variable left right
  | Const left, Const right -> left = right
  | App (left, lefts), App (right, rights) ->
      left = right && List.length lefts = List.length rights
      && List.for_all2 same_term lefts rights
  | _ -> false

let same_condition left right =
  match left, right with
  | EqCondition (BoolCond left), EqCondition (BoolCond right) ->
      same_term left right
  | EqCondition (EqCond (left, right)), EqCondition (EqCond (left', right')) ->
      same_term left left' && same_term right right'
  | _ -> false

(* Only identical structural positions are aligned. Do not choose an arbitrary
 * associative split, or replace a narrower variable by a wider-sort subject. *)
let align_inputs ?(sequences = false) ?(bindings = []) index params patterns subjects =
  let sequence_sorts =
    "SpectecTerminals"
    :: List.map
         (fun owner ->
           (Hintd.typed_sequence_representation index.Prescan.sort_metadata owner).sort)
         (Hintd.typed_list_sorts index.Prescan.sort_metadata)
  in
  let rec align bindings pattern subject =
    match pattern, subject with
    | Var variable, Var subject
      when variable.sort = subject.sort
           && (sequences || not (List.mem variable.sort sequence_sorts)) ->
        begin match List.find_opt (fun (v, _) -> same_variable v variable) bindings with
        | None -> Some ((variable, subject) :: bindings)
        | Some (_, previous) when same_variable previous subject -> Some bindings
        | Some _ -> None
        end
    | Const left, Const right when left = right -> Some bindings
    | App (left, lefts), App (right, rights)
      when left = right && List.length lefts = List.length rights ->
        align_list bindings lefts rights
    | _ -> None
  and align_list bindings patterns subjects =
    match patterns, subjects with
    | [], [] -> Some bindings
    | pattern :: patterns, subject :: subjects ->
        begin match align bindings pattern subject with
        | None -> None
        | Some bindings -> align_list bindings patterns subjects
        end
    | _ -> None
  in
  let fixed =
    Param.translate_terms index params
    |> List.fold_left term_variables []
    |> List.map (fun variable -> variable, variable)
  in
  align_list (fixed @ bindings) patterns subjects

let aligned_condition bindings condition =
  map_rule_condition_variables
    (fun variable ->
      match List.find_opt (fun (v, _) -> same_variable v variable) bindings with
      | Some (_, replacement) -> replacement
      | None -> variable)
    condition

let bool_combine name identity left right =
  let absorbing = if identity = "true" then "false" else "true" in
  if same_term left (Const identity) then right
  else if same_term right (Const identity) then left
  else if same_term left (Const absorbing) || same_term right (Const absorbing) then
    Const absorbing
  else if same_term left right then left
  else App (name, [left; right])

let rec total_number = function
  | Var variable -> List.mem variable.sort ["Nat"; "Int"; "Rat"]
  | Const number ->
      let digits =
        if String.length number > 0 && number.[0] = '-' then
          String.sub number 1 (String.length number - 1)
        else number
      in
      String.length digits > 0
      && String.for_all (fun c -> c >= '0' && c <= '9') digits
  | App (("_+_" | "_-_" | "_*_"), args) -> List.for_all total_number args
  | _ -> false

let rec total_comparison = function
  | Const ("true" | "false") | App (("_==_" | "_=/=_"), _) -> true
  | App (("_<_" | "_<=_" | "_>_" | "_>=_"), args) ->
      List.for_all total_number args
  | App (("_and_" | "_or_"), args) -> List.for_all total_comparison args
  | App ("not_", [inner]) -> total_comparison inner
  | _ -> false

let rec negate_comparison = function
  | Const "true" -> Const "false"
  | Const "false" -> Const "true"
  | App ("_==_", args) -> App ("_=/=_", args)
  | App ("_=/=_", args) -> App ("_==_", args)
  | App ("_and_", [left; right])
    when total_comparison left && total_comparison right ->
      bool_combine "_or_" "false" (negate_comparison left) (negate_comparison right)
  | App ("_or_", [left; right])
    when total_comparison left && total_comparison right ->
      bool_combine "_and_" "true" (negate_comparison left) (negate_comparison right)
  | App (("_<_" | "_<=_" | "_>_" | "_>=_" as op), args)
    when List.for_all total_number args ->
      let opposite =
        match op with
        | "_<_" -> "_>=_" | "_<=_" -> "_>_"
        | "_>_" -> "_<=_" | _ -> "_<_"
      in
      App (opposite, args)
  | App ("not_", [inner]) when total_comparison inner -> inner
  | predicate ->
      (* An unsuccessful condition includes a residual partial comparison.
       * Bool not / numeric duals would leave that case stuck, unlike [owise]. *)
      App ("_=/=_", [predicate; Const "true"])

(* Identical matches can share their outputs only when the structural match
 * has a unique decomposition. In particular, two sequence holes must retain
 * existential enabledness instead of testing one arbitrary split. *)
let unique_match_pattern index pattern =
  let metadata = index.Prescan.sort_metadata in
  let families =
    ("_ _", "SpectecTerminals") :: ("_;_", "RecordFields")
    :: List.map
         (fun owner ->
           let sequence = Hintd.typed_sequence_representation metadata owner in
           sequence.concat, sequence.sort)
         (Hintd.typed_list_sorts metadata)
  in
  let rec unique = function
    | Var _ | Const _ -> true
    | App (name, args) ->
        let rec parts = function
          | App (op, args) when op = name -> List.concat_map parts args
          | term -> [term]
        in
        let holes =
          match List.assoc_opt name families with
          | None -> 0
          | Some sort ->
              List.concat_map parts args
              |> List.filter
                   (function Var variable -> variable.sort = sort | _ -> false)
              |> List.length
        in
        holes <= 1 && List.for_all unique args
  in
  unique pattern

let direct_complement ~complements index params available inputs predecessor =
  match align_inputs index params predecessor.inputs inputs with
  | None -> None
  | Some bindings ->
      (* A fallback's pure bindings may be used before its complement, but not
       * bindings after an execution premise. *)
      let rec pure_prefix = function
        | EqCondition _ as condition :: rest -> condition :: pure_prefix rest
        | RewriteCond _ :: _ | [] -> []
      in
      let available = pure_prefix available in
      let aligned bindings condition =
        let condition = aligned_condition bindings condition in
        match List.find_opt (fun (helper, _) -> same_condition helper condition) complements with
        | Some (_, direct) -> direct
        | None -> condition
      in
      let implied bindings condition =
        List.exists (same_condition (aligned bindings condition)) available
      in
      let bound =
        List.fold_left term_variables [] (Param.translate_terms index params @ inputs)
        |> fun bound -> List.fold_left
             (fun bound -> function
               | EqCondition (MatchCond (pattern, _)) -> term_variables bound pattern
               | _ -> bound)
             bound available
      in
      let rec negate bindings result = function
        | [] ->
            if List.for_all (implied bindings) predecessor.guard_conditions then Some result
            else None
        | EqCondition (MatchCond (pattern, subject)) :: conditions ->
            let subject =
              match aligned_condition bindings (EqCondition (MatchCond (pattern, subject))) with
              | EqCondition (MatchCond (_, subject)) -> subject
              | _ -> assert false
            in
            let shared =
              if not (unique_match_pattern index pattern) then None else
              List.find_map
                (function
                  | EqCondition (MatchCond (pattern', subject'))
                    when same_term subject subject' && unique_match_pattern index pattern' ->
                      align_inputs ~sequences:true ~bindings index params [pattern] [pattern']
                  | _ -> None)
                available
            in
            begin match shared with
            | None -> None
            | Some bindings -> negate bindings result conditions
            end
        | condition :: conditions when implied bindings condition ->
            negate bindings result conditions
        | EqCondition (BoolCond predicate) :: conditions ->
            begin match aligned bindings (EqCondition (BoolCond predicate)) with
            | EqCondition (BoolCond predicate) when variables_bound bound predicate ->
                negate bindings (bool_combine "_or_" "false" result (negate_comparison predicate)) conditions
            | _ -> None
            end
        | EqCondition (EqCond (left, right)) :: conditions ->
            begin match aligned bindings (EqCondition (EqCond (left, right))) with
            | EqCondition (EqCond (left, right))
              when variables_bound bound left && variables_bound bound right ->
                negate bindings (bool_combine "_or_" "false" result
                          (App ("_=/=_", [left; right]))) conditions
            | _ -> None
            end
        | _ -> None
      in
      negate bindings (Const "false") predecessor.conditions

let complement_conditions index id params inputs available predecessors =
  let step (conditions, helpers, complements) predecessor =
    let helper = EqCondition (EqCond
      (helper_call index id params predecessor.ordinal inputs, Const "false")) in
    match direct_complement ~complements index params (available @ conditions) inputs predecessor with
    | Some predicate ->
        let direct = EqCondition (BoolCond predicate) in
        conditions @ [direct], helpers, (helper, direct) :: complements
    | None ->
        conditions @ [helper], helpers @ [predecessor.ordinal], complements
  in
  let conditions, helpers, _ = List.fold_left step ([], [], []) predecessors in
  conditions, helpers

let lower_execution_rule index id params policy
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
  let body =
    lower_rule_body ~head:(Prescan.rel_name index id)
      index id params policy rule
  in
  let conditions = schedule_rule_conditions body.left body.conditions in
  let input_shapes = input_shapes body.head_conditions body.input_terms in
  let predecessors =
    if body.otherwise then
      List.filter
        (fun predecessor ->
          List.for_all2 (source_overlap index) body.input_exps predecessor.input_exps
          && inputs_may_overlap index input_shapes predecessor.input_shapes)
        previous
    else []
  in
  if body.otherwise && previous = [] then
    invalid_arg "otherwise execution rule has no predecessor";
  let complements, helpers =
    complement_conditions index id params body.input_terms conditions predecessors
  in
  { ordinal
  ; input_exps = body.input_exps
  ; inputs = body.input_terms
  ; input_shapes
  ; left = body.left
  ; right = body.right
  ; conditions = complements @ conditions
  ; guard_conditions = body.guard_conditions
  ; predecessors = helpers
  }

let execution_statement rule =
  (* A helper may rely on the caller's domain. Check those automatic guards
   * before invoking it, not merely somewhere in the same conjunction. *)
  let guards =
    List.filter
      (function EqCondition (BoolCond (App ("typecheck", _))) -> true | _ -> false)
      rule.guard_conditions
  in
  let conditions =
    guards
    @ List.filter
        (fun condition -> not (List.exists (same_condition condition) guards))
        rule.conditions
    |> schedule_rule_conditions rule.left
  in
  match conditions with
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

let helper_statements index id params input_sorts callers rule =
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
  let fallback =
    App (name, Param.translate_terms index params @ helper_inputs)
  in
  let left = App (name, Param.translate_terms index params @ rule.inputs) in
  let callers =
    List.filter (fun caller -> List.mem rule.ordinal caller.predecessors) callers
  in
  let redundant_guard condition =
    match condition with
    | EqCondition (BoolCond (App ("typecheck", _)))
      when List.exists (same_condition condition) rule.guard_conditions ->
        callers <> []
        && List.for_all
             (fun caller ->
               match align_inputs index params rule.inputs caller.inputs with
               | None -> false
               | Some bindings ->
                   List.exists
                     (same_condition (aligned_condition bindings condition))
                     caller.conditions)
             callers
    | _ -> false
  in
  let rule =
    {rule with conditions = List.filter (fun c -> not (redundant_guard c)) rule.conditions}
  in
  let conditions =
    helper_conditions id rule
    |> List.map (fun condition -> EqCondition condition)
    |> schedule_rule_conditions left
    |> eq_conditions
  in
  let enabled =
    match conditions with
    | [] -> Eq (left, Const "true", [])
    | conditions -> Ceq (left, Const "true", conditions, [])
  in
  [ declaration
  ; enabled
  ; Eq (fallback, Const "false", [Owise])
  ]

let lower_execution_rules ~include_rule
    index id params policy rules =
  rules
  |> List.mapi (fun ordinal rule -> ordinal, rule)
  |> List.filter (fun (_, rule) -> include_rule rule)
  |> List.fold_left
       (fun previous (ordinal, rule) ->
         let lowered =
           lower_execution_rule index id params policy
             (List.rev previous) ordinal rule
         in
         lowered :: previous)
       []
  |> List.rev

let translate_execution ~include_rule
    index id params typ policy rules =
  let input_count =
    match policy with
    | Prescan.Execution {input_count; _} -> input_count
    | Prescan.Compute _ | Prescan.Check _ ->
        invalid_arg "expected an execution relation policy"
  in
  let lowered =
    lower_execution_rules ~include_rule
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
    |> List.concat_map (helper_statements index id params input_sorts lowered)
  in
  helpers @ List.map execution_statement lowered

(* hint(maude_trans): Rel(.., h1, h2) holds by one step of another rule, or
 * by one such step to a listed witness h' followed by Rel(.., h', h2). Any
 * chain through listed witnesses regroups into this form, so only the first
 * premise needs the step operator. h' =/= h1 excludes the reflexive step,
 * which would repeat the query; h' =/= h2 excludes a reflexive tail. *)
let translate_trans index id params (trans : Prescan.trans) rule =
  match rule.it with
  | RuleD (rule_id, quants, mixop, exp, prems) ->
      let fail reason =
        Util.Error.error rule.at "translation"
          ("Unsupported: maude_trans " ^ id.it ^ "/" ^ rule_id.it ^ ": " ^ reason)
      in
      let conclusion = Prem.components mixop exp in
      (* The one conclusion position a premise replaces by a fresh variable. *)
      let replaced (args, comps) =
        if List.length comps <> List.length conclusion then None
        else
          match
            List.combine conclusion comps
            |> List.mapi (fun position pair -> position, pair)
            |> List.filter (fun (_, (left, right)) -> not (Il.Eq.eq_exp left right))
          with
          | [position, (_, ({it = VarE x; _} as middle))] ->
              Some (args, comps, position, x.it, middle)
          | _ -> None
      in
      let self prem =
        match prem.it with
        | RulePr (target, args, mixop, exp) when target.it = id.it ->
            replaced (args, Prem.components mixop exp)
        | _ -> None
      in
      let shape = "premises must be Rel(.., h1, h') and Rel(.., h', h2)" in
      let (args1, comps1, i, x, middle), (args2, comps2, j, y, _) =
        match List.map self prems with
        | [Some first; Some second] -> first, second
        | _ -> fail shape
      in
      if i = j || x <> y || Il.Free.Set.mem x Il.Free.(free_exp exp).varid then
        fail shape;
      let witness name =
        let source = String.map (function '_' -> '-' | char -> char) name in
        match
          source_constructors index [] middle.note
          |> Option.value ~default:[]
          |> List.find_opt (fun mixop ->
               Xl.Mixop.arity mixop = 0 && Mixop.name mixop = source)
        with
        | Some mixop -> Const (Prescan.mixop_name index mixop)
        | None -> fail ("witness " ^ name ^ " is not a nullary constructor of "
                        ^ Il.Print.string_of_typ middle.note)
      in
      let body =
        lower_rule_body ~head:(Prescan.rel_name index id) index id params
          (Prescan.Check {trans = None})
          {rule with it = RuleD (rule_id, quants, mixop, exp, [])}
      in
      let term = Term.translate_exp index in
      let middle_term = term middle in
      let call name args comps =
        App (name, List.map (Term.translate_arg index) args @ List.map term comps)
      in
      let rest sort = Var (generated_variable "WITNESSES" sort) in
      let conditions =
        [ EqCondition
            (MatchCond
               ( Term.sequence
                   [rest "SpectecTerminals"; middle_term; rest "SpectecTerminals"]
               , Term.sequence (List.map witness trans.witnesses) ))
        ; EqCondition (BoolCond (App ("_=/=_", [middle_term; term (List.nth conclusion j)])))
        ; EqCondition (BoolCond (App ("_=/=_", [middle_term; term (List.nth conclusion i)])))
        ; EqCondition (BoolCond (call trans.step args1 comps1))
        ; EqCondition (BoolCond (call (Prescan.rel_name index id) args2 comps2))
        ]
      in
      Ceq
        ( body.left
        , Const "true"
        , eq_conditions
            (schedule_rule_conditions body.left (body.conditions @ conditions))
        , [] )

let check_decl index name parameter_sorts types =
  OpDecl
    { name
    ; domain = parameter_sorts @ List.map (Term.translate_sort index) types
    ; codomain = "Bool"
    ; arrow = Partial
    ; attrs = []
    }

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
  | Prescan.Compute {input_count; subsume} ->
      let inputs, outputs = Prem.split input_count types in
      OpDecl
        { name = Prescan.rel_name index id
        ; domain = parameter_sorts @ List.map (Term.translate_sort index) inputs
        ; codomain = output_sort index outputs
        ; arrow = Partial
        ; attrs = []
        }
      :: (match subsume with
          | Some {check; _} -> [check_decl index check parameter_sorts types]
          | None -> [])
  | Prescan.Check {trans} ->
      check_decl index (Prescan.rel_name index id) parameter_sorts types
      :: (match trans with
          | Some {step; _} -> [check_decl index step parameter_sorts types]
          | None -> [])

(* Rel(xs) = true if Rel-step(xs): the rules other than maude_trans. *)
let step_bridge index id params typ step =
  let variables =
    Param.translate_terms index params
    @ List.mapi
        (fun position typ ->
          Var
            (generated_variable ("REL-ARG" ^ string_of_int (position + 1))
               (Term.translate_sort index typ)))
        (component_types typ)
  in
  Ceq
    ( App (Prescan.rel_name index id, variables)
    , Const "true"
    , [BoolCond (App (step, variables))]
    , [] )

let translate index id params _mixop typ rules =
  match Prescan.relation_policy index id with
  | Error _ -> []
  | Ok policy ->
      let declarations = translate_decl index id params typ policy in
      let name = Prescan.rel_name index id in
      let rule head policy r =
        translate_rule ~head index id params policy r
      in
      (* hint(k_heatcool) rules are translated by Heatcool. *)
      let include_rule rule = not (Prescan.is_heatcool_rule index id rule) in
      match policy with
      | Prescan.Execution _ ->
          declarations
          @ translate_execution ~include_rule index id params typ
              policy rules
      | Prescan.Compute {subsume = Some {subsume_rule; check}; _} ->
          declarations
          @ List.map
              (fun r ->
                if (Hintd.rule_id r).it = subsume_rule then
                  rule check (Prescan.Check {trans = None}) r
                else rule name policy r)
              rules
      | Prescan.Check {trans = Some trans} ->
          declarations
          @ step_bridge index id params typ trans.step
            :: List.map
                 (fun r ->
                   if (Hintd.rule_id r).it = trans.trans_rule then
                     translate_trans index id params trans r
                   else rule trans.step policy r)
                 rules
      | Prescan.Compute {subsume = None; _} | Prescan.Check {trans = None} ->
          declarations @ List.map (rule name policy) rules
