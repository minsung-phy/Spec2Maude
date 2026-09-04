open Util.Source
open Il.Ast
open Maude_il

module StringSet = Set.Make (String)

let deduplicate values =
  let seen = Hashtbl.create 32 in
  let keep value =
    if Hashtbl.mem seen value then false
    else begin
      Hashtbl.add seen value ();
      true
    end
  in
  List.filter keep values

let deduplicate_conditions = function
  | Cmb (term, sort, conditions) ->
      Cmb (term, sort, deduplicate conditions)
  | Ceq (left, right, conditions, attrs) ->
      Ceq (left, right, deduplicate conditions, attrs)
  | Crl (label, left, right, conditions) ->
      Crl (label, left, right, deduplicate conditions)
  | (SortDecl _ | SubsortDecl _ | VarDecl _ | OpDecl _
    | Mb _ | Eq _ | Rl _) as statement ->
      statement

let normalize_constructor_declarations statements =
  let same_head (left : op_decl) (right : op_decl) =
    left.name = right.name && left.domain = right.domain
  in
  let rec add declarations = function
    | [] -> List.rev declarations
    | OpDecl declaration :: statements
      when List.mem Ctor declaration.attrs ->
        begin match
          List.find_opt
            (function
              | OpDecl previous -> same_head previous declaration
              | _ -> false)
            declarations
        with
        | None -> add (OpDecl declaration :: declarations) statements
        | Some (OpDecl previous)
          when previous.codomain = declaration.codomain
               && previous.arrow = declaration.arrow
               && previous.attrs = declaration.attrs ->
            add declarations statements
        | Some (OpDecl previous) ->
            invalid_arg
              (Printf.sprintf
                 "unsupported constructor signature for %s: %s and %s"
                 declaration.name previous.codomain declaration.codomain)
        | Some _ -> assert false
        end
    | statement :: statements -> add (statement :: declarations) statements
  in
  add [] statements

let sort_metadata_declarations metadata =
  let annotated =
    Sort_metadata.annotated_sorts metadata |> List.map (fun sort -> SortDecl sort)
  in
  let proper =
    Sort_metadata.proper_sorts metadata
    |> List.map (fun (proper, _) -> SortDecl proper)
  in
  let edges =
    Sort_metadata.subsort_edges metadata @ Sort_metadata.proper_sorts metadata
    |> List.map (fun (subsort, supersort) -> SubsortDecl (subsort, supersort))
  in
  annotated @ proper @ edges

type script_translation =
  { sort_statements : statement list
  ; list_views : top_level list
  ; list_imports : import list
  ; list_statements : statement list
  ; generated_statements : statement list
  }

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
  let statements =
    List.map normalize_statement statements
    |> List.map deduplicate_conditions
  in
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

let rec translate ?request_output index def =
  match def.it with
  | TypD (id, params, insts) -> Typd.translate index id params insts
  | DecD (id, params, typ, clauses) -> Decd.translate index id params typ clauses
  | RelD (id, params, mixop, typ, rules) ->
      Reld.translate ?request_output index id params mixop typ rules
  | GramD _ -> []
  | HintD _ -> []
  | RecD defs -> List.concat_map (translate ?request_output index) defs

let normalize_module ?(constructors = true) source_declarations statements =
  let variable_declarations, statements =
    normalize_variables source_declarations statements
  in
  let sort_declarations, statements =
    List.partition
      (function SortDecl _ | SubsortDecl _ -> true | _ -> false)
      statements
  in
  let operator_declarations, definitions =
    List.partition (function OpDecl _ -> true | _ -> false) statements
  in
  let operator_declarations =
    if constructors then normalize_constructor_declarations operator_declarations
    else operator_declarations
  in
  sort_declarations @ operator_declarations
  @ variable_declarations @ definitions

let translate_script script =
  let index = Prescan.scan script in
  let sort_metadata = Prescan.sort_metadata index in
  let output_requests = ref [] in
  let request_output iteration position =
    let request = iteration.Prescan.name, position in
    if not (List.mem request !output_requests) then
      output_requests := request :: !output_requests
  in
  let translated_definitions =
    List.concat_map (translate ~request_output index) script
    @ Param.translate_applications index
  in
  let iterations =
    let bind_body bound body subject =
      let result =
        Prem.bind_pattern index bound body subject
          "computed IterE body is not invertible"
      in
      result.conditions, result.bound
    in
    Iter.translate_all
      (Prem.translate_pattern_parts index)
      (Prem.can_bind_computed_pattern index)
      bind_body
      (Term.translate_exp index) index
  in
  let premise_iterations =
    let translate_body allow_membership iteration bound body =
      let bind_membership =
        allow_membership
        && Prescan.premise_iteration_binds_membership index iteration
      in
      let result =
        Prem.translate_all index ~bound ~bind_membership [body]
      in
      result.conditions, result.otherwise, result.bound
    in
    Iter.translate_premise_all translate_body index !output_requests
  in
  let typed_list_support = Typed_list.statements sort_metadata in
  let list_statements =
    normalize_module ~constructors:false [] typed_list_support
  in
  let generated_statements =
    Typed_list.generated_statements sort_metadata
    @ translated_definitions @ iterations @ premise_iterations
    |> normalize_module (Prescan.variable_declarations index)
  in
  { sort_statements = sort_metadata_declarations sort_metadata
  ; list_views = Typed_list.views sort_metadata
  ; list_imports = Typed_list.imports sort_metadata
  ; list_statements
  ; generated_statements
  }
