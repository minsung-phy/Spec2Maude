open Util.Source
open Il.Ast


type capture = id * typ

type iteration_body =
  | ExpBody of exp
  | PremiseBody of prem

type iteration =
  { name : string
  ; body : exp
  ; iterexp : iterexp
  ; captures : capture list
  }

type premise_iteration =
  { name : string
  ; premise : prem
  ; body : prem
  ; iterexp : iterexp
  ; captures : capture list
  }

type t =
  { iterations : iteration list
  ; premise_iterations : premise_iteration list
  ; hints : hintdef list
  }


let sanitize name =
  name
  |> String.to_seq
  |> Seq.map (function
       | ('a'..'z' | 'A'..'Z' | '0'..'9' | '-') as char -> char
       | _ -> '-')
  |> String.of_seq

let iteration_name body =
  match body.it with
  | CallE (id, _) ->
      "map-" ^ sanitize id.it
  | _ ->
      let pos = body.at.left in
      let file = Filename.basename pos.file |> sanitize in
      if file = "" then
        Printf.sprintf "map-exp-%d-%d" pos.line pos.column
      else
        Printf.sprintf "map-%s-%d-%d" file pos.line pos.column


let index_ids = function
  | ListN (_, Some id) -> [id]
  | Opt | List | List1 | ListN (_, None) -> []

let bound_ids (iter, generators) =
  index_ids iter @ List.map fst generators

let rec remove_id name = function
  | [] -> []
  | id :: ids when id = name -> ids
  | id :: ids -> id :: remove_id name ids

let capture_variables free body iterexp =
  let bound =
    ref (List.map (fun id -> id.it) (bound_ids iterexp))
  in
  let captures = ref [] in
  let add id typ =
    let name = String.uppercase_ascii id.it in
    if Il.Free.Set.mem id.it free
       && not (List.mem id.it !bound)
       && not
            (List.exists
               (fun (captured, _) ->
                 String.uppercase_ascii captured.it = name)
               !captures)
    then
      captures := (id, typ) :: !captures
  in
  let module Visitor = Il.Iter.Make (struct
    include Il.Iter.Skip

    let visit_exp exp =
      match exp.it with
      | VarE id -> add id exp.note
      | _ -> ()

    let scope_enter id _typ =
      bound := id.it :: !bound

    let scope_exit id () =
      bound := remove_id id.it !bound
  end)
  in
  begin match body with
  | ExpBody exp -> Visitor.exp exp
  | PremiseBody prem -> Visitor.prem prem
  end;
  List.rev !captures

let capture_exp_variables body iterexp =
  capture_variables Il.Free.(free_exp body).varid (ExpBody body) iterexp

let capture_premise_variables body iterexp =
  capture_variables Il.Free.(free_prem body).varid (PremiseBody body) iterexp


let scan script =
  let iterations = ref [] in
  let premise_iterations = ref [] in
  let premise_count = ref 0 in
  let hints = ref [] in
  let add_iteration body iterexp =
    iterations :=
      { name = iteration_name body
      ; body
      ; iterexp
      ; captures = capture_exp_variables body iterexp
      }
      :: !iterations
  in
  let add_premise_iteration premise body iterexp =
    incr premise_count;
    premise_iterations :=
      { name = "iterpr-" ^ string_of_int !premise_count
      ; premise
      ; body
      ; iterexp
      ; captures = capture_premise_variables body iterexp
      }
      :: !premise_iterations
  in
  let module Visitor = Il.Iter.Make (struct
    include Il.Iter.Skip

    let visit_exp exp =
      match exp.it with
      | IterE (body, iterexp) -> add_iteration body iterexp
      | _ -> ()

    let visit_prem premise =
      match premise.it with
      | IterPr (body, iterexp) -> add_premise_iteration premise body iterexp
      | _ -> ()
  end)
  in
  let rec scan_def def =
    match def.it with
    | TypD _ | RelD _ | DecD _ ->
        Visitor.def def
    | RecD defs ->
        List.iter scan_def defs
    | HintD hintdef ->
        begin match hintdef.it with
        | TypH _ | RelH _ | DecH _ | RuleH _ ->
            hints := hintdef :: !hints
        | GramH _ ->
            ()
        end
    | GramD _ ->
        ()
  in
  List.iter scan_def script;
  { iterations = List.rev !iterations
  ; premise_iterations = List.rev !premise_iterations
  ; hints = List.rev !hints
  }

let iterations index = index.iterations
let premise_iterations index = index.premise_iterations

let premise_iteration index premise =
  List.find_opt
    (fun iteration -> iteration.premise == premise)
    index.premise_iterations

let hints index = index.hints
