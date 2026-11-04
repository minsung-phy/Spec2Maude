module T = Spectec_term

let seq terms = T.seq terms
let u64 value = T.atom (Int64.to_string value)
let present term = T.app "_?" [term]
let option f = function None -> seq [] | Some value -> present (f value)

let host_valtype = function
  | Wasm.Types.NumT Wasm.Types.I32T -> T.atom "i32"
  | Wasm.Types.NumT Wasm.Types.I64T -> T.atom "i64"
  | Wasm.Types.NumT Wasm.Types.F32T -> T.atom "f32"
  | Wasm.Types.NumT Wasm.Types.F64T -> T.atom "f64"
  | Wasm.Types.VecT _ | Wasm.Types.RefT _ | Wasm.Types.BotT ->
      invalid_arg "Wast_host_encode.host_valtype"

let host_deftype = function
  | Wasm.Types.DefT
      (Wasm.Types.RecT
         [Wasm.Types.SubT
            (Wasm.Types.Final, [], Wasm.Types.FuncT (args, results))], 0l) ->
      let comp =
        T.app "comptype.func-sym"
          [seq (List.map host_valtype args);
           seq (List.map host_valtype results)]
      in
      let subtype =
        T.app "subtype.sub" [present (T.atom "final.final"); seq []; comp]
      in
      T.app "deftype.def"
        [T.app "rectype.rec" [seq [subtype]]; T.atom "0"]
  | _ -> invalid_arg "Wast_host_encode.host_deftype"

let limits {Wasm.Types.min; max} =
  T.app "limits.sym-sym-sym"
    [u64 min; option (fun max -> T.app "#_" [u64 max]) max]

let addrtype = function
  | Wasm.Types.I32AT -> T.atom "i32"
  | Wasm.Types.I64AT -> T.atom "i64"

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
           [present (T.atom "null.null"); T.atom "absheaptype.func"]]
  | Wasm.Types.TableT _ -> invalid_arg "Wast_host_encode.tabletype"

let empty_module =
  T.app "rec.moduleinst"
    [seq []; seq []; seq []; seq []; seq []; seq []; seq []; seq []; seq []]

let host_resource_term {Wast_plan.export; _} =
  match Wast_host.kind export with
  | Wast_host.Function typ ->
      (* hostfunc = _HOSTFUNC text, the export name; spectest names are ASCII. *)
      let name = Wasm.Utf8.encode (Wast_host.name export) in
      T.app "rec.funcinst"
        [host_deftype typ; empty_module;
         T.app "hostfunc.hostfunc" [T.app "#_" [T.atom ("\"" ^ name ^ "\"")]]]
  | Wast_host.Global (typ, value) ->
      T.app "rec.globalinst" [globaltype typ; Encode.num_value value]
  | Wast_host.Memory (Wasm.Types.MemoryT (_, lim) as typ) ->
      let bytes = Int64.mul lim.min 65536L in
      (* meminst BYTES is a maude_array field: size and an empty array (all 0). *)
      T.app "rec.meminst" [memtype typ; T.app "sized-array" [u64 bytes; T.atom "empty"]]
  | Wast_host.Table (Wasm.Types.TableT (_, lim, _) as typ) ->
      T.app "rec.tableinst"
        [tabletype typ;
         T.app "repeatSeq" [u64 lim.min; T.atom "ref.ref-null-addr"]]

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

(* Wasm 1.0 and 2.0 (spec/wasm-VERSION/4-runtime.spectec) have no host
   functions: a spectest print function is a function instance whose code is
   a function with no locals and an empty body. It returns no value and
   changes no state, as the spectest functions observable to a test. This is
   a model of the environment, not part of the specification. *)
module Mvp = struct
  module M = Maude_term

  let record fields =
    let field (name, value) = M.app "field" [M.atom ("'" ^ name); value] in
    let rec join = function
      | [] -> M.atom "EMPTY"
      | [f] -> field f
      | f :: rest -> M.app "_;_" [field f; join rest]
    in
    M.app "{_}" [join fields]

  (* Wasm 2.0 module instances and stores also have element and data segments. *)
  let segments () =
    if !Wasm_version.current = Wasm_version.V2 then ["ELEMS", M.seq []; "DATAS", M.seq []]
    else []

  let instance_record exports =
    let empty = List.map (fun f -> f, M.seq []) ["TYPES"; "FUNCS"; "GLOBALS"; "TABLES"; "MEMS"] in
    record (empty @ segments () @ ["EXPORTS", M.seq exports])

  let functype = function
    | Wasm.Types.DefT
        (Wasm.Types.RecT [Wasm.Types.SubT (Wasm.Types.Final, [], comp)], 0l) ->
        Encode_version.functype comp
    | _ -> invalid_arg "Wast_host_encode.Mvp.functype"

  let resource {Wast_plan.export; _} =
    match Wast_host.kind export with
    | Wast_host.Function typ ->
        let code = M.app "spectec-FUNC" [M.atom "0"; M.seq []; M.seq []] in
        record ["TYPE", functype typ; "MODULE", instance_record []; "CODE", code]
    | Wast_host.Global (typ, value) ->
        record ["TYPE", Encode_version.globaltype typ; "VALUE", Encode.num_value value]
    | Wast_host.Memory (Wasm.Types.MemoryT (_, lim) as typ) ->
        let bytes = Int64.mul lim.min 65536L in
        record
          [ "TYPE", Encode_version.memtype typ
          ; "BYTES", M.app "sized-array" [M.atom (Int64.to_string bytes); M.atom "empty"] ]
    | Wast_host.Table (Wasm.Types.TableT (_, lim, _) as typ) ->
        let null =
          if !Wasm_version.current = Wasm_version.V2 then Encode_v2.null_reference Wasm.Types.FuncHT
          else M.app "seq" [M.seq []]
        in
        record
          [ "TYPE", Encode_version.tabletype typ
          ; "REFS", M.app "map-of" [M.app "repeatSeq" [M.atom (Int64.to_string lim.min); null]] ]

  let extern {Wast_plan.export; address} =
    let address = M.atom (string_of_int address) in
    match Wast_host.kind export with
    | Wast_host.Function _ -> M.app "FUNC" [address]
    | Wast_host.Global _ -> M.app "GLOBAL" [address]
    | Wast_host.Memory _ -> M.app "MEM" [address]
    | Wast_host.Table _ -> M.app "TABLE" [address]

  let instance binding =
    let export =
      record ["NAME", Encode.name (Wast_host.name binding.Wast_plan.export); "ADDR", extern binding]
    in
    instance_record [export]

  let store (host : Wast_plan.host) =
    let resources bindings = M.seq (List.map resource bindings) in
    let fields =
      [ "FUNCS", M.app "map-of" [resources host.funcs]
      ; "GLOBALS", resources host.globals
      ; "TABLES", resources host.tables
      ; "MEMS", M.app "map-of" [resources host.memories] ]
    in
    record (fields @ segments ())
end

let instances providers =
  List.fold_right
    (fun provider rest ->
      let id, instance =
        if Wasm_version.legacy () then provider.Wast_plan.id, Mvp.instance provider.binding
        else host_provider_term provider
      in
      T.app "instances.concat"
        [T.app "instances.entry" [T.atom (string_of_int id); instance]; rest])
    providers (T.atom "instances.nil")

let store (host : Wast_plan.host) =
  if Wasm_version.legacy () then Mvp.store host else
  T.app "rec.store"
    [seq [];
     seq (List.map host_resource_term host.globals);
     seq (List.map host_resource_term host.memories);
     seq (List.map host_resource_term host.tables);
     seq (List.map host_resource_term host.funcs);
     seq []; seq []; seq []; seq []; seq []]
