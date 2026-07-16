open Il.Ast
open Util.Source

type relation_kind =
  | Execution
  | Execution_star
  | Deterministic_candidate
  | Predicate_candidate
  | Unknown

let string_of_relation_kind = function
  | Execution -> "execution"
  | Execution_star -> "execution-star"
  | Deterministic_candidate -> "deterministic-candidate"
  | Predicate_candidate -> "predicate-candidate"
  | Unknown -> "unknown"

let mixop_has_atom predicate mixop =
  Xl.Mixop.flatten mixop
  |> List.exists (fun atoms ->
    atoms |> List.exists (fun atom -> predicate atom.it))

let classify_mixop mixop =
  let markers =
    [ ( mixop_has_atom (function Xl.Atom.SqArrow -> true | _ -> false) mixop
      , Execution )
    ; ( mixop_has_atom (function Xl.Atom.SqArrowStar -> true | _ -> false) mixop
      , Execution_star )
    ; ( mixop_has_atom
          (function Xl.Atom.Approx | Xl.Atom.ApproxSub -> true | _ -> false)
          mixop
      , Deterministic_candidate )
    ; ( mixop_has_atom
          (function
            | Xl.Atom.Turnstile | Xl.Atom.TurnstileSub | Xl.Atom.Sub -> true
            | _ -> false)
          mixop
      , Predicate_candidate )
    ]
    |> List.filter_map (fun (present, kind) -> if present then Some kind else None)
  in
  match markers with
  | [ kind ] -> kind
  | [] | _ :: _ :: _ -> Unknown

let string_of_mixop = Xl.Mixop.to_string

let eq_mixop = Xl.Mixop.eq

let mixop_shape_text mixop =
  string_of_mixop mixop

let exp_components exp =
  match exp.it with
  | TupE components -> components
  | _ -> [ exp ]

let exp_components_for_count expected_count exp =
  match expected_count, exp.it with
  | 1, _ -> Some [ exp ]
  | _, TupE components when List.length components = expected_count -> Some components
  | _, _ -> None
