open Il.Ast
open Maude_ir
open Util.Source

type typd_error =
  | Nested_sequence
  | Iteration_guard of iter
  | Tuple_carrier

let s = sort
let spectec_terminal = s "SpectecTerminal"
let spectec_terminals = s "SpectecTerminals"

let numeric_conversion_preserves_runtime_representation source_typ target_typ =
  match source_typ, target_typ with
  | `NatT, `NatT | `IntT, `IntT | `NatT, `IntT -> true
  | `IntT, `NatT | `NatT, (`RatT | `RealT) | `IntT, (`RatT | `RealT)
  | (`RatT | `RealT), _ ->
    false

let numeric_sort_coercion_preserves_runtime_representation source_sort target_sort =
  match sort_name source_sort, sort_name target_sort with
  | source, target when source = target -> true
  | "Nat", "Int" -> true
  | _ -> false

let raw_numeric_sort_of_numtyp = function
  | `NatT -> Some (s "Nat")
  | `IntT -> Some (s "Int")
  | `RatT -> Some (s "Rat")
  | `RealT -> None

let is_raw_numeric_sort sort =
  match sort_name sort with
  | "Nat" | "Int" | "Rat" -> true
  | _ -> false

let is_nat_int_sort sort =
  match sort_name sort with
  | "Nat" | "Int" -> true
  | _ -> false

let is_sequence_sort sort =
  sort_name sort = sort_name spectec_terminals

let is_nat_sort sort =
  sort_name sort = "Nat"

let is_flat_list_typ = Type_shape.is_flat_list_typ
let is_flat_optional_typ = Type_shape.is_flat_optional_typ
let is_nested_list_typ = Type_shape.is_nested_list_typ
let is_optional_list_typ = Type_shape.is_optional_list_typ
let is_list_optional_typ = Type_shape.is_list_optional_typ

let for_expression = function
  | { it = BoolT | NumT `RatT | NumT `RealT | TextT | VarT _; _ } ->
    Some spectec_terminal
  | { it = NumT `NatT; _ } -> Some (s "Nat")
  | { it = NumT `IntT; _ } -> Some (s "Int")
  | typ
    when is_flat_list_typ typ || is_flat_optional_typ typ || is_nested_list_typ typ
         || is_optional_list_typ typ || is_list_optional_typ typ ->
    Some spectec_terminals
  | { it = TupT _; _ } -> Some spectec_terminal
  | { it = IterT _; _ } -> None

let primitive_numeric_alias_sort ctx typ =
  let rec resolve visited typ =
    match typ.it with
    | NumT `NatT -> Some (s "Nat")
    | NumT `IntT -> Some (s "Int")
    | VarT (id, []) when not (List.mem id.it visited) ->
      let entries = Analysis.Source_index.find_by_id (Context.source_index ctx) id.it in
      entries
      |> List.find_map (fun entry ->
        match entry.Analysis.Source_index.def.it with
        | TypD (_, [], [ inst ]) ->
          (match inst.it with
          | InstD ([], [], { it = AliasT alias_typ; _ }) ->
            resolve (id.it :: visited) alias_typ
          | _ -> None)
        | _ -> None)
    | _ -> None
  in
  resolve [] typ

let raw_numeric_sort_of_typ ctx typ =
  match primitive_numeric_alias_sort ctx typ with
  | Some sort -> Some sort
  | None ->
    (match typ.it with
    | NumT typ -> raw_numeric_sort_of_numtyp typ
    | _ -> None)

let typ_is_nat ctx typ =
  match for_expression typ with
  | Some sort when sort_name sort = "Nat" -> true
  | _ ->
    (match primitive_numeric_alias_sort ctx typ with
    | Some sort when sort_name sort = "Nat" -> true
    | _ -> false)

let for_typd ctx typ =
  match primitive_numeric_alias_sort ctx typ with
  | Some sort -> Ok sort
  | None ->
    match typ.it with
    | BoolT | NumT `RatT | NumT `RealT | TextT | VarT _ ->
      Ok spectec_terminal
    | NumT `NatT -> Ok (s "Nat")
    | NumT `IntT -> Ok (s "Int")
    | _ when is_flat_list_typ typ || is_flat_optional_typ typ || is_nested_list_typ typ
             || is_optional_list_typ typ || is_list_optional_typ typ ->
      Ok spectec_terminals
    | IterT (_, (List | Opt)) -> Error Nested_sequence
    | IterT (_, ((List1 | ListN _) as iter)) -> Error (Iteration_guard iter)
    | TupT _ -> Error Tuple_carrier
