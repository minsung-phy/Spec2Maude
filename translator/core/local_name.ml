open Maude_ir

module Names = Set.Make (String)
module Sources = Map.Make (String)

type role =
  | Result
  | Pattern
  | Head
  | Tail
  | Component
  | Update
  | Value
  | Capture
  | Output
  | Witness
  | Chunk
  | Count
  | Stream
  | Byte
  | Width
  | Type
  | History

type t =
  { reserved : Names.t
  ; sources : string Sources.t
  ; result : int
  ; pattern : int
  ; head : int
  ; tail : int
  ; component : int
  ; update : int
  ; value : int
  ; capture : int
  ; output : int
  ; witness : int
  ; chunk : int
  ; count : int
  ; stream : int
  ; byte : int
  ; width : int
  ; typ : int
  ; history : int
  }

let empty =
  { reserved = Names.empty
  ; sources = Sources.empty
  ; result = 0
  ; pattern = 0
  ; head = 0
  ; tail = 0
  ; component = 0
  ; update = 0
  ; value = 0
  ; capture = 0
  ; output = 0
  ; witness = 0
  ; chunk = 0
  ; count = 0
  ; stream = 0
  ; byte = 0
  ; width = 0
  ; typ = 0
  ; history = 0
  }

let rec available_source_name reserved base ordinal =
  let candidate = if ordinal = 1 then base else base ^ string_of_int ordinal in
  if Names.mem candidate reserved then
    available_source_name reserved base (ordinal + 1)
  else
    candidate

let source_key source = "source\000" ^ source
let phantom_key source = "phantom\000" ^ source

let reserve_named_source names key base =
  if Sources.mem key names.sources then names
  else
    let name = available_source_name names.reserved base 1 in
    { names with
      reserved = Names.add name names.reserved
    ; sources = Sources.add key name names.sources
    }

let reserve_source names source =
  reserve_named_source names (source_key source) (Naming.source_var source)

let reserve_sources = List.fold_left reserve_source

let reserve_phantom names source =
  reserve_named_source
    names (phantom_key source) ("TYP_" ^ Naming.source_var source)

let variable_base name =
  match String.index_opt name ':' with
  | Some index -> String.sub name 0 index
  | None -> name

let reserve_existing names name =
  { names with reserved = Names.add (variable_base name) names.reserved }

let reserve_existing_many = List.fold_left reserve_existing

let stem = function
  | Result -> "RESULT"
  | Pattern -> "PATTERN"
  | Head -> "HEAD"
  | Tail -> "TAIL"
  | Component -> "COMPONENT"
  | Update -> "UPDATE"
  | Value -> "VALUE"
  | Capture -> "CAPTURE"
  | Output -> "OUTPUT"
  | Witness -> "WITNESS"
  | Chunk -> "CHUNK"
  | Count -> "COUNT"
  | Stream -> "STREAM"
  | Byte -> "BYTE"
  | Width -> "WIDTH"
  | Type -> "TYPE"
  | History -> "HISTORY"

let next names = function
  | Result -> names.result + 1
  | Pattern -> names.pattern + 1
  | Head -> names.head + 1
  | Tail -> names.tail + 1
  | Component -> names.component + 1
  | Update -> names.update + 1
  | Value -> names.value + 1
  | Capture -> names.capture + 1
  | Output -> names.output + 1
  | Witness -> names.witness + 1
  | Chunk -> names.chunk + 1
  | Count -> names.count + 1
  | Stream -> names.stream + 1
  | Byte -> names.byte + 1
  | Width -> names.width + 1
  | Type -> names.typ + 1
  | History -> names.history + 1

let with_next names role ordinal =
  match role with
  | Result -> { names with result = ordinal }
  | Pattern -> { names with pattern = ordinal }
  | Head -> { names with head = ordinal }
  | Tail -> { names with tail = ordinal }
  | Component -> { names with component = ordinal }
  | Update -> { names with update = ordinal }
  | Value -> { names with value = ordinal }
  | Capture -> { names with capture = ordinal }
  | Output -> { names with output = ordinal }
  | Witness -> { names with witness = ordinal }
  | Chunk -> { names with chunk = ordinal }
  | Count -> { names with count = ordinal }
  | Stream -> { names with stream = ordinal }
  | Byte -> { names with byte = ordinal }
  | Width -> { names with width = ordinal }
  | Type -> { names with typ = ordinal }
  | History -> { names with history = ordinal }

let rec fresh names role =
  let ordinal = next names role in
  let candidate = stem role ^ string_of_int ordinal in
  let names = with_next names role ordinal in
  if Names.mem candidate names.reserved then
    fresh names role
  else
    candidate, { names with reserved = Names.add candidate names.reserved }

let fresh_typed names role sort =
  let name, names = fresh names role in
  Var (name ^ ":" ^ sort_name sort), names

let type_qualifier = function
  | SortRef sort -> sort_name sort
  | KindRef kind -> "[" ^ sort_name (kind_sort kind) ^ "]"

let qualified_name name type_ref =
  name ^ ":" ^ type_qualifier type_ref

let qualified name type_ref =
  Var (qualified_name name type_ref)

let reserved_name names kind key source =
  match Sources.find_opt key names.sources with
  | Some name -> name
  | None ->
    invalid_arg
      (Printf.sprintf
         "Local_name.%s: source `%s` was not reserved in this statement supply"
         kind source)

let source_name names source =
  reserved_name names "source" (source_key source) source

let phantom_name names source =
  reserved_name names "phantom" (phantom_key source) source

let source_qualified_name names source type_ref =
  qualified_name (source_name names source) type_ref

let source_qualified names source type_ref =
  qualified (source_name names source) type_ref

let fresh_source_name names source =
  let base = Naming.source_var source in
  let name = available_source_name names.reserved base 1 in
  name, { names with reserved = Names.add name names.reserved }

let fresh_source_qualified_name names source type_ref =
  let name, names = fresh_source_name names source in
  qualified_name name type_ref, names

let fresh_source_qualified names source type_ref =
  let name, names = fresh_source_qualified_name names source type_ref in
  Var name, names

let phantom_qualified_name names source type_ref =
  qualified_name (phantom_name names source) type_ref

let fresh_qualified_name names role type_ref =
  let name, names = fresh names role in
  qualified_name name type_ref, names

let fresh_qualified names role type_ref =
  let name, names = fresh_qualified_name names role type_ref in
  Var name, names
