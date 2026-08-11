type t =
  | Ordinary
  | Canonical_runs

let key = function
  | Ordinary -> "ordinary"
  | Canonical_runs -> "canonical-runs"
