open Wasm_to_maude

let scalar_source =
  "(module\n"
  ^ "  (func (export \"add\") (param i32 i32) (result i32)\n"
  ^ "    local.get 0 local.get 1 i32.add))"

let simd_source =
  "(module\n"
  ^ "  (func (param v128 v128) (result v128)\n"
  ^ "    local.get 0 local.get 1 i8x16.shuffle"
  ^ " 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)\n"
  ^ "  (func (param v128 v128) (result v128)\n"
  ^ "    local.get 0 local.get 1 i32x4.dot_i16x8_s)\n"
  ^ "  (func (param v128) (result v128)\n"
  ^ "    local.get 0 i32x4.trunc_sat_f32x4_s))"

let call_and_convert_source =
  "(module\n"
  ^ "  (type (func (param i32) (result i32)))\n"
  ^ "  (table 1 funcref)\n"
  ^ "  (func (type 0) local.get 0)\n"
  ^ "  (func (param i32 i32) (result i32)\n"
  ^ "    local.get 0 local.get 1 call_indirect (type 0))\n"
  ^ "  (func (param i64) (result i32) local.get 0 i32.wrap_i64))"

let contains text fragment =
  let text_len = String.length text in
  let fragment_len = String.length fragment in
  let rec loop i =
    i + fragment_len <= text_len
    && (String.sub text i fragment_len = fragment || loop (i + 1))
  in
  fragment_len = 0 || loop 0

let compact text =
  text |> String.to_seq
  |> Seq.filter (function ' ' | '\n' | '\r' | '\t' -> false | _ -> true)
  |> String.of_seq

let require_fragments name source required =
  let module_ = Frontend.text ~name source in
  let actual = Emit.term module_ in
  List.iter
    (fun fragment ->
      if not (contains actual fragment)
      then failwith ("missing Maude fragment: " ^ fragment))
    required

let require_wast_fragments ~checked ~runtime path required =
  let actual, report =
    Wast_run.emit ~semantics:"builtins.maude" ~steps:100 ~call_depth:256 path
  in
  let actual = compact actual in
  List.iter
    (fun fragment ->
      if not (contains actual fragment) then
        failwith ("missing WAST Maude fragment: " ^ fragment))
    required;
  if Wast_run.checked report <> checked then
    failwith ("WAST checked count changed: " ^ path);
  if Wast_run.runtime_assertions report <> runtime then
    failwith ("WAST runtime count changed: " ^ path)

let require_wast_absent path forbidden =
  let actual, _ =
    Wast_run.emit ~semantics:"builtins.maude" ~steps:100 ~call_depth:256 path
  in
  let actual = compact actual in
  List.iter
    (fun fragment ->
      if contains actual fragment then
        failwith ("unexpected WAST Maude fragment: " ^ fragment))
    forbidden

let require_import_plan path =
  let commands = Wast_plan.load path |> Wast_plan.commands in
  let providers =
    List.filter_map
      (function
        | Wast_plan.Instantiate (_, _, imports) ->
            Some (List.map (fun import -> import.Wast_plan.provider) imports)
        | Wast_plan.Unlinkable _ | Wast_plan.Uninstantiable _
        | Wast_plan.Return _
        | Wast_plan.Trap _ | Wast_plan.Exception _ | Wast_plan.Exhaustion _
        | Wast_plan.Do _ -> None)
      commands
  in
  if providers <> [ []; []; [1; 1; 1]; [1; 1; 1]; [2; 2; 2] ] then
    failwith "registered provider IDs or source import order changed";
  let first_action =
    List.find_map
      (function
        | Wast_plan.Return (index, _, _)
        | Wast_plan.Trap (index, _)
        | Wast_plan.Exception (index, _)
        | Wast_plan.Exhaustion (index, _)
        | Wast_plan.Do (index, _)
        | Wast_plan.Unlinkable (index, _)
        | Wast_plan.Uninstantiable (index, _) -> Some index
        | Wast_plan.Instantiate _ -> None)
      commands
  in
  if first_action <> Some 1 then
    failwith "instance planning introduced an action numbering gap"

let require_vector_plan path =
  let cases =
    [ Wasm.V128.I8x16 (),
      ["0"; "1"; "2"; "3"; "4"; "5"; "6"; "7";
       "8"; "9"; "10"; "11"; "12"; "13"; "14"; "15"];
      Wasm.V128.I16x8 (),
      ["0"; "257"; "514"; "771"; "-1"; "-2"; "32767"; "-32768"];
      Wasm.V128.I32x4 (),
      ["1"; "-2"; "2147483647"; "-2147483648"];
      Wasm.V128.I64x2 (),
      ["9223372036854775807"; "-9223372036854775808"];
      Wasm.V128.F32x4 (), ["1"; "-2"; "3.5"; "-4.25"];
      Wasm.V128.F64x2 (), ["1.5"; "-2.25"] ]
  in
  let expected =
    List.map
      (fun (shape, lanes) ->
        let value = Wasm.V128.of_strings shape lanes in
        Maude_term.to_string (Encode.vec_value value), value)
      cases
  in
  let actual =
    Wast_plan.load path |> Wast_plan.commands
    |> List.filter_map
      (function
        | Wast_plan.Return
            (_, Wast_plan.Invoke (_, _, [arg]), [Wast_plan.ExactVec result]) ->
            Some (Maude_term.to_string arg, result)
        | Wast_plan.Instantiate _ | Wast_plan.Unlinkable _
        | Wast_plan.Uninstantiable _ | Wast_plan.Return _
        | Wast_plan.Trap _ | Wast_plan.Exception _ | Wast_plan.Exhaustion _
        | Wast_plan.Do _ -> None)
  in
  if actual <> expected then
    failwith "concrete vector argument or six-shape reconstruction changed"

let require_vector_nan_plan path =
  let commands = Wast_plan.load path |> Wast_plan.commands in
  let patterns =
    List.filter_map
      (function
        | Wast_plan.Return (_, _, [pattern]) -> Some pattern
        | Wast_plan.Instantiate _ | Wast_plan.Unlinkable _
        | Wast_plan.Uninstantiable _ | Wast_plan.Return _
        | Wast_plan.Trap _ | Wast_plan.Exception _ | Wast_plan.Exhaustion _
        | Wast_plan.Do _ -> None)
      commands
  in
  let f32_lanes =
    List.find_map
      (function
        | Wast_plan.VecLanes (Wast_plan.F32x4Lanes lanes) -> Some lanes
        | _ -> None)
      patterns
  in
  let f64_lanes =
    List.find_map
      (function
        | Wast_plan.VecLanes (Wast_plan.F64x2Lanes lanes) -> Some lanes
        | _ -> None)
      patterns
  in
  if f32_lanes <>
      Some
        [ Wast_plan.NanLane Wast_plan.Canonical;
          Wast_plan.NanLane Wast_plan.Arithmetic;
          Wast_plan.ExactLane (Wasm.F32.of_string "-0");
          Wast_plan.ExactLane (Wasm.F32.of_string "1") ]
  then failwith "f32x4 mixed lane order, class, or -0 payload changed";
  if f64_lanes <>
      Some
        [ Wast_plan.NanLane Wast_plan.Canonical;
          Wast_plan.ExactLane (Wasm.F64.of_string "-0") ]
  then failwith "f64x2 mixed lane order, class, or -0 payload changed";
  let lane_patterns =
    List.fold_left
      (fun count -> function Wast_plan.VecLanes _ -> count + 1 | _ -> count)
      0 patterns
  in
  let either_mixed =
    List.exists
      (function
        | Wast_plan.Either alternatives ->
            List.exists (function Wast_plan.VecLanes _ -> true | _ -> false)
              alternatives
        | _ -> false)
      patterns
  in
  if lane_patterns <> 7 || not either_mixed
     || not (List.exists (function Wast_plan.ExactVec _ -> true | _ -> false) patterns)
  then failwith "mixed vector, Either, or ExactVec planning boundary changed"

let require_result_pattern_plan path =
  let tags =
    Wast_plan.load path |> Wast_plan.commands
    |> List.filter_map
      (function
        | Wast_plan.Return (_, _, [Wast_plan.Either _]) -> Some "either"
        | Wast_plan.Return
            (_, _, [Wast_plan.Nan (Wasm.Types.F32T, Wast_plan.Canonical)]) ->
            Some "f32-canonical"
        | Wast_plan.Return
            (_, _, [Wast_plan.Nan (Wasm.Types.F64T, Wast_plan.Arithmetic)]) ->
            Some "f64-arithmetic"
        | Wast_plan.Return (_, _, [Wast_plan.ExactNum _]) -> Some "exact-num"
        | Wast_plan.Return
            (_, _, [Wast_plan.RefType Wasm.Types.FuncHT]) -> Some "func"
        | Wast_plan.Return
            (_, _, [Wast_plan.NullRef Wasm.Types.FuncHT]) -> Some "null-func"
        | Wast_plan.Return
            (_, _, [Wast_plan.NullRef Wasm.Types.ExternHT]) -> Some "null-extern"
        | Wast_plan.Return
            (_, _, [Wast_plan.RefType Wasm.Types.AnyHT]) -> Some "any"
        | Wast_plan.Return
            (_, _, [Wast_plan.RefType Wasm.Types.ExternHT]) -> Some "extern"
        | Wast_plan.Instantiate _ | Wast_plan.Unlinkable _
        | Wast_plan.Uninstantiable _ | Wast_plan.Return _
        | Wast_plan.Trap _ | Wast_plan.Exception _ | Wast_plan.Exhaustion _
        | Wast_plan.Do _ -> None)
  in
  if tags <>
      ["either"; "f32-canonical"; "f64-arithmetic"; "exact-num";
       "func"; "null-func"; "null-extern"; "any"; "any";
       "extern"; "extern"]
  then failwith "semantic WAST result pattern planning changed"

let require_wast_unsupported path fragment =
  try
    ignore
      (Wast_run.emit ~semantics:"builtins.maude" ~steps:1 ~call_depth:256 path);
    failwith ("WAST case was accepted: " ^ path)
  with
  | Ingress_error.Error
      {kind = Ingress_error.Unsupported; message; _}
      when contains message fragment -> ()

let require_run_unsupported source export args fragment =
  let module_ = Frontend.text ~name:"invoke-ingress.wat" source in
  try
    ignore
      (Emit.run ~semantics:"builtins.maude" ~export ~args ~steps:1 module_);
    failwith "invalid direct invocation was accepted"
  with
  | Ingress_error.Error
      {kind = Ingress_error.Unsupported; message; _}
      when contains message fragment -> ()

let require_modelcheck_fragments () =
  let module_ = Frontend.text ~name:"modelcheck.wat" scalar_source in
  let actual =
    Emit.modelcheck ~semantics:"builtins.maude"
      ~export:(Wasm.Utf8.decode "add")
      ~args:[Wasm.Value.I32 2l; Wasm.Value.I32 3l]
      ~expected:(Wasm.Value.I32 5l) ~rejected:(Wasm.Value.I32 6l)
      ~steps:100 module_
    |> compact
  in
  List.iter
    (fun fragment ->
      if not (contains actual fragment) then
        failwith ("missing model-checking fragment: " ^ fragment))
    [ "includingMODEL-CHECKER.";
      "subsortModelState<State.";
      "ifdef.instantiate(emptyStore,inputModule,eps)=>C.";
      "ifrel.steps(C)=>config.sym";
      "modelCheck(boot,<>returned(expected))";
      "modelCheck(boot,[]~returned(rejected))" ]

let assertion_definition path =
  Wasm.Parse.Script.parse_file path
  |> List.find_map (fun command ->
       match command.Wasm.Source.it with
       | Wasm.Script.Assertion assertion ->
           (match assertion.Wasm.Source.it with
            | Wasm.Script.AssertMalformed (def, _)
            | Wasm.Script.AssertMalformedCustom (def, _)
            | Wasm.Script.AssertInvalid (def, _)
            | Wasm.Script.AssertInvalidCustom (def, _) -> Some def
            | Wasm.Script.AssertUnlinkable _
            | Wasm.Script.AssertUninstantiable _
            | Wasm.Script.AssertReturn _
            | Wasm.Script.AssertException _
            | Wasm.Script.AssertTrap _
            | Wasm.Script.AssertExhaustion _ -> None)
       | Wasm.Script.Module _ | Wasm.Script.Instance _
       | Wasm.Script.Register _ | Wasm.Script.Action _
       | Wasm.Script.Meta _ -> None)
  |> Option.get

let require_checked path expected =
  let actual = Wast_plan.load path |> Wast_plan.checked in
  if actual <> expected then failwith ("WAST checked count changed: " ^ path)

let require_ingress_kind path expected =
  try
    ignore (Wast_plan.load path);
    failwith ("WAST assertion unexpectedly passed: " ^ path)
  with
  | Ingress_error.Error {kind; _} when kind = expected -> ()

let require_wast_syntax_region path =
  try
    ignore (Wast_plan.load path);
    failwith ("malformed WAST script was accepted: " ^ path)
  with
  | Ingress_error.Error
      {kind = Ingress_error.Syntax; source; region = Some at; message}
      when source = path && at.Wasm.Source.left.file = path
        && at.left.line = 1 && contains message "misplaced annotation" -> ()

let require_quoted_malformed_region path =
  let def = assertion_definition path in
  let quote_at =
    match def.Wasm.Source.it with
    | Wasm.Script.Quoted (_, text) -> text.Wasm.Source.at
    | Wasm.Script.Textual _ | Wasm.Script.Encoded _ ->
        failwith "malformed-region fixture is not quoted"
  in
  try
    ignore (Frontend.of_definition path def);
    failwith "malformed quoted definition was accepted"
  with
  | Ingress_error.Error
      {kind = Ingress_error.Syntax; region = Some region; _} ->
      if region.Wasm.Source.left.file <> quote_at.Wasm.Source.left.file
         || region.left.line < quote_at.left.line
         || (region.left.line = quote_at.left.line
             && region.left.column <= quote_at.left.column)
      then failwith "quoted syntax region did not retain its payload offset"

let require_canonical_public_surfaces () =
  let render = Maude_term.to_string in
  let scalar =
    [ Encode.num_value (Wasm.Value.I32 1l)
    ; Encode.num_instr (Wasm.Value.F64 (Wasm.F64.of_float 0.))
    ]
    |> List.map render
  in
  let vector =
    Wasm.V128.of_strings (Wasm.V128.I32x4 ()) ["0"; "1"; "2"; "3"]
  in
  let terms =
    scalar @ [ render (Encode.vec_value vector); render (Encode.vec_instr vector) ]
  in
  if not (List.for_all (fun term -> contains term "const(") scalar) then
    failwith "scalar encoder did not emit the shared public const surface";
  if not (List.for_all (fun term -> contains term "vconst(") (List.tl (List.tl terms))) then
    failwith "vector encoder did not emit the shared public vconst surface";
  List.iter
    (fun qualified ->
      if List.exists (fun term -> contains term qualified) terms then
        failwith ("encoder leaked qualified constructor " ^ qualified))
    [ "num.const"; "instr.const"; "vec.vconst"; "instr.vconst" ]

let run () =
  require_canonical_public_surfaces ();
  require_modelcheck_fragments ();
  require_fragments "add.wat" scalar_source
    [ "module.module"; "func.func"; "instr.local-get"; "instr.binop";
      "export.export" ];
  require_fragments "simd.wat" simd_source
    [ "instr.vshuffle"; "bshape.wrap"; "instr.vextbinop";
      "ishape.wrap"; "vextbinop.dot-s"; "instr.vcvtop";
      "vcvtop.trunc-sat" ];
  require_fragments "call-and-convert.wat" call_and_convert_source
    [ "instr.call-indirect"; "idx"; "instr.cvtop";
      "i32"; "i64"; "cvtop.wrap" ];
  require_wast_fragments ~checked:2 ~runtime:2 "wast_quoted_modules.wast"
    [ "command.module(1,"; "command.module(2,";
      "action.invoke(1,"; "action.invoke(2,";
      "VALUES:=ARGS";
      "typecheck(VALUES,syn.val)";
      "typecheck(ARGS,syn.instr)";
      "ACTUAL:=value('VALUE,index(value('GLOBALS,S),A))";
      "typecheck(ACTUAL,syn.val)";
      "typecheck(ACTUAL,syn.instr)" ];
  require_wast_absent "wast_quoted_modules.wast" [ "helper.subtype-" ];
  require_checked "wast_quoted_invalid.wast" 1;
  require_checked "wast_quoted_malformed.wast" 1;
  require_quoted_malformed_region "wast_quoted_malformed.wast";
  require_ingress_kind "wast_quoted_wrong_invalid.wast" Ingress_error.Syntax;
  require_ingress_kind "wast_quoted_wrong_malformed.wast" Ingress_error.Invalid;
  require_wast_syntax_region "wast_custom_syntax.wast";
  require_wast_fragments ~checked:4 ~runtime:6 "wast_named_instances.wast"
    [ "command.module(1,"; "command.module(2,";
      "action.invoke(1,"; "action.invoke(2,";
      "action.get(1,"; "action.get(2,";
      "instances.cons(ID,MI,ENV)"; "findInstance(ENV,TARGET)";
      "opfindFunc:SpectecTerminalsSpectecTerminal~>Nat.";
      "varsIDTARGETAADDRNMINREQUIRED:Nat." ];
  require_wast_fragments ~checked:5 ~runtime:7 "wast_register_imports.wast"
    [ "import.ref(1,"; "import.ref(2,";
      "findExport(value('EXPORTS,findInstance(ENV,TARGET)),NAME)";
      "link.ok(EXPORTS):=linkImports(S,ENV,IMPORTS)";
      "def.instantiate(S,M,EXPORTS)" ];
  require_import_plan "wast_register_imports.wast";
  require_wast_fragments ~checked:4 ~runtime:4
    "wast_linking_function_subset.wast" [ "import.ref(1," ];
  require_wast_fragments ~checked:0 ~runtime:1
    "wast_spectest_print_completes.wast"
    [ "hostFunctionAddresses=0"; "hostfunc.sym"; "[host-call]";
      "hostArguments(VALUES,TYPES)=true" ];
  require_wast_fragments ~checked:1 ~runtime:1
    "wast_spectest_global_i32_value.wast"
    [ "rec.globalinst(globaltype.wrap(eps,i32),const(i32,uN.wrap(666)))" ];
  require_wast_unsupported "wast_spectest_unknown_export_unsupported.wast"
    "has no export";
  require_wast_unsupported "wast_spectest_wrong_type_unsupported.wast"
    "incompatible import type";
  require_wast_unsupported "wast_import_missing_export_unsupported.wast"
    "has no export";
  require_wast_unsupported "wast_import_mismatch_unsupported.wast"
    "incompatible import type";
  require_wast_unsupported "wast_invoke_wrong_arity.wast"
    "wrong number of arguments";
  require_wast_unsupported "wast_invoke_wrong_type.wast"
    "wrong type";
  require_run_unsupported scalar_source (Wasm.Utf8.decode "add")
    [Wasm.Value.I32 1l] "wrong number of arguments";
  require_run_unsupported scalar_source (Wasm.Utf8.decode "add")
    [Wasm.Value.I32 1l; Wasm.Value.I64 2L] "wrong type";
  require_checked "wast_assert_unlinkable_unsupported.wast" 1;
  require_wast_fragments ~checked:6 ~runtime:7 "wast_vectors.wast"
    [ "vconst(vectype.v128,uN.wrap(";
      "eqruntimeResults(vconst(vectype.v128,C)ACTUAL)=" ];
  require_wast_absent "wast_vectors.wast" [ "vec.vconst("; "instr.vconst(" ];
  require_vector_plan "wast_vectors.wast";
  require_wast_fragments ~checked:11 ~runtime:11 "wast_result_patterns.wast"
    [ "sortsScriptActionImportRequirementImportRefImportRefsLinkResultCommandCommandsInstanceEnvScriptStateResultPatternResultPatternsResultAlternativesLanePatternLanePatternsMatchVerdict.";
      "oppatterns.cons:ResultPatternResultPatterns->ResultPatterns[ctor].";
      "opmatch.value:SpectecTerminalResultPattern->MatchVerdict.";
      "result.nan-canonical(f32)";
      "result.nan-arithmetic(f64)";
      "_>=_(ADDR,4194304)=true";
      "result.ref-type(absheaptype.func)";
      "result.ref-type(absheaptype.extern)";
      "opscript.wrong-result:NatSpectecTerminalsResultPatterns->ScriptState[ctor].";
      "match.values(ACTUAL,EXPECTED)=match.no" ];
  require_result_pattern_plan "wast_result_patterns.wast";
  require_wast_fragments ~checked:9 ~runtime:9 "wast_vector_nan_lanes.wast"
    [ "ResultAlternativesLanePatternLanePatternsMatchVerdict";
      "result.vec-lanes(shape.x(f32,dim.wrap(4))";
      "result.vec-lanes(shape.x(f64,dim.wrap(2))";
      "lane.exact(fN.neg(fNmag.subnorm(0)))";
      "ifLANES:=builtin.lanes(shape.x(LT,DIM),VALUE)";
      "match.vec-lanes(NT,VALUELANES,lanes.cons(LPAT,LPATS))";
      "eqmatch.lane(NT,VALUE,LPAT)=match.no[owise]." ];
  require_wast_absent "wast_vector_nan_lanes.wast"
    [ "lane.exact(const" ];
  require_vector_nan_plan "wast_vector_nan_lanes.wast"

let () =
  try run () with
  | Ingress_error.Error error -> failwith (Ingress_error.to_string error)
