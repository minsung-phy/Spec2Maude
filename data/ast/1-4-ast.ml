[
  (* 1. syntax local = LOCAL valtype *)
  TypD ("local", 
    [], (* params: 바인더가 없으므로 빈 리스트 *)
    [ InstD (
        [], (* binds *)
        [], (* args *)
        VariantT [
          (* mixop, (bind list, typ, prem list), hint list *)
          (["LOCAL"], ([], VarT ("valtype", []), []), [])
        ]
    )]
  );

  (* 2-2. syntax func = FUNC typeidx local* expr *)
  TypD ("func", 
    [], 
    [ InstD (
        [], 
        [], 
        VariantT [
          (["FUNC"], (
            [], 
            (* 여러 개의 인자를 받으므로 TupT 사용. 
               ast.ml에서 TupT는 (exp * typ) list 형태를 받음. 
               (명시적인 필드 이름이 없으므로 exp 자리에는 VarE "_" 같은 더미를 넣음) *)
            TupT [
              (VarE "_", VarT ("typeidx", [])); 
              (VarE "_", IterT (VarT ("local", []), List)); (* 핵심: local* 의 IterT 래핑 *)
              (VarE "_", VarT ("expr", []))
            ], 
            []
          ), [])
        ]
    )]
  )
]