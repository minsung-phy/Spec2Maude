open Wasm_to_maude
open Wasm.Types

let name text = Wasm.Utf8.decode text

let function_type args =
  ExternFuncT (Def (DefT (RecT [SubT (Final, [], FuncT (args, []))], 0l)))

let expected =
  [ "print", function_type [];
    "print_i32", function_type [NumT I32T];
    "print_i64", function_type [NumT I64T];
    "print_f32", function_type [NumT F32T];
    "print_f64", function_type [NumT F64T];
    "print_i32_f32", function_type [NumT I32T; NumT F32T];
    "print_f64_f64", function_type [NumT F64T; NumT F64T];
    "global_i32", ExternGlobalT (GlobalT (Cons, NumT I32T));
    "global_i64", ExternGlobalT (GlobalT (Cons, NumT I64T));
    "global_f32", ExternGlobalT (GlobalT (Cons, NumT F32T));
    "global_f64", ExternGlobalT (GlobalT (Cons, NumT F64T));
    "memory", ExternMemoryT (MemoryT (I32AT, {min = 1L; max = Some 2L}));
    "table",
      ExternTableT
        (TableT (I32AT, {min = 10L; max = Some 20L}, (Null, FuncHT)));
    "table64",
      ExternTableT
        (TableT (I64AT, {min = 10L; max = Some 20L}, (Null, FuncHT))) ]

let require_catalog () =
  let actual =
    List.map
      (fun export ->
        Wasm.Utf8.encode (Wast_host.name export), Wast_host.externtype export)
      Wast_host.exports
  in
  if actual <> expected then failwith "native spectest catalog changed";
  if Wast_host.lookup (name "missing") <> None then
    failwith "unknown native spectest export was accepted"

let require_initial_values () =
  let value export_name =
    match Wast_host.lookup (name export_name) with
    | Some export -> Wast_host.kind export
    | None -> failwith ("missing catalog export: " ^ export_name)
  in
  let expect export_name expected =
    match value export_name with
    | Wast_host.Global (_, actual) when actual = expected -> ()
    | _ -> failwith ("wrong catalog value: " ^ export_name)
  in
  expect "global_i32" (Wasm.Value.I32 666l);
  expect "global_i64" (Wasm.Value.I64 666L);
  expect "global_f32" (Wasm.Value.F32 (Wasm.F32.of_float 666.6));
  expect "global_f64" (Wasm.Value.F64 (Wasm.F64.of_float 666.6))

let require_lifetimes () =
  let plans =
    Wast_plan.load "wast_spectest_tables_shared.wast" |> Wast_plan.host
  in
  if List.map (fun binding -> binding.Wast_plan.address) plans.memories <> [0]
  then failwith "native spectest memory is not a singleton";
  if List.map (fun binding -> binding.Wast_plan.address) plans.tables <> [0; 1]
  then failwith "native spectest table addresses changed";
  let imported = List.map (fun provider -> provider.Wast_plan.binding.address) plans.providers in
  if imported <> [0; 1; 0; 1] then
    failwith "native spectest shared provider views lost identity"

let require_fresh_lookups () =
  let fresh =
    Wast_plan.load "wast_spectest_fresh_lookup_lifetimes.wast"
    |> Wast_plan.host
  in
  if List.map (fun binding -> binding.Wast_plan.address) fresh.funcs <> [0; 1]
  then failwith "native spectest function lookup is not fresh";
  if List.map (fun binding -> binding.Wast_plan.address) fresh.globals <> [0; 1]
  then failwith "native spectest global lookup is not fresh";
  let plans =
    Wast_plan.load "wast_spectest_register_override.wast" |> Wast_plan.host
  in
  if List.map (fun binding -> binding.Wast_plan.address) plans.globals <> [0]
  then failwith "register override did not stop virtual host lookup"

let () =
  require_catalog ();
  require_initial_values ();
  require_lifetimes ();
  require_fresh_lookups ()
