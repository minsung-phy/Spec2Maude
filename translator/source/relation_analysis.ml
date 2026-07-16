open Il.Ast
open Util.Source

type relation =
  { identity : Source_rule_identity.relation
  ; id : string
  ; origin : Origin.t
  ; source_params : param list
  ; kind : Relation_graph.relation_kind
  ; mixop : mixop
  ; result : typ
  ; rule_count : int
  ; hints : string list
  ; maude_equational_view : bool
  ; external_validation_shape : bool
  }

type relation_demand =
  { id : string
  ; reason : string
  }

type rule_hint =
  { relation_id : string
  ; rule_id : string
  ; origin : Origin.t
  ; hints : hint list
  }

type runtime_search_blocker =
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

type runtime_search_rule =
  { identity : Source_rule_identity.rule
  ; relation_id : string
  ; relation_result : typ
  ; rule_id : string option
  ; origin : Origin.t
  ; source_echo : string option
  ; binds : quant list
  ; mixop : mixop
  ; head : exp
  ; prems : prem list
  }

type runtime_predicate_search_plan =
  | Runtime_search_no_shape_blockers of
      { closure : string list
      ; rules : runtime_search_rule list
      }
  | Runtime_search_blocked_plan of
      { closure : string list
      ; rules : runtime_search_rule list
      ; blockers : runtime_search_blocker list
      }

type runtime_predicate_dependency_completeness =
  | Runtime_predicate_dependencies_complete of
      { closure : string list
      }
  | Runtime_predicate_dependencies_incomplete of
      { closure : string list
      ; rules : runtime_search_rule list
      ; blockers : runtime_search_blocker list
      }

type relation_body =
  { relation_id : id
  ; relation_origin : Origin.t
  ; relation_params : param list
  ; relation_rules : rule list
  }

type t =
  { relations : relation list
  ; relations_by_id : (string, relation) Hashtbl.t
  ; rule_hints_by_id : (string, rule_hint) Hashtbl.t
  ; relation_bodies_by_id : (string, relation_body) Hashtbl.t
  ; relation_bodies : relation_body list
  ; relation_edges_by_id : (string, string list) Hashtbl.t
  ; relation_runtime_demands : (string, relation_demand) Hashtbl.t
  }

let add_once table key value =
  if not (Hashtbl.mem table key) then Hashtbl.add table key value

let rec collect_relation_refs_from_prem acc prem =
  match prem.it with
  | RulePr (rel_id, _, _, _) ->
    if List.mem rel_id.it acc then acc else rel_id.it :: acc
  | IterPr (prem, _) | NegPr prem ->
    collect_relation_refs_from_prem acc prem
  | IfPr _ | LetPr _ | ElsePr -> acc

let collect_relation_refs_from_rule rule =
  match rule.it with
  | RuleD (_, _, _, _, prems) ->
    prems
    |> List.fold_left collect_relation_refs_from_prem []
    |> List.rev

let maude_equational_view_hint = "maude_equational_view"

let relation_hint_table entries =
  let table = Hashtbl.create 127 in
  entries
  |> List.iter (fun (entry : Source_index.entry) ->
    match entry.def.it with
    | HintD hintdef ->
      (match hintdef.it with
      | RelH (id, hints) ->
        let old =
          match Hashtbl.find_opt table id.it with
          | None -> []
          | Some names -> names
        in
        let names =
          hints
          |> List.map (fun hint -> hint.hintid.it)
          |> List.fold_left
               (fun acc name -> if List.mem name acc then acc else name :: acc)
               (List.rev old)
          |> List.rev
        in
        Hashtbl.replace table id.it names
      | TypH _ | DecH _ | GramH _ | RuleH _ -> ())
    | TypD _ | RelD _ | DecD _ | GramD _ | RecD _ -> ());
  table

let relation_hints table id =
  match Hashtbl.find_opt table id with
  | None -> []
  | Some hints -> hints

let rule_hint_key ~relation_id ~rule_id =
  relation_id ^ "\000" ^ rule_id

let rule_hint_table entries =
  let table = Hashtbl.create 127 in
  entries
  |> List.iter (fun (entry : Source_index.entry) ->
    match entry.def.it with
    | HintD hintdef ->
      (match hintdef.it with
      | RuleH (rel_id, rule_id, hints) ->
        let key = rule_hint_key ~relation_id:rel_id.it ~rule_id:rule_id.it in
        Hashtbl.replace
          table
          key
          { relation_id = rel_id.it
          ; rule_id = rule_id.it
          ; origin = entry.origin
          ; hints
          }
      | TypH _ | RelH _ | DecH _ | GramH _ -> ())
    | TypD _ | RelD _ | DecD _ | GramD _ | RecD _ -> ());
  table

let is_nullary_marker_case = function
  | _, ({ it = TupT []; _ }, [], []), _ -> true
  | _ -> false

let is_nullary_marker_entry (entry : Source_index.entry) =
  match entry.def.it with
  | TypD
      (_, [],
       [ { it = InstD ([], [], { it = VariantT [ case ]; _ }); _ } ]) ->
    is_nullary_marker_case case
  | TypD _ | RelD _ | DecD _ | GramD _ | RecD _ | HintD _ -> false

let validation_marker_result index typ =
  match typ.it with
  | VarT (id, []) ->
    (match
       Source_index.find_by_id index id.it
       |> List.filter (fun (entry : Source_index.entry) ->
         match entry.def.it with TypD _ -> true | _ -> false)
     with
     | [ entry ] -> is_nullary_marker_entry entry
     | [] | _ :: _ :: _ -> false)
  | VarT _ | BoolT | NumT _ | TextT | TupT _ | IterT _ -> false

let build index =
  let relations_by_id = Hashtbl.create 127 in
  let relation_bodies_by_id = Hashtbl.create 127 in
  let relation_edges_by_id = Hashtbl.create 127 in
  let relations = ref [] in
  let relation_bodies = ref [] in
  let entries = Source_index.entries index in
  let relation_hints_by_id = relation_hint_table entries in
  let rule_hints_by_id = rule_hint_table entries in
  entries
  |> List.iter (fun (entry : Source_index.entry) ->
    match entry.def.it with
    | RelD (id, params, mixop, result, rules) ->
      let hints = relation_hints relation_hints_by_id id.it in
      let identity =
        Source_rule_identity.relation
          ~source_id:id.it ~source_ordinal:entry.ordinal
      in
      let relation =
        { identity
        ; id = id.it
        ; origin = entry.origin
        ; source_params = params
        ; kind = Relation_graph.classify_mixop mixop
        ; mixop
        ; result
        ; rule_count = List.length rules
        ; hints
        ; maude_equational_view = List.mem maude_equational_view_hint hints
        ; external_validation_shape = validation_marker_result index result
        }
      in
      relations := relation :: !relations;
      let relation_body =
        { relation_id = id
        ; relation_origin = entry.origin
        ; relation_params = params
        ; relation_rules = rules
        }
      in
      relation_bodies := relation_body :: !relation_bodies;
      add_once relations_by_id id.it relation;
      add_once relation_bodies_by_id id.it relation_body;
      Hashtbl.replace
        relation_edges_by_id
        id.it
        (rules
         |> List.map collect_relation_refs_from_rule
         |> List.concat
         |> List.sort_uniq String.compare)
    | TypD _ | DecD _ | GramD _ | RecD _ | HintD _ -> ());
  { relations = List.rev !relations
  ; relations_by_id
  ; rule_hints_by_id
  ; relation_bodies_by_id
  ; relation_bodies = List.rev !relation_bodies
  ; relation_edges_by_id
  ; relation_runtime_demands = Hashtbl.create 127
  }

let relations t = t.relations
let relation_bodies t = t.relation_bodies
let find_relation t id = Hashtbl.find_opt t.relations_by_id id

let rule_hints t ~relation_id ~rule_id =
  Hashtbl.find_opt
    t.rule_hints_by_id
    (rule_hint_key ~relation_id ~rule_id)

let relation_has_maude_equational_view relation =
  relation.maude_equational_view

let runtime_seed_reason (relation : relation) =
  match relation.kind with
  | Relation_graph.Execution ->
    Some "execution relation is emitted as Maude rewrite rules, so its RulePr dependencies are runtime-relevant"
  | Relation_graph.Execution_star ->
    Some "execution-star relation is emitted as Maude rewrite rules, so its RulePr dependencies are runtime-relevant"
  | Relation_graph.Deterministic_candidate
  | Relation_graph.Predicate_candidate
  | Relation_graph.Unknown -> None

let decd_runtime_seed_reason relation_id decd_id (relation : relation) =
  match relation.kind with
  | Relation_graph.Execution ->
    Some
      (Printf.sprintf
         "execution relation `%s` is used as a RulePr premise while lowering DecD `%s`; pure equations cannot erase this runtime dependency"
         relation_id
         decd_id)
  | Relation_graph.Execution_star ->
    Some
      (Printf.sprintf
         "execution-star relation `%s` is used as a RulePr premise while lowering DecD `%s`; pure equations cannot erase this runtime dependency"
         relation_id
         decd_id)
  | Relation_graph.Deterministic_candidate ->
    Some
      (Printf.sprintf
         "deterministic relation `%s` is used as a RulePr premise while lowering DecD `%s`; its equational result constrains the generated definition"
         relation_id
         decd_id)
  | Relation_graph.Predicate_candidate | Relation_graph.Unknown -> None

let add_runtime_demand t id reason =
  if Hashtbl.mem t.relation_runtime_demands id then
    false
  else (
    Hashtbl.add t.relation_runtime_demands id { id; reason };
    true)

let runtime_dependency_reason target_id source_id =
  Printf.sprintf
    "relation `%s` is used directly as a RulePr premise while lowering runtime-emitted relation `%s`; skipping it would erase a source branch or guard"
    target_id
    source_id

let add_runtime_dependencies t queue source_id =
  match Hashtbl.find_opt t.relation_edges_by_id source_id with
  | None -> ()
  | Some targets ->
    targets
    |> List.iter (fun target_id ->
      if Hashtbl.mem t.relations_by_id target_id then
        let added =
          add_runtime_demand
            t
            target_id
            (runtime_dependency_reason target_id source_id)
        in
        if added then queue := target_id :: !queue)

let seed_runtime_demand t queue id reason =
  if add_runtime_demand t id reason then
    queue := id :: !queue

let compute_runtime_demands t decd_relation_seeds =
  let queue = ref [] in
  t.relations
  |> List.iter (fun relation ->
    match runtime_seed_reason relation with
    | None -> ()
    | Some reason -> seed_runtime_demand t queue relation.id reason);
  decd_relation_seeds
  |> List.iter (fun (target_id, decd_id) ->
    match Hashtbl.find_opt t.relations_by_id target_id with
    | None -> ()
    | Some relation ->
      (match decd_runtime_seed_reason target_id decd_id relation with
      | None -> ()
      | Some reason -> seed_runtime_demand t queue target_id reason));
  let rec drain = function
    | [] -> ()
    | source_id :: rest ->
      queue := rest;
      add_runtime_dependencies t queue source_id;
      drain !queue
  in
  drain !queue

let relation_runtime_demand_reason t id =
  match Hashtbl.find_opt t.relation_runtime_demands id with
  | None -> None
  | Some demand -> Some demand.reason

let relation_is_runtime_demanded t id =
  Option.is_some (relation_runtime_demand_reason t id)

let runtime_closure_kind = function
  | Relation_graph.Predicate_candidate ->
    Runtime_predicate_closure.Predicate_candidate
  | Relation_graph.Deterministic_candidate ->
    Runtime_predicate_closure.Deterministic_candidate
  | Relation_graph.Execution ->
    Runtime_predicate_closure.Execution
  | Relation_graph.Execution_star ->
    Runtime_predicate_closure.Execution_star
  | Relation_graph.Unknown ->
    Runtime_predicate_closure.Unknown
      (Relation_graph.string_of_relation_kind Relation_graph.Unknown)

let runtime_closure_rule relation_identity source_rule_index rule =
  match rule.it with
  | RuleD (rule_id, binds, mixop, exp, prems) ->
    { Runtime_predicate_closure.identity =
        Source_rule_identity.rule relation_identity ~source_rule_index
    ; rule_id =
        if rule_id.it = "" || rule_id.it = "_" then None else Some rule_id.it
    ; origin =
        Origin.make
          ~source_echo:(Il.Print.string_of_rule rule)
          ~ast_constructor:"RuleD"
          rule.at
    ; source_echo = Some (Il.Print.string_of_rule rule)
    ; binds
    ; mixop
    ; head = exp
    ; prems
    }

let runtime_closure_relation t (relation : relation) =
  let rules =
    match Hashtbl.find_opt t.relation_bodies_by_id relation.id with
    | None -> None
    | Some body ->
      Some
        (List.mapi
           (runtime_closure_rule relation.identity)
           body.relation_rules)
  in
  { Runtime_predicate_closure.id = relation.id
  ; origin = relation.origin
  ; source_params = relation.source_params
  ; kind = runtime_closure_kind relation.kind
  ; mixop = relation.mixop
  ; result = relation.result
  ; rules
  ; runtime_demanded = relation_is_runtime_demanded t relation.id
  ; external_validation_shape = relation.external_validation_shape
  }

let runtime_closure_graph t =
  let find_relation id =
    Hashtbl.find_opt t.relations_by_id id
    |> Option.map (runtime_closure_relation t)
  in
  let dependencies id =
    match Hashtbl.find_opt t.relation_edges_by_id id with
    | None -> []
    | Some deps -> deps
  in
  Runtime_predicate_closure.make
    ~find_relation
    ~dependencies
    ~mixop_equal:Relation_graph.eq_mixop

let runtime_search_blocker
    (blocker : Runtime_predicate_closure.blocker)
  =
  { relation_id = blocker.relation_id
  ; rule_id = blocker.rule_id
  ; origin = blocker.origin
  ; constructor = blocker.constructor
  ; reason = blocker.reason
  ; suggestion = blocker.suggestion
  ; source_echo = blocker.source_echo
  ; premise_origin = blocker.premise_origin
  ; premise_constructor = blocker.premise_constructor
  ; premise_source_echo = blocker.premise_source_echo
  }

let runtime_search_rule
    (search_rule : Runtime_predicate_closure.search_rule)
  =
  let rule = search_rule.rule in
  { identity = rule.identity
  ; relation_id = search_rule.relation_id
  ; relation_result = search_rule.relation_result
  ; rule_id = rule.rule_id
  ; origin = rule.origin
  ; source_echo = rule.source_echo
  ; binds = rule.binds
  ; mixop = rule.mixop
  ; head = rule.head
  ; prems = rule.prems
  }

let runtime_relation_rules t id =
  match
    Hashtbl.find_opt t.relations_by_id id,
    Hashtbl.find_opt t.relation_bodies_by_id id
  with
  | Some relation, Some body ->
    Some
      (body.relation_rules
       |> List.mapi (runtime_closure_rule relation.identity)
       |> List.map (fun rule ->
         runtime_search_rule
           { Runtime_predicate_closure.relation_id = id
           ; relation_result = relation.result
           ; rule
           }))
  | _ -> None

let runtime_predicate_closure_plan t use id =
  match Runtime_predicate_closure.plan (runtime_closure_graph t) use id with
  | Complete { closure; rules } ->
    Runtime_search_no_shape_blockers
      { closure; rules = List.map runtime_search_rule rules }
  | Blocked { closure; rules; blockers } ->
    Runtime_search_blocked_plan
      { closure
      ; rules = List.map runtime_search_rule rules
      ; blockers = List.map runtime_search_blocker blockers
      }

let runtime_predicate_search_plan t id =
  runtime_predicate_closure_plan t Runtime_predicate_closure.Search_helper id

let runtime_predicate_truth_plan t id =
  runtime_predicate_closure_plan t Runtime_predicate_closure.Truth_helper id

let runtime_predicate_dependency_completeness t id =
  match Runtime_predicate_closure.dependency_completeness (runtime_closure_graph t) id with
  | Complete { closure; _ } ->
    Runtime_predicate_dependencies_complete { closure }
  | Blocked { closure; rules; blockers } ->
    Runtime_predicate_dependencies_incomplete
      { closure
      ; rules = List.map runtime_search_rule rules
      ; blockers = List.map runtime_search_blocker blockers
      }
