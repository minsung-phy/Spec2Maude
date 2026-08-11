type t

val analyze : Il.Env.t -> Source_index.t -> t

val field_representation :
  t -> owner_id:string -> Il.Ast.atom -> Sequence_representation.t

val path_representation : t -> Il.Ast.path -> Sequence_representation.t
