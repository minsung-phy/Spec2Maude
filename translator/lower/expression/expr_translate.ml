open Il.Ast
open Maude_ir
open Util.Source

open Expr_diagnostic
open Expr_result

let app name args = App (name, args)

type result = Expr_result.result =
  { term : term option
  ; guards : eq_condition list
  ; diagnostics : Diagnostics.t list
  }

type binding = Expr_env.binding =
  { term : term
  ; sort : sort
  ; typ : typ
  }

type pattern_result = Expr_result.pattern_result =
  { pattern_term : term option
  ; pattern_guards : eq_condition list
  ; introduced_bindings : (string * binding) list
  ; pattern_diagnostics : Diagnostics.t list
  }

type env = Expr_env.t

let carrier_sort_of_typ = Carrier_sort.for_expression

let numeric_literal_diagnostic ctx origin exp =
  unsupported
    ~ctx ~origin ~constructor:"Expr/NumE"
    ~source_echo:(source_echo_exp exp)
    ~reason:
      "numeric literal is only lowered directly when the IL expected type is Nat or Int"
    ~suggestion:"Add wrapper/primitive strategy for Rat/Real literals before lowering this expression"
    ()

let literal_num_value ctx origin exp n =
  match Xl.Num.to_typ n with
  | `NatT | `IntT -> with_term (Primitive_term.number n)
  | `RatT | `RealT -> with_diagnostics [ numeric_literal_diagnostic ctx origin exp ]

let typecheck_conditions_for_typ = Typecheck_guard.for_typ

type witness_result =
  { witness_term : term option
  ; witness_guards : eq_condition list
  ; witness_diagnostics : Diagnostics.t list
  }

let rec nth_opt items index =
  match items, index with
  | item :: _, 0 -> Some item
  | _ :: rest, index when index > 0 -> nth_opt rest (index - 1)
  | _ -> None

let lower_case_impl ~lower_value ~category_guards_for_term ctx env origin exp mixop arg_exp =
  let lower_arg exp = lower_value ctx env origin exp in
  let arg_results =
    match arg_exp.it with
    | TupE exps -> List.map lower_arg exps
    | _ -> [ lower_arg arg_exp ]
  in
  let guards, diagnostics = append_result_metadata arg_results in
  let terms =
    List.filter_map (fun (result : result) -> result.term) arg_results
  in
  if List.length terms = List.length arg_results then
    let arity = List.length terms in
    match exp.note.it, terms with
    | VarT (id, _), _ ->
      ignore id;
      (match Typcase_constructor.resolve_emitted ctx exp.note mixop ~arity with
      | Typcase_constructor.Found resolution ->
        let constructor = resolution.Typcase_constructor.resolved_constructor in
        let constructor_term = app constructor terms in
        let category_guards_opt, category_diagnostics =
          category_guards_for_term
            ctx env origin "Expr/CaseE/category" exp constructor_term exp.note
        in
        (match category_guards_opt with
        | Some category_guards ->
          { term = Some constructor_term
          ; guards = guards @ category_guards
          ; diagnostics = diagnostics @ category_diagnostics
          }
        | None ->
          { term = None
          ; guards
          ; diagnostics = diagnostics @ category_diagnostics
          })
      | Typcase_constructor.Missing ->
        let diagnostic =
          unsupported_exp ctx origin "Expr/CaseE" exp
            "constructor case has no emitted TypD constructor registry entry, so expression lowering refuses to call an undeclared Maude operator"
        in
        { diagnostic with
          guards = diagnostic.guards @ guards
        ; diagnostics = diagnostics @ diagnostic.diagnostics
        }
      | Typcase_constructor.Blocked reason ->
        let diagnostic = unsupported_exp ctx origin "Expr/CaseE" exp reason in
        { diagnostic with
          guards = diagnostic.guards @ guards
        ; diagnostics = diagnostics @ diagnostic.diagnostics
        }
      | Typcase_constructor.Ambiguous resolutions ->
        let constructors =
          List.map
            (fun resolution ->
              resolution.Typcase_constructor.resolved_constructor)
            resolutions
        in
        let diagnostic =
          unsupported_exp ctx origin "Expr/CaseE" exp
            (Printf.sprintf
               "constructor registry found %d emitted TypD constructor candidates for this category/arity, so expression lowering refuses to guess: %s"
               (List.length constructors)
               (String.concat ", " constructors))
        in
        { diagnostic with
          guards = diagnostic.guards @ guards
        ; diagnostics = diagnostics @ diagnostic.diagnostics
        })
    | _ ->
      let diagnostic =
        unsupported_exp ctx origin "Expr/CaseE" exp
          "constructor expression lowering requires a VarT source category on the result note"
      in
      { diagnostic with
        guards = diagnostic.guards @ guards
      ; diagnostics = diagnostics @ diagnostic.diagnostics
      }
  else
    { term = None; guards; diagnostics }

let lower_uncase_projection_impl
    ~lower_value
    ~category_guards_for_term
    ctx env origin exp scrutinee mixop payload_typ index =
  let arity = List.length (Type_shape.typ_components payload_typ) in
  if index < 0 || index >= arity then
    unsupported_exp ctx origin "Expr/ProjE" exp
      (Printf.sprintf
         "projection index %d is outside constructor payload arity %d"
         index arity)
  else
    match Typcase_constructor.resolve_emitted ctx scrutinee.note mixop ~arity with
    | Typcase_constructor.Found resolution ->
      let scrutinee_result : result = lower_value ctx env origin scrutinee in
      (match scrutinee_result.term with
      | Some scrutinee_term ->
        (match nth_opt resolution.Typcase_constructor.projection_ops index with
        | Some projection_op ->
          let scrutinee_guards_opt, scrutinee_guard_diagnostics =
            category_guards_for_term
              ctx env origin "Expr/UncaseE/scrutinee" scrutinee scrutinee_term scrutinee.note
          in
          (match scrutinee_guards_opt with
          | Some scrutinee_guards ->
            { term = Some (app projection_op [ scrutinee_term ])
            ; guards = scrutinee_result.guards @ scrutinee_guards
            ; diagnostics =
                scrutinee_result.diagnostics @ scrutinee_guard_diagnostics
            }
          | None ->
            { scrutinee_result with
              term = None
            ; diagnostics =
                scrutinee_result.diagnostics @ scrutinee_guard_diagnostics
            })
        | None ->
          unsupported_exp ctx origin "Expr/UncaseE" exp
            "constructor registry entry does not provide the requested projection index")
      | None -> scrutinee_result)
    | Typcase_constructor.Missing ->
      unsupported_exp ctx origin "Expr/UncaseE" exp
        "constructor destructor exists in source, but no emitted TypD constructor registry entry is available in this profile"
    | Typcase_constructor.Blocked reason ->
      unsupported_exp ctx origin "Expr/UncaseE" exp reason
    | Typcase_constructor.Ambiguous _ ->
      unsupported_exp ctx origin "Expr/UncaseE" exp
        "constructor registry has multiple emitted candidates for this destructor shape, so UncaseE refuses to guess"

let rec lower_type_witness_impl ~lower_value ctx env origin constructor typ =
  match typ.it with
  | VarT (id, []) ->
    (match Context.find_phantom_typ ctx id.it with
    | Some var_name ->
      { witness_term = Some (Var var_name)
      ; witness_guards = []
      ; witness_diagnostics = []
      }
    | None ->
      { witness_term = Some (app (Naming.category_witness id) [])
      ; witness_guards = []
      ; witness_diagnostics = []
      })
  | VarT (id, args) ->
    let results =
      List.map (lower_type_witness_arg_impl ~lower_value ctx env origin constructor) args
    in
    let terms = List.filter_map (fun result -> result.witness_term) results in
    let guards =
      results |> List.map (fun result -> result.witness_guards) |> List.concat
    in
    let diagnostics =
      results |> List.map (fun result -> result.witness_diagnostics) |> List.concat
    in
    if List.length terms = List.length args then
      { witness_term = Some (app (Naming.category_witness id) terms)
      ; witness_guards = guards
      ; witness_diagnostics = diagnostics
      }
    else
      { witness_term = None
      ; witness_guards = guards
      ; witness_diagnostics = diagnostics
      }
  | BoolT ->
    { witness_term = Some (Const (Naming.primitive_witness "bool"))
    ; witness_guards = []
    ; witness_diagnostics = []
    }
  | NumT `NatT ->
    { witness_term = Some (Const (Naming.primitive_witness "nat"))
    ; witness_guards = []
    ; witness_diagnostics = []
    }
  | NumT `IntT ->
    { witness_term = Some (Const (Naming.primitive_witness "int"))
    ; witness_guards = []
    ; witness_diagnostics = []
    }
  | NumT `RatT ->
    { witness_term = Some (Const (Naming.primitive_witness "rat"))
    ; witness_guards = []
    ; witness_diagnostics = []
    }
  | NumT `RealT ->
    { witness_term = Some (Const (Naming.primitive_witness "real"))
    ; witness_guards = []
    ; witness_diagnostics = []
    }
  | TextT ->
    { witness_term = Some (Const (Naming.primitive_witness "text"))
    ; witness_guards = []
    ; witness_diagnostics = []
    }
  | IterT (inner, (List | Opt)) when not (Type_shape.typ_is_iter inner) ->
    lower_type_witness_impl ~lower_value ctx env origin constructor inner
  | IterT ({ it = IterT (inner, (List | Opt)); _ }, (List | Opt))
    when not (Type_shape.typ_is_iter inner) ->
    lower_type_witness_impl ~lower_value ctx env origin constructor inner
  | IterT _ | TupT _ ->
    { witness_term = None
    ; witness_guards = []
    ; witness_diagnostics =
        [ unsupported_witness
            ctx origin (constructor ^ "/type-witness")
            (Il.Print.string_of_typ typ)
            "nested iteration or tuple type witness is not implemented for this lowering"
        ]
    }

and lower_type_witness_arg_impl ~lower_value ctx env origin constructor arg =
  match arg.it with
  | ExpA exp ->
    (match exp.it with
    | VarE id ->
      (match Expr_env.find env id.it with
      | Some binding ->
        { witness_term = Some binding.term
        ; witness_guards = []
        ; witness_diagnostics = []
        }
      | None ->
        { witness_term = None
        ; witness_guards = []
        ; witness_diagnostics =
            [ unsupported_witness
                ctx origin (constructor ^ "/type-arg/VarE")
                (Il.Print.string_of_exp exp)
                ("unbound type witness expression argument `" ^ id.it ^ "`")
            ]
        })
    | NumE n ->
      (match Xl.Num.to_typ n with
      | `NatT | `IntT ->
        { witness_term = Some (Primitive_term.number n)
        ; witness_guards = []
        ; witness_diagnostics = []
        }
      | `RatT | `RealT ->
        { witness_term = None
        ; witness_guards = []
        ; witness_diagnostics =
            [ unsupported_witness
                ctx origin (constructor ^ "/type-arg/NumE")
                (Il.Print.string_of_exp exp)
                "Rat/Real numeric type witness arguments need the primitive wrapper strategy"
            ]
        })
    | BoolE b ->
      { witness_term = Some (Primitive_term.bool (Const (string_of_bool b)))
      ; witness_guards = []
      ; witness_diagnostics = []
      }
    | TextE text ->
      { witness_term = Some (Primitive_term.text text)
      ; witness_guards = []
      ; witness_diagnostics = []
      }
    | _ ->
      let result : result = lower_value ctx env origin exp in
      (match result.term with
      | Some term ->
        { witness_term = Some term
        ; witness_guards = result.guards
        ; witness_diagnostics = result.diagnostics
        }
      | None ->
        { witness_term = None
        ; witness_guards = result.guards
        ; witness_diagnostics =
            result.diagnostics
            @ [ unsupported_witness
                  ctx origin (constructor ^ "/type-arg")
                  (Il.Print.string_of_exp exp)
                  "type witness expression argument could not be lowered with its required guards"
              ]
        }))
  | TypA typ ->
    lower_type_witness_impl ~lower_value ctx env origin constructor typ
  | DefA id ->
    { witness_term = None
    ; witness_guards = []
    ; witness_diagnostics =
        [ unsupported_witness
            ctx origin (constructor ^ "/type-arg/DefA") id.it
            "definition-valued type witness arguments require DefP specialization"
        ]
    }
  | GramA sym ->
    { witness_term = None
    ; witness_guards = []
    ; witness_diagnostics =
        [ unsupported_witness
            ctx origin (constructor ^ "/type-arg/GramA")
            (Il.Print.string_of_sym sym)
            "grammar-valued type witness arguments require monomorphization"
        ]
    }

let lower_call_impl ~lower_value ctx env origin exp id args =
  let graph = Context.function_graph ctx in
  let target_id =
    match Context.find_static_def ctx id.it with
    | Some actual_id -> { id with it = actual_id }
    | None -> id
  in
  let definition =
    Analysis.Function_graph.find_definition graph target_id.it
  in
  let resolution =
    Analysis.Function_graph.resolve_call
      graph
      ~static_typ_env:(Context.static_typ_env ctx)
      ~static_def_env:(Context.static_def_env ctx)
      ~origin
      target_id
      args
  in
  let unsupported_arg arg reason constructor =
    with_diagnostics
      [ unsupported
          ~ctx ~origin ~constructor
          ~source_echo:(Il.Print.string_of_arg arg)
          ~reason
          ~suggestion:"Specialize the called definition before lowering this call"
          ()
      ]
  in
  let lower_by_param param arg =
    match param, arg.it with
    | Analysis.Function_graph.Runtime_exp, ExpA exp ->
      Some (lower_value ctx env origin exp)
    | Analysis.Function_graph.Runtime_exp, (TypA _ | DefA _ | GramA _) ->
      Some
        (unsupported_arg
           arg
           "runtime ExpP parameter position received a static argument"
           "Expr/CallE/runtime-arg")
    | Analysis.Function_graph.Static_typ, TypA typ ->
      let witness =
        lower_type_witness_impl
          ~lower_value
          ctx
          env
          origin
          "Expr/CallE/static-arg/TypP"
          typ
      in
      Some
        { term = witness.witness_term
        ; guards = witness.witness_guards
        ; diagnostics = witness.witness_diagnostics
        }
    | Analysis.Function_graph.Static_typ, (ExpA _ | DefA _ | GramA _) ->
      Some
        (unsupported_arg
           arg
           "TypP parameter position requires a TypA argument"
           "Expr/CallE/static-arg/TypP")
    | Analysis.Function_graph.Static_def, DefA _ -> None
    | Analysis.Function_graph.Static_def, (ExpA _ | TypA _ | GramA _) ->
      Some
        (unsupported_arg
           arg
           "DefP parameter position requires a DefA argument"
           "Expr/CallE/static-arg/DefP")
    | Analysis.Function_graph.Static_gram, _ ->
      Some
        (unsupported_arg
           arg
           "GramP call arguments are outside the finite TypP/DefP monomorphization slice"
           "Expr/CallE/static-arg/GramP")
  in
  let results =
    match definition with
    | Some definition when List.length definition.params = List.length args ->
      List.filter_map Fun.id (List.map2 lower_by_param definition.params args)
    | Some _ ->
      [ with_diagnostics
          [ unsupported
              ~ctx ~origin ~constructor:"Expr/CallE/arity"
              ~source_echo:(source_echo_exp exp)
              ~reason:"definition call arity does not match the callee DecD parameter list"
              ~suggestion:"Preserve source argument positions before lowering this CallE"
              ()
          ]
      ]
    | None ->
      args
      |> List.map (fun arg ->
        match arg.it with
        | ExpA exp -> lower_value ctx env origin exp
        | TypA _ | DefA _ | GramA _ ->
          unsupported_arg
            arg
            "static argument targets an unknown DecD and cannot be specialized"
            "Expr/CallE/static-arg")
  in
  let _all_guards, diagnostics = append_result_metadata results in
  let terms = List.filter_map (fun (result : result) -> result.term) results in
  let guards = List.concat_map (fun (result : result) -> result.guards) results in
  let resolution_diagnostics, resolved_call =
    match resolution with
    | Analysis.Function_graph.Plain_call ->
      [], Some
        ( Context.definition_op ctx target_id
        , Analysis.Function_graph.plain_identity target_id.it )
    | Analysis.Function_graph.Specialized_call specialization ->
      if Analysis.Function_graph.has_specialization graph specialization then
        [], Some
          ( Context.specialized_definition_op ctx target_id specialization
          , Analysis.Function_graph.identity_of_specialization specialization )
      else
        [ unsupported
            ~ctx ~origin ~constructor:"Expr/CallE/static-specialization"
            ~source_echo:(source_echo_exp exp)
            ~reason:
              "call resolves to a static TypP/DefP specialization that was not materialized by the finite worklist"
            ~suggestion:"Extend the specialization worklist before emitting this call"
            ()
        ],
        None
    | Analysis.Function_graph.Unsupported_call reason ->
      [ unsupported
          ~ctx ~origin ~constructor:"Expr/CallE/static-specialization"
          ~source_echo:(source_echo_exp exp)
          ~reason
          ~suggestion:"Keep this CallE Unsupported until its static arguments can be resolved finitely"
          ()
      ],
      None
    | Analysis.Function_graph.Prelude_gap_call reason ->
      [ prelude_gap
          ~ctx ~origin ~constructor:"Expr/CallE/prelude-gap"
          ~source_echo:(source_echo_exp exp)
          ~reason
          ~suggestion:
            "Add an explicit generated DecD, builtin, or verified prelude handler before lowering this CallE"
          ()
      ],
      None
  in
  let diagnostics = diagnostics @ resolution_diagnostics in
  if List.exists Diagnostics.is_fatal diagnostics then
    { term = None; guards; diagnostics }
  else
    match resolved_call with
    | Some (op_name, identity) ->
      let term = app op_name terms in
      Context.record_definition_call ctx term identity;
      { term = Some term; guards; diagnostics }
    | None -> { term = None; guards; diagnostics }

type pattern_bridge_callbacks =
  { lower_value : Context.t -> env -> Origin.t -> exp -> result
  ; witness_of_typ_with_guards :
      Context.t -> env -> Origin.t -> constructor:string -> typ -> witness_result
  }

let pattern_case_constructor ctx origin exp mixop arity =
  let pattern_unsupported constructor reason suggestion =
    [ unsupported
        ~ctx ~origin ~constructor
        ~source_echo:(source_echo_exp exp)
        ~reason
        ~suggestion
        ()
    ]
  in
  match exp.note.it with
  | VarT _ ->
    (match Typcase_constructor.resolve_emitted ctx exp.note mixop ~arity with
    | Typcase_constructor.Found resolution ->
      Some resolution.Typcase_constructor.resolved_constructor, []
    | Typcase_constructor.Missing ->
      None,
      pattern_unsupported
        "Pattern/CaseE"
        "constructor case has no emitted TypD constructor registry entry, so pattern lowering refuses to call an undeclared Maude operator"
        "Keep this constructor pattern Unsupported until the corresponding TypD case can be emitted source-safely"
    | Typcase_constructor.Blocked reason ->
      None,
      pattern_unsupported
        "Pattern/CaseE"
        reason
        "Keep this constructor pattern Unsupported until the corresponding TypD case can be emitted source-safely"
    | Typcase_constructor.Ambiguous resolutions ->
      let constructors =
        List.map
          (fun resolution ->
            resolution.Typcase_constructor.resolved_constructor)
          resolutions
      in
      None,
      pattern_unsupported
        "Pattern/CaseE"
        (Printf.sprintf
           "constructor registry found %d emitted TypD constructor candidates for this category/arity, so pattern lowering refuses to guess: %s"
           (List.length constructors)
           (String.concat ", " constructors))
        "Keep this constructor pattern Unsupported until the source category has a unique emitted-safe constructor for this arity")
  | _ ->
    None,
    pattern_unsupported
      "Pattern/CaseE"
      "constructor pattern lowering requires a VarT result category on the CaseE note"
      "Preserve the source category witness before lowering this constructor pattern"

let pattern_result_to_expr_pattern (result : Pattern_translate.result) =
  let introduced_bindings =
    result.introduced_bindings
    |> List.map (fun (id, (binding : Pattern_translate.binding)) ->
      id, { term = binding.term; sort = binding.sort; typ = binding.typ })
  in
  { pattern_term = result.term
  ; pattern_guards = result.guards
  ; introduced_bindings
  ; pattern_diagnostics = result.diagnostics
  }

let lower_pattern_raw names callbacks ctx env origin exp =
  let pattern_callbacks : Pattern_translate.callbacks =
    { find_var =
        (fun id ->
          match Expr_env.find env id with
          | None -> None
          | Some binding ->
            Some
              { Pattern_translate.term = binding.term
              ; sort = binding.sort
              ; typ = binding.typ
              })
    ; bound_vars = Expr_env.bound_vars env
    ; lower_guard_value =
        (fun origin exp ->
          let result = callbacks.lower_value ctx env origin exp in
          { Pattern_translate.term = result.term
          ; guards = result.guards
          ; introduced_bindings = []
          ; diagnostics = result.diagnostics
          })
    ; carrier_sort_of_typ
    ; is_nat_typ = Carrier_sort.typ_is_nat ctx
    ; witness_of_typ =
        (fun ~constructor origin typ ->
          let result =
            callbacks.witness_of_typ_with_guards ctx env origin ~constructor typ
          in
          ( result.witness_term
          , result.witness_guards
          , result.witness_diagnostics ))
    ; case_constructor = pattern_case_constructor ctx
    }
  in
  Pattern_translate.lower_with_names names ctx pattern_callbacks origin exp

let rec lower_value ctx env origin exp =
  match exp.it with
  | VarE id ->
    (match Expr_env.find env id.it with
    | Some binding -> with_term binding.term
    | None ->
      unsupported_exp ctx origin "Expr/VarE" exp
        ("unbound variable `" ^ id.it ^ "` in expression lowering"))
  | BoolE b -> with_term (Primitive_term.bool (Const (string_of_bool b)))
  | NumE n -> literal_num_value ctx origin exp n
  | TextE text -> with_term (Primitive_term.text text)
  | UnE (`NotOp, _, _) ->
    lower_bool_value ctx env origin exp
  | UnE (op, _, exp1) ->
    lower_unary_value ctx env origin exp (Il.Print.string_of_unop op) exp1
  | BinE ((`AndOp | `OrOp | `ImplOp | `EquivOp), _, _, _) ->
    lower_bool_value ctx env origin exp
  | BinE (`ModOp, _, left, right) ->
    lower_binary_value ctx env origin exp "\\" left right
  | BinE (op, _, left, right) ->
    lower_binary_value ctx env origin exp (Il.Print.string_of_binop op) left right
  | CmpE _ ->
    lower_bool_value ctx env origin exp
  | ProjE (inner, index) ->
    lower_projection ctx env origin exp inner index
  | CaseE (mixop, arg_exp) ->
    lower_case ctx env origin exp mixop arg_exp
  | UncaseE (inner, mixop) ->
    lower_uncase ctx env origin exp inner mixop
  | ListE exps ->
    lower_list ctx env origin exp exps
  | CatE (left, right) ->
    lower_cat ctx env origin exp left right
  | OptE opt ->
    lower_opt ctx env origin exp opt
  | LiftE inner ->
    lower_lift ctx env origin exp inner
  | StrE fields ->
    lower_record_literal ctx env origin exp fields
  | DotE (record, atom) ->
    lower_record_dot ctx env origin record atom
  | CompE (left, right) ->
    lower_comp ctx env origin left right
  | LenE inner ->
    lower_len ctx env origin inner
  | IdxE (base, index) ->
    lower_index ctx env origin exp base index
  | SliceE (base, first, last) ->
    lower_slice ctx env origin base first last
  | UpdE (record, path, replacement) ->
    lower_record_update ctx env origin exp record path replacement
  | ExtE (record, path, extension) ->
    lower_record_extension ctx env origin exp record path extension
  | CallE (id, args) ->
    lower_call ctx env origin exp id args
  | IterE (body, iterexp) ->
    lower_iter ctx env origin exp body iterexp
  | MemE (left, right) ->
    lower_mem_value ctx env origin exp left right
  | TupE exps ->
    lower_tuple ctx env origin exp exps
  | IfE _ ->
    unsupported_exp ctx origin "Expr/IfE" exp
      "IfE lowering is not implemented in this pure DecD slice"
  | CvtE (inner, source_typ, target_typ) ->
    lower_numeric_conversion ctx env origin exp inner source_typ target_typ
  | SubE (inner, source_typ, target_typ) ->
    lower_numeric_subtyping ctx env origin exp inner source_typ target_typ
  | TheE _ ->
    unsupported_exp ctx origin "Expr" exp
      "this expression constructor is outside the conservative pure DecD slice"

and witness_of_typ_with_guards ctx env origin constructor typ =
  lower_type_witness_impl ~lower_value ctx env origin constructor typ

and lower_type_witness ctx env origin ~constructor typ =
  let result =
    lower_type_witness_impl ~lower_value ctx env origin constructor typ
  in
  { term = result.witness_term
  ; guards = result.witness_guards
  ; diagnostics = result.witness_diagnostics
  }

and witness_of_typ_for ctx env origin constructor typ =
  let result = witness_of_typ_with_guards ctx env origin constructor typ in
  match result.witness_guards with
  | [] -> result.witness_term, result.witness_diagnostics
  | _ ->
    None,
    result.witness_diagnostics
    @ [ unsupported_witness
          ctx origin (constructor ^ "/type-witness/guarded")
          (Il.Print.string_of_typ typ)
          "this call site cannot preserve guards introduced by type witness arguments"
      ]

and witness_of_typ ctx env origin typ =
  witness_of_typ_for ctx env origin "Expr/SubE" typ

and category_guards_for_term ctx env origin constructor exp term typ =
  let witness_result =
    witness_of_typ_with_guards ctx env origin constructor typ
  in
  match carrier_sort_of_typ typ, witness_result.witness_term with
  | Some sort, Some witness ->
    Some
      (witness_result.witness_guards
       @ typecheck_conditions_for_typ typ sort term witness),
    witness_result.witness_diagnostics
  | None, _ ->
    None,
    witness_result.witness_diagnostics
    @ [ unsupported
          ~ctx ~origin ~constructor:(constructor ^ "/carrier")
          ~source_echo:(source_echo_exp exp)
          ~reason:
            "constructor category guard could not determine the carrier sort of the source result type"
          ~suggestion:
            "Keep this constructor expression Unsupported until its source type has a carrier-preserving encoding"
          ()
      ]
  | Some _, None ->
    None,
    witness_result.witness_diagnostics
    @ [ unsupported
          ~ctx ~origin ~constructor:(constructor ^ "/witness")
          ~source_echo:(source_echo_exp exp)
          ~reason:
            "constructor category guard could not lower the source result type witness"
          ~suggestion:
            "Extend witness lowering before emitting this constructor expression"
          ()
      ]

and expr_bool_numeric_callbacks =
  { Expr_bool_numeric.lower_value
  ; lower_sequence
  ; lower_call
  ; witness_of_typ = (fun ctx env origin typ -> witness_of_typ ctx env origin typ)
  }

and lower_numeric_conversion ctx env origin exp inner source_typ target_typ =
  Expr_bool_numeric.lower_numeric_conversion expr_bool_numeric_callbacks ctx env origin exp inner source_typ target_typ

and lower_numeric_subtyping ctx env origin exp inner source_typ target_typ =
  Expr_subtyping.lower
    { Expr_subtyping.lower_value = lower_value; witness_of_typ }
    ctx env origin exp inner source_typ target_typ

and lower_bool_value ctx env origin exp =
  Expr_bool_numeric.lower_bool_value expr_bool_numeric_callbacks ctx env origin exp

and lower_unary_value ctx env origin exp op exp1 =
  Expr_bool_numeric.lower_unary_value expr_bool_numeric_callbacks ctx env origin exp op exp1

and lower_binary_value ctx env origin exp op left right =
  Expr_bool_numeric.lower_binary_value expr_bool_numeric_callbacks ctx env origin exp op left right

and lower_numeric_guard_value ctx env origin exp =
  Expr_bool_numeric.lower_numeric_guard_value expr_bool_numeric_callbacks ctx env origin exp

and lower_bool_raw ctx env origin exp =
  Expr_bool_numeric.lower_bool_raw expr_bool_numeric_callbacks ctx env origin exp

and lower_mem_value ctx env origin exp left right =
  Expr_bool_numeric.lower_mem_value expr_bool_numeric_callbacks ctx env origin exp left right

and lower_case ctx env origin _exp mixop arg_exp =
  lower_case_impl
    ~lower_value
    ~category_guards_for_term
    ctx env origin _exp mixop arg_exp

and expr_sequence_callbacks =
  { Expr_sequence.lower_value; lower_iter }

and lower_tuple ctx env origin exp exps =
  Expr_sequence.lower_tuple expr_sequence_callbacks ctx env origin exp exps

and lower_list ctx env origin exp exps =
  Expr_sequence.lower_list expr_sequence_callbacks ctx env origin exp exps

and lower_sequence ctx env origin exp =
  Expr_sequence.lower_sequence expr_sequence_callbacks ctx env origin exp

and lower_cat ctx env origin exp left right =
  Expr_sequence.lower_cat expr_sequence_callbacks ctx env origin exp left right

and lower_opt ctx env origin exp opt =
  Expr_sequence.lower_opt expr_sequence_callbacks ctx env origin exp opt

and lower_lift ctx env origin exp inner =
  Expr_sequence.lower_lift expr_sequence_callbacks ctx env origin exp inner

and lower_uncase_projection ctx env origin exp scrutinee mixop payload_typ index =
  lower_uncase_projection_impl
    ~lower_value
    ~category_guards_for_term
    ctx env origin exp scrutinee mixop payload_typ index

and lower_uncase ctx env origin exp scrutinee mixop =
  let arity = List.length (Type_shape.typ_components exp.note) in
  if arity = 1 then
    lower_uncase_projection ctx env origin exp scrutinee mixop exp.note 0
  else
    unsupported_exp ctx origin "Expr/UncaseE" exp
      "multi-field constructor destructor must be followed by an explicit ProjE so the source projection index is preserved"

and lower_projection ctx env origin exp inner index =
  match inner.it with
  | UncaseE (scrutinee, mixop) ->
    lower_uncase_projection ctx env origin exp scrutinee mixop inner.note index
  | _ ->
    unsupported_exp ctx origin "Expr/ProjE" exp
      "projection lowering is implemented only for source constructor destructors of the form e!C.i"

and expr_record_callbacks =
  { Expr_record.lower_value; lower_sequence }

and lower_record_literal ctx env origin exp fields =
  Expr_record.lower_record_literal expr_record_callbacks ctx env origin exp fields

and lower_record_dot ctx env origin record atom =
  Expr_record.lower_record_dot expr_record_callbacks ctx env origin record atom

and lower_comp ctx env origin left right =
  Expr_record.lower_comp expr_record_callbacks ctx env origin left right

and lower_len ctx env origin inner =
  Expr_record.lower_len expr_record_callbacks ctx env origin inner

and lower_index ctx env origin exp base index =
  Expr_record.lower_index expr_record_callbacks ctx env origin exp base index

and lower_slice ctx env origin base first last =
  Expr_record.lower_slice expr_record_callbacks ctx env origin base first last

and lower_record_update ctx env origin exp record path replacement =
  Expr_record.lower_record_update expr_record_callbacks ctx env origin exp record path replacement

and lower_record_extension ctx env origin exp record path extension =
  Expr_record.lower_record_extension expr_record_callbacks ctx env origin exp record path extension

and expr_iter_callbacks =
  { Expr_iter.lower_value; lower_sequence }

and lower_iter ctx env origin exp body iterexp =
  Expr_iter.lower_iter expr_iter_callbacks ctx env origin exp body iterexp

and lower_call ctx env origin exp id args =
  lower_call_impl ~lower_value ctx env origin exp id args

let pattern_callbacks =
  { lower_value
  ; witness_of_typ_with_guards =
      (fun ctx env origin ~constructor typ ->
        witness_of_typ_with_guards ctx env origin constructor typ)
  }

let lower_pattern_with_bindings_named names ctx env origin exp =
  let result, names =
    lower_pattern_raw names pattern_callbacks ctx env origin exp
  in
  pattern_result_to_expr_pattern result, names

let lower_bool_condition = lower_bool_raw
