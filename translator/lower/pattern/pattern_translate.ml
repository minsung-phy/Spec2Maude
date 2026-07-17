open Il.Ast
open Maude_ir
open Util.Source

module Request = Helper_request

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

type binding = Pattern_subtyping.binding =
  { term : term
  ; sort : sort
  ; typ : typ
  }

type result = Pattern_subtyping.result =
  { term : term option
  ; guards : eq_condition list
  ; introduced_bindings : (string * binding) list
  ; diagnostics : Diagnostics.t list
  }

type callbacks =
  { find_var : string -> binding option
  ; bound_vars : string list
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

let return names result = result, names

let rec lower_list_with_names lower names = function
  | [] -> [], names
  | item :: items ->
    let result, names = lower names item in
    let results, names = lower_list_with_names lower names items in
    result :: results, names

let fresh_pattern names sort =
  Local_name.fresh_typed names Local_name.Pattern sort

let s = sort
let spectec_terminals = s "SpectecTerminals"

let fresh_tail names =
  Local_name.fresh_qualified_name
    names Local_name.Tail (sort_ref spectec_terminals)

let app name args = App (name, args)

let source_echo_exp exp =
  Il.Print.string_of_exp exp

let qid_of_atom atom =
  Qid (Xl.Atom.to_string atom)

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
    ~enclosing:
      (Diagnostic_provenance.enclosing ~context:(Context.enclosing_path ctx) origin)
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

let dedup_guards guards =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | guard :: rest when List.mem guard seen -> loop seen acc rest
    | guard :: rest -> loop (guard :: seen) (guard :: acc) rest
  in
  loop [] [] guards

let is_sequence_sort sort =
  sort_name sort = sort_name spectec_terminals

let typecheck_conditions_for_typ typ sort value witness =
  match typ.it with
  | IterT (inner, Opt) when not (Type_shape.typ_is_iter inner) ->
    [ BoolCond (app "isOpt" [ value ])
    ; BoolCond (Typecheck_term.typecheck_seq value witness)
    ]
  | IterT ({ it = IterT (inner, Opt); _ }, List)
    when not (Type_shape.typ_is_iter inner) ->
    [ BoolCond (Typecheck_term.typecheck_opt_seq value witness) ]
  | IterT ({ it = IterT (inner, List); _ }, Opt)
    when not (Type_shape.typ_is_iter inner) ->
    [ BoolCond (Typecheck_term.typecheck_seq_opt value witness) ]
  | IterT ({ it = IterT (inner, List); _ }, List)
    when not (Type_shape.typ_is_iter inner) ->
    [ BoolCond (Typecheck_term.typecheck_nested_seq value witness) ]
  | _ -> [ BoolCond (Typecheck_term.typecheck_for_sort sort value witness) ]

let len term =
  app "len" [ term ]

let all_len term n =
  app "allLen" [ term; n ]

let is_opt term =
  app "isOpt" [ term ]

let all_opt term =
  app "allOpt" [ term ]

let bool_eq left right =
  app "_==_" [ left; right ]

let bool_or left right =
  app "_or_" [ left; right ]

let seq term = app "seq" [ term ]

let iter_pattern_zip_request
    ~source_shape
    ~subject_item_term
    ~subject_tail_var
    ~sources
    ~body_eq_conditions
    ~reason
    ~origin
  =
  { Request.kind =
      Request.Iter_pattern_zip
        { source_shape
        ; subject_item_term
        ; subject_tail_var
        ; sources
        ; body_eq_conditions
        }
  ; reason
  ; origin
  }

let literal_num_pattern ctx origin exp n =
  match Xl.Num.to_typ n with
  | `NatT | `IntT -> with_term (Primitive_term.number n)
  | `RatT | `RealT ->
    unsupported_pattern ctx origin "NumE" exp
      "Rat/Real numeric literal patterns need the verified primitive wrapper strategy before they can be matched safely"

type iter_source_descriptor =
  { source_item_shape : Request.iter_map_source_item_shape
  ; source_element_typ : typ
  ; source_element_sort : sort
  }

let iter_source_descriptor callbacks typ =
  let descriptor item_shape element_typ =
    match callbacks.carrier_sort_of_typ element_typ with
    | Some source_element_sort ->
      Some { source_item_shape = item_shape; source_element_typ = element_typ; source_element_sort }
    | None -> None
  in
  match typ.it with
  | IterT (element_typ, (List | List1 | ListN _))
    when not (Type_shape.typ_is_iter element_typ) ->
    descriptor Request.Source_flat_terminal element_typ
  | IterT
      (({ it = IterT (inner_typ, (List | Opt)); _ } as element_typ), (List | List1 | ListN _))
    when not (Type_shape.typ_is_iter inner_typ) ->
    descriptor Request.Source_nested_seq element_typ
  | _ -> None

let flat_subject_iter_typ typ =
  match typ.it with
  | IterT (element_typ, (List | List1 | ListN _))
    when not (Type_shape.typ_is_iter element_typ) ->
    Some element_typ
  | _ -> None

let typed_pattern_var names id sort =
  if id.it = "_" then
    fresh_pattern names sort
  else
    Local_name.source_qualified names id.it (sort_ref sort), names

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
      Some (witness_guards @ typecheck_conditions_for_typ typ sort term witness),
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

let lower_bound_or_fresh_var names ctx callbacks origin exp id =
  match callbacks.find_var id.it with
  | Some binding -> return names (with_term binding.term)
  | None ->
    (match callbacks.carrier_sort_of_typ exp.note with
    | None ->
      return names
        (unsupported_pattern ctx origin "VarE" exp
           "unbound pattern variable has no safely known carrier in its IL note")
    | Some sort ->
      let term, names = typed_pattern_var names id sort in
      let introduced_bindings =
        if id.it = "_" then [] else [ id.it, { term; sort; typ = exp.note } ]
      in
      { (with_term term) with introduced_bindings }, names)

let rec lower_internal names ctx callbacks origin exp =
  match exp.it with
  | VarE id -> lower_bound_or_fresh_var names ctx callbacks origin exp id
  | BoolE b ->
    return names (with_term (Primitive_term.bool (Const (string_of_bool b))))
  | NumE n -> return names (literal_num_pattern ctx origin exp n)
  | TextE text -> return names (with_term (Primitive_term.text text))
  | CaseE (mixop, arg_exp) -> lower_case names ctx callbacks origin exp mixop arg_exp
  | ListE exps -> lower_list names ctx callbacks origin exp exps
  | CatE (left, right) -> lower_cat names ctx callbacks origin exp left right
  | OptE opt -> lower_opt names ctx callbacks origin exp opt
  | IterE (body, iterexp) -> lower_iter names ctx callbacks origin exp body iterexp
  | CvtE (inner, source_typ, target_typ) ->
    lower_numeric_conversion names ctx callbacks origin exp inner source_typ target_typ
  | SubE (inner, source_typ, target_typ) ->
    Pattern_subtyping.lower_direct
      names
      ctx
      { bound_vars = callbacks.bound_vars
      ; lower_pattern = (fun names -> lower_internal names ctx callbacks)
      ; carrier_sort_of_typ = callbacks.carrier_sort_of_typ
      ; guard_for_typ =
          (fun origin ~constructor exp term typ ->
            guard_for_typ ctx callbacks origin constructor exp term typ)
      }
      origin exp inner source_typ target_typ
  | LiftE inner -> lower_lift names ctx callbacks origin exp inner
  | CallE _ -> lower_call_pattern names ctx callbacks origin exp
  | TupE exps -> lower_tuple names ctx callbacks origin exp exps
  | StrE fields -> lower_record names ctx callbacks origin exp fields
  | DotE (record, atom) -> lower_dot names ctx callbacks origin exp record atom
  | IdxE (base, index_exp) -> lower_idx names ctx callbacks origin exp base index_exp
  | UnE _ | BinE _ | CmpE _ | ProjE _ | UncaseE _ | TheE _
  | CompE _ | MemE _ | LenE _ | SliceE _ | UpdE _
  | ExtE _ | IfE _ ->
    return names
      (unsupported_pattern ctx origin (form_name (classify exp)) exp
         "this expression constructor is not a documented safe pattern form for this slice")

and lower_call_pattern names ctx callbacks origin exp =
  match callbacks.carrier_sort_of_typ exp.note with
  | None ->
    return names
      (unsupported_pattern ctx origin "CallE" exp
         "pattern CallE hoisting requires a known carrier sort for the function result")
  | Some sort ->
    let call_result = callbacks.lower_guard_value origin exp in
    (match call_result.term with
    | Some call_term ->
      let pattern_term, names = fresh_pattern names sort in
      ( { term = Some pattern_term
        ; guards = call_result.guards @ [ MatchCond (pattern_term, call_term) ]
        ; introduced_bindings = []
        ; diagnostics = call_result.diagnostics
        }
      , names )
    | None ->
      return names
        { term = None
        ; guards = call_result.guards
        ; introduced_bindings = []
        ; diagnostics =
            call_result.diagnostics
            @ [ unsupported
                  ~ctx ~origin ~constructor:"Pattern/CallE"
                  ~source_echo:(source_echo_exp exp)
                  ~reason:
                    "pattern CallE could not lower the function call as an already-bound value; inverse/search is not introduced in this direct hoisting slice"
                  ~suggestion:
                    "Keep this pattern Unsupported until the call arguments are bound or an explicit inverse helper is available"
                  ()
              ]
        })

and lower_lift names ctx callbacks origin exp inner =
  if Type_shape.is_flat_list_typ exp.note
     && Type_shape.is_flat_optional_typ inner.note
  then
    let result, names =
      lower_sequence names ctx callbacks (child_origin origin "lift-inner" inner) inner
    in
    (match result.term with
    | Some term ->
      { result with guards = result.guards @ [ EqCond (app "isOpt" [ term ], Const "true") ] }, names
    | None -> result, names)
  else
    return names
      (unsupported_pattern ctx origin "LiftE" exp
         "pattern LiftE is supported only for identity lifting from a flat optional carrier to a flat list carrier")

and lower_dot names ctx callbacks origin exp record atom =
  let record_result =
    callbacks.lower_guard_value (child_origin origin "dot-record" record) record
  in
  match record_result.term with
  | Some record_term ->
    { record_result with term = Some (record_value atom record_term) }, names
  | None ->
    ( { record_result with
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
    , names )

and lower_idx names ctx callbacks origin exp base index_exp =
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
    ( { term = Some (index base_term index_term)
      ; guards = base_result.guards @ index_result.guards
      ; introduced_bindings = []
      ; diagnostics = base_result.diagnostics @ index_result.diagnostics
      }
    , names )
  | _ ->
    ( { term = None
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
    , names )

and lower_case names ctx callbacks origin exp mixop arg_exp =
  let arg_exps =
    match arg_exp.it with
    | TupE exps -> exps
    | _ -> [ arg_exp ]
  in
  let indexed_args = List.mapi (fun index arg -> index, arg) arg_exps in
  let arg_items, names =
    lower_list_with_names
      (fun names (index, arg) ->
      let arg_origin =
        child_origin origin (Printf.sprintf "case-arg[%d]" index) arg
      in
      let result, names = lower_internal names ctx callbacks arg_origin arg in
      (arg, arg_origin, result), names)
      names indexed_args
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
          ( { term = Some constructor_term
            ; guards = guards @ arg_guards @ whole_guards
            ; introduced_bindings
            ; diagnostics =
                diagnostics @ arg_guard_diagnostics @ whole_guard_diagnostics
                @ constructor_diagnostics
            }
          , names )
        | None ->
          ( { term = None
            ; guards = guards @ arg_guards
            ; introduced_bindings
            ; diagnostics =
                diagnostics @ arg_guard_diagnostics @ whole_guard_diagnostics
                @ constructor_diagnostics
            }
          , names ))
      else
        ( { term = None
          ; guards
          ; introduced_bindings
          ; diagnostics =
              diagnostics @ arg_guard_diagnostics @ constructor_diagnostics
          }
        , names )
    | None ->
      ( { term = None
        ; guards
        ; introduced_bindings
        ; diagnostics = diagnostics @ arg_guard_diagnostics @ constructor_diagnostics
        }
      , names )
  else
    { term = None; guards; introduced_bindings; diagnostics }, names

and lower_tuple_component names ctx callbacks origin exp =
  match callbacks.carrier_sort_of_typ exp.note with
  | Some sort when is_sequence_sort sort ->
    let result, names = lower_sequence names ctx callbacks origin exp in
    (match result_term result with
    | Some term -> { result with term = Some (seq term) }, names
    | None -> result, names)
  | _ -> lower_internal names ctx callbacks origin exp

and lower_record_field names ctx callbacks origin (atom, field_exp) =
  let field_origin = child_origin origin (Xl.Atom.to_string atom) field_exp in
  let result, names =
    match callbacks.carrier_sort_of_typ field_exp.note with
    | Some sort when is_sequence_sort sort ->
      lower_sequence names ctx callbacks field_origin field_exp
    | Some _ -> lower_internal names ctx callbacks field_origin field_exp
    | None ->
      return names
        (unsupported_pattern ctx field_origin "StrE/field" field_exp
           "record pattern field has no safely known carrier sort")
  in
  (atom, result), names

and lower_record names ctx callbacks origin exp fields =
  match Record_shape.of_typ ctx exp.note with
  | Error error ->
    return names
      (unsupported_pattern ctx origin "StrE/type" exp
         (Record_shape.describe_error error))
  | Ok shape ->
    (match Record_shape.match_fields shape fields with
    | Error error ->
      return names
        (unsupported_pattern ctx origin "StrE/fields" exp
           (Record_shape.describe_error error))
    | Ok fields ->
      let results, names =
        lower_list_with_names
          (fun names (_, field) ->
            lower_record_field names ctx callbacks origin field)
          names fields
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
      let terms =
        results
        |> List.filter_map (fun (_atom, result) -> result.term)
      in
      if List.length terms = List.length fields then
        ( { term = Some (app (Naming.record_constructor shape.id) terms)
          ; guards
          ; introduced_bindings
          ; diagnostics
          }
        , names )
      else
        { term = None; guards; introduced_bindings; diagnostics }, names)

and lower_tuple names ctx callbacks origin _exp exps =
  let indexed_exps = List.mapi (fun index exp -> index, exp) exps in
  let results, names =
    lower_list_with_names
      (fun names (index, exp) ->
        lower_tuple_component names ctx callbacks
          (child_origin origin (Printf.sprintf "tuple[%d]" index) exp) exp)
      names indexed_exps
  in
  let guards, introduced_bindings, diagnostics = append_result_metadata results in
  let terms = List.filter_map result_term results in
  if List.length terms = List.length results then
    let tuple_items =
      match terms with
      | [] -> Const "eps"
      | hd :: tl -> List.fold_left (fun acc term -> app "_ _" [ acc; term ]) hd tl
    in
    { term = Some (app "tuple" [ tuple_items ]); guards; introduced_bindings; diagnostics }, names
  else
    { term = None; guards; introduced_bindings; diagnostics }, names

and lower_list names ctx callbacks origin exp exps =
  if Type_shape.is_nested_list_typ exp.note then
    lower_nested_list names ctx callbacks origin exp exps
  else if Type_shape.is_optional_list_typ exp.note then
    lower_optional_list names ctx callbacks origin exp exps
  else if Type_shape.is_list_optional_typ exp.note then
    lower_list_optional names ctx callbacks origin exps
  else
    lower_flat_list names ctx callbacks origin exps

and lower_flat_list names ctx callbacks origin exps =
  match exps with
  | [] -> return names (with_term (Const "eps"))
  | _ ->
    let indexed_exps = List.mapi (fun index exp -> index, exp) exps in
    let results, names =
      lower_list_with_names
        (fun names (index, exp) ->
          lower_internal names ctx callbacks
            (child_origin origin (Printf.sprintf "list[%d]" index) exp) exp)
        names indexed_exps
    in
    let guards, introduced_bindings, diagnostics = append_result_metadata results in
    let terms = List.filter_map result_term results in
    if List.length terms = List.length results then
      let term =
        match terms with
        | [] -> Const "eps"
        | hd :: tl -> List.fold_left (fun acc term -> app "_ _" [ acc; term ]) hd tl
      in
      { term = Some term; guards; introduced_bindings; diagnostics }, names
    else
      { term = None; guards; introduced_bindings; diagnostics }, names

and lower_list_optional names ctx callbacks origin exps =
  let result, names = lower_flat_list names ctx callbacks origin exps in
  match result.term with
  | Some term -> { result with term = Some (seq term) }, names
  | None -> result, names

and lower_sequence names ctx callbacks origin exp =
  match exp.it with
  | VarE id ->
    (match callbacks.find_var id.it with
    | Some binding when is_sequence_sort binding.sort ->
      return names (with_term binding.term)
    | Some _ ->
      return names
        (unsupported_pattern ctx origin "SequenceVarE" exp
           "bound variable pattern is not known to have a SpectecTerminals carrier")
    | None ->
      (match callbacks.carrier_sort_of_typ exp.note with
      | Some sort when is_sequence_sort sort ->
        lower_bound_or_fresh_var names ctx callbacks origin exp id
      | _ ->
        return names
          (unsupported_pattern ctx origin "SequenceVarE" exp
             "unbound sequence pattern variable does not have a safely known SpectecTerminals carrier")))
  | ListE exps -> lower_list names ctx callbacks origin exp exps
  | CatE (left, right) -> lower_cat names ctx callbacks origin exp left right
  | OptE opt -> lower_opt names ctx callbacks origin exp opt
  | IterE (body, iterexp) -> lower_iter names ctx callbacks origin exp body iterexp
  | _ ->
    (match callbacks.carrier_sort_of_typ exp.note with
    | Some sort when is_sequence_sort sort ->
      lower_internal names ctx callbacks origin exp
    | _ ->
      return names
        (unsupported_pattern ctx origin "Sequence" exp
           "pattern is not known to have SpectecTerminals carrier, so sequence matching would be a guess"))

and lower_cat names ctx callbacks origin exp left right =
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
  let left_result, names =
    lower_sequence names ctx callbacks (child_origin origin "cat-left" left) left
  in
  let right_result, names =
    lower_sequence names ctx callbacks (child_origin origin "cat-right" right) right
  in
  match expected_sequence, left_result.term, right_result.term with
  | [], Some left_term, Some right_term ->
    ( { term = Some (app "_ _" [ left_term; right_term ])
      ; guards = left_result.guards @ right_result.guards
      ; introduced_bindings =
          left_result.introduced_bindings @ right_result.introduced_bindings
      ; diagnostics = left_result.diagnostics @ right_result.diagnostics
      }
    , names )
  | _ ->
    ( { term = None
      ; guards = left_result.guards @ right_result.guards
      ; introduced_bindings =
          left_result.introduced_bindings @ right_result.introduced_bindings
      ; diagnostics = expected_sequence @ left_result.diagnostics @ right_result.diagnostics
      }
    , names )

and lower_opt names ctx callbacks origin exp opt =
  if Type_shape.is_list_optional_typ exp.note then
    match opt with
    | None -> return names (with_term (Const "eps"))
    | Some inner ->
      let result, names =
        lower_sequence names ctx callbacks
          (child_origin origin "opt-list-some" inner)
          inner
      in
      (match result.term with
      | Some term -> { result with term = Some (seq term) }, names
      | None -> result, names)
  else
  match callbacks.carrier_sort_of_typ exp.note with
  | Some sort when is_sequence_sort sort ->
    (match opt with
    | None -> return names (with_term (Const "eps"))
    | Some inner ->
      lower_internal names ctx callbacks (child_origin origin "opt-some" inner) inner)
  | _ ->
    return names
      (unsupported_pattern ctx origin "OptE" exp
         "optional pattern lowering requires a non-nested optional carrier represented as eps or a singleton terminal")

and lower_nested_list names ctx callbacks origin _exp exps =
  match exps with
  | [] -> return names (with_term (Const "eps"))
  | _ ->
    let lower_inner names (index, inner) =
      if Type_shape.is_flat_list_typ inner.note
         || Type_shape.is_flat_optional_typ inner.note
      then
        let result, names =
          lower_sequence names ctx callbacks
            (child_origin origin (Printf.sprintf "nested-list[%d]" index) inner)
            inner
        in
        (match result.term with
        | Some term ->
          let guards =
            if Type_shape.is_flat_optional_typ inner.note then
              result.guards @ [ EqCond (is_opt term, Const "true") ]
            else
              result.guards
          in
          { result with term = Some (seq term); guards }, names
        | None -> result, names)
      else
        return names
          (unsupported_pattern ctx (child_origin origin (Printf.sprintf "nested-list[%d]" index) inner)
             "ListE/nested-element" inner
             "nested list pattern expects each outer element to be a flat list or flat optional sequence")
    in
    lower_sequence_elements names lower_inner exps

and lower_optional_list names ctx callbacks origin _exp exps =
  match exps with
  | [] -> return names (with_term (Const "eps"))
  | _ ->
    let lower_inner names (index, inner) =
      if Type_shape.is_flat_optional_typ inner.note then
        let result, names =
          lower_sequence names ctx callbacks
            (child_origin origin (Printf.sprintf "optional-list[%d]" index) inner)
            inner
        in
        (match result.term with
        | Some term ->
          ( { result with
              term = Some (seq term)
            ; guards = result.guards @ [ EqCond (is_opt term, Const "true") ]
            }
          , names )
        | None -> result, names)
      else
        return names
          (unsupported_pattern ctx (child_origin origin (Printf.sprintf "optional-list[%d]" index) inner)
             "ListE/optional-list-element" inner
             "optional-list pattern expects each outer element to be a flat optional sequence")
    in
    lower_sequence_elements names lower_inner exps

and lower_sequence_elements names lower_inner exps =
  let indexed_exps = List.mapi (fun index exp -> index, exp) exps in
  let results, names = lower_list_with_names lower_inner names indexed_exps in
  let guards, introduced_bindings, diagnostics = append_result_metadata results in
  let terms = List.filter_map result_term results in
  if List.length terms = List.length results then
    let term =
      match terms with
      | [] -> Const "eps"
      | hd :: tl -> List.fold_left (fun acc term -> app "_ _" [ acc; term ]) hd tl
    in
    { term = Some term; guards; introduced_bindings; diagnostics }, names
  else
    { term = None; guards; introduced_bindings; diagnostics }, names

and lower_iter names ctx callbacks origin exp body (iter, generators) =
  let names =
    let ids = generators |> List.map (fun (id, _) -> id.it) in
    let ids =
      match iter with
      | ListN (_, Some id) -> id.it :: ids
      | Opt | List | List1 | ListN (_, None) -> ids
    in
    Local_name.reserve_sources names ids
  in
  match iter, generators, body.it with
  | Opt, [], _ ->
    lower_exact_optional_pattern names ctx callbacks origin exp body
  | List, [ generator_id, source_exp ], VarE body_id
    when body_id.it = generator_id.it
         && Type_shape.is_optional_list_typ exp.note ->
    lower_optional_list_identity names ctx callbacks origin source_exp
  | List, [ generator_id, source_exp ], _
    when Type_shape.is_optional_list_typ exp.note
         && is_identity_optional_expr_over generator_id.it body ->
    lower_optional_list_identity names ctx callbacks origin source_exp
  | List, [ generator_id, source_exp ], _
    when Type_shape.is_nested_list_typ exp.note
         && is_lifted_identity_optional_expr_over generator_id.it body ->
    lower_optional_list_identity names ctx callbacks origin source_exp
  | List, [ generator_id, source_exp ], VarE body_id
    when body_id.it = generator_id.it ->
    lower_sequence names ctx callbacks (child_origin origin "iter-source" source_exp) source_exp
  | List1, [ generator_id, source_exp ], VarE body_id
    when body_id.it = generator_id.it ->
    lower_nonempty_sequence names ctx callbacks origin source_exp
  | List, [ generator_id, source_exp ], _
    when is_source_preserving_iter_body generator_id.it body ->
    lower_sequence_with_target_guard
      names ctx callbacks origin exp generator_id.it body source_exp
  | List1, [ generator_id, source_exp ], _
    when is_source_preserving_iter_body generator_id.it body ->
    lower_nonempty_sequence_with_target_guard
      names ctx callbacks origin exp generator_id.it body source_exp
  | List, [ generator_id, source_exp ], _
    when Type_shape.is_nested_list_typ exp.note
         && is_identity_list_expr_over generator_id.it body ->
    lower_sequence names ctx callbacks (child_origin origin "iter-source" source_exp) source_exp
  | List, [ generator_id, source_exp ], _
    when Type_shape.is_nested_list_typ exp.note ->
    lower_nested_outer_identity_listn names ctx callbacks origin exp generator_id.it source_exp body
  | ListN (n_exp, _), [ generator_id, source_exp ], VarE body_id
    when body_id.it = generator_id.it ->
    lower_flat_identity_listn names ctx callbacks origin source_exp n_exp
  | ListN (n_exp, _), [ generator_id, source_exp ], _
    when is_source_preserving_iter_body generator_id.it body ->
    lower_flat_listn_with_target_guard
      names ctx callbacks origin exp generator_id.it body source_exp n_exp
  | List, generators, CaseE _ when generators <> [] ->
    lower_constructor_zip_iter_pattern names ctx callbacks origin exp body iter generators None
  | ListN (n_exp, None), generators, CaseE _ when generators <> [] ->
    lower_constructor_zip_iter_pattern names ctx callbacks origin exp body iter generators (Some n_exp)
  | ListN (_n_exp, Some _index_id), _, CaseE _ ->
    return names
      (unsupported_pattern ctx origin "IterE" exp
         "constructor pattern ListN with an index binder needs an index-aware pattern helper and remains outside this slice")
  | Opt, [ generator_id, source_exp ], VarE body_id
    when body_id.it = generator_id.it ->
    lower_flat_identity_opt names ctx callbacks origin source_exp
  | Opt, [ generator_id, source_exp ], _
    when Type_shape.is_list_optional_typ exp.note
         && is_identity_list_expr_over generator_id.it body ->
    lower_sequence names ctx callbacks (child_origin origin "iter-source" source_exp) source_exp
  | (Opt | List1), _, _ ->
    return names
      (unsupported_pattern ctx origin "IterE" exp
         "Opt/List1 pattern iteration requires helper semantics outside this identity sequence slice")
  | ListN _, _, _ ->
    return names
      (unsupported_pattern ctx origin "IterE" exp
         "only identity ListN pattern iteration over one known sequence generator is supported in this slice")
  | List, _, _ ->
    return names
      (unsupported_pattern ctx origin "IterE" exp
         "only identity list pattern iteration VarE x over one generator x <- xs is supported in this slice")

and binding_for_generator ctx origin exp body_result generator_id =
  let matching =
    body_result.introduced_bindings
    |> List.filter (fun (id, _) -> id = generator_id.it)
  in
  match matching with
  | [ _, binding ] -> Ok binding
  | [] ->
    Error
      (unsupported
         ~ctx ~origin ~constructor:"Pattern/IterE"
         ~source_echo:(source_echo_exp exp)
         ~reason:
           ("constructor iteration body did not introduce generator `"
            ^ generator_id.it
            ^ "` as a local element pattern")
         ~suggestion:
           "Keep this IterE Unsupported until the pattern body exposes each generator as a source-shaped local pattern"
         ())
  | _ ->
    Error
      (unsupported
         ~ctx ~origin ~constructor:"Pattern/IterE"
         ~source_echo:(source_echo_exp exp)
         ~reason:
           ("constructor iteration body introduced generator `"
            ^ generator_id.it
            ^ "` more than once")
         ~suggestion:
           "Keep this IterE Unsupported until duplicate local generator bindings can be represented without ambiguity"
         ())

and lower_constructor_zip_iter_pattern
    names ctx callbacks origin exp body iter generators listn_count_exp_opt =
  let unsupported_result reason =
    unsupported_pattern ctx origin "IterE" exp reason
  in
  match flat_subject_iter_typ exp.note with
  | None ->
    return names
      (unsupported_result
         "constructor zip pattern helper requires the IterE result to be a flat list/ListN carrier")
  | Some _subject_element_typ ->
    let body_origin = child_origin origin "iter-body" body in
    let body_result, names = lower_internal names ctx callbacks body_origin body in
    let indexed_generators = List.mapi (fun index generator -> index, generator) generators in
    let source_results, names =
      lower_list_with_names
        (fun names (index, (generator_id, source_exp)) ->
        let source_origin =
          child_origin origin (Printf.sprintf "iter-source[%d]" index) source_exp
        in
        let source_result, names = lower_sequence names ctx callbacks source_origin source_exp in
        (match
          (match source_exp.it with
          | VarE _ -> iter_source_descriptor callbacks source_exp.note
          | _ -> None),
          source_result.term,
          binding_for_generator ctx source_origin source_exp body_result generator_id
        with
        | Some descriptor, Some source_term, Ok binding ->
          Ok
            ( generator_id
            , source_exp
            , descriptor
            , source_term
            , source_result
            , binding )
        | None, _, _ ->
          Error
            (unsupported_result
               ("constructor zip pattern generator `"
                ^ generator_id.it
                ^ "` source must be a plain sequence variable with a supported flat or boundary-preserving sequence carrier"))
        | _, None, _ ->
          Error
            { source_result with
              diagnostics =
                source_result.diagnostics
                @ [ unsupported
                      ~ctx ~origin:source_origin ~constructor:"Pattern/IterE"
                      ~source_echo:(source_echo_exp source_exp)
                      ~reason:
                        ("constructor zip pattern generator `"
                         ^ generator_id.it
                         ^ "` source could not be lowered as a sequence pattern")
                      ~suggestion:
                        "Bind the generator source as a sequence pattern before using it in an iterated constructor pattern"
                      ()
                  ]
            }
        | _, _, Error diagnostic ->
          Error { source_result with diagnostics = source_result.diagnostics @ [ diagnostic ] }),
        names)
        names indexed_generators
    in
    let extra_body_bindings =
      body_result.introduced_bindings
      |> List.filter (fun (id, _) ->
        not (List.exists (fun (generator_id, _) -> generator_id.it = id) generators))
    in
    let extra_body_diagnostics =
      extra_body_bindings
      |> List.map (fun (id, _) ->
        unsupported
          ~ctx ~origin:body_origin ~constructor:"Pattern/IterE"
          ~source_echo:(source_echo_exp body)
          ~reason:
            ("constructor iteration body introduces non-generator binding `"
             ^ id
             ^ "`; branch-local element bindings cannot escape the pattern helper")
          ~suggestion:
            "Keep this IterE Unsupported until the helper explicitly models local-only pattern bindings"
          ())
    in
    let successful_sources =
      source_results
      |> List.filter_map (function Ok source -> Some source | Error _ -> None)
    in
    let source_diagnostics =
      source_results
      |> List.concat_map (function
        | Ok (_, _, _, _, result, _) -> result.diagnostics
        | Error result -> result.diagnostics)
    in
    (match body_result.term, extra_body_diagnostics, source_results with
    | Some body_term, [], _ when List.length successful_sources = List.length generators ->
      let subject_term, names = fresh_pattern names spectec_terminals in
      let subject_tail_var, names = fresh_tail names in
      let helper_sources, names =
        lower_list_with_names
          (fun names (generator_id, source_exp, descriptor, _source_term, _source_result, (binding : binding)) ->
            let source_tail_var, names = fresh_tail names in
          let source_shape : Request.iter_zip_source_shape =
            { generator_source_id = generator_id.it
            ; source_source = source_echo_exp source_exp
            ; source_typ_source = Il.Print.string_of_typ source_exp.note
            }
          in
            ( { Request.source_shape = source_shape
              ; source_item_shape = descriptor.source_item_shape
              ; source_head_term = binding.term
              ; source_tail_var
              }
            , names ))
          names successful_sources
      in
      let helper_request =
        iter_pattern_zip_request
          ~source_shape:
            { pattern_source = source_echo_exp exp
            ; body_source = source_echo_exp body
            ; iter_source =
                (match iter with
                | List -> "List"
                | ListN _ -> "ListN"
                | List1 -> "List1"
                | Opt -> "Opt")
            ; sources =
                List.map
                  (fun (source : Request.iter_pattern_zip_source) ->
                    source.Request.source_shape)
                  helper_sources
            }
          ~subject_item_term:body_term
          ~subject_tail_var
          ~sources:helper_sources
          ~body_eq_conditions:body_result.guards
          ~reason:"source-preserving iterated constructor pattern helper"
          ~origin
      in
      let helper_name = Helper.request (Context.helpers ctx) helper_request in
      let source_terms =
        successful_sources |> List.map (fun (_, _, _, source_term, _, _) -> source_term)
      in
      let source_tuple =
        let wrapped = List.map (fun source_term -> app "seq" [ source_term ]) source_terms in
        let tuple_items =
          match wrapped with
          | [] -> Const "eps"
          | hd :: tl -> List.fold_left (fun acc term -> app "_ _" [ acc; term ]) hd tl
        in
        app "tuple" [ tuple_items ]
      in
      let source_guards =
        successful_sources |> List.concat_map (fun (_, _, _, _, result, _) -> result.guards)
      in
      let source_bindings =
        successful_sources
        |> List.concat_map (fun (_, _, _, _, result, _) -> result.introduced_bindings)
      in
      let listn_result, names =
        match listn_count_exp_opt with
        | None -> return names (with_term (Const "0"))
        | Some n_exp ->
          lower_length_pattern_or_value
            names ctx callbacks
            (child_origin origin "iter-length" n_exp)
            n_exp
      in
      let length_guards, length_bindings, length_diagnostics =
        match listn_count_exp_opt, listn_result.term with
        | None, _ -> [], [], []
        | Some _, Some n_term ->
          let len_condition =
            match n_term with
            | Var _ -> MatchCond (n_term, len subject_term)
            | _ -> EqCond (len subject_term, n_term)
          in
          listn_result.guards @ [ len_condition ],
          listn_result.introduced_bindings,
          listn_result.diagnostics
        | Some _, None ->
          listn_result.guards,
          listn_result.introduced_bindings,
          listn_result.diagnostics
          @ [ unsupported
                ~ctx ~origin ~constructor:"Pattern/IterE"
                ~source_echo:(source_echo_exp exp)
                ~reason:"constructor ListN pattern could not lower its count expression"
                ~suggestion:
                  "Bind the ListN count before using it in an iterated constructor pattern"
                ()
            ]
      in
      let guard_opt, guard_diagnostics =
        guard_for_typ ctx callbacks origin "Pattern/IterE" exp subject_term exp.note
      in
      let helper_guard =
        MatchCond (source_tuple, app helper_name [ subject_term ])
      in
      (match guard_opt with
      | Some target_guards ->
        ( { term = Some subject_term
          ; guards =
              length_guards @ [ helper_guard ] @ source_guards @ target_guards
          ; introduced_bindings = source_bindings @ length_bindings
          ; diagnostics =
              source_diagnostics @ body_result.diagnostics @ length_diagnostics
              @ guard_diagnostics
          }
        , names )
      | None ->
        ( { term = None
          ; guards = length_guards @ [ helper_guard ] @ source_guards
          ; introduced_bindings = source_bindings @ length_bindings
          ; diagnostics =
              source_diagnostics @ body_result.diagnostics @ length_diagnostics
              @ guard_diagnostics
          }
        , names ))
    | _ ->
      ( { term = None
        ; guards =
            body_result.guards
            @ (source_results
               |> List.concat_map (function
                 | Ok (_, _, _, _, result, _) | Error result -> result.guards))
        ; introduced_bindings =
            source_results
            |> List.concat_map (function
              | Ok (_, _, _, _, result, _) | Error result -> result.introduced_bindings)
        ; diagnostics =
            body_result.diagnostics @ source_diagnostics @ extra_body_diagnostics
        }
      , names ))

and lower_exact_optional_pattern names ctx callbacks origin exp body =
  let body_result, names =
    lower_internal names ctx callbacks (child_origin origin "iter-body" body) body
  in
  match body_result.term with
  | Some body_term when body_result.introduced_bindings = [] ->
    let opt_term, names = fresh_pattern names spectec_terminals in
    ( { term = Some opt_term
      ; guards =
          body_result.guards
          @ [ EqCond (is_opt opt_term, Const "true")
            ; BoolCond
                (bool_or
                   (bool_eq opt_term (Const "eps"))
                   (bool_eq opt_term body_term))
            ]
      ; introduced_bindings = []
      ; diagnostics = body_result.diagnostics
      }
    , names )
  | Some _ ->
    ( { term = None
      ; guards = body_result.guards
      ; introduced_bindings = body_result.introduced_bindings
      ; diagnostics =
          body_result.diagnostics
          @ [ unsupported
                ~ctx ~origin ~constructor:"Pattern/IterE"
                ~source_echo:(source_echo_exp exp)
                ~reason:
                  "exact optional pattern body introduces variables; lowering it as eps-or-present would leak bindings across the absent branch"
                ~suggestion:
                  "Keep this optional pattern Unsupported until branch-local optional pattern bindings are represented explicitly"
                ()
            ]
      }
    , names )
  | None -> body_result, names

and source_preserving_body_types generator_id body =
  match body.it with
  | VarE id when id.it = generator_id -> []
  | CvtE (inner, _, _) -> source_preserving_body_types generator_id inner
  | SubE (inner, source_typ, target_typ) ->
    source_preserving_body_types generator_id inner @ [ source_typ; target_typ ]
  | _ -> []

and sequence_guard_for_element_typ ctx callbacks origin exp term typ =
  let sequence_typ = { typ with it = IterT (typ, List) } in
  guard_for_typ ctx callbacks origin "Pattern/IterE/coercion" exp term sequence_typ

and source_preserving_body_guards ctx callbacks origin exp term generator_id body =
  source_preserving_body_types generator_id body
  |> List.fold_left
       (fun (guards, diagnostics) typ ->
         let guard_opt, new_diagnostics =
           sequence_guard_for_element_typ ctx callbacks origin exp term typ
         in
         match guard_opt with
         | Some new_guards ->
           guards @ new_guards, diagnostics @ new_diagnostics
         | None -> guards, diagnostics @ new_diagnostics)
       ([], [])

and lower_source_preserving_sequence
    names ctx callbacks origin exp generator_id body source_exp source_result =
  match source_result.term, body.it with
  | Some source_term,
    SubE ({ it = VarE id; _ }, source_typ, target_typ)
    when id.it = generator_id ->
    Pattern_subtyping.lower_iterated
      names
      ctx
      { bound_vars = callbacks.bound_vars
      ; lower_pattern = (fun names -> lower_internal names ctx callbacks)
      ; carrier_sort_of_typ = callbacks.carrier_sort_of_typ
      ; guard_for_typ =
          (fun origin ~constructor exp term typ ->
            guard_for_typ ctx callbacks origin constructor exp term typ)
      }
      origin exp ~source_exp ~source_result ~source_term
      ~source_typ ~target_typ
  | Some _, _
    when source_preserving_body_types generator_id body <> [] ->
    ( { source_result with
        term = None
      ; diagnostics =
          source_result.diagnostics
          @ [ unsupported
                ~ctx ~origin ~constructor:"Pattern/IterE/SubE/composition"
                ~source_echo:(source_echo_exp body)
                ~reason:
                  "iterated pattern contains a non-direct or composed SubE whose inverse cannot be represented by one source-exact sequence projection"
                ~suggestion:
                  "Keep this IterE unsupported until its coercion composition has a proven inverse plan"
                ()
            ]
      }
    , names )
  | Some source_term, _ ->
    let body_guards, body_diagnostics =
      source_preserving_body_guards
        ctx callbacks origin exp source_term generator_id body
    in
    let guard_opt, diagnostics =
      guard_for_typ ctx callbacks origin "Pattern/IterE" exp source_term exp.note
    in
    (match guard_opt with
    | Some guards ->
      ( { source_result with
          guards = dedup_guards (source_result.guards @ body_guards @ guards)
        ; diagnostics =
            source_result.diagnostics @ body_diagnostics @ diagnostics
        }
      , names )
    | None ->
      ( { source_result with
          term = None
        ; diagnostics =
            source_result.diagnostics @ body_diagnostics @ diagnostics
        }
      , names ))
  | None, _ -> source_result, names

and lower_sequence_with_target_guard names ctx callbacks origin exp generator_id body source_exp =
  let source_result, names =
    lower_sequence names ctx callbacks (child_origin origin "iter-source" source_exp) source_exp
  in
  lower_source_preserving_sequence
    names ctx callbacks origin exp generator_id body source_exp source_result

and lower_nonempty_sequence names ctx callbacks origin source_exp =
  let result, names =
    lower_sequence names ctx callbacks (child_origin origin "iter-source" source_exp) source_exp
  in
  match result.term with
  | Some term ->
    ( { result with
        guards = result.guards @ [ BoolCond (app "_=/=_" [ term; Const "eps" ]) ]
      }
    , names )
  | None -> result, names

and lower_nonempty_sequence_with_target_guard
    names ctx callbacks origin exp generator_id body source_exp =
  let result, names =
    lower_sequence_with_target_guard
      names ctx callbacks origin exp generator_id body source_exp
  in
  match result.term with
  | Some term ->
    ( { result with
        guards = result.guards @ [ BoolCond (app "_=/=_" [ term; Const "eps" ]) ]
      }
    , names )
  | None -> result, names

and lower_optional_list_identity names ctx callbacks origin source_exp =
  let source_result, names =
    lower_sequence names ctx callbacks (child_origin origin "iter-source" source_exp) source_exp
  in
  match source_result.term with
  | Some source_term ->
    ( { term = Some source_term
      ; guards = source_result.guards @ [ EqCond (all_opt source_term, Const "true") ]
      ; introduced_bindings = source_result.introduced_bindings
      ; diagnostics = source_result.diagnostics
      }
    , names )
  | None -> source_result, names

and lower_flat_identity_opt names ctx callbacks origin source_exp =
  let source_result, names =
    lower_sequence names ctx callbacks (child_origin origin "iter-source" source_exp) source_exp
  in
  match source_result.term with
  | Some source_term ->
    ( { term = Some source_term
      ; guards = source_result.guards @ [ EqCond (is_opt source_term, Const "true") ]
      ; introduced_bindings = source_result.introduced_bindings
      ; diagnostics = source_result.diagnostics
      }
    , names )
  | None -> source_result, names

and lower_length_pattern_or_value names ctx callbacks origin exp =
  match exp.it with
  | VarE id -> lower_bound_or_fresh_var names ctx callbacks origin exp id
  | _ -> return names (callbacks.lower_guard_value origin exp)

and lower_flat_identity_listn names ctx callbacks origin source_exp n_exp =
  let source_result, names =
    lower_sequence names ctx callbacks (child_origin origin "iter-source" source_exp) source_exp
  in
  let n_result, names =
    lower_length_pattern_or_value
      names ctx callbacks
      (child_origin origin "iter-length" n_exp)
      n_exp
  in
  match source_result.term, n_result.term with
  | Some source_term, Some n_term ->
    let len_term = len source_term in
    let len_condition =
      match n_term with
      | Var _ -> MatchCond (n_term, len_term)
      | _ -> EqCond (len_term, n_term)
    in
    ( { term = Some source_term
      ; guards = source_result.guards @ n_result.guards @ [ len_condition ]
      ; introduced_bindings =
          source_result.introduced_bindings @ n_result.introduced_bindings
      ; diagnostics = source_result.diagnostics @ n_result.diagnostics
      }
    , names )
  | _ ->
    ( { term = None
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
    , names )

and lower_flat_listn_with_target_guard
    names ctx callbacks origin exp generator_id body source_exp n_exp =
  let result, names = lower_flat_identity_listn names ctx callbacks origin source_exp n_exp in
  lower_source_preserving_sequence
    names ctx callbacks origin exp generator_id body source_exp result

and lower_nested_outer_identity_listn names ctx callbacks origin exp outer_id source_exp body =
  match listn_body_over_outer outer_id body with
  | Some n_exp ->
    let source_result, names =
      lower_sequence names ctx callbacks (child_origin origin "iter-source" source_exp) source_exp
    in
    let n_result, names =
      lower_length_pattern_or_value
        names ctx callbacks
        (child_origin origin "iter-length" n_exp)
        n_exp
    in
    (match source_result.term, n_result.term with
    | Some source_term, Some n_term ->
      ( { term = Some source_term
        ; guards =
            source_result.guards @ n_result.guards
            @ [ EqCond (all_len source_term n_term, Const "true") ]
        ; introduced_bindings =
            source_result.introduced_bindings @ n_result.introduced_bindings
        ; diagnostics = source_result.diagnostics @ n_result.diagnostics
        }
      , names )
    | _ ->
      ( { term = None
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
        }
      , names ))
  | None ->
    return names
      (unsupported_pattern ctx origin "IterE" exp
         "nested List pattern is supported here only when its body is an identity ListN iteration over the current outer generator")

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

and is_source_preserving_iter_body generator_id exp =
  match exp.it with
  | VarE id -> id.it = generator_id
  | CvtE (inner, source_typ, target_typ) ->
    numeric_conversion_preserves_representation source_typ target_typ
    && is_source_preserving_iter_body generator_id inner
  | SubE (inner, _, _) ->
    is_source_preserving_iter_body generator_id inner
  | _ -> false

and listn_body_over_outer outer_id exp =
  match exp.it with
  | IterE ({ it = VarE body_id; _ }, (ListN (n_exp, _), [ generator_id, source_exp ]))
    when body_id.it = generator_id.it ->
    (match source_exp.it with
    | VarE source_id when source_id.it = outer_id -> Some n_exp
    | _ -> None)
  | _ -> None

and numeric_conversion_preserves_representation source_typ target_typ =
  match source_typ, target_typ with
  | `NatT, `NatT | `IntT, `IntT | `NatT, `IntT -> true
  | `IntT, `NatT | `NatT, (`RatT | `RealT) | `IntT, (`RatT | `RealT)
  | (`RatT | `RealT), _ ->
    false

and lower_numeric_conversion names ctx callbacks origin exp inner source_typ target_typ =
  if numeric_conversion_preserves_representation source_typ target_typ then
    lower_internal names ctx callbacks (child_origin origin "cvt-inner" inner) inner
  else
    return names
      (unsupported_pattern ctx origin "CvtE" exp
         "only representation-preserving numeric conversions are erased in pattern lowering; sign-changing, narrowing, Rat, and Real conversions need a verified carrier strategy")

let lower_with_names names ctx callbacks origin exp =
  let source_names =
    Il.Free.(free_exp exp).varid |> Il.Free.Set.elements
  in
  let names = Local_name.reserve_sources names source_names in
  let names = Local_name.reserve_existing_many names callbacks.bound_vars in
  lower_internal names ctx callbacks origin exp
