#!/usr/bin/env python3
"""Concrete-sample probe every rl/crl in output_bs.maude.

This complements audit_output_bs_rules.py.  The symbolic audit asks Maude to
find witnesses for open terms.  This script instead substitutes generated
variables with small, concrete sample terms based on their declared sort/name,
then asks whether the instantiated LHS rewrites to the instantiated RHS.

It is still an audit, not a proof over all possible inputs.  A failed concrete
sample means "the generated sample did not exercise this rule"; a stack
overflow or Maude error is a stronger lead.
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import subprocess
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MAUDE = Path("/Users/minsung/Dev/tools/Maude-3.5.1-macos-x86_64/maude")

TOKEN_CHARS = r"A-Za-z0-9_$'\-*"


SAMPLE_MODULE = r"""
load wasm-exec-bs

mod C1-RULE-CONCRETE-SAMPLES is
  inc WASM-FIB-BS .

  op C0 : -> Context .
  eq C0 = RECContextA13(eps, eps, eps, eps, eps, eps, eps, eps, eps, eps, eps, eps, eps) .

  op C1 : -> Context .
  eq C1 = RECContextA13(eps, eps, eps, eps, eps, eps, eps, eps, eps, CTORI32A0, eps, eps, eps) .

  op C2 : -> Context .
  op C3 : -> Context .

  op ST0 : -> State .
  eq ST0 = fib-store ; empty-frame .

  op S-ELEM0 : -> Store .
  eq S-ELEM0 =
    RECStoreA10(eps, eps, eps, eps, eps, eps,
      RECEleminstA2(REF0, CTORREFI31NUMA1(7)),
      eps, eps, eps) .

  op MI-ELEM0 : -> Moduleinst .
  eq MI-ELEM0 =
    RECModuleinstA9(eps, eps, eps, eps, eps, eps, eps, 0, eps) .

  op Z-ELEM0 : -> State .
  eq Z-ELEM0 = S-ELEM0 ; RECFrameA2(eps, MI-ELEM0) .

  op CFG0 : -> Config .
  eq CFG0 = ST0 ; CTORNOPA0 .

  op FR0 : -> Frame .
  eq FR0 = empty-frame .

  op MI0 : -> Moduleinst .
  eq MI0 = fib-moduleinst .

  op MOD0 : -> Module .
  eq MOD0 = fib-module .

  op I32VAL0 : -> Val .
  eq I32VAL0 = CTORCONSTA2(CTORI32A0, 0) .

  op I32VAL1 : -> Val .
  eq I32VAL1 = CTORCONSTA2(CTORI32A0, 1) .

  op INSTR0 : -> Instr .
  eq INSTR0 = CTORNOPA0 .

  op INSTR1 : -> Instr .
  eq INSTR1 = CTORCONSTA2(CTORI32A0, 0) .

  op EXPR0 : -> Expr .
  eq EXPR0 = CTORNOPA0 .

  op ARROW0 : -> Instrtype .
  eq ARROW0 = CTORARROWA3(eps, eps, eps) .

  op ARROW1 : -> Instrtype .
  eq ARROW1 = CTORARROWA3(eps, eps, CTORI32A0) .

  op REF0 : -> Reftype .
  eq REF0 = CTORREFA2(eps, CTORI31A0) .

  op BLOCKTYPE0 : -> Blocktype .
  eq BLOCKTYPE0 = CTORWRESULTA1(eps) .

  op TYPEUSE0 : -> Typeuse .
  eq TYPEUSE0 = CTORWIDXA1(0) .

  op LIMITS0 : -> Limits .
  eq LIMITS0 = CTORLBRACKDOTDOTRBRACKA2(0, eps) .

  op MEMARG0 : -> Memarg .
  eq MEMARG0 = {item('ALIGN, 0) ; item('OFFSET, 0)} .

  eq C2 =
    RECContextA13(
      fib-type,                  --- TYPES
      eps,                       --- RECS
      TYPEUSE0,                  --- TAGS
      eps CTORI32A0,             --- GLOBALS
      CTORPAGEA2(CTORI32A0, LIMITS0), --- MEMS
      CTORI32A0 LIMITS0 REF0,    --- TABLES
      fib-type,                  --- FUNCS
      CTOROKA0,                  --- DATAS
      REF0,                      --- ELEMS
      CTORSETA0 CTORI32A0,       --- LOCALS
      CTORI32A0,                 --- LABELS
      CTORI32A0,                 --- RETURN
      0) .                       --- REFS

  op DT-FUNC0 : -> Deftype .
  eq DT-FUNC0 = CTORWDEFA2(CTORRECA1(CTORSUBA3(CTORFINALA0, eps, CTORFUNCARROWA2(eps, eps))), 0) .

  op DT-STRUCT0 : -> Deftype .
  eq DT-STRUCT0 = CTORWDEFA2(CTORRECA1(CTORSUBA3(CTORFINALA0, eps, CTORSTRUCTA1(eps CTORI32A0))), 0) .

  op DT-ARRAY0 : -> Deftype .
  eq DT-ARRAY0 = CTORWDEFA2(CTORRECA1(CTORSUBA3(CTORFINALA0, eps, CTORARRAYA1(eps CTORI32A0))), 0) .

  eq C3 =
    RECContextA13(
      DT-FUNC0 DT-STRUCT0 DT-ARRAY0, --- TYPES
      CTORSUBA3(CTORFINALA0, eps, CTORFUNCARROWA2(eps, eps)), --- RECS
      DT-FUNC0,                  --- TAGS
      eps CTORI32A0 CTORMUTA0 CTORI32A0, --- GLOBALS
      CTORPAGEA2(CTORI32A0, LIMITS0), --- MEMS
      CTORI32A0 LIMITS0 REF0,    --- TABLES
      DT-FUNC0,                  --- FUNCS
      CTOROKA0,                  --- DATAS
      REF0,                      --- ELEMS
      CTORSETA0 CTORI32A0,       --- LOCALS
      CTORI32A0,                 --- LABELS
      CTORI32A0,                 --- RETURN
      0) .                       --- REFS
endm
"""


@dataclass
class Rule:
    line: int
    kind: str
    label: str
    statement: str
    lhs: str
    rhs: str
    vars: dict[str, str]


def maude_bin() -> str:
    env = os.environ.get("MAUDE_BIN")
    if env:
        return env
    if DEFAULT_MAUDE.exists():
        return str(DEFAULT_MAUDE)
    return "maude"


def normalize(s: str) -> str:
    return re.sub(r"\s+", " ", s.strip())


def parse_rules(path: Path) -> list[Rule]:
    lines = path.read_text().splitlines()
    rules: list[Rule] = []
    i = 0
    start_re = re.compile(r"^\s*(rl|crl)\s+\[([^\]]+)\]\s*:")
    while i < len(lines):
        m = start_re.match(lines[i])
        if not m:
            i += 1
            continue
        start = i
        chunks = [lines[i]]
        i += 1
        while i < len(lines):
            chunks.append(lines[i])
            if lines[i].strip().endswith("."):
                break
            i += 1
        stmt = "\n".join(chunks)
        body = stmt.split(":", 1)[1].strip()
        if body.endswith("."):
            body = body[:-1].strip()
        lhs, rhs = body, ""
        if "=>" in body:
            lhs, rhs_cond = body.split("=>", 1)
            parts = re.split(r"\n\s+if\s+|\s+if\s+", rhs_cond, maxsplit=1)
            rhs = parts[0]
        rules.append(
            Rule(
                line=start + 1,
                kind=m.group(1),
                label=m.group(2),
                statement=stmt,
                lhs=normalize(lhs),
                rhs=normalize(rhs),
                vars={},
            )
        )
        i += 1
    return rules


def parse_vars(path: Path) -> dict[str, str]:
    text = path.read_text()
    vars_by_name: dict[str, str] = {}
    # Generated declarations are one-line var/vars statements.
    for m in re.finditer(r"^\s*vars?\s+(.+?)\s*:\s*([A-Za-z][A-Za-z0-9-]*)\s*\.\s*$", text, re.M):
        names, sort = m.group(1), m.group(2)
        for name in names.split():
            vars_by_name[name] = sort
    return vars_by_name


def family_of(label: str) -> str:
    if label.startswith("step-from-step-pure-"):
        return "NON_C1_FINAL_STEP_PURE_LIFT"
    if label.startswith("$exec-") or "exec-tail-empty" in label:
        return "VALIDATION_EXECUTION_OVERLAY"
    if label.startswith("$iter-"):
        return "RELATION_STAR_META_LOWERING"
    if label.startswith("step"):
        return "EXECUTION_STEP"
    if label.startswith("eval-"):
        return "EVAL"
    if label.startswith(
        (
            "numtype-",
            "vectype-",
            "heaptype-",
            "reftype-",
            "valtype-",
            "resulttype-",
            "instrtype-",
            "instr-ok-",
            "instrs-ok-",
            "expr-",
            "module-",
            "func-",
            "externaddr-",
            "ref-ok-",
            "global-",
            "type-",
            "types-",
            "export-",
            "import-",
            "start-",
            "table-",
            "mem-",
            "tag-",
            "data-",
            "elem-",
        )
    ):
        return "SOURCE_RELATION_RULE"
    return "SOURCE_OR_DEF_RULE"


def name_hint(name: str) -> str:
    return name.upper().replace("-", "_")


def semantic_hint(name: str) -> str:
    """Return the source-ish suffix of a generated variable name.

    Generated variables include the whole rule label, e.g.
    INSTR-OK-BR-ON-NULL12-RT.  Looking at the full name makes every variable in
    an Instr-ok rule look instruction-like.  The right sampling cue is usually
    the final source binder fragment, such as RT, TS1, INSTRS, X, or BT.
    """

    pieces = [p for p in re.split(r"[-_]+", name.upper()) if p]
    if not pieces:
        return name_hint(name)
    tail = pieces[-1]
    tail = re.sub(r"^[0-9]+", "", tail)
    tail = re.sub(r"[0-9]+$", "", tail)
    if tail:
        return tail
    return pieces[-1]


def candidates_for(name: str, sort: str) -> list[str]:
    n = name_hint(name)
    h = semantic_hint(name)
    scalar_index = ["0", "1"]
    nu = name.upper()
    if "MEMARG-OK" in nu:
        if h in {"LOWN", "ALIGN"}:
            return ["0", "1"]
        if h in {"LOWM", "OFFSET"}:
            return ["0", "1"]
        if h == "N":
            return ["32", "8", "16"]
    # Val-ok/Val-oks are easy to mis-sample because the generated relation
    # operator is intentionally broad (SpectecTerminals, SpectecTerminals,
    # SpectecTerminals).  Use the source-rule provenance in the variable name:
    # value-side binders get concrete values; type-side binders get value types.
    if "VAL-OK" in nu or "VAL_OKS" in nu:
        if sort == "SpectecTerminals":
            if h in {"LOWS", "S"} or n.endswith("_A0"):
                return ["fib-store", "C3", "ST0"]
            if h in {"NUM", "VEC", "REF", "LOWV", "V", "VAL", "VALS"} or re.search(r"VAL_OKS-.*U1", nu):
                return [
                    "CTORCONSTA2(CTORI32A0, 0)",
                    "CTORCONSTA2(CTORI32A0, 1)",
                    "CTORVCONSTA2(CTORV128A0, 0)",
                    "CTORREFNULLA1(CTORI31A0)",
                ]
            if h in {"NT", "VT", "RT", "LOWT", "T", "TYPE", "TYP"} or re.search(r"VAL_OKS-.*U2", nu):
                return [
                    "CTORI32A0",
                    "CTORV128A0",
                    "CTORREFA2(CTORNULLA0, CTORI31A0)",
                    "REF0",
                ]
    # Source-star lowering helper variables are intentionally broad in the
    # generated Maude.  Their generated names still carry the relation family,
    # so use that provenance to avoid nonsensical samples such as
    # Valtype-oks(eps, ...).
    if sort == "SpectecTerminals" and n.endswith("_A0"):
        if any(prefix in nu for prefix in ["VAL_OKS", "REF_OKS", "EXTERNADDR_OKS"]):
            return ["fib-store", "ST0", "C3"]
        return ["C3", "C2", "C0", "fib-store"]
    if "ARRAY-NEW-ELEM" in name.upper() and h == "N":
        return ["1", "0"]
    if sort in {"Nat", "Int", "N", "M", "K", "Idx", "Typeidx", "Funcidx", "Localidx", "Labelidx", "Globalidx", "Tableidx", "Memidx", "Tagidx", "Elemidx", "Dataidx", "Fieldidx", "Addr", "Funcaddr", "Externaddr", "Tableaddr", "Memaddr", "Globaladdr", "Tagaddr", "Elemaddr", "Dataaddr", "Arrayaddr", "Structaddr", "Exnaddr", "Hostaddr", "Laneidx", "U32", "U64", "U31"}:
        if h in {"N", "M", "K", "SZ"}:
            return ["0", "1", "8", "16", "32"]
        return scalar_index
    if sort == "Bool":
        return ["true", "false"]
    if sort == "Num":
        return ["CTORCONSTA2(CTORI32A0, 0)", "CTORCONSTA2(CTORI32A0, 1)"]
    if sort == "Vec":
        return ["CTORVCONSTA2(CTORV128A0, 0)"]
    if sort == "Sx":
        return ["CTORUA0", "CTORSA0"]
    if sort == "Shape":
        return ["CTORXA2(CTORI32A0, 4)", "CTORXA2(CTORI8A0, 16)"]
    if sort == "Vvunop":
        return ["CTORWNOTA0"]
    if sort == "Vvbinop":
        return ["CTORWANDA0", "CTORWORA0", "CTORXORA0"]
    if sort == "Vvternop":
        return ["CTORBITSELECTA0"]
    if sort == "Vvtestop":
        return ["CTORANYTRUEA0"]
    if sort == "Context":
        return ["C3", "C2", "C0", "C1"]
    if sort == "Store":
        return ["fib-store"]
    if sort == "Frame":
        return ["FR0", "RECFrameA2(eps, MI0)"]
    if sort == "State":
        if "ARRAY-NEW-ELEM" in name.upper():
            return ["Z-ELEM0", "ST0"]
        return ["ST0"]
    if sort == "Config":
        return ["CFG0"]
    if sort == "Moduleinst":
        return ["MI0"]
    if sort == "Module":
        return ["MOD0"]
    if sort == "Val":
        return ["I32VAL0", "I32VAL1"]
    if sort == "Ref":
        return ["CTORREFNULLA1(CTORI31A0)", "CTORREFI31NUMA1(7)", "CTORREFFUNCADDRA1(0)"]
    if sort == "Instr":
        return ["INSTR0", "INSTR1"]
    if sort == "Expr":
        return ["EXPR0", "INSTR1"]
    if sort == "Numtype":
        return ["CTORI32A0", "CTORI64A0"]
    if sort == "Vectype":
        return ["CTORV128A0"]
    if sort == "Packtype":
        return ["CTORI8A0", "CTORI16A0"]
    if sort == "Lanetype":
        return ["CTORI32A0", "CTORI8A0", "CTORV128A0"]
    if sort == "Storagetype":
        return ["CTORI32A0", "CTORI8A0", "REF0"]
    if sort == "Consttype":
        return ["CTORI32A0", "CTORV128A0"]
    if sort == "Absheaptype":
        return ["CTORANYA0", "CTORWEQA0", "CTORI31A0", "CTORSTRUCTA0", "CTORARRAYA0", "CTORFUNCA0", "CTOREXTERNA0"]
    if sort == "Heaptype":
        return ["CTORI31A0", "CTORWEQA0", "CTORANYA0", "CTORWIDXA1(0)", "CTORRECA1(0)"]
    if sort == "Reftype":
        return ["REF0", "CTORREFA2(CTORNULLA0, CTORI31A0)", "CTORREFA2(eps, CTORI31A0)"]
    if sort == "Valtype":
        return ["CTORI32A0", "REF0"]
    if sort == "Resulttype":
        return ["eps", "CTORI32A0"]
    if sort == "Instrtype":
        return ["ARROW0", "ARROW1"]
    if sort == "Blocktype":
        return ["BLOCKTYPE0"]
    if sort == "Typeuse":
        return ["TYPEUSE0"]
    if sort == "Limits":
        return ["LIMITS0"]
    if sort == "Memarg":
        return ["MEMARG0"]
    if sort == "Fieldtype":
        return ["eps CTORI32A0", "CTORMUTA0 CTORI32A0", "eps CTORI8A0"]
    if sort == "Comptype":
        return ["CTORFUNCARROWA2(eps, eps)", "CTORSTRUCTA1(eps CTORI32A0)", "CTORARRAYA1(eps CTORI32A0)"]
    if sort == "Subtype":
        return ["CTORSUBA3(CTORFINALA0, eps, CTORFUNCARROWA2(eps, eps))", "CTORSUBA3(CTORFINALA0, eps, CTORSTRUCTA1(eps CTORI32A0))"]
    if sort == "Rectype":
        return ["CTORRECA1(eps)", "CTORRECA1(CTORSUBA3(CTORFINALA0, eps, CTORFUNCARROWA2(eps, eps)))"]
    if sort == "Deftype":
        return ["DT-FUNC0", "fib-type", "DT-STRUCT0", "DT-ARRAY0"]
    if sort == "Type":
        return ["CTORTYPEA1(CTORRECA1(eps))", "CTORTYPEA1(CTORRECA1(CTORSUBA3(CTORFINALA0, eps, CTORFUNCARROWA2(eps, eps))))"]
    if sort == "Tagtype":
        return ["DT-FUNC0", "TYPEUSE0"]
    if sort == "Datatype":
        return ["CTOROKA0"]
    if sort == "Elemtype":
        return ["REF0"]
    if sort == "Local":
        return ["CTORLOCALA1(CTORI32A0)"]
    if sort == "Localtype":
        return ["CTORSETA0 CTORI32A0"]
    if sort == "Global":
        return ["CTORGLOBALA2(eps CTORI32A0, CTORCONSTA2(CTORI32A0, 0))"]
    if sort == "Mem":
        return ["CTORMEMORYA1(CTORPAGEA2(CTORI32A0, LIMITS0))"]
    if sort == "Table":
        return ["CTORTABLEA2(CTORI32A0 LIMITS0 REF0, CTORREFNULLA1(CTORI31A0))"]
    if sort == "Data":
        return ["CTORDATAA2(eps, CTORPASSIVEA0)"]
    if sort == "Elem":
        return ["CTORELEMA3(REF0, eps, CTORPASSIVEA0)"]
    if sort == "Start":
        return ["CTORSTARTA1(0)", "eps"]
    if sort == "Import":
        return ["CTORIMPORTA3(0, 0, CTORFUNCA1(DT-FUNC0))"]
    if sort == "Export":
        return ["CTOREXPORTA2(0, CTORFUNCA1(0))"]
    if sort == "Func":
        return ["CTORFUNCA3(0, eps, CTORCONSTA2(CTORI32A0, 0))"]
    if sort == "Module":
        return ["MOD0", "CTORMODULEA11(eps, eps, eps, eps, eps, eps, eps, eps, eps, eps, eps)"]
    if sort == "Catch":
        return ["CTORCATCHALLA1(0)", "CTORCATCHA2(0, 0)"]
    if sort == "Globaltype":
        return ["eps CTORI32A0", "CTORMUTA0 CTORI32A0"]
    if sort == "Tabletype":
        return ["CTORI32A0 LIMITS0 REF0"]
    if sort == "Memtype":
        return ["CTORPAGEA2(CTORI32A0, LIMITS0)"]
    if sort == "Externtype":
        return ["CTORFUNCA1(TYPEUSE0)", "CTORGLOBALA1(eps CTORI32A0)"]
    if sort == "Externidx":
        return ["CTORFUNCA1(0)", "CTORGLOBALA1(0)"]
    if sort == "Externaddr":
        return ["CTORFUNCA1(0)", "CTORGLOBALA1(0)"]

    if sort == "SpectecTerminals":
        if "VAL_OKS" in nu:
            if re.search(r"VAL_OKS-.*(R1|U1)", nu):
                return ["eps", "CTORCONSTA2(CTORI32A0, 0)", "CTORCONSTA2(CTORI32A0, 0) CTORCONSTA2(CTORI32A0, 1)"]
            if re.search(r"VAL_OKS-.*(R2|U2)", nu):
                return ["eps", "CTORI32A0", "CTORI32A0 CTORI32A0"]
        if "EXPR-OK-CONST" in name.upper() and h in {"EXPR", "EXPRS"}:
            return ["CTORCONSTA2(CTORI32A0, 0)", "CTORREFNULLA1(CTORI31A0)", "eps"]
        if h in {"PACKTYPE", "PACKTYPES", "PT"}:
            return ["CTORI8A0", "CTORI16A0", "eps"]
        if h in {"FIELD", "FIELDS", "FIELDTYPE", "FIELDTYPES", "FT", "FTS", "ZT", "ZTS"}:
            return ["eps CTORI32A0", "CTORMUTA0 CTORI32A0", "eps"]
        if h in {"COMPTYPE", "COMPTYPES", "CT", "CTS"}:
            return ["CTORFUNCARROWA2(eps, eps)", "CTORSTRUCTA1(eps CTORI32A0)", "eps"]
        if h in {"SUBTYPE", "SUBTYPES", "ST", "STS"}:
            return ["CTORSUBA3(CTORFINALA0, eps, CTORFUNCARROWA2(eps, eps))", "eps"]
        if h in {"RECTYPE", "RECTYPES"}:
            return ["CTORRECA1(eps)", "CTORRECA1(CTORSUBA3(CTORFINALA0, eps, CTORFUNCARROWA2(eps, eps)))"]
        if h in {"TYPE", "TYPES"}:
            return ["CTORTYPEA1(CTORRECA1(eps))", "eps"]
        if h in {"TAGTYPE", "TAGTYPES", "JT", "JTS"}:
            return ["DT-FUNC0", "TYPEUSE0", "eps"]
        if h in {"LOCAL", "LOCALS", "LOCALTYPE", "LOCALTYPES"}:
            return ["CTORLOCALA1(CTORI32A0)", "CTORSETA0 CTORI32A0", "eps"]
        if h in {"GLOBAL", "GLOBALS"}:
            return ["CTORGLOBALA2(eps CTORI32A0, CTORCONSTA2(CTORI32A0, 0))", "eps"]
        if h in {"MEM", "MEMS"}:
            return ["CTORMEMORYA1(CTORPAGEA2(CTORI32A0, LIMITS0))", "eps"]
        if h in {"TABLE", "TABLES"}:
            return ["CTORTABLEA2(CTORI32A0 LIMITS0 REF0, CTORREFNULLA1(CTORI31A0))", "eps"]
        if h in {"DATA", "DATAS"}:
            return ["CTORDATAA2(eps, CTORPASSIVEA0)", "eps"]
        if h in {"ELEM", "ELEMS"}:
            return ["CTORELEMA3(REF0, eps, CTORPASSIVEA0)", "eps"]
        if h in {"START", "STARTS"}:
            return ["CTORSTARTA1(0)", "eps"]
        if h in {"IMPORT", "IMPORTS"}:
            return ["CTORIMPORTA3(0, 0, CTORFUNCA1(DT-FUNC0))", "eps"]
        if h in {"EXPORT", "EXPORTS"}:
            return ["CTOREXPORTA2(0, CTORFUNCA1(0))", "eps"]
        if h in {"FUNC", "FUNCS"}:
            return ["CTORFUNCA3(0, eps, CTORCONSTA2(CTORI32A0, 0))", "eps"]
        if h in {"CATCH", "CATCHS"}:
            return ["CTORCATCHALLA1(0)", "CTORCATCHA2(0, 0)", "eps"]
        if h in {"INSTRS", "INSTRSQ", "EXPR", "EXPRS", "CODE", "BODY"}:
            return ["INSTR0", "INSTR1", "eps"]
        if h in {"VVUNOP"}:
            return ["CTORWNOTA0"]
        if h in {"VVBINOP"}:
            return ["CTORWANDA0", "CTORWORA0"]
        if h in {"VVTERNOP"}:
            return ["CTORBITSELECTA0"]
        if h in {"VVTESTOP"}:
            return ["CTORANYTRUEA0"]
        if h in {"VUNOP"}:
            return ["CTORABSA0", "CTORNEGA0", "CTORPOPCNTA0"]
        if h in {"VBINOP"}:
            return ["CTORADDA0", "CTORSUBA0", "CTORMULA0"]
        if h in {"VTERNOP"}:
            return ["CTORBITSELECTA0"]
        if h in {"VTESTOP"}:
            return ["CTORANYTRUEA0"]
        if h in {"VRELOP"}:
            return ["CTORWEQA0", "CTORNEA0"]
        if h in {"VSHIFTOP"}:
            return ["CTORSHLA0", "CTORSHRA1(CTORUA0)"]
        if h in {"SH", "SHAPE"}:
            return ["CTORXA2(CTORI32A0, 4)", "CTORXA2(CTORI8A0, 16)"]
        if h in {"VAL", "VALS", "VALSQ", "V", "VS"}:
            return ["I32VAL0", "I32VAL0 I32VAL1", "eps"]
        if h in {"RT", "RTS", "REFTYPE", "REFTYPES"}:
            return ["REF0", "CTORREFA2(CTORNULLA0, CTORFUNCA0)", "eps"]
        if h in {"BT", "BLOCKTYPE"}:
            return ["BLOCKTYPE0", "eps"]
        if h in {"IT", "ITQ", "INSTRTYPE"}:
            return ["ARROW0", "ARROW1"]
        if h in {"DT", "DTS", "DEFTYPE", "DEFTYPES"}:
            return ["DT-FUNC0", "fib-type", "eps"]
        if h in {"TYPEUSE", "TYPEUSES", "TU", "TUS"}:
            return ["TYPEUSE0", "eps"]
        if h in {"GT", "GTS", "GLOBALTYPE", "GLOBALTYPES"}:
            return ["eps CTORI32A0", "CTORMUTA0 CTORI32A0", "eps"]
        if h in {"MT", "MTS", "MEMTYPE", "MEMTYPES"}:
            return ["CTORPAGEA2(CTORI32A0, LIMITS0)", "eps"]
        if h in {"TT", "TTS", "TABLETYPE", "TABLETYPES"}:
            return ["CTORI32A0 LIMITS0 REF0", "eps"]
        if h in {"T", "TQ", "TS", "TSQ", "RESULT", "RESULTTYPE", "PARAMS"}:
            return ["eps", "CTORI32A0", "CTORI32A0 CTORI32A0"]
        if h in {"IDX", "IDXS", "XS", "X", "Y", "I", "J", "L", "IS", "LABEL", "LABELS", "LOCAL", "LOCALS", "REFS"}:
            return ["eps", "0", "0 1"]
        return ["eps", "CTORI32A0", "INSTR0"]

    if sort == "SpectecTerminal":
        if "VAL_OKS" in nu:
            if re.search(r"VAL_OKS-.*(E1|U1)", nu):
                return ["CTORCONSTA2(CTORI32A0, 0)", "CTORCONSTA2(CTORI32A0, 1)"]
            if re.search(r"VAL_OKS-.*(E2|U2)", nu):
                return ["CTORI32A0", "CTORV128A0", "REF0"]
        if "VAL-OK" in nu:
            if h in {"NUM", "LOWN"}:
                return ["CTORCONSTA2(CTORI32A0, 0)", "CTORCONSTA2(CTORI32A0, 1)"]
            if h == "VEC":
                return ["CTORVCONSTA2(CTORV128A0, 0)"]
            if h == "REF":
                return ["CTORREFNULLA1(CTORI31A0)", "CTORREFI31NUMA1(7)"]
        if "EXPR-OK-CONST" in name.upper() and h in {"EXPR", "EXPRS"}:
            return ["CTORCONSTA2(CTORI32A0, 0)", "CTORREFNULLA1(CTORI31A0)"]
        if h in {"PACKTYPE", "PT"}:
            return ["CTORI8A0", "CTORI16A0"]
        if h in {"FIELD", "FIELDTYPE", "FT", "ZT"}:
            return ["eps CTORI32A0", "CTORMUTA0 CTORI32A0"]
        if h in {"COMPTYPE", "CT"}:
            return ["CTORFUNCARROWA2(eps, eps)", "CTORSTRUCTA1(eps CTORI32A0)"]
        if h in {"SUBTYPE", "ST"}:
            return ["CTORSUBA3(CTORFINALA0, eps, CTORFUNCARROWA2(eps, eps))"]
        if h in {"RECTYPE"}:
            return ["CTORRECA1(eps)", "CTORRECA1(CTORSUBA3(CTORFINALA0, eps, CTORFUNCARROWA2(eps, eps)))"]
        if h in {"TAGTYPE", "JT"}:
            return ["DT-FUNC0", "TYPEUSE0"]
        if h in {"C", "CTX"} or n.endswith("_C") or n.endswith("-C"):
            return ["C3", "C2", "C0", "C1"]
        if h in {"INSTR", "INSTRQ", "INSTR1", "INSTR2", "EXPR", "CODE", "BODY"}:
            return ["INSTR0", "INSTR1", "CTORI32A0"]
        if h in {"REF"}:
            return ["CTORREFNULLA1(CTORI31A0)", "CTORREFI31NUMA1(7)", "CTORREFFUNCADDRA1(0)"]
        if h in {"VVUNOP"}:
            return ["CTORWNOTA0"]
        if h in {"VVBINOP"}:
            return ["CTORWANDA0", "CTORWORA0"]
        if h in {"VVTERNOP"}:
            return ["CTORBITSELECTA0"]
        if h in {"VVTESTOP"}:
            return ["CTORANYTRUEA0"]
        if h in {"VUNOP"}:
            return ["CTORABSA0", "CTORNEGA0", "CTORPOPCNTA0"]
        if h in {"VBINOP"}:
            return ["CTORADDA0", "CTORSUBA0", "CTORMULA0"]
        if h in {"VTERNOP"}:
            return ["CTORBITSELECTA0"]
        if h in {"VTESTOP"}:
            return ["CTORANYTRUEA0"]
        if h in {"VRELOP"}:
            return ["CTORWEQA0", "CTORNEA0"]
        if h in {"VSHIFTOP"}:
            return ["CTORSHLA0", "CTORSHRA1(CTORUA0)"]
        if h in {"SH", "SHAPE"}:
            return ["CTORXA2(CTORI32A0, 4)", "CTORXA2(CTORI8A0, 16)"]
        if h in {"VAL", "VALQ", "V", "VQ", "CONST"}:
            return ["I32VAL0", "CTORI32A0", "0"]
        if h in {"TYPEUSE", "TU", "YY"}:
            return ["TYPEUSE0", "CTORI32A0"]
        if h in {"RT", "RTQ", "REFTYPE"}:
            return ["REF0", "CTORI32A0"]
        if h in {"HT", "HTQ", "HEAPTYPE"}:
            return ["CTORI31A0", "CTORWEQA0"]
        if h in {"BT", "BLOCKTYPE"}:
            return ["BLOCKTYPE0", "CTORI32A0"]
        if h in {"IT", "ITQ", "INSTRTYPE"}:
            return ["ARROW0", "ARROW1"]
        if h in {"DT", "DTQ", "DTN", "DEFTYPE"}:
            return ["DT-FUNC0", "fib-type", "CTORI32A0"]
        if h == "TYPE" and "ALLOCTYPES" in name.upper():
            return ["fib-source-type", "CTORI32A0"]
        if h in {"GT", "GTQ", "GLOBALTYPE"}:
            return ["eps CTORI32A0", "CTORMUTA0 CTORI32A0"]
        if h in {"MT", "MTQ", "MEMTYPE"}:
            return ["CTORPAGEA2(CTORI32A0, LIMITS0)", "CTORI32A0"]
        if h in {"TT", "TTQ", "TABLETYPE"}:
            return ["CTORI32A0 LIMITS0 REF0", "CTORI32A0"]
        if h in {"LIM", "LIMITS"}:
            return ["LIMITS0", "eps"]
        if h in {"AT", "ADDRTYPE"}:
            return ["CTORI32A0", "CTORI64A0"]
        if h in {"NT", "NUMTYPE", "VT", "VALTYPE", "TYPE", "T", "TQ", "T1", "T2", "ZT"}:
            return ["CTORI32A0", "eps"]
        if h in {"IDX", "ADDR", "X", "Y", "I", "J", "L", "N", "M", "K", "A"}:
            return ["0", "1", "8", "16", "32", "CTORI32A0"]
        return ["CTORI32A0", "0", "eps"]

    # For source categories not listed above, try common representatives.
    return ["CTORI32A0", "0", "eps"]


def variable_names_in(term: str, vars_by_name: dict[str, str]) -> list[str]:
    names = []
    for name in vars_by_name:
        pattern = rf"(?<![{TOKEN_CHARS}]){re.escape(name)}(?![{TOKEN_CHARS}])"
        if re.search(pattern, term):
            names.append(name)
    return sorted(names, key=len, reverse=True)


def instantiate(term: str, subst: dict[str, str]) -> str:
    out = term
    for name in sorted(subst, key=len, reverse=True):
        pattern = rf"(?<![{TOKEN_CHARS}]){re.escape(name)}(?![{TOKEN_CHARS}])"
        out = re.sub(pattern, subst[name], out)
    return out


def substitutions_for(rule: Rule, vars_by_name: dict[str, str], max_variants: int) -> list[dict[str, str]]:
    names = variable_names_in(rule.lhs + " " + rule.rhs, vars_by_name)
    if not names:
        return [{}]
    variants: list[dict[str, str]] = []
    baseline: dict[str, str] = {}
    cand_map: dict[str, list[str]] = {}
    for name in names:
        cands = candidates_for(name, vars_by_name[name])
        cand_map[name] = cands
        baseline[name] = cands[0]
    variants.append(baseline)
    for k in range(max_variants):
        subst: dict[str, str] = {}
        for name in names:
            cands = cand_map[name]
            subst[name] = cands[min(k, len(cands) - 1)]
        variants.append(subst)
    # One-variable-at-a-time variants catch common source-valid combinations
    # such as X = 1 while the result type T remains i32.  The old all-k variant
    # missed these and made many rule probes look stuck for purely sample
    # reasons.
    for name in names:
        cands = cand_map[name]
        for k in range(1, min(max_variants, len(cands))):
            subst = dict(baseline)
            subst[name] = cands[k]
            variants.append(subst)
    # A final "empty-ish" variant often helps source rules with star premises.
    emptyish: dict[str, str] = {}
    for name in names:
        sort = vars_by_name[name]
        if sort == "SpectecTerminals" or sort in {"Resulttype"}:
            emptyish[name] = "eps"
        else:
            emptyish[name] = candidates_for(name, sort)[0]
    variants.append(emptyish)
    # Deduplicate while preserving order.
    seen = set()
    uniq = []
    for subst in variants:
        key = tuple(sorted(subst.items()))
        if key not in seen:
            seen.add(key)
            uniq.append(subst)
    return uniq


def result_payload(output: str) -> str:
    marker = "\nresult "
    pos = output.rfind(marker)
    if pos < 0:
        if output.startswith("result "):
            pos = 0
        else:
            return ""
    tail = output[pos:].strip()
    colon = tail.find(":")
    if colon < 0:
        return ""
    payload = tail[colon + 1 :].strip()
    # Drop the next prompt/command if Maude prints one after the result.
    payload = re.split(r"\nMaude>|\nBye\.", payload, maxsplit=1)[0].strip()
    return normalize(payload)


def top_head(term: str) -> str:
    term = normalize(term)
    m = re.match(r"\(?\s*([A-Za-z_$][A-Za-z0-9_$'\\-]*)\s*\(", term)
    if m:
        return m.group(1)
    return ""


def run_probe(rule: Rule, subst: dict[str, str], out_dir: Path, timeout: int, variant: int, mode: str) -> tuple[str, str]:
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", rule.label)[:120]
    probe_dir = out_dir / "rule-probes"
    log_dir = out_dir / "rule-logs"
    probe_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)
    lhs = instantiate(rule.lhs, subst)
    rhs = instantiate(rule.rhs, subst)
    probe_file = probe_dir / f"{rule.line:05d}-{safe}-{mode}-v{variant}.maude"
    log_file = log_dir / f"{rule.line:05d}-{safe}-{mode}-v{variant}.log"
    if mode == "exact":
        text = (
            SAMPLE_MODULE
            + "\n"
            + "search [1] in C1-RULE-CONCRETE-SAMPLES :\n"
            + f"  ({lhs})\n"
            + f"  =>+ ({rhs}) .\n"
            + "q\n"
        )
    elif mode == "rewrite":
        text = (
            SAMPLE_MODULE
            + "\n"
            + "rew [100] in C1-RULE-CONCRETE-SAMPLES :\n"
            + f"  ({lhs}) .\n"
            + "q\n"
        )
    else:
        raise ValueError(f"unknown probe mode: {mode}")
    probe_file.write_text(text)
    timed_out = False
    try:
        proc = subprocess.run(
            [maude_bin(), "-no-banner"],
            cwd=ROOT,
            input=text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
        output = proc.stdout
        returncode = proc.returncode
    except subprocess.TimeoutExpired as exc:
        timed_out = True
        output = (exc.stdout or "") if isinstance(exc.stdout, str) else ""
        returncode = 124
    log_file.write_text(output)
    if timed_out:
        status = "TIMEOUT"
    elif "Fatal error: stack overflow" in output:
        status = "STACK_OVERFLOW"
    elif mode == "exact" and "Solution 1" in output:
        status = "SOLUTION"
    elif mode == "exact" and "No solution" in output:
        status = "NO_SOLUTION"
    elif "parse error" in output.lower() or "bad token" in output.lower():
        status = "PARSE_ERROR"
    elif returncode != 0:
        status = f"MAUDE_EXIT_{returncode}"
    elif mode == "rewrite":
        payload = result_payload(output)
        if not payload:
            status = "UNKNOWN"
        elif normalize(rhs) == "valid" and payload == "valid":
            status = "REDUCED"
        elif payload == normalize(lhs):
            status = "STUCK"
        elif top_head(lhs) and payload.startswith(top_head(lhs) + "("):
            status = "STUCK"
        else:
            status = "REDUCED"
    else:
        status = "UNKNOWN"
    return status, str(log_file.relative_to(ROOT))


CSV_FIELDS = ["line", "kind", "label", "family", "status", "attempts", "log", "lhs", "rhs"]


def write_summary(path: Path, rows: list[dict[str, str]], *, completed: int, total: int, max_variants: int, mode: str) -> None:
    counts: dict[str, int] = {}
    for row in rows:
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    with path.open("w") as f:
        f.write("# output_bs.maude concrete-sample rl/crl audit\n\n")
        f.write(f"- probe mode: {mode}\n")
        f.write(f"- rules completed: {completed} / {total}\n")
        f.write(f"- max variants per rule: {max_variants} + empty-ish variant\n\n")
        f.write("## Status counts\n\n")
        f.write("| status | count |\n|---|---:|\n")
        for status, count in sorted(counts.items()):
            f.write(f"| {status} | {count} |\n")
        good_status = "SOLUTION" if mode == "exact" else "REDUCED"
        f.write("\n## Non-passing statuses\n\n")
        f.write("| line | label | family | status | log |\n|---:|---|---|---|---|\n")
        for row in rows:
            if row["status"] != good_status:
                f.write(f"| {row['line']} | `{row['label']}` | {row['family']} | {row['status']} | `{row['log']}` |\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", default="output_bs.maude")
    ap.add_argument("--artifact-dir", default="")
    ap.add_argument("--timeout", type=int, default=4)
    ap.add_argument("--max-variants", type=int, default=3)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--label-regex", default="")
    ap.add_argument(
        "--labels-file",
        default="",
        help="Optional CSV/TXT file containing labels to audit. CSV files may use a 'label' column.",
    )
    ap.add_argument(
        "--probe-mode",
        choices=["exact", "rewrite"],
        default="exact",
        help="exact: search instantiated LHS =>+ instantiated RHS; rewrite: rew instantiated LHS and check that it changes",
    )
    args = ap.parse_args()

    out_dir = Path(args.artifact_dir) if args.artifact_dir else ROOT / "artifacts" / f"rule-concrete-audit-{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    if not out_dir.is_absolute():
        out_dir = ROOT / out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    output_path = ROOT / args.output
    vars_by_name = parse_vars(output_path)
    rules = parse_rules(output_path)
    if args.labels_file:
        labels_path = Path(args.labels_file)
        if not labels_path.is_absolute():
            labels_path = ROOT / labels_path
        wanted: set[str] = set()
        if labels_path.suffix == ".csv":
            with labels_path.open() as f:
                reader = csv.DictReader(f)
                if reader.fieldnames and "label" in reader.fieldnames:
                    wanted = {row["label"] for row in reader if row.get("label")}
                else:
                    f.seek(0)
                    wanted = {line.strip().split(",")[0] for line in f if line.strip()}
        else:
            wanted = {line.strip() for line in labels_path.read_text().splitlines() if line.strip()}
        rules = [r for r in rules if r.label in wanted]
    if args.label_regex:
        rx = re.compile(args.label_regex)
        rules = [r for r in rules if rx.search(r.label)]
    if args.limit:
        rules = rules[: args.limit]

    rows: list[dict[str, str]] = []
    results_path = out_dir / "rule_concrete_results.csv"
    with results_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        writer.writeheader()
        f.flush()
        for idx, rule in enumerate(rules, 1):
            variants = substitutions_for(rule, vars_by_name, args.max_variants)
            best_status = "NO_ATTEMPT"
            best_log = ""
            attempted = 0
            stack_logs: list[str] = []
            parse_logs: list[str] = []
            for v_idx, subst in enumerate(variants):
                attempted += 1
                status, log = run_probe(rule, subst, out_dir, args.timeout, v_idx, args.probe_mode)
                if status in {"SOLUTION", "REDUCED"}:
                    best_status, best_log = status, log
                    break
                if status == "STACK_OVERFLOW":
                    stack_logs.append(log)
                if status == "PARSE_ERROR":
                    parse_logs.append(log)
                if best_status in {"NO_ATTEMPT", "NO_SOLUTION"}:
                    best_status, best_log = status, log
            if stack_logs and best_status not in {"SOLUTION", "REDUCED"}:
                best_status, best_log = "STACK_OVERFLOW", stack_logs[0]
            elif parse_logs and best_status not in {"SOLUTION", "STACK_OVERFLOW"}:
                best_status, best_log = "PARSE_ERROR", parse_logs[0]
            row = {
                "line": str(rule.line),
                "kind": rule.kind,
                "label": rule.label,
                "family": family_of(rule.label),
                "status": best_status,
                "attempts": str(attempted),
                "log": best_log,
                "lhs": rule.lhs,
                "rhs": rule.rhs,
            }
            rows.append(row)
            writer.writerow(row)
            f.flush()
            print(f"[{idx:04d}/{len(rules):04d}] {rule.label}: {best_status} ({attempted} variants)", flush=True)
            if idx == 1 or idx % 25 == 0:
                write_summary(
                    out_dir / "summary.partial.md",
                    rows,
                    completed=idx,
                    total=len(rules),
                    max_variants=args.max_variants,
                    mode=args.probe_mode,
                )

    write_summary(
        out_dir / "summary.md",
        rows,
        completed=len(rows),
        total=len(rules),
        max_variants=args.max_variants,
        mode=args.probe_mode,
    )

    print(f"[DONE] {out_dir.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
