#!/usr/bin/env python3
"""measure generic LUT4 logic around explicitly enumerated native RAM and DSP macros."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess


def digest(path):
    """bind the audit to exact executable, script and candidate bytes."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """reuse an immutable candidate snapshot without changing its functional inputs."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--yosys', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    candidate, output, yosys = args.candidate.resolve(), args.output.resolve(), args.yosys.resolve()
    output.mkdir(parents=True, exist_ok=False)
    identity = json.loads((candidate / 'summary.json').read_text())
    tools = yosys.parent.parent
    expected = json.loads((candidate / 'tool-and-database-sha256.json').read_text())['libexec/yosys']
    # a changed synthesis executable cannot inherit the routed candidate's qualification.
    if digest(tools / 'libexec/yosys') != expected:
        raise RuntimeError('Yosys differs from the routed candidate')
    top = identity['top']
    netlist = output / 'generic.json'
    prefix = (candidate / 'synthesis.ys').read_text().split('synth_ecp5 -noabc9 -top ')[0]
    script = prefix + (
        f'synth_ecp5 -noabc9 -top {top} -run begin:map_ffram; '
        f'select -assert-count {identity["mapping"]["cells"]["DP16KD"]} t:DP16KD; '
        f'select -assert-count {identity["mapping"]["cells"]["MULT18X18D"]} t:MULT18X18D; '
        f'select -assert-count {identity["mapping"]["cells"]["TRELLIS_DPR16X4"]} t:TRELLIS_DPR16X4; '
        'memory_map; opt; techmap; opt; dffunmap; abc -lut 4; clean; '
        'check -assert; select -assert-none t:$dlatch t:$adlatch; '
        f'stat; blackbox =A:whitebox; write_json {netlist}\n')
    (output / 'generic.ys').write_text(script)
    shutil.copy2(Path(__file__).resolve(), output / 'audit_fpga_generic.py')
    command = [str(yosys), '-Q', '-T', '-m', 'slang', '-s', str(output / 'generic.ys')]
    result = {'scope': 'local board top only; excludes debug, acquisition and external-memory controllers',
              'metric': 'new LUT4 audit with enumerated ECP5 RAM/DSP macros; not a historical generic baseline',
              'budget_status': 'unqualified; not a like-for-like CPU-plus-debug or complete-SoC comparison',
              'candidate_summary_sha256': digest(candidate / 'summary.json'),
              'candidate_sources': identity['source_sha256'], 'yosys_sha256': expected,
              'script_sha256': digest(output / 'generic.ys'),
              'driver_sha256': digest(output / 'audit_fpga_generic.py'), 'command': command}
    # retain the exact tool invocation and every diagnostic, including failed mappings.
    with (output / 'generic.log').open('w') as stream:
        stream.write('$ ' + shlex.join(command) + '\n')
        stream.flush()
        completed = subprocess.run(command, cwd=candidate, stdout=stream,
                                   stderr=subprocess.STDOUT, check=False)
    result['exit'] = completed.returncode
    # only completed mapping supplies count evidence.
    if completed.returncode == 0:
        cells = json.loads(netlist.read_text())['modules'][top]['cells']
        counts = Counter(cell['type'] for cell in cells.values())
        result['cells'] = dict(sorted(counts.items()))
        result['lut4'] = counts['$lut']
        result['scalar_ff_bits'] = sum(count for name, count in counts.items() if name.startswith('$_DFF'))
        result['native_macros'] = {name: {'type': cell['type'], 'parameters': cell.get('parameters', {})}
                                   for name, cell in cells.items() if cell['type'] in
                                   {'DP16KD', 'TRELLIS_DPR16X4', 'MULT18X18D', 'EHXPLLL'}}
        result['register_accounting'] = {
            'DP16KD': 'storage and synchronous port state remain inside each enumerated physical EBR',
            'TRELLIS_DPR16X4': '64 storage bits per macro; asynchronous reads, synchronous write',
            'MULT18X18D': 'unsigned combinational products; no clock ports, product registers count as scalar FFs',
            'EHXPLLL': 'clock primitive excluded from generic logic; counted separately in native utilization'}
        result['netlist_sha256'] = digest(netlist)
        result['warnings'] = [line for line in (output / 'generic.log').read_text().splitlines()
                              if 'Warning:' in line]
    (output / 'summary.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    return completed.returncode


# importing the auditor never launches synthesis.
if __name__ == '__main__':
    raise SystemExit(main())
