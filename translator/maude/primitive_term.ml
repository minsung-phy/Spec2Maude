open Maude_ir

let bool term = App ("bool", [ term ])

let text text =
  App ("text", [ Const ("\"" ^ String.escaped text ^ "\"") ])

let number num =
  match Xl.Num.to_string num with
  | text when String.length text > 0 && text.[0] = '+' ->
    Const (String.sub text 1 (String.length text - 1))
  | text -> Const text
