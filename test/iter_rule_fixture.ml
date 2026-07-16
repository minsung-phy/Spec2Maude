open Translator
open Maude_ir
open Util.Source

let origin =
  Origin.synthetic ~ast_constructor:"IterPrFixture" "rewrite-backed iteration"

let shape source =
  { Helper_request.prem_source = source
  ; body_source = "proof(head) => proofResult(witness)"
  ; source_source = source
  ; source_typ_source = "nat*"
  ; iter_source = "*"
  }

let list_request =
  { Helper_request.source_shape = shape "list"
  ; generator_var = "x"
  ; helper_head_var = "LH"
  ; source_tail_var = "LT"
  ; source_element_sort = sort "Nat"
  ; captures = []
  ; body_conditions =
      [ RewriteCond
          (App ("fixtureProof", [ Var "LH" ]),
           App ("fixtureProofResult", [ Var "LH" ]))
      ]
  }

let exists_request =
  { Helper_request.source_shape =
      { prem_source = "exists"
      ; indexed_source = "xs"
      ; source_typ_source = "nat*"
      ; predicate_source = "proof(x)"
      }
  ; index_source_id = "x"
  ; helper_head_var = "EH"
  ; source_tail_var = "ET"
  ; source_element_sort = sort "Nat"
  ; captures = []
  ; body_conditions =
      [ RewriteCond
          (App ("fixtureProof", [ Var "EH" ]),
           App ("fixtureProofResult", [ Var "EH" ]))
      ]
  }

let zip_source id head tail : Helper_request.iter_zip_source =
  { source_shape =
      { generator_source_id = id
      ; source_source = id ^ "s"
      ; source_typ_source = "nat*"
      }
  ; source_item_shape = Source_flat_terminal
  ; helper_head_var = head
  ; source_tail_var = tail
  ; source_element_sort = sort "Nat"
  }

let zip_request =
  let sources =
    [ zip_source "left" "ZH1" "ZT1"; zip_source "right" "ZH2" "ZT2" ]
  in
  let capture : Helper_request.capture =
    { source_id = "capture"
    ; call_term = Var "CAPTURE"
    ; formal_var = "ZC"
    ; sort = sort "Nat"
    ; typ = Il.Ast.NumT `NatT $ Util.Source.no_region
    }
  in
  { Helper_request.source_shape =
      { prem_source = "zip"
      ; body_source = "proof(left) => witness /\\ witness == right"
      ; iter_source = "*"
      ; sources =
          List.map
            (fun (source : Helper_request.iter_zip_source) -> source.source_shape)
            sources
      }
  ; sources
  ; captures = [ capture ]
  ; body_conditions =
      [ RewriteCond
          (App ("fixtureProof", [ Var "ZH1" ]),
           App ("fixtureProofResult", [ Var "ZW" ]))
      ; EqCondition (BoolCond (App ("_==_", [ Var "ZW"; Var "ZH2" ])))
      ]
  }

let entry name kind =
  { Helper_registry.name
  ; request = { Helper_request.kind; reason = "fixture"; origin }
  }

let helper_statements =
  let list_entry = entry "fixtureAll" (Iter_premise_list_rule list_request) in
  let exists_entry = entry "fixtureExists" (Iter_premise_exists_rule exists_request) in
  let zip_entry = entry "fixtureZip" (Iter_premise_zip_rule zip_request) in
  Helper_materialize_iter.materialize_iter_premise_list_rule
    list_entry list_request
  @ Helper_materialize_iter.materialize_iter_premise_exists_rule
      exists_entry exists_request
  @ Helper_materialize_iter.materialize_iter_premise_zip_rule
      zip_entry zip_request

let support =
  let generated node = Maude_ir.generated ~provenance:Source ~origin node in
  [ generated (sort_decl (sort "FixtureProof"))
  ; generated
      (op "fixtureProof" [ sort_ref (sort "Nat") ] (sort "FixtureProof")
         ~attrs:[ Frozen [ 1 ] ])
  ; generated
      (op "fixtureProofResult" [ sort_ref (sort "Nat") ] (sort "FixtureProof")
         ~attrs:[ Ctor ])
  ; generated (var "FIXTUREN" (sort_ref (sort "Nat")))
  ; generated (var "ZW" (sort_ref (sort "Nat")))
  ; generated
      (rl
         (App ("fixtureProof", [ Var "FIXTUREN" ]))
         (App ("fixtureProofResult", [ Var "FIXTUREN" ])))
  ]

let () =
  let module_ =
    { name = "SPEC2MAUDE-ITER-RULE-FIXTURE"
    ; kind = System
    ; imports = Prelude.imports
    ; statements = Prelude.statements @ support @ helper_statements
    }
  in
  print_string (Emit.render_module module_);
  print_endline "rew fixtureAll(0 1) .";
  print_endline "rew fixtureExists(0 1) .";
  print_endline "rew fixtureZip(0 1, 0 1, 7) ."
