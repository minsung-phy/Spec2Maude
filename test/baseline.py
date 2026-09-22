#!/usr/bin/env python3
"""Check removed hint diagnostics and the remaining ordinary relation path."""
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / '_build/default/bin/spec2maude.exe'
SOURCE = ROOT / 'test/fixtures/baseline-premises.spectec'

def run(args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, timeout=60,
                          cwd=ROOT, **kwargs)

with tempfile.TemporaryDirectory(prefix='spec2maude-baseline-') as directory:
    work = Path(directory)
    output = work / 'output.maude'
    result = run([str(EXE), '-o', str(output), str(SOURCE)])
    assert result.returncode == 0, result.stderr
    assert sorted(work.glob("*.maude")) == [output], list(work.iterdir())
    for hint in ['maude_sort', 'maude_subsort', 'maude_proper',
                 'k_heatcool', 'maude_context']:
        source = work / f'{hint}.spectec'
        text = SOURCE.read_text()
        if hint in ['maude_sort', 'maude_subsort', 'maude_proper']:
            argument = {'maude_sort': '', 'maude_subsort': ' "num"',
                        'maude_proper': ' "num Proper"'}[hint]
            text = text.replace('syntax num =',
                                f'syntax num hint({hint}{argument}) =')
        else:
            text += f'  hint({hint})\n'
        source.write_text(text)
        result = run([str(EXE), '-o', str(output), str(source)])
        assert result.returncode != 0, hint
        assert f'removed baseline hint {hint}' in result.stderr, result.stderr
        assert re.search(re.escape(str(source)) + r':\d+\.\d+',
                         result.stderr), result.stderr
    commands = f"""load {ROOT / 'translator/backend/pretype.maude'}
load {output}
rew in SPEC2MAUDE-GENERATED : Twice(1) .
quit
"""
    result = run([os.environ.get('MAUDE', 'maude'), '-no-banner'], input=commands)
    log = result.stdout + result.stderr
    assert result.returncode == 0, log
    assert not re.search(r'Warning:|Advisory:|\*\*\*', log), log
    assert 'result NzNat: 2' in log, log
    print(log)
print('baseline: PASS (five rejected hints and ordinary relation execution)')
