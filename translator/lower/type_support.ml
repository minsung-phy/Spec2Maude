open Il.Ast
open Maude_ir
open Util.Source

type result =
  { statements : generated list
  ; diagnostics : Diagnostics.t list
  }

type static_exp_binding =
  { static_term : term
  ; static_sort : sort
  ; static_typ : typ
  }

type static_env =
  { exp_vars : (string * static_exp_binding) list
  ; typ_vars : (string * term) list
  }

type component =
  { variable : string
  ; sort : sort
  ; typ : typ
  ; source_id : string option
  ; witness : term
  ; diagnostics : Diagnostics.t list
  }

type hidden_exp_bind =
  { hidden_source_id : string
  ; hidden_variable : string
  ; hidden_sort : sort
  ; hidden_typ : typ
  ; hidden_witness : term
  ; hidden_diagnostics : Diagnostics.t list
  }

let empty =
  { statements = []
  ; diagnostics = []
  }

let append left right =
  { statements = left.statements @ right.statements
  ; diagnostics = left.diagnostics @ right.diagnostics
  }

let with_diagnostics diagnostics =
  { empty with diagnostics }

let s = sort
let sr sort = sort_ref sort
let kr sort = kind_ref (kind_of_sort sort)

let spectec_terminal = s "SpectecTerminal"
let spectec_terminals = s "SpectecTerminals"
let spectec_type = s "SpectecType"

let app name args = App (name, args)

let category_name_of_target = function
  | Const name | App (name, _) ->
    let prefix = "syn-" in
    let prefix_len = String.length prefix in
    if String.length name > prefix_len
       && String.sub name 0 prefix_len = prefix
    then
      String.sub name prefix_len (String.length name - prefix_len)
    else
      name
  | Var name -> name
  | Qid name -> name

let register_constructor
    ctx origin
    ?(status = Constructor_registry.Emitted)
    ?(payload_witnesses = [])
    ?(payload_sorts = [])
    ?static_args_key
    ~target
    ~mixop
    ~arity
    ~constructor_op
    ~projection_ops
    () =
  let category = category_name_of_target target in
  Constructor_registry.register
    (Context.constructors ctx)
    { Constructor_registry.source_category = category
    ; declaring_category = category
    ; static_args_key
    ; mixop
    ; arity
    ; constructor_op
    ; projection_ops
    ; payload_witnesses
    ; payload_sorts
    ; origin
    ; enclosing = Context.enclosing_path ctx
    ; status
    }

let category_ref_of_typ key_env typ =
  Static_key.typ_ref ~env:key_env typ
  |> Option.map (fun ref ->
    Naming.source_slug ref.Static_key.category_id, ref.Static_key.static_args_key)

let register_category_inclusion
    ctx origin
    ~reason
    ~key_env
    ?parent_static_args_key
    ~target
    child_typ =
  match category_ref_of_typ key_env child_typ with
  | None -> ()
  | Some (child_category, child_static_args_key) ->
    let parent_category = category_name_of_target target in
    Constructor_registry.register_inclusion
      (Context.constructors ctx)
      { Constructor_registry.parent_category
      ; parent_static_args_key
      ; child_category
      ; child_static_args_key
      ; origin
      ; reason
      }

let typecheck value typ = app "typecheck" [ value; typ ]
let typecheck_seq value typ = app "typecheckSeq" [ value; typ ]
let typecheck_opt_seq value typ = app "typecheckOptSeq" [ value; typ ]
let typecheck_seq_opt value typ = app "typecheckSeqOpt" [ value; typ ]
let typecheck_nested_seq value typ = app "typecheckNestedSeq" [ value; typ ]
let typecheck_for_sort sort value typ =
  if sort_name sort = sort_name spectec_terminals then
    typecheck_seq value typ
  else
    typecheck value typ

let rec term_free_vars = function
  | Var name -> [ name ]
  | Const _ | Qid _ -> []
  | App (_, args) ->
    args
    |> List.map term_free_vars
    |> List.concat
    |> List.fold_left
         (fun vars name -> if List.mem name vars then vars else name :: vars)
         []

let condition_free_vars = function
  | EqCond (left, right) | MatchCond (left, right) ->
    term_free_vars left @ term_free_vars right
  | MembershipCond (term, _) | BoolCond term -> term_free_vars term

let vars_subset vars bound =
  List.for_all (fun name -> List.mem name bound) vars

let add_bound_var vars name =
  if List.mem name vars then vars else name :: vars

let add_bound_vars vars names =
  List.fold_left add_bound_var vars names

let gen origin node =
  generated ~origin node

let diagnostic ?suggestion ?source_echo ~category ~ctx ~origin ~constructor ~reason () =
  Diagnostics.make
    ?suggestion
    ?source_echo
    ~category
    ~origin
    ~constructor
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason
    ()

let unsupported ?suggestion ?source_echo ~ctx ~origin ~constructor ~reason () =
  diagnostic
    ?suggestion
    ?source_echo
    ~category:Diagnostics.Unsupported
    ~ctx ~origin ~constructor ~reason ()

let skipped ?suggestion ?source_echo ~ctx ~origin ~constructor ~reason () =
  diagnostic
    ?suggestion
    ?source_echo
    ~category:Diagnostics.Skipped
    ~ctx ~origin ~constructor ~reason ()

let obligation ?suggestion ?source_echo ~ctx ~origin ~constructor ~reason () =
  diagnostic
    ?suggestion
    ?source_echo
    ~category:Diagnostics.Obligation
    ~ctx ~origin ~constructor ~reason ()

let child_origin parent segment ast_constructor region source_echo =
  Origin.with_child
    ?source_echo
    parent
    segment
    ~ast_constructor
    region

let source_echo_typ typ =
  Some (Il.Print.string_of_typ typ)

let source_echo_prem prem =
  Some (Il.Print.string_of_prem prem)

let source_echo_typcase (mixop, (typ, _quants, prems), _hints) =
  let prems =
    prems
    |> List.map Il.Print.string_of_prem
    |> String.concat "; "
  in
  let suffix = if prems = "" then "" else " -- " ^ prems in
  Some (Il.Print.string_of_mixop mixop ^ " " ^ Il.Print.string_of_typ typ ^ suffix)

let source_echo_typfield (atom, (typ, _quants, prems), _hints) =
  let prems =
    prems
    |> List.map Il.Print.string_of_prem
    |> String.concat "; "
  in
  let suffix = if prems = "" then "" else " -- " ^ prems in
  Some (Il.Print.string_of_atom atom ^ " " ^ Il.Print.string_of_typ typ ^ suffix)

let stable_seed origin fallback =
  let raw =
    match origin.Origin.path with
    | [] -> fallback
    | path -> String.concat "_" path ^ "_" ^ fallback
  in
  Naming.maude_var raw

let var_name seed role index =
  Printf.sprintf "%s%s%d" seed role index

let rec payload_source_id exp =
  match exp.it with
  | VarE id when id.it <> "_" -> Some id.it
  | IterE (body, ((List | Opt), [ generator_id, source_exp ]))
    when iter_body_preserves_generator generator_id.it body ->
    payload_source_id source_exp
  | LiftE inner ->
    (match inner.it with
    | IterE ({ it = VarE body_id; _ }, (Opt, [ generator_id, source_exp ]))
      when body_id.it = generator_id.it ->
      (match source_exp.it with
      | VarE source_id when source_id.it <> "_" -> Some source_id.it
      | _ -> None)
    | _ -> None)
  | SubE (inner, _, _) -> payload_source_id inner
  | _ -> None

and payload_source_matches expected exp =
  match payload_source_id exp with
  | Some id -> id = expected
  | None -> false

and iter_body_preserves_generator generator body =
  match body.it with
  | VarE id -> id.it = generator
  | IterE (inner, ((List | Opt), [ inner_generator, source_exp ])) ->
    payload_source_matches generator source_exp
    && iter_body_preserves_generator inner_generator.it inner
  | LiftE inner | SubE (inner, _, _) ->
    iter_body_preserves_generator generator inner
  | _ -> false

let variable_sort_suffix sort =
  match sort_name sort with
  | "SpectecTerminal" -> "term"
  | "SpectecTerminals" -> "terms"
  | name -> Naming.sanitize name

let var_name_from_exp seed role index exp sort =
  match payload_source_id exp with
  | Some id ->
    Naming.maude_var
      (id ^ "_" ^ variable_sort_suffix sort ^ "_" ^ role ^ string_of_int index)
  | None -> var_name seed role index

let lookup name bindings =
  List.assoc_opt name bindings

let numeric_literal_sort num =
  match Xl.Num.to_typ num with
  | `NatT | `IntT -> Some (Const (Xl.Num.to_string num))
  | `RatT | `RealT -> None

let exp_note_allows_nat_int_literal exp =
  match exp.note.it with
  | NumT (`RatT | `RealT) -> false
  | _ -> true

let bool_wrapper term =
  app "bool" [ term ]

let text_wrapper text =
  app "text" [ Const ("\"" ^ String.escaped text ^ "\"") ]

let alias_projection_mixop : mixop = Xl.Mixop.Arg ()

let mixop_is_hole_only = Type_shape.mixop_is_hole_only

let qid_of_atom atom =
  Xl.Atom.to_string atom

let typ_components = Type_shape.typ_components

let unsupported_iter_guard ctx origin constructor typ iter =
  let iter_text = Il.Print.string_of_iter iter in
  unsupported
    ~ctx ~origin ~constructor
    ?source_echo:(source_echo_typ typ)
    ~reason:
      ("iteration guard " ^ iter_text
       ^ " needs a generic non-empty, singleton, or length-preserving sequence encoding; "
       ^ "lowering it to plain element-wise typecheck would be unsound")
    ~suggestion:"Add the sequence guard helper required by docs/IMPLEMENTATION_PLAN_V2.md before lowering this case"
    ()

let typ_is_iter = Type_shape.typ_is_iter

let is_flat_list_typ = Type_shape.is_flat_list_typ

let is_flat_optional_typ = Type_shape.is_flat_optional_typ

let is_nested_list_typ = Type_shape.is_nested_list_typ

let is_optional_list_typ = Type_shape.is_optional_list_typ

let is_list_optional_typ = Type_shape.is_list_optional_typ

let primitive_numeric_alias_sort ctx typ =
  let rec resolve visited typ =
    match typ.it with
    | NumT `NatT -> Some (s "Nat")
    | NumT `IntT -> Some (s "Int")
    | VarT (id, []) when not (List.mem id.it visited) ->
      let entries = Analysis.Source_index.find_by_id (Context.source_index ctx) id.it in
      entries
      |> List.find_map (fun entry ->
        match entry.Analysis.Source_index.def.it with
        | TypD (_, [], [ inst ]) ->
          (match inst.it with
          | InstD ([], [], { it = AliasT alias_typ; _ }) ->
            resolve (id.it :: visited) alias_typ
          | _ -> None)
        | _ -> None)
    | _ -> None
  in
  resolve [] typ

let unsupported_nested_iter_guard ctx origin constructor typ =
  unsupported
    ~ctx ~origin ~constructor
    ?source_echo:(source_echo_typ typ)
    ~reason:
      "nested sequence or optional-over-sequence carrier needs a boundary-preserving encoding; flattening to SpectecTerminals would erase source structure"
    ~suggestion:
      "Implement the nested sequence helper/monomorphized representation before lowering this type"
    ()

let carrier_sort_of_typ ctx origin constructor typ =
  match primitive_numeric_alias_sort ctx typ with
  | Some sort -> Some sort, []
  | None ->
  match typ.it with
  | BoolT | NumT `RatT | NumT `RealT | TextT | VarT _ ->
    Some spectec_terminal, []
  | NumT `NatT -> Some (s "Nat"), []
  | NumT `IntT -> Some (s "Int"), []
  | _ when is_flat_list_typ typ || is_flat_optional_typ typ || is_nested_list_typ typ
           || is_optional_list_typ typ || is_list_optional_typ typ ->
    Some spectec_terminals, []
  | IterT (_, (List | Opt)) ->
    None, [ unsupported_nested_iter_guard ctx origin constructor typ ]
  | IterT (_, ((List1 | ListN _) as iter)) ->
    None, [ unsupported_iter_guard ctx origin constructor typ iter ]
  | TupT _ ->
    None,
    [ unsupported
        ~ctx ~origin ~constructor
        ?source_echo:(source_echo_typ typ)
        ~reason:"tuple/config carrier lowering is not part of Milestone A"
        ~suggestion:"Add the source-preserving tuple/config encoding from the plan before lowering this type"
        ()
    ]

let payload_matches_exp_bind bind_id (payload, _typ) =
  match payload_source_id payload with
  | Some payload_id -> payload_id = bind_id.it
  | None -> false

let exp_mentions_var id exp =
  Il.Free.Set.mem id (Il.Free.free_exp exp).varid

let rec exp_is_var id exp =
  match exp.it with
  | VarE var_id -> var_id.it = id
  | SubE (inner, _, _) | CvtE (inner, _, _) -> exp_is_var id inner
  | _ -> false

let hidden_bind_rhs_from_equality bind_id left right =
  if exp_is_var bind_id left && not (exp_mentions_var bind_id right) then
    Some right
  else if exp_is_var bind_id right && not (exp_mentions_var bind_id left) then
    Some left
  else
    None

let rec hidden_bind_extract_from_exp bind_id exp =
  match exp.it with
  | CmpE (`EqOp, _, left, right) ->
    hidden_bind_rhs_from_equality bind_id left right
    |> Option.map (fun rhs -> rhs, [])
  | BinE (`AndOp, _, left, right) ->
    (match
       hidden_bind_extract_from_exp bind_id left,
       hidden_bind_extract_from_exp bind_id right
     with
    | Some (rhs, residuals), None -> Some (rhs, residuals @ [ right ])
    | None, Some (rhs, residuals) -> Some (rhs, left :: residuals)
    | None, None | Some _, Some _ -> None)
  | _ -> None

let hidden_bind_extract_from_prem bind_id prem =
  match prem.it with
  | IfPr exp -> hidden_bind_extract_from_exp bind_id exp
  | LetPr (_quants, lhs, rhs) ->
    hidden_bind_rhs_from_equality bind_id lhs rhs
    |> Option.map (fun rhs -> rhs, [])
  | RulePr _ | ElsePr | IterPr _ | NegPr _ -> None

let hidden_exp_bind_supported bind_id components prems =
  (not (List.exists (payload_matches_exp_bind bind_id) components))
  && List.exists (fun prem -> Option.is_some (hidden_bind_extract_from_prem bind_id.it prem)) prems

let rec terms_of_static_exps env ctx origin exps =
  let terms, diagnostics =
    exps
    |> List.map (term_of_static_exp env ctx origin)
    |> List.split
  in
  if List.for_all Option.is_some terms then
    Some (List.map Option.get terms), List.concat diagnostics
  else
    None, List.concat diagnostics

and static_case_args env ctx origin arg_exp =
  match arg_exp.it with
  | TupE exps -> terms_of_static_exps env ctx origin exps
  | _ ->
    let term, diagnostics = term_of_static_exp env ctx origin arg_exp in
    (match term with
    | Some term -> Some [ term ], diagnostics
    | None -> None, diagnostics)

and lower_static_case env ctx origin exp mixop arg_exp =
  let args_opt, diagnostics = static_case_args env ctx origin arg_exp in
  match args_opt with
  | None -> None, diagnostics
  | Some args ->
    let arity = List.length args in
    let key_env = Static_key.of_static_typ_env (Context.static_typ_env ctx) in
    (match Static_key.typ_ref ~env:key_env exp.note with
    | Some { Static_key.category_id; static_args_key } ->
      (match
         Constructor_registry.lookup_emitted
           (Context.constructors ctx)
           ~source_category:(Naming.source_slug category_id)
           ~static_args_key
           ~mixop
           ~arity
       with
      | Constructor_registry.Found entry ->
        Some (app entry.Constructor_registry.constructor_op args), diagnostics
      | Constructor_registry.Missing ->
        let reason =
          match
            Constructor_registry.lookup_visible
              (Context.constructors ctx)
              ~source_category:(Naming.source_slug category_id)
              ~static_args_key
              ~mixop
              ~arity
          with
          | Constructor_registry.Found entry ->
            Printf.sprintf
              "matching TypD constructor exists but is registered as %s at %s"
              (Constructor_registry.status_to_string entry.Constructor_registry.status)
              (Origin.summary entry.Constructor_registry.origin)
          | Constructor_registry.Ambiguous _ ->
            "matching TypD constructor shape exists but is ambiguous or not emitted"
          | Constructor_registry.Missing ->
            "static CaseE argument has no emitted TypD constructor registry entry"
        in
        None,
        diagnostics
        @ [ unsupported
              ~ctx ~origin ~constructor:"TypD/arg/ExpA/CaseE"
              ~source_echo:(Il.Print.string_of_exp exp)
              ~reason
              ~suggestion:
                "Keep this type-family argument Unsupported until the source TypD constructor can be emitted and registered source-safely"
              ()
          ]
      | Constructor_registry.Ambiguous entries ->
        None,
        diagnostics
        @ [ unsupported
              ~ctx ~origin ~constructor:"TypD/arg/ExpA/CaseE/ambiguous"
              ~source_echo:(Il.Print.string_of_exp exp)
              ~reason:
                (Printf.sprintf
                   "static CaseE argument matches multiple emitted constructors: %s"
                   (entries
                    |> List.map (fun entry -> entry.Constructor_registry.constructor_op)
                    |> List.sort_uniq String.compare
                    |> String.concat ", "))
              ~suggestion:
                "Refine the static specialization key instead of guessing which constructor to call"
              ()
          ])
    | None ->
      None,
      diagnostics
      @ [ unsupported
            ~ctx ~origin ~constructor:"TypD/arg/ExpA/CaseE"
            ~source_echo:(Il.Print.string_of_exp exp)
            ~reason:
              "static CaseE argument needs a VarT result category so its constructor name can be tied back to a source TypD"
            ~suggestion:
              "Preserve the source type witness before lowering this static constructor argument"
            ()
        ])

and term_of_static_exp env ctx origin exp =
  match exp.it with
  | VarE id ->
    (match lookup id.it env.exp_vars with
    | Some binding -> Some binding.static_term, []
    | None ->
      None,
      [ unsupported
          ~ctx ~origin ~constructor:"TypD/arg/ExpA"
          ~source_echo:(Il.Print.string_of_exp exp)
          ~reason:
            ("static expression argument refers to unbound value variable `" ^ id.it ^ "`")
          ~suggestion:"Implement finite static-argument specialization before using this expression as a witness argument"
          ()
      ])
  | NumE n ->
    (match numeric_literal_sort n, exp_note_allows_nat_int_literal exp with
    | Some term, true -> Some term, []
    | _ ->
      None,
      [ unsupported
          ~ctx ~origin ~constructor:"TypD/arg/ExpA/NumE"
          ~source_echo:(Il.Print.string_of_exp exp)
          ~reason:
            "numeric static expression arguments are lowered only for Nat/Int literal carriers; Rat/Real or explicitly non-integral notes are not guessed"
          ~suggestion:
            "Track expected static argument types before lowering Rat/Real or non-numeric static expressions"
          ()
      ])
  | BoolE b -> Some (bool_wrapper (Const (string_of_bool b))), []
  | TextE text -> Some (text_wrapper text), []
  | ListE exps ->
    let terms_opt, diagnostics = terms_of_static_exps env ctx origin exps in
    (match terms_opt with
    | Some [] -> Some (Const "eps"), diagnostics
    | Some (hd :: tl) ->
      Some (List.fold_left (fun acc term -> app "_ _" [ acc; term ]) hd tl),
      diagnostics
    | None -> None, diagnostics)
  | OptE None -> Some (Const "eps"), []
  | OptE (Some inner) -> term_of_static_exp env ctx origin inner
  | LiftE inner -> term_of_static_exp env ctx origin inner
  | CaseE (mixop, arg_exp) ->
    lower_static_case env ctx origin exp mixop arg_exp
  | SubE (inner, _, _) | CvtE (inner, _, _) ->
    term_of_static_exp env ctx origin inner
  | CallE (id, args) ->
    let terms, diagnostics = terms_of_args env ctx origin args in
    (match terms with
    | Some terms -> Some (app (Naming.definition_op id) terms), diagnostics
    | None -> None, diagnostics)
  | _ ->
    None,
    [ unsupported
        ~ctx ~origin ~constructor:"TypD/arg/ExpA"
        ~source_echo:(Il.Print.string_of_exp exp)
        ~reason:"only variable and literal static expression arguments are supported in Milestone A"
        ~suggestion:"Lower this expression through the expression translator before using it in a category witness"
        ()
    ]

and term_of_arg env ctx origin arg =
  match arg.it with
  | ExpA exp -> term_of_static_exp env ctx origin exp
  | TypA typ -> witness_of_typ env ctx origin "TypD/arg/TypA" typ
  | DefA id ->
    None,
    [ unsupported
        ~ctx ~origin ~constructor:"TypD/arg/DefA"
        ~source_echo:id.it
        ~reason:"definition-valued static arguments require monomorphization, which is outside Milestone A"
        ~suggestion:"Implement static DefA specialization before lowering this type family instance"
        ()
    ]
  | GramA sym ->
    None,
    [ unsupported
        ~ctx ~origin ~constructor:"TypD/arg/GramA"
        ~source_echo:(Il.Print.string_of_sym sym)
        ~reason:"grammar-valued static arguments require monomorphization, which is outside Milestone A"
        ~suggestion:"Implement static GramA specialization before lowering this type family instance"
        ()
    ]

and terms_of_args env ctx origin args =
  let terms, diagnostics =
    args
    |> List.map (term_of_arg env ctx origin)
    |> List.split
  in
  if List.for_all Option.is_some terms then
    Some (List.map Option.get terms), List.concat diagnostics
  else
    None, List.concat diagnostics

and witness_of_typ env ctx origin constructor typ =
  match typ.it with
  | VarT (id, args) ->
    (match args, lookup id.it env.typ_vars with
    | [], Some term -> Some term, []
    | _ ->
      let terms, diagnostics = terms_of_args env ctx origin args in
      (match terms with
      | Some terms -> Some (app (Naming.category_witness id) terms), diagnostics
      | None -> None, diagnostics))
  | BoolT -> Some (Const (Naming.primitive_witness "bool")), []
  | NumT `NatT -> Some (Const (Naming.primitive_witness "nat")), []
  | NumT `IntT -> Some (Const (Naming.primitive_witness "int")), []
  | NumT `RatT -> Some (Const (Naming.primitive_witness "rat")), []
  | NumT `RealT -> Some (Const (Naming.primitive_witness "real")), []
  | TextT -> Some (Const (Naming.primitive_witness "text")), []
  | IterT (typ, (List | Opt)) when not (typ_is_iter typ) ->
    witness_of_typ env ctx origin constructor typ
  | IterT ({ it = IterT (typ, (List | Opt)); _ }, (List | Opt))
    when not (typ_is_iter typ) ->
    witness_of_typ env ctx origin constructor typ
  | IterT (_, (List | Opt)) ->
    None, [ unsupported_nested_iter_guard ctx origin constructor typ ]
  | IterT (_, ((List1 | ListN _) as iter)) ->
    None, [ unsupported_iter_guard ctx origin constructor typ iter ]
  | TupT _ ->
    None,
    [ unsupported
        ~ctx ~origin ~constructor
        ?source_echo:(source_echo_typ typ)
        ~reason:"tuple/config type witness lowering is not part of Milestone A"
        ~suggestion:"Preserve tuple payload shape through a tuple witness helper before lowering this case"
        ()
    ]

let guard_conditions_for_typ env ctx origin constructor typ sort value witness =
  ignore env;
  ignore ctx;
  ignore origin;
  ignore constructor;
  match typ.it with
  | IterT (inner, Opt) when not (typ_is_iter inner) ->
    [ BoolCond (app "isOpt" [ value ])
    ; BoolCond (typecheck_seq value witness)
    ], []
  | IterT ({ it = IterT (inner, Opt); _ }, List)
    when not (typ_is_iter inner) ->
    [ BoolCond (typecheck_opt_seq value witness) ], []
  | IterT ({ it = IterT (inner, List); _ }, Opt)
    when not (typ_is_iter inner) ->
    [ BoolCond (typecheck_seq_opt value witness) ], []
  | IterT ({ it = IterT (inner, List); _ }, List)
    when not (typ_is_iter inner) ->
    [ BoolCond (typecheck_nested_seq value witness) ], []
  | _ -> [ BoolCond (typecheck_for_sort sort value witness) ], []

let expr_env_of_static_env env =
  env.exp_vars
  |> List.fold_left
       (fun expr_env (id, binding) ->
         Expr_translate.add_var
           expr_env
           id
           { Expr_translate.term = binding.static_term
           ; sort = binding.static_sort
           ; typ = binding.static_typ
           })
       Expr_translate.empty_env
