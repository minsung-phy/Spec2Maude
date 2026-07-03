open Util.Source

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

let skipped ?suggestion ~ctx ~origin ~constructor ~reason ?source_echo () =
  Diagnostics.make
    ~category:Diagnostics.Skipped
    ~origin
    ~constructor
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason
    ?suggestion
    ?source_echo
    ()

let source_echo_prem prem =
  Il.Print.string_of_prem prem

let source_echo_exp exp =
  Il.Print.string_of_exp exp

let origin_for_premise parent prem =
  Origin.with_child
    ~source_echo:(source_echo_prem prem)
    parent
    "premise"
    ~ast_constructor:"Premise"
    prem.at

let origin_for_if_conjunct parent segment exp =
  Origin.with_child
    ~source_echo:(source_echo_exp exp)
    parent
    segment
    ~ast_constructor:"IfPr/BinE"
    exp.at

let unsupported_prem ctx env ~bound_vars origin constructor prem reason =
  { (Premise_result.empty_with_env ~bound_vars env) with
    diagnostics =
      [ unsupported
          ~ctx ~origin ~constructor
          ~source_echo:(source_echo_prem prem)
          ~reason
          ~suggestion:"Keep this premise as Unsupported until the generic lowering rule is implemented"
          ()
      ]
  }

let unsupported_rulepr_args ctx env ~bound_vars origin prem rel_id args =
  unsupported_prem
    ctx
    env
    ~bound_vars
    origin
    "Premise/RulePr/args"
    prem
    ("relation premise `"
     ^ rel_id.it
     ^ "` carries explicit RulePr arguments `"
     ^ Il.Print.string_of_args args
     ^ "`, but relation-argument instantiation is not lowered yet; keep the args in the IL path instead of silently dropping them")

let skipped_prem ctx env ~bound_vars origin constructor prem reason suggestion =
  { (Premise_result.empty_with_env ~bound_vars env) with
    diagnostics =
      [ skipped
          ~ctx ~origin ~constructor
          ~source_echo:(source_echo_prem prem)
          ~reason
          ~suggestion
          ()
      ]
  }
