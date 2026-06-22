type op_signature =
  { name : string
  ; args : Maude_ir.type_ref list
  ; result : Maude_ir.sort
  ; kind : Maude_ir.op_kind
  ; attrs : Maude_ir.attr list
  ; origin : Origin.t
  }

type violation =
  { origin : Origin.t
  ; constructor : string
  ; reason : string
  ; suggestion : string option
  ; source_echo : string option
  }

type t =
  { sorts : (string, Origin.t) Hashtbl.t
  ; ops_by_exact_signature : (string, op_signature) Hashtbl.t
  ; ops_by_name : (string, op_signature list) Hashtbl.t
  }

let create () =
  { sorts = Hashtbl.create 127
  ; ops_by_exact_signature = Hashtbl.create 257
  ; ops_by_name = Hashtbl.create 257
  }

let type_ref_key = function
  | Maude_ir.SortRef sort -> "sort:" ^ Maude_ir.sort_name sort
  | Maude_ir.KindRef kind ->
    "kind:[" ^ Maude_ir.sort_name (Maude_ir.kind_sort kind) ^ "]"

let attr_key = function
  | Maude_ir.Assoc -> "assoc"
  | Maude_ir.Comm -> "comm"
  | Maude_ir.Ctor -> "ctor"
  | Maude_ir.Id term -> "id:" ^ string_of_int (Hashtbl.hash term)
  | Maude_ir.Frozen positions ->
    "frozen(" ^ String.concat "," (List.map string_of_int positions) ^ ")"

let op_kind_key = function
  | Maude_ir.Total -> "total"
  | Maude_ir.Partial -> "partial"

let op_domain_key (decl : Maude_ir.op_decl) =
  String.concat
    "|"
    [ decl.name
    ; String.concat "," (List.map type_ref_key decl.args)
    ]

let op_shape_key signature =
  String.concat
    "|"
    [ signature.name
    ; String.concat "," (List.map type_ref_key signature.args)
    ; Maude_ir.sort_name signature.result
    ; op_kind_key signature.kind
    ; String.concat "," (List.map attr_key signature.attrs)
    ]

let source_echo origin = origin.Origin.source_echo

let violation ?suggestion ~origin ~constructor ~reason () =
  { origin
  ; constructor
  ; reason
  ; suggestion
  ; source_echo = source_echo origin
  }

let has_sort t name =
  Hashtbl.mem t.sorts name

let find_ops t ~name =
  match Hashtbl.find_opt t.ops_by_name name with
  | None -> []
  | Some signatures -> signatures

let has_op t ~name ~arity =
  find_ops t ~name
  |> List.exists (fun signature -> List.length signature.args = arity)

let add_sort t origin sort =
  let name = Maude_ir.sort_name sort in
  if not (Hashtbl.mem t.sorts name) then Hashtbl.add t.sorts name origin

let primitive_subsort_is_forbidden lower upper =
  Maude_ir.sort_name upper = "SpectecTerminal"
  &&
  match Maude_ir.sort_name lower with
  | "Bool" | "Rat" | "Float" | "String" -> true
  | _ -> false

let validate_mixfix_arity origin (decl : Maude_ir.op_decl) =
  if String.contains decl.name '_' then
    let placeholders = Maude_ir.mixfix_placeholder_count decl.name in
    let arity = List.length decl.args in
    if placeholders <> arity then
      [ violation
          ~origin
          ~constructor:"MaudeRegistry/op/mixfix-arity"
          ~reason:
            (Printf.sprintf
               "operator `%s` has %d mixfix placeholder(s), but declaration has %d argument(s)"
               decl.name placeholders arity)
          ~suggestion:
            "Fix the Maude IR operator declaration before emitting concrete Maude text"
          ()
      ]
    else
      []
  else
    []

let validate_frozen_positions origin (decl : Maude_ir.op_decl) =
  let arity = List.length decl.args in
  decl.attrs
  |> List.concat_map (function
    | Maude_ir.Frozen positions ->
      positions
      |> List.filter (fun position -> position < 1 || position > arity)
      |> List.map (fun position ->
        violation
          ~origin
          ~constructor:"MaudeRegistry/op/frozen"
          ~reason:
            (Printf.sprintf
               "operator `%s` freezes position %d, but its arity is %d"
               decl.name position arity)
          ~suggestion:"Use one-based frozen positions that refer to existing operator arguments"
          ())
    | Maude_ir.Assoc | Maude_ir.Comm | Maude_ir.Ctor | Maude_ir.Id _ -> [])

let add_op t origin (decl : Maude_ir.op_decl) =
  let signature =
    { name = decl.name
    ; args = decl.args
    ; result = decl.result
    ; kind = decl.kind
    ; attrs = decl.attrs
    ; origin
    }
  in
  let domain_key = op_domain_key decl in
  let duplicate_violations =
    match Hashtbl.find_opt t.ops_by_exact_signature domain_key with
    | None -> []
    | Some existing ->
      if op_shape_key existing = op_shape_key signature then
        []
      else
        [ violation
            ~origin
            ~constructor:"MaudeRegistry/op/duplicate-incompatible"
            ~reason:
              ("operator `" ^ decl.name
               ^ "` is redeclared with the same domain but incompatible result, kind, or attributes")
            ~suggestion:
              "Give the generated operator a deterministic distinct name, or make the declarations exactly identical"
            ()
        ]
  in
  if duplicate_violations = [] then
    Hashtbl.replace t.ops_by_exact_signature domain_key signature;
  let by_name =
    match Hashtbl.find_opt t.ops_by_name decl.name with
    | None -> []
    | Some signatures -> signatures
  in
  if
    not
      (List.exists
         (fun existing -> op_shape_key existing = op_shape_key signature)
         by_name)
  then
    Hashtbl.replace t.ops_by_name decl.name (by_name @ [ signature ]);
  duplicate_violations
  @ validate_mixfix_arity origin decl
  @ validate_frozen_positions origin decl

let validate_label origin constructor = function
  | None -> []
  | Some label ->
    let sanitized = Maude_ir.sanitize_label label in
    if label = sanitized then
      []
    else
      [ violation
          ~origin
          ~constructor
          ~reason:
            ("rule label `" ^ label ^ "` is not Maude-safe; sanitized form would be `"
             ^ sanitized ^ "`")
          ~suggestion:
            "Create rule labels through Maude_ir.rl/crl or Naming before emitting rules"
          ()
      ]

let add_var vars name =
  if List.mem name vars then vars else name :: vars

let add_vars vars bound =
  List.fold_left add_var bound vars

let rec term_vars = function
  | Maude_ir.Var name -> [ name ]
  | Maude_ir.Const _ | Maude_ir.Qid _ -> []
  | Maude_ir.App (_, args) ->
    args
    |> List.map term_vars
    |> List.concat
    |> List.fold_left (fun vars name -> add_var vars name) []

let unbound_vars term bound =
  term_vars term
  |> List.filter (fun name -> not (List.mem name bound))
  |> List.sort_uniq String.compare

let vars_text vars =
  vars |> List.sort_uniq String.compare |> String.concat ", "

let require_bound origin constructor index role bound term =
  match unbound_vars term bound with
  | [] -> []
  | missing ->
    [ violation
        ~origin
        ~constructor
        ~reason:
          (Printf.sprintf
             "condition %d uses variable(s) before they are bound in %s: %s"
             index role (vars_text missing))
        ~suggestion:
          "Introduce variables through the statement lhs or an earlier matching/rewrite condition before using them"
        ()
    ]

let validate_eq_condition origin constructor index bound condition =
  match condition with
  | Maude_ir.EqCond (lhs, rhs) ->
    let violations =
      require_bound origin constructor index "equation lhs" bound lhs
      @ require_bound origin constructor index "equation rhs" bound rhs
    in
    bound, violations
  | Maude_ir.MatchCond (pattern, subject) ->
    let subject_violations =
      require_bound origin constructor index "matching subject" bound subject
    in
    if Condition_closure.is_match_pattern pattern then
      add_vars (term_vars pattern) bound, subject_violations
    else
      bound,
      subject_violations
      @ [ violation
            ~origin
            ~constructor
            ~reason:
              (Printf.sprintf
                 "condition %d matching lhs is not a Maude pattern, so it cannot introduce variables soundly"
                 index)
            ~suggestion:
              "Lower the source lhs to a constructor/variable pattern before emitting a Maude matching condition"
            ()
        ]
  | Maude_ir.MembershipCond (term, _) ->
    let violations =
      require_bound origin constructor index "membership term" bound term
    in
    bound, violations
  | Maude_ir.BoolCond term ->
    let violations =
      require_bound origin constructor index "Bool condition" bound term
    in
    bound, violations

let validate_rule_condition origin constructor index bound condition =
  match condition with
  | Maude_ir.EqCondition condition ->
    validate_eq_condition origin constructor index bound condition
  | Maude_ir.RewriteCond (lhs, rhs) ->
    let violations =
      require_bound origin constructor index "rewrite lhs" bound lhs
    in
    add_vars (term_vars rhs) bound, violations

let validate_condition_list validate_one origin constructor initial_bound conditions =
  conditions
  |> List.mapi (fun index condition -> index + 1, condition)
  |> List.fold_left
       (fun (bound, violations) (index, condition) ->
         let bound, new_violations =
           validate_one origin constructor index bound condition
         in
         bound, violations @ new_violations)
       (initial_bound, [])

let validate_rhs_admissible origin constructor bound rhs =
  match unbound_vars rhs bound with
  | [] -> []
  | missing ->
    [ violation
        ~origin
        ~constructor
        ~reason:
          ("statement rhs uses variable(s) before they are bound by lhs or conditions: "
           ^ vars_text missing)
        ~suggestion:
          "Bind rhs variables through the statement lhs or an admissible earlier matching/rewrite condition"
        ()
    ]

let validate_cmb_conditions origin term conditions =
  let _bound, violations =
    validate_condition_list
      validate_eq_condition
      origin
      "MaudeRegistry/cmb-condition-admissibility"
      (term_vars term)
      conditions
  in
  violations

let validate_ceq_conditions origin lhs rhs conditions =
  let bound, violations =
    validate_condition_list
      validate_eq_condition
      origin
      "MaudeRegistry/ceq-condition-admissibility"
      (term_vars lhs)
      conditions
  in
  violations @ validate_rhs_admissible origin "MaudeRegistry/ceq-condition-admissibility" bound rhs

let validate_crl_conditions origin lhs rhs conditions =
  let bound, violations =
    validate_condition_list
      validate_rule_condition
      origin
      "MaudeRegistry/crl-condition-admissibility"
      (term_vars lhs)
      conditions
  in
  violations @ validate_rhs_admissible origin "MaudeRegistry/crl-condition-admissibility" bound rhs

let register_generated t generated =
  let origin = generated.Maude_ir.origin in
  match generated.Maude_ir.node with
  | Maude_ir.SortDecl sort ->
    add_sort t origin sort;
    []
  | Maude_ir.SubsortDecl (lower, upper) ->
    add_sort t origin lower;
    add_sort t origin upper;
    if primitive_subsort_is_forbidden lower upper then
      [ violation
          ~origin
          ~constructor:"MaudeRegistry/subsort/primitive-carrier"
          ~reason:
            ("direct subsort `" ^ Maude_ir.sort_name lower
             ^ " < SpectecTerminal` violates the primitive carrier policy")
          ~suggestion:
            "Only Nat/Int may be direct SpectecTerminal subsorts; use wrapper carriers for Bool/Rat/Float/String"
          ()
      ]
    else
      []
  | Maude_ir.OpDecl decl ->
    add_sort t origin decl.result;
    add_op t origin decl
  | Maude_ir.Cmb (term, _, conditions) ->
    validate_cmb_conditions origin term conditions
  | Maude_ir.Ceq (lhs, rhs, conditions, _) ->
    validate_ceq_conditions origin lhs rhs conditions
  | Maude_ir.Crl (label, lhs, rhs, conditions) ->
    validate_label origin "MaudeRegistry/rule-label" label
    @ validate_crl_conditions origin lhs rhs conditions
  | Maude_ir.Rl (label, _, _) ->
    validate_label origin "MaudeRegistry/rule-label" label
  | Maude_ir.VarDecl _ | Maude_ir.Mb _ | Maude_ir.Eq _ ->
    []

let build statements =
  let t = create () in
  let violations =
    statements
    |> List.concat_map (register_generated t)
  in
  t, violations

let module_has_rule module_ =
  List.exists
    (fun generated ->
      match generated.Maude_ir.node with
      | Maude_ir.Rl _ | Maude_ir.Crl _ -> true
      | _ -> false)
    module_.Maude_ir.statements

let validate_module module_ =
  let _registry, violations = build module_.Maude_ir.statements in
  match module_.Maude_ir.kind with
  | Maude_ir.System -> violations
  | Maude_ir.Functional ->
    if module_has_rule module_ then
      let origin =
        Origin.synthetic
          ~ast_constructor:"MaudeModule"
          ~source_echo:"functional module contains rewrite rules"
          module_.Maude_ir.name
      in
      violation
        ~origin
        ~constructor:"MaudeRegistry/module-kind"
        ~reason:
          "functional Maude module contains rl/crl statements, which require a system module"
        ~suggestion:"Emit `mod/endm` for generated modules that contain rewrite rules"
        ()
      :: violations
    else
      violations

let diagnostics ~profile violations =
  violations
  |> List.map (fun violation ->
    Diagnostics.make
      ?suggestion:violation.suggestion
      ?source_echo:violation.source_echo
      ~category:Diagnostics.Unsupported
      ~origin:violation.origin
      ~constructor:violation.constructor
      ~enclosing:[]
      ~profile
      ~reason:violation.reason
      ())
