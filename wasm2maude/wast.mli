type audit

val parse : string -> Wasm.Script.script
val sources : string -> string list
val audit_suite : string -> audit
val audit_files : audit -> int
val audit_modules : audit -> int
val audit_encoded : audit -> int
val audit_failures : audit -> (string * int) list
val audit_issues : audit -> string list
