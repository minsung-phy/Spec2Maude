open Il.Ast
open Maude_ir

module Request = Helper_request

type source =
  { generator_id : id
  ; source_exp : exp
  ; binding : Expr_env.binding
  ; item_shape : Request.iter_map_source_item_shape
  ; head_term : term
  ; tail_var : string
  }

let app name args =
  App (name, args)

let concat left right =
  app "_ _" [ left; right ]

let iter_name = function
  | Opt -> "Opt"
  | List -> "List"
  | List1 -> "List1"
  | ListN _ -> "ListN"

let source_shape source : Request.iter_zip_source_shape =
  { generator_source_id = source.generator_id.it
  ; source_source = Il.Print.string_of_exp source.source_exp
  ; source_typ_source = Il.Print.string_of_typ source.source_exp.note
  }

let helper_source source : Request.iter_pattern_zip_source =
  { source_shape = source_shape source
  ; source_item_shape = source.item_shape
  ; source_head_term = source.head_term
  ; source_tail_var = source.tail_var
  }

let source_tuple sources =
  let terms =
    sources
    |> List.map (fun source -> app "seq" [ source.binding.Expr_env.term ])
  in
  let items =
    match terms with
    | [] -> Const "eps"
    | head :: tail -> List.fold_left concat head tail
  in
  app "tuple" [ items ]

let match_condition
    ctx
    origin
    ~pattern_exp
    ~body_exp
    ~iter
    ~subject_item
    ~subject_tail_var
    ~sources
    ~captures
    ~body_conditions
    ~subject
  =
  let helper_sources = List.map helper_source sources in
  let request =
    { Request.kind =
        Request.Iter_pattern_zip
          { source_shape =
              { pattern_source = Il.Print.string_of_exp pattern_exp
              ; body_source = Il.Print.string_of_exp body_exp
              ; iter_source = iter_name iter
              ; sources = List.map source_shape sources
              }
          ; subject_item_term = subject_item
          ; subject_tail_var
          ; sources = helper_sources
          ; captures
          ; body_eq_conditions = body_conditions
          }
    ; reason = "source IterE binding of a declared inverse result"
    ; origin
    }
  in
  let helper_name = Helper.request (Context.helpers ctx) request in
  let capture_terms =
    captures |> List.map (fun capture -> capture.Request.call_term)
  in
  MatchCond
    ( source_tuple sources
    , app helper_name (subject :: capture_terms) )
