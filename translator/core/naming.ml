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

let source_slug ?(lower = false) source =
  let b = Buffer.create (String.length source) in
  let separator = ref false in
  let add_separator () =
    if Buffer.length b > 0 && not !separator then (
      Buffer.add_char b '-';
      separator := true)
  in
  String.iter
    (fun ch ->
      match ch with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' ->
        Buffer.add_char b (if lower then Char.lowercase_ascii ch else ch);
        separator := false
      | _ -> add_separator ())
    source;
  let raw = trim_separator_edges (Buffer.contents b) in
  if raw = "" then "unnamed" else raw

let sanitize source = source_slug ~lower:true source

let source_owner source = source

let source_atom_slug source =
  match source_slug ~lower:true source with
  | "unnamed" -> "sym"
  | slug -> slug

let source_id id = sanitize id.Util.Source.it

let category_slug id =
  source_slug id.Util.Source.it

let primitive_witness = function
  | name -> "syn." ^ source_slug name

let source_mixop mixop =
  match
    Xl.Mixop.flatten mixop
    |> List.concat
    |> List.map (fun atom -> source_atom_slug (Xl.Atom.to_string atom))
  with
  | [] -> "wrap"
  | atoms -> String.concat "-" atoms

let source_mixop_projection_label = source_mixop

let category_witness id =
  "syn." ^ category_slug id

let constructor_op mixop =
  source_mixop mixop

let constructor_op_in_category ?record_like_single_constructor:_ category mixop =
  source_slug category ^ "." ^ source_mixop mixop

let constructor_op_for_typ typ mixop =
  match typ.Util.Source.it with
  | Il.Ast.VarT (id, _) -> constructor_op_in_category (category_slug id) mixop
  | _ -> constructor_op mixop

let destructor_op_in_category category mixop index =
  "proj." ^ source_slug category ^ "." ^ source_mixop_projection_label mixop
  ^ "." ^ string_of_int index

let projection_op constructor_op index =
  "proj." ^ constructor_op ^ "." ^ string_of_int index

let destructor_op_for_typ typ mixop index =
  match typ.Util.Source.it with
  | Il.Ast.VarT (id, _) ->
    destructor_op_in_category (category_slug id) mixop index
  | _ ->
    "proj." ^ source_mixop_projection_label mixop ^ "." ^ string_of_int index

let wrapper_constructor_in_category category =
  source_slug category ^ ".wrap"

let wrapper_constructor_for_id id =
  wrapper_constructor_in_category (category_slug id)

let record_constructor id =
  "rec." ^ category_slug id

let definition_op id =
  "def." ^ source_slug ~lower:true id.Util.Source.it

let builtin_definition_op id =
  "builtin." ^ source_slug ~lower:true id.Util.Source.it

let specialized_definition_op ?(builtin = false) id target_ids =
  let base =
    if builtin then builtin_definition_op id else definition_op id
  in
  match target_ids with
  | [] -> base
  | targets ->
    base ^ ".with."
    ^ String.concat "." (List.map (source_slug ~lower:true) targets)

let relation_op id =
  "rel." ^ source_slug ~lower:true id.Util.Source.it

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

let helper_owner origin =
  source_slug ~lower:true (helper_source_context origin)

let helper_op ~role ~owner =
  "helper." ^ source_slug ~lower:true role ^ "." ^ source_slug ~lower:true owner

let helper_ordinal name ordinal =
  if ordinal <= 1 then name else name ^ "." ^ string_of_int ordinal

let helper_companion ~role name =
  match String.split_on_char '.' name with
  | "helper" :: _ :: owner ->
    "helper." ^ source_slug ~lower:true role ^ "." ^ String.concat "." owner
  | _ -> helper_op ~role ~owner:name

let sort_token source =
  let words =
    source
    |> String.map (function '.' | '-' -> '_' | ch -> ch)
    |> String.split_on_char '_'
    |> List.filter (fun word -> word <> "")
  in
  match words with
  | [] -> "Generated"
  | words -> String.concat "" (List.map String.capitalize_ascii words)

let source_sort_token source =
  sort_token (source_slug ~lower:true source)

let definition_config_sort id target_ids =
  let base = "DecConf" ^ source_sort_token id.Util.Source.it in
  match target_ids with
  | [] -> base
  | targets ->
    base ^ "With" ^ String.concat "" (List.map source_sort_token targets)

let relation_config_sort id =
  "RelConf" ^ source_sort_token id.Util.Source.it

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

let readable_var_slug ?(source_identity = false) source =
  let b = Buffer.create (String.length source) in
  let last_was_sep = ref false in
  let add_sep () =
    if Buffer.length b > 0 && not !last_was_sep then (
      Buffer.add_char b '_';
      last_was_sep := true)
  in
  let add_word word =
    add_sep ();
    Buffer.add_string b word;
    last_was_sep := false
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
      | '\'' when source_identity -> add_word "PRIME"
      | '*' when source_identity -> add_word "STAR"
      | '?' when source_identity -> add_word "OPT"
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

let source_var ?(fallback = "V") source =
  let raw = readable_var_slug ~source_identity:true source in
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

let helper_context_stem origin =
  maude_var ~fallback:"HELPER" (helper_source_context origin)

let helper_context_name origin =
  match split_words (helper_context_stem origin) with
  | [] -> "Source"
  | words -> String.concat "" (List.map capitalize_word words)

let maude_module_name source =
  source
  |> sanitize
  |> String.uppercase_ascii
