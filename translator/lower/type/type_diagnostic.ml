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

let unsupported_carrier ~ctx ~origin ~constructor typ = function
  | Carrier_sort.Nested_sequence ->
    unsupported
      ~ctx ~origin ~constructor
      ?source_echo:(source_echo_typ typ)
      ~reason:
        "nested sequence or optional-over-sequence carrier needs a boundary-preserving encoding; flattening to SpectecTerminals would erase source structure"
      ~suggestion:
        "Implement the nested sequence helper/monomorphized representation before lowering this type"
      ()
  | Carrier_sort.Iteration_guard iter ->
    unsupported
      ~ctx ~origin ~constructor
      ?source_echo:(source_echo_typ typ)
      ~reason:
        ("iteration guard " ^ Il.Print.string_of_iter iter
         ^ " needs a generic non-empty, singleton, or length-preserving sequence encoding; "
         ^ "lowering it to plain element-wise typecheck would be unsound")
      ~suggestion:
        "Add the sequence guard helper required by docs/IMPLEMENTATION_PLAN_V2.md before lowering this case"
      ()
  | Carrier_sort.Tuple_carrier ->
    unsupported
      ~ctx ~origin ~constructor
      ?source_echo:(source_echo_typ typ)
      ~reason:"tuple/config carrier lowering is not part of Milestone A"
      ~suggestion:
        "Add the source-preserving tuple/config encoding from the plan before lowering this type"
      ()

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
