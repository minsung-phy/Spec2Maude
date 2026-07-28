type summary
type suite
type audit

val load : string -> summary
val sources : string -> string list
val load_suite : string -> suite
val audit_suite : string -> audit
val typecheck_suite : ?details:bool -> semantics:string -> string -> string * audit
val to_lines : summary -> (string * int) list
val total : summary -> int
val files : suite -> int
val summary : suite -> summary
val audit_files : audit -> int
val audit_modules : audit -> int
val audit_encoded : audit -> int
val audit_failures : audit -> (string * int) list
val audit_issues : audit -> string list
