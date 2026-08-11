open Il.Ast
open Util.Source

(* This is a least-fixed-point proof over execution-relation dependencies.
   A relation is admitted only when every rule is constructor-disjoint,
   strictly descends through a certified context, or depends solely on already
   proved relations.  The result therefore certifies that an all-value input
   has no execution successor. *)

type t = All_values_irreducible

type execution_relation =
  { id : id
  ; mixop : mixop
  ; shape : Relation_shape.execution_shape
  ; rules : rule list
  }

type rule_proof =
  | Disjoint
  | Strict_descent
  | Requires of string list
  | Unknown

let split_at count items =
  let rec loop count left right =
    if count = 0 then Some (List.rev left, right)
    else
      match right with
      | [] -> None
      | item :: rest -> loop (count - 1) (item :: left) rest
  in
  loop count [] items

let constructor_arity payload =
  match payload.it with
  | TupE payloads -> List.length payloads
  | _ -> 1

let execution_relations ctx =
  Analysis.Source_index.entries (Context.source_index ctx)
  |> List.filter_map (fun (entry : Analysis.Source_index.entry) ->
    match entry.def.it with
    | RelD (id, params, mixop, result, rules) ->
      (match (Relation_shape.of_reld params mixop result).decision with
      | Relation_shape.Execution shape -> Some { id; mixop; shape; rules }
      | Static_validation _ | Runtime_predicate _ | Deterministic_candidate _
      | Unknown _ -> None)
    | TypD _ | DecD _ | GramD _ | RecD _ | HintD _ -> None)

let find_relation relations id =
  List.find_opt (fun relation -> relation.id.it = id) relations

let sequence_typ element_typ =
  IterT (element_typ, List) $ element_typ.at

let rec sequence_nodes typ exp =
  if Il.Eq.eq_typ exp.note typ then [ exp ]
  else
    match exp.it with
    | TupE exps | ListE exps -> List.concat_map (sequence_nodes typ) exps
    | CaseE (_, payload) | SubE (payload, _, _) | LiftE payload ->
      sequence_nodes typ payload
    | BoolE _ | NumE _ | TextE _ | VarE _ | UnE _ | BinE _ | CmpE _
    | ProjE _ | UncaseE _ | OptE _ | TheE _ | StrE _ | DotE _ | CompE _
    | MemE _ | LenE _ | CatE _ | IdxE _ | SliceE _ | UpdE _ | ExtE _
    | IfE _ | CallE _ | IterE _ | CvtE _ -> []

let input_sequence target_typ relation exp =
  let input_count = List.length relation.shape.inputs in
  let component_count = input_count + List.length relation.shape.outputs in
  match
    Analysis.Relation_graph.exp_components_for_count component_count exp
  with
  | None -> None
  | Some components ->
    (match split_at input_count components with
    | None -> None
    | Some (inputs, _) ->
      (match
         inputs
         |> List.concat_map (sequence_nodes (sequence_typ target_typ))
       with
      | [ sequence ] -> Some sequence
      | [] | _ :: _ :: _ -> None))

let rec may_be_all_values value_cases exp =
  match exp.it with
  | CaseE (mixop, payload) ->
    List.exists
      (fun (value_mixop, arity) ->
        Il.Eq.eq_mixop value_mixop mixop
        && arity = constructor_arity payload)
      value_cases
  | CatE (left, right) ->
    may_be_all_values value_cases left
    && may_be_all_values value_cases right
  | ListE exps -> List.for_all (may_be_all_values value_cases) exps
  | IterE (_, (List, _)) | IterE (_, (Opt, _)) | OptE None -> true
  | IterE (body, (List1, _)) | OptE (Some body) ->
    may_be_all_values value_cases body
  | IterE (_, (ListN _, _)) -> true
  | SubE (inner, _, _) | CvtE (inner, _, _) | LiftE inner ->
    may_be_all_values value_cases inner
  | BoolE _ | NumE _ | TextE _ | VarE _ | UnE _ | BinE _ | CmpE _
  | TupE _ | ProjE _ | UncaseE _ | TheE _ | StrE _ | DotE _ | CompE _
  | MemE _ | LenE _ | IdxE _ | SliceE _ | UpdE _ | ExtE _ | IfE _
  | CallE _ -> true

let required_relations relations target_typ head_sequence prems =
  prems
  |> List.filter_map (fun prem ->
    match prem.it with
    | RulePr (id, [], mixop, exp) ->
      (match find_relation relations id.it with
      | Some relation when Il.Eq.eq_mixop relation.mixop mixop ->
        (match input_sequence target_typ relation exp with
        | Some sequence when Il.Eq.eq_exp head_sequence sequence -> Some id.it
        | Some _ | None -> None)
      | Some _ | None -> None)
    | RulePr _ | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> None)
  |> List.sort_uniq String.compare

let strict_descent source_typ target_typ relation rule =
  match Execution_context_certificate.certify relation.id rule with
  | Some certificate ->
    Execution_context_certificate.strictly_smaller_focus certificate
    && Il.Eq.eq_typ
         source_typ
         (Execution_context_certificate.value_source_typ certificate)
    && Il.Eq.eq_typ
         target_typ
         (Execution_context_certificate.value_target_typ certificate)
  | None -> false

let classify_rule
    relations value_cases source_typ target_typ relation rule =
  match rule.it with
  | RuleD (_, _, _, head, prems) ->
    (match input_sequence target_typ relation head with
    | None -> Unknown
    | Some sequence when not (may_be_all_values value_cases sequence) ->
      Disjoint
    | Some _ when strict_descent source_typ target_typ relation rule ->
      Strict_descent
    | Some sequence ->
      (match required_relations relations target_typ sequence prems with
      | [] -> Unknown
      | dependencies -> Requires dependencies))

let relation_proofs relations value_cases source_typ target_typ relation =
  relation.rules
  |> List.map
       (classify_rule relations value_cases source_typ target_typ relation)

let proved_relation proved proofs =
  List.for_all
    (function
      | Disjoint | Strict_descent -> true
      | Requires dependencies ->
        List.exists (fun dependency -> List.mem dependency proved) dependencies
      | Unknown -> false)
    proofs

let close_relations relations proofs =
  let rec loop proved =
    let proved' =
      relations
      |> List.fold_left
           (fun proved relation ->
             if List.mem relation.id.it proved then proved
             else
               match List.assoc_opt relation.id.it proofs with
               | Some rule_proofs when proved_relation proved rule_proofs ->
                 relation.id.it :: proved
               | Some _ | None -> proved)
           proved
      |> List.sort_uniq String.compare
    in
    if proved' = proved then proved else loop proved'
  in
  loop []

(* The certificate proves irreducibility by induction on derivation height,
   with sequence length as the measure for a certified self-context rule.  It
   is recomputed from the complete current RuleD set; any unknown head,
   optional dependency, or unranked cycle makes the optimization unavailable. *)
let certify ctx ~relation_id ~context ~value_cases =
  let source_typ = Execution_context_certificate.value_source_typ context in
  let target_typ = Execution_context_certificate.value_target_typ context in
  if value_cases = [] then None
  else
    let relations = execution_relations ctx in
    let proofs =
      relations
      |> List.map (fun relation ->
        relation.id.it,
        relation_proofs
          relations value_cases source_typ target_typ relation)
    in
    let proved = close_relations relations proofs in
    if List.mem relation_id.it proved then Some All_values_irreducible
    else None
