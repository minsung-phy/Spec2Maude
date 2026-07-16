open Maude_ir

let s = sort
let sr name = sort_ref (s name)
let kr name = kind_ref (kind_of_sort (s name))
let app name args = App (name, args)
let witness name = Naming.primitive_witness name
module T = Typecheck_term
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
    ; op (witness "bool") [] spectec_type
    ; op (witness "nat") [] spectec_type
    ; op (witness "int") [] spectec_type
    ; op (witness "rat") [] spectec_type
    ; op (witness "real") [] spectec_type
    ; op (witness "text") [] spectec_type
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
    ; op "natOfInt" [ sr "Int" ] (s "Nat") ~kind:Partial
    ; op "intOfRat" [ sr "Rat" ] (s "Int") ~kind:Partial
    ; op "natOfRat" [ sr "Rat" ] (s "Nat") ~kind:Partial
    ; op "ratIsInt" [ sr "Rat" ] (s "Bool")
    ; op "modNat" [ sr "Nat"; sr "Nat" ] (s "Nat") ~kind:Partial
    ; op "modInt" [ sr "Int"; sr "Int" ] (s "Int") ~kind:Partial
    ; op "allLen" [ sr "SpectecTerminals"; sr "Nat" ] (s "Bool")
    ; op "isOpt" [ sr "SpectecTerminals" ] (s "Bool")
    ; op "allOpt" [ sr "SpectecTerminals" ] (s "Bool")
    ; op "contains" [ sr "SpectecTerminal"; sr "SpectecTerminals" ] (s "Bool")
    ; op "isTrue" [ sr "SpectecTerminal" ] (s "Bool") ~kind:Partial
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
    ; op "{_}" [ sr "RecordItems" ] spectec_terminal ~attrs:[ Ctor ]
    ; op "item" [ sr "Qid"; sr "SpectecTerminals" ] record_item ~attrs:[ Ctor ]
    ; op "value" [ sr "Qid"; sr "SpectecTerminal" ] spectec_terminal
    ; op "value" [ sr "Qid"; sr "RecordItems" ] spectec_terminals
    ; op "_++_" [ sr "RecordItems"; sr "RecordItems" ] spectec_terminal
    ; op "_[._<-_]" [ sr "SpectecTerminal"; sr "Qid"; sr "SpectecTerminals" ] spectec_terminal
    ; op "_[._=++_]" [ sr "SpectecTerminal"; sr "Qid"; sr "SpectecTerminals" ] spectec_terminal
    ; op "setItem" [ sr "RecordItems"; sr "Qid"; sr "SpectecTerminals" ] record_items
    ; op "_[_<-_]" [ sr "SpectecTerminals"; sr "Nat"; sr "SpectecTerminal" ] spectec_terminals
    ; op "index" [ sr "SpectecTerminals"; sr "Nat" ] spectec_terminal
    ; op "indexSeq" [ sr "SpectecTerminals"; sr "Nat" ] spectec_terminals
    ; op "indexDefined" [ sr "SpectecTerminals"; sr "Nat" ] (s "Bool")
    ; op "slice" [ sr "SpectecTerminals"; sr "Nat"; sr "Nat" ] spectec_terminals
    ; op "drop" [ sr "Nat"; sr "SpectecTerminals" ] spectec_terminals
    ; op "splice" [ sr "SpectecTerminals"; sr "Nat"; sr "Nat"; sr "SpectecTerminals" ] spectec_terminals
    ; op "merge" [ sr "SpectecTerminal"; sr "SpectecTerminal" ] spectec_terminal
        ~attrs:[ Ctor ]
    ; var "B" (sr "Bool")
    ; var "N" (sr "Nat")
    ; var "N2" (sr "Nat")
    ; var "I" (sr "Int")
    ; var "I2" (sr "Int")
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
    ; eq (app "natOfInt" [ Var "N" ]) (Var "N")
    ; eq (app "intOfRat" [ Var "I" ]) (Var "I")
    ; eq (app "natOfRat" [ Var "N" ]) (Var "N")
    ; eq (app "ratIsInt" [ Var "I" ]) (Const "true")
    ; eq ~attrs:[ Owise ] (app "ratIsInt" [ Var "R" ]) (Const "false")
    ; ceq
        (app "modNat" [ Var "N"; Var "N2" ])
        (app "_rem_" [ Var "N"; Var "N2" ])
        [ BoolCond (app "_=/=_" [ Var "N2"; Const "0" ]) ]
    ; ceq
        (app "modInt" [ Var "I"; Var "I2" ])
        (app "_rem_" [ Var "I"; Var "I2" ])
        [ BoolCond (app "_=/=_" [ Var "I2"; Const "0" ]) ]
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
    ; eq (app "isTrue" [ app "bool" [ Const "true" ] ]) (Const "true")
    ; eq (app "isTrue" [ app "bool" [ Const "false" ] ]) (Const "false")
    ; eq (T.typecheck (app "bool" [ Var "B" ]) (Const (witness "bool"))) (Const "true")
    ; eq (T.typecheck (Var "N") (Const (witness "nat"))) (Const "true")
    ; eq (T.typecheck (Var "I") (Const (witness "int"))) (Const "true")
    ; eq (T.typecheck (app "rat" [ Var "R" ]) (Const (witness "rat"))) (Const "true")
    ; eq (T.typecheck (app "float" [ Var "F" ]) (Const (witness "real"))) (Const "true")
    ; eq (T.typecheck (app "text" [ Var "S" ]) (Const (witness "text"))) (Const "true")
    ; eq (T.typecheck_seq (Const "eps") (Var "T")) (Const "true")
    ; eq (T.typecheck_seq (Var "X") (Var "T")) (T.typecheck (Var "X") (Var "T"))
    ; ceq
        (T.typecheck_seq (app "_ _" [ Var "X"; Var "XS" ]) (Var "T"))
        (app "_and_" [ T.typecheck (Var "X") (Var "T"); T.typecheck_seq (Var "XS") (Var "T") ])
        [ BoolCond (app "_=/=_" [ Var "XS"; Const "eps" ]) ]
    ; eq (T.typecheck_opt_seq (Const "eps") (Var "T")) (Const "true")
    ; eq
        (T.typecheck_opt_seq (app "seq" [ Var "YS" ]) (Var "T"))
        (app "_and_" [ app "isOpt" [ Var "YS" ]; T.typecheck_seq (Var "YS") (Var "T") ])
    ; ceq
        (T.typecheck_opt_seq (app "_ _" [ app "seq" [ Var "YS" ]; Var "XS" ]) (Var "T"))
        (app "_and_"
           [ app "_and_" [ app "isOpt" [ Var "YS" ]; T.typecheck_seq (Var "YS") (Var "T") ]
           ; T.typecheck_opt_seq (Var "XS") (Var "T")
           ])
        [ BoolCond (app "_=/=_" [ Var "XS"; Const "eps" ]) ]
    ; eq (T.typecheck_opt_seq (Var "XS") (Var "T")) (Const "false") ~attrs:[ Owise ]
    ; eq (T.typecheck_seq_opt (Const "eps") (Var "T")) (Const "true")
    ; eq
        (T.typecheck_seq_opt (app "seq" [ Var "YS" ]) (Var "T"))
        (T.typecheck_seq (Var "YS") (Var "T"))
    ; eq (T.typecheck_seq_opt (Var "XS") (Var "T")) (Const "false") ~attrs:[ Owise ]
    ; eq (T.typecheck_nested_seq (Const "eps") (Var "T")) (Const "true")
    ; eq
        (T.typecheck_nested_seq (app "seq" [ Var "YS" ]) (Var "T"))
        (T.typecheck_seq (Var "YS") (Var "T"))
    ; ceq
        (T.typecheck_nested_seq (app "_ _" [ app "seq" [ Var "YS" ]; Var "XS" ]) (Var "T"))
        (app "_and_" [ T.typecheck_seq (Var "YS") (Var "T"); T.typecheck_nested_seq (Var "XS") (Var "T") ])
        [ BoolCond (app "_=/=_" [ Var "XS"; Const "eps" ]) ]
    ; eq (T.typecheck_nested_seq (Var "XS") (Var "T")) (Const "false") ~attrs:[ Owise ]
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
    ; eq
        (app "indexSeq" [ app "_ _" [ app "seq" [ Var "YS" ]; Var "XS" ]; Const "0" ])
        (Var "YS")
    ; eq
        (app "indexSeq"
           [ app "_ _" [ app "seq" [ Var "YS" ]; Var "XS" ]
           ; app "s_" [ Var "N2" ]
           ])
        (app "indexSeq" [ Var "XS"; Var "N2" ])
    ; eq (app "indexDefined" [ Const "eps"; Var "N" ]) (Const "false")
    ; eq
        (app "indexDefined" [ app "_ _" [ Var "X"; Var "XS" ]; Const "0" ])
        (Const "true")
    ; eq
        (app "indexDefined"
           [ app "_ _" [ Var "X"; Var "XS" ]; app "s_" [ Var "N2" ] ])
        (app "indexDefined" [ Var "XS"; Var "N2" ])
    ; eq (app "_[_<-_]" [ Const "eps"; Var "N"; Var "Y" ]) (Const "eps")
    ; eq
        (app "_[_<-_]" [ app "_ _" [ Var "X"; Var "XS" ]; Const "0"; Var "Y" ])
        (app "_ _" [ Var "Y"; Var "XS" ])
    ; eq
        (app "_[_<-_]" [ app "_ _" [ Var "X"; Var "XS" ]; app "s_" [ Var "N2" ]; Var "Y" ])
        (app "_ _" [ Var "X"; app "_[_<-_]" [ Var "XS"; Var "N2"; Var "Y" ] ])
    ; eq (app "drop" [ Const "0"; Var "XS" ]) (Var "XS")
    ; eq (app "drop" [ app "s_" [ Var "N" ]; Const "eps" ]) (Const "eps")
    ; eq
        (app "drop" [ app "s_" [ Var "N" ]; app "_ _" [ Var "X"; Var "XS" ] ])
        (app "drop" [ Var "N"; Var "XS" ])
    ; eq (app "slice" [ Var "XS"; Var "N"; Const "0" ]) (Const "eps")
    ; eq
        (app "slice" [ Const "eps"; app "s_" [ Var "N" ]; Var "N2" ])
        (Const "eps")
    ; eq
        (app "slice" [ Const "eps"; Const "0"; app "s_" [ Var "N" ] ])
        (Const "eps")
    ; eq
        (app "slice" [ app "_ _" [ Var "X"; Var "XS" ]; Const "0"; app "s_" [ Var "N" ] ])
        (app "_ _" [ Var "X"; app "slice" [ Var "XS"; Const "0"; Var "N" ] ])
    ; eq
        (app "slice"
           [ app "_ _" [ Var "X"; Var "XS" ]
           ; app "s_" [ Var "N" ]
           ; Var "N2"
           ])
        (app "slice" [ Var "XS"; Var "N"; Var "N2" ])
    ; eq
        (app "splice" [ Var "XS"; Const "0"; Var "N"; Var "VAL" ])
        (app "_ _" [ Var "VAL"; app "drop" [ Var "N"; Var "XS" ] ])
    ; eq
        (app "splice"
           [ app "_ _" [ Var "X"; Var "XS" ]; app "s_" [ Var "N" ]; Const "0"; Var "VAL" ])
        (app "_ _"
           [ Var "X"; app "splice" [ Var "XS"; Var "N"; Const "0"; Var "VAL" ] ])
    ; eq
        (app "splice"
           [ Const "eps"; app "s_" [ Var "N" ]; app "s_" [ Var "N2" ]; Var "VAL" ])
        (Const "eps")
    ; eq
        (app "splice"
           [ app "_ _" [ Var "X"; Var "XS" ]
           ; app "s_" [ Var "N" ]
           ; app "s_" [ Var "N2" ]
           ; Var "VAL"
           ])
        (app "_ _"
           [ Var "X"; app "splice" [ Var "XS"; Var "N"; Var "N2"; Var "VAL" ] ])
    ; eq (T.typecheck (Var "K") (Var "T")) (Const "false") ~attrs:[ Owise ]
    ]
