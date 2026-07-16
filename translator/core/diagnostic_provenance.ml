let enclosing ~context origin =
  match context with
  | _ :: _ -> context
  | [] -> origin.Origin.path

let enclosing_with ~context origin supplemental =
  enclosing ~context origin @ [ supplemental ]
