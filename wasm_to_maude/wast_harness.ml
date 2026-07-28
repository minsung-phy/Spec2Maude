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
       \  op action.invoke : Nat SpectecTerminal SpectecTerminals\n\
       \    -> ScriptAction [ctor] .\n\
       \  op action.get : Nat SpectecTerminal -> ScriptAction [ctor] .\n\
       \  op commands.nil : -> Commands [ctor] .\n\
       \  op commands.cons : Command Commands -> Commands [ctor] .\n\
       \  op import.ready : -> ImportRequirement [ctor] .\n\
       \  op import.current-memory-min : Nat -> ImportRequirement [ctor] .\n\
       \  op import.current-table-min : Nat -> ImportRequirement [ctor] .\n\
       \  op import.ref : Nat SpectecTerminal ImportRequirement\n\
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
       \  op findExport : SpectecTerminals SpectecTerminal\n\
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
       \  op findFunc : SpectecTerminals SpectecTerminal ~> Nat .\n\n\
       \  op findGlobal : SpectecTerminals SpectecTerminal ~> Nat .\n\n\
       \  op runtimeResults : SpectecTerminals -> Bool .\n\n\
       \  op activeFrameDepth : SpectecTerminals -> Nat .\n\n\
       \  vars C C2 M S MI CURRENT NAME OTHER XA : SpectecTerminal .\n\
       \  vars NT VALUE LT DIM AT RT : SpectecTerminal .\n\
       \  vars LOCALS EXPORTS ARGS ACTUAL LANES VALUES TYPES MAX : SpectecTerminals .\n\
       \  vars BODY INSTRS REST CATCHES : SpectecTerminals .\n\
       \  var CMDS : Commands .\n\
       \  vars IMPORTS IMPORTS2 : ImportRefs .\n\
       \  var REQUIREMENT : ImportRequirement .\n\
       \  var LINK : LinkResult .\n\
       \  var ENV : InstanceEnv .\n\
       \  var PATTERN : ResultPattern .\n\
       \  vars EXPECTED PATTERNS : ResultPatterns .\n\
       \  var ALTERNATIVES : ResultAlternatives .\n\
       \  vars LPAT : LanePattern .\n\
       \  vars LPATS : LanePatterns .\n\
       \  vars ID TARGET A ADDR N MIN REQUIRED : Nat .\n\n\
       \  eq inputCommands = %s .\n\
       \  eq emptyStore = %s .\n\
       \  eq hostFunctionAddresses = %s .\n\n\
       \  eq hostArguments(eps, eps) = true .\n\
       \  eq hostArguments(num.const(NT, VALUE) VALUES, NT TYPES) =\n\
       \    hostArguments(VALUES, TYPES) .\n\
       \  eq hostArguments(VALUES, TYPES) = false [owise] .\n\n\
       \  eq findInstance(instances.cons(ID, MI, ENV), ID) = MI .\n\
       \  ceq findInstance(instances.cons(ID, MI, ENV), TARGET) =\n\
       \      findInstance(ENV, TARGET)\n\
       \    if ID =/= TARGET .\n\n\
       \  eq findExport(rec.exportinst(NAME, XA) EXPORTS, NAME) = XA .\n\
       \  ceq findExport(rec.exportinst(OTHER, XA) EXPORTS, NAME) =\n\
       \      findExport(EXPORTS, NAME)\n\
       \    if OTHER =/= NAME .\n\n\
       \  eq link.append(link.error, LINK) = link.error .\n\
       \  eq link.append(link.ok(XA), link.error) = link.error .\n\
       \  eq link.append(link.ok(XA), link.ok(EXPORTS)) =\n\
       \    link.ok(XA EXPORTS) .\n\n\
       \  eq checkImport(S, XA, import.ready) = link.ok(XA) .\n\
       \  ceq checkImport(S, externaddr.mem(A),\n\
       \    import.current-memory-min(REQUIRED)) =\n\
       \      link.ok(externaddr.mem(A))\n\
       \    if memtype.page(AT,\n\
       \         limits.sym-sym-sym(uN.wrap(MIN), MAX)) :=\n\
       \         value('TYPE, index(value('MEMS, S), A))\n\
       \       /\\ _>=_(MIN, REQUIRED) = true .\n\
       \  ceq checkImport(S, externaddr.mem(A),\n\
       \    import.current-memory-min(REQUIRED)) = link.error\n\
       \    if memtype.page(AT,\n\
       \         limits.sym-sym-sym(uN.wrap(MIN), MAX)) :=\n\
       \         value('TYPE, index(value('MEMS, S), A))\n\
       \       /\\ _<_(MIN, REQUIRED) = true .\n\
       \  eq checkImport(S, externaddr.tag(A),\n\
       \    import.current-memory-min(REQUIRED)) = link.error .\n\
       \  eq checkImport(S, externaddr.global(A),\n\
       \    import.current-memory-min(REQUIRED)) = link.error .\n\
       \  eq checkImport(S, externaddr.table(A),\n\
       \    import.current-memory-min(REQUIRED)) = link.error .\n\
       \  eq checkImport(S, externaddr.func(A),\n\
       \    import.current-memory-min(REQUIRED)) = link.error .\n\n\
       \  ceq checkImport(S, externaddr.table(A),\n\
       \    import.current-table-min(REQUIRED)) =\n\
       \      link.ok(externaddr.table(A))\n\
       \    if tabletype.wrap(AT,\n\
       \         limits.sym-sym-sym(uN.wrap(MIN), MAX), RT) :=\n\
       \         value('TYPE, index(value('TABLES, S), A))\n\
       \       /\\ _>=_(MIN, REQUIRED) = true .\n\
       \  ceq checkImport(S, externaddr.table(A),\n\
       \    import.current-table-min(REQUIRED)) = link.error\n\
       \    if tabletype.wrap(AT,\n\
       \         limits.sym-sym-sym(uN.wrap(MIN), MAX), RT) :=\n\
       \         value('TYPE, index(value('TABLES, S), A))\n\
       \       /\\ _<_(MIN, REQUIRED) = true .\n\
       \  eq checkImport(S, externaddr.tag(A),\n\
       \    import.current-table-min(REQUIRED)) = link.error .\n\
       \  eq checkImport(S, externaddr.global(A),\n\
       \    import.current-table-min(REQUIRED)) = link.error .\n\
       \  eq checkImport(S, externaddr.mem(A),\n\
       \    import.current-table-min(REQUIRED)) = link.error .\n\
       \  eq checkImport(S, externaddr.func(A),\n\
       \    import.current-table-min(REQUIRED)) = link.error .\n\n\
       \  eq linkImports(S, ENV, imports.nil) = link.ok(eps) .\n\
       \  eq linkImports(S, ENV, imports.cons(\n\
       \    import.ref(TARGET, NAME, REQUIREMENT), IMPORTS2)) =\n\
       \      link.append(\n\
       \        checkImport(S, findExport(value('EXPORTS,\n\
       \          findInstance(ENV, TARGET)), NAME), REQUIREMENT),\n\
       \        linkImports(S, ENV, IMPORTS2)) .\n\n\
       \  eq findFunc(\n\
       \    rec.exportinst(NAME, externaddr.func(ADDR)) EXPORTS, NAME) = ADDR .\n\
       \  ceq findFunc(rec.exportinst(OTHER, XA) EXPORTS, NAME) =\n\
       \      findFunc(EXPORTS, NAME)\n\
       \    if OTHER =/= NAME .\n\n\
       \  eq findGlobal(\n\
       \    rec.exportinst(NAME, externaddr.global(A)) EXPORTS, NAME) = A .\n\
       \  ceq findGlobal(rec.exportinst(OTHER, XA) EXPORTS, NAME) =\n\
       \      findGlobal(EXPORTS, NAME)\n\
       \    if OTHER =/= NAME .\n\n\
       \  eq runtimeResults(eps) = true .\n\
       \  ceq runtimeResults(instr.const(NT, VALUE) ACTUAL) =\n\
       \      runtimeResults(ACTUAL)\n\
       \    if typecheck(NT, syn.numtype)\n\
       \       /\\ typecheck(VALUE, syn.num(NT)) .\n\n\
       \  eq runtimeResults(instr.vconst(vectype.v128, C) ACTUAL) =\n\
       \    runtimeResults(ACTUAL) .\n\n\
       \  ceq runtimeResults(C ACTUAL) = runtimeResults(ACTUAL)\n\
       \    if typecheck(C, syn.ref) .\n\n\
       \  eq activeFrameDepth(eps) = 0 .\n\
       \  eq activeFrameDepth(\n\
       \    instr.frame-sym-sym(N, C, BODY) REST) =\n\
       \      _+_(1, activeFrameDepth(BODY)) .\n\
       \  eq activeFrameDepth(\n\
       \    instr.label-sym-sym(N, INSTRS, BODY) REST) =\n\
       \      activeFrameDepth(BODY) .\n\
       \  eq activeFrameDepth(\n\
       \    instr.handler-sym-sym(N, CATCHES, BODY) REST) =\n\
       \      activeFrameDepth(BODY) .\n\
       \  ceq activeFrameDepth(instr.const(NT, VALUE) REST) =\n\
       \      activeFrameDepth(REST)\n\
       \    if typecheck(NT, syn.numtype)\n\
       \       /\\ typecheck(VALUE, syn.num(NT)) .\n\
       \  eq activeFrameDepth(\n\
       \    instr.vconst(vectype.v128, C) REST) = activeFrameDepth(REST) .\n\
       \  ceq activeFrameDepth(C REST) = activeFrameDepth(REST)\n\
       \    if typecheck(C, syn.ref) .\n\
       \  eq activeFrameDepth(INSTRS) = 0 [owise] .\n\n\
       \  eq match.and(match.yes, match.yes) = match.yes .\n\
       \  eq match.and(match.yes, match.no) = match.no .\n\
       \  eq match.and(match.no, match.yes) = match.no .\n\
       \  eq match.and(match.no, match.no) = match.no .\n\
       \  eq match.or(match.yes, match.yes) = match.yes .\n\
       \  eq match.or(match.yes, match.no) = match.yes .\n\
       \  eq match.or(match.no, match.yes) = match.yes .\n\
       \  eq match.or(match.no, match.no) = match.no .\n\n\
       \  eq match.value(VALUE, result.exact-num(VALUE)) = match.yes .\n\
       \  eq match.value(VALUE, result.exact-vec(VALUE)) = match.yes .\n\
       \  eq match.value(VALUE, result.exact-ref(VALUE)) = match.yes .\n\
       \  eq match.value(ref.ref-null-addr, result.null-ref(NT)) =\n\
       \    match.yes .\n\
       \  eq match.value(VALUE, result.either(ALTERNATIVES)) =\n\
       \    match.any(VALUE, ALTERNATIVES) .\n\n\
       \  ceq match.value(\n\
       \    instr.vconst(vectype.v128, VALUE),\n\
       \    result.vec-lanes(shape.x(LT, DIM), LPATS)) =\n\
       \      match.vec-lanes(LT, LANES, LPATS)\n\
       \    if LANES := builtin.lanes(shape.x(LT, DIM), VALUE) .\n\n\
       \  eq match.lane(NT, VALUE, lane.exact(VALUE)) = match.yes .\n\
       \  eq match.lane(numtype.f32,\n\
       \    fN.pos(fNmag.nan(4194304)), lane.nan-canonical) = match.yes .\n\
       \  eq match.lane(numtype.f32,\n\
       \    fN.neg(fNmag.nan(4194304)), lane.nan-canonical) = match.yes .\n\
       \  eq match.lane(numtype.f64,\n\
       \    fN.pos(fNmag.nan(2251799813685248)), lane.nan-canonical) =\n\
       \      match.yes .\n\
       \  eq match.lane(numtype.f64,\n\
       \    fN.neg(fNmag.nan(2251799813685248)), lane.nan-canonical) =\n\
       \      match.yes .\n\
       \  ceq match.lane(numtype.f32,\n\
       \    fN.pos(fNmag.nan(ADDR)), lane.nan-arithmetic) = match.yes\n\
       \    if _>=_(ADDR, 4194304) = true .\n\
       \  ceq match.lane(numtype.f32,\n\
       \    fN.neg(fNmag.nan(ADDR)), lane.nan-arithmetic) = match.yes\n\
       \    if _>=_(ADDR, 4194304) = true .\n\
       \  ceq match.lane(numtype.f64,\n\
       \    fN.pos(fNmag.nan(ADDR)), lane.nan-arithmetic) = match.yes\n\
       \    if _>=_(ADDR, 2251799813685248) = true .\n\
       \  ceq match.lane(numtype.f64,\n\
       \    fN.neg(fNmag.nan(ADDR)), lane.nan-arithmetic) = match.yes\n\
       \    if _>=_(ADDR, 2251799813685248) = true .\n\
       \  eq match.lane(NT, VALUE, LPAT) = match.no [owise] .\n\n\
       \  eq match.vec-lanes(NT, eps, lanes.nil) = match.yes .\n\
       \  eq match.vec-lanes(NT, VALUE LANES, lanes.cons(LPAT, LPATS)) =\n\
       \    match.and(match.lane(NT, VALUE, LPAT),\n\
       \      match.vec-lanes(NT, LANES, LPATS)) .\n\
       \  eq match.vec-lanes(NT, LANES, LPATS) = match.no [owise] .\n\n\
       \  eq match.value(\n\
       \    instr.const(numtype.f32, fN.pos(fNmag.nan(4194304))),\n\
       \    result.nan-canonical(numtype.f32)) = match.yes .\n\
       \  eq match.value(\n\
       \    instr.const(numtype.f32, fN.neg(fNmag.nan(4194304))),\n\
       \    result.nan-canonical(numtype.f32)) = match.yes .\n\
       \  eq match.value(\n\
       \    instr.const(numtype.f64, fN.pos(fNmag.nan(2251799813685248))),\n\
       \    result.nan-canonical(numtype.f64)) = match.yes .\n\
       \  eq match.value(\n\
       \    instr.const(numtype.f64, fN.neg(fNmag.nan(2251799813685248))),\n\
       \    result.nan-canonical(numtype.f64)) = match.yes .\n\
       \  ceq match.value(\n\
       \    instr.const(numtype.f32, fN.pos(fNmag.nan(ADDR))),\n\
       \    result.nan-arithmetic(numtype.f32)) = match.yes\n\
       \    if _>=_(ADDR, 4194304) = true .\n\
       \  ceq match.value(\n\
       \    instr.const(numtype.f32, fN.neg(fNmag.nan(ADDR))),\n\
       \    result.nan-arithmetic(numtype.f32)) = match.yes\n\
       \    if _>=_(ADDR, 4194304) = true .\n\
       \  ceq match.value(\n\
       \    instr.const(numtype.f64, fN.pos(fNmag.nan(ADDR))),\n\
       \    result.nan-arithmetic(numtype.f64)) = match.yes\n\
       \    if _>=_(ADDR, 2251799813685248) = true .\n\
       \  ceq match.value(\n\
       \    instr.const(numtype.f64, fN.neg(fNmag.nan(ADDR))),\n\
       \    result.nan-arithmetic(numtype.f64)) = match.yes\n\
       \    if _>=_(ADDR, 2251799813685248) = true .\n\n\
       \  eq match.value(ref.ref-null-addr,\n\
       \    result.ref-type(absheaptype.any)) = match.yes .\n\
       \  eq match.value(ref.ref-i31-num(VALUE),\n\
       \    result.ref-type(absheaptype.any)) = match.yes .\n\
       \  eq match.value(ref.ref-struct-addr(ADDR),\n\
       \    result.ref-type(absheaptype.any)) = match.yes .\n\
       \  eq match.value(ref.ref-array-addr(ADDR),\n\
       \    result.ref-type(absheaptype.any)) = match.yes .\n\
       \  eq match.value(ref.ref-exn-addr(ADDR),\n\
       \    result.ref-type(absheaptype.any)) = match.yes .\n\
       \  eq match.value(ref.ref-host-addr(ADDR),\n\
       \    result.ref-type(absheaptype.any)) = match.yes .\n\
       \  eq match.value(ref.ref-extern(VALUE),\n\
       \    result.ref-type(absheaptype.any)) = match.yes .\n\
       \  eq match.value(ref.ref-i31-num(VALUE),\n\
       \    result.ref-type(absheaptype.eq)) = match.yes .\n\
       \  eq match.value(ref.ref-struct-addr(ADDR),\n\
       \    result.ref-type(absheaptype.eq)) = match.yes .\n\
       \  eq match.value(ref.ref-array-addr(ADDR),\n\
       \    result.ref-type(absheaptype.eq)) = match.yes .\n\
       \  eq match.value(ref.ref-i31-num(VALUE),\n\
       \    result.ref-type(absheaptype.i31)) = match.yes .\n\
       \  eq match.value(ref.ref-struct-addr(ADDR),\n\
       \    result.ref-type(absheaptype.struct)) = match.yes .\n\
       \  eq match.value(ref.ref-array-addr(ADDR),\n\
       \    result.ref-type(absheaptype.array)) = match.yes .\n\
       \  eq match.value(ref.ref-func-addr(ADDR),\n\
       \    result.ref-type(absheaptype.func)) = match.yes .\n\
       \  eq match.value(ref.ref-exn-addr(ADDR),\n\
       \    result.ref-type(absheaptype.exn)) = match.yes .\n\
       \  eq match.value(ref.ref-null-addr,\n\
       \    result.ref-type(absheaptype.extern)) = match.yes .\n\
       \  eq match.value(ref.ref-i31-num(VALUE),\n\
       \    result.ref-type(absheaptype.extern)) = match.yes .\n\
       \  eq match.value(ref.ref-struct-addr(ADDR),\n\
       \    result.ref-type(absheaptype.extern)) = match.yes .\n\
       \  eq match.value(ref.ref-array-addr(ADDR),\n\
       \    result.ref-type(absheaptype.extern)) = match.yes .\n\
       \  eq match.value(ref.ref-func-addr(ADDR),\n\
       \    result.ref-type(absheaptype.extern)) = match.yes .\n\
       \  eq match.value(ref.ref-exn-addr(ADDR),\n\
       \    result.ref-type(absheaptype.extern)) = match.yes .\n\
       \  eq match.value(ref.ref-host-addr(ADDR),\n\
       \    result.ref-type(absheaptype.extern)) = match.yes .\n\
       \  eq match.value(ref.ref-extern(VALUE),\n\
       \    result.ref-type(absheaptype.extern)) = match.yes .\n\
       \  eq match.value(VALUE, PATTERN) = match.no [owise] .\n\n\
       \  eq match.values(eps, patterns.nil) = match.yes .\n\
       \  eq match.values(VALUE ACTUAL,\n\
       \    patterns.cons(PATTERN, PATTERNS)) =\n\
       \      match.and(match.value(VALUE, PATTERN),\n\
       \        match.values(ACTUAL, PATTERNS)) .\n\
       \  eq match.values(ACTUAL, EXPECTED) = match.no [owise] .\n\n\
       \  eq match.any(VALUE, alternatives.nil) = match.no .\n\
       \  eq match.any(VALUE,\n\
       \    alternatives.cons(PATTERN, ALTERNATIVES)) =\n\
       \      match.or(match.value(VALUE, PATTERN),\n\
       \        match.any(VALUE, ALTERNATIVES)) .\n\n\
       \  crl [host-call] :\n\
       \    rel.step-read(config.sym(state.sym(S, CURRENT),\n\
       \      ARGS (ref.ref-func-addr(A) instr.call-ref(C)))) => eps\n\
       \    if contains(A, hostFunctionAddresses) = true\n\
       \       /\\ VALUES := helper.subtype-project-seq.step-pure(ARGS)\n\
       \       /\\ (typecheckSeq(VALUES, syn.val)) = true\n\
       \       /\\ N := len(VALUES)\n\
       \       /\\ XA := index(value('FUNCS, S), A)\n\
       \       /\\ value('CODE, XA) = hostfunc.sym\n\
       \       /\\ comptype.func-sym(list.wrap(TYPES), list.wrap(eps)) :=\n\
       \         rel.expand(value('TYPE, XA))\n\
       \       /\\ N = len(TYPES)\n\
       \       /\\ hostArguments(VALUES, TYPES) = true .\n\n\
       \  rl [start] : script.start =>\n\
       \    script.ready(emptyStore, %s, inputCommands) .\n\
       \  crl [module-start] :\n\
       \    script.ready(S, ENV,\n\
       \      commands.cons(command.module(ID, M, IMPORTS), CMDS))\n\
       \    => script.module(ID, ENV, CMDS, C)\n\
       \    if link.ok(EXPORTS) := linkImports(S, ENV, IMPORTS)\n\
       \       /\\ def.instantiate(S, M, EXPORTS) => C .\n\
       \  crl [module-link-error] :\n\
       \    script.ready(S, ENV,\n\
       \      commands.cons(command.module(ID, M, IMPORTS), CMDS))\n\
       \    => script.link-error(ID)\n\
       \    if linkImports(S, ENV, IMPORTS) = link.error .\n\
       \  crl [module-step] : script.module(ID, ENV, CMDS, C)\n\
       \    => script.module(ID, ENV, CMDS, C2)\n\
       \    if rel.step(C) => C2 .\n\
       \  rl [module-done] :\n\
       \    script.module(ID, ENV, CMDS,\n\
       \      config.sym(state.sym(S, rec.frame(LOCALS, MI)), eps))\n\
       \    => script.ready(S, instances.cons(ID, MI, ENV), CMDS) .\n\n\
       \  crl [assert-unlinkable] :\n\
       \    script.ready(S, ENV,\n\
       \      commands.cons(command.unlinkable(ID, IMPORTS), CMDS))\n\
       \    => script.ready(S, ENV, CMDS)\n\
       \    if linkImports(S, ENV, IMPORTS) = link.error .\n\
       \  crl [assert-unlinkable-wrong] :\n\
       \    script.ready(S, ENV,\n\
       \      commands.cons(command.unlinkable(ID, IMPORTS), CMDS))\n\
       \    => script.wrong-assertion(ID)\n\
       \    if link.ok(EXPORTS) := linkImports(S, ENV, IMPORTS) .\n\n\
       \  rl [assert-uninstantiable-static-link-error] :\n\
       \    script.ready(S, ENV,\n\
       \      commands.cons(command.uninstantiable-static(ID), CMDS))\n\
       \    => script.wrong-assertion(ID) .\n\
       \  crl [assert-uninstantiable-link-error] :\n\
       \    script.ready(S, ENV,\n\
       \      commands.cons(command.uninstantiable(ID, M, IMPORTS), CMDS))\n\
       \    => script.wrong-assertion(ID)\n\
       \    if linkImports(S, ENV, IMPORTS) = link.error .\n\
       \  crl [assert-uninstantiable-start] :\n\
       \    script.ready(S, ENV,\n\
       \      commands.cons(command.uninstantiable(ID, M, IMPORTS), CMDS))\n\
       \    => script.uninstantiable(ID, ENV, CMDS, C)\n\
       \    if link.ok(EXPORTS) := linkImports(S, ENV, IMPORTS)\n\
       \       /\\ def.instantiate(S, M, EXPORTS) => C .\n\
       \  crl [assert-uninstantiable-step] :\n\
       \    script.uninstantiable(ID, ENV, CMDS, C)\n\
       \    => script.uninstantiable(ID, ENV, CMDS, C2)\n\
       \    if rel.step(C) => C2 .\n\
       \  rl [assert-uninstantiable-trap] :\n\
       \    script.uninstantiable(ID, ENV, CMDS,\n\
       \      config.sym(state.sym(S, rec.frame(LOCALS, CURRENT)), instr.trap))\n\
       \    => script.ready(S, ENV, CMDS) .\n\
       \  rl [assert-uninstantiable-exception] :\n\
       \    script.uninstantiable(ID, ENV, CMDS,\n\
       \      config.sym(state.sym(S, rec.frame(LOCALS, CURRENT)),\n\
       \        ref.ref-exn-addr(A) instr.throw-ref))\n\
       \    => script.ready(S, ENV, CMDS) .\n\
       \  rl [assert-uninstantiable-normal] :\n\
       \    script.uninstantiable(ID, ENV, CMDS,\n\
       \      config.sym(state.sym(S, rec.frame(LOCALS, CURRENT)), eps))\n\
       \    => script.wrong-assertion(ID) .\n\n\
       \  rl [call-return] :\n\
       \    script.ready(S, ENV,\n\
       \      commands.cons(\n\
       \        command.return(ID,\n\
       \          action.invoke(TARGET, NAME, ARGS), EXPECTED), CMDS))\n\
       \    => script.return(ID, ENV, EXPECTED, CMDS,\n\
       \      def.invoke(S, findFunc(value('EXPORTS,\n\
       \        findInstance(ENV, TARGET)), NAME), ARGS)) .\n\
       \  crl [get-return] :\n\
       \    script.ready(S, ENV,\n\
       \      commands.cons(command.return(ID,\n\
       \        action.get(TARGET, NAME), EXPECTED), CMDS))\n\
       \    => script.ready(S, ENV, CMDS)\n\
       \    if A := findGlobal(value('EXPORTS,\n\
       \         findInstance(ENV, TARGET)), NAME)\n\
       \       /\\ ACTUAL := helper.subtype-inject.step-pure(\n\
       \         value('VALUE, index(value('GLOBALS, S), A)))\n\
       \       /\\ match.values(ACTUAL, EXPECTED) = match.yes .\n\
       \  crl [get-wrong-result] :\n\
       \    script.ready(S, ENV,\n\
       \      commands.cons(command.return(ID,\n\
       \        action.get(TARGET, NAME), EXPECTED), CMDS))\n\
       \    => script.wrong-result(ID, ACTUAL, EXPECTED)\n\
       \    if A := findGlobal(value('EXPORTS,\n\
       \         findInstance(ENV, TARGET)), NAME)\n\
       \       /\\ ACTUAL := helper.subtype-inject.step-pure(\n\
       \         value('VALUE, index(value('GLOBALS, S), A)))\n\
       \       /\\ match.values(ACTUAL, EXPECTED) = match.no .\n\
       \  crl [return-step] : script.return(ID, ENV, EXPECTED, CMDS, C)\n\
       \    => script.return(ID, ENV, EXPECTED, CMDS, C2)\n\
       \    if rel.step(C) => C2 .\n\
       \  crl [return-done] :\n\
       \    script.return(ID, ENV, EXPECTED, CMDS,\n\
       \      config.sym(state.sym(S, rec.frame(LOCALS, CURRENT)), ACTUAL))\n\
       \    => script.ready(S, ENV, CMDS)\n\
       \    if runtimeResults(ACTUAL) = true\n\
       \       /\\ match.values(ACTUAL, EXPECTED) = match.yes .\n\
       \  crl [return-wrong-result] :\n\
       \    script.return(ID, ENV, EXPECTED, CMDS,\n\
       \      config.sym(state.sym(S, rec.frame(LOCALS, CURRENT)), ACTUAL))\n\
       \    => script.wrong-result(ID, ACTUAL, EXPECTED)\n\
       \    if runtimeResults(ACTUAL) = true\n\
       \       /\\ match.values(ACTUAL, EXPECTED) = match.no .\n\n\
       \  rl [call-trap] :\n\
       \    script.ready(S, ENV,\n\
       \      commands.cons(command.trap(ID,\n\
       \        action.invoke(TARGET, NAME, ARGS)), CMDS))\n\
       \    => script.trap(ID, ENV, CMDS,\n\
       \      def.invoke(S, findFunc(value('EXPORTS,\n\
       \        findInstance(ENV, TARGET)), NAME), ARGS)) .\n\
       \  crl [trap-step] : script.trap(ID, ENV, CMDS, C)\n\
       \    => script.trap(ID, ENV, CMDS, C2)\n\
       \    if rel.step(C) => C2 .\n\
       \  rl [trap-done] :\n\
       \    script.trap(ID, ENV, CMDS,\n\
       \      config.sym(state.sym(S, rec.frame(LOCALS, CURRENT)), instr.trap))\n\
       \    => script.ready(S, ENV, CMDS) .\n\n\
       \  rl [call-exception] :\n\
       \    script.ready(S, ENV,\n\
       \      commands.cons(command.exception(ID,\n\
       \        action.invoke(TARGET, NAME, ARGS)), CMDS))\n\
       \    => script.exception(ID, ENV, CMDS,\n\
       \      def.invoke(S, findFunc(value('EXPORTS,\n\
       \        findInstance(ENV, TARGET)), NAME), ARGS)) .\n\
       \  crl [exception-step] : script.exception(ID, ENV, CMDS, C)\n\
       \    => script.exception(ID, ENV, CMDS, C2)\n\
       \    if rel.step(C) => C2 .\n\
       \  rl [exception-done] :\n\
       \    script.exception(ID, ENV, CMDS,\n\
       \      config.sym(state.sym(S, rec.frame(LOCALS, CURRENT)),\n\
       \        ref.ref-exn-addr(A) instr.throw-ref))\n\
       \    => script.ready(S, ENV, CMDS) .\n\
       \  rl [exception-trap] :\n\
       \    script.exception(ID, ENV, CMDS,\n\
       \      config.sym(state.sym(S, rec.frame(LOCALS, CURRENT)), instr.trap))\n\
       \    => script.wrong-assertion(ID) .\n\
       \  crl [exception-normal] :\n\
       \    script.exception(ID, ENV, CMDS,\n\
       \      config.sym(state.sym(S, rec.frame(LOCALS, CURRENT)), ACTUAL))\n\
       \    => script.wrong-assertion(ID)\n\
       \    if runtimeResults(ACTUAL) = true .\n\n\
       \  rl [call-action] :\n\
       \    script.ready(S, ENV,\n\
       \      commands.cons(command.do(ID,\n\
       \        action.invoke(TARGET, NAME, ARGS)), CMDS))\n\
       \    => script.action(ID, ENV, CMDS,\n\
       \      def.invoke(S, findFunc(value('EXPORTS,\n\
       \        findInstance(ENV, TARGET)), NAME), ARGS)) .\n\
       \  crl [action-step] : script.action(ID, ENV, CMDS, C)\n\
       \    => script.action(ID, ENV, CMDS, C2)\n\
       \    if rel.step(C) => C2 .\n\
       \  crl [action-done] :\n\
       \    script.action(ID, ENV, CMDS,\n\
       \      config.sym(state.sym(S, rec.frame(LOCALS, CURRENT)), ACTUAL))\n\
       \    => script.ready(S, ENV, CMDS)\n\
       \    if runtimeResults(ACTUAL) = true .\n\
       \  crl [get-action] :\n\
       \    script.ready(S, ENV,\n\
       \      commands.cons(command.do(ID,\n\
       \        action.get(TARGET, NAME)), CMDS))\n\
       \    => script.ready(S, ENV, CMDS)\n\
       \    if A := findGlobal(value('EXPORTS,\n\
       \         findInstance(ENV, TARGET)), NAME)\n\
       \       /\\ ACTUAL := helper.subtype-inject.step-pure(\n\
       \         value('VALUE, index(value('GLOBALS, S), A))) .\n\n\
       \  rl [call-exhaustion] :\n\
       \    script.ready(S, ENV,\n\
       \      commands.cons(command.exhaustion(ID, REQUIRED,\n\
       \        action.invoke(TARGET, NAME, ARGS)), CMDS))\n\
       \    => script.exhaustion(ID, REQUIRED, ENV, CMDS,\n\
       \      def.invoke(S, findFunc(value('EXPORTS,\n\
       \        findInstance(ENV, TARGET)), NAME), ARGS)) .\n\
       \  crl [exhaustion-done] :\n\
       \    script.exhaustion(ID, REQUIRED, ENV, CMDS,\n\
       \      config.sym(state.sym(S, rec.frame(LOCALS, CURRENT)), BODY))\n\
       \    => script.ready(S, ENV, CMDS)\n\
       \    if rel.step(config.sym(\n\
       \         state.sym(S, rec.frame(LOCALS, CURRENT)), BODY))\n\
       \         => config.sym(C2, INSTRS)\n\
       \       /\\ _>_(activeFrameDepth(INSTRS), REQUIRED) = true .\n\
       \  crl [exhaustion-step] :\n\
       \    script.exhaustion(ID, REQUIRED, ENV, CMDS, C)\n\
       \    => script.exhaustion(ID, REQUIRED, ENV, CMDS,\n\
       \      config.sym(C2, INSTRS))\n\
       \    if rel.step(C) => config.sym(C2, INSTRS)\n\
       \       /\\ _<=_(activeFrameDepth(INSTRS), REQUIRED) = true .\n\
       \  rl [exhaustion-trap] :\n\
       \    script.exhaustion(ID, REQUIRED, ENV, CMDS,\n\
       \      config.sym(state.sym(S, rec.frame(LOCALS, CURRENT)), instr.trap))\n\
       \    => script.wrong-assertion(ID) .\n\
       \  rl [exhaustion-exception] :\n\
       \    script.exhaustion(ID, REQUIRED, ENV, CMDS,\n\
       \      config.sym(state.sym(S, rec.frame(LOCALS, CURRENT)),\n\
       \        ref.ref-exn-addr(A) instr.throw-ref))\n\
       \    => script.wrong-assertion(ID) .\n\
       \  crl [exhaustion-normal] :\n\
       \    script.exhaustion(ID, REQUIRED, ENV, CMDS,\n\
       \      config.sym(state.sym(S, rec.frame(LOCALS, CURRENT)), ACTUAL))\n\
       \    => script.wrong-assertion(ID)\n\
       \    if runtimeResults(ACTUAL) = true .\n\n\
       \  rl [done] : script.ready(S, ENV, commands.nil) => script.done .\n\
       endm\n\n\
       rew [%d] in WASM2MAUDE-WAST : script.start .\n"
      semantics commands host_store host_functions host_instances steps
