type producer =
  | Deterministic_output
  | Equality_value of Maude_ir.term * Maude_ir.eq_condition list

type t =
  { typ : Il.Ast.typ
  ; producer : producer
  }

type value =
  { source_typ : Il.Ast.typ
  ; result : Expr_result.result
  }

let result_has_fatal (result : Expr_result.result) =
  List.exists Diagnostics.is_fatal result.diagnostics

let deterministic_output ~output_typ ~(pattern : Il.Ast.exp) =
  if Il.Eq.eq_typ output_typ pattern.note then
    Some { typ = output_typ; producer = Deterministic_output }
  else
    None

(* This is the only equality producer admitted by the certificate.  The
   expression lowerer establishes the elaborated note type exactly when its
   emitted value guards succeed; callers cannot certify an arbitrary result. *)
let lower_equality_value ctx env origin (subject : Il.Ast.exp) =
  { source_typ = subject.note
  ; result = Expr_translate.lower_value ctx env origin subject
  }

let value_result value = value.result

let equality_value ~value ~(pattern : Il.Ast.exp) =
  if not (Il.Eq.eq_typ value.source_typ pattern.note)
     || result_has_fatal value.result
  then
    None
  else
    match value.result.term with
    | Some term ->
      Some
        { typ = value.source_typ
        ; producer = Equality_value (term, value.result.guards)
        }
    | None -> None

let matches_result certificate (value : Expr_result.result) =
  match certificate.producer, value.term with
  | Equality_value (term, guards), Some value_term ->
    term = value_term && guards = value.guards && not (result_has_fatal value)
  | Equality_value _, None | Deterministic_output, _ -> false

let lower_pattern_named certificate names ctx env origin (pattern : Il.Ast.exp) =
  if Il.Eq.eq_typ certificate.typ pattern.note then
    Expr_translate.lower_typed_subject_pattern_named
      names ctx env origin pattern
  else
    Expr_translate.lower_pattern_with_bindings_named
      names ctx env origin pattern
