type signature =
  { arguments : string list
  ; result : string
  }

type head =
  { name : string
  ; arity : int
  ; signatures : signature list
  }

type t =
  { heads : head list
  ; equation_lhss : Maude_ir.term list
  ; axiomatic_heads : (string * int) list
  ; variable_sorts : (string * string list) list
  ; subsorts : (string * string) list
  }

let empty =
  { heads = []; equation_lhss = []; axiomatic_heads = []
  ; variable_sorts = []; subsorts = [] }

let sort_key sort =
  "sort:" ^ Maude_ir.sort_name sort

let type_ref_key = function
  | Maude_ir.SortRef sort -> sort_key sort
  | Maude_ir.KindRef kind ->
    "kind:[" ^ Maude_ir.sort_name (Maude_ir.kind_sort kind) ^ "]"

let add_signature name arguments result certificate =
  let signature = { arguments; result } in
  let arity = List.length arguments in
  let rec add acc = function
    | [] ->
      List.rev ({ name; arity; signatures = [ signature ] } :: acc)
    | head :: rest
      when String.equal head.name name && head.arity = arity ->
      let signatures =
        if List.mem signature head.signatures then head.signatures
        else signature :: head.signatures
      in
      List.rev_append acc ({ head with signatures } :: rest)
    | head :: rest -> add (head :: acc) rest
  in
  { certificate with heads = add [] certificate.heads }

let add_equation_lhs lhs certificate =
  if List.mem lhs certificate.equation_lhss then certificate
  else { certificate with equation_lhss = lhs :: certificate.equation_lhss }

let add_axiomatic_head name arity certificate =
  let head = name, arity in
  if List.mem head certificate.axiomatic_heads then certificate
  else
    { certificate with
      axiomatic_heads = head :: certificate.axiomatic_heads
    }

let add_variable_sort name sort certificate =
  let rec add acc = function
    | [] -> List.rev ((name, [ sort ]) :: acc)
    | (existing, sorts) :: rest when String.equal existing name ->
      let sorts = if List.mem sort sorts then sorts else sort :: sorts in
      List.rev_append acc ((existing, sorts) :: rest)
    | binding :: rest -> add (binding :: acc) rest
  in
  { certificate with variable_sorts = add [] certificate.variable_sorts }

let add_subsort lower upper certificate =
  let edge = lower, upper in
  if List.mem edge certificate.subsorts then certificate
  else { certificate with subsorts = edge :: certificate.subsorts }

let has_equational_axiom attrs =
  List.exists
    (function
      | Maude_ir.Assoc | Comm | Id _ -> true
      | Ctor | Frozen _ -> false)
    attrs

let imported =
  empty
  |> add_signature "0" [] "sort:Nat"
  |> add_signature "s_" [ "sort:Nat" ] "sort:Nat"
  |> add_signature "true" [] "sort:Bool"
  |> add_signature "false" [] "sort:Bool"
  |> add_signature "eps" [] "sort:SpectecTerminals"

let source ctx =
  let constructors =
    Constructor_registry.entries (Context.constructors ctx)
    |> List.fold_left
       (fun certificate (entry : Constructor_registry.entry) ->
         match entry.status with
         | Constructor_registry.Emitted ->
           add_signature entry.constructor_op
             (List.map sort_key entry.payload_sorts)
             "sort:SpectecTerminal"
             certificate
         | Constructor_registry.Skipped | Constructor_registry.Unsupported ->
           certificate)
       empty
  in
  Record_certificate.constructors (Context.record_certificates ctx)
  |> List.fold_left
       (fun certificate constructor ->
         add_signature
           (Record_certificate.constructor_name constructor)
           (Record_certificate.constructor_payload_sorts constructor
            |> List.map sort_key)
           "sort:SpectecTerminal"
           certificate)
       constructors

let generated statements =
  statements
  |> List.fold_left
       (fun certificate statement ->
         match statement.Maude_ir.node with
         | Maude_ir.OpDecl decl ->
           let certificate =
             if has_equational_axiom decl.attrs then
               add_axiomatic_head decl.name (List.length decl.args) certificate
             else certificate
           in
           if List.mem Maude_ir.Ctor decl.attrs
           then
             add_signature decl.name (List.map type_ref_key decl.args)
               (sort_key decl.result) certificate
           else certificate
         | VarDecl decl ->
           add_variable_sort decl.name (type_ref_key decl.type_ref) certificate
         | SubsortDecl (lower, upper) ->
           add_subsort (sort_key lower) (sort_key upper) certificate
         | Eq (lhs, _, _) | Ceq (lhs, _, _, _) ->
           add_equation_lhs lhs certificate
         | SortDecl _ | Mb _ | Cmb _
         | Rl _ | Crl _ -> certificate)
       empty

let union left right =
  let certificate =
    right.heads
  |> List.fold_left
       (fun certificate head ->
         List.fold_left
           (fun certificate signature ->
             add_signature head.name signature.arguments signature.result certificate)
           certificate head.signatures)
       left
  in
  let variables =
    right.variable_sorts
    |> List.fold_left
         (fun certificate (name, sorts) ->
           List.fold_left
             (fun certificate sort -> add_variable_sort name sort certificate)
             certificate sorts)
         certificate
  in
  { certificate with
    equation_lhss =
      List.sort_uniq compare
        (certificate.equation_lhss @ right.equation_lhss)
  ; axiomatic_heads =
      List.sort_uniq compare
        (certificate.axiomatic_heads @ right.axiomatic_heads)
  ; variable_sorts =
      variables.variable_sorts
  ; subsorts =
      List.sort_uniq compare (certificate.subsorts @ right.subsorts)
  }

let admits certificate name arity =
  not (List.mem (name, arity) certificate.axiomatic_heads)
  && match
    List.find_opt
      (fun head -> String.equal head.name name && head.arity = arity)
      certificate.heads
  with
  | Some { signatures = [ _ ]; _ } -> true
  | Some _ | None -> false

let unique_signature certificate name arity =
  match
    List.find_opt
      (fun head -> String.equal head.name name && head.arity = arity)
      certificate.heads
  with
  | Some { signatures = [ signature ]; _ } -> Some signature
  | Some _ | None -> None

let inline_variable_type name =
  match String.index_opt name ':' with
  | None -> None
  | Some index ->
    let qualifier =
      String.sub name (index + 1) (String.length name - index - 1)
    in
    let length = String.length qualifier in
    if length >= 2 && qualifier.[0] = '[' && qualifier.[length - 1] = ']' then
      Some ("kind:" ^ qualifier)
    else if qualifier = "" then
      None
    else
      Some ("sort:" ^ qualifier)

let variable_sort certificate name =
  match inline_variable_type name with
  | Some sort -> Some sort
  | None ->
    (match List.assoc_opt name certificate.variable_sorts with
    | Some [ sort ] -> Some sort
    | Some _ | None -> None)

let rec is_subsort certificate actual expected =
  String.equal actual expected
  || List.exists
       (fun (lower, upper) ->
         String.equal lower actual && is_subsort certificate upper expected)
       certificate.subsorts

let term_sort certificate = function
  | Maude_ir.Var name -> variable_sort certificate name
  | Maude_ir.Const name ->
    Option.map (fun signature -> signature.result)
      (unique_signature certificate name 0)
  | Maude_ir.Qid _ -> Some "sort:Qid"
  | Maude_ir.App (name, args) ->
    Option.map (fun signature -> signature.result)
      (unique_signature certificate name (List.length args))

type sequence_contract =
  { name : string
  ; sequence_sort : string
  ; element_sort : string
  }

let sequence_contracts =
  [ { name = "_ _"
    ; sequence_sort = "sort:SpectecTerminals"
    ; element_sort = "sort:SpectecTerminal"
    }
  ; { name = "_;_"
    ; sequence_sort = "sort:RecordItems"
    ; element_sort = "sort:RecordItem"
    }
  ]

let sequence_contract certificate name arity =
  if arity <> 2 || not (List.mem (name, arity) certificate.axiomatic_heads)
  then None
  else
    match
      List.find_opt (fun contract -> String.equal contract.name name)
        sequence_contracts
    with
    | None -> None
    | Some contract ->
      match unique_signature certificate name arity with
      | Some { arguments = [ left; right ]; result }
        when String.equal left contract.sequence_sort
             && String.equal right contract.sequence_sort
             && String.equal result contract.sequence_sort ->
        Some contract
      | Some _ | None -> None

type side = Candidate | Equation

type term =
  | Variable of side * string
  | Operator of string * term list
  | Quoted of string

let rec term side = function
  | Maude_ir.Var name -> Variable (side, name)
  | Maude_ir.Const name -> Operator (name, [])
  | Maude_ir.Qid name -> Quoted name
  | Maude_ir.App (name, args) -> Operator (name, List.map (term side) args)

let rec lookup variable = function
  | [] -> None
  | (bound, value) :: rest ->
    if bound = variable then Some value else lookup variable rest

let rec dereference subst = function
  | Variable (side, name) as term ->
    let variable = side, name in
    (match lookup variable subst with
    | None -> term
    | Some value -> dereference subst value)
  | (Operator _ | Quoted _) as term -> term

let rec occurs subst variable term =
  match dereference subst term with
  | Variable (side, name) -> variable = (side, name)
  | Operator (_, args) -> List.exists (occurs subst variable) args
  | Quoted _ -> false

let bind subst variable value =
  let value = dereference subst value in
  if value = Variable (fst variable, snd variable) then Some subst
  else if occurs subst variable value then None
  else Some ((variable, value) :: subst)

let rec unify subst left right =
  match dereference subst left, dereference subst right with
  | Variable (side, name), value | value, Variable (side, name) ->
    bind subst (side, name) value
  | Operator (left_name, left_args), Operator (right_name, right_args) ->
    if not (String.equal left_name right_name)
       || List.length left_args <> List.length right_args then
      None
    else
      unify_args subst left_args right_args
  | Quoted left, Quoted right when String.equal left right -> Some subst
  | Quoted _, Quoted _ | Quoted _, Operator _ | Operator _, Quoted _ -> None

and unify_args subst left right =
  match left, right with
  | [], [] -> Some subst
  | left :: lefts, right :: rights ->
    (match unify subst left right with
    | None -> None
    | Some subst -> unify_args subst lefts rights)
  | _ -> None

let overlaps candidate equation_lhs =
  match unify [] (term Candidate candidate) (term Equation equation_lhs) with
  | Some _ -> true
  | None -> false

let rec non_variable_subterms = function
  | Maude_ir.Var _ -> []
  | (Maude_ir.Const _ | Maude_ir.Qid _) as term -> [ term ]
  | Maude_ir.App (_, args) as term ->
    term :: List.concat_map non_variable_subterms args

let rec constructor_term certificate = function
  | Maude_ir.Var _ -> true
  | Maude_ir.Const name -> admits certificate name 0
  | Maude_ir.Qid _ -> true
  | Maude_ir.App (name, args) ->
    (match sequence_contract certificate name (List.length args) with
    | Some contract -> fixed_sequence_pattern certificate contract args
    | None ->
      admits certificate name (List.length args)
      && List.for_all (constructor_term certificate) args)

and fixed_sequence_pattern certificate contract args =
  let rec flatten acc = function
    | [] -> List.rev acc
    | Maude_ir.App (name, nested) :: rest
      when String.equal name contract.name ->
      flatten acc (nested @ rest)
    | term :: rest -> flatten (term :: acc) rest
  in
  flatten [] args
  |> List.for_all (fun term ->
       constructor_term certificate term
       && match term_sort certificate term with
          | Some sort -> is_subsort certificate sort contract.element_sort
          | None -> false)

let is_pattern certificate candidate =
  constructor_term certificate candidate
  && (non_variable_subterms candidate
      |> List.for_all (fun subterm ->
        not (List.exists (overlaps subterm) certificate.equation_lhss)))
