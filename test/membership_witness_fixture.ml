open Translator
open Maude_ir

let origin = Origin.synthetic ~ast_constructor:"MemE" "membership-witness-fixture"

let request =
  { Membership_witness_helper.source = "x <- xs"
  ; element_sort = sort "SpectecTerminal"
  ; head_var = "MEMBERHEAD"
  ; tail_var = "MEMBERTAIL"
  ; witness_var = "MEMBERWITNESS"
  }

let name = "membershipChoice"
let result_op = Naming.helper_companion ~role:"membership-result" name
let result_sort = "MembershipWitness" ^ Naming.sort_token name ^ "Conf"

let optional_statements =
  let conf = sort "OptionalMembershipConf" in
  let member = Var "OPTIONALMEMBER" in
  let statement node = generated ~origin node in
  [ statement (sort_decl conf)
  ; statement
      (op "optionalChoice" [ sort_ref (sort "SpectecTerminals") ] conf
         ~attrs:[ Frozen [ 1 ] ])
  ; statement
      (op "optionalResult" [ sort_ref (sort "SpectecTerminal") ] conf
         ~attrs:[ Ctor; Frozen [ 1 ] ])
  ; statement (var "OPTIONALMEMBER" (sort_ref (sort "SpectecTerminal")))
  ; statement
      (rl (App ("optionalChoice", [ member ]))
         (App ("optionalResult", [ member ])))
  ]

let () =
  let statements =
    Membership_witness_helper.materialize ~name origin request
  in
  let module_ =
    { name = "SPEC2MAUDE-MEMBERSHIP-WITNESS-FIXTURE"
    ; kind = System
    ; imports = Prelude.imports
    ; statements = Prelude.statements @ statements @ optional_statements
    }
  in
  print_string (Emit.render_module module_);
  Printf.printf
    "search [10] %s(0 1 2) =>1 %s(X:SpectecTerminal) .\n"
    name result_op;
  Printf.printf
    "search [1] %s(eps) =>* %s(X:SpectecTerminal) .\n"
    name result_op;
  Printf.printf
    "search [1] %s(0) =>1 C:%s .\n"
    result_op result_sort;
  print_endline
    "search [1] optionalChoice(7) =>1 optionalResult(X:SpectecTerminal) .";
  print_endline
    "search [1] optionalChoice(eps) =>* optionalResult(X:SpectecTerminal) ."
