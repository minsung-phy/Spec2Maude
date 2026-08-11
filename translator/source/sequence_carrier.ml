open Il.Ast

(* A field receives the compact sequence representation only when every use in
   the closed source index preserves that representation.  The analysis is a
   conservative must-analysis over IL syntax: any escaping or ambiguous use
   falls back to the ordinary sequence carrier. *)

type field =
  { owner_id : string
  ; atom : atom
  }

type t =
  { env : Il.Env.t
  ; fields : field list
  }

let owner_id env typ =
  match (Il.Eval.reduce_typ env typ).it with
  | VarT (id, _) -> Some id.it
  | BoolT | NumT _ | TextT | TupT _ | IterT _ -> None

let declared_field env owner_typ atom =
  match owner_id env owner_typ, (Il.Eval.reduce_typdef env owner_typ).it with
  | Some owner_id, StructT fields ->
    fields
    |> List.find_map (fun (field, (typ, _, _), _) ->
         if
           Xl.Atom.eq field atom
           && Type_shape.is_flat_list_typ (Il.Eval.reduce_typ env typ)
         then
           Some { owner_id; atom }
         else
           None)
  | Some _, (AliasT _ | VariantT _)
  | None, _ ->
    None

let rec path_fields env (path : path) =
  match path.it with
  | RootP -> []
  | DotP (parent, _) -> path_fields env parent
  | IdxP (parent, _) -> path_fields env parent
  | SliceP (({ it = DotP (owner, atom); _ } as parent), _, _) ->
    Option.to_list (declared_field env owner.note atom) @ path_fields env parent
  | SliceP (parent, _, _) -> path_fields env parent

let collector env =
  { (Il.Walk.base_collector [] List.rev_append) with
    collect_exp = (fun (exp : exp) ->
      match exp.it with
      | UpdE (_, path, _) -> path_fields env path, true
      | BoolE _ | NumE _ | TextE _ | VarE _ | UnE _ | BinE _ | CmpE _
      | TupE _ | ProjE _ | CaseE _ | UncaseE _ | OptE _ | TheE _ | StrE _
      | DotE _ | CompE _ | ListE _ | LiftE _ | MemE _ | LenE _ | CatE _
      | IdxE _ | SliceE _ | ExtE _ | IfE _ | CallE _ | IterE _ | CvtE _
      | SubE _ ->
        [], true)
  }

let collect_deftyp collect_typ collect_param collect_prem (deftyp : deftyp) =
  match deftyp.it with
  | AliasT typ -> collect_typ typ
  | StructT fields ->
    fields
    |> List.concat_map (fun (_, (typ, params, prems), _) ->
         collect_typ typ
         @ List.concat_map collect_param params
         @ List.concat_map collect_prem prems)
  | VariantT cases ->
    cases
    |> List.concat_map (fun (_, (typ, params, prems), _) ->
         collect_typ typ
         @ List.concat_map collect_param params
         @ List.concat_map collect_prem prems)

let def_fields env (def : def) =
  let collector = collector env in
  let collect_exp = Il.Walk.collect_exp collector in
  let collect_arg = Il.Walk.collect_arg collector in
  let collect_typ = Il.Walk.collect_typ collector in
  let collect_param = Il.Walk.collect_param collector in
  let collect_prem = Il.Walk.collect_prem collector in
  let collect_sym = Il.Walk.collect_sym collector in
  let collect_deftyp = collect_deftyp collect_typ collect_param collect_prem in
  match def.it with
  | TypD (_, params, insts) ->
    List.concat_map collect_param params
    @ List.concat_map (fun (inst : inst) ->
        let InstD (params, args, deftyp) = inst.it in
        List.concat_map collect_param params
        @ List.concat_map collect_arg args
        @ collect_deftyp deftyp)
        insts
  | RelD (_, params, _, typ, rules) ->
    List.concat_map collect_param params
    @ collect_typ typ
    @ List.concat_map (fun (rule : rule) ->
        let RuleD (_, params, _, head, prems) = rule.it in
        List.concat_map collect_param params
        @ collect_exp head
        @ List.concat_map collect_prem prems)
        rules
  | DecD (_, params, typ, clauses) ->
    List.concat_map collect_param params
    @ collect_typ typ
    @ List.concat_map (fun (clause : clause) ->
        let DefD (params, args, body, prems) = clause.it in
        List.concat_map collect_param params
        @ List.concat_map collect_arg args
        @ collect_exp body
        @ List.concat_map collect_prem prems)
        clauses
  | GramD (_, params, typ, prods) ->
    List.concat_map collect_param params
    @ collect_typ typ
    @ List.concat_map (fun (prod : prod) ->
        let ProdD (params, sym, body, prems) = prod.it in
        List.concat_map collect_param params
        @ collect_sym sym
        @ collect_exp body
        @ List.concat_map collect_prem prems)
        prods
  | RecD _ | HintD _ -> []

let same_field left right =
  String.equal left.owner_id right.owner_id && Xl.Atom.eq left.atom right.atom

let is_field field = function
  | Some candidate -> same_field field candidate
  | None -> false

let rec whole_sequence_var env (exp : exp) =
  let is_sequence =
    Type_shape.is_flat_list_typ (Il.Eval.reduce_typ env exp.note)
  in
  match exp.it with
  | VarE id when is_sequence -> Some id.it
  | IterE ({ it = VarE id; _ }, (List, [])) when is_sequence -> Some id.it
  | IterE ({ it = VarE body; _ }, (List, [ generator, source ]))
    when is_sequence && String.equal body.it generator.it ->
    whole_sequence_var env source
  | BoolE _ | NumE _ | TextE _ | VarE _ | UnE _ | BinE _ | CmpE _
  | TupE _ | ProjE _ | CaseE _ | UncaseE _ | OptE _ | TheE _ | StrE _
  | DotE _ | CompE _ | ListE _ | LiftE _ | MemE _ | LenE _ | CatE _
  | IdxE _ | SliceE _ | UpdE _ | ExtE _ | IfE _ | CallE _ | IterE _
  | CvtE _ | SubE _ ->
    None

let capture_collector env field =
  { (Il.Walk.base_collector [] List.rev_append) with
    collect_exp = (fun (exp : exp) ->
      match exp.it with
      | StrE fields ->
        fields
        |> List.filter_map (fun (atom, value) ->
             if is_field field (declared_field env exp.note atom) then
               whole_sequence_var env value
             else
               None),
        true
      | BoolE _ | NumE _ | TextE _ | VarE _ | UnE _ | BinE _ | CmpE _
      | TupE _ | ProjE _ | CaseE _ | UncaseE _ | OptE _ | TheE _
      | DotE _ | CompE _ | ListE _ | LiftE _ | MemE _ | LenE _
      | CatE _ | IdxE _ | SliceE _ | UpdE _ | ExtE _ | IfE _
      | CallE _ | IterE _ | CvtE _ | SubE _ ->
        [], true)
  }

let captured_exp collector exp =
  Il.Walk.collect_exp collector exp

let captured_prem collector prem =
  Il.Walk.collect_prem collector prem

let captured_sym collector sym =
  Il.Walk.collect_sym collector sym

let selected_dot env field (record : exp) atom =
  is_field field (declared_field env record.note atom)

type path_step =
  | Path_dot of typ * atom
  | Path_index of exp
  | Path_slice of exp * exp

let path_steps path =
  let rec collect steps (path : path) =
    match path.it with
    | RootP -> steps
    | DotP (parent, atom) ->
      collect (Path_dot (parent.note, atom) :: steps) parent
    | IdxP (parent, index) -> collect (Path_index index :: steps) parent
    | SliceP (parent, first, count) ->
      collect (Path_slice (first, count) :: steps) parent
  in
  collect [] path

type path_use =
  | No_selected_field
  | Selected_field_safe
  | Selected_field_unsafe

let classify_path env field steps =
  let selected = function
    | Path_dot (owner_typ, atom) ->
      is_field field (declared_field env owner_typ atom)
    | Path_index _ | Path_slice _ -> false
  in
  let rec find index found = function
    | [] -> found
    | step :: rest ->
      find (index + 1) (if selected step then index :: found else found) rest
  in
  let rec drop count steps =
    if count = 0 then steps
    else
      match steps with
      | [] -> []
      | _ :: rest -> drop (count - 1) rest
  in
  match List.rev (find 0 [] steps) with
  | [] -> No_selected_field
  | [ index ] ->
    let suffix = drop (index + 1) steps in
    (match suffix with
    | [] | [ Path_slice _ ] -> Selected_field_safe
    | Path_dot _ :: _ | Path_index _ :: _ | Path_slice _ :: _ ->
      Selected_field_unsafe)
  | _ :: _ :: _ -> Selected_field_unsafe

module Names = Set.Make (String)

type scope =
  { bound : Names.t
  ; carriers : Names.t
  }

let names strings =
  List.fold_left (fun names name -> Names.add name names) Names.empty strings

let var_names free =
  Il.Free.Set.elements free.Il.Free.varid |> names

let exp_vars exp =
  var_names (Il.Free.free_exp exp)

let prem_vars prem =
  var_names (Il.Free.free_prem prem)

let sym_vars sym =
  var_names (Il.Free.free_sym sym)

let iter_has_outward_source scope (_, generators) =
  List.exists (fun (_, source) ->
    not (Names.subset (exp_vars source) scope.bound))
    generators

let prem_uses_carrier collector scope prem =
  not (Names.is_empty (Names.inter scope.carriers (prem_vars prem)))
  || captured_prem collector prem <> []

let bound_typ_vars (typ : typ) =
  match typ.it with
  | TupT fields ->
    fields
    |> List.fold_left
         (fun names ((id : id), _) -> Names.add id.it names)
         Names.empty
  | BoolT | NumT _ | TextT | VarT _ | IterT _ -> Names.empty

let add_param scope (param : param) =
  match param.it with
  | ExpP (id, _) -> { scope with bound = Names.add id.it scope.bound }
  | TypP _ | DefP _ | GramP _ -> scope

let add_params scope params =
  List.fold_left add_param scope params

let add_iter_binders scope (iter, generators) =
  let bound =
    generators
    |> List.fold_left
         (fun bound ((id : id), _) -> Names.add id.it bound)
         scope.bound
  in
  let bound =
    match iter with
    | ListN (_, Some id) -> Names.add id.it bound
    | Opt | List | List1 | ListN (_, None) -> bound
  in
  { scope with bound }

let has_unbound scope exp =
  not (Names.subset (exp_vars exp) scope.bound)

let rec is_unbound_var scope (exp : exp) =
  match exp.it with
  | VarE id -> not (Names.mem id.it scope.bound)
  | SubE (inner, _, _) | CvtE (inner, _, _) -> is_unbound_var scope inner
  | BoolE _ | NumE _ | TextE _ | UnE _ | BinE _ | CmpE _ | TupE _
  | ProjE _ | CaseE _ | UncaseE _ | OptE _ | TheE _ | StrE _ | DotE _
  | CompE _ | ListE _ | LiftE _ | MemE _ | LenE _ | CatE _ | IdxE _
  | SliceE _ | UpdE _ | ExtE _ | IfE _ | CallE _ | IterE _ -> false

let rec safe_exp env field carriers (exp : exp) =
  let safe = safe_exp env field carriers in
  let safe_all = List.for_all safe in
  match exp.it with
  | BoolE _ | NumE _ | TextE _ -> true
  | VarE id -> not (Names.mem id.it carriers)
  | LenE source -> safe_sequence_source env field carriers source
  | IdxE (source, index) ->
    safe_sequence_source env field carriers source && safe index
  | SliceE (source, first, count) ->
    safe_sequence_source env field carriers source && safe first && safe count
  | DotE (record, atom) ->
    not (selected_dot env field record atom) && safe record
  | StrE fields ->
    List.for_all (fun (atom, value) ->
      if is_field field (declared_field env exp.note atom) then
        safe_canonical_field env field carriers value
      else
        safe value)
      fields
  | UpdE (record, path, replacement) ->
    safe record
    && safe_path_expressions env field carriers path
    && (match classify_path env field (path_steps path) with
       | No_selected_field -> safe replacement
       | Selected_field_safe ->
         safe_canonical_field env field carriers replacement
       | Selected_field_unsafe -> false)
  | ExtE (record, path, extension) ->
    safe record
    && safe_path_expressions env field carriers path
    && classify_path env field (path_steps path) = No_selected_field
    && safe extension
  | UnE (_, _, inner) | ProjE (inner, _) | CaseE (_, inner)
  | UncaseE (inner, _) | TheE inner | LiftE inner | CvtE (inner, _, _)
  | SubE (inner, _, _) ->
    safe inner
  | BinE (_, _, left, right) | CmpE (_, _, left, right)
  | CompE (left, right) | MemE (left, right) | CatE (left, right) ->
    safe left && safe right
  | TupE exps | ListE exps -> safe_all exps
  | OptE exp -> Option.fold ~none:true ~some:safe exp
  | IfE (condition, if_true, if_false) ->
    safe condition && safe if_true && safe if_false
  | CallE (_, args) -> List.for_all (safe_arg env field carriers) args
  | IterE (body, iterexp) ->
    safe body && safe_iterexp env field carriers iterexp

and safe_sequence_source env field carriers (exp : exp) =
  match whole_sequence_var env exp with
  | Some id when Names.mem id carriers -> true
  | _ ->
    match exp.it with
    | DotE (record, atom) when selected_dot env field record atom ->
      safe_exp env field carriers record
    | BoolE _ | NumE _ | TextE _ | VarE _ | UnE _ | BinE _ | CmpE _
    | TupE _ | ProjE _ | CaseE _ | UncaseE _ | OptE _ | TheE _ | StrE _
    | DotE _ | CompE _ | ListE _ | LiftE _ | MemE _ | LenE _ | CatE _
    | IdxE _ | SliceE _ | UpdE _ | ExtE _ | IfE _ | CallE _ | IterE _
    | CvtE _ | SubE _ ->
      safe_exp env field carriers exp

and safe_canonical_field env field carriers (exp : exp) =
  match whole_sequence_var env exp with
  | Some _ -> true
  | _ ->
    match exp.it with
    | CatE (left, right) ->
      safe_canonical_field env field carriers left
      && safe_canonical_field env field carriers right
    | ListE elements -> List.for_all (safe_exp env field carriers) elements
    | IterE (body, (ListN (count, None), [])) ->
      safe_exp env field carriers body && safe_exp env field carriers count
    | IterE ({ it = VarE body; _ }, (List, [ generator, source ]))
      when String.equal body.it generator.it ->
      safe_sequence_source env field carriers source
    | IterE _ -> false
    | BoolE _ | NumE _ | TextE _ | VarE _ | UnE _ | BinE _ | CmpE _
    | TupE _ | ProjE _ | CaseE _ | UncaseE _ | OptE _ | TheE _ | StrE _
    | DotE _ | CompE _ | LiftE _ | MemE _ | LenE _ | IdxE _ | SliceE _
    | UpdE _ | ExtE _ | IfE _ | CallE _ | CvtE _ | SubE _ ->
      safe_exp env field carriers exp

and safe_path_expressions env field carriers path =
  path_steps path
  |> List.for_all (function
       | Path_dot _ -> true
       | Path_index index -> safe_exp env field carriers index
       | Path_slice (first, count) ->
         safe_exp env field carriers first && safe_exp env field carriers count)

and safe_iter env field carriers = function
  | Opt | List | List1 -> true
  | ListN (count, _) -> safe_exp env field carriers count

and safe_iterexp env field carriers (iter, generators) =
  safe_iter env field carriers iter
  && List.for_all (fun (_, source) -> safe_exp env field carriers source) generators

and safe_typ env field carriers (typ : typ) =
  match typ.it with
  | BoolT | NumT _ | TextT -> true
  | VarT (_, args) -> List.for_all (safe_arg env field carriers) args
  | TupT fields ->
    List.for_all (fun (_, typ) -> safe_typ env field carriers typ) fields
  | IterT (element, iter) ->
    safe_typ env field carriers element && safe_iter env field carriers iter

and safe_arg env field carriers (arg : arg) =
  match arg.it with
  | ExpA exp -> safe_exp env field carriers exp
  | TypA typ -> safe_typ env field carriers typ
  | DefA _ -> true
  | GramA sym -> safe_sym env field carriers sym

and safe_param env field carriers (param : param) =
  match param.it with
  | ExpP (_, typ) -> safe_typ env field carriers typ
  | TypP _ -> true
  | DefP (_, params, typ) | GramP (_, params, typ) ->
    List.for_all (safe_param env field carriers) params
    && safe_typ env field carriers typ

and safe_sym env field carriers (sym : sym) =
  match sym.it with
  | VarG (_, args) -> List.for_all (safe_arg env field carriers) args
  | NumG _ | TextG _ | EpsG -> true
  | SeqG syms | AltG syms ->
    List.for_all (safe_sym env field carriers) syms
  | RangeG (left, right) ->
    safe_sym env field carriers left && safe_sym env field carriers right
  | IterG (sym, iterexp) ->
    safe_sym env field carriers sym
    && safe_iterexp env field carriers iterexp
  | AttrG (exp, sym) ->
    safe_exp env field carriers exp && safe_sym env field carriers sym

let rec safe_pattern env field carriers ~whole (exp : exp) =
  let nested = safe_pattern env field carriers ~whole:false in
  let nested_all = List.for_all nested in
  match exp.it with
  | BoolE _ | NumE _ | TextE _ -> true
  | VarE id -> whole || not (Names.mem id.it carriers)
  | IterE ({ it = VarE id; _ }, (List, [])) ->
    whole || not (Names.mem id.it carriers)
  | StrE fields ->
    List.for_all (fun (atom, value) ->
      if is_field field (declared_field env exp.note atom) then
        Option.is_some (whole_sequence_var env value)
      else
        nested value)
      fields
  | DotE (record, atom) ->
    not (selected_dot env field record atom) && nested record
  | TupE exps | ListE exps -> nested_all exps
  | OptE exp -> Option.fold ~none:true ~some:nested exp
  | CaseE (_, inner) -> nested inner
  | CatE (left, right) | CompE (left, right) ->
    nested left && nested right
  | IterE (body, iterexp) ->
    nested body && safe_iterexp env field carriers iterexp
  | LiftE inner | CvtE (inner, _, _) | SubE (inner, _, _) ->
    safe_pattern env field carriers ~whole inner
  | UnE _ | BinE _ | CmpE _ | ProjE _ | UncaseE _ | TheE _
  | MemE _ | LenE _ | IdxE _ | SliceE _ | UpdE _ | ExtE _ | IfE _
  | CallE _ ->
    safe_exp env field carriers exp

let bind_pattern env field collector scope exp =
  let captures = captured_exp collector exp |> names in
  let reused = Names.inter captures scope.bound in
  if not (Names.subset reused scope.carriers) then
    None
  else
    let carriers = Names.union captures scope.carriers in
    if safe_pattern env field carriers ~whole:true exp then
      Some
        { bound = Names.union scope.bound (exp_vars exp)
        ; carriers
        }
    else
      None

let rec bind_arg_patterns env field collector scope = function
  | [] -> Some scope
  | (arg : arg) :: rest ->
    (match arg.it with
    | ExpA exp ->
      Option.bind (bind_pattern env field collector scope exp)
        (fun scope -> bind_arg_patterns env field collector scope rest)
    | TypA typ when safe_typ env field scope.carriers typ ->
      bind_arg_patterns env field collector scope rest
    | DefA _ -> bind_arg_patterns env field collector scope rest
    | GramA sym when safe_sym env field scope.carriers sym ->
      bind_arg_patterns env field collector scope rest
    | TypA _ | GramA _ -> None)

let check_ambiguous_equality env field collector scope left right =
  let captures =
    names (captured_exp collector left @ captured_exp collector right)
  in
  if
    Names.is_empty captures
    && safe_pattern env field scope.carriers ~whole:true left
    && safe_pattern env field scope.carriers ~whole:true right
  then
    Some scope
  else
    None

let check_if env field collector scope (condition : exp) =
  match condition.it with
  | CmpE (`EqOp, _, left, right) ->
    if is_unbound_var scope left && safe_exp env field scope.carriers right then
      bind_pattern env field collector scope left
    else if is_unbound_var scope right && safe_exp env field scope.carriers left then
      bind_pattern env field collector scope right
    else
    (match has_unbound scope left, has_unbound scope right with
    | false, false ->
      if
        safe_exp env field scope.carriers left
        && safe_exp env field scope.carriers right
      then Some scope else None
    | false, true ->
      if safe_exp env field scope.carriers left then
        bind_pattern env field collector scope right
      else
        None
    | true, false ->
      if safe_exp env field scope.carriers right then
        bind_pattern env field collector scope left
      else
        None
    | true, true ->
      check_ambiguous_equality env field collector scope left right)
  | _ ->
    if safe_exp env field scope.carriers condition then Some scope else None

let rec check_prem env field collector scope (prem : prem) =
  match prem.it with
  | RulePr (_, args, _, head) ->
    if List.for_all (safe_arg env field scope.carriers) args then
      bind_pattern env field collector scope head
    else
      None
  | IfPr condition -> check_if env field collector scope condition
  | LetPr (params, left, right) ->
    if
      List.for_all (safe_param env field scope.carriers) params
      && safe_exp env field scope.carriers right
    then
      Option.map (fun scope -> add_params scope params)
        (bind_pattern env field collector scope left)
    else
      None
  | ElsePr -> Some scope
  | IterPr (prem, iterexp) ->
    if
      (not (iter_has_outward_source scope iterexp)
       || not (prem_uses_carrier collector scope prem))
      && safe_iterexp env field scope.carriers iterexp
    then
      let nested = add_iter_binders scope iterexp in
      Option.map (fun _ -> scope) (check_prem env field collector nested prem)
    else
      None
  | NegPr prem ->
    Option.map (fun _ -> scope) (check_prem env field collector scope prem)

let rec check_prems env field collector scope = function
  | [] -> Some scope
  | prem :: rest ->
    Option.bind (check_prem env field collector scope prem)
      (fun scope -> check_prems env field collector scope rest)

let safe_deftyp env field collector scope (deftyp : deftyp) =
  let check_case (_, (typ, params, prems), _) =
    if
      safe_typ env field scope.carriers typ
      && List.for_all (safe_param env field scope.carriers) params
    then
      let bound =
        Names.union scope.bound (bound_typ_vars typ)
      in
      Option.is_some
        (check_prems env field collector { scope with bound } prems)
    else
      false
  in
  match deftyp.it with
  | AliasT typ -> safe_typ env field scope.carriers typ
  | StructT fields -> List.for_all check_case fields
  | VariantT cases -> List.for_all check_case cases

let safe_rule env field collector outer (rule : rule) =
  let RuleD (_, params, _, head, prems) = rule.it in
  List.for_all (safe_param env field outer.carriers) params
  &&
  match bind_pattern env field collector outer head with
  | None -> false
  | Some scope -> Option.is_some (check_prems env field collector scope prems)

let safe_clause env field collector outer (clause : clause) =
  let DefD (params, args, body, prems) = clause.it in
  List.for_all (safe_param env field outer.carriers) params
  &&
  match bind_arg_patterns env field collector outer args with
  | None -> false
  | Some scope ->
    (match check_prems env field collector scope prems with
    | None -> false
    | Some scope -> safe_exp env field scope.carriers body)

let safe_inst env field collector outer (inst : inst) =
  let InstD (params, args, deftyp) = inst.it in
  List.for_all (safe_param env field outer.carriers) params
  &&
  match bind_arg_patterns env field collector outer args with
  | None -> false
  | Some scope -> safe_deftyp env field collector scope deftyp

let safe_prod env field collector outer (prod : prod) =
  let ProdD (params, sym, body, prems) = prod.it in
  List.for_all (safe_param env field outer.carriers) params
  && safe_sym env field outer.carriers sym
  && captured_sym collector sym = []
  &&
  let scope = { outer with bound = Names.union outer.bound (sym_vars sym) } in
  match check_prems env field collector scope prems with
  | None -> false
  | Some scope -> safe_exp env field scope.carriers body

let def_preserves_representation env field (def : def) =
  let collector = capture_collector env field in
  let empty = { bound = Names.empty; carriers = Names.empty } in
  match def.it with
  | TypD (_, params, insts) ->
    List.for_all (safe_param env field empty.carriers) params
    &&
    let outer = add_params empty params in
    List.for_all (safe_inst env field collector outer) insts
  | RelD (_, params, _, typ, rules) ->
    List.for_all (safe_param env field empty.carriers) params
    && safe_typ env field empty.carriers typ
    &&
    let outer = add_params empty params in
    List.for_all (safe_rule env field collector outer) rules
  | DecD (_, params, typ, clauses) ->
    List.for_all (safe_param env field empty.carriers) params
    && safe_typ env field empty.carriers typ
    &&
    let outer = add_params empty params in
    List.for_all (safe_clause env field collector outer) clauses
  | GramD (_, params, typ, prods) ->
    List.for_all (safe_param env field empty.carriers) params
    && safe_typ env field empty.carriers typ
    &&
    let outer = add_params empty params in
    List.for_all (safe_prod env field collector outer) prods
  | RecD _ | HintD _ -> true

let field_is_closed env entries field =
  List.for_all (fun (entry : Source_index.entry) ->
    def_preserves_representation env field entry.def)
    entries

let analyze env source_index =
  let entries = Source_index.entries source_index in
  let fields =
    entries
    |> List.concat_map (fun (entry : Source_index.entry) ->
         def_fields env entry.def)
    |> List.fold_left (fun fields field ->
         if List.exists (same_field field) fields then fields else field :: fields)
         []
    |> List.rev
    |> List.filter (field_is_closed env entries)
  in
  { env; fields }

let field_representation t ~owner_id atom =
  if List.exists
       (fun field -> String.equal field.owner_id owner_id && Xl.Atom.eq field.atom atom)
       t.fields
  then Sequence_representation.Canonical_runs
  else Sequence_representation.Ordinary

let rec path_representation t (path : path) =
  match path.it with
  | DotP (owner, atom) ->
    (match owner_id t.env owner.note with
    | Some owner_id -> field_representation t ~owner_id atom
    | None -> Sequence_representation.Ordinary)
  | SliceP (parent, _, _) | IdxP (parent, _) -> path_representation t parent
  | RootP -> Sequence_representation.Ordinary
