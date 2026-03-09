[
  (* 1. syntax init = | SET | UNSET *)
  TypD ("init", 
    [], (* 매개변수 없음 *)
    [ InstD (
        [], [], 
        VariantT [
          (* 인자가 없는 0항 생성자들이므로 TupT [] 사용 *)
          (["SET"], ([], TupT [], []), []);
          (["UNSET"], ([], TupT [], []), [])
        ]
    )]
  );

  (* 2. syntax localtype = init valtype *)
  TypD ("localtype", 
    [], 
    [ InstD (
        [], [], 
        VariantT [
          (* 명시적인 키워드(생성자 이름)가 없는 순수 병치(Juxtaposition) 구문 *)
          (* 파서에 따라 빈 문자열 [""] 이나 내부적으로 묶는 가짜 생성자 이름을 쓸 수 있음 *)
          ([""], (
            [], 
            TupT [
              (VarE "_", VarT ("init", [])); 
              (VarE "_", VarT ("valtype", []))
            ], 
            []
          ), [])
        ]
    )]
  );

  (* 3. syntax instrtype = resulttype ->_ localidx* resulttype *)
  TypD ("instrtype", 
    [], 
    [ InstD (
        [], [], 
        VariantT [
          (* 화살표 기호(->_)를 하나의 믹스픽스(Mixfix) 연산자 이름으로 취급 *)
          (["%->_%%"], (
            [], 
            TupT [
              (VarE "_", VarT ("resulttype", []));
              (VarE "_", IterT (VarT ("localidx", []), List)); (* localidx* 처리 *)
              (VarE "_", VarT ("resulttype", []))
            ], 
            []
          ), [])
        ]
    )]
  )
]