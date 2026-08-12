type construction_domain =
  | Total_constructor
  | Certified_representation_constructor
  | Length_guarded_representation_constructor of
      { payload_index : int
      ; closed_bound : Il.Ast.exp
      ; guard_origin : Origin.t
      }
  | Guarded_constructor of string

type source_case

val source_case :
  payload_typ:Il.Ast.typ ->
  case_binds:Il.Ast.quant list ->
  case_prems:Il.Ast.prem list ->
  instance_binds:Il.Ast.quant list ->
  instance_args:Il.Ast.arg list ->
  static_args_key:string option ->
  construction_domain:construction_domain ->
  origin:Origin.t ->
  source_case

type entry =
  { source_category : string
  ; static_args_key : string option
  ; mixop : Il.Ast.mixop
  ; arity : int
  ; payload_typs : Il.Ast.typ list
  ; payload_witnesses : Maude_ir.term list
  ; payload_sorts : Maude_ir.sort list
  ; source_case : source_case option
  ; origin : Origin.t
  ; emitted : bool
  }

type category_case =
  { case_category : string
  ; case_static_key : string option
  ; case_origin : Origin.t
  }

type inclusion =
  { parent_category : string
  ; parent_static_args_key : string option
  ; child_category : string
  ; child_static_args_key : string option
  ; covered_origins : Origin.t list
  }

type t

val analyze :
  il_env:Il.Env.t ->
  source_index:Analysis.Source_index.t ->
  entries:entry list ->
  cases:category_case list ->
  inclusions:inclusion list ->
  Il.Ast.script ->
  t

val canonical_entry : t -> entry -> entry option
val equivalent : t -> entry -> entry -> bool
val shared : t -> entry -> bool
