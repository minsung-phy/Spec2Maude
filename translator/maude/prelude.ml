open Maude_ir

let s = sort
let sr name = sort_ref (s name)
let kr name = kind_ref (kind_of_sort (s name))
let app name args = App (name, args)
let typecheck value typ = app "typecheck" [ value; typ ]
let typecheck_seq value typ = app "typecheckSeq" [ value; typ ]
let typecheck_opt_seq value typ = app "typecheckOptSeq" [ value; typ ]
let typecheck_seq_opt value typ = app "typecheckSeqOpt" [ value; typ ]
let typecheck_nested_seq value typ = app "typecheckNestedSeq" [ value; typ ]

let spectec_terminal = s "SpectecTerminal"
let spectec_terminals = s "SpectecTerminals"
let spectec_type = s "SpectecType"
let spectec_types = s "SpectecTypes"
let record_item = s "RecordItem"
let record_items = s "RecordItems"

let origin =
  Origin.synthetic
    ~path:[ "prelude" ]
    ~ast_constructor:"Prelude"
    "Spec2Maude minimal runtime prelude"

let gen node =
  generated ~provenance:Prelude ~origin node

let imports =
  [ Protecting "BOOL"
  ; Protecting "NAT"
  ; Protecting "INT"
  ; Protecting "RAT"
  ; Protecting "FLOAT"
  ; Protecting "STRING"
  ; Protecting "QID"
  ]

let statements =
  List.map gen
    [ sort_decl spectec_terminal
    ; sort_decl spectec_terminals
    ; sort_decl spectec_type
    ; sort_decl spectec_types
    ; subsort (s "Nat") spectec_terminal
    ; subsort (s "Int") spectec_terminal
    ; subsort spectec_terminal spectec_terminals
    ; subsort spectec_type spectec_types
    ; op "syn-bool" [] spectec_type
    ; op "syn-nat" [] spectec_type
    ; op "syn-int" [] spectec_type
    ; op "syn-rat" [] spectec_type
    ; op "syn-real" [] spectec_type
    ; op "syn-text" [] spectec_type
    ; op "bool" [ sr "Bool" ] spectec_terminal ~attrs:[ Ctor ]
    ; op "rat" [ sr "Rat" ] spectec_terminal ~attrs:[ Ctor ]
    ; op "float" [ sr "Float" ] spectec_terminal ~attrs:[ Ctor ]
    ; op "text" [ sr "String" ] spectec_terminal ~attrs:[ Ctor ]
    ; op "seq" [ sr "SpectecTerminals" ] spectec_terminal ~attrs:[ Ctor ]
    ; op "tuple" [ sr "SpectecTerminals" ] spectec_terminal ~attrs:[ Ctor ]
    ; op "eps" [] spectec_terminals
    ; op "_ _" [ sr "SpectecTerminals"; sr "SpectecTerminals" ] spectec_terminals
        ~attrs:[ Ctor; Assoc; Id (Const "eps") ]
    ; op "len" [ sr "SpectecTerminals" ] (s "Nat")
    ; op "allLen" [ sr "SpectecTerminals"; sr "Nat" ] (s "Bool")
    ; op "isOpt" [ sr "SpectecTerminals" ] (s "Bool")
    ; op "allOpt" [ sr "SpectecTerminals" ] (s "Bool")
    ; op "contains" [ sr "SpectecTerminal"; sr "SpectecTerminals" ] (s "Bool")
    ; op "isTrue" [ kr "SpectecTerminal" ] (s "Bool")
    ; op "typecheck" [ kr "SpectecTerminal"; sr "SpectecType" ] (s "Bool")
    ; op "typecheckSeq" [ sr "SpectecTerminals"; sr "SpectecType" ] (s "Bool")
    ; op "typecheckSeq" [ sr "SpectecTerminals"; sr "SpectecTypes" ] (s "Bool")
    ; op "typecheckOptSeq" [ sr "SpectecTerminals"; sr "SpectecType" ] (s "Bool")
    ; op "typecheckSeqOpt" [ sr "SpectecTerminals"; sr "SpectecType" ] (s "Bool")
    ; op "typecheckNestedSeq" [ sr "SpectecTerminals"; sr "SpectecType" ] (s "Bool")
    ; sort_decl record_item
    ; sort_decl record_items
    ; subsort record_item record_items
    ; op "EMPTY" [] record_item
    ; op "_;_" [ sr "RecordItems"; sr "RecordItems" ] record_items
        ~attrs:[ Ctor; Assoc; Id (Const "EMPTY") ]
    ; op "{_}" [ sr "RecordItems" ] spectec_terminal
    ; op "item" [ sr "Qid"; sr "SpectecTerminals" ] record_item
    ; op "value" [ sr "Qid"; sr "SpectecTerminal" ] spectec_terminal
    ; op "value" [ sr "Qid"; sr "RecordItems" ] spectec_terminals
    ; op "_++_" [ sr "RecordItems"; sr "RecordItems" ] spectec_terminal
    ; op "_[._<-_]" [ sr "SpectecTerminal"; sr "Qid"; sr "SpectecTerminals" ] spectec_terminal
    ; op "_[._=++_]" [ sr "SpectecTerminal"; sr "Qid"; sr "SpectecTerminals" ] spectec_terminal
    ; op "setItem" [ sr "RecordItems"; sr "Qid"; sr "SpectecTerminals" ] record_items
    ; op "_[_<-_]" [ sr "SpectecTerminals"; sr "Nat"; sr "SpectecTerminal" ] spectec_terminals
    ; op "index" [ sr "SpectecTerminals"; sr "Nat" ] spectec_terminal
    ; op "slice" [ sr "SpectecTerminals"; sr "Nat"; sr "Nat" ] spectec_terminals
    ; op "merge" [ sr "SpectecTerminal"; sr "SpectecTerminal" ] spectec_terminal
        ~attrs:[ Ctor ]
    ; var "B" (sr "Bool")
    ; var "N" (sr "Nat")
    ; var "N2" (sr "Nat")
    ; var "I" (sr "Int")
    ; var "R" (sr "Rat")
    ; var "F" (sr "Float")
    ; var "FQ" (sr "Qid")
    ; var "FQ2" (sr "Qid")
    ; var "S" (sr "String")
    ; var "K" (kr "SpectecTerminal")
    ; var "X" (sr "SpectecTerminal")
    ; var "Y" (sr "SpectecTerminal")
    ; var "REC" (sr "SpectecTerminal")
    ; var "XS" (sr "SpectecTerminals")
    ; var "YS" (sr "SpectecTerminals")
    ; var "VAL" (sr "SpectecTerminals")
    ; var "VAL2" (sr "SpectecTerminals")
    ; var "RI" (sr "RecordItems")
    ; var "RI2" (sr "RecordItems")
    ; var "T" (sr "SpectecType")
    ; eq (app "len" [ Const "eps" ]) (Const "0")
    ; eq (app "len" [ Var "X" ]) (Const "1")
    ; ceq
        (app "len" [ app "_ _" [ Var "X"; Var "XS" ] ])
        (app "_+_" [ Const "1"; app "len" [ Var "XS" ] ])
        [ BoolCond (app "_=/=_" [ Var "XS"; Const "eps" ]) ]
    ; eq (app "allLen" [ Const "eps"; Var "N" ]) (Const "true")
    ; eq
        (app "allLen" [ app "seq" [ Var "YS" ]; Var "N" ])
        (app "_==_" [ app "len" [ Var "YS" ]; Var "N" ])
    ; ceq
        (app "allLen" [ app "_ _" [ app "seq" [ Var "YS" ]; Var "XS" ]; Var "N" ])
        (app "_and_" [ app "_==_" [ app "len" [ Var "YS" ]; Var "N" ]; app "allLen" [ Var "XS"; Var "N" ] ])
        [ BoolCond (app "_=/=_" [ Var "XS"; Const "eps" ]) ]
    ; eq (app "isOpt" [ Const "eps" ]) (Const "true")
    ; eq (app "isOpt" [ Var "X" ]) (Const "true")
    ; ceq
        (app "isOpt" [ app "_ _" [ Var "X"; Var "XS" ] ])
        (Const "false")
        [ BoolCond (app "_=/=_" [ Var "XS"; Const "eps" ]) ]
    ; eq (app "allOpt" [ Const "eps" ]) (Const "true")
    ; eq
        (app "allOpt" [ app "seq" [ Var "YS" ] ])
        (app "isOpt" [ Var "YS" ])
    ; ceq
        (app "allOpt" [ app "_ _" [ app "seq" [ Var "YS" ]; Var "XS" ] ])
        (app "_and_" [ app "isOpt" [ Var "YS" ]; app "allOpt" [ Var "XS" ] ])
        [ BoolCond (app "_=/=_" [ Var "XS"; Const "eps" ]) ]
    ; eq (app "contains" [ Var "X"; Const "eps" ]) (Const "false")
    ; eq (app "contains" [ Var "X"; Var "Y" ]) (app "_==_" [ Var "X"; Var "Y" ])
    ; ceq
        (app "contains" [ Var "X"; app "_ _" [ Var "Y"; Var "XS" ] ])
        (app "_or_" [ app "_==_" [ Var "X"; Var "Y" ]; app "contains" [ Var "X"; Var "XS" ] ])
        [ BoolCond (app "_=/=_" [ Var "XS"; Const "eps" ]) ]
    ; eq (app "isTrue" [ app "bool" [ Var "B" ] ]) (Var "B")
    ; eq (app "isTrue" [ Var "K" ]) (Const "false") ~attrs:[ Owise ]
    ; eq (typecheck (app "bool" [ Var "B" ]) (Const "syn-bool")) (Const "true")
    ; eq (typecheck (Var "N") (Const "syn-nat")) (Const "true")
    ; eq (typecheck (Var "I") (Const "syn-int")) (Const "true")
    ; eq (typecheck (app "rat" [ Var "R" ]) (Const "syn-rat")) (Const "true")
    ; eq (typecheck (app "float" [ Var "F" ]) (Const "syn-real")) (Const "true")
    ; eq (typecheck (app "text" [ Var "S" ]) (Const "syn-text")) (Const "true")
    ; eq (typecheck_seq (Const "eps") (Var "T")) (Const "true")
    ; eq (typecheck_seq (Var "X") (Var "T")) (typecheck (Var "X") (Var "T"))
    ; ceq
        (typecheck_seq (app "_ _" [ Var "X"; Var "XS" ]) (Var "T"))
        (app "_and_" [ typecheck (Var "X") (Var "T"); typecheck_seq (Var "XS") (Var "T") ])
        [ BoolCond (app "_=/=_" [ Var "XS"; Const "eps" ]) ]
    ; eq (typecheck_opt_seq (Const "eps") (Var "T")) (Const "true")
    ; eq
        (typecheck_opt_seq (app "seq" [ Var "YS" ]) (Var "T"))
        (app "_and_" [ app "isOpt" [ Var "YS" ]; typecheck_seq (Var "YS") (Var "T") ])
    ; ceq
        (typecheck_opt_seq (app "_ _" [ app "seq" [ Var "YS" ]; Var "XS" ]) (Var "T"))
        (app "_and_"
           [ app "_and_" [ app "isOpt" [ Var "YS" ]; typecheck_seq (Var "YS") (Var "T") ]
           ; typecheck_opt_seq (Var "XS") (Var "T")
           ])
        [ BoolCond (app "_=/=_" [ Var "XS"; Const "eps" ]) ]
    ; eq (typecheck_opt_seq (Var "XS") (Var "T")) (Const "false") ~attrs:[ Owise ]
    ; eq (typecheck_seq_opt (Const "eps") (Var "T")) (Const "true")
    ; eq
        (typecheck_seq_opt (app "seq" [ Var "YS" ]) (Var "T"))
        (typecheck_seq (Var "YS") (Var "T"))
    ; eq (typecheck_seq_opt (Var "XS") (Var "T")) (Const "false") ~attrs:[ Owise ]
    ; eq (typecheck_nested_seq (Const "eps") (Var "T")) (Const "true")
    ; eq
        (typecheck_nested_seq (app "seq" [ Var "YS" ]) (Var "T"))
        (typecheck_seq (Var "YS") (Var "T"))
    ; ceq
        (typecheck_nested_seq (app "_ _" [ app "seq" [ Var "YS" ]; Var "XS" ]) (Var "T"))
        (app "_and_" [ typecheck_seq (Var "YS") (Var "T"); typecheck_nested_seq (Var "XS") (Var "T") ])
        [ BoolCond (app "_=/=_" [ Var "XS"; Const "eps" ]) ]
    ; eq (typecheck_nested_seq (Var "XS") (Var "T")) (Const "false") ~attrs:[ Owise ]
    ; eq
        (app "value" [ Var "FQ"; app "{_}" [ Var "RI" ] ])
        (app "value" [ Var "FQ"; Var "RI" ])
    ; eq (app "value" [ Var "FQ"; Const "EMPTY" ]) (Const "eps")
    ; eq
        (app "value"
           [ Var "FQ"; app "_;_" [ app "item" [ Var "FQ"; Var "VAL" ]; Var "RI" ] ])
        (Var "VAL")
    ; ceq
        (app "value"
           [ Var "FQ"; app "_;_" [ app "item" [ Var "FQ2"; Var "VAL" ]; Var "RI" ] ])
        (app "value" [ Var "FQ"; Var "RI" ])
        [ BoolCond (app "_=/=_" [ Var "FQ"; Var "FQ2" ]) ]
    ; eq (app "_++_" [ Var "RI"; Var "RI2" ]) (app "{_}" [ app "_;_" [ Var "RI"; Var "RI2" ] ])
    ; eq
        (app "_[._<-_]" [ app "{_}" [ Var "RI" ]; Var "FQ"; Var "VAL2" ])
        (app "{_}" [ app "setItem" [ Var "RI"; Var "FQ"; Var "VAL2" ] ])
    ; eq
        (app "setItem" [ Const "EMPTY"; Var "FQ"; Var "VAL2" ])
        (app "item" [ Var "FQ"; Var "VAL2" ])
    ; eq
        (app "setItem"
           [ app "_;_" [ app "item" [ Var "FQ"; Var "VAL" ]; Var "RI" ]
           ; Var "FQ"
           ; Var "VAL2"
           ])
        (app "_;_" [ app "item" [ Var "FQ"; Var "VAL2" ]; Var "RI" ])
    ; ceq
        (app "setItem"
           [ app "_;_" [ app "item" [ Var "FQ"; Var "VAL" ]; Var "RI" ]
           ; Var "FQ2"
           ; Var "VAL2"
           ])
        (app "_;_"
           [ app "item" [ Var "FQ"; Var "VAL" ]
           ; app "setItem" [ Var "RI"; Var "FQ2"; Var "VAL2" ]
           ])
        [ BoolCond (app "_=/=_" [ Var "FQ"; Var "FQ2" ]) ]
    ; eq
        (app "_[._=++_]" [ Var "REC"; Var "FQ"; Var "VAL2" ])
        (app "_[._<-_]"
           [ Var "REC"
           ; Var "FQ"
           ; app "_ _" [ app "value" [ Var "FQ"; Var "REC" ]; Var "VAL2" ]
           ])
    ; eq (app "index" [ app "_ _" [ Var "X"; Var "XS" ]; Const "0" ]) (Var "X")
    ; eq
        (app "index" [ app "_ _" [ Var "X"; Var "XS" ]; app "s_" [ Var "N2" ] ])
        (app "index" [ Var "XS"; Var "N2" ])
    ; eq (app "_[_<-_]" [ Const "eps"; Var "N"; Var "Y" ]) (Const "eps")
    ; eq
        (app "_[_<-_]" [ app "_ _" [ Var "X"; Var "XS" ]; Const "0"; Var "Y" ])
        (app "_ _" [ Var "Y"; Var "XS" ])
    ; eq
        (app "_[_<-_]" [ app "_ _" [ Var "X"; Var "XS" ]; app "s_" [ Var "N2" ]; Var "Y" ])
        (app "_ _" [ Var "X"; app "_[_<-_]" [ Var "XS"; Var "N2"; Var "Y" ] ])
    ; eq (typecheck (Var "K") (Var "T")) (Const "false") ~attrs:[ Owise ]
    ]
