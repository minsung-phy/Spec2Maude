open Translator

let () =
  let module_ =
    { Maude_ir.name = "OPTIONAL-COMPOSITION-FIXTURE"
    ; kind = Functional
    ; imports = Prelude.imports
    ; statements = Prelude.statements
    }
  in
  print_string (Emit.render_module module_);
  print_endline "red isOpt(composeOpt(eps, eps)) .";
  print_endline "red isOpt(composeOpt(eps, bool(true))) .";
  print_endline "red isOpt(composeOpt(bool(true), eps)) .";
  print_endline "red composeOpt(bool(true), bool(false)) ."
