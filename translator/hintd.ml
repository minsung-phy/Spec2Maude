open Util.Source
open Il.Ast

type maude_sort = string
type constructor = mixop

type sequence_representation =
  { sort : maude_sort
  ; empty : string
  ; concat : string
  ; append : string
  ; occurs : string
  ; size : string
  ; repeat : string
  ; lift : string
  ; typed : bool
  }

type relation =
  { id : id
  ; params : param list
  ; mixop : mixop
  ; rules : rule list
  }

type t =
  { type_env : Il.Env.t
  ; type_definitions : (string * inst list) list
  ; relations : relation list
  ; context_hints : (id * id * hint list * hintdef) list
  ; origins : (maude_sort * region) list
  ; annotated : maude_sort list
  ; edges : (maude_sort * maude_sort) list
  ; proper : (maude_sort * maude_sort) list
  ; owners : (constructor * maude_sort list) list
  ; lists : maude_sort list
  }

let unsupported_sort at reason =
  Util.Error.error at "translation" ("Unsupported: maude sort hints " ^ reason)

let add_unique equal value values =
  if List.exists (equal value) values then values else values @ [value]

let add_assoc key values entries =
  let rec add = function
    | [] -> [key, values]
    | (key', values') :: entries when key = key' ->
        (key, values' @ values) :: entries
    | entry :: entries -> entry :: add entries
  in
  add entries

type source_index =
  { definitions : (string * inst list) list
  ; type_hints : (string * hint list) list
  ; relations : relation list
  ; context_hints : (id * id * hint list * hintdef) list
  ; list_uses : string list
  }

let scan_source script =
  let definitions = ref [] in
  let type_hints = ref [] in
  let relations = ref [] in
  let context_hints = ref [] in
  let list_uses = ref [] in
  let module Visitor = Il.Iter.Make (struct
    include Il.Iter.Skip

    let visit_def def =
      match def.it with
      | TypD (id, _, insts) ->
          definitions := add_assoc id.it insts !definitions
      | RelD (id, params, mixop, _, rules) ->
          relations := {id; params; mixop; rules} :: !relations
      | HintD ({it = TypH (id, values); _}) ->
          type_hints := add_assoc id.it values !type_hints
      | HintD ({it = RuleH (relation, rule, values); _} as hint) ->
          context_hints := (relation, rule, values, hint) :: !context_hints
      | DecD _ | GramD _ | RecD _ | HintD _ -> ()

    let visit_typ typ =
      match typ.it with
      | IterT ({it = VarT (id, _); _}, (List | List1 | ListN _)) ->
          list_uses := add_unique String.equal id.it !list_uses
      | VarT _ | BoolT | NumT _ | TextT | TupT _ | IterT _ -> ()
  end)
  in
  Visitor.list Visitor.def script;
  { definitions = !definitions
  ; type_hints = !type_hints
  ; relations = List.rev !relations
  ; context_hints = List.rev !context_hints
  ; list_uses = !list_uses
  }

let hint_values name values =
  values |> List.filter (fun hint -> hint.hintid.it = name)

let require_flags name values =
  List.iter
    (fun hint ->
      match hint.hintexp.it with
      | El.Ast.SeqE [] -> ()
      | _ -> unsupported_sort hint.hintid.at (name ^ " must be a flag"))
    values

let annotated_sorts_of hints =
  hints
  |> List.filter_map (fun (source, values) ->
       let markers = hint_values "maude_sort" values in
       require_flags "maude_sort" markers;
       if markers = [] then None else Some source)

let explicit_edges hints annotated =
  hints
  |> List.concat_map (fun (source, values) ->
       hint_values "maude_subsort" values
       |> List.map (fun hint ->
            let target =
              match hint.hintexp.it with
              | El.Ast.TextE target -> target
              | _ -> unsupported_sort hint.hintid.at
                  "maude_subsort must name a syntax type"
            in
            if not (List.mem source annotated) then
              unsupported_sort hint.hintid.at
                "maude_subsort requires maude_sort on its source";
            if not (List.mem target annotated) then
              unsupported_sort hint.hintid.at
                "maude_subsort target must have maude_sort";
            source, target))

let sort_origin origins sort =
  Option.value (List.assoc_opt sort origins) ~default:no_region

let subsort_edges_of hints annotated =
  let explicit = explicit_edges hints annotated in
  let roots =
    annotated
    |> List.filter (fun sort ->
         not (List.exists (fun (subsort, _) -> subsort = sort) explicit))
    |> List.map (fun sort -> sort, "SpectecTerminal")
  in
  explicit @ roots

let rec is_subsort edges seen source target =
  source = target
  ||
  (not (List.mem source seen)
   && List.exists
        (fun (subsort, supersort) ->
          subsort = source
          && is_subsort edges (source :: seen) supersort target)
        edges)

let validate_edges origins edges =
  List.iter
    (fun (subsort, supersort) ->
      if is_subsort edges [] supersort subsort then
        unsupported_sort (sort_origin origins subsort)
          "maude_subsort graph must be acyclic")
    edges

let order_sorts origins edges sorts =
  let rec order ordered = function
    | [] -> List.rev ordered
    | remaining ->
        let ready, blocked =
          List.partition
            (fun sort ->
              not
                (List.exists
                   (fun (subsort, supersort) ->
                     supersort = sort && List.mem subsort remaining)
                   edges))
            remaining
        in
        match ready with
        | [] ->
            let at =
              match remaining with
              | sort :: _ -> sort_origin origins sort
              | [] -> no_region
            in
            unsupported_sort at "maude_subsort graph must be acyclic"
        | _ -> order (List.rev_append ready ordered) blocked
  in
  order [] sorts

let constructor_equal = Il.Eq.eq_mixop

let proper_sort sort = String.capitalize_ascii sort ^ "Proper"

let proper_sorts_of annotated edges =
  annotated
  |> List.filter (fun supersort ->
       List.exists
         (fun subsort ->
           subsort <> supersort
           && is_subsort edges [] subsort supersort)
         annotated)
  |> List.map (fun sort -> proper_sort sort, sort)

let rec constructors_of_name definitions seen name =
  if List.mem name seen then []
  else
    match List.assoc_opt name definitions with
    | None -> []
    | Some insts ->
        insts
        |> List.concat_map (constructors_of_inst definitions (name :: seen))
        |> List.fold_left
             (fun constructors constructor ->
               add_unique constructor_equal constructor constructors)
             []

and constructors_of_inst definitions seen inst =
  match inst.it with
  | InstD (_, _, {it = AliasT typ; _}) ->
      constructors_of_transparent_typ definitions seen typ
  | InstD (_, _, {it = StructT _; _}) -> []
  | InstD (_, _, {it = VariantT cases; _}) ->
      List.concat_map
        (fun (mixop, (typ, _, _), _) ->
          if Mixop.is_hole_only mixop then
            constructors_of_transparent_typ definitions seen typ
          else [mixop])
        cases

and constructors_of_transparent_typ definitions seen typ =
  match typ.it with
  | VarT (id, _) -> constructors_of_name definitions seen id.it
  | TupT [(_, typ)] -> constructors_of_transparent_typ definitions seen typ
  | IterT (typ, _) -> constructors_of_transparent_typ definitions seen typ
  | BoolT | NumT _ | TextT | TupT _ -> []

let constructor_owners_of definitions annotated =
  List.fold_left
    (fun owners owner ->
      constructors_of_name definitions [] owner
      |> List.fold_left
           (fun owners constructor ->
             let rec add = function
               | [] -> [constructor, [owner]]
               | (constructor', owners') :: entries
                 when constructor_equal constructor constructor' ->
                   (constructor', add_unique String.equal owner owners') :: entries
               | entry :: entries -> entry :: add entries
             in
             add owners)
           owners)
    [] annotated

let typed_list_sorts_of list_uses annotated edges =
  let lists = List.filter (fun sort -> List.mem sort annotated) list_uses in
  let rec close lists =
    let supersorts =
      edges
      |> List.filter_map (fun (source, target) ->
           if List.mem source lists && List.mem target annotated
           then Some target else None)
    in
    let lists' =
      List.fold_left
        (fun lists sort -> add_unique String.equal sort lists)
        lists supersorts
    in
    if List.length lists = List.length lists' then lists else close lists'
  in
  let closed = close lists in
  List.filter (fun sort -> List.mem sort closed) annotated

let primitive_sort typ =
  match typ.it with
  | NumT `NatT -> "Nat"
  | NumT `IntT -> "Int"
  | IterT _ -> "SpectecTerminals"
  | VarT _ | BoolT | NumT (`RatT | `RealT) | TextT | TupT _ ->
      "SpectecTerminal"

let common_sort = function
  | sort :: sorts when List.for_all (String.equal sort) sorts -> sort
  | [] | _ -> "SpectecTerminal"

let list_sort sort =
  String.capitalize_ascii sort ^ "List"

let constructor_result_sort metadata constructor =
  let owners =
    metadata.owners
    |> List.find_opt (fun (constructor', _) ->
         constructor_equal constructor constructor')
    |> Option.map snd
    |> Option.value ~default:[]
  in
  let fail reason =
    let at =
      match owners with
      | owner :: _ -> sort_origin metadata.origins owner
      | [] -> no_region
    in
    unsupported_sort at reason
  in
  match
    owners
    |> List.filter (fun candidate ->
         List.for_all
           (fun owner -> is_subsort metadata.edges [] candidate owner)
           owners)
  with
  | [owner] ->
      begin match List.find_opt (fun (_, sort) -> sort = owner) metadata.proper with
      | Some (proper, _) -> proper
      | None -> owner
      end
  | [] when owners = [] -> "SpectecTerminal"
  | [] -> fail "constructor has incomparable annotated owners"
  | _ -> fail "constructor has ambiguous annotated owners"

let rec sort_of_typ_seen metadata seen typ =
  match typ.it with
  | VarT (id, _) when List.mem id.it metadata.annotated -> id.it
  | IterT ({it = VarT (id, _); _}, iter)
    when List.mem id.it metadata.lists ->
      begin match iter with
      | List | List1 | ListN _ -> list_sort id.it
      | Opt -> "SpectecTerminals"
      end
  | VarT (id, _) when not (List.mem id.it seen) ->
      begin match List.assoc_opt id.it metadata.type_definitions with
      | None -> "SpectecTerminal"
      | Some insts ->
          insts
          |> List.map (sort_of_inst metadata (id.it :: seen))
          |> common_sort
      end
  | VarT _ -> "SpectecTerminal"
  | _ -> primitive_sort typ

and sort_of_inst metadata seen inst =
  match inst.it with
  | InstD (_, _, {it = AliasT typ; _}) ->
      sort_of_typ_seen metadata seen typ
  | InstD (_, _, {it = StructT _; _}) ->
      "SpectecTerminal"
  | InstD (_, _, {it = VariantT cases; _}) ->
      cases
      |> List.map (fun (mixop, (typ, _, _), _) ->
           if Mixop.is_hole_only mixop then
             match typ.it with
             | TupT [(_, payload)] -> sort_of_typ_seen metadata seen payload
             | _ -> "SpectecTerminal"
           else constructor_result_sort metadata mixop)
      |> common_sort

(* Shared list constructors require a chain: sibling lists would give their
 * common empty constructor two incomparable least sorts. Independent chains
 * are instantiated separately. *)
let validate_list_families hints lists edges =
  let below source target = is_subsort edges [] source target in
  List.iter
    (fun source ->
      List.iter
        (fun target ->
          let connected =
            List.exists
              (fun sort ->
                (below source sort && below target sort)
                || (below sort source && below sort target))
              lists
          in
          if connected && not (below source target || below target source) then
            let hint = List.hd (hint_values "maude_sort" (List.assoc source hints)) in
            Util.Error.error hint.hintid.at "translation"
              ("Unsupported: typed-list family branches between " ^ source
               ^ " and " ^ target ^ "; shared list constructors require a chain"))
        lists)
    lists

let scan_sorts script =
  let source = scan_source script in
  let definitions = source.definitions in
  let hints = source.type_hints in
  let annotated = annotated_sorts_of hints in
  let origins =
    annotated
    |> List.filter_map (fun sort ->
         match List.assoc_opt sort hints with
         | None -> None
         | Some values ->
             begin match hint_values "maude_sort" values with
             | hint :: _ -> Some (sort, hint.hintid.at)
             | [] -> None
             end)
  in
  let edges = subsort_edges_of hints annotated in
  validate_edges origins edges;
  let annotated = order_sorts origins edges annotated in
  let proper = proper_sorts_of annotated edges in
  let lists = typed_list_sorts_of source.list_uses annotated edges in
  validate_list_families hints lists edges;
  let owners = constructor_owners_of definitions annotated in
  { type_env = Il.Env.env_of_script script
  ; type_definitions = definitions
  ; relations = source.relations
  ; context_hints = source.context_hints
  ; origins
  ; annotated
  ; edges
  ; proper
  ; owners
  ; lists
  }

let annotated_sorts metadata = metadata.annotated
let subsort_edges metadata = metadata.edges
let proper_sorts metadata = metadata.proper
let typed_list_sorts metadata = metadata.lists

let typed_parents metadata sort =
  metadata.edges
  |> List.filter_map (fun (source, target) ->
       if source = sort && List.mem target metadata.lists then Some target
       else None)

let typed_parent metadata sort =
  let parents = typed_parents metadata sort in
  (* Ignore redundant transitive edges from explicit subsort hints. *)
  let immediate =
    List.filter
      (fun parent ->
        not (List.exists
          (fun other -> other <> parent && is_subsort metadata.edges [] other parent)
          parents))
      parents
    |> List.sort_uniq String.compare
  in
  match immediate with
  | [] -> None
  | [parent] -> Some parent
  | _ -> unsupported_sort (sort_origin metadata.origins sort)
      "typed-list subsort has multiple immediate supersorts"

let rec find_typed_list_root metadata seen sort =
  if List.mem sort seen then
    unsupported_sort (sort_origin metadata.origins sort)
      "typed-list subsort graph contains a cycle"
  else
    match typed_parent metadata sort with
    | None -> sort
    | Some parent -> find_typed_list_root metadata (sort :: seen) parent

let typed_list_root metadata sort =
  find_typed_list_root metadata [] sort

let typed_list_roots metadata =
  metadata.lists
  |> List.filter (fun sort -> Option.is_none (typed_parent metadata sort))

let separate_list_families metadata =
  List.length (typed_list_roots metadata) > 1

let sort_of_typ metadata typ =
  let reduced = Il.Eval.reduce_typ metadata.type_env typ in
  match typ.it with
  | VarT (id, _) when List.mem id.it metadata.annotated -> id.it
  | IterT ({it = VarT (id, _); _}, _) when List.mem id.it metadata.lists ->
      sort_of_typ_seen metadata [] typ
  | _ -> sort_of_typ_seen metadata [] reduced

let rec typed_list_owner metadata typ =
  match typ.it with
  | IterT ({it = VarT (id, _); _}, (List | List1 | ListN _))
    when List.mem id.it metadata.lists ->
      Some id.it
  | _ ->
      let reduced = Il.Eval.reduce_typ metadata.type_env typ in
      if Il.Eq.eq_typ typ reduced then None else typed_list_owner metadata reduced

let typed_sequence_representation metadata owner =
  let title = String.capitalize_ascii owner in
  let root = typed_list_root metadata owner in
  let separate = separate_list_families metadata in
  (* Keep the existing generic representation for a single family. Different
   * roots must not overload one empty constant with incomparable sorts. *)
  { sort = title ^ "List"
  ; empty = if separate then root ^ "Nil" else "eps"
  ; concat = if separate then root ^ "Concat" else "_ _"
  ; append = root ^ "Append"
  ; occurs = root ^ "Occurs"
  ; size = root ^ "Size"
  ; repeat = owner ^ "Repeat"
  ; lift = owner ^ "Lift"
  ; typed = true
  }

let sequence_representation metadata typ =
  match typed_list_owner metadata typ with
  | Some owner -> typed_sequence_representation metadata owner
  | None ->
      { sort = "SpectecTerminals"
      ; empty = "eps"
      ; concat = "_ _"
      ; append = "_++_"
      ; occurs = "_<-_"
      ; size = "|_|"
      ; repeat = "repeatSeq"
      ; lift = "lift"
      ; typed = false
      }

let representation_inclusion metadata source target =
  match typed_list_owner metadata source, typed_list_owner metadata target with
  | Some source, Some target -> is_subsort metadata.edges [] source target
  | None, None ->
      is_subsort metadata.edges []
        (sort_of_typ metadata source) (sort_of_typ metadata target)
  | Some _, None | None, Some _ -> false

let sequence_element_wrappers metadata typ =
  match typed_list_owner metadata typ with
  | Some _ -> Some ("seq", "unseq")
  | None when sort_of_typ metadata typ = "SpectecTerminals" ->
      Some ("seq", "unseq")
  | None -> None

(* Rule-level hints are analyzed here as certificates for later RuleD
 * translation.  This module does not emit Maude code. *)
type frame =
  { mixop : mixop
  ; config_typ : typ
  ; state_typ : typ
  ; sequence_position : int
  }

type bridge =
  { source : relation
  ; ordinal : int
  ; rule : rule
  ; premise : prem
  }

type focus_pattern =
  { source : relation
  ; ordinal : int
  ; rule : rule
  ; operands : exp list
  ; trailing : exp list
  ; deferred_execution : id option
  ; bridges : bridge list
  }

type context =
  { source : relation
  ; ordinal : int
  ; rule : rule
  ; inner_relation : id
  ; prefix : id
  ; prefix_typ : typ
  ; focus : id
  ; focus_typ : typ
  ; postfix : id
  ; postfix_typ : typ
  ; proper_sort : maude_sort
  ; frame : frame
  ; patterns : focus_pattern list
  }

let unsupported at reason =
  Util.Error.error at "translation" ("Unsupported: maude_context " ^ reason)

let unique at absent ambiguous = function
  | [value] -> value
  | [] -> unsupported at absent
  | _ -> unsupported at ambiguous

let context_hint values =
  values |> List.filter (fun hint -> hint.hintid.it = "maude_context")

let target_names hint =
  match hint.hintexp.it with
  | El.Ast.TextE text ->
      begin match
        text |> String.split_on_char ' ' |> List.filter ((<>) "")
      with
      | [focus; postfix] when focus <> postfix -> focus, postfix
      | _ -> unsupported hint.hintid.at
          "hint must contain two distinct repeated-variable names"
      end
  | _ -> unsupported hint.hintid.at
      "hint argument must be a string"

let find_relation relations id at =
  relations
  |> List.filter (fun relation -> relation.id.it = id.it)
  |> unique at "refers to an unknown relation" "refers to an ambiguous relation"

let find_rule (relation : relation) id at =
  relation.rules
  |> List.mapi (fun ordinal rule -> ordinal, rule)
  |> List.filter (fun (_, rule) ->
       let RuleD (rule_id, _, _, _, _) = rule.it in
       rule_id.it = id.it)
  |> unique at "refers to an unknown rule" "refers to an ambiguous rule"

let rule_id rule =
  let RuleD (id, _, _, _, _) = rule.it in
  id

let components mixop exp =
  match Xl.Mixop.arity mixop, exp.it with
  | 0, TupE [] -> []
  | 1, _ -> [exp]
  | arity, TupE exps when List.length exps = arity -> exps
  | _ -> unsupported exp.at "rule head does not match its relation"

let rec take at count taken = function
  | rest when count = 0 -> List.rev taken, rest
  | exp :: exps -> take at (count - 1) (exp :: taken) exps
  | [] -> unsupported at "execution input arity exceeds its rule head"

let relation_inputs execution_input_count relation mixop head at =
  let input_count =
    match execution_input_count relation.id.it with
    | Some count -> count
    | None -> unsupported at "refers to a non-execution relation"
  in
  take at input_count [] (components mixop head) |> fst

let quant_type quants name at =
  quants
  |> List.filter_map (fun quant ->
       match quant.it with
       | ExpP (id, typ) when id.it = name -> Some (id, typ)
       | ExpP _ | TypP _ | DefP _ | GramP _ -> None)
  |> unique at ("names an unknown variable `" ^ name ^ "`")
       ("names an ambiguous variable `" ^ name ^ "`")

let rec preceding target next = function
  | prefix :: focus :: postfix :: _
    when focus = target && postfix = next -> Some prefix
  | _ :: names -> preceding target next names
  | [] -> None

let rec source_name exp =
  match exp.it with
  | VarE id -> Some id.it
  | IterE (_, (_, [(_, source)])) -> source_name source
  | SubE (source, _, _) -> source_name source
  | _ -> None

let empty exp =
  match exp.it with ListE [] -> true | _ -> false

let nonempty_name exp =
  match exp.it with
  | CmpE (`NeOp, _, left, right) when empty right -> source_name left
  | CmpE (`NeOp, _, left, right) when empty left -> source_name right
  | _ -> None

let nonempty_context prefix postfix exp =
  match exp.it with
  | BinE (`OrOp, `BoolT, left, right) ->
      begin match nonempty_name left, nonempty_name right with
      | Some left, Some right ->
          List.sort String.compare [left; right]
          = List.sort String.compare [prefix; postfix]
      | _ -> false
      end
  | _ -> false

let children ~deep exp =
  match exp.it with
  | TupE exps | ListE exps -> exps
  | CaseE (_, payload) | SubE (payload, _, _) -> [payload]
  | LiftE payload when deep -> [payload]
  | CatE (left, right) when deep -> [left; right]
  | IterE (body, (_, bindings)) when deep -> body :: List.map snd bindings
  | VarE _ | BoolE _ | NumE _ | TextE _ | UnE _ | BinE _ | CmpE _
  | ProjE _ | UncaseE _ | OptE _ | TheE _ | StrE _ | DotE _ | CompE _
  | LiftE _ | MemE _ | LenE _ | CatE _ | IdxE _ | SliceE _ | UpdE _
  | ExtE _ | IfE _ | CallE _ | IterE _ | CvtE _ -> []

let rec sequence_subjects metadata owner exp =
  match typed_list_owner metadata exp.note with
  | Some candidate when candidate = owner -> [exp]
  | _ -> children ~deep:false exp
      |> List.concat_map (sequence_subjects metadata owner)

let sequence_subject metadata owner inputs at =
  inputs
  |> List.concat_map (sequence_subjects metadata owner)
  |> unique at "cannot locate the focused repeated field"
       "has more than one possible focused repeated field"

let rec locate_unique ~deep at ambiguous locate exp =
  match locate exp with
  | Some result -> Some result
  | None ->
      begin match
        children ~deep exp
        |> List.filter_map (locate_unique ~deep at ambiguous locate)
      with
      | [] -> None
      | [result] -> Some result
      | _ -> unsupported at ambiguous
      end

let locate_inputs ~deep at ambiguous locate inputs =
  List.filter_map (locate_unique ~deep at ambiguous locate) inputs

let frame mixop exp state sequence_position =
  {mixop; config_typ = exp.note; state_typ = state.note; sequence_position}

let sequence_frame_opt subject inputs at =
  let find exp =
    match exp.it with
    | CaseE (mixop, {it = TupE components; _}) ->
        begin match
          components
          |> List.mapi (fun position component -> position, component)
          |> List.filter (fun (_, component) -> component == subject)
        with
        | [sequence_position, _] when List.length components = 2 ->
            let state = List.nth components (1 - sequence_position) in
            Some (frame mixop exp state sequence_position)
        | [] -> None
        | [_] -> unsupported exp.at
            "focused configuration must contain one state and one sequence"
        | _ -> unsupported exp.at
            "focused sequence occurs more than once in its configuration"
        end
    | _ -> None
  in
  match locate_inputs ~deep:false at
    "focused sequence has more than one enclosing configuration" find inputs with
  | [] -> None
  | [frame] -> Some frame
  | _ -> unsupported at
      "focused sequence has more than one enclosing input configuration"

let framed_subject (expected : frame) inputs at =
  let find exp =
    match exp.it with
    | CaseE (mixop, {it = TupE components; _})
      when mixop = expected.mixop ->
        if List.length components <> 2 then
          unsupported exp.at
            "focused configuration must contain one state and one sequence";
        Some (List.nth components expected.sequence_position)
    | _ -> None
  in
  match locate_inputs ~deep:true at
    "rule input contains more than one focused configuration" find inputs with
  | [subject] -> subject
  | [] -> unsupported at "cannot locate the focused configuration"
  | _ -> unsupported at
      "focused configuration occurs in more than one relation input"

let sequence_frame subject inputs at =
  match sequence_frame_opt subject inputs at with
  | Some frame -> frame
  | None -> unsupported at
      "focused repeated field is not inside a state/sequence configuration"

let sequence_parts exp =
  let rec collect exp parts =
    match exp.it with
    | CatE (left, right) -> collect left (collect right parts)
    | SubE (source, _, _) -> collect source parts
    | LiftE element -> element :: parts
    | ListE elements -> List.fold_right collect elements parts
    | _ -> exp :: parts
  in
  collect exp []

let rec strip_subtype exp =
  match exp.it with
  | SubE (source, _, _) -> strip_subtype source
  | _ -> exp

let constructor exp =
  match (strip_subtype exp).it with
  | CaseE (mixop, _) -> Some mixop
  | _ -> None

let focus_proper_sort metadata owner at =
  proper_sorts metadata
  |> List.filter_map (fun (proper, parent) ->
       if parent = owner then Some proper else None)
  |> unique at "focused sort has no proper-instruction subsort"
       "focused sort has ambiguous proper-instruction subsorts"

let is_trigger metadata proper exp =
  match constructor exp with
  | Some mixop -> constructor_result_sort metadata mixop = proper
  | None -> false

let rec value_part metadata owner exp =
  let exp = strip_subtype exp in
  match exp.it with
  | IterE (element, _) | LiftE element -> value_part metadata owner element
  | ListE elements -> List.for_all (value_part metadata owner) elements
  | _ ->
      let candidate =
        match constructor exp with
        | Some mixop -> constructor_result_sort metadata mixop
        | None ->
            begin match typed_list_owner metadata exp.note with
            | Some candidate -> candidate
            | None -> sort_of_typ metadata exp.note
            end
      in
      candidate <> owner
      && is_subsort
           (subsort_edges metadata) [] candidate owner

let split_trigger metadata owner subject at =
  let parts = sequence_parts subject in
  let proper = focus_proper_sort metadata owner at in
  let rec split operands = function
    | [] -> None
    | exp :: trailing when is_trigger metadata proper exp ->
        Some (List.rev operands, exp, trailing)
    | exp :: rest -> split (exp :: operands) rest
  in
  match split [] parts with
  | None -> None
  | Some (operands, trigger, trailing) ->
      if List.exists (is_trigger metadata proper) trailing then
        unsupported at "has more than one top-level proper-instruction trigger";
      if not (List.for_all (value_part metadata owner) operands) then
        unsupported at
          ("has a non-value before its proper-instruction trigger in `"
           ^ Il.Print.string_of_exp subject ^ "`");
      Some (operands, trigger, trailing)

let execution_premises execution_input_count premises =
  premises
  |> List.filter_map (fun premise ->
       match premise.it with
       | RulePr (id, _, mixop, head)
         when Option.is_some (execution_input_count id.it) ->
           Some (id, mixop, head, premise)
       | RulePr _ | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> None)

let shares_variable left right =
  let left = (Il.Free.free_exp left).varid in
  let right = (Il.Free.free_exp right).varid in
  not (Il.Free.Set.is_empty (Il.Free.Set.inter left right))

let focus_patterns metadata execution_input_count relations context owner =
  let rec visit seen bridges relation_id =
    if List.mem relation_id.it seen then
      unsupported relation_id.at "execution-relation bridge contains a cycle";
    let relation = find_relation relations relation_id relation_id.at in
    relation.rules
    |> List.mapi (fun ordinal rule -> ordinal, rule)
    |> List.concat_map (fun (ordinal, rule) ->
         let RuleD (id, _, mixop, head, premises) = rule.it in
         let is_context_rule =
           relation.id.it = context.source.id.it
           && id.it = (rule_id context.rule).it
         in
         let execution = execution_premises execution_input_count premises in
         if is_context_rule then []
         else
           let inputs =
             relation_inputs execution_input_count relation mixop head rule.at
           in
           let subject =
             if relation.id.it = context.source.id.it then
               framed_subject context.frame inputs rule.at
             else
               sequence_subject metadata owner inputs rule.at
           in
           match split_trigger metadata owner subject rule.at with
           | Some (operands, _, trailing) ->
               let deferred_execution =
                 match
                   execution
                   |> List.filter_map (fun (target, _, _, _) ->
                        if target.it = relation.id.it then Some target else None)
                 with
                 | [] -> None
                 | [target] -> Some target
                 | _ -> unsupported rule.at
                     "has more than one recursive execution premise"
               in
               [{ source = relation
                ; ordinal
                ; rule
                ; operands
                ; trailing
                ; deferred_execution
                ; bridges = List.rev bridges
                }]
           | None ->
               begin match execution with
               | [(target_id, premise_mixop, premise_head, premise)]
                 when target_id.it <> relation.id.it ->
                   if List.length premises <> 1 then
                     unsupported rule.at
                       "execution-relation bridge has additional premises";
                   let target = find_relation relations target_id premise.at in
                   let target_inputs =
                     relation_inputs execution_input_count target
                       premise_mixop premise_head premise.at
                   in
                   let target_subject =
                     sequence_subject metadata owner target_inputs premise.at
                   in
                   if not (shares_variable subject target_subject) then
                     unsupported premise.at
                       "bridge does not pass the focused repeated field";
                   let bridge =
                     { source = relation
                     ; ordinal
                     ; rule
                     ; premise
                     }
                   in
                   visit (relation.id.it :: seen) (bridge :: bridges) target_id
               | [] -> unsupported rule.at
                   ("direct execution rule has no proper-instruction trigger in `"
                    ^ Il.Print.string_of_exp subject ^ "`")
               | _ -> unsupported rule.at
                   "has an ambiguous execution-relation bridge"
               end)
  in
  visit [] [] context.inner_relation

let validate metadata execution_input_count relations
    (relation_id, rule_id, values, hintdef) =
  match context_hint values with
  | [] -> None
  | _ :: _ :: _ -> unsupported hintdef.at
      "rule has more than one maude_context hint"
  | [hint] ->
      let focus_name, postfix_name = target_names hint in
      let relation = find_relation relations relation_id hintdef.at in
      let input_count =
        match execution_input_count relation.id.it with
        | Some count -> count
        | None -> unsupported hintdef.at
            "is only supported on an execution relation"
      in
      let ordinal, rule = find_rule relation rule_id hintdef.at in
      let RuleD (_, quants, _, head, premises) = rule.it in
      let inputs, _ =
        take rule.at input_count [] (components relation.mixop head)
      in
      let focus, focus_typ = quant_type quants focus_name hint.hintid.at in
      let postfix, postfix_typ = quant_type quants postfix_name hint.hintid.at in
      let focus_owner =
        match typed_list_owner metadata focus_typ,
          typed_list_owner metadata postfix_typ with
        | Some focus_owner, Some postfix_owner when focus_owner = postfix_owner ->
            focus_owner
        | _ -> unsupported hint.hintid.at
            "requires a repeated annotated prefix followed by two repeated fields of one annotated supersort"
      in
      let subject = sequence_subject metadata focus_owner inputs rule.at in
      let prefix_name =
        match
          subject |> sequence_parts |> List.filter_map source_name
          |> preceding focus_name postfix_name
        with
        | Some name -> name
        | None -> unsupported hint.hintid.at
            "targets must follow one repeated prefix in the input configuration"
      in
      let prefix, prefix_typ = quant_type quants prefix_name hint.hintid.at in
      begin match typed_list_owner metadata prefix_typ with
      | Some prefix_owner when prefix_owner <> focus_owner
          && is_subsort (subsort_edges metadata) [] prefix_owner focus_owner -> ()
      | _ -> unsupported hint.hintid.at
          "requires a repeated annotated prefix followed by two repeated fields of one annotated supersort"
      end;
      let frame = sequence_frame subject inputs rule.at in
      let inner_relation =
        match execution_premises execution_input_count premises with
        | [(inner, _, _, _)] -> inner
        | [] -> unsupported rule.at
            "rule must have exactly one internal execution premise"
        | _ -> unsupported rule.at
            "rule has more than one internal execution premise"
      in
      if not
           (List.exists
              (fun premise ->
                match premise.it with
                | IfPr condition ->
                    nonempty_context prefix.it postfix.it condition
                | RulePr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> false)
              premises)
      then unsupported rule.at
          "rule must require a nonempty prefix or postfix";
      Some
        ({ source = relation
         ; ordinal
         ; rule
         ; inner_relation
         ; prefix
         ; prefix_typ
         ; focus
         ; focus_typ
         ; postfix
         ; postfix_typ
         ; proper_sort = focus_proper_sort metadata focus_owner hint.hintid.at
         ; frame
         ; patterns = []
         }, focus_owner)

let scan_contexts metadata execution_input_count =
  metadata.context_hints
  |> List.filter_map
       (validate metadata execution_input_count metadata.relations)
  |> List.map (fun (context, owner) ->
       let patterns =
         focus_patterns metadata execution_input_count metadata.relations
           context owner
       in
       {context with patterns})
