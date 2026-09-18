open Util.Source
open Il.Ast
open Maude_il


type definition_parameter =
  { id : id
  ; params : param list
  ; result : typ
  }

type capture =
  | VariableCapture of id * typ
  | DefinitionCapture of definition_parameter
  | TypeCapture of id

type iteration_owner =
  | RelationOwner of string
  | DefinitionOwner of string
  | OtherOwner

type iteration_body =
  | ExpBody of exp
  | PremiseBody of prem

type iteration =
  { name : string
  ; tail_name : string
  ; projector_name : string
  ; projector_tail_name : string
  ; mutable forward_requested : bool
  ; mutable projector_requested : bool
  ; owner : iteration_owner
  ; body : exp
  ; iterexp : iterexp
  ; captures : capture list
  }

type premise_iteration =
  { name : string
  ; tail_name : string
  ; output_names : (name * name) list
  ; mutable check_requested : bool
  ; owner : iteration_owner
  ; premise : prem
  ; body : prem
  ; iterexp : iterexp
  ; captures : capture list
  }

type definition_application =
  { target : id
  ; params : param list
  ; result : typ
  }

type inverse_contract =
  { inverse_target : id
  ; missing : int
  }

type inverse =
  | ValidInverse of inverse_contract
  | InvalidInverse of string

type relation_policy =
  | Execution of
      { request_sort : sort
      ; input_count : int
      }
  | Equation of {input_count : int}
  | Predicate
  | BackendCheck
  | BackendCompute of {input_count : int}

type membership_choice =
  { definition : string
  ; clause : clause
  ; helper_name : name
  ; prefix : prem list
  ; element : exp
  ; collection : exp
  }

type name_kind = TypName | RelName | DefName | MixopName

type t =
  { type_env : Il.Env.t
  ; sort_metadata : Hintd.t
  ; contexts : Hintd.context list
  ; iterations : iteration list
  ; premise_iterations : premise_iteration list
  ; hints : hintdef list
  ; names : (name_kind * string * name) list
  ; relation_policies : (string * relation_policy) list
  ; relation_enabled_helpers : ((string * int) * name) list
  ; unsupported_relations : (string * string) list
  ; definition_bodies : (string * bool) list
  ; rewrite_sorts : (string * sort) list
  ; membership_choices : membership_choice list
  ; type_definitions : (string * inst list) list
  ; variables : ((string * sort) * name) list
  ; anonymous_variables : (id * sort * name) list
  ; definition_parameters : definition_parameter list
  ; type_parameters : id list
  ; definition_arguments : (arg * definition_parameter) list
  ; definition_calls : (exp * definition_parameter) list
  ; definition_values : definition_application list
  ; definition_applications : definition_application list
  ; inverses : (string * inverse) list
  }


module StringSet = Set.Make (String)

let sanitize name =
  name
  |> String.to_seq
  |> Seq.map (function
       | ('a'..'z' | 'A'..'Z' | '0'..'9' | '-') as char -> char
       | _ -> '-')
  |> String.of_seq

let builtin_name name =
  name
  |> sanitize
  |> String.lowercase_ascii

let sort_of_typ index typ =
  Hintd.sort_of_typ index.sort_metadata typ

let sequence_representation index typ =
  Hintd.sequence_representation index.sort_metadata typ

(* Record composition uses the equation emitted for its monomorphic TypD. *)
let record_composition_available index typ =
  match (Il.Eval.reduce_typ index.type_env typ).it with
  | VarT (id, []) ->
      begin match Il.Env.find_typ index.type_env id with
      | [], [{it = InstD ([], [], {it = StructT _; _}); _}] -> true
      | _ -> false
      end
  | _ -> false

let rec parameter_sort metadata param =
  match param.it with
  | ExpP (_, typ) -> Hintd.sort_of_typ metadata typ
  | TypP _ -> "SpectecType"
  | DefP (_, params, result) ->
      let sort, _, _ =
        definition_signature_with metadata params result
      in
      sort
  | GramP _ -> invalid_arg "GramP is not supported"

and definition_signature_with metadata params result =
  let domain = List.map (parameter_sort metadata) params in
  let codomain = Hintd.sort_of_typ metadata result in
  let args =
    match domain with [] -> "Unit" | _ -> String.concat "-" domain
  in
  "SpectecDef-" ^ args ^ "-to-" ^ codomain, domain, codomain

let definition_signature index params result =
  definition_signature_with index.sort_metadata params result

let reserved_names =
  StringSet.of_list
    [ "true"; "false"; "none"; "min"; "max"; "s"; "sd"
    (* Native Float operations retain their hooks under import renaming. *)
    ; "nativeFloatNeg"; "nativeFloatAdd"; "nativeFloatSub"
    ; "nativeFloatMul"; "nativeFloatDiv"; "nativeFloatPow"
    ; "nativeToFloat"; "nativeToRat"; "nativeParseFloat"; "nativeParseRat"
    ; "nativeFloatString"; "nativeRatString"; "decFloat"
    ; "integerXor"; "floatRem"; "floatAbs"; "floatFloor"
    ; "floatCeiling"; "floatMin"; "floatMax"; "floatLess"
    ; "floatLessEqual"; "floatGreater"; "floatGreaterEqual"
    ; "sqrt"; "exp"; "log"; "sin"; "cos"; "tan"
    ; "asin"; "acos"; "atan"; "pi"; "_xor_"
    ; "eps"; "bool"; "rat"; "float"; "text"; "seq"; "unseq"
    ; "tuple"; "item"; "value"; "typecheck"; "len"
    ; "index"; "slice"; "lift"; "repeatSeq"
    ; "_+_"; "_-_"; "_*_"; "_/_"; "_^_"; "_<_"; "_>_"
    ; "_<=_"; "_>=_"; "_==_"; "_=/=_"; "not_"; "_and_"
    ; "_or_"; "_implies_"; "_rem_"
    (* Native numeric operators whose domains overlap unwrapped Nat/Int. *)
    ; "abs"; "ceiling"; "floor"; "gcd"; "lcm"; "modExp"
    (* Native string operators now share the source value kind. *)
    ; "stringConcat"; "stringLess"; "stringLessEqual"
    ; "stringGreater"; "stringGreaterEqual"; "nativeChar"
    ; "ascii"; "length"; "substr"; "find"; "rfind"
    ; "upperCase"; "lowerCase"; "notFound"
    (* spectec-support/pretype.maude *)
    ; "nat"; "int"; "real"
    ; "iterOpt"; "iterList"; "iterList1"
    ; "iterListN"
    (* spectec-support/sequence.maude *)
    ; "indexDefined"; "setAt"
    ; "splice"; "lenAux"
    (* spectec-support/record.maude *)
    ; "EMPTY"; "recordConcat"; "optionConcat"
    ; "setItem"; "hasField"
    (* builtins.maude *)
    ; "ibits-aux"; "inv-ibits-aux"; "ibytes-aux"
    ; "inv-ibytes-aux"; "sign-extend-nat"; "ipopcnt-bits"; "ipopcnt-bits-aux"
    ; "irev-bits"; "irev-bits-aux"; "shift-count"
    ; "signed-nat"; "floor-div-pow2-int"; "sat-s-int"
    ; "wrap-s-int"; "fnmag-valid"
    ; "scale-rat"; "fmag-rat"; "float-rat"
    ; "float-finite"; "trunc-rat-int"; "nearest-rat-int"
    ; "floor-log2"
    ; "floor-log2-rat"; "nat-fmag-exact"; "nat-to-fmag"
    ; "round-nat-significand"; "rounded-nat-to-fmag"; "round-rat-subnormal"
    ; "round-rat-normal"; "round-rat-to-fmag"; "floor-half-int"
    ; "floor-sqrt-rat-range"; "nearest-sqrt-rat-int"; "sqrt-rat-subnormal"
    ; "sqrt-rat-normal"; "sqrt-rat-to-fmag"; "sqrt-fmag"
    ; "int-to-float-like"; "int-to-iN"; "saturate-u-int"
    ; "saturate-s-int"; "bit-not"; "bit-and"
    ; "bit-or"; "bit-xor"; "float-nan-bit"
    ; "float-sign-bit"; "float-eq-bit"; "float-lt-bit"
    ; "float-default-nan"; "float-canonical-nan"; "float-binary-nan"
    ; "float-neg"; "rat-to-float-nearest"; "rat-to-float-nearest-signed-zero"
    ; "float-signed-zero"; "float-signed-inf"; "float-add-result"
    ; "float-min-equal"; "float-max-equal"; "float-min"
    ; "float-max"; "float-pmin"; "float-pmax"
    ; "promote-f32-normal-frac"; "promote-f32-subnorm-frac"; "promote-f32-subnorm-exp"
    ; "promote-f32"
    ; "demote-f64"
    ; "float-bias"; "float-max-exp-field"; "float-exp-field"
    ; "float-frac-field"; "float-sign-field"; "float-mag-from-bits"
    ; "float-from-bits"; "float-mag-to-bits"; "float-to-bits"
    ; "nbytes-int"; "nbytes-float"; "inv-nbytes-int"
    ; "inv-nbytes-float"; "zbytes-pack"; "inv-zbytes-pack"
    ; "lane-width"; "vec-raw"; "lane-from-bits"
    ; "lane-to-bits"; "lanes-aux"; "inv-lanes-aux"
    ; "pair-chunks"; "fixed-chunks"
    (* relation-backends.maude *)
    ; "backend-reftype-sub"; "backend-heaptype-sub"; "backend-valid-heaptype"
    ; "backend-close-super"; "backend-deftype-step"; "ref-ok-actual-type"
    ; "externaddr-ok-actual-type"; "backend-externtype-sub"; "backend-tagtype-sub"
    ; "backend-globaltype-sub"; "backend-memtype-sub"; "backend-tabletype-sub"
    ; "backend-valtype-sub"; "backend-limits-sub"; "module-ok-import-types"
    ; "module-ok-tag-types"; "module-ok-global-types"; "module-ok-mem-types"
    ; "module-ok-table-types"; "module-ok-func-types"; "module-ok-export-types"
    ]

let fresh used suffix candidate =
  let rec choose index =
    let name =
      if index = 1 then candidate
      else candidate ^ suffix index
    in
    if StringSet.mem name !used then choose (index + 1)
    else name
  in
  let name = choose 1 in
  used := StringSet.add name !used;
  name

let fresh_name used candidate =
  let candidate =
    if StringSet.mem candidate reserved_names
       || StringSet.mem candidate !used
    then "spectec-" ^ candidate
    else candidate
  in
  fresh used (fun index -> "-" ^ string_of_int index) candidate

let fresh_variable_name used candidate =
  fresh used string_of_int candidate

let variable_base name =
  let name = sanitize name |> String.uppercase_ascii in
  let name = if name = "" then "VAR" else name in
  match name.[0] with
  | 'A'..'Z' -> name
  | _ -> "V-" ^ name

let iteration_base_name (body : exp) =
  let compact name =
    name
    |> sanitize
    |> String.split_on_char '-'
    |> List.filter (fun part -> part <> "")
    |> String.concat "-"
  in
  match body.it with
  | CallE (id, _) ->
      begin match compact id.it with
      | "" -> "map-exp"
      | name -> "map-" ^ name
      end
  | _ -> "map-exp"


let index_ids = function
  | ListN (_, Some id) -> [id]
  | Opt | List | List1 | ListN (_, None) -> []

let bound_ids (iter, generators) =
  index_ids iter @ List.map fst generators

let rec remove_id name = function
  | [] -> []
  | id :: ids when id = name -> ids
  | id :: ids -> id :: remove_id name ids

(* Expression notes may retain ListN, which Il.Iter.typ excludes from
 * declaration types. Visit their actual shape without rewriting the AST. *)
let rec visit_noted_type visit visit_exp typ =
  visit typ;
  match typ.it with
  | VarT (_, args) ->
      List.iter
        (fun arg ->
          match arg.it with
          | TypA typ -> visit_noted_type visit visit_exp typ
          | ExpA exp -> visit_exp exp
          | DefA _ | GramA _ -> ())
        args
  | TupT fields ->
      List.iter (fun (_, typ) -> visit_noted_type visit visit_exp typ) fields
  | IterT (typ, iter) ->
      visit_noted_type visit visit_exp typ;
      (match iter with ListN (count, _) -> visit_exp count | _ -> ())
  | BoolT | NumT _ | TextT -> ()

let capture_variables definition_calls definition_arguments type_parameters free body iterexp =
  let free = ref free in
  let bound = ref (List.map (fun id -> id.it) (bound_ids iterexp)) in
  let captures = ref [] in
  let add_variable id typ =
    if Il.Free.Set.mem id.it (!free).Il.Free.varid
       && not (List.mem id.it !bound)
       && not (List.exists (function
            | VariableCapture (other, _) -> other.it = id.it
            | DefinitionCapture _ | TypeCapture _ -> false) !captures)
    then captures := VariableCapture (id, typ) :: !captures
  in
  let add_definition = function
    | Some parameter
      when Il.Free.Set.mem parameter.id.it (!free).Il.Free.defid
           && not (List.exists (function
                | DefinitionCapture other -> other.id.it = parameter.id.it
                | VariableCapture _ | TypeCapture _ -> false) !captures) ->
        captures := DefinitionCapture parameter :: !captures
    | Some _ | None -> ()
  in
  let add_arguments args =
    List.iter
      (fun arg ->
        List.find_opt (fun (actual, _) -> actual == arg) definition_arguments
        |> Option.map snd
        |> add_definition)
      args
  in
  let add_type typ =
    match typ.it with
    | VarT (id, []) when List.exists (( == ) id) type_parameters ->
        if not (List.exists (function
          | TypeCapture other -> other.it = id.it
          | VariableCapture _ | DefinitionCapture _ -> false) !captures)
        then captures := TypeCapture id :: !captures
    | VarT (_, args) -> add_arguments args
    | _ -> ()
  in
  let add_exp exp =
    match exp.it with
    | VarE id -> add_variable id exp.note
    | CallE (_, args) ->
        add_definition
          (List.find_opt (fun (call, _) -> call == exp) definition_calls
           |> Option.map snd);
        add_arguments args
    | _ -> ()
  in
  let module Types = Il.Iter.Make (struct
    include Il.Iter.Skip
    let visit_typ = add_type
    let visit_exp = add_exp
  end) in
  let add_note typ =
    free := Il.Free.(!free ++ free_typ typ);
    visit_noted_type add_type Types.exp typ
  in
  let module Visitor = Il.Iter.Make (struct
    include Il.Iter.Skip

    let visit_exp exp =
      add_note exp.note;
      add_exp exp
    let visit_typ = add_type
    let visit_path path = add_note path.note
    let visit_prem prem =
      match prem.it with
      | RulePr (_, args, _, _) -> add_arguments args
      | _ -> ()

    let scope_enter id _typ =
      bound := id.it :: !bound

    let scope_exit id () =
      bound := remove_id id.it !bound
  end)
  in
  begin match body with
  | ExpBody exp -> Visitor.exp exp
  | PremiseBody prem -> Visitor.prem prem
  end;
  List.rev !captures

let capture_exp_variables definition_calls definition_arguments type_parameters body iterexp =
  capture_variables definition_calls definition_arguments type_parameters Il.Free.(free_exp body)
    (ExpBody body) iterexp

let capture_premise_variables definition_calls definition_arguments type_parameters body iterexp =
  capture_variables definition_calls definition_arguments type_parameters Il.Free.(free_prem body)
    (PremiseBody body) iterexp


let rec collect_hints hints = function
  | [] -> hints
  | def :: defs ->
      begin match def.it with
      | HintD hintdef -> collect_hints (hintdef :: hints) defs
      | RecD nested ->
          collect_hints (collect_hints hints nested) defs
      | TypD _ | RelD _ | DecD _ | GramD _ ->
          collect_hints hints defs
      end

let has_dec_hint_in hints target_name name =
  List.fold_left
    (fun found hintdef ->
      match hintdef.it with
      | DecH (target, values) when target.it = target_name ->
          List.fold_left
               (fun found hint ->
                 begin match hint.hintid.it, hint.hintexp.it with
                 | ("builtin" | "maude_kind" | "maude_rule"), El.Ast.SeqE [] -> ()
                 | ("builtin" | "maude_kind" | "maude_rule" as flag), _ ->
                     Util.Error.error hint.hintid.at "translation"
                       ("Unsupported DecD $" ^ target_name ^ ": "
                        ^ flag ^ " must be a flag hint")
                 | _ -> ()
                 end;
                 found || hint.hintid.it = name)
               found values
      | TypH _ | RelH _ | DecH _ | GramH _ | RuleH _ -> found)
    false hints

let relation_hint_names hints target_name =
  let values =
    hints
    |> List.concat_map (fun hintdef ->
         match hintdef.it with
         | RelH (target, values) when target.it = target_name -> values
         | TypH _ | RelH _ | DecH _ | GramH _ | RuleH _ -> [])
  in
  values
  |> List.fold_left
       (fun names hint ->
         match names, hint.hintid.it with
         | Error _ as error, _ -> error
         | Ok names, ("maude_eq" | "maude_predicate" as name) ->
             begin match hint.hintexp.it with
             | El.Ast.SeqE [] -> Ok (name :: names)
             | _ -> Error (name ^ " must be a flag hint")
             end
         | Ok names, "maude_backend" ->
             begin match hint.hintexp.it with
             | El.Ast.TextE "check" -> Ok ("backend-check" :: names)
             | El.Ast.TextE "compute" -> Ok ("backend-compute" :: names)
             | _ -> Error "maude_backend must be \"check\" or \"compute\""
             end
         | Ok names, _ -> Ok names)
       (Ok [])
  |> Result.map (List.sort_uniq String.compare)

let classify_relation hints source mixop request_sort =
  let markers = Mixop.marker_positions in
  let arity = Xl.Mixop.arity mixop in
  let plain = markers Xl.Atom.[SqArrow; SqArrowStar] mixop in
  let execution =
    markers Xl.Atom.[SqArrow; SqArrowSub; SqArrowStar; SqArrowStarSub] mixop
  in
  let plain_equation = markers Xl.Atom.[Approx] mixop in
  let equation = markers Xl.Atom.[Approx; ApproxSub] mixop in
  let plain_function = markers Xl.Atom.[Colon] mixop in
  let functions = markers Xl.Atom.[Colon; ColonSub] mixop in
  match execution, plain, equation, plain_equation,
        functions, plain_function,
        relation_hint_names hints source with
  | _, _, _, _, _, _, Error reason -> Error reason
  | [input_count], [plain_count], [], [], _, _, Ok []
    when input_count = plain_count && input_count > 0 && input_count < arity ->
      Ok (Execution {request_sort = request_sort (); input_count})
  | [], [], [input_count], [plain_count], _, _, Ok ["maude_eq"]
    when input_count = plain_count && input_count > 0 && input_count < arity ->
      Ok (Equation {input_count})
  | [], [], _, _, _, _, Ok ["maude_eq"] ->
      Error "maude_eq requires exactly one plain ~~ marker"
  | [], [], _, _, _, _, Ok ["maude_predicate"] -> Ok Predicate
  | [], [], _, _, _, _, Ok ["backend-check"] -> Ok BackendCheck
  | [], [], _, _, [input_count], [plain_count], Ok ["backend-compute"]
    when input_count = plain_count && input_count > 0 && input_count < arity ->
      Ok (BackendCompute {input_count})
  | [], [], _, _, _, _, Ok ["backend-compute"] ->
      Error "maude_backend \"compute\" requires exactly one plain : marker"
  | [], [], _, _, _, _, Ok [] ->
      Error "non-execution relation requires an explicit backend hint"
  | _ -> Error "relation has unsupported or conflicting backend markers"

let inverse_hint hints source =
  let targets =
    hints
    |> List.concat_map (fun hintdef ->
         match hintdef.it with
         | DecH (id, hints) when id.it = source ->
             hints
             |> List.filter (fun hint -> hint.hintid.it = "inverse")
             |> List.map (fun hint ->
                  match hint.hintexp.it with
                  | El.Ast.CallE (target, []) -> Ok target
                  | _ -> Error "inverse hint must name a definition")
         | TypH _ | RelH _ | DecH _ | GramH _ | RuleH _ ->
             [])
  in
  match targets with
  | [] -> None
  | Error reason :: _ -> Some (Error reason)
  | Ok target :: targets ->
      if List.for_all
           (function Ok other -> other.it = target.it | Error _ -> false)
           targets
      then Some (Ok target)
      else Some (Error "definition has conflicting inverse hints")

let rec equal_parameter compare_names left right =
  let equal_id left right =
    not compare_names || left.it = right.it
  in
  match left.it, right.it with
  | ExpP (left_id, left_typ), ExpP (right_id, right_typ) ->
      equal_id left_id right_id && Il.Eq.eq_typ left_typ right_typ
  | TypP left_id, TypP right_id -> equal_id left_id right_id
  | DefP (left_id, left_params, left_result),
    DefP (right_id, right_params, right_result) ->
      equal_id left_id right_id
      && List.length left_params = List.length right_params
      && List.for_all2
           (equal_parameter compare_names) left_params right_params
      && Il.Eq.eq_typ left_result right_result
  | GramP _, GramP _ -> false
  | (ExpP _ | TypP _ | DefP _ | GramP _), _ -> false

let compatible_parameter = equal_parameter false
let same_parameter = equal_parameter true

(* A definition inverse receives the preserved parameters in source order,
   followed by the original result, and returns the omitted parameter. *)
let remove_at index items =
  items
  |> List.mapi (fun position item -> position, item)
  |> List.filter_map (fun (position, item) ->
       if position = index then None else Some item)

let validate_inverse definitions source = function
  | Error reason -> InvalidInverse reason
  | Ok target ->
      let find name =
        List.find_opt (fun (id, _, _) -> id = name) definitions
      in
      match find source, find target.it with
      | None, _ -> InvalidInverse "inverse source is not a definition"
      | _, None -> InvalidInverse "inverse target is not a definition"
      | Some (_, source_params, source_result),
        Some (_, target_params, target_result) ->
          begin match List.rev target_params with
          | {it = ExpP (_, result); _} :: target_known_rev
            when Il.Eq.eq_typ source_result result ->
              let target_known = List.rev target_known_rev in
              let candidates =
                source_params
                |> List.mapi (fun missing param -> missing, param)
                |> List.filter_map (fun (missing, param) ->
                     match param.it with
                     | ExpP (_, missing_result)
                       when Il.Eq.eq_typ missing_result target_result ->
                         let source_known = remove_at missing source_params in
                         if List.length source_known = List.length target_known
                            && List.for_all2
                                 compatible_parameter source_known target_known
                         then Some missing else None
                     | ExpP _ | TypP _ | DefP _ | GramP _ -> None)
              in
              let candidates =
                match candidates with
                | [_] -> candidates
                | _ ->
                    List.filter
                      (fun missing ->
                        List.for_all2 same_parameter
                          (remove_at missing source_params) target_known)
                      candidates
              in
              begin match candidates with
              | [missing] ->
                  ValidInverse {inverse_target = target; missing}
              | [] ->
                  InvalidInverse
                    "inverse signature does not identify a missing argument"
              | _ ->
                  InvalidInverse
                    "inverse signature identifies multiple missing arguments"
              end
          | _ ->
              InvalidInverse
                "inverse must take the forward result as its last argument"
          end

let membership_choice_shape definition clause =
  match clause.it with
  | DefD (_, args, rhs, prems) ->
      begin match List.rev prems with
      | {it = IfPr ({it = MemE (({it = VarE _; _} as element), collection); _}); _}
        :: prefix_rev
        when Il.Eq.eq_exp rhs element ->
          let prefix = List.rev prefix_rev in
          let head = Frontend.Det.det_list Frontend.Det.det_arg args in
          let preceding =
            Frontend.Det.det_list Frontend.Det.det_prem prefix
          in
          let bound = Il.Free.Set.union head.varid preceding.varid in
          let known exp =
            Il.Free.Set.subset Il.Free.(free_exp exp).varid bound
          in
          if not (known element) && known collection then
            Some
              { definition
              ; clause
              ; helper_name = ""
              ; prefix
              ; element
              ; collection
              }
          else None
      | _ -> None
      end

let rec collect_membership_choices = function
  | [] -> []
  | def :: defs ->
      let choices =
        match def.it with
        | DecD (id, _, _, clauses) ->
            List.filter_map (membership_choice_shape id.it) clauses
        | RecD nested -> collect_membership_choices nested
        | TypD _ | RelD _ | GramD _ | HintD _ -> []
      in
      choices @ collect_membership_choices defs


let scan script =
  let type_env = Il.Env.env_of_script script in
  let sort_metadata = Hintd.scan_sorts script in
  let rec collect declarations def =
    let types, definitions, relations = declarations in
    match def.it with
    | TypD (id, _, insts) ->
        (id.it, insts) :: types, definitions, relations
    | DecD (id, params, result, _) ->
        types, (id.it, params, result) :: definitions, relations
    | RelD (id, _, mixop, _, _) ->
        types, definitions, (id.it, mixop) :: relations
    | RecD defs -> List.fold_left collect declarations defs
    | GramD _ | HintD _ -> declarations
  in
  let types, definitions, relations =
    List.fold_left collect ([], [], []) script
  in
  let type_definitions = List.rev types in
  let definitions = List.rev definitions in
  let relations = List.rev relations in
  let hints = collect_hints [] script |> List.rev in
  let membership_choices = collect_membership_choices script in
  let inverses =
    definitions
    |> List.filter_map (fun (source, _, _) ->
         inverse_hint hints source
         |> Option.map (fun inverse ->
              source,
              validate_inverse definitions source inverse))
  in
  let iterations = ref [] in
  let premise_iterations = ref [] in
  let premise_count = ref 0 in
  let names = ref [] in
  let used_names = ref reserved_names in

  let add_name kind source candidate =
    match
      List.find_opt
        (fun (kind', source', _) -> kind = kind' && source = source')
        !names
    with
    | Some (_, _, name) -> name
    | None ->
        let name = fresh_name used_names candidate in
        names := (kind, source, name) :: !names;
        name
  in
  let registered_name kind source =
    match
      List.find_opt
        (fun (kind', source', _) -> kind = kind' && source = source')
        !names
    with
    | Some (_, _, name) -> name
    | None -> invalid_arg ("unregistered source name " ^ source)
  in
  let add_id_name kind id =
    ignore (add_name kind id.it (sanitize id.it))
  in
  let add_mixop_name mixop =
    if not (Mixop.is_hole_only mixop) then
      let source = Mixop.key mixop in
      ignore (add_name MixopName source (Mixop.name mixop))
  in
  let add_def_name def =
    match def.it with
    | TypD (id, _, _) -> add_id_name TypName id
    | RelD (id, _, _, _, _) -> add_id_name RelName id
    | DecD (id, _, _, _) ->
        let candidate =
          if has_dec_hint_in hints id.it "builtin" then builtin_name id.it
          else sanitize id.it
        in
        ignore (add_name DefName id.it candidate)
    | GramD _ -> ()
    | HintD _ -> ()
    | RecD _ -> ()
  in
  List.iter
    (fun (source, _, _) ->
      if has_dec_hint_in hints source "builtin" then
        ignore (add_name DefName source (builtin_name source)))
    definitions;

  let observed_variables = ref [] in
  let definition_parameters = ref [] in
  let type_parameters = ref [] in
  let definition_arguments = ref [] in
  let definition_calls = ref [] in
  let definition_values = ref [] in
  let definition_applications = ref [] in
  let sort_of_typ typ =
    Hintd.sort_of_typ sort_metadata typ
  in

  let add_variable_with_sort id sort =
    let anonymous = id.it = "_" in
    let matches (other, other_sort, other_anonymous) =
      if anonymous then id == other
      else not other_anonymous && other.it = id.it && other_sort = sort
    in
    if not (List.exists matches !observed_variables) then
      observed_variables := (id, sort, anonymous) :: !observed_variables
  in
  let add_variable id typ =
    add_variable_with_sort id (sort_of_typ typ)
  in
  let rec add_param param =
    match param.it with
    | ExpP (id, typ) -> add_variable id typ
    | DefP (id, params, result) ->
        definition_parameters := {id; params; result} :: !definition_parameters;
        let sort, _, _ =
          definition_signature_with sort_metadata params result
        in
        add_variable_with_sort id sort;
        add_params params
    | TypP id ->
        type_parameters := id :: !type_parameters;
        add_variable_with_sort id "SpectecType"
    | GramP _ -> ()

  and add_params params =
    List.iter add_param params
  in

  let find_definition_parameter parameters id =
    List.find_opt (fun parameter -> parameter.id.it = id.it) parameters
  in
  let local_definition_parameters params =
    List.filter_map
      (fun param ->
        match param.it with
        | DefP (id, params, result) -> Some {id; params; result}
        | ExpP _ | TypP _ | GramP _ -> None)
      params
  in
  let target_definition id =
    match
      List.filter_map
        (fun (name, params, result) ->
          if name = id.it then Some {target = id; params; result} else None)
        definitions
    with
    | [] -> invalid_arg ("unknown definition value " ^ id.it)
    | value :: values ->
        let signature' value =
          definition_signature_with sort_metadata value.params value.result
        in
        if List.for_all (fun candidate -> signature' candidate = signature' value) values
        then value
        else invalid_arg ("conflicting signatures for definition " ^ id.it)
  in
  let add_definition_value id =
    let value = target_definition id in
    if not
         (List.exists
            (fun candidate -> candidate.target.it = id.it)
            !definition_values)
    then definition_values := value :: !definition_values;
    value
  in
  let add_definition_application target params result =
    let value = add_definition_value target in
    let signature = definition_signature_with sort_metadata in
    let expected = signature params result in
    let actual = signature value.params value.result in
    if expected <> actual then
      invalid_arg ("definition argument signature mismatch for " ^ target.it);
    definition_applications := value :: !definition_applications
  in
  let inspect_bound_argument bound arg =
    match arg.it with
    | DefA id ->
        begin match find_definition_parameter bound id with
        | Some parameter ->
            definition_arguments := (arg, parameter) :: !definition_arguments
        | None ->
            ignore (add_definition_value id)
        end
    | ExpA _ | TypA _ | GramA _ -> ()
  in
  let rec inspect_arguments bound formals actuals =
    match formals, actuals with
    | formal :: formals, actual :: actuals ->
        begin match formal.it, actual.it with
        | DefP (_, params, result), DefA target
          when find_definition_parameter bound target = None ->
            add_definition_application target params result
        | _ -> ()
        end;
        inspect_arguments bound formals actuals
    | _, _ -> ()
  in
  let scan_scope outer_params scope =
    let quants, head_args =
      match scope with
      | `Clause {it = DefD (quants, args, _, _); _} -> quants, args
      | `Rule {it = RuleD (_, quants, _, _, _); _} -> quants, []
      | `Instance {it = InstD (quants, args, _); _} -> quants, args
      | `Field (_, (_, quants, _), _) | `Case (_, (_, quants, _), _) -> quants, []
    in
    let bound_types =
      List.filter_map
        (fun param -> match param.it with TypP id -> Some id.it | _ -> None)
        (quants @ outer_params)
    in
    let mark_type typ =
      match typ.it with
      | VarT (id, []) when List.mem id.it bound_types ->
          if not (List.exists (( == ) id) !type_parameters)
          then type_parameters := id :: !type_parameters
      | _ -> ()
    in
    let bound =
      local_definition_parameters quants
      @ local_definition_parameters outer_params
    in
    let inspect_type typ =
      mark_type typ;
      match typ.it with
      | VarT (_, args) -> List.iter (inspect_bound_argument bound) args
      | _ -> ()
    in
    let inspect_exp exp =
      match exp.it with
      | CallE (id, args) ->
          List.iter (inspect_bound_argument bound) args;
          begin match find_definition_parameter bound id with
          | Some parameter ->
              definition_calls := (exp, parameter) :: !definition_calls
          | None ->
              begin match
                List.find_opt (fun (name, _, _) -> name = id.it) definitions
              with
              | Some (_, params, _) -> inspect_arguments bound params args
              | None -> ()
              end
          end
      | _ -> ()
    in
    let module Types = Il.Iter.Make (struct
      include Il.Iter.Skip
      let visit_typ = inspect_type
      let visit_exp = inspect_exp
    end) in
    List.iter (inspect_bound_argument bound) head_args;
    let module DefinitionVisitor = Il.Iter.Make (struct
      include Il.Iter.Skip

      let visit_exp exp =
        visit_noted_type inspect_type Types.exp exp.note;
        inspect_exp exp
      let visit_typ = inspect_type
      let visit_path path = visit_noted_type inspect_type Types.exp path.note

      let visit_prem prem =
        match prem.it with
        | RulePr (_, args, _, _) ->
            List.iter (inspect_bound_argument bound) args
        | IfPr _ | ElsePr | IterPr _ | LetPr _ | NegPr _ -> ()
    end)
    in
    begin match scope with
    | `Clause clause -> DefinitionVisitor.clause clause
    | `Rule rule -> DefinitionVisitor.rule rule
    | `Instance inst -> DefinitionVisitor.inst inst
    | `Field field -> DefinitionVisitor.typfield field
    | `Case case -> DefinitionVisitor.typcase case
    end
  in
  let add_deftyp_quants params deftyp =
    match deftyp.it with
    | AliasT _ -> ()
    | StructT fields ->
        List.iter
          (fun ((_, (_, quants, _), _) as field) ->
            add_params quants;
            scan_scope params (`Field field))
          fields
    | VariantT cases ->
        List.iter
          (fun ((_, (_, quants, _), _) as case) ->
            add_params quants;
            scan_scope params (`Case case))
          cases
  in
  let add_def_variables def =
    match def.it with
    | TypD (_, params, insts) ->
        add_params params;
        List.iter
          (fun inst ->
            match inst.it with
            | InstD (quants, _, deftyp) ->
                add_params quants;
                scan_scope params (`Instance inst);
                add_deftyp_quants (quants @ params) deftyp)
          insts
    | RelD (_, params, _, _, rules) ->
        add_params params;
        List.iter
          (fun rule ->
            match rule.it with
            | RuleD (_, quants, _, _, _) ->
                add_params quants;
                scan_scope params (`Rule rule))
          rules
    | DecD (_, params, _, clauses) ->
        add_params params;
        List.iter
          (fun clause ->
            match clause.it with
            | DefD (quants, _, _, _) ->
                add_params quants;
                scan_scope params (`Clause clause))
          clauses
    | GramD _ | RecD _ | HintD _ -> ()
  in

  let add_iteration owner body iterexp =
    iterations :=
      { name = iteration_base_name body
      ; tail_name = ""
      ; projector_name = ""
      ; projector_tail_name = ""
      ; forward_requested = false
      ; projector_requested = false
      ; owner
      ; body
      ; iterexp
      ; captures = capture_exp_variables !definition_calls !definition_arguments
          !type_parameters body iterexp
      }
      :: !iterations
  in
  let add_premise_iteration owner premise body iterexp =
    incr premise_count;
    premise_iterations :=
      { name = "iterpr-" ^ string_of_int !premise_count
      ; tail_name = ""
      ; output_names = []
      ; check_requested = false
      ; owner
      ; premise
      ; body
      ; iterexp
      ; captures = capture_premise_variables !definition_calls !definition_arguments
          !type_parameters body iterexp
      }
      :: !premise_iterations
  in

  let current_owner = ref OtherOwner in
  let module VariableVisitor = Il.Iter.Make (struct
    include Il.Iter.Skip

    let visit_mixop = add_mixop_name
    let visit_def def =
      current_owner :=
        begin match def.it with
        | RelD (id, _, _, _, _) -> RelationOwner id.it
        | DecD (id, _, _, _) -> DefinitionOwner id.it
        | TypD _ | GramD _ | HintD _ | RecD _ -> OtherOwner
        end;
      add_def_name def;
      add_def_variables def

    let visit_exp exp =
      match exp.it with
      | VarE id -> add_variable id exp.note
      | IterE (body, iterexp) -> add_iteration !current_owner body iterexp
      | _ -> ()

    let visit_prem premise =
      match premise.it with
      | LetPr (quants, _, _) -> add_params quants
      | IterPr (body, iterexp) ->
          add_premise_iteration !current_owner premise body iterexp
      | RulePr _ | IfPr _ | ElsePr | NegPr _ -> ()

    let scope_enter id typ =
      add_variable id typ

    let scope_exit _id () = ()
  end)
  in
  VariableVisitor.list VariableVisitor.def script;
  (* Il.Iter's scope hook receives the collection type. The helper's head
   * needs its element type, even if the binder never occurs in the body. *)
  let add_generators (_, generators) =
    List.iter (fun (id, source) ->
      match source.note.it with
      | IterT (element, _) -> add_variable id element
      | _ -> invalid_arg "iteration generator does not have an iteration type")
      generators
  in
  List.iter (fun (iteration : iteration) -> add_generators iteration.iterexp)
    (List.rev !iterations);
  List.iter (fun (iteration : premise_iteration) -> add_generators iteration.iterexp)
    (List.rev !premise_iterations);

  let observed_variables = List.rev !observed_variables in
  let named, anonymous =
    List.partition (fun (_, _, anonymous) -> not anonymous)
      observed_variables
  in
  let exact, renamed =
    List.partition
      (fun (id, _, _) -> id.it = variable_base id.it)
      named
  in
  let used_variable_names =
    ref !used_names
  in
  let variables =
    exact @ renamed
    |> List.map (fun (id, sort, _) ->
         let target_name =
           fresh_variable_name used_variable_names (variable_base id.it)
         in
         (id.it, sort), target_name)
  in
  let anonymous_variables =
    anonymous
    |> List.mapi (fun index (id, sort, _) ->
         let target_name =
           fresh_variable_name used_variable_names
             ("PARAM" ^ string_of_int (index + 1))
         in
         id, sort, target_name)
  in
  let iterations =
    List.rev !iterations
    |> List.map (fun (iteration : iteration) ->
         let name =
           fresh used_names
             (fun index -> "-" ^ string_of_int index)
             iteration.name
         in
         { iteration with
           name
         ; tail_name = fresh_name used_names (name ^ "-tail")
         ; projector_name = fresh_name used_names ("project-" ^ name)
         ; projector_tail_name =
             fresh_name used_names ("project-" ^ name ^ "-tail")
         })
  in
  let premise_iterations =
    List.rev !premise_iterations
    |> List.map (fun (iteration : premise_iteration) ->
         let name = fresh_name used_names iteration.name in
         let _, generators = iteration.iterexp in
         let output_names =
           List.mapi
             (fun position _ ->
               let output =
                 fresh_name used_names
                   (name ^ "-output-" ^ string_of_int (position + 1))
               in
               output, fresh_name used_names (output ^ "-tail"))
             generators
         in
         { iteration with
           name
         ; tail_name = fresh_name used_names (name ^ "-tail")
         ; output_names
         })
  in
  let membership_choices =
    membership_choices
    |> List.map (fun choice ->
         let definition_name =
           registered_name DefName choice.definition
         in
         let position = choice.clause.at.left in
         let candidate =
           Printf.sprintf "%s-choice-%d-%d"
             definition_name position.line position.column
         in
         {choice with helper_name = fresh_name used_names candidate})
  in
  let choice_definitions =
    membership_choices
    |> List.map (fun choice -> choice.definition)
    |> StringSet.of_list
  in
  let rewrite_sorts =
    definitions
    |> List.filter_map (fun (source, _, _) ->
         let is_choice = StringSet.mem source choice_definitions in
         if has_dec_hint_in hints source "maude_rule" || is_choice then
           let name = registered_name DefName source in
           let suffix = if is_choice then "-Request" else "-Config" in
           Some (source, fresh_name used_names (name ^ suffix))
         else
           None)
  in
  let relation_policies, unsupported_relations =
    List.fold_right
      (fun (source, mixop) (policies, unsupported) ->
        let request_sort () =
          let name = registered_name RelName source in
          fresh_name used_names (name ^ "-Request")
        in
        match classify_relation hints source mixop request_sort with
        | Ok policy -> (source, policy) :: policies, unsupported
        | Error reason -> policies, (source, reason) :: unsupported)
      relations ([], [])
  in
  let contexts =
    Hintd.scan_contexts sort_metadata
      (fun source ->
        match List.assoc_opt source relation_policies with
        | Some (Execution {input_count; _}) -> Some input_count
        | Some (Equation _ | Predicate | BackendCheck | BackendCompute _)
        | None -> None)
  in
  let relation_enabled_helpers =
    let rec collect acc def =
      match def.it with
      | RelD (id, _, _, _, rules) ->
          begin match List.assoc_opt id.it relation_policies with
          | Some (Execution _) ->
              let relation = registered_name RelName id.it in
              List.mapi
                (fun ordinal _ ->
                  let candidate =
                    Printf.sprintf "%s-enabled-%d" relation (ordinal + 1)
                  in
                  (id.it, ordinal), fresh_name used_names candidate)
                rules
              |> List.rev_append acc
          | Some (Equation _ | Predicate | BackendCheck | BackendCompute _)
          | None -> acc
          end
      | RecD defs -> List.fold_left collect acc defs
      | TypD _ | DecD _ | GramD _ | HintD _ -> acc
    in
    List.fold_left collect [] script |> List.rev
  in
  let unsupported_relation_names =
    List.map fst unsupported_relations |> StringSet.of_list
  in
  let unsupported_definition_names =
    let names = ref StringSet.empty in
    let rec visit_def def =
      match def.it with
      | DecD (id, _, _, clauses) ->
          if List.exists
               (fun clause ->
                 let unsupported = ref false in
                 let module Visitor = Il.Iter.Make (struct
                   include Il.Iter.Skip
                   let visit_prem prem =
                     match prem.it with
                     | RulePr (target, _, _, _)
                       when StringSet.mem
                              target.it unsupported_relation_names ->
                         unsupported := true
                     | RulePr _ | IfPr _ | LetPr _ | ElsePr
                     | IterPr _ | NegPr _ -> ()
                 end)
                 in
                 Visitor.clause clause;
                 !unsupported)
               clauses
          then names := StringSet.add id.it !names
      | RecD defs -> List.iter visit_def defs
      | TypD _ | RelD _ | GramD _ | HintD _ -> ()
    in
    List.iter visit_def script;
    !names
  in
  let definition_bodies =
    definitions
    |> List.map (fun (source, _, _) ->
         source,
         not (has_dec_hint_in hints source "builtin")
         && not (StringSet.mem source unsupported_definition_names))
    |> List.sort_uniq compare
  in
  let relation_supported source =
    match List.assoc_opt source relation_policies with
    | Some (BackendCheck | BackendCompute _) | None -> false
    | Some (Execution _ | Equation _ | Predicate) -> true
  in
  let definition_supported source =
    Option.value (List.assoc_opt source definition_bodies) ~default:false
  in
  let owner_supported = function
    | RelationOwner source -> relation_supported source
    | DefinitionOwner source -> definition_supported source
    | OtherOwner -> true
  in
  let premise_iterations =
    premise_iterations
    |> List.filter (fun (iteration : premise_iteration) ->
         owner_supported iteration.owner)
  in
  let iterations =
    iterations
    |> List.filter (fun (iteration : iteration) ->
         owner_supported iteration.owner)
  in
  (* Renamed list families cannot silently pass through an erased X* API:
   * its equations still match the generic eps/__ constructors. *)
  if Hintd.separate_list_families sort_metadata then begin
    let rec check id actual formal =
      let owner = Hintd.typed_list_owner sort_metadata in
      match owner actual, owner formal with
      | Some _, None | None, Some _ ->
          Util.Error.error id.at "translation"
            ("Unsupported: call $" ^ id.it
             ^ " crosses renamed typed-list and generic representations ("
             ^ Il.Print.string_of_typ actual ^ " / "
             ^ Il.Print.string_of_typ formal
             ^ "); list conversion is not implemented")
      | _ ->
          begin match actual.it, formal.it with
          | IterT (actual, _), IterT (formal, _) -> check id actual formal
          | TupT actuals, TupT formals
            when List.length actuals = List.length formals ->
              List.iter2 (fun (_, a) (_, f) -> check id a f) actuals formals
          | _ -> ()
          end
    in
    let module Visitor = Il.Iter.Make (struct
      include Il.Iter.Skip
      let visit_exp exp =
        match exp.it with
        | CallE (id, args) ->
            let params, result =
              match List.find_opt
                (fun (call, _) -> call == exp) !definition_calls with
              | Some (_, parameter) -> parameter.params, parameter.result
              | None ->
                  let params, result, _ = Il.Env.find_def type_env id in
                  params, result
            in
            List.iter2
              (fun param arg ->
                match param.it, arg.it with
                | ExpP (_, typ), ExpA arg -> check id arg.note typ
                | _ -> ())
              params args;
            check id exp.note result
        | _ -> ()
    end) in
    List.iter Visitor.def script
  end;
  { type_env
  ; sort_metadata
  ; contexts
  ; iterations
  ; premise_iterations
  ; hints
  ; names = List.rev !names
  ; relation_policies
  ; relation_enabled_helpers
  ; unsupported_relations
  ; definition_bodies
  ; rewrite_sorts
  ; membership_choices
  ; type_definitions
  ; variables
  ; anonymous_variables
  ; definition_parameters = List.rev !definition_parameters
  ; type_parameters = !type_parameters
  ; definition_arguments = List.rev !definition_arguments
  ; definition_calls = List.rev !definition_calls
  ; definition_values = List.rev !definition_values
  ; definition_applications = List.rev !definition_applications
  ; inverses
  }


let find_name index kind source =
  List.find_opt
    (fun (kind', source', _) -> kind = kind' && source = source')
    index.names
  |> Option.map (fun (_, _, name) -> name)

let name index kind source =
  match find_name index kind source with
  | Some name -> name
  | None -> invalid_arg ("unregistered source name " ^ source)

let local_name index kind id =
  match find_name index kind id.it with
  | Some name -> name
  | None -> sanitize id.it

let typ_name index id = local_name index TypName id
let rel_name index id = name index RelName id.it
let def_name index id = local_name index DefName id
let mixop_name index mixop = name index MixopName (Mixop.key mixop)

let has_dec_hint index id name =
  has_dec_hint_in index.hints id.it name

let relation_policy index id =
  match List.assoc_opt id.it index.relation_policies with
  | Some policy -> Ok policy
  | None ->
      begin match List.assoc_opt id.it index.unsupported_relations with
      | Some reason -> Error reason
      | None -> invalid_arg ("unregistered relation " ^ id.it)
      end

let relation_enabled_helper index id ordinal =
  match List.assoc_opt (id.it, ordinal) index.relation_enabled_helpers with
  | Some name -> name
  | None ->
      invalid_arg
        (Printf.sprintf
           "unregistered enabledness helper for relation %s rule %d"
           id.it (ordinal + 1))

let definition_body_supported index id =
  match List.assoc_opt id.it index.definition_bodies with
  | Some supported -> supported
  | None -> invalid_arg ("unregistered definition " ^ id.it)

let require_definition_body index use id =
  if not (definition_body_supported index id || has_dec_hint index id "builtin")
  then invalid_arg
    (use ^ " $" ^ id.it ^ " at " ^ string_of_region id.at
     ^ " requires a body containing an unsupported RulePr;"
     ^ " its relation needs an explicit supported lowering")

let premise_iteration_binds_membership index
    (iteration : premise_iteration) =
  match iteration.owner with
  | RelationOwner source ->
      begin match List.assoc_opt source index.relation_policies with
      | Some (Execution _) -> true
      | Some (Equation _ | Predicate | BackendCheck | BackendCompute _)
      | None -> false
      end
  | DefinitionOwner _ | OtherOwner -> false

let membership_choice index clause =
  List.find_opt (fun choice -> choice.clause == clause) index.membership_choices

let has_membership_choice index id =
  List.exists
    (fun choice -> choice.definition = id.it)
    index.membership_choices

let definition_requires_rewrite index id =
  has_dec_hint index id "maude_rule" || has_membership_choice index id

let rewrite_sort index id =
  match List.assoc_opt id.it index.rewrite_sorts with
  | Some sort -> sort
  | None -> invalid_arg ("definition does not produce rewrite requests: " ^ id.it)

let definition_variable index (parameter : definition_parameter) =
  let sort, _, _ =
    definition_signature index parameter.params parameter.result
  in
  match List.assoc_opt (parameter.id.it, sort) index.variables with
  | Some name -> Maude_il.source_variable name sort
  | None -> invalid_arg ("unregistered definition variable " ^ parameter.id.it)

let definition_argument index arg =
  List.find_opt (fun (arg', _) -> arg == arg') index.definition_arguments
  |> Option.map snd

let definition_call index exp =
  List.find_opt (fun (exp', _) -> exp == exp') index.definition_calls
  |> Option.map snd

let definition_parameters index = index.definition_parameters
let definition_values index = index.definition_values
let definition_applications index = index.definition_applications

let inverse index id =
  match List.assoc_opt id.it index.inverses with
  | None -> None
  | Some (ValidInverse contract) -> Some contract
  | Some (InvalidInverse reason) -> invalid_arg reason

let source_variable_with_sort index id sort =
  let target_name =
    if id.it = "_" then
      List.find_opt (fun (id', _, _) -> id == id') index.anonymous_variables
      |> Option.map (fun (_, _, name) -> name)
    else
      List.assoc_opt (id.it, sort) index.variables
  in
  match target_name with
  | Some name -> Maude_il.source_variable name sort
  | None ->
      invalid_arg ("unregistered source variable " ^ id.it)

let source_variable index id typ =
  source_variable_with_sort index id (sort_of_typ index typ)

let type_parameter index id =
  if List.exists (( == ) id) index.type_parameters then
    Some (source_variable_with_sort index id "SpectecType")
  else None

let same_representation index source target =
  Hintd.representation_inclusion index.sort_metadata source target

let alias_type index typ =
  match typ.it with
  | VarT (id, _) ->
      begin match List.assoc_opt id.it index.type_definitions with
      | Some insts ->
          List.exists
            (fun inst ->
              match inst.it with
              | InstD (_, _, {it = AliasT _; _}) -> true
              | InstD (_, _, {it = StructT _ | VariantT _; _}) -> false)
            insts
      | None -> false
      end
  | BoolT | NumT _ | TextT | TupT _ | IterT _ -> false

let variable_declarations index =
  let rec add (name, sort) groups =
    match groups with
    | [] -> [sort, [name]]
    | (sort', names) :: groups when sort = sort' ->
        (sort, name :: names) :: groups
    | group :: groups -> group :: add (name, sort) groups
  in
  let variables =
    List.map (fun ((_, sort), name) -> name, sort) index.variables
    @ List.map (fun (_, sort, name) -> name, sort) index.anonymous_variables
  in
  List.fold_left (fun groups variable -> add variable groups) [] variables
  |> List.map (fun (sort, names) -> VarDecl (List.rev names, sort))

let iterations index = index.iterations
let iteration index body =
  List.find_opt
    (fun (iteration : iteration) -> iteration.body == body)
    index.iterations

let iteration_name index body =
  match iteration index body with
  | Some iteration -> iteration.forward_requested <- true; iteration.name
  | None -> invalid_arg "IterE is missing from the prescan index"

let projector_name index body =
  match iteration index body with
  | Some iteration -> iteration.projector_requested <- true; iteration.projector_name
  | None -> invalid_arg "IterE is missing from the prescan index"

let premise_iterations index = index.premise_iterations

let premise_iteration index premise =
  List.find_opt
    (fun iteration -> iteration.premise == premise)
    index.premise_iterations

let hints index = index.hints
let sort_metadata index = index.sort_metadata
let contexts index = index.contexts

let is_context_rule index relation rule =
  List.exists
    (fun (context : Hintd.context) ->
      context.source.id.it = relation.it && context.rule == rule)
    index.contexts
