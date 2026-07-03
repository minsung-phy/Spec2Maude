open Maude_ir

let render_sort sort = sort_name sort

let render_kind kind =
  "[" ^ render_sort (kind_sort kind) ^ "]"

let render_type_ref = function
  | SortRef sort -> render_sort sort
  | KindRef kind -> render_kind kind

let split_mixfix_template template =
  let rec loop start index pieces placeholders =
    if index = String.length template then
      List.rev (String.sub template start (index - start) :: pieces), placeholders
    else if template.[index] = '_' then
      loop (index + 1) (index + 1)
        (String.sub template start (index - start) :: pieces)
        (placeholders + 1)
    else
      loop start (index + 1) pieces placeholders
  in
  loop 0 0 [] 0

let render_mixfix_app render template args =
  let pieces, placeholders = split_mixfix_template template in
  if placeholders <> List.length args then
    invalid_arg
      (Printf.sprintf
         "Maude mixfix operator %S expects %d placeholder(s), got %d argument(s)"
         template placeholders (List.length args));
  let rendered_args =
    args
    |> List.map (function
      | App (name, _) as term when String.contains name '_' ->
        "(" ^ render term ^ ")"
      | term -> render term)
  in
  let tokens = ref [] in
  let add_piece piece =
    let piece = String.trim piece in
    if piece <> "" then tokens := piece :: !tokens
  in
  let add_arg arg =
    tokens := arg :: !tokens
  in
  let rec interleave pieces args =
    match pieces, args with
    | [ piece ], [] -> add_piece piece
    | piece :: pieces, arg :: args ->
      add_piece piece;
      add_arg arg;
      interleave pieces args
    | _ ->
      invalid_arg
        (Printf.sprintf
           "Maude mixfix render invariant failed for %S: %d piece(s), %d argument(s)"
           template (List.length pieces) (List.length rendered_args))
  in
  interleave pieces rendered_args;
  String.concat " " (List.rev !tokens)

let render_prefix_app render name args =
  name ^ "(" ^ String.concat ", " (List.map render args) ^ ")"

let render_as_prefix_mixfix = function
  | "_+_" | "_-_" | "_*_" | "_/_" | "_%_" | "_^_"
  | "_<_" | "_>_" | "_<=_" | "_>=_" | "_==_" | "_=/=_"
  | "_and_" | "_or_" | "not_" | "-_" ->
    true
  | _ -> false

let validate_mixfix_arity template arity =
  if String.contains template '_' then (
    let _pieces, placeholders = split_mixfix_template template in
    if placeholders <> arity then
      invalid_arg
        (Printf.sprintf
           "Maude mixfix operator declaration %S expects %d placeholder(s), got arity %d"
           template placeholders arity))

let render_term =
  let rec render = function
    | Var name -> name
    | Const name -> name
    | Qid qid -> "'" ^ qid
    | App (name, []) -> name
    | App (name, args) ->
      if render_as_prefix_mixfix name then
        render_prefix_app render name args
      else if String.contains name '.'
              && String.contains name '_'
              && not (String.contains name ' ')
              && not (String.contains name '[')
              && not (String.contains name ']')
      then
        render_prefix_app render name args
      else if String.contains name '_' then
        render_mixfix_app render name args
      else
        name ^ "(" ^ String.concat ", " (List.map render args) ^ ")"
  in
  render

let render_attr = function
  | Assoc -> "assoc"
  | Comm -> "comm"
  | Ctor -> "ctor"
  | Id term -> "id: " ^ render_term term
  | Frozen positions ->
    (match positions with
    | [] -> "frozen"
    | _ -> "frozen (" ^ String.concat " " (List.map string_of_int positions) ^ ")")

let render_eq_attr = function
  | Owise -> "owise"

let render_attrs = function
  | [] -> ""
  | attrs -> " [" ^ String.concat " " (List.map render_attr attrs) ^ "]"

let render_eq_attrs = function
  | [] -> ""
  | attrs -> " [" ^ String.concat " " (List.map render_eq_attr attrs) ^ "]"

let render_op_kind = function
  | Total -> "->"
  | Partial -> "~>"

let render_op_decl (decl : op_decl) =
  validate_mixfix_arity decl.name (List.length decl.args);
  "op " ^ decl.name ^ " : "
  ^ String.concat " " (List.map render_type_ref decl.args)
  ^ (if decl.args = [] then "" else " ")
  ^ render_op_kind decl.kind ^ " "
  ^ render_sort decl.result
  ^ render_attrs decl.attrs
  ^ " ."

let is_simple_bool_atom = function
  | Var _ | Const _ -> true
  | App ("_=/=_", [ _; _ ]) -> true
  | App ("typecheck", _) -> true
  | App (_, []) -> true
  | Qid _ | App _ -> false

let render_bool_condition term =
  if is_simple_bool_atom term then
    render_term term
  else
    "(" ^ render_term term ^ ") = true"

let render_eq_condition = function
  | EqCond (lhs, rhs) -> render_term lhs ^ " = " ^ render_term rhs
  | MatchCond (lhs, rhs) -> render_term lhs ^ " := " ^ render_term rhs
  | MembershipCond (term, sort) -> render_term term ^ " : " ^ render_sort sort
  | BoolCond term -> render_bool_condition term

let render_rule_condition = function
  | EqCondition cond -> render_eq_condition cond
  | RewriteCond (lhs, rhs) -> render_term lhs ^ " => " ^ render_term rhs

let render_conditions render_condition conditions =
  String.concat " /\\ " (List.map render_condition conditions)

let render_label = function
  | None -> ""
  | Some label -> " [" ^ label ^ "]"

let render_rule_prefix keyword label =
  match label with
  | None -> keyword ^ " "
  | Some _ -> keyword ^ render_label label ^ " : "

let render_statement_node = function
  | SortDecl sort -> "sort " ^ render_sort sort ^ " ."
  | SubsortDecl (lower, upper) ->
    "subsort " ^ render_sort lower ^ " < " ^ render_sort upper ^ " ."
  | OpDecl decl -> render_op_decl decl
  | VarDecl { name; type_ref } ->
    "var " ^ name ^ " : " ^ render_type_ref type_ref ^ " ."
  | Mb (term, sort) -> "mb " ^ render_term term ^ " : " ^ render_sort sort ^ " ."
  | Cmb (term, sort, conditions) ->
    "cmb " ^ render_term term ^ " : " ^ render_sort sort ^ "\n  if "
    ^ render_conditions render_eq_condition conditions
    ^ " ."
  | Eq (lhs, rhs, attrs) ->
    "eq " ^ render_term lhs ^ " = " ^ render_term rhs ^ render_eq_attrs attrs ^ " ."
  | Ceq (lhs, rhs, conditions, attrs) ->
    "ceq " ^ render_term lhs ^ " = " ^ render_term rhs ^ "\n  if "
    ^ render_conditions render_eq_condition conditions
    ^ render_eq_attrs attrs
    ^ " ."
  | Rl (label, lhs, rhs) ->
    render_rule_prefix "rl" label ^ render_term lhs ^ " => " ^ render_term rhs ^ " ."
  | Crl (label, lhs, rhs, conditions) ->
    render_rule_prefix "crl" label ^ render_term lhs ^ " => " ^ render_term rhs
    ^ "\n  if "
    ^ render_conditions render_rule_condition conditions
    ^ " ."

let render_import = function
  | Protecting name -> "protecting " ^ name ^ " ."
  | Including name -> "including " ^ name ^ " ."
  | Extending name -> "extending " ^ name ^ " ."

let render_module_open = function
  | Functional -> "fmod"
  | System -> "mod"

let render_module_close = function
  | Functional -> "endfm"
  | System -> "endm"

let render_generated generated =
  Origin.to_comment generated.origin
  ^ "\n"
  ^ render_statement_node generated.node
  ^ "\n"

let render_module module_ =
  let b = Buffer.create 4096 in
  Buffer.add_string b (render_module_open module_.kind ^ " " ^ module_.name ^ " is\n");
  List.iter
    (fun import ->
      Buffer.add_string b "  ";
      Buffer.add_string b (render_import import);
      Buffer.add_char b '\n')
    module_.imports;
  if module_.imports <> [] && module_.statements <> [] then Buffer.add_char b '\n';
  List.iter
    (fun statement ->
      let rendered = render_generated statement in
      rendered
      |> String.split_on_char '\n'
      |> List.iter (fun line ->
        if line <> "" then (
          Buffer.add_string b "  ";
          Buffer.add_string b line);
        Buffer.add_char b '\n'))
    module_.statements;
  Buffer.add_string b (render_module_close module_.kind ^ "\n");
  Buffer.contents b
