open Util.Source
open Il.Ast
open Maude_il

module StringSet = Set.Make (String)

let normalize_variables source_declarations statements =
  let source_sorts = Hashtbl.create 64 in
  let declared = Hashtbl.create 64 in
  let declaration_order = ref [] in
  let source_names = ref StringSet.empty in
  let add_declared name sort =
    match Hashtbl.find_opt declared name with
    | None ->
        Hashtbl.add declared name sort;
        declaration_order := (name, sort) :: !declaration_order
    | Some sort' when sort = sort' -> ()
    | Some _ -> invalid_arg ("variable " ^ name ^ " has conflicting sorts")
  in
  List.iter
    (function
      | VarDecl (names, sort) ->
          List.iter
            (fun name ->
              source_names := StringSet.add name !source_names;
              match Hashtbl.find_opt source_sorts name with
              | None -> Hashtbl.add source_sorts name sort
              | Some sort' when sort = sort' -> ()
              | Some _ ->
                  invalid_arg ("source variable " ^ name ^ " has conflicting sorts"))
            names
      | _ -> invalid_arg "expected a variable declaration")
    source_declarations;

  let fresh_generated local_used (variable : variable) =
    let rec choose index =
      let name =
        if index = 1 then variable.name
        else variable.name ^ string_of_int index
      in
      if StringSet.mem name !source_names || StringSet.mem name !local_used then
        choose (index + 1)
      else
        match Hashtbl.find_opt declared name with
        | Some sort when sort <> variable.sort -> choose (index + 1)
        | Some _ -> name
        | None -> add_declared name variable.sort; name
    in
    choose 1
  in

  let normalize_statement statement =
    let generated = Hashtbl.create 16 in
    let local_used = ref StringSet.empty in
    let normalize_variable (variable : variable) =
      match variable.origin with
      | Source ->
          begin match Hashtbl.find_opt source_sorts variable.name with
          | Some sort when sort = variable.sort ->
              add_declared variable.name variable.sort;
              local_used := StringSet.add variable.name !local_used;
              variable
          | Some _ ->
              invalid_arg ("source variable " ^ variable.name ^ " changed sort")
          | None ->
              invalid_arg ("undeclared source variable " ^ variable.name)
          end
      | Generated id ->
          begin match Hashtbl.find_opt generated id with
          | Some normalized -> normalized
          | None ->
              let name = fresh_generated local_used variable in
              local_used := StringSet.add name !local_used;
              let normalized = {variable with name} in
              Hashtbl.add generated id normalized;
              normalized
          end
    in
    match statement with
    | VarDecl _ -> invalid_arg "variable declarations are rebuilt after lowering"
    | statement -> map_statement_variables normalize_variable statement
  in
  let statements = List.map normalize_statement statements in
  let groups = Hashtbl.create 16 in
  let sort_order = ref [] in
  List.iter
    (fun (name, sort) ->
      if not (Hashtbl.mem groups sort) then sort_order := sort :: !sort_order;
      let names = Option.value (Hashtbl.find_opt groups sort) ~default:[] in
      Hashtbl.replace groups sort (name :: names))
    (List.rev !declaration_order);
  let declarations =
    List.rev !sort_order
    |> List.map (fun sort ->
         VarDecl (List.rev (Hashtbl.find groups sort), sort))
  in
  declarations, statements

let rec translate index def =
  match def.it with
  | TypD (id, params, insts) -> Typd.translate index id params insts
  | DecD (id, params, typ, clauses) -> Decd.translate index id params typ clauses
  | RelD (id, params, mixop, typ, rules) ->
      Reld.translate index id params mixop typ rules
  | GramD _ -> []
  | HintD _ -> []
  | RecD defs -> List.concat_map (translate index) defs

let translate_script script =
  let index = Prescan.scan script in
  let translated_definitions =
    List.concat_map (translate index) script
    @ Param.translate_applications index
  in
  let iterations =
    Iter.translate_all
      (Prem.translate_pattern_parts index)
      (Term.translate_exp index) index
  in
  let premise_iterations =
    let translate_body bound body =
      let result = Prem.translate_all index ~bound [body] in
      result.conditions, result.otherwise
    in
    Iter.translate_premise_all translate_body index
  in
  let statements =
    translated_definitions @ iterations @ premise_iterations
  in
  let variable_declarations, statements =
    normalize_variables
      (Prescan.variable_declarations index)
      statements
  in
  let sort_declarations, statements =
    List.partition
      (function SortDecl _ | SubsortDecl _ -> true | _ -> false)
      statements
  in
  let operator_declarations, definitions =
    List.partition (function OpDecl _ -> true | _ -> false) statements
  in
  sort_declarations @ operator_declarations
  @ variable_declarations @ definitions
