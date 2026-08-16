open Util.Source
open Il.Ast

let rec translate def =
  match def.it with
  | TypD (id, params, insts) -> Typd.translate id params insts
  | DecD (id, params, typ, clauses) -> Decd.translate id params typ clauses
  | RelD (id, params, mixop, typ, rules) -> Reld.translate id params mixop typ rules
  | GramD _ -> []
  | HintD _ -> []
  | RecD defs -> List.concat_map translate defs

let translate_script script =
  let index = Prescan.scan script in
  let definitions = List.concat_map translate script in
  let iterations =
    Iter.translate_all Exp.translate Typ.translate_sort index
  in
  definitions @ iterations
