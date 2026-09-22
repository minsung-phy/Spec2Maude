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
  | Seq [item] -> Format.fprintf fmt "@[%a@]" pp item
  | Seq xs ->
      let items = Array.of_list xs in
      (* Bound flat associative parses; grouping preserves order and elements. *)
      let rec range fmt (start, length) =
        if length <= 8 then begin
          Format.pp_open_hovbox fmt 0;
          for i = start to start + length - 1 do
            if i > start then Format.pp_print_space fmt ();
            pp fmt items.(i)
          done;
          Format.pp_close_box fmt ()
        end else begin
          let left = length / 2 in
          Format.fprintf fmt "(@[%a@])@ (@[%a@])"
            range (start, left) range (start + left, length - left)
        end
      in
      range fmt (0, Array.length items)
  | App ("[_.._]", [lower; upper]) ->
      Format.fprintf fmt "[@[%a@ ..@ %a@]]" pp lower pp upper
  | App ("{_}", [items]) ->
      Format.fprintf fmt "{@[%a@]}" pp items
  | App ("_;_", [left; right]) ->
      Format.fprintf fmt "(@[%a@ ;@ %a@])" pp left pp right
  | App ("_._", [record; field]) ->
      Format.fprintf fmt "(@[%a@ .@ %a@])" pp record pp field
  | App (f, []) -> Format.pp_print_string fmt f
  | App (f, xs) ->
      Format.fprintf fmt "@[%s(@;<0 2>" f;
      List.iteri
        (fun i x ->
          if i > 0 then Format.fprintf fmt ",@ ";
          pp_argument fmt x)
        xs;
      Format.fprintf fmt ")@]"

and pp_argument fmt = function
  | Seq (_ :: _ :: _ as xs) -> Format.fprintf fmt "(@[%a@])" pp (Seq xs)
  | term -> pp fmt term

let to_string t = Format.asprintf "%a" pp t
