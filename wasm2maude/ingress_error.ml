type kind =
  | Io
  | Syntax
  | Invalid
  | Unsupported

type t = {
  kind : kind;
  source : string;
  region : Wasm.Source.region option;
  message : string;
}

exception Error of t

let raise ?region kind source message =
  Stdlib.raise (Error {kind; source; region; message})

let string_of_kind = function
  | Io -> "I/O error"
  | Syntax -> "syntax error"
  | Invalid -> "invalid module"
  | Unsupported -> "unsupported"

let to_string {kind; source; region; message} =
  let where =
    match region with
    | None -> source
    | Some at -> Wasm.Source.string_of_region at
  in
  Printf.sprintf "%s: %s: %s" where (string_of_kind kind) message
