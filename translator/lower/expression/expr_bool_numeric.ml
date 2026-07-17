open Il.Ast
open Maude_ir
open Util.Source

open Expr_diagnostic
open Expr_result

let app name args = App (name, args)

let maude_unop (op : unop) =
  match op with
  | `NotOp -> "~_"
  | `PlusOp -> "+_"
  | `MinusOp -> "-_"

let maude_binop (op : binop) =
  match op with
  | `AndOp -> "_/\\_"
  | `OrOp -> "_\\/_"
  | `ImplOp -> "_=>_"
  | `EquivOp -> "_<=>_"
  | `AddOp -> "_+_"
  | `SubOp -> "_-_"
  | `MulOp -> "_*_"
  | `DivOp -> "_/_"
  | `ModOp -> "_\\_"
  | `PowOp -> "_^_"

let maude_cmp_op (op : cmpop) =
  match op with
  | `EqOp -> "_==_"
  | `NeOp -> "_=/=_"
  | `LtOp -> "_<_"
  | `GtOp -> "_>_"
  | `LeOp -> "_<=_"
  | `GeOp -> "_>=_"

let contains term sequence =
  app "contains" [ term; sequence ]

let is_true term =
  app "isTrue" [ term ]

type env = Expr_env.t
type binding = Expr_env.binding

type callbacks =
  { lower_value : Context.t -> env -> Origin.t -> exp -> result
  ; lower_sequence : Context.t -> env -> Origin.t -> exp -> result
  ; lower_call : Context.t -> env -> Origin.t -> exp -> id -> arg list -> result
  ; witness_of_typ : Context.t -> env -> Origin.t -> typ -> term option * Diagnostics.t list
  }

let numeric_cast source_sort target_sort term =
  match sort_name source_sort, sort_name target_sort with
  | source, target when source = target -> Some (term, [])
  | "Nat", ("Int" | "Rat") -> Some (term, [])
  | "Int", "Rat" -> Some (term, [])
  | "Int", "Nat" ->
    Some
      ( app "natOfInt" [ term ]
      , [ BoolCond (app "_>=_" [ term; Const "0" ]) ] )
  | "Rat", "Int" ->
    Some
      ( app "intOfRat" [ term ]
      , [ BoolCond (app "ratIsInt" [ term ]) ] )
  | "Rat", "Nat" ->
    Some
      ( app "natOfRat" [ term ]
      , [ BoolCond (app "ratIsInt" [ term ])
        ; BoolCond (app "_>=_" [ term; Const "0" ])
        ] )
  | _ -> None

let wrap_numeric_value target_sort term =
  match sort_name target_sort with
  | "Nat" | "Int" -> Some term
  | "Rat" -> Some (app "rat" [ term ])
  | _ -> None

let modulo_lowering sort left right =
  match sort_name sort with
  | "Nat" ->
    Some
      ( app "modNat" [ left; right ]
      , [ BoolCond (app "_=/=_" [ right; Const "0" ]) ] )
  | "Int" ->
    Some
      ( app "modInt" [ left; right ]
      , [ BoolCond (app "_=/=_" [ right; Const "0" ]) ] )
  | _ -> None

let division_guards (op : binop) right =
  match op with
  | `DivOp -> [ BoolCond (app "_=/=_" [ right; Const "0" ]) ]
  | `AndOp | `OrOp | `ImplOp | `EquivOp
  | `AddOp | `SubOp | `MulOp | `ModOp | `PowOp -> []

let rec lower_raw_numeric_conversion callbacks ctx env origin exp inner source_sort target_sort =
  let lowered = lower_numeric_guard_value callbacks ctx env origin inner in
  match lowered.term with
  | Some term ->
    (match numeric_cast source_sort target_sort term with
    | Some (term, guards) ->
      { lowered with term = Some term; guards = lowered.guards @ guards }
    | None ->
      unsupported_exp ctx origin "Expr/CvtE" exp
        "numeric conversion has no verified Maude carrier conversion for this source/target sort pair")
  | None -> lowered

and lower_numeric_conversion callbacks ctx env origin exp inner source_typ target_typ =
  match
    Carrier_sort.raw_numeric_sort_of_numtyp source_typ,
    Carrier_sort.raw_numeric_sort_of_numtyp target_typ
  with
  | Some source_sort, Some target_sort ->
    let lowered =
      lower_raw_numeric_conversion callbacks ctx env origin exp inner source_sort target_sort
    in
    (match lowered.term with
    | Some term ->
      (match wrap_numeric_value target_sort term with
      | Some term -> { lowered with term = Some term }
      | None ->
        unsupported_exp ctx origin "Expr/CvtE" exp
          "numeric conversion target has no verified runtime carrier wrapper")
    | None -> lowered)
  | _ ->
    unsupported_exp ctx origin "Expr/CvtE" exp
      "Real/Float numeric conversions need the builtin float policy before lowering"

and lower_bool_value callbacks ctx env origin exp =
  let lowered = lower_bool_raw callbacks ctx env origin exp in
  match lowered.term with
  | Some term -> { lowered with term = Some (Primitive_term.bool term) }
  | None -> lowered

and lower_unary_value callbacks ctx env origin exp op exp1 =
  let lowered = callbacks.lower_value ctx env origin exp1 in
  match op, lowered.term with
  | (`NotOp | `PlusOp | `MinusOp), None -> lowered
  | `PlusOp, Some term ->
    (match Carrier_sort.raw_numeric_sort_of_typ ctx exp.note with
    | Some sort when Carrier_sort.is_nat_int_sort sort -> { lowered with term = Some term }
    | _ ->
      unsupported_exp ctx origin "Expr/UnE" exp
        "unary plus erasure is only valid for Nat/Int value carriers")
  | (`NotOp | `MinusOp), Some term ->
    let raw = app (maude_unop op) [ term ] in
    (match exp.note.it, Carrier_sort.raw_numeric_sort_of_typ ctx exp.note with
    | BoolT, _ -> { lowered with term = Some (Primitive_term.bool raw) }
    | _, Some sort when Carrier_sort.is_nat_int_sort sort -> { lowered with term = Some raw }
    | _ ->
      unsupported_exp ctx origin "Expr/UnE" exp
        "unary operator result type is not a supported pure DecD value carrier")

and lower_binary_value callbacks ctx env origin exp op left right =
  let lower_operand =
    match op with
    | `ModOp | `DivOp -> lower_numeric_guard_value callbacks ctx env origin
    | `AndOp | `OrOp | `ImplOp | `EquivOp
    | `AddOp | `SubOp | `MulOp | `PowOp -> callbacks.lower_value ctx env origin
  in
  let left_result = lower_operand left in
  let right_result = lower_operand right in
  match left_result.term, right_result.term with
  | Some left_term, Some right_term ->
    let numeric_sort = Carrier_sort.raw_numeric_sort_of_typ ctx exp.note in
    let raw_opt, modulo_guards, modulo_diagnostics =
      match op with
      | `ModOp ->
        (match numeric_sort with
        | Some sort ->
          (match modulo_lowering sort left_term right_term with
          | Some (raw, guards) -> Some raw, guards, []
          | None ->
            None, [],
            [ unsupported
                ~ctx ~origin ~constructor:"Expr/BinE"
                ~source_echo:(source_echo_exp exp)
                ~reason:
                  ("numeric modulo is implemented only for Nat/Int value carriers, not "
                   ^ sort_name sort)
                ()
            ])
        | None ->
          None, [],
          [ unsupported
              ~ctx ~origin ~constructor:"Expr/BinE"
              ~source_echo:(source_echo_exp exp)
              ~reason:
                "numeric modulo requires a Nat/Int carrier; result type did not provide one"
              ()
          ])
      | `AndOp | `OrOp | `ImplOp | `EquivOp
      | `AddOp | `SubOp | `MulOp | `DivOp | `PowOp ->
        ( Some (app (maude_binop op) [ left_term; right_term ])
        , division_guards op right_term
        , [] )
    in
    let lowered_term =
      match raw_opt, exp.note.it, numeric_sort with
      | Some raw, BoolT, _ -> Some (Primitive_term.bool raw)
      | Some raw, _, Some sort -> wrap_numeric_value sort raw
      | _ -> None
    in
    { term =
        lowered_term
    ; guards = left_result.guards @ right_result.guards @ modulo_guards
    ; diagnostics =
        left_result.diagnostics @ right_result.diagnostics
        @ modulo_diagnostics
        @ (match raw_opt, exp.note.it, numeric_sort with
          | None, _, _ -> []
          | _, BoolT, _ -> []
          | Some raw, _, Some sort when Option.is_some (wrap_numeric_value sort raw) -> []
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
  match Carrier_sort.raw_numeric_sort_of_typ ctx exp.note with
  | None ->
    unsupported_exp ctx origin "Expr/NumericGuard" exp
      "numeric guard expression does not have a Nat, Int, Rat, or primitive numeric alias note"
  | Some _ ->
    (match exp.it with
    | VarE id ->
      (match Expr_env.find env id.it with
      | Some binding when Carrier_sort.is_raw_numeric_sort binding.sort -> with_term binding.term
      | Some binding
        when Option.is_some (Carrier_sort.raw_numeric_sort_of_typ ctx binding.typ) ->
        with_term binding.term
      | Some _ ->
        unsupported_exp ctx origin "Expr/NumericGuard/VarE" exp
          "bound variable is not a raw Nat/Int/Rat guard carrier"
      | None ->
        unsupported_exp ctx origin "Expr/NumericGuard/VarE" exp
          ("unbound variable `" ^ id.it ^ "` in numeric guard"))
    | NumE n -> with_term (Primitive_term.number n)
    | UnE (op, _, inner) ->
      let lowered = lower_numeric_guard_value callbacks ctx env origin inner in
      (match lowered.term with
      | Some term ->
        (match op with
        | `PlusOp -> { lowered with term = Some term }
        | `NotOp | `MinusOp ->
          { lowered with term = Some (app (maude_unop op) [ term ]) })
      | None -> lowered)
    | BinE (`ModOp, _, left, right) ->
      let left_result = lower_numeric_guard_value callbacks ctx env origin left in
      let right_result = lower_numeric_guard_value callbacks ctx env origin right in
      (match
         left_result.term,
         right_result.term,
         Carrier_sort.raw_numeric_sort_of_typ ctx exp.note
       with
      | Some left_term, Some right_term, Some sort ->
        (match modulo_lowering sort left_term right_term with
        | Some (raw, modulo_guards) ->
          { term = Some raw
          ; guards = left_result.guards @ right_result.guards @ modulo_guards
          ; diagnostics = left_result.diagnostics @ right_result.diagnostics
          }
        | None ->
          unsupported_exp ctx origin "Expr/NumericGuard/BinE" exp
            "numeric modulo is implemented only for Nat/Int guard carriers")
      | _ ->
        { term = None
        ; guards = left_result.guards @ right_result.guards
        ; diagnostics = left_result.diagnostics @ right_result.diagnostics
        })
    | BinE (op, _, left, right) ->
      let left_result = lower_numeric_guard_value callbacks ctx env origin left in
      let right_result = lower_numeric_guard_value callbacks ctx env origin right in
      (match left_result.term, right_result.term with
      | Some left_term, Some right_term ->
        { term =
            Some (app (maude_binop op) [ left_term; right_term ])
        ; guards =
            left_result.guards @ right_result.guards
            @ division_guards op right_term
        ; diagnostics = left_result.diagnostics @ right_result.diagnostics
        }
      | _ ->
        { term = None
        ; guards = left_result.guards @ right_result.guards
        ; diagnostics = left_result.diagnostics @ right_result.diagnostics
        })
    | CvtE (inner, source_typ, target_typ) ->
      (match
         Carrier_sort.raw_numeric_sort_of_numtyp source_typ,
         Carrier_sort.raw_numeric_sort_of_numtyp target_typ
       with
      | Some source_sort, Some target_sort ->
        lower_raw_numeric_conversion callbacks ctx env origin exp inner source_sort target_sort
      | _ ->
        unsupported_exp ctx origin "Expr/NumericGuard/CvtE" exp
          "Real/Float numeric guard conversion needs the builtin float policy before lowering")
    | SubE (inner, source_typ, target_typ) ->
      (match
         Carrier_sort.raw_numeric_sort_of_typ ctx source_typ,
         Carrier_sort.raw_numeric_sort_of_typ ctx target_typ
       with
      | Some source_sort, Some target_sort
        when Carrier_sort.numeric_sort_coercion_preserves_runtime_representation
               source_sort target_sort ->
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
  let arity = List.length (Type_shape.typ_components payload_typ) in
  if arity <> 1 then
    None
  else
    match Typcase_constructor.resolve_emitted ctx scrutinee.note mixop ~arity with
    | Typcase_constructor.Found resolution ->
      Some resolution.Typcase_constructor.resolved_constructor
    | Typcase_constructor.Missing
    | Typcase_constructor.Blocked _
    | Typcase_constructor.Ambiguous _ -> None

and lower_projection_equality_binding callbacks ctx env origin projection_exp value_exp =
  match projection_exp.it with
  | ProjE (({ it = UncaseE (scrutinee, mixop); _ } as uncase_exp), 0) ->
    (match scrutinee.it, projection_inverse_constructor ctx scrutinee mixop uncase_exp.note with
    | VarE id, Some constructor ->
      (match Expr_env.find env id.it with
      | Some { term = (Var _ as scrutinee_term); _ } ->
        let value_result = callbacks.lower_value ctx env origin value_exp in
        (match value_result.term with
        | Some value_term ->
          Some
            { term = Some (Const "true")
            ; guards =
                value_result.guards
                @ [ MatchCond (scrutinee_term, app constructor [ value_term ]) ]
            ; diagnostics = value_result.diagnostics
            }
        | None -> Some value_result)
      | Some _ | None -> None)
    | _ -> None)
  | _ -> None

and binding_is_condition_bound env (binding : binding) =
  match Expr_env.condition_bound_vars env with
  | None -> false
  | Some bound ->
    Condition_closure.term_vars binding.term
    |> List.for_all (fun var -> List.mem var bound)

and category_named_var ctx id =
  Analysis.Source_index.find_by_id (Context.source_index ctx) id.it
  |> List.find_map (fun entry ->
    match entry.Analysis.Source_index.def.it with
    | TypD (typ_id, [], _) when typ_id.it = id.it ->
      Some (Const (Naming.category_witness id))
    | _ -> None)

and source_category_witness ctx env exp =
  match exp.it with
  | VarE id when Expr_env.find env id.it = None -> category_named_var ctx id
  | SubE ({ it = VarE id; _ }, { it = VarT (typ_id, []); _ }, _)
    when id.it = typ_id.it
         && (match Expr_env.find env id.it with
             | None -> true
             | Some binding -> not (binding_is_condition_bound env binding)) ->
    category_named_var ctx id
  | _ -> None

and lower_category_membership_equality callbacks ctx env origin value_exp category_exp =
  match source_category_witness ctx env category_exp with
  | None -> None
  | Some witness ->
    let value_result = callbacks.lower_value ctx env origin value_exp in
    let sort_opt = Carrier_sort.for_expression value_exp.note in
    Some
      (match value_result.term, sort_opt with
      | Some value_term, Some value_sort ->
        { value_result with
          term = Some (Typecheck_term.typecheck_for_sort value_sort value_term witness)
        }
      | _ -> value_result)

and lower_cmp_raw callbacks ctx env origin _exp op left right =
  match op with
  | `EqOp ->
    (match lower_category_membership_equality callbacks ctx env origin left right with
    | Some result -> result
    | None ->
      (match lower_category_membership_equality callbacks ctx env origin right left with
      | Some result -> result
      | None ->
        (match lower_projection_equality_binding callbacks ctx env origin left right with
        | Some result -> result
        | None ->
          (match lower_projection_equality_binding callbacks ctx env origin right left with
          | Some result -> result
          | None -> lower_cmp_raw_default callbacks ctx env origin op left right))))
  | _ -> lower_cmp_raw_default callbacks ctx env origin op left right

and lower_cmp_raw_default callbacks ctx env origin op left right =
  let lower_operand exp =
    match Carrier_sort.raw_numeric_sort_of_typ ctx exp.note with
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
    (match Expr_env.find env id.it with
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
  | Some term -> { lowered with term = Some (Primitive_term.bool term) }
  | None -> lowered

and lower_mem_raw callbacks ctx env origin exp left right =
  let binding_diagnostic =
    match left.it with
    | VarE id when Expr_env.find env id.it = None ->
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
