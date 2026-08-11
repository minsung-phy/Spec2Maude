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
    ~enclosing:
      (Diagnostic_provenance.enclosing ~context:(Context.enclosing_path ctx) origin)
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
  (* A successful Maude match entails the corresponding equality modulo the
     declared equational theory, so a later copy of that equality is redundant. *)
  let same_equality (left, right) (left', right') =
    (left = left' && right = right')
    || (left = right' && right = left')
  in
  let rec loop bindings seen acc = function
    | [] -> List.rev acc
    | condition :: rest when List.mem condition seen ->
      loop bindings seen acc rest
    | Maude_ir.EqCondition (Maude_ir.EqCond (left, right)) :: rest
      when List.exists (same_equality (left, right)) bindings ->
      loop bindings seen acc rest
    | Maude_ir.EqCondition (Maude_ir.MatchCond (left, right)) as condition :: rest ->
      loop
        ((left, right) :: bindings)
        (condition :: seen)
        (condition :: acc)
        rest
    | condition :: rest ->
      loop bindings (condition :: seen) (condition :: acc) rest
  in
  loop [] [] [] conditions

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
