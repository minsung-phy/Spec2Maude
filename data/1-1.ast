(* Wasm 3.0 진짜 AST 구조: 
   uN, sN도 GramD가 아니라 TypD 안의 VariantT 조건절(if)로 정의됨 
*)

(* 1. uN(N): TypD + VariantT (조건 i >= 0 && i < 2^N) *)
TypD (id "uN", [ExpP (id "N", NumT Nat)], [
  InstD ([], [ExpA (VarE (id "N"))], 
    VariantT [
      ("%", ([ExpB (id "i", NumT Nat)], NumT Nat, [
        IfPr (BinE (And, BoolT, 
          CmpE (Ge, NumT Nat, VarE (id "i"), NumE (Num.from_int 0)),
          CmpE (Le, NumT Nat, VarE (id "i"), BinE (Sub, NumT Nat, BinE (Pow, NumT Nat, NumE (Num.from_int 2), VarE (id "N")), NumE (Num.from_int 1)))
        ))
      ]), [])
    ]
  )
]);

(* 2. sN(N): TypD + VariantT (조건 -2^(N-1) <= i <= 2^(N-1)-1) *)
TypD (id "sN", [ExpP (id "N", NumT Nat)], [
  InstD ([], [ExpA (VarE (id "N"))], 
    VariantT [
      ("%", ([ExpB (id "i", NumT Int)], NumT Int, [
        IfPr (BinE (And, BoolT, 
          CmpE (Ge, NumT Int, VarE (id "i"), UnE (Neg, NumT Int, BinE (Pow, NumT Nat, NumE (Num.from_int 2), BinE (Sub, NumT Nat, VarE (id "N"), NumE (Num.from_int 1))))),
          CmpE (Le, NumT Int, VarE (id "i"), BinE (Sub, NumT Int, BinE (Pow, NumT Nat, NumE (Num.from_int 2), BinE (Sub, NumT Nat, VarE (id "N"), NumE (Num.from_int 1))), NumE (Num.from_int 1)))
        ))
      ]), [])
    ]
  )
]);

(* 3. iN(N) = uN(N) (AliasT) *)
TypD (id "iN", [ExpP (id "N", NumT Nat)], [
  InstD ([], [ExpA (VarE (id "N"))], AliasT (VarT (id "uN", [ExpA (VarE (id "N"))])))
]);

(* 4. 구체적 비트수 타입들 (AliasT) *)
TypD (id "u8", [], [InstD ([], [], AliasT (VarT (id "uN", [ExpA (NumE (Num.from_int 8)) ])))]);
TypD (id "u16", [], [InstD ([], [], AliasT (VarT (id "uN", [ExpA (NumE (Num.from_int 16)) ])))]);
TypD (id "u32", [], [InstD ([], [], AliasT (VarT (id "uN", [ExpA (NumE (Num.from_int 32)) ])))]);
TypD (id "u64", [], [InstD ([], [], AliasT (VarT (id "uN", [ExpA (NumE (Num.from_int 64)) ])))]);
TypD (id "u128", [], [InstD ([], [], AliasT (VarT (id "uN", [ExpA (NumE (Num.from_int 128)) ])))]);
TypD (id "s33", [], [InstD ([], [], AliasT (VarT (id "sN", [ExpA (NumE (Num.from_int 33)) ])))]);

(* 5. 인덱스 및 상속 타입들 (전부 AliasT) *)
TypD (id "idx", [], [InstD ([], [], AliasT (VarT (id "u32", [])))]);
TypD (id "laneidx", [], [InstD ([], [], AliasT (VarT (id "u8", [])))]);
TypD (id "typeidx", [], [InstD ([], [], AliasT (VarT (id "idx", [])))]);
TypD (id "funcidx", [], [InstD ([], [], AliasT (VarT (id "idx", [])))]);
TypD (id "globalidx", [], [InstD ([], [], AliasT (VarT (id "idx", [])))]);
TypD (id "tableidx", [], [InstD ([], [], AliasT (VarT (id "idx", [])))]);
TypD (id "memidx", [], [InstD ([], [], AliasT (VarT (id "idx", [])))]);
TypD (id "tagidx", [], [InstD ([], [], AliasT (VarT (id "idx", [])))]);
TypD (id "elemidx", [], [InstD ([], [], AliasT (VarT (id "idx", [])))]);
TypD (id "dataidx", [], [InstD ([], [], AliasT (VarT (id "idx", [])))]);
TypD (id "labelidx", [], [InstD ([], [], AliasT (VarT (id "idx", [])))]);
TypD (id "localidx", [], [InstD ([], [], AliasT (VarT (id "idx", [])))]);
TypD (id "fieldidx", [], [InstD ([], [], AliasT (VarT (id "idx", [])))]);