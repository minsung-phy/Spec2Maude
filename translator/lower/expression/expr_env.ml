type binding =
  { term : Maude_ir.term
  ; sort : Maude_ir.sort
  ; typ : Il.Ast.typ
  }

type introduced_binding =
  { id : string
  ; binding : binding
  ; subtype_roundtrip : Pattern_subtyping.subtype_roundtrip option
  }

type entry =
  { binding : binding
  ; subtype_roundtrip : Pattern_subtyping.subtype_roundtrip option
  }

type t =
  { vars : (string * entry) list
  ; condition_bound_vars : string list option
  }

let empty =
  { vars = []; condition_bound_vars = None }

let add env id binding =
  { env with
    vars =
      (id, { binding; subtype_roundtrip = None })
      :: List.remove_assoc id env.vars
  }

let find env id =
  List.assoc_opt id env.vars |> Option.map (fun entry -> entry.binding)

let bindings env =
  List.map (fun (_id, entry) -> entry.binding) env.vars

let introduce id binding =
  { id; binding; subtype_roundtrip = None }

let of_pattern_introduction
    (introduced : Pattern_subtyping.introduced_binding) =
  let binding = introduced.binding in
  { id = introduced.id
  ; binding =
      { term = binding.term
      ; sort = binding.sort
      ; typ = binding.typ
      }
  ; subtype_roundtrip = introduced.subtype_roundtrip
  }

let add_introduced env introduced =
  { env with
    vars =
      (introduced.id,
       { binding = introduced.binding
       ; subtype_roundtrip = introduced.subtype_roundtrip
       })
      :: List.remove_assoc introduced.id env.vars
  }

let find_subtype_roundtrip env id =
  Option.bind
    (List.assoc_opt id env.vars)
    (fun entry -> entry.subtype_roundtrip)

let forget_subtype_roundtrips env =
  let forget (id, entry) =
    id, { entry with subtype_roundtrip = None }
  in
  { env with vars = List.map forget env.vars }

let bound_vars env =
  env.vars
  |> List.concat_map (fun (_id, entry) ->
    Condition_closure.term_vars entry.binding.term)
  |> List.sort_uniq String.compare

let condition_bound_vars env =
  env.condition_bound_vars

let with_condition_bound_vars env vars =
  { env with
    condition_bound_vars = Some (List.sort_uniq String.compare vars)
  }
