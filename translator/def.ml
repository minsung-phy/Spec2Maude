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
              raise (Unsupported
                (Printf.sprintf
                   "unsupported constructor signature for %s: %s and %s"
                   declaration.name previous.codomain declaration.codomain))
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
  let edges =
    Hintd.subsort_edges metadata
    |> List.map (fun (subsort, supersort) -> SubsortDecl (subsort, supersort))
  in
  annotated @ edges

type script_translation =
  { sort_statements : statement list
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
    | Some _ -> raise (Unsupported ("variable " ^ name ^ " has conflicting sorts"))
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
                  raise (Unsupported ("source variable " ^ name ^ " has conflicting sorts")))
            names
      | _ -> raise (Unsupported "expected a variable declaration"))
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
              raise (Unsupported ("source variable " ^ variable.name ^ " changed sort"))
          | None ->
              raise (Unsupported ("undeclared source variable " ^ variable.name))
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
    | VarDecl _ -> raise (Unsupported "variable declarations are rebuilt after lowering")
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
  located def.at (owner_of def) @@ fun () ->
  match def.it with
  | TypD (id, params, insts) -> Typd.translate index id params insts
  | DecD (id, params, typ, clauses) -> Decd.translate index id params typ clauses
  | RelD (id, params, mixop, typ, rules) ->
      (* Rules with hint(k_heatcool) are left to Heatcool. *)
      Reld.translate index id params mixop typ rules
      @ Heatcool.translate_relation index id
  | GramD _ | HintD _ -> []
  | RecD defs -> List.concat_map (translate index) defs

let normalize_module ?(constructors = true) source_declarations statements =
  let variable_declarations, statements =
    normalize_variables source_declarations statements
  in
  let sort_declarations, statements =
    List.partition
      (function SortDecl _ | SubsortDecl _ -> true | _ -> false)
      statements
  in
  (* Helpers may declare the same request sort (Iter_helpers). *)
  let sort_declarations =
    List.fold_left (fun kept d -> Hintd.add_unique ( = ) d kept) [] sort_declarations
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

(* Generated helpers (TRANSLATION_MAP.md, section 6). Every IterE, IterPr,
 * and membership choice gets its own helper, under a unique working name
 * (Prescan). After translation, helpers whose statements are equal up to
 * variable names are one helper: the later ones are dropped and their calls
 * go to the first. Each remaining helper is then named from its base
 * (Prescan.helper_name). *)

let rec rename_term rename = function
  | Var _ as term -> term
  | Const name -> Const (rename name)
  | App (name, args) -> App (rename name, List.map (rename_term rename) args)

let rename_statement rename statement =
  match map_statement_terms (rename_term rename) statement with
  | OpDecl declaration -> OpDecl {declaration with name = rename declaration.name}
  | statement -> statement

(* The operator a statement declares or defines. *)
let defined_name = function
  | OpDecl declaration -> Some declaration.name
  | Eq (App (name, _), _, _) | Ceq (App (name, _), _, _, _)
  | Rl (_, App (name, _), _) | Crl (_, App (name, _), _, _) -> Some name
  | SortDecl _ | SubsortDecl _ | VarDecl _
  | Eq _ | Ceq _ | Rl _ | Crl _ -> None

(* A helper's statements with its own name blanked, calls resolved, and the
 * variables of each statement numbered in order of occurrence. *)
let canonical resolve name statements =
  let variables statement =
    let seen = ref [] in
    map_statement_variables
      (fun variable ->
        match List.find_opt (fun (seen, _) -> same_variable variable seen) !seen with
        | Some (_, numbered) -> numbered
        | None ->
            let numbered =
              source_variable (string_of_int (List.length !seen)) variable.sort
            in
            seen := (variable, numbered) :: !seen;
            numbered)
      statement
  in
  List.map
    (fun statement ->
      rename_statement (fun called -> if called = name then "" else resolve called) statement
      |> variables)
    statements

let share_helpers index statements =
  let bases = Prescan.helper_names index in
  let helpers =
    List.filter_map
      (function
        | OpDecl declaration when List.mem_assoc declaration.name bases ->
            Some declaration.name
        | _ -> None)
      statements
  in
  let defining name =
    List.filter (fun statement -> defined_name statement = Some name) statements
  in
  let shared = Hashtbl.create 64 in
  let rec resolve name =
    match Hashtbl.find_opt shared name with
    | Some first -> resolve first
    | None -> name
  in
  (* Sharing a callee can make its callers equal, so repeat until stable. *)
  let rec merge () =
    let firsts = Hashtbl.create 64 in
    let merged = ref false in
    List.iter
      (fun name ->
        if not (Hashtbl.mem shared name) then
          let key = canonical resolve name (defining name) in
          match Hashtbl.find_opt firsts key with
          | Some first ->
              Hashtbl.replace shared name first;
              merged := true
          | None -> Hashtbl.add firsts key name)
      helpers;
    if !merged then merge ()
  in
  merge ();
  let statements =
    statements
    |> List.filter (fun statement ->
         match defined_name statement with
         | Some name -> not (Hashtbl.mem shared name)
         | None -> true)
    |> List.map (rename_statement resolve)
  in
  let kept = List.filter (fun name -> not (Hashtbl.mem shared name)) helpers in
  (* Helpers that would get the same name move on to their next candidate,
     until no two share one or their candidates run out. *)
  let level = Hashtbl.create 64 in
  let candidate name =
    match List.assoc name bases with
    | Prescan.Base candidates ->
        let k = Option.value (Hashtbl.find_opt level name) ~default:0 in
        Some (List.nth candidates (min k (List.length candidates - 1)))
    | Prescan.Tail _ -> None
  in
  let rec separate () =
    let moved = ref false in
    List.iter
      (fun name ->
        match List.assoc name bases, candidate name with
        | Prescan.Base candidates, Some current ->
            let k = Option.value (Hashtbl.find_opt level name) ~default:0 in
            let others =
              List.filter (fun other -> other <> name && candidate other = Some current) kept
            in
            if others <> [] && k < List.length candidates - 1 then begin
              List.iter
                (fun other ->
                  let k' = Option.value (Hashtbl.find_opt level other) ~default:0 in
                  match List.assoc other bases with
                  | Prescan.Base candidates' when k' < List.length candidates' - 1 ->
                      Hashtbl.replace level other (k' + 1)
                  | _ -> ())
                others;
              Hashtbl.replace level name (k + 1);
              moved := true
            end
        | _ -> ())
      kept;
    if !moved then separate ()
  in
  separate ();
  let used = ref Prescan.StringSet.empty in
  let names = Hashtbl.create 64 in
  let rec final name =
    match Hashtbl.find_opt names name with
    | Some final -> final
    | None ->
        let candidate =
          match List.assoc name bases with
          | Prescan.Base _ -> Option.get (candidate name)
          | Prescan.Tail helper -> final (resolve helper) ^ "-tail"
        in
        let final = Prescan.fresh_helper_name index used candidate in
        Hashtbl.add names name final;
        final
  in
  List.iter (fun name -> ignore (final name)) kept;
  List.map
    (rename_statement (fun name ->
       Option.value (Hashtbl.find_opt names name) ~default:name))
    statements

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
  List.iter
    (fun def ->
      owner := owner_of def;
      match def.it with
      | DecD (_, params, typ, clauses) ->
          bound := Param.def_ids params;
          List.iter (fun param -> ignore (Decd.map_param inspect param)) params;
          ignore (Decd.map_typ inspect typ);
          List.iter
            (fun clause ->
              let DefD (quants, _, _, _) = clause.it in
              bound := Param.def_ids (params @ quants);
              ignore (Decd.map_clause inspect clause))
            clauses;
          bound := []
      | TypD _ | RelD _ | GramD _ | HintD _ | RecD _ ->
          ignore (Decd.map_def inspect def))
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
                      raise (Unsupported "collected call lost its DefA argument"))
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
  Decd.map_def replace def


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
  let reject args =
    List.iter
      (fun arg ->
        match arg.it with
        | DefA id ->
            unsupported arg.at "DefA" owner
              ("$" ^ id.it ^ " is passed outside a DecD call")
        | ExpA _ | TypA _ | GramA _ -> ())
      args
  in
  (* Every argument list of the IL: calls, type and grammar uses, premises,
     and the heads of instances and clauses. *)
  let module Remaining = Il.Iter.Make (struct
    include Il.Iter.Skip
    let visit_exp exp =
      match exp.it with CallE (_, args) -> reject args | _ -> ()
    let visit_typ typ =
      match typ.it with VarT (_, args) -> reject args | _ -> ()
    let visit_sym sym =
      match sym.it with VarG (_, args) -> reject args | _ -> ()
    let visit_prem prem =
      match prem.it with RulePr (_, args, _, _) -> reject args | _ -> ()
    let visit_def def =
      match def.it with
      | TypD (_, _, insts) ->
          List.iter (fun {it = InstD (_, args, _); _} -> reject args) insts
      | DecD (_, _, _, clauses) ->
          List.iter (fun {it = DefD (_, args, _, _); _} -> reject args) clauses
      | RelD _ | GramD _ | RecD _ | HintD _ -> ()
  end) in
  Remaining.def def

(* Translator hints that describe the higher-order definition itself would
 * not describe its copies. hint(maude_disjoint) is for definitions only. *)
let check_hints higher_order script =
  let only_definitions kind owner hints =
    List.iter
      (fun hint ->
        if hint.hintid.it = "maude_disjoint" then
          unsupported hint.hintid.at kind owner
            "maude_disjoint is a hint on a definition (DecD)")
      hints
  in
  List.iter
    (fun def ->
      match def.it with
      | TypD (id, _, insts) ->
          List.iter
            (fun inst ->
              let InstD (_, _, deftyp) = inst.it in
              match deftyp.it with
              | VariantT cases ->
                  List.iter
                    (fun (_, _, hints) -> only_definitions "case hint" ("TypD " ^ id.it) hints)
                    cases
              | StructT fields ->
                  List.iter
                    (fun (_, _, hints) -> only_definitions "field hint" ("TypD " ^ id.it) hints)
                    fields
              | AliasT _ -> ())
            insts
      | HintD {it = TypH (id, hints); _} -> only_definitions "TypH" ("TypD " ^ id.it) hints
      | HintD {it = RelH (id, hints); _} -> only_definitions "RelH" ("RelD " ^ id.it) hints
      | HintD {it = GramH (id, hints); _} -> only_definitions "GramH" ("GramD " ^ id.it) hints
      | HintD {it = RuleH (id, rule_id, hints); _} ->
          only_definitions "RuleH" ("RelD " ^ id.it ^ "/" ^ rule_id.it) hints
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
    | DecD (id, params, result_typ, clauses) when List.mem id.it higher_order ->
        instances
        |> List.filter (fun instance -> instance.Decd.callee.it = id.it)
        |> List.map (fun specialization ->
             Decd.specialize specialization id params result_typ clauses $ def.at)
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
  | IfPr _ | LetPr _ | ElsePr -> None

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
        {r with it = RuleD (id, Prem.used_quants free quants, mixop, exp, prems)}
  in
  let clause owner names c =
    let DefD (quants, args, exp, prems) = c.it in
    let prems = omit_assumed c.at owner names prems in
    let free = Il.Free.(free_args args ++ free_exp exp ++ free_prems prems) in
    {c with it = DefD (Prem.used_quants free quants, args, exp, prems)}
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

(* hint(maude_array), hint(maude_map): a premise e = {.., f x*} binds x* to
   the array or map stored in e.f, so x* equals e.f. Later premises and the
   result use e.f in place of x*, which gets the stored translation (|e.f| is
   the stored size, e.f s grows it); the binding premise is kept. *)
let stored_script script =
  let stored = Hintd.scan_stored script in
  let bound_variable exp =
    match exp.it with
    | VarE x -> Some x
    | IterE ({it = VarE y; _}, (_, [(y', {it = VarE x; _})])) when y.it = y'.it ->
        Some x
    | _ -> None
  in
  let field_bindings record pattern =
    match pattern.it with
    | StrE (fields, _) ->
        fields
        |> List.filter_map (fun (atom, value) ->
             if Hintd.stored_field stored pattern.note atom = None then None
             else
               bound_variable value
               |> Option.map (fun x -> x, DotE (record, atom) $$ (value.at, value.note)))
    | _ -> []
  in
  let premise_bindings prem =
    match prem.it with
    | IfPr {it = CmpE (`EqOp, _, left, right); _} ->
        field_bindings left right @ field_bindings right left
    | LetPr (_, pattern, value) -> field_bindings value pattern
    | _ -> []
  in
  (* Substitution renames iteration binders, so it is applied only after a
     binding exists; other clauses stay unchanged. *)
  let substitute exp prems =
    let apply bindings f x =
      if bindings = [] then x
      else
        let subst =
          List.fold_left
            (fun subst (x, field) -> Il.Subst.add_varid subst x field)
            Il.Subst.empty bindings
        in
        f subst x
    in
    let bindings, prems =
      List.fold_left
        (fun (bindings, prems) prem ->
          let prem = apply bindings Il.Subst.subst_prem prem in
          bindings @ premise_bindings prem, prem :: prems)
        ([], []) prems
    in
    apply bindings Il.Subst.subst_exp exp, List.rev prems
  in
  let clause c =
    let DefD (quants, args, exp, prems) = c.it in
    let exp, prems = substitute exp prems in
    {c with it = DefD (quants, args, exp, prems)}
  in
  let rule r =
    let RuleD (id, quants, mixop, exp, prems) = r.it in
    let exp, prems = substitute exp prems in
    {r with it = RuleD (id, quants, mixop, exp, prems)}
  in
  let rec transform def =
    match def.it with
    | DecD (id, params, typ, clauses) ->
        {def with it = DecD (id, params, typ, List.map clause clauses)}
    | RelD (id, params, mixop, typ, rules) ->
        {def with it = RelD (id, params, mixop, typ, List.map rule rules)}
    | RecD defs -> {def with it = RecD (List.map transform defs)}
    | TypD _ | GramD _ | HintD _ -> def
  in
  List.map transform script

(* Operations on literals, such as 2^32 - 1, are replaced by their value
 * (Xl.Num, Xl.Bool), innermost first by Decd.map_exp. An undefined operation,
 * such as 1 \ 0, is kept, and so is any operation on a non-literal, even
 * 0 * e: the IL evaluates e first (Step_exp/BIN), which may fail. *)
let fold_ground e =
  let it =
    match e.it with
    | UnE (#Xl.Num.unop as op, _, {it = NumE n; _}) ->
        Option.map (fun n -> NumE n) (Xl.Num.un op n)
    | BinE (#Xl.Num.binop as op, _, {it = NumE n1; _}, {it = NumE n2; _}) ->
        Option.map (fun n -> NumE n) (Xl.Num.bin op n1 n2)
    | CvtE ({it = NumE n; _}, _, nt) -> Option.map (fun n -> NumE n) (Xl.Num.cvt nt n)
    | CmpE (#Xl.Num.cmpop as op, _, {it = NumE n1; _}, {it = NumE n2; _}) ->
        Option.map (fun b -> BoolE b) (Xl.Num.cmp op n1 n2)
    | CmpE (#Xl.Bool.cmpop as op, _, {it = NumE n1; _}, {it = NumE n2; _}) ->
        Some (BoolE (Xl.Bool.cmp op n1 n2))
    | UnE (#Xl.Bool.unop as op, _, {it = BoolE b; _}) -> Some (BoolE (Xl.Bool.un op b))
    | BinE (#Xl.Bool.binop as op, _, {it = BoolE b1; _}, {it = BoolE b2; _}) ->
        Some (BoolE (Xl.Bool.bin op b1 b2))
    | _ -> None
  in
  match it with Some it -> {e with it} | None -> e

let fold_script script = List.map (Decd.map_def fold_ground) script

(* A use of a variable has the type of its binder. The elaborator may note a
 * use with an equivalent type instead (val* as instr* when val and instr have
 * the same cases), and the translator names a variable after its type, so
 * such a use would become another variable. Give each such use its binder's
 * type. *)
let binder_type_script script =
  let env = Il.Env.env_of_script script in
  let binder_types quants =
    let binders =
      List.filter_map
        (fun param -> match param.it with ExpP (id, typ) -> Some (id.it, typ) | _ -> None)
        quants
    in
    fun exp ->
      match exp.it with
      | VarE id ->
          begin match List.assoc_opt id.it binders with
          | Some typ
            when not (Il.Eq.eq_typ typ exp.note) && Il.Eval.equiv_typ env typ exp.note ->
              {exp with note = typ}
          | Some _ | None -> exp
          end
      | _ -> exp
  in
  let rule ({it = RuleD (id, quants, mixop, exp, prems); _} as rule) =
    let f = binder_types quants in
    {rule with
     it = RuleD (id, quants, mixop, Decd.map_exp f exp, List.map (Decd.map_prem f) prems)}
  in
  let clause ({it = DefD (quants, _, _, _); _} as clause) =
    Decd.map_clause (binder_types quants) clause
  in
  let rec def d =
    match d.it with
    | RelD (id, params, mixop, typ, rules) ->
        {d with it = RelD (id, params, mixop, typ, List.map rule rules)}
    | DecD (id, params, typ, clauses) ->
        {d with it = DecD (id, params, typ, List.map clause clauses)}
    | RecD defs -> {d with it = RecD (List.map def defs)}
    | TypD _ | GramD _ | HintD _ -> d
  in
  List.map def script

(* Case premises (IL reduction, Step_exp/INJ): a value built by an unchecked
 * case constructor C e is a value only if the premises of C's case hold for
 * the payload e; otherwise the construction fails. Each evaluated
 * construction therefore adds its case premises, instantiated with the
 * payload, in front of the premise that evaluates it, or after the premises
 * for a rule output or definition result. Inside an iteration the premises
 * are iterated likewise. A construction with an unbound variable is a pattern
 * that only matches existing values, as are relation inputs and definition
 * arguments. A definition with such premises may have no result, so it is
 * partial (Prescan.partial_defs). *)

type case_checks =
  { checks : prem list  (* all added premises *)
  ; result_checks : prem list  (* those for rule outputs and results *)
  ; partial : string list  (* definitions with added premises *)
  }

let deftyp env owner typ =
  match Il.Eval.reduce_typdef env typ with
  | Ok dt -> dt
  | Error _ -> unsupported typ.at "case type" owner "type does not reduce to a definition"

let rec element_typ typ =
  match typ.it with IterT (typ, _) -> element_typ typ | _ -> typ

let has_field_premises fields =
  List.exists (fun (_, (_, _, prems), _) -> prems <> []) fields

(* Subsumption and field update recheck the premises of the result's case or
   fields (Step_exp/SUB-INJ, SUB-STR, UPD-DOT); they are not instantiated, so
   an evaluated one whose type has such premises is rejected. A variant case
   whose payload type, quantifiers, and premises equal those of the source
   case (e.g. instr <: admininstr, where admininstr includes instr) needs no
   recheck: a value of the source case already satisfies those premises
   (evaluated constructions are checked, see case_premise_script). *)
let same_case (typ1, quants1, prems1) (typ2, quants2, prems2) =
  Il.Eq.eq_typ typ1 typ2
  && Il.Eq.eq_list Il.Eq.eq_param quants1 quants2
  && Il.Eq.eq_list Il.Eq.eq_prem prems1 prems2

let recheck env owner exp =
  let fail case = unsupported exp.at case owner "rechecked premises are not instantiated" in
  match exp.it with
  | SubE (_, t1, t2) ->
      let source = deftyp env owner (element_typ t1) in
      begin match source.it, (deftyp env owner (element_typ t2)).it with
      | VariantT cases1, VariantT cases2
        when List.exists
               (fun (op, ((_, _, prems) as case2), _) ->
                 prems <> []
                 && List.exists
                      (fun (op', case1, _) ->
                        Xl.Mixop.eq op op' && not (same_case case1 case2))
                      cases1)
               cases2 ->
          fail "SubE"
      | _, StructT fields when has_field_premises fields -> fail "SubE"
      | _ -> ()
      end
  | UpdE (_, path, _) | ExtE (_, path, _) ->
      let rec dots path =
        match path.it with
        | RootP -> ()
        | DotP (p, _) ->
            begin match (deftyp env owner p.note).it with
            | StructT fields when has_field_premises fields -> fail "UpdE"
            | _ -> dots p
            end
        | IdxP (p, _) | SliceP (p, _, _) -> dots p
      in
      dots path
  | _ -> ()

let case_premises env owner bound exp =
  match exp.it with
  | CaseE (op, payload, Unchecked)
    when Il.Free.Set.subset (Il.Free.free_exp exp).varid bound ->
      begin match (deftyp env owner exp.note).it with
      | VariantT cases ->
          begin match List.find_opt (fun (op', _, _) -> Xl.Mixop.eq op op') cases with
          | Some (_, (_, _, []), _) -> [], []
          | Some (_, (typ, quants, prems), _) ->
              (* Only named binders of a tuple case occur in its premises. *)
              let subst =
                match typ.it, payload.it with
                | TupT binders, TupE values
                  when List.length values = List.length binders ->
                    List.fold_left2
                      (fun subst (x, _) value -> Il.Subst.add_varid subst x value)
                      Il.Subst.empty binders values
                | TupT _, _ ->
                    unsupported exp.at "CaseE" owner
                      "case payload does not match its case binders"
                | _ -> Il.Subst.empty
              in
              let subst, quants =
                List.fold_left_map
                  (fun subst quant ->
                    match quant.it with
                    | ExpP (x, typ) ->
                        let x' = Il.Fresh.refresh_varid x in
                        let typ = Il.Subst.subst_typ subst typ in
                        ( Il.Subst.add_varid subst x (VarE x' $$ x.at % typ)
                        , ExpP (x', typ) $ quant.at )
                    | TypP _ | DefP _ | GramP _ ->
                        unsupported quant.at "case quantifier" owner
                          "only expression quantifiers are instantiated")
                  subst quants
              in
              (* Instantiation makes operations on literals, folded as in the
                 rest of the script; a premise folded to true holds for every
                 construction and is omitted. *)
              let instantiate prem =
                match prem.it with
                | IfPr e ->
                    let e = Decd.map_exp fold_ground e in
                    if e.it = BoolE true then None else Some (IfPr e $ prem.at)
                | RulePr _ | LetPr _ | ElsePr | IterPr _ -> Some prem
              in
              ( quants
              , List.filter_map instantiate (Il.Subst.subst_prems subst prems) )
          | None -> unsupported exp.at "CaseE" owner "case is not in its variant type"
          end
      | AliasT _ | StructT _ ->
          unsupported exp.at "CaseE" owner "constructed type is not a variant"
      end
  | StrE (_, Unchecked)
    when Il.Free.Set.subset (Il.Free.free_exp exp).varid bound ->
      begin match (deftyp env owner exp.note).it with
      | StructT fields when not (has_field_premises fields) -> [], []
      | StructT _ ->
          unsupported exp.at "StrE" owner "record field premises are not instantiated"
      | AliasT _ | VariantT _ ->
          unsupported exp.at "StrE" owner "constructed type is not a record"
      end
  | _ -> [], []

let concat_premises parts = List.concat_map fst parts, List.concat_map snd parts

(* The case premises of the constructions evaluated in exp, inner first. An
 * evaluated subsumption or update is also checked by recheck. *)
let rec exp_case_premises env owner bound exp =
  let sub = exp_case_premises env owner bound in
  let concat = concat_premises in
  let inner =
    match exp.it with
    | VarE _ | BoolE _ | NumE _ | TextE _ -> [], []
    | UnE (_, _, e1) | ProjE (e1, _) | UncaseE (e1, _) | TheE e1 | DotE (e1, _)
    | LiftE e1 | LenE e1 | CvtE (e1, _, _) | SubE (e1, _, _) | CaseE (_, e1, _) ->
        sub e1
    | StrE (fields, _) -> concat (List.map (fun (_, e) -> sub e) fields)
    | OptE eo -> concat (List.map sub (Option.to_list eo))
    | TupE es | ListE es -> concat (List.map sub es)
    | BinE (_, _, e1, e2) | CmpE (_, _, e1, e2) | CompE (e1, e2) | MemE (e1, e2)
    | CatE (e1, e2) | IdxE (e1, e2) ->
        concat [sub e1; sub e2]
    | SliceE (e1, e2, e3) -> concat [sub e1; sub e2; sub e3]
    | UpdE (e1, path, e2) | ExtE (e1, path, e2) ->
        concat [sub e1; path_case_premises env owner bound path; sub e2]
    | CallE (_, args) ->
        concat
          (List.map
             (fun arg ->
               match arg.it with
               | ExpA e -> sub e
               | TypA _ | DefA _ | GramA _ -> [], [])
             args)
    | IterE (body, iterexp) ->
        iterexp_case_premises env owner bound iterexp
          (fun bound -> exp_case_premises env owner bound body)
  in
  if Il.Free.Set.subset (Il.Free.free_exp exp).varid bound then recheck env owner exp;
  let quants, prems = case_premises env owner bound exp in
  fst inner @ quants, snd inner @ prems

and path_case_premises env owner bound path =
  match path.it with
  | RootP -> [], []
  | DotP (p, _) -> path_case_premises env owner bound p
  | IdxP (p, e) ->
      concat_premises
        [path_case_premises env owner bound p; exp_case_premises env owner bound e]
  | SliceP (p, e1, e2) ->
      concat_premises
        [ path_case_premises env owner bound p
        ; exp_case_premises env owner bound e1
        ; exp_case_premises env owner bound e2 ]

(* The body's premises hold for each element, so they iterate with it over
 * the elements of the bound sources; an element variable whose source is
 * unbound is a pattern. The sources and the count are evaluated outside the
 * iteration. *)
and iterexp_case_premises env owner bound (iter, generators) body =
  let outside =
    List.map (fun (_, source) -> exp_case_premises env owner bound source) generators
    @ (match iter with
       | ListN (count, _) -> [exp_case_premises env owner bound count]
       | Opt | List | List1 -> [])
  in
  let is_bound e = Il.Free.Set.subset (Il.Free.free_exp e).varid bound in
  let generators = List.filter (fun (_, source) -> is_bound source) generators in
  let local =
    Il.Free.Set.union bound
      (Il.Free.Set.of_list
         (List.map (fun (x, _) -> x.it) generators
          @ (match iter with
             | ListN (count, Some i) when is_bound count -> [i.it]
             | _ -> [])))
  in
  let quants, prems = body local in
  begin match quants with
  | [] -> ()
  | quant :: _ ->
      unsupported quant.at "case quantifier" owner
        "a case quantifier inside an iteration is not iterated"
  end;
  List.concat_map fst outside,
  List.concat_map snd outside
  @ List.map (fun prem -> IterPr (prem, (iter, generators)) $ prem.at) prems

let rec prem_case_premises env owner bound prem =
  match prem.it with
  | RulePr (_, _, _, e) | IfPr e -> exp_case_premises env owner bound e
  | LetPr (_, e1, e2) ->
      concat_premises
        [exp_case_premises env owner bound e1; exp_case_premises env owner bound e2]
  | ElsePr -> [], []
  | IterPr (p, iterexp) ->
      iterexp_case_premises env owner bound iterexp
        (fun bound -> prem_case_premises env owner bound p)

(* Each premise is preceded by the case premises of its evaluated
 * constructions; the variables of a premise are bound after it. Returns the
 * added quantifiers, the premises, and the premises added for prems and for
 * results. *)
let with_case_premises env owner bound prems results =
  let step (bound, quants, checks) prem =
    let quants', checks' = prem_case_premises env owner bound prem in
    ( (Il.Free.Set.union bound (Il.Free.free_prem prem).varid, quants @ quants', checks @ checks')
    , checks' @ [prem] )
  in
  let (bound, quants, checks), prems = List.fold_left_map step (bound, [], []) prems in
  let quants', after = concat_premises (List.map (exp_case_premises env owner bound) results) in
  quants @ quants', List.concat prems @ after, checks, after

let case_premise_script index script =
  let env = Il.Env.env_of_script script in
  let add acc checks after =
    {acc with checks = checks @ after @ acc.checks; result_checks = after @ acc.result_checks}
  in
  let rule relation policy acc r =
    let RuleD (id, quants, mixop, exp, prems) = r.it in
    let owner = "RuleD " ^ relation ^ "/" ^ id.it in
    let exps = Prem.components mixop exp in
    let inputs, outputs =
      match policy with
      | Prescan.Execution {input_count; _} | Prescan.Compute {input_count; _} ->
          Prem.split input_count exps
      | Prescan.Check _ -> exps, []
    in
    let bound = (Il.Free.free_list Il.Free.free_exp inputs).varid in
    let quants', prems, checks, after = with_case_premises env owner bound prems outputs in
    add acc checks after, {r with it = RuleD (id, quants @ quants', mixop, exp, prems)}
  in
  let clause id acc c =
    let DefD (quants, args, exp, prems) = c.it in
    let owner = "DecD $" ^ id.it in
    let bound = (Il.Free.free_args args).varid in
    let quants', prems, checks, after = with_case_premises env owner bound prems [exp] in
    let acc = add acc checks after in
    let acc =
      if checks @ after = [] || List.mem id.it acc.partial then acc
      else {acc with partial = id.it :: acc.partial}
    in
    acc, {c with it = DefD (quants @ quants', args, exp, prems)}
  in
  let rec transform acc def =
    match def.it with
    | RelD (id, params, mixop, typ, rules) ->
        begin match Prescan.relation_policy index id with
        | Ok policy ->
            let acc, rules = List.fold_left_map (rule id.it policy) acc rules in
            acc, {def with it = RelD (id, params, mixop, typ, rules)}
        | Error _ -> acc, def
        end
    | DecD (id, params, typ, clauses) ->
        let acc, clauses = List.fold_left_map (clause id) acc clauses in
        acc, {def with it = DecD (id, params, typ, clauses)}
    | RecD defs ->
        let acc, defs = List.fold_left_map transform acc defs in
        acc, {def with it = RecD defs}
    | TypD _ | GramD _ | HintD _ -> acc, def
  in
  let acc, script =
    List.fold_left_map transform {checks = []; result_checks = []; partial = []} script
  in
  script, acc

(* A premise e_1 \/ .. \/ e_n with a variable that the inputs and earlier
 * premises do not bind (Wasm 1.0 block: t? = eps /\ n = 0 \/ t? =/= eps /\
 * n = 1) holds for some value of it iff one disjunct does. An execution rule
 * is a rewrite rule, so it is split into one rule per disjunct, named
 * id-1 .. id-n; together they have exactly the source rule's steps.
 * Equations (definitions, other relations) are not split, and neither is a
 * rule that a hint names. *)
let rec disjuncts exp =
  match exp.it with
  | BinE (`OrOp, `BoolT, left, right) -> disjuncts left @ disjuncts right
  | _ -> [exp]

let disjunction_script index script =
  let hinted =
    List.filter_map
      (fun hintdef ->
        match hintdef.it with
        | RuleH (r, id, _) -> Some (r.it, id.it)
        | TypH _ | RelH _ | DecH _ | GramH _ -> None)
      (Prescan.collect_hints script)
  in
  let rec rule relation input_count r =
    let RuleD (id, quants, mixop, exp, prems) = r.it in
    let inputs, _ = Prem.split input_count (Prem.components mixop exp) in
    let bound = (Il.Free.free_list Il.Free.free_exp inputs).varid in
    let rec find bound before = function
      | [] -> None
      | ({it = IfPr e; _} as prem) :: after
        when List.length (disjuncts e) > 1
             && not (Il.Free.Set.subset (Il.Free.free_exp e).varid bound) ->
          Some (List.rev before, prem, e, after)
      | prem :: after ->
          find (Il.Free.Set.union bound (Il.Free.free_prem prem).varid)
            (prem :: before) after
    in
    match find bound [] prems with
    | None -> [r]
    | Some _ when List.mem (relation, id.it) hinted -> [r]
    | Some _ when List.exists (fun prem -> match prem.it with ElsePr -> true | _ -> false) prems ->
        (* Each piece would count the earlier pieces as preceding rules. *)
        Maude_il.located r.at ("RelD " ^ relation ^ "/" ^ id.it) (fun () ->
          raise (Unsupported "otherwise rule with a disjunction premise that splits it"))
    | Some (before, prem, e, after) ->
        disjuncts e
        |> List.mapi (fun k disjunct ->
             let prems = before @ [IfPr disjunct $ prem.at] @ after in
             let free = Il.Free.(free_exp exp ++ free_prems prems) in
             let id = {id with it = id.it ^ "-" ^ string_of_int (k + 1)} in
             {r with it = RuleD (id, Prem.used_quants free quants, mixop, exp, prems)})
        |> List.concat_map (rule relation input_count)
  in
  let rec transform def =
    match def.it with
    | RelD (id, params, mixop, typ, rules) ->
        begin match Prescan.relation_policy index id with
        | Ok (Prescan.Execution {input_count; _}) ->
            let rules = List.concat_map (rule id.it input_count) rules in
            {def with it = RelD (id, params, mixop, typ, rules)}
        | Ok (Prescan.Compute _ | Prescan.Check _) | Error _ -> def
        end
    | RecD defs -> {def with it = RecD (List.map transform defs)}
    | TypD _ | DecD _ | GramD _ | HintD _ -> def
  in
  List.map transform script

(* A maude_array or maude_map field is not a Maude list, so a record pattern
 * binds its value only in the premises that stored_script replaces by the
 * field: m = {F x*} and {F x*} = m. Elsewhere (a DefD argument, a rule input,
 * another premise) such a binding is Unsupported. A definition with such a
 * clause gets no body, as one that uses an untranslated relation (Prescan);
 * the result lists them with the position of the first binding. *)
let check_stored_patterns index script =
  let stored_variables bound exp =
    let found = ref [] in
    let module Visitor = Il.Iter.Make (struct
      include Il.Iter.Skip
      let visit_exp exp =
        match exp.it with
        | StrE (fields, _) ->
            List.iter
              (fun (atom, value) ->
                if Prescan.stored_field index exp.note atom <> None then
                  let free = Il.Free.(free_exp value).varid in
                  found := Il.Free.Set.elements (Il.Free.Set.diff free bound) @ !found)
              fields
        | _ -> ()
    end)
    in
    Visitor.exp exp;
    !found
  in
  let reason x =
    "record pattern binds " ^ x ^ " to a maude_array or maude_map field outside m = {F x*}"
  in
  let check owner bound exp =
    match stored_variables bound exp with
    | [] -> ()
    | x :: _ -> unsupported exp.at "StrE" owner (reason x)
  in
  (* For a definition, the first such binding instead of an error. *)
  let first bound exp =
    match stored_variables bound exp with
    | [] -> None
    | _ :: _ -> Some exp.at
  in
  let replaced = function
    | {it = StrE (fields, _); note; _} ->
        List.for_all
          (fun (atom, (value : exp)) ->
            Prescan.stored_field index note atom = None
            ||
            match value.it with
            | VarE _ -> true
            | IterE ({it = VarE y; _}, (_, [(y', {it = VarE _; _})])) -> y.it = y'.it
            | _ -> false)
          fields
    | _ -> false
  in
  let premise_patterns bound prems =
    List.fold_left
      (fun (bound, patterns) prem ->
        let patterns =
          match prem.it with
          | IfPr {it = CmpE (`EqOp, _, left, right); _}
            when replaced left || replaced right -> patterns
          | LetPr (_, pattern, _) when replaced pattern -> patterns
          | IfPr exp | LetPr (_, exp, _) | RulePr (_, _, _, exp) ->
              (bound, exp) :: patterns
          | IterPr _ | ElsePr -> patterns
        in
        Il.Free.Set.union bound (Il.Free.free_prem prem).varid, patterns)
      (bound, []) prems
    |> snd |> List.rev
  in
  let rec visit def =
    match def.it with
    | DecD (id, _, _, clauses) ->
        clauses
        |> List.find_map (fun clause ->
             let DefD (_, args, _, prems) = clause.it in
             let exps =
               List.filter_map (fun arg -> match arg.it with ExpA e -> Some e | _ -> None) args
             in
             List.map (fun exp -> Il.Free.Set.empty, exp) exps
             @ premise_patterns Il.Free.(free_list free_exp exps).varid prems
             |> List.find_map (fun (bound, exp) -> first bound exp))
        |> Option.map (fun at -> id.it, at)
        |> Option.to_list
    | RelD (id, _, _, _, rules) ->
        let input_count =
          match Prescan.relation_policy index id with
          | Ok (Prescan.Execution {input_count; _} | Prescan.Compute {input_count; _}) ->
              Some input_count
          | Ok (Prescan.Check _) -> None
          | Error _ -> Some 0
        in
        List.iter
          (fun rule ->
            let RuleD (rule_id, _, mixop, exp, prems) = rule.it in
            let owner = "RelD " ^ id.it ^ "/" ^ rule_id.it in
            let components = Prem.components mixop exp in
            let inputs =
              match input_count with
              | Some count -> fst (Prem.split count components)
              | None -> components
            in
            List.iter (check owner Il.Free.Set.empty) inputs;
            premise_patterns Il.Free.(free_list free_exp inputs).varid prems
            |> List.iter (fun (bound, exp) -> check owner bound exp))
          rules;
        []
    | RecD defs -> List.concat_map visit defs
    | TypD _ | GramD _ | HintD _ -> []
  in
  List.concat_map visit script

(* builtin_names are the operators of the spec's builtin Maude files
   (spec2maude --builtins); generated names avoid them. *)
let translate_script ?(builtin_names = []) script =
  let script =
    binder_type_script
      (fold_script (stored_script (specialize_script (assume_script script))))
  in
  let index = Prescan.scan ~builtin_names script in
  let bodiless = check_stored_patterns index script in
  List.iter
    (fun (name, (at : region)) ->
      Printf.eprintf
        "[spec2maude] warning: definition not translated (record pattern on a maude_array or maude_map field outside m = {F x*}): %s (%s:%d)\n"
        name (Filename.basename at.left.file) at.left.line)
    bodiless;
  let script = disjunction_script index script in
  (* The pass needs the relation policies of the first scan; the index is
     scanned again for the premises it adds. *)
  let script, checks = case_premise_script (Prescan.scan ~builtin_names script) script in
  let index =
    Prescan.scan ~case_premises:checks.checks ~result_case_premises:checks.result_checks
      ~partial_defs:checks.partial ~bodiless_defs:(List.map fst bodiless) ~builtin_names
      script
  in
  (* Relations without a supported policy are omitted; a call to one is
     rejected later, but an unreferenced one would vanish silently. One line
     per reason lists its relations in source order, each with its file and
     line. *)
  let rec relation_regions defs =
    List.concat_map
      (fun def ->
        match def.it with
        | RelD (id, _, _, _, _) -> [id.it, def.at]
        | RecD defs -> relation_regions defs
        | TypD _ | DecD _ | GramD _ | HintD _ -> [])
      defs
  in
  let regions = relation_regions script in
  let with_region name =
    match List.assoc_opt name regions with
    | Some at ->
        Printf.sprintf "%s (%s:%d)" name (Filename.basename at.left.file) at.left.line
    | None -> name
  in
  let relations = index.Prescan.unsupported_relations in
  List.sort_uniq compare (List.map snd relations)
  |> List.iter (fun reason ->
       let names =
         List.filter_map
           (fun (name, reason') ->
             if reason' = reason then Some (with_region name) else None)
           relations
       in
       Printf.eprintf "[spec2maude] warning: relations not translated (%s): %s\n"
         reason (String.concat ", " names));
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
    |> share_helpers index
    |> normalize_module (Prescan.variable_declarations index)
  in
  { sort_statements = sort_metadata_declarations sort_metadata
  ; list_statements
  ; generated_statements
  }
