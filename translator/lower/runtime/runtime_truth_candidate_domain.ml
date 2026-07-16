open Il.Ast
open Maude_ir
open Util.Source

let rec term_key = function
  | Var name -> "V:" ^ name
  | Const name -> "C:" ^ name
  | Qid text -> "Q:" ^ text
  | App (op, args) ->
    "A:" ^ op ^ "(" ^ String.concat "," (List.map term_key args) ^ ")"

let dedup_terms terms =
  let _seen, terms =
    terms
    |> List.fold_left
         (fun (seen, acc) term ->
           let key = term_key term in
           if List.mem key seen then
             seen, acc
           else
             key :: seen, term :: acc)
         ([], [])
  in
  List.rev terms

let terminal_sequence terms =
  List.fold_right
    (fun term rest ->
      match rest with
      | Const "eps" -> term
      | _ -> App ("_ _", [ term; rest ]))
    terms
    (Const "eps")

let rec path_source_ids path =
  match path.it with
  | RootP -> []
  | IdxP (path, exp) -> path_source_ids path @ exp_source_ids exp
  | SliceP (path, first, last) ->
    path_source_ids path @ exp_source_ids first @ exp_source_ids last
  | DotP (path, _) -> path_source_ids path

and arg_source_ids arg =
  match arg.it with
  | ExpA exp -> exp_source_ids exp
  | TypA typ -> typ_source_ids typ
  | DefA _ | GramA _ -> []

and typ_source_ids typ =
  match typ.it with
  | VarT (_, args) -> List.concat_map arg_source_ids args
  | TupT components ->
    components
    |> List.concat_map (fun (id, typ) -> id.it :: typ_source_ids typ)
  | IterT (typ, ListN (exp, index)) ->
    let ids = typ_source_ids typ @ exp_source_ids exp in
    (match index with
    | None -> ids
    | Some id -> id.it :: ids)
  | IterT (typ, _) -> typ_source_ids typ
  | BoolT | NumT _ | TextT -> []

and exp_source_ids exp =
  match exp.it with
  | VarE id -> [ id.it ]
  | BoolE _ | NumE _ | TextE _ -> []
  | UnE (_, _, exp) | OptE (Some exp) | TheE exp | LiftE exp
  | LenE exp | UncaseE (exp, _) ->
    exp_source_ids exp
  | OptE None -> []
  | BinE (_, _, left, right) | CmpE (_, _, left, right)
  | CompE (left, right) | CatE (left, right) ->
    exp_source_ids left @ exp_source_ids right
  | TupE exps | ListE exps -> List.concat_map exp_source_ids exps
  | ProjE (exp, _) | DotE (exp, _) | CaseE (_, exp) -> exp_source_ids exp
  | StrE fields ->
    fields |> List.concat_map (fun (_atom, exp) -> exp_source_ids exp)
  | MemE (left, right) | IdxE (left, right) ->
    exp_source_ids left @ exp_source_ids right
  | SliceE (base, first, last) ->
    exp_source_ids base @ exp_source_ids first @ exp_source_ids last
  | UpdE (base, path, value) | ExtE (base, path, value) ->
    exp_source_ids base @ path_source_ids path @ exp_source_ids value
  | CallE (_, args) -> List.concat_map arg_source_ids args
  | IterE (body, (_iter, generators)) ->
    exp_source_ids body
    @ (generators
       |> List.concat_map (fun (id, source) ->
         id.it :: exp_source_ids source))
  | CvtE (exp, _, _) -> exp_source_ids exp
  | SubE (exp, from_typ, to_typ) ->
    exp_source_ids exp @ typ_source_ids from_typ @ typ_source_ids to_typ
  | IfE (test, then_, else_) ->
    exp_source_ids test @ exp_source_ids then_ @ exp_source_ids else_

let is_closed_exp exp =
  exp_source_ids exp = []

let split_exps prefix_arity exps =
  let rec take n acc rest =
    if n = 0 then Some (List.rev acc, rest)
    else
      match rest with
      | [] -> None
      | exp :: rest -> take (n - 1) (exp :: acc) rest
  in
  match take prefix_arity [] exps with
  | Some (_prefix, [ left; right ]) -> Some (left, right)
  | Some _ | None -> None

let lower_closed_candidate ctx origin exp =
  if not (is_closed_exp exp) then
    None, []
  else
    let result = Expr_translate.lower_value ctx Expr_env.empty origin exp in
    match result.term with
    | Some term -> Some term, result.diagnostics
    | None -> None, result.diagnostics

let query_candidates plan input_vars =
  let prefix_arity = plan.Runtime_witness_domain.candidate.prefix_arity in
  let rec drop n vars =
    if n = 0 then vars
    else
      match vars with
      | [] -> []
      | _ :: vars -> drop (n - 1) vars
  in
  match drop prefix_arity input_vars with
  | left :: right :: _ -> [ left; right ]
  | _ -> []

let child_origin parent segment ast_constructor region source_echo =
  Origin.with_child ?source_echo parent segment ~ast_constructor region

let rule_origin parent index (rule : Analysis.Function_graph.runtime_search_rule) =
  child_origin
    parent
    (Printf.sprintf "RuleD[%d]" index)
    "RuleD"
    rule.origin.region
    rule.source_echo

let rule_head_candidates ctx ~parent ~input_count plan rules =
  let prefix_arity = plan.Runtime_witness_domain.candidate.prefix_arity in
  let rec loop index terms diagnostics = function
    | [] -> List.rev terms, List.rev diagnostics
    | rule :: rules ->
      let origin = rule_origin parent index rule in
      let candidates =
        match
          Analysis.Relation_graph.exp_components_for_count input_count rule.head
        with
        | None -> []
        | Some exps ->
          (match split_exps prefix_arity exps with
          | None -> []
          | Some (left, right) -> [ left; right ])
      in
      let terms, diagnostics =
        candidates
        |> List.fold_left
             (fun (terms, diagnostics) exp ->
               let candidate_origin =
                 child_origin
                   origin
                   "finite-candidate"
                   "RuntimeTruthSearch/Candidate"
                   exp.at
                   (Some (Il.Print.string_of_exp exp))
               in
               match lower_closed_candidate ctx candidate_origin exp with
               | Some term, new_diagnostics ->
                 term :: terms, List.rev_append new_diagnostics diagnostics
               | None, new_diagnostics ->
                 terms, List.rev_append new_diagnostics diagnostics)
             (terms, diagnostics)
      in
      loop (index + 1) terms diagnostics rules
  in
  loop 1 [] [] rules
