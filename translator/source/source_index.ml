open Il.Ast
open Util.Source

let source_echo_of_def def =
  match def.it with
  | HintD hintdef ->
    let kind, id, hints =
      match hintdef.it with
      | TypH (id, hints) -> "TypH", id, hints
      | RelH (id, hints) -> "RelH", id, hints
      | DecH (id, hints) -> "DecH", id, hints
      | GramH (id, hints) -> "GramH", id, hints
      | RuleH (rel_id, rule_id, hints) ->
        "RuleH", { rel_id with it = rel_id.it ^ "/" ^ rule_id.it }, hints
    in
    let hint_names =
      hints
      |> List.map (fun hint -> hint.hintid.it)
      |> String.concat ", "
    in
    Printf.sprintf "%s %s [%s]" kind id.it hint_names
  | _ -> Il.Print.string_of_def def

let constructor_of_def def =
  match def.it with
  | TypD _ -> "TypD"
  | RelD _ -> "RelD"
  | DecD _ -> "DecD"
  | GramD _ -> "GramD"
  | RecD _ -> "RecD"
  | HintD _ -> "HintD"

let id_of_def def =
  match def.it with
  | TypD (id, _, _)
  | RelD (id, _, _, _, _)
  | DecD (id, _, _, _)
  | GramD (id, _, _, _) -> Some id.it
  | RecD _ -> None
  | HintD hintdef ->
    let id =
      match hintdef.it with
      | TypH (id, _)
      | RelH (id, _)
      | DecH (id, _)
      | GramH (id, _)
      | RuleH (id, _, _) -> id
    in
    Some id.it

type entry =
  { ordinal : int
  ; id : string option
  ; constructor : string
  ; origin : Origin.t
  ; def : def
  }

type t =
  { entries : entry list
  ; by_id : (string, entry list) Hashtbl.t
  }

let add_by_id table entry =
  match entry.id with
  | None -> ()
  | Some id ->
    let old =
      match Hashtbl.find_opt table id with
      | None -> []
      | Some entries -> entries
    in
    Hashtbl.replace table id (old @ [ entry ])

let of_script script =
  let table = Hashtbl.create 127 in
  let ordinal = ref 0 in
  let entries = ref [] in
  let rec visit path def =
    incr ordinal;
    let constructor = constructor_of_def def in
    let segment = Printf.sprintf "%04d-%s" !ordinal constructor in
    let origin =
      Origin.make
        ~source_echo:(source_echo_of_def def)
        ~path:(path @ [ segment ])
        ~ast_constructor:constructor def.at
    in
    let entry =
      { ordinal = !ordinal
      ; id = id_of_def def
      ; constructor
      ; origin
      ; def
      }
    in
    entries := entry :: !entries;
    add_by_id table entry;
    match def.it with
    | RecD defs ->
      List.iteri
        (fun index child ->
          visit (path @ [ segment; Printf.sprintf "rec[%d]" index ]) child)
        defs
    | TypD _ | RelD _ | DecD _ | GramD _ | HintD _ -> ()
  in
  List.iteri
    (fun index def -> visit [ Printf.sprintf "script[%d]" index ] def)
    script;
  { entries = List.rev !entries; by_id = table }

let entries t = t.entries

let find_by_id t id =
  match Hashtbl.find_opt t.by_id id with
  | None -> []
  | Some entries -> entries
