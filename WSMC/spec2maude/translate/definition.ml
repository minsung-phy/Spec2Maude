open Il.Ast

let rec translate def =
  match def.it with
  | TypD (id, params, insts) -> TypD.translate id params insts
  | DecD (id, params, typ, clauses) -> DecD.translate id params typ clauses
  | RelD (id, params, mixop, typ, rules) -> RelD.translate id params mixop typ rules
  | GramD _ -> []
  | HintD _ -> []
  | RecD defs -> List.concat_map translate defs

let translate_script script = List.concat_map translate script
