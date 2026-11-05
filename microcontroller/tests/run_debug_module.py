#!/usr/bin/env python3
"""qualify the external DM and JTAG DTM with retained revisions."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

# keep independent seeds and failure signatures explicit.
parser = argparse.ArgumentParser()
parser.add_argument('--verilator', required=True)
parser.add_argument('--yosys')
parser.add_argument('--build-dir', required=True)
parser.add_argument('--evidence-dir')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
build = Path(args.build_dir).resolve()
evidence = Path(args.evidence_dir).resolve() if args.evidence_dir else root / 'microcontroller/tests/evidence/debug-module-2026-11-04'
evidence.mkdir(parents=True, exist_ok=True)
revisions = evidence / 'revisions'
revisions.mkdir(exist_ok=True)
revision = revisions / f'{len(list(revisions.iterdir())) + 1:02d}-qualification'
revision.mkdir()
source_names = ['microcontroller/rtl/drg5_debug_module.sv', 'microcontroller/rtl/drg5_debug_transport.sv',
                'microcontroller/tests/drg5_debug_module_tb.sv', 'microcontroller/tests/drg5_debug_transport_tb.sv',
                'microcontroller/tests/run_debug_module.py']
sources = {}
# retain every exact source even when a qualification attempt fails.
for name in source_names:
    path = root / name
    target = revision / 'sources' / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(path, target)
    sources[name] = hashlib.sha256(path.read_bytes()).hexdigest()
summary = {'status': 'running', 'source_sha256': sources, 'seeds': [0, 1, 305419896],
           'runs': [], 'negative_controls': [], 'synthesis': [], 'revision': revision.name,
           'scope': 'standalone DM and TAP/CDC simulations; no CPU or host-debugger qualification'}


# retain commands and output without relaxing warnings or expected failures.
def run(command, name, expected=None):
    """run one bounded check and retain its exact diagnostic output."""
    result = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    (revision / f'{name}.log').write_text(result.stdout)
    (revision / f'{name}.command.json').write_text(json.dumps(command, indent=2) + '\n')
    # detectors must reject through their ordinary assertion and named failure.
    if expected:
        assert result.returncode != 0 and expected in result.stdout, (name, result.returncode, result.stdout[-2000:])
    # successful elaboration must not rely on suppressed lint findings.
    else:
        assert result.returncode == 0 and '%Warning' not in result.stdout and 'ERROR:' not in result.stdout, (name, result.stdout[-2000:])
    return result.stdout


# each top has its own object directory and independently compiled fixture.
def compile_top(kind, label, rtl):
    """build one production or deliberately mutated component."""
    top = f'drg5_debug_{kind}_tb'
    obj = build / label
    obj.mkdir(parents=True, exist_ok=True)
    command = [args.verilator, '--binary', '--timing', '--assert', '-Wall', '-j', '2',
               '--top-module', top, '--Mdir', str(obj), str(rtl),
               str(root / f'microcontroller/tests/{top}.sv')]
    run(command, f'{label}-build')
    return obj / f'V{top}'


# keep a failed attempt discoverable instead of publishing a partial pass.
try:
    summary['verilator'] = run([args.verilator, '--version'], 'verilator-version').strip()
    # production modules and their fixtures qualify independently across seeds.
    for kind in ['module', 'transport']:
        rtl = root / f'microcontroller/rtl/drg5_debug_{kind}.sv'
        run([args.verilator, '--lint-only', '--timing', '-Wall', '--top-module', f'drg5_debug_{kind}', str(rtl)], f'{kind}-lint')
        binary = compile_top(kind, kind, rtl)
        # independent schedules alter acceptance/response delays and clock ratios.
        for seed in summary['seeds']:
            output = run([str(binary), f'+seed={seed}'], f'{kind}-seed-{seed}')
            match = re.search(r'(DM|DTM)_PASS seed=(\d+) checks=(\d+) (.*)', output)
            assert match, output[-2000:]
            summary['runs'].append({'kind': kind, 'seed': seed, 'checks': int(match[3]), 'metrics': match[4]})
    mutations = [
        ('module', 'narrow_read', "{24'b0, sb_shifted[7:0]}", "{24'hffffff, sb_shifted[7:0]}", 'SBA narrow zero extension'),
        ('module', 'revoked_abstract', '!revoke && abstract_busy_q && !unavailable', 'abstract_busy_q && !unavailable', 'same-edge abstract revocation'),
        ('module', 'withdraw_offer', "if (!dmi_req_data_i[0]) begin", "if (!dmi_req_data_i[0]) begin\n          sb_state_q <= SB_FREE;", 'deactivation waits for exposed SBA'),
        ('module', 'resume_halt', '!halt_q && !new_halt && !abstract_busy_q', '!halt_q && !abstract_busy_q', 'same-edge halt priority'),
        ('transport', 'stale_capture', 'assign effective_data = fresh_response ? response_data_q : last_data_q;', 'assign effective_data = last_data_q;', 'completion coincident with Capture-DR'),
        ('transport', 'old_hardreset_response', 'discard_q <= busy;', 'discard_q <= 0;', 'hard reset discards old response'),
    ]
    # mutations change production logic, then exercise the unchanged ordinary checker.
    for kind, name, before, after, expected in mutations:
        original = (root / f'microcontroller/rtl/drg5_debug_{kind}.sv').read_text()
        assert original.count(before) == 1, name
        folder = build / 'mutations' / name
        folder.mkdir(parents=True, exist_ok=True)
        rtl = folder / f'drg5_debug_{kind}.sv'
        rtl.write_text(original.replace(before, after))
        shutil.copyfile(rtl, revision / f'{name}.sv')
        binary = compile_top(kind, name, rtl)
        run([str(binary), '+seed=1'], name, expected)
        summary['negative_controls'].append({'name': name, 'detector': expected, 'detected': True})
    # optional native ECP5 mapping checks both independent clock domains for latches.
    if args.yosys:
        summary['yosys'] = run([args.yosys, '-V'], 'yosys-version').strip()
        # map each component independently, retaining its complete netlist.
        for kind in ['module', 'transport']:
            top = f'drg5_debug_{kind}'
            script = f'read_verilog -sv microcontroller/rtl/{top}.sv; hierarchy -check -top {top}; synth_ecp5 -noabc9 -top {top}; check -assert; stat -json; write_json {revision / (top + ".json")}'
            output = run([args.yosys, '-Q', '-p', script], f'{kind}-synth')
            netlist = json.loads((revision / f'{top}.json').read_text())
            cells = list(netlist['modules'][top]['cells'].values())
            assert all('latch' not in cell['type'].lower() for cell in cells)
            counts = {}
            # count native cells without treating mapping as a clock qualification.
            for cell in cells:
                counts[cell['type']] = counts.get(cell['type'], 0) + 1
            summary['synthesis'].append({'kind': kind, 'cells': counts})
    summary['status'] = 'passed'
# failures preserve the complete partial record and propagate to the caller.
finally:
    (revision / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    (evidence / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps({'status': summary['status'], 'runs': len(summary['runs']),
                  'checks': sum(item['checks'] for item in summary['runs']),
                  'detectors': len(summary['negative_controls']), 'revision': revision.name}))
