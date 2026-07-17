open Il.Ast
open Util.Source

type t =
  { id : id
  ; fields : typfield list
  }

type concatenable =
  | Sequence
  | Optional
  | Record of t

type error =
  | Irreducible of typ
  | Reduction_failed of typ * string
  | Non_concatenable of typ
  | Non_nominal_record of typ
  | Recursive_record of id
  | Field_composition of atom * error
  | Field_arity of int * int
  | Field_identity of int * atom * atom

let static_typ_subst ctx =
  Context.static_typ_env ctx
  |> List.fold_left
       (fun subst (name, typ) -> Il.Subst.add_typid subst (name $ typ.at) typ)
       Il.Subst.empty

let canonical_typ ctx typ =
  let typ = Il.Subst.subst_typ (static_typ_subst ctx) typ in
  try Ok (Il.Eval.reduce_typ (Context.il_env ctx) typ) with
  | Il.Eval.Irred -> Error (Irreducible typ)
  | Util.Error.Error (_, message) -> Error (Reduction_failed (typ, message))

let record_of_canonical ctx typ =
  match typ.it with
  | VarT (id, _) ->
    (try
       match (Il.Eval.reduce_typdef (Context.il_env ctx) typ).it with
       | StructT fields -> Ok { id; fields }
       | AliasT _ | VariantT _ -> Error (Non_concatenable typ)
     with
     | Il.Eval.Irred -> Error (Irreducible typ)
     | Util.Error.Error (_, message) -> Error (Reduction_failed (typ, message)))
  | BoolT | NumT _ | TextT | TupT _ | IterT _ ->
    Error (Non_nominal_record typ)

let of_typ ctx typ =
  match canonical_typ ctx typ with
  | Ok typ -> record_of_canonical ctx typ
  | Error error -> Error error

let concatenable ctx typ =
  match canonical_typ ctx typ with
  | Ok { it = IterT (_, Opt); _ } -> Ok Optional
  | Ok { it = IterT (_, (List | List1 | ListN _)); _ } -> Ok Sequence
  | Ok typ -> Result.map (fun record -> Record record) (record_of_canonical ctx typ)
  | Error error -> Error error

let composition ctx record =
  let rec validate visited record =
    if List.exists (Il.Eq.eq_id record.id) visited then
      Error (Recursive_record record.id)
    else
      let visited = record.id :: visited in
      let rec fields acc = function
        | [] -> Ok (Record_certificate.plan record.id (List.rev acc))
        | (atom, (typ, _, _), _) :: rest ->
          (match concatenable ctx typ with
          | Ok Sequence ->
            fields ((atom, Record_certificate.Append) :: acc) rest
          | Ok Optional ->
            fields ((atom, Record_certificate.Compose_optional) :: acc) rest
          | Ok (Record nested) ->
            (match validate visited nested with
            | Ok nested_plan ->
              fields
                ((atom, Record_certificate.Compose_record nested_plan) :: acc)
                rest
            | Error error -> Error (Field_composition (atom, error)))
          | Error error -> Error (Field_composition (atom, error)))
      in
      fields [] record.fields
  in
  validate [] record

let rec error_path = function
  | Field_composition (atom, error) -> atom :: error_path error
  | Irreducible _ | Reduction_failed _ | Non_concatenable _
  | Non_nominal_record _ | Recursive_record _ | Field_arity _
  | Field_identity _ ->
    []

let match_fields record fields =
  let expected = List.length record.fields in
  let actual_count = List.length fields in
  if expected <> actual_count then
    Error (Field_arity (expected, actual_count))
  else
    let rec match_fields index acc declared actual =
      match declared, actual with
      | [], [] -> Ok (List.rev acc)
      | ((expected_atom, _, _) as field) :: declared,
        ((actual_atom, _) as expfield) :: actual ->
        if Il.Eq.eq_atom expected_atom actual_atom then
          match_fields (index + 1) ((field, expfield) :: acc) declared actual
        else
          Error (Field_identity (index, expected_atom, actual_atom))
      | _ -> Error (Field_arity (expected, actual_count))
    in
    match_fields 1 [] record.fields fields

let rec describe_error = function
  | Irreducible typ ->
    "the elaborated type note could not be reduced through the IL environment: "
    ^ Il.Print.string_of_typ typ
  | Reduction_failed (typ, message) ->
    "the elaborated type note failed IL type reduction ("
    ^ Il.Print.string_of_typ typ ^ "): " ^ message
  | Non_concatenable typ ->
    "the reduced type note is neither an iterated type nor a StructT: "
    ^ Il.Print.string_of_typ typ
  | Non_nominal_record typ ->
    "canonical record construction requires a nominal VarT owner after IL type reduction: "
    ^ Il.Print.string_of_typ typ
  | Recursive_record id ->
    "recursive StructT composition has no finite nominal helper dependency order: "
    ^ id.it
  | Field_composition (atom, error) ->
    "record field " ^ Xl.Atom.to_string atom
    ^ " is not recursively concatenable: " ^ describe_error error
  | Field_arity (expected, actual) ->
    Printf.sprintf
      "record field arity does not match its elaborated StructT (expected %d, got %d)"
      expected actual
  | Field_identity (index, expected, actual) ->
    Printf.sprintf
      "record field %d does not match its elaborated StructT (expected %s, got %s)"
      index (Xl.Atom.to_string expected) (Xl.Atom.to_string actual)
