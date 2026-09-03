open Spec2maude_manual_translate

let default_source_dir = "spectec/wasm-3.0"
let default_output = "optimization/output_optimization.maude"

let die message =
  prerr_endline ("spec2maude: " ^ message);
  exit 2

let sorted_spectec_files dir =
  if not (Sys.file_exists dir) then die ("cannot find " ^ dir);
  Sys.readdir dir
  |> Array.to_list
  |> List.filter (fun name -> Filename.check_suffix name ".spectec")
  |> List.sort String.compare
  |> List.map (Filename.concat dir)

let load_script files =
  files
  |> List.concat_map Frontend.Parse.parse_file
  |> Frontend.Elab.elab
  |> fst

let typed_sequence_extras prefix element list_sort =
  let c = String.capitalize_ascii prefix in
  let p suffix = prefix ^ suffix in
  let v suffix = c ^ suffix in
  String.concat "\n"
    [ "  vars " ^ v "E" ^ " " ^ v "NEW" ^ " : " ^ element ^ " ."
    ; "  vars " ^ v "L" ^ " " ^ v "R" ^ " : " ^ list_sort ^ " ."
    ; "  vars " ^ v "N" ^ " " ^ v "M" ^ " : Nat ."
    ; "  op " ^ p "List" ^ " : " ^ list_sort ^ " -> " ^ list_sort ^ " ."
    ; "  eq " ^ p "List(" ^ v "L) = " ^ v "L ."
    ; "  op " ^ p "Lift : SpectecTerminals -> " ^ list_sort ^ " ."
    ; "  eq " ^ p "Lift(eps) = " ^ p "Nil ."
    ; "  eq " ^ p "Lift(" ^ v "E ?) = " ^ v "E ."
    ; "  op " ^ p "Seq : " ^ list_sort ^ " -> SpectecTerminal [ctor] ."
    ; "  op un" ^ p "Seq : SpectecTerminal ~> " ^ list_sort ^ " ."
    ; "  eq un" ^ p "Seq(" ^ p "Seq(" ^ v "L)) = " ^ v "L ."
    ; "  op " ^ p "Index : " ^ list_sort ^ " Nat ~> " ^ element ^ " ."
    ; "  eq " ^ p "Index(" ^ v "E, 0) = " ^ v "E ."
    ; "  ceq " ^ p "Index(" ^ p "Concat(" ^ v "E, " ^ v "L), s(" ^ v "N))"
      ^ " = " ^ p "Index(" ^ v "L, " ^ v "N) if " ^ v "L =/= " ^ p "Nil ."
    ; "  op " ^ p "Take : " ^ list_sort ^ " Nat -> " ^ list_sort ^ " ."
    ; "  op " ^ p "Drop : " ^ list_sort ^ " Nat -> " ^ list_sort ^ " ."
    ; "  op " ^ p "Slice : " ^ list_sort ^ " Nat Nat -> " ^ list_sort ^ " ."
    ; "  eq " ^ p "Take(" ^ v "L, 0) = " ^ p "Nil ."
    ; "  eq " ^ p "Take(" ^ p "Nil, " ^ v "N) = " ^ p "Nil ."
    ; "  eq " ^ p "Take(" ^ v "E, s(" ^ v "N)) = " ^ v "E ."
    ; "  ceq " ^ p "Take(" ^ p "Concat(" ^ v "E, " ^ v "L), s(" ^ v "N))"
      ^ " = " ^ p "Concat(" ^ v "E, " ^ p "Take(" ^ v "L, " ^ v "N))"
      ^ " if " ^ v "L =/= " ^ p "Nil ."
    ; "  eq " ^ p "Drop(" ^ v "L, 0) = " ^ v "L ."
    ; "  eq " ^ p "Drop(" ^ p "Nil, " ^ v "N) = " ^ p "Nil ."
    ; "  eq " ^ p "Drop(" ^ v "E, s(" ^ v "N)) = " ^ p "Nil ."
    ; "  ceq " ^ p "Drop(" ^ p "Concat(" ^ v "E, " ^ v "L), s(" ^ v "N))"
      ^ " = " ^ p "Drop(" ^ v "L, " ^ v "N) if " ^ v "L =/= " ^ p "Nil ."
    ; "  eq " ^ p "Slice(" ^ v "L, " ^ v "N, " ^ v "M) = "
      ^ p "Take(" ^ p "Drop(" ^ v "L, " ^ v "N), " ^ v "M) ."
    ; "  op " ^ p "SetAt : " ^ list_sort ^ " Nat " ^ element ^ " -> " ^ list_sort ^ " ."
    ; "  eq " ^ p "SetAt(" ^ p "Nil, " ^ v "N, " ^ v "NEW) = " ^ p "Nil ."
    ; "  eq " ^ p "SetAt(" ^ v "E, 0, " ^ v "NEW) = " ^ v "NEW ."
    ; "  eq " ^ p "SetAt(" ^ p "Concat(" ^ v "E, " ^ v "L), 0, " ^ v "NEW)"
      ^ " = " ^ p "Concat(" ^ v "NEW, " ^ v "L) ."
    ; "  ceq " ^ p "SetAt(" ^ p "Concat(" ^ v "E, " ^ v "L), s(" ^ v "N), " ^ v "NEW)"
      ^ " = " ^ p "Concat(" ^ v "E, " ^ p "SetAt(" ^ v "L, " ^ v "N, " ^ v "NEW))"
      ^ " if " ^ v "L =/= " ^ p "Nil ."
    ; "  op " ^ p "Splice : " ^ list_sort ^ " Nat Nat " ^ list_sort ^ " -> " ^ list_sort ^ " ."
    ; "  eq " ^ p "Splice(" ^ v "L, " ^ v "N, " ^ v "M, " ^ v "R)"
      ^ " = " ^ p "Concat(" ^ p "Take(" ^ v "L, " ^ v "N), "
      ^ p "Concat(" ^ v "R, " ^ p "Drop(" ^ v "L, " ^ v "N + " ^ v "M))) ."
    ; "  op " ^ p "ExtendAt : " ^ list_sort ^ " Nat " ^ list_sort ^ " -> " ^ list_sort ^ " ."
    ; "  op " ^ p "ExtendSlice : " ^ list_sort ^ " Nat Nat " ^ list_sort ^ " -> " ^ list_sort ^ " ."
    ; "  eq " ^ p "ExtendAt(" ^ v "L, " ^ v "N, " ^ v "R) = "
      ^ p "SetAt(" ^ v "L, " ^ v "N, "
      ^ p "Concat(" ^ p "Index(" ^ v "L, " ^ v "N), " ^ v "R)) ."
    ; "  eq " ^ p "ExtendSlice(" ^ v "L, " ^ v "N, " ^ v "M, " ^ v "R) = "
      ^ p "Splice(" ^ v "L, " ^ v "N, " ^ v "M, "
      ^ p "Concat(" ^ p "Slice(" ^ v "L, " ^ v "N, " ^ v "M), " ^ v "R)) ."
    ; "  op " ^ p "Repeat : Nat " ^ element ^ " -> " ^ list_sort ^ " ."
    ; "  eq " ^ p "Repeat(0, " ^ v "E) = " ^ p "Nil ."
    ; "  eq " ^ p "Repeat(s(" ^ v "N), " ^ v "E) = "
      ^ p "Concat(" ^ v "E, " ^ p "Repeat(" ^ v "N, " ^ v "E)) ."
    ; ""
    ]

let emit_script script =
  let typed_support = {|fmod SPEC2MAUDE-SORTS is
  protecting DSL-TERM .
  sorts Num Vec Ref Val Instr .
  subsorts Num Vec Ref < Val .
  subsorts Num Vec Ref < Instr .
  subsorts Val Instr < SpectecTerminal .
endfm

view VAL-VIEW from TRIV to SPEC2MAUDE-SORTS is
  sort Elt to Val .
endv

view INSTR-VIEW from TRIV to SPEC2MAUDE-SORTS is
  sort Elt to Instr .
endv

view REF-VIEW from TRIV to SPEC2MAUDE-SORTS is
  sort Elt to Ref .
endv

fmod SPEC2MAUDE-TYPED-SUPPORT is
  protecting SPEC2MAUDE-SORTS .
  protecting DSL-OPTION .
  protecting LIST{VAL-VIEW} * (
    sort List{VAL-VIEW} to ValList,
    sort NeList{VAL-VIEW} to NeValList,
    op nil to valNil,
    op __ to valConcat,
    op append to valAppend,
    op head to valHead,
    op tail to valTail,
    op last to valLast,
    op front to valFront,
    op occurs to valOccurs,
    op reverse to valReverse,
    op $reverse to valReverseAux,
    op size to valSize,
    op $size to valSizeAux
  ) .
  protecting LIST{INSTR-VIEW} * (
    sort List{INSTR-VIEW} to InstrList,
    sort NeList{INSTR-VIEW} to NeInstrList,
    op nil to instrNil,
    op __ to instrConcat,
    op append to instrAppend,
    op head to instrHead,
    op tail to instrTail,
    op last to instrLast,
    op front to instrFront,
    op occurs to instrOccurs,
    op reverse to instrReverse,
    op $reverse to instrReverseAux,
    op size to instrSize,
    op $size to instrSizeAux
  ) .
  protecting LIST{REF-VIEW} * (
    sort List{REF-VIEW} to RefList,
    sort NeList{REF-VIEW} to NeRefList,
    op nil to refNil,
    op __ to refConcat,
    op append to refAppend,
    op head to refHead,
    op tail to refTail,
    op last to refLast,
    op front to refFront,
    op occurs to refOccurs,
    op reverse to refReverse,
    op $reverse to refReverseAux,
    op size to refSize,
    op $size to refSizeAux
  ) .

  vars N : Num .
  vars V : Vec .
  vars R : Ref .
  vars VS : ValList .
  vars IS : InstrList .

  op valToInstr : Val ~> Instr .
  eq valToInstr(N) = N .
  eq valToInstr(V) = V .
  eq valToInstr(R) = R .

  op instrToVal : Instr ~> Val .
  eq instrToVal(N) = N .
  eq instrToVal(V) = V .
  eq instrToVal(R) = R .

  op valsToInstrs : ValList -> InstrList .
  eq valsToInstrs(valNil) = instrNil .
  eq valsToInstrs(N) = N .
  eq valsToInstrs(V) = V .
  eq valsToInstrs(R) = R .
  ceq valsToInstrs(valConcat(N, VS))
    = instrConcat(N, valsToInstrs(VS)) if VS =/= valNil .
  ceq valsToInstrs(valConcat(V, VS))
    = instrConcat(V, valsToInstrs(VS)) if VS =/= valNil .
  ceq valsToInstrs(valConcat(R, VS))
    = instrConcat(R, valsToInstrs(VS)) if VS =/= valNil .

  op instrsToVals : InstrList ~> ValList .
  eq instrsToVals(instrNil) = valNil .
  eq instrsToVals(N) = N .
  eq instrsToVals(V) = V .
  eq instrsToVals(R) = R .
  ceq instrsToVals(instrConcat(N, IS))
    = valConcat(N, instrsToVals(IS)) if IS =/= instrNil .
  ceq instrsToVals(instrConcat(V, IS))
    = valConcat(V, instrsToVals(IS)) if IS =/= instrNil .
  ceq instrsToVals(instrConcat(R, IS))
    = valConcat(R, instrsToVals(IS)) if IS =/= instrNil .

  op instrsToNeVals : NeInstrList ~> NeValList .
  eq instrsToNeVals(N) = N .
  eq instrsToNeVals(V) = V .
  eq instrsToNeVals(R) = R .
  ceq instrsToNeVals(instrConcat(N, IS))
    = valConcat(N, instrsToVals(IS)) if IS =/= instrNil .
  ceq instrsToNeVals(instrConcat(V, IS))
    = valConcat(V, instrsToVals(IS)) if IS =/= instrNil .
  ceq instrsToNeVals(instrConcat(R, IS))
    = valConcat(R, instrsToVals(IS)) if IS =/= instrNil .

|}
    ^ typed_sequence_extras "val" "Val" "ValList"
    ^ typed_sequence_extras "instr" "Instr" "InstrList"
    ^ typed_sequence_extras "ref" "Ref" "RefList"
    ^ {|  vars OUTER-REST : SpectecTerminals .
  var FL-VAL : ValList .
  var FL-INSTR : InstrList .
  var FL-REF : RefList .
  op valFlatten : SpectecTerminals -> ValList .
  eq valFlatten(eps) = valNil .
  eq valFlatten(valSeq(FL-VAL)) = FL-VAL .
  ceq valFlatten(valSeq(FL-VAL) OUTER-REST)
    = valAppend(FL-VAL, valFlatten(OUTER-REST)) if OUTER-REST =/= eps .

  op instrFlatten : SpectecTerminals -> InstrList .
  eq instrFlatten(eps) = instrNil .
  eq instrFlatten(instrSeq(FL-INSTR)) = FL-INSTR .
  ceq instrFlatten(instrSeq(FL-INSTR) OUTER-REST)
    = instrAppend(FL-INSTR, instrFlatten(OUTER-REST)) if OUTER-REST =/= eps .

  op refFlatten : SpectecTerminals -> RefList .
  eq refFlatten(eps) = refNil .
  eq refFlatten(refSeq(FL-REF)) = FL-REF .
  ceq refFlatten(refSeq(FL-REF) OUTER-REST)
    = refAppend(FL-REF, refFlatten(OUTER-REST)) if OUTER-REST =/= eps .
|}
    ^ "endfm\n\n" in
  let modul : Maude_il.modul =
    { name = "SPEC2MAUDE-GENERATED"
    ; kind = System
    ; imports =
        [ Protecting "SPECTEC-SUPPORT"
        ; Protecting "SPEC2MAUDE-TYPED-SUPPORT"
        ]
    ; statements = Definition.translate_script script
    }
  in
  typed_support ^ Maude_emit.emit_module modul ^ "\n"

let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)

let () =
  let output = ref default_output in
  let files = ref [] in
  let options =
    [ "-o", Arg.Set_string output, "FILE write generated Maude to FILE"
    ; "--output", Arg.Set_string output, "FILE write generated Maude to FILE"
    ]
  in
  let usage = "usage: spec2maude [-o FILE] [SPECTEC ...]" in
  try
    Arg.parse options (fun file -> files := file :: !files) usage;
    let files =
      match List.rev !files with
      | [] -> sorted_spectec_files default_source_dir
      | files -> files
    in
    files |> load_script |> emit_script |> write_file !output;
    Printf.eprintf "[spec2maude] wrote %s from %d SpecTec files\n"
      !output (List.length files)
  with
  | Util.Error.Error (region, message) ->
      Util.Error.print_error region message;
      exit 1
  | Sys_error message -> die message
