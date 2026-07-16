open Il.Ast
open Util.Source

let diagnostic ctx origin id constructor rule reason suggestion =
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin
    ~constructor
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason:("annotated execution relation `" ^ id.it ^ "`: " ^ reason)
    ~suggestion
    ?source_echo:(Option.map Il.Print.string_of_rule rule)
    ()

let split count components =
  let rec loop n left right =
    if n = 0 then List.rev left, right
    else
      match right with
      | [] -> List.rev left, []
      | item :: rest -> loop (n - 1) (item :: left) rest
  in
  loop count [] components

let rule_bundle input_count component_count rule =
  match rule.it with
  | RuleD (_, _, _, exp, prems) ->
    Option.map (fun components ->
      let inputs, outputs = split input_count components in
      inputs, outputs, prems)
      (Analysis.Relation_graph.exp_components_for_count component_count exp)

type side = Left | Right

type pattern =
  | PVar of side * string
  | PNode of string * string * pattern list
  | POpaque of Il.Ast.exp

let node family tag args = PNode (family, tag, args)

let rec pattern side (exp : exp) =
  let children = List.map (pattern side) in
  match exp.it with
  | VarE id -> PVar (side, id.it)
  | BoolE _ -> node "bool" (Il.Print.string_of_exp exp) []
  | NumE _ -> node "num" (Il.Print.string_of_exp exp) []
  | TextE _ -> node "text" (Il.Print.string_of_exp exp) []
  | TupE exps -> node "tuple" (string_of_int (List.length exps)) (children exps)
  | CaseE (mixop, arg) ->
    node
      ("case:" ^ Il.Print.string_of_typ exp.note)
      (Analysis.Relation_graph.mixop_shape_text mixop)
      [ pattern side arg ]
  | OptE None -> node ("opt:" ^ Il.Print.string_of_typ exp.note) "none" []
  | OptE (Some value) ->
    node ("opt:" ^ Il.Print.string_of_typ exp.note) "some" [ pattern side value ]
  | ListE exps -> node "list" (string_of_int (List.length exps)) (children exps)
  | CatE (left, right) -> node "cat" "cat" [ pattern side left; pattern side right ]
  | StrE fields ->
    let names = List.map (fun (atom, _) -> Xl.Atom.to_string atom) fields in
    node "record" (String.concat "," names)
      (fields |> List.map (fun (_, value) -> pattern side value))
  | LiftE inner -> node "lift" (Il.Print.string_of_typ exp.note) [ pattern side inner ]
  | CvtE (inner, source, target) ->
    node "cvt"
      (Il.Print.string_of_typ (NumT source $ no_region) ^ ":"
       ^ Il.Print.string_of_typ (NumT target $ no_region))
      [ pattern side inner ]
  | SubE (inner, source, target) ->
    node "sub"
      (Il.Print.string_of_typ source ^ ":" ^ Il.Print.string_of_typ target)
      [ pattern side inner ]
  | UnE _ | BinE _ | CmpE _ | ProjE _ | UncaseE _ | TheE _ | DotE _
  | CompE _ | MemE _ | LenE _ | IdxE _ | SliceE _ | UpdE _ | ExtE _
  | IfE _ | CallE _ | IterE _ -> POpaque exp

let rec deref substitution = function
  | PVar (side, id) as variable ->
    let key = side, id in
    (match List.assoc_opt key substitution with
    | None -> variable
    | Some value -> deref substitution value)
  | pattern -> pattern

let rec occurs substitution key pattern =
  match deref substitution pattern with
  | PVar (side, id) -> key = (side, id)
  | PNode (_, _, children) -> List.exists (occurs substitution key) children
  | POpaque _ -> false

let bind substitution key value =
  let value = deref substitution value in
  if value = PVar (fst key, snd key) then Some substitution
  else if occurs substitution key value then None
  else Some ((key, value) :: substitution)

let rec unify substitution left right =
  let left = deref substitution left and right = deref substitution right in
  match left, right with
  | PVar (side, id), value | value, PVar (side, id) ->
    bind substitution (side, id) value
  | PNode (left_family, left_tag, left_args),
    PNode (right_family, right_tag, right_args)
    when left_family = right_family && left_tag = right_tag
         && List.length left_args = List.length right_args ->
    List.fold_left2
      (fun substitution left right ->
        Option.bind substitution (fun substitution -> unify substitution left right))
      (Some substitution) left_args right_args
  | PNode (left_family, _, _), PNode (right_family, _, _)
    when left_family = right_family -> None
  | POpaque left, POpaque right when Il.Eq.eq_exp left right -> Some substitution
  | PNode _, PNode _ | POpaque _, _ | _, POpaque _ -> Some substitution

let overlap substitution left right =
  if List.length left <> List.length right then None
  else
    List.fold_left2
      (fun substitution left right ->
        Option.bind substitution (fun substitution ->
          unify substitution (pattern Left left) (pattern Right right)))
      (Some substitution) left right

let rec equal_under substitution left right =
  match deref substitution left, deref substitution right with
  | PVar (left_side, left_id), PVar (right_side, right_id) ->
    left_side = right_side && left_id = right_id
  | PNode (left_family, left_tag, left_args),
    PNode (right_family, right_tag, right_args) ->
    left_family = right_family && left_tag = right_tag
    && List.length left_args = List.length right_args
    && List.for_all2 (equal_under substitution) left_args right_args
  | POpaque left, POpaque right -> Il.Eq.eq_exp left right
  | PVar _, _ | _, PVar _ | PNode _, _ | _, PNode _ -> false

let outputs_agree substitution left right =
  List.length left = List.length right
  && List.for_all2
       (fun left right ->
         equal_under substitution (pattern Left left) (pattern Right right))
       left right

let validate ctx origin id (shape : Relation_shape.execution_shape) rules =
  let graph = Context.function_graph ctx in
  match Analysis.Function_graph.find_relation graph id.it with
  | Some relation
    when Analysis.Function_graph.relation_has_maude_equational_view relation ->
    let input_count = List.length shape.inputs in
    let component_count = input_count + List.length shape.outputs in
    let bundles = List.map (fun rule -> rule, rule_bundle input_count component_count rule) rules in
    let malformed =
      bundles
      |> List.filter_map (function
        | rule, None ->
          Some
            (diagnostic ctx origin id
               "RelD/maude-equational-view/malformed-bundle"
               (Some rule)
               (Printf.sprintf
                  "RuleD head does not preserve the declared %d-input/%d-output bundle"
                  input_count (List.length shape.outputs))
               "Make every RuleD head match the declared execution relation bundle without flattening or dropping components")
        | _, Some _ -> None)
    in
    let unconditional =
      bundles
      |> List.filter_map (function
        | rule, Some (inputs, outputs, []) -> Some (rule, inputs, outputs)
        | _, Some (_, _, _ :: _) | _, None -> None)
    in
    let rec conflicts diagnostics = function
      | [] -> diagnostics
      | (rule, inputs, outputs) :: rest ->
        let new_diagnostics =
          rest
          |> List.filter_map (fun (_other_rule, other_inputs, other_outputs) ->
            match overlap [] inputs other_inputs with
            | Some substitution when not (outputs_agree substitution outputs other_outputs) ->
              Some
                (diagnostic ctx origin id
                   "RelD/maude-equational-view/right-uniqueness"
                   (Some rule)
                   "two unconditional RuleD input patterns structurally overlap, but their completed outputs are not provably equal on the overlap"
                   "Make the alternatives structurally disjoint, make their completed outputs agree under input bindings, or do not assert hint(maude_equational_view)")
            | Some _ | None -> None)
        in
        conflicts (List.rev_append new_diagnostics diagnostics) rest
    in
    malformed @ List.rev (conflicts [] unconditional)
  | Some _ | None -> []
