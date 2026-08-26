module Script = Wasm.Script
module Source = Wasm.Source
module Names = Map.Make (String)

module T = Maude_term

type invoke = int * Wasm.Ast.name * T.t list

type action =
  | Invoke of invoke
  | Get of int * Wasm.Ast.name

type import_requirement =
  | Ready
  | Current_memory_min of int64
  | Current_table_min of int64

type import = {
  provider : int;
  name : Wasm.Ast.name;
  requirement : import_requirement;
}

type host_binding = {export : Wast_host.export; address : int}
type host_provider = {id : int; binding : host_binding}
type host = {
  providers : host_provider list;
  globals : host_binding list;
  memories : host_binding list;
  tables : host_binding list;
  funcs : host_binding list;
}

type nan_class = Canonical | Arithmetic

type 'a lane_pattern = ExactLane of 'a | NanLane of nan_class

type vector_pattern =
  | F32x4Lanes of Wasm.F32.t lane_pattern list
  | F64x2Lanes of Wasm.F64.t lane_pattern list

type result_pattern =
  | ExactNum of Wasm.Value.num
  | ExactVec of Wasm.V128.t
  | VecLanes of vector_pattern
  | ExactRef of Wasm.Value.ref_
  | RefType of Wasm.Types.heaptype
  | NullRef of Wasm.Types.heaptype
  | Either of result_pattern list
  | Nan of Wasm.Types.numtype * nan_class

type uninstantiable =
  | Static_link_failure
  | Live_instantiation of T.t * import list

type uninstantiable_plan = {
  expected : string;
  instantiation : uninstantiable;
}

type exhaustion_plan = {
  expected : string;
  invocation : invoke;
}

type command =
  | Instantiate of int * T.t * import list
  | Unlinkable of int * import list
  | Uninstantiable of int * uninstantiable_plan
  | Return of int * action * result_pattern list
  | Trap of int * action
  | Exception of int * invoke
  | Exhaustion of int * exhaustion_plan
  | Do of int * action

type t = {commands : command list; host : host; checked : int}

type instance = {id : int; module_ : Frontend.module_}
type provider = Instance of instance | Host

type link_failure =
  | Unknown_module of Source.region * string
  | Missing_host_export of Source.region * string * Wasm.Ast.name
  | Missing_registered_export of Source.region * string * Wasm.Ast.name
  | Incompatible_import of
      Source.region * string * Wasm.Ast.name *
      Wasm.Types.externtype * Wasm.Types.externtype

type link_plan =
  | Linkable of import list
  | Statically_unlinkable of link_failure

type env = {
  modules : Frontend.module_ Names.t;
  latest_module : Frontend.module_ option;
  instances : instance Names.t;
  latest_instance : instance option;
  registry : provider Names.t;
  next_instance : int;
  next_host_provider : int;
  next_command : int;
  host : host;
}

let add_shared host export =
  let binding address = {export; address} in
  match Wast_host.kind export with
  | Wast_host.Memory _ ->
      let binding = binding (List.length host.memories) in
      binding, {host with memories = binding :: host.memories}
  | Wast_host.Table _ ->
      let binding = binding (List.length host.tables) in
      binding, {host with tables = binding :: host.tables}
  | Wast_host.Function _ | Wast_host.Global _ ->
      invalid_arg "Wast_plan.add_shared"

let empty_host =
  {providers = []; globals = []; memories = []; tables = []; funcs = []}

let empty instances = {
  modules = Names.empty;
  latest_module = None;
  instances = Names.empty;
  latest_instance = None;
  registry =
    Names.singleton (Wasm.Utf8.encode Wast_host.module_name) Host;
  next_instance = 1;
  next_host_provider = instances + 1;
  next_command = 1;
  host = empty_host;
}

let unsupported source at message =
  Ingress_error.raise ~region:at Ingress_error.Unsupported source message

let bind source category names var value =
  if Names.mem var.Source.it names then
    unsupported source var.at
      (Printf.sprintf "%s %s is already defined" category var.it);
  Names.add var.it value names

let resolve source category names latest at = function
  | None ->
      (match latest with
       | Some value -> value
       | None -> unsupported source at ("no " ^ category ^ " is defined"))
  | Some var ->
      (match Names.find_opt var.Source.it names with
       | Some value -> value
       | None ->
           unsupported source var.at
             (Printf.sprintf "unknown %s %s" category var.it))

let literal source literal =
  match literal.Source.it with
  | Script.ValLit (Wasm.Value.Num value) -> Encode.num_value value
  | Script.ValLit (Wasm.Value.Ref Wasm.Value.NullRef)
  | Script.NullLit _ -> T.atom "ref.ref-null-addr"
  | Script.ValLit (Wasm.Value.Ref (Script.HostRef address)) ->
      T.app "ref.ref-host-addr" [T.atom (Int32.to_string address)]
  | Script.ValLit
      (Wasm.Value.Ref (Wasm.Extern.ExternRef (Script.HostRef address))) ->
      T.app "ref.ref-extern"
        [T.app "ref.ref-host-addr" [T.atom (Int32.to_string address)]]
  | Script.ValLit (Wasm.Value.Vec (Wasm.Value.V128 value)) ->
      Encode.vec_value value
  | Script.ValLit (Wasm.Value.Ref _) ->
      unsupported source literal.at
        "this reference WAST argument is not supported"

let i32_lane source at = function
  | Script.NumPat {Source.it = Wasm.Value.I32 value; _} -> value
  | Script.NumPat _ ->
      unsupported source at "vector lane has the wrong numeric type; expected i32"
  | Script.NanPat _ ->
      unsupported source at "vector NaN patterns are not supported"

let i64_lane source at = function
  | Script.NumPat {Source.it = Wasm.Value.I64 value; _} -> value
  | Script.NumPat _ ->
      unsupported source at "vector lane has the wrong numeric type; expected i64"
  | Script.NanPat _ ->
      unsupported source at "vector NaN patterns are not supported"

let f32_lane source at = function
  | Script.NumPat {Source.it = Wasm.Value.F32 value; _} -> value
  | Script.NumPat _ ->
      unsupported source at "vector lane has the wrong numeric type; expected f32"
  | Script.NanPat _ ->
      unsupported source at "vector NaN patterns are not supported"

let f64_lane source at = function
  | Script.NumPat {Source.it = Wasm.Value.F64 value; _} -> value
  | Script.NumPat _ ->
      unsupported source at "vector lane has the wrong numeric type; expected f64"
  | Script.NanPat _ ->
      unsupported source at "vector NaN patterns are not supported"

let nan_class = function
  | Script.CanonicalNan -> Canonical
  | Script.ArithmeticNan -> Arithmetic

let f32_lane_pattern source at = function
  | Script.NumPat {Source.it = Wasm.Value.F32 value; _} -> ExactLane value
  | Script.NumPat _ ->
      unsupported source at "vector lane has the wrong numeric type; expected f32"
  | Script.NanPat {Source.it = Wasm.Value.F32 nan; _} ->
      NanLane (nan_class nan)
  | Script.NanPat _ ->
      unsupported source at "vector NaN lane has the wrong numeric type; expected f32"

let f64_lane_pattern source at = function
  | Script.NumPat {Source.it = Wasm.Value.F64 value; _} -> ExactLane value
  | Script.NumPat _ ->
      unsupported source at "vector lane has the wrong numeric type; expected f64"
  | Script.NanPat {Source.it = Wasm.Value.F64 nan; _} ->
      NanLane (nan_class nan)
  | Script.NanPat _ ->
      unsupported source at "vector NaN lane has the wrong numeric type; expected f64"

let exact_vector source at shape lanes =
  match shape with
  | Wasm.V128.I8x16 () ->
      Wasm.V128.I8x16.of_lanes
        (List.map (fun lane -> Wasm.Convert.I8_.wrap_i32 (i32_lane source at lane)) lanes)
  | Wasm.V128.I16x8 () ->
      Wasm.V128.I16x8.of_lanes
        (List.map
           (fun lane -> Wasm.Convert.I16_.wrap_i32 (i32_lane source at lane))
           lanes)
  | Wasm.V128.I32x4 () ->
      Wasm.V128.I32x4.of_lanes (List.map (i32_lane source at) lanes)
  | Wasm.V128.I64x2 () ->
      Wasm.V128.I64x2.of_lanes (List.map (i64_lane source at) lanes)
  | Wasm.V128.F32x4 () ->
      Wasm.V128.F32x4.of_lanes (List.map (f32_lane source at) lanes)
  | Wasm.V128.F64x2 () ->
      Wasm.V128.F64x2.of_lanes (List.map (f64_lane source at) lanes)

let vector source at shape lanes =
  let expected = Wasm.V128.num_lanes shape in
  if List.length lanes <> expected then
    unsupported source at
      (Printf.sprintf "vector %s pattern has %d lanes; expected %d"
         (Wasm.V128.string_of_shape shape) (List.length lanes) expected);
  if List.for_all (function Script.NumPat _ -> true | Script.NanPat _ -> false) lanes
  then ExactVec (exact_vector source at shape lanes)
  else
    match shape with
    | Wasm.V128.F32x4 () ->
        VecLanes (F32x4Lanes (List.map (f32_lane_pattern source at) lanes))
    | Wasm.V128.F64x2 () ->
        VecLanes (F64x2Lanes (List.map (f64_lane_pattern source at) lanes))
    | Wasm.V128.I8x16 () | Wasm.V128.I16x8 ()
    | Wasm.V128.I32x4 () | Wasm.V128.I64x2 () ->
        unsupported source at
          "integer vector shapes cannot contain NaN lane patterns"

let result_heaptype source at = function
  | Wasm.Types.UseHT (Wasm.Types.Def _) ->
      unsupported source at
        "semantic heap type is not reachable in a source WAST result pattern"
  | heaptype -> heaptype

let type_of_literal literal =
  match literal.Source.it with
  | Script.ValLit value -> Wasm.Value.type_of_value value
  | Script.NullLit heaptype -> Wasm.Types.RefT (Wasm.Types.Null, heaptype)

let check_invocation source at instance name args =
  let arguments = List.map type_of_literal args in
  match Frontend.validate_invocation instance.module_ name arguments with
  | Ok () -> ()
  | Error Frontend.Missing_export ->
      unsupported source at "action names an undefined export"
  | Error Frontend.Non_function_export ->
      unsupported source at "action export is not a function"
  | Error Frontend.Unresolved_function_type ->
      unsupported source at
        "validated function export retained an unresolved type index"
  | Error Frontend.Wrong_arity ->
      unsupported source at "function invocation has the wrong number of arguments"
  | Error (Frontend.Wrong_argument_type index) ->
      let literal = List.nth args index in
      unsupported source literal.Source.at
        "function invocation argument has the wrong type"

let exact_ref source at = function
  | Wasm.Value.NullRef
  | Script.HostRef _
  | Wasm.Extern.ExternRef (Script.HostRef _) as reference ->
      ExactRef reference
  | _ ->
      unsupported source at
        "this exact reference WAST result pattern is not parser-reachable"

let nan source at nanop =
  match nanop.Source.it with
  | Wasm.Value.I32 _ | Wasm.Value.I64 _ ->
      unsupported source at "integer NaN result patterns are not supported"
  | Wasm.Value.F32 Script.CanonicalNan ->
      Nan (Wasm.Types.F32T, Canonical)
  | Wasm.Value.F32 Script.ArithmeticNan ->
      Nan (Wasm.Types.F32T, Arithmetic)
  | Wasm.Value.F64 Script.CanonicalNan ->
      Nan (Wasm.Types.F64T, Canonical)
  | Wasm.Value.F64 Script.ArithmeticNan ->
      Nan (Wasm.Types.F64T, Arithmetic)

let rec result source result_phrase =
  match result_phrase.Source.it with
  | Script.NumResult (Script.NumPat value) -> ExactNum value.Source.it
  | Script.NumResult (Script.NanPat nanop) -> nan source result_phrase.at nanop
  | Script.VecResult
      (Script.VecPat (Wasm.Value.V128 (shape, lanes))) ->
      vector source result_phrase.at shape lanes
  | Script.RefResult (Script.RefPat reference) ->
      exact_ref source result_phrase.at reference.Source.it
  | Script.RefResult (Script.RefTypePat heaptype) ->
      RefType (result_heaptype source result_phrase.at heaptype)
  | Script.RefResult (Script.NullPat heaptype) ->
      NullRef (result_heaptype source result_phrase.at heaptype)
  | Script.EitherResult [] ->
      unsupported source result_phrase.at
        "empty either result patterns are not supported"
  | Script.EitherResult results -> Either (List.map (result source) results)

let action source env action =
  let instance =
    match action.Source.it with
    | Script.Invoke (var, _, _) | Script.Get (var, _) ->
        resolve source "module instance" env.instances env.latest_instance
          action.at var
  in
  match action.Source.it with
  | Script.Invoke (_, name, args) ->
      check_invocation source action.at instance name args;
      Invoke (instance.id, name, List.map (literal source) args)
  | Script.Get (_, name) -> Get (instance.id, name)

let trapping_action source env source_action =
  match action source env source_action with
  | Invoke _ as action -> action
  | Get _ ->
      unsupported source source_action.Source.at
        "a WAST global.get action cannot produce a trap"

let exception_action source env source_action =
  match action source env source_action with
  | Invoke invoke -> invoke
  | Get _ ->
      unsupported source source_action.Source.at
        "a WAST global.get action cannot throw an exception"

let exhaustion_action source env source_action =
  match action source env source_action with
  | Invoke invocation -> invocation
  | Get _ ->
      unsupported source source_action.Source.at
        "a WAST global.get action cannot exhaust the call depth"

let expect_invalid source def =
  try
    ignore (Frontend.of_definition source def);
    unsupported source def.Source.at "assert_invalid module passed validation"
  with
  | Ingress_error.Error {kind = Ingress_error.Invalid; _} -> ()

let expect_malformed source def =
  try
    ignore (Frontend.of_definition source def);
    unsupported source def.at "assert_malformed module was accepted"
  with
  | Ingress_error.Error {kind = Ingress_error.Syntax; _} -> ()

let bind_module source env var module_ =
  let modules =
    match var with
    | None -> env.modules
    | Some name -> bind source "module" env.modules name module_
  in
  {env with modules; latest_module = Some module_}

let shared_binding host key =
  let bindings = host.memories @ host.tables in
  List.find_opt
    (fun binding -> Wast_host.lifetime binding.export = Wast_host.Shared key)
    bindings

let allocate_host host export =
  match Wast_host.lifetime export, Wast_host.kind export with
  | Wast_host.Shared key, _ ->
      begin match shared_binding host key with
      | Some binding -> binding, host
      | None -> add_shared host export
      end
  | Wast_host.Fresh, Wast_host.Function _ ->
      let binding = {export; address = List.length host.funcs} in
      binding, {host with funcs = binding :: host.funcs}
  | Wast_host.Fresh, Wast_host.Global _ ->
      let binding = {export; address = List.length host.globals} in
      binding, {host with globals = binding :: host.globals}
  | Wast_host.Fresh, (Wast_host.Memory _ | Wast_host.Table _) ->
      invalid_arg "Wast_plan.allocate_host"

let reachable_min {Wasm.Types.min; max} required =
  Wasm.I64.lt_u min required &&
  match max with None -> true | Some max -> Wasm.I64.le_u required max

let import_requirement actual expected =
  if Wasm.Match.match_externtype [] actual expected then Some Ready else
  match actual, expected with
  | Wasm.Types.ExternMemoryT (Wasm.Types.MemoryT (addr, limits)),
    Wasm.Types.ExternMemoryT
      (Wasm.Types.MemoryT (_, expected_limits))
    when reachable_min limits expected_limits.min ->
      let raised =
        Wasm.Types.ExternMemoryT
          (Wasm.Types.MemoryT
             (addr, {limits with min = expected_limits.min}))
      in
      if Wasm.Match.match_externtype [] raised expected
      then Some (Current_memory_min expected_limits.min)
      else None
  | Wasm.Types.ExternTableT (Wasm.Types.TableT (addr, limits, ref_type)),
    Wasm.Types.ExternTableT
      (Wasm.Types.TableT (_, expected_limits, _))
    when reachable_min limits expected_limits.min ->
      let raised =
        Wasm.Types.ExternTableT
          (Wasm.Types.TableT
             (addr, {limits with min = expected_limits.min}, ref_type))
      in
      if Wasm.Match.match_externtype [] raised expected
      then Some (Current_table_min expected_limits.min)
      else None
  | _ -> None

let check_import at module_key item_name expected actual =
  match import_requirement actual expected with
  | Some requirement -> Ok requirement
  | None -> Error (Incompatible_import (at, module_key, item_name, expected, actual))

let plan_host_import env module_key item_name expected at =
  match Wast_host.lookup item_name with
  | None -> Error (Missing_host_export (at, module_key, item_name)), env
  | Some export ->
      (match check_import at module_key item_name expected
               (Wast_host.externtype export) with
       | Error failure -> Error failure, env
       | Ok requirement ->
           let binding, host = allocate_host env.host export in
           let provider = env.next_host_provider in
           let host_provider = {id = provider; binding} in
           Ok {provider; name = item_name; requirement},
           {env with
            next_host_provider = provider + 1;
            host = {host with providers = host_provider :: host.providers}})

let plan_import env (module_ : Frontend.module_) import =
  let Wasm.Types.ImportT (module_name, item_name, expected) =
    Wasm.Ast.importtype_of module_.ast import
  in
  let module_key = Wasm.Utf8.encode module_name in
  match Names.find_opt module_key env.registry with
  | Some Host ->
      plan_host_import env module_key item_name expected import.at
  | Some (Instance provider) ->
      (match Frontend.export_type provider.module_ item_name with
       | None ->
           Error (Missing_registered_export (import.at, module_key, item_name)), env
       | Some actual ->
           (match check_import import.at module_key item_name expected actual with
            | Error failure -> Error failure, env
            | Ok requirement ->
                Ok {provider = provider.id; name = item_name; requirement}, env))
  | None ->
      Error (Unknown_module (import.Source.at, module_key)), env

let plan_imports env (module_ : Frontend.module_) =
  let {Wasm.Ast.imports; _} = module_.ast.Source.it in
  let rec plan planned env = function
    | [] -> Linkable (List.rev planned), env
    | import :: rest ->
        let result, env = plan_import env module_ import in
        match result with
        | Ok binding -> plan (binding :: planned) env rest
        | Error failure -> Statically_unlinkable failure, env
  in
  plan [] env imports

let link_failure source = function
  | Unknown_module (at, module_key) ->
      unsupported source at
        (Printf.sprintf
           "virtual or unregistered import module %S is not supported"
           module_key)
  | Missing_host_export (at, module_key, item_name) ->
      unsupported source at
        (Printf.sprintf "virtual module %S has no export %S"
           module_key (Wasm.Types.string_of_name item_name))
  | Missing_registered_export (at, module_key, item_name) ->
      unsupported source at
        (Printf.sprintf "registered module %S has no export %S"
           module_key (Wasm.Types.string_of_name item_name))
  | Incompatible_import (at, module_key, item_name, expected, actual) ->
      unsupported source at
        (Printf.sprintf
           "incompatible import type for %S.%S: expected %s, got %s"
           module_key (Wasm.Types.string_of_name item_name)
           (Wasm.Types.string_of_externtype expected)
           (Wasm.Types.string_of_externtype actual))

let instantiate source env instance_var module_var at =
  let module_ =
    resolve source "module" env.modules env.latest_module at module_var
  in
  let imports, env =
    match plan_imports env module_ with
    | Linkable imports, env -> imports, env
    | Statically_unlinkable failure, _ -> link_failure source failure
  in
  let instance = {id = env.next_instance; module_} in
  let instances =
    match instance_var with
    | None -> env.instances
    | Some name -> bind source "module instance" env.instances name instance
  in
  let command = Instantiate (instance.id, Encode.module_ module_, imports) in
  command,
  {env with instances; latest_instance = Some instance;
    next_instance = instance.id + 1}

let plan_uninstantiable source env module_var expected at =
  let module_ =
    resolve source "module" env.modules env.latest_module at module_var
  in
  let link, env = plan_imports env module_ in
  let instantiation =
    match link with
    | Statically_unlinkable _ -> Static_link_failure
    | Linkable imports -> Live_instantiation (Encode.module_ module_, imports)
  in
  {expected; instantiation}, env

let register source env name instance_var at =
  let instance =
    resolve source "module instance" env.instances env.latest_instance at
      instance_var
  in
  {env with
   registry = Names.add (Wasm.Utf8.encode name) (Instance instance) env.registry}

let push env command commands =
  command :: commands, {env with next_command = env.next_command + 1}

let load source =
  let script =
    try Wasm.Parse.Script.parse_file source with
    | Wasm.Parse.Syntax (at, message) | Wasm.Custom.Syntax (at, message) ->
        Ingress_error.raise ~region:at Ingress_error.Syntax source message
    | Sys_error message -> Ingress_error.raise Ingress_error.Io source message
  in
  let instances =
    List.fold_left
      (fun count command ->
        match command.Source.it with
        | Script.Instance _ -> count + 1
        | Script.Module _ | Script.Register _ | Script.Action _
        | Script.Assertion _ | Script.Meta _ -> count)
      0 script
  in
  let finish host =
    {providers = List.rev host.providers;
     globals = List.rev host.globals;
     memories = List.rev host.memories;
     tables = List.rev host.tables;
     funcs = List.rev host.funcs}
  in
  let rec collect env checked commands = function
    | [] -> {commands = List.rev commands; host = finish env.host; checked}
    | command :: rest ->
        (match command.Source.it with
         | Script.Module (var, def) ->
             let module_ = Frontend.of_definition source def in
             collect (bind_module source env var module_) checked commands rest
         | Script.Instance (instance_var, module_var) ->
             let command, env =
               instantiate source env instance_var module_var command.at
             in
             collect env checked (command :: commands) rest
         | Script.Register (name, instance_var) ->
             let env = register source env name instance_var command.at in
             collect env checked commands rest
         | Script.Action source_action ->
             let action = action source env source_action in
             let commands, env = push env (Do (env.next_command, action)) commands in
             collect env checked commands rest
         | Script.Assertion assertion ->
             (match assertion.Source.it with
              | Script.AssertReturn (source_action, results) ->
                  let action = action source env source_action in
                  let results = List.map (result source) results in
                  let command = Return (env.next_command, action, results) in
                  let commands, env = push env command commands in
                  collect env (checked + 1) commands rest
              | Script.AssertTrap (source_action, _) ->
                  let action = trapping_action source env source_action in
                  let command = Trap (env.next_command, action) in
                  let commands, env = push env command commands in
                  collect env (checked + 1) commands rest
              | Script.AssertException source_action ->
                  let invoke = exception_action source env source_action in
                  let command = Exception (env.next_command, invoke) in
                  let commands, env = push env command commands in
                  collect env (checked + 1) commands rest
              | Script.AssertInvalid (def, _)
              | Script.AssertInvalidCustom (def, _) ->
                  expect_invalid source def;
                  collect env (checked + 1) commands rest
              | Script.AssertMalformed (def, _)
              | Script.AssertMalformedCustom (def, _) ->
                  expect_malformed source def;
                  collect env (checked + 1) commands rest
              | Script.AssertUnlinkable (module_var, _) ->
                  let module_ =
                    resolve source "module" env.modules env.latest_module
                      assertion.at module_var
                  in
                  (match plan_imports env module_ with
                   | Statically_unlinkable _, env ->
                       collect env (checked + 1) commands rest
                   | Linkable imports, env ->
                       let command =
                         Unlinkable (env.next_command, imports)
                       in
                       let commands, env = push env command commands in
                       collect env (checked + 1) commands rest)
              | Script.AssertUninstantiable (module_var, expected) ->
                  let plan, env =
                    plan_uninstantiable source env module_var expected assertion.at
                  in
                  let command = Uninstantiable (env.next_command, plan) in
                  let commands, env = push env command commands in
                  collect env (checked + 1) commands rest
              | Script.AssertExhaustion (source_action, expected) ->
                  let invocation = exhaustion_action source env source_action in
                  let plan = {expected; invocation} in
                  let command = Exhaustion (env.next_command, plan) in
                  let commands, env = push env command commands in
                  collect env (checked + 1) commands rest)
         | Script.Meta _ ->
             unsupported source command.at
               "WAST meta commands are not supported")
  in
  collect (empty instances) 0 [] script

let commands plan = plan.commands
let host (plan : t) = plan.host
let checked plan = plan.checked

let runtime_assertions plan =
  List.fold_left
    (fun count -> function
      | Instantiate _ -> count
      | Unlinkable _ | Uninstantiable _ | Return _ | Trap _
      | Exception _ | Exhaustion _ | Do _ -> count + 1)
    0 plan.commands
