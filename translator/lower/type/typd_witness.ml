open Il.Ast
open Maude_ir
open Util.Source

open Type_diagnostic

let app name args = App (name, args)

let text_wrapper text =
  app "text" [ Const ("\"" ^ String.escaped text ^ "\"") ]

let unsupported_numeric_static_arg ctx origin exp =
  None,
  [ unsupported
      ~ctx ~origin ~constructor:"TypD/arg/ExpA/NumE"
      ~source_echo:(Il.Print.string_of_exp exp)
      ~reason:
        "numeric static expression arguments are lowered only for Nat/Int literal carriers; Rat/Real or explicitly non-integral notes are not guessed"
      ~suggestion:
        "Track expected static argument types before lowering Rat/Real or non-numeric static expressions"
      ()
  ]

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

let unsupported_nested_iter_guard ctx origin constructor typ =
  unsupported
    ~ctx ~origin ~constructor
    ?source_echo:(source_echo_typ typ)
    ~reason:
      "nested sequence or optional-over-sequence carrier needs a boundary-preserving encoding; flattening to SpectecTerminals would erase source structure"
    ~suggestion:
      "Implement the nested sequence helper/monomorphized representation before lowering this type"
    ()

let rec terms_of_static_exps env ctx origin exps =
  let terms, diagnostics =
    exps
    |> List.map (term_of_static_exp env ctx origin)
    |> List.split
  in
  if List.for_all Option.is_some terms then
    Some (List.filter_map Fun.id terms), List.concat diagnostics
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
           ~source_category:(Naming.source_owner category_id)
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
              ~source_category:(Naming.source_owner category_id)
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
    (match Type_static_env.find_exp env id.it with
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
    (match Xl.Num.to_typ n, exp.note.it with
    | (`NatT | `IntT), NumT (`RatT | `RealT) ->
      unsupported_numeric_static_arg ctx origin exp
    | (`NatT | `IntT), _ -> Some (Const (Xl.Num.to_string n)), []
    | _ -> unsupported_numeric_static_arg ctx origin exp)
  | BoolE b -> Some (app "bool" [ Const (string_of_bool b) ]), []
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
    | Some terms -> Some (app (Context.definition_op ctx id) terms), diagnostics
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
  | TypA typ -> of_typ env ctx origin ~constructor:"TypD/arg/TypA" typ
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
    Some (List.filter_map Fun.id terms), List.concat diagnostics
  else
    None, List.concat diagnostics

and of_typ env ctx origin ~constructor typ =
  match typ.it with
  | VarT (id, args) ->
    (match args, Type_static_env.find_typ env id.it with
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
  | IterT (typ, (List | Opt)) when not (Type_shape.typ_is_iter typ) ->
    of_typ env ctx origin ~constructor typ
  | IterT ({ it = IterT (typ, (List | Opt)); _ }, (List | Opt))
    when not (Type_shape.typ_is_iter typ) ->
    of_typ env ctx origin ~constructor typ
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
