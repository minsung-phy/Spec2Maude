type profile =
  | Runtime_after_external_validation

type enclosing =
  { def_id : string option
  ; rule_id : string option
  ; clause_id : string option
  }

type t =
  { profile : profile
  ; source_index : Analysis.Source_index.t
  ; function_graph : Analysis.Function_graph.t
  ; constructors : Constructor_registry.t
  ; helpers : Helper.t
  ; enclosing : enclosing
  ; static_typ_env : (string * Il.Ast.typ) list
  ; static_def_env : (string * string) list
  ; current_specialization : Analysis.Function_graph.specialization option
  }

let string_of_profile = function
  | Runtime_after_external_validation -> "Runtime_after_external_validation"

let create ?(profile = Runtime_after_external_validation) source_index =
  { profile
  ; source_index
  ; function_graph = Analysis.Function_graph.build source_index
  ; constructors = Constructor_registry.create ()
  ; helpers = Helper.create ()
  ; enclosing = { def_id = None; rule_id = None; clause_id = None }
  ; static_typ_env = []
  ; static_def_env = []
  ; current_specialization = None
  }

let profile_name t =
  string_of_profile t.profile

let helpers t =
  t.helpers

let constructors t =
  t.constructors

let source_index t =
  t.source_index

let function_graph t =
  t.function_graph

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

let with_def t id =
  { t with enclosing = { def_id = Some id; rule_id = None; clause_id = None } }

let with_rule t id =
  { t with enclosing = { t.enclosing with rule_id = Some id } }

let with_clause t id =
  { t with enclosing = { t.enclosing with clause_id = Some id } }

let enclosing_path t =
  [ t.enclosing.def_id; t.enclosing.rule_id; t.enclosing.clause_id ]
  |> List.filter_map Fun.id
