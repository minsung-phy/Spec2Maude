let register_constructor
    ctx origin
    ?(status = Constructor_registry.Emitted)
    ?(construction_domain =
      Constructor_registry.Guarded_constructor
        "constructor source domain was not certified")
    ?payload_labels
    ?(payload_witnesses = [])
    ?(payload_sorts = [])
    ?static_args_key
    ~source_category
    ~mixop
    ~arity
    ~constructor_op
    ~projection_ops
    () =
  let payload_labels =
    Option.value payload_labels
      ~default:(List.init arity (fun _ -> Constructor_registry.Structural_payload))
  in
  Constructor_registry.register_checked
    (Context.constructors ctx)
    { Constructor_registry.source_category
    ; declaring_category = source_category
    ; static_args_key
    ; mixop
    ; arity
    ; constructor_op
    ; projection_ops
    ; payload_labels
    ; payload_witnesses
    ; payload_sorts
    ; origin
    ; enclosing = Context.enclosing_path ctx
    ; status
    ; construction_domain
    }

let category_ref_of_typ key_env typ =
  Static_key.typ_ref ~env:key_env typ
  |> Option.map (fun ref ->
    Naming.source_owner ref.Static_key.category_id, ref.Static_key.static_args_key)

let register_inclusion
    ctx origin
    ~reason
    ~key_env
    ?parent_static_args_key
    ~parent_category
    child_typ =
  match category_ref_of_typ key_env child_typ with
  | None -> ()
  | Some (child_category, child_static_args_key) ->
    Constructor_registry.register_inclusion
      (Context.constructors ctx)
      { Constructor_registry.parent_category
      ; parent_static_args_key
      ; child_category
      ; child_static_args_key
      ; origin
      ; reason
      }
