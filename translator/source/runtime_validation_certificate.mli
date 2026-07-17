type t =
  | Certified
  | Unavailable of string

val premise_shape :
  predicate_marker:bool ->
  source_params:Il.Ast.param list ->
  mixop_equal:(Il.Ast.mixop -> Il.Ast.mixop -> bool) ->
  declaration_mixop:Il.Ast.mixop ->
  premise_args:Il.Ast.arg list ->
  premise_mixop:Il.Ast.mixop ->
  result:Il.Ast.typ ->
  premise_exp:Il.Ast.exp ->
  t

val certify :
  predicate_marker:bool ->
  source_params:Il.Ast.param list ->
  runtime_demanded:bool ->
  mixop_equal:(Il.Ast.mixop -> Il.Ast.mixop -> bool) ->
  declaration_mixop:Il.Ast.mixop ->
  premise_args:Il.Ast.arg list ->
  premise_mixop:Il.Ast.mixop ->
  result:Il.Ast.typ ->
  premise_exp:Il.Ast.exp ->
  t

val certified :
  predicate_marker:bool ->
  source_params:Il.Ast.param list ->
  runtime_demanded:bool ->
  mixop_equal:(Il.Ast.mixop -> Il.Ast.mixop -> bool) ->
  declaration_mixop:Il.Ast.mixop ->
  premise_args:Il.Ast.arg list ->
  premise_mixop:Il.Ast.mixop ->
  result:Il.Ast.typ ->
  premise_exp:Il.Ast.exp ->
  bool
