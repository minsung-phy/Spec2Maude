open Util.Source
open Il.Ast
open Maude_il

module StringSet = Set.Make (String)

let normalize_constructor_declarations statements =
  let declarations = Hashtbl.create 64 in
  let keep = function
    | OpDecl declaration ->
        let key = declaration.name, declaration.domain in
        begin match
          Hashtbl.find_opt declarations key
        with
        | Some previous when List.mem Ctor declaration.attrs ->
            if previous.codomain = declaration.codomain
               && previous.arrow = declaration.arrow
               && previous.attrs = declaration.attrs then false
            else
              invalid_arg
                (Printf.sprintf
                   "unsupported constructor signature for %s: %s and %s"
                   declaration.name previous.codomain declaration.codomain)
        | None | Some _ ->
            Hashtbl.replace declarations key declaration;
            true
        end
    | _ -> true
  in
  List.filter keep statements

let sort_metadata_declarations metadata =
  let annotated =
    Hintd.annotated_sorts metadata |> List.map (fun sort -> SortDecl sort)
  in
  let proper = Hintd.proper_sorts metadata in
  let proper_declarations =
    List.map (fun (sort, _) -> SortDecl sort) proper
  in
  let edges =
    Hintd.subsort_edges metadata @ proper
    |> List.map (fun (subsort, supersort) -> SubsortDecl (subsort, supersort))
  in
  annotated @ proper_declarations @ edges

type script_translation =
  { sort_statements : statement list
  ; list_views : top_level list
  ; list_imports : import list
  ; list_subsorts : statement list
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

  let operator_names =
    List.fold_left
      (fun names -> function
        | OpDecl declaration -> StringSet.add declaration.name names
        | _ -> names)
      StringSet.empty statements
  in
  let fresh_generated local_used (variable : variable) =
    let rec choose index =
      let name =
        if index = 1 then variable.name
        else variable.name ^ "-" ^ string_of_int index
      in
      if StringSet.mem name operator_names
         || StringSet.mem name !source_names || StringSet.mem name !local_used then
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

let owner_of def =
  match def.it with
  | TypD (id, _, _) -> "TypD " ^ id.it
  | DecD (id, _, _, _) -> "DecD $" ^ id.it
  | RelD (id, _, _, _, _) -> "RelD " ^ id.it
  | GramD (id, _, _, _) -> "GramD " ^ id.it
  | RecD _ -> "RecD"
  | HintD _ -> "HintD"

let rec translate index def =
  try
    match def.it with
    | TypD (id, params, insts) -> Typd.translate index id params insts
    | DecD (id, params, typ, clauses) -> Decd.translate index id params typ clauses
    | RelD (id, params, mixop, typ, rules) ->
        (* Rules with hint(k_heatcool) are left to Heatcool. *)
        Reld.translate index id params mixop typ rules
        @ Heatcool.translate_relation index id
    | GramD _ | HintD _ -> []
    | RecD defs -> List.concat_map (translate index) defs
  with Invalid_argument reason ->
    Util.Error.error def.at "translation"
      ("Unsupported " ^ owner_of def ^ ": " ^ reason)

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

(* Def-parameter specialization runs before Prescan: every call of a DecD with
 * DefP parameters is redirected to a Decd.specialize copy for its DefA
 * targets, so translation never sees DefP or DefA. *)

let unsupported at case owner reason =
  Util.Error.error at "translation"
    ("Unsupported " ^ case ^ " in " ^ owner ^ ": " ^ reason)

(* Collection *)

let collect declarations script =
  let instances = ref [] in
  let owner = ref "" in
  let bound = ref [] in
  let target arg =
    match arg.it with
    | DefA id when List.mem id.it !bound ->
        unsupported arg.at "DefA" !owner
          ("$" ^ id.it ^ " is a def parameter of the enclosing definition;"
           ^ " passing a received function on is not specialized")
    | DefA id when List.mem_assoc id.it declarations -> id
    | DefA id ->
        unsupported arg.at "DefA" !owner ("$" ^ id.it ^ " is not a declared DecD")
    | ExpA _ | TypA _ | GramA _ ->
        unsupported arg.at "CallE argument" !owner
          "a def parameter position expects a DefA argument"
  in
  let inspect exp =
    begin match exp.it with
    | CallE (callee, args)
      when List.mem callee.it !bound
           && List.exists
                (fun arg ->
                  match arg.it with
                  | DefA _ -> true
                  | ExpA _ | TypA _ | GramA _ -> false)
                args ->
        unsupported exp.at "CallE" !owner
          ("def parameter $" ^ callee.it ^ " receives a DefA argument;"
           ^ " def parameters with def parameters are not specialized")
    | CallE (callee, args) ->
        begin match List.assoc_opt callee.it declarations with
        | Some params when List.exists Param.is_def params ->
            let _, def_args = Param.split_def_positions params args in
            let targets = List.map target def_args in
            let same instance =
              instance.Decd.callee.it = callee.it
              && List.map (fun id -> id.it) instance.Decd.targets
                 = List.map (fun id -> id.it) targets
            in
            if not (List.exists same !instances) then
              let name =
                String.concat "" (callee.it :: List.map (fun id -> id.it) targets)
              in
              if List.mem_assoc name declarations
                 || List.exists (fun instance -> instance.Decd.copy.it = name) !instances
              then
                unsupported exp.at "CallE" !owner
                  ("specialized name $" ^ name ^ " is already used");
              instances :=
                {Decd.callee; targets; copy = name $ callee.at} :: !instances
        | Some _ | None -> ()
        end
    | _ -> ()
    end;
    exp
  in
  (* The same traversal as replace_calls, so every rewritten call is collected. *)
  let visit = {Il.Walk.base_transformer with transform_exp = inspect} in
  List.iter
    (fun def ->
      owner := owner_of def;
      match def.it with
      | DecD (_, params, typ, clauses) ->
          bound := Param.def_ids params;
          List.iter (fun param -> ignore (Il.Walk.transform_param visit param)) params;
          ignore (Il.Walk.transform_typ visit typ);
          List.iter
            (fun clause ->
              let DefD (quants, _, _, _) = clause.it in
              bound := Param.def_ids (params @ quants);
              ignore (Il.Walk.transform_clause visit clause))
            clauses;
          bound := []
      | TypD _ | RelD _ | GramD _ | HintD _ | RecD _ ->
          ignore (Il.Walk.transform_def visit def))
    (List.concat_map Prescan.flatten script);
  List.rev !instances


(* Calls *)

let replace_calls declarations instances def =
  let replace exp =
    match exp.it with
    | CallE (callee, args) ->
        begin match List.assoc_opt callee.it declarations with
        | Some params when List.exists Param.is_def params ->
            let args, def_args = Param.split_def_positions params args in
            let targets =
              List.map
                (fun arg ->
                  match arg.it with
                  | DefA id -> id.it
                  | ExpA _ | TypA _ | GramA _ ->
                      invalid_arg "collected call lost its DefA argument")
                def_args
            in
            let instance =
              List.find
                (fun instance ->
                  instance.Decd.callee.it = callee.it
                  && List.map (fun id -> id.it) instance.Decd.targets = targets)
                instances
            in
            {exp with it = CallE (instance.Decd.copy, args)}
        | Some _ | None -> exp
        end
    | _ -> exp
  in
  Il.Walk.transform_def {Il.Walk.base_transformer with transform_exp = replace} def


(* Remaining def arguments have no specialization. *)

let check_remaining def =
  let owner = owner_of def in
  let reject_def_params params =
    List.iter
      (fun param ->
        if Param.is_def param then
          unsupported param.at "DefP" owner
            "def parameters are specialized only for DecD")
      params
  in
  begin match def.it with
  | TypD (_, params, _) | RelD (_, params, _, _, _) | GramD (_, params, _, _) ->
      reject_def_params params
  | DecD _ | HintD _ | RecD _ -> ()
  end;
  let reject arg =
    match arg.it with
    | DefA id ->
        unsupported arg.at "DefA" owner
          ("$" ^ id.it ^ " is passed outside a DecD call")
    | ExpA _ | TypA _ | GramA _ -> arg
  in
  ignore
    (Il.Walk.transform_def
       {Il.Walk.base_transformer with transform_arg = reject} def)

(* Translator hints that describe the higher-order definition itself would
 * not describe its copies. *)
let check_hints higher_order script =
  List.iter
    (fun def ->
      match def.it with
      | HintD {it = DecH (id, hints); _} when List.mem id.it higher_order ->
          List.iter
            (fun hint ->
              match hint.hintid.it with
              | "builtin" | "maude_kind" | "maude_rule" | "inverse" ->
                  unsupported hint.hintid.at "DecH" ("DecD $" ^ id.it)
                    (hint.hintid.it ^ " hint on a definition with def parameters")
              | _ -> ())
            hints
      | _ -> ())
    (List.concat_map Prescan.flatten script)


let specialize_script script =
  let declarations =
    List.filter_map
      (fun def ->
        match def.it with
        | DecD (id, params, _, _) -> Some (id.it, params)
        | TypD _ | RelD _ | GramD _ | HintD _ | RecD _ -> None)
      (List.concat_map Prescan.flatten script)
  in
  let higher_order =
    List.filter_map
      (fun (id, params) ->
        if List.exists Param.is_def params then Some id else None)
      declarations
  in
  check_hints higher_order script;
  let instances = collect declarations script in
  (* A copy is placed where its source definition was; a definition with def
   * parameters and no call produces no copy. *)
  let rec place def =
    match def.it with
    | DecD (id, _, _, _) when List.mem id.it higher_order ->
        instances
        |> List.filter (fun instance -> instance.Decd.callee.it = id.it)
        |> List.map (fun specialization ->
             match def.it with
             | DecD (_, params, result_typ, clauses) ->
                 Decd.specialize specialization id params result_typ clauses $ def.at
             | TypD _ | RelD _ | GramD _ | HintD _ | RecD _ -> assert false)
    | RecD defs -> [{def with it = RecD (List.concat_map place defs)}]
    | TypD _ | RelD _ | DecD _ | GramD _ | HintD _ -> [def]
  in
  let script =
    script
    |> List.concat_map place
    |> List.map (replace_calls declarations instances)
  in
  List.iter check_remaining (List.concat_map Prescan.flatten script);
  script

(* hint(maude_assume "Rel" ...) on a rule or definition omits its premises on
 * the named relations. Each premise is assumed to hold for every admitted
 * input, e.g. a module that passed the frontend validator; the assumption is
 * recorded with the hint in docs/TRANSLATION.md, not checked here. *)

let assumed_relations owner hints =
  hints
  |> List.filter (fun hint -> hint.hintid.it = "maude_assume")
  |> List.concat_map (fun hint ->
       let name (exp : El.Ast.exp) =
         match exp.it with
         | El.Ast.TextE name -> name
         | _ ->
             unsupported hint.hintid.at "hint" owner
               "maude_assume expects relation names as strings"
       in
       match hint.hintexp.it with
       | El.Ast.SeqE exps -> List.map name exps
       | _ -> [name hint.hintexp])

let rec premise_relation prem =
  match prem.it with
  | RulePr (id, _, _, _) -> Some id.it
  | IterPr (prem, _) -> premise_relation prem
  | IfPr _ | LetPr _ | ElsePr | NegPr _ -> None

let omit_assumed at owner names prems =
  let assumed prem =
    match premise_relation prem with
    | Some id -> List.mem id names
    | None -> false
  in
  List.iter
    (fun name ->
      if not (List.exists (fun prem -> premise_relation prem = Some name) prems)
      then
        unsupported at "hint" owner
          ("maude_assume names " ^ name ^ ", which is not a premise here"))
    names;
  List.filter (fun prem -> not (assumed prem)) prems

(* Variables that occurred only in omitted premises are no longer quantified. *)
let used_quants free quants =
  List.filter
    (fun quant ->
      match quant.it with
      | ExpP (id, _) -> Il.Free.Set.mem id.it free.Il.Free.varid
      | TypP _ | DefP _ | GramP _ -> true)
    quants

let assume_script script =
  let hints = Prescan.collect_hints script in
  let rule_hints relation rule =
    List.concat_map
      (fun hintdef ->
        match hintdef.it with
        | RuleH (r, id, values) when r.it = relation && id.it = rule -> values
        | TypH _ | RelH _ | DecH _ | GramH _ | RuleH _ -> [])
      hints
  in
  let dec_hints definition =
    List.concat_map
      (fun hintdef ->
        match hintdef.it with
        | DecH (id, values) when id.it = definition -> values
        | TypH _ | RelH _ | DecH _ | GramH _ | RuleH _ -> [])
      hints
  in
  let rule relation r =
    let RuleD (id, quants, mixop, exp, prems) = r.it in
    let owner = "RuleD " ^ relation ^ "/" ^ id.it in
    match assumed_relations owner (rule_hints relation id.it) with
    | [] -> r
    | names ->
        let prems = omit_assumed r.at owner names prems in
        let free = Il.Free.(free_exp exp ++ free_prems prems) in
        {r with it = RuleD (id, used_quants free quants, mixop, exp, prems)}
  in
  let clause owner names c =
    let DefD (quants, args, exp, prems) = c.it in
    let prems = omit_assumed c.at owner names prems in
    let free = Il.Free.(free_args args ++ free_exp exp ++ free_prems prems) in
    {c with it = DefD (used_quants free quants, args, exp, prems)}
  in
  let rec transform def =
    match def.it with
    | RelD (id, params, mixop, typ, rules) ->
        {def with it = RelD (id, params, mixop, typ, List.map (rule id.it) rules)}
    | DecD (id, params, typ, clauses) ->
        let owner = "DecD $" ^ id.it in
        begin match assumed_relations owner (dec_hints id.it) with
        | [] -> def
        | names ->
            {def with it = DecD (id, params, typ, List.map (clause owner names) clauses)}
        end
    | RecD defs -> {def with it = RecD (List.map transform defs)}
    | TypD _ | GramD _ | HintD _ -> def
  in
  List.map transform script

let translate_script script =
  let script = specialize_script (assume_script script) in
  let index = Prescan.scan script in
  (* Relations without a supported policy are omitted; a call to one is
     rejected later, but an unreferenced one would vanish silently. *)
  begin match index.Prescan.unsupported_relations with
  | [] -> ()
  | relations ->
      Printf.eprintf "[spec2maude] warning: relations not translated: %s\n"
        (String.concat ", " (List.map fst relations))
  end;
  let sort_metadata = Prescan.sort_metadata index in
  let translated_definitions =
    List.concat_map (translate index) script
  in
  let premise_iterations = Iter_helpers.translate_premise_all index in
  let typed_list_support = Typd.list_statements sort_metadata in
  let list_statements =
    normalize_module ~constructors:false [] typed_list_support
  in
  let generated_statements =
    Typd.list_generated_statements sort_metadata
    @ translated_definitions
  in
  let iterations = Iter_helpers.translate_all index in
  let generated_statements =
    generated_statements
    @ iterations @ premise_iterations
    |> normalize_module (Prescan.variable_declarations index)
  in
  { sort_statements = sort_metadata_declarations sort_metadata
  ; list_views = Typd.list_views sort_metadata
  ; list_imports = Typd.list_imports sort_metadata
  ; list_subsorts = Typd.list_subsorts sort_metadata
  ; list_statements
  ; generated_statements
  }
