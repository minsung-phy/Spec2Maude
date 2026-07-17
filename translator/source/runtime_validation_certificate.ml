type t =
  | Certified
  | Unavailable of string

let components (exp : Il.Ast.exp) =
  match exp.it with Il.Ast.TupE exps -> exps | _ -> [ exp ]

let result_arity (typ : Il.Ast.typ) =
  match typ.it with Il.Ast.TupT fields -> List.length fields | _ -> 1

let premise_shape
    ~predicate_marker ~source_params ~mixop_equal
    ~declaration_mixop ~premise_args ~premise_mixop ~result ~premise_exp =
  if not predicate_marker then
    Unavailable "referenced relation is not structurally predicate-shaped"
  else if source_params <> [] || premise_args <> [] then
    Unavailable
      "relation parameters are not closed: this certificate currently admits only declarations and RulePr uses with no static parameters or arguments"
  else if not (mixop_equal declaration_mixop premise_mixop) then
    Unavailable "premise and declaration mixop skeletons differ"
  else if result_arity result <> List.length (components premise_exp) then
    Unavailable "premise components do not cover the declared relation signature"
  else
    Certified

let certify
    ~predicate_marker ~source_params ~runtime_demanded ~mixop_equal
    ~declaration_mixop ~premise_args ~premise_mixop ~result ~premise_exp =
  match
    premise_shape
      ~predicate_marker ~source_params ~mixop_equal
      ~declaration_mixop ~premise_args ~premise_mixop ~result ~premise_exp
  with
  | Unavailable _ as unavailable -> unavailable
  | Certified when runtime_demanded ->
    Unavailable
      "runtime-demanded predicate cannot be discharged from fixed syntax or variable closure; this path has no whole-expression, non-synthesis ingress certificate"
  | Certified -> Certified

let certified
    ~predicate_marker ~source_params ~runtime_demanded ~mixop_equal
    ~declaration_mixop ~premise_args ~premise_mixop ~result ~premise_exp =
  certify
    ~predicate_marker ~source_params ~runtime_demanded ~mixop_equal
    ~declaration_mixop ~premise_args ~premise_mixop ~result ~premise_exp
  = Certified
