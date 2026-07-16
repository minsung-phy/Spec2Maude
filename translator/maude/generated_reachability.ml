type op_identity =
  { name : string
  ; args : Maude_ir.type_ref list
  ; result : Maude_ir.sort
  }

type op_reference =
  { name : string
  ; arity : int
  }

type dependencies =
  { operators : op_reference list
  ; sorts : Maude_ir.sort list
  }

type violation =
  { origin : Origin.t
  ; constructor : string
  ; reason : string
  }

type result =
  { statements : Maude_ir.generated list
  ; violations : violation list
  }

let empty =
  { operators = []; sorts = [] }

let union left right =
  { operators = left.operators @ right.operators
  ; sorts = left.sorts @ right.sorts
  }

let sort_of_type_ref = function
  | Maude_ir.SortRef sort -> sort
  | Maude_ir.KindRef kind -> Maude_ir.kind_sort kind

let rec term_dependencies = function
  | Maude_ir.Var _ -> empty
  | Maude_ir.Const name | Maude_ir.Qid name ->
    { empty with operators = [ { name; arity = 0 } ] }
  | Maude_ir.App (name, args) ->
    args
    |> List.fold_left
         (fun dependencies arg -> union dependencies (term_dependencies arg))
         { empty with operators = [ { name; arity = List.length args } ] }

let attr_dependencies = function
  | Maude_ir.Id term -> term_dependencies term
  | Maude_ir.Assoc | Maude_ir.Comm | Maude_ir.Ctor | Maude_ir.Frozen _ -> empty

let eq_condition_dependencies = function
  | Maude_ir.EqCond (left, right)
  | Maude_ir.MatchCond (left, right) ->
    union (term_dependencies left) (term_dependencies right)
  | Maude_ir.MembershipCond (term, sort) ->
    union (term_dependencies term) { empty with sorts = [ sort ] }
  | Maude_ir.BoolCond term -> term_dependencies term

let rule_condition_dependencies = function
  | Maude_ir.EqCondition condition -> eq_condition_dependencies condition
  | Maude_ir.RewriteCond (left, right) ->
    union (term_dependencies left) (term_dependencies right)

let fold_dependencies f items =
  List.fold_left (fun acc item -> union acc (f item)) empty items

let statement_dependencies statement =
  match statement.Maude_ir.node with
  | Maude_ir.SortDecl _ -> empty
  | Maude_ir.SubsortDecl (lower, upper) ->
    { empty with sorts = [ lower; upper ] }
  | Maude_ir.OpDecl declaration ->
    let attrs = fold_dependencies attr_dependencies declaration.attrs in
    union attrs
      { empty with
        sorts = declaration.result :: List.map sort_of_type_ref declaration.args
      }
  | Maude_ir.VarDecl declaration ->
    { empty with sorts = [ sort_of_type_ref declaration.type_ref ] }
  | Maude_ir.Mb (term, sort) ->
    union (term_dependencies term) { empty with sorts = [ sort ] }
  | Maude_ir.Cmb (term, sort, conditions) ->
    union
      (union (term_dependencies term) { empty with sorts = [ sort ] })
      (fold_dependencies eq_condition_dependencies conditions)
  | Maude_ir.Eq (left, right, _) ->
    union (term_dependencies left) (term_dependencies right)
  | Maude_ir.Ceq (left, right, conditions, _) ->
    union
      (union (term_dependencies left) (term_dependencies right))
      (fold_dependencies eq_condition_dependencies conditions)
  | Maude_ir.Rl (_, left, right) ->
    union (term_dependencies left) (term_dependencies right)
  | Maude_ir.Crl (_, left, right, conditions) ->
    union
      (union (term_dependencies left) (term_dependencies right))
      (fold_dependencies rule_condition_dependencies conditions)

let declared_op statement =
  match statement.Maude_ir.node with
  | Maude_ir.OpDecl declaration ->
    Some
      { name = declaration.name
      ; args = declaration.args
      ; result = declaration.result
      }
  | Maude_ir.SortDecl _ | Maude_ir.SubsortDecl _ | Maude_ir.VarDecl _
  | Maude_ir.Mb _ | Maude_ir.Cmb _ | Maude_ir.Eq _ | Maude_ir.Ceq _
  | Maude_ir.Rl _ | Maude_ir.Crl _ -> None

let declared_sort statement =
  match statement.Maude_ir.node with
  | Maude_ir.SortDecl sort -> Some sort
  | Maude_ir.SubsortDecl _ | Maude_ir.OpDecl _ | Maude_ir.VarDecl _
  | Maude_ir.Mb _ | Maude_ir.Cmb _ | Maude_ir.Eq _ | Maude_ir.Ceq _
  | Maude_ir.Rl _ | Maude_ir.Crl _ -> None

let op_arity identity = List.length identity.args

let op_key name arity = name ^ "\000" ^ string_of_int arity

let add table key value =
  let values = Option.value ~default:[] (Hashtbl.find_opt table key) in
  if not (List.mem value values) then Hashtbl.replace table key (value :: values)

type index =
  { owners : string list
  ; statements_by_owner : (string, Maude_ir.generated list) Hashtbl.t
  ; ops_by_owner : (string, op_identity list) Hashtbl.t
  ; sorts_by_owner : (string, Maude_ir.sort list) Hashtbl.t
  ; op_owners : (string, string list) Hashtbl.t
  ; sort_owners : (string, string list) Hashtbl.t
  }

let build_index statements =
  let statements_by_owner = Hashtbl.create 127 in
  let ops_by_owner = Hashtbl.create 127 in
  let sorts_by_owner = Hashtbl.create 127 in
  let op_owners = Hashtbl.create 257 in
  let sort_owners = Hashtbl.create 127 in
  let owners = ref [] in
  statements |> List.iter (fun statement ->
    match statement.Maude_ir.provenance with
    | Maude_ir.Prelude | Maude_ir.Source -> ()
    | Maude_ir.Helper owner ->
      if not (List.mem owner !owners) then owners := owner :: !owners;
      add statements_by_owner owner statement;
      (match declared_op statement with
      | Some identity ->
        add ops_by_owner owner identity;
        add op_owners (op_key identity.name (op_arity identity)) owner
      | None -> ());
      (match declared_sort statement with
      | Some sort ->
        add sorts_by_owner owner sort;
        add sort_owners (Maude_ir.sort_name sort) owner
      | None -> ())) ;
  { owners = List.sort String.compare !owners
  ; statements_by_owner; ops_by_owner; sorts_by_owner; op_owners; sort_owners
  }

let owner_statements index owner =
  Option.value ~default:[] (Hashtbl.find_opt index.statements_by_owner owner)

let helper_ops index owner =
  Option.value ~default:[] (Hashtbl.find_opt index.ops_by_owner owner)

let helper_sorts index owner =
  Option.value ~default:[] (Hashtbl.find_opt index.sorts_by_owner owner)

let dependency_owners index statement =
  let dependencies = statement_dependencies statement in
  let operators =
    dependencies.operators
    |> List.concat_map (fun reference ->
      Option.value ~default:[]
        (Hashtbl.find_opt index.op_owners (op_key reference.name reference.arity)))
  in
  let sorts =
    dependencies.sorts
    |> List.concat_map (fun sort ->
      Option.value ~default:[]
        (Hashtbl.find_opt index.sort_owners (Maude_ir.sort_name sort)))
  in
  List.sort_uniq String.compare (operators @ sorts)

let reference_of_identity (identity : op_identity) =
  { name = identity.name; arity = op_arity identity }

let helper_mentions_blocked index owner blocked_ops blocked_sorts =
  helper_ops index owner
  |> List.exists (fun identity ->
       List.mem (reference_of_identity identity) blocked_ops)
  || helper_sorts index owner
     |> List.exists (fun sort -> List.mem sort blocked_sorts)
  || owner_statements index owner
     |> List.exists (fun statement ->
          let dependencies = statement_dependencies statement in
          List.exists (fun reference -> List.mem reference blocked_ops)
            dependencies.operators
          || List.exists (fun sort -> List.mem sort blocked_sorts)
               dependencies.sorts)

let blocked_helpers index blocked_ops blocked_sorts =
  let rec close blocked_ops blocked_sorts blocked_owners =
    let new_owners =
      index.owners
      |> List.filter (fun owner ->
        not (List.mem owner blocked_owners)
        && (helper_mentions_blocked index owner blocked_ops blocked_sorts
            || owner_statements index owner
               |> List.exists (fun statement ->
                    dependency_owners index statement
                    |> List.exists (fun dependency ->
                         List.mem dependency blocked_owners))))
    in
    match new_owners with
    | [] -> blocked_owners
    | _ ->
      let new_ops =
        new_owners
        |> List.concat_map (helper_ops index)
        |> List.map reference_of_identity
      in
      let new_sorts =
        new_owners
        |> List.concat_map (helper_sorts index)
      in
      close
        (List.sort_uniq compare (new_ops @ blocked_ops))
        (List.sort_uniq compare (new_sorts @ blocked_sorts))
        (List.sort_uniq String.compare (new_owners @ blocked_owners))
  in
  close
    (List.sort_uniq compare blocked_ops)
    (List.sort_uniq compare blocked_sorts)
    []

let reachable_helpers index statements blocked =
  let roots =
    statements
    |> List.filter (fun statement ->
      match statement.Maude_ir.provenance with
      | Maude_ir.Prelude | Maude_ir.Source -> true
      | Maude_ir.Helper _ -> false)
    |> List.concat_map (dependency_owners index)
    |> List.filter (fun owner -> not (List.mem owner blocked))
    |> List.sort_uniq String.compare
  in
  let rec close reachable = function
    | [] -> reachable
    | owner :: pending ->
      let dependencies =
        owner_statements index owner
        |> List.concat_map (dependency_owners index)
        |> List.filter (fun dependency ->
          not (List.mem dependency blocked || List.mem dependency reachable))
        |> List.sort_uniq String.compare
      in
      close (dependencies @ reachable) (pending @ dependencies)
  in
  close roots roots

let namespace_violations statements =
  let reserved =
    statements
    |> List.filter_map (fun statement ->
      match statement.Maude_ir.provenance, declared_op statement with
      | (Maude_ir.Prelude | Maude_ir.Source), Some identity -> Some identity.name
      | Maude_ir.Helper _, _ | _, None -> None)
    |> List.sort_uniq String.compare
  in
  statements
  |> List.filter_map (fun statement ->
    match statement.Maude_ir.provenance, declared_op statement with
    | Maude_ir.Helper owner, Some identity when List.mem identity.name reserved ->
      Some
        { origin = statement.origin
        ; constructor = "GeneratedReachability/helper-namespace-collision"
        ; reason =
            "generated helper owner `" ^ owner ^ "` declares operator `"
            ^ identity.name
            ^ "`, which is reserved by the source/prelude namespace"
        }
    | Maude_ir.Helper _, _ | Maude_ir.Prelude, _ | Maude_ir.Source, _ -> None)

let blocked_source_violations
    index statements blocked blocked_ops blocked_sorts =
  let blocked_ops =
    (blocked
     |> List.concat_map (helper_ops index)
     |> List.map reference_of_identity)
    @ blocked_ops
    |> List.sort_uniq compare
  in
  let blocked_sorts =
    (blocked |> List.concat_map (helper_sorts index)) @ blocked_sorts
    |> List.sort_uniq compare
  in
  statements
  |> List.filter_map (fun statement ->
    match statement.Maude_ir.provenance with
    | Maude_ir.Helper _ -> None
    | Maude_ir.Prelude | Maude_ir.Source ->
      let dependencies = statement_dependencies statement in
      let blocked_op =
        dependencies.operators
        |> List.find_opt (fun reference ->
          List.mem reference blocked_ops)
      in
      (match blocked_op with
      | Some reference ->
        Some
          { origin = statement.origin
          ; constructor = "GeneratedReachability/source-depends-on-blocked-helper"
          ; reason =
              "retained source/prelude statement references blocked helper declaration `"
              ^ reference.name ^ "/" ^ string_of_int reference.arity
              ^ "`; the enclosing source definition was not rolled back atomically"
          }
      | None ->
        dependencies.sorts
        |> List.find_opt (fun sort -> List.mem sort blocked_sorts)
        |> Option.map (fun sort ->
             { origin = statement.origin
             ; constructor =
                 "GeneratedReachability/source-depends-on-blocked-helper"
             ; reason =
                 "retained source/prelude statement references blocked generated sort `"
                 ^ Maude_ir.sort_name sort
                 ^ "`; the enclosing source definition was not rolled back atomically"
             })))

let retain ~blocked_declarations statements =
  let index = build_index statements in
  let blocked_ops =
    blocked_declarations
    |> List.filter_map declared_op
    |> List.map reference_of_identity
    |> List.sort_uniq compare
  in
  let blocked_sorts =
    blocked_declarations
    |> List.filter_map declared_sort
    |> List.sort_uniq compare
  in
  let blocked = blocked_helpers index blocked_ops blocked_sorts in
  let reachable = reachable_helpers index statements blocked in
  let retained =
    statements
    |> List.filter (fun statement ->
      match statement.Maude_ir.provenance with
      | Maude_ir.Prelude | Maude_ir.Source -> true
      | Maude_ir.Helper owner ->
        not (List.mem owner blocked) && List.mem owner reachable)
  in
  { statements = retained
  ; violations =
      namespace_violations statements
      @ blocked_source_violations
          index statements blocked blocked_ops blocked_sorts
  }
