open Il.Ast
open Util.Source

(* The certificate recognizes the source context rule

     values* focus suffix  ~>  values* focus' suffix

   together with its unique recursive execution premise.  Consumers may use
   the certificate instead of rediscovering that structural fact from emitted
   Maude terms. *)

type t =
  { prefix_source : string
  ; focus_source : string
  ; suffix_source : string
  ; output_focus_source : string
  ; value_source_typ : typ
  ; value_target_typ : typ
  }

type list_segment =
  { body : exp
  ; binder : id
  ; source : id
  ; whole : exp
  }

type subtype_segment =
  { segment : list_segment
  ; source_typ : typ
  ; target_typ : typ
  }

type config =
  { mixop : mixop
  ; state : exp
  ; instrs : exp
  }

let prefix_source certificate = certificate.prefix_source
let focus_source certificate = certificate.focus_source
let suffix_source certificate = certificate.suffix_source
let output_focus_source certificate = certificate.output_focus_source
let value_source_typ certificate = certificate.value_source_typ
let value_target_typ certificate = certificate.value_target_typ

let same_id left right = left.it = right.it

let list_segment exp =
  match exp.it with
  | IterE (body, (List, [ binder, { it = VarE source; _ } ])) ->
    Some { body; binder; source; whole = exp }
  | _ -> None

let plain_segment exp =
  match list_segment exp with
  | Some ({ body = { it = VarE item; _ }; binder; _ } as segment)
    when same_id item binder -> Some segment
  | Some _ | None -> None

let subtype_segment exp =
  match list_segment exp with
  | Some
      ({ body = { it = SubE ({ it = VarE item; _ }, source_typ, target_typ); _ }
       ; binder
       ; _
       } as segment)
    when same_id item binder ->
      Some { segment; source_typ; target_typ }
  | Some _ | None -> None

let cat_segments exp =
  let rec collect acc exp =
    match exp.it with
    | CatE (left, right) -> collect (collect acc right) left
    | _ -> exp :: acc
  in
  collect [] exp

let config exp =
  match exp.it with
  | CaseE (mixop, { it = TupE [ state; instrs ]; _ }) ->
    Some { mixop; state; instrs }
  | _ -> None

let context_head exp =
  match exp.it with
  | TupE [ input; output ] ->
    (match config input, config output with
    | Some input, Some output ->
      (match cat_segments input.instrs, cat_segments output.instrs with
      | [ prefix; focus; suffix ], [ output_prefix; output_focus; output_suffix ]
        when Il.Eq.eq_exp prefix output_prefix
             && Il.Eq.eq_exp suffix output_suffix ->
        (match
           subtype_segment prefix,
           plain_segment focus,
           plain_segment suffix,
           plain_segment output_focus
         with
        | Some prefix, Some focus, Some suffix, Some output_focus ->
          Some (input, output, prefix, focus, suffix, output_focus)
        | _ -> None)
      | _ -> None)
    | _ -> None)
  | _ -> None

let recursive_context relation_id rule_mixop input output focus output_focus prem =
  match prem.it with
  | RulePr (id, [], mixop, exp)
    when same_id relation_id id && Il.Eq.eq_mixop rule_mixop mixop ->
    (match exp.it with
    | TupE [ recursive_input; recursive_output ] ->
      (match config recursive_input, config recursive_output with
      | Some recursive_input, Some recursive_output ->
        Il.Eq.eq_mixop input.mixop recursive_input.mixop
        && Il.Eq.eq_mixop output.mixop recursive_output.mixop
        && Il.Eq.eq_exp input.state recursive_input.state
        && Il.Eq.eq_exp output.state recursive_output.state
        && Il.Eq.eq_exp focus.whole recursive_input.instrs
        && Il.Eq.eq_exp output_focus.whole recursive_output.instrs
      | _ -> false)
    | _ -> false)
  | RulePr _ | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> false

let certify relation_id rule =
  match rule.it with
  | RuleD (_, _, rule_mixop, head, prems) ->
    (match context_head head with
    | Some (input, output, prefix, focus, suffix, output_focus) ->
      let recursive_premises =
        prems
        |> List.filter (fun prem ->
             recursive_context
               relation_id rule_mixop input output focus output_focus prem)
      in
      (match recursive_premises with
      | [ _ ] ->
        Some
          { prefix_source = prefix.segment.source.it
          ; focus_source = focus.source.it
          ; suffix_source = suffix.source.it
          ; output_focus_source = output_focus.source.it
          ; value_source_typ = prefix.source_typ
          ; value_target_typ = prefix.target_typ
          }
      | [] | _ :: _ :: _ -> None)
    | None -> None)
