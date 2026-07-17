open Maude_ir

type term_result =
  { term : term
  ; conditions : rule_condition list
  ; diagnostics : Diagnostics.t list
  }

let empty term = { term; conditions = []; diagnostics = [] }

let diagnostic ctx origin constructor reason suggestion =
  Diagnostics.make ~category:Diagnostics.Unsupported ~origin ~constructor
    ~enclosing:
      (Diagnostic_provenance.enclosing ~context:(Context.enclosing_path ctx) origin)
    ~profile:(Context.profile_name ctx)
    ~reason ~suggestion ()

type call_kind =
  | Ordinary
  | Rewrite of sort
  | Blocked of Diagnostics.t

let classify_call ctx origin term op_name =
  let graph = Context.function_graph ctx in
  match Context.definition_call_identities ctx term with
  | [] when Context.emitted_definition_operator ctx op_name ->
    Blocked
      (diagnostic ctx origin "DecD/rewrite-backed/CallE/missing-provenance"
         ("generated definition call `" ^ op_name
          ^ "` reached rewrite lowering without its source definition identity")
         "Carry the CallE/DefA definition id and specialization key through expression lowering")
  | [] -> Ordinary
  | _ :: _ :: _ ->
    Blocked
      (diagnostic ctx origin "DecD/rewrite-backed/CallE/ambiguous-provenance"
         ("definition call `" ^ op_name
          ^ "` has multiple structured source identities; selecting one would merge specializations")
         "Keep the call Unsupported until its CallE/DefA specialization identity is unique")
  | [ identity ] ->
    (match Analysis.Function_graph.emitted_definition graph identity with
    | None ->
      Blocked
        (diagnostic ctx origin "DecD/rewrite-backed/CallE/unemitted-provenance"
           ("structured source identity for `" ^ identity.def_id
            ^ "` has no emitted definition surface")
           "Materialize the exact specialization before lowering this call")
    | Some definition when not definition.rewrite_backed -> Ordinary
    | Some definition ->
      (match Expr_translate.carrier_sort_of_typ definition.result with
      | Some sort -> Rewrite sort
      | None ->
        Blocked
          (diagnostic ctx origin "DecD/rewrite-backed/CallE/result-carrier"
             ("rewrite-backed CallE identity `" ^ identity.def_id
              ^ "` has no source-preserving result carrier")
             "Add the result carrier before promoting this exact specialization")))

let lower_term ctx origin names term =
  let rec lower names = function
    | Var _ | Const _ | Qid _ as term -> empty term, names
    | App (op_name, args) as source_term ->
      let args, conditions, diagnostics, names =
        List.fold_left (fun (args, conditions, diagnostics, names) arg ->
          let result, names = lower names arg in
          ( result.term :: args
          , List.rev_append result.conditions conditions
          , List.rev_append result.diagnostics diagnostics
          , names ))
          ([], [], [], names) args
      in
      let args = List.rev args in
      let conditions = List.rev conditions in
      let diagnostics = List.rev diagnostics in
      let call = App (op_name, args) in
      match classify_call ctx origin source_term op_name with
      | Ordinary -> { term = call; conditions; diagnostics }, names
      | Blocked diagnostic ->
        { term = call; conditions; diagnostics = diagnostics @ [ diagnostic ] },
        names
      | Rewrite sort ->
        let result, names =
          Local_name.fresh_typed names Local_name.Result sort
        in
        { term = result
        ; conditions = conditions @ [ RewriteCond (call, result) ]
        ; diagnostics
        },
        names
  in
  lower names term

let lower_eq_condition ctx origin names = function
  | EqCond (left, right) ->
    let left, names = lower_term ctx origin names left in
    let right, names = lower_term ctx origin names right in
    ( left.conditions @ right.conditions
      @ [ EqCondition (EqCond (left.term, right.term)) ]
    , left.diagnostics @ right.diagnostics
    , names )
  | MatchCond (pattern, subject) ->
    let subject, names = lower_term ctx origin names subject in
    ( subject.conditions @ [ EqCondition (MatchCond (pattern, subject.term)) ]
    , subject.diagnostics
    , names )
  | MembershipCond (term, sort) ->
    let result, names = lower_term ctx origin names term in
    ( result.conditions @ [ EqCondition (MembershipCond (result.term, sort)) ]
    , result.diagnostics
    , names )
  | BoolCond term ->
    let result, names = lower_term ctx origin names term in
    ( result.conditions @ [ EqCondition (BoolCond result.term) ]
    , result.diagnostics
    , names )

let lower_eq_conditions ctx origin names conditions =
  List.fold_left (fun (lowered, diagnostics, names) condition ->
    let conditions, new_diagnostics, names =
      lower_eq_condition ctx origin names condition
    in
    lowered @ conditions, diagnostics @ new_diagnostics, names)
    ([], [], names) conditions

let lower_rule_condition ctx origin names = function
  | EqCondition condition -> lower_eq_condition ctx origin names condition
  | RewriteCond (left, right) ->
    let left, names = lower_term ctx origin names left in
    ( left.conditions @ [ RewriteCond (left.term, right) ]
    , left.diagnostics
    , names )

let lower_rule_conditions ctx origin names conditions =
  List.fold_left (fun (lowered, diagnostics, names) condition ->
    let conditions, new_diagnostics, names =
      lower_rule_condition ctx origin names condition
    in
    lowered @ conditions, diagnostics @ new_diagnostics, names)
    ([], [], names) conditions
