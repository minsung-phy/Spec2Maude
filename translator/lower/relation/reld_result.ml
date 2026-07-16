type output =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

let empty = { statements = []; diagnostics = [] }

let append left right =
  { statements = left.statements @ right.statements
  ; diagnostics = left.diagnostics @ right.diagnostics
  }

let source_echo origin =
  origin.Origin.source_echo

let diagnostic ?suggestion ?source_echo ~category ~ctx ~origin ~constructor
    ~reason () =
  Diagnostics.make
    ?suggestion
    ?source_echo
    ~category
    ~origin
    ~constructor
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason
    ()

let with_origin_echo origin = function
  | Some source_echo -> Some source_echo
  | None -> source_echo origin

let unsupported ?suggestion ?source_echo ~ctx ~origin ~constructor ~reason () =
  diagnostic
    ?suggestion
    ?source_echo:(with_origin_echo origin source_echo)
    ~category:Diagnostics.Unsupported
    ~ctx ~origin ~constructor ~reason ()

let skipped ?suggestion ?source_echo ~ctx ~origin ~constructor ~reason () =
  diagnostic
    ?suggestion
    ?source_echo:(with_origin_echo origin source_echo)
    ~category:Diagnostics.Skipped
    ~ctx ~origin ~constructor ~reason ()

let one_diagnostic diagnostic =
  { empty with diagnostics = [ diagnostic ] }

let has_fatal diagnostics =
  List.exists Diagnostics.is_fatal diagnostics

let dedup_conditions conditions =
  List.fold_right
    (fun condition acc ->
      if List.exists (( = ) condition) acc then acc else condition :: acc)
    conditions
    []

let dedup_rule_conditions conditions =
  List.fold_right
    (fun condition acc ->
      if List.exists (( = ) condition) acc then acc else condition :: acc)
    conditions
    []

let dedup_generated statements =
  let rec loop seen = function
    | [] -> List.rev seen
    | statement :: rest ->
      if List.exists (fun old -> old.Maude_ir.node = statement.Maude_ir.node) seen then
        loop seen rest
      else
        loop (statement :: seen) rest
  in
  loop [] statements
