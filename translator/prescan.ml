open Util.Source
open Il.Ast
open Maude_il


type capture =
  | VariableCapture of id * typ
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
  ; owner : iteration_owner
  ; body : exp
  ; iterexp : iterexp
  ; captures : capture list
  }

type premise_iteration =
  { name : string
  ; tail_name : string
  ; output_names : (name * name) list
  ; owner : iteration_owner
  ; premise : prem
  ; body : prem
  ; iterexp : iterexp
  ; captures : capture list
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
  | Compute of
      { input_count : int
      ; subsume : subsume option
      }
  | Check of {trans : trans option}

(* hint(maude_subsume) on a rule of a computed relation: the rule's conclusion
 * is the relation's check form, an operator separate from the computation. *)
and subsume =
  { subsume_rule : string
  ; check : name
  }

(* hint(maude_trans "C" ...) on a transitivity rule of a checked relation:
 * the existential middle ranges over the listed nullary constructors and its
 * first premise uses the relation without that rule (the step operator). *)
and trans =
  { trans_rule : string
  ; step : name
  ; witnesses : string list
  }

type membership_choice =
  { definition : string
  ; clause : clause
  ; helper_name : name
  ; prefix : prem list
  ; element : exp
  ; collection : exp
  }

type name_kind = TypName | RelName | DefName | MixopName

(* The Maude name of a generated helper. Helpers first get unique working
 * names; after translation, helpers that are equal up to variable names
 * are shared and each remaining helper is named from its base
 * (Def.share_helpers, TRANSLATION_MAP.md section 6). The second name is
 * used instead when several helpers have the same first name. *)
type helper_name =
  | Base of string * string  (* e.g. map-f or else map-r, all-r, choose-f *)
  | Tail of name    (* the tail helper of the named helper: <its name>-tail *)

module StringSet = Set.Make (String)

(* Iteration helpers are generated only when a translation case calls them.
 * A case records each call in the request table of the index. *)
type helper_request =
  | ForwardHelper       (* IterE helper that computes the sequence *)
  | ProjectorHelper     (* IterE helper that recovers a pattern's variables *)
  | CheckHelper         (* IterPr helper that checks every element *)
  | OutputHelper of int (* IterPr helper that computes one generator source *)

type t =
  { type_env : Il.Env.t
  ; input_types : (exp * typ) list option
  ; sort_metadata : Hintd.t
  ; contexts : Hintd.context list
  ; heatcool : Hintd.heatcool list
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
  ; type_parameters : id list
  ; inverses : (string * inverse) list
  ; requests : (name * helper_request, unit) Hashtbl.t
  ; helper_names : (name * helper_name) list
  ; reserved : StringSet.t  (* every non-helper name in use *)
  }



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

let reserved_names =
  StringSet.of_list
    [ "true"; "false"; "none"; "min"; "max"; "s"; "sd"
    ; "decFloat"
    ; "sqrt"; "exp"; "log"; "sin"; "cos"; "tan"
    ; "asin"; "acos"; "atan"; "pi"; "_xor_"
    ; "eps"; "bool"; "rat"; "float"; "text"; "seq"; "unseq"
    ; "#_"; "#bool"; "#rat"; "#float"; "#string"; "string"
    ; "tuple"; "field"; "typecheck"; "len"
    ; "lift"; "repeatSeq"
    ; "_+_"; "_-_"; "_*_"; "_/_"; "_^_"; "_<_"; "_>_"
    ; "_<=_"; "_>=_"; "_==_"; "_=/=_"; "not_"; "_and_"
    ; "_or_"; "_implies_"; "_rem_"
    (* Native numeric operators whose domains overlap unwrapped Nat/Int. *)
    ; "abs"; "ceiling"; "floor"; "gcd"; "lcm"; "modExp"
    (* Native string operators *)
    ; "char"; "ascii"; "length"; "substr"; "find"; "rfind"
    ; "upperCase"; "lowerCase"; "notFound"
    (* backend/spectec-{builtin-types,semantics}.maude: types, sequences, records *)
    ; "nat"; "int"; "real"
    ; "iterOpt"; "iterList"
    ; "indexDefined"; "lenAux"
    ; "EMPTY"; "recordConcat"; "optionConcat"
    ; "hasField"
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
    ; "lane-width"; "lane-from-bits"
    ; "lane-to-bits"; "lanes-aux"; "inv-lanes-aux"
    ; "pair-chunks"; "fixed-chunks"
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

(* SpecTec subscripts use '_', so a "-N" suffix stays visibly distinct from
 * them: a second t_1 becomes T_1-2, not T_12. *)
let fresh_variable_name used candidate =
  fresh used (fun index -> "-" ^ string_of_int index) candidate

(* A variable keeps SpecTec's iteration, prime, and subscript marks: a Maude
 * variable is any whitespace-delimited token except ':' and the
 * self-delimiting ( ) [ ] { } , (Maude manual, Appendix B.2). *)
let variable_base name =
  let name =
    name
    |> String.map (function
         | ('a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '\'' | '*' | '?' | '+') as char -> char
         | _ -> '-')
    |> String.uppercase_ascii
  in
  let name = if name = "" then "VAR" else name in
  match name.[0] with
  | 'A'..'Z' -> name
  | _ -> "V-" ^ name

let compact name =
  name
  |> sanitize
  |> String.split_on_char '-'
  |> List.filter (fun part -> part <> "")
  |> String.concat "-"

let owner_name = function
  | RelationOwner source | DefinitionOwner source -> compact source
  | OtherOwner -> "exp"

(* What an IterE helper is named after: the called definition, the
 * constructor, or else the enclosing definition or relation. *)
let helper_subject owner (body : exp) =
  match body.it with
  | CallE (id, _) when compact id.it <> "" -> compact id.it
  | CaseE (mixop, _) when not (Mixop.is_hole_only mixop)
                          && compact (Mixop.name mixop) <> "" ->
      compact (Mixop.name mixop)
  | _ -> owner_name owner

let helper_base prefix owner body =
  Base (prefix ^ helper_subject owner body, prefix ^ owner_name owner)

let helper_names iterations premise_iterations membership_choices =
  List.concat_map
    (fun (iteration : iteration) ->
      let base prefix = helper_base prefix iteration.owner iteration.body in
      [ iteration.name, base "map-"
      ; iteration.tail_name, Tail iteration.name
      ; iteration.projector_name, base "unzip-"
      ; iteration.projector_tail_name, Tail iteration.projector_name
      ])
    iterations
  @ List.concat_map
      (fun (iteration : premise_iteration) ->
        let owner = owner_name iteration.owner in
        (iteration.name, Base ("all-" ^ owner, "all-" ^ owner))
        :: (iteration.tail_name, Tail iteration.name)
        :: List.concat_map
             (fun (output, tail) ->
               [output, Base ("bind-" ^ owner, "bind-" ^ owner); tail, Tail output])
             iteration.output_names)
      premise_iterations
  @ List.map
      (fun choice ->
        let name = "choose-" ^ compact choice.definition in
        choice.helper_name, Base (name, name))
      membership_choices

let iteration_base_name (body : exp) =
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

let capture_variables type_parameters free body iterexp =
  let free = ref free in
  let bound = ref (List.map (fun id -> id.it) (bound_ids iterexp)) in
  let captures = ref [] in
  let add_variable id typ =
    if Il.Free.Set.mem id.it (!free).Il.Free.varid
       && not (List.mem id.it !bound)
       && not (List.exists (function
            | VariableCapture (other, _) -> other.it = id.it
            | TypeCapture _ -> false) !captures)
    then captures := VariableCapture (id, typ) :: !captures
  in
  let add_type typ =
    match typ.it with
    | VarT (id, []) when List.exists (( == ) id) type_parameters ->
        if not (List.exists (function
          | TypeCapture other -> other.it = id.it
          | VariableCapture _ -> false) !captures)
        then captures := TypeCapture id :: !captures
    | _ -> ()
  in
  let add_exp exp =
    match exp.it with
    | VarE id -> add_variable id exp.note
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

let capture_exp_variables type_parameters body iterexp =
  capture_variables type_parameters Il.Free.(free_exp body)
    (ExpBody body) iterexp

let capture_premise_variables type_parameters body iterexp =
  capture_variables type_parameters Il.Free.(free_prem body)
    (PremiseBody body) iterexp


let rec flatten def =
  match def.it with
  | RecD defs -> List.concat_map flatten defs
  | TypD _ | RelD _ | DecD _ | GramD _ | HintD _ -> [def]

let collect_hints defs =
  List.filter_map
    (fun def -> match def.it with HintD hintdef -> Some hintdef | _ -> None)
    (List.concat_map flatten defs)

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
         | Ok names, ("maude_compute" | "maude_check" as name) ->
             begin match hint.hintexp.it with
             | El.Ast.SeqE [] -> Ok (name :: names)
             | _ -> Error (name ^ " must be a flag hint")
             end
         | Ok names, _ -> Ok names)
       (Ok [])
  |> Result.map (List.sort_uniq String.compare)

let rule_hints hints relation name =
  List.concat_map
    (fun hintdef ->
      match hintdef.it with
      | RuleH (target, rule, values) when target.it = relation ->
          values
          |> List.filter (fun hint -> hint.hintid.it = name)
          |> List.map (fun hint -> rule.it, hint)
      | TypH _ | RelH _ | DecH _ | GramH _ | RuleH _ -> [])
    hints

let subsume_hint hints source derived =
  match rule_hints hints source "maude_subsume" with
  | [] -> Ok None
  | [rule, {hintexp = {it = El.Ast.SeqE []; _}; _}] ->
      Ok (Some {subsume_rule = rule; check = derived rule})
  | [_] -> Error "maude_subsume must be a flag hint"
  | _ -> Error "relation has more than one maude_subsume rule"

let trans_hint hints source derived =
  match rule_hints hints source "maude_trans" with
  | [] -> Ok None
  | [rule, hint] ->
      let exps =
        match hint.hintexp.it with
        | El.Ast.SeqE exps -> exps
        | _ -> [hint.hintexp]
      in
      let witnesses =
        List.filter_map
          (fun (exp : El.Ast.exp) ->
            match exp.it with El.Ast.TextE name -> Some name | _ -> None)
          exps
      in
      if witnesses = [] || List.length witnesses <> List.length exps then
        Error "maude_trans expects constructor names as strings"
      else Ok (Some {trans_rule = rule; step = derived "step"; witnesses})
  | _ -> Error "relation has more than one maude_trans rule"

let classify_relation hints source mixop request_sort derived =
  let markers = Mixop.marker_positions in
  let arity = Xl.Mixop.arity mixop in
  let plain = markers Xl.Atom.[SqArrow; SqArrowStar] mixop in
  let execution =
    markers Xl.Atom.[SqArrow; SqArrowSub; SqArrowStar; SqArrowStarSub] mixop
  in
  (* A computed relation's outputs follow its one ~~ or : marker. *)
  let output = markers Xl.Atom.[Approx; ApproxSub; Colon; ColonSub] mixop in
  let plain_output = markers Xl.Atom.[Approx; Colon] mixop in
  let subsume = subsume_hint hints source derived in
  let trans = trans_hint hints source derived in
  match execution, plain, output, plain_output,
        relation_hint_names hints source, subsume, trans with
  | _, _, _, _, Error reason, _, _
  | _, _, _, _, _, Error reason, _
  | _, _, _, _, _, _, Error reason -> Error reason
  | [input_count], [plain_count], _, _, Ok [], Ok None, Ok None
    when input_count = plain_count && input_count > 0 && input_count < arity
         && markers Xl.Atom.[Approx; ApproxSub] mixop = [] ->
      Ok (Execution {request_sort = request_sort (); input_count})
  | [], [], [input_count], [plain_count], Ok ["maude_compute"], Ok subsume, Ok None
    when input_count = plain_count && input_count > 0 && input_count < arity ->
      Ok (Compute {input_count; subsume})
  | [], [], _, _, Ok ["maude_compute"], _, Ok None ->
      Error "maude_compute requires exactly one plain ~~ or : marker"
  | [], [], _, _, Ok ["maude_check"], Ok None, Ok trans -> Ok (Check {trans})
  | _, _, _, _, _, Ok (Some _), _ ->
      Error "maude_subsume requires a maude_compute relation"
  | _, _, _, _, _, _, Ok (Some _) ->
      Error "maude_trans requires a maude_check relation"
  | [], [], _, _, Ok [], _, _ ->
      Error "non-execution relation requires hint(maude_compute) or hint(maude_check)"
  | _ -> Error "relation has unsupported or conflicting markers or hints"

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
  List.filteri (fun position _ -> position <> index) items

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

let collect_membership_choices defs =
  List.concat_map
    (fun def ->
      match def.it with
      | DecD (id, _, _, clauses) ->
          List.filter_map (membership_choice_shape id.it) clauses
      | TypD _ | RelD _ | GramD _ | HintD _ | RecD _ -> [])
    defs


(* Stage 1: Maude names for declarations and constructors. A name that is
 * taken receives a numeric suffix, so names are chosen in a fixed order:
 * builtin definitions, then declarations and constructors in source order. *)

type registry =
  { entries : (name_kind * string * name) list ref
  ; used : StringSet.t ref
  }

let lookup entries kind source =
  List.find_map
    (fun (kind', source', name) ->
      if kind = kind' && source = source' then Some name else None)
    entries

let register registry kind source candidate =
  match lookup !(registry.entries) kind source with
  | Some name -> name
  | None ->
      let name = fresh_name registry.used candidate in
      registry.entries := (kind, source, name) :: !(registry.entries);
      name

let registered registry kind source =
  match lookup !(registry.entries) kind source with
  | Some name -> name
  | None -> invalid_arg ("unregistered source name " ^ source)

let register_names hints definitions script =
  let registry = {entries = ref []; used = ref reserved_names} in
  let builtin source = has_dec_hint_in hints source "builtin" in
  let add kind source candidate = ignore (register registry kind source candidate) in
  List.iter
    (fun (source, _, _) ->
      if builtin source then add DefName source (builtin_name source))
    definitions;
  let module Visitor = Il.Iter.Make (struct
    include Il.Iter.Skip

    let visit_mixop mixop =
      if not (Mixop.is_hole_only mixop) then
        add MixopName (Mixop.key mixop) (Mixop.name mixop)

    let visit_def def =
      match def.it with
      | TypD (id, _, _) -> add TypName id.it (sanitize id.it)
      | RelD (id, _, _, _, _) -> add RelName id.it (sanitize id.it)
      | DecD (id, _, _, _) ->
          add DefName id.it
            (if builtin id.it then builtin_name id.it else sanitize id.it)
      | GramD _ | HintD _ | RecD _ -> ()
  end)
  in
  Visitor.list Visitor.def script;
  registry


(* Stage 2: source variables, type parameters, and iterations, in source
 * order. Iterations are named in stage 3. *)

type occurrences =
  { observed : (id * sort * bool) list
  ; found_type_parameters : id list
  ; found_iterations : iteration list
  ; found_premise_iterations : premise_iteration list
  }

let collect_occurrences sort_metadata script =
  let iterations = ref [] in
  let premise_iterations = ref [] in
  let premise_count = ref 0 in
  let observed_variables = ref [] in
  let type_parameters = ref [] in
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
    | DefP _ -> invalid_arg "DefP must be removed by Def.specialize_script"
    | TypP id ->
        type_parameters := id :: !type_parameters;
        add_variable_with_sort id "SpectecType"
    | GramP _ -> ()

  and add_params params =
    List.iter add_param params
  in

  let scan_scope outer_params scope =
    let quants =
      match scope with
      | `Clause {it = DefD (quants, _, _, _); _} -> quants
      | `Rule {it = RuleD (_, quants, _, _, _); _} -> quants
      | `Instance {it = InstD (quants, _, _); _} -> quants
      | `Field (_, (_, quants, _), _) | `Case (_, (_, quants, _), _) -> quants
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
    let module Types = Il.Iter.Make (struct
      include Il.Iter.Skip
      let visit_typ = mark_type
    end) in
    let module ScopeVisitor = Il.Iter.Make (struct
      include Il.Iter.Skip

      let visit_exp exp = visit_noted_type mark_type Types.exp exp.note
      let visit_typ = mark_type
      let visit_path path = visit_noted_type mark_type Types.exp path.note
    end)
    in
    begin match scope with
    | `Clause clause -> ScopeVisitor.clause clause
    | `Rule rule -> ScopeVisitor.rule rule
    | `Instance inst -> ScopeVisitor.inst inst
    | `Field field -> ScopeVisitor.typfield field
    | `Case case -> ScopeVisitor.typcase case
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

  (* Captures are computed when an iteration is visited, from the type
   * parameters collected so far. This is complete because Il.Iter calls
   * visit_def before visiting the definition's contents, and visit_def
   * (add_def_variables) registers every type parameter of the definition
   * and of its rules, clauses, and instances. *)
  let add_iteration owner body iterexp =
    iterations :=
      { name = iteration_base_name body
      ; tail_name = ""
      ; projector_name = ""
      ; projector_tail_name = ""
      ; owner
      ; body
      ; iterexp
      ; captures = capture_exp_variables
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
      ; owner
      ; premise
      ; body
      ; iterexp
      ; captures = capture_premise_variables
          !type_parameters body iterexp
      }
      :: !premise_iterations
  in

  let current_owner = ref OtherOwner in
  let module VariableVisitor = Il.Iter.Make (struct
    include Il.Iter.Skip

    let visit_def def =
      current_owner :=
        begin match def.it with
        | RelD (id, _, _, _, _) -> RelationOwner id.it
        | DecD (id, _, _, _) -> DefinitionOwner id.it
        | TypD _ | GramD _ | HintD _ | RecD _ -> OtherOwner
        end;
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

  { observed = List.rev !observed_variables
  ; found_type_parameters = !type_parameters
  ; found_iterations = List.rev !iterations
  ; found_premise_iterations = List.rev !premise_iterations
  }


(* Stage 3: Maude names for variables and generated helpers. *)

(* Variable names may repeat declaration names; they are chosen from a copy
 * of the names used so far. *)
let name_variables used observed =
  let named, anonymous =
    List.partition (fun (_, _, anonymous) -> not anonymous) observed
  in
  let exact, renamed =
    List.partition (fun (id, _, _) -> id.it = variable_base id.it) named
  in
  let used = ref used in
  let variables =
    exact @ renamed
    |> List.map (fun (id, sort, _) ->
         (id.it, sort), fresh_variable_name used (variable_base id.it))
  in
  let anonymous_variables =
    anonymous
    |> List.mapi (fun index (id, sort, _) ->
         id, sort,
         fresh_variable_name used ("PARAM" ^ string_of_int (index + 1)))
  in
  variables, anonymous_variables

let name_iterations used iterations =
  iterations
  |> List.map (fun (iteration : iteration) ->
       let name =
         fresh used (fun index -> "-" ^ string_of_int index) iteration.name
       in
       { iteration with
         name
       ; tail_name = fresh_name used (name ^ "-tail")
       ; projector_name = fresh_name used ("project-" ^ name)
       ; projector_tail_name = fresh_name used ("project-" ^ name ^ "-tail")
       })

let name_premise_iterations used premise_iterations =
  premise_iterations
  |> List.map (fun (iteration : premise_iteration) ->
       let name = fresh_name used iteration.name in
       let _, generators = iteration.iterexp in
       let output_names =
         List.mapi
           (fun position _ ->
             let output =
               fresh_name used (name ^ "-output-" ^ string_of_int (position + 1))
             in
             output, fresh_name used (output ^ "-tail"))
           generators
       in
       {iteration with name; tail_name = fresh_name used (name ^ "-tail"); output_names})

let name_membership_choices registry choices =
  choices
  |> List.map (fun choice ->
       let definition_name = registered registry DefName choice.definition in
       let position = choice.clause.at.left in
       let candidate =
         Printf.sprintf "%s-choice-%d-%d"
           definition_name position.line position.column
       in
       {choice with helper_name = fresh_name registry.used candidate})


(* Generated Maude sorts for definitions evaluated by rewriting. *)
let name_rewrite_sorts registry hints definitions membership_choices =
  let choice_definitions =
    membership_choices
    |> List.map (fun choice -> choice.definition)
    |> StringSet.of_list
  in
  definitions
  |> List.filter_map (fun (source, _, _) ->
       let is_choice = StringSet.mem source choice_definitions in
       if has_dec_hint_in hints source "maude_rule" || is_choice then
         let name = registered registry DefName source in
         let suffix = if is_choice then "-Request" else "-Config" in
         Some (source, fresh_name registry.used (name ^ suffix))
       else
         None)


(* Stage 4: the kind of each relation (section 2 of TRANSLATION_MAP.md) and
 * the names that kind requires. *)

let classify_relations registry hints relations =
  List.fold_right
    (fun (source, mixop) (policies, unsupported) ->
      let request_sort () =
        let name = registered registry RelName source in
        fresh_name registry.used (name ^ "-Request")
      in
      let derived suffix =
        fresh_name registry.used (registered registry RelName source ^ "-" ^ suffix)
      in
      match classify_relation hints source mixop request_sort derived with
      | Ok policy -> (source, policy) :: policies, unsupported
      | Error reason -> policies, (source, reason) :: unsupported)
    relations ([], [])

(* One enabled-predicate name per rule of an execution relation, used when
 * an ElsePr cannot state the negation of an earlier rule directly. *)
let name_enabled_helpers registry relation_policies defs =
  defs
  |> List.concat_map (fun def ->
       match def.it with
       | RelD (id, _, _, _, rules) ->
           begin match List.assoc_opt id.it relation_policies with
           | Some (Execution _) ->
               let relation = registered registry RelName id.it in
               List.mapi
                 (fun ordinal _ ->
                   let candidate =
                     Printf.sprintf "%s-enabled-%d" relation (ordinal + 1)
                   in
                   (id.it, ordinal), fresh_name registry.used candidate)
                 rules
           | Some (Compute _ | Check _)
           | None -> []
           end
       | TypD _ | DecD _ | GramD _ | HintD _ | RecD _ -> [])


(* Stage 5: a definition with a clause that uses an untranslated relation
 * gets no body. *)
let unsupported_definitions unsupported_relations defs =
  let unsupported_relation_names =
    List.map fst unsupported_relations |> StringSet.of_list
  in
  let uses_unsupported clause =
    let unsupported = ref false in
    let module Visitor = Il.Iter.Make (struct
      include Il.Iter.Skip
      let visit_prem prem =
        match prem.it with
        | RulePr (target, _, _, _)
          when StringSet.mem target.it unsupported_relation_names ->
            unsupported := true
        | RulePr _ | IfPr _ | LetPr _ | ElsePr
        | IterPr _ | NegPr _ -> ()
    end)
    in
    Visitor.clause clause;
    !unsupported
  in
  defs
  |> List.filter_map (fun def ->
       match def.it with
       | DecD (id, _, _, clauses) when List.exists uses_unsupported clauses ->
           Some id.it
       | TypD _ | RelD _ | DecD _ | GramD _ | HintD _ | RecD _ -> None)
  |> StringSet.of_list


let scan script =
  let type_env = Il.Env.env_of_script script in
  let sort_metadata = Hintd.scan_sorts script in
  let defs = List.concat_map flatten script in
  let type_definitions =
    List.filter_map
      (fun def ->
        match def.it with
        | TypD (id, _, insts) -> Some (id.it, insts)
        | RelD _ | DecD _ | GramD _ | HintD _ | RecD _ -> None)
      defs
  in
  let definitions =
    List.filter_map
      (fun def ->
        match def.it with
        | DecD (id, params, result, _) -> Some (id.it, params, result)
        | TypD _ | RelD _ | GramD _ | HintD _ | RecD _ -> None)
      defs
  in
  let relations =
    List.filter_map
      (fun def ->
        match def.it with
        | RelD (id, _, mixop, _, _) -> Some (id.it, mixop)
        | TypD _ | DecD _ | GramD _ | HintD _ | RecD _ -> None)
      defs
  in
  let hints = collect_hints script in
  let membership_choices = collect_membership_choices defs in
  let inverses =
    definitions
    |> List.filter_map (fun (source, _, _) ->
         inverse_hint hints source
         |> Option.map (fun inverse ->
              source,
              validate_inverse definitions source inverse))
  in
  let registry = register_names hints definitions script in
  let occurrences = collect_occurrences sort_metadata script in
  let variables, anonymous_variables =
    name_variables !(registry.used) occurrences.observed
  in
  let iterations = name_iterations registry.used occurrences.found_iterations in
  let premise_iterations =
    name_premise_iterations registry.used occurrences.found_premise_iterations
  in
  let membership_choices =
    name_membership_choices registry membership_choices
  in
  let helper_names =
    helper_names iterations premise_iterations membership_choices
  in
  let rewrite_sorts =
    name_rewrite_sorts registry hints definitions membership_choices
  in
  let relation_policies, unsupported_relations =
    classify_relations registry hints relations
  in
  let execution_input_count source =
    match List.assoc_opt source relation_policies with
    | Some (Execution {input_count; _}) -> Some input_count
    | Some (Compute _ | Check _)
    | None -> None
  in
  let heatcool = Hintd.scan_heatcool sort_metadata execution_input_count in
  let contexts = Hintd.scan_contexts sort_metadata execution_input_count heatcool in
  let relation_enabled_helpers =
    name_enabled_helpers registry relation_policies defs
  in
  let unsupported_definition_names =
    unsupported_definitions unsupported_relations defs
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
    | Some (Execution _ | Compute _ | Check _) -> true
    | None -> false
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
  let reserved =
    StringSet.diff !(registry.used)
      (StringSet.of_list (List.map fst helper_names))
  in
  { type_env
  ; input_types = None
  ; sort_metadata
  ; contexts
  ; heatcool
  ; iterations
  ; premise_iterations
  ; hints
  ; names = List.rev !(registry.entries)
  ; relation_policies
  ; relation_enabled_helpers
  ; unsupported_relations
  ; definition_bodies
  ; rewrite_sorts
  ; membership_choices
  ; type_definitions
  ; variables
  ; anonymous_variables
  ; type_parameters = occurrences.found_type_parameters
  ; inverses
  ; requests = Hashtbl.create 64
  ; helper_names
  ; reserved
  }


let find_name index kind source = lookup index.names kind source

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
      | Some (Compute _ | Check _)
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

let helper_names index = index.helper_names

(* The final name of a helper: its base, or with a "-N" suffix if that is
 * already in use. A base that is a backend name gets the spectec- prefix. *)
let fresh_helper_name index used candidate =
  let candidate =
    if StringSet.mem candidate reserved_names then "spectec-" ^ candidate
    else candidate
  in
  used := StringSet.union index.reserved !used;
  fresh used (fun index -> "-" ^ string_of_int index) candidate

let request index name kind = Hashtbl.replace index.requests (name, kind) ()
let requested index name kind = Hashtbl.mem index.requests (name, kind)

let requested_outputs index name =
  Hashtbl.fold
    (fun (name', kind) () positions ->
      match kind with
      | OutputHelper position when name' = name -> position :: positions
      | OutputHelper _ | ForwardHelper | ProjectorHelper | CheckHelper -> positions)
    index.requests []
  |> List.sort_uniq compare


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

let heatcool index = index.heatcool

let is_heatcool_rule index relation rule =
  List.exists
    (fun (heated : Hintd.heatcool) ->
      heated.source.id.it = relation.it && heated.rule == rule)
    index.heatcool
