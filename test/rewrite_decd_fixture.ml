open Il.Ast
open Translator
open Util.Source

let region = no_region
let id text = text $ region
let nat_typ = NumT `NatT $ region
let seq_typ = IterT (nat_typ, List) $ region
let result_typ = TupT [ id "state", nat_typ; id "values", seq_typ ] $ region
let relation_typ =
  TupT
    [ id "state-in", nat_typ
    ; id "expr", nat_typ
    ; id "state-out", nat_typ
    ; id "value", nat_typ
    ]
  $ region

let var ?(typ = nat_typ) text = VarE (id text) $$ region % typ
let nat value = NumE (`Nat (Z.of_int value)) $$ region % nat_typ
let exp_param name typ = ExpP (id name, typ) $ region
let exp_arg exp = ExpA exp $ region

let execution_mixop =
  let marker = Xl.Atom.SqArrow $$ region % Xl.Atom.info "rewrite-fixture" in
  Xl.Mixop.Infix (Xl.Mixop.Arg (), marker, Xl.Mixop.Arg ())

let transition name state expr next value =
  RuleD
    (id name, [], execution_mixop,
     TupE [ nat state; nat expr; nat next; nat value ] $$ region % relation_typ,
     [])
  $ region

let annotation relation_id =
  let hint =
    { hintid = id "maude_equational_view"
    ; hintexp = El.Ast.BoolE true $ region
    }
  in
  HintD (RelH (id relation_id, [ hint ]) $ region) $ region

let relation_id = id "renamed_eval"
let definition_id = id "renamed_sequence"

let script =
  let state = var "state" in
  let expr = var "expr" in
  let rest = var ~typ:seq_typ "rest" in
  let next = var "next" in
  let value = var "value" in
  let final = var "final" in
  let values = var ~typ:seq_typ "values" in
  let empty = ListE [] $$ region % seq_typ in
  let relation_premise =
    RulePr
      (relation_id, [], execution_mixop,
       TupE [ state; expr; next; value ] $$ region % relation_typ)
    $ region
  in
  let recursive_call =
    CallE
      (definition_id, [ exp_arg next; exp_arg rest ])
    $$ region % result_typ
  in
  let recursive_result = TupE [ final; values ] $$ region % result_typ in
  let recursive_premise =
    IfPr
      (CmpE (`EqOp, `NatT, recursive_result, recursive_call)
       $$ region % (BoolT $ region))
    $ region
  in
  let empty_clause =
    DefD
      ([ exp_param "state" nat_typ ],
       [ exp_arg state; exp_arg empty ],
       TupE [ state; empty ] $$ region % result_typ,
       [])
    $ region
  in
  let cons_head = ListE [ expr ] $$ region % seq_typ in
  let value_head = ListE [ value ] $$ region % seq_typ in
  let cons = CatE (cons_head, rest) $$ region % seq_typ in
  let value_cons = CatE (value_head, values) $$ region % seq_typ in
  let recursive_clause =
    DefD
      ([ exp_param "state" nat_typ
       ; exp_param "expr" nat_typ
       ; exp_param "rest" seq_typ
       ; exp_param "next" nat_typ
       ; exp_param "value" nat_typ
       ; exp_param "final" nat_typ
       ; exp_param "values" seq_typ
       ],
       [ exp_arg state; exp_arg cons ],
       TupE [ final; value_cons ] $$ region % result_typ,
       [ relation_premise; recursive_premise ])
    $ region
  in
  [ RelD
      (relation_id, [], execution_mixop, relation_typ,
       [ transition "first" 0 10 1 100
       ; transition "second" 1 20 2 200
       ])
    $ region
  ; annotation relation_id.it
  ; DecD
      (definition_id,
       [ exp_param "state" nat_typ; exp_param "exprs" seq_typ ],
       result_typ,
       [ empty_clause; recursive_clause ])
    $ region
  ]

let () =
  let result = Driver.translate script in
  let fatal =
    result.Driver.diagnostics
    |> List.filter (fun diagnostic ->
      Diagnostics.is_fatal diagnostic
      && diagnostic.Diagnostics.constructor <> "BuiltinBackend/representation")
  in
  if fatal <> [] then (
    prerr_endline (Diagnostics.render_all fatal);
    exit 1);
  print_string (Driver.emit result);
  Printf.printf "rew %s(0, 10 20) .\n" (Naming.definition_op definition_id)
