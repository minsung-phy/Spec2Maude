let render ~semantics ~steps ~commands ~host_store ~host_instances
    ~host_functions =
    let buffer = Buffer.create 4096 in
    List.iter
      (fun (name, body) ->
        Printf.bprintf buffer "  op %s : -> Commands .\n  eq %s = %s .\n"
          name name (Maude_term.to_string body))
      commands;
    let commands = Buffer.contents buffer in
    Printf.sprintf
      ({|load %s

mod WASM2MAUDE-WAST is
  including WASM-BUILTINS .

  sorts ScriptAction ImportRequirement ImportRef ImportRefs LinkResult
    Command Commands
    InstanceEnv ScriptState ResultPattern ResultPatterns
    ResultAlternatives LanePattern LanePatterns MatchVerdict .
  subsort Command < Commands .
  op action.invoke : Nat SpectecTerminals ValList
    -> ScriptAction [ctor] .
  op action.get : Nat SpectecTerminals -> ScriptAction [ctor] .
  op commands.nil : -> Commands [ctor] .
  op commands.cons : Command Commands -> Commands [ctor] .
  op import.ready : -> ImportRequirement [ctor] .
  op import.current-memory-min : Nat -> ImportRequirement [ctor] .
  op import.current-table-min : Nat -> ImportRequirement [ctor] .
  op import.ref : Nat SpectecTerminals ImportRequirement
    -> ImportRef [ctor] .
  op imports.nil : -> ImportRefs [ctor] .
  op imports.cons : ImportRef ImportRefs -> ImportRefs [ctor] .
  op link.ok : SpectecTerminals -> LinkResult [ctor] .
  op link.error : -> LinkResult [ctor] .
  op link.append : LinkResult LinkResult -> LinkResult .
  op command.module : Nat SpectecTerminal ImportRefs
    -> Command [ctor] .
  op command.unlinkable : Nat ImportRefs -> Command [ctor] .
  op command.uninstantiable-static : Nat -> Command [ctor] .
  op command.uninstantiable : Nat SpectecTerminal ImportRefs
    -> Command [ctor] .
  op patterns.nil : -> ResultPatterns [ctor] .
  op patterns.cons : ResultPattern ResultPatterns
    -> ResultPatterns [ctor] .
  op alternatives.nil : -> ResultAlternatives [ctor] .
  subsort ResultPattern < ResultAlternatives .
  op alternatives.cons : ResultAlternatives ResultAlternatives
    -> ResultAlternatives [ctor assoc id: alternatives.nil] .
  op result.exact-num : SpectecTerminal -> ResultPattern [ctor] .
  op result.exact-vec : SpectecTerminal -> ResultPattern [ctor] .
  op result.vec-lanes : SpectecTerminal LanePatterns
    -> ResultPattern [ctor] .
  op result.exact-ref : SpectecTerminal -> ResultPattern [ctor] .
  op result.ref-type : SpectecTerminal -> ResultPattern [ctor] .
  op result.null-ref : SpectecTerminal -> ResultPattern [ctor] .
  op result.either : ResultAlternatives -> ResultPattern [ctor] .
  op result.nan-canonical : SpectecTerminal
    -> ResultPattern [ctor] .
  op result.nan-arithmetic : SpectecTerminal
    -> ResultPattern [ctor] .
  op lane.exact : SpectecTerminal -> LanePattern [ctor] .
  op lane.nan-canonical : -> LanePattern [ctor] .
  op lane.nan-arithmetic : -> LanePattern [ctor] .
  op lanes.nil : -> LanePatterns [ctor] .
  op lanes.cons : LanePattern LanePatterns -> LanePatterns [ctor] .
  op match.yes : -> MatchVerdict [ctor] .
  op match.no : -> MatchVerdict [ctor] .
  op match.and : MatchVerdict MatchVerdict -> MatchVerdict .
  op match.value : SpectecTerminal ResultPattern
    -> MatchVerdict .
  op match.values : ValList ResultPatterns
    -> MatchVerdict .
  op match.any : SpectecTerminal ResultAlternatives
    -> MatchVerdict .

  op match.lane : SpectecTerminal SpectecTerminal LanePattern
    -> MatchVerdict .
  op match.vec-lanes : SpectecTerminal SpectecTerminals LanePatterns
    -> MatchVerdict .

  op command.return : Nat ScriptAction ResultPatterns
    -> Command [ctor] .
  op command.trap : Nat ScriptAction -> Command [ctor] .
  op command.exception : Nat ScriptAction -> Command [ctor] .
  op command.exhaustion : Nat Nat ScriptAction -> Command [ctor] .
  op command.do : Nat ScriptAction -> Command [ctor] .

  op instances.nil : -> InstanceEnv [ctor] .
  op instances.entry : Nat SpectecTerminal -> InstanceEnv [ctor] .
  op instances.concat : InstanceEnv InstanceEnv -> InstanceEnv
    [ctor assoc id: instances.nil] .
  op hasInstance : InstanceEnv Nat -> Bool .
  op findInstance : InstanceEnv Nat ~> SpectecTerminal .

  op hasExport : SpectecTerminals SpectecTerminals -> Bool .
  op findExport : SpectecTerminals SpectecTerminals
    ~> SpectecTerminal .
  op checkImport : SpectecTerminal SpectecTerminal ImportRequirement
    -> LinkResult .
  op linkImports : SpectecTerminal InstanceEnv ImportRefs
    -> LinkResult .

  op script.start : -> ScriptState [ctor] .
  op script.ready : SpectecTerminal InstanceEnv Commands
    -> ScriptState [ctor] .
  op script.module : Nat InstanceEnv Commands SpectecTerminal
    -> ScriptState [ctor frozen (4)] .
  op script.return : Nat InstanceEnv ResultPatterns Commands
    SpectecTerminal -> ScriptState [ctor frozen (5)] .
  op script.trap : Nat InstanceEnv Commands SpectecTerminal
    -> ScriptState [ctor frozen (4)] .
  op script.exception : Nat InstanceEnv Commands SpectecTerminal
    -> ScriptState [ctor frozen (4)] .
  op script.exhaustion : Nat Nat InstanceEnv Commands SpectecTerminal
    -> ScriptState [ctor frozen (5)] .
  op script.exhaustion-check : Nat Nat InstanceEnv Commands
    SpectecTerminal SpectecTerminal
    -> ScriptState [ctor frozen (5 6)] .
  op script.action : Nat InstanceEnv Commands SpectecTerminal
    -> ScriptState [ctor frozen (4)] .
  op script.uninstantiable : Nat InstanceEnv Commands SpectecTerminal
    -> ScriptState [ctor frozen (4)] .
  op script.wrong-result : Nat ValList ResultPatterns
    -> ScriptState [ctor] .
  op script.wrong-assertion : Nat -> ScriptState [ctor] .
  op script.link-error : Nat -> ScriptState [ctor] .
  op script.done : -> ScriptState [ctor] .

  op emptyStore : -> SpectecTerminal .
  op hostFunctionAddresses : -> SpectecTerminals .
  op hostArguments : ValList SpectecTerminals -> Bool .
  op hostCallable : SpectecTerminal Nat ValList -> Bool .
  op findFunc : SpectecTerminals SpectecTerminals ~> Nat .

  op findGlobal : SpectecTerminals SpectecTerminals ~> Nat .

  op runtimeResults : ValList -> Bool .

  op activeFrameDepth : InstrList -> Nat .

  vars WSHC WSHC2 WSHM WSHS WSHS2 WSHF2 WSHMI WSHCURRENT WSHXA WSHHEAD : SpectecTerminal .
  vars WSHNT WSHVALUE WSHLT WSHAT WSHRT : SpectecTerminal .
  vars WSHNAME WSHEXPORTPREFIX WSHLOCALS WSHEXPORTS : SpectecTerminals .
  vars WSHLANES WSHTYPES WSHMAX WSHCATCHES : SpectecTerminals .
  vars WSHARGS WSHACTUAL WSHVALUES WSHPREFIX : ValList .
  vars WSHBODY WSHINSTRS WSHREST : InstrList .
  var WSHCMDS : Commands .
  vars WSHIMPORTS WSHIMPORTS2 : ImportRefs .
  var WSHREQUIREMENT : ImportRequirement .
  var WSHLINK : LinkResult .
  vars WSHENV WSHENVPREFIX WSHENVSUFFIX : InstanceEnv .
  var WSHPATTERN : ResultPattern .
  vars WSHEXPECTED WSHPATTERNS : ResultPatterns .
  vars WSHALTERNATIVES WSHALTPREFIX WSHALTSUFFIX : ResultAlternatives .
  var WSHLPAT : LanePattern .
  var WSHLPATS : LanePatterns .
  vars WSHID WSHTARGET WSHA WSHADDR WSHN WSHMIN WSHREQUIRED WSHDIM : Nat .

%s  eq emptyStore = %s .
  eq hostFunctionAddresses = %s .

  eq hostArguments(eps, eps) = true .
  eq hostArguments(CONST(WSHNT, WSHVALUE) WSHVALUES,
    WSHNT WSHTYPES) = hostArguments(WSHVALUES, WSHTYPES) .
  eq hostArguments(WSHVALUES, WSHTYPES) = false [owise] .

  eq hasInstance(instances.concat(WSHENVPREFIX,
    instances.concat(instances.entry(WSHID, WSHMI), WSHENVSUFFIX)), WSHID) = true .
  eq hasInstance(WSHENV, WSHID) = false [owise] .
  ceq findInstance(instances.concat(WSHENVPREFIX,
    instances.concat(instances.entry(WSHID, WSHMI), WSHENVSUFFIX)), WSHID) = WSHMI
    if not hasInstance(WSHENVPREFIX, WSHID) .
|} ^^ "  \n" ^^ {|  ceq hasExport(WSHEXPORTPREFIX WSHHEAD WSHEXPORTS, WSHNAME) = true
    if WSHNAME = value('NAME, WSHHEAD) .
  eq hasExport(WSHEXPORTS, WSHNAME) = false [owise] .
  ceq findExport(WSHEXPORTPREFIX WSHHEAD WSHEXPORTS, WSHNAME) = WSHXA
    if WSHNAME = value('NAME, WSHHEAD)
       /\ not hasExport(WSHEXPORTPREFIX, WSHNAME)
       /\ WSHXA := value('ADDR, WSHHEAD) .
  eq link.append(link.error, WSHLINK) = link.error .
  eq link.append(link.ok(WSHXA), link.error) = link.error .
  eq link.append(link.ok(WSHXA), link.ok(WSHEXPORTS)) =
    link.ok(WSHXA WSHEXPORTS) .

  eq checkImport(WSHS, WSHXA, import.ready) = link.ok(WSHXA) .
  ceq checkImport(WSHS, MEM(WSHA),
    import.current-memory-min(WSHREQUIRED)) = link.ok(MEM(WSHA))
    if __PAGE(WSHAT, [WSHMIN .. WSHMAX]) :=
         value('TYPE, index(value('MEMS, WSHS), WSHA))
       /\ WSHMIN >= WSHREQUIRED = true .
  ceq checkImport(WSHS, MEM(WSHA),
    import.current-memory-min(WSHREQUIRED)) = link.error
    if __PAGE(WSHAT, [WSHMIN .. WSHMAX]) :=
         value('TYPE, index(value('MEMS, WSHS), WSHA))
       /\ WSHMIN < WSHREQUIRED = true .
  eq checkImport(WSHS, TAG(WSHA),
    import.current-memory-min(WSHREQUIRED)) = link.error .
  eq checkImport(WSHS, GLOBAL(WSHA),
    import.current-memory-min(WSHREQUIRED)) = link.error .
  eq checkImport(WSHS, TABLE(WSHA),
    import.current-memory-min(WSHREQUIRED)) = link.error .
  eq checkImport(WSHS, FUNC(WSHA),
    import.current-memory-min(WSHREQUIRED)) = link.error .

  ceq checkImport(WSHS, TABLE(WSHA),
    import.current-table-min(WSHREQUIRED)) = link.ok(TABLE(WSHA))
    if tuple(WSHAT [WSHMIN .. WSHMAX] WSHRT) :=
         value('TYPE, index(value('TABLES, WSHS), WSHA))
       /\ WSHMIN >= WSHREQUIRED = true .
  ceq checkImport(WSHS, TABLE(WSHA),
    import.current-table-min(WSHREQUIRED)) = link.error
    if tuple(WSHAT [WSHMIN .. WSHMAX] WSHRT) :=
         value('TYPE, index(value('TABLES, WSHS), WSHA))
       /\ WSHMIN < WSHREQUIRED = true .
  eq checkImport(WSHS, TAG(WSHA),
    import.current-table-min(WSHREQUIRED)) = link.error .
  eq checkImport(WSHS, GLOBAL(WSHA),
    import.current-table-min(WSHREQUIRED)) = link.error .
  eq checkImport(WSHS, MEM(WSHA),
    import.current-table-min(WSHREQUIRED)) = link.error .
  eq checkImport(WSHS, FUNC(WSHA),
    import.current-table-min(WSHREQUIRED)) = link.error .

  eq linkImports(WSHS, WSHENV, imports.nil) = link.ok(eps) .
  eq linkImports(WSHS, WSHENV, imports.cons(
    import.ref(WSHTARGET, WSHNAME, WSHREQUIREMENT), WSHIMPORTS2)) =
      link.append(
        checkImport(WSHS, findExport(value('EXPORTS,
          findInstance(WSHENV, WSHTARGET)), WSHNAME), WSHREQUIREMENT),
        linkImports(WSHS, WSHENV, WSHIMPORTS2)) .

  ceq findFunc(WSHEXPORTS, WSHNAME) = WSHADDR
    if FUNC(WSHADDR) := findExport(WSHEXPORTS, WSHNAME) .
  ceq findGlobal(WSHEXPORTS, WSHNAME) = WSHA
    if GLOBAL(WSHA) := findExport(WSHEXPORTS, WSHNAME) .

  eq runtimeResults(eps) = true .
  ceq runtimeResults(CONST(WSHNT, WSHVALUE) WSHACTUAL) =
      runtimeResults(WSHACTUAL)
    if typecheck(WSHNT, numtype)
       /\ typecheck(WSHVALUE, num-(WSHNT)) .

  eq runtimeResults(VCONST(V128, WSHC) WSHACTUAL) =
    runtimeResults(WSHACTUAL) .

  ceq runtimeResults(WSHC WSHACTUAL) = runtimeResults(WSHACTUAL)
    if typecheck(WSHC, ref) .

  ceq activeFrameDepth(WSHPREFIX ((FRAME- WSHN { WSHC } WSHBODY) WSHREST)) =
    1 + activeFrameDepth(WSHBODY)
    if runtimeResults(WSHPREFIX) .
  ceq activeFrameDepth(WSHPREFIX ((LABEL- WSHN { WSHINSTRS } WSHBODY) WSHREST)) =
    activeFrameDepth(WSHBODY)
    if runtimeResults(WSHPREFIX) .
  ceq activeFrameDepth(WSHPREFIX ((HANDLER- WSHN { WSHCATCHES } WSHBODY) WSHREST)) =
    activeFrameDepth(WSHBODY)
    if runtimeResults(WSHPREFIX) .
  eq activeFrameDepth(WSHINSTRS) = 0 [owise] .
  eq match.and(match.yes, match.yes) = match.yes .
  eq match.and(match.yes, match.no) = match.no .
  eq match.and(match.no, match.yes) = match.no .
  eq match.and(match.no, match.no) = match.no .
  eq match.value(WSHVALUE, result.exact-num(WSHVALUE)) = match.yes .
  eq match.value(WSHVALUE, result.exact-vec(WSHVALUE)) = match.yes .
  eq match.value(WSHVALUE, result.exact-ref(WSHVALUE)) = match.yes .
  eq match.value(REF.NULL-ADDR, result.null-ref(WSHNT)) =
    match.yes .
  eq match.value(WSHVALUE, result.either(WSHALTERNATIVES)) =
    match.any(WSHVALUE, WSHALTERNATIVES) .

  ceq match.value(
    VCONST(V128, WSHVALUE),
    result.vec-lanes(WSHLT X WSHDIM, WSHLPATS)) =
      match.vec-lanes(WSHLT, WSHLANES, WSHLPATS)
    if WSHLANES := lanes-(WSHLT X WSHDIM, WSHVALUE) .

  eq match.lane(WSHNT, WSHVALUE, lane.exact(WSHVALUE)) = match.yes .
  eq match.lane(F32,
    POS(NAN(4194304)), lane.nan-canonical) = match.yes .
  eq match.lane(F32,
    NEG(NAN(4194304)), lane.nan-canonical) = match.yes .
  eq match.lane(F64,
    POS(NAN(2251799813685248)), lane.nan-canonical) =
      match.yes .
  eq match.lane(F64,
    NEG(NAN(2251799813685248)), lane.nan-canonical) =
      match.yes .
  ceq match.lane(F32,
    POS(NAN(WSHADDR)), lane.nan-arithmetic) = match.yes
    if _>=_(WSHADDR, 4194304) = true .
  ceq match.lane(F32,
    NEG(NAN(WSHADDR)), lane.nan-arithmetic) = match.yes
    if _>=_(WSHADDR, 4194304) = true .
  ceq match.lane(F64,
    POS(NAN(WSHADDR)), lane.nan-arithmetic) = match.yes
    if _>=_(WSHADDR, 2251799813685248) = true .
  ceq match.lane(F64,
    NEG(NAN(WSHADDR)), lane.nan-arithmetic) = match.yes
    if _>=_(WSHADDR, 2251799813685248) = true .
  eq match.lane(WSHNT, WSHVALUE, WSHLPAT) = match.no [owise] .

  eq match.vec-lanes(WSHNT, eps, lanes.nil) = match.yes .
  eq match.vec-lanes(WSHNT, WSHVALUE WSHLANES,
    lanes.cons(WSHLPAT, WSHLPATS)) =
    match.and(match.lane(WSHNT, WSHVALUE, WSHLPAT),
      match.vec-lanes(WSHNT, WSHLANES, WSHLPATS)) .
  eq match.vec-lanes(WSHNT, WSHLANES, WSHLPATS) =
    match.no [owise] .

  eq match.value(
    CONST(F32, POS(NAN(4194304))),
    result.nan-canonical(F32)) = match.yes .
  eq match.value(
    CONST(F32, NEG(NAN(4194304))),
    result.nan-canonical(F32)) = match.yes .
  eq match.value(
    CONST(F64, POS(NAN(2251799813685248))),
    result.nan-canonical(F64)) = match.yes .
  eq match.value(
    CONST(F64, NEG(NAN(2251799813685248))),
    result.nan-canonical(F64)) = match.yes .
  ceq match.value(
    CONST(F32, POS(NAN(WSHADDR))),
    result.nan-arithmetic(F32)) = match.yes
    if _>=_(WSHADDR, 4194304) = true .
  ceq match.value(
    CONST(F32, NEG(NAN(WSHADDR))),
    result.nan-arithmetic(F32)) = match.yes
    if _>=_(WSHADDR, 4194304) = true .
  ceq match.value(
    CONST(F64, POS(NAN(WSHADDR))),
    result.nan-arithmetic(F64)) = match.yes
    if _>=_(WSHADDR, 2251799813685248) = true .
  ceq match.value(
    CONST(F64, NEG(NAN(WSHADDR))),
    result.nan-arithmetic(F64)) = match.yes
    if _>=_(WSHADDR, 2251799813685248) = true .

  eq match.value(REF.NULL-ADDR, result.ref-type(ANY)) = match.yes .
  eq match.value(REF.I31-NUM(WSHVALUE), result.ref-type(ANY)) = match.yes .
  eq match.value(REF.STRUCT-ADDR(WSHADDR), result.ref-type(ANY)) = match.yes .
  eq match.value(REF.ARRAY-ADDR(WSHADDR), result.ref-type(ANY)) = match.yes .
  eq match.value(REF.EXN-ADDR(WSHADDR), result.ref-type(ANY)) = match.yes .
  eq match.value(REF.HOST-ADDR(WSHADDR), result.ref-type(ANY)) = match.yes .
  eq match.value(REF.EXTERN(WSHVALUE), result.ref-type(ANY)) = match.yes .
  eq match.value(REF.I31-NUM(WSHVALUE), result.ref-type(EQ)) = match.yes .
  eq match.value(REF.STRUCT-ADDR(WSHADDR), result.ref-type(EQ)) = match.yes .
  eq match.value(REF.ARRAY-ADDR(WSHADDR), result.ref-type(EQ)) = match.yes .
  eq match.value(REF.I31-NUM(WSHVALUE), result.ref-type(I31)) = match.yes .
  eq match.value(REF.STRUCT-ADDR(WSHADDR), result.ref-type(STRUCT)) = match.yes .
  eq match.value(REF.ARRAY-ADDR(WSHADDR), result.ref-type(ARRAY)) = match.yes .
  eq match.value(REF.FUNC-ADDR(WSHADDR), result.ref-type(spectec-FUNC)) = match.yes .
  eq match.value(REF.EXN-ADDR(WSHADDR), result.ref-type(EXN)) = match.yes .
  eq match.value(REF.NULL-ADDR, result.ref-type(EXTERN)) = match.yes .
  eq match.value(REF.I31-NUM(WSHVALUE), result.ref-type(EXTERN)) = match.yes .
  eq match.value(REF.STRUCT-ADDR(WSHADDR), result.ref-type(EXTERN)) = match.yes .
  eq match.value(REF.ARRAY-ADDR(WSHADDR), result.ref-type(EXTERN)) = match.yes .
  eq match.value(REF.FUNC-ADDR(WSHADDR), result.ref-type(EXTERN)) = match.yes .
  eq match.value(REF.EXN-ADDR(WSHADDR), result.ref-type(EXTERN)) = match.yes .
  eq match.value(REF.HOST-ADDR(WSHADDR), result.ref-type(EXTERN)) = match.yes .
  eq match.value(REF.EXTERN(WSHVALUE), result.ref-type(EXTERN)) = match.yes .
  eq match.value(WSHVALUE, WSHPATTERN) = match.no [owise] .

  eq match.values(eps, patterns.nil) = match.yes .
  eq match.values(WSHVALUE WSHACTUAL,
    patterns.cons(WSHPATTERN, WSHPATTERNS)) =
      match.and(match.value(WSHVALUE, WSHPATTERN),
        match.values(WSHACTUAL, WSHPATTERNS)) .
  eq match.values(WSHACTUAL, WSHEXPECTED) = match.no [owise] .

  ceq match.any(WSHVALUE, alternatives.cons(WSHALTPREFIX,
    alternatives.cons(WSHPATTERN, WSHALTSUFFIX))) = match.yes
    if match.value(WSHVALUE, WSHPATTERN) = match.yes .
  eq match.any(WSHVALUE, WSHALTERNATIVES) = match.no [owise] .
  ceq hostCallable(WSHS, WSHA, WSHARGS) = true
    if WSHA <- hostFunctionAddresses = true
       /\ typecheck(WSHARGS, val) = true
       /\ typecheck(WSHARGS, instr) = true
       /\ WSHXA := index(value('FUNCS, WSHS), WSHA)
       /\ value('CODE, WSHXA) = ...
       /\ FUNC WSHTYPES -> eps := Expand(value('TYPE, WSHXA))
       /\ len(WSHARGS) = len(WSHTYPES)
       /\ hostArguments(WSHARGS, WSHTYPES) = true .
  eq hostCallable(WSHS, WSHA, WSHARGS) = false [owise] .

  crl [host-call] :
    Step-read((WSHS ; WSHCURRENT) ;
      (WSHARGS (REF.FUNC-ADDR(WSHA) CALL-REF(WSHC)))) => eps
    if hostCallable(WSHS, WSHA, WSHARGS) = true .

  crl [focus-host-call] :
    identifyFocus(WSHS ; WSHCURRENT,
      WSHPREFIX (WSHARGS REF.FUNC-ADDR(WSHA)), CALL-REF(WSHC), WSHREST)
    => { WSHPREFIX | ((WSHS ; WSHCURRENT) ;
      (WSHARGS (REF.FUNC-ADDR(WSHA) CALL-REF(WSHC)))) | WSHREST }
    if hostCallable(WSHS, WSHA, WSHARGS) = true .

  rl [start] : script.start =>
    script.ready(emptyStore, %s, inputCommands) .
  crl [module-start] :
    script.ready(WSHS, WSHENV,
      commands.cons(command.module(WSHID, WSHM, WSHIMPORTS), WSHCMDS))
    => script.module(WSHID, WSHENV, WSHCMDS, WSHC)
    if link.ok(WSHEXPORTS) := linkImports(WSHS, WSHENV, WSHIMPORTS)
       /\ instantiate(WSHS, WSHM, WSHEXPORTS) => WSHC .
  crl [module-link-error] :
    script.ready(WSHS, WSHENV,
      commands.cons(command.module(WSHID, WSHM, WSHIMPORTS), WSHCMDS))
    => script.link-error(WSHID)
    if linkImports(WSHS, WSHENV, WSHIMPORTS) = link.error .
  rl [module-done] :
    script.module(WSHID, WSHENV, WSHCMDS,
      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHMI)) }) ; eps)
    => script.ready(WSHS, instances.concat(instances.entry(WSHID, WSHMI), WSHENV), WSHCMDS) .

  crl [module-step] : script.module(WSHID, WSHENV, WSHCMDS, WSHC)
    => script.module(WSHID, WSHENV, WSHCMDS, WSHC2)
    if Step(WSHC) => WSHC2 .

  crl [assert-unlinkable] :
    script.ready(WSHS, WSHENV,
      commands.cons(command.unlinkable(WSHID, WSHIMPORTS), WSHCMDS))
    => script.ready(WSHS, WSHENV, WSHCMDS)
    if linkImports(WSHS, WSHENV, WSHIMPORTS) = link.error .
  crl [assert-unlinkable-wrong] :
    script.ready(WSHS, WSHENV,
      commands.cons(command.unlinkable(WSHID, WSHIMPORTS), WSHCMDS))
    => script.wrong-assertion(WSHID)
    if link.ok(WSHEXPORTS) := linkImports(WSHS, WSHENV, WSHIMPORTS) .

  rl [assert-uninstantiable-static-link-error] :
    script.ready(WSHS, WSHENV,
      commands.cons(command.uninstantiable-static(WSHID), WSHCMDS))
    => script.wrong-assertion(WSHID) .
  crl [assert-uninstantiable-link-error] :
    script.ready(WSHS, WSHENV,
      commands.cons(command.uninstantiable(WSHID, WSHM, WSHIMPORTS), WSHCMDS))
    => script.wrong-assertion(WSHID)
    if linkImports(WSHS, WSHENV, WSHIMPORTS) = link.error .
  crl [assert-uninstantiable-start] :
    script.ready(WSHS, WSHENV,
      commands.cons(command.uninstantiable(WSHID, WSHM, WSHIMPORTS), WSHCMDS))
    => script.uninstantiable(WSHID, WSHENV, WSHCMDS, WSHC)
    if link.ok(WSHEXPORTS) := linkImports(WSHS, WSHENV, WSHIMPORTS)
       /\ instantiate(WSHS, WSHM, WSHEXPORTS) => WSHC .
  rl [assert-uninstantiable-trap] :
    script.uninstantiable(WSHID, WSHENV, WSHCMDS,
      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; TRAP)
    => script.ready(WSHS, WSHENV, WSHCMDS) .
  rl [assert-uninstantiable-exception] :
    script.uninstantiable(WSHID, WSHENV, WSHCMDS,
      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ;
        (REF.EXN-ADDR(WSHA) THROW-REF))
    => script.ready(WSHS, WSHENV, WSHCMDS) .
  rl [assert-uninstantiable-normal] :
    script.uninstantiable(WSHID, WSHENV, WSHCMDS,
      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; eps)
    => script.wrong-assertion(WSHID) .
  crl [assert-uninstantiable-step] :
    script.uninstantiable(WSHID, WSHENV, WSHCMDS, WSHC)
    => script.uninstantiable(WSHID, WSHENV, WSHCMDS, WSHC2)
    if Step(WSHC) => WSHC2 .

  rl [call-return] :
    script.ready(WSHS, WSHENV, commands.cons(
      command.return(WSHID, action.invoke(WSHTARGET, WSHNAME, WSHARGS),
        WSHEXPECTED), WSHCMDS))
    => script.return(WSHID, WSHENV, WSHEXPECTED, WSHCMDS,
      invoke(WSHS, findFunc(value('EXPORTS,
        findInstance(WSHENV, WSHTARGET)), WSHNAME), WSHARGS)) .
  crl [get-return] :
    script.ready(WSHS, WSHENV, commands.cons(command.return(WSHID,
      action.get(WSHTARGET, WSHNAME), WSHEXPECTED), WSHCMDS))
    => script.ready(WSHS, WSHENV, WSHCMDS)
    if WSHA := findGlobal(value('EXPORTS,
         findInstance(WSHENV, WSHTARGET)), WSHNAME)
       /\ WSHACTUAL := value('VALUE, index(value('GLOBALS, WSHS), WSHA))
       /\ typecheck(WSHACTUAL, val)
       /\ typecheck(WSHACTUAL, instr)
       /\ match.values(WSHACTUAL, WSHEXPECTED) = match.yes .
  crl [get-wrong-result] :
    script.ready(WSHS, WSHENV, commands.cons(command.return(WSHID,
      action.get(WSHTARGET, WSHNAME), WSHEXPECTED), WSHCMDS))
    => script.wrong-result(WSHID, WSHACTUAL, WSHEXPECTED)
    if WSHA := findGlobal(value('EXPORTS,
         findInstance(WSHENV, WSHTARGET)), WSHNAME)
       /\ WSHACTUAL := value('VALUE, index(value('GLOBALS, WSHS), WSHA))
       /\ typecheck(WSHACTUAL, val)
       /\ typecheck(WSHACTUAL, instr)
       /\ match.values(WSHACTUAL, WSHEXPECTED) = match.no .
  crl [return-done] :
    script.return(WSHID, WSHENV, WSHEXPECTED, WSHCMDS,
      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; WSHACTUAL)
    => script.ready(WSHS, WSHENV, WSHCMDS)
    if runtimeResults(WSHACTUAL) = true
       /\ match.values(WSHACTUAL, WSHEXPECTED) = match.yes .
  crl [return-wrong-result] :
    script.return(WSHID, WSHENV, WSHEXPECTED, WSHCMDS,
      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; WSHACTUAL)
    => script.wrong-result(WSHID, WSHACTUAL, WSHEXPECTED)
    if runtimeResults(WSHACTUAL) = true
       /\ match.values(WSHACTUAL, WSHEXPECTED) = match.no .
  crl [return-step] :
    script.return(WSHID, WSHENV, WSHEXPECTED, WSHCMDS, WSHC)
    => script.return(WSHID, WSHENV, WSHEXPECTED, WSHCMDS, WSHC2)
    if Step(WSHC) => WSHC2 .

  rl [call-trap] :
    script.ready(WSHS, WSHENV, commands.cons(command.trap(WSHID,
      action.invoke(WSHTARGET, WSHNAME, WSHARGS)), WSHCMDS))
    => script.trap(WSHID, WSHENV, WSHCMDS,
      invoke(WSHS, findFunc(value('EXPORTS,
        findInstance(WSHENV, WSHTARGET)), WSHNAME), WSHARGS)) .
  rl [trap-done] :
    script.trap(WSHID, WSHENV, WSHCMDS,
      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; TRAP)
    => script.ready(WSHS, WSHENV, WSHCMDS) .
  crl [trap-step] : script.trap(WSHID, WSHENV, WSHCMDS, WSHC)
    => script.trap(WSHID, WSHENV, WSHCMDS, WSHC2)
    if Step(WSHC) => WSHC2 .

  rl [call-exception] :
    script.ready(WSHS, WSHENV, commands.cons(command.exception(WSHID,
      action.invoke(WSHTARGET, WSHNAME, WSHARGS)), WSHCMDS))
    => script.exception(WSHID, WSHENV, WSHCMDS,
      invoke(WSHS, findFunc(value('EXPORTS,
        findInstance(WSHENV, WSHTARGET)), WSHNAME), WSHARGS)) .
  rl [exception-done] :
    script.exception(WSHID, WSHENV, WSHCMDS,
      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ;
        (REF.EXN-ADDR(WSHA) THROW-REF))
    => script.ready(WSHS, WSHENV, WSHCMDS) .
  rl [exception-trap] :
    script.exception(WSHID, WSHENV, WSHCMDS,
      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; TRAP)
    => script.wrong-assertion(WSHID) .
  crl [exception-normal] :
    script.exception(WSHID, WSHENV, WSHCMDS,
      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; WSHACTUAL)
    => script.wrong-assertion(WSHID)
    if runtimeResults(WSHACTUAL) = true .
  crl [exception-step] : script.exception(WSHID, WSHENV, WSHCMDS, WSHC)
    => script.exception(WSHID, WSHENV, WSHCMDS, WSHC2)
    if Step(WSHC) => WSHC2 .

  rl [call-action] :
    script.ready(WSHS, WSHENV, commands.cons(command.do(WSHID,
      action.invoke(WSHTARGET, WSHNAME, WSHARGS)), WSHCMDS))
    => script.action(WSHID, WSHENV, WSHCMDS,
      invoke(WSHS, findFunc(value('EXPORTS,
        findInstance(WSHENV, WSHTARGET)), WSHNAME), WSHARGS)) .
  crl [action-done] :
    script.action(WSHID, WSHENV, WSHCMDS,
      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; WSHACTUAL)
    => script.ready(WSHS, WSHENV, WSHCMDS)
    if runtimeResults(WSHACTUAL) = true .
  crl [action-step] : script.action(WSHID, WSHENV, WSHCMDS, WSHC)
    => script.action(WSHID, WSHENV, WSHCMDS, WSHC2)
    if Step(WSHC) => WSHC2 .
  crl [get-action] :
    script.ready(WSHS, WSHENV, commands.cons(command.do(WSHID,
      action.get(WSHTARGET, WSHNAME)), WSHCMDS))
    => script.ready(WSHS, WSHENV, WSHCMDS)
    if WSHA := findGlobal(value('EXPORTS,
         findInstance(WSHENV, WSHTARGET)), WSHNAME)
       /\ WSHACTUAL := value('VALUE, index(value('GLOBALS, WSHS), WSHA))
       /\ typecheck(WSHACTUAL, val)
       /\ typecheck(WSHACTUAL, instr) .

  rl [call-exhaustion] :
    script.ready(WSHS, WSHENV, commands.cons(command.exhaustion(WSHID,
      WSHREQUIRED, action.invoke(WSHTARGET, WSHNAME, WSHARGS)), WSHCMDS))
    => script.exhaustion(WSHID, WSHREQUIRED, WSHENV, WSHCMDS,
      invoke(WSHS, findFunc(value('EXPORTS,
        findInstance(WSHENV, WSHTARGET)), WSHNAME), WSHARGS)) .
  rl [exhaustion-trap] :
    script.exhaustion(WSHID, WSHREQUIRED, WSHENV, WSHCMDS,
      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; TRAP)
    => script.wrong-assertion(WSHID) .
  rl [exhaustion-exception] :
    script.exhaustion(WSHID, WSHREQUIRED, WSHENV, WSHCMDS,
      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ;
        (REF.EXN-ADDR(WSHA) THROW-REF))
    => script.wrong-assertion(WSHID) .
  crl [exhaustion-normal] :
    script.exhaustion(WSHID, WSHREQUIRED, WSHENV, WSHCMDS,
      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; WSHACTUAL)
    => script.wrong-assertion(WSHID)
    if runtimeResults(WSHACTUAL) = true .
  crl [exhaustion-step] :
    script.exhaustion(WSHID, WSHREQUIRED, WSHENV, WSHCMDS,
      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; WSHBODY)
    => script.exhaustion-check(WSHID, WSHREQUIRED, WSHENV, WSHCMDS,
      WSHS2, (WSHS2 ; WSHF2) ; WSHINSTRS)
    if Step((WSHS ;
         { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; WSHBODY)
         => (WSHS2 ; WSHF2) ; WSHINSTRS .
  crl [exhaustion-done] :
    script.exhaustion-check(WSHID, WSHREQUIRED, WSHENV, WSHCMDS, WSHS,
      WSHC2 ; WSHINSTRS)
    => script.ready(WSHS, WSHENV, WSHCMDS)
    if activeFrameDepth(WSHINSTRS) > WSHREQUIRED = true .
  crl [exhaustion-continue] :
    script.exhaustion-check(WSHID, WSHREQUIRED, WSHENV, WSHCMDS, WSHS, WSHC)
    => script.exhaustion(WSHID, WSHREQUIRED, WSHENV, WSHCMDS, WSHC)
    if WSHC2 ; WSHINSTRS := WSHC
       /\ activeFrameDepth(WSHINSTRS) <= WSHREQUIRED = true .

  rl [done] :
    script.ready(WSHS, WSHENV, commands.nil) => script.done .
endm

rew [%d] in WASM2MAUDE-WAST : script.start .
continue 1 .
|})
      semantics commands host_store host_functions host_instances steps
