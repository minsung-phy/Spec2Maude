open Il.Ast
open Util.Source

type binding_domain =
  | Total
  | Zero_or_one

type binding =
  { premise : prem
  ; pattern : exp
  ; value : exp
  ; domain : binding_domain
  }

type producer =
  | Direct of
      { rule : Analysis.Function_graph.runtime_search_rule
      ; successor : exp
      }
  | Query_endpoint of
      { rule : Analysis.Function_graph.runtime_search_rule
      ; successor : exp
      }
  | Projection of
      { rule : Analysis.Function_graph.runtime_search_rule
      ; premise : prem
      ; successor : exp
      }
  | Indexed of
      { entry_rule : Analysis.Function_graph.runtime_search_rule
      ; rule : Analysis.Function_graph.runtime_search_rule
      ; prefix : prem list
      ; bindings : binding list
      ; source : exp
      ; index_source_id : string
      ; successor : exp
      }
  | Indexed_constructor of
      { rule : Analysis.Function_graph.runtime_search_rule
      ; prefix : prem list
      ; source : exp
      ; index_source_id : string
      ; index_typ : typ
      ; successor : exp
      }
  | Delegated of
      { entry_rule : Analysis.Function_graph.runtime_search_rule
      ; premise : prem
      ; relation_id : string
      ; producers : producer list
      }

type domain_candidate =
  | Closed_term of exp
  | Closed_constructor of string
  | Indexed_domain of
      { source : exp
      ; index_source_id : string
      ; index_typ : typ
      ; index_constructor : string option
      ; witness : exp
      }

type total_fact =
  | Validated_sequence_index of
      { source : exp
      ; index_source_id : string
      ; index_typ : typ
      ; index_constructor : string option
      ; witness : exp
      }

type coverage =
  { relation_id : string
  ; source_rules : Source_rule_identity.rule list
  }

type t =
  { transitive : Runtime_witness_proof.transitive_domain
  ; producers : producer list
  ; domain_candidates : domain_candidate list
  ; total_facts : total_fact list
  ; decision_coverage : coverage option
  }

type blocker =
  { relation_id : string
  ; rule_id : string option
  ; origin : Origin.t
  ; constructor : string
  ; reason : string
  ; suggestion : string
  ; source_echo : string option
  }

type decision =
  | Materialized of t
  | Blocked of blocker list

let components = Analysis.Relation_graph.exp_components

let split_endpoints arity exp =
  let rec split count prefix rest =
    if count = 0 then Some (List.rev prefix, rest)
    else match rest with
      | [] -> None
      | exp :: rest -> split (count - 1) (exp :: prefix) rest
  in
  match split arity [] (components exp) with
  | Some (prefix, [ left; right ]) -> Some (prefix, left, right)
  | Some _ | None -> None

let free exp = Il.Free.(free_exp exp).varid
let subset left right = Il.Free.Set.subset left right
let union exps =
  exps |> List.fold_left (fun ids exp -> Il.Free.Set.union ids (free exp)) Il.Free.Set.empty

let rulepr prem =
  match prem.it with
  | RulePr (id, [], _, exp) -> Some (id.it, exp)
  | RulePr (_, _ :: _, _, _) | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> None

let rec indexed exp =
  match exp.it with
  | IdxE (source, { it = VarE index; _ }) -> Some (source, index.it)
  | SubE (exp, _, _) | CvtE (exp, _, _) -> indexed exp
  | _ -> None

let rec indexed_with_typ exp =
  match exp.it with
  | IdxE (source, ({ it = VarE index; note = index_typ; _ })) ->
    Some (source, index.it, index_typ)
  | SubE (exp, _, _) | CvtE (exp, _, _) -> indexed_with_typ exp
  | _ -> None

let source_rule (rule : Analysis.Function_graph.runtime_search_rule) =
  { Runtime_witness_proof.identity = rule.identity
  ; relation_id = rule.relation_id
  ; rule_id = rule.rule_id
  ; origin = rule.origin
  ; source_echo = rule.source_echo
  ; head = rule.head
  ; prems = rule.prems
  }

let is_transitive rule =
  Option.is_some (Runtime_witness_proof.transitive_domain (source_rule rule))

let blocker
    ?(constructor = "RuntimeTruthSuccessorDomain/unclassified-rule")
    ?(suggestion =
      "Classify every transitivity-free RuleD as a direct, projection, indexed, target-conditional, or universal edge before admitting the finite successor certificate")
    rule reason =
  { relation_id = rule.Analysis.Function_graph.relation_id
  ; rule_id = rule.rule_id
  ; origin = rule.origin
  ; constructor
  ; reason
  ; suggestion
  ; source_echo = rule.source_echo
  }

let rec representation exp =
  match exp.it with
  | SubE (exp, _, _) | CvtE (exp, _, _) -> representation exp
  | _ -> exp

let same left right = Il.Eq.eq_exp (representation left) (representation right)

let self_projection relation_id arity known right rule =
  rule.Analysis.Function_graph.prems
  |> List.find_map (fun prem ->
    match rulepr prem with
    | Some (id, exp) when String.equal id relation_id ->
      (match split_endpoints arity exp with
      | Some (_, successor, target)
        when same target right && subset (free successor) known ->
        Some (Projection { rule; premise = prem; successor })
      | _ -> None)
    | _ -> None)

let indexed_head arity entry_rule rule =
  match split_endpoints arity rule.Analysis.Function_graph.head with
  | Some (_, _, right) ->
    (match indexed right with
    | Some (source, index_source_id) ->
      Some
        (Indexed
           { entry_rule; rule; prefix = rule.prems; bindings = []; source
           ; index_source_id; successor = right })
    | None -> None)
  | None -> None

let finite_sequence exp =
  match exp.note.it with
  | IterT (_, (List | List1 | ListN _)) -> true
  | _ -> false

type indexed_constructor_decision =
  | No_indexed_constructor
  | Indexed_constructor_producer of producer
  | Indexed_constructor_blocker of blocker

let prefix_scope known prefix =
  prefix
  |> List.fold_left
       (fun bound prem ->
         Il.Free.Set.union bound Il.Free.(free_prem prem).varid)
       known

let indexed_constructor relation_id arity known left successor rule =
  let introduced = Il.Free.Set.diff (free successor) known |> Il.Free.Set.elements in
  match introduced with
  | [ index_source_id ] ->
    let rec scan prefix = function
      | [] -> No_indexed_constructor
      | prem :: rest ->
        (match rulepr prem with
        | Some (id, exp) when String.equal id relation_id && rest = [] ->
          (match split_endpoints arity exp with
          | Some (_, recursive_left, recursive_right) when same recursive_left left ->
            (match indexed_with_typ recursive_right with
            | Some (source, index, index_typ)
              when String.equal index index_source_id ->
              let prefix = List.rev prefix in
              if not (finite_sequence source) then
                Indexed_constructor_blocker
                  (blocker rule
                     ~constructor:"RuntimeTruthSuccessorDomain/indexed-constructor/non-finite-source"
                     ~suggestion:
                       "Use an IL List/List1/ListN source with a complete finite runtime value before indexed-constructor enumeration"
                     "self RulePr indexes a source whose IL type is not a finite sequence")
              else if Il.Free.Set.mem index_source_id (free source) then
                Indexed_constructor_blocker
                  (blocker rule
                     ~constructor:"RuntimeTruthSuccessorDomain/indexed-constructor/dynamic-source"
                     ~suggestion:
                       "The enumerated source must be fixed before the index variable is introduced"
                     "indexed-constructor source depends on the index being enumerated")
              else
                let unbound =
                  Il.Free.Set.diff (free source) (prefix_scope known prefix)
                  |> Il.Free.Set.elements
                in
                if unbound <> [] then
                  Indexed_constructor_blocker
                    (blocker rule
                       ~constructor:"RuntimeTruthSuccessorDomain/indexed-constructor/symbolic-source"
                       ~suggestion:
                         "Bind the complete finite source from the RuleD head or an earlier ordered premise"
                       ("indexed-constructor source has variables outside the RuleD head and ordered premise prefix: "
                        ^ String.concat ", " unbound))
                else
                  Indexed_constructor_producer
                    (Indexed_constructor
                       { rule; prefix; source; index_source_id; index_typ
                       ; successor })
            | _ -> No_indexed_constructor)
          | _ -> No_indexed_constructor)
        | _ -> scan (prem :: prefix) rest)
    in
    scan [] rule.prems
  | [] | _ :: _ :: _ -> No_indexed_constructor

let rec safe_constructor_pattern exp =
  match exp.it with
  | VarE _ | BoolE _ | NumE _ | TextE _ -> true
  | CaseE (_, payload) -> safe_pattern_payload payload
  | SubE (inner, _, _) | CvtE (inner, _, _) | LiftE inner ->
    safe_constructor_pattern inner
  | OptE opt -> Option.fold ~none:true ~some:safe_constructor_pattern opt
  | TupE exps | ListE exps -> List.for_all safe_constructor_pattern exps
  | IterE ({ it = VarE body_id; _ },
           ((Opt | List | List1 | ListN _), [ generator_id, source ]))
    when String.equal body_id.it generator_id.it ->
    safe_constructor_pattern source
  | StrE fields ->
    List.for_all (fun (_, field) -> safe_constructor_pattern field) fields
  | UnE _ | BinE _ | CmpE _ | ProjE _ | UncaseE _ | TheE _ | DotE _
  | CompE _ | MemE _ | LenE _ | CatE _ | IdxE _ | SliceE _ | UpdE _
  | ExtE _ | IfE _ | CallE _ | IterE _ -> false

and safe_pattern_payload exp =
  match exp.it with
  | TupE exps -> List.for_all safe_constructor_pattern exps
  | _ -> safe_constructor_pattern exp

let rec safe_result_pattern exp =
  match exp.it with
  | CaseE (_, payload) -> safe_pattern_payload payload
  | SubE (inner, _, _) | CvtE (inner, _, _) | LiftE inner ->
    safe_result_pattern inner
  | _ -> false

let rec call_result exp =
  match exp.it with
  | CallE (id, _) -> Some (id, exp)
  | SubE (inner, _, _) | CvtE (inner, _, _) -> call_result inner
  | _ -> None

let split_prefix_witness arity exp =
  let rec take count prefix rest =
    if count = 0 then Some (List.rev prefix, rest)
    else
      match rest with
      | [] -> None
      | component :: rest -> take (count - 1) (component :: prefix) rest
  in
  match take arity [] (components exp) with
  | Some (prefix, [ witness ]) -> Some (prefix, witness)
  | Some _ | None -> None

let same_prefix left right =
  List.length left = List.length right && List.for_all2 same left right

let constructor_entry constructors exp =
  let exp = representation exp in
  match exp.it with
  | CaseE (mixop, payload) ->
    let arity =
      match payload.it with
      | TupE payloads -> List.length payloads
      | _ -> 1
    in
    let key_env = Static_key.of_static_typ_env [] in
    (match Static_key.typ_ref ~env:key_env exp.note with
    | None -> None
    | Some { Static_key.category_id; static_args_key } ->
      (match
         Constructor_registry.lookup_visible constructors
           ~source_category:(Naming.source_owner category_id)
           ~static_args_key ~mixop ~arity
       with
      | Constructor_registry.Found entry
        when entry.status = Constructor_registry.Emitted -> Some entry
      | Constructor_registry.Found _ | Missing | Ambiguous _ -> None))
  | _ -> None

let closed_nullary_family constructors typ =
  let key_env = Static_key.of_static_typ_env [] in
  match Static_key.typ_ref ~env:key_env typ with
  | None -> None
  | Some { Static_key.category_id; static_args_key } ->
    (match
       Constructor_registry.family_coverage constructors
         ~source_category:(Naming.source_owner category_id)
         ~static_args_key
     with
    | Constructor_registry.Closed entries
      when entries <> []
           && List.for_all
                (fun (entry : Constructor_registry.entry) ->
                  entry.status = Constructor_registry.Emitted
                  && entry.arity = 0
                  && entry.construction_domain = Constructor_registry.Total_constructor)
                entries ->
      Some (List.map (fun entry -> entry.Constructor_registry.constructor_op) entries)
    | Constructor_registry.Closed _ | Open _ -> None)

let constructor_elimination
    constructors resolve_constructor scrutinee mixop payload_typ index =
  let scrutinee = representation scrutinee in
  match scrutinee.it with
  | VarE id ->
    let arity = match payload_typ.it with TupT typs -> List.length typs | _ -> 1 in
    if arity <> 1 || index <> 0 then None else
      let key_env = Static_key.of_static_typ_env [] in
      (match Static_key.typ_ref ~env:key_env scrutinee.note with
      | None -> None
      | Some { Static_key.category_id; static_args_key } ->
        let lookup =
          Constructor_registry.lookup_visible constructors
             ~source_category:(Naming.source_owner category_id)
             ~static_args_key ~mixop ~arity
        in
        let entry =
          match lookup with
          | Constructor_registry.Found entry -> Some entry
          | Missing -> resolve_constructor scrutinee.note mixop arity
          | Ambiguous _ -> None
        in
        (match entry with
        | Some entry
          when entry.status = Constructor_registry.Emitted
               && Il.Eq.eq_mixop entry.mixop mixop
               && entry.arity = arity
               && (match entry.construction_domain with
                   | Constructor_registry.Total_constructor
                   | Constructor_registry.Certified_representation_constructor -> true
                   | Length_guarded_representation_constructor _
                   | Guarded_constructor _ -> false) ->
          Some (id.it, scrutinee.note, entry.constructor_op)
        | Some _ | None -> None))
  | _ -> None

let rec domain_index constructors resolve_constructor exp =
  match exp.it with
  | VarE id -> Some (id.it, exp.note, None)
  | ProjE ({ it = UncaseE (scrutinee, mixop); note = payload_typ; _ }, index) ->
    Option.map
      (fun (id, typ, constructor) -> id, typ, Some constructor)
      (constructor_elimination
         constructors resolve_constructor scrutinee mixop payload_typ index)
  | SubE (inner, _, _) | CvtE (inner, _, _) ->
    domain_index constructors resolve_constructor inner
  | _ -> None

let indexed_source_of_premise
    constructors resolve_constructor index_source_id prem =
  let indexed_side exp =
    match exp.it with
    | IdxE (source, index) ->
      (match domain_index constructors resolve_constructor index with
      | Some (index, index_typ, index_constructor)
      when String.equal index index_source_id && finite_sequence source ->
        Some (source, index_typ, index_constructor)
      | Some _ | None -> None)
    | _ -> None
  in
  match prem.it with
  | LetPr (_, left, right)
  | IfPr { it = CmpE (`EqOp, _, left, right); _ } ->
    (match indexed_side left with
    | Some _ as indexed -> indexed
    | None -> indexed_side right)
  | RulePr _ | IfPr _ | ElsePr | IterPr _ | NegPr _ -> None

let source_element_typ source =
  match source.note.it with
  | IterT (element_typ, (Opt | List | List1 | ListN _)) -> Some element_typ
  | VarT _ | BoolT | NumT _ | TextT | TupT _ -> None

type nested_indexed =
  { source : exp
  ; index_source_id : string
  ; index_typ : typ
  ; index_constructor : string option
  ; witness : exp
  ; element_typ : typ
  }

type nested_domain_case =
  | Nested_indexed of nested_indexed

let nested_domain_case
    constructors resolve_constructor prefix_arity rule =
  match split_prefix_witness prefix_arity rule.Analysis.Function_graph.head with
  | None -> None
  | Some (prefix, witness) ->
    let witness = representation witness in
    (match witness.it with
    | CaseE _ ->
      let witness_ids = Il.Free.(free_exp witness).varid |> Il.Free.Set.elements in
      (match witness_ids with
      | [ index_source_id ] ->
        let indexed_source =
          rule.prems
          |> List.find_map
               (indexed_source_of_premise
                  constructors resolve_constructor index_source_id)
        in
        (match indexed_source with
        | Some (source, index_typ, index_constructor)
          when subset (free source) (union prefix)
               && Option.is_some (constructor_entry constructors witness) ->
          Option.map
            (fun element_typ ->
              Nested_indexed
                { source; index_source_id; index_typ; index_constructor
                ; witness; element_typ })
            (source_element_typ source)
        | None | Some _ -> None)
      | [] | _ :: _ :: _ -> None)
    | VarE _ -> None
    | _ -> None)

let nested_domain
    graph constructors resolve_constructor prefix_arity relation_id =
  match Analysis.Function_graph.runtime_relation_rules graph relation_id with
  | None | Some [] -> None
  | Some rules ->
    let cases = List.map (fun rule ->
      nested_domain_case
        constructors resolve_constructor prefix_arity rule) rules in
    if List.exists Option.is_none cases then None else
      let indexed =
        cases |> List.filter_map (function
          | Some (Nested_indexed indexed) -> Some indexed
          | None -> None)
      in
      if indexed = [] then None
      else
        let indexed_candidates =
          indexed
          |> List.map (fun indexed ->
            Indexed_domain
              { source = indexed.source
              ; index_source_id = indexed.index_source_id
              ; index_typ = indexed.index_typ
              ; index_constructor = indexed.index_constructor
              ; witness = indexed.witness
              })
        in
        let facts =
          indexed
          |> List.map (fun indexed ->
            Validated_sequence_index
              { source = indexed.source
              ; index_source_id = indexed.index_source_id
              ; index_typ = indexed.index_typ
              ; index_constructor = indexed.index_constructor
              ; witness = indexed.witness
              })
        in
        Some (indexed_candidates, facts)

let exact_domain_candidates graph constructors resolve_constructor
    (transitive : Runtime_witness_proof.transitive_domain) =
  match split_prefix_witness transitive.prefix_arity
          (match transitive.domain_premise.it with
          | RulePr (_, [], _, exp) -> exp
          | RulePr (_, _ :: _, _, _) | IfPr _ | LetPr _ | ElsePr
          | IterPr _ | NegPr _ -> transitive.rule.head)
  with
  | None -> None
  | Some (domain_prefix, _) ->
    (match
       Analysis.Function_graph.runtime_relation_rules graph transitive.domain_rel_id
     with
    | None | Some [] -> None
    | Some rules ->
      let classify rule =
        let result = match split_prefix_witness transitive.prefix_arity rule.Analysis.Function_graph.head with
        | Some (prefix, witness) when same_prefix domain_prefix prefix ->
          let witness = representation witness in
          (match witness.it with
          | VarE _ when rule.prems = [] ->
            Option.map
              (fun constructors ->
                List.map (fun name -> Closed_constructor name) constructors, [])
              (closed_nullary_family constructors witness.note)
          | VarE _ ->
            (match rule.prems with
            | [ prem ] ->
              (match rulepr prem with
              | Some (relation_id, exp) ->
                (match split_prefix_witness transitive.prefix_arity exp with
                | Some (child_prefix, child_witness)
                  when same_prefix prefix child_prefix
                       && same child_witness witness ->
                  nested_domain
                    graph constructors resolve_constructor
                    transitive.prefix_arity relation_id
                | Some _ | None -> None)
              | None -> None)
            | [] | _ :: _ :: _ -> None)
          | CaseE _ when subset (free witness) (union prefix) ->
            (match constructor_entry constructors witness with
            | Some _ -> Some ([ Closed_term witness ], [])
            | None -> None)
          | _ -> None)
        | Some _ | None -> None
        in
        result
      in
      let classified = List.map (fun rule -> rule, classify rule) rules in
      let proven = List.filter_map snd classified in
      if proven = [] then None
      else
        let candidates, facts =
          proven
          |> List.fold_left
               (fun (candidates, facts) (new_candidates, new_facts) ->
                 List.rev_append new_candidates candidates,
                 List.rev_append new_facts facts)
               ([], [])
        in
        if candidates = [] then None
        else
          let coverage =
            if List.for_all (fun (_, candidate) -> Option.is_some candidate) classified
            then
              Some
                { relation_id = transitive.domain_rel_id
                ; source_rules =
                    List.map
                      (fun rule -> rule.Analysis.Function_graph.identity)
                      rules
                }
            else None
          in
          Some (List.rev candidates, List.rev facts, coverage))

let delegated_prefix source_total source_zero_or_one known rule prefix =
  let blocked prem constructor reason suggestion =
    let origin =
      Origin.with_child ~source_echo:(Il.Print.string_of_prem prem)
        rule.Analysis.Function_graph.origin "delegated-prefix"
        ~ast_constructor:"LetPr" prem.at
    in
    Error
      { (blocker rule ~constructor ~suggestion reason) with
        origin; source_echo = Some (Il.Print.string_of_prem prem) }
  in
  let bind_result prem bound introduced pattern value =
    let missing = Il.Free.Set.diff (free value) bound |> Il.Free.Set.elements in
    let finish domain =
      let fresh = Il.Free.Set.diff (free pattern) bound in
      if Il.Free.Set.is_empty fresh || not (safe_result_pattern pattern) then
        blocked prem
          "RuntimeTruthSuccessorDomain/delegated/result-pattern-unsafe"
          "delegated deterministic result is not matched by a constructor pattern that safely introduces source variables"
          "Match the deterministic result with a constructor-shaped IL pattern before using introduced variables"
      else
        Ok
          ( Il.Free.Set.union bound fresh
          , Il.Free.Set.union introduced fresh
          , { premise = prem; pattern; value; domain } )
    in
    if missing <> [] then
      blocked prem
        "RuntimeTruthSuccessorDomain/delegated/call-input-unbound"
        ("certified deterministic value has inputs not bound by the child RuleD head or an earlier ordered premise: "
         ^ String.concat ", " missing)
        "Bind every deterministic input before matching its result pattern"
    else match call_result value with
    | Some (call_id, call) ->
      let bound_ids = Il.Free.Set.elements bound in
      let domain =
        if source_total ~bound:bound_ids call then Some Total
        else if source_zero_or_one ~bound:bound_ids call then Some Zero_or_one
        else None
      in
      (match domain with
      | None ->
        blocked prem
          "RuntimeTruthSuccessorDomain/delegated/call-not-source-complete-deterministic"
          ("delegated binding calls `" ^ call_id.it
           ^ "`, but that exact CallE is neither total nor a certified zero-or-one source value")
          "Use a total DecD call, or a single-clause equation-backed DecD observed through a constructor result pattern"
      | Some domain -> finish domain)
    | None -> finish Zero_or_one
  in
  let rec scan bound introduced bindings = function
    | [] -> Ok (bound, introduced, List.rev bindings)
    | prem :: rest ->
      let bind pattern value =
        match bind_result prem bound introduced pattern value with
        | Ok (bound, introduced, binding) ->
          scan bound introduced (binding :: bindings) rest
        | Error _ as error -> error
      in
      (match prem.it with
      | LetPr (_, lhs, rhs) ->
        (match call_result lhs, call_result rhs with
        | Some (_, call), None -> bind rhs call
        | None, Some (_, call) -> bind lhs call
        | Some _, Some _ | None, None ->
          blocked prem
            "RuntimeTruthSuccessorDomain/delegated/result-pattern-unsafe"
            "delegated LetPr does not have exactly one deterministic CallE side and one constructor-pattern side"
            "Orient one source-complete deterministic CallE against its constructor result pattern")
      | IfPr { it = CmpE (`EqOp, _, left, right); _ } ->
        let fresh_left = Il.Free.Set.diff (free left) bound in
        let fresh_right = Il.Free.Set.diff (free right) bound in
        if not (Il.Free.Set.is_empty fresh_right) && safe_result_pattern right
           && subset (free left) bound
        then bind right left
        else if not (Il.Free.Set.is_empty fresh_left) && safe_result_pattern left
                && subset (free right) bound
        then bind left right
        else
          let missing = Il.Free.Set.diff Il.Free.(free_prem prem).varid bound
                        |> Il.Free.Set.elements in
          if missing = [] then scan bound introduced bindings rest
          else
            blocked prem
              "RuntimeTruthSuccessorDomain/delegated/prefix-input-unbound"
              ("delegated equality uses variables before binding them: "
               ^ String.concat ", " missing)
              "Orient a deterministic value against a safe constructor result pattern"
      | IfPr _ | RulePr _ ->
        let missing = Il.Free.Set.diff Il.Free.(free_prem prem).varid bound
                      |> Il.Free.Set.elements in
        if missing = [] then scan bound introduced bindings rest
        else
          blocked prem
            "RuntimeTruthSuccessorDomain/delegated/prefix-input-unbound"
            ("delegated ordered premise uses variables before binding them: "
             ^ String.concat ", " missing)
            "Preserve source premise order and bind each variable before use"
      | ElsePr | IterPr _ | NegPr _ ->
        blocked prem
          "RuntimeTruthSuccessorDomain/delegated/prefix-unsupported"
          "delegated successor prefix contains a premise without a total ordered equational lowering"
          "Keep this delegated edge Unsupported until the prefix premise has a source-complete lowering")
  in
  scan known Il.Free.Set.empty [] prefix

let delegated_producers
    source_total source_zero_or_one graph relation_id arity entry_rule delegated_id =
  match Analysis.Function_graph.runtime_relation_rules graph delegated_id with
  | None -> Error (blocker entry_rule "delegated predicate has no indexed source RuleD body")
  | Some rules ->
    let classify rule =
      let rec scan prefix = function
        | [] -> Ok []
        | prem :: rest ->
          (match rulepr prem with
          | Some (id, exp) when String.equal id relation_id ->
            (match split_endpoints arity exp with
            | Some (_, successor, _) when rest = [] ->
              (match indexed successor with
              | Some (source, index_source_id) ->
                let prefix = List.rev prefix in
                let known =
                  match split_endpoints arity rule.Analysis.Function_graph.head with
                  | Some (head_prefix, left, _) -> union (left :: head_prefix)
                  | None -> Il.Free.Set.empty
                in
                (match
                   delegated_prefix
                     source_total source_zero_or_one known rule prefix
                 with
                | Error blocker -> Error blocker
                | Ok (bound, introduced, bindings) ->
                  let missing = Il.Free.Set.diff (free source) bound |> Il.Free.Set.elements in
                  if not (finite_sequence source) then
                    Error
                      (blocker rule
                         ~constructor:"RuntimeTruthSuccessorDomain/delegated/non-finite-source"
                         ~suggestion:
                           "Use an IL List/List1/ListN value introduced by the ordered deterministic result match"
                         "delegated indexed endpoint does not range over a finite IL sequence")
                  else if missing <> [] then
                    Error
                      (blocker rule
                         ~constructor:"RuntimeTruthSuccessorDomain/delegated/symbolic-source"
                         ~suggestion:
                           "Bind the complete finite source in the child RuleD head or ordered LetPr prefix"
                         ("delegated indexed source remains symbolic after its ordered prefix: "
                          ^ String.concat ", " missing))
                  else if prefix <> []
                          && Il.Free.Set.is_empty
                               (Il.Free.Set.inter introduced (free source)) then
                    Error
                      (blocker rule
                         ~constructor:"RuntimeTruthSuccessorDomain/delegated/result-pattern-unsafe"
                         ~suggestion:
                           "Use the finite sequence introduced by the deterministic constructor-result pattern"
                         "delegated indexed source is not introduced by its ordered CallE result match")
                  else
                    Ok
                      [ Indexed
                          { entry_rule; rule; prefix; bindings; source
                          ; index_source_id; successor } ])
              | None -> scan (prem :: prefix) rest)
            | Some _ | None -> scan (prem :: prefix) rest)
          | _ -> scan (prem :: prefix) rest)
      in
      scan [] rule.prems
    in
    let results = List.map classify rules in
    match List.find_map (function Error blocker -> Some blocker | Ok _ -> None) results with
    | Some blocker -> Error blocker
    | None -> Ok (List.concat_map (function Ok ps -> ps | Error _ -> []) results)

let classify_rule source_total source_zero_or_one graph relation_id arity rule =
  match split_endpoints arity rule.Analysis.Function_graph.head with
  | None -> Error (blocker rule "RuleD head does not expose the transitive relation prefix and two endpoints")
  | Some (prefix, left, right) ->
    let known = union (left :: prefix) in
    if subset (free right) known then
      Ok [ Direct { rule; successor = right } ]
    else
      (match indexed_head arity rule rule with
      | Some (Indexed indexed) ->
        (match
           delegated_prefix
             source_total source_zero_or_one known rule indexed.prefix
         with
        | Error blocker -> Error blocker
        | Ok (_, _, bindings) -> Ok [ Indexed { indexed with bindings } ])
      | Some
          (Direct _ | Query_endpoint _ | Projection _ | Indexed_constructor _
          | Delegated _) ->
        Error (blocker rule "indexed-head classifier returned a non-indexed producer")
      | None ->
        (match indexed_constructor relation_id arity known left right rule with
        | Indexed_constructor_producer producer -> Ok [ producer ]
        | Indexed_constructor_blocker blocker -> Error blocker
        | No_indexed_constructor ->
        (match self_projection relation_id arity known right rule with
        | Some producer -> Ok [ producer ]
        | None ->
          let delegated =
            rule.prems |> List.find_map (fun prem ->
              match rulepr prem with
              | Some (id, exp) when not (String.equal id relation_id) ->
                (match split_endpoints arity exp with
                | Some (delegated_prefix, delegated_left, delegated_right)
                  when List.length delegated_prefix = List.length prefix
                       && List.for_all2 same delegated_prefix prefix
                       && same delegated_left left && same delegated_right right ->
                      Some
                        ( prem
                        , id
                        , delegated_producers
                            source_total source_zero_or_one
                            graph relation_id arity rule id )
                | _ -> None)
              | _ -> None)
          in
          (match delegated with
          | Some (premise, delegated_id, Ok producers) ->
            Ok
              [ Delegated
                  { entry_rule = rule; premise; relation_id = delegated_id; producers } ]
          | Some (_, _, Error blocker) -> Error blocker
          | None
            when List.for_all
                   (fun prem -> subset Il.Free.(free_prem prem).varid (free rule.head))
                   rule.prems ->
            Ok [ Query_endpoint { rule; successor = right } ]
          | None ->
            Error
              (blocker rule
                 "RuleD has an open right endpoint and no typed proof that the clause produces zero successors")))))

let source_rule_is rules rule =
  List.exists
    (Source_rule_identity.equal_rule
       rule.Analysis.Function_graph.identity)
    rules

let rec exhaustive_producer query_endpoints = function
  | Direct _ | Projection _ | Indexed _ | Indexed_constructor _ -> true
  | Delegated { producers; _ } ->
    List.for_all (exhaustive_producer query_endpoints) producers
  | Query_endpoint { rule; _ } -> source_rule_is query_endpoints rule

let producer_coverage relation_id rules query_endpoints producer_groups =
  let exhaustive = function
    | [] -> false
    | producers ->
      List.for_all (exhaustive_producer query_endpoints) producers
  in
  if List.for_all exhaustive producer_groups then
    Some
      { relation_id
      ; source_rules =
          List.map
            (fun rule -> rule.Analysis.Function_graph.identity)
            rules
      }
  else None

let subtyping_mixop mixop =
  Xl.Mixop.flatten mixop
  |> List.exists (List.exists (fun atom -> atom.it = Xl.Atom.Sub))

let closed_over prefix exp = subset (free exp) (union prefix)

let endpoint_var exp =
  match (representation exp).it with
  | VarE id -> Some id.it
  | BoolE _ | NumE _ | TextE _ | UnE _ | BinE _ | CmpE _ | TupE _
  | ProjE _ | CaseE _ | UncaseE _ | OptE _ | TheE _ | StrE _ | DotE _
  | CompE _ | ListE _ | LiftE _ | MemE _ | LenE _ | CatE _ | IdxE _
  | SliceE _ | UpdE _ | ExtE _ | IfE _ | CallE _ | IterE _ | CvtE _
  | SubE _ -> None

let excluded_endpoint prefix endpoint prem =
  let excluded left right =
    if same left endpoint && closed_over prefix right then Some right
    else if same right endpoint && closed_over prefix left then Some left
    else None
  in
  match prem.it with
  | IfPr { it = CmpE (`NeOp, _, left, right); _ } -> excluded left right
  | RulePr _ | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> None

let rooted_endpoint_rule relation_id arity rule =
  match split_endpoints arity rule.Analysis.Function_graph.head with
  | Some (prefix, left, right) ->
    (match endpoint_var right with
    | None -> Some `Target
    | Some _ ->
      let recursive, guards =
        rule.prems
        |> List.fold_left
             (fun (recursive, guards) prem ->
               match rulepr prem with
               | Some (id, exp) when String.equal id relation_id ->
                 (match split_endpoints arity exp with
                 | Some (child_prefix, child_left, root)
                   when same_prefix prefix child_prefix
                        && same child_left right
                        && closed_over prefix root ->
                   (root :: recursive, guards)
                 | Some _ | None -> recursive, guards)
               | Some _ -> recursive, guards
               | None -> recursive, prem :: guards)
             ([], [])
      in
      match recursive, guards with
      | [], [] when closed_over prefix left -> Some (`Universal left)
      | [], [] -> None
      | [ root ], [ guard ] ->
        Option.map
          (fun bottom -> `Rooted (left, root, bottom))
          (excluded_endpoint prefix right guard)
      | [], _ :: _ | _ :: _ :: _, _ | [ _ ], [] | [ _ ], _ :: _ :: _ ->
        None)
  | None -> None

let validation_domain graph
    (transitive : Runtime_witness_proof.transitive_domain) =
  match transitive.Runtime_witness_proof.domain_premise.it with
  | RulePr (id, args, mixop, exp)
    when String.equal id.it transitive.Runtime_witness_proof.domain_rel_id ->
    (match Analysis.Function_graph.find_relation graph id.it with
    | Some relation ->
      let certificate =
        Runtime_validation_certificate.premise_shape
        ~predicate_marker:
          (relation.kind = Analysis.Relation_graph.Predicate_candidate)
        ~source_params:relation.source_params
        ~mixop_equal:Il.Eq.eq_mixop
        ~declaration_mixop:relation.mixop
        ~premise_args:args
        ~premise_mixop:mixop
        ~result:relation.result
        ~premise_exp:exp
      in
      certificate = Runtime_validation_certificate.Certified
    | None -> false)
  | RulePr _ | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> false

(* For a validated subtyping judgement, nominal supertypes are kind-preserving
   and strictly decrease the validated type index.  Hence a derivation ending at
   a fixed target admits cut elimination: an open bottom-family edge can use the
   target itself, while every other first edge is one of the finite producers.
   The certificate below admits that theorem only for the source schema that
   states it: one universal bottom and target-directed rooted rules excluding
   that same bottom.  Arbitrary open relations remain incomplete. *)
let rooted_subtyping_endpoints graph
    (transitive : Runtime_witness_proof.transitive_domain) producer_groups =
  let relation_id = transitive.Runtime_witness_proof.rule.relation_id in
  match Analysis.Function_graph.find_relation graph relation_id with
  | None -> []
  | Some relation ->
    let is_subtyping = subtyping_mixop relation.mixop in
    let has_validation_domain = validation_domain graph transitive in
    if not is_subtyping || not has_validation_domain then []
    else
    let query_rules =
      producer_groups
      |> List.concat_map (List.filter_map (function
           | Query_endpoint { rule; _ } -> Some rule
           | Direct _ | Projection _ | Indexed _ | Indexed_constructor _
           | Delegated _ -> None))
    in
    let classified =
      List.map
        (fun rule -> rule, rooted_endpoint_rule relation_id transitive.prefix_arity rule)
        query_rules
    in
    let universals =
      classified
      |> List.filter_map (function _, Some (`Universal bottom) -> Some bottom | _ -> None)
    in
    let rooted =
      classified
      |> List.filter_map (function
           | _, Some (`Rooted (left, root, bottom)) ->
             Some (left, root, bottom)
           | _ -> None)
    in
    match universals with
    | [ bottom ]
      when rooted <> []
           && List.for_all (fun (_, _, excluded) -> same bottom excluded) rooted
           && List.for_all (fun (_, result) -> Option.is_some result) classified ->
      List.map
        (fun (rule, _) -> rule.Analysis.Function_graph.identity)
        classified
    | [] | _ :: _ :: _ | [ _ ] -> []

let certify
    ?(source_total = fun ~bound:_ _ -> false)
    ?(source_zero_or_one = fun ~bound:_ _ -> false)
    ?source_total_with_facts
    ?constructors
    ?(resolve_constructor = fun _ _ _ -> None)
    graph
    (transitive : Runtime_witness_proof.transitive_domain) =
  let domain_candidates, total_facts, decision_coverage =
    match constructors with
    | None -> [], [], None
    | Some constructors ->
      (match exact_domain_candidates
               graph constructors resolve_constructor transitive with
      | None -> [], [], None
      | Some (candidates, facts, coverage) ->
        candidates, facts, coverage)
  in
  let source_total =
    match source_total_with_facts with
    | Some source_total -> source_total ~facts:total_facts
    | None -> source_total
  in
  match
    Analysis.Function_graph.runtime_relation_rules
      graph transitive.rule.relation_id
  with
  | None ->
    Blocked
      [ { relation_id = transitive.rule.relation_id
        ; rule_id = transitive.rule.rule_id
        ; origin = transitive.rule.origin
        ; constructor = "RuntimeTruthSuccessorDomain/relation"
        ; reason = "transitive relation has no indexed source RuleD body"
        ; suggestion = "Keep the SCC Unsupported until its complete RuleD body is available"
        ; source_echo = transitive.rule.source_echo
        } ]
  | Some rules ->
    let base_rules = List.filter (fun rule -> not (is_transitive rule)) rules in
    let results =
      base_rules |> List.map
           (classify_rule source_total source_zero_or_one
              graph transitive.rule.relation_id
              transitive.prefix_arity)
    in
    let blockers = results |> List.filter_map (function Error blocker -> Some blocker | Ok _ -> None) in
    if blockers <> [] then Blocked blockers
    else
      let producer_groups =
        results |> List.filter_map (function Ok producers -> Some producers | Error _ -> None)
      in
      let producers = List.concat producer_groups
      in
      let decision_coverage =
        match decision_coverage with
        | Some _ as coverage -> coverage
        | None ->
          let query_endpoints =
            rooted_subtyping_endpoints graph transitive producer_groups
          in
          (* For R(x,y) with the source transitivity clause

               D(w), R(x,w), R(w,y) / R(x,y),

             every nonempty proof starts with one edge produced by a
             non-transitive RuleD.  Exhaustively classifying those RuleDs
             therefore gives a finite direct-successor basis.  The visited
             worklist computes its least reflexive-transitive closure.  A
             target-directed open endpoint counts as exhaustive only under the
             rooted-subtyping cut certificate above. *)
          producer_coverage transitive.rule.relation_id rules
            query_endpoints producer_groups
      in
      Materialized
        { transitive
        ; producers
        ; domain_candidates
        ; total_facts
        ; decision_coverage
        }

let same_rule left right =
  Source_rule_identity.equal_rule
    left.Runtime_witness_proof.identity right.Runtime_witness_proof.identity

let matches certificate (transitive : Runtime_witness_proof.transitive_domain) =
  same_rule certificate.transitive.rule transitive.rule
  && String.equal certificate.transitive.domain_rel_id transitive.domain_rel_id
  && String.equal
       certificate.transitive.witness_source_id
       transitive.witness_source_id
  && certificate.transitive.prefix_arity = transitive.prefix_arity

let decision_complete certificate =
  Option.is_some certificate.decision_coverage

let key certificate =
  let rule_key rule =
    Source_rule_identity.rule_key rule.Analysis.Function_graph.identity
  in
  let rec producer_key = function
    | Direct { rule; successor } ->
      "direct:" ^ rule_key rule ^ ":" ^ Il.Print.string_of_exp successor
    | Query_endpoint { rule; successor } ->
      "query-endpoint:" ^ rule_key rule ^ ":" ^ Il.Print.string_of_exp successor
    | Projection { rule; successor; _ } ->
      "projection:" ^ rule_key rule ^ ":" ^ Il.Print.string_of_exp successor
    | Indexed { entry_rule; rule; source; successor; _ } ->
      String.concat ":"
        [ "indexed"; rule_key entry_rule; rule_key rule
        ; Il.Print.string_of_exp source; Il.Print.string_of_exp successor ]
    | Indexed_constructor { rule; source; successor; index_source_id; _ } ->
      String.concat ":"
        [ "indexed-constructor"; rule_key rule; index_source_id
        ; Il.Print.string_of_exp source; Il.Print.string_of_exp successor ]
    | Delegated { entry_rule; relation_id; producers; _ } ->
      String.concat ":"
        [ "delegated"; rule_key entry_rule; relation_id
        ; String.concat "," (List.map producer_key producers) ]
  in
  let domain_key = function
    | Closed_term exp -> "closed:" ^ Il.Print.string_of_exp exp
    | Closed_constructor name -> "constructor:" ^ name
    | Indexed_domain
        { source; index_source_id; index_constructor; witness; _ } ->
      String.concat ":"
        [ "domain-indexed"; index_source_id
        ; Option.value ~default:"direct" index_constructor
        ; Il.Print.string_of_exp source; Il.Print.string_of_exp witness ]
  in
  let transitive = certificate.transitive in
  String.concat "\000"
    [ Source_rule_identity.rule_key transitive.rule.identity
    ; transitive.domain_rel_id
    ; transitive.witness_source_id
    ; string_of_int transitive.prefix_arity
    ] ^ "\000"
  ^ String.concat "\000" (List.map producer_key certificate.producers)
  ^ "\000domain\000"
  ^ String.concat "\000" (List.map domain_key certificate.domain_candidates)
  ^ "\000coverage\000"
  ^ (match certificate.decision_coverage with
     | None -> "open"
     | Some coverage ->
       coverage.relation_id ^ "\000"
       ^ String.concat "\000"
           (List.map Source_rule_identity.rule_key coverage.source_rules))
