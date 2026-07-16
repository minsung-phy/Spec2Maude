open Util.Source

type enclosing =
  { def_id : string option
  ; rule_id : string option
  ; clause_id : string option
  }

type t =
  { source_index : Analysis.Source_index.t
  ; il_env : Il.Env.t
  ; function_graph : Analysis.Function_graph.t
  ; runtime_ingress_contract : Runtime_ingress_contract.t
  ; runtime_ingress_validation : Runtime_ingress_validation.t
  ; runtime_ingress_uses : (string, unit) Hashtbl.t
  ; builtins : Builtin_registry.t
  ; backend_name : string
  ; constructors : Constructor_registry.t
  ; helpers : Helper.t
  ; enclosing : enclosing
  ; static_typ_env : (string * Il.Ast.typ) list
  ; static_def_env : (string * string) list
  ; phantom_typ_env : (string * string) list
  ; current_specialization : Analysis.Function_graph.specialization option
  ; runtime_relation_uses : (string * string) list
  ; definition_calls :
      (Maude_ir.term, Analysis.Function_graph.definition_identity list) Hashtbl.t
  ; emitted_definition_ops : (string, unit) Hashtbl.t
  }

type stage =
  { target : t
  ; helper_stage : Helper.stage
  ; staged : t
  }

let specialization_targets specialization =
  specialization.Analysis.Function_graph.static_defs
  |> List.map (fun binding -> binding.Analysis.Function_graph.target_id)

let definition_op_for builtins id =
  Builtin_registry.definition_op builtins id

let specialized_definition_op_for builtins id specialization =
  Naming.specialized_definition_op
    ~builtin:(Builtin_registry.is_hint_builtin builtins id.Util.Source.it)
    id (specialization_targets specialization)

let emitted_definition_ops graph builtins =
  let table = Hashtbl.create 127 in
  Analysis.Function_graph.definitions graph
  |> List.iter (fun definition ->
    if List.exists (function Analysis.Function_graph.Static_def -> true | _ -> false)
         definition.Analysis.Function_graph.params
    then
      Analysis.Function_graph.specializations_for graph definition.id
      |> List.iter (fun specialization ->
        Hashtbl.replace table
          (specialized_definition_op_for builtins
             (definition.id $ Util.Source.no_region) specialization) ())
    else
      Hashtbl.replace table
        (definition_op_for builtins (definition.id $ Util.Source.no_region)) ());
  table

let create
    ?(runtime_ingress_contract = Runtime_ingress_contract.empty)
    ?backend_name
    source_index builtins =
  let backend_name =
    Option.value ~default:(Builtin_backend.name (Builtin_backend.load ()))
      backend_name
  in
  let il_env =
    Analysis.Source_index.entries source_index
    |> List.fold_left
         (fun env entry -> Il.Env.env_of_def env entry.Analysis.Source_index.def)
         Il.Env.empty
  in
  let function_graph = Analysis.Function_graph.build source_index in
  { source_index
  ; il_env
  ; function_graph
  ; runtime_ingress_contract
  ; runtime_ingress_validation = Runtime_ingress_validation.of_source_index source_index
  ; runtime_ingress_uses = Hashtbl.create 7
  ; builtins
  ; backend_name
  ; constructors = Constructor_registry.create ()
  ; helpers = Helper.create ()
  ; enclosing = { def_id = None; rule_id = None; clause_id = None }
  ; static_typ_env = []
  ; static_def_env = []
  ; phantom_typ_env = []
  ; current_specialization = None
  ; runtime_relation_uses = []
  ; definition_calls = Hashtbl.create 127
  ; emitted_definition_ops = emitted_definition_ops function_graph builtins
  }

let profile_name ctx =
  "runtime-after-validated-initial-configuration; backend="
  ^ ctx.backend_name

let runtime_ingress_contract t =
  t.runtime_ingress_contract

let helpers t =
  t.helpers

let copy_table table =
  let copy = Hashtbl.create (Hashtbl.length table) in
  Hashtbl.iter (Hashtbl.add copy) table;
  copy

let begin_stage target =
  let helper_stage = Helper.begin_stage target.helpers in
  let staged =
    { target with
      helpers = Helper.staged helper_stage
    ; constructors = Constructor_registry.copy target.constructors
    ; definition_calls = copy_table target.definition_calls
    ; runtime_ingress_uses = copy_table target.runtime_ingress_uses
    }
  in
  { target; helper_stage; staged }

let staged stage =
  stage.staged

let commit_stage stage =
  Helper.commit_stage stage.helper_stage;
  Constructor_registry.replace
    ~target:stage.target.constructors
    ~source:stage.staged.constructors;
  Hashtbl.clear stage.target.definition_calls;
  Hashtbl.iter
    (Hashtbl.add stage.target.definition_calls)
    stage.staged.definition_calls;
  Hashtbl.clear stage.target.runtime_ingress_uses;
  Hashtbl.iter
    (Hashtbl.add stage.target.runtime_ingress_uses)
    stage.staged.runtime_ingress_uses

let constructors t =
  t.constructors

let builtins t =
  t.builtins

let definition_op t id =
  definition_op_for t.builtins id

let specialized_definition_op t id specialization =
  specialized_definition_op_for t.builtins id specialization

let with_builtins t builtins =
  { t with
    builtins
  ; emitted_definition_ops = emitted_definition_ops t.function_graph builtins
  }

let source_index t =
  t.source_index

let il_env t =
  t.il_env

let function_graph t =
  t.function_graph

let runtime_ingress_validation t =
  t.runtime_ingress_validation

let use_runtime_ingress_attestation t attestation =
  Hashtbl.replace t.runtime_ingress_uses
    (Runtime_ingress_contract.attestation_key attestation) ()

let unused_runtime_ingress_attestations t =
  Runtime_ingress_contract.attestations t.runtime_ingress_contract
  |> List.filter (fun attestation ->
       not
         (Hashtbl.mem t.runtime_ingress_uses
            (Runtime_ingress_contract.attestation_key attestation)))

let static_typ_env t =
  t.static_typ_env

let with_static_typ t id typ =
  { t with static_typ_env = (id, typ) :: List.remove_assoc id t.static_typ_env }

let find_static_typ t id =
  List.assoc_opt id t.static_typ_env

let static_def_env t =
  t.static_def_env

let with_static_def t id target_id =
  { t with static_def_env = (id, target_id) :: List.remove_assoc id t.static_def_env }

let find_static_def t id =
  List.assoc_opt id t.static_def_env

let with_phantom_typ t id var_name =
  { t with phantom_typ_env = (id, var_name) :: List.remove_assoc id t.phantom_typ_env }

let find_phantom_typ t id =
  List.assoc_opt id t.phantom_typ_env

let with_specialization t specialization =
  let static_typ_env =
    specialization.Analysis.Function_graph.static_typs
    |> List.fold_left
         (fun env (binding : Analysis.Function_graph.static_typ_binding) ->
           let param_id = binding.Analysis.Function_graph.param_id in
           let typ = binding.Analysis.Function_graph.typ in
           (param_id, typ) :: List.remove_assoc param_id env)
         t.static_typ_env
  in
  let static_def_env =
    specialization.Analysis.Function_graph.static_defs
    |> List.fold_left
         (fun env (binding : Analysis.Function_graph.static_def_binding) ->
           let param_id = binding.Analysis.Function_graph.param_id in
           let target_id = binding.Analysis.Function_graph.target_id in
           (param_id, target_id) :: List.remove_assoc param_id env)
         t.static_def_env
  in
  { t with static_typ_env; static_def_env; current_specialization = Some specialization }

let current_specialization t =
  t.current_specialization

let with_runtime_relation_use t id reason =
  { t with
    runtime_relation_uses =
      (id, reason) :: List.remove_assoc id t.runtime_relation_uses
  }

let runtime_relation_use_reason t id =
  List.assoc_opt id t.runtime_relation_uses

let record_definition_call t term identity =
  let identities = Hashtbl.find_opt t.definition_calls term |> Option.value ~default:[] in
  if not (List.mem identity identities) then
    Hashtbl.replace t.definition_calls term (identity :: identities)

let definition_call_identities t term =
  Hashtbl.find_opt t.definition_calls term |> Option.value ~default:[] |> List.rev

let emitted_definition_operator t op_name =
  Hashtbl.mem t.emitted_definition_ops op_name

let with_def t id =
  { t with enclosing = { def_id = Some id; rule_id = None; clause_id = None } }

let with_rule t id =
  { t with enclosing = { t.enclosing with rule_id = Some id } }

let with_clause t id =
  { t with enclosing = { t.enclosing with clause_id = Some id } }

let enclosing_path t =
  [ t.enclosing.def_id; t.enclosing.rule_id; t.enclosing.clause_id ]
  |> List.filter_map Fun.id
