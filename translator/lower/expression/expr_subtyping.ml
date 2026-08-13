open Il.Ast
open Maude_ir
open Expr_diagnostic
open Expr_result
open Util.Source

type env = Expr_env.t

type callbacks =
  { lower_value : Context.t -> env -> Origin.t -> exp -> result
  ; witness_of_typ :
      Context.t -> env -> Origin.t -> typ -> term option * Diagnostics.t list
  ; carrier_sort : Context.t -> typ -> sort option
  }

let plan ctx source_typ target_typ =
  Subtype_plan.make
    ~il_env:(Context.il_env ctx)
    ~source_index:(Context.source_index ctx)
    ~constructors:(Context.constructors ctx)
    ~static_typ_env:(Context.static_typ_env ctx)
    source_typ target_typ

let plan_diagnostic ctx origin exp error =
  let reason, suggestion = Subtype_plan.describe_error error in
  unsupported
    ~ctx ~origin ~constructor:"Expr/SubE/injection"
    ~source_echo:(source_echo_exp exp)
    ~reason ~suggestion ()

let accept_injection ctx origin injection =
  let request = Helper_request.subtype_injection_request ~origin injection in
  let forward = Helper.request (Context.helpers ctx) request in
  forward

let direct_roundtrip env inner inner_term injection =
  match inner.it with
  | VarE id ->
    (match
       Expr_env.find env id.it,
       Expr_env.find_subtype_roundtrip env id.it
     with
    | Some binding, Some roundtrip when binding.term = inner_term ->
      Pattern_subtyping.reuse_direct
        roundtrip ~source:binding.term injection
    | _ -> None)
  | _ -> None

let lower_with_type_guards
    callbacks ctx env origin exp typs inner_result term =
  let add_guard (guards, diagnostics, failed) typ =
    let witness, witness_diagnostics =
      callbacks.witness_of_typ ctx env origin typ
    in
    let carrier =
      match typ.it with
      | IterT _ -> Some (sort "SpectecTerminals")
      | _ -> callbacks.carrier_sort ctx typ
    in
    match witness, carrier with
    | Some witness, Some _
      when not (List.exists Diagnostics.is_fatal witness_diagnostics) ->
      let guard = BoolCond (Typecheck_term.typecheck term witness) in
      let guards = if List.mem guard guards then guards else guard :: guards in
      guards, List.rev_append witness_diagnostics diagnostics, failed
    | _ ->
      guards,
      List.rev_append
        ([ unsupported
             ~ctx ~origin ~constructor:"Expr/SubE/type-guard"
             ~source_echo:(source_echo_exp exp)
             ~reason:"SubE source or target witness/carrier could not be lowered"
             ~suggestion:
               "Extend both source and target type witnesses before emitting this coercion"
             ()
         ] @ witness_diagnostics)
        diagnostics,
      true
  in
  let guards, diagnostics, failed =
    List.fold_left add_guard (List.rev inner_result.guards, [], false) typs
  in
  { term = if failed then None else Some term
  ; guards = List.rev guards
  ; diagnostics = inner_result.diagnostics @ List.rev diagnostics
  }

let lower_with_target_guard
    callbacks ctx env origin exp target_typ inner_result term =
  lower_with_type_guards
    callbacks ctx env origin exp [ target_typ ] inner_result term

let lower_atomic callbacks ctx env origin exp inner source_typ target_typ =
  let inner_result = callbacks.lower_value ctx env origin inner in
  let coercion = plan ctx source_typ target_typ in
  match inner_result.term, coercion with
  | Some inner_term, Ok (Subtype_plan.Injection injection) ->
    (match direct_roundtrip env inner inner_term injection with
    | Some reuse ->
      { term = Some reuse.Pattern_subtyping.target
      ; guards = inner_result.guards @ [ reuse.required_guard ]
      ; diagnostics = inner_result.diagnostics
      }
    | None ->
      let term =
        App (accept_injection ctx origin injection, [ inner_term ])
      in
      lower_with_target_guard
        callbacks ctx env origin exp target_typ inner_result term)
  | Some inner_term, Ok Subtype_plan.Identity ->
    lower_with_type_guards
      callbacks ctx env origin exp [ source_typ ] inner_result inner_term
  | Some _, Error error ->
    { term = None
    ; guards = inner_result.guards
    ; diagnostics = inner_result.diagnostics @ [ plan_diagnostic ctx origin exp error ]
    }
  | None, _ ->
    { term = None
    ; guards = inner_result.guards
    ; diagnostics = inner_result.diagnostics
    }

(* This is the component-wise SubE transformation from SpecTec's
   [middlend/sub.ml]: products are coerced component by component and
   iterations are mapped with the same iterator and source generator. *)
let lower_tuple callbacks ctx env origin exp inner =
  let inner_result = callbacks.lower_value ctx env origin inner in
  { term = None
  ; guards = inner_result.guards
  ; diagnostics =
      inner_result.diagnostics
      @ [ unsupported
            ~ctx ~origin ~constructor:"Expr/SubE/tuple"
            ~source_echo:(source_echo_exp exp)
            ~reason:
              "tuple SubE needs dependent component substitution, but general tuple ProjE lowering is not available"
            ~suggestion:
              "Keep tuple SubE unsupported until component projections preserve dependent field bindings"
            ()
        ]
  }

let fresh_iter_binder inner source_typ target_typ =
  let free_varids sets = Il.Free.Set.elements sets.Il.Free.varid in
  let used =
    free_varids (Il.Free.free_exp inner)
    @ free_varids (Il.Free.free_typ source_typ)
    @ free_varids (Il.Free.free_typ target_typ)
  in
  let rec pick index =
    let candidate =
      if index = 1 then "sub_elem" else "sub_elem" ^ string_of_int index
    in
    if List.mem candidate used then pick (index + 1) else candidate
  in
  pick 1 $ inner.at

let lower_iter callbacks ctx env origin exp inner source_typ target_typ iter =
  match plan ctx source_typ target_typ with
  | Ok Subtype_plan.Identity ->
    let inner_result = callbacks.lower_value ctx env origin inner in
    (match inner_result.term with
    | Some term ->
      lower_with_type_guards
        callbacks ctx env origin exp [ inner.note ] inner_result term
    | None -> inner_result)
  | Ok (Subtype_plan.Injection _) | Error _ ->
    let binder = fresh_iter_binder inner source_typ target_typ in
    let item = VarE binder $$ inner.at % source_typ in
    let body =
      if Il.Eq.eq_typ source_typ target_typ then item
      else SubE (item, source_typ, target_typ) $$ exp.at % target_typ
    in
    let mapped = IterE (body, (iter, [ binder, inner ])) $$ exp.at % exp.note in
    callbacks.lower_value ctx env origin mapped

let same_sequence_representation source_iter target_iter =
  match source_iter, target_iter with
  | List, List | ListN _, List -> true
  | _ -> Il.Eq.eq_iter source_iter target_iter

let lower callbacks ctx env origin exp inner source_typ target_typ =
  match source_typ.it, target_typ.it with
  | TupT source_fields, TupT target_fields
    when List.length source_fields = List.length target_fields ->
    lower_tuple callbacks ctx env origin exp inner
  | IterT (source_typ, source_iter), IterT (target_typ, target_iter)
    when same_sequence_representation source_iter target_iter ->
    lower_iter callbacks ctx env origin exp inner source_typ target_typ source_iter
  | _ ->
    lower_atomic callbacks ctx env origin exp inner source_typ target_typ
