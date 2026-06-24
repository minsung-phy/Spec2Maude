let is_word_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
  | _ -> false

let is_source_slug_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '/' | '.' -> true
  | _ -> false

let sanitize source =
  let b = Buffer.create (String.length source) in
  String.iter
    (fun ch ->
      if is_word_char ch then (
        Buffer.add_char b (Char.lowercase_ascii ch))
      else
        Buffer.add_string b (Printf.sprintf "x%02xx" (Char.code ch)))
    source;
  let raw = Buffer.contents b in
  if raw = "" then "unnamed" else raw

let source_slug ?(lower = false) source =
  let b = Buffer.create (String.length source) in
  String.iter
    (fun ch ->
      if is_source_slug_char ch then
        Buffer.add_char b (if lower then Char.lowercase_ascii ch else ch)
      else if ch = '_' then
        Buffer.add_string b "x5f"
      else
        Buffer.add_string b (Printf.sprintf "x%02xx" (Char.code ch)))
    source;
  let raw = Buffer.contents b in
  if raw = "" then "unnamed" else raw

let trim_separator_edges text =
  let len = String.length text in
  let left = ref 0 in
  while !left < len && text.[!left] = '-' do
    incr left
  done;
  let right = ref (len - 1) in
  while !right >= !left && text.[!right] = '-' do
    decr right
  done;
  if !left > !right then "" else String.sub text !left (!right - !left + 1)

let source_atom_slug source =
  let b = Buffer.create (String.length source) in
  let last_was_sep = ref false in
  let add_sep () =
    if Buffer.length b > 0 && not !last_was_sep then (
      Buffer.add_char b '-';
      last_was_sep := true)
  in
  String.iter
    (fun ch ->
      match ch with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' ->
        Buffer.add_char b (Char.lowercase_ascii ch);
        last_was_sep := false
      | '_' | '-' | '.' | '/' -> add_sep ()
      | _ -> add_sep ())
    source;
  let raw = trim_separator_edges (Buffer.contents b) in
  if raw = "" then "sym" else raw

let source_id id = sanitize id.Util.Source.it

let category_slug id =
  source_slug id.Util.Source.it

let primitive_witness = function
  | "bool" -> "syn-bool"
  | "nat" -> "syn-nat"
  | "int" -> "syn-int"
  | "rat" -> "syn-rat"
  | "real" -> "syn-real"
  | "text" -> "syn-text"
  | name -> "syn-" ^ source_slug name

let source_mixop mixop =
  let atom_slug atom =
    source_atom_slug (Xl.Atom.to_string atom)
  in
  let segment atoms =
    atoms
    |> List.map atom_slug
    |> String.concat "."
  in
  match List.map segment mixop with
  | [] -> "unnamed"
  | [ "" ] -> "unnamed"
  | [ segment ] -> segment
  | segments -> String.concat "_" segments

let source_mixop_projection_label mixop =
  let atom_slug atom =
    source_atom_slug (Xl.Atom.to_string atom)
  in
  let atoms =
    mixop
    |> List.concat
    |> List.map atom_slug
  in
  match atoms with
  | [] -> "wrap"
  | _ -> String.concat "." atoms

let category_witness id =
  "syn-" ^ category_slug id

let constructor_op mixop =
  source_mixop mixop

let constructor_op_in_category ?(record_like_single_constructor = false) category mixop =
  if record_like_single_constructor then
    source_slug category
  else
    source_slug category ^ "." ^ source_mixop mixop

let constructor_op_for_typ typ mixop =
  match typ.Util.Source.it with
  | Il.Ast.VarT (id, _) -> constructor_op_in_category (category_slug id) mixop
  | _ -> constructor_op mixop

let destructor_op_in_category category mixop index =
  "proj." ^ source_slug category ^ "." ^ source_mixop_projection_label mixop
  ^ "." ^ string_of_int index ^ "_"

let destructor_op_for_typ typ mixop index =
  match typ.Util.Source.it with
  | Il.Ast.VarT (id, _) ->
    destructor_op_in_category (category_slug id) mixop index
  | _ ->
    "proj." ^ source_mixop_projection_label mixop ^ "." ^ string_of_int index ^ "_"

let wrapper_constructor_in_category category =
  source_slug category ^ ".wrap_"

let wrapper_constructor_for_id id =
  wrapper_constructor_in_category (category_slug id)

let record_constructor id =
  "rec-" ^ category_slug id

let definition_op id =
  "def" ^ sanitize id.Util.Source.it

let specialized_definition_op id static_keys =
  match static_keys with
  | [] -> definition_op id
  | keys ->
    let material = String.concat "\000" keys in
    definition_op id ^ "x2dxspecx" ^ Digest.to_hex (Digest.string material)

let relation_op id =
  source_atom_slug id.Util.Source.it

let relation_equational_view_op id =
  relation_op id ^ "-view"

let substring_after_marker marker text =
  let marker_len = String.length marker in
  let text_len = String.length text in
  let rec loop index =
    if index + marker_len > text_len then
      None
    else if String.sub text index marker_len = marker then
      Some (String.sub text (index + marker_len) (text_len - index - marker_len))
    else
      loop (index + 1)
  in
  loop 0

let helper_source_context origin =
  let markers = [ "DecD-"; "RelD-"; "TypD-"; "RuleD-"; "DefD-" ] in
  let rec find_in_segments = function
    | [] -> None
    | segment :: segments ->
      (match
         markers |> List.find_map (fun marker -> substring_after_marker marker segment)
       with
      | Some context when context <> "" -> Some context
      | _ -> find_in_segments segments)
  in
  match find_in_segments (List.rev origin.Origin.path) with
  | Some context -> context
  | None -> origin.Origin.ast_constructor

let trim_var_separators text =
  let len = String.length text in
  let left = ref 0 in
  while !left < len && text.[!left] = '_' do
    incr left
  done;
  let right = ref (len - 1) in
  while !right >= !left && text.[!right] = '_' do
    decr right
  done;
  if !left > !right then "" else String.sub text !left (!right - !left + 1)

let is_hex = function
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false

let hex_value = function
  | '0' .. '9' as ch -> Char.code ch - Char.code '0'
  | 'a' .. 'f' as ch -> 10 + Char.code ch - Char.code 'a'
  | 'A' .. 'F' as ch -> 10 + Char.code ch - Char.code 'A'
  | _ -> 0

let decode_sanitize_escapes source =
  let len = String.length source in
  let b = Buffer.create len in
  let rec loop index =
    if index >= len then
      ()
    else if
      index + 3 < len
      && source.[index] = 'x'
      && is_hex source.[index + 1]
      && is_hex source.[index + 2]
      && source.[index + 3] = 'x'
    then (
      let code =
        (hex_value source.[index + 1] * 16) + hex_value source.[index + 2]
      in
      Buffer.add_char b (Char.chr code);
      loop (index + 4))
    else (
      Buffer.add_char b source.[index];
      loop (index + 1))
  in
  loop 0;
  Buffer.contents b

let readable_var_slug source =
  let source = decode_sanitize_escapes source in
  let b = Buffer.create (String.length source) in
  let last_was_sep = ref false in
  let add_sep () =
    if Buffer.length b > 0 && not !last_was_sep then (
      Buffer.add_char b '_';
      last_was_sep := true)
  in
  String.iter
    (fun ch ->
      match ch with
      | 'a' .. 'z' | 'A' .. 'Z' ->
        Buffer.add_char b (Char.uppercase_ascii ch);
        last_was_sep := false
      | '0' .. '9' ->
        Buffer.add_char b ch;
        last_was_sep := false
      | '_' | '-' | '.' | '/' | '\'' | '`' | '*' | '?' -> add_sep ()
      | _ -> add_sep ())
    source;
  trim_var_separators (Buffer.contents b)

let maude_var ?(fallback = "V") source =
  let raw = readable_var_slug source in
  let fallback = readable_var_slug fallback |> fun slug -> if slug = "" then "V" else slug in
  let raw = if raw = "" then fallback else raw in
  match raw.[0] with
  | 'A' .. 'Z' -> raw
  | _ -> fallback ^ raw

let split_words text =
  text
  |> String.split_on_char '_'
  |> List.filter (fun word -> word <> "")

let capitalize_word word =
  match String.lowercase_ascii word with
  | "" -> ""
  | word ->
    String.make 1 (Char.uppercase_ascii word.[0])
    ^ String.sub word 1 (String.length word - 1)

let helper_context_var_stem origin =
  maude_var ~fallback:"HELPER" (helper_source_context origin)

let helper_local_var_stem origin =
  helper_context_var_stem origin

let helper_context_name origin =
  match split_words (helper_context_var_stem origin) with
  | [] -> "Source"
  | words -> String.concat "" (List.map capitalize_word words)

let maude_module_name source =
  source
  |> sanitize
  |> String.uppercase_ascii
