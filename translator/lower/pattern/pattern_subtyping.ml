open Il.Ast
open Maude_ir
open Util.Source

type binding =
  { term : term
  ; sort : sort
  ; typ : typ
  }

type roundtrip_form =
  | Direct
  | Pointwise_sequence of iter

type subtype_roundtrip =
  { source : term
  ; target : term
  ; injection : Subtype_injection.t
  ; guard : eq_condition
  ; form : roundtrip_form
  }

type sequence_roundtrip =
  { source : term
  ; target : term
  ; injection : Subtype_injection.t
  ; required_guard : eq_condition
  }

let sequence_roundtrip roundtrip =
  match roundtrip.form with
  | Pointwise_sequence List ->
    Some
      { source = roundtrip.source
      ; target = roundtrip.target
      ; injection = roundtrip.injection
      ; required_guard = roundtrip.guard
      }
  | Direct | Pointwise_sequence (Opt | List1 | ListN _) -> None

type roundtrip_reuse =
  { target : term
  ; required_guard : eq_condition
  }

type introduced_binding =
  { id : string
  ; binding : binding
  ; subtype_roundtrip : subtype_roundtrip option
  }

type result =
  { term : term option
  ; guards : eq_condition list
  ; introduced_bindings : introduced_binding list
  ; diagnostics : Diagnostics.t list
  }

type callbacks =
  { bound_vars : string list
  ; lower_pattern : Local_name.t -> Origin.t -> exp -> result * Local_name.t
  ; carrier_sort_of_typ : typ -> sort option
  ; guard_for_typ :
      Origin.t ->
      constructor:string ->
      exp ->
      term ->
      typ ->
      eq_condition list option * Diagnostics.t list
  }

let return names result = result, names

let introduce id binding =
  { id; binding; subtype_roundtrip = None }

let app name args = App (name, args)

let source_echo_exp exp =
  Il.Print.string_of_exp exp

let unsupported ctx origin constructor exp reason suggestion =
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin
    ~constructor
    ~enclosing:
      (Diagnostic_provenance.enclosing ~context:(Context.enclosing_path ctx) origin)
    ~profile:(Context.profile_name ctx)
    ~source_echo:(source_echo_exp exp)
    ~reason
    ~suggestion
    ()

let subtype_plan ctx source_typ target_typ =
  Subtype_plan.make
    ~il_env:(Context.il_env ctx)
    ~source_index:(Context.source_index ctx)
    ~constructors:(Context.constructors ctx)
    ~static_typ_env:(Context.static_typ_env ctx)
    source_typ target_typ

let subtype_diagnostic ctx origin constructor exp error =
  let reason, suggestion = Subtype_plan.describe_error error in
  unsupported ctx origin constructor exp reason suggestion

let accept_injection ctx origin injection =
  let request = Helper_request.subtype_injection_request ~origin injection in
  Helper.request (Context.helpers ctx) request

let child_origin parent segment exp =
  Origin.with_child
    ~source_echo:(source_echo_exp exp)
    parent
    segment
    ~ast_constructor:"Pattern"
    exp.at

let dedup_guards guards =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | guard :: rest when List.mem guard seen -> loop seen acc rest
    | guard :: rest -> loop (guard :: seen) (guard :: acc) rest
  in
  loop [] [] guards

let rec replace_term source target term =
  if term = source then target
  else match term with
       | App (op, args) -> App (op, List.map (replace_term source target) args)
       | Var _ | Const _ | Qid _ -> term

let replace_condition source target = function
  | EqCond (left, right) ->
    EqCond (replace_term source target left, replace_term source target right)
  | MatchCond (left, right) ->
    MatchCond (replace_term source target left, replace_term source target right)
  | MembershipCond (term, sort) ->
    MembershipCond (replace_term source target term, sort)
  | BoolCond term -> BoolCond (replace_term source target term)

let identity_subject names source_exp source_result source_term sort =
  match source_exp.it, source_term with
  | VarE id, Var _
    when List.exists
           (fun introduced -> introduced.id = id.it)
           source_result.introduced_bindings ->
    let target, names = Local_name.fresh_typed names Local_name.Pattern sort in
    let introduced_bindings =
      source_result.introduced_bindings
      |> List.map (fun introduced ->
        if introduced.id = id.it && introduced.binding.term = source_term then
          { introduced with
            binding = { introduced.binding with term = target }
          }
        else introduced)
    in
    target,
    { source_result with
      guards = List.map (replace_condition source_term target) source_result.guards
    ; introduced_bindings
    },
    names
  | _ -> source_term, source_result, names

let identity_sequence_subject names source_exp source_result source_term =
  match source_exp.it, source_term with
  | VarE id, Var _ when id.it <> "_" ->
    let sort = sort "SpectecTerminals" in
    let target, names = Local_name.fresh_typed names Local_name.Pattern sort in
    let introduced = introduce id.it { term = target; sort; typ = source_exp.note } in
    let introduced_bindings =
      introduced
      :: List.filter
           (fun previous -> previous.id <> id.it)
           source_result.introduced_bindings
    in
    target,
    { source_result with
      guards = List.map (replace_condition source_term target) source_result.guards
    ; introduced_bindings
    },
    names
  | _ -> source_term, source_result, names

(** A projection is partial exactly outside the certified injection image.
    A successful match therefore proves both source and target categories. *)
let without_typechecks guards =
  guards
  |> List.filter (function
       | BoolCond term -> not (Typecheck_term.is_typecheck term)
       | EqCond _ | MatchCond _ | MembershipCond _ -> true)

type projection_condition =
  | Projection_match
  | Projection_equality

let projection_condition
    ctx callbacks origin constructor source_exp source_result source_term
    ~reason ~suggestion =
  if Condition_closure.is_match_pattern
       ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
       source_term then
    Ok Projection_match
  else if
    source_result.introduced_bindings = []
    && Condition_closure.vars_subset
         (Condition_closure.term_vars source_term)
         callbacks.bound_vars
  then
    Ok Projection_equality
  else
    Error
      (unsupported
         ctx origin constructor source_exp
         reason suggestion)

let make_projection_condition kind source projected =
  match kind with
  | Projection_match -> MatchCond (source, projected)
  | Projection_equality -> EqCond (source, projected)

let projection_guard project source target =
  MatchCond (source, App (project, [ target ]))

(** These constructors remain private to pattern lowering.  Each proof is made
    only alongside the exact generated partial-projection guard that establishes
    its image domain. *)
let direct_roundtrip ~forward ~source ~target injection =
  { source
  ; target
  ; injection
  ; guard =
      projection_guard
        (Subtype_injection.projection_name ~forward)
        source target
  ; form = Direct
  }

(** Pointwise sequence projection is a partial retraction and preserves length
    on its exact domain.  The stored iterator retains any [ListN] count/index
    obligation checked by the reuse query. *)
let iterated_roundtrip ~forward ~iter ~source ~target injection =
  { source
  ; target
  ; injection
  ; guard =
      projection_guard
        (Subtype_injection.sequence_projection_name ~forward)
        source target
  ; form = Pointwise_sequence iter
  }

let same_injection left right =
  Subtype_injection.key left = Subtype_injection.key right

let reuse (roundtrip : subtype_roundtrip) =
  { target = roundtrip.target; required_guard = roundtrip.guard }

let reuse_direct roundtrip ~source injection =
  match roundtrip.form with
  | Direct
    when source = roundtrip.source
         && same_injection injection roundtrip.injection ->
    Some (reuse roundtrip)
  | Direct | Pointwise_sequence _ -> None

let reuse_iterated roundtrip ~source ~iter injection =
  match roundtrip.form with
  | Pointwise_sequence certified_iter
    when source = roundtrip.source
         && Il.Eq.eq_iter iter certified_iter
         && same_injection injection roundtrip.injection ->
    Some (reuse roundtrip)
  | Direct | Pointwise_sequence _ -> None

let attach_roundtrip source_result source_exp (roundtrip : subtype_roundtrip) =
  match source_exp.it with
  | VarE id ->
    let matching =
      source_result.introduced_bindings
      |> List.filter (fun introduced -> introduced.id = id.it)
    in
    (match matching with
    | [ introduced ] when introduced.binding.term = roundtrip.source ->
      source_result.introduced_bindings
      |> List.map (fun introduced ->
        if introduced.id = id.it then
          { introduced with subtype_roundtrip = Some roundtrip }
        else introduced)
    | [] | [ _ ] | _ :: _ :: _ -> source_result.introduced_bindings)
  | _ -> source_result.introduced_bindings

(** A bare source variable is introduced by the projection [MatchCond] even
    when its RuleD quantifier already supplied a typed declaration.  Construct
    that introduction from the exact pattern term and note; never copy an
    arbitrary callback binding into the result. *)
let projection_introductions
    callbacks source_result source_exp source_term source_sort =
  match source_exp.it with
  | VarE id
    when not
      (List.exists
         (fun introduced -> introduced.id = id.it)
         source_result.introduced_bindings)
      && not
        (Condition_closure.vars_subset
           (Condition_closure.term_vars source_term)
           callbacks.bound_vars) ->
    (match source_sort with
    | Some sort ->
      introduce id.it
        { term = source_term; sort; typ = source_exp.note }
      :: source_result.introduced_bindings
    | None -> source_result.introduced_bindings)
  | _ -> source_result.introduced_bindings

let lower_direct names ctx callbacks origin exp inner source_typ target_typ =
  let inner_result, names =
    callbacks.lower_pattern names (child_origin origin "sub-inner" inner) inner
  in
  match inner_result.term, subtype_plan ctx source_typ target_typ with
  | None, _ ->
    return names
      { inner_result with
        diagnostics =
          inner_result.diagnostics
          @ [ unsupported
                ctx origin "Pattern/SubE" exp
                "SubE pattern could not lower its inner source pattern"
                "Extend inner pattern lowering before preserving this coercion guard"
            ]
      }
  | Some _, Error error ->
    return names
      { inner_result with
        term = None
      ; diagnostics =
          inner_result.diagnostics
          @ [ subtype_diagnostic ctx origin "Pattern/SubE/injection" exp error ]
      }
  | Some source_term, Ok Subtype_plan.Identity ->
    let source_term, inner_result, names =
      match callbacks.carrier_sort_of_typ target_typ with
      | Some sort -> identity_subject names inner inner_result source_term sort
      | None -> source_term, inner_result, names
    in
    let source_guards, source_diagnostics =
      callbacks.guard_for_typ
        origin ~constructor:"Pattern/SubE/source" exp source_term source_typ
    in
    let target_guards, target_diagnostics =
      callbacks.guard_for_typ
        origin ~constructor:"Pattern/SubE" exp source_term target_typ
    in
    (match source_guards, target_guards with
    | Some source_guards, Some target_guards ->
      return names
        { inner_result with
          term = Some source_term
        ; guards = dedup_guards (inner_result.guards @ source_guards @ target_guards)
        ; diagnostics =
            inner_result.diagnostics @ source_diagnostics @ target_diagnostics
        }
    | _ ->
      return names
        { inner_result with
          term = None
        ; diagnostics =
            inner_result.diagnostics @ source_diagnostics @ target_diagnostics
        })
  | Some source_term, Ok (Subtype_plan.Injection injection) ->
    (match callbacks.carrier_sort_of_typ target_typ with
    | None ->
      return names
        { term = None
        ; guards = []
        ; introduced_bindings = []
        ; diagnostics =
            [ unsupported
                ctx origin "Pattern/SubE" exp
                "injective SubE pattern has no known target carrier for its outer pattern"
                "Keep this pattern as Unsupported until a source-preserving pattern lowering rule is implemented"
            ]
        }
    | Some target_sort ->
      let target_term, names =
        Local_name.fresh_typed names Local_name.Pattern target_sort
      in
      (match
         projection_condition
           ctx callbacks origin "Pattern/SubE/projection"
           inner inner_result source_term
           ~reason:
             "the inner source term is not an admissible match pattern and depends on variables not already bound"
           ~suggestion:
             "Keep this SubE Unsupported unless projection needs only equality over existing bindings"
       with
      | Ok condition_kind ->
        let forward = accept_injection ctx origin injection in
        let projected =
          app (Subtype_injection.projection_name ~forward) [ target_term ]
        in
        let guard, introduced_bindings =
          match condition_kind with
          | Projection_match ->
            let inner_result =
              { inner_result with
                introduced_bindings =
                  projection_introductions
                    callbacks inner_result inner source_term
                    (callbacks.carrier_sort_of_typ inner.note)
              }
            in
            let roundtrip =
              direct_roundtrip
                ~forward ~source:source_term ~target:target_term injection
            in
            roundtrip.guard,
            attach_roundtrip inner_result inner roundtrip
          | Projection_equality ->
            make_projection_condition
              condition_kind source_term projected,
            inner_result.introduced_bindings
        in
        return names
          { term = Some target_term
          ; guards =
              dedup_guards
                (without_typechecks inner_result.guards
                 @ [ guard ])
          ; introduced_bindings
          ; diagnostics = inner_result.diagnostics
          }
      | Error diagnostic ->
        return names
          { inner_result with
            term = None
          ; diagnostics = inner_result.diagnostics @ [ diagnostic ]
          }))

let sequence_typ typ =
  { typ with it = IterT (typ, List) }

let lower_iterated
    names ctx callbacks origin exp ~source_exp ~source_result ~source_term
    ~source_typ ~target_typ ~iter =
  match subtype_plan ctx source_typ target_typ with
  | Ok Subtype_plan.Identity ->
    let source_term, source_result, names =
      identity_sequence_subject names source_exp source_result source_term
    in
    let source_guards, source_diagnostics =
      callbacks.guard_for_typ
        origin ~constructor:"Pattern/IterE/coercion"
        exp source_term (sequence_typ source_typ)
    in
    let target_guards, target_diagnostics =
      callbacks.guard_for_typ
        origin ~constructor:"Pattern/IterE/coercion"
        exp source_term (sequence_typ target_typ)
    in
    (match source_guards, target_guards with
    | Some source_guards, Some target_guards ->
      return names { source_result with
        term = Some source_term
      ; guards =
          dedup_guards
            (source_result.guards @ source_guards @ target_guards)
      ; diagnostics =
          source_result.diagnostics @ source_diagnostics @ target_diagnostics
      }
    | _ ->
      return names { source_result with
        term = None
      ; diagnostics =
          source_result.diagnostics @ source_diagnostics @ target_diagnostics
      })
  | Ok (Subtype_plan.Injection injection) ->
    let target_term, names =
      Local_name.fresh_typed names Local_name.Pattern (sort "SpectecTerminals")
    in
    (match
       projection_condition
         ctx callbacks origin "Pattern/IterE/SubE/projection"
         source_exp source_result source_term
         ~reason:
           "the projected source sequence is not an admissible match pattern and depends on variables not already bound"
         ~suggestion:
           "Keep this iterated SubE Unsupported unless projection needs only equality over existing bindings"
     with
    | Ok condition_kind ->
      let forward = accept_injection ctx origin injection in
      let projected =
        app
          (Subtype_injection.sequence_projection_name ~forward)
          [ target_term ]
      in
      let guard, introduced_bindings =
        match condition_kind with
        | Projection_match ->
          let source_result =
            { source_result with
              introduced_bindings =
                projection_introductions
                  callbacks source_result source_exp source_term
                  (Some (sort "SpectecTerminals"))
            }
          in
          let roundtrip =
            iterated_roundtrip
              ~forward ~iter ~source:source_term ~target:target_term injection
          in
          roundtrip.guard,
          attach_roundtrip source_result source_exp roundtrip
        | Projection_equality ->
          make_projection_condition condition_kind source_term projected,
          source_result.introduced_bindings
      in
      return names { term = Some target_term
      ; guards =
          dedup_guards
            (without_typechecks source_result.guards
             @ [ guard ])
      ; introduced_bindings
      ; diagnostics = source_result.diagnostics
      }
    | Error diagnostic ->
      return names { source_result with
        term = None
      ; diagnostics = source_result.diagnostics @ [ diagnostic ]
      })
  | Error error ->
    return names { source_result with
      term = None
    ; diagnostics =
        source_result.diagnostics
        @ [ subtype_diagnostic
              ctx origin "Pattern/IterE/SubE/injection" exp error ]
    }
