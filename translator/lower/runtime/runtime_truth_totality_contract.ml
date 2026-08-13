type t =
  | Total
  | Observer

(* Closed backend contract, not a source-name heuristic.  Each entry denotes
   an emitted Maude operator whose equations are total at this exact arity. *)
let classify ~name ~arity =
  match name, arity with
  | ( "typecheck" | "typecheckOptSeq"
    | "typecheckSeqOpt" | "typecheckNestedSeq" ), 2 ->
    Some Observer
  | ("isOpt" | "allOpt" | "len" | "ratIsInt" | "not_"), 1 ->
    Some Total
  | ( "allLen" | "contains" | "_==_" | "_=/=_" | "_<_" | "_<=_"
    | "_>_" | "_>=_" | "_and_" | "_or_" ), 2 ->
    Some Total
  | _ -> None

let is_total ~name ~arity = Option.is_some (classify ~name ~arity)

let is_observer ~name ~arity =
  match classify ~name ~arity with
  | Some Observer -> true
  | Some Total | None -> false
