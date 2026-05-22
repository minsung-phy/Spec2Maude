#!/usr/bin/env python3
"""Classify rule-level execution audit results.

The broad concrete audit already runs one Maude command for every generated
artifact.  This script narrows the rule-level rows (`rl`/`crl`) into a more
useful research queue:

- already executable with the generated sample,
- known limitation/debt,
- confirmed new limitation from a focused probe,
- likely representation limitation that needs a source-valid focused probe,
- likely broad-sample problem.

It does not prove every rule for all inputs.  It records the strongest current
classification for each generated rule so the next debugging work can be
prioritized without losing the full 884-rule view.
"""

from __future__ import annotations

import argparse
import csv
from collections import Counter
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def label_family(label: str) -> str:
    if label.startswith("step-from-step-pure-"):
        return "step-from-step-pure"
    if label.startswith("step-read-"):
        return "step-read"
    if label.startswith("step-pure-"):
        return "step-pure"
    if label.startswith("instr-ok-"):
        return "instr-ok"
    if label.startswith("instrs-ok-"):
        return "instrs-ok"
    if label.startswith("externaddr-ok-"):
        return "externaddr-ok"
    if "-" in label:
        return label.rsplit("-", 1)[0]
    return label


def classify_no_solution(row: dict[str, str]) -> tuple[str, str, str]:
    label = row["label_or_head"]
    stmt = row["statement"]

    if label == "instr-ok-local-get":
        return (
            "CONFIRMED_NEW_LIMITATION",
            "TYPED_SEQUENCE_INDEX_COMPOSITE_ENTRY",
            "Focused source-valid probe still stuck: C.LOCALS[0] = SET i32 is flattened to CTORSETA0 CTORI32A0, but scalar index returns CTORSETA0.",
        )

    if label.startswith("instr-ok-") and any(
        needle in stmt
        for needle in [
            "value('LOCALS",
            "value('GLOBALS",
            "value('TABLES",
            "value('MEMS",
            "value('TYPES",
            "value('ELEMS",
            "value('DATAS",
        ]
    ):
        return (
            "LIKELY_TYPED_INDEX_OR_CONTEXT_SAMPLE",
            "CONTEXT_LOOKUP_OR_COMPOSITE_SEQUENCE_INDEXING",
            "Rule indexes a source context field; may need richer source-valid context and may hit composite-entry typed-index limitation.",
        )

    if label.startswith("instr-ok-") and any(
        needle in stmt for needle in ["Instrs-ok", "Blocktype-ok", "$iter-catch-ok"]
    ):
        return (
            "KNOWN_OR_LIKELY_WITNESS_LIMITATION",
            "INSTRS_OK_OR_BLOCK_BODY_WITNESS",
            "Rule depends on block/if/loop body validation or inferred arrow witness; overlaps known Instrs-ok witness/sequence limitation.",
        )

    if label.startswith("instr-ok-") and (
        "value('LABELS" in stmt or "value('RETURN" in stmt
    ):
        return (
            "NEEDS_SOURCE_VALID_SAMPLE",
            "NEEDS_LABEL_OR_RETURN_CONTEXT",
            "Broad audit did not construct a context with matching LABELS/RETURN entries.",
        )

    if label.startswith("instr-ok-v") or label.startswith("instr-ok-i31"):
        return (
            "LIKELY_SAMPLE_PROBLEM",
            "NEEDS_PRECISE_VECTOR_OR_REFERENCE_OPERATOR_SAMPLE",
            "Vector/reference instruction rule needs matching operator, lane shape, and arrow type.",
        )

    if label in {"expr-const-r0", "instr-const-r0", "eval-r0"}:
        return (
            "CONFIRMED_BROAD_SAMPLE_PROBLEM",
            "AUTO_SAMPLE_NOT_SOURCE_VALID",
            "Focused source-valid const/eval probes pass; broad audit used a mismatched instruction/value shape.",
        )

    if label.startswith("val-ok-"):
        return (
            "LIKELY_SAMPLE_PROBLEM_OR_SEQUENCE_QUERY_LIMITATION",
            "VALUE_SHAPE_OR_NON_SOURCE_SEQUENCE_VAL_OK",
            "Broad audit often used type atoms as values; direct sequence-shaped Val-ok remains a separate intentional limitation.",
        )

    if label.startswith(("step-read-", "step-pure-", "step-")):
        return (
            "NEEDS_SOURCE_VALID_RUNTIME_SAMPLE",
            "RUNTIME_STORE_FRAME_STACK_SHAPE",
            "Execution rules require precise store/frame/stack shape; broad audit samples are intentionally shallow.",
        )

    if label.startswith(("heaptype-", "rectype-", "subtype-", "deftype-", "typeuse-", "expand", "types-ok", "type-ok")):
        return (
            "NEEDS_SOURCE_VALID_RECURSIVE_TYPE_CONTEXT",
            "RECURSIVE_TYPE_CONTEXT_OR_TYPEUSE_INDEX",
            "Requires a context with matching TYPES/RECS and typeuse/deftype witnesses.",
        )

    if label.startswith(("module-ok", "func-ok", "global-ok", "mem-ok", "table-ok", "data-ok", "local-ok", "tag-ok", "start-ok", "import-ok", "export-ok")):
        return (
            "NEEDS_SOURCE_VALID_MODULE_HARNESS",
            "MODULE_VALIDATION_CONTEXT_OR_ITERATED_WITNESS",
            "Module-family rules require source-shaped module/context and iterated premise witnesses.",
        )

    if label.startswith(("ref-ok", "externaddr-ok", "externidx-ok", "externtype-ok", "catch-ok")):
        return (
            "NEEDS_SOURCE_VALID_STORE_OR_EXTERN_CONTEXT",
            "STORE_EXTERNADDR_OR_REFERENCE_WITNESS",
            "Requires source-shaped store/ref/extern context; broad audit does not provide the needed witness.",
        )

    return (
        "NEEDS_SOURCE_VALID_SAMPLE",
        "UNCLASSIFIED_BROAD_SAMPLE_NO_SOLUTION",
        "No focused source-valid probe has been written yet.",
    )


def classify_row(row: dict[str, str]) -> dict[str, str]:
    status = row["status"]
    label = row["label_or_head"]
    if status == "PASS":
        cls = ("EXECUTABLE_WITH_GENERATED_SAMPLE", "PASS", row["notes"])
    elif status == "KNOWN_LIMITATION":
        cls = ("KNOWN_LIMITATION_OR_DEBT", "KNOWN_LIMITATION", row["notes"])
    elif status == "NO_SOLUTION":
        cls = classify_no_solution(row)
    else:
        cls = (f"AUDIT_{status}", status, row["notes"])
    final_status, root_cause, notes = cls
    return {
        "id": row["id"],
        "line": row["line"],
        "kind": row["kind"],
        "label": label,
        "family": label_family(label),
        "audit_status": status,
        "final_status": final_status,
        "root_cause": root_cause,
        "notes": notes,
        "command": row["command"],
        "statement": row["statement"].replace("\n", " "),
        "log": row["log"],
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--test-results",
        default=str(ROOT / "artifacts/output-bs-total-audit-20260521_114249/test_results.csv"),
    )
    ap.add_argument("--out-dir", default="")
    args = ap.parse_args()

    test_results = Path(args.test_results)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_dir = Path(args.out_dir) if args.out_dir else ROOT / "artifacts" / f"rule-execution-classification-{stamp}"
    out_dir.mkdir(parents=True, exist_ok=True)

    rows = [
        r
        for r in csv.DictReader(test_results.open())
        if r["kind"] in {"rl", "crl"}
    ]
    classified = [classify_row(r) for r in rows]

    csv_path = out_dir / "rule_execution_classification.csv"
    fieldnames = [
        "id",
        "line",
        "kind",
        "label",
        "family",
        "audit_status",
        "final_status",
        "root_cause",
        "notes",
        "command",
        "statement",
        "log",
    ]
    with csv_path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(classified)

    by_audit = Counter(r["audit_status"] for r in classified)
    by_final = Counter(r["final_status"] for r in classified)
    by_root = Counter(r["root_cause"] for r in classified)
    by_family = Counter(r["family"] for r in classified if r["final_status"] != "EXECUTABLE_WITH_GENERATED_SAMPLE")

    md_path = out_dir / "summary.md"
    with md_path.open("w") as f:
        f.write("# Rule Execution Classification\n\n")
        f.write(f"Source audit: `{test_results}`\n\n")
        f.write("This covers every generated `rl` / `crl` row from the broad concrete audit. It is a concrete-probe classification, not a proof for all possible inputs.\n\n")
        f.write(f"- Total rules classified: {len(classified)}\n\n")
        f.write("## Original Audit Status\n\n| status | count |\n|---|---:|\n")
        for k, v in by_audit.most_common():
            f.write(f"| `{k}` | {v} |\n")
        f.write("\n## Refined Final Status\n\n| status | count |\n|---|---:|\n")
        for k, v in by_final.most_common():
            f.write(f"| `{k}` | {v} |\n")
        f.write("\n## Root Cause / Queue\n\n| root cause | count |\n|---|---:|\n")
        for k, v in by_root.most_common():
            f.write(f"| `{k}` | {v} |\n")
        f.write("\n## Non-Pass Families\n\n| family | count |\n|---|---:|\n")
        for k, v in by_family.most_common():
            f.write(f"| `{k}` | {v} |\n")
        f.write("\n## Key Takeaways\n\n")
        f.write("- `PASS` means at least one generated concrete probe for that rule executed.\n")
        f.write("- `NO_SOLUTION` rows are now split into queues instead of being treated as one giant bug bucket.\n")
        f.write("- `instr-ok-local-get` is a confirmed real execution limitation: flat token indexing cannot return the composite source element `SET i32`.\n")
        f.write("- Many remaining `instr-ok` context lookup rows need focused probes and may share the same typed-sequence/category-aware indexing issue.\n")
        f.write("- Runtime `step*` rows mostly need source-shaped store/frame/stack samples; broad audit samples are too shallow.\n")
        f.write("- Recursive type and module-family rows need richer source-valid contexts and witnesses.\n")

    print(out_dir)


if __name__ == "__main__":
    main()
