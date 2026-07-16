open Expr_result

let source_echo_exp exp =
  Il.Print.string_of_exp exp

let unsupported ?suggestion ~ctx ~origin ~constructor ~reason ?source_echo
    ?deferral () =
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin
    ~constructor
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason
    ?suggestion
    ?source_echo
    ?deferral
    ()

let prelude_gap ?suggestion ~ctx ~origin ~constructor ~reason ?source_echo () =
  Diagnostics.make
    ~category:Diagnostics.PreludeGap
    ~origin
    ~constructor
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason
    ?suggestion
    ?source_echo
    ()

let unsupported_witness ctx origin constructor source reason =
  unsupported
    ~ctx ~origin ~constructor
    ~source_echo:source
    ~reason
    ~suggestion:"Keep this coercion Unsupported until its type witness can be lowered source-safely"
    ()

let unsupported_exp ctx origin constructor exp reason =
  with_diagnostics
    [ unsupported
        ~ctx ~origin ~constructor
        ~source_echo:(source_echo_exp exp)
        ~reason
        ~suggestion:"Keep this expression as Unsupported until the generic lowering rule is implemented"
        ()
    ]

let sequence_sort_diagnostic ctx origin exp =
  unsupported
    ~ctx ~origin ~constructor:"Expr/Sequence"
    ~source_echo:(source_echo_exp exp)
    ~reason:
      "expression is not known to have SpectecTerminals carrier, so sequence concatenation would be a guess"
    ~suggestion:"Track a sequence carrier for this expression before lowering it as SpectecTerminals"
    ()
