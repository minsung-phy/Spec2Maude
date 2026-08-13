open Translator

let () =
  let module_ =
    { Maude_ir.name = "NESTED-TYPECHECK-FIXTURE"
    ; kind = Functional
    ; imports = Prelude.imports
    ; statements = Prelude.statements
    }
  in
  print_string (Emit.render_module module_);
  print_endline "red allSeq(seq(bool(true)) seq(bool(false))) .";
  print_endline "red allSeq(bool(true)) .";
  print_endline "red allOpt(seq(eps) seq(bool(true))) .";
  print_endline "red allOpt(seq(bool(true) bool(false))) .";
  print_endline "red isOpt(seq(bool(true) bool(false))) .";
  print_endline "red typecheck(seq(bool(true)), syn.bool) .";
  print_endline
    "red typecheck(flattenNested(seq(bool(true)) seq(bool(false))), syn.bool) .";
  print_endline "red flattenNested(seq(bool(true)) seq(bool(false))) ."
