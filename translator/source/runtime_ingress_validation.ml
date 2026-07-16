open Il.Ast
open Util.Source

module Call_count = struct
  type t = (string, int) Hashtbl.t

  let create () = Hashtbl.create 31

  let add counts id =
    let count = Option.value ~default:0 (Hashtbl.find_opt counts id) in
    Hashtbl.replace counts id (count + 1)

  let get counts id = Option.value ~default:0 (Hashtbl.find_opt counts id)
end

module Calls (Acc : sig val counts : Call_count.t end) = Il.Iter.Make (struct
  include Il.Iter.Skip

  let visit_exp (exp : exp) =
    match exp.it with
    | CallE (id, _) -> Call_count.add Acc.counts id.it
    | _ -> ()
end)

let calls_of_exp exp =
  let counts = Call_count.create () in
  let module Walk = Calls (struct let counts = counts end) in
  Walk.exp exp;
  counts

let calls_of_def counts def =
  let module Walk = Calls (struct let counts = counts end) in
  Walk.def def

let rec typ_categories typ =
  match typ.it with
  | VarT (id, _) -> [ Naming.source_owner id.it ]
  | TupT fields -> List.concat_map (fun (_, typ) -> typ_categories typ) fields
  | IterT (typ, _) -> typ_categories typ
  | BoolT | NumT _ | TextT -> []

let add_categories set typ =
  typ_categories typ |> List.iter (fun id -> Hashtbl.replace set id ())

module Exp_categories (Acc : sig val categories : (string, unit) Hashtbl.t end) =
  Il.Iter.Make (struct
    include Il.Iter.Skip

    let visit_exp (exp : exp) =
      add_categories Acc.categories exp.note;
      match exp.it with
      | SubE (_, source, target) ->
        add_categories Acc.categories source;
        add_categories Acc.categories target
      | _ -> ()
  end)

let add_exp_categories categories exp =
  let module Walk = Exp_categories (struct let categories = categories end) in
  Walk.exp exp

let split count components =
  let rec loop count left right =
    if count = 0 then List.rev left, right
    else match right with
      | [] -> List.rev left, []
      | component :: right -> loop (count - 1) (component :: left) right
  in
  loop count [] components

let rule_output_exps params mixop result rule =
  match rule.it with
  | RuleD (_, _, _, head, _) ->
    let shape = Relation_shape.of_reld params mixop result in
    let component_count = List.length shape.components in
    match Analysis.Relation_graph.exp_components_for_count component_count head with
    | None -> [ head ]
    | Some components ->
      (match shape.decision with
      | Relation_shape.Deterministic_candidate shape ->
        snd (split (List.length shape.inputs) components)
      | Relation_shape.Execution shape ->
        snd (split (List.length shape.inputs) components)
      | Relation_shape.Static_validation _ | Runtime_predicate _ -> []
      | Relation_shape.Unknown _ -> [ head ])

let add_rule_output_categories set params mixop result rules =
  if rules <> [] then (
    match (Relation_shape.of_reld params mixop result).decision with
    | Relation_shape.Deterministic_candidate shape -> add_categories set shape.output.typ
    | Relation_shape.Execution shape ->
      List.iter (fun (component : Relation_shape.component) ->
        add_categories set component.typ) shape.outputs
    | Relation_shape.Static_validation _ | Runtime_predicate _ -> ()
    | Relation_shape.Unknown _ -> add_categories set result;
    rules
    |> List.concat_map (rule_output_exps params mixop result)
    |> List.iter (add_exp_categories set))

let category_links source_index =
  let links = ref [] in
  let add parent typ =
    typ_categories typ |> List.iter (fun child -> links := (parent, child) :: !links)
  in
  let add_deftyp parent deftyp =
    match deftyp.it with
    | AliasT typ -> add parent typ
    | StructT fields ->
      List.iter (fun (_, (typ, _, _), _) -> add parent typ) fields
    | VariantT cases ->
      List.iter (fun (_, (typ, _, _), _) -> add parent typ) cases
  in
  Analysis.Source_index.entries source_index
  |> List.iter (fun entry ->
    match entry.Analysis.Source_index.def.it with
    | TypD (id, _, insts) ->
      let parent = Naming.source_owner id.it in
      List.iter (fun inst ->
        match inst.it with InstD (_, _, deftyp) -> add_deftyp parent deftyp) insts
    | RelD _ | DecD _ | GramD _ | RecD _ | HintD _ -> ());
  !links

let close_categories categories links =
  let changed = ref true in
  while !changed do
    changed := false;
    List.iter (fun (left, right) ->
      if Hashtbl.mem categories left || Hashtbl.mem categories right then (
        if not (Hashtbl.mem categories left) then changed := true;
        if not (Hashtbl.mem categories right) then changed := true;
        Hashtbl.replace categories left ();
        Hashtbl.replace categories right ())) links
  done

let synthesized_categories source_index =
  let categories = Hashtbl.create 31 in
  Analysis.Source_index.entries source_index
  |> List.iter (fun entry ->
    match entry.Analysis.Source_index.def.it with
    | DecD (_, _, result, clauses) when clauses <> [] ->
      add_categories categories result;
      clauses |> List.iter (fun clause ->
        match clause.it with DefD (_, _, rhs, _) -> add_exp_categories categories rhs)
    | RelD (_, params, mixop, result, rules) ->
      add_rule_output_categories categories params mixop result rules
    | TypD _ | DecD _ | GramD _ | RecD _ | HintD _ -> ());
  close_categories categories (category_links source_index);
  categories

let builtin_declarations source_index =
  let builtins = Hashtbl.create 31 in
  Analysis.Source_index.entries source_index
  |> List.iter (fun entry ->
    match entry.Analysis.Source_index.def.it with
    | HintD { it = DecH (id, hints); _ }
      when List.exists (fun hint -> hint.hintid.it = "builtin") hints ->
      Hashtbl.replace builtins id.it ()
    | TypD _ | RelD _ | DecD _ | GramD _ | RecD _ | HintD _ -> ());
  builtins

let clause_free_declarations source_index builtins =
  let declarations = Hashtbl.create 31 in
  Analysis.Source_index.entries source_index
  |> List.iter (fun entry ->
    match entry.Analysis.Source_index.def.it with
    | DecD (id, _, _, clauses) ->
      let clause_free =
        clauses = [] && not (Hashtbl.mem builtins id.it)
        && Option.value ~default:true (Hashtbl.find_opt declarations id.it)
      in
      Hashtbl.replace declarations id.it clause_free
    | TypD _ | RelD _ | GramD _ | RecD _ | HintD _ -> ());
  declarations

let exp_contains_call id exp =
  Call_count.get (calls_of_exp exp) id > 0

let rec binding_side = function
  | { it = VarE _; _ } -> true
  | { it = SubE (exp, _, _) | CvtE (exp, _, _); _ } -> binding_side exp
  | _ -> false

let rec binds_call_result id exp =
  let nested = binds_call_result id in
  match exp.it with
  | CmpE (`EqOp, _, left, right) ->
    (binding_side left && exp_contains_call id right)
    || (binding_side right && exp_contains_call id left)
    || nested left || nested right
  | UnE (_, _, exp) | ProjE (exp, _) | UncaseE (exp, _) | TheE exp
  | DotE (exp, _) | LiftE exp | LenE exp | CvtE (exp, _, _) | SubE (exp, _, _) ->
    nested exp
  | BinE (_, _, left, right) | CmpE (_, _, left, right)
  | CompE (left, right) | MemE (left, right) | CatE (left, right)
  | IdxE (left, right) -> nested left || nested right
  | TupE exps | ListE exps -> List.exists nested exps
  | CaseE (_, exp) -> nested exp
  | OptE exp -> Option.fold ~none:false ~some:nested exp
  | StrE fields -> List.exists (fun (_, exp) -> nested exp) fields
  | SliceE (exp, start, stop) | IfE (exp, start, stop) ->
    nested exp || nested start || nested stop
  | UpdE (exp, _, value) | ExtE (exp, _, value) -> nested exp || nested value
  | CallE (_, args) ->
    List.exists (fun arg -> match arg.it with ExpA exp -> nested exp | _ -> false) args
  | IterE (body, (_, generators)) ->
    nested body || List.exists (fun (_, exp) -> nested exp) generators
  | VarE _ | BoolE _ | NumE _ | TextE _ -> false

type allowed_use =
  { category_id : string
  ; condition : exp
  ; calls : Call_count.t
  }

let typd_uses source_index =
  let uses = ref [] in
  let visit_prem category_id prem =
    match prem.it with
    | IfPr exp ->
      let calls = calls_of_exp exp in
      if Hashtbl.length calls > 0 then
        uses := { category_id = Naming.source_owner category_id; condition = exp; calls } :: !uses
    | RulePr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> ()
  in
  let visit_deftyp category_id deftyp =
    match deftyp.it with
    | VariantT cases ->
      cases |> List.iter (fun (_, (_, _, prems), _) -> List.iter (visit_prem category_id) prems)
    | StructT fields ->
      fields |> List.iter (fun (_, (_, _, prems), _) -> List.iter (visit_prem category_id) prems)
    | AliasT _ -> ()
  in
  Analysis.Source_index.entries source_index
  |> List.iter (fun entry ->
    match entry.Analysis.Source_index.def.it with
    | TypD (id, _, insts) ->
      insts |> List.iter (fun inst ->
        match inst.it with InstD (_, _, deftyp) -> visit_deftyp id.it deftyp)
    | RelD _ | DecD _ | GramD _ | RecD _ | HintD _ -> ());
  List.rev !uses

type discharge =
  { declarations : string list
  }

type t =
  { eligible : (string, unit) Hashtbl.t
  ; synthesized : (string, unit) Hashtbl.t
  }

let of_source_index source_index =
  let total = Call_count.create () in
  Analysis.Source_index.entries source_index
  |> List.iter (fun entry -> calls_of_def total entry.Analysis.Source_index.def);
  let synthesized = synthesized_categories source_index in
  let uses = typd_uses source_index in
  let allowed = Call_count.create () in
  uses |> List.iter (fun use ->
    if not (Hashtbl.mem synthesized use.category_id) then
      Hashtbl.iter (fun id count ->
        if not (binds_call_result id use.condition) then
          for _ = 1 to count do Call_count.add allowed id done)
        use.calls);
  let declarations = clause_free_declarations source_index (builtin_declarations source_index) in
  let eligible = Hashtbl.create 31 in
  Hashtbl.iter (fun id clause_free ->
    let count = Call_count.get total id in
    if clause_free && count > 0 && Call_count.get allowed id = count then
      Hashtbl.replace eligible id ())
    declarations;
  { eligible; synthesized }

let rec ingress_only_condition eligible exp =
  match exp.it with
  | BinE (`AndOp, _, left, right) ->
    ingress_only_condition eligible left && ingress_only_condition eligible right
  | _ ->
    let calls = calls_of_exp exp in
    Hashtbl.length calls > 0
    && (Hashtbl.to_seq_keys calls
        |> Seq.for_all (fun id ->
          Hashtbl.mem eligible id && not (binds_call_result id exp)))

let find t ~category_id prem =
  match prem.it with
  | IfPr exp when not (Hashtbl.mem t.synthesized category_id) ->
    let calls = calls_of_exp exp in
    let declarations =
      Hashtbl.to_seq_keys calls |> List.of_seq |> List.sort_uniq String.compare
    in
    if declarations <> [] && ingress_only_condition t.eligible exp
    then Some { declarations }
    else None
  | IfPr _ | RulePr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> None
