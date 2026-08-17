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

let name mixop =
  match mixop with
  | Xl.Mixop.Seq (Xl.Mixop.Atom atom :: args)
    when args <> [] && List.for_all is_arg args ->
      atom_name atom
  | _ when Xl.Mixop.flatten mixop |> List.for_all (( = ) []) ->
      invalid_arg "a hole-only mixop has no constructor name"
  | _ ->
      translate mixop
