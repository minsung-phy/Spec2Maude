open Il.Ast
open Maude_ir
open Util.Source

type form =
  | Var_pattern
  | Literal_pattern
  | Constructor_pattern
  | Sequence_pattern
  | Optional_pattern
  | Coercion_pattern
  | Tuple_pattern
  | Record_pattern
  | Non_pattern of string

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
  { find_var : string -> binding option
  ; lower_guard_value : Origin.t -> exp -> result
  ; carrier_sort_of_typ : typ -> sort option
  ; is_nat_typ : typ -> bool
  ; witness_of_typ :
      constructor:string ->
      Origin.t ->
      typ ->
      term option * eq_condition list * Diagnostics.t list
  ; case_constructor :
      Origin.t -> exp -> mixop -> int -> string option * Diagnostics.t list
  }

let empty_result = { term = None; guards = []; introduced_bindings = []; diagnostics = [] }
let with_term term = { term = Some term; guards = []; introduced_bindings = []; diagnostics = [] }
let with_diagnostics diagnostics = { empty_result with diagnostics }
let result_term (result : result) = result.term
let result_guards (result : result) = result.guards
let result_diagnostics (result : result) = result.diagnostics
let result_bindings (result : result) = result.introduced_bindings

let s = sort
let spectec_terminals = s "SpectecTerminals"

let app name args = App (name, args)

let source_echo_exp exp =
  Il.Print.string_of_exp exp

let qid_of_atom atom =
  Qid (Xl.Atom.to_string atom)

let record_item atom value =
  app "item" [ qid_of_atom atom; value ]

let record_literal items =
  app "{_}" [ items ]

let record_items = function
  | [] -> Const "EMPTY"
  | hd :: tl -> List.fold_left (fun acc item -> app "_;_" [ acc; item ]) hd tl

let record_value atom record =
  app "value" [ qid_of_atom atom; record ]

let index base index =
  app "index" [ base; index ]

let classify exp =
  match exp.it with
  | VarE _ -> Var_pattern
  | BoolE _ | NumE _ | TextE _ -> Literal_pattern
  | CaseE _ -> Constructor_pattern
  | ListE _ | CatE _ | IterE _ -> Sequence_pattern
  | OptE _ -> Optional_pattern
  | CvtE _ | SubE _ -> Coercion_pattern
  | TupE _ -> Tuple_pattern
  | StrE _ -> Record_pattern
  | UnE _ -> Non_pattern "UnE"
  | BinE _ -> Non_pattern "BinE"
  | CmpE _ -> Non_pattern "CmpE"
  | ProjE _ -> Non_pattern "ProjE"
  | UncaseE _ -> Non_pattern "UncaseE"
  | TheE _ -> Non_pattern "TheE"
  | DotE _ -> Non_pattern "DotE"
  | CompE _ -> Non_pattern "CompE"
  | LiftE _ -> Non_pattern "LiftE"
  | MemE _ -> Non_pattern "MemE"
  | LenE _ -> Non_pattern "LenE"
  | IdxE _ -> Non_pattern "IdxE"
  | SliceE _ -> Non_pattern "SliceE"
  | UpdE _ -> Non_pattern "UpdE"
  | ExtE _ -> Non_pattern "ExtE"
  | CallE _ -> Non_pattern "CallE"
  | IfE _ -> Non_pattern "IfE"

let form_name = function
  | Var_pattern -> "VarE"
  | Literal_pattern -> "literal"
  | Constructor_pattern -> "CaseE"
  | Sequence_pattern -> "sequence"
  | Optional_pattern -> "OptE"
  | Coercion_pattern -> "coercion"
  | Tuple_pattern -> "TupE"
  | Record_pattern -> "StrE"
  | Non_pattern name -> name

let unsupported ?suggestion ~ctx ~origin ~constructor ~reason ?source_echo () =
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin
    ~constructor
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason
    ?suggestion
    ?source_echo
    ()

let unsupported_pattern ctx origin constructor exp reason =
  with_diagnostics
    [ unsupported
        ~ctx ~origin ~constructor:("Pattern/" ^ constructor)
        ~source_echo:(source_echo_exp exp)
        ~reason
        ~suggestion:
          "Keep this pattern as Unsupported until a source-preserving pattern lowering rule is implemented"
        ()
    ]

let child_origin parent segment exp =
  Origin.with_child
    ~source_echo:(source_echo_exp exp)
    parent
    segment
    ~ast_constructor:"Pattern"
    exp.at

let append_result_metadata results =
  let guards = List.concat (List.map result_guards results) in
  let introduced_bindings = List.concat (List.map result_bindings results) in
  let diagnostics = List.concat (List.map result_diagnostics results) in
  guards, introduced_bindings, diagnostics

let is_sequence_sort sort =
  sort_name sort = sort_name spectec_terminals

let typecheck value typ =
  app "typecheck" [ value; typ ]

let typecheck_seq value typ =
  app "typecheckSeq" [ value; typ ]

let typecheck_for_sort sort value typ =
  if is_sequence_sort sort then typecheck_seq value typ else typecheck value typ

let len term =
  app "len" [ term ]

let all_len term n =
  app "allLen" [ term; n ]

let is_opt term =
  app "isOpt" [ term ]

let all_opt term =
  app "allOpt" [ term ]

let bool_wrapper term =
  app "bool" [ term ]

let text_literal text =
  app "text" [ Const ("\"" ^ String.escaped text ^ "\"") ]

let maude_numeric_literal num =
  match Xl.Num.to_string num with
  | text when String.length text > 0 && text.[0] = '+' ->
    String.sub text 1 (String.length text - 1)
  | text -> text

let literal_num_pattern ctx origin exp n =
  match Xl.Num.to_typ n with
  | `NatT | `IntT -> with_term (Const (maude_numeric_literal n))
  | `RatT | `RealT ->
    unsupported_pattern ctx origin "NumE" exp
      "Rat/Real numeric literal patterns need the verified primitive wrapper strategy before they can be matched safely"

let typ_is_iter typ =
  match typ.it with
  | IterT _ -> true
  | _ -> false

let is_flat_list_typ typ =
  match typ.it with
  | IterT (element_typ, List) -> not (typ_is_iter element_typ)
  | _ -> false

let is_flat_optional_typ typ =
  match typ.it with
  | IterT (element_typ, Opt) -> not (typ_is_iter element_typ)
  | _ -> false

let is_nested_list_typ typ =
  match typ.it with
  | IterT ({ it = IterT (element_typ, List); _ }, List) ->
    not (typ_is_iter element_typ)
  | _ -> false

let is_optional_list_typ typ =
  match typ.it with
  | IterT ({ it = IterT (element_typ, Opt); _ }, List) ->
    not (typ_is_iter element_typ)
  | _ -> false

let pattern_var_name origin id =
  if id.it = "_" then
    Naming.maude_var
      ("pattern-wild-"
       ^ String.concat "-" origin.Origin.path
       ^ "-"
       ^ Origin.source_location origin)
  else
    Naming.maude_var ("pattern-" ^ id.it)

let typed_pattern_var origin id sort =
  Var (pattern_var_name origin id ^ ":" ^ sort_name sort)

let guard_for_typ ctx callbacks origin constructor exp term typ =
  match callbacks.carrier_sort_of_typ typ with
  | None ->
    None,
    [ unsupported
        ~ctx ~origin ~constructor
        ~source_echo:(source_echo_exp exp)
        ~reason:
          "pattern carrier sort is not known, so emitting a Maude variable would guess the source shape"
        ~suggestion:
          "Add a source-preserving carrier for this IL type before lowering the pattern"
        ()
    ]
  | Some sort ->
    let witness_opt, witness_guards, witness_diagnostics =
      callbacks.witness_of_typ ~constructor origin typ
    in
    (match witness_opt with
    | Some witness ->
      Some (witness_guards @ [ BoolCond (typecheck_for_sort sort term witness) ]),
      witness_diagnostics
    | None ->
      None,
      witness_diagnostics
      @ [ unsupported
            ~ctx ~origin ~constructor
            ~source_echo:(source_echo_exp exp)
            ~reason:
              "pattern type witness could not be lowered, so the source category guard would be erased"
            ~suggestion:
              "Extend witness lowering before using this source type in a pattern"
            ()
        ])

let guard_for_lowered_pattern ctx callbacks origin constructor exp term =
  guard_for_typ ctx callbacks origin constructor exp term exp.note

let lower_bound_or_fresh_var ctx callbacks origin exp id =
  match callbacks.find_var id.it with
  | Some binding -> with_term binding.term
  | None ->
    (match callbacks.carrier_sort_of_typ exp.note with
    | None ->
      unsupported_pattern ctx origin "VarE" exp
        "unbound pattern variable has no safely known carrier in its IL note"
    | Some sort ->
      let term = typed_pattern_var origin id sort in
      let introduced_bindings =
        if id.it = "_" then [] else [ id.it, { term; sort; typ = exp.note } ]
      in
      { (with_term term) with introduced_bindings })

let rec lower ctx callbacks origin exp =
  match exp.it with
  | VarE id -> lower_bound_or_fresh_var ctx callbacks origin exp id
  | BoolE b -> with_term (bool_wrapper (Const (string_of_bool b)))
  | NumE n -> literal_num_pattern ctx origin exp n
  | TextE text -> with_term (text_literal text)
  | CaseE (mixop, arg_exp) -> lower_case ctx callbacks origin exp mixop arg_exp
  | ListE exps -> lower_list ctx callbacks origin exp exps
  | CatE (left, right) -> lower_cat ctx callbacks origin exp left right
  | OptE opt -> lower_opt ctx callbacks origin exp opt
  | IterE (body, iterexp) -> lower_iter ctx callbacks origin exp body iterexp
  | CvtE (inner, source_typ, target_typ) ->
    lower_numeric_conversion ctx callbacks origin exp inner source_typ target_typ
  | SubE (inner, _source_typ, target_typ) ->
    lower_subtyping ctx callbacks origin exp inner target_typ
  | TupE exps -> lower_tuple ctx callbacks origin exp exps
  | StrE fields -> lower_record ctx callbacks origin exp fields
  | DotE (record, atom) -> lower_dot ctx callbacks origin exp record atom
  | IdxE (base, index_exp) -> lower_idx ctx callbacks origin exp base index_exp
  | UnE _ | BinE _ | CmpE _ | ProjE _ | UncaseE _ | TheE _
  | CompE _ | LiftE _ | MemE _ | LenE _ | SliceE _ | UpdE _
  | ExtE _ | CallE _ | IfE _ ->
    unsupported_pattern ctx origin (form_name (classify exp)) exp
      "this expression constructor is not a documented safe pattern form for this slice"

and lower_dot ctx callbacks origin exp record atom =
  let record_result =
    callbacks.lower_guard_value (child_origin origin "dot-record" record) record
  in
  match record_result.term with
  | Some record_term ->
    { record_result with term = Some (record_value atom record_term) }
  | None ->
    { record_result with
      diagnostics =
        record_result.diagnostics
        @ [ unsupported
              ~ctx ~origin ~constructor:"Pattern/DotE"
              ~source_echo:(source_echo_exp exp)
              ~reason:
                "direct field projection pattern could not lower the record expression as an already-bound value"
              ~suggestion:
                "Keep this pattern Unsupported until the record side can be lowered without search"
              ()
          ]
    }

and lower_idx ctx callbacks origin exp base index_exp =
  let base_result =
    callbacks.lower_guard_value (child_origin origin "idx-base" base) base
  in
  let index_result =
    callbacks.lower_guard_value (child_origin origin "idx-index" index_exp) index_exp
  in
  let index_sort_diagnostics =
    if callbacks.is_nat_typ index_exp.note then
      []
    else
      [ unsupported
          ~ctx ~origin ~constructor:"Pattern/IdxE/index-sort"
          ~source_echo:(source_echo_exp exp)
          ~reason:
            "direct index projection pattern requires a Nat index because Maude prelude declares index : SpectecTerminals Nat -> SpectecTerminal"
          ~suggestion:
            "Keep this pattern Unsupported until the source index type is known to be Nat or a source-preserving numeric conversion is available"
          ()
      ]
  in
  let base_sort_diagnostics =
    match callbacks.carrier_sort_of_typ base.note with
    | Some sort when is_sequence_sort sort -> []
    | _ ->
      [ unsupported
          ~ctx ~origin ~constructor:"Pattern/IdxE/base-sort"
          ~source_echo:(source_echo_exp exp)
          ~reason:
            "direct index projection pattern requires a SpectecTerminals base because Maude prelude declares index : SpectecTerminals Nat -> SpectecTerminal"
          ~suggestion:
            "Keep this pattern Unsupported until the base expression is known to be a sequence"
          ()
      ]
  in
  match base_result.term, index_result.term with
  | Some base_term, Some index_term
    when index_sort_diagnostics = [] && base_sort_diagnostics = [] ->
    { term = Some (index base_term index_term)
    ; guards = base_result.guards @ index_result.guards
    ; introduced_bindings = []
    ; diagnostics = base_result.diagnostics @ index_result.diagnostics
    }
  | _ ->
    { term = None
    ; guards = base_result.guards @ index_result.guards
    ; introduced_bindings = []
    ; diagnostics =
        base_result.diagnostics @ index_result.diagnostics
        @ base_sort_diagnostics @ index_sort_diagnostics
        @ [ unsupported
              ~ctx ~origin ~constructor:"Pattern/IdxE"
              ~source_echo:(source_echo_exp exp)
              ~reason:
                "direct index projection pattern could not lower its base and index as already-bound values"
              ~suggestion:
                "Keep this pattern Unsupported until index projection can be represented without search/splitting"
              ()
          ]
    }

and lower_case ctx callbacks origin exp mixop arg_exp =
  let arg_exps =
    match arg_exp.it with
    | TupE exps -> exps
    | _ -> [ arg_exp ]
  in
  let arg_items =
    arg_exps
    |> List.mapi (fun index arg ->
      let arg_origin =
        child_origin origin (Printf.sprintf "case-arg[%d]" index) arg
      in
      arg, arg_origin, lower ctx callbacks arg_origin arg)
  in
  let arg_results = List.map (fun (_, _, result) -> result) arg_items in
  let guards, introduced_bindings, diagnostics = append_result_metadata arg_results in
  let terms = List.filter_map result_term arg_results in
  if List.length terms = List.length arg_results then
    let guarded_args =
      List.map2
        (fun (arg, arg_origin, _) term ->
          let guard_opt, guard_diagnostics =
            guard_for_lowered_pattern
              ctx callbacks arg_origin "Pattern/CaseE/arg" arg term
          in
          guard_opt, guard_diagnostics)
        arg_items terms
    in
    let arg_guards =
      guarded_args
      |> List.filter_map fst
      |> List.concat
    in
    let arg_guard_diagnostics =
      guarded_args |> List.map snd |> List.concat
    in
    let constructor_opt, constructor_diagnostics =
      callbacks.case_constructor origin exp mixop (List.length arg_results)
    in
    match constructor_opt with
    | Some constructor ->
      if List.for_all (fun (guard_opt, _) -> Option.is_some guard_opt) guarded_args then
        let constructor_term = app constructor terms in
        let whole_guard_opt, whole_guard_diagnostics =
          guard_for_lowered_pattern
            ctx callbacks origin "Pattern/CaseE/category" exp constructor_term
        in
        (match whole_guard_opt with
        | Some whole_guards ->
          { term = Some constructor_term
          ; guards = guards @ arg_guards @ whole_guards
          ; introduced_bindings
          ; diagnostics =
              diagnostics @ arg_guard_diagnostics @ whole_guard_diagnostics
              @ constructor_diagnostics
          }
        | None ->
          { term = None
          ; guards = guards @ arg_guards
          ; introduced_bindings
          ; diagnostics =
              diagnostics @ arg_guard_diagnostics @ whole_guard_diagnostics
              @ constructor_diagnostics
          })
      else
        { term = None
        ; guards
        ; introduced_bindings
        ; diagnostics =
            diagnostics @ arg_guard_diagnostics @ constructor_diagnostics
        }
    | None ->
      { term = None
      ; guards
      ; introduced_bindings
      ; diagnostics = diagnostics @ arg_guard_diagnostics @ constructor_diagnostics
      }
  else
    { term = None; guards; introduced_bindings; diagnostics }

and lower_tuple_component ctx callbacks origin exp =
  match callbacks.carrier_sort_of_typ exp.note with
  | Some sort when is_sequence_sort sort ->
    let result = lower_sequence ctx callbacks origin exp in
    (match result_term result with
    | Some term -> { result with term = Some (app "seq" [ term ]) }
    | None -> result)
  | _ -> lower ctx callbacks origin exp

and lower_record_field ctx callbacks origin (atom, field_exp) =
  let field_origin = child_origin origin (Xl.Atom.to_string atom) field_exp in
  let result =
    match callbacks.carrier_sort_of_typ field_exp.note with
    | Some sort when is_sequence_sort sort ->
      lower_sequence ctx callbacks field_origin field_exp
    | Some _ -> lower ctx callbacks field_origin field_exp
    | None ->
      unsupported_pattern ctx field_origin "StrE/field" field_exp
        "record pattern field has no safely known carrier sort"
  in
  atom, result

and lower_record ctx callbacks origin _exp fields =
  let results =
    fields
    |> List.map (lower_record_field ctx callbacks origin)
  in
  let guards =
    results
    |> List.map (fun (_atom, result) -> result.guards)
    |> List.concat
  in
  let introduced_bindings =
    results
    |> List.map (fun (_atom, result) -> result.introduced_bindings)
    |> List.concat
  in
  let diagnostics =
    results
    |> List.map (fun (_atom, result) -> result.diagnostics)
    |> List.concat
  in
  let items =
    results
    |> List.filter_map (fun (atom, result) ->
      match result.term with
      | Some term -> Some (record_item atom term)
      | None -> None)
  in
  if List.length items = List.length fields then
    { term = Some (record_literal (record_items items))
    ; guards
    ; introduced_bindings
    ; diagnostics
    }
  else
    { term = None; guards; introduced_bindings; diagnostics }

and lower_tuple ctx callbacks origin _exp exps =
  let results =
    exps
    |> List.mapi (fun index exp ->
      lower_tuple_component
        ctx callbacks
        (child_origin origin (Printf.sprintf "tuple[%d]" index) exp)
        exp)
  in
  let guards, introduced_bindings, diagnostics = append_result_metadata results in
  let terms = List.filter_map result_term results in
  if List.length terms = List.length results then
    let tuple_items =
      match terms with
      | [] -> Const "eps"
      | hd :: tl -> List.fold_left (fun acc term -> app "_ _" [ acc; term ]) hd tl
    in
    { term = Some (app "tuple" [ tuple_items ]); guards; introduced_bindings; diagnostics }
  else
    { term = None; guards; introduced_bindings; diagnostics }

and lower_list ctx callbacks origin exp exps =
  if is_nested_list_typ exp.note then
    lower_nested_list ctx callbacks origin exp exps
  else if is_optional_list_typ exp.note then
    lower_optional_list ctx callbacks origin exp exps
  else
    lower_flat_list ctx callbacks origin exps

and lower_flat_list ctx callbacks origin exps =
  match exps with
  | [] -> with_term (Const "eps")
  | _ ->
    let results =
      exps
      |> List.mapi (fun index exp ->
        lower ctx callbacks (child_origin origin (Printf.sprintf "list[%d]" index) exp) exp)
    in
    let guards, introduced_bindings, diagnostics = append_result_metadata results in
    let terms = List.filter_map result_term results in
    if List.length terms = List.length results then
      let term =
        match terms with
        | [] -> Const "eps"
        | hd :: tl -> List.fold_left (fun acc term -> app "_ _" [ acc; term ]) hd tl
      in
      { term = Some term; guards; introduced_bindings; diagnostics }
    else
      { term = None; guards; introduced_bindings; diagnostics }

and lower_sequence ctx callbacks origin exp =
  match exp.it with
  | VarE id ->
    (match callbacks.find_var id.it with
    | Some binding when is_sequence_sort binding.sort ->
      with_term binding.term
    | Some _ ->
      unsupported_pattern ctx origin "SequenceVarE" exp
        "bound variable pattern is not known to have a SpectecTerminals carrier"
    | None ->
      (match callbacks.carrier_sort_of_typ exp.note with
      | Some sort when is_sequence_sort sort ->
        lower_bound_or_fresh_var ctx callbacks origin exp id
      | _ ->
        unsupported_pattern ctx origin "SequenceVarE" exp
          "unbound sequence pattern variable does not have a safely known SpectecTerminals carrier"))
  | ListE exps -> lower_list ctx callbacks origin exp exps
  | CatE (left, right) -> lower_cat ctx callbacks origin exp left right
  | OptE opt -> lower_opt ctx callbacks origin exp opt
  | IterE (body, iterexp) -> lower_iter ctx callbacks origin exp body iterexp
  | _ ->
    (match callbacks.carrier_sort_of_typ exp.note with
    | Some sort when is_sequence_sort sort -> lower ctx callbacks origin exp
    | _ ->
      unsupported_pattern ctx origin "Sequence" exp
        "pattern is not known to have SpectecTerminals carrier, so sequence matching would be a guess")

and lower_cat ctx callbacks origin exp left right =
  let expected_sequence =
    match callbacks.carrier_sort_of_typ exp.note with
    | Some sort when is_sequence_sort sort -> []
    | _ ->
      [ unsupported
          ~ctx ~origin ~constructor:"Pattern/CatE"
          ~source_echo:(source_echo_exp exp)
          ~reason:
            "CatE pattern result is not known to have SpectecTerminals carrier"
          ~suggestion:
            "Track a sequence carrier before lowering this source CatE as a Maude sequence pattern"
          ()
      ]
  in
  let left_result = lower_sequence ctx callbacks (child_origin origin "cat-left" left) left in
  let right_result = lower_sequence ctx callbacks (child_origin origin "cat-right" right) right in
  match expected_sequence, left_result.term, right_result.term with
  | [], Some left_term, Some right_term ->
    { term = Some (app "_ _" [ left_term; right_term ])
    ; guards = left_result.guards @ right_result.guards
    ; introduced_bindings =
        left_result.introduced_bindings @ right_result.introduced_bindings
    ; diagnostics = left_result.diagnostics @ right_result.diagnostics
    }
  | _ ->
    { term = None
    ; guards = left_result.guards @ right_result.guards
    ; introduced_bindings =
        left_result.introduced_bindings @ right_result.introduced_bindings
    ; diagnostics = expected_sequence @ left_result.diagnostics @ right_result.diagnostics
    }

and lower_opt ctx callbacks origin exp opt =
  match callbacks.carrier_sort_of_typ exp.note with
  | Some sort when is_sequence_sort sort ->
    (match opt with
    | None -> with_term (Const "eps")
    | Some inner -> lower ctx callbacks (child_origin origin "opt-some" inner) inner)
  | _ ->
    unsupported_pattern ctx origin "OptE" exp
      "optional pattern lowering requires a non-nested optional carrier represented as eps or a singleton terminal"

and lower_nested_list ctx callbacks origin _exp exps =
  match exps with
  | [] -> with_term (Const "eps")
  | _ ->
    let lower_inner index inner =
      if is_flat_list_typ inner.note || is_flat_optional_typ inner.note then
        let result =
          lower_sequence
            ctx callbacks
            (child_origin origin (Printf.sprintf "nested-list[%d]" index) inner)
            inner
        in
        (match result.term with
        | Some term ->
          let guards =
            if is_flat_optional_typ inner.note then
              result.guards @ [ EqCond (is_opt term, Const "true") ]
            else
              result.guards
          in
          { result with term = Some (app "seq" [ term ]); guards }
        | None -> result)
      else
        unsupported_pattern ctx (child_origin origin (Printf.sprintf "nested-list[%d]" index) inner)
          "ListE/nested-element" inner
          "nested list pattern expects each outer element to be a flat list or flat optional sequence"
    in
    lower_sequence_elements lower_inner exps

and lower_optional_list ctx callbacks origin _exp exps =
  match exps with
  | [] -> with_term (Const "eps")
  | _ ->
    let lower_inner index inner =
      if is_flat_optional_typ inner.note then
        let result =
          lower_sequence
            ctx callbacks
            (child_origin origin (Printf.sprintf "optional-list[%d]" index) inner)
            inner
        in
        (match result.term with
        | Some term ->
          { result with
            term = Some (app "seq" [ term ])
          ; guards = result.guards @ [ EqCond (is_opt term, Const "true") ]
          }
        | None -> result)
      else
        unsupported_pattern ctx (child_origin origin (Printf.sprintf "optional-list[%d]" index) inner)
          "ListE/optional-list-element" inner
          "optional-list pattern expects each outer element to be a flat optional sequence"
    in
    lower_sequence_elements lower_inner exps

and lower_sequence_elements lower_inner exps =
  let results = List.mapi lower_inner exps in
  let guards, introduced_bindings, diagnostics = append_result_metadata results in
  let terms = List.filter_map result_term results in
  if List.length terms = List.length results then
    let term =
      match terms with
      | [] -> Const "eps"
      | hd :: tl -> List.fold_left (fun acc term -> app "_ _" [ acc; term ]) hd tl
    in
    { term = Some term; guards; introduced_bindings; diagnostics }
  else
    { term = None; guards; introduced_bindings; diagnostics }

and lower_iter ctx callbacks origin exp body (iter, generators) =
  match iter, generators, body.it with
  | List, [ generator_id, source_exp ], VarE body_id
    when body_id.it = generator_id.it && is_optional_list_typ exp.note ->
    lower_optional_list_identity ctx callbacks origin source_exp
  | List, [ generator_id, source_exp ], _
    when is_optional_list_typ exp.note && is_identity_optional_expr_over generator_id.it body ->
    lower_optional_list_identity ctx callbacks origin source_exp
  | List, [ generator_id, source_exp ], _
    when is_nested_list_typ exp.note && is_lifted_identity_optional_expr_over generator_id.it body ->
    lower_optional_list_identity ctx callbacks origin source_exp
  | List, [ generator_id, source_exp ], VarE body_id
    when body_id.it = generator_id.it ->
    lower_sequence ctx callbacks (child_origin origin "iter-source" source_exp) source_exp
  | List, [ generator_id, source_exp ], _
    when is_nested_list_typ exp.note && is_identity_list_expr_over generator_id.it body ->
    lower_sequence ctx callbacks (child_origin origin "iter-source" source_exp) source_exp
  | List, [ generator_id, source_exp ], _
    when is_nested_list_typ exp.note ->
    lower_nested_outer_identity_listn ctx callbacks origin exp generator_id.it source_exp body
  | ListN (n_exp, _), [ generator_id, source_exp ], VarE body_id
    when body_id.it = generator_id.it ->
    lower_flat_identity_listn ctx callbacks origin source_exp n_exp
  | Opt, [ generator_id, source_exp ], VarE body_id
    when body_id.it = generator_id.it ->
    lower_flat_identity_opt ctx callbacks origin source_exp
  | (Opt | List1), _, _ ->
    unsupported_pattern ctx origin "IterE" exp
      "Opt/List1 pattern iteration requires helper semantics outside this identity sequence slice"
  | ListN _, _, _ ->
    unsupported_pattern ctx origin "IterE" exp
      "only identity ListN pattern iteration over one known sequence generator is supported in this slice"
  | List, _, _ ->
    unsupported_pattern ctx origin "IterE" exp
      "only identity list pattern iteration VarE x over one generator x <- xs is supported in this slice"

and lower_optional_list_identity ctx callbacks origin source_exp =
  let source_result =
    lower_sequence ctx callbacks (child_origin origin "iter-source" source_exp) source_exp
  in
  match source_result.term with
  | Some source_term ->
    { term = Some source_term
    ; guards = source_result.guards @ [ EqCond (all_opt source_term, Const "true") ]
    ; introduced_bindings = source_result.introduced_bindings
    ; diagnostics = source_result.diagnostics
    }
  | None -> source_result

and lower_flat_identity_opt ctx callbacks origin source_exp =
  let source_result =
    lower_sequence ctx callbacks (child_origin origin "iter-source" source_exp) source_exp
  in
  match source_result.term with
  | Some source_term ->
    { term = Some source_term
    ; guards = source_result.guards @ [ EqCond (is_opt source_term, Const "true") ]
    ; introduced_bindings = source_result.introduced_bindings
    ; diagnostics = source_result.diagnostics
    }
  | None -> source_result

and lower_flat_identity_listn ctx callbacks origin source_exp n_exp =
  let source_result =
    lower_sequence ctx callbacks (child_origin origin "iter-source" source_exp) source_exp
  in
  let n_result =
    callbacks.lower_guard_value (child_origin origin "iter-length" n_exp) n_exp
  in
  match source_result.term, n_result.term with
  | Some source_term, Some n_term ->
    let len_term = len source_term in
    let len_condition =
      match n_term with
      | Var _ -> MatchCond (n_term, len_term)
      | _ -> EqCond (len_term, n_term)
    in
    { term = Some source_term
    ; guards = source_result.guards @ n_result.guards @ [ len_condition ]
    ; introduced_bindings =
        source_result.introduced_bindings @ n_result.introduced_bindings
    ; diagnostics = source_result.diagnostics @ n_result.diagnostics
    }
  | _ ->
    { term = None
    ; guards = source_result.guards @ n_result.guards
    ; introduced_bindings =
        source_result.introduced_bindings @ n_result.introduced_bindings
    ; diagnostics =
        source_result.diagnostics @ n_result.diagnostics
        @ [ unsupported
              ~ctx ~origin ~constructor:"Pattern/IterE"
              ~source_echo:(source_echo_exp source_exp)
              ~reason:
                "ListN identity pattern could not lower its source sequence or length expression"
              ~suggestion:
                "Keep this pattern Unsupported until both pieces can be lowered without guessing"
              ()
          ]
    }

and lower_nested_outer_identity_listn ctx callbacks origin exp outer_id source_exp body =
  match listn_body_over_outer outer_id body with
  | Some n_exp ->
    let source_result =
      lower_sequence ctx callbacks (child_origin origin "iter-source" source_exp) source_exp
    in
    let n_result =
      callbacks.lower_guard_value (child_origin origin "iter-length" n_exp) n_exp
    in
    (match source_result.term, n_result.term with
    | Some source_term, Some n_term ->
      { term = Some source_term
      ; guards =
          source_result.guards @ n_result.guards
          @ [ EqCond (all_len source_term n_term, Const "true") ]
      ; introduced_bindings =
          source_result.introduced_bindings @ n_result.introduced_bindings
      ; diagnostics = source_result.diagnostics @ n_result.diagnostics
      }
    | _ ->
      { term = None
      ; guards = source_result.guards @ n_result.guards
      ; introduced_bindings =
          source_result.introduced_bindings @ n_result.introduced_bindings
      ; diagnostics =
          source_result.diagnostics @ n_result.diagnostics
          @ [ unsupported
                ~ctx ~origin ~constructor:"Pattern/IterE"
                ~source_echo:(source_echo_exp exp)
                ~reason:
                  "nested ListN identity pattern could not lower its source sequence or length expression"
                ~suggestion:
                  "Keep this pattern Unsupported until both pieces can be lowered without guessing"
                ()
            ]
      })
  | None ->
    unsupported_pattern ctx origin "IterE" exp
      "nested List pattern is supported here only when its body is an identity ListN iteration over the current outer generator"

and is_identity_list_expr_over outer_id exp =
  match exp.it with
  | VarE id -> id.it = outer_id
  | IterE ({ it = VarE body_id; _ }, (List, [ generator_id, source_exp ])) ->
    body_id.it = generator_id.it
    && (match source_exp.it with
      | VarE source_id -> source_id.it = outer_id
      | _ -> false)
  | _ -> false

and is_identity_optional_expr_over outer_id exp =
  match exp.it with
  | IterE ({ it = VarE body_id; _ }, (Opt, [ generator_id, source_exp ]))
    when body_id.it = generator_id.it ->
    (match source_exp.it with
    | VarE source_id when source_id.it = outer_id -> true
    | _ -> false)
  | _ -> false

and is_lifted_identity_optional_expr_over outer_id exp =
  match exp.it with
  | LiftE inner -> is_identity_optional_expr_over outer_id inner
  | _ -> false

and listn_body_over_outer outer_id exp =
  match exp.it with
  | IterE ({ it = VarE body_id; _ }, (ListN (n_exp, _), [ generator_id, source_exp ]))
    when body_id.it = generator_id.it ->
    (match source_exp.it with
    | VarE source_id when source_id.it = outer_id -> Some n_exp
    | _ -> None)
  | _ -> None

and lower_numeric_conversion ctx callbacks origin exp inner source_typ target_typ =
  let preserves_runtime_representation =
    match source_typ, target_typ with
    | `NatT, `NatT | `IntT, `IntT | `NatT, `IntT -> true
    | `IntT, `NatT | `NatT, (`RatT | `RealT) | `IntT, (`RatT | `RealT)
    | (`RatT | `RealT), _ ->
      false
  in
  if preserves_runtime_representation then
    lower ctx callbacks (child_origin origin "cvt-inner" inner) inner
  else
    unsupported_pattern ctx origin "CvtE" exp
      "only representation-preserving numeric conversions are erased in pattern lowering; sign-changing, narrowing, Rat, and Real conversions need a verified carrier strategy"

and lower_subtyping ctx callbacks origin exp inner target_typ =
  let inner_result = lower ctx callbacks (child_origin origin "sub-inner" inner) inner in
  match inner_result.term with
  | None ->
    { inner_result with
      diagnostics =
        inner_result.diagnostics
        @ [ unsupported
              ~ctx ~origin ~constructor:"Pattern/SubE"
              ~source_echo:(source_echo_exp exp)
              ~reason:"SubE pattern could not lower its inner source pattern"
              ~suggestion:"Extend inner pattern lowering before preserving this coercion guard"
              ()
          ]
    }
  | Some term ->
    let guard_opt, diagnostics =
      guard_for_typ ctx callbacks origin "Pattern/SubE" exp term target_typ
    in
    (match guard_opt with
    | Some guards ->
      { term = Some term
      ; guards = inner_result.guards @ guards
      ; introduced_bindings = inner_result.introduced_bindings
      ; diagnostics = inner_result.diagnostics @ diagnostics
      }
    | None ->
      { term = None
      ; guards = inner_result.guards
      ; introduced_bindings = inner_result.introduced_bindings
      ; diagnostics = inner_result.diagnostics @ diagnostics
      })
