[
  (* 1. $bool 함수 *)
  DecD (id "$bool", 
    [ExpP (id "bool", VarT (id "bool", []))], 
    VarT (id "nat", []), (* 명세에서는 nat를 타입으로 씁니다 *)
    [
      (* def $bool(false) = 0 *)
      DefD ([], [ExpA (VarE (id "false"))], NumE (Num.from_int 0), []);
      (* def $bool(true) = 1 *)
      DefD ([], [ExpA (VarE (id "true"))],  NumE (Num.from_int 1), [])
    ]
  );

  (* 2. $iadd_ 함수 *)
  DecD (id "$iadd_",
    [ TypP (id "N"); 
      ExpP (id "i_1", VarT (id "iN", [TypA (VarT (id "N", []))])); 
      ExpP (id "i_2", VarT (id "iN", [TypA (VarT (id "N", []))])) ],
    VarT (id "iN", [TypA (VarT (id "N", []))]),
    [
      (* def $iadd_(N, i_1, i_2) = $((i_1 + i_2) \ 2^N) *)
      DefD ([],
        [TypA (VarT (id "N", [])); ExpA (VarE (id "i_1")); ExpA (VarE (id "i_2"))],
        BinE (`ModOp, 
          BinE (`AddOp, VarE (id "i_1"), VarE (id "i_2")),
          BinE (`PowOp, NumE (Num.from_int 2), VarE (id "N"))
        ),
        []
      )
    ]
  );

  (* 3. $isub_ 함수 *)
  DecD (id "$isub_",
    [ TypP (id "N"); 
      ExpP (id "i_1", VarT (id "iN", [TypA (VarT (id "N", []))])); 
      ExpP (id "i_2", VarT (id "iN", [TypA (VarT (id "N", []))])) ],
    VarT (id "iN", [TypA (VarT (id "N", []))]),
    [
      (* def $isub_(N, i_1, i_2) = $((2^N + i_1 - i_2) \ 2^N) *)
      DefD ([],
        [TypA (VarT (id "N", [])); ExpA (VarE (id "i_1")); ExpA (VarE (id "i_2"))],
        BinE (`ModOp,
          BinE (`SubOp,
            BinE (`AddOp, BinE (`PowOp, NumE (Num.from_int 2), VarE (id "N")), VarE (id "i_1")),
            VarE (id "i_2")
          ),
          BinE (`PowOp, NumE (Num.from_int 2), VarE (id "N"))
        ),
        []
      )
    ]
  );

  (* 4. $binop_ 함수 *)
  DecD (id "$binop_",
    [ TypP (id "numtype"); 
      ExpP (id "op",  VarT (id "binop_", [TypA (VarT (id "numtype", []))])); 
      ExpP (id "i_1", VarT (id "num_",   [TypA (VarT (id "numtype", []))])); 
      ExpP (id "i_2", VarT (id "num_",   [TypA (VarT (id "numtype", []))])) ],
    IterT (VarT (id "num_", [TypA (VarT (id "numtype", []))]), List),
    [
      (* def $binop_(Inn, ADD, i_1, i_2) = $iadd_($sizenn(Inn), i_1, i_2) *)
      DefD ([], 
        [ TypA (VarT (id "Inn", [])); 
          ExpA (CaseE ([[id "ADD"]], None)); (* 생성자는 CaseE로 매핑됨 *)
          ExpA (VarE (id "i_1")); 
          ExpA (VarE (id "i_2")) ],
        CallE (id "$iadd_", [
          ExpA (CallE (id "$sizenn", [TypA (VarT (id "Inn", []))])); 
          ExpA (VarE (id "i_1")); 
          ExpA (VarE (id "i_2"))
        ]),
        []
      );

      (* def $binop_(Inn, SUB, i_1, i_2) = $isub_($sizenn(Inn), i_1, i_2) *)
      DefD ([], 
        [ TypA (VarT (id "Inn", [])); 
          ExpA (CaseE ([[id "SUB"]], None)); 
          ExpA (VarE (id "i_1")); 
          ExpA (VarE (id "i_2")) ],
        CallE (id "$isub_", [
          ExpA (CallE (id "$sizenn", [TypA (VarT (id "Inn", []))])); 
          ExpA (VarE (id "i_1")); 
          ExpA (VarE (id "i_2"))
        ]),
        []
      )
    ]
  );

  (* 5. $ieq_ 함수 *)
  DecD (id "$ieq_",
    [ TypP (id "N"); 
      ExpP (id "i_1", VarT (id "iN", [TypA (VarT (id "N", []))])); 
      ExpP (id "i_2", VarT (id "iN", [TypA (VarT (id "N", []))])) ],
    VarT (id "u32", []),
    [
      (* def $ieq_(N, i_1, i_2) = $bool(i_1 = i_2) *)
      DefD ([],
        [TypA (VarT (id "N", [])); ExpA (VarE (id "i_1")); ExpA (VarE (id "i_2"))],
        CallE (id "$bool", [
          ExpA (CmpE (`EqOp, VarE (id "i_1"), VarE (id "i_2")))
        ]),
        []
      )
    ]
  );

  (* 6. $relop_ 함수 *)
  DecD (id "$relop_",
    [ TypP (id "numtype"); 
      ExpP (id "op",  VarT (id "relop_", [TypA (VarT (id "numtype", []))])); 
      ExpP (id "i_1", VarT (id "num_",   [TypA (VarT (id "numtype", []))])); 
      ExpP (id "i_2", VarT (id "num_",   [TypA (VarT (id "numtype", []))])) ],
    VarT (id "u32", []),
    [
      (* def $relop_(Inn, EQ, i_1, i_2) = $ieq_($sizenn(Inn), i_1, i_2) *)
      DefD ([], 
        [ TypA (VarT (id "Inn", [])); 
          ExpA (CaseE ([[id "EQ"]], None)); 
          ExpA (VarE (id "i_1")); 
          ExpA (VarE (id "i_2")) ],
        CallE (id "$ieq_", [
          ExpA (CallE (id "$sizenn", [TypA (VarT (id "Inn", []))])); 
          ExpA (VarE (id "i_1")); 
          ExpA (VarE (id "i_2"))
        ]),
        []
      )
    ]
  )
]