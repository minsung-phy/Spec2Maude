open Il.Ast
open Maude_ir
open Util.Source

type binding =
  { term : term
  ; sort : sort
  ; typ : typ
  }

type env =
  { vars : (string * binding) list
  ; condition_bound_vars : string list option
  }

type result =
  { term : term option
  ; guards : eq_condition list
  ; diagnostics : Diagnostics.t list
  }

type pattern_result =
  { pattern_term : term option
  ; pattern_guards : eq_condition list
  ; introduced_bindings : (string * binding) list
  ; pattern_diagnostics : Diagnostics.t list
  }

type witness_result =
  { witness_term : term option
  ; witness_guards : eq_condition list
  ; witness_diagnostics : Diagnostics.t list
  }

type zip_source_lowering =
  { zip_id : id
  ; zip_source_exp : exp
  ; zip_element_typ : typ
  ; zip_element_sort : sort
  ; zip_source_item_shape : Helper.iter_map_source_item_shape
  ; zip_source_listn_count : exp option
  ; zip_head_var : string
  ; zip_tail_var : string
  ; zip_source_shape : Helper.iter_zip_source_shape
  }

let empty_env = { vars = []; condition_bound_vars = None }

let empty_result = { term = None; guards = []; diagnostics = [] }

let s = sort
let spectec_terminal = s "SpectecTerminal"
let spectec_terminals = s "SpectecTerminals"

let app name args = App (name, args)

let source_echo_exp exp =
  Il.Print.string_of_exp exp

let unsupported ?suggestion ~ctx ~origin ~constructor ~reason ?source_echo () =
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin
    ~constructor
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason
    ?suggestion
    ?source_echo
    ()

let prelude_gap ?suggestion ~ctx ~origin ~constructor ~reason ?source_echo () =
  Diagnostics.make
    ~category:Diagnostics.PreludeGap
    ~origin
    ~constructor
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason
    ?suggestion
    ?source_echo
    ()

let with_term term : result = { term = Some term; guards = []; diagnostics = [] }
let with_diagnostics diagnostics = { empty_result with diagnostics }

let append_result_metadata (results : result list) =
  let guards = List.concat (List.map (fun (result : result) -> result.guards) results) in
  let diagnostics =
    List.concat (List.map (fun (result : result) -> result.diagnostics) results)
  in
  guards, diagnostics

let add_var env id binding =
  { env with vars = (id, binding) :: env.vars }

let find_var env id =
  List.assoc_opt id env.vars

let env_bound_vars env =
  env.vars
  |> List.map (fun (_id, (binding : binding)) ->
    Condition_closure.term_vars binding.term)
  |> List.concat
  |> List.sort_uniq String.compare

let with_condition_bound_vars env vars =
  { env with condition_bound_vars = Some (vars |> List.sort_uniq String.compare) }

let maude_op_of_source op =
  "_" ^ op ^ "_"

let maude_unop_of_source op =
  op ^ "_"

let maude_cmp_op op =
  match op with
  | `EqOp -> "_==_"
  | `NeOp -> "_=/=_"
  | _ -> maude_op_of_source (Il.Print.string_of_cmpop op)

let len term =
  app "len" [ term ]

let is_opt term =
  app "isOpt" [ term ]

let all_opt term =
  app "allOpt" [ term ]

let contains term sequence =
  app "contains" [ term; sequence ]

let is_true term =
  app "isTrue" [ term ]

let qid_of_atom atom =
  Qid (Xl.Atom.to_string atom)

let typ_is_iter = Type_shape.typ_is_iter

let numeric_conversion_preserves_runtime_representation source_typ target_typ =
  match source_typ, target_typ with
  | `NatT, `NatT | `IntT, `IntT | `NatT, `IntT -> true
  | `IntT, `NatT | `NatT, (`RatT | `RealT) | `IntT, (`RatT | `RealT)
  | (`RatT | `RealT), _ ->
    false

let numeric_sort_coercion_preserves_runtime_representation source_sort target_sort =
  match sort_name source_sort, sort_name target_sort with
  | source, target when source = target -> true
  | "Nat", "Int" -> true
  | _ -> false

let raw_numeric_sort_of_numtyp = function
  | `NatT -> Some (s "Nat")
  | `IntT -> Some (s "Int")
  | `RatT -> Some (s "Rat")
  | `RealT -> None

let is_raw_numeric_sort sort =
  match sort_name sort with
  | "Nat" | "Int" | "Rat" -> true
  | _ -> false

let is_nat_int_sort sort =
  match sort_name sort with
  | "Nat" | "Int" -> true
  | _ -> false

let is_flat_list_typ = Type_shape.is_flat_list_typ

let is_flat_optional_typ = Type_shape.is_flat_optional_typ

let is_nested_list_typ = Type_shape.is_nested_list_typ

let is_optional_list_typ = Type_shape.is_optional_list_typ

let is_list_optional_typ = Type_shape.is_list_optional_typ

let carrier_sort_of_typ = function
  | { it = BoolT | NumT `RatT | NumT `RealT | TextT | VarT _; _ } -> Some spectec_terminal
  | { it = NumT `NatT; _ } -> Some (s "Nat")
  | { it = NumT `IntT; _ } -> Some (s "Int")
  | typ
    when is_flat_list_typ typ || is_flat_optional_typ typ || is_nested_list_typ typ
         || is_optional_list_typ typ || is_list_optional_typ typ ->
    Some spectec_terminals
  | { it = TupT _; _ } -> Some spectec_terminal
  | { it = IterT _; _ } -> None

let primitive_numeric_alias_sort ctx typ =
  let rec resolve visited typ =
    match typ.it with
    | NumT `NatT -> Some (s "Nat")
    | NumT `IntT -> Some (s "Int")
    | VarT (id, []) when not (List.mem id.it visited) ->
      let entries = Analysis.Source_index.find_by_id (Context.source_index ctx) id.it in
      entries
      |> List.find_map (fun entry ->
        match entry.Analysis.Source_index.def.it with
        | TypD (_, [], [ inst ]) ->
          (match inst.it with
          | InstD ([], [], { it = AliasT alias_typ; _ }) ->
            resolve (id.it :: visited) alias_typ
          | _ -> None)
        | _ -> None)
    | _ -> None
  in
  resolve [] typ

let raw_numeric_sort_of_typ ctx typ =
  match primitive_numeric_alias_sort ctx typ with
  | Some sort -> Some sort
  | None ->
    (match typ.it with
    | NumT typ -> raw_numeric_sort_of_numtyp typ
    | _ -> None)

let typ_is_nat ctx typ =
  match carrier_sort_of_typ typ with
  | Some sort when sort_name sort = "Nat" -> true
  | _ ->
    (match primitive_numeric_alias_sort ctx typ with
    | Some sort when sort_name sort = "Nat" -> true
    | _ -> false)

let type_ref_of_sort sort =
  sort_ref sort

let numeric_literal_diagnostic ctx origin exp =
  unsupported
    ~ctx ~origin ~constructor:"Expr/NumE"
    ~source_echo:(source_echo_exp exp)
    ~reason:
      "numeric literal is only lowered directly when the IL expected type is Nat or Int"
    ~suggestion:"Add wrapper/primitive strategy for Rat/Real literals before lowering this expression"
    ()

let maude_numeric_literal num =
  match Xl.Num.to_string num with
  | text when String.length text > 0 && text.[0] = '+' ->
    String.sub text 1 (String.length text - 1)
  | text -> text

let literal_num_value ctx origin exp n =
  match Xl.Num.to_typ n with
  | `NatT | `IntT -> with_term (Const (maude_numeric_literal n))
  | `RatT | `RealT -> with_diagnostics [ numeric_literal_diagnostic ctx origin exp ]

let text_literal text =
  app "text" [ Const ("\"" ^ String.escaped text ^ "\"") ]

let bool_wrapper term =
  app "bool" [ term ]

let record_value atom record =
  app "value" [ qid_of_atom atom; record ]

let record_item atom value =
  app "item" [ qid_of_atom atom; value ]

let record_literal items =
  app "{_}" [ items ]

let record_items = function
  | [] -> Const "EMPTY"
  | hd :: tl -> List.fold_left (fun acc item -> app "_;_" [ acc; item ]) hd tl

let typecheck value typ = app "typecheck" [ value; typ ]
let typecheck_seq value typ = app "typecheckSeq" [ value; typ ]
let typecheck_opt_seq value typ = app "typecheckOptSeq" [ value; typ ]
let typecheck_seq_opt value typ = app "typecheckSeqOpt" [ value; typ ]
let typecheck_nested_seq value typ = app "typecheckNestedSeq" [ value; typ ]
let typecheck_for_sort sort value typ =
  if sort_name sort = sort_name spectec_terminals then
    typecheck_seq value typ
  else
    typecheck value typ

let typecheck_conditions_for_typ typ sort value witness =
  match typ.it with
  | IterT (inner, Opt) when not (Type_shape.typ_is_iter inner) ->
    [ BoolCond (app "isOpt" [ value ])
    ; BoolCond (typecheck_seq value witness)
    ]
  | IterT ({ it = IterT (inner, Opt); _ }, List)
    when not (Type_shape.typ_is_iter inner) ->
    [ BoolCond (typecheck_opt_seq value witness) ]
  | IterT ({ it = IterT (inner, List); _ }, Opt)
    when not (Type_shape.typ_is_iter inner) ->
    [ BoolCond (typecheck_seq_opt value witness) ]
  | IterT ({ it = IterT (inner, List); _ }, List)
    when not (Type_shape.typ_is_iter inner) ->
    [ BoolCond (typecheck_nested_seq value witness) ]
  | _ -> [ BoolCond (typecheck_for_sort sort value witness) ]

let typ_components = Type_shape.typ_components

type typcase_constructor_lookup =
  | Constructor_found of string
  | Constructor_missing
  | Constructor_blocked of string
  | Constructor_ambiguous of string list

type typcase_constructor_resolution =
  { resolved_constructor : string
  ; resolved_typ : typ
  ; projection_ops : string list
  }

let describe_static_key = function
  | None -> "<generic>"
  | Some key -> key

let describe_registry_entry entry =
  Printf.sprintf
    "%s category=%s key=%s mixop=%s arity=%d status=%s"
    entry.Constructor_registry.constructor_op
    entry.source_category
    (describe_static_key entry.static_args_key)
    (Il.Print.string_of_mixop entry.mixop)
    entry.arity
    (Constructor_registry.status_to_string entry.status)

let constructor_lookup_miss_detail ctx ~source_category ~static_args_key ~mixop ~arity =
  let entries = Constructor_registry.entries (Context.constructors ctx) in
  let same_category =
    entries
    |> List.filter (fun entry ->
      entry.Constructor_registry.source_category = source_category)
  in
  let same_category_arity =
    same_category
    |> List.filter (fun entry -> entry.Constructor_registry.arity = arity)
  in
  let same_category_mixop =
    same_category
    |> List.filter (fun entry ->
      entry.Constructor_registry.arity = arity
      && Il.Eq.eq_mixop entry.mixop mixop)
  in
  let sample entries =
    entries
    |> List.map describe_registry_entry
    |> List.sort_uniq String.compare
    |> fun entries ->
      match entries with
      | [] -> ""
      | _ ->
        entries
        |> List.filteri (fun index _ -> index < 5)
        |> String.concat "; "
  in
  if same_category = [] then
    Printf.sprintf
      "no TypD constructor entries are registered for category %s"
      source_category
  else if same_category_arity = [] then
    Printf.sprintf
      "category %s has registered constructors, but none with arity %d; requested mixop %s and key %s"
      source_category
      arity
      (Il.Print.string_of_mixop mixop)
      (describe_static_key static_args_key)
  else if same_category_mixop = [] then
    Printf.sprintf
      "category %s has arity-%d constructors, but none with requested mixop %s and key %s; candidates: %s"
      source_category
      arity
      (Il.Print.string_of_mixop mixop)
      (describe_static_key static_args_key)
      (sample same_category_arity)
  else
    Printf.sprintf
      "category %s has matching mixop/arity entries, but not as an emitted constructor visible at key %s; candidates: %s"
      source_category
      (describe_static_key static_args_key)
      (sample same_category_mixop)

let emitted_typcase_constructor_resolution_lookup ctx typ mixop arity =
  let key_env = Static_key.of_static_typ_env (Context.static_typ_env ctx) in
  match Static_key.typ_ref ~env:key_env typ with
  | Some { Static_key.category_id; static_args_key } ->
    let source_category = Naming.source_slug category_id in
    (match
        Constructor_registry.lookup_emitted
          (Context.constructors ctx)
          ~source_category
          ~static_args_key
          ~mixop
          ~arity
      with
      | Constructor_registry.Found entry ->
        `Found
          { resolved_constructor = entry.Constructor_registry.constructor_op
          ; resolved_typ = typ
          ; projection_ops = entry.Constructor_registry.projection_ops
          }
      | Constructor_registry.Ambiguous entries ->
        `Ambiguous
          (entries
           |> List.map (fun entry ->
             { resolved_constructor = entry.Constructor_registry.constructor_op
             ; resolved_typ = typ
             ; projection_ops = entry.Constructor_registry.projection_ops
             }))
      | Constructor_registry.Missing ->
        (match
             Constructor_registry.lookup_visible
               (Context.constructors ctx)
               ~source_category
             ~static_args_key
             ~mixop
             ~arity
         with
        | Constructor_registry.Found entry ->
          `Blocked
            (Printf.sprintf
               "matching TypD constructor exists but is registered as %s at %s"
               (Constructor_registry.status_to_string entry.Constructor_registry.status)
               (Origin.summary entry.Constructor_registry.origin))
        | Constructor_registry.Ambiguous entries ->
          `Blocked
            (Printf.sprintf
               "matching TypD constructor shape is non-emitted or ambiguous: %s"
               (entries
                |> List.map (fun entry ->
                  Printf.sprintf
                    "%s[%s]@%s"
                    entry.Constructor_registry.constructor_op
                    (Constructor_registry.status_to_string entry.Constructor_registry.status)
                    (Origin.summary entry.Constructor_registry.origin))
               |> String.concat ", "))
        | Constructor_registry.Missing ->
          `Blocked
            (constructor_lookup_miss_detail
               ctx
               ~source_category
               ~static_args_key
               ~mixop
               ~arity)))
  | None -> `Missing

let emitted_typcase_constructor_lookup ctx typ mixop arity =
  match emitted_typcase_constructor_resolution_lookup ctx typ mixop arity with
  | `Found resolution -> Constructor_found resolution.resolved_constructor
  | `Missing -> Constructor_missing
  | `Blocked reason -> Constructor_blocked reason
  | `Ambiguous resolutions ->
    Constructor_ambiguous
      (resolutions |> List.map (fun resolution -> resolution.resolved_constructor))

let unsupported_witness ctx origin constructor source reason =
  unsupported
    ~ctx ~origin ~constructor
    ~source_echo:source
    ~reason
    ~suggestion:"Keep this coercion Unsupported until its type witness can be lowered source-safely"
    ()

let unsupported_exp ctx origin constructor exp reason =
  with_diagnostics
    [ unsupported
        ~ctx ~origin ~constructor
        ~source_echo:(source_echo_exp exp)
        ~reason
        ~suggestion:"Keep this expression as Unsupported until the generic lowering rule is implemented"
        ()
    ]

let is_sequence_sort sort =
  sort_name sort = sort_name spectec_terminals

let is_nat_sort sort =
  sort_name sort = "Nat"

let sequence_sort_diagnostic ctx origin exp =
  unsupported
    ~ctx ~origin ~constructor:"Expr/Sequence"
    ~source_echo:(source_echo_exp exp)
    ~reason:
      "expression is not known to have SpectecTerminals carrier, so sequence concatenation would be a guess"
    ~suggestion:"Track a sequence carrier for this expression before lowering it as SpectecTerminals"
    ()

let term_vars term =
  let rec loop acc = function
    | Var name -> name :: acc
    | Const _ | Qid _ -> acc
    | App (_, args) -> List.fold_left loop acc args
  in
  loop [] term |> List.sort_uniq String.compare

let source_free_var_ids exp =
  Il.Free.(free_exp exp).varid
  |> Il.Free.Set.to_seq
  |> List.of_seq
  |> List.sort_uniq String.compare

let type_note_free_var_ids typ =
  Il.Free.(free_typ typ).varid
  |> Il.Free.Set.to_seq
  |> List.of_seq
  |> List.sort_uniq String.compare

let rec expression_note_free_var_ids exp =
  let child_ids =
    match exp.it with
    | VarE _ | BoolE _ | NumE _ | TextE _ -> []
    | UnE (_, _, inner)
    | LiftE inner
    | LenE inner
    | ProjE (inner, _)
    | TheE inner
    | DotE (inner, _)
    | CaseE (_, inner)
    | UncaseE (inner, _)
    | CvtE (inner, _, _) ->
      expression_note_free_var_ids inner
    | BinE (_, _, left, right)
    | CmpE (_, _, left, right)
    | IdxE (left, right)
    | CompE (left, right)
    | MemE (left, right)
    | CatE (left, right) ->
      expression_note_free_var_ids left @ expression_note_free_var_ids right
    | SliceE (base, first, last) | IfE (base, first, last) ->
      expression_note_free_var_ids base
      @ expression_note_free_var_ids first
      @ expression_note_free_var_ids last
    | OptE None -> []
    | OptE (Some inner) -> expression_note_free_var_ids inner
    | TupE fields | ListE fields ->
      fields |> List.concat_map expression_note_free_var_ids
    | UpdE (base, path, value) | ExtE (base, path, value) ->
      expression_note_free_var_ids base
      @ path_note_free_var_ids path
      @ expression_note_free_var_ids value
    | StrE fields ->
      fields
      |> List.concat_map (fun (_atom, field) ->
        expression_note_free_var_ids field)
    | CallE (_id, args) ->
      args |> List.concat_map arg_note_free_var_ids
    | IterE (body, (_iter, sources)) ->
      expression_note_free_var_ids body
      @ (sources
         |> List.concat_map (fun (_id, source) ->
           expression_note_free_var_ids source))
    | SubE (inner, from_typ, to_typ) ->
      expression_note_free_var_ids inner
      @ type_note_free_var_ids from_typ
      @ type_note_free_var_ids to_typ
  in
  type_note_free_var_ids exp.note @ child_ids
  |> List.sort_uniq String.compare

and path_note_free_var_ids path =
  let child_ids =
    match path.it with
    | RootP -> []
    | IdxP (inner, index) ->
      path_note_free_var_ids inner @ expression_note_free_var_ids index
    | SliceP (inner, first, last) ->
      path_note_free_var_ids inner
      @ expression_note_free_var_ids first
      @ expression_note_free_var_ids last
    | DotP (inner, _) -> path_note_free_var_ids inner
  in
  type_note_free_var_ids path.note @ child_ids
  |> List.sort_uniq String.compare

and arg_note_free_var_ids arg =
  match arg.it with
  | ExpA exp -> expression_note_free_var_ids exp
  | TypA typ -> type_note_free_var_ids typ
  | DefA _ | GramA _ -> []

let source_and_note_free_var_ids exp =
  source_free_var_ids exp @ expression_note_free_var_ids exp
  |> List.sort_uniq String.compare

let unique_source_ids ids =
  ids |> List.sort_uniq String.compare

let vars_within allowed vars =
  vars
  |> List.for_all (fun var -> List.exists (( = ) var) allowed)

let short_source_stem source =
  let words =
    Naming.maude_var ~fallback:"BODY" source
    |> String.split_on_char '_'
    |> List.filter (fun word -> word <> "")
  in
  let rec take count length acc = function
    | [] -> List.rev acc
    | word :: words ->
      if count >= 3 then
        List.rev acc
      else
      let next_length = length + String.length word + if acc = [] then 0 else 1 in
      if next_length > 24 && acc <> [] then
        List.rev acc
      else
        take (count + 1) next_length (word :: acc) words
  in
  match take 0 0 [] words with
  | [] -> "BODY"
  | words -> String.concat "_" words

let helper_local_stem origin exp =
  Naming.helper_local_var_stem origin ^ "_" ^ short_source_stem (source_echo_exp exp)

let helper_local_prefix origin exp =
  "CAP" ^ helper_local_stem origin exp ^ "X"
