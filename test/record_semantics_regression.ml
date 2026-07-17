open Il.Ast
open Translator
open Maude_ir
open Util.Source

let region = no_region
let id text = text $ region
let atom text = Xl.Atom.Atom text $$ region % Xl.Atom.info "record-semantics"
let nat_typ = NumT `NatT $ region
let list_typ = IterT (nat_typ, List) $ region
let opt_typ = IterT (nat_typ, Opt) $ region
let byte_typ = VarT (id "byte", []) $ region
let byte_list_typ = IterT (byte_typ, List) $ region
let record_typ name = VarT (id name, []) $ region
let num n = NumE (`Nat (Z.of_int n)) $$ region % nat_typ
let list typ values = ListE values $$ region % typ
let variable typ name = VarE (id name) $$ region % typ

let field name typ = atom name, (typ, [], []), []

let record_type name fields =
  let deftyp = StructT fields $ region in
  TypD (id name, [], [ InstD ([], [], deftyp) $ region ]) $ region

let record typ fields = StrE fields $$ region % typ
let origin name = Origin.synthetic ~ast_constructor:"RecordSemantics" name

let context script =
  let index = Analysis.Source_index.of_script script in
  Context.create index (Builtin_registry.of_source_index index)

let translated_context script =
  let ctx = context script in
  ignore (Def_translate.translate_script ctx script);
  ctx

let root = function
  | Some (App (name, _)) -> Some name
  | Some (Const name) -> Some name
  | Some (Var _ | Qid _) | None -> None

let arguments = function
  | Some (App (_, args)) -> Some args
  | Some (Var _ | Const _ | Qid _) | None -> None

let rec contains_op expected = function
  | Var _ | Const _ | Qid _ -> false
  | App (name, args) ->
    name = expected || List.exists (contains_op expected) args

let require condition message =
  if not condition then failwith message

let option_exists predicate = function
  | Some value -> predicate value
  | None -> false

let contains text fragment =
  let text_length = String.length text in
  let fragment_length = String.length fragment in
  let rec search index =
    index + fragment_length <= text_length
    &&
    (String.sub text index fragment_length = fragment
     || search (index + 1))
  in
  fragment_length = 0 || search 0

let count_occurrences text fragment =
  let text_length = String.length text in
  let fragment_length = String.length fragment in
  let rec count offset total =
    if offset + fragment_length > text_length then total
    else if String.sub text offset fragment_length = fragment then
      count (offset + fragment_length) (total + 1)
    else
      count (offset + 1) total
  in
  if fragment_length = 0 then 0 else count 0 0

let test_literal_pattern_and_composition () =
  let inner_typ = record_typ "nested_probe" in
  let outer_typ = record_typ "record_probe" in
  let script =
    [ record_type "nested_probe" [ field "ITEMS" list_typ ]
    ; record_type "record_probe"
        [ field "MAYBE" opt_typ
        ; field "VALUES" list_typ
        ; field "NESTED" inner_typ
        ]
    ]
  in
  let ctx = translated_context script in
  let inner values = record inner_typ [ atom "ITEMS", list list_typ values ] in
  let literal maybe values nested =
    record outer_typ
      [ atom "MAYBE", maybe
      ; atom "VALUES", list list_typ values
      ; atom "NESTED", nested
      ]
  in
  let left = literal (OptE None $$ region % opt_typ) [ num 4 ] (inner [ num 1 ]) in
  let right =
    literal (OptE (Some (num 2)) $$ region % opt_typ) [ num 5 ] (inner [ num 3 ])
  in
  let literal_result =
    Expr_translate.lower_value ctx Expr_env.empty (origin "literal") left
  in
  let right_result =
    Expr_translate.lower_value ctx Expr_env.empty (origin "literal-right") right
  in
  require
    (root literal_result.term = Some "rec.record-probe")
    "StrE expression did not use the canonical nominal record constructor";
  let composition = CompE (left, right) $$ region % outer_typ in
  let composition_result =
    Expr_translate.lower_value ctx Expr_env.empty (origin "composition") composition
  in
  require
    (root composition_result.term = Some "compose.rec.record-probe")
    "record CompE did not use its compact nominal composition helper";
  require
    (arguments composition_result.term
     = Option.bind literal_result.term (fun left_term ->
         Option.map (fun right_term -> [ left_term; right_term ]) right_result.term))
    "record CompE expanded fields instead of retaining its two operands";
  require
    (not (option_exists (contains_op "merge") composition_result.term))
    "CompE retained the uninterpreted merge fallback";
  let pattern =
    record outer_typ
      [ atom "MAYBE", variable opt_typ "maybe"
      ; atom "VALUES", variable list_typ "values"
      ; atom "NESTED",
          record inner_typ [ atom "ITEMS", variable list_typ "items" ]
      ]
  in
  let pattern_result, _ =
    Expr_translate.lower_pattern_with_bindings_named
      Local_name.empty ctx Expr_env.empty (origin "pattern") pattern
  in
  require
    (root pattern_result.pattern_term = root literal_result.term)
    "StrE expression and pattern lowering disagree on the record constructor";
  require
    (List.length pattern_result.introduced_bindings = 3)
    "canonical record pattern lost source bindings";
  let rendered =
    Driver.translate script |> fun result -> Emit.render_module result.module_
  in
  require
    (contains rendered
       "op compose.rec.record-probe : SpectecTerminal SpectecTerminal ~> SpectecTerminal")
    "StructT ownership did not emit the nominal composition declaration";
  require
    (contains rendered "composeOpt(LEFT_MAYBE" && contains rendered "LEFT_VALUES:SpectecTerminals RIGHT_VALUES")
    "StructT composition equation lost optional or list field semantics";
  require
    (contains rendered "compose.rec.nested-probe(LEFT_NESTED" && contains rendered "RIGHT_NESTED")
    "StructT composition equation lost its nested nominal dependency"

let test_field_identity_rejection () =
  let typ = record_typ "identity_probe" in
  let ctx =
    context
      [ record_type "identity_probe"
          [ field "LEFT" list_typ; field "RIGHT" opt_typ ]
      ]
  in
  let mismatched =
    record typ
      [ atom "RIGHT", OptE None $$ region % opt_typ
      ; atom "LEFT", list list_typ [ num 1 ]
      ]
  in
  let result =
    Expr_translate.lower_value ctx Expr_env.empty (origin "identity") mismatched
  in
  require (result.term = None) "StrE silently accepted mismatched field identity";
  require
    (List.exists
       (fun diagnostic -> diagnostic.Diagnostics.constructor = "Expr/StrE/fields")
       result.diagnostics)
    "StrE field mismatch did not produce a structured Unsupported diagnostic"

let test_sequence_composition () =
  let ctx = context [] in
  let left = list list_typ [ num 1 ] in
  let right = list list_typ [ num 2 ] in
  let exp = CompE (left, right) $$ region % list_typ in
  let result = Expr_translate.lower_value ctx Expr_env.empty (origin "sequence") exp in
  require
    (root result.term = Some "_ _")
    "list CompE did not lower to sequence concatenation"

let test_optional_composition () =
  let ctx = context [] in
  let left = OptE None $$ region % opt_typ in
  let right = OptE (Some (num 1)) $$ region % opt_typ in
  let exp = CompE (left, right) $$ region % opt_typ in
  let result = Expr_translate.lower_value ctx Expr_env.empty (origin "optional") exp in
  require
    (root result.term = Some "composeOpt")
    "optional CompE did not lower to partial optional composition"

let test_non_concatenable_record () =
  let typ = record_typ "scalar_probe" in
  let script = [ record_type "scalar_probe" [ field "COUNT" nat_typ ] ] in
  let ctx = translated_context script in
  let left = record typ [ atom "COUNT", num 1 ] in
  let right = record typ [ atom "COUNT", num 2 ] in
  let exp = CompE (left, right) $$ region % typ in
  let result = Expr_translate.lower_value ctx Expr_env.empty (origin "scalar") exp in
  require (result.term = None)
    "record CompE silently composed a non-concatenable scalar field";
  require
    (List.exists
       (fun diagnostic -> diagnostic.Diagnostics.constructor = "Expr/CompE/field")
       result.diagnostics)
    "non-concatenable record CompE did not produce structured Unsupported";
  let rendered =
    Driver.translate script |> fun result -> Emit.render_module result.module_
  in
  require
    (not (contains rendered "compose.rec.scalar-probe"))
    "StructT ownership emitted a composition helper for a scalar record"

let test_typd_record_certificate_rollback () =
  let typ = record_typ "rollback_probe" in
  let tuple_typ =
    TupT [ id "left", nat_typ; id "right", nat_typ ] $ region
  in
  let valid = InstD ([], [], StructT [ field "ITEMS" list_typ ] $ region) $ region in
  let blocked =
    InstD ([], [], StructT [ field "BROKEN" tuple_typ ] $ region) $ region
  in
  let typd = TypD (id "rollback_probe", [], [ valid; blocked ]) $ region in
  let script = [ RecD [ typd ] $ region ] in
  let ctx = context script in
  let translated = Def_translate.translate_script ctx script in
  require
    (List.exists Diagnostics.is_fatal translated.diagnostics)
    "rollback fixture did not block its enclosing TypD";
  require
    (translated.statements = [])
    "blocked TypD retained statements from a successful sibling instance";
  require
    (not
       (Condition_pattern_certificate.admits
          (Condition_pattern_certificate.source ctx)
          "rec.rollback-probe" 1))
    "blocked TypD leaked its record constructor certificate";
  let value = record typ [ atom "ITEMS", list list_typ [ num 1 ] ] in
  let composition = CompE (value, value) $$ region % typ in
  let result =
    Expr_translate.lower_value ctx Expr_env.empty (origin "rollback") composition
  in
  require (result.term = None)
    "CompE called a helper rolled back with its enclosing TypD"

let test_duplicate_record_composition_plan () =
  let instance =
    InstD ([], [], StructT [ field "ITEMS" list_typ ] $ region) $ region
  in
  let script =
    [ TypD (id "duplicate_probe", [], [ instance; instance ]) $ region ]
  in
  let result = Driver.translate script in
  require
    (not (List.exists Diagnostics.is_fatal result.diagnostics))
    "identical StructT specializations were rejected";
  let rendered = Emit.render_module result.module_ in
  require
    (count_occurrences rendered "op rec.duplicate-probe :" = 1)
    "identical StructT specializations emitted duplicate constructors";
  require
    (count_occurrences rendered "cmb rec.duplicate-probe(" = 1)
    "identical StructT specializations emitted duplicate memberships";
  require
    (count_occurrences rendered "ceq typecheck(rec.duplicate-probe(" = 1)
    "identical StructT specializations emitted duplicate typecheck equations";
  require
    (count_occurrences rendered "eq value('ITEMS, rec.duplicate-probe(" = 1)
    "identical StructT specializations emitted duplicate accessors";
  require
    (count_occurrences rendered "eq rec.duplicate-probe(" = 1)
    "identical StructT specializations emitted duplicate updates";
  require
    (count_occurrences rendered "op compose.rec.duplicate-probe :" = 1)
    "identical StructT plans emitted duplicate composition declarations";
  require
    (count_occurrences rendered "ceq compose.rec.duplicate-probe(" = 1)
    "identical StructT plans emitted duplicate composition equations"

let test_incompatible_record_composition_plan () =
  let list_instance =
    InstD ([], [], StructT [ field "VALUE" list_typ ] $ region) $ region
  in
  let byte_instance =
    InstD ([], [], StructT [ field "VALUE" byte_list_typ ] $ region) $ region
  in
  let script =
    [ TypD
        (id "conflicting_probe", [], [ list_instance; byte_instance ])
        $ region
    ]
  in
  let ctx = context script in
  let translated = Def_translate.translate_script ctx script in
  require
    (List.exists
       (fun diagnostic ->
         diagnostic.Diagnostics.constructor = "TypD/StructT/record-surface")
       translated.diagnostics)
    "incompatible StructT specializations lacked a structured diagnostic";
  require (translated.statements = [])
    "incompatible StructT specializations committed partial statements";
  require
    (Record_certificate.constructors (Context.record_certificates ctx) = [])
    "incompatible StructT specializations committed a record certificate"

let test_missing_nested_composition_helper () =
  let nested_typ = record_typ "late_nested_probe" in
  let outer_typ = record_typ "early_outer_probe" in
  let script =
    [ record_type "early_outer_probe" [ field "NESTED" nested_typ ]
    ; record_type "late_nested_probe" [ field "ITEMS" list_typ ]
    ]
  in
  let ctx = translated_context script in
  let nested =
    record nested_typ [ atom "ITEMS", list list_typ [ num 1 ] ]
  in
  let outer = record outer_typ [ atom "NESTED", nested ] in
  let composition = CompE (outer, outer) $$ region % outer_typ in
  let result =
    Expr_translate.lower_value
      ctx Expr_env.empty (origin "missing-nested") composition
  in
  require (result.term = None)
    "CompE called a record composition helper that was never emitted";
  require
    (List.exists
       (fun diagnostic ->
         diagnostic.Diagnostics.constructor
         = "Expr/CompE/composition-helper")
       result.diagnostics)
    "missing nested composition helper lacked structured Unsupported";
  require
    (List.exists
       (fun diagnostic -> contains diagnostic.Diagnostics.reason "late-nested-probe")
       result.diagnostics)
    "missing nested composition diagnostic lost its child helper identity";
  let rendered =
    Driver.translate script |> fun translated -> Emit.render_module translated.module_
  in
  require
    (not (contains rendered "op compose.rec.early-outer-probe :"))
    "outer StructT emitted a helper before its nested dependency"

let () =
  test_literal_pattern_and_composition ();
  test_field_identity_rejection ();
  test_sequence_composition ();
  test_optional_composition ();
  test_non_concatenable_record ();
  test_typd_record_certificate_rollback ();
  test_duplicate_record_composition_plan ();
  test_incompatible_record_composition_plan ();
  test_missing_nested_composition_helper ()
