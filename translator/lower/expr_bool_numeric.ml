open Il.Ast
open Maude_ir
open Util.Source

include Expr_support

type callbacks =
  { lower_value : Context.t -> env -> Origin.t -> exp -> result
  ; lower_sequence : Context.t -> env -> Origin.t -> exp -> result
  ; lower_call : Context.t -> env -> Origin.t -> exp -> id -> arg list -> result
  ; witness_of_typ : Context.t -> env -> Origin.t -> typ -> term option * Diagnostics.t list
  }

let lower_numeric_conversion callbacks ctx env origin exp inner source_typ target_typ =
  if numeric_conversion_preserves_runtime_representation source_typ target_typ then
    callbacks.lower_value ctx env origin inner
  else
    unsupported_exp ctx origin "Expr/CvtE" exp
      "only representation-preserving numeric conversions are erased in this slice; sign-changing, narrowing, Rat, and Real conversions still need a verified carrier strategy"

let lower_numeric_subtyping callbacks ctx env origin exp inner source_typ target_typ =
  match primitive_numeric_alias_sort ctx source_typ, primitive_numeric_alias_sort ctx target_typ with
  | Some source_sort, Some target_sort
    when numeric_sort_coercion_preserves_runtime_representation source_sort target_sort ->
    callbacks.lower_value ctx env origin inner
  | _ ->
    let inner_result = callbacks.lower_value ctx env origin inner in
    let witness_opt, witness_diagnostics =
      callbacks.witness_of_typ ctx env origin target_typ
    in
    let target_sort_opt = carrier_sort_of_typ target_typ in
    (match inner_result.term, witness_opt, target_sort_opt with
    | Some term, Some witness, Some target_sort ->
      { term = Some term
      ; guards =
          inner_result.guards
          @ [ BoolCond (typecheck_for_sort target_sort term witness) ]
      ; diagnostics = inner_result.diagnostics @ witness_diagnostics
      }
    | _ ->
      { term = None
      ; guards = inner_result.guards
      ; diagnostics =
          inner_result.diagnostics @ witness_diagnostics
          @ [ unsupported
                ~ctx ~origin ~constructor:"Expr/SubE"
                ~source_echo:(source_echo_exp exp)
                ~reason:
                  "SubE coercion could not lower its inner expression, target witness, or target carrier"
                ~suggestion:
                  "Extend witness/carrier lowering for this source type before preserving the coercion as a Maude guard"
                ()
            ]
      })

let rec lower_bool_value callbacks ctx env origin exp =
  let lowered = lower_bool_raw callbacks ctx env origin exp in
  match lowered.term with
  | Some term -> { lowered with term = Some (bool_wrapper term) }
  | None -> lowered

and lower_unary_value callbacks ctx env origin exp op exp1 =
  let lowered = callbacks.lower_value ctx env origin exp1 in
  match lowered.term with
  | None -> lowered
  | Some term when op = "+" ->
    (match raw_numeric_sort_of_typ ctx exp.note with
    | Some sort when is_nat_int_sort sort -> { lowered with term = Some term }
    | _ ->
      unsupported_exp ctx origin "Expr/UnE" exp
        "unary plus erasure is only valid for Nat/Int value carriers")
  | Some term ->
    let raw = app (maude_unop_of_source op) [ term ] in
    (match exp.note.it, raw_numeric_sort_of_typ ctx exp.note with
    | BoolT, _ -> { lowered with term = Some (bool_wrapper raw) }
    | _, Some sort when is_nat_int_sort sort -> { lowered with term = Some raw }
    | _ ->
      unsupported_exp ctx origin "Expr/UnE" exp
        "unary operator result type is not a supported pure DecD value carrier")

and lower_binary_value callbacks ctx env origin exp op left right =
  let left_result = callbacks.lower_value ctx env origin left in
  let right_result = callbacks.lower_value ctx env origin right in
  match left_result.term, right_result.term with
  | Some left_term, Some right_term ->
    let raw = app (maude_op_of_source op) [ left_term; right_term ] in
    let numeric_sort = raw_numeric_sort_of_typ ctx exp.note in
    { term =
        (match exp.note.it, numeric_sort with
        | BoolT, _ -> Some (bool_wrapper raw)
        | _, Some sort when is_nat_int_sort sort -> Some raw
        | _ -> None)
    ; guards = left_result.guards @ right_result.guards
    ; diagnostics =
        left_result.diagnostics @ right_result.diagnostics
        @ (match exp.note.it, numeric_sort with
          | BoolT, _ -> []
          | _, Some sort when is_nat_int_sort sort -> []
          | _ ->
            [ unsupported
                ~ctx ~origin ~constructor:"Expr/BinE"
                ~source_echo:(source_echo_exp exp)
                ~reason:
                  "binary operator result type is not a supported pure DecD value carrier"
                ()
            ])
    }
  | _ ->
    { term = None
    ; guards = left_result.guards @ right_result.guards
    ; diagnostics = left_result.diagnostics @ right_result.diagnostics
    }

and lower_numeric_guard_value callbacks ctx env origin exp =
  match raw_numeric_sort_of_typ ctx exp.note with
  | None ->
    unsupported_exp ctx origin "Expr/NumericGuard" exp
      "numeric guard expression does not have a Nat, Int, Rat, or primitive numeric alias note"
  | Some _ ->
    (match exp.it with
    | VarE id ->
      (match find_var env id.it with
      | Some binding when is_raw_numeric_sort binding.sort -> with_term binding.term
      | Some binding
        when Option.is_some (raw_numeric_sort_of_typ ctx binding.typ) ->
        with_term binding.term
      | Some _ ->
        unsupported_exp ctx origin "Expr/NumericGuard/VarE" exp
          "bound variable is not a raw Nat/Int/Rat guard carrier"
      | None ->
        unsupported_exp ctx origin "Expr/NumericGuard/VarE" exp
          ("unbound variable `" ^ id.it ^ "` in numeric guard"))
    | NumE n -> with_term (Const (maude_numeric_literal n))
    | UnE (op, _, inner) ->
      let lowered = lower_numeric_guard_value callbacks ctx env origin inner in
      (match lowered.term with
      | Some term when Il.Print.string_of_unop op = "+" ->
        { lowered with term = Some term }
      | Some term ->
        { lowered with
          term =
            Some
              (app
                 (maude_unop_of_source (Il.Print.string_of_unop op))
                 [ term ])
        }
      | None -> lowered)
    | BinE (`ModOp, _, _, _) ->
      unsupported_exp ctx origin "Expr/NumericGuard/BinE" exp
        "numeric modulo uses source operator `\\`, which needs a verified Maude/prelude encoding before it can be emitted parse-safely"
    | BinE (op, _, left, right) ->
      let left_result = lower_numeric_guard_value callbacks ctx env origin left in
      let right_result = lower_numeric_guard_value callbacks ctx env origin right in
      (match left_result.term, right_result.term with
      | Some left_term, Some right_term ->
        { term =
            Some
              (app
                 (maude_op_of_source (Il.Print.string_of_binop op))
                 [ left_term; right_term ])
        ; guards = left_result.guards @ right_result.guards
        ; diagnostics = left_result.diagnostics @ right_result.diagnostics
        }
      | _ ->
        { term = None
        ; guards = left_result.guards @ right_result.guards
        ; diagnostics = left_result.diagnostics @ right_result.diagnostics
        })
    | CvtE (inner, source_typ, target_typ) ->
      (match raw_numeric_sort_of_numtyp source_typ, raw_numeric_sort_of_numtyp target_typ with
      | Some source_sort, Some target_sort
        when numeric_sort_coercion_preserves_runtime_representation source_sort target_sort ->
        lower_numeric_guard_value callbacks ctx env origin inner
      | _ ->
        unsupported_exp ctx origin "Expr/NumericGuard/CvtE" exp
          "numeric guard conversion is supported only when it preserves the raw numeric representation")
    | SubE (inner, source_typ, target_typ) ->
      (match raw_numeric_sort_of_typ ctx source_typ, raw_numeric_sort_of_typ ctx target_typ with
      | Some source_sort, Some target_sort
        when numeric_sort_coercion_preserves_runtime_representation source_sort target_sort ->
        lower_numeric_guard_value callbacks ctx env origin inner
      | _ ->
        unsupported_exp ctx origin "Expr/NumericGuard/SubE" exp
          "numeric guard subtype coercion is supported only when it preserves the raw numeric representation")
    | CallE (id, args) ->
      callbacks.lower_call ctx env origin exp id args
    | ProjE _ | UncaseE _ | LenE _ | IdxE _ | SliceE _ ->
      callbacks.lower_value ctx env origin exp
    | _ ->
      callbacks.lower_value ctx env origin exp)

and projection_inverse_constructor ctx scrutinee mixop payload_typ =
  let arity = List.length (typ_components payload_typ) in
  if arity <> 1 then
    None
  else
    match emitted_typcase_constructor_lookup ctx scrutinee.note mixop arity with
    | Constructor_found constructor -> Some constructor
    | Constructor_missing | Constructor_blocked _ | Constructor_ambiguous _ -> None

and lower_projection_equality_binding callbacks ctx env origin projection_exp value_exp =
  match projection_exp.it with
  | ProjE (({ it = UncaseE (scrutinee, mixop); _ } as uncase_exp), 0) ->
    (match scrutinee.it, projection_inverse_constructor ctx scrutinee mixop uncase_exp.note with
    | VarE id, Some constructor ->
      (match find_var env id.it with
      | Some { term = (Var _ as scrutinee_term); _ } ->
        let value_result = callbacks.lower_value ctx env origin value_exp in
        (match value_result.term with
        | Some value_term ->
          Some
            { term = Some (Const "true")
            ; guards =
                value_result.guards
                @ [ MatchCond (app constructor [ value_term ], scrutinee_term) ]
            ; diagnostics = value_result.diagnostics
            }
        | None -> Some value_result)
      | Some _ | None -> None)
    | _ -> None)
  | _ -> None

and lower_cmp_raw callbacks ctx env origin _exp op left right =
  match op with
  | `EqOp ->
    (match lower_projection_equality_binding callbacks ctx env origin left right with
    | Some result -> result
    | None ->
      (match lower_projection_equality_binding callbacks ctx env origin right left with
      | Some result -> result
      | None -> lower_cmp_raw_default callbacks ctx env origin op left right))
  | _ -> lower_cmp_raw_default callbacks ctx env origin op left right

and lower_cmp_raw_default callbacks ctx env origin op left right =
  let lower_operand exp =
    match raw_numeric_sort_of_typ ctx exp.note with
    | Some _ -> lower_numeric_guard_value callbacks ctx env origin exp
    | None -> callbacks.lower_value ctx env origin exp
  in
  let left_result = lower_operand left in
  let right_result = lower_operand right in
  match left_result.term, right_result.term with
  | Some left_term, Some right_term ->
    { term = Some (app (maude_cmp_op op) [ left_term; right_term ])
    ; guards = left_result.guards @ right_result.guards
    ; diagnostics = left_result.diagnostics @ right_result.diagnostics
    }
  | _ ->
    { term = None
    ; guards = left_result.guards @ right_result.guards
    ; diagnostics = left_result.diagnostics @ right_result.diagnostics
    }

and lower_bool_raw callbacks ctx env origin exp =
  match exp.it with
  | BoolE b -> with_term (Const (string_of_bool b))
  | CmpE (op, _, left, right) ->
    lower_cmp_raw callbacks ctx env origin exp op left right
  | MemE (left, right) ->
    lower_mem_raw callbacks ctx env origin exp left right
  | CallE (id, args) ->
    let lowered = callbacks.lower_call ctx env origin exp id args in
    (match lowered.term with
    | Some term -> { lowered with term = Some (is_true term) }
    | None -> lowered)
  | UnE (`NotOp, _, exp1) ->
    let lowered = lower_bool_raw callbacks ctx env origin exp1 in
    (match lowered.term with
    | Some term -> { lowered with term = Some (app "not_" [ term ]) }
    | None -> lowered)
  | UnE _ ->
    unsupported_exp ctx origin "Expr/BoolUnE" exp
      "only source Bool negation is supported as a raw Bool unary operator"
  | BinE ((`AndOp | `OrOp) as op, _, left, right) ->
    let left_result = lower_bool_raw callbacks ctx env origin left in
    let right_result = lower_bool_raw callbacks ctx env origin right in
    (match left_result.term, right_result.term with
    | Some left_term, Some right_term ->
      let op_name =
        match op with
        | `AndOp -> "_and_"
        | `OrOp -> "_or_"
      in
      { term = Some (app op_name [ left_term; right_term ])
      ; guards = left_result.guards @ right_result.guards
      ; diagnostics = left_result.diagnostics @ right_result.diagnostics
      }
    | _ ->
      { term = None
      ; guards = left_result.guards @ right_result.guards
      ; diagnostics = left_result.diagnostics @ right_result.diagnostics
      })
  | BinE ((`ImplOp | `EquivOp) as op, _, left, right) ->
    let left_result = lower_bool_raw callbacks ctx env origin left in
    let right_result = lower_bool_raw callbacks ctx env origin right in
    (match left_result.term, right_result.term with
    | Some left_term, Some right_term ->
      let term =
        match op with
        | `ImplOp -> app "_or_" [ app "not_" [ left_term ]; right_term ]
        | `EquivOp -> app "_==_" [ left_term; right_term ]
      in
      { term = Some term
      ; guards = left_result.guards @ right_result.guards
      ; diagnostics = left_result.diagnostics @ right_result.diagnostics
      }
    | _ ->
      { term = None
      ; guards = left_result.guards @ right_result.guards
      ; diagnostics = left_result.diagnostics @ right_result.diagnostics
      })
  | VarE id ->
    (match find_var env id.it with
    | Some { sort; term; _ } when sort_name sort = "Bool" -> with_term term
    | Some { typ = { it = BoolT; _ }; term; _ } -> with_term (is_true term)
    | Some _ ->
      unsupported_exp ctx origin "Expr/BoolVarE" exp
        "source bool variables in Bool conditions need wrapper elimination, which is not implemented"
    | None ->
      unsupported_exp ctx origin "Expr/BoolVarE" exp
        ("unbound variable `" ^ id.it ^ "` in Bool condition"))
  | _ ->
    unsupported_exp ctx origin "Expr/BoolCondition" exp
      "expression is not a supported Bool condition form"

and lower_mem_value callbacks ctx env origin exp left right =
  let lowered = lower_mem_raw callbacks ctx env origin exp left right in
  match lowered.term with
  | Some term -> { lowered with term = Some (bool_wrapper term) }
  | None -> lowered

and lower_mem_raw callbacks ctx env origin exp left right =
  let binding_diagnostic =
    match left.it with
    | VarE id when find_var env id.it = None ->
      Some
        (unsupported
           ~ctx ~origin ~constructor:"Expr/MemE/binding"
           ~source_echo:(source_echo_exp exp)
           ~reason:
             ("membership expression would bind unbound variable `" ^ id.it
              ^ "`; binding membership/search semantics are outside this slice")
           ~suggestion:
             "Route binding membership through a future MatchCond/search helper instead of lowering it to contains"
           ())
    | _ -> None
  in
  match binding_diagnostic with
  | Some diagnostic -> with_diagnostics [ diagnostic ]
  | None ->
    let left_result = callbacks.lower_value ctx env origin left in
    let right_result = callbacks.lower_sequence ctx env origin right in
    (match left_result.term, right_result.term with
    | Some left_term, Some right_term ->
      { term = Some (contains left_term right_term)
      ; guards = left_result.guards @ right_result.guards
      ; diagnostics = left_result.diagnostics @ right_result.diagnostics
      }
    | _ ->
      { term = None
      ; guards = left_result.guards @ right_result.guards
      ; diagnostics = left_result.diagnostics @ right_result.diagnostics
      })
