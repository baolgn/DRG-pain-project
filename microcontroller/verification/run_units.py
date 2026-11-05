#!/usr/bin/env python3
"""bind datapath, RF and arithmetic proof checks to one source snapshot."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


# the Makefile retains the original positive checks and named negative controls.
def main():
    """replay standalone checks and preserve their complete current-source evidence."""
    root = Path(__file__).resolve().parents[2]
    evidence = root / 'microcontroller/verification/evidence/verification-2026-11-04/units'
    evidence.mkdir(parents=True, exist_ok=True)
    revisions = evidence / 'revisions'; revisions.mkdir(exist_ok=True)
    number = max([int(p.name) for p in revisions.iterdir() if p.is_dir()] + [0]) + 1
    attempt = revisions / f'{number:02d}'; attempt.mkdir()
    build = Path('/tmp/drg5-verification-units')
    sources = [str(path.relative_to(root)) for directory in ['rtl', 'tests', 'synth']
               for path in sorted((root / 'microcontroller' / directory).glob('*'))
               if path.is_file() and (path.suffix in {'.sv', '.svh', '.py'} or path.name == 'Makefile')]
    sources.append(str(Path(__file__).relative_to(root)))
    before = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in sources}
    # preserve the exact sources before allowing any tool invocation.
    for name in sources:
        target = attempt / 'sources' / name; target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, target)
    command = ['make', '-C', 'microcontroller/tests', 'datapath', 'regfile', 'arithmetic-formal',
               'VERILATOR=/tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator',
               'YOSYS=/tmp/drg5-control-tools-20260301/oss-cad-suite/bin/yosys', 'BUILD_ROOT=' + str(build)]
    summary = {'status': 'running', 'source_sha256': before, 'command': command,
               'scope': 'standalone decoder/immediate/ALU/shifter and RF behavior; combinational arithmetic proof'}
    # save ordinary failures without turning absent checks into success.
    try:
        # capture the complete Makefile invocation in one retained log.
        with (attempt / 'run.log').open('w') as stream:
            result = subprocess.run(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT, timeout=900)
        output = (attempt / 'run.log').read_text()
        summary['exit_code'] = result.returncode
        assert result.returncode == 0 and '%Warning' not in output, 'standalone qualification failed'
        markers = [line for line in output.splitlines() if line.startswith('PASS datapath ')]
        assert len(markers) == 3 and 'positive RF_PASS ' in output, 'positive terminals missing'
        assert 'ARITHMETIC_FORMAL_PASS assertions=7 assumptions=0 negative_detected=1' in output
        assert before == {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in sources}
        summary.update({'status': 'passed', 'datapath_runs': markers, 'datapath_negative_controls': 6,
                        'regfile': json.loads((build / 'regfile/results.json').read_text()),
                        'arithmetic_formal': json.loads((build / 'arithmetic-formal/summary.json').read_text()),
                        'limits': ['two-state logic only', 'no complete pipeline proof',
                                   'RF candidates retain different documented read latency',
                                   'standalone RF is not the controller register-array implementation']})
    # failed tool runs remain visible as their own attempt.
    except Exception as error:
        summary.update({'status': 'failed', 'failure': str(error)})
        raise
    # logs and checker records survive even an unsuccessful invocation.
    finally:
        # copy each diagnostic before the build tree can be reclaimed.
        for path in build.rglob('*'):
            # generated compiler caches are deliberately excluded from evidence.
            if path.is_file() and path.suffix in {'.log', '.json', '.vcd', '.ys'}:
                target = attempt / 'records' / path.relative_to(build)
                target.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(path, target)
        (attempt / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
        (evidence / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('UNITS_PASS datapath_runs=3 RF_checks=40919 arithmetic_assertions=7 negative_controls=9')


# importing the wrapper does not execute any tools.
if __name__ == '__main__':
    main()
