open Util.Source
open Il.Ast


type capture = id * typ

type iteration =
  { name : string
  ; body : exp
  ; iterexp : iterexp
  ; captures : capture list
  }

type t =
  { iterations : iteration list
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

let capture_variables body iterexp =
  let bound =
    ref (List.map (fun id -> id.it) (bound_ids iterexp))
  in
  let captures = ref [] in
  let add id typ =
    let name = String.uppercase_ascii id.it in
    if not (List.mem id.it !bound)
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
  Visitor.exp body;
  List.rev !captures


let scan script =
  let iterations = ref [] in
  let hints = ref [] in
  let add_iteration body iterexp =
    iterations :=
      { name = iteration_name body
      ; body
      ; iterexp
      ; captures = capture_variables body iterexp
      }
      :: !iterations
  in
  let module Visitor = Il.Iter.Make (struct
    include Il.Iter.Skip

    let visit_exp exp =
      match exp.it with
      | IterE (body, iterexp) -> add_iteration body iterexp
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
  ; hints = List.rev !hints
  }

let iterations index = index.iterations
let hints index = index.hints
