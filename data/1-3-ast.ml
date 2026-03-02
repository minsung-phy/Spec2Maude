(* phrase 래퍼를 생략한 순수 AST 구조
   dummy_lbl = TupE [] : 튜플 내에서 레이블이 없는 경우를 나타내는 빈 표현식
*)
let dummy_lbl = TupE []

let spectec_ast : script = [

  (* 1. 숫자 타입 정의 (num_): $sizenn 함수 호출을 통한 가변 크기 처리 *)
  TypD ("num_", 
    [ TypP "numtype" ], 
    [ InstD (
        [ TypB ("Inn", VarT ("numtype", [])) ], 
        [ TypA (VarT ("Inn", [])) ], 
        AliasT (VarT ("iN", [ 
          ExpA (CallE ("$sizenn", [ ExpA (VarE "Inn") ])) 
        ]))
    )]
  );

  (* 2. 이항 연산자 (binop_): % 기호는 부호(sx)가 필요한 연산을 의미 *)
  TypD ("binop_", 
    [ TypP "numtype" ],
    [ InstD (
        [ TypB ("Inn", VarT ("numtype", [])) ],
        [ TypA (VarT ("Inn", [])) ],
        VariantT [
          (["ADD"], ([], TupT [], []), []);
          (["SUB"], ([], TupT [], []), []);
          (["MUL"], ([], TupT [], []), []);
          (["DIV%"], ([], VarT ("sx", []), []), []);
          (["REM%"], ([], VarT ("sx", []), []), []);
          (["AND"], ([], TupT [], []), []);
          (["OR"], ([], TupT [], []), []);
          (["XOR"], ([], TupT [], []), []);
          (["SHL"], ([], TupT [], []), []);
          (["SHR%"], ([], VarT ("sx", []), []), []);
          (["ROTL"], ([], TupT [], []), []);
          (["ROTR"], ([], TupT [], []), []);
        ]
    )]
  );

  (* 3. 비교 연산자 (relop_) *)
  TypD ("relop_", 
    [ TypP "numtype" ],
    [ InstD (
        [ TypB ("Inn", VarT ("numtype", [])) ],
        [ TypA (VarT ("Inn", [])) ],
        VariantT [
          (["EQ"], ([], TupT [], []), []);
          (["NE"], ([], TupT [], []), []);
          (["GT%"], ([], VarT ("sx", []), []), []);
        ]
    )]
  );

  (* 4. 블록 타입 (blocktype) *)
  TypD ("blocktype", [], 
    [ InstD (
        [], [],
        VariantT [
          (["_RESULT%"], ([], IterT (VarT ("valtype", []), Opt), []), []);
          (["_IDX%"], ([], VarT ("typeidx", []), []), [])
        ]
    )]
  );

  (* 5. 명령어 통합 (instr): 모든 카테고리와 실행 상태를 하나로 통합 *)
  TypD ("instr", [], [
    InstD ([], [], VariantT [
      (* --- 수치 명령어 --- *)
      (["CONST%%"], ([], TupT [
        (dummy_lbl, VarT ("numtype", [])); 
        (dummy_lbl, VarT ("num_", [ TypA (VarT ("numtype", [])) ]))
      ], []), []);
      
      (["BINOP%%"], ([], TupT [
        (dummy_lbl, VarT ("numtype", [])); 
        (dummy_lbl, VarT ("binop_", [ TypA (VarT ("numtype", [])) ]))
      ], []), []);

      (["RELOP%%"], ([], TupT [
        (dummy_lbl, VarT ("numtype", [])); 
        (dummy_lbl, VarT ("relop_", [ TypA (VarT ("numtype", [])) ]))
      ], []), []);

      (* --- 로컬 명령어 --- *)
      (["LOCAL.GET%"], ([], VarT ("localidx", []), []), []);
      (["LOCAL.SET%"], ([], VarT ("localidx", []), []), []);

      (* --- 제어 흐름 명령어 --- *)
      (["BLOCK%%"], ([], TupT [
        (dummy_lbl, VarT ("blocktype", []));
        (dummy_lbl, IterT (VarT ("instr", []), List))
      ], []), []);
      
      (["LOOP%%"], ([], TupT [
        (dummy_lbl, VarT ("blocktype", []));
        (dummy_lbl, IterT (VarT ("instr", []), List))
      ], []), []);
      
      (["IF%%ELSE%"], ([], TupT [
        (dummy_lbl, VarT ("blocktype", []));
        (dummy_lbl, IterT (VarT ("instr", []), List));
        (dummy_lbl, IterT (VarT ("instr", []), List))
      ], []), []);

      (["BR%"], ([], VarT ("labelidx", []), []), []);
      (["BR_IF%"], ([], VarT ("labelidx", []), []), []);

      (* --- 호출 명령어 --- *)
      (["CALL%"], ([], VarT ("funcidx", []), []), []);
      (["CALL_REF%"], ([], VarT ("typeuse", []), []), []);
      (["REF.FUNC%"], ([], VarT ("funcidx", []), []), []);
    ])
  ]);

  (* 6. 표현식 (expr) *)
  TypD ("expr", [], 
    [ InstD (
        [], [],
        AliasT (IterT (VarT ("instr", []), List))
    )]
  );
]