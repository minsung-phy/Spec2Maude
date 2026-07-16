open Il.Ast
open Maude_ir
open Util.Source

type binding =
  { term : term
  ; sort : sort
  ; typ : typ
  }

type result =
  { term : term option
  ; guards : eq_condition list
  ; introduced_bindings : (string * binding) list
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

let app name args = App (name, args)

let source_echo_exp exp =
  Il.Print.string_of_exp exp

let unsupported ctx origin constructor exp reason suggestion =
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin
    ~constructor
    ~enclosing:(Context.enclosing_path ctx)
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
  let forward = Helper.request (Context.helpers ctx) request in
  Subtype_injection.projection_name ~forward,
  Subtype_injection.sequence_projection_name ~forward

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

let projection_condition
    ctx callbacks origin constructor source_exp source_result source_term
    ~reason ~suggestion =
  if Condition_closure.is_match_pattern
       ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
       source_term then
    Ok (fun projected -> MatchCond (source_term, projected))
  else if
    source_result.introduced_bindings = []
    && Condition_closure.vars_subset
         (Condition_closure.term_vars source_term)
         callbacks.bound_vars
  then
    Ok (fun projected -> EqCond (source_term, projected))
  else
    Error
      (unsupported
         ctx origin constructor source_exp
         reason suggestion)

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
          guards = dedup_guards (inner_result.guards @ source_guards @ target_guards)
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
      let source_guards, source_diagnostics =
        callbacks.guard_for_typ
          origin ~constructor:"Pattern/SubE/source" exp source_term source_typ
      in
      let target_guards, target_diagnostics =
        callbacks.guard_for_typ
          origin ~constructor:"Pattern/SubE" exp target_term target_typ
      in
      (match source_guards, target_guards with
      | Some source_guards, Some target_guards ->
        (match
           projection_condition
             ctx callbacks origin "Pattern/SubE/projection"
             inner inner_result source_term
             ~reason:
               "the inner source term is not an admissible match pattern and depends on variables not already bound"
             ~suggestion:
               "Keep this SubE Unsupported unless projection needs only equality over existing bindings"
         with
        | Ok make_condition ->
          let project, _ = accept_injection ctx origin injection in
          return names
            { term = Some target_term
            ; guards =
                dedup_guards
                  (inner_result.guards @ target_guards
                   @ [ make_condition (app project [ target_term ]) ]
                   @ source_guards)
            ; introduced_bindings = inner_result.introduced_bindings
            ; diagnostics =
                inner_result.diagnostics @ source_diagnostics @ target_diagnostics
            }
        | Error diagnostic ->
          return names
            { inner_result with
              term = None
            ; diagnostics =
                inner_result.diagnostics @ source_diagnostics @ target_diagnostics
                @ [ diagnostic ]
            })
      | _ ->
        return names
          { inner_result with
            term = None
          ; diagnostics =
              inner_result.diagnostics @ source_diagnostics @ target_diagnostics
          }))

let sequence_typ typ =
  { typ with it = IterT (typ, List) }

let lower_iterated
    names ctx callbacks origin exp ~source_exp ~source_result ~source_term
    ~source_typ ~target_typ =
  match subtype_plan ctx source_typ target_typ with
  | Ok Subtype_plan.Identity ->
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
        guards =
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
    let source_guards, source_diagnostics =
      callbacks.guard_for_typ
        origin ~constructor:"Pattern/IterE/coercion"
        source_exp source_term (sequence_typ source_typ)
    in
    let target_guards, target_diagnostics =
      callbacks.guard_for_typ
        origin ~constructor:"Pattern/IterE/SubE/target" exp target_term exp.note
    in
    (match source_guards, target_guards with
    | Some source_guards, Some target_guards ->
      (match
         projection_condition
           ctx callbacks origin "Pattern/IterE/SubE/projection"
           source_exp source_result source_term
           ~reason:
             "the projected source sequence is not an admissible match pattern and depends on variables not already bound"
           ~suggestion:
             "Keep this iterated SubE Unsupported unless projection needs only equality over existing bindings"
       with
      | Ok make_condition ->
        let _, project_seq = accept_injection ctx origin injection in
        return names { term = Some target_term
        ; guards =
            dedup_guards
              (source_result.guards @ target_guards
               @ [ make_condition (app project_seq [ target_term ]) ]
               @ source_guards)
        ; introduced_bindings = source_result.introduced_bindings
        ; diagnostics =
            source_result.diagnostics @ source_diagnostics @ target_diagnostics
        }
      | Error diagnostic ->
        return names { source_result with
          term = None
        ; diagnostics =
            source_result.diagnostics @ source_diagnostics @ target_diagnostics
            @ [ diagnostic ]
        })
    | _ ->
      return names { source_result with
        term = None
      ; diagnostics =
          source_result.diagnostics @ source_diagnostics @ target_diagnostics
      })
  | Error error ->
    return names { source_result with
      term = None
    ; diagnostics =
        source_result.diagnostics
        @ [ subtype_diagnostic
              ctx origin "Pattern/IterE/SubE/injection" exp error ]
    }
