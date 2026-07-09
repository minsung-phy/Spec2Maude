open Maude_ir

type t =
  { declarations : Maude_ir.generated list
  ; term : Maude_ir.term
  }

let generated helper_name origin node =
  Maude_ir.generated ~provenance:(Maude_ir.Helper helper_name) ~origin node

let payload_sorts_complete entry =
  List.length entry.Constructor_registry.payload_sorts
  = entry.Constructor_registry.arity

let build ~helper_name ~origin ~var_name entry =
  if not (payload_sorts_complete entry) then
    None
  else
    match entry.Constructor_registry.arity with
    | 0 ->
      Some { declarations = []; term = Const entry.constructor_op }
    | _ ->
      let fields =
        entry.Constructor_registry.payload_sorts
        |> List.mapi (fun index sort ->
          let name = var_name index sort in
          generated helper_name origin (var name (sort_ref sort)), Var name)
      in
      Some
        { declarations = List.map fst fields
        ; term = App (entry.constructor_op, List.map snd fields)
        }
