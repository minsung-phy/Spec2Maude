open Util.Source

let atom_name atom =
  Xl.Atom.to_string atom
  |> String.map (function '_' -> '-' | char -> char)

let is_arg = function
  | Xl.Mixop.Arg _ -> true
  | _ -> false

let rec translate = function
  | Xl.Mixop.Arg () ->
      "_"
  | Xl.Mixop.Atom atom ->
      atom_name atom
  | Xl.Mixop.Brack (left, mixop, right) ->
      atom_name left ^ translate mixop ^ atom_name right
  | Xl.Mixop.Infix (left, atom, right) ->
      translate left ^ atom_name atom ^ translate right
  | Xl.Mixop.Seq mixops ->
      String.concat "" (List.map translate mixops)

let is_hole_only mixop =
  Xl.Mixop.flatten mixop |> List.for_all (( = ) [])

let name mixop =
  match mixop with
  | Xl.Mixop.Seq (Xl.Mixop.Atom atom :: args)
    when args <> [] && List.for_all is_arg args ->
      atom_name atom
  | _ when is_hole_only mixop ->
      invalid_arg "a hole-only mixop has no constructor name"
  | _ ->
      translate mixop

let key mixop =
  name mixop ^ "/" ^ string_of_int (Xl.Mixop.arity mixop)

let marker_positions markers mixop =
  Xl.Mixop.flatten mixop
  |> List.mapi (fun index atoms ->
       atoms
       |> List.filter_map (fun atom ->
            if List.mem atom.it markers then
              Some (index + if Xl.Atom.is_sub atom then 1 else 0)
            else None))
  |> List.concat
