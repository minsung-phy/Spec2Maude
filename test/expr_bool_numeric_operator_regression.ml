open Il.Ast
open Translator
open Maude_ir
open Util.Source

let region = no_region
let nat_typ = NumT `NatT $ region
let bool_typ = BoolT $ region
let nat value = NumE (`Nat (Z.of_int value)) $$ region % nat_typ
let bool value = BoolE value $$ region % bool_typ
let origin = Origin.synthetic ~ast_constructor:"OperatorRegression" "operators"
let app name args = App (name, args)
let bool_term term = app "bool" [ term ]

let index = Analysis.Source_index.of_script []
let ctx = Context.create index (Builtin_registry.of_source_index index)

let check label expected_term expected_guards result =
  if result.Expr_result.diagnostics <> [] then
    failwith
      (label ^ " emitted diagnostics:\n"
       ^ Diagnostics.render_all result.diagnostics);
  if result.term <> Some expected_term then
    failwith (label ^ " emitted the wrong Maude term");
  if result.guards <> expected_guards then
    failwith (label ^ " emitted the wrong guards")

let callbacks =
  { Expr_bool_numeric.lower_value = Expr_translate.lower_value
  ; lower_sequence = Expr_translate.lower_sequence
  ; lower_call = (fun _ _ _ _ _ _ -> failwith "operator regression called a definition")
  ; witness_of_typ = (fun _ _ _ _ -> None, [])
  }

let direct_unary label op optyp result_typ operand expected =
  let exp = UnE (op, optyp, operand) $$ region % result_typ in
  Expr_bool_numeric.lower_unary_value
    callbacks ctx Expr_env.empty origin exp op operand
  |> check label expected []

let direct_binary label op optyp result_typ left right expected guards =
  let exp = BinE (op, optyp, left, right) $$ region % result_typ in
  Expr_bool_numeric.lower_binary_value
    callbacks ctx Expr_env.empty origin exp op left right
  |> check label expected guards

let nonzero term = BoolCond (app "_=/=_" [ term; Const "0" ])

let test_direct_operator_tables () =
  direct_unary "unary-not" `NotOp `BoolT bool_typ (bool true)
    (bool_term (app "~_" [ bool_term (Const "true") ]));
  direct_unary "unary-plus" `PlusOp `NatT nat_typ (nat 2) (Const "2");
  direct_unary "unary-minus" `MinusOp `NatT nat_typ (nat 2)
    (app "-_" [ Const "2" ]);
  let left = nat 4 and right = nat 2 in
  List.iter
    (fun (label, op, name, guards) ->
      direct_binary label op `NatT nat_typ left right
        (app name [ Const "4"; Const "2" ]) guards)
    [ "binary-add", `AddOp, "_+_", []
    ; "binary-sub", `SubOp, "_-_", []
    ; "binary-mul", `MulOp, "_*_", []
    ; "binary-div", `DivOp, "_/_", [ nonzero (Const "2") ]
    ; "binary-mod", `ModOp, "modNat", [ nonzero (Const "2") ]
    ; "binary-pow", `PowOp, "_^_", []
    ];
  let left = bool true and right = bool false in
  List.iter
    (fun (label, op, name) ->
      direct_binary label op `BoolT bool_typ left right
        (bool_term
           (app name [ bool_term (Const "true"); bool_term (Const "false") ]))
        [])
    [ "binary-and", `AndOp, "_/\\_"
    ; "binary-or", `OrOp, "_\\/_"
    ; "binary-impl", `ImplOp, "_=>_"
    ; "binary-equiv", `EquivOp, "_<=>_"
    ]

let test_numeric_guard_decisions () =
  let check_guard label exp expected guards =
    Expr_translate.lower_numeric_guard_value ctx Expr_env.empty origin exp
    |> check label expected guards
  in
  check_guard "guard-plus"
    (UnE (`PlusOp, `NatT, nat 2) $$ region % nat_typ)
    (Const "2") [];
  check_guard "guard-minus"
    (UnE (`MinusOp, `NatT, nat 2) $$ region % nat_typ)
    (app "-_" [ Const "2" ]) [];
  check_guard "guard-div"
    (BinE (`DivOp, `NatT, nat 4, nat 2) $$ region % nat_typ)
    (app "_/_" [ Const "4"; Const "2" ]) [ nonzero (Const "2") ];
  check_guard "guard-mod"
    (BinE (`ModOp, `NatT, nat 4, nat 2) $$ region % nat_typ)
    (app "modNat" [ Const "4"; Const "2" ]) [ nonzero (Const "2") ]

let test_comparison_table () =
  List.iter
    (fun (label, op, name) ->
      let exp = CmpE (op, `NatT, nat 1, nat 2) $$ region % bool_typ in
      Expr_translate.lower_value ctx Expr_env.empty origin exp
      |> check label
           (bool_term (app name [ Const "1"; Const "2" ])) [])
    [ "cmp-eq", `EqOp, "_==_"
    ; "cmp-ne", `NeOp, "_=/=_"
    ; "cmp-lt", `LtOp, "_<_"
    ; "cmp-gt", `GtOp, "_>_"
    ; "cmp-le", `LeOp, "_<=_"
    ; "cmp-ge", `GeOp, "_>=_"
    ]

let test_bool_routing () =
  let left = bool true and right = bool false in
  let check_bool label op expected =
    let exp = BinE (op, `BoolT, left, right) $$ region % bool_typ in
    Expr_translate.lower_value ctx Expr_env.empty origin exp
    |> check label (bool_term expected) []
  in
  check_bool "route-and" `AndOp (app "_and_" [ Const "true"; Const "false" ]);
  check_bool "route-or" `OrOp (app "_or_" [ Const "true"; Const "false" ]);
  check_bool "route-impl" `ImplOp
    (app "_or_" [ app "not_" [ Const "true" ]; Const "false" ]);
  check_bool "route-equiv" `EquivOp (app "_==_" [ Const "true"; Const "false" ]);
  let not_exp = UnE (`NotOp, `BoolT, bool true) $$ region % bool_typ in
  Expr_translate.lower_value ctx Expr_env.empty origin not_exp
  |> check "route-not" (bool_term (app "not_" [ Const "true" ])) []

let () =
  test_direct_operator_tables ();
  test_numeric_guard_decisions ();
  test_comparison_table ();
  test_bool_routing ()
