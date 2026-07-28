type invoke = int * Wasm.Ast.name * Maude_term.t list

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
  | Live_instantiation of Maude_term.t * import list

type uninstantiable_plan = {
  (* Retained as source metadata; the current Maude boundary cannot compare it. *)
  expected : string;
  instantiation : uninstantiable;
}

type exhaustion_plan = {
  (* Retained as source metadata; configurations carry no reason payload. *)
  expected : string;
  invocation : invoke;
}

type command =
  | Instantiate of int * Maude_term.t * import list
  | Unlinkable of int * import list
  | Uninstantiable of int * uninstantiable_plan
  | Return of int * action * result_pattern list
  | Trap of int * action
  | Exception of int * invoke
  | Exhaustion of int * exhaustion_plan
  | Do of int * action

type t

val load : string -> t
val commands : t -> command list
val host : t -> host
val checked : t -> int
val runtime_assertions : t -> int
