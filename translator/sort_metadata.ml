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

type t =
  { type_env : Il.Env.t
  ; type_definitions : (string * inst list) list
  ; annotated : maude_sort list
  ; edges : (maude_sort * maude_sort) list
  ; proper : (maude_sort * maude_sort) list
  ; owners : (constructor * maude_sort list) list
  ; lists : maude_sort list
  }

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

let rec fold_defs visit acc = function
  | [] -> acc
  | def :: defs ->
      let acc = visit acc def in
      let acc =
        match def.it with
        | RecD nested -> fold_defs visit acc nested
        | TypD _ | RelD _ | DecD _ | GramD _ | HintD _ -> acc
      in
      fold_defs visit acc defs

let type_definitions script =
  fold_defs
    (fun definitions def ->
      match def.it with
      | TypD (id, _, insts) -> add_assoc id.it insts definitions
      | RelD _ | DecD _ | GramD _ | RecD _ | HintD _ -> definitions)
    [] script

let type_hints script =
  fold_defs
    (fun hints def ->
      match def.it with
      | HintD {it = TypH (id, values); _} -> add_assoc id.it values hints
      | TypD _ | RelD _ | DecD _ | GramD _ | RecD _ | HintD _ -> hints)
    [] script

let hint_values name values =
  values |> List.filter (fun hint -> hint.hintid.it = name)

let require_flags name values =
  List.iter
    (fun hint ->
      match hint.hintexp.it with
      | El.Ast.SeqE [] -> ()
      | _ -> invalid_arg (name ^ " must be a flag hint"))
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
              | _ -> invalid_arg "maude_subsort must name a syntax type"
            in
            if not (List.mem source annotated) then
              invalid_arg "maude_subsort requires maude_sort on its source";
            if not (List.mem target annotated) then
              invalid_arg "maude_subsort target must have maude_sort";
            source, target))

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

let validate_edges edges =
  List.iter
    (fun (subsort, supersort) ->
      if is_subsort edges [] supersort subsort then
        invalid_arg "maude_subsort hints must be acyclic")
    edges

let order_sorts edges sorts =
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
        | [] -> invalid_arg "maude_subsort hints must be acyclic"
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

let typed_list_sorts_of script annotated edges =
  let lists = ref [] in
  let module Visitor = Il.Iter.Make (struct
    include Il.Iter.Skip

    let visit_typ typ =
      match typ.it with
      | IterT ({it = VarT (id, _); _}, (List | List1 | ListN _))
        when List.mem id.it annotated ->
          lists := add_unique String.equal id.it !lists
      | VarT _ | BoolT | NumT _ | TextT | TupT _ | IterT _ -> ()
  end)
  in
  Visitor.list Visitor.def script;
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
  let closed = close !lists in
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
  | [] -> invalid_arg "constructor has incomparable annotated owners"
  | _ -> invalid_arg "constructor has ambiguous annotated owners"

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

let scan script =
  let definitions = type_definitions script in
  let hints = type_hints script in
  let annotated = annotated_sorts_of hints in
  let edges = subsort_edges_of hints annotated in
  validate_edges edges;
  let annotated = order_sorts edges annotated in
  let proper = proper_sorts_of annotated edges in
  let lists = typed_list_sorts_of script annotated edges in
  let owners = constructor_owners_of definitions annotated in
  { type_env = Il.Env.env_of_script script
  ; type_definitions = definitions
  ; annotated
  ; edges
  ; proper
  ; owners
  ; lists
  }

let annotated_sorts metadata = metadata.annotated
let subsort_edges metadata = metadata.edges
let proper_sorts metadata = metadata.proper
let constructor_owners metadata = metadata.owners
let typed_list_sorts metadata = metadata.lists

let typed_parents metadata sort =
  metadata.edges
  |> List.filter_map (fun (source, target) ->
       if source = sort && List.mem target metadata.lists then Some target
       else None)

let typed_parent metadata sort =
  match typed_parents metadata sort with
  | [] -> None
  | [parent] -> Some parent
  | _ -> invalid_arg "typed-list subsort has multiple immediate supersorts"

let rec find_typed_list_root metadata seen sort =
  if List.mem sort seen then invalid_arg "typed-list subsort cycle"
  else
    match typed_parent metadata sort with
    | None -> sort
    | Some parent -> find_typed_list_root metadata (sort :: seen) parent

let typed_list_root metadata sort =
  find_typed_list_root metadata [] sort

let typed_list_roots metadata =
  metadata.lists
  |> List.filter (fun sort -> Option.is_none (typed_parent metadata sort))

let typed_list_subsort_edges metadata =
  metadata.edges
  |> List.filter (fun (source, target) ->
       List.mem source metadata.lists
       && (List.mem target metadata.lists || target = "SpectecTerminal"))

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
  { sort = title ^ "List"
  ; empty = "eps"
  ; concat = "_ _"
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

let constructors_of_typ metadata id =
  constructors_of_name metadata.type_definitions [] id.it
