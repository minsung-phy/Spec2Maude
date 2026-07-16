open Il.Ast
open Util.Source

type source_rule =
  { identity : Source_rule_identity.rule
  ; relation_id : string
  ; rule_id : string option
  ; origin : Origin.t
  ; source_echo : string option
  ; head : exp
  ; prems : prem list
  }

type transitive_domain =
  { rule : source_rule
  ; domain_rel_id : string
  ; witness_source_id : string
  ; prefix_arity : int
  ; domain_premise : prem
  ; left_premise : prem
  ; right_premise : prem
  }

type finite_domain_plan =
  { cycle_rel_ids : string list
  ; candidate_source_ids : string list
  ; domain_premise : prem
  ; fuel_measure : string
  ; visited_key_source_ids : string list
  }

type closed_world_domain =
  { transitive : transitive_domain
  ; domain_plan : finite_domain_plan
  ; policy : string
  ; fuel_source_ids : string list
  ; visited_key_source_ids : string list
  }

type target_chain =
  { rule : source_rule
  ; target_rel_id : string
  ; witness_source_id : string
  ; prefix_arity : int
  ; recursive_premise : prem
  ; target_premise : prem
  ; guard_premises : prem list
  }

type recursion =
  | Acyclic
  | Finite_transitive of closed_world_domain
  | Target_guided_self of target_chain

type t =
  { recursion : recursion }

let acyclic =
  { recursion = Acyclic }

let recursion t =
  t.recursion

let key t =
  match t.recursion with
  | Acyclic -> "acyclic"
  | Finite_transitive domain ->
    String.concat
      ":"
      [ "finite-transitive"
      ; Source_rule_identity.rule_key domain.transitive.rule.identity
      ; domain.transitive.domain_rel_id
      ; domain.transitive.witness_source_id
      ; string_of_int domain.transitive.prefix_arity
      ; String.concat "," domain.domain_plan.cycle_rel_ids
      ; String.concat "," domain.domain_plan.candidate_source_ids
      ; domain.domain_plan.fuel_measure
      ; String.concat "," domain.fuel_source_ids
      ; String.concat "," domain.visited_key_source_ids
      ]
  | Target_guided_self target ->
    String.concat
      ":"
      [ "target-guided-self"
      ; Source_rule_identity.rule_key target.rule.identity
      ; target.target_rel_id
      ; target.witness_source_id
      ; string_of_int target.prefix_arity
      ; String.concat "|" (List.map Il.Print.string_of_prem target.guard_premises)
      ]

let closed_world_domain ?(cycle_rel_ids = []) (transitive : transitive_domain) =
  let fuel_source_ids = [ transitive.witness_source_id ] in
  let visited_key_source_ids =
    transitive.witness_source_id :: fuel_source_ids
    |> List.sort_uniq String.compare
  in
  let cycle_rel_ids =
    if cycle_rel_ids = [] then
      [ transitive.rule.relation_id ]
    else
      cycle_rel_ids |> List.sort_uniq String.compare
  in
  let domain_plan =
    { cycle_rel_ids
    ; candidate_source_ids = [ transitive.witness_source_id ]
    ; domain_premise = transitive.domain_premise
    ; fuel_measure = "candidate-domain-length"
    ; visited_key_source_ids
    }
  in
  { transitive
  ; domain_plan
  ; policy =
      "source-derived closed-world witness domain: domain premise candidates plus query/source terms"
  ; fuel_source_ids
  ; visited_key_source_ids
  }

let finite_transitive domain =
  { recursion = Finite_transitive domain }

let target_guided_self target =
  { recursion = Target_guided_self target }

let exp_components exp =
  match exp.it with
  | TupE components -> components
  | _ -> [ exp ]

let rec exp_equal left right =
  match left.it, right.it with
  | VarE left, VarE right -> String.equal left.it right.it
  | TupE left, TupE right -> list_equal exp_equal left right
  | _ -> false

and list_equal equal left right =
  List.length left = List.length right && List.for_all2 equal left right

let direct_var_source_id exp =
  match exp.it with
  | VarE id -> Some id.it
  | _ -> None

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
    |> List.concat_map (fun (id, typ) ->
      id.it :: typ_source_ids typ)
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

let contains_source_id source_id exp =
  exp_source_ids exp |> List.exists (String.equal source_id)

let strip_suffix2 components =
  match List.rev components with
  | second :: first :: rev_prefix -> Some (List.rev rev_prefix, first, second)
  | _ -> None

let strip_suffix1 components =
  match List.rev components with
  | last :: rev_prefix -> Some (List.rev rev_prefix, last)
  | [] -> None

let prefix_equal left right =
  List.length left = List.length right && List.for_all2 exp_equal left right

let rulepr_payload prem =
  match prem.it with
  | RulePr (rel_id, [], _mixop, exp) -> Some (rel_id.it, exp, prem)
  | RulePr (_, _ :: _, _, _) -> None
  | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> None

let rulepr_payloads prems =
  let rec loop acc = function
    | [] -> Some (List.rev acc)
    | prem :: prems ->
      (match rulepr_payload prem with
      | Some payload -> loop (payload :: acc) prems
      | None -> None)
  in
  loop [] prems

let recursive_pair_shape prefix a b w first second =
  match strip_suffix2 (exp_components first), strip_suffix2 (exp_components second) with
  | ( Some (prefix1, a1, w1)
    , Some (prefix2, w2, b2) )
    when prefix_equal prefix prefix1
         && prefix_equal prefix prefix2
         && exp_equal a a1
         && exp_equal w w1
         && exp_equal w w2
         && exp_equal b b2 ->
    true
  | _ -> false

let transitive_domain rule =
  match rulepr_payloads rule.prems with
  | None -> None
  | Some payloads ->
    (match payloads with
    | [ (dom_id, dom_exp, domain_premise)
      ; (left_id, left_exp, left_premise)
      ; (right_id, right_exp, right_premise)
      ] ->
      let recursive =
        [ left_id; right_id ]
        |> List.for_all (String.equal rule.relation_id)
      in
      let domain = not (String.equal rule.relation_id dom_id) in
      (match strip_suffix2 (exp_components rule.head), strip_suffix1 (exp_components dom_exp) with
      | Some (head_prefix, a, b), Some (dom_prefix, w)
        when recursive
             && domain
             && prefix_equal head_prefix dom_prefix
             && Option.is_some (direct_var_source_id w) ->
        (match direct_var_source_id w with
        | Some witness_source_id
          when (not (contains_source_id witness_source_id rule.head))
               && (recursive_pair_shape head_prefix a b w left_exp right_exp
                   || recursive_pair_shape head_prefix a b w right_exp left_exp) ->
          Some
            { rule
            ; domain_rel_id = dom_id
            ; witness_source_id
            ; prefix_arity = List.length head_prefix
            ; domain_premise
            ; left_premise
            ; right_premise
            }
        | _ -> None)
      | _ -> None)
    | _ -> None)

let has_transitive_domain rules =
  List.exists (fun rule -> Option.is_some (transitive_domain rule)) rules

let target_chain_shape head_prefix a b w recursive target =
  match strip_suffix2 (exp_components recursive), strip_suffix2 (exp_components target) with
  | Some (recursive_prefix, a1, w1), Some (_target_prefix, w2, b2)
    when prefix_equal head_prefix recursive_prefix
         && exp_equal a a1
         && exp_equal w w1
         && exp_equal w w2
         && exp_equal b b2 ->
    true
  | _ -> false

let target_chain rule =
  match rulepr_payloads rule.prems with
  | None -> None
  | Some payloads ->
    let choose
        recursive_id
        recursive_exp
        recursive_premise
        target_id
        target_exp
        target_premise
        guard_payloads
      =
      match strip_suffix2 (exp_components rule.head) with
      | Some (head_prefix, a, b)
        when String.equal recursive_id rule.relation_id
             && not (String.equal target_id rule.relation_id) ->
        (match strip_suffix2 (exp_components recursive_exp) with
        | Some (_recursive_prefix, _a, w) ->
          (match direct_var_source_id w with
          | Some witness_source_id
            when (not (contains_source_id witness_source_id rule.head))
                 && target_chain_shape head_prefix a b w recursive_exp target_exp
                 && List.for_all
                      (fun (_guard_id, guard_exp, _guard_premise) ->
                        not (contains_source_id witness_source_id guard_exp))
                      guard_payloads ->
            Some
              { rule
              ; target_rel_id = target_id
              ; witness_source_id
              ; prefix_arity = List.length head_prefix
              ; recursive_premise
              ; target_premise
              ; guard_premises =
                  List.map
                    (fun (_guard_id, _guard_exp, guard_premise) -> guard_premise)
                    guard_payloads
              }
          | _ -> None)
        | _ -> None)
      | _ -> None
    in
    let rec pairs left = function
      | [] -> None
      | recursive :: rest ->
        let others = List.rev_append left rest in
        let result =
          others
          |> List.find_map (fun target ->
            let guard_payloads =
              others
              |> List.filter (fun payload -> payload != target)
            in
            let recursive_id, recursive_exp, recursive_premise = recursive in
            let target_id, target_exp, target_premise = target in
            choose
              recursive_id
              recursive_exp
              recursive_premise
              target_id
              target_exp
              target_premise
              guard_payloads)
        in
        (match result with
        | Some _ -> result
        | None -> pairs (recursive :: left) rest)
    in
    pairs [] payloads
