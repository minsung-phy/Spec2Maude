open Il.Ast
open Translator
open Util.Source

let region = no_region
let id text = text $ region
let atom text = Xl.Atom.Atom text $$ region % Xl.Atom.info "record-composition"
let nat_typ = NumT `NatT $ region
let list_typ = IterT (nat_typ, List) $ region
let opt_typ = IterT (nat_typ, Opt) $ region
let record_typ name = VarT (id name, []) $ region
let field name typ = atom name, (typ, [], []), []

let record_type name fields =
  TypD
    ( id name
    , []
    , [ InstD ([], [], StructT fields $ region) $ region ] )
  $ region

let () =
  let nested_typ = record_typ "nested_probe" in
  let script =
    [ record_type "nested_probe" [ field "ITEMS" list_typ ]
    ; record_type "record_probe"
        [ field "MAYBE" opt_typ
        ; field "VALUES" list_typ
        ; field "NESTED" nested_typ
        ]
    ]
  in
  let result = Driver.translate script in
  print_string (Emit.render_module result.module_);
  print_endline
    "red compose.rec.record-probe(rec.record-probe(eps, 1, rec.nested-probe(3)), rec.record-probe(0, 2, rec.nested-probe(4))) .";
  print_endline
    "red compose.rec.record-probe(rec.record-probe(0, 1, rec.nested-probe(3)), rec.record-probe(5, 2, rec.nested-probe(4))) ."
