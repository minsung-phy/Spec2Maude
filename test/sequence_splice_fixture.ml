open Translator

let print_splice_reference xs len =
  let replacements = [ "eps"; "9"; "9 8" ] in
  for index = 0 to len + 1 do
    for count = 0 to len + 2 do
      List.iter
        (fun replacement ->
          let expected =
            if index <= len then
              Printf.sprintf
                "take(%d, %s) %s drop(%d, %s)"
                index xs replacement (index + count) xs
            else xs
          in
          Printf.printf
            "red splice(%s, %d, %d, %s) == %s .\n"
            xs index count replacement expected)
        replacements
    done
  done

let print_repeat_splice_reference () =
  let xs = "repeatSeq(2048, 0)" in
  let indices = [ 0; 1; 1023; 1024; 2048; 2049 ] in
  let counts = [ 0; 1; 2; 1024; 4096 ] in
  let replacements = [ "eps"; "9"; "9 8" ] in
  List.iter
    (fun index ->
      List.iter
        (fun count ->
          List.iter
            (fun replacement ->
              let expected =
                if index <= 2048 then
                  Printf.sprintf
                    "take(%d, %s) %s drop(%d, %s)"
                    index xs replacement (index + count) xs
                else xs
              in
              Printf.printf
                "red splice(%s, %d, %d, %s) == %s .\n"
                xs index count replacement expected)
            replacements)
        counts)
    indices

let () =
  let module_ =
    { Maude_ir.name = "SEQUENCE-SPLICE-FIXTURE"
    ; kind = Functional
    ; imports = Prelude.imports
    ; statements = Prelude.statements
    }
  in
  print_string (Emit.render_module module_);
  print_endline "red splice(0 1 2 3 4, 2, 1, 9 8) == 0 1 9 8 3 4 .";
  print_endline "red splice(0 1 2 3 4, 5, 0, 9) == 0 1 2 3 4 9 .";
  print_endline "red splice(0 1 2 3 4, 6, 1, 9) == 0 1 2 3 4 .";
  print_endline "red splice(0 1 2 3 4, 3, 10, 9) == 0 1 2 9 .";
  print_endline "red len(splice(repeatSeq(2048, 0), 1024, 1, 9)) == 2048 .";
  print_endline "red index(splice(repeatSeq(2048, 0), 1024, 1, 9), 1023) == 0 .";
  print_endline "red index(splice(repeatSeq(2048, 0), 1024, 1, 9), 1024) == 9 .";
  print_endline "red index(splice(repeatSeq(2048, 0), 1024, 1, 9), 1025) == 0 .";
  print_endline "red typecheckSeq(repeatSeq(2048, 7), syn.nat) .";
  print_endline "red index(repeatSeq(2048, 7), 2047) == 7 .";
  print_endline "red len(take(1024, repeatSeq(2048, 7))) == 1024 .";
  print_endline "red len(drop(1024, repeatSeq(2048, 7))) == 1024 .";
  print_endline "red index(repeatSeq(4, 0) [ 2 <- 9 ], 2) == 9 .";
  print_endline "red len(splice(repeatSeq(2048, 0), 2048, 0, 9)) == 2049 .";
  print_endline "red len(splice(repeatSeq(2048, 0), 2049, 1, 9)) == 2048 .";
  print_endline
    "red splice(0 1, 0, 1, VAL:SpectecTerminals) == VAL:SpectecTerminals 1 .";
  print_endline
    "red splice(repeatSeq(3, 0) XS:SpectecTerminals, 1, 1, 9) == take(1, repeatSeq(3, 0) XS:SpectecTerminals) 9 drop(2, repeatSeq(3, 0) XS:SpectecTerminals) .";
  print_endline
    "red splice(repeatSeq(3, 0) XS:SpectecTerminals, 4, 1, 9) == repeatSeq(3, 0) splice(XS:SpectecTerminals, 1, 1, 9) .";
  print_endline
    "red splice(splice(repeatSeq(2048, 0), 0, 1, 9), 1, 1, 9) == 9 9 repeatSeq(2046, 0) .";
  print_splice_reference "0 1 2 3" 4;
  print_splice_reference "0 0 0 0" 4;
  print_repeat_splice_reference ()
