#!/usr/bin/env python3
"""Bounded model checker for an automatically translated whole Wasm program.

The environment bound is the set of all permutations of event identifiers.
Each successor execution is computed by wasm2maude and the generated official
Wasm semantics; no SpaceWasm state transition is hand encoded.  Deterministic
program runs are independent and therefore evaluated in parallel.
"""

from __future__ import annotations

import argparse
import itertools
import json
import os
import re
import subprocess
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import asdict, dataclass
from pathlib import Path


RESULT_RE = re.compile(
    r"instr\.const\(\s*numtype\.i32,\s*uN\.wrap\((-?[0-9]+)\)\)",
    re.DOTALL,
)


@dataclass
class ScheduleResult:
    schedule: tuple[int, ...]
    result: int | None
    elapsed_seconds: float
    maude_returncode: int
    log: str
    generated: str
    error: str | None = None


def run_schedule(
    root: str,
    wasm: str,
    semantics: str,
    maude: str,
    output_dir: str,
    schedule: tuple[int, ...],
    timeout_seconds: int,
    steps: int,
) -> ScheduleResult:
    root_path = Path(root)
    out = Path(output_dir)
    tag = "-".join(map(str, schedule))
    generated = out / f"schedule-{tag}.maude"
    log = out / f"schedule-{tag}.log"

    command = [
        "opam",
        "exec",
        "--",
        "dune",
        "exec",
        "--profile",
        "release",
        "./bin/wasm2maude.exe",
        "--",
        "run",
        wasm,
        "--invoke",
        "spacewasm_run3",
    ]
    for event in schedule:
        command.extend(["--arg", f"i32:{event}"])
    command.extend(
        [
            "--steps",
            str(steps),
            "--semantics",
            semantics,
            "-o",
            str(generated),
        ]
    )

    started = time.monotonic()
    try:
        subprocess.run(
            command,
            cwd=root_path,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        with log.open("w", encoding="utf-8") as stream:
            completed = subprocess.run(
                [maude, "-no-banner", str(generated)],
                cwd=root_path,
                check=False,
                stdout=stream,
                stderr=subprocess.STDOUT,
                timeout=timeout_seconds,
                text=True,
            )
        text = log.read_text(encoding="utf-8")
        matches = RESULT_RE.findall(text[text.rfind("result RunState:") :])
        value = int(matches[-1]) if matches else None
        return ScheduleResult(
            schedule=schedule,
            result=value,
            elapsed_seconds=time.monotonic() - started,
            maude_returncode=completed.returncode,
            log=str(log),
            generated=str(generated),
            error=None if value is not None else "terminal i32 result not found",
        )
    except subprocess.TimeoutExpired:
        return ScheduleResult(
            schedule=schedule,
            result=None,
            elapsed_seconds=time.monotonic() - started,
            maude_returncode=124,
            log=str(log),
            generated=str(generated),
            error="timeout",
        )
    except Exception as exc:  # evidence is written even for infrastructure failures
        return ScheduleResult(
            schedule=schedule,
            result=None,
            elapsed_seconds=time.monotonic() - started,
            maude_returncode=1,
            log=str(log),
            generated=str(generated),
            error=f"{type(exc).__name__}: {exc}",
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--wasm", type=Path, required=True)
    parser.add_argument("--semantics", type=Path, required=True)
    parser.add_argument("--maude", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--events", default="0,1,2")
    parser.add_argument("--bad-result", type=int, default=1)
    parser.add_argument("--timeout-seconds", type=int, default=6300)
    parser.add_argument("--steps", type=int, default=1_000_000_000)
    parser.add_argument("--workers", type=int, default=6)
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    events = tuple(int(value) for value in args.events.split(","))
    schedules = tuple(itertools.permutations(events))

    common = dict(
        root=str(args.root.resolve()),
        wasm=str(args.wasm.resolve()),
        semantics=str(args.semantics.resolve()),
        maude=str(args.maude.resolve()),
        output_dir=str(args.output_dir.resolve()),
        timeout_seconds=args.timeout_seconds,
        steps=args.steps,
    )

    results: list[ScheduleResult] = []
    with ProcessPoolExecutor(max_workers=min(args.workers, len(schedules))) as pool:
        futures = {
            pool.submit(run_schedule, schedule=schedule, **common): schedule
            for schedule in schedules
        }
        for future in as_completed(futures):
            result = future.result()
            results.append(result)
            (args.output_dir / "partial-results.json").write_text(
                json.dumps([asdict(item) for item in results], indent=2),
                encoding="utf-8",
            )

    results.sort(key=lambda item: item.schedule)
    bad = [item for item in results if item.result == args.bad_result]
    summary = {
        "events": events,
        "schedule_count": len(schedules),
        "complete": all(item.result is not None for item in results),
        "bad_result": args.bad_result,
        "counterexamples": [list(item.schedule) for item in bad],
        "results": [asdict(item) for item in results],
    }
    (args.output_dir / "results.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    lines = [
        "Whole-program bounded schedule model checking",
        "=============================================",
        f"schedules={len(schedules)}",
        f"complete={summary['complete']}",
        f"counterexamples={summary['counterexamples']}",
    ]
    for item in results:
        lines.append(
            f"schedule={item.schedule} result={item.result} "
            f"seconds={item.elapsed_seconds:.3f} rc={item.maude_returncode} "
            f"error={item.error}"
        )
    (args.output_dir / "results.txt").write_text("\n".join(lines) + "\n")

    if not summary["complete"]:
        raise SystemExit("one or more complete-program executions did not terminate")
    if not bad:
        raise SystemExit("no violating schedule found")


if __name__ == "__main__":
    main()
