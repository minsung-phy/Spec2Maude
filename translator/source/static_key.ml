open Il.Ast

type exp_binding =
  { exp : exp
  ; key : string
  }

type typ_binding =
  { typ : typ
  ; key : string
  }

type env =
  { exp_vars : (string * exp_binding) list
  ; typ_vars : (string * typ_binding) list
  ; def_vars : (string * string) list
  ; gram_vars : (string * string) list
  }

type typ_ref =
  { category_id : string
  ; static_args_key : string option
  }

let empty =
  { exp_vars = []
  ; typ_vars = []
  ; def_vars = []
  ; gram_vars = []
  }

let remove_assoc id bindings =
  bindings |> List.filter (fun (candidate, _) -> candidate <> id)

let lookup id bindings =
  List.assoc_opt id bindings

let join components =
  match components with
  | [] -> None
  | _ -> Some (String.concat " | " components)

let parens = function
  | [] -> ""
  | components -> "(" ^ String.concat ", " components ^ ")"

let key_of_id prefix id =
  prefix ^ ":" ^ id

let rec key_of_iter env = function
  | Opt -> "iter:?"
  | List -> "iter:*"
  | List1 -> "iter:+"
  | ListN (exp, index_id) ->
    let suffix =
      match index_id with
      | None -> ""
      | Some id -> ", index:" ^ id.it
    in
    "iter:^(" ^ (key_of_exp env exp) ^ suffix ^ ")"

and key_of_exp env exp =
  match exp.it with
  | VarE id ->
    (match lookup id.it env.exp_vars with
    | Some binding -> binding.key
    | None -> key_of_id "exp:var" id.it)
  | BoolE value -> "exp:bool:" ^ string_of_bool value
  | NumE num -> "exp:num:" ^ Xl.Num.to_string num
  | TextE text -> "exp:text:" ^ String.escaped text
  | UnE (_, _, inner) ->
    "exp:un:" ^ Il.Print.string_of_exp exp ^ parens [ key_of_exp env inner ]
  | BinE (_, _, left, right) ->
    "exp:bin:" ^ Il.Print.string_of_exp exp ^ parens [ key_of_exp env left; key_of_exp env right ]
  | CmpE (_, _, left, right) ->
    "exp:cmp:" ^ Il.Print.string_of_exp exp ^ parens [ key_of_exp env left; key_of_exp env right ]
  | TupE exps -> "exp:tup" ^ parens (List.map (key_of_exp env) exps)
  | ProjE (inner, index) ->
    "exp:proj:" ^ string_of_int index ^ parens [ key_of_exp env inner ]
  | CaseE (mixop, arg) ->
    "exp:case:" ^ Il.Print.string_of_mixop mixop ^ parens [ key_of_exp env arg ]
  | UncaseE (inner, mixop) ->
    "exp:uncase:" ^ Il.Print.string_of_mixop mixop ^ parens [ key_of_exp env inner ]
  | OptE None -> "exp:opt:none"
  | OptE (Some inner) -> "exp:opt:some" ^ parens [ key_of_exp env inner ]
  | TheE inner -> "exp:the" ^ parens [ key_of_exp env inner ]
  | StrE fields ->
    let fields =
      fields
      |> List.map (fun (atom, field_exp) ->
        Xl.Atom.to_string atom ^ "=" ^ key_of_exp env field_exp)
    in
    "exp:record" ^ parens fields
  | DotE (inner, atom) ->
    "exp:dot:" ^ Xl.Atom.to_string atom ^ parens [ key_of_exp env inner ]
  | CompE (left, right) ->
    "exp:comp" ^ parens [ key_of_exp env left; key_of_exp env right ]
  | ListE exps -> "exp:list" ^ parens (List.map (key_of_exp env) exps)
  | LiftE inner -> "exp:lift" ^ parens [ key_of_exp env inner ]
  | MemE (left, right) ->
    "exp:mem" ^ parens [ key_of_exp env left; key_of_exp env right ]
  | LenE inner -> "exp:len" ^ parens [ key_of_exp env inner ]
  | CatE (left, right) ->
    "exp:cat" ^ parens [ key_of_exp env left; key_of_exp env right ]
  | IdxE (seq, index) ->
    "exp:idx" ^ parens [ key_of_exp env seq; key_of_exp env index ]
  | SliceE (seq, left, right) ->
    "exp:slice" ^ parens [ key_of_exp env seq; key_of_exp env left; key_of_exp env right ]
  | UpdE (record, _path, value) ->
    "exp:update:" ^ Il.Print.string_of_exp exp ^ parens [ key_of_exp env record; key_of_exp env value ]
  | ExtE (record, _path, value) ->
    "exp:extend:" ^ Il.Print.string_of_exp exp ^ parens [ key_of_exp env record; key_of_exp env value ]
  | CallE (id, args) ->
    "exp:call:" ^ id.it ^ parens (List.map (key_of_arg env) args)
  | IterE (body, (iter, generators)) ->
    let generators =
      generators
      |> List.map (fun ((generator_id : id), source) ->
        generator_id.it ^ "<-" ^ key_of_exp env source)
    in
    "exp:iter:" ^ key_of_iter env iter ^ parens (key_of_exp env body :: generators)
  | CvtE (inner, _, _) ->
    "exp:cvt:" ^ Il.Print.string_of_exp exp ^ parens [ key_of_exp env inner ]
  | SubE (inner, source_typ, target_typ) ->
    "exp:sub"
    ^ parens [ key_of_exp env inner; key_of_typ env source_typ; key_of_typ env target_typ ]
  | IfE (cond, then_exp, else_exp) ->
    "exp:if" ^ parens [ key_of_exp env cond; key_of_exp env then_exp; key_of_exp env else_exp ]

and key_of_typ env typ =
  match typ.it with
  | VarT (id, []) ->
    (match lookup id.it env.typ_vars with
    | Some binding -> binding.key
    | None -> key_of_id "typ" id.it)
  | VarT (id, args) ->
    key_of_id "typ" id.it ^ parens (List.map (key_of_arg env) args)
  | BoolT -> "typ:bool"
  | NumT typ -> "typ:num:" ^ Xl.Num.string_of_typ typ
  | TextT -> "typ:text"
  | TupT fields ->
    let fields =
      fields
      |> List.map (fun (id, typ) ->
        id.Util.Source.it ^ ":" ^ key_of_typ env typ)
    in
    "typ:tup" ^ parens fields
  | IterT (inner, iter) ->
    "typ:iter:" ^ key_of_iter env iter ^ parens [ key_of_typ env inner ]

and key_of_sym env (sym : sym) =
  match sym.it with
  | VarG (id, args) ->
    (match args, lookup id.it env.gram_vars with
    | [], Some key -> key
    | _ -> key_of_id "gram" id.it ^ parens (List.map (key_of_arg env) args))
  | _ -> "gram:" ^ Il.Print.string_of_sym sym

and key_of_arg env (arg : arg) =
  match arg.it with
  | ExpA exp -> key_of_exp env exp
  | TypA typ -> key_of_typ env typ
  | DefA id ->
    (match lookup id.it env.def_vars with
    | Some key -> key
    | None -> key_of_id "def" id.it)
  | GramA sym -> key_of_sym env sym

let of_arg ?(env = empty) arg =
  key_of_arg env arg

let of_args ?(env = empty) (args : arg list) =
  args
  |> List.map (key_of_arg env)
  |> join

let rec typ_ref_with_visited env visited (typ : typ) =
  match typ.it with
  | VarT (id, []) ->
    (match lookup id.it env.typ_vars with
    | Some binding when not (List.mem id.it visited) ->
      typ_ref_with_visited env (id.it :: visited) binding.typ
    | _ -> Some { category_id = id.it; static_args_key = None })
  | VarT (id, args) ->
    Some { category_id = id.it; static_args_key = of_args ~env args }
  | BoolT | NumT _ | TextT | TupT _ | IterT _ -> None

let typ_ref ?(env = empty) typ =
  typ_ref_with_visited env [] typ

let of_typ ?(env = empty) typ =
  match typ_ref ~env typ with
  | Some ref -> ref.static_args_key
  | None -> None

let add_exp env id exp =
  let binding = { exp; key = key_of_exp env exp } in
  { env with exp_vars = (id, binding) :: remove_assoc id env.exp_vars }

let add_typ env id typ =
  let binding = { typ; key = key_of_typ env typ } in
  { env with typ_vars = (id, binding) :: remove_assoc id env.typ_vars }

let add_def env id target_id =
  let key = key_of_id "def" target_id in
  { env with def_vars = (id, key) :: remove_assoc id env.def_vars }

let add_gram env id sym =
  let key = key_of_sym env sym in
  { env with gram_vars = (id, key) :: remove_assoc id env.gram_vars }

let of_static_typ_env bindings =
  bindings
  |> List.fold_left (fun env (id, typ) -> add_typ env id typ) empty

let bind_param_arg env (param : param) (arg : arg) =
  match param.it, arg.it with
  | ExpP (id, _), ExpA exp -> Ok (add_exp env id.it exp)
  | TypP id, TypA typ -> Ok (add_typ env id.it typ)
  | DefP (id, _, _), DefA target_id -> Ok (add_def env id.it target_id.it)
  | GramP (id, _, _), GramA sym -> Ok (add_gram env id.it sym)
  | ExpP (id, _), _ ->
    Error ("ExpP parameter `" ^ id.it ^ "` requires an ExpA argument")
  | TypP id, _ ->
    Error ("TypP parameter `" ^ id.it ^ "` requires a TypA argument")
  | DefP (id, _, _), _ ->
    Error ("DefP parameter `" ^ id.it ^ "` requires a DefA argument")
  | GramP (id, _, _), _ ->
    Error ("GramP parameter `" ^ id.it ^ "` requires a GramA argument")

let rec fold_params_args env params args =
  match params, args with
  | [], [] -> Ok env
  | param :: params, arg :: args ->
    (match bind_param_arg env param arg with
    | Ok env -> fold_params_args env params args
    | Error _ as error -> error)
  | [], _ :: _ -> Error "static specialization received more arguments than parameters"
  | _ :: _, [] -> Error "static specialization received fewer arguments than parameters"

let of_params_args params args =
  fold_params_args empty params args
