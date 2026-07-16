val has_materializer : Helper_request.request_kind -> bool
val kind_name : Helper_request.request_kind -> string
val key : Helper_request.request -> string
val name : used:(string -> bool) -> Helper_request.request -> string
