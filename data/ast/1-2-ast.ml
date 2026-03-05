(* 1. syntax null = NULL *)
TypD (id "null", [], [
  InstD ([], [], VariantT [
    (it = Atom.Atom "NULL", ([], TupT [], []), [])
  ])
]);

(* 2. syntax addrtype = I32 | I64 *)
TypD (id "addrtype", [], [
  InstD ([], [], VariantT [
    (it = Atom.Atom "I32", ([], TupT [], []), []);
    (it = Atom.Atom "I64", ([], TupT [], []), [])
  ])
]);

(* 3. syntax numtype = I32 | I64 | F32 | F64 *)
TypD (id "numtype", [], [
  InstD ([], [], VariantT [
    (it = Atom.Atom "I32", ([], TupT [], []), []);
    (it = Atom.Atom "I64", ([], TupT [], []), []);
    (it = Atom.Atom "F32", ([], TupT [], []), []);
    (it = Atom.Atom "F64", ([], TupT [], []), [])
  ])
]);

(* 4. syntax deftype = _DEF rectype n *)
TypD (id "deftype", [], [
  InstD ([], [], VariantT [
    (it = Atom.Atom "_DEF", (
      [ExpB (id "rectype"); ExpB (id "n", NumT Nat)], TupT [], []
    ), [])
  ])
]);

(* 5. syntax typeuse/syn = _IDX typeidx *)
TypD (id "typeuse/syn", [], [
  InstD ([], [], VariantT [
    (it = Atom.Atom "_IDX", (
      [ExpB (id "idx", VarT (id "typeidx", []))], TupT [], []
    ), [])
  ])
]);

(* 6. syntax typeuse/sem = ... | deftype | REC n *)
TypD (id "typeuse/sem", [], [
  InstD ([], [], VariantT [
    (it = Atom.Atom "deftype", ([], VarT (id "deftype", []), []), []);
    (it = Atom.Atom "REC", (
      [ExpB (id "n", NumT Nat)], TupT [], []
    ), [])
  ])
]);

(* 7. def $size(numtype) : nat *)
DecD (id "$size", [ExpP (id "nt", VarT (id "numtype", []))], NumT Nat, [
  DefD ([], [ExpA (VarE (id "I32"))], NumE (Num.from_int 32), []);
  DefD ([], [ExpA (VarE (id "I64"))], NumE (Num.from_int 64), []);
  DefD ([], [ExpA (VarE (id "F32"))], NumE (Num.from_int 32), []);
  DefD ([], [ExpA (VarE (id "F64"))], NumE (Num.from_int 64), [])
]);

(* 8. def $sizenn(numtype) : nat   hint... 
    def $sizenn(nt) = $size(nt) *)
DecD (id "$sizenn", [ExpP (id "nt", VarT (id "numtype", []))], NumT Nat, [                                                  
    DefD ([], [ExpA (VarE (id "nt"))], CallE (id "$size", [ExpA (VarE (id "nt"))]), [])
  ]
)

(* 9. syntax Inn = addrtype (Alias) *)
TypD (id "Inn", [], [
  InstD ([], [], AliasT (VarT (id "addrtype", [])))
]);

(* 10. syntax valtype/syn = numtype | ... *)
TypD (id "valtype/syn", [], [
  InstD ([], [], VariantT [
    (it = Atom.Atom "numtype", ([], VarT (id "numtype", []), []), [])
  ])
])

----------------------------------------------------

(* 아래 부분(1-2.spectec의 일부)만 변환하면 됨

syntax null = NULL

syntax addrtype =
  | I32 | I64

syntax numtype =
  | I32 | I64 | F32 | F64

syntax deftype =
  | _DEF rectype n

syntax typeuse/syn =
  | _IDX typeidx | ...
syntax typeuse/sem =
  | ... | deftype | REC n 

def $size(numtype) : nat       
def $size(I32) = 32
def $size(I64) = 64
def $size(F32) = 32
def $size(F64) = 64

def $sizenn(numtype) : nat   
def $sizenn(nt) = $size(nt)

syntax Inn = addrtype

syntax valtype/syn =
  | numtype | ...

*)