open Maude_ir

type t =
  { substitution : (string * term) list
  ; projection_guard : eq_condition
  ; membership : rule_condition
  ; statements : generated list
  }

let specialize_term context =
  Head_specialization.substitute_term context.substitution

let specialize_guard context =
  Head_specialization.substitute_condition context.substitution

let specialize_condition context = function
  | EqCondition condition ->
    EqCondition (specialize_guard context condition)
  | RewriteCond (left, right) ->
    RewriteCond
      (specialize_term context left, specialize_term context right)

let specialize_terms context terms =
  List.map (specialize_term context) terms

let specialize_guards context guards =
  List.map (specialize_guard context) guards

let membership context = context.membership
let statements context = context.statements

let same_guard left right =
  match left, right with
  | (EqCond (left1, right1) | MatchCond (left1, right1)),
    (EqCond (left2, right2) | MatchCond (left2, right2)) ->
    left1 = left2 && right1 = right2
  | BoolCond left, BoolCond right -> left = right
  | MembershipCond (left, left_sort), MembershipCond (right, right_sort) ->
    left = right && left_sort = right_sort
  | _ -> false

let is_projection_guard context condition =
  let projection_guard =
    specialize_guard context context.projection_guard
  in
  same_guard condition context.projection_guard
  || same_guard (specialize_guard context condition) projection_guard

let specialize_conditions context conditions =
  (* Direct prefix membership replaces the projection that previously
     reconstructed the source value sequence. *)
  conditions
  |> List.filter (function
       | EqCondition condition -> not (is_projection_guard context condition)
       | RewriteCond _ -> true)
  |> List.map (specialize_condition context)

let source_surface_is_total injection =
  match Subtype_injection.cases injection with
  | [] -> false
  | cases -> List.for_all Subtype_injection.projects_totally cases

let constructor name args =
  match args with
  | [] -> Const name
  | _ -> App (name, args)

let fresh_payloads names case =
  Subtype_injection.payload_sorts case
  |> List.fold_left
       (fun (variables, names) sort ->
         let variable, names =
           Local_name.fresh_qualified
             names Local_name.Component (sort_ref sort)
         in
         variable :: variables, names)
       ([], names)
  |> fun (variables, names) -> List.rev variables, names

(* A source value and its instruction form may use distinct constructors.
   Preserve the source membership directly on the emitted representation. *)
let membership_equations origin names witness injection =
  Subtype_injection.cases injection
  |> List.fold_left
       (fun (statements, names) case ->
         let source_op = Subtype_injection.source_op case in
         let target_op = Subtype_injection.target_op case in
         if source_op = target_op then statements, names
         else
           let payloads, names = fresh_payloads names case in
           let source = constructor source_op payloads in
           let target = constructor target_op payloads in
           let statement =
             generated ~origin
               (ceq
                  (Typecheck_term.typecheck target witness)
                  (Const "true")
                  [ BoolCond (Typecheck_term.typecheck source witness) ])
           in
           statement :: statements, names)
       ([], names)
  |> fun (statements, names) -> List.rev statements, names

let variable_substitution source target =
  match target with
  | Var target_var -> Some [ target_var, source ]
  | Const _ | Qid _ | App _ -> None

let context_roundtrip env certificate =
  match
    Expr_env.find_subtype_roundtrip
      env (Execution_context_certificate.prefix_source certificate)
  with
  | None -> None
  | Some roundtrip -> Pattern_subtyping.sequence_roundtrip roundtrip

let value_witness ctx origin certificate =
  Typd_witness.of_typ
    Type_static_env.empty
    ctx origin
    ~constructor:"RelD/execution/context-prefix"
    (Execution_context_certificate.value_source_typ certificate)
  |> fst

let lower_sequence
    ctx origin names certificate
    (sequence : Pattern_subtyping.sequence_roundtrip) =
  if not (source_surface_is_total sequence.injection) then None
  else
    match
      variable_substitution sequence.source sequence.target,
      value_witness ctx origin certificate
    with
    | Some substitution, Some witness ->
      let statements =
        membership_equations origin names witness sequence.injection |> fst
      in
      let source =
        Head_specialization.substitute_term substitution sequence.target
      in
      let membership =
        EqCondition (BoolCond (Typecheck_term.typecheck_seq source witness))
      in
      Some
        { substitution
        ; projection_guard = sequence.required_guard
        ; membership
        ; statements
        }
    | None, _ | _, None -> None

let lower ctx origin names env certificate =
  match context_roundtrip env certificate with
  | None -> None
  | Some sequence -> lower_sequence ctx origin names certificate sequence
