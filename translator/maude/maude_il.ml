(* Maude intermediate language *)

type name = string
type sort = string
type label = string


(* Terms *)

type variable_origin =
  | Source
  | Generated of int

type variable =
  { name : name
  ; sort : sort
  ; origin : variable_origin
  }

let generated_variable_count = ref 0

let source_variable name sort =
  {name; sort; origin = Source}

let generated_variable name sort =
  incr generated_variable_count;
  {name; sort; origin = Generated !generated_variable_count}

let same_variable left right =
  match left.origin, right.origin with
  | Source, Source -> left.name = right.name && left.sort = right.sort
  | Generated left, Generated right -> left = right
  | Source, Generated _ | Generated _, Source -> false

type term =
  | Var of variable
  | Const of string
  | App of name * term list


(* Operator declarations *)

type arrow =
  | Total
  | Partial

type op_attr =
  | Ctor
  | Assoc
  | Comm
  | Ditto
  | Id of term
  | Prec of int
  | Frozen of int list

type op_decl =
  { name : name
  ; domain : sort list
  ; codomain : sort
  ; arrow : arrow
  ; attrs : op_attr list
  }

let frozen_all count =
  match List.init count (( + ) 1) with
  | [] -> []
  | positions -> [Frozen positions]


(* Conditions for equations and memberships *)

type eq_condition =
  | EqCond of term * term
  | MatchCond of term * term
  | MembershipCond of term * sort
  | BoolCond of term


(* Conditions for rewrite rules *)

type rule_condition =
  | EqCondition of eq_condition
  | RewriteCond of term * term


(* Equation attributes *)

type eq_attr =
  | Owise


(* Maude statements *)

type statement =
  | SortDecl of sort
  | SubsortDecl of sort * sort
  | VarDecl of name list * sort

  | OpDecl of op_decl

  | Mb of term * sort
  | Cmb of term * sort * eq_condition list

  | Eq of term * term * eq_attr list
  | Ceq of term * term * eq_condition list * eq_attr list

  | Rl of label option * term * term
  | Crl of label option * term * term * rule_condition list


(* Variable traversal *)

let rec term_variables variables = function
  | Var variable ->
      if List.exists (same_variable variable) variables then variables
      else variable :: variables
  | Const _ -> variables
  | App (_, args) -> List.fold_left term_variables variables args

let variables_bound bound term =
  term_variables [] term
  |> List.for_all (fun variable -> List.exists (same_variable variable) bound)

let rec map_term_variables map = function
  | Var variable -> Var (map variable)
  | Const _ as term -> term
  | App (name, args) -> App (name, List.map (map_term_variables map) args)

(* Apply [f] to every top-level term of a condition or statement. *)
let map_eq_condition_terms f = function
  | EqCond (left, right) -> EqCond (f left, f right)
  | MatchCond (left, right) -> MatchCond (f left, f right)
  | MembershipCond (term, sort) -> MembershipCond (f term, sort)
  | BoolCond term -> BoolCond (f term)

let map_rule_condition_terms f = function
  | EqCondition condition -> EqCondition (map_eq_condition_terms f condition)
  | RewriteCond (left, right) -> RewriteCond (f left, f right)

let map_statement_terms f = function
  | (SortDecl _ | SubsortDecl _ | VarDecl _) as statement -> statement
  | OpDecl declaration ->
      let attrs =
        List.map
          (function
            | Id term -> Id (f term)
            | (Ctor | Assoc | Comm | Ditto | Prec _ | Frozen _) as attr -> attr)
          declaration.attrs
      in
      OpDecl {declaration with attrs}
  | Mb (term, sort) -> Mb (f term, sort)
  | Cmb (term, sort, conditions) ->
      Cmb (f term, sort, List.map (map_eq_condition_terms f) conditions)
  | Eq (left, right, attrs) -> Eq (f left, f right, attrs)
  | Ceq (left, right, conditions, attrs) ->
      Ceq (f left, f right, List.map (map_eq_condition_terms f) conditions, attrs)
  | Rl (label, left, right) -> Rl (label, f left, f right)
  | Crl (label, left, right, conditions) ->
      Crl (label, f left, f right, List.map (map_rule_condition_terms f) conditions)

let map_eq_condition_variables map =
  map_eq_condition_terms (map_term_variables map)

let map_rule_condition_variables map =
  map_rule_condition_terms (map_term_variables map)

let map_statement_variables map =
  map_statement_terms (map_term_variables map)


(* Condition order *)

(* Premises are translated in source order (Prem). The functions below
 * reorder the resulting Maude conditions: a condition moves after the
 * conditions that bind its variables, and some ready conditions are
 * preferred over others. The last ones drop repeated conditions.
 *
 * Maude evaluates conditions from left to right, and a matching or rewrite
 * condition binds the variables of its pattern. Place each condition after
 * the conditions that bind its variables, otherwise keeping the given order.
 * Among ready conditions, those selected by [prefer bound] come first. *)
let condition_ready bound = function
  | EqCondition (EqCond (left, right)) ->
      variables_bound bound left && variables_bound bound right
  | EqCondition (MatchCond (_, subject)) -> variables_bound bound subject
  | EqCondition (MembershipCond (term, _) | BoolCond term) ->
      variables_bound bound term
  | RewriteCond (call, _) -> variables_bound bound call

let schedule_conditions prefer left conditions =
  let take select bound =
    let rec take prefix = function
      | [] -> None
      | condition :: rest when select condition && condition_ready bound condition ->
          Some (condition, List.rev_append prefix rest)
      | condition :: rest -> take (condition :: prefix) rest
    in
    take []
  in
  let rec schedule bound ordered pending =
    match pending with
    | [] -> List.rev ordered
    | _ ->
        let selected =
          match take (prefer bound) bound pending with
          | Some selected -> Some selected
          | None -> take (fun _ -> true) bound pending
        in
        begin match selected with
        | None -> invalid_arg "conditions have unresolved dependencies"
        | Some (EqCondition (MatchCond (pattern, subject)), pending)
          when variables_bound bound pattern ->
            schedule bound (EqCondition (EqCond (pattern, subject)) :: ordered) pending
        | Some ((EqCondition (MatchCond (pattern, _)) | RewriteCond (_, pattern)
                 as condition), pending) ->
            schedule (term_variables bound pattern) (condition :: ordered) pending
        | Some ((EqCondition (EqCond _ | MembershipCond _ | BoolCond _)
                 as condition), pending) ->
            schedule bound (condition :: ordered) pending
        end
  in
  schedule (term_variables [] left) [] conditions

(* Relation rules: equational conditions are evaluated before rewrite
 * conditions when both are ready. *)
let schedule_rule_conditions =
  schedule_conditions (fun _ -> function
    | EqCondition _ -> true
    | RewriteCond _ -> false)

(* Function clauses: ready guards are checked before a condition that binds
 * new variables, so a deferred result pattern is constructed only after its
 * guards hold. *)
let schedule_equation_conditions left conditions =
  let binds bound = function
    | EqCondition (MatchCond (pattern, _)) -> not (variables_bound bound pattern)
    | EqCondition (EqCond _ | MembershipCond _ | BoolCond _) | RewriteCond _ -> false
  in
  conditions
  |> List.map (fun condition -> EqCondition condition)
  |> schedule_conditions (fun bound condition -> not (binds bound condition)) left
  |> List.map (function
       | EqCondition condition -> condition
       | RewriteCond _ -> invalid_arg "an equation cannot use a rewrite condition")

(* Execution rules: the type guards of the inputs come first, because a
 * helper called by a later condition may rely on the input's type. *)
let schedule_execution_conditions guards left conditions =
  guards @ List.filter (fun condition -> not (List.mem condition guards)) conditions
  |> schedule_rule_conditions left

(* After variable names are fixed, a condition that repeats an earlier one is
 * removed. An equality that repeats an earlier match or equality, in either
 * order, is also removed: the earlier condition already established it. *)
let deduplicate values =
  let seen = Hashtbl.create 32 in
  let keep value =
    if Hashtbl.mem seen value then false
    else begin
      Hashtbl.add seen value ();
      true
    end
  in
  List.filter keep values

let simplify_conditions equation conditions =
  let equalities = ref [] in
  let keep condition =
    match equation condition with
    | Some (MatchCond (pattern, subject)) ->
        equalities := (pattern, subject) :: !equalities;
        true
    | Some (EqCond (left, right)) ->
        (* A preceding successful match or equality establishes either order. *)
        let redundant =
          List.exists
            (fun (first, second) ->
              (left = first && right = second)
              || (left = second && right = first))
            !equalities
        in
        if not redundant then equalities := (left, right) :: !equalities;
        not redundant
    | Some (MembershipCond _ | BoolCond _) | None -> true
  in
  List.filter keep (deduplicate conditions)

let deduplicate_conditions = function
  | Cmb (term, sort, conditions) ->
      Cmb (term, sort, simplify_conditions Option.some conditions)
  | Ceq (left, right, conditions, attrs) ->
      Ceq (left, right, simplify_conditions Option.some conditions, attrs)
  | Crl (label, left, right, conditions) ->
      let equation = function
        | EqCondition condition -> Some condition
        | RewriteCond _ -> None
      in
      Crl (label, left, right, simplify_conditions equation conditions)
  | (SortDecl _ | SubsortDecl _ | VarDecl _ | OpDecl _
    | Mb _ | Eq _ | Rl _) as statement ->
      statement


(* Maude module expressions *)

type renaming =
  | SortRenaming of sort * sort
  | OpRenaming of name * name

type module_expr =
  | ModuleName of name
  | ModuleInstantiation of name * name list
  | ModuleRenaming of module_expr * renaming list


(* Maude modules and views *)

type import =
  | Protecting of module_expr
  | Including of module_expr
  | Extending of module_expr

type module_kind =
  | Functional
  | System

type modul =
  { name : name
  ; kind : module_kind
  ; imports : import list
  ; statements : statement list
  }

type view_mapping =
  | SortMapping of sort * sort
  | OpMapping of name * name

type view =
  { name : name
  ; source : module_expr
  ; target : module_expr
  ; mappings : view_mapping list
  }

type top_level =
  | Module of modul
  | View of view
  | Load of string
