module T = Maude_term
module S = Spectec_term

let invoke_term (instance, name, args) =
  T.app "action.invoke"
    [T.atom (string_of_int instance); Encode.name name; T.seq args]

let action_term = function
  | Wast_plan.Invoke invoke -> invoke_term invoke
  | Wast_plan.Get (instance, name) ->
      T.app "action.get"
        [T.atom (string_of_int instance); Encode.name name]

let import_requirement_term = function
  | Wast_plan.Ready -> T.atom "import.ready"
  | Wast_plan.Current_memory_min min ->
      T.app "import.current-memory-min" [T.atom (Int64.to_string min)]
  | Wast_plan.Current_table_min min ->
      T.app "import.current-table-min" [T.atom (Int64.to_string min)]

let import_term {Wast_plan.provider; name; requirement} =
  T.app "import.ref"
    [T.atom (string_of_int provider); Encode.name name;
     import_requirement_term requirement]

let imports_term imports =
  List.fold_right
    (fun import rest -> T.app "imports.cons" [import_term import; rest])
    imports (T.atom "imports.nil")

let reference_term = function
  | Wasm.Value.NullRef -> S.atom "ref.ref-null-addr"
  | Wasm.Script.HostRef address ->
      S.app "ref.ref-host-addr" [T.atom (Int32.to_string address)]
  | Wasm.Extern.ExternRef (Wasm.Script.HostRef address) ->
      S.app "ref.ref-extern"
        [S.app "ref.ref-host-addr" [T.atom (Int32.to_string address)]]
  | _ -> invalid_arg "Wast_command_encode.reference_term"

let lane_patterns_term exact lanes =
  List.fold_right
    (fun lane rest ->
      let lane =
        match lane with
        | Wast_plan.ExactLane value -> T.app "lane.exact" [exact value]
        | Wast_plan.NanLane Wast_plan.Canonical ->
            T.atom "lane.nan-canonical"
        | Wast_plan.NanLane Wast_plan.Arithmetic ->
            T.atom "lane.nan-arithmetic"
      in
      T.app "lanes.cons" [lane; rest])
    lanes (T.atom "lanes.nil")

let rec result_pattern_term = function
  | Wast_plan.ExactNum value ->
      T.app "result.exact-num" [Encode.num_instr value]
  | Wast_plan.ExactVec value ->
      T.app "result.exact-vec" [Encode.vec_instr value]
  | Wast_plan.VecLanes pattern -> vector_pattern_term pattern
  | Wast_plan.ExactRef reference ->
      T.app "result.exact-ref" [reference_term reference]
  | Wast_plan.RefType heaptype ->
      T.app "result.ref-type" [Encode.result_heaptype heaptype]
  | Wast_plan.NullRef heaptype ->
      T.app "result.null-ref" [Encode.result_heaptype heaptype]
  | Wast_plan.Either alternatives ->
      T.app "result.either" [result_alternatives_term alternatives]
  | Wast_plan.Nan (numtype, Wast_plan.Canonical) ->
      T.app "result.nan-canonical" [Encode.result_numtype numtype]
  | Wast_plan.Nan (numtype, Wast_plan.Arithmetic) ->
      T.app "result.nan-arithmetic" [Encode.result_numtype numtype]

and result_alternatives_term alternatives =
  List.fold_right
    (fun pattern rest ->
      T.app "alternatives.cons" [result_pattern_term pattern; rest])
    alternatives (T.atom "alternatives.nil")

and vector_pattern_term = function
  | Wast_plan.F32x4Lanes lanes ->
      T.app "result.vec-lanes"
        [Encode.result_shape (Wasm.V128.F32x4 ());
         lane_patterns_term
           (fun value -> Encode.num_payload (Wasm.Value.F32 value)) lanes]
  | Wast_plan.F64x2Lanes lanes ->
      T.app "result.vec-lanes"
        [Encode.result_shape (Wasm.V128.F64x2 ());
         lane_patterns_term
           (fun value -> Encode.num_payload (Wasm.Value.F64 value)) lanes]

let result_patterns_term patterns =
  List.fold_right
    (fun pattern rest ->
      T.app "patterns.cons" [result_pattern_term pattern; rest])
    patterns (T.atom "patterns.nil")

let command_term ~call_depth = function
  | Wast_plan.Instantiate (instance, module_, imports) ->
      T.app "command.module"
        [T.atom (string_of_int instance); module_; imports_term imports]
  | Wast_plan.Unlinkable (index, imports) ->
      T.app "command.unlinkable"
        [T.atom (string_of_int index); imports_term imports]
  | Wast_plan.Uninstantiable
      (index, {Wast_plan.instantiation = Wast_plan.Static_link_failure; _}) ->
      T.app "command.uninstantiable-static" [T.atom (string_of_int index)]
  | Wast_plan.Uninstantiable
      (index,
       {Wast_plan.instantiation =
          Wast_plan.Live_instantiation (module_, imports); _}) ->
      T.app "command.uninstantiable"
        [T.atom (string_of_int index); module_; imports_term imports]
  | Wast_plan.Return (index, action, results) ->
      T.app "command.return"
        [T.atom (string_of_int index); action_term action;
         result_patterns_term results]
  | Wast_plan.Trap (index, action) ->
      T.app "command.trap"
        [T.atom (string_of_int index); action_term action]
  | Wast_plan.Exception (index, invoke) ->
      T.app "command.exception"
        [T.atom (string_of_int index); invoke_term invoke]
  | Wast_plan.Exhaustion (index, {Wast_plan.invocation; _}) ->
      T.app "command.exhaustion"
        [T.atom (string_of_int index); T.atom (string_of_int call_depth);
         invoke_term invocation]
  | Wast_plan.Do (index, action) ->
      T.app "command.do"
        [T.atom (string_of_int index); action_term action]

let commands ~call_depth commands =
  List.fold_right
    (fun command rest ->
      T.app "commands.cons" [command_term ~call_depth command; rest])
    commands (T.atom "commands.nil")
