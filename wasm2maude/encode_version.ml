(* Terms that differ per Wasm version (Wasm_version.current): modules and
   references. Numbers, vectors, and names have the same terms. *)
let module_ m =
  match !Wasm_version.current with
  | Wasm_version.V1 -> Encode_v1.module_ m
  | Wasm_version.V2 -> Encode_v2.module_ m
  | Wasm_version.V3 -> Encode.module_ m

(* Wasm 1.0 has no references, so its scripts reach none of these. *)
let no_references () = invalid_arg "Encode_version: Wasm 1.0 has no references"

let reference_value r =
  match !Wasm_version.current with
  | Wasm_version.V1 -> no_references ()
  | Wasm_version.V2 -> Encode_v2.reference_value r
  | Wasm_version.V3 -> Encode.reference_value r

(* A null reference literal: typed in Wasm 2.0 (REF.NULL reftype). *)
let null_literal heaptype =
  match !Wasm_version.current with
  | Wasm_version.V1 -> no_references ()
  | Wasm_version.V2 -> Encode_v2.null_reference heaptype
  | Wasm_version.V3 -> Encode.reference_value Wasm.Value.NullRef

let result_heaptype heaptype =
  match !Wasm_version.current with
  | Wasm_version.V1 -> no_references ()
  | Wasm_version.V2 -> Encode_v2.result_reftype heaptype
  | Wasm_version.V3 -> Encode.result_heaptype heaptype

(* Types of the spectest host resources, which Wasm 1.0 and 2.0 scripts
   import as module instances (Wast_host_encode). *)
let host_type v1 v2 typ =
  let source, at = "spectest", Wasm.Source.no_region in
  match !Wasm_version.current with
  | Wasm_version.V1 -> v1 source at typ
  | Wasm_version.V2 -> v2 source at typ
  | Wasm_version.V3 -> invalid_arg "Encode_version.host_type: Wasm 3.0 has host terms"

let functype typ = host_type Encode_v1.functype Encode_v2.functype typ
let globaltype typ = host_type Encode_v1.globaltype Encode_v2.globaltype typ
let memtype typ = host_type Encode_v1.memtype Encode_v2.memtype typ
let tabletype typ = host_type Encode_v1.tabletype Encode_v2.tabletype typ
