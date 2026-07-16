open Maude_ir

type result =
  | Irrefutable
  | Certified of
      { failure : eq_condition
      ; statements : generated list
      }
  | Blocked of string

let rec pattern_vars = function
  | Var name -> [ name ]
  | Const _ | Qid _ -> []
  | App (_, args) -> List.concat_map pattern_vars args

let vars term = List.sort_uniq String.compare (pattern_vars term)
let subset left right = List.for_all (fun item -> List.mem item right) left

let registry_entry constructors name arity =
  Constructor_registry.entries constructors
  |> List.filter (fun entry ->
    entry.Constructor_registry.constructor_op = name
    && entry.arity = arity
    && entry.status = Constructor_registry.Emitted)
  |> function
    | [ entry ] -> Ok entry
    | [] -> Error ("constructor `" ^ name ^ "` is not uniquely registered")
    | _ -> Error ("constructor `" ^ name ^ "` has ambiguous registry identity")

let closed_family constructors entry =
  match
    Constructor_registry.family_coverage constructors
      ~source_category:entry.Constructor_registry.source_category
      ~static_args_key:entry.static_args_key
  with
  | Constructor_registry.Closed entries -> Ok entries
  | Open reasons -> Error (String.concat "; " reasons)

let distinct_vars term =
  let all = pattern_vars term in
  List.length all = List.length (List.sort_uniq String.compare all)

let rec irrefutable constructors = function
  | Var _ -> true
  | App (name, args) as term ->
    distinct_vars term
    && (match registry_entry constructors name (List.length args) with
       | Error _ -> false
       | Ok entry ->
         (match closed_family constructors entry with
         | Ok [ only ] when only.constructor_op = entry.constructor_op ->
           List.for_all (irrefutable constructors) args
         | Ok _ | Error _ -> false))
  | Const _ | Qid _ -> false

let generated helper_name origin node =
  Maude_ir.generated ~provenance:(Helper helper_name) ~origin node

let equation_pattern helper_name index entry entry_index =
  let variables, declarations =
    entry.Constructor_registry.payload_sorts
    |> List.mapi (fun payload_index sort ->
      let name =
        Naming.maude_var ~fallback:"MATCH"
          (helper_name ^ "-match-" ^ string_of_int index ^ "-"
           ^ string_of_int entry_index ^ "-" ^ string_of_int payload_index)
      in
      Var name, var name (sort_ref sort))
    |> List.split
  in
  App (entry.constructor_op, variables), declarations

let certify constructors ~origin ~helper_name ~index ~bound ~pattern ~subject =
  if not (subset (vars subject) bound) then
    Blocked "match subject uses a variable not bound by the source-ordered prefix"
  else if not (distinct_vars pattern) then
    Blocked "match pattern repeats a variable and therefore is not an irrefutable binding"
  else
    match pattern with
    | Var name when not (List.mem name bound) -> Irrefutable
    | Var _ -> Blocked "bound-variable match requires an equality complement"
    | Const _ | Qid _ -> Blocked "literal match has no constructor-family certificate"
    | App (name, args) ->
      (match registry_entry constructors name (List.length args) with
      | Error reason -> Blocked reason
      | Ok target ->
        if not (List.for_all (irrefutable constructors) args) then
          Blocked "constructor payload pattern does not cover its complete payload domain"
        else
          match closed_family constructors target with
          | Error reason -> Blocked reason
          | Ok [ only ] when only.constructor_op = target.constructor_op -> Irrefutable
          | Ok family ->
            let op_name =
              "runtimeEnablednessMatch" ^ Naming.sanitize helper_name
              ^ "x" ^ string_of_int index
            in
            let input_sort = sort "SpectecTerminal" in
            let declarations =
              [ generated helper_name origin
                  (op op_name [ sort_ref input_sort ] (sort "Bool") ~attrs:[ Frozen [ 1 ] ]) ]
            in
            let equations, variables =
              family |> List.mapi (fun entry_index (entry : Constructor_registry.entry) ->
                if entry.constructor_op = target.constructor_op then
                  generated helper_name origin
                    (eq (App (op_name, [ pattern ])) (Const "true")), []
                else
                  let pattern, declarations =
                    equation_pattern helper_name index entry entry_index
                  in
                  generated helper_name origin
                    (eq (App (op_name, [ pattern ])) (Const "false")),
                  List.map (generated helper_name origin) declarations)
              |> List.split
            in
            Certified
              { failure = EqCond (App (op_name, [ subject ]), Const "false")
              ; statements =
                  declarations @ List.concat variables @ equations
              })
