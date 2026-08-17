open Util.Source
open Il.Ast

let rec translate index def =
  match def.it with
  | TypD (id, params, insts) -> Typd.translate index id params insts
  | DecD (id, params, typ, clauses) -> Decd.translate index id params typ clauses
  | RelD (id, params, mixop, typ, rules) ->
      Reld.translate index id params mixop typ rules
  | GramD _ -> []
  | HintD _ -> []
  | RecD defs -> List.concat_map (translate index) defs

let translate_script script =
  let index = Prescan.scan script in
  let definitions = List.concat_map (translate index) script in
  let iterations =
    Iter.translate_all Term.translate_exp Term.translate_sort index
  in
  let premise_iterations =
    let translate_body bound body =
      let result = Prem.translate_all index ~bound [body] in
      result.conditions, result.otherwise
    in
    Iter.translate_premise_all translate_body Term.translate_sort index
  in
  let declarations, definitions =
    List.partition (function Maude_il.OpDecl _ -> true | _ -> false) definitions
  in
  let iteration_declarations, iterations =
    List.partition (function Maude_il.OpDecl _ -> true | _ -> false) iterations
  in
  let premise_declarations, premise_iterations =
    List.partition
      (function Maude_il.OpDecl _ -> true | _ -> false)
      premise_iterations
  in
  declarations @ iteration_declarations @ premise_declarations
  @ definitions @ iterations @ premise_iterations
