open Il.Ast
open Translator
open Maude_ir
open Util.Source

let region = no_region
let id text = text $ region
let atom text = Xl.Atom.Atom text $$ region % Xl.Atom.info "optional-iter-binding"
let nat_typ = NumT `NatT $ region
let bool_typ = BoolT $ region
let opt_typ = IterT (nat_typ, Opt) $ region
let record_id = id "optional_source_record"
let record_typ = VarT (record_id, []) $ region
let variable typ name = VarE (id name) $$ region % typ
let origin = Origin.synthetic ~ast_constructor:"OptionalIterBinding" "regression"

let record_def =
  let field = atom "BOUND", (opt_typ, [], []), [] in
  TypD
    ( record_id
    , []
    , [ InstD ([], [], StructT [ field ] $ region) $ region ] )
  $ region

let binding term sort typ =
  { Expr_env.term = Var term; sort; typ }

let require condition message =
  if not condition then failwith message

let () =
  let index = Analysis.Source_index.of_script [ record_def ] in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let translated =
    Type_translate.translate_typd ctx origin record_id []
      [ InstD
          ([], [], StructT [ atom "BOUND", (opt_typ, [], []), [] ] $ region)
        $ region
      ]
  in
  require
    (not (List.exists Diagnostics.is_fatal translated.diagnostics))
    "focused StructT setup failed before optional IterPr lowering";
  let env =
    Expr_env.empty
    |> fun env ->
       Expr_env.add env "record_input"
         (binding "RECORD_INPUT" (sort "SpectecTerminal") record_typ)
    |> fun env ->
       Expr_env.add env "limit" (binding "LIMIT" (sort "Nat") nat_typ)
  in
  let optional_source = variable opt_typ "optional_source" in
  let record_pattern =
    StrE [ atom "BOUND", optional_source ] $$ region % record_typ
  in
  let bind_optional =
    IfPr
      (CmpE
         (`EqOp, `NatT, variable record_typ "record_input", record_pattern)
       $$ region % bool_typ)
    $ region
  in
  let generator = variable nat_typ "element" in
  let body =
    IfPr
      (CmpE (`LeOp, `NatT, variable nat_typ "limit", generator)
       $$ region % bool_typ)
    $ region
  in
  let optional_iter =
    IterPr (body, (Opt, [ id "element", optional_source ])) $ region
  in
  match
    Premise_translate.translate_premises
      ctx env
      ~bound_terms:[ Var "RECORD_INPUT"; Var "LIMIT" ]
      origin [ bind_optional; optional_iter ]
  with
  | Premise_result.Complete result ->
    let certificate =
      Premise_result.condition_pattern_certificate ctx result
    in
    let bound =
      Condition_closure.conditions_bound_vars
        ~constructor_op:certificate
        [ "RECORD_INPUT"; "LIMIT" ]
        (Premise_result.eq_conditions result)
    in
    let source_binding =
      Expr_env.find (Premise_result.env_after result) "optional_source"
    in
    require
      (match source_binding with
      | Some binding ->
        Condition_closure.vars_subset
          (Condition_closure.term_vars binding.Expr_env.term) bound
      | None -> false)
      "record pattern did not bind the optional IterPr source before its helper call"
  | Premise_result.Blocked diagnostics
  | Premise_result.Deferred (_, diagnostics) ->
    diagnostics
    |> List.map (fun diagnostic ->
         diagnostic.Diagnostics.constructor ^ ": " ^ diagnostic.reason)
    |> String.concat "\n"
    |> failwith
