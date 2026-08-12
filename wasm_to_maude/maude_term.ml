type t =
  | Const of string
  | App of string * t list
  | Seq of t list

let atom s = Const s
let app f xs = App (f, xs)
let seq xs = Seq xs

let rec pp fmt = function
  | Const s -> Format.pp_print_string fmt s
  | Seq [] -> Format.pp_print_string fmt "eps"
  | Seq xs ->
      Format.pp_open_hovbox fmt 0;
      List.iteri
        (fun i x ->
          if i > 0 then Format.pp_print_space fmt ();
          pp fmt x)
        xs;
      Format.pp_close_box fmt ()
  | App (f, []) -> Format.pp_print_string fmt f
  | App (f, xs) ->
      Format.fprintf fmt "@[%s(@;<0 2>" f;
      List.iteri
        (fun i x ->
          if i > 0 then Format.fprintf fmt ",@ ";
          pp fmt x)
        xs;
      Format.fprintf fmt ")@]"

let to_string t = Format.asprintf "%a" pp t
