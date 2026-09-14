#!/usr/bin/env python3
"""Sequentially retry a saved WAST list using the existing suite-run classifier."""
import argparse
import collections
import csv
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FIELDS = ['status', 'seconds', 'commands', 'checked_assertions',
          'runtime_assertions', 'source', 'detail']
STATUSES = {'PASS', 'WRONG_RESULT', 'UNSUPPORTED', 'FRONTEND_ERROR',
            'MAUDE_ERROR', 'TIMEOUT', 'STEP_LIMIT', 'STUCK'}


def write_report(path, rows):
    temporary = path.with_suffix('.tmp')
    with temporary.open('w', newline='') as out:
        writer = csv.DictWriter(out, fieldnames=FIELDS, delimiter='\t')
        writer.writeheader()
        writer.writerows(rows)
    temporary.replace(path)


def kill_group(pid, sig):
    try:
        os.killpg(pid, sig)
    except ProcessLookupError:
        pass


def run_case(binary, maude, source, seconds, directory):
    directory.mkdir(parents=True)
    logs = directory / 'logs'
    logs.mkdir()
    report = directory / 'report.tsv'
    command = [str(binary), 'suite-run', str(source), '-o', str(report),
               '--semantics', str(ROOT / 'translator/backend/semantics.maude'),
               '--maude', maude, '--timeout', str(seconds),
               '--steps', '1000000000000', '--call-depth', '256',
               '--log-dir', str(logs)]
    (directory / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
    with (directory / 'stdout.log').open('w') as out, \
            (directory / 'stderr.log').open('w') as err:
        process = subprocess.Popen(command, cwd=ROOT, stdin=subprocess.DEVNULL,
                                   stdout=out, stderr=err, start_new_session=True)
        try:
            code = process.wait()
        finally:
            # Include Maude descendants when this driver is interrupted.
            kill_group(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
            kill_group(process.pid, signal.SIGKILL)
            process.wait()
    with report.open(newline='') as inp:
        reader = csv.DictReader(inp, delimiter='\t')
        if reader.fieldnames != FIELDS:
            raise RuntimeError(f'Unexpected report header: {report}')
        rows = list(reader)
    if (len(rows) != 1 or rows[0]['source'] != str(source)
            or rows[0]['status'] not in STATUSES
            or code != (0 if rows[0]['status'] == 'PASS' else 1)):
        raise RuntimeError(f'Invalid result or unexpected exit {code}: {report}')
    return rows[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cases', type=Path,
                        default=ROOT / 'test/wasm_timeouts_20260915.txt')
    parser.add_argument('--short-timeout', type=int, default=300)
    parser.add_argument('--long-timeout', type=int, default=3600)
    parser.add_argument('--maude', default=os.environ.get('MAUDE', 'maude'))
    parser.add_argument('--result-dir', type=Path)
    args = parser.parse_args()
    if args.short_timeout <= 0 or args.long_timeout <= 0:
        parser.error('Timeouts must be positive seconds')
    binary = ROOT / '_build/default/bin/wasm2maude.exe'
    maude = shutil.which(args.maude)
    if not binary.is_file() or not maude:
        parser.error('Run dune build first and install Maude on PATH (or use --maude)')
    sources = [(ROOT / line.strip()).resolve()
               for line in args.cases.read_text().splitlines()
               if line.strip() and not line.lstrip().startswith('#')]
    if not sources or len(set(sources)) != len(sources):
        parser.error('Cases must be nonempty and unique')
    if any(not source.is_file() or source.suffix != '.wast' for source in sources):
        parser.error('Every case must name an existing .wast file')
    if any(ROOT not in source.parents for source in sources):
        parser.error('Cases must be inside this repository')
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    result = (args.result_dir or ROOT.parent / 'WasmSuiteTest' /
              'spec2maude-results' / f'timeout-retry-{stamp}').resolve()
    result.mkdir(parents=True, exist_ok=False)
    print(f'Results: {result}', flush=True)
    (result / 'cases.txt').write_text('\n'.join(map(str, sources)) + '\n')
    for name, command in [('revision.txt', ['git', 'rev-parse', 'HEAD']),
                          ('status.txt', ['git', 'status', '--short']),
                          ('changes.patch', ['git', 'diff', 'HEAD'])]:
        with (result / name).open('w') as out:
            subprocess.run(command, cwd=ROOT, stdout=out, check=True)
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in [binary, *sorted((ROOT / 'translator').rglob('*.maude')),
                           *sources]}
    settings = dict(started=stamp, short_timeout=args.short_timeout,
                    long_timeout=args.long_timeout, steps=1000000000000,
                    call_depth=256, maude=maude, hashes=hashes)
    (result / 'settings.json').write_text(json.dumps(settings, indent=2) + '\n')
    final = {}
    pending = sources
    try:
        for stage, seconds in [('short', args.short_timeout), ('long', args.long_timeout)]:
            rows = []
            for index, source in enumerate(pending, 1):
                print(f'[{stage} {index}/{len(pending)}] {source.relative_to(ROOT)} '
                      f'({seconds}s)', flush=True)
                row = run_case(binary, maude, source, seconds,
                               result / stage / f'{index:02d}-{source.stem}')
                rows.append(row)
                final[source] = row
                write_report(result / f'{stage}.tsv', rows)
                write_report(result / 'partial.tsv',
                             [final[s] for s in sources if s in final])
                print(f"  {row['status']} ({row['seconds']}s)", flush=True)
            if not rows:
                write_report(result / f'{stage}.tsv', [])
            pending = [s for s in sources if final[s]['status'] == 'TIMEOUT']
        write_report(result / 'final.tsv', [final[s] for s in sources])
        counts = collections.Counter(row['status'] for row in final.values())
        summary = 'status\tfiles\n' + ''.join(
            f'{status}\t{counts[status]}\n' for status in sorted(STATUSES))
        (result / 'summary.tsv').write_text(summary)
        print(summary, end='', flush=True)
        (result / 'COMPLETE').write_text('Both stages finished. See final.tsv.\n')
        return 0 if counts['PASS'] == len(sources) else 1
    except BaseException:
        (result / 'INCOMPLETE').write_text('Interrupted or driver error; see partial reports.\n')
        raise


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('Interrupted; child processes stopped. Partial logs retained.', file=sys.stderr)
        sys.exit(130)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'Driver error: {error}', file=sys.stderr)
        sys.exit(2)
