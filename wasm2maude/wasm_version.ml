(* The Wasm specification version whose generated semantics a run uses. It
   selects the module encoding (its SpecTec syntax differs per version), the
   semantics, and the WAST runtime. *)
type t = V1 | V2 | V3

let current = ref V3

let of_string = function
  | "1.0" -> Some V1
  | "2.0" -> Some V2
  | "3.0" -> Some V3
  | _ -> None

(* Wasm 1.0 and 2.0 scripts and modules are read by the 3.0 front end. *)
let legacy () = !current <> V3

let semantics = function
  | V1 -> "translator/backend/main-wasm-1.0.maude"
  | V2 -> "translator/backend/main-wasm-2.0.maude"
  | V3 -> "translator/backend/main.maude"

let wast_runtime = function
  | V1 -> "wasm2maude/wast-runtime-1.0.maude"
  | V2 -> "wasm2maude/wast-runtime-2.0.maude"
  | V3 -> "wasm2maude/wast-runtime-3.0.maude"
