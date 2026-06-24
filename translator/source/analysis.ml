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
  | RelD (id, _, _, _)
  | DecD (id, _, _, _)
  | GramD (id, _, _, _) -> Some id.it
  | RecD _ -> None
  | HintD hintdef ->
    let id =
      match hintdef.it with
      | TypH (id, _)
      | RelH (id, _)
      | DecH (id, _)
      | GramH (id, _) -> id
    in
    Some id.it

module Source_index = struct
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
end

module Relation_graph = struct
  type relation_kind =
    | Execution
    | Execution_star
    | Deterministic_candidate
    | Predicate_candidate
    | Unknown

  let string_of_relation_kind = function
    | Execution -> "execution"
    | Execution_star -> "execution-star"
    | Deterministic_candidate -> "deterministic-candidate"
    | Predicate_candidate -> "predicate-candidate"
    | Unknown -> "unknown"

  let mixop_has_atom predicate mixop =
    List.exists
      (fun atoms -> List.exists (fun atom -> predicate atom.it) atoms)
      mixop

  let classify_mixop mixop =
    let markers =
      [ ( mixop_has_atom (function Xl.Atom.SqArrow -> true | _ -> false) mixop
        , Execution )
      ; ( mixop_has_atom (function Xl.Atom.SqArrowStar -> true | _ -> false) mixop
        , Execution_star )
      ; ( mixop_has_atom
            (function Xl.Atom.Approx | Xl.Atom.ApproxSub -> true | _ -> false)
            mixop
        , Deterministic_candidate )
      ; ( mixop_has_atom
            (function
              | Xl.Atom.Turnstile | Xl.Atom.TurnstileSub | Xl.Atom.Sub -> true
              | _ -> false)
            mixop
        , Predicate_candidate )
      ]
      |> List.filter_map (fun (present, kind) -> if present then Some kind else None)
    in
    match markers with
    | [ kind ] -> kind
    | [] | _ :: _ :: _ -> Unknown

  let string_of_mixop = Xl.Mixop.to_string

  let eq_mixop = Xl.Mixop.eq

  let mixop_shape_text mixop =
    string_of_mixop mixop

  let exp_components exp =
    match exp.it with
    | TupE components -> components
    | _ -> [ exp ]

  let exp_components_for_count expected_count exp =
    match expected_count, exp.it with
    | 1, _ -> Some [ exp ]
    | _, TupE components when List.length components = expected_count -> Some components
    | _, _ -> None

end

module Function_graph = struct
  type param_kind =
    | Runtime_exp
    | Static_typ
    | Static_def
    | Static_gram

  type definition =
    { id : string
    ; origin : Origin.t
    ; params : param_kind list
    ; result : typ
    ; clause_count : int
    ; inverse_id : string option
    }

  type relation =
    { id : string
    ; origin : Origin.t
    ; kind : Relation_graph.relation_kind
    ; mixop : mixop
    ; result : typ
    ; rule_count : int
    ; hints : string list
    ; maude_equational_view : bool
    }

  type relation_demand =
    { id : string
    ; reason : string
    }

  type static_typ_binding =
    { param_id : string
    ; typ : typ
    ; key : string
    }

  type static_def_binding =
    { param_id : string
    ; target_id : string
    ; key : string
    }

  type specialization =
    { def_id : string
    ; key_components : string list
    ; static_typs : static_typ_binding list
    ; static_defs : static_def_binding list
    ; origin : Origin.t
    }

  type violation =
    { origin : Origin.t
    ; constructor : string
    ; reason : string
    ; suggestion : string option
    ; source_echo : string option
    }

  type call_resolution =
    | Plain_call
    | Specialized_call of specialization
    | Unsupported_call of string
    | Prelude_gap_call of string

  type runtime_search_capability =
    | Runtime_search_candidate of string list
    | Runtime_search_blocked of
        { closure : string list
        ; blockers : string list
        }

  type def_body =
    { body_id : id
    ; body_origin : Origin.t
    ; body_params : param list
    ; body_clauses : clause list
    }

  type relation_body =
    { relation_id : id
    ; relation_origin : Origin.t
    ; relation_rules : rule list
    }

  type t =
    { definitions : definition list
    ; relations : relation list
    ; definitions_by_id : (string, definition) Hashtbl.t
    ; relations_by_id : (string, relation) Hashtbl.t
    ; bodies_by_id : (string, def_body) Hashtbl.t
    ; relation_bodies_by_id : (string, relation_body) Hashtbl.t
    ; relation_bodies : relation_body list
    ; relation_edges_by_id : (string, string list) Hashtbl.t
    ; relation_runtime_demands : (string, relation_demand) Hashtbl.t
    ; specializations_by_id : (string, specialization list) Hashtbl.t
    ; mutable violations : violation list
    }

  let finite_specialization_cap = 10000

  let param_kind param =
    match param.it with
    | ExpP _ -> Runtime_exp
    | TypP _ -> Static_typ
    | DefP _ -> Static_def
    | GramP _ -> Static_gram

  let add_once table key value =
    if not (Hashtbl.mem table key) then Hashtbl.add table key value

  let free_sets_empty sets =
    Il.Free.subset sets Il.Free.empty && Il.Free.subset Il.Free.empty sets

  let exp_is_source_closed exp =
    free_sets_empty (Il.Free.free_exp exp)

  let rec exp_is_constructor_normal exp =
    match exp.it with
    | BoolE _ | NumE _ | TextE _ -> true
    | CaseE (_, inner) -> exp_is_constructor_normal inner
    | TupE exps | ListE exps -> List.for_all exp_is_constructor_normal exps
    | OptE opt -> Option.fold ~none:true ~some:exp_is_constructor_normal opt
    | StrE fields ->
      fields |> List.for_all (fun (_atom, field_exp) ->
        exp_is_constructor_normal field_exp)
    | VarE _ | UnE _ | BinE _ | CmpE _ | ProjE _ | UncaseE _ | TheE _
    | DotE _ | CompE _ | LiftE _ | MemE _ | LenE _ | CatE _ | IdxE _
    | SliceE _ | UpdE _ | ExtE _ | CallE _ | IterE _ | CvtE _ | SubE _
    | IfE _ -> false

  (* Only source-closed constructor-normal expressions are finite static keys at
     the Function_graph layer.
     Broader ExpA keys can materialize clauses whose variables are only bound by
     not-yet-implemented inverse/premise helpers, which breaks Maude condition
     admissibility before those helpers exist. *)
  let static_exp_key exp =
    if exp_is_source_closed exp && exp_is_constructor_normal exp then
      Some (Static_key.of_arg (ExpA exp $ exp.at))
    else
      None

  let rec resolve_typ_static ?(visited = []) env typ =
    match typ.it with
    | VarT (id, []) when List.mem_assoc id.it env && not (List.mem id.it visited) ->
      resolve_typ_static ~visited:(id.it :: visited) env (List.assoc id.it env)
    | VarT (id, _ :: _) when List.mem_assoc id.it env -> None
    | VarT (id, args) ->
      let arg_keys = List.map (arg_static_key env) args in
      if List.for_all Option.is_some arg_keys then
        Some
          ( typ
          , "typ:" ^ Naming.sanitize id.it ^ "("
            ^ String.concat "," (List.map Option.get arg_keys)
            ^ ")" )
      else
        None
    | BoolT -> Some (typ, "typ:bool")
    | NumT `NatT -> Some (typ, "typ:nat")
    | NumT `IntT -> Some (typ, "typ:int")
    | NumT `RatT -> Some (typ, "typ:rat")
    | NumT `RealT -> Some (typ, "typ:real")
    | TextT -> Some (typ, "typ:text")
    | IterT (inner, Opt) ->
      Option.map
        (fun (typ, key) -> typ, "typ:opt(" ^ key ^ ")")
        (resolve_typ_static env inner)
    | IterT (inner, List) ->
      Option.map
        (fun (typ, key) -> typ, "typ:list(" ^ key ^ ")")
        (resolve_typ_static env inner)
    | IterT (inner, List1) ->
      Option.map
        (fun (typ, key) -> typ, "typ:list1(" ^ key ^ ")")
        (resolve_typ_static env inner)
    | IterT (inner, ListN (n_exp, _)) ->
      (match resolve_typ_static env inner, static_exp_key n_exp with
      | Some (typ, key), Some n_key -> Some (typ, "typ:listn(" ^ key ^ "," ^ n_key ^ ")")
      | _ -> None)
    | TupT _ -> None

  and arg_static_key env arg =
    match arg.it with
    | TypA typ ->
      Option.map snd (resolve_typ_static env typ)
    | ExpA exp -> static_exp_key exp
    | DefA _ | GramA _ -> None

  let typ_static_key typ =
    Option.map snd (resolve_typ_static [] typ)

  let typ_static_key_with_env env typ =
    Option.map snd (resolve_typ_static env typ)

  let body_has_unsupported_static_param params =
    List.exists
      (fun param ->
        match param.it with
        | GramP _ -> true
        | ExpP _ | TypP _ | DefP _ -> false)
      params

  let definition_body_has_static_params params =
    List.exists
      (fun param ->
        match param.it with
        | TypP _ | DefP _ -> true
        | ExpP _ | GramP _ -> false)
      params

  let specialization_identity specialization =
    specialization.def_id ^ "|" ^ String.concat "|" specialization.key_components

  let specializations_for t id =
    match Hashtbl.find_opt t.specializations_by_id id with
    | None -> []
    | Some specializations -> specializations

  let has_specialization t specialization =
    specializations_for t specialization.def_id
    |> List.exists (fun existing ->
      specialization_identity existing = specialization_identity specialization)

  let def_signature_key params result =
    "params("
    ^ String.concat "," (List.map Il.Print.string_of_param params)
    ^ ")->"
    ^ Il.Print.string_of_typ result

  let static_def_key t ~formal_id ~formal_params ~formal_result ~target_id =
    match
      Hashtbl.find_opt t.bodies_by_id target_id,
      Hashtbl.find_opt t.definitions_by_id target_id
    with
    | Some body, Some definition ->
      let formal_sig = def_signature_key formal_params formal_result in
      let actual_sig = def_signature_key body.body_params definition.result in
      if formal_sig = actual_sig then
        Ok
          ("def:" ^ formal_id ^ "->" ^ target_id
           ^ ":formal:" ^ formal_sig
           ^ ":actual:" ^ actual_sig)
      else
        Error
          ("DefA target `" ^ target_id
           ^ "` has signature `" ^ actual_sig
           ^ "`, but static DefP parameter `" ^ formal_id
           ^ "` requires `" ^ formal_sig ^ "`")
    | _ ->
      Error
        ("DefA target `" ^ target_id
         ^ "` is not a known DecD, so the static definition specialization cannot be trusted")

  let call_target_id static_def_env id =
    match List.assoc_opt id.it static_def_env with
    | Some target_id -> target_id
    | None -> id.it

  let resolve_call t ~static_typ_env ~static_def_env ~origin id args =
    let target_id = call_target_id static_def_env id in
    match Hashtbl.find_opt t.bodies_by_id target_id with
    | None ->
      if
        List.mem_assoc id.it static_def_env
        ||
        List.exists
          (fun arg ->
            match arg.it with
            | TypA _ | DefA _ | GramA _ -> true
            | ExpA _ -> false)
          args
      then
        Unsupported_call
          ("static definition call target `" ^ target_id ^ "` is not a known DecD")
      else if
        List.exists
          (fun arg ->
            match arg.it with
            | ExpA _ -> true
            | TypA _ | DefA _ | GramA _ -> false)
          args
      then
        Prelude_gap_call
          ("runtime CallE target `" ^ target_id
           ^ "` is not a generated DecD and has no explicit prelude/builtin handler")
      else
        Prelude_gap_call
          ("nullary CallE target `" ^ target_id
           ^ "` is not a generated DecD and has no explicit prelude/builtin handler")
    | Some body ->
      if List.length body.body_params <> List.length args then
        Unsupported_call
          (Printf.sprintf
             "CallE arity mismatch for `%s`: expected %d source argument(s), got %d"
             target_id
             (List.length body.body_params)
             (List.length args))
      else if body_has_unsupported_static_param body.body_params then
        Unsupported_call "GramP static parameters are outside the finite TypP/DefP monomorphization slice"
      else if not (definition_body_has_static_params body.body_params) then
        Plain_call
      else
        let typ_bindings_rev, def_bindings_rev, keys_rev, error =
          List.fold_left2
            (fun (typ_bindings, def_bindings, keys, error) param arg ->
              match error with
              | Some _ -> typ_bindings, def_bindings, keys, error
              | None ->
                (match param.it, arg.it with
                | TypP param_id, TypA typ ->
                  (match resolve_typ_static static_typ_env typ with
                  | Some (typ, key) ->
                    let binding = { param_id = param_id.it; typ; key } in
                    binding :: typ_bindings, def_bindings, key :: keys, None
                  | None ->
                    typ_bindings,
                    def_bindings,
                    keys,
                    Some
                      ("TypA argument `" ^ Il.Print.string_of_typ typ
                       ^ "` is not a concrete finite specialization key"))
                | TypP _, (ExpA _ | DefA _ | GramA _) ->
                  typ_bindings, def_bindings, keys, Some "TypP parameter position requires a TypA argument"
                | DefP (param_id, formal_params, formal_result), DefA actual_id ->
                  (match
                     static_def_key
                       t
                       ~formal_id:param_id.it
                       ~formal_params
                       ~formal_result
                       ~target_id:actual_id.it
                   with
                  | Ok key ->
                    let binding =
                      { param_id = param_id.it; target_id = actual_id.it; key }
                    in
                    typ_bindings, binding :: def_bindings, key :: keys, None
                  | Error reason -> typ_bindings, def_bindings, keys, Some reason)
                | DefP _, (ExpA _ | TypA _ | GramA _) ->
                  typ_bindings, def_bindings, keys, Some "DefP parameter position requires a DefA argument"
                | ExpP _, ExpA _ -> typ_bindings, def_bindings, keys, None
                | ExpP _, (TypA _ | DefA _ | GramA _) ->
                  typ_bindings, def_bindings, keys, Some "runtime ExpP parameter position received a static argument"
                | GramP _, _ ->
                  typ_bindings,
                  def_bindings,
                  keys,
                  Some "GramP static parameters are outside the finite TypP/DefP monomorphization slice"))
            ([], [], [], None)
            body.body_params
            args
        in
        (match error with
        | Some reason -> Unsupported_call reason
        | None ->
          let static_typs = List.rev typ_bindings_rev in
          let static_defs = List.rev def_bindings_rev in
          let key_components = List.rev keys_rev in
          Specialized_call
            { def_id = target_id; key_components; static_typs; static_defs; origin })

  let rec collect_exp_calls t static_typ_env static_def_env origin acc exp =
    let acc =
      match exp.it with
      | CallE (id, args) ->
        (match
           resolve_call t ~static_typ_env ~static_def_env ~origin id args
         with
        | Specialized_call specialization -> specialization :: acc
        | Plain_call | Unsupported_call _ | Prelude_gap_call _ -> acc)
      | _ -> acc
    in
    match exp.it with
    | VarE _ | BoolE _ | NumE _ | TextE _ -> acc
    | UnE (_, _, exp1) | LenE exp1 | LiftE exp1 | TheE exp1
    | UncaseE (exp1, _) | CvtE (exp1, _, _) ->
      collect_exp_calls t static_typ_env static_def_env origin acc exp1
    | BinE (_, _, left, right) | CmpE (_, _, left, right)
    | CompE (left, right) | MemE (left, right) | CatE (left, right)
    | IdxE (left, right) ->
      let acc = collect_exp_calls t static_typ_env static_def_env origin acc left in
      collect_exp_calls t static_typ_env static_def_env origin acc right
    | IfE (cond, then_exp, else_exp) ->
      let acc = collect_exp_calls t static_typ_env static_def_env origin acc cond in
      let acc = collect_exp_calls t static_typ_env static_def_env origin acc then_exp in
      collect_exp_calls t static_typ_env static_def_env origin acc else_exp
    | TupE exps | ListE exps ->
      List.fold_left
        (collect_exp_calls t static_typ_env static_def_env origin)
        acc
        exps
    | CaseE (_, exp1) ->
      collect_exp_calls t static_typ_env static_def_env origin acc exp1
    | OptE None -> acc
    | OptE (Some exp1) ->
      collect_exp_calls t static_typ_env static_def_env origin acc exp1
    | StrE fields ->
      fields
      |> List.map snd
      |> List.fold_left
           (collect_exp_calls t static_typ_env static_def_env origin)
           acc
    | DotE (record, _) ->
      collect_exp_calls t static_typ_env static_def_env origin acc record
    | SliceE (source, start, stop) ->
      let acc = collect_exp_calls t static_typ_env static_def_env origin acc source in
      let acc = collect_exp_calls t static_typ_env static_def_env origin acc start in
      collect_exp_calls t static_typ_env static_def_env origin acc stop
    | UpdE (record, path, value) | ExtE (record, path, value) ->
      let acc = collect_exp_calls t static_typ_env static_def_env origin acc record in
      let acc = collect_path_calls t static_typ_env static_def_env origin acc path in
      collect_exp_calls t static_typ_env static_def_env origin acc value
    | ProjE (exp1, _) ->
      collect_exp_calls t static_typ_env static_def_env origin acc exp1
    | CallE (_, args) ->
      args
      |> List.fold_left
           (fun acc arg ->
             match arg.it with
             | ExpA exp ->
               collect_exp_calls t static_typ_env static_def_env origin acc exp
             | TypA _ | DefA _ | GramA _ -> acc)
           acc
    | IterE (body, (_iter, generators)) ->
      let acc = collect_exp_calls t static_typ_env static_def_env origin acc body in
      generators
      |> List.map snd
      |> List.fold_left
           (collect_exp_calls t static_typ_env static_def_env origin)
           acc
    | SubE (exp1, _, _) ->
      collect_exp_calls t static_typ_env static_def_env origin acc exp1

  and collect_path_calls t static_typ_env static_def_env origin acc path =
    match path.it with
    | RootP -> acc
    | IdxP (path, exp) ->
      let acc = collect_path_calls t static_typ_env static_def_env origin acc path in
      collect_exp_calls t static_typ_env static_def_env origin acc exp
    | SliceP (path, start, stop) ->
      let acc = collect_path_calls t static_typ_env static_def_env origin acc path in
      let acc = collect_exp_calls t static_typ_env static_def_env origin acc start in
      collect_exp_calls t static_typ_env static_def_env origin acc stop
    | DotP (path, _) ->
      collect_path_calls t static_typ_env static_def_env origin acc path

  let rec collect_prem_calls t static_typ_env static_def_env origin acc prem =
    match prem.it with
    | RulePr (_, _, exp) | IfPr exp ->
      collect_exp_calls t static_typ_env static_def_env origin acc exp
    | LetPr (lhs, rhs, _ids) ->
      let acc = collect_exp_calls t static_typ_env static_def_env origin acc lhs in
      collect_exp_calls t static_typ_env static_def_env origin acc rhs
    | ElsePr -> acc
    | IterPr (prem, (_iter, generators)) ->
      let acc = collect_prem_calls t static_typ_env static_def_env origin acc prem in
      generators
      |> List.map snd
      |> List.fold_left
           (collect_exp_calls t static_typ_env static_def_env origin)
           acc
    | NegPr prem -> collect_prem_calls t static_typ_env static_def_env origin acc prem

  let collect_clause_calls t static_typ_env static_def_env origin acc clause =
    match clause.it with
    | DefD (_binds, args, rhs, prems) ->
      let acc =
        args
        |> List.fold_left
             (fun acc arg ->
               match arg.it with
               | ExpA exp ->
                 collect_exp_calls t static_typ_env static_def_env origin acc exp
               | TypA _ | DefA _ | GramA _ -> acc)
             acc
      in
      let acc = collect_exp_calls t static_typ_env static_def_env origin acc rhs in
      List.fold_left
        (collect_prem_calls t static_typ_env static_def_env origin)
        acc
        prems

  let collect_body_calls t static_typ_env static_def_env body =
    List.fold_left
      (collect_clause_calls t static_typ_env static_def_env body.body_origin)
      []
      body.body_clauses

  let collect_rule_calls t static_typ_env static_def_env origin acc rule =
    match rule.it with
    | RuleD (_id, _binds, _mixop, exp, prems) ->
      let acc = collect_exp_calls t static_typ_env static_def_env origin acc exp in
      List.fold_left
        (collect_prem_calls t static_typ_env static_def_env origin)
        acc
        prems

  let rec collect_relation_refs_from_prem acc prem =
    match prem.it with
    | RulePr (rel_id, _, _) ->
      if List.mem rel_id.it acc then acc else rel_id.it :: acc
    | IterPr (prem, _) | NegPr prem ->
      collect_relation_refs_from_prem acc prem
    | IfPr _ | LetPr _ | ElsePr -> acc

  let collect_relation_refs_from_rule rule =
    match rule.it with
    | RuleD (_, _, _, _, prems) ->
      prems
      |> List.fold_left collect_relation_refs_from_prem []
      |> List.rev

  let collect_relation_refs_from_clause clause =
    match clause.it with
    | DefD (_, _, _, prems) ->
      prems
      |> List.fold_left collect_relation_refs_from_prem []
      |> List.rev

  let rec search_premise_dependencies prem =
    match prem.it with
    | IfPr _ | LetPr _ -> [], []
    | RulePr (rel_id, _, _) ->
      [ rel_id.it ], []
    | ElsePr ->
      [],
      [ "otherwise premise needs enabledness complement before it can be part of a search relation" ]
    | IterPr (body, _) ->
      let deps, blockers = search_premise_dependencies body in
      deps,
      "iterated premise needs a source-shaped IterPr helper before search generation"
      :: blockers
    | NegPr body ->
      let deps, blockers = search_premise_dependencies body in
      deps,
      "negated premise needs decidable complement before search generation"
      :: blockers

  let search_rule_dependencies relation_mixop rule =
    match rule.it with
    | RuleD (_id, _binds, mixop, _exp, prems) ->
      let marker_blockers =
        if Relation_graph.eq_mixop relation_mixop mixop then
          []
        else
          [ "rule mixop skeleton does not match the enclosing RelD skeleton" ]
      in
      let deps, blockers =
        prems
        |> List.map search_premise_dependencies
        |> List.fold_left
             (fun (deps, blockers) (new_deps, new_blockers) ->
               deps @ new_deps, blockers @ new_blockers)
             ([], [])
      in
      deps, marker_blockers @ blockers

  let add_specialization t queue specialization =
    if has_specialization t specialization then
      ()
    else (
      let old = specializations_for t specialization.def_id in
      Hashtbl.replace
        t.specializations_by_id
        specialization.def_id
        (old @ [ specialization ]);
      queue := !queue @ [ specialization ])

  let add_violation t violation =
    t.violations <- t.violations @ [ violation ]

  let record_specialization_cap t steps queue =
    match queue with
    | [] -> ()
    | (specialization : specialization) :: _ ->
      add_violation t
        { origin = specialization.origin
        ; constructor = "FunctionGraph/static-specialization/finite-cap"
        ; reason =
            (Printf.sprintf
               "finite static specialization worklist reached cap %d after %d processed item(s); pending specialization `%s` with key `%s` was not explored"
               finite_specialization_cap
               steps
               specialization.def_id
               (String.concat "," specialization.key_components))
        ; suggestion =
            Some
              "Keep this specialization Unsupported until the static argument closure is proven finite or the cap is raised with evidence"
        ; source_echo = specialization.origin.Origin.source_echo
        }

  let compute_specializations t =
    let queue = ref [] in
    Hashtbl.iter
      (fun _id body ->
        if not (definition_body_has_static_params body.body_params) then
          collect_body_calls t [] [] body
          |> List.iter (add_specialization t queue))
      t.bodies_by_id;
    t.relation_bodies
    |> List.iter (fun body ->
      body.relation_rules
      |> List.fold_left
           (collect_rule_calls t [] [] body.relation_origin)
           []
      |> List.iter (add_specialization t queue));
    let rec drain steps =
      match !queue with
      | [] -> ()
      | _ when steps >= finite_specialization_cap ->
        record_specialization_cap t steps !queue;
        queue := []
      | specialization :: rest ->
        queue := rest;
        (match Hashtbl.find_opt t.bodies_by_id specialization.def_id with
        | None -> ()
        | Some body ->
          let static_typ_env =
            specialization.static_typs
            |> List.map
                 (fun (binding : static_typ_binding) ->
                   binding.param_id, binding.typ)
          in
          let static_def_env =
            specialization.static_defs
            |> List.map
                 (fun (binding : static_def_binding) ->
                   binding.param_id, binding.target_id)
          in
          collect_body_calls t static_typ_env static_def_env body
          |> List.iter (add_specialization t queue));
        drain (steps + 1)
    in
    drain 0

  let runtime_seed_reason (relation : relation) =
    match relation.kind with
    | Relation_graph.Execution ->
      Some "execution relation is emitted as Maude rewrite rules, so its RulePr dependencies are runtime-relevant"
    | Relation_graph.Execution_star ->
      Some "execution-star relation is emitted as Maude rewrite rules, so its RulePr dependencies are runtime-relevant"
    | Relation_graph.Deterministic_candidate
    | Relation_graph.Predicate_candidate
    | Relation_graph.Unknown -> None

  let decd_runtime_seed_reason relation_id decd_id (relation : relation) =
    match relation.kind with
    | Relation_graph.Execution ->
      Some
        (Printf.sprintf
           "execution relation `%s` is used as a RulePr premise while lowering DecD `%s`; pure equations cannot erase this runtime dependency"
           relation_id
           decd_id)
    | Relation_graph.Execution_star ->
      Some
        (Printf.sprintf
           "execution-star relation `%s` is used as a RulePr premise while lowering DecD `%s`; pure equations cannot erase this runtime dependency"
           relation_id
           decd_id)
    | Relation_graph.Deterministic_candidate ->
      Some
        (Printf.sprintf
           "deterministic relation `%s` is used as a RulePr premise while lowering DecD `%s`; its equational result constrains the generated definition"
           relation_id
           decd_id)
    | Relation_graph.Predicate_candidate ->
      None
    | Relation_graph.Unknown ->
      None

  let add_runtime_demand t queue id reason =
    if not (Hashtbl.mem t.relation_runtime_demands id) then (
      Hashtbl.add t.relation_runtime_demands id { id; reason };
      queue := !queue @ [ id ])

  let compute_relation_runtime_demands t decd_relation_seeds =
    let queue = ref [] in
    t.relations
    |> List.iter (fun relation ->
      match runtime_seed_reason relation with
      | None -> ()
      | Some reason -> add_runtime_demand t queue relation.id reason);
    decd_relation_seeds
    |> List.iter (fun (target_id, decd_id) ->
      match Hashtbl.find_opt t.relations_by_id target_id with
      | None -> ()
      | Some relation ->
        (match decd_runtime_seed_reason target_id decd_id relation with
        | None -> ()
        | Some reason -> add_runtime_demand t queue target_id reason));
    let rec drain () =
      match !queue with
      | [] -> ()
      | source_id :: rest ->
        queue := rest;
        let targets =
          match Hashtbl.find_opt t.relation_edges_by_id source_id with
          | None -> []
          | Some targets -> targets
        in
        targets
        |> List.iter (fun target_id ->
          if Hashtbl.mem t.relations_by_id target_id then
            add_runtime_demand
              t
              queue
              target_id
              (Printf.sprintf
                 "relation `%s` is used as a RulePr premise while lowering runtime-demanded relation `%s`; skipping it would erase a source branch or guard"
                 target_id
                 source_id));
        drain ()
    in
    drain ()

  let maude_equational_view_hint = "maude_equational_view"

  let inverse_hint_target (hint : hint) =
    if hint.hintid.it <> "inverse" then
      None
    else
      match hint.hintexp.it with
      | El.Ast.CallE (id, [])
      | El.Ast.VarE (id, []) -> Some id.it
      | _ -> None

  let dec_inverse_table entries =
    let table = Hashtbl.create 127 in
    entries
    |> List.iter (fun (entry : Source_index.entry) ->
      match entry.def.it with
      | HintD hintdef ->
        (match hintdef.it with
        | DecH (id, hints) ->
          (match List.find_map inverse_hint_target hints with
          | None -> ()
          | Some inverse_id -> Hashtbl.replace table id.it inverse_id)
        | TypH _ | RelH _ | GramH _ -> ())
      | TypD _ | RelD _ | DecD _ | GramD _ | RecD _ -> ());
    table

  let dec_inverse table id =
    Hashtbl.find_opt table id

  let relation_hint_table entries =
    let table = Hashtbl.create 127 in
    entries
    |> List.iter (fun (entry : Source_index.entry) ->
      match entry.def.it with
      | HintD hintdef ->
        (match hintdef.it with
        | RelH (id, hints) ->
          let old =
            match Hashtbl.find_opt table id.it with
            | None -> []
            | Some names -> names
          in
          let names =
            hints
            |> List.map (fun hint -> hint.hintid.it)
            |> List.fold_left
                 (fun acc name -> if List.mem name acc then acc else name :: acc)
                 (List.rev old)
            |> List.rev
          in
          Hashtbl.replace table id.it names
        | TypH _ | DecH _ | GramH _ -> ())
      | TypD _ | RelD _ | DecD _ | GramD _ | RecD _ -> ());
    table

  let relation_hints table id =
    match Hashtbl.find_opt table id with
    | None -> []
    | Some hints -> hints

  let build index =
    let definitions_by_id = Hashtbl.create 127 in
    let relations_by_id = Hashtbl.create 127 in
    let bodies_by_id = Hashtbl.create 127 in
    let relation_bodies_by_id = Hashtbl.create 127 in
    let relation_edges_by_id = Hashtbl.create 127 in
    let relation_runtime_demands = Hashtbl.create 127 in
    let specializations_by_id = Hashtbl.create 127 in
    let definitions = ref [] in
    let relations = ref [] in
    let relation_bodies = ref [] in
    let decd_relation_seeds = ref [] in
    let entries = Source_index.entries index in
    let relation_hints_by_id = relation_hint_table entries in
    let dec_inverses_by_id = dec_inverse_table entries in
    entries
    |> List.iter (fun (entry : Source_index.entry) ->
      match entry.def.it with
      | DecD (id, params, result, clauses) ->
        let definition =
          { id = id.it
          ; origin = entry.origin
          ; params = List.map param_kind params
          ; result
          ; clause_count = List.length clauses
          ; inverse_id = dec_inverse dec_inverses_by_id id.it
          }
        in
        definitions := definition :: !definitions;
        add_once definitions_by_id id.it definition;
        add_once
          bodies_by_id
          id.it
          { body_id = id
          ; body_origin = entry.origin
          ; body_params = params
          ; body_clauses = clauses
          };
        clauses
        |> List.map collect_relation_refs_from_clause
        |> List.concat
        |> List.sort_uniq String.compare
        |> List.iter (fun rel_id ->
          decd_relation_seeds :=
            (rel_id, id.it)
            :: !decd_relation_seeds)
      | RelD (id, mixop, result, rules) ->
        let hints = relation_hints relation_hints_by_id id.it in
        let relation =
          { id = id.it
          ; origin = entry.origin
          ; kind = Relation_graph.classify_mixop mixop
          ; mixop
          ; result
          ; rule_count = List.length rules
          ; hints
          ; maude_equational_view = List.mem maude_equational_view_hint hints
          }
        in
        relations := relation :: !relations;
        let relation_body =
          { relation_id = id; relation_origin = entry.origin; relation_rules = rules }
        in
        relation_bodies := relation_body :: !relation_bodies;
        add_once relations_by_id id.it relation;
        add_once relation_bodies_by_id id.it relation_body;
        Hashtbl.replace
          relation_edges_by_id
          id.it
          (rules
           |> List.map collect_relation_refs_from_rule
           |> List.concat
           |> List.sort_uniq String.compare)
      | TypD _ | GramD _ | RecD _ | HintD _ -> ());
    { definitions = List.rev !definitions
    ; relations = List.rev !relations
    ; definitions_by_id
    ; relations_by_id
    ; bodies_by_id
    ; relation_bodies_by_id
    ; relation_bodies = List.rev !relation_bodies
    ; relation_edges_by_id
    ; relation_runtime_demands
    ; specializations_by_id
    ; violations = []
    }
    |> fun t ->
    compute_specializations t;
    compute_relation_runtime_demands t !decd_relation_seeds;
    t

  let violations t =
    t.violations

  let diagnostics ~profile t =
    t.violations
    |> List.map (fun violation ->
      Diagnostics.make
        ?suggestion:violation.suggestion
        ?source_echo:violation.source_echo
        ~category:Diagnostics.Unsupported
        ~origin:violation.origin
        ~constructor:violation.constructor
        ~enclosing:[]
        ~profile
        ~reason:violation.reason
        ())

  let definitions t = t.definitions

  let relations t = t.relations

  let find_definition t id =
    Hashtbl.find_opt t.definitions_by_id id

  let definition_inverse t id =
    match find_definition t id with
    | None -> None
    | Some definition -> definition.inverse_id

  let find_relation t id =
    Hashtbl.find_opt t.relations_by_id id

  let relation_has_maude_equational_view relation =
    relation.maude_equational_view

  let relation_runtime_demand_reason t id =
    match Hashtbl.find_opt t.relation_runtime_demands id with
    | None -> None
    | Some demand -> Some demand.reason

  let relation_is_runtime_demanded t id =
    Option.is_some (relation_runtime_demand_reason t id)

  let runtime_predicate_search_capability t id =
    let closure = ref [] in
    let blockers = ref [] in
    let add_closure id =
      if not (List.mem id !closure) then
        closure := id :: !closure
    in
    let add_blocker relation_id reason =
      blockers :=
        (Printf.sprintf "%s: %s" relation_id reason)
        :: !blockers
    in
    let rec visit stack id =
      if List.mem id stack then (
        add_closure id;
        add_blocker
          id
          ("recursive predicate-search dependency cycle `"
           ^ String.concat " -> " (List.rev (id :: stack))
           ^ "` needs a bounded/source-complete witness-space proof before helper emission"))
      else (
        add_closure id;
        match Hashtbl.find_opt t.relations_by_id id with
        | None ->
          add_blocker id "referenced relation is not known in the source index"
        | Some relation ->
          (match relation.kind with
          | Relation_graph.Predicate_candidate -> ()
          | kind ->
            add_blocker
              id
              ("referenced relation is classified as `"
               ^ Relation_graph.string_of_relation_kind kind
               ^ "`, not as a predicate relation"));
          if not (relation_is_runtime_demanded t id) then
            add_blocker id "referenced relation is not runtime-demanded in the relation graph";
          (match Hashtbl.find_opt t.relation_bodies_by_id id with
          | None ->
            add_blocker id "referenced relation has no source RuleD body in the source index"
          | Some body when body.relation_rules = [] ->
            add_blocker
              id
              "referenced relation has no source RuleD clauses to generate a search relation from"
          | Some body ->
            let deps, rule_blockers =
              body.relation_rules
              |> List.map (search_rule_dependencies relation.mixop)
              |> List.fold_left
                   (fun (deps, blockers) (new_deps, new_blockers) ->
                     deps @ new_deps, blockers @ new_blockers)
                   ([], [])
            in
            rule_blockers
            |> List.sort_uniq String.compare
            |> List.iter (add_blocker id);
            deps
            |> List.sort_uniq String.compare
            |> List.iter (fun dep_id ->
              match Hashtbl.find_opt t.relations_by_id dep_id with
              | None ->
                add_blocker
                  id
                  ("rule premise references unknown relation `" ^ dep_id ^ "`")
              | Some dep_relation ->
                (match dep_relation.kind with
                | Relation_graph.Predicate_candidate ->
                  visit (id :: stack) dep_id
                | Relation_graph.Deterministic_candidate ->
                  add_blocker
                    id
                    ("rule premise depends on deterministic relation `" ^ dep_id
                     ^ "`; predicate search generation cannot yet call deterministic result matching source-completely")
                | Relation_graph.Execution | Relation_graph.Execution_star ->
                  add_blocker
                    id
                    ("rule premise depends on execution relation `" ^ dep_id
                     ^ "`; predicate search generation cannot contain rewrite semantics in this slice")
                | Relation_graph.Unknown ->
                  add_blocker
                    id
                    ("rule premise depends on unknown relation `" ^ dep_id
                     ^ "`; predicate search generation cannot classify it source-completely")))))
    in
    visit [] id;
    let closure = List.rev !closure |> List.sort_uniq String.compare in
    match !blockers |> List.rev |> List.sort_uniq String.compare with
    | [] -> Runtime_search_candidate closure
    | blockers -> Runtime_search_blocked { closure; blockers }

  let definition_has_static_params definition =
    List.exists
      (function
        | Static_typ | Static_def | Static_gram -> true
        | Runtime_exp -> false)
      definition.params
end

module Profile_policy = struct
  type runtime_skip =
    { reason : string
    ; suggestion : string option
    }

  let gramd_skip =
    { reason =
        "runtime Maude is not the SpecTec text parser; grammar definitions have already been consumed by the frontend"
    ; suggestion = Some "Keep the origin in diagnostics and do not emit runtime Maude for GramD in this profile"
    }
end

module Hint_policy = struct
  type classification =
    | Presentation
    | Semantic_obligation
    | Translator_annotation
    | Unknown

  let string_has_prefix ~prefix text =
    let prefix_len = String.length prefix in
    String.length text >= prefix_len
    && String.sub text 0 prefix_len = prefix

  let classify_hint_name = function
    | "desc" | "show" | "name" ->
      Presentation
    | "maude_equational_view" ->
      Translator_annotation
    | "builtin" | "partial" | "inverse" | "macro" | "tabular" ->
      Semantic_obligation
    | name when string_has_prefix ~prefix:"prose" name -> Presentation
    | _ -> Unknown

  let classify hint =
    classify_hint_name hint.hintid.it

  let string_of_classification = function
    | Presentation -> "presentation"
    | Semantic_obligation -> "semantic-obligation"
    | Translator_annotation -> "translator-annotation"
    | Unknown -> "unknown"
end
