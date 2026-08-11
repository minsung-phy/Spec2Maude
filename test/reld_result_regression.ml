open Translator
open Maude_ir

let binding =
  let value = Var "VALUE" in
  let projection = App ("project", [ Var "INPUT" ]) in
  EqCondition (MatchCond (value, projection)), value, projection

let () =
  let binding, value, projection = binding in
  let guard = EqCondition (BoolCond (App ("ready", [ value ]))) in
  let conditions =
    [ binding
    ; EqCondition (EqCond (value, projection))
    ; EqCondition (EqCond (projection, value))
    ; guard
    ; guard
    ]
  in
  match Reld_result.dedup_rule_conditions conditions with
  | [ binding'; guard' ] when binding' = binding && guard' = guard -> ()
  | _ -> failwith "rule-condition deduplication lost a binding or kept its equality"
