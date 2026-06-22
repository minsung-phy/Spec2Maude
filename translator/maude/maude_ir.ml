type sort = Sort of string
type kind = Kind of sort

type type_ref =
  | SortRef of sort
  | KindRef of kind

type label = string

type term =
  | Var of string
  | Const of string
  | Qid of string
  | App of string * term list

type attr =
  | Assoc
  | Comm
  | Ctor
  | Id of term
  | Frozen of int list

type eq_attr =
  | Owise

type op_kind =
  | Total
  | Partial

type op_decl =
  { name : string
  ; args : type_ref list
  ; result : sort
  ; kind : op_kind
  ; attrs : attr list
  }

type var_decl =
  { name : string
  ; type_ref : type_ref
  }

type eq_condition =
  | EqCond of term * term
  | MatchCond of term * term
  | MembershipCond of term * sort
  | BoolCond of term

type rule_condition =
  | EqCondition of eq_condition
  | RewriteCond of term * term

type statement_node =
  | SortDecl of sort
  | SubsortDecl of sort * sort
  | OpDecl of op_decl
  | VarDecl of var_decl
  | Mb of term * sort
  | Cmb of term * sort * eq_condition list
  | Eq of term * term * eq_attr list
  | Ceq of term * term * eq_condition list * eq_attr list
  | Rl of label option * term * term
  | Crl of label option * term * term * rule_condition list

type provenance =
  | Prelude
  | Source
  | Helper of string

type generated =
  { node : statement_node
  ; origin : Origin.t
  ; provenance : provenance
  }

type import =
  | Protecting of string
  | Including of string
  | Extending of string

type module_kind =
  | Functional
  | System

type module_ =
  { name : string
  ; kind : module_kind
  ; imports : import list
  ; statements : generated list
  }

let mixfix_placeholder_count name =
  String.fold_left
    (fun count ch -> if ch = '_' then count + 1 else count)
    0
    name

let is_label_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' -> true
  | _ -> false

let trim_label_edges text =
  let len = String.length text in
  let left = ref 0 in
  while !left < len && text.[!left] = '-' do
    incr left
  done;
  let right = ref (len - 1) in
  while !right >= !left && text.[!right] = '-' do
    decr right
  done;
  if !left > !right then "" else String.sub text !left (!right - !left + 1)

let sanitize_label source =
  let b = Buffer.create (String.length source) in
  let last_was_sep = ref false in
  let add_sep () =
    if Buffer.length b > 0 && not !last_was_sep then (
      Buffer.add_char b '-';
      last_was_sep := true)
  in
  String.iter
    (fun ch ->
      if is_label_char ch then
        (Buffer.add_char b (Char.lowercase_ascii ch);
         last_was_sep := false)
      else
        add_sep ())
    source;
  let raw = trim_label_edges (Buffer.contents b) in
  let raw = if raw = "" then "rule" else raw in
  match raw.[0] with
  | '0' .. '9' -> "r" ^ raw
  | _ -> raw

let sort name = Sort name

let kind_of_sort sort = Kind sort

let sort_name (Sort name) = name

let kind_sort (Kind sort) = sort

let sort_ref sort = SortRef sort

let kind_ref kind = KindRef kind

let sort_decl name = SortDecl name

let subsort lower upper = SubsortDecl (lower, upper)

let op ?(kind = Total) ?(attrs = []) name args result =
  OpDecl { name; args; result; kind; attrs }

let var name type_ref =
  VarDecl { name; type_ref }

let mb term sort =
  Mb (term, sort)

let cmb term sort = function
  | [] -> Mb (term, sort)
  | conditions -> Cmb (term, sort, conditions)

let eq ?(attrs = []) lhs rhs =
  Eq (lhs, rhs, attrs)

let ceq ?(attrs = []) lhs rhs = function
  | [] -> Eq (lhs, rhs, attrs)
  | conditions -> Ceq (lhs, rhs, conditions, attrs)

let normalize_label = Option.map sanitize_label

let rl ?label lhs rhs =
  Rl (normalize_label label, lhs, rhs)

let crl ?label lhs rhs = function
  | [] -> Rl (normalize_label label, lhs, rhs)
  | conditions -> Crl (normalize_label label, lhs, rhs, conditions)

let generated ?(provenance = Source) ~origin node =
  { node; origin; provenance }
