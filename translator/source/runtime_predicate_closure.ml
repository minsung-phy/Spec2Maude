open Il.Ast
open Util.Source

type use =
  | Search_helper
  | Truth_helper
  | Positive_predicate

type relation_kind =
  | Predicate_candidate
  | Deterministic_candidate
  | Execution
  | Execution_star
  | Unknown of string

type rule =
  { identity : Source_rule_identity.rule
  ; rule_id : string option
  ; origin : Origin.t
  ; source_echo : string option
  ; binds : quant list
  ; mixop : mixop
  ; head : exp
  ; prems : prem list
  }

type relation =
  { id : string
  ; origin : Origin.t
  ; source_params : param list
  ; kind : relation_kind
  ; mixop : mixop
  ; result : typ
  ; rules : rule list option
  ; runtime_demanded : bool
  ; external_validation_shape : bool
  }

type search_rule =
  { relation_id : string
  ; relation_result : typ
  ; rule : rule
  }

type graph =
  { find_relation : string -> relation option
  ; dependencies : string -> string list
  ; mixop_equal : mixop -> mixop -> bool
  }

type blocker =
  { relation_id : string
  ; rule_id : string option
  ; origin : Origin.t option
  ; constructor : string
  ; reason : string
  ; suggestion : string
  ; source_echo : string option
  ; premise_origin : Origin.t option
  ; premise_constructor : string option
  ; premise_source_echo : string option
  }

type premise_blocker =
  { constructor : string
  ; reason : string
  ; suggestion : string
  ; premise_origin : Origin.t option
  ; premise_constructor : string option
  ; premise_source_echo : string option
  }

type premise_dependency =
  { dep_id : string
  ; rule_id : string option
  ; rule_origin : Origin.t option
  ; rule_source_echo : string option
  ; premise_origin : Origin.t option
  ; premise_constructor : string
  ; premise_source_echo : string option
  }

type plan =
  | Complete of
      { closure : string list
      ; rules : search_rule list
      }
  | Blocked of
      { closure : string list
      ; rules : search_rule list
      ; blockers : blocker list
      }

let make ~find_relation ~dependencies ~mixop_equal =
  { find_relation; dependencies; mixop_equal }

let string_of_relation_kind = function
  | Predicate_candidate -> "predicate candidate"
  | Deterministic_candidate -> "deterministic candidate"
  | Execution -> "execution"
  | Execution_star -> "execution-star"
  | Unknown text -> text

let compare_blocker left right =
  match String.compare left.relation_id right.relation_id with
  | 0 ->
    (match compare left.rule_id right.rule_id with
    | 0 ->
      (match String.compare left.constructor right.constructor with
      | 0 ->
        (match compare left.premise_source_echo right.premise_source_echo with
        | 0 -> String.compare left.reason right.reason
        | order -> order)
      | order -> order)
    | order -> order)
  | order -> order

let compare_dependency left right =
  match String.compare left.dep_id right.dep_id with
  | 0 ->
    (match compare left.rule_id right.rule_id with
    | 0 -> compare left.premise_source_echo right.premise_source_echo
    | order -> order)
  | order -> order

let constructor_of_premise prem =
  match prem.it with
  | RulePr _ -> "RulePr"
  | IfPr _ -> "IfPr"
  | LetPr _ -> "LetPr"
  | ElsePr -> "ElsePr"
  | IterPr _ -> "IterPr"
  | NegPr _ -> "NegPr"

let premise_source_echo prem =
  Some (Il.Print.string_of_prem prem)

let premise_origin prem =
  Some
    (Origin.make
       ?source_echo:(premise_source_echo prem)
       ~ast_constructor:(constructor_of_premise prem)
       prem.at)

let with_premise prem (blocker : premise_blocker) =
  let premise_kind : string = constructor_of_premise prem in
  { blocker with
    premise_origin =
      (match blocker.premise_origin with
      | Some _ -> blocker.premise_origin
      | None -> premise_origin prem)
  ;
    premise_constructor = Some premise_kind
  ; premise_source_echo = premise_source_echo prem
  }

let otherwise_blocker = function
  | Search_helper | Truth_helper ->
    { constructor = "RuntimePredicateClosure/ElsePr"
    ; reason =
        "otherwise premise needs enabledness complement before it can be part of a search relation"
    ; suggestion =
        "Implement source-derived enabledness complement before using this relation in predicate search"
    ; premise_origin = None
    ; premise_constructor = None
    ; premise_source_echo = None
    }
  | Positive_predicate ->
    { constructor = "RuntimePredicateClosure/ElsePr"
    ; reason =
        "otherwise premise needs a source-derived complement before predicate completeness can be proven"
    ; suggestion =
        "Implement source-derived enabledness complement before proving this predicate complete"
    ; premise_origin = None
    ; premise_constructor = None
    ; premise_source_echo = None
    }

let rec supported_if_exp exp =
  match exp.it with
  | BinE (`AndOp, _, left, right) ->
    supported_if_exp left && supported_if_exp right
  | CmpE _ | CallE _ -> true
  | _ -> false

let if_blocker exp = function
  | (Search_helper | Truth_helper) when supported_if_exp exp -> None
  | Search_helper | Truth_helper ->
    Some
      { constructor = "RuntimePredicateClosure/IfPr"
      ; reason =
          "source IfPr shape is not covered by runtime search helper condition lowering"
      ; suggestion =
          "Keep this relation out of predicate search until this IfPr expression form can be lowered all-or-nothing by the runtime search materializer"
      ; premise_origin = None
      ; premise_constructor = None
      ; premise_source_echo = None
      }
  | Positive_predicate -> None

let let_blocker = function
  | Search_helper | Truth_helper ->
    Some
      { constructor = "RuntimePredicateClosure/LetPr"
      ; reason =
          "source LetPr can introduce local bindings, so predicate search generation must prove the binding is admissible before helper emission"
      ; suggestion =
          "Keep this relation out of predicate search until LetPr binding lowering is implemented all-or-nothing for helper rules"
      ; premise_origin = None
      ; premise_constructor = None
      ; premise_source_echo = None
      }
  | Positive_predicate -> None

let supported_iter_shape body iter generators =
  match iter, generators, body.it with
  | Opt, [ _source_generator, _source_exp ], IfPr _ -> true
  | (List | List1 | ListN (_, None)), [ _source_generator, _source_exp ], _ ->
    true
  | (List | List1 | ListN (_, None)), _ :: _ :: _, _ -> true
  | _ -> false

let iter_blocker body iter generators = function
  | (Search_helper | Truth_helper) when supported_iter_shape body iter generators -> None
  | Search_helper | Truth_helper ->
    Some
      { constructor = "RuntimePredicateClosure/IterPr"
      ; reason =
          "iterated premise shape is not covered by the source-shaped IterPr helpers"
      ; suggestion =
          "Materialize the missing IterPr helper shape before using this relation in predicate search"
      ; premise_origin = None
      ; premise_constructor = None
      ; premise_source_echo = None
      }
  | Positive_predicate ->
    None

let neg_blocker = function
  | Search_helper | Truth_helper ->
    { constructor = "RuntimePredicateClosure/NegPr"
    ; reason = "negated premise needs decidable complement before search generation"
    ; suggestion =
        "Implement a source-derived decidable complement before using this relation in predicate search"
    ; premise_origin = None
    ; premise_constructor = None
    ; premise_source_echo = None
    }
  | Positive_predicate ->
    { constructor = "RuntimePredicateClosure/NegPr"
    ; reason = "negated premise needs decidable complement before predicate completeness can be proven"
    ; suggestion =
        "Implement a source-derived decidable complement before proving this predicate complete"
    ; premise_origin = None
    ; premise_constructor = None
    ; premise_source_echo = None
    }

let rulepr_args_blocker rel_id args =
  { constructor = "RuntimePredicateClosure/RulePr/args"
  ; reason =
      "parameterized RulePr premise `"
      ^ rel_id.it
      ^ "` carries explicit arguments `"
      ^ Il.Print.string_of_args args
      ^ "`, so predicate closure cannot treat it as an unparameterized relation call"
  ; suggestion =
      "Preserve this premise as Unsupported until relation-argument instantiation is lowered source-completely"
  ; premise_origin = None
  ; premise_constructor = None
  ; premise_source_echo = None
  }

let truth_external_validation_premise graph rel_id args mixop exp =
  match graph.find_relation rel_id.it with
  | None -> false
  | Some relation ->
    Runtime_validation_certificate.certified
      ~predicate_marker:(relation.kind = Predicate_candidate)
      ~source_params:relation.source_params
      ~runtime_demanded:relation.runtime_demanded
      ~mixop_equal:graph.mixop_equal
      ~declaration_mixop:relation.mixop
      ~premise_args:args
      ~premise_mixop:mixop
      ~result:relation.result
      ~premise_exp:exp

let rec premise_dependencies graph use prem =
  match prem.it with
  | IfPr exp ->
    let blockers =
      match if_blocker exp use with
      | None -> []
      | Some blocker -> [ with_premise prem blocker ]
    in
    [], blockers
  | LetPr _ ->
    let blockers =
      match let_blocker use with
      | None -> []
      | Some blocker -> [ with_premise prem blocker ]
    in
    [], blockers
  | RulePr (rel_id, args, mixop, exp) ->
    if use = Truth_helper
       && truth_external_validation_premise graph rel_id args mixop exp
    then
      [], []
    else if args = [] then
      [ { dep_id = rel_id.it
        ; rule_id = None
        ; rule_origin = None
        ; rule_source_echo = None
        ; premise_origin = premise_origin prem
        ; premise_constructor = constructor_of_premise prem
        ; premise_source_echo = premise_source_echo prem
        }
      ], []
    else
      [], [ with_premise prem (rulepr_args_blocker rel_id args) ]
  | ElsePr ->
    [], [ with_premise prem (otherwise_blocker use) ]
  | IterPr (body, (iter, generators)) ->
    let deps, blockers = premise_dependencies graph use body in
    let blockers =
      match iter_blocker body iter generators use with
      | None -> blockers
      | Some blocker -> with_premise prem blocker :: blockers
    in
    deps, blockers
  | NegPr body ->
    let deps, blockers = premise_dependencies graph use body in
    deps, with_premise prem (neg_blocker use) :: blockers

let make_blocker
    relation_id
    ?origin
    ?rule_id
    ?source_echo
    ?premise_origin
    ?premise_constructor
    ?premise_source_echo
    premise =
  { relation_id
  ; rule_id
  ; origin
  ; constructor = premise.constructor
  ; reason = premise.reason
  ; suggestion = premise.suggestion
  ; source_echo
  ; premise_origin =
      (match premise_origin with
      | Some _ -> premise_origin
      | None -> premise.premise_origin)
  ; premise_constructor =
      (match premise_constructor with
      | Some _ -> premise_constructor
      | None -> premise.premise_constructor)
  ; premise_source_echo =
      (match premise_source_echo with
      | Some _ -> premise_source_echo
      | None -> premise.premise_source_echo)
  }

let rule_premise_blocker relation_id (rule : rule) premise =
  make_blocker
    relation_id
    ~origin:rule.origin
    ?rule_id:rule.rule_id
    ?source_echo:rule.source_echo
    premise

let dependency_blocker relation_id dependency premise =
  make_blocker
    relation_id
    ?origin:dependency.rule_origin
    ?rule_id:dependency.rule_id
    ?source_echo:dependency.rule_source_echo
    ?premise_origin:dependency.premise_origin
    ~premise_constructor:dependency.premise_constructor
    ?premise_source_echo:dependency.premise_source_echo
    premise

let transitive_domain_premise relation_id (rule : rule) =
  let source_rule =
    { Runtime_witness_proof.identity = rule.identity
    ; relation_id
    ; rule_id = rule.rule_id
    ; origin = rule.origin
    ; source_echo = rule.source_echo
    ; head = rule.head
    ; prems = rule.prems
    }
  in
  source_rule
  |> Runtime_witness_proof.transitive_domain
  |> Option.map (fun (domain : Runtime_witness_proof.transitive_domain) ->
    domain.domain_premise)

let same_source_premise left right =
  left == right || String.equal (Il.Print.string_of_prem left) (Il.Print.string_of_prem right)

let rule_dependencies graph use relation_id relation_mixop (rule : rule) =
  let marker_blockers =
    if graph.mixop_equal relation_mixop rule.mixop then
      []
    else
      [ { constructor = "RuntimePredicateClosure/rule-mixop"
        ; reason = "rule mixop skeleton does not match the enclosing RelD skeleton"
        ; suggestion =
            "Keep this relation out of predicate search until local RuleD mixops match the enclosing RelD source skeleton"
        ; premise_origin = None
        ; premise_constructor = None
        ; premise_source_echo = None
        }
      ]
  in
  let domain_premise =
    match use with
    | Search_helper | Truth_helper -> transitive_domain_premise relation_id rule
    | Positive_predicate -> None
  in
  let deps, blockers =
    rule.prems
    |> List.map (fun prem ->
      match domain_premise with
      | Some domain_premise when same_source_premise prem domain_premise -> [], []
      | Some _ | None -> premise_dependencies graph use prem)
    |> List.fold_left
         (fun (deps, blockers) (new_deps, new_blockers) ->
           List.rev_append new_deps deps, List.rev_append new_blockers blockers)
         ([], [])
  in
  let deps =
    deps
    |> List.map (fun dependency ->
      { dependency with
        rule_id = rule.rule_id
      ; rule_origin = Some rule.origin
      ; rule_source_echo = rule.source_echo
      })
  in
  let blockers =
    marker_blockers @ List.rev blockers
    |> List.map
         (rule_premise_blocker relation_id rule)
  in
  List.rev deps, blockers

let source_rule relation_id (rule : rule) =
  { Runtime_witness_proof.identity = rule.identity
  ; relation_id
  ; rule_id = rule.rule_id
  ; origin = rule.origin
  ; source_echo = rule.source_echo
  ; head = rule.head
  ; prems = rule.prems
  }

let source_transitive_witness_rule relation_id rule =
  source_rule relation_id rule
  |> Runtime_witness_proof.transitive_domain
  |> Option.is_some

let source_target_chain_rule relation_id rule =
  source_rule relation_id rule
  |> Runtime_witness_proof.target_chain
  |> Option.is_some

let cycle_has_source_target_chain graph cycle =
  match List.rev cycle with
  | relation_id :: _ ->
    (match graph.find_relation relation_id with
    | Some { rules = Some rules; _ } ->
      List.exists (source_target_chain_rule relation_id) rules
    | _ -> false)
  | [] -> false

let cycle_has_source_transitive_rule graph cycle =
  cycle
  |> List.exists (fun relation_id ->
    match graph.find_relation relation_id with
    | Some { rules = Some rules; _ } ->
      List.exists (source_transitive_witness_rule relation_id) rules
    | _ -> false)

let recursive_blocker graph use cycle =
  let cycle_text = String.concat " -> " cycle in
  match use with
  | (Truth_helper | Search_helper)
    when cycle_has_source_target_chain graph cycle ->
    None
  | (Truth_helper | Search_helper)
    when cycle_has_source_transitive_rule graph cycle ->
    Some
      { constructor = "RuntimePredicateClosure/recursive-transitive-cycle"
      ; reason =
          "recursive predicate dependency cycle `"
          ^ cycle_text
          ^ "` contains a source transitivity rule, but no source-complete goal worklist proof has been established"
      ; suggestion =
          "Build a finitely branching source-derived AND/OR SCC worklist keyed by complete ground goals, with separate positive and total-false proofs, before emitting truth or search helpers"
      ; premise_origin = None
      ; premise_constructor = None
      ; premise_source_echo = None
      }
  | Truth_helper | Search_helper ->
    Some
      { constructor = "RuntimePredicateClosure/recursive-truth-cycle"
      ; reason =
          "recursive predicate dependency cycle `"
          ^ cycle_text
          ^ "` has no recognized source-decreasing or source-finite recursion proof"
      ; suggestion =
          "Provide a structural recursion proof for positive search and a separate source-complete no-hit proof, or keep this relation Unsupported"
      ; premise_origin = None
      ; premise_constructor = None
      ; premise_source_echo = None
      }
  | Positive_predicate ->
    None

let empty_body_blocker = function
  | Search_helper | Truth_helper ->
    { constructor = "RuntimePredicateClosure/empty-body"
    ; reason = "referenced relation has no source RuleD clauses to generate a search relation from"
    ; suggestion =
        "Keep this relation out of predicate search until its source RuleD body is available"
    ; premise_origin = None
    ; premise_constructor = None
    ; premise_source_echo = None
    }
  | Positive_predicate ->
    { constructor = "RuntimePredicateClosure/empty-body"
    ; reason =
        "referenced relation has no source RuleD clauses to prove predicate completeness from"
    ; suggestion =
        "Emit no partial predicate equations until the source RuleD body is available"
    ; premise_origin = None
    ; premise_constructor = None
    ; premise_source_echo = None
    }

let deterministic_blocker use _dep_id =
  match use with
  | Search_helper | Truth_helper -> None
  | Positive_predicate ->
    None

let execution_blocker use dep_id =
  match use with
  | Search_helper | Truth_helper ->
    { constructor = "RuntimePredicateClosure/execution-dependency"
    ; reason =
        "rule premise depends on execution relation `"
        ^ dep_id
        ^ "`; predicate search generation cannot contain rewrite semantics in this slice"
    ; suggestion =
        "Use an explicit rewrite-backed helper boundary before mixing execution semantics into predicate search"
    ; premise_origin = None
    ; premise_constructor = None
    ; premise_source_echo = None
    }
  | Positive_predicate ->
    { constructor = "RuntimePredicateClosure/execution-dependency"
    ; reason =
        "rule premise depends on execution relation `"
        ^ dep_id
        ^ "`; predicate completeness cannot put rewrite semantics in Bool equations"
    ; suggestion =
        "Keep this predicate incomplete until execution dependencies are represented by an explicit helper"
    ; premise_origin = None
    ; premise_constructor = None
    ; premise_source_echo = None
    }

let unknown_blocker use dep_id =
  match use with
  | Search_helper | Truth_helper ->
    { constructor = "RuntimePredicateClosure/unknown-dependency"
    ; reason =
        "rule premise depends on unknown relation `"
        ^ dep_id
        ^ "`; predicate search generation cannot classify it source-completely"
    ; suggestion =
        "Classify the referenced relation structurally before using this predicate in search"
    ; premise_origin = None
    ; premise_constructor = None
    ; premise_source_echo = None
    }
  | Positive_predicate ->
    { constructor = "RuntimePredicateClosure/unknown-dependency"
    ; reason =
        "rule premise depends on unknown relation `"
        ^ dep_id
        ^ "`; predicate completeness cannot classify it source-completely"
    ; suggestion =
        "Classify the referenced relation structurally before proving this predicate complete"
    ; premise_origin = None
    ; premise_constructor = None
    ; premise_source_echo = None
    }

let plan graph use id =
  let closure = ref [] in
  let search_rules = ref [] in
  let blockers = ref [] in
  let add_closure id =
    if not (List.mem id !closure) then closure := id :: !closure
  in
  let add_search_rules relation_id relation_result rules =
    rules
    |> List.iter (fun rule ->
      let search_rule = { relation_id; relation_result; rule } in
      if not (List.mem search_rule !search_rules) then
        search_rules := search_rule :: !search_rules)
  in
  let add_blocker ?origin relation_id premise =
    blockers := make_blocker relation_id ?origin premise :: !blockers
  in
  let add_blockers new_blockers =
    blockers := List.rev_append new_blockers !blockers
  in
  let rec visit stack id =
    if List.mem id stack then (
      add_closure id;
      match recursive_blocker graph use (List.rev (id :: stack)) with
      | None -> ()
      | Some blocker -> add_blocker id blocker)
    else (
      add_closure id;
      match graph.find_relation id with
      | None ->
        add_blocker id
          { constructor = "RuntimePredicateClosure/unknown-relation"
          ; reason = "referenced relation is not known in the source index"
          ; suggestion =
              "Register the referenced source relation before using it in predicate search"
          ; premise_origin = None
          ; premise_constructor = None
          ; premise_source_echo = None
          }
      | Some relation ->
        (match relation.kind with
        | Predicate_candidate -> ()
        | kind ->
          add_blocker
            ~origin:relation.origin
            id
            { constructor = "RuntimePredicateClosure/non-predicate-relation"
            ; reason =
                "referenced relation is classified as `"
                ^ string_of_relation_kind kind
                ^ "`, not as a predicate relation"
            ; suggestion =
                "Keep non-predicate relations out of predicate search unless an explicit helper boundary is implemented"
            ; premise_origin = None
            ; premise_constructor = None
            ; premise_source_echo = None
            });
        (match relation.rules with
        | None ->
          add_blocker ~origin:relation.origin id
            { constructor = "RuntimePredicateClosure/missing-body"
            ; reason = "referenced relation has no source RuleD body in the source index"
            ; suggestion =
                "Keep this relation out of predicate search until the source RuleD body is available"
            ; premise_origin = None
            ; premise_constructor = None
            ; premise_source_echo = None
            }
        | Some [] ->
          add_blocker id (empty_body_blocker use)
        | Some rules ->
          add_search_rules id relation.result rules;
          let deps, rule_blockers =
            rules
            |> List.map (rule_dependencies graph use id relation.mixop)
            |> List.fold_left
                 (fun (deps, blockers) (new_deps, new_blockers) ->
                   List.rev_append new_deps deps, List.rev_append new_blockers blockers)
                 ([], [])
          in
          rule_blockers
          |> List.rev
          |> List.sort_uniq compare_blocker
          |> add_blockers;
          deps
          |> List.rev
          |> List.sort_uniq compare_dependency
          |> List.iter (fun dependency ->
            match graph.find_relation dependency.dep_id with
            | None ->
              blockers :=
                dependency_blocker
                  id
                  dependency
                { constructor = "RuntimePredicateClosure/unknown-dependency"
                ; reason =
                    "rule premise references unknown relation `"
                    ^ dependency.dep_id
                    ^ "`"
                ; suggestion =
                    "Register and classify the referenced relation before using this predicate in search"
                ; premise_origin = None
                ; premise_constructor = None
                ; premise_source_echo = None
                }
                :: !blockers
            | Some dep_relation ->
              (match dep_relation.kind with
              | Predicate_candidate ->
                visit (id :: stack) dependency.dep_id
              | Deterministic_candidate ->
                (match deterministic_blocker use dependency.dep_id with
                | None -> ()
                | Some blocker ->
                  blockers := dependency_blocker id dependency blocker :: !blockers)
              | Execution | Execution_star ->
                blockers :=
                  dependency_blocker id dependency
                    (execution_blocker use dependency.dep_id)
                  :: !blockers
              | Unknown _ ->
                blockers :=
                  dependency_blocker id dependency
                    (unknown_blocker use dependency.dep_id)
                  :: !blockers))))
  in
  visit [] id;
  let closure = List.rev !closure |> List.sort_uniq String.compare in
  match !blockers |> List.rev |> List.sort_uniq compare_blocker with
  | [] -> Complete { closure; rules = List.rev !search_rules }
  | blockers -> Blocked { closure; rules = List.rev !search_rules; blockers }

let is_runtime_predicate_dependency graph dep_id =
  match graph.find_relation dep_id with
  | Some { kind = Predicate_candidate; runtime_demanded = true; _ } -> true
  | Some _ | None -> false

let dependency_completeness graph id =
  let closure = ref [] in
  let blockers = ref [] in
  let add_closure id =
    if not (List.mem id !closure) then closure := id :: !closure
  in
  let add_blockers new_blockers =
    blockers := List.rev_append new_blockers !blockers
  in
  let deps_of id =
    graph.dependencies id
    |> List.filter (is_runtime_predicate_dependency graph)
    |> List.sort_uniq String.compare
  in
  let rec visit seen id =
    if not (List.mem id seen) then
      deps_of id
      |> List.iter (fun dep_id ->
        add_closure dep_id;
        (match plan graph Positive_predicate dep_id with
        | Complete { closure = dep_closure; _ } ->
          List.iter add_closure dep_closure
        | Blocked { closure = dep_closure; blockers = dep_blockers; _ } ->
          List.iter add_closure dep_closure;
          add_blockers dep_blockers);
        visit (id :: seen) dep_id)
  in
  visit [] id;
  let closure = List.rev !closure |> List.sort_uniq String.compare in
  match !blockers |> List.rev |> List.sort_uniq compare_blocker with
  | [] -> Complete { closure; rules = [] }
  | blockers -> Blocked { closure; rules = []; blockers }
