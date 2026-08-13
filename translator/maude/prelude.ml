open Maude_ir

let s = sort
let sr name = sort_ref (s name)
let kr name = kind_ref (kind_of_sort (s name))
let app name args = App (name, args)
let seq head tail = app "_ _" [ head; tail ]
let repeat count value = app "repeatSeq" [ count; value ]
let run count value = app "runSeq" [ count; value ]
let canonical_run count value = app "canonicalRun" [ count; value ]
let compact_run count value = app "compactRun" [ count; value ]
let drop count values = app "drop" [ count; values ]
let take_run count values = app "takeRun" [ count; values ]
let splice values index count replacement =
  app "splice" [ values; index; count; replacement ]
let splice_run values index count replacement =
  app "spliceRun" [ values; index; count; replacement ]
let prepend_run count value values =
  app "prependRun" [ count; value; values ]
let append_runs left right = app "appendRuns" [ left; right ]
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

let declarations =
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
    ; op "compactRepeatThreshold" [] (s "Nat")
    ; op "repeatSeq" [ sr "Nat"; sr "SpectecTerminal" ] spectec_terminals
        ~attrs:[ Ctor ]
    ; op "runSeq" [ sr "Nat"; sr "SpectecTerminal" ] spectec_terminals
        ~attrs:[ Ctor ]
    ; op "canonicalRun" [ sr "Nat"; sr "SpectecTerminal" ] spectec_terminals
    ; op "compactRun" [ sr "Nat"; sr "SpectecTerminal" ] spectec_terminals
    ; op "len" [ sr "SpectecTerminals" ] (s "Nat")
    ; op "natOfInt" [ sr "Int" ] (s "Nat") ~kind:Partial
    ; op "intOfRat" [ sr "Rat" ] (s "Int") ~kind:Partial
    ; op "natOfRat" [ sr "Rat" ] (s "Nat") ~kind:Partial
    ; op "ratIsInt" [ sr "Rat" ] (s "Bool")
    ; op "modNat" [ sr "Nat"; sr "Nat" ] (s "Nat") ~kind:Partial
    ; op "modInt" [ sr "Int"; sr "Int" ] (s "Int") ~kind:Partial
    ; op "allLen" [ sr "SpectecTerminals"; sr "Nat" ] (s "Bool")
    ; op "isOpt" [ sr "SpectecTerminals" ] (s "Bool")
    ; op "composeOpt" [ sr "SpectecTerminals"; sr "SpectecTerminals" ]
        spectec_terminals ~kind:Partial
    ; op "allOpt" [ sr "SpectecTerminals" ] (s "Bool")
    ; op "allSeq" [ sr "SpectecTerminals" ] (s "Bool")
    ; op "flattenNested" [ sr "SpectecTerminals" ] spectec_terminals
        ~kind:Partial
    ; op "contains" [ sr "SpectecTerminal"; sr "SpectecTerminals" ] (s "Bool")
    ; op "isTrue" [ sr "SpectecTerminal" ] (s "Bool") ~kind:Partial
    ; op "typecheck" [ kr "SpectecTerminal"; sr "SpectecType" ] (s "Bool")
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
    ; op "take" [ sr "Nat"; sr "SpectecTerminals" ] spectec_terminals
    ; op "takeRun" [ sr "Nat"; sr "SpectecTerminals" ] spectec_terminals
    ; op "splice" [ sr "SpectecTerminals"; sr "Nat"; sr "Nat"; sr "SpectecTerminals" ] spectec_terminals
    ; op "spliceRun" [ sr "SpectecTerminals"; sr "Nat"; sr "Nat"; sr "SpectecTerminals" ] spectec_terminals
    ; op "prependRun" [ sr "Nat"; sr "SpectecTerminal"; sr "SpectecTerminals" ] spectec_terminals
    ; op "appendRuns" [ sr "SpectecTerminals"; sr "SpectecTerminals" ] spectec_terminals
  ]

let variables =
  [ var "B" (sr "Bool")
    ; var "N" (sr "Nat")
    ; var "N2" (sr "Nat")
    ; var "N3" (sr "Nat")
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
  ]

let core_equations =
  [ eq (Const "compactRepeatThreshold") (Const "1024")
    ; eq (app "repeatSeq" [ Const "0"; Var "X" ]) (Const "eps")
    ; eq (app "repeatSeq" [ Const "1"; Var "X" ]) (Var "X")
    ; ceq
        (app "repeatSeq" [ app "s_" [ Var "N" ]; Var "X" ])
        (app "_ _"
           [ Var "X"
           ; app "repeatSeq" [ Var "N"; Var "X" ]
           ])
        [ BoolCond
            (app "_<_"
               [ app "s_" [ Var "N" ]
               ; Const "compactRepeatThreshold"
               ])
        ]
    ; eq (run (Const "0") (Var "X")) (Const "eps")
    ; eq (run (Const "1") (Var "X")) (Var "X")
    ; eq (canonical_run (Const "0") (Var "X")) (Const "eps")
    ; eq (canonical_run (Const "1") (Var "X")) (Var "X")
    ; ceq
        (canonical_run
           (app "s_" [ app "s_" [ Var "N" ] ]) (Var "X"))
        (repeat
           (app "s_" [ app "s_" [ Var "N" ] ]) (Var "X"))
        [ BoolCond
            (app "_<_"
               [ app "s_" [ app "s_" [ Var "N" ] ]
               ; Const "compactRepeatThreshold"
               ])
        ]
    ; ceq
        (canonical_run (Var "N") (Var "X"))
        (run (Var "N") (Var "X"))
        [ BoolCond
            (app "_>=_"
               [ Var "N"; Const "compactRepeatThreshold" ])
        ]
    ; eq (compact_run (Const "0") (Var "X")) (Const "eps")
    ; eq (compact_run (Const "1") (Var "X")) (Var "X")
    ; eq
        (compact_run
           (app "s_" [ app "s_" [ Var "N" ] ]) (Var "X"))
        (run (app "s_" [ app "s_" [ Var "N" ] ]) (Var "X"))
    ; eq (app "len" [ Const "eps" ]) (Const "0")
    ; eq (app "len" [ Var "X" ]) (Const "1")
    ; eq
        (app "len" [ app "repeatSeq" [ Var "N"; Var "X" ] ])
        (Var "N")
    ; ceq
        (app "len"
           [ app "_ _"
               [ app "repeatSeq" [ Var "N"; Var "X" ]
               ; Var "XS"
               ]
           ])
        (app "_+_" [ Var "N"; app "len" [ Var "XS" ] ])
        [ BoolCond (app "_=/=_" [ Var "XS"; Const "eps" ]) ]
    ; eq (app "len" [ run (Var "N") (Var "X") ]) (Var "N")
    ; ceq
        (app "len" [ seq (run (Var "N") (Var "X")) (Var "XS") ])
        (app "_+_" [ Var "N"; app "len" [ Var "XS" ] ])
        [ BoolCond (app "_=/=_" [ Var "XS"; Const "eps" ]) ]
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
    ; ceq
        (app "composeOpt" [ Const "eps"; Var "XS" ])
        (Var "XS")
        [ BoolCond (app "isOpt" [ Var "XS" ]) ]
    ; eq
        (app "composeOpt" [ Var "X"; Const "eps" ])
        (Var "X")
    ; eq (app "allOpt" [ Const "eps" ]) (Const "true")
    ; eq
        (app "allOpt" [ app "seq" [ Var "YS" ] ])
        (app "isOpt" [ Var "YS" ])
    ; ceq
        (app "allOpt" [ app "_ _" [ app "seq" [ Var "YS" ]; Var "XS" ] ])
        (app "_and_" [ app "isOpt" [ Var "YS" ]; app "allOpt" [ Var "XS" ] ])
        [ BoolCond (app "_=/=_" [ Var "XS"; Const "eps" ]) ]
    ; eq (app "allOpt" [ Var "XS" ]) (Const "false") ~attrs:[ Owise ]
    ; eq (app "allSeq" [ Const "eps" ]) (Const "true")
    ; eq (app "allSeq" [ app "seq" [ Var "YS" ] ]) (Const "true")
    ; ceq
        (app "allSeq" [ app "_ _" [ app "seq" [ Var "YS" ]; Var "XS" ] ])
        (app "allSeq" [ Var "XS" ])
        [ BoolCond (app "_=/=_" [ Var "XS"; Const "eps" ]) ]
    ; eq (app "allSeq" [ Var "XS" ]) (Const "false") ~attrs:[ Owise ]
    ; eq (app "flattenNested" [ Const "eps" ]) (Const "eps")
    ; eq
        (app "flattenNested" [ app "seq" [ Var "YS" ] ])
        (Var "YS")
    ; ceq
        (app "flattenNested"
           [ app "_ _" [ app "seq" [ Var "YS" ]; Var "XS" ] ])
        (app "_ _" [ Var "YS"; app "flattenNested" [ Var "XS" ] ])
        [ BoolCond (app "_=/=_" [ Var "XS"; Const "eps" ]) ]
    ; eq (app "contains" [ Var "X"; Const "eps" ]) (Const "false")
    ; eq (app "contains" [ Var "X"; Var "Y" ]) (app "_==_" [ Var "X"; Var "Y" ])
    ; ceq
        (app "contains" [ Var "X"; app "_ _" [ Var "Y"; Var "XS" ] ])
        (app "_or_" [ app "_==_" [ Var "X"; Var "Y" ]; app "contains" [ Var "X"; Var "XS" ] ])
        [ BoolCond (app "_=/=_" [ Var "XS"; Const "eps" ]) ]
    ; eq (app "isTrue" [ app "bool" [ Const "true" ] ]) (Const "true")
    ; eq (app "isTrue" [ app "bool" [ Const "false" ] ]) (Const "false")
  ]

let typecheck_equations =
  [ eq (T.typecheck (app "bool" [ Var "B" ]) (Const (witness "bool"))) (Const "true")
    ; eq (T.typecheck (Var "N") (Const (witness "nat"))) (Const "true")
    ; eq (T.typecheck (Var "I") (Const (witness "int"))) (Const "true")
    ; eq (T.typecheck (app "rat" [ Var "R" ]) (Const (witness "rat"))) (Const "true")
    ; eq (T.typecheck (app "float" [ Var "F" ]) (Const (witness "real"))) (Const "true")
    ; eq (T.typecheck (app "text" [ Var "S" ]) (Const (witness "text"))) (Const "true")
    ; eq (T.typecheck (Const "eps") (Var "T")) (Const "true")
    ; ceq
        (T.typecheck
           (app "repeatSeq" [ Var "N"; Var "X" ])
           (Var "T"))
        (T.typecheck (Var "X") (Var "T"))
        [ BoolCond (app "_=/=_" [ Var "N"; Const "0" ]) ]
    ; ceq
        (T.typecheck
           (app "_ _"
              [ app "repeatSeq" [ Var "N"; Var "X" ]
              ; Var "XS"
              ])
           (Var "T"))
        (T.typecheck (Var "XS") (Var "T"))
        [ BoolCond (app "_=/=_" [ Var "N"; Const "0" ])
        ; BoolCond (app "_=/=_" [ Var "XS"; Const "eps" ])
        ; BoolCond (T.typecheck (Var "X") (Var "T"))
        ]
    ; ceq
        (T.typecheck (run (Var "N") (Var "X")) (Var "T"))
        (T.typecheck (Var "X") (Var "T"))
        [ BoolCond (app "_=/=_" [ Var "N"; Const "0" ]) ]
    ; ceq
        (T.typecheck
           (seq (run (Var "N") (Var "X")) (Var "XS"))
           (Var "T"))
        (T.typecheck (Var "XS") (Var "T"))
        [ BoolCond (app "_=/=_" [ Var "N"; Const "0" ])
        ; BoolCond (app "_=/=_" [ Var "XS"; Const "eps" ])
        ; BoolCond (T.typecheck (Var "X") (Var "T"))
        ]
    ; ceq
        (T.typecheck (app "_ _" [ Var "X"; Var "XS" ]) (Var "T"))
        (T.typecheck (Var "XS") (Var "T"))
        [ BoolCond (app "_=/=_" [ Var "XS"; Const "eps" ])
        ; BoolCond (T.typecheck (Var "X") (Var "T"))
        ]
  ]

let data_equations =
  [ eq
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
    ; ceq
        (app "index"
           [ app "_ _"
               [ app "repeatSeq" [ Var "N"; Var "X" ]
               ; Var "XS"
               ]
           ; Var "N2"
           ])
        (Var "X")
        [ BoolCond (app "_<_" [ Var "N2"; Var "N" ]) ]
    ; ceq
        (app "index"
           [ app "_ _"
               [ app "repeatSeq" [ Var "N"; Var "X" ]
               ; Var "XS"
               ]
           ; Var "N2"
           ])
        (app "index" [ Var "XS"; app "_-_" [ Var "N2"; Var "N" ] ])
        [ BoolCond (app "_<=_" [ Var "N"; Var "N2" ]) ]
    ; ceq
        (app "index"
           [ seq (run (Var "N") (Var "X")) (Var "XS")
           ; Var "N2"
           ])
        (Var "X")
        [ BoolCond (app "_<_" [ Var "N2"; Var "N" ]) ]
    ; ceq
        (app "index"
           [ seq (run (Var "N") (Var "X")) (Var "XS")
           ; Var "N2"
           ])
        (app "index" [ Var "XS"; app "_-_" [ Var "N2"; Var "N" ] ])
        [ BoolCond (app "_<=_" [ Var "N"; Var "N2" ]) ]
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
    ; eq
        (app "indexDefined" [ Var "XS"; Var "N" ])
        (app "_<_" [ Var "N"; app "len" [ Var "XS" ] ])
    ; eq (app "_[_<-_]" [ Const "eps"; Var "N"; Var "Y" ]) (Const "eps")
    ; ceq
        (app "_[_<-_]"
           [ app "_ _"
               [ app "repeatSeq" [ Var "N"; Var "X" ]
               ; Var "XS"
               ]
           ; Var "N2"
           ; Var "Y"
           ])
        (app "_ _"
           [ app "repeatSeq" [ Var "N2"; Var "X" ]
           ; app "_ _"
               [ Var "Y"
               ; app "_ _"
                   [ app "repeatSeq"
                       [ app "_-_"
                           [ Var "N"
                           ; app "_+_" [ Var "N2"; Const "1" ]
                           ]
                       ; Var "X"
                       ]
                   ; Var "XS"
                   ]
               ]
           ])
        [ BoolCond (app "_<_" [ Var "N2"; Var "N" ]) ]
    ; ceq
        (app "_[_<-_]"
           [ app "_ _"
               [ app "repeatSeq" [ Var "N"; Var "X" ]
               ; Var "XS"
               ]
           ; Var "N2"
           ; Var "Y"
           ])
        (app "_ _"
           [ app "repeatSeq" [ Var "N"; Var "X" ]
           ; app "_[_<-_]"
               [ Var "XS"
               ; app "_-_" [ Var "N2"; Var "N" ]
               ; Var "Y"
               ]
           ])
        [ BoolCond (app "_<=_" [ Var "N"; Var "N2" ]) ]
    ; eq
        (app "_[_<-_]" [ app "_ _" [ Var "X"; Var "XS" ]; Const "0"; Var "Y" ])
        (app "_ _" [ Var "Y"; Var "XS" ])
    ; eq
        (app "_[_<-_]" [ app "_ _" [ Var "X"; Var "XS" ]; app "s_" [ Var "N2" ]; Var "Y" ])
        (app "_ _" [ Var "X"; app "_[_<-_]" [ Var "XS"; Var "N2"; Var "Y" ] ])
    ; eq (app "drop" [ Const "0"; Var "XS" ]) (Var "XS")
    ; eq (app "drop" [ app "s_" [ Var "N" ]; Const "eps" ]) (Const "eps")
    ; ceq
        (app "drop"
           [ Var "N2"
           ; app "_ _"
               [ app "repeatSeq" [ Var "N"; Var "X" ]
               ; Var "XS"
               ]
           ])
        (app "_ _"
           [ app "repeatSeq"
               [ app "_-_" [ Var "N"; Var "N2" ]
               ; Var "X"
               ]
           ; Var "XS"
           ])
        [ BoolCond (app "_<=_" [ Var "N2"; Var "N" ]) ]
    ; ceq
        (app "drop"
           [ Var "N2"
           ; app "_ _"
               [ app "repeatSeq" [ Var "N"; Var "X" ]
               ; Var "XS"
               ]
           ])
        (app "drop"
           [ app "_-_" [ Var "N2"; Var "N" ]
           ; Var "XS"
           ])
        [ BoolCond (app "_<_" [ Var "N"; Var "N2" ]) ]
    ; ceq
        (app "drop"
           [ Var "N2"
           ; seq (run (Var "N") (Var "X")) (Var "XS")
           ])
        (seq
           (run (app "_-_" [ Var "N"; Var "N2" ]) (Var "X"))
           (Var "XS"))
        [ BoolCond (app "_<=_" [ Var "N2"; Var "N" ]) ]
    ; ceq
        (app "drop"
           [ Var "N2"
           ; seq (run (Var "N") (Var "X")) (Var "XS")
           ])
        (app "drop"
           [ app "_-_" [ Var "N2"; Var "N" ]
           ; Var "XS"
           ])
        [ BoolCond (app "_<_" [ Var "N"; Var "N2" ]) ]
    ; eq
        (app "drop" [ app "s_" [ Var "N" ]; app "_ _" [ Var "X"; Var "XS" ] ])
        (app "drop" [ Var "N"; Var "XS" ])
    ; eq (app "take" [ Const "0"; Var "XS" ]) (Const "eps")
    ; eq (app "take" [ app "s_" [ Var "N" ]; Const "eps" ]) (Const "eps")
    ; ceq
        (app "take"
           [ Var "N2"
           ; app "_ _"
               [ app "repeatSeq" [ Var "N"; Var "X" ]
               ; Var "XS"
               ]
           ])
        (app "repeatSeq" [ Var "N2"; Var "X" ])
        [ BoolCond (app "_<=_" [ Var "N2"; Var "N" ]) ]
    ; ceq
        (app "take"
           [ Var "N2"
           ; app "_ _"
               [ app "repeatSeq" [ Var "N"; Var "X" ]
               ; Var "XS"
               ]
           ])
        (app "_ _"
           [ app "repeatSeq" [ Var "N"; Var "X" ]
           ; app "take"
               [ app "_-_" [ Var "N2"; Var "N" ]
               ; Var "XS"
               ]
           ])
        [ BoolCond (app "_<_" [ Var "N"; Var "N2" ]) ]
    ; ceq
        (app "take"
           [ Var "N2"
           ; seq (run (Var "N") (Var "X")) (Var "XS")
           ])
        (repeat (Var "N2") (Var "X"))
        [ BoolCond (app "_<=_" [ Var "N2"; Var "N" ]) ]
    ; ceq
        (app "take"
           [ Var "N2"
           ; seq (run (Var "N") (Var "X")) (Var "XS")
           ])
        (seq
           (repeat (Var "N") (Var "X"))
           (app "take"
              [ app "_-_" [ Var "N2"; Var "N" ]
              ; Var "XS"
              ]))
        [ BoolCond (app "_<_" [ Var "N"; Var "N2" ]) ]
    ; eq
        (app "take"
           [ app "s_" [ Var "N" ]
           ; app "_ _" [ Var "X"; Var "XS" ]
           ])
        (app "_ _"
           [ Var "X"
           ; app "take" [ Var "N"; Var "XS" ]
           ])
      (* [takeRun] is extensionally [take], but keeps equal adjacent elements
         in the canonical carrier used by execution-state updates. *)
    ; eq (take_run (Const "0") (Var "XS")) (Const "eps")
    ; eq
        (take_run (app "s_" [ Var "N" ]) (Const "eps"))
        (Const "eps")
    ; ceq
        (take_run
           (Var "N2")
           (seq (repeat (Var "N") (Var "X")) (Var "XS")))
        (canonical_run (Var "N2") (Var "X"))
        [ BoolCond (app "_<=_" [ Var "N2"; Var "N" ]) ]
    ; ceq
        (take_run
           (Var "N2")
           (seq (repeat (Var "N") (Var "X")) (Var "XS")))
        (prepend_run
           (Var "N") (Var "X")
           (take_run
              (app "_-_" [ Var "N2"; Var "N" ])
              (Var "XS")))
        [ BoolCond (app "_<_" [ Var "N"; Var "N2" ]) ]
    ; ceq
        (take_run
           (Var "N2")
           (seq (run (Var "N") (Var "X")) (Var "XS")))
        (canonical_run (Var "N2") (Var "X"))
        [ BoolCond (app "_<=_" [ Var "N2"; Var "N" ]) ]
    ; ceq
        (take_run
           (Var "N2")
           (seq (run (Var "N") (Var "X")) (Var "XS")))
        (prepend_run
           (Var "N") (Var "X")
           (take_run
              (app "_-_" [ Var "N2"; Var "N" ])
              (Var "XS")))
        [ BoolCond (app "_<_" [ Var "N"; Var "N2" ]) ]
    ; eq
        (take_run
           (app "s_" [ Var "N" ])
           (seq (Var "X") (Var "XS")))
        (prepend_run
           (Const "1") (Var "X")
           (take_run (Var "N") (Var "XS")))
    ; eq
        (app "slice" [ Var "XS"; Var "N"; Var "N2" ])
        (app "take"
           [ Var "N2"
           ; app "drop" [ Var "N"; Var "XS" ]
           ])
      (* Splice follows the prefix once.  The repeat and ordinary cases rebuild
         exactly the sequence produced by take/index/drop, without a new value
         representation or a Wasm-specific shortcut. *)
    ; eq
        (splice (Const "eps") (Const "0") (Var "N2") (Var "VAL"))
        (Var "VAL")
    ; eq
        (splice
           (Const "eps") (app "s_" [ Var "N" ]) (Var "N2") (Var "VAL"))
        (Const "eps")
    ; ceq
        (splice
           (seq (repeat (Var "N") (Var "X")) (Var "XS"))
           (Var "N2") (Var "N3") (Var "VAL"))
        (seq
           (repeat (Var "N2") (Var "X"))
           (seq
              (Var "VAL")
              (drop
                 (Var "N3")
                 (seq
                    (repeat (app "_-_" [ Var "N"; Var "N2" ]) (Var "X"))
                    (Var "XS")))))
        [ BoolCond (app "_<_" [ Var "N2"; Var "N" ]) ]
    ; ceq
        (splice
           (seq (repeat (Var "N") (Var "X")) (Var "XS"))
           (Var "N2") (Var "N3") (Var "VAL"))
        (seq
           (repeat (Var "N") (Var "X"))
           (splice
              (Var "XS")
              (app "_-_" [ Var "N2"; Var "N" ])
              (Var "N3")
              (Var "VAL")))
        [ BoolCond (app "_<=_" [ Var "N"; Var "N2" ]) ]
    ; eq
        (splice
           (seq (Var "X") (Var "XS"))
           (Const "0") (Var "N2") (Var "VAL"))
        (seq
           (Var "VAL")
           (drop (Var "N2") (seq (Var "X") (Var "XS"))))
    ; eq
        (splice
           (seq (Var "X") (Var "XS"))
           (app "s_" [ Var "N" ]) (Var "N2") (Var "VAL"))
        (seq
           (Var "X")
           (splice (Var "XS") (Var "N") (Var "N2") (Var "VAL")))
      (* [runSeq] denotes the same sequence as [repeatSeq] but remains opaque.
         [canonicalRun] leaves standalone short runs in ordinary source shape;
         [compactRun] preserves runs created by internal updates.
         The run helpers normalize reducible carriers before inspecting their
         head.  Direct carrier rules only consume irreducible counts, so their
         result is independent of Maude's argument-reduction strategy.
         [prependRun] compares values by repeated-variable matching after Maude
         canonicalization; it does not invent a value equivalence.  Thus the
         equations below satisfy

           denote (spliceRun xs i n ys) = splice (denote xs) i n (denote ys)

         without changing the source transition relation. *)
    ; eq
        (prepend_run (Const "0") (Var "X") (Var "XS"))
        (Var "XS")
    ; eq
        (prepend_run (app "s_" [ Var "N" ]) (Var "X") (Const "eps"))
        (compact_run (app "s_" [ Var "N" ]) (Var "X"))
    ; eq
        (prepend_run
           (app "s_" [ Var "N" ]) (Var "X")
           (seq
              (run
                 (app "s_" [ app "s_" [ Var "N2" ] ])
                 (Var "X"))
              (Var "XS")))
        (prepend_run
           (app "_+_"
              [ app "s_" [ Var "N" ]
              ; app "s_" [ app "s_" [ Var "N2" ] ]
              ])
           (Var "X") (Var "XS"))
    ; eq ~attrs:[ Owise ]
        (prepend_run
           (app "s_" [ Var "N" ]) (Var "X")
           (seq
              (run
                 (app "s_" [ app "s_" [ Var "N2" ] ])
                 (Var "Y"))
              (Var "XS")))
        (seq
           (compact_run (app "s_" [ Var "N" ]) (Var "X"))
           (seq
              (run
                 (app "s_" [ app "s_" [ Var "N2" ] ])
                 (Var "Y"))
              (Var "XS")))
    ; eq
        (prepend_run
           (app "s_" [ Var "N" ]) (Var "X")
           (seq (repeat (Var "N2") (Var "X")) (Var "XS")))
        (prepend_run
           (app "_+_" [ app "s_" [ Var "N" ]; Var "N2" ])
           (Var "X") (Var "XS"))
    ; ceq ~attrs:[ Owise ]
        (prepend_run
           (app "s_" [ Var "N" ]) (Var "X")
           (seq (repeat (Var "N2") (Var "Y")) (Var "XS")))
        (seq
           (compact_run (app "s_" [ Var "N" ]) (Var "X"))
           (seq (repeat (Var "N2") (Var "Y")) (Var "XS")))
        [ BoolCond
            (app "_>=_"
               [ Var "N2"; Const "compactRepeatThreshold" ])
        ]
    ; eq
        (prepend_run
           (app "s_" [ Var "N" ]) (Var "X")
           (seq (Var "X") (Var "XS")))
        (prepend_run
           (app "s_" [ app "s_" [ Var "N" ] ])
           (Var "X") (Var "XS"))
    ; eq ~attrs:[ Owise ]
        (prepend_run
           (app "s_" [ Var "N" ]) (Var "X")
           (seq (Var "Y") (Var "XS")))
        (seq
           (compact_run (app "s_" [ Var "N" ]) (Var "X"))
           (seq (Var "Y") (Var "XS")))
    ; eq
        (append_runs (Const "eps") (Var "XS"))
        (Var "XS")
    ; eq
        (append_runs
           (seq
              (run
                 (app "s_" [ app "s_" [ Var "N" ] ])
                 (Var "X"))
              (Var "XS"))
           (Var "YS"))
        (prepend_run
           (app "s_" [ app "s_" [ Var "N" ] ]) (Var "X")
           (append_runs (Var "XS") (Var "YS")))
    ; eq
        (append_runs
           (seq (repeat (Var "N") (Var "X")) (Var "XS"))
           (Var "YS"))
        (prepend_run
           (Var "N") (Var "X")
           (append_runs (Var "XS") (Var "YS")))
    ; eq
        (append_runs
           (seq (Var "X") (Var "XS"))
           (Var "YS"))
        (prepend_run
           (Const "1") (Var "X")
           (append_runs (Var "XS") (Var "YS")))
    ; eq
        (splice_run (Const "eps") (Const "0") (Var "N2") (Var "VAL"))
        (append_runs (Var "VAL") (Const "eps"))
    ; eq
        (splice_run
           (Const "eps") (app "s_" [ Var "N" ]) (Var "N2") (Var "VAL"))
        (Const "eps")
    ; ceq
        (splice_run
           (seq (repeat (Var "N") (Var "X")) (Var "XS"))
           (Var "N2") (Var "N3") (Var "VAL"))
        (prepend_run
           (Var "N2") (Var "X")
           (append_runs
              (Var "VAL")
              (drop
                 (Var "N3")
                 (seq
                    (repeat (app "_-_" [ Var "N"; Var "N2" ]) (Var "X"))
                    (Var "XS")))))
        [ BoolCond (app "_<_" [ Var "N2"; Var "N" ]) ]
    ; ceq
        (splice_run
           (seq (repeat (Var "N") (Var "X")) (Var "XS"))
           (Var "N2") (Var "N3") (Var "VAL"))
        (prepend_run
           (Var "N") (Var "X")
           (splice_run
              (Var "XS")
              (app "_-_" [ Var "N2"; Var "N" ])
              (Var "N3") (Var "VAL")))
        [ BoolCond (app "_<=_" [ Var "N"; Var "N2" ]) ]
    ; ceq
        (splice_run
           (seq
              (run
                 (app "s_" [ app "s_" [ Var "N" ] ])
                 (Var "X"))
              (Var "XS"))
           (Var "N2") (Var "N3") (Var "VAL"))
        (prepend_run
           (Var "N2") (Var "X")
           (append_runs
              (Var "VAL")
              (drop
                 (Var "N3")
                 (seq
                    (run
                       (app "_-_"
                          [ app "s_" [ app "s_" [ Var "N" ] ]
                          ; Var "N2"
                          ])
                       (Var "X"))
                    (Var "XS")))))
        [ BoolCond
            (app "_<_"
               [ Var "N2"; app "s_" [ app "s_" [ Var "N" ] ] ])
        ]
    ; ceq
        (splice_run
           (seq
              (run
                 (app "s_" [ app "s_" [ Var "N" ] ])
                 (Var "X"))
              (Var "XS"))
           (Var "N2") (Var "N3") (Var "VAL"))
        (prepend_run
           (app "s_" [ app "s_" [ Var "N" ] ]) (Var "X")
           (splice_run
              (Var "XS")
              (app "_-_"
                 [ Var "N2"; app "s_" [ app "s_" [ Var "N" ] ] ])
              (Var "N3") (Var "VAL")))
        [ BoolCond
            (app "_<=_"
               [ app "s_" [ app "s_" [ Var "N" ] ]; Var "N2" ])
        ]
    ; eq
        (splice_run
           (seq (Var "X") (Var "XS"))
           (Const "0") (Var "N2") (Var "VAL"))
        (append_runs
           (Var "VAL")
           (drop (Var "N2") (seq (Var "X") (Var "XS"))))
    ; eq
        (splice_run
           (seq (Var "X") (Var "XS"))
           (app "s_" [ Var "N" ]) (Var "N2") (Var "VAL"))
        (prepend_run
           (Const "1") (Var "X")
           (splice_run (Var "XS") (Var "N") (Var "N2") (Var "VAL")))
    ; eq (T.typecheck (Var "K") (Var "T")) (Const "false") ~attrs:[ Owise ]
  ]

let statements =
  declarations @ variables @ core_equations @ typecheck_equations @ data_equations
  |> List.map gen
