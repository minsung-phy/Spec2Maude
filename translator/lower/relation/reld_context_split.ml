open Maude_ir

(* Lower a structurally certified associative execution context to a private
   splitter.  The helper enumerates exactly the source-valid decompositions;
   it does not add successors to the source Step relation. *)

type guard_proof =
  { proved_guards : eq_condition list
  ; witness_vars : string list
  }

type t =
  { lhs_terms : term list
  ; condition : rule_condition
  ; guard_proof : guard_proof option
  ; statements : generated list
  }

let lhs_terms split = split.lhs_terms
let condition split = split.condition
let statements split = split.statements

let condition_vars = function
  | EqCond (left, right) | MatchCond (left, right) ->
    Head_specialization.term_vars left @ Head_specialization.term_vars right
  | BoolCond term | MembershipCond (term, _) ->
    Head_specialization.term_vars term

let rule_condition_vars = function
  | EqCondition condition -> condition_vars condition
  | RewriteCond (left, right) ->
    Head_specialization.term_vars left @ Head_specialization.term_vars right

let eliminate_witness_guards split ~lhs ~rhs conditions =
  match split.guard_proof with
  | None -> conditions
  | Some proof ->
    let retained =
      conditions
      |> List.filter (function
           | EqCondition condition ->
             not (List.mem condition proof.proved_guards)
           | RewriteCond _ -> true)
    in
    let live_vars =
      Head_specialization.term_vars lhs
      @ Head_specialization.term_vars rhs
      @ List.concat_map rule_condition_vars retained
      |> List.sort_uniq String.compare
    in
    if List.exists (fun var -> List.mem var live_vars) proof.witness_vars then
      conditions
    else
      retained

let app name args = App (name, args)
let seq_sort = sort "SpectecTerminals"
let terminal_sort = sort "SpectecTerminal"
let nat_sort = sort "Nat"
let bool_sort = sort "Bool"

let helper_name origin =
  Naming.helper_op
    ~role:"context-split"
    ~owner:(Naming.helper_owner origin)

let companion role name = Naming.helper_companion ~role name

let helper_sort stem owner =
  sort (stem ^ Naming.sort_token owner)

let generated_helper name origin node =
  generated ~provenance:(Helper name) ~origin node

let frozen count =
  [ Frozen (List.init count (fun index -> index + 1)) ]

let fresh names role sort =
  Local_name.fresh_qualified names role (sort_ref sort)

let constructor name args =
  match args with
  | [] -> Const name
  | _ -> App (name, args)

let sequence_parts term =
  let rec collect acc = function
    | App ("_ _", [ left; right ]) -> collect (collect acc right) left
    | term -> term :: acc
  in
  collect [] term

let replace_context prefix focus suffix whole term =
  match term with
  | App (name, [ state; instrs ])
    when sequence_parts instrs = [ prefix; focus; suffix ] ->
    Some (App (name, [ state; whole ]))
  | Var _ | Const _ | Qid _ | App _ -> None

let replace_unique prefix focus suffix whole terms =
  let rec loop changed acc = function
    | [] when changed -> Some (List.rev acc)
    | [] -> None
    | term :: rest ->
      (match replace_context prefix focus suffix whole term with
      | Some _ when changed -> None
      | Some term -> loop true (term :: acc) rest
      | None -> loop changed (term :: acc) rest)
  in
  loop false [] terms

let fresh_value_pattern names case =
  let variables, names =
    Subtype_injection.payload_sorts case
    |> List.fold_left
         (fun (variables, names) sort ->
           let variable, names =
             fresh names Local_name.Component sort
           in
           variable :: variables, names)
         ([], names)
  in
  constructor
    (Subtype_injection.target_op case)
    (List.rev variables),
  names

let source_surface_is_total injection =
  match Subtype_injection.cases injection with
  | [] -> false
  | cases -> List.for_all Subtype_injection.projects_totally cases

let strict_progress source suffix =
  BoolCond
    (app "_or_"
       [ app "_=/=_" [ source; Const "eps" ]
       ; app "_=/=_" [ suffix; Const "eps" ]
       ])

let materialize ~all_values_irreducible ~strict_progress origin injection =
  let owner = Naming.helper_owner origin in
  let name = helper_name origin in
  let maybe_sort = helper_sort "ContextMaybeFocus" owner in
  let split_sort = helper_sort "ContextSplit" owner in
  let stack_sort = helper_sort "ContextStack" owner in
  let result = companion "context-split-result" name in
  let stop = companion "context-stop" name in
  let is_value = companion "context-is-value" name in
  let has_compact = companion "context-has-compact" name in
  let dispatch = companion "context-dispatch" name in
  let no_focus = companion "context-no-focus" name in
  let at_focus = companion "context-at-focus" name in
  let first_non_value = companion "context-first-non-value" name in
  let first_defined = companion "context-first-defined" name in
  let first_value = companion "context-first-value" name in
  let empty_stack = companion "context-stack-empty" name in
  let stack_item = companion "context-stack-item" name in
  let scan = companion "context-scan" name in
  let scan_value = companion "context-scan-value" name in
  let scan_non_value = companion "context-scan-non-value" name in
  let scan_index = companion "context-scan-index" name in
  let scan_index_values = companion "context-scan-index-values" name in
  let statement node = generated_helper name origin node in
  let stream, names =
    fresh Local_name.empty Local_name.Stream seq_sort
  in
  let remaining, names =
    fresh names Local_name.Stream seq_sort
  in
  let prefix, names =
    fresh names Local_name.Stream seq_sort
  in
  let suffix, names =
    fresh names Local_name.Stream seq_sort
  in
  let base_prefix, names =
    fresh names Local_name.Stream seq_sort
  in
  let base_focus, names =
    fresh names Local_name.Stream seq_sort
  in
  let current_prefix, names =
    fresh names Local_name.Stream seq_sort
  in
  let current_focus, names =
    fresh names Local_name.Stream seq_sort
  in
  let previous_prefix, names =
    fresh names Local_name.Stream seq_sort
  in
  let value, names =
    fresh names Local_name.Value terminal_sort
  in
  let count, names =
    fresh names Local_name.Count nat_sort
  in
  let prefix_index, names =
    fresh names Local_name.Count nat_sort
  in
  let end_index, names =
    fresh names Local_name.Count nat_sort
  in
  let limit, names =
    fresh names Local_name.Count nat_sort
  in
  let stack, names =
    fresh names Local_name.History stack_sort
  in
  let base_stack, names =
    fresh names Local_name.History stack_sort
  in
  let current_stack, names =
    fresh names Local_name.History stack_sort
  in
  let rest_stack, names =
    fresh names Local_name.History stack_sort
  in
  let value_patterns, _names =
    Subtype_injection.cases injection
    |> List.fold_left
         (fun (patterns, names) case ->
           let pattern, names = fresh_value_pattern names case in
           pattern :: patterns, names)
         ([], names)
    |> fun (patterns, names) -> List.rev patterns, names
  in
  let seq left right = app "_ _" [ left; right ] in
  let succ term = app "s_" [ term ] in
  let chunk carrier count value = app carrier [ count; value ] in
  let nonempty term = BoolCond (app "_=/=_" [ term; Const "eps" ]) in
  let split_call = app name [ stream ] in
  let scan_term remaining prefix stack =
    app scan [ remaining; prefix; stack ]
  in
  let stack_item_term value prefix stack =
    app stack_item [ value; prefix; stack ]
  in
  let non_value_state
      base_stack base_prefix base_focus suffix
      current_stack current_prefix current_focus =
    app scan_non_value
      [ base_stack; base_prefix; base_focus; suffix
      ; current_stack; current_prefix; current_focus
      ]
  in
  let index_state limit prefix_index end_index =
    app scan_index [ stream; limit; count; prefix_index; end_index ]
  in
  let index_value_state limit prefix_index end_index =
    app scan_index_values [ stream; limit; prefix_index; end_index ]
  in
  let index_result prefix_index end_index =
    app result
      [ app "takeRun" [ prefix_index; stream ]
      ; app "slice"
          [ stream; prefix_index; app "_-_" [ end_index; prefix_index ] ]
      ; app "drop" [ end_index; stream ]
      ]
  in
  let declarations =
    [ statement (sort_decl maybe_sort)
    ; statement (sort_decl split_sort)
    ; statement (sort_decl stack_sort)
    ; statement
        (op result
           [ sort_ref seq_sort; sort_ref seq_sort; sort_ref seq_sort ]
           split_sort ~attrs:[ Ctor ])
    ; statement (op stop [] split_sort ~attrs:[ Ctor ])
    ; statement (op is_value [ sort_ref terminal_sort ] bool_sort)
    ; statement (op has_compact [ sort_ref seq_sort ] bool_sort)
    ; statement (op no_focus [] maybe_sort ~attrs:[ Ctor ])
    ; statement (op at_focus [ sort_ref nat_sort ] maybe_sort ~attrs:[ Ctor ])
    ; statement
        (op first_non_value
           [ sort_ref seq_sort; sort_ref nat_sort; sort_ref nat_sort ]
           maybe_sort)
    ; statement
        (op first_defined
           [ sort_ref seq_sort; sort_ref nat_sort; sort_ref nat_sort
           ; sort_ref bool_sort
           ]
           maybe_sort ~attrs:(frozen 4))
    ; statement
        (op first_value
           [ sort_ref seq_sort; sort_ref nat_sort; sort_ref nat_sort
           ; sort_ref bool_sort
           ]
           maybe_sort ~attrs:(frozen 4))
    ; statement
        (op empty_stack [] stack_sort ~attrs:[ Ctor ])
    ; statement
        (op stack_item
           [ sort_ref terminal_sort; sort_ref seq_sort; sort_ref stack_sort ]
           stack_sort ~attrs:[ Ctor ])
    ; statement
        (op scan
           [ sort_ref seq_sort; sort_ref seq_sort; sort_ref stack_sort ]
           split_sort ~attrs:(frozen 3))
    ; statement
        (op scan_value
           [ sort_ref terminal_sort; sort_ref seq_sort; sort_ref seq_sort
           ; sort_ref stack_sort; sort_ref bool_sort
           ]
           split_sort ~attrs:(frozen 5))
    ; statement
        (op scan_non_value
           [ sort_ref stack_sort; sort_ref seq_sort; sort_ref seq_sort
           ; sort_ref seq_sort; sort_ref stack_sort; sort_ref seq_sort
           ; sort_ref seq_sort
           ]
           split_sort ~attrs:(frozen 7))
    ; statement
        (op scan_index
           [ sort_ref seq_sort; sort_ref nat_sort; sort_ref nat_sort
           ; sort_ref nat_sort
           ; sort_ref nat_sort
           ]
           split_sort ~attrs:(frozen 5))
    ; statement
        (op name [ sort_ref seq_sort ] split_sort ~attrs:(frozen 1))
    ]
    @ if all_values_irreducible then
        [ statement
            (op dispatch
               [ sort_ref seq_sort; sort_ref bool_sort ]
               split_sort ~attrs:(frozen 2))
        ]
      else
        [ statement
            (op scan_index_values
               [ sort_ref seq_sort; sort_ref nat_sort; sort_ref nat_sort
               ; sort_ref nat_sort
               ]
               split_sort ~attrs:(frozen 4))
        ]
  in
  let value_equations =
    List.map
      (fun pattern -> statement (eq (app is_value [ pattern ]) (Const "true")))
      value_patterns
    @ [ statement
          (eq ~attrs:[ Owise ] (app is_value [ value ]) (Const "false"))
      ]
  in
  let compact_equations =
    let carrier carrier = chunk carrier count value in
    [ statement (eq (app has_compact [ Const "eps" ]) (Const "false"))
    ; statement
        (eq (app has_compact [ carrier "repeatSeq" ]) (Const "true"))
    ; statement
        (ceq
           (app has_compact [ seq (carrier "repeatSeq") remaining ])
           (Const "true")
           [ nonempty remaining ])
    ; statement
        (eq (app has_compact [ carrier "runSeq" ]) (Const "true"))
    ; statement
        (ceq
           (app has_compact [ seq (carrier "runSeq") remaining ])
           (Const "true")
           [ nonempty remaining ])
    ; statement (eq (app has_compact [ value ]) (Const "false"))
    ; statement
        (ceq
           (app has_compact [ seq value remaining ])
           (app has_compact [ remaining ])
           [ nonempty remaining ])
    ]
    @ if all_values_irreducible then
        [ statement
            (eq split_call
               (app dispatch [ stream; app has_compact [ stream ] ]))
        ]
      else []
  in
  let scan_equations =
    [ statement
        (eq
           (scan_term (Const "eps") prefix stack)
           (Const stop))
    ; statement
        (eq
           (scan_term value prefix stack)
           (app scan_value
              [ value; Const "eps"; prefix; stack
              ; app is_value [ value ]
              ]))
    ; statement
        (ceq
           (scan_term (seq value remaining) prefix stack)
           (app scan_value
              [ value; remaining; prefix; stack
              ; app is_value [ value ]
              ])
           [ nonempty remaining ])
    ; statement
        (eq
           (app scan_value
              [ value; remaining; prefix; stack; Const "true" ])
           (scan_term
              remaining
              (seq prefix value)
              (stack_item_term value prefix stack)))
    ; statement
        (eq
           (app scan_value
              [ value; remaining; prefix; stack; Const "false" ])
           (non_value_state
              stack prefix value remaining stack prefix value))
    ]
  in
  let index_equations =
    [ statement
        (eq
           (app first_non_value [ stream; limit; count ])
           (app first_defined
              [ stream; limit; count
              ; app "_<_" [ count; limit ]
              ]))
    ; statement
        (eq
           (app first_defined [ stream; limit; count; Const "false" ])
           (Const no_focus))
    ; statement
        (eq
           (app first_defined [ stream; limit; count; Const "true" ])
           (app first_value
              [ stream; limit; count
              ; app is_value [ app "index" [ stream; count ] ]
              ]))
    ; statement
        (eq
           (app first_value [ stream; limit; count; Const "true" ])
           (app first_non_value [ stream; limit; succ count ]))
    ; statement
        (eq
           (app first_value [ stream; limit; count; Const "false" ])
           (app at_focus [ count ]))
    ]
  in
  let start_rules =
    (if all_values_irreducible then
       [ statement
           (rl
              ~label:(sanitize_label (name ^ "-cursor-start"))
              (app dispatch [ stream; Const "false" ])
              (scan_term stream (Const "eps") (Const empty_stack)))
       ]
     else [])
    @ [ statement
        (crl
           ~label:(sanitize_label (name ^ "-index-start"))
           (if all_values_irreducible then
              app dispatch [ stream; Const "true" ]
            else split_call)
           (index_state limit count (succ count))
           [ EqCondition
               (MatchCond (limit, app "len" [ stream ]))
           ; EqCondition
               (MatchCond
                  (app at_focus [ count ],
                   app first_non_value [ stream; limit; Const "0" ]))
           ])
    ]
  in
  let cursor_result_rules =
    if strict_progress then
      [ statement
          (rl
             ~label:(sanitize_label (name ^ "-non-value-result-prefix"))
             (non_value_state
                base_stack base_prefix base_focus suffix
                (stack_item_term value previous_prefix rest_stack)
                current_prefix current_focus)
             (app result [ current_prefix; current_focus; suffix ]))
      ; statement
          (crl
             ~label:(sanitize_label (name ^ "-non-value-result-suffix"))
             (non_value_state
                base_stack base_prefix base_focus suffix
                (Const empty_stack) current_prefix current_focus)
             (app result [ current_prefix; current_focus; suffix ])
             [ EqCondition (nonempty suffix) ])
      ]
    else
      [ statement
          (rl
             ~label:(sanitize_label (name ^ "-non-value-result"))
             (non_value_state
                base_stack base_prefix base_focus suffix
                current_stack current_prefix current_focus)
             (app result [ current_prefix; current_focus; suffix ]))
      ]
  in
  let index_result_rules role state limit =
    if strict_progress then
      [ statement
          (rl
             ~label:(sanitize_label (name ^ "-" ^ role ^ "-result-prefix"))
             (state (succ prefix_index) end_index)
             (index_result (succ prefix_index) end_index))
      ; statement
          (crl
             ~label:(sanitize_label (name ^ "-" ^ role ^ "-result-suffix"))
             (state (Const "0") end_index)
             (index_result (Const "0") end_index)
             [ EqCondition
                 (BoolCond (app "_<_" [ end_index; limit ])) ])
      ]
    else
      [ statement
          (rl
             ~label:(sanitize_label (name ^ "-" ^ role ^ "-result"))
             (state prefix_index end_index)
             (index_result prefix_index end_index))
      ]
  in
  (* The scan builds a persistent stack of prefix snapshots.  If [k] is the
     first non-value, popping that stack moves the left boundary from [k] to
     [0]; shifting the suffix moves the right boundary from [k + 1] to [n].
     Hence each state denotes exactly one pair

       0 <= prefix <= k < end <= len(stream),

     and every pair is visited once.  The right boundary increases from
     [k + 1] to [n]; for each right boundary, the left boundary decreases
     from [k] to [0].  This is exactly the order of the index definition.
     The cursor is private to the helper condition; no cursor state is
     exposed as a source [Step] successor. *)
  let non_value_rules =
    cursor_result_rules
    @ [ statement
        (rl
           ~label:(sanitize_label (name ^ "-non-value-pop"))
           (non_value_state
              base_stack base_prefix base_focus suffix
              (stack_item_term value previous_prefix rest_stack)
              current_prefix current_focus)
           (non_value_state
              base_stack base_prefix base_focus suffix
              rest_stack previous_prefix (seq value current_focus)))
    ; statement
        (rl
           ~label:(sanitize_label (name ^ "-non-value-extend-one"))
           (non_value_state
              base_stack base_prefix base_focus value
              (Const empty_stack) (Const "eps") current_focus)
           (non_value_state
              base_stack base_prefix (seq base_focus value) (Const "eps")
              base_stack base_prefix (seq base_focus value)))
    ; statement
        (crl
           ~label:(sanitize_label (name ^ "-non-value-extend"))
           (non_value_state
              base_stack base_prefix base_focus (seq value remaining)
              (Const empty_stack) (Const "eps") current_focus)
           (non_value_state
              base_stack base_prefix (seq base_focus value) remaining
              base_stack base_prefix (seq base_focus value))
           [ EqCondition (nonempty remaining) ])
    ]
    @ index_result_rules "index" (index_state limit) limit
    @ [ statement
        (rl
           ~label:(sanitize_label (name ^ "-index-prefix"))
           (index_state limit (succ prefix_index) end_index)
           (index_state limit prefix_index end_index))
    ; statement
        (crl
           ~label:(sanitize_label (name ^ "-index-end"))
           (index_state limit (Const "0") end_index)
           (index_state limit count (succ end_index))
           [ EqCondition
               (BoolCond (app "_<_" [ end_index; limit ]))
           ])
    ]
  in
  let value_rules =
    if all_values_irreducible then []
    else
      [ statement
          (crl
             ~label:(sanitize_label (name ^ "-index-all-values-start"))
             split_call
             (index_value_state
                limit limit limit)
             [ EqCondition
                 (MatchCond (limit, app "len" [ stream ]))
             ; EqCondition
                 (MatchCond
                    (Const no_focus,
                     app first_non_value [ stream; limit; Const "0" ])) ])
      ; statement
          (crl
             ~label:(sanitize_label (name ^ "-index-value-fallback"))
             (index_state limit (Const "0") end_index)
             (index_value_state limit limit limit)
             [ EqCondition
                 (EqCond (end_index, limit)) ])
      ]
      @ index_result_rules
          "index-value"
          (index_value_state count)
          count
      @ [ statement
          (crl
             ~label:(sanitize_label (name ^ "-index-value-end"))
             (index_value_state count prefix_index end_index)
             (index_value_state count prefix_index (succ end_index))
             [ EqCondition
                 (BoolCond (app "_<_" [ end_index; count ])) ])
      ; statement
          (rl
             ~label:(sanitize_label (name ^ "-index-value-prefix"))
             (index_value_state count (succ prefix_index) count)
             (index_value_state count prefix_index prefix_index))
      ]
  in
  let statements =
    declarations @ value_equations @ compact_equations @ scan_equations
    @ index_equations @ start_rules @ non_value_rules @ value_rules
  in
  name, result, statements

let lower ctx relation_id origin names env certificate lhs_terms =
  let find source = Expr_env.find env source in
  let found =
    find (Execution_context_certificate.prefix_source certificate),
    find (Execution_context_certificate.focus_source certificate),
    find (Execution_context_certificate.suffix_source certificate),
    Expr_env.find_subtype_roundtrip
      env (Execution_context_certificate.prefix_source certificate)
  in
  (match found with
  | Some _prefix, Some focus, Some suffix, Some roundtrip ->
    (match Pattern_subtyping.sequence_roundtrip roundtrip with
    | None -> None
    | Some sequence_roundtrip
      when not (source_surface_is_total sequence_roundtrip.injection) ->
      (* A target constructor can be skipped as a source value only when its
         payload membership establishes the complete source construction
         domain.  Guarded source cases keep the original associative match. *)
      None
    | Some sequence_roundtrip ->
      let value_cases =
        Subtype_injection.cases sequence_roundtrip.injection
        |> List.map (fun case ->
          Subtype_injection.source_mixop case,
          List.length (Subtype_injection.payload_sorts case))
      in
      let progress_certificate =
        Execution_progress_certificate.certify
          ctx ~relation_id ~context:certificate ~value_cases
      in
      let strict =
        Execution_context_certificate.strictly_smaller_focus certificate
      in
      let whole, names =
        Local_name.fresh_typed names Local_name.Stream seq_sort
      in
      (match
         replace_unique
           sequence_roundtrip.target focus.term suffix.term whole lhs_terms
       with
      | None -> None
      | Some lhs_terms ->
        let name, result, statements =
          materialize
            ~all_values_irreducible:(Option.is_some progress_certificate)
            ~strict_progress:strict
            origin sequence_roundtrip.injection
        in
        let condition =
          RewriteCond
            ( app name [ whole ]
            , app result
                [ sequence_roundtrip.target; focus.term; suffix.term ] )
        in
        let guard_proof =
          match progress_certificate, strict, sequence_roundtrip.source with
          | Some _, true, Var source_var ->
            Some
              { proved_guards =
                  [ sequence_roundtrip.required_guard
                  ; strict_progress sequence_roundtrip.source suffix.term
                  ]
              ; witness_vars = [ source_var ]
              }
          | Some _, true, (Const _ | Qid _ | App _) | None, _, _
          | Some _, false, _ -> None
        in
        Some
          ({ lhs_terms; condition; guard_proof; statements }, names)))
  | _ -> None)
