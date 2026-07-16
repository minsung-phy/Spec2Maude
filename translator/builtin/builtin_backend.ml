type totality = Total | Partial
type demand = Direct | Indirect
type scope = Global | Scoped

type requirement =
  { key : string
  ; public_op : string
  ; totality : totality
  ; demand : demand
  ; dependencies : string list
  ; representations : string list
  }

type representation =
  { key : string
  ; scope : scope
  ; category : string
  ; arity : int
  ; payload_sort : string
  ; constructor : string
  ; witness : string option
  }

type t =
  { name : string
  ; description : string
  ; source : string
  ; revision : string
  ; module_name : string
  ; abi : int
  ; contract_path : string
  ; smoke_fixture : string
  ; requirements : requirement list
  ; representations : representation list
  ; maude : string
  }

let contract_file = "builtins.contract"

let locate path =
  if Sys.file_exists path then path
  else
    let parent = Filename.concat ".." path in
    if Sys.file_exists parent then parent
    else path

let read_file path =
  let channel = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let fields line =
  line |> String.split_on_char ' ' |> List.filter (( <> ) "")

let csv = function
  | "-" -> []
  | text -> String.split_on_char ',' text

let parse_totality path line_number = function
  | "total" -> Total
  | "partial" -> Partial
  | text ->
    failwith
      (Printf.sprintf "%s:%d: unknown totality '%s'" path line_number text)

let parse_demand path line_number = function
  | "direct" -> Direct
  | "indirect" -> Indirect
  | text ->
    failwith
      (Printf.sprintf "%s:%d: unknown demand '%s'" path line_number text)

let parse_scope path line_number = function
  | "global" -> Global
  | "scoped" -> Scoped
  | text ->
    failwith
      (Printf.sprintf "%s:%d: unknown representation scope '%s'"
         path line_number text)

let required path label = function
  | Some value -> value
  | None -> failwith (path ^ ": missing '" ^ label ^ "' field")

let contains text pattern =
  let text_len = String.length text and pattern_len = String.length pattern in
  let rec search index =
    index + pattern_len <= text_len
    && (String.sub text index pattern_len = pattern || search (index + 1))
  in
  pattern_len = 0 || search 0

let validate backend =
  List.iter (fun (requirement : requirement) ->
    List.iter (fun dependency ->
      if not (List.exists (fun (candidate : requirement) ->
                candidate.key = dependency)
                backend.requirements) then
        failwith
          (backend.contract_path ^ ": requirement '" ^ requirement.key
           ^ "' has unknown dependency '" ^ dependency ^ "'"))
      requirement.dependencies;
    List.iter (fun representation ->
      if not (List.exists (fun (candidate : representation) ->
                candidate.key = representation)
                backend.representations) then
        failwith
          (backend.contract_path ^ ": requirement '" ^ requirement.key
           ^ "' has unknown representation '" ^ representation ^ "'"))
      requirement.representations;
    if not (contains backend.maude requirement.public_op) then
      failwith
        (backend.contract_path ^ ": public operator '" ^ requirement.public_op
         ^ "' is absent from the hand-written Maude backend"))
    backend.requirements;
  let module_header = "mod " ^ backend.module_name ^ " is" in
  if not (contains backend.maude module_header) then
    failwith
      (backend.contract_path ^ ": Maude module '" ^ backend.module_name
       ^ "' is absent from the backend source")

let parse path =
  let name = ref None and description = ref None and source = ref None in
  let revision = ref None and module_name = ref None and abi = ref None in
  let maude_path = ref None and smoke_fixture = ref None in
  let requirements : requirement list ref = ref [] in
  let representations : representation list ref = ref [] in
  read_file path |> String.split_on_char '\n'
  |> List.iteri (fun index line ->
    let line_number = index + 1 and line = String.trim line in
    if line <> "" && not (String.starts_with ~prefix:"#" line) then
      match fields line with
      | [ "backend"; value ] -> name := Some value
      | "description" :: values -> description := Some (String.concat " " values)
      | [ "source"; value ] -> source := Some value
      | [ "revision"; value ] -> revision := Some value
      | [ "module"; value ] -> module_name := Some value
      | [ "abi"; value ] ->
        (match int_of_string_opt value with
        | Some value -> abi := Some value
        | None -> failwith (Printf.sprintf "%s:%d: invalid ABI" path line_number))
      | [ "maude"; value ] -> maude_path := Some value
      | [ "smoke"; value ] -> smoke_fixture := Some value
      | [ "representation"; key; scope; category; arity; payload_sort
        ; constructor; witness ] ->
        if List.exists (fun (entry : representation) -> entry.key = key)
             !representations then
          failwith (path ^ ": duplicate representation '" ^ key ^ "'");
        let arity =
          match int_of_string_opt arity with
          | Some arity when arity >= 0 -> arity
          | _ ->
            failwith
              (Printf.sprintf "%s:%d: invalid representation arity"
                 path line_number)
        in
        representations :=
          { key; scope = parse_scope path line_number scope; category; arity
          ; payload_sort; constructor
          ; witness = if witness = "-" then None else Some witness
          } :: !representations
      | [ "require"; key; public_op; totality; demand; dependencies
        ; representations_ ] ->
        if List.exists (fun (entry : requirement) -> entry.key = key)
             !requirements then
          failwith (path ^ ": duplicate requirement '" ^ key ^ "'");
        requirements :=
          { key; public_op
          ; totality = parse_totality path line_number totality
          ; demand = parse_demand path line_number demand
          ; dependencies = csv dependencies
          ; representations = csv representations_
          } :: !requirements
      | _ ->
        failwith
          (Printf.sprintf "%s:%d: malformed builtin contract line"
             path line_number));
  let maude_path = required path "maude" !maude_path in
  let maude_path =
    match Filename.dirname path with
    | "." -> maude_path
    | directory -> Filename.concat directory maude_path
  in
  let backend =
    { name = required path "backend" !name
    ; description = required path "description" !description
    ; source = required path "source" !source
    ; revision = required path "revision" !revision
    ; module_name = required path "module" !module_name
    ; abi = required path "abi" !abi
    ; contract_path = path
    ; smoke_fixture = required path "smoke" !smoke_fixture
    ; requirements = List.rev !requirements
    ; representations = List.rev !representations
    ; maude = read_file maude_path
    }
  in
  validate backend;
  backend

let backend = lazy (parse (locate contract_file))
let load () = Lazy.force backend
let name backend = backend.name
let description backend = backend.description
let source backend = backend.source
let revision backend = backend.revision
let module_name backend = backend.module_name
let abi backend = backend.abi
let contract_path backend = backend.contract_path
let smoke_fixture backend = backend.smoke_fixture
let requirements backend = backend.requirements
let requirement_key (requirement : requirement) = requirement.key
let public_op (requirement : requirement) = requirement.public_op
let totality (requirement : requirement) = requirement.totality
let demand (requirement : requirement) = requirement.demand
let dependencies (requirement : requirement) = requirement.dependencies
let representations (requirement : requirement) = requirement.representations
let representation_requirements backend = backend.representations
let representation_key (representation : representation) = representation.key
let representation_scope (representation : representation) = representation.scope
let representation_category (representation : representation) = representation.category
let representation_arity (representation : representation) = representation.arity
let representation_payload_sort (representation : representation) =
  representation.payload_sort
let representation_constructor (representation : representation) =
  representation.constructor
let representation_witness (representation : representation) =
  representation.witness

let find backend key =
  List.find_opt (fun (requirement : requirement) -> requirement.key = key)
    backend.requirements

let representation backend key =
  List.find_opt (fun (representation : representation) ->
    representation.key = key)
    backend.representations

let render ?(output_load = "output") backend =
  backend.maude |> String.split_on_char '\n'
  |> List.map (function
       | "load output" -> "load " ^ output_load
       | line -> line)
  |> String.concat "\n"
