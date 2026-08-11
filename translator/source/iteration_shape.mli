val flat_optional_element : Il.Ast.typ -> Il.Ast.typ option
val flat_list_element : Il.Ast.typ -> Il.Ast.typ option
val flat_repeated_element : Il.Ast.typ -> Il.Ast.typ option

val list_of_lists_element : Il.Ast.typ -> Il.Ast.typ option
val list_of_optionals_element : Il.Ast.typ -> Il.Ast.typ option
val optional_list_element : Il.Ast.typ -> Il.Ast.typ option

val repeated_list_element : Il.Ast.typ -> Il.Ast.typ option
val repeated_sequence_element : Il.Ast.typ -> Il.Ast.typ option
