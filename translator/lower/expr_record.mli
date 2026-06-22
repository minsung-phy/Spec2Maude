open Il.Ast

type callbacks =
  { lower_value : Context.t -> Expr_support.env -> Origin.t -> exp -> Expr_support.result
  ; lower_sequence : Context.t -> Expr_support.env -> Origin.t -> exp -> Expr_support.result
  }

val lower_record_literal :
  callbacks ->
  Context.t ->
  Expr_support.env ->
  Origin.t ->
  exp ->
  (atom * exp) list ->
  Expr_support.result

val lower_record_dot :
  callbacks -> Context.t -> Expr_support.env -> Origin.t -> exp -> atom -> Expr_support.result

val lower_comp :
  callbacks -> Context.t -> Expr_support.env -> Origin.t -> exp -> exp -> Expr_support.result

val lower_len :
  callbacks -> Context.t -> Expr_support.env -> Origin.t -> exp -> Expr_support.result

val lower_index :
  callbacks -> Context.t -> Expr_support.env -> Origin.t -> exp -> exp -> Expr_support.result

val lower_slice :
  callbacks ->
  Context.t ->
  Expr_support.env ->
  Origin.t ->
  exp ->
  exp ->
  exp ->
  Expr_support.result

val lower_record_update :
  callbacks ->
  Context.t ->
  Expr_support.env ->
  Origin.t ->
  exp ->
  exp ->
  path ->
  exp ->
  Expr_support.result

val lower_record_extension :
  callbacks ->
  Context.t ->
  Expr_support.env ->
  Origin.t ->
  exp ->
  exp ->
  path ->
  exp ->
  Expr_support.result
