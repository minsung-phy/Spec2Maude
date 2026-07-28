module T = Maude_term

let seq terms = T.seq terms
let list terms = T.app "list.wrap" [seq terms]
let u64 value = T.app "uN.wrap" [T.atom (Int64.to_string value)]

let host_valtype = function
  | Wasm.Types.NumT Wasm.Types.I32T -> T.atom "numtype.i32"
  | Wasm.Types.NumT Wasm.Types.I64T -> T.atom "numtype.i64"
  | Wasm.Types.NumT Wasm.Types.F32T -> T.atom "numtype.f32"
  | Wasm.Types.NumT Wasm.Types.F64T -> T.atom "numtype.f64"
  | Wasm.Types.VecT _ | Wasm.Types.RefT _ | Wasm.Types.BotT ->
      invalid_arg "Wast_host_encode.host_valtype"

let host_deftype = function
  | Wasm.Types.DefT
      (Wasm.Types.RecT
         [Wasm.Types.SubT
            (Wasm.Types.Final, [], Wasm.Types.FuncT (args, results))], 0l) ->
      let comp =
        T.app "comptype.func-sym"
          [list (List.map host_valtype args);
           list (List.map host_valtype results)]
      in
      let subtype = T.app "subtype.sub" [T.atom "final.final"; seq []; comp] in
      T.app "deftype.def"
        [T.app "rectype.rec" [list [subtype]]; T.atom "0"]
  | _ -> invalid_arg "Wast_host_encode.host_deftype"

let limits {Wasm.Types.min; max} =
  T.app "limits.sym-sym-sym"
    [u64 min; (match max with None -> seq [] | Some value -> u64 value)]

let addrtype = function
  | Wasm.Types.I32AT -> T.atom "addrtype.i32"
  | Wasm.Types.I64AT -> T.atom "addrtype.i64"

let globaltype = function
  | Wasm.Types.GlobalT (Wasm.Types.Cons, typ) ->
      T.app "globaltype.wrap" [seq []; host_valtype typ]
  | Wasm.Types.GlobalT (Wasm.Types.Var, _) ->
      invalid_arg "Wast_host_encode.globaltype"

let memtype = function
  | Wasm.Types.MemoryT (addr, lim) ->
      T.app "memtype.page" [addrtype addr; limits lim]

let tabletype = function
  | Wasm.Types.TableT (addr, lim, (Wasm.Types.Null, Wasm.Types.FuncHT)) ->
      T.app "tabletype.wrap"
        [addrtype addr; limits lim;
         T.app "reftype.ref"
           [T.atom "null.null"; T.atom "absheaptype.func"]]
  | Wasm.Types.TableT _ -> invalid_arg "Wast_host_encode.tabletype"

let empty_module =
  T.app "rec.moduleinst"
    [seq []; seq []; seq []; seq []; seq []; seq []; seq []; seq []; seq []]

let host_resource_term {Wast_plan.export; _} =
  match Wast_host.kind export with
  | Wast_host.Function typ ->
      T.app "rec.funcinst" [host_deftype typ; empty_module; T.atom "hostfunc.sym"]
  | Wast_host.Global (typ, value) ->
      T.app "rec.globalinst" [globaltype typ; Encode.num_value value]
  | Wast_host.Memory (Wasm.Types.MemoryT (_, lim) as typ) ->
      let bytes = Int64.mul lim.min 65536L in
      T.app "rec.meminst"
        [memtype typ;
         T.app "helper.iter-count.allocmem" [T.atom (Int64.to_string bytes); u64 lim.min]]
  | Wast_host.Table (Wasm.Types.TableT (_, lim, _) as typ) ->
      T.app "rec.tableinst"
        [tabletype typ;
         T.app "helper.iter-count.alloctable"
           [T.atom (Int64.to_string lim.min); u64 lim.min;
            T.atom "ref.ref-null-addr"]]

let host_extern_term {Wast_plan.export; address} =
  let address = T.atom (string_of_int address) in
  match Wast_host.kind export with
  | Wast_host.Function _ -> T.app "externaddr.func" [address]
  | Wast_host.Global _ -> T.app "externaddr.global" [address]
  | Wast_host.Memory _ -> T.app "externaddr.mem" [address]
  | Wast_host.Table _ -> T.app "externaddr.table" [address]

let host_provider_term {Wast_plan.id; binding} =
  let export =
    T.app "rec.exportinst"
      [Encode.name (Wast_host.name binding.export); host_extern_term binding]
  in
  let instance =
    T.app "rec.moduleinst"
      [seq []; seq []; seq []; seq []; seq []; seq []; seq []; seq []; export]
  in
  id, instance

let instances providers =
  List.fold_right
    (fun provider rest ->
      let id, instance = host_provider_term provider in
      T.app "instances.cons" [T.atom (string_of_int id); instance; rest])
    providers (T.atom "instances.nil")

let store (host : Wast_plan.host) =
  T.app "rec.store"
    [seq [];
     seq (List.map host_resource_term host.globals);
     seq (List.map host_resource_term host.memories);
     seq (List.map host_resource_term host.tables);
     seq (List.map host_resource_term host.funcs);
     seq []; seq []; seq []; seq []; seq []]

let function_addresses funcs =
  funcs
  |> List.map (fun binding -> T.atom (string_of_int binding.Wast_plan.address))
  |> T.seq
