open Il.Ast
open Translator
open Util.Source

let region = no_region
let id text = text $ region
let atom text = Xl.Atom.Atom text $$ region % Xl.Atom.info "regression"
let nat_typ = NumT `NatT $ region
let bool_typ = BoolT $ region
let nat value = NumE (`Nat (Z.of_int value)) $$ region % nat_typ

let owner_typ owner =
  VarT (id owner, []) $ region

let sequence_typ =
  IterT (nat_typ, List) $ region

let variable typ name =
  VarE (id name) $$ region % typ

let field_dot field record =
  DotE (record, field) $$ region % sequence_typ

let record_declaration_with owner field field_typ =
  let shape = StructT [ field, (field_typ, [], []), [] ] $ region in
  let instance = InstD ([], [], shape) $ region in
  TypD (id owner, [], [ instance ]) $ region

let record_declaration owner field =
  record_declaration_with owner field sequence_typ

let alias_declaration name typ =
  let instance = InstD ([], [], AliasT typ $ region) $ region in
  TypD (id name, [], [ instance ]) $ region

let equality left right =
  IfPr
    (CmpE (`EqOp, `NatT, left, right) $$ region % bool_typ)
  $ region

let record_value owner field value =
  StrE [ field, value ] $$ region % owner_typ owner

let identity_sequence typ name =
  let item = variable nat_typ "item" in
  let source = variable typ name in
  IterE (item, (List, [ id "item", source ])) $$ region % typ

let captured_length_definition owner field sequence_typ =
  let record_typ = owner_typ owner in
  let record = variable record_typ "record" in
  let captured = identity_sequence sequence_typ "payload" in
  let pattern = record_value owner field captured in
  let payload = variable sequence_typ "payload" in
  let body = LenE payload $$ region % nat_typ in
  let parameter = ExpP (id "record", record_typ) $ region in
  let clause = DefD ([], [ ExpA record $ region ], body,
    [ equality record pattern ]) $ region in
  DecD (id "captured_length", [ parameter ], nat_typ, [ clause ]) $ region

let reused_payload_definition owner field =
  let record_typ = owner_typ owner in
  let payload = variable sequence_typ "payload" in
  let pattern =
    record_value owner field (identity_sequence sequence_typ "payload")
  in
  let params =
    [ ExpP (id "payload", sequence_typ) $ region
    ; ExpP (id "record", record_typ) $ region
    ]
  in
  let args = [ ExpA payload $ region; ExpA pattern $ region ] in
  let clause = DefD ([], args, nat 0, []) $ region in
  DecD (id "reused_payload", params, nat_typ, [ clause ]) $ region

let outward_iteration_definition owner field =
  let record_typ = owner_typ owner in
  let record = variable record_typ "record" in
  let pattern =
    record_value owner field (identity_sequence sequence_typ "payload")
  in
  let output = variable sequence_typ "output" in
  let iter = List, [ id "item", output ] in
  let premise = IterPr (equality record pattern, iter) $ region in
  let parameter = ExpP (id "record", record_typ) $ region in
  let clause = DefD ([], [ ExpA record $ region ], nat 0, [ premise ]) $ region in
  DecD (id "outward_iteration", [ parameter ], nat_typ, [ clause ]) $ region

let structured_pattern_definition owner field =
  let record_typ = owner_typ owner in
  let record = variable record_typ "record" in
  let element = variable nat_typ "element" in
  let pattern =
    record_value owner field
      (ListE [ element ] $$ region % sequence_typ)
  in
  let parameter = ExpP (id "record", record_typ) $ region in
  let clause = DefD ([], [ ExpA record $ region ], nat 0,
    [ equality record pattern ]) $ region in
  DecD (id "structured_pattern", [ parameter ], nat_typ, [ clause ]) $ region

let producer_definition owner field iter =
  let record_typ = owner_typ owner in
  let output = variable record_typ "output" in
  let produced = IterE (nat 0, (iter, [])) $$ region % sequence_typ in
  let value = record_value owner field produced in
  let clause = DefD ([], [], output, [ equality output value ]) $ region in
  DecD (id "producer", [], record_typ, [ clause ]) $ region

let dependent_escape_definition owner field =
  let record_typ = owner_typ owner in
  let record = variable record_typ "record" in
  let payload = identity_sequence sequence_typ "payload" in
  let pattern = record_value owner field payload in
  let escaped =
    CallE
      (id "consume", [ ExpA (variable sequence_typ "payload") $ region ])
    $$ region % bool_typ
  in
  let guard = IfPr escaped $ region in
  let typ = TupT [ id "record", record_typ ] $ region in
  let shape =
    StructT [ atom "CASE", (typ, [], [ equality record pattern; guard ]), [] ]
    $ region
  in
  let instance = InstD ([], [], shape) $ region in
  TypD (id "dependent", [], [ instance ]) $ region

let update_definition owner field =
  let owner_typ = owner_typ owner in
  let record = variable owner_typ "record" in
  let root = RootP $$ region % owner_typ in
  let selected = DotP (root, field) $$ region % sequence_typ in
  let path = SliceP (selected, nat 0, nat 1) $$ region % sequence_typ in
  let replacement = ListE [ nat 0 ] $$ region % sequence_typ in
  let body = UpdE (record, path, replacement) $$ region % owner_typ in
  let parameter = ExpP (id "record", owner_typ) $ region in
  let argument = ExpA record $ region in
  let clause = DefD ([], [ argument ], body, []) $ region in
  DecD (id "replace", [ parameter ], owner_typ, [ clause ]) $ region

let observe_definition owner field =
  let owner_typ = owner_typ owner in
  let record = variable owner_typ "record" in
  let body = LenE (field_dot field record) $$ region % nat_typ in
  let parameter = ExpP (id "record", owner_typ) $ region in
  let argument = ExpA record $ region in
  let clause = DefD ([], [ argument ], body, []) $ region in
  DecD (id "length", [ parameter ], nat_typ, [ clause ]) $ region

let escape_definition owner field =
  let owner_typ = owner_typ owner in
  let record = variable owner_typ "record" in
  let selected = field_dot field record in
  let body = CallE (id "consume", [ ExpA selected $ region ]) $$ region % nat_typ in
  let parameter = ExpP (id "record", owner_typ) $ region in
  let argument = ExpA record $ region in
  let clause = DefD ([], [ argument ], body, []) $ region in
  DecD (id "escape", [ parameter ], nat_typ, [ clause ]) $ region

let membership_definition owner field =
  let owner_typ = owner_typ owner in
  let record = variable owner_typ "record" in
  let selected = field_dot field record in
  let body = MemE (nat 0, selected) $$ region % bool_typ in
  let parameter = ExpP (id "record", owner_typ) $ region in
  let argument = ExpA record $ region in
  let clause = DefD ([], [ argument ], body, []) $ region in
  DecD (id "contains", [ parameter ], bool_typ, [ clause ]) $ region

let representation owner field defs =
  let index = Analysis.Source_index.of_script defs in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  Analysis.Sequence_carrier.field_representation
    (Context.sequence_carriers ctx) ~owner_id:owner field

let expect expected message actual =
  if actual <> expected then failwith message

let test_closed_consumers () =
  let owner = "renamed_buffer" in
  let field = atom "PAYLOAD" in
  representation owner field
    [ record_declaration owner field
    ; update_definition owner field
    ; observe_definition owner field
    ]
  |> expect Sequence_representation.Canonical_runs
       "closed sequence consumers did not receive the compact representation"

let test_call_escape_falls_back () =
  let owner = "renamed_buffer" in
  let field = atom "PAYLOAD" in
  representation owner field
    [ record_declaration owner field
    ; update_definition owner field
    ; escape_definition owner field
    ]
  |> expect Sequence_representation.Ordinary
       "a sequence escaping through CallE retained the compact representation"

let test_membership_falls_back () =
  let owner = "renamed_buffer" in
  let field = atom "PAYLOAD" in
  representation owner field
    [ record_declaration owner field
    ; update_definition owner field
    ; membership_definition owner field
    ]
  |> expect Sequence_representation.Ordinary
       "a sequence observed by MemE retained the compact representation"

let test_whole_field_binding_is_closed () =
  let owner = "renamed_buffer" in
  let field = atom "PAYLOAD" in
  representation owner field
    [ record_declaration owner field
    ; update_definition owner field
    ; captured_length_definition owner field sequence_typ
    ]
  |> expect Sequence_representation.Canonical_runs
       "a whole-field binding was not recognized as representation preserving"

let test_reused_binding_falls_back () =
  let owner = "renamed_buffer" in
  let field = atom "PAYLOAD" in
  representation owner field
    [ record_declaration owner field
    ; update_definition owner field
    ; reused_payload_definition owner field
    ]
  |> expect Sequence_representation.Ordinary
       "an existing ordinary sequence was promoted to a compact carrier"

let test_outward_iteration_falls_back () =
  let owner = "renamed_buffer" in
  let field = atom "PAYLOAD" in
  representation owner field
    [ record_declaration owner field
    ; update_definition owner field
    ; outward_iteration_definition owner field
    ]
  |> expect Sequence_representation.Ordinary
       "an outward IterPr binding retained the compact representation"

let test_structured_field_pattern_falls_back () =
  let owner = "renamed_buffer" in
  let field = atom "PAYLOAD" in
  representation owner field
    [ record_declaration owner field
    ; update_definition owner field
    ; structured_pattern_definition owner field
    ]
  |> expect Sequence_representation.Ordinary
       "an element-structured record pattern retained the compact representation"

let test_iteration_shapes () =
  let owner = "renamed_buffer" in
  let field = atom "PAYLOAD" in
  representation owner field
    [ record_declaration owner field
    ; update_definition owner field
    ; producer_definition owner field (ListN (nat 4, None))
    ]
  |> expect Sequence_representation.Canonical_runs
       "the supported fixed-count producer lost the compact representation";
  representation owner field
    [ record_declaration owner field
    ; update_definition owner field
    ; producer_definition owner field List1
    ]
  |> expect Sequence_representation.Ordinary
       "an unsupported canonical iteration retained the compact representation"

let test_aliases_are_reduced () =
  let owner = "aliased_buffer" in
  let sequence = "payload_sequence" in
  let field = atom "PAYLOAD" in
  let alias_typ = VarT (id sequence, []) $ region in
  representation owner field
    [ alias_declaration sequence sequence_typ
    ; record_declaration_with owner field alias_typ
    ; update_definition owner field
    ; captured_length_definition owner field alias_typ
    ]
  |> expect Sequence_representation.Canonical_runs
       "a flat-list alias disabled the compact representation"

let test_dependent_type_escape_falls_back () =
  let owner = "renamed_buffer" in
  let field = atom "PAYLOAD" in
  representation owner field
    [ record_declaration owner field
    ; update_definition owner field
    ; dependent_escape_definition owner field
    ]
  |> expect Sequence_representation.Ordinary
       "a dependent type premise let a captured carrier escape"

let () =
  test_closed_consumers ();
  test_call_escape_falls_back ();
  test_membership_falls_back ();
  test_whole_field_binding_is_closed ();
  test_reused_binding_falls_back ();
  test_outward_iteration_falls_back ();
  test_structured_field_pattern_falls_back ();
  test_iteration_shapes ();
  test_aliases_are_reduced ();
  test_dependent_type_escape_falls_back ()
