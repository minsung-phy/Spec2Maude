type category =
  | Unsupported
  | Skipped
  | Obligation
  | PreludeGap

type severity =
  | Info
  | Warning
  | Fatal

type deferral =
  | ListN_premise_admissibility
  | Binding_membership_admissibility
  | Runtime_predicate_binding_admissibility

type t =
  { category : category
  ; severity : severity
  ; origin : Origin.t
  ; constructor : string
  ; enclosing : string list
  ; profile : string
  ; reason : string
  ; suggestion : string option
  ; source_echo : string option
  ; deferral : deferral option
  }

let string_of_category = function
  | Unsupported -> "Unsupported"
  | Skipped -> "Skipped"
  | Obligation -> "Obligation"
  | PreludeGap -> "PreludeGap"

let string_of_severity = function
  | Info -> "info"
  | Warning -> "warning"
  | Fatal -> "fatal"

let default_severity = function
  | Unsupported | PreludeGap -> Fatal
  | Skipped -> Info
  | Obligation -> Warning

let make ?severity ?suggestion ?source_echo ?deferral ~category ~origin ~constructor
    ~enclosing ~profile ~reason () =
  let severity =
    match severity with
    | Some severity -> severity
    | None -> default_severity category
  in
  { category
  ; severity
  ; origin
  ; constructor
  ; enclosing
  ; profile
  ; reason
  ; suggestion
  ; source_echo
  ; deferral
  }

let is_fatal diagnostic =
  match diagnostic.severity with
  | Fatal -> true
  | Info | Warning -> false

let render diagnostic =
  let b = Buffer.create 256 in
  let add line = Buffer.add_string b line; Buffer.add_char b '\n' in
  add
    (Printf.sprintf "%s: %s at %s"
       (string_of_severity diagnostic.severity)
       (string_of_category diagnostic.category)
       (Origin.summary diagnostic.origin));
  add ("  constructor: " ^ diagnostic.constructor);
  add ("  profile: " ^ diagnostic.profile);
  (match diagnostic.enclosing with
  | [] -> ()
  | xs -> add ("  enclosing: " ^ String.concat " > " xs));
  add ("  reason: " ^ diagnostic.reason);
  (match diagnostic.suggestion with
  | None -> ()
  | Some suggestion -> add ("  suggestion: " ^ suggestion));
  (match diagnostic.source_echo with
  | None | Some "" -> ()
  | Some echo -> add ("  source: " ^ String.trim echo));
  Buffer.contents b

let render_all diagnostics =
  diagnostics
  |> List.map render
  |> String.concat ""

let key diagnostic =
  String.concat
    "\000"
    [ string_of_category diagnostic.category
    ; string_of_severity diagnostic.severity
    ; Origin.summary diagnostic.origin
    ; diagnostic.constructor
    ; String.concat "/" diagnostic.enclosing
    ; diagnostic.profile
    ; diagnostic.reason
    ; Option.value diagnostic.suggestion ~default:""
    ; Option.value diagnostic.source_echo ~default:""
    ]

let dedup diagnostics =
  let _seen, diagnostics =
    diagnostics
    |> List.fold_left
         (fun (seen, acc) diagnostic ->
           let key = key diagnostic in
           if List.mem key seen then
             seen, acc
           else
             key :: seen, diagnostic :: acc)
         ([], [])
  in
  List.rev diagnostics

let count_by predicate diagnostics =
  List.fold_left
    (fun count diagnostic -> if predicate diagnostic then count + 1 else count)
    0 diagnostics

let summary diagnostics =
  let total = List.length diagnostics in
  let fatal = count_by is_fatal diagnostics in
  let unsupported =
    count_by (fun d -> d.category = Unsupported) diagnostics
  in
  let skipped =
    count_by (fun d -> d.category = Skipped) diagnostics
  in
  let obligations =
    count_by (fun d -> d.category = Obligation) diagnostics
  in
  let prelude_gaps =
    count_by (fun d -> d.category = PreludeGap) diagnostics
  in
  Printf.sprintf
    "diagnostics: total=%d fatal=%d unsupported=%d skipped=%d obligations=%d prelude_gaps=%d"
    total fatal unsupported skipped obligations prelude_gaps
