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

val raise : ?region:Wasm.Source.region -> kind -> string -> string -> 'a
val to_string : t -> string
