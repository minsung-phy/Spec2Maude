open Il.Ast
open Maude_ir
open Util.Source

include Expr_support

type callbacks =
  { lower_value : Context.t -> env -> Origin.t -> exp -> result
  ; lower_iter : Context.t -> env -> Origin.t -> exp -> exp -> iterexp -> result
  }

let seq term = app "seq" [ term ]

let rec lower_tuple_component callbacks ctx env origin exp =
  match carrier_sort_of_typ exp.note with
  | Some sort when is_sequence_sort sort ->
    let result = lower_sequence callbacks ctx env origin exp in
    (match result.term with
    | Some term -> { result with term = Some (seq term) }
    | None -> result)
  | _ -> callbacks.lower_value ctx env origin exp

and lower_tuple callbacks ctx env origin _exp exps =
  let results =
    exps
    |> List.mapi (fun index exp ->
      lower_tuple_component
        callbacks ctx env
        (Origin.with_child
           ~source_echo:(source_echo_exp exp)
           origin
           (Printf.sprintf "tuple[%d]" index)
           ~ast_constructor:"Expr"
           exp.at)
        exp)
  in
  let guards, diagnostics = append_result_metadata results in
  let terms = List.filter_map (fun result -> result.term) results in
  if List.length terms = List.length results then
    let tuple_items =
      match terms with
      | [] -> Const "eps"
      | hd :: tl -> List.fold_left (fun acc term -> app "_ _" [ acc; term ]) hd tl
    in
    { term = Some (app "tuple" [ tuple_items ]); guards; diagnostics }
  else
    { term = None; guards; diagnostics }

and lower_list callbacks ctx env origin exp exps =
  if is_nested_list_typ exp.note then
    lower_nested_list callbacks ctx env origin exp exps
  else if is_optional_list_typ exp.note then
    lower_optional_list callbacks ctx env origin exp exps
  else if is_list_optional_typ exp.note then
    lower_list_optional callbacks ctx env origin exp exps
  else
    lower_flat_list callbacks ctx env origin exps

and lower_flat_list callbacks ctx env origin exps =
  match exps with
  | [] -> with_term (Const "eps")
  | _ ->
    let results = List.map (callbacks.lower_value ctx env origin) exps in
    let guards, diagnostics = append_result_metadata results in
    let terms = List.filter_map (fun result -> result.term) results in
    if List.length terms = List.length results then
      let term =
        match terms with
        | [] -> Const "eps"
        | hd :: tl -> List.fold_left (fun acc term -> app "_ _" [ acc; term ]) hd tl
      in
      { term = Some term; guards; diagnostics }
    else
      { term = None; guards; diagnostics }

and nested_list_element_diagnostic ctx origin exp inner =
  unsupported
    ~ctx ~origin ~constructor:"Expr/ListE/nested-element"
    ~source_echo:(source_echo_exp exp)
    ~reason:
      ("nested list carrier expects each outer element to be a flat list expression, but got `"
       ^ Il.Print.string_of_exp inner ^ "`")
    ~suggestion:
      "Keep deeper or optional nested sequence shapes Unsupported until a boundary-preserving helper exists"
    ()

and lower_nested_list callbacks ctx env origin exp exps =
  match exps with
  | [] -> with_term (Const "eps")
  | _ ->
    let lower_inner inner =
      if is_flat_list_typ inner.note || is_flat_optional_typ inner.note then
        let result = lower_sequence callbacks ctx env origin inner in
        (match result.term with
        | Some term ->
          let guards =
            if is_flat_optional_typ inner.note then
              result.guards @ [ EqCond (is_opt term, Const "true") ]
            else
              result.guards
          in
          { result with term = Some (seq term); guards }
        | None -> result)
      else
        with_diagnostics [ nested_list_element_diagnostic ctx origin exp inner ]
    in
    let results = List.map lower_inner exps in
    let guards, diagnostics = append_result_metadata results in
    let terms = List.filter_map (fun result -> result.term) results in
    if List.length terms = List.length results then
      let term =
        match terms with
        | [] -> Const "eps"
        | hd :: tl -> List.fold_left (fun acc term -> app "_ _" [ acc; term ]) hd tl
      in
      { term = Some term; guards; diagnostics }
    else
      { term = None; guards; diagnostics }

and optional_list_element_diagnostic ctx origin exp inner =
  unsupported
    ~ctx ~origin ~constructor:"Expr/ListE/optional-list-element"
    ~source_echo:(source_echo_exp exp)
    ~reason:
      ("optional-list carrier expects each outer element to be a flat optional expression, but got `"
       ^ Il.Print.string_of_exp inner ^ "`")
    ~suggestion:
      "Keep deeper optional/list nesting Unsupported until a boundary-preserving helper exists"
    ()

and lower_optional_list callbacks ctx env origin exp exps =
  match exps with
  | [] -> with_term (Const "eps")
  | _ ->
    let lower_inner inner =
      if is_flat_optional_typ inner.note then
        let result = lower_sequence callbacks ctx env origin inner in
        (match result.term with
        | Some term ->
          { result with
            term = Some (seq term)
          ; guards = result.guards @ [ EqCond (is_opt term, Const "true") ]
          }
        | None -> result)
      else
        with_diagnostics [ optional_list_element_diagnostic ctx origin exp inner ]
    in
    let results = List.map lower_inner exps in
    let guards, diagnostics = append_result_metadata results in
    let terms = List.filter_map (fun result -> result.term) results in
    if List.length terms = List.length results then
      let term =
        match terms with
        | [] -> Const "eps"
        | hd :: tl -> List.fold_left (fun acc term -> app "_ _" [ acc; term ]) hd tl
      in
      { term = Some term; guards; diagnostics }
    else
      { term = None; guards; diagnostics }

and lower_list_optional callbacks ctx env origin _exp exps =
  let result = lower_flat_list callbacks ctx env origin exps in
  match result.term with
  | Some term -> { result with term = Some (seq term) }
  | None -> result

and lower_sequence callbacks ctx env origin exp =
  match exp.it with
  | VarE id ->
    (match find_var env id.it with
    | Some binding when is_sequence_sort binding.sort -> with_term binding.term
    | Some _ -> with_diagnostics [ sequence_sort_diagnostic ctx origin exp ]
    | None ->
      unsupported_exp ctx origin "Expr/SequenceVarE" exp
        ("unbound sequence variable `" ^ id.it ^ "`"))
  | ListE exps -> lower_list callbacks ctx env origin exp exps
  | CatE (left, right) -> lower_cat callbacks ctx env origin exp left right
  | IterE (body, iterexp) ->
    callbacks.lower_iter ctx env origin exp body iterexp
  | _ ->
    (match carrier_sort_of_typ exp.note with
    | Some sort when is_sequence_sort sort -> callbacks.lower_value ctx env origin exp
    | _ -> with_diagnostics [ sequence_sort_diagnostic ctx origin exp ])

and lower_cat callbacks ctx env origin exp left right =
  let expected_sequence =
    match carrier_sort_of_typ exp.note with
    | Some sort when is_sequence_sort sort -> []
    | _ -> [ sequence_sort_diagnostic ctx origin exp ]
  in
  let left_result = lower_sequence callbacks ctx env origin left in
  let right_result = lower_sequence callbacks ctx env origin right in
  match expected_sequence, left_result.term, right_result.term with
  | [], Some left_term, Some right_term ->
    { term = Some (app "_ _" [ left_term; right_term ])
    ; guards = left_result.guards @ right_result.guards
    ; diagnostics = left_result.diagnostics @ right_result.diagnostics
    }
  | _ ->
    { term = None
    ; guards = left_result.guards @ right_result.guards
    ; diagnostics = expected_sequence @ left_result.diagnostics @ right_result.diagnostics
    }

and lower_opt callbacks ctx env origin exp opt =
  if is_list_optional_typ exp.note then
    match opt with
    | None -> with_term (Const "eps")
    | Some inner ->
      let result =
        lower_sequence callbacks ctx env (Origin.with_child
          ~source_echo:(source_echo_exp inner)
          origin
          "opt-list-some"
          ~ast_constructor:"Expr"
          inner.at)
          inner
      in
      (match result.term with
      | Some term -> { result with term = Some (seq term) }
      | None -> result)
  else
  match carrier_sort_of_typ exp.note with
  | Some sort when is_sequence_sort sort ->
    (match opt with
    | None -> with_term (Const "eps")
    | Some inner -> callbacks.lower_value ctx env origin inner)
  | _ ->
    unsupported_exp ctx origin "Expr/OptE" exp
      "optional expression lowering requires a non-nested optional carrier represented as eps or a singleton terminal"

and lower_lift callbacks ctx env origin exp inner =
  if is_flat_list_typ exp.note && is_flat_optional_typ inner.note then
    let result = lower_sequence callbacks ctx env origin inner in
    match result.term with
    | Some term ->
      { result with guards = result.guards @ [ EqCond (is_opt term, Const "true") ] }
    | None -> result
  else
    unsupported_exp ctx origin "Expr/LiftE" exp
      "only identity lifting from a flat optional carrier to a flat list carrier is supported in this slice"
