type 'a pending =
  { key : string
  ; value : 'a
  }

type ('a, 'b) result =
  { completed : 'b list
  ; stalled : 'a pending list
  }

val run :
  pending:(unit -> 'a pending list) ->
  materialize:('a -> 'b option) ->
  ('a, 'b) result
