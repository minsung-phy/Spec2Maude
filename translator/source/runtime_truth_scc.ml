open Il.Ast
open Util.Source

type phase =
  | Goal
  | Optional
  | List
  | List1
  | List_indexed

type blocker =
  { relation_id : string
  ; rule_id : string option
  ; origin : Origin.t
  ; constructor : string
  ; reason : string
  ; suggestion : string
  ; source_echo : string option
  }

type premise =
  | Finite_rule_call of
      { relation_id : string
      ; premise : Il.Ast.prem
      }
  | Finite_domain_call of Il.Ast.prem
  | Finite_successor_call of
      { relation_id : string
      ; introduced : string list
      ; premise : Il.Ast.prem
      }
  | Deterministic_total of Il.Ast.prem
  | Externally_validated of Il.Ast.prem
  | Source_boolean of Il.Ast.prem
  | Deterministic_binding_iter of Il.Ast.prem
  | Finite_iter of
      { phase : phase
      ; premise : Il.Ast.prem
      ; body : premise list
      }

type rule =
  { source : Analysis.Function_graph.runtime_search_rule
  ; premises : premise list
  ; schedule : int list
  }

type scc =
  { index : int
  ; relations : string list
  ; rules : rule list
  }

type t =
  { root_relation : string
  ; closure : string list
  ; sccs : scc list
  ; successor_domains : Runtime_truth_successor_domain.t list
  ; blockers : blocker list
  }

let phase_key = function
  | Goal -> "goal"
  | Optional -> "optional"
  | List -> "list"
  | List1 -> "list1"
  | List_indexed -> "list-indexed"

let complete plan = plan.blockers = []

let decision_complete plan =
  complete plan
  && List.for_all
       Runtime_truth_successor_domain.decision_complete
       plan.successor_domains

let incomplete_decision_relations plan =
  plan.successor_domains
  |> List.filter_map (fun domain ->
       if Runtime_truth_successor_domain.decision_complete domain then None
       else Some domain.transitive.rule.relation_id)
  |> List.sort_uniq String.compare

let find_scc plan relation_id =
  List.find_opt (fun scc -> List.mem relation_id scc.relations) plan.sccs

let scheduled_premises rule =
  rule.schedule
  |> List.map (fun index ->
    match List.nth_opt rule.premises index with
    | Some premise -> index, premise
    | None -> invalid_arg "Runtime_truth_scc.scheduled_premises")

let successor_domain plan transitive =
  plan.successor_domains
  |> List.find_opt (fun domain ->
    Runtime_truth_successor_domain.matches domain transitive)

let free_var_ids_of_exp exp =
  Il.Free.(free_exp exp).varid |> Il.Free.Set.elements

let free_var_ids_of_prem prem =
  Il.Free.(free_prem prem).varid |> Il.Free.Set.elements

let add_bound bound ids =
  List.fold_left (fun bound id -> if List.mem id bound then bound else id :: bound) bound ids

let missing bound prem =
  free_var_ids_of_prem prem |> List.filter (fun id -> not (List.mem id bound))

let rec total_bound_value bound exp =
  match exp.it with
  | VarE id -> List.mem id.it bound
  | BoolE _ | NumE _ | TextE _ -> true
  | TupE exps | ListE exps -> List.for_all (total_bound_value bound) exps
  | OptE None -> true
  | OptE (Some exp) -> total_bound_value bound exp
  | StrE fields ->
    List.for_all (fun (_, exp) -> total_bound_value bound exp) fields
  | UnE _ | BinE _ | CmpE _ | ProjE _ | CaseE _ | UncaseE _ | TheE _
  | DotE _ | CompE _ | LiftE _ | MemE _ | LenE _ | CatE _ | IdxE _
  | SliceE _ | UpdE _ | ExtE _ | IfE _ | CallE _ | IterE _ | CvtE _
  | SubE _ -> false

let rec source_pattern_bindings bound exp =
  let combine results =
    if List.exists Option.is_none results then None
    else
      results |> List.filter_map Fun.id |> List.concat
      |> List.sort_uniq String.compare |> Option.some
  in
  match exp.it with
  | VarE id -> Some (if List.mem id.it bound || id.it = "_" then [] else [ id.it ])
  | BoolE _ | NumE _ | TextE _ | OptE None -> Some []
  | TupE exps | ListE exps -> combine (List.map (source_pattern_bindings bound) exps)
  | CaseE (_, arg) | OptE (Some arg) | TheE arg | LiftE arg ->
    source_pattern_bindings bound arg
  | StrE fields ->
    combine (List.map (fun (_, exp) -> source_pattern_bindings bound exp) fields)
  | IterE ({ it = VarE body; _ }, (iter, [ generator, source ]))
    when String.equal body.it generator.it ->
    let source = source_pattern_bindings bound source in
    let count =
      match iter with
      | ListN ({ it = VarE id; _ }, _) ->
        Some (if List.mem id.it bound then [] else [ id.it ])
      | ListN (count, _) when total_bound_value bound count -> Some []
      | Opt | List | List1 -> Some []
      | ListN _ -> None
    in
    combine [ source; count ]
  | UnE _ | BinE _ | CmpE _ | ProjE _ | UncaseE _ | DotE _ | CompE _
  | MemE _ | LenE _ | CatE _ | IdxE _ | SliceE _ | UpdE _ | ExtE _
  | IfE _ | CallE _ | IterE _ | CvtE _ | SubE _ -> None

let equality_binding total_value bound prem =
  let binding pattern value =
    match source_pattern_bindings bound pattern with
    | Some (_ :: _ as introduced) when total_value ~bound value ->
      Some introduced
    | Some _ | None -> None
  in
  match prem.it with
  | IfPr { it = CmpE (`EqOp, _, left, right); _ } ->
    (match binding left right with
    | Some _ as binding -> binding
    | None -> binding right left)
  | RulePr _ | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> None

let equality_match_binding bound prem =
  let binding pattern value =
    match source_pattern_bindings bound pattern with
    | Some (_ :: _ as introduced)
      when free_var_ids_of_exp value
           |> List.for_all (fun id -> List.mem id bound) ->
      Some introduced
    | Some _ | None -> None
  in
  match prem.it with
  | IfPr { it = CmpE (`EqOp, _, left, right); _ } ->
    (match binding left right with
    | Some _ as binding -> binding
    | None -> binding right left)
  | RulePr _ | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> None

let take_dependency_binding total_value bound needed prems =
  let rec take before = function
    | [] -> None
    | ((_, prem) as indexed) :: rest ->
      (match equality_binding total_value bound prem with
      | Some introduced
        when List.exists (fun id -> List.mem id needed) introduced ->
        Some (indexed, List.rev_append before rest)
      | Some _ | None -> take (indexed :: before) rest)
  in
  take [] prems

let finite_generator_source exp =
  match exp.note.it with
  | IterT (_, (Opt | List | List1 | ListN _)) -> true
  | _ -> false

let iter_outer_expressions iter generators =
  let sources = List.map snd generators in
  match iter with
  | ListN (count, _) -> count :: sources
  | Opt | List | List1 -> sources

let iter_local_ids iter generators =
  let ids = List.map (fun (id, _) -> id.it) generators in
  match iter with
  | ListN (_, Some id) -> id.it :: ids
  | Opt | List | List1 | ListN (_, None) -> ids

let direct_unbound_source bound (_, exp) =
  match exp.it with
  | VarE id when not (List.mem id.it bound) -> Some id.it
  | _ -> None

let iter_binding_outputs bound body generators =
  let targets = List.filter_map (direct_unbound_source bound) generators in
  let input_generators =
    generators
    |> List.filter_map (fun (id, source) ->
      if Option.is_none (direct_unbound_source bound (id, source)) then Some id.it
      else None)
  in
  let body_bound = add_bound bound input_generators in
  match equality_match_binding body_bound body with
  | Some introduced ->
    generators
    |> List.filter_map (fun (generator, source) ->
      match source.it with
      | VarE id
        when List.mem id.it targets && List.mem generator.it introduced ->
        Some id.it
      | _ -> None)
    |> List.sort_uniq String.compare
  | None -> []

let rec indexed_source_for id exp =
  match exp.it with
  | IdxE (source, { it = VarE index; _ }) when String.equal id index.it ->
    (match source.note.it with
    | IterT (_, (List | List1 | ListN _)) -> Some source
    | _ -> None)
  | SubE (inner, _, _) | CvtE (inner, _, _) -> indexed_source_for id inner
  | _ -> None

let indexed_successor introduced prem =
  match introduced, prem.it with
  | [ index ], RulePr (_, [], _, exp) ->
    let components = Analysis.Relation_graph.exp_components exp in
    let sources = List.filter_map (indexed_source_for index) components in
    (match sources with [ _ ] -> true | [] | _ :: _ :: _ -> false)
  | _ -> false

let rule_id rule = rule.Analysis.Function_graph.rule_id

let blocker rule ?premise constructor reason suggestion =
  let origin, source_echo =
    match premise with
    | None -> rule.Analysis.Function_graph.origin, rule.source_echo
    | Some prem ->
      ( Origin.with_child
          ~source_echo:(Il.Print.string_of_prem prem)
          rule.origin
          "premise"
          ~ast_constructor:"Premise"
          prem.at
      , Some (Il.Print.string_of_prem prem) )
  in
  { relation_id = rule.relation_id
  ; rule_id = rule_id rule
  ; origin
  ; constructor
  ; reason
  ; suggestion
  ; source_echo
  }

let successor_blocker (blocker : Runtime_truth_successor_domain.blocker) =
  { relation_id = blocker.relation_id
  ; rule_id = blocker.rule_id
  ; origin = blocker.origin
  ; constructor = blocker.constructor
  ; reason = blocker.reason
  ; suggestion = blocker.suggestion
  ; source_echo = blocker.source_echo
  }

let relation_kind graph id =
  Analysis.Function_graph.find_relation graph id
  |> Option.map (fun relation -> relation.Analysis.Function_graph.kind)

let runtime_call graph id =
  match Analysis.Function_graph.find_relation graph id with
  | Some relation ->
    relation.kind = Analysis.Relation_graph.Predicate_candidate
    && relation.rule_count > 0
  | None -> false

let validation_certificate graph prem =
  match prem.it with
  | RulePr (id, args, mixop, exp) ->
    (match Analysis.Function_graph.find_relation graph id.it with
    | Some relation ->
      Some
        (Runtime_validation_certificate.certify
           ~predicate_marker:
             (relation.kind = Analysis.Relation_graph.Predicate_candidate)
           ~source_params:relation.source_params
           ~runtime_demanded:
             (Analysis.Function_graph.relation_is_runtime_demanded graph id.it)
           ~mixop_equal:Il.Eq.eq_mixop
           ~declaration_mixop:relation.mixop
           ~premise_args:args
           ~premise_mixop:mixop
           ~result:relation.result
           ~premise_exp:exp)
    | None -> None)
  | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> None

let validation_total_leaf graph _bound prem =
  validation_certificate graph prem
  = Some Runtime_validation_certificate.Certified

let phase_of_iter = function
  | Opt -> Some Optional
  | List -> Some List
  | List1 -> Some List1
  | ListN (_, Some _) -> Some List_indexed
  | ListN (_, None) -> Some List

let rec classify_premise total_value graph rule
    ~retain_validation ~finite_domain bound prem =
  match prem.it with
  | RulePr (_, [], _, _) when retain_validation && finite_domain ->
    let introduced = missing bound prem in
    Finite_domain_call prem, add_bound bound introduced, [], []
  | RulePr (id, [], _, _)
    when not retain_validation
         && not (runtime_call graph id.it)
         && validation_total_leaf graph bound prem ->
    Externally_validated prem, bound, [], []
  | RulePr (id, [], _, _) when runtime_call graph id.it ->
    let introduced = missing bound prem in
    let child =
      if introduced = [] then
        Finite_rule_call { relation_id = id.it; premise = prem }
      else if indexed_successor introduced prem then
        Finite_iter
          { phase = List_indexed
          ; premise = prem
          ; body = [ Finite_rule_call { relation_id = id.it; premise = prem } ]
          }
      else
        Finite_successor_call
          { relation_id = id.it; introduced; premise = prem }
    in
    let blockers =
      if introduced = [] || indexed_successor introduced prem then []
      else
        [ blocker rule ~premise:prem
            "RuntimeTruthScc/RulePr/open-successor"
            ("RulePr `" ^ id.it ^ "` introduces successor variable(s) `"
             ^ String.concat "`, `" introduced
             ^ "`, but no finite ground enumerator has been established")
            "Derive a finite successor enumerator from the referenced RuleD heads and ground inputs before admitting this SCC"
        ]
    in
    child, add_bound bound introduced, [ id.it ], blockers
  | RulePr (id, [], _, _) ->
    (match relation_kind graph id.it with
    | Some Analysis.Relation_graph.Deterministic_candidate ->
      let introduced = missing bound prem in
      ( Deterministic_total prem, add_bound bound introduced, [], [] )
    | Some Analysis.Relation_graph.Predicate_candidate ->
      let introduced = missing bound prem in
      if introduced = [] then
        (match validation_certificate graph prem with
        | Some Runtime_validation_certificate.Unavailable reason ->
          ( Deterministic_total prem
          , bound
          , []
          , [ blocker rule ~premise:prem
                "RuntimeTruthScc/RulePr/validation-certificate"
                ("external-validation discharge is not structurally certified: "
                 ^ reason)
                "Keep this premise Unsupported or materialize its complete runtime predicate relation"
            ] )
        | Some Runtime_validation_certificate.Certified | None ->
          Deterministic_total prem, bound, [], [])
      else
        ( Finite_successor_call
            { relation_id = id.it; introduced; premise = prem }
        , add_bound bound introduced
        , []
        , [ blocker rule ~premise:prem
              "RuntimeTruthScc/RulePr/open-successor"
              ("validation RulePr `" ^ id.it
               ^ "` introduces a successor without a proven finite ground enumerator")
              "Materialize the exact finite validation domain before admitting this successor edge"
          ] )
    | Some (Analysis.Relation_graph.Execution | Execution_star | Unknown) | None ->
      let kind =
        match relation_kind graph id.it with
        | None -> "unknown"
        | Some kind -> Analysis.Relation_graph.string_of_relation_kind kind
      in
      ( Deterministic_total prem
      , bound
      , []
      , [ blocker rule ~premise:prem
            "RuntimeTruthScc/RulePr/open"
            ("RulePr `" ^ id.it ^ "` is " ^ kind
             ^ ", so it has no finite runtime-truth successor contract")
            "Provide a source finite/total relation contract or keep this ground query Unsupported"
        ] ))
  | RulePr (id, _ :: _, _, _) ->
    ( Deterministic_total prem
    , bound
    , []
    , [ blocker rule ~premise:prem
          "RuntimeTruthScc/RulePr/parameterized"
          ("parameterized RulePr `" ^ id.it
           ^ "` has no complete specialization in the runtime truth key")
          "Close every static relation argument before requesting the SCC worklist"
      ] )
  | IfPr { it = CmpE (`EqOp, _, _, _); _ } ->
    let introduced =
      Option.value ~default:[] (equality_match_binding bound prem)
    in
    Source_boolean prem, add_bound bound introduced, [], []
  | IfPr _ -> Source_boolean prem, bound, [], []
  | LetPr _ ->
    let introduced = missing bound prem in
    Deterministic_total prem, add_bound bound introduced, [], []
  | IterPr (body, (iter, generators)) ->
    (match phase_of_iter iter with
    | Some phase when generators <> [] ->
      let binding_outputs =
        iter_binding_outputs bound body generators
      in
      let outer = iter_outer_expressions iter generators in
      let unbound =
        outer |> List.concat_map free_var_ids_of_exp
        |> List.filter (fun id ->
             not (List.mem id bound || List.mem id binding_outputs))
        |> List.sort_uniq String.compare
      in
      let finite = List.for_all finite_generator_source (List.map snd generators) in
      let body_bound = add_bound bound (iter_local_ids iter generators) in
      let child, _, deps, body_blockers =
        classify_premise total_value graph rule
          ~retain_validation:false ~finite_domain:false body_bound body
      in
      let domain_blockers =
        if unbound <> [] then
          [ blocker rule ~premise:prem
              "RuntimeTruthScc/IterPr/generator-domain-unbound"
              ("IterPr generator/count expression uses outer variable(s) `"
               ^ String.concat "`, `" unbound
               ^ "` before they are bound")
              "Bind every finite generator source and ListN count outside the IterPr; generator ids are local only to its body"
          ]
        else if not finite then
          [ blocker rule ~premise:prem
              "RuntimeTruthScc/IterPr/generator-domain"
              "IterPr generator expression has no finite list/optional IL type"
              "Keep this iterator Unsupported until its source domain is a finite IterT constructor"
          ]
        else []
      in
      ( (if binding_outputs = [] then
           Finite_iter { phase; premise = prem; body = [ child ] }
         else Deterministic_binding_iter prem)
      , add_bound bound binding_outputs
      , deps
      , domain_blockers @ body_blockers )
    | Some _ | None ->
      ( Deterministic_total prem
      , bound
      , []
      , [ blocker rule ~premise:prem
            "RuntimeTruthScc/IterPr/open"
            "IterPr does not expose a finite source list/optional/index generator"
            "Preserve the query as Unsupported until the exact iteration successor set is finite"
        ] ))
  | ElsePr ->
    ( Deterministic_total prem
    , bound
    , []
    , [ blocker rule ~premise:prem
          "RuntimeTruthScc/ElsePr"
          "ElsePr has no source-derived exhaustive complement inside the truth graph"
          "Preprocess enabledness before admitting this rule to the SCC worklist"
      ] )
  | NegPr _ ->
    ( Deterministic_total prem
    , bound
    , []
    , [ blocker rule ~premise:prem
          "RuntimeTruthScc/NegPr"
          "NegPr is open until its child has a total finite decision"
          "Materialize the child total decision before admitting this negation"
      ] )

let classify_rule total_value graph
    (finite_domain : Runtime_truth_successor_domain.t option) rule =
  let components = Analysis.Relation_graph.exp_components rule.Analysis.Function_graph.head in
  let bound = components |> List.concat_map free_var_ids_of_exp |> List.sort_uniq String.compare in
  let bound =
    match finite_domain with
    | Some domain ->
      add_bound bound
        [ domain.Runtime_truth_successor_domain.transitive.witness_source_id ]
    | None -> bound
  in
  let rec classify plans schedule bound deps blockers = function
    | [] -> plans, List.rev schedule, bound, deps, blockers
    | ((source_index, prem) as indexed) :: rest ->
      let needed =
        match prem.it with
        | RulePr _ -> missing bound prem
        | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> []
      in
      (match take_dependency_binding total_value bound needed rest with
      | Some (binding, remaining) ->
        classify plans schedule bound deps blockers
          (binding :: indexed :: remaining)
      | None ->
        let retain_validation =
          match finite_domain with
          | Some domain ->
            let transitive = domain.Runtime_truth_successor_domain.transitive in
            Il.Eq.eq_prem
              prem transitive.Runtime_witness_proof.domain_premise
          | None -> false
        in
        let plan, bound, new_deps, new_blockers =
          classify_premise total_value graph rule ~retain_validation
            ~finite_domain:
              (match finite_domain with
              | Some domain ->
                Runtime_truth_successor_domain.decision_complete domain
              | None -> false)
            bound prem
        in
        classify
          ((source_index, plan) :: plans)
          (source_index :: schedule)
          bound
          (List.rev_append new_deps deps)
          (List.rev_append new_blockers blockers)
          rest)
  in
  let indexed_prems = List.mapi (fun index prem -> index, prem) rule.prems in
  let premises, schedule, _, _dependencies, blockers =
    classify [] [] bound [] [] indexed_prems
  in
  let source_rule =
    { Runtime_witness_proof.identity = rule.identity
    ; relation_id = rule.relation_id
    ; rule_id = rule.rule_id
    ; origin = rule.origin
    ; source_echo = rule.source_echo
    ; head = rule.head
    ; prems = rule.prems
    }
  in
  let target = Runtime_witness_proof.target_chain source_rule in
  let premises =
    premises |> List.sort (fun (left, _) (right, _) -> compare left right)
    |> List.map snd
  in
  let dependencies =
    List.rev _dependencies |> List.sort_uniq String.compare
  in
  let admitted_successor =
    match target with
    | Some target -> Some target.recursive_premise
    | None -> None
  in
  let dependencies, blockers =
    match finite_domain, admitted_successor with
    | Some _, _ -> dependencies, blockers
    | None, None -> dependencies, blockers
    | None, Some admitted ->
      (* Filter only the target-chain successor justified by seed RuleD
         alternatives.  A transitive-domain shape is not itself a finite
         candidate theorem: indexed and projection-produced endpoints must be
         represented by an explicit materializable certificate first. *)
      dependencies, List.filter
        (fun blocker ->
          blocker.constructor <> "RuntimeTruthScc/RulePr/open-successor"
          || blocker.source_echo <> Some (Il.Print.string_of_prem admitted))
        blockers
  in
  ( { source = rule; premises; schedule }
  , dependencies
  , List.rev blockers )

let tarjan vertices successors =
  let next = ref 0 in
  let indices = Hashtbl.create 31 and low = Hashtbl.create 31 in
  let stack = Stack.create () and on_stack = Hashtbl.create 31 in
  let components = ref [] in
  let rec visit vertex =
    let index = !next in
    incr next;
    Hashtbl.add indices vertex index;
    Hashtbl.add low vertex index;
    Stack.push vertex stack;
    Hashtbl.replace on_stack vertex true;
    successors vertex |> List.iter (fun child ->
      if not (Hashtbl.mem indices child) then (
        visit child;
        Hashtbl.replace low vertex (min (Hashtbl.find low vertex) (Hashtbl.find low child)))
      else if Option.value ~default:false (Hashtbl.find_opt on_stack child) then
        Hashtbl.replace low vertex (min (Hashtbl.find low vertex) (Hashtbl.find indices child)));
    if Hashtbl.find low vertex = Hashtbl.find indices vertex then (
      let rec pop acc =
        let item = Stack.pop stack in
        Hashtbl.replace on_stack item false;
        let acc = item :: acc in
        if String.equal item vertex then acc else pop acc
      in
      components := List.sort String.compare (pop []) :: !components)
  in
  List.iter (fun vertex -> if not (Hashtbl.mem indices vertex) then visit vertex) vertices;
  List.rev !components

let plan
    ?(total_value = fun ~bound exp -> total_bound_value bound exp)
    ?(zero_or_one_value = fun ~bound:_ _ -> false)
    ?(total_value_with_facts = fun ~facts:_ ~bound exp -> total_value ~bound exp)
    ?constructors
    ?resolve_constructor
    graph root_relation =
  let rules = Hashtbl.create 31 and edges = Hashtbl.create 31 in
  let blockers = ref [] and closure = ref [] and successor_domains = ref [] in
  let rec visit relation_id =
    if not (List.mem relation_id !closure) then (
      closure := relation_id :: !closure;
      match Analysis.Function_graph.runtime_relation_rules graph relation_id with
      | None -> ()
      | Some source_rules ->
        let finite_transitive = ref [] in
        source_rules |> List.iter (fun (rule : Analysis.Function_graph.runtime_search_rule) ->
          let source_rule =
            { Runtime_witness_proof.identity = rule.identity
            ; relation_id = rule.relation_id
            ; rule_id = rule.rule_id; origin = rule.origin
            ; source_echo = rule.source_echo; head = rule.head; prems = rule.prems }
          in
          match Runtime_witness_proof.transitive_domain source_rule with
          | None -> ()
          | Some transitive ->
            (match
               Runtime_truth_successor_domain.certify
                 ~source_total:total_value
                 ~source_zero_or_one:zero_or_one_value
                 ~source_total_with_facts:total_value_with_facts
                 ?constructors ?resolve_constructor graph transitive
             with
            | Blocked domain_blockers ->
              blockers := List.rev_append
                (List.map successor_blocker domain_blockers)
                !blockers
            | Materialized domain ->
              finite_transitive := domain :: !finite_transitive;
              if not (List.exists (fun existing ->
                   String.equal
                     (Runtime_truth_successor_domain.key existing)
                     (Runtime_truth_successor_domain.key domain))
                   !successor_domains)
              then successor_domains := domain :: !successor_domains));
        let plans, dependencies, new_blockers =
          source_rules
          |> List.fold_left (fun (plans, deps, blockers)
                                  (rule : Analysis.Function_graph.runtime_search_rule) ->
            let certified =
              let source_rule =
                { Runtime_witness_proof.identity = rule.identity
                ; relation_id = rule.relation_id
                ; rule_id = rule.rule_id; origin = rule.origin
                ; source_echo = rule.source_echo; head = rule.head; prems = rule.prems }
              in
              match Runtime_witness_proof.transitive_domain source_rule with
              | None -> None
              | Some transitive ->
                !finite_transitive
                |> List.find_opt (fun domain ->
                     Runtime_truth_successor_domain.matches domain transitive)
            in
            let rule_total_value =
              match certified with
              | Some domain ->
                total_value_with_facts ~facts:domain.total_facts
              | None -> total_value
            in
            let plan, rule_deps, rule_blockers =
              classify_rule rule_total_value graph certified rule
            in
            plan :: plans, List.rev_append rule_deps deps,
            List.rev_append rule_blockers blockers) ([], [], [])
        in
        Hashtbl.replace rules relation_id (List.rev plans);
        let dependencies = List.sort_uniq String.compare dependencies in
        Hashtbl.replace edges relation_id dependencies;
        blockers := List.rev_append new_blockers !blockers;
        List.iter visit dependencies)
  in
  visit root_relation;
  let closure = List.rev !closure in
  let successors id = Option.value ~default:[] (Hashtbl.find_opt edges id) in
  let components = tarjan closure successors in
  let sccs =
    components
    |> List.mapi (fun index relations ->
      { index
      ; relations
      ; rules = relations |> List.concat_map (fun id -> Option.value ~default:[] (Hashtbl.find_opt rules id))
      })
  in
  { root_relation; closure; sccs
  ; successor_domains = List.rev !successor_domains
  ; blockers = List.rev !blockers }
