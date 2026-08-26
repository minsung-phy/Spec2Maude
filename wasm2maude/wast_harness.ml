let render ~semantics ~steps ~commands ~host_store ~host_instances
    ~host_functions =
    Printf.sprintf
      "load %s\n\nmod WASM2MAUDE-WAST is\n\
       \  including WASM-BUILTINS .\n\n\
       \  sorts ScriptAction ImportRequirement ImportRef ImportRefs LinkResult\n\
       \    Command Commands\n\
       \    InstanceEnv ScriptState ResultPattern ResultPatterns\n\
       \    ResultAlternatives LanePattern LanePatterns MatchVerdict .\n\
       \  subsort Command < Commands .\n\
       \  op action.invoke : Nat SpectecTerminals SpectecTerminals\n\
       \    -> ScriptAction [ctor] .\n\
       \  op action.get : Nat SpectecTerminals -> ScriptAction [ctor] .\n\
       \  op commands.nil : -> Commands [ctor] .\n\
       \  op commands.cons : Command Commands -> Commands [ctor] .\n\
       \  op import.ready : -> ImportRequirement [ctor] .\n\
       \  op import.current-memory-min : Nat -> ImportRequirement [ctor] .\n\
       \  op import.current-table-min : Nat -> ImportRequirement [ctor] .\n\
       \  op import.ref : Nat SpectecTerminals ImportRequirement\n\
       \    -> ImportRef [ctor] .\n\
       \  op imports.nil : -> ImportRefs [ctor] .\n\
       \  op imports.cons : ImportRef ImportRefs -> ImportRefs [ctor] .\n\
       \  op link.ok : SpectecTerminals -> LinkResult [ctor] .\n\
       \  op link.error : -> LinkResult [ctor] .\n\
       \  op link.append : LinkResult LinkResult -> LinkResult .\n\
       \  op command.module : Nat SpectecTerminal ImportRefs\n\
       \    -> Command [ctor] .\n\
       \  op command.unlinkable : Nat ImportRefs -> Command [ctor] .\n\
       \  op command.uninstantiable-static : Nat -> Command [ctor] .\n\
       \  op command.uninstantiable : Nat SpectecTerminal ImportRefs\n\
       \    -> Command [ctor] .\n\
       \  op patterns.nil : -> ResultPatterns [ctor] .\n\
       \  op patterns.cons : ResultPattern ResultPatterns\n\
       \    -> ResultPatterns [ctor] .\n\
       \  op alternatives.nil : -> ResultAlternatives [ctor] .\n\
       \  op alternatives.cons : ResultPattern ResultAlternatives\n\
       \    -> ResultAlternatives [ctor] .\n\
       \  op result.exact-num : SpectecTerminal -> ResultPattern [ctor] .\n\
       \  op result.exact-vec : SpectecTerminal -> ResultPattern [ctor] .\n\
       \  op result.vec-lanes : SpectecTerminal LanePatterns\n\
       \    -> ResultPattern [ctor] .\n\
       \  op result.exact-ref : SpectecTerminal -> ResultPattern [ctor] .\n\
       \  op result.ref-type : SpectecTerminal -> ResultPattern [ctor] .\n\
       \  op result.null-ref : SpectecTerminal -> ResultPattern [ctor] .\n\
       \  op result.either : ResultAlternatives -> ResultPattern [ctor] .\n\
       \  op result.nan-canonical : SpectecTerminal\n\
       \    -> ResultPattern [ctor] .\n\
       \  op result.nan-arithmetic : SpectecTerminal\n\
       \    -> ResultPattern [ctor] .\n\
       \  op lane.exact : SpectecTerminal -> LanePattern [ctor] .\n\
       \  op lane.nan-canonical : -> LanePattern [ctor] .\n\
       \  op lane.nan-arithmetic : -> LanePattern [ctor] .\n\
       \  op lanes.nil : -> LanePatterns [ctor] .\n\
       \  op lanes.cons : LanePattern LanePatterns -> LanePatterns [ctor] .\n\
       \  op match.yes : -> MatchVerdict [ctor] .\n\
       \  op match.no : -> MatchVerdict [ctor] .\n\
       \  op match.and : MatchVerdict MatchVerdict -> MatchVerdict .\n\
       \  op match.or : MatchVerdict MatchVerdict -> MatchVerdict .\n\
       \  op match.value : SpectecTerminal ResultPattern\n\
       \    -> MatchVerdict .\n\
       \  op match.values : SpectecTerminals ResultPatterns\n\
       \    -> MatchVerdict .\n\
       \  op match.any : SpectecTerminal ResultAlternatives\n\
       \    -> MatchVerdict .\n\n\
       \  op match.lane : SpectecTerminal SpectecTerminal LanePattern\n\
       \    -> MatchVerdict .\n\
       \  op match.vec-lanes : SpectecTerminal SpectecTerminals LanePatterns\n\
       \    -> MatchVerdict .\n\n\
       \  op command.return : Nat ScriptAction ResultPatterns\n\
       \    -> Command [ctor] .\n\
       \  op command.trap : Nat ScriptAction -> Command [ctor] .\n\
       \  op command.exception : Nat ScriptAction -> Command [ctor] .\n\
       \  op command.exhaustion : Nat Nat ScriptAction -> Command [ctor] .\n\
       \  op command.do : Nat ScriptAction -> Command [ctor] .\n\n\
       \  op instances.nil : -> InstanceEnv [ctor] .\n\
       \  op instances.cons : Nat SpectecTerminal InstanceEnv\n\
       \    -> InstanceEnv [ctor] .\n\
       \  op findInstance : InstanceEnv Nat ~> SpectecTerminal .\n\n\
       \  op findExport : SpectecTerminals SpectecTerminals\n\
       \    ~> SpectecTerminal .\n\
       \  op checkImport : SpectecTerminal SpectecTerminal ImportRequirement\n\
       \    -> LinkResult .\n\
       \  op linkImports : SpectecTerminal InstanceEnv ImportRefs\n\
       \    -> LinkResult .\n\n\
       \  op script.start : -> ScriptState [ctor] .\n\
       \  op script.ready : SpectecTerminal InstanceEnv Commands\n\
       \    -> ScriptState [ctor] .\n\
       \  op script.module : Nat InstanceEnv Commands SpectecTerminal\n\
       \    -> ScriptState [ctor frozen (4)] .\n\
       \  op script.return : Nat InstanceEnv ResultPatterns Commands\n\
       \    SpectecTerminal -> ScriptState [ctor frozen (5)] .\n\
       \  op script.trap : Nat InstanceEnv Commands SpectecTerminal\n\
       \    -> ScriptState [ctor frozen (4)] .\n\
       \  op script.exception : Nat InstanceEnv Commands SpectecTerminal\n\
       \    -> ScriptState [ctor frozen (4)] .\n\
       \  op script.exhaustion : Nat Nat InstanceEnv Commands SpectecTerminal\n\
       \    -> ScriptState [ctor frozen (5)] .\n\
       \  op script.exhaustion-check : Nat Nat InstanceEnv Commands\n\
       \    SpectecTerminal SpectecTerminal\n\
       \    -> ScriptState [ctor frozen (5 6)] .\n\
       \  op script.action : Nat InstanceEnv Commands SpectecTerminal\n\
       \    -> ScriptState [ctor frozen (4)] .\n\
       \  op script.uninstantiable : Nat InstanceEnv Commands SpectecTerminal\n\
       \    -> ScriptState [ctor frozen (4)] .\n\
       \  op script.wrong-result : Nat SpectecTerminals ResultPatterns\n\
       \    -> ScriptState [ctor] .\n\
       \  op script.wrong-assertion : Nat -> ScriptState [ctor] .\n\
       \  op script.link-error : Nat -> ScriptState [ctor] .\n\
       \  op script.done : -> ScriptState [ctor] .\n\n\
       \  op inputCommands : -> Commands .\n\
       \  op emptyStore : -> SpectecTerminal .\n\
       \  op hostFunctionAddresses : -> SpectecTerminals .\n\
       \  op hostArguments : SpectecTerminals SpectecTerminals -> Bool .\n\
       \  op findFunc : SpectecTerminals SpectecTerminals ~> Nat .\n\n\
       \  op findGlobal : SpectecTerminals SpectecTerminals ~> Nat .\n\n\
       \  op runtimeResults : SpectecTerminals -> Bool .\n\n\
       \  op activeFrameDepth : SpectecTerminals -> Nat .\n\n\
       \  vars WSHC WSHC2 WSHM WSHS WSHS2 WSHF2 WSHMI WSHCURRENT WSHXA WSHHEAD : SpectecTerminal .\n\
       \  vars WSHNT WSHVALUE WSHLT WSHAT WSHRT : SpectecTerminal .\n\
       \  vars WSHNAME WSHOTHER WSHLOCALS WSHEXPORTS WSHARGS WSHACTUAL : SpectecTerminals .\n\
       \  vars WSHLANES WSHVALUES WSHTYPES WSHMAX WSHBODY WSHINSTRS : SpectecTerminals .\n\
       \  vars WSHREST WSHCATCHES : SpectecTerminals .\n\
       \  var WSHCMDS : Commands .\n\
       \  vars WSHIMPORTS WSHIMPORTS2 : ImportRefs .\n\
       \  var WSHREQUIREMENT : ImportRequirement .\n\
       \  var WSHLINK : LinkResult .\n\
       \  var WSHENV : InstanceEnv .\n\
       \  var WSHPATTERN : ResultPattern .\n\
       \  vars WSHEXPECTED WSHPATTERNS : ResultPatterns .\n\
       \  var WSHALTERNATIVES : ResultAlternatives .\n\
       \  var WSHLPAT : LanePattern .\n\
       \  var WSHLPATS : LanePatterns .\n\
       \  vars WSHID WSHTARGET WSHA WSHADDR WSHN WSHMIN WSHREQUIRED WSHDIM : Nat .\n\n\
       \  eq inputCommands = %s .\n\
       \  eq emptyStore = %s .\n\
       \  eq hostFunctionAddresses = %s .\n\n\
       \  eq hostArguments(eps, eps) = true .\n\
       \  eq hostArguments(CONST(WSHNT, WSHVALUE) WSHVALUES,\n\
       \    WSHNT WSHTYPES) = hostArguments(WSHVALUES, WSHTYPES) .\n\
       \  eq hostArguments(WSHVALUES, WSHTYPES) = false [owise] .\n\n\
       \  eq findInstance(instances.cons(WSHID, WSHMI, WSHENV), WSHID) = WSHMI .\n\
       \  ceq findInstance(instances.cons(WSHID, WSHMI, WSHENV), WSHTARGET) =\n\
       \      findInstance(WSHENV, WSHTARGET)\n\
       \    if WSHID =/= WSHTARGET .\n\n\
       \  ceq findExport(WSHHEAD WSHEXPORTS, WSHNAME) = WSHXA\n\
       \    if WSHNAME = value('NAME, WSHHEAD)\n\
       \       /\\ WSHXA := value('ADDR, WSHHEAD) .\n\
       \  ceq findExport(WSHHEAD WSHEXPORTS, WSHNAME) =\n\
       \      findExport(WSHEXPORTS, WSHNAME)\n\
       \    if WSHOTHER := value('NAME, WSHHEAD)\n\
       \       /\\ WSHOTHER =/= WSHNAME .\n\n\
       \  eq link.append(link.error, WSHLINK) = link.error .\n\
       \  eq link.append(link.ok(WSHXA), link.error) = link.error .\n\
       \  eq link.append(link.ok(WSHXA), link.ok(WSHEXPORTS)) =\n\
       \    link.ok(WSHXA WSHEXPORTS) .\n\n\
       \  eq checkImport(WSHS, WSHXA, import.ready) = link.ok(WSHXA) .\n\
       \  ceq checkImport(WSHS, MEM(WSHA),\n\
       \    import.current-memory-min(WSHREQUIRED)) = link.ok(MEM(WSHA))\n\
       \    if __PAGE(WSHAT, [WSHMIN .. WSHMAX]) :=\n\
       \         value('TYPE, index(value('MEMS, WSHS), WSHA))\n\
       \       /\\ WSHMIN >= WSHREQUIRED = true .\n\
       \  ceq checkImport(WSHS, MEM(WSHA),\n\
       \    import.current-memory-min(WSHREQUIRED)) = link.error\n\
       \    if __PAGE(WSHAT, [WSHMIN .. WSHMAX]) :=\n\
       \         value('TYPE, index(value('MEMS, WSHS), WSHA))\n\
       \       /\\ WSHMIN < WSHREQUIRED = true .\n\
       \  eq checkImport(WSHS, TAG(WSHA),\n\
       \    import.current-memory-min(WSHREQUIRED)) = link.error .\n\
       \  eq checkImport(WSHS, GLOBAL(WSHA),\n\
       \    import.current-memory-min(WSHREQUIRED)) = link.error .\n\
       \  eq checkImport(WSHS, TABLE(WSHA),\n\
       \    import.current-memory-min(WSHREQUIRED)) = link.error .\n\
       \  eq checkImport(WSHS, FUNC(WSHA),\n\
       \    import.current-memory-min(WSHREQUIRED)) = link.error .\n\n\
       \  ceq checkImport(WSHS, TABLE(WSHA),\n\
       \    import.current-table-min(WSHREQUIRED)) = link.ok(TABLE(WSHA))\n\
       \    if tuple(WSHAT [WSHMIN .. WSHMAX] WSHRT) :=\n\
       \         value('TYPE, index(value('TABLES, WSHS), WSHA))\n\
       \       /\\ WSHMIN >= WSHREQUIRED = true .\n\
       \  ceq checkImport(WSHS, TABLE(WSHA),\n\
       \    import.current-table-min(WSHREQUIRED)) = link.error\n\
       \    if tuple(WSHAT [WSHMIN .. WSHMAX] WSHRT) :=\n\
       \         value('TYPE, index(value('TABLES, WSHS), WSHA))\n\
       \       /\\ WSHMIN < WSHREQUIRED = true .\n\
       \  eq checkImport(WSHS, TAG(WSHA),\n\
       \    import.current-table-min(WSHREQUIRED)) = link.error .\n\
       \  eq checkImport(WSHS, GLOBAL(WSHA),\n\
       \    import.current-table-min(WSHREQUIRED)) = link.error .\n\
       \  eq checkImport(WSHS, MEM(WSHA),\n\
       \    import.current-table-min(WSHREQUIRED)) = link.error .\n\
       \  eq checkImport(WSHS, FUNC(WSHA),\n\
       \    import.current-table-min(WSHREQUIRED)) = link.error .\n\n\
       \  eq linkImports(WSHS, WSHENV, imports.nil) = link.ok(eps) .\n\
       \  eq linkImports(WSHS, WSHENV, imports.cons(\n\
       \    import.ref(WSHTARGET, WSHNAME, WSHREQUIREMENT), WSHIMPORTS2)) =\n\
       \      link.append(\n\
       \        checkImport(WSHS, findExport(value('EXPORTS,\n\
       \          findInstance(WSHENV, WSHTARGET)), WSHNAME), WSHREQUIREMENT),\n\
       \        linkImports(WSHS, WSHENV, WSHIMPORTS2)) .\n\n\
       \  ceq findFunc(WSHEXPORTS, WSHNAME) = WSHADDR\n\
       \    if FUNC(WSHADDR) := findExport(WSHEXPORTS, WSHNAME) .\n\
       \  ceq findGlobal(WSHEXPORTS, WSHNAME) = WSHA\n\
       \    if GLOBAL(WSHA) := findExport(WSHEXPORTS, WSHNAME) .\n\n\
       \  eq runtimeResults(eps) = true .\n\
       \  ceq runtimeResults(CONST(WSHNT, WSHVALUE) WSHACTUAL) =\n\
       \      runtimeResults(WSHACTUAL)\n\
       \    if typecheck(WSHNT, numtype)\n\
       \       /\\ typecheck(WSHVALUE, num-(WSHNT)) .\n\n\
       \  eq runtimeResults(VCONST(V128, WSHC) WSHACTUAL) =\n\
       \    runtimeResults(WSHACTUAL) .\n\n\
       \  ceq runtimeResults(WSHC WSHACTUAL) = runtimeResults(WSHACTUAL)\n\
       \    if typecheck(WSHC, ref) .\n\n\
       \  eq activeFrameDepth(eps) = 0 .\n\
       \  eq activeFrameDepth((FRAME- WSHN { WSHC } WSHBODY) WSHREST) =\n\
       \    1 + activeFrameDepth(WSHBODY) .\n\
       \  eq activeFrameDepth((LABEL- WSHN { WSHINSTRS } WSHBODY) WSHREST) =\n\
       \    activeFrameDepth(WSHBODY) .\n\
       \  eq activeFrameDepth((HANDLER- WSHN { WSHCATCHES } WSHBODY) WSHREST) =\n\
       \    activeFrameDepth(WSHBODY) .\n\
       \  ceq activeFrameDepth(CONST(WSHNT, WSHVALUE) WSHREST) =\n\
       \      activeFrameDepth(WSHREST)\n\
       \    if typecheck(WSHNT, numtype)\n\
       \       /\\ typecheck(WSHVALUE, num-(WSHNT)) .\n\
       \  eq activeFrameDepth(VCONST(V128, WSHC) WSHREST) =\n\
       \    activeFrameDepth(WSHREST) .\n\
       \  ceq activeFrameDepth(WSHC WSHREST) = activeFrameDepth(WSHREST)\n\
       \    if typecheck(WSHC, ref) .\n\
       \  eq activeFrameDepth(WSHINSTRS) = 0 [owise] .\n\n\
       \  eq match.and(match.yes, match.yes) = match.yes .\n\
       \  eq match.and(match.yes, match.no) = match.no .\n\
       \  eq match.and(match.no, match.yes) = match.no .\n\
       \  eq match.and(match.no, match.no) = match.no .\n\
       \  eq match.or(match.yes, match.yes) = match.yes .\n\
       \  eq match.or(match.yes, match.no) = match.yes .\n\
       \  eq match.or(match.no, match.yes) = match.yes .\n\
       \  eq match.or(match.no, match.no) = match.no .\n\n\
       \  eq match.value(WSHVALUE, result.exact-num(WSHVALUE)) = match.yes .\n\
       \  eq match.value(WSHVALUE, result.exact-vec(WSHVALUE)) = match.yes .\n\
       \  eq match.value(WSHVALUE, result.exact-ref(WSHVALUE)) = match.yes .\n\
       \  eq match.value(REF.NULL-ADDR, result.null-ref(WSHNT)) =\n\
       \    match.yes .\n\
       \  eq match.value(WSHVALUE, result.either(WSHALTERNATIVES)) =\n\
       \    match.any(WSHVALUE, WSHALTERNATIVES) .\n\n\
       \  ceq match.value(\n\
       \    VCONST(V128, WSHVALUE),\n\
       \    result.vec-lanes(WSHLT X WSHDIM, WSHLPATS)) =\n\
       \      match.vec-lanes(WSHLT, WSHLANES, WSHLPATS)\n\
       \    if WSHLANES := lanes-(WSHLT X WSHDIM, WSHVALUE) .\n\n\
       \  eq match.lane(WSHNT, WSHVALUE, lane.exact(WSHVALUE)) = match.yes .\n\
       \  eq match.lane(F32,\n\
       \    POS(NAN(4194304)), lane.nan-canonical) = match.yes .\n\
       \  eq match.lane(F32,\n\
       \    NEG(NAN(4194304)), lane.nan-canonical) = match.yes .\n\
       \  eq match.lane(F64,\n\
       \    POS(NAN(2251799813685248)), lane.nan-canonical) =\n\
       \      match.yes .\n\
       \  eq match.lane(F64,\n\
       \    NEG(NAN(2251799813685248)), lane.nan-canonical) =\n\
       \      match.yes .\n\
       \  ceq match.lane(F32,\n\
       \    POS(NAN(WSHADDR)), lane.nan-arithmetic) = match.yes\n\
       \    if _>=_(WSHADDR, 4194304) = true .\n\
       \  ceq match.lane(F32,\n\
       \    NEG(NAN(WSHADDR)), lane.nan-arithmetic) = match.yes\n\
       \    if _>=_(WSHADDR, 4194304) = true .\n\
       \  ceq match.lane(F64,\n\
       \    POS(NAN(WSHADDR)), lane.nan-arithmetic) = match.yes\n\
       \    if _>=_(WSHADDR, 2251799813685248) = true .\n\
       \  ceq match.lane(F64,\n\
       \    NEG(NAN(WSHADDR)), lane.nan-arithmetic) = match.yes\n\
       \    if _>=_(WSHADDR, 2251799813685248) = true .\n\
       \  eq match.lane(WSHNT, WSHVALUE, WSHLPAT) = match.no [owise] .\n\n\
       \  eq match.vec-lanes(WSHNT, eps, lanes.nil) = match.yes .\n\
       \  eq match.vec-lanes(WSHNT, WSHVALUE WSHLANES,\n\
       \    lanes.cons(WSHLPAT, WSHLPATS)) =\n\
       \    match.and(match.lane(WSHNT, WSHVALUE, WSHLPAT),\n\
       \      match.vec-lanes(WSHNT, WSHLANES, WSHLPATS)) .\n\
       \  eq match.vec-lanes(WSHNT, WSHLANES, WSHLPATS) =\n\
       \    match.no [owise] .\n\n\
       \  eq match.value(\n\
       \    CONST(F32, POS(NAN(4194304))),\n\
       \    result.nan-canonical(F32)) = match.yes .\n\
       \  eq match.value(\n\
       \    CONST(F32, NEG(NAN(4194304))),\n\
       \    result.nan-canonical(F32)) = match.yes .\n\
       \  eq match.value(\n\
       \    CONST(F64, POS(NAN(2251799813685248))),\n\
       \    result.nan-canonical(F64)) = match.yes .\n\
       \  eq match.value(\n\
       \    CONST(F64, NEG(NAN(2251799813685248))),\n\
       \    result.nan-canonical(F64)) = match.yes .\n\
       \  ceq match.value(\n\
       \    CONST(F32, POS(NAN(WSHADDR))),\n\
       \    result.nan-arithmetic(F32)) = match.yes\n\
       \    if _>=_(WSHADDR, 4194304) = true .\n\
       \  ceq match.value(\n\
       \    CONST(F32, NEG(NAN(WSHADDR))),\n\
       \    result.nan-arithmetic(F32)) = match.yes\n\
       \    if _>=_(WSHADDR, 4194304) = true .\n\
       \  ceq match.value(\n\
       \    CONST(F64, POS(NAN(WSHADDR))),\n\
       \    result.nan-arithmetic(F64)) = match.yes\n\
       \    if _>=_(WSHADDR, 2251799813685248) = true .\n\
       \  ceq match.value(\n\
       \    CONST(F64, NEG(NAN(WSHADDR))),\n\
       \    result.nan-arithmetic(F64)) = match.yes\n\
       \    if _>=_(WSHADDR, 2251799813685248) = true .\n\n\
       \  eq match.value(REF.NULL-ADDR, result.ref-type(ANY)) = match.yes .\n\
       \  eq match.value(REF.I31-NUM(WSHVALUE), result.ref-type(ANY)) = match.yes .\n\
       \  eq match.value(REF.STRUCT-ADDR(WSHADDR), result.ref-type(ANY)) = match.yes .\n\
       \  eq match.value(REF.ARRAY-ADDR(WSHADDR), result.ref-type(ANY)) = match.yes .\n\
       \  eq match.value(REF.EXN-ADDR(WSHADDR), result.ref-type(ANY)) = match.yes .\n\
       \  eq match.value(REF.HOST-ADDR(WSHADDR), result.ref-type(ANY)) = match.yes .\n\
       \  eq match.value(REF.EXTERN(WSHVALUE), result.ref-type(ANY)) = match.yes .\n\
       \  eq match.value(REF.I31-NUM(WSHVALUE), result.ref-type(EQ)) = match.yes .\n\
       \  eq match.value(REF.STRUCT-ADDR(WSHADDR), result.ref-type(EQ)) = match.yes .\n\
       \  eq match.value(REF.ARRAY-ADDR(WSHADDR), result.ref-type(EQ)) = match.yes .\n\
       \  eq match.value(REF.I31-NUM(WSHVALUE), result.ref-type(I31)) = match.yes .\n\
       \  eq match.value(REF.STRUCT-ADDR(WSHADDR), result.ref-type(STRUCT)) = match.yes .\n\
       \  eq match.value(REF.ARRAY-ADDR(WSHADDR), result.ref-type(ARRAY)) = match.yes .\n\
       \  eq match.value(REF.FUNC-ADDR(WSHADDR), result.ref-type(spectec-FUNC)) = match.yes .\n\
       \  eq match.value(REF.EXN-ADDR(WSHADDR), result.ref-type(EXN)) = match.yes .\n\
       \  eq match.value(REF.NULL-ADDR, result.ref-type(EXTERN)) = match.yes .\n\
       \  eq match.value(REF.I31-NUM(WSHVALUE), result.ref-type(EXTERN)) = match.yes .\n\
       \  eq match.value(REF.STRUCT-ADDR(WSHADDR), result.ref-type(EXTERN)) = match.yes .\n\
       \  eq match.value(REF.ARRAY-ADDR(WSHADDR), result.ref-type(EXTERN)) = match.yes .\n\
       \  eq match.value(REF.FUNC-ADDR(WSHADDR), result.ref-type(EXTERN)) = match.yes .\n\
       \  eq match.value(REF.EXN-ADDR(WSHADDR), result.ref-type(EXTERN)) = match.yes .\n\
       \  eq match.value(REF.HOST-ADDR(WSHADDR), result.ref-type(EXTERN)) = match.yes .\n\
       \  eq match.value(REF.EXTERN(WSHVALUE), result.ref-type(EXTERN)) = match.yes .\n\
       \  eq match.value(WSHVALUE, WSHPATTERN) = match.no [owise] .\n\n\
       \  eq match.values(eps, patterns.nil) = match.yes .\n\
       \  eq match.values(WSHVALUE WSHACTUAL,\n\
       \    patterns.cons(WSHPATTERN, WSHPATTERNS)) =\n\
       \      match.and(match.value(WSHVALUE, WSHPATTERN),\n\
       \        match.values(WSHACTUAL, WSHPATTERNS)) .\n\
       \  eq match.values(WSHACTUAL, WSHEXPECTED) = match.no [owise] .\n\n\
       \  eq match.any(WSHVALUE, alternatives.nil) = match.no .\n\
       \  eq match.any(WSHVALUE,\n\
       \    alternatives.cons(WSHPATTERN, WSHALTERNATIVES)) =\n\
       \      match.or(match.value(WSHVALUE, WSHPATTERN),\n\
       \        match.any(WSHVALUE, WSHALTERNATIVES)) .\n\n\
       \  crl [host-call] :\n\
       \    Step-read((WSHS ; WSHCURRENT) ;\n\
       \      (WSHARGS (REF.FUNC-ADDR(WSHA) CALL-REF(WSHC)))) => eps\n\
       \    if WSHA <- hostFunctionAddresses = true\n\
       \       /\\ WSHVALUES := WSHARGS\n\
       \       /\\ typecheck(WSHVALUES, val) = true\n\
       \       /\\ typecheck(WSHARGS, instr) = true\n\
       \       /\\ WSHN := len(WSHVALUES)\n\
       \       /\\ WSHXA := index(value('FUNCS, WSHS), WSHA)\n\
       \       /\\ value('CODE, WSHXA) = ...\n\
       \       /\\ FUNC WSHTYPES -> eps := Expand(value('TYPE, WSHXA))\n\
       \       /\\ WSHN = len(WSHTYPES)\n\
       \       /\\ hostArguments(WSHVALUES, WSHTYPES) = true .\n\n\
       \  rl [start] : script.start =>\n\
       \    script.ready(emptyStore, %s, inputCommands) .\n\
       \  crl [module-start] :\n\
       \    script.ready(WSHS, WSHENV,\n\
       \      commands.cons(command.module(WSHID, WSHM, WSHIMPORTS), WSHCMDS))\n\
       \    => script.module(WSHID, WSHENV, WSHCMDS, WSHC)\n\
       \    if link.ok(WSHEXPORTS) := linkImports(WSHS, WSHENV, WSHIMPORTS)\n\
       \       /\\ instantiate(WSHS, WSHM, WSHEXPORTS) => WSHC .\n\
       \  crl [module-link-error] :\n\
       \    script.ready(WSHS, WSHENV,\n\
       \      commands.cons(command.module(WSHID, WSHM, WSHIMPORTS), WSHCMDS))\n\
       \    => script.link-error(WSHID)\n\
       \    if linkImports(WSHS, WSHENV, WSHIMPORTS) = link.error .\n\
       \  rl [module-done] :\n\
       \    script.module(WSHID, WSHENV, WSHCMDS,\n\
       \      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHMI)) }) ; eps)\n\
       \    => script.ready(WSHS, instances.cons(WSHID, WSHMI, WSHENV), WSHCMDS) .\n\n\
       \  crl [module-step] : script.module(WSHID, WSHENV, WSHCMDS, WSHC)\n\
       \    => script.module(WSHID, WSHENV, WSHCMDS, WSHC2)\n\
       \    if Step(WSHC) => WSHC2 .\n\n\
       \  crl [assert-unlinkable] :\n\
       \    script.ready(WSHS, WSHENV,\n\
       \      commands.cons(command.unlinkable(WSHID, WSHIMPORTS), WSHCMDS))\n\
       \    => script.ready(WSHS, WSHENV, WSHCMDS)\n\
       \    if linkImports(WSHS, WSHENV, WSHIMPORTS) = link.error .\n\
       \  crl [assert-unlinkable-wrong] :\n\
       \    script.ready(WSHS, WSHENV,\n\
       \      commands.cons(command.unlinkable(WSHID, WSHIMPORTS), WSHCMDS))\n\
       \    => script.wrong-assertion(WSHID)\n\
       \    if link.ok(WSHEXPORTS) := linkImports(WSHS, WSHENV, WSHIMPORTS) .\n\n\
       \  rl [assert-uninstantiable-static-link-error] :\n\
       \    script.ready(WSHS, WSHENV,\n\
       \      commands.cons(command.uninstantiable-static(WSHID), WSHCMDS))\n\
       \    => script.wrong-assertion(WSHID) .\n\
       \  crl [assert-uninstantiable-link-error] :\n\
       \    script.ready(WSHS, WSHENV,\n\
       \      commands.cons(command.uninstantiable(WSHID, WSHM, WSHIMPORTS), WSHCMDS))\n\
       \    => script.wrong-assertion(WSHID)\n\
       \    if linkImports(WSHS, WSHENV, WSHIMPORTS) = link.error .\n\
       \  crl [assert-uninstantiable-start] :\n\
       \    script.ready(WSHS, WSHENV,\n\
       \      commands.cons(command.uninstantiable(WSHID, WSHM, WSHIMPORTS), WSHCMDS))\n\
       \    => script.uninstantiable(WSHID, WSHENV, WSHCMDS, WSHC)\n\
       \    if link.ok(WSHEXPORTS) := linkImports(WSHS, WSHENV, WSHIMPORTS)\n\
       \       /\\ instantiate(WSHS, WSHM, WSHEXPORTS) => WSHC .\n\
       \  rl [assert-uninstantiable-trap] :\n\
       \    script.uninstantiable(WSHID, WSHENV, WSHCMDS,\n\
       \      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; TRAP)\n\
       \    => script.ready(WSHS, WSHENV, WSHCMDS) .\n\
       \  rl [assert-uninstantiable-exception] :\n\
       \    script.uninstantiable(WSHID, WSHENV, WSHCMDS,\n\
       \      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ;\n\
       \        (REF.EXN-ADDR(WSHA) THROW-REF))\n\
       \    => script.ready(WSHS, WSHENV, WSHCMDS) .\n\
       \  rl [assert-uninstantiable-normal] :\n\
       \    script.uninstantiable(WSHID, WSHENV, WSHCMDS,\n\
       \      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; eps)\n\
       \    => script.wrong-assertion(WSHID) .\n\
       \  crl [assert-uninstantiable-step] :\n\
       \    script.uninstantiable(WSHID, WSHENV, WSHCMDS, WSHC)\n\
       \    => script.uninstantiable(WSHID, WSHENV, WSHCMDS, WSHC2)\n\
       \    if Step(WSHC) => WSHC2 .\n\n\
       \  rl [call-return] :\n\
       \    script.ready(WSHS, WSHENV, commands.cons(\n\
       \      command.return(WSHID, action.invoke(WSHTARGET, WSHNAME, WSHARGS),\n\
       \        WSHEXPECTED), WSHCMDS))\n\
       \    => script.return(WSHID, WSHENV, WSHEXPECTED, WSHCMDS,\n\
       \      invoke(WSHS, findFunc(value('EXPORTS,\n\
       \        findInstance(WSHENV, WSHTARGET)), WSHNAME), WSHARGS)) .\n\
       \  crl [get-return] :\n\
       \    script.ready(WSHS, WSHENV, commands.cons(command.return(WSHID,\n\
       \      action.get(WSHTARGET, WSHNAME), WSHEXPECTED), WSHCMDS))\n\
       \    => script.ready(WSHS, WSHENV, WSHCMDS)\n\
       \    if WSHA := findGlobal(value('EXPORTS,\n\
       \         findInstance(WSHENV, WSHTARGET)), WSHNAME)\n\
       \       /\\ WSHACTUAL := value('VALUE, index(value('GLOBALS, WSHS), WSHA))\n\
       \       /\\ typecheck(WSHACTUAL, val)\n\
       \       /\\ typecheck(WSHACTUAL, instr)\n\
       \       /\\ match.values(WSHACTUAL, WSHEXPECTED) = match.yes .\n\
       \  crl [get-wrong-result] :\n\
       \    script.ready(WSHS, WSHENV, commands.cons(command.return(WSHID,\n\
       \      action.get(WSHTARGET, WSHNAME), WSHEXPECTED), WSHCMDS))\n\
       \    => script.wrong-result(WSHID, WSHACTUAL, WSHEXPECTED)\n\
       \    if WSHA := findGlobal(value('EXPORTS,\n\
       \         findInstance(WSHENV, WSHTARGET)), WSHNAME)\n\
       \       /\\ WSHACTUAL := value('VALUE, index(value('GLOBALS, WSHS), WSHA))\n\
       \       /\\ typecheck(WSHACTUAL, val)\n\
       \       /\\ typecheck(WSHACTUAL, instr)\n\
       \       /\\ match.values(WSHACTUAL, WSHEXPECTED) = match.no .\n\
       \  crl [return-done] :\n\
       \    script.return(WSHID, WSHENV, WSHEXPECTED, WSHCMDS,\n\
       \      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; WSHACTUAL)\n\
       \    => script.ready(WSHS, WSHENV, WSHCMDS)\n\
       \    if runtimeResults(WSHACTUAL) = true\n\
       \       /\\ match.values(WSHACTUAL, WSHEXPECTED) = match.yes .\n\
       \  crl [return-wrong-result] :\n\
       \    script.return(WSHID, WSHENV, WSHEXPECTED, WSHCMDS,\n\
       \      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; WSHACTUAL)\n\
       \    => script.wrong-result(WSHID, WSHACTUAL, WSHEXPECTED)\n\
       \    if runtimeResults(WSHACTUAL) = true\n\
       \       /\\ match.values(WSHACTUAL, WSHEXPECTED) = match.no .\n\
       \  crl [return-step] :\n\
       \    script.return(WSHID, WSHENV, WSHEXPECTED, WSHCMDS, WSHC)\n\
       \    => script.return(WSHID, WSHENV, WSHEXPECTED, WSHCMDS, WSHC2)\n\
       \    if Step(WSHC) => WSHC2 .\n\n\
       \  rl [call-trap] :\n\
       \    script.ready(WSHS, WSHENV, commands.cons(command.trap(WSHID,\n\
       \      action.invoke(WSHTARGET, WSHNAME, WSHARGS)), WSHCMDS))\n\
       \    => script.trap(WSHID, WSHENV, WSHCMDS,\n\
       \      invoke(WSHS, findFunc(value('EXPORTS,\n\
       \        findInstance(WSHENV, WSHTARGET)), WSHNAME), WSHARGS)) .\n\
       \  rl [trap-done] :\n\
       \    script.trap(WSHID, WSHENV, WSHCMDS,\n\
       \      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; TRAP)\n\
       \    => script.ready(WSHS, WSHENV, WSHCMDS) .\n\
       \  crl [trap-step] : script.trap(WSHID, WSHENV, WSHCMDS, WSHC)\n\
       \    => script.trap(WSHID, WSHENV, WSHCMDS, WSHC2)\n\
       \    if Step(WSHC) => WSHC2 .\n\n\
       \  rl [call-exception] :\n\
       \    script.ready(WSHS, WSHENV, commands.cons(command.exception(WSHID,\n\
       \      action.invoke(WSHTARGET, WSHNAME, WSHARGS)), WSHCMDS))\n\
       \    => script.exception(WSHID, WSHENV, WSHCMDS,\n\
       \      invoke(WSHS, findFunc(value('EXPORTS,\n\
       \        findInstance(WSHENV, WSHTARGET)), WSHNAME), WSHARGS)) .\n\
       \  rl [exception-done] :\n\
       \    script.exception(WSHID, WSHENV, WSHCMDS,\n\
       \      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ;\n\
       \        (REF.EXN-ADDR(WSHA) THROW-REF))\n\
       \    => script.ready(WSHS, WSHENV, WSHCMDS) .\n\
       \  rl [exception-trap] :\n\
       \    script.exception(WSHID, WSHENV, WSHCMDS,\n\
       \      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; TRAP)\n\
       \    => script.wrong-assertion(WSHID) .\n\
       \  crl [exception-normal] :\n\
       \    script.exception(WSHID, WSHENV, WSHCMDS,\n\
       \      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; WSHACTUAL)\n\
       \    => script.wrong-assertion(WSHID)\n\
       \    if runtimeResults(WSHACTUAL) = true .\n\
       \  crl [exception-step] : script.exception(WSHID, WSHENV, WSHCMDS, WSHC)\n\
       \    => script.exception(WSHID, WSHENV, WSHCMDS, WSHC2)\n\
       \    if Step(WSHC) => WSHC2 .\n\n\
       \  rl [call-action] :\n\
       \    script.ready(WSHS, WSHENV, commands.cons(command.do(WSHID,\n\
       \      action.invoke(WSHTARGET, WSHNAME, WSHARGS)), WSHCMDS))\n\
       \    => script.action(WSHID, WSHENV, WSHCMDS,\n\
       \      invoke(WSHS, findFunc(value('EXPORTS,\n\
       \        findInstance(WSHENV, WSHTARGET)), WSHNAME), WSHARGS)) .\n\
       \  crl [action-done] :\n\
       \    script.action(WSHID, WSHENV, WSHCMDS,\n\
       \      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; WSHACTUAL)\n\
       \    => script.ready(WSHS, WSHENV, WSHCMDS)\n\
       \    if runtimeResults(WSHACTUAL) = true .\n\
       \  crl [action-step] : script.action(WSHID, WSHENV, WSHCMDS, WSHC)\n\
       \    => script.action(WSHID, WSHENV, WSHCMDS, WSHC2)\n\
       \    if Step(WSHC) => WSHC2 .\n\
       \  crl [get-action] :\n\
       \    script.ready(WSHS, WSHENV, commands.cons(command.do(WSHID,\n\
       \      action.get(WSHTARGET, WSHNAME)), WSHCMDS))\n\
       \    => script.ready(WSHS, WSHENV, WSHCMDS)\n\
       \    if WSHA := findGlobal(value('EXPORTS,\n\
       \         findInstance(WSHENV, WSHTARGET)), WSHNAME)\n\
       \       /\\ WSHACTUAL := value('VALUE, index(value('GLOBALS, WSHS), WSHA))\n\
       \       /\\ typecheck(WSHACTUAL, val)\n\
       \       /\\ typecheck(WSHACTUAL, instr) .\n\n\
       \  rl [call-exhaustion] :\n\
       \    script.ready(WSHS, WSHENV, commands.cons(command.exhaustion(WSHID,\n\
       \      WSHREQUIRED, action.invoke(WSHTARGET, WSHNAME, WSHARGS)), WSHCMDS))\n\
       \    => script.exhaustion(WSHID, WSHREQUIRED, WSHENV, WSHCMDS,\n\
       \      invoke(WSHS, findFunc(value('EXPORTS,\n\
       \        findInstance(WSHENV, WSHTARGET)), WSHNAME), WSHARGS)) .\n\
       \  rl [exhaustion-trap] :\n\
       \    script.exhaustion(WSHID, WSHREQUIRED, WSHENV, WSHCMDS,\n\
       \      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; TRAP)\n\
       \    => script.wrong-assertion(WSHID) .\n\
       \  rl [exhaustion-exception] :\n\
       \    script.exhaustion(WSHID, WSHREQUIRED, WSHENV, WSHCMDS,\n\
       \      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ;\n\
       \        (REF.EXN-ADDR(WSHA) THROW-REF))\n\
       \    => script.wrong-assertion(WSHID) .\n\
       \  crl [exhaustion-normal] :\n\
       \    script.exhaustion(WSHID, WSHREQUIRED, WSHENV, WSHCMDS,\n\
       \      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; WSHACTUAL)\n\
       \    => script.wrong-assertion(WSHID)\n\
       \    if runtimeResults(WSHACTUAL) = true .\n\
       \  crl [exhaustion-step] :\n\
       \    script.exhaustion(WSHID, WSHREQUIRED, WSHENV, WSHCMDS,\n\
       \      (WSHS ; { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; WSHBODY)\n\
       \    => script.exhaustion-check(WSHID, WSHREQUIRED, WSHENV, WSHCMDS,\n\
       \      WSHS2, (WSHS2 ; WSHF2) ; WSHINSTRS)\n\
       \    if Step((WSHS ;\n\
       \         { (item('LOCALS, WSHLOCALS) ; item('MODULE, WSHCURRENT)) }) ; WSHBODY)\n\
       \         => (WSHS2 ; WSHF2) ; WSHINSTRS .\n\
       \  crl [exhaustion-done] :\n\
       \    script.exhaustion-check(WSHID, WSHREQUIRED, WSHENV, WSHCMDS, WSHS,\n\
       \      WSHC2 ; WSHINSTRS)\n\
       \    => script.ready(WSHS, WSHENV, WSHCMDS)\n\
       \    if activeFrameDepth(WSHINSTRS) > WSHREQUIRED = true .\n\
       \  crl [exhaustion-continue] :\n\
       \    script.exhaustion-check(WSHID, WSHREQUIRED, WSHENV, WSHCMDS, WSHS, WSHC)\n\
       \    => script.exhaustion(WSHID, WSHREQUIRED, WSHENV, WSHCMDS, WSHC)\n\
       \    if WSHC2 ; WSHINSTRS := WSHC\n\
       \       /\\ activeFrameDepth(WSHINSTRS) <= WSHREQUIRED = true .\n\
       \n\
       \  rl [done] :\n\
       \    script.ready(WSHS, WSHENV, commands.nil) => script.done .\n\
       endm\n\n\
       rew [%d] in WASM2MAUDE-WAST : script.start .\n\
       continue 1 .\n"
      semantics commands host_store host_functions host_instances steps
