#!/usr/bin/env python3
"""map the control-flow prototype; do not claim placement or CPU timing."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    """synthesize both alignment profiles with the open-source slang frontend."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--yosys', default='yosys')
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-control-flow-synth'))
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    root = here.parent.parent
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    yosys = Path(shutil.which(args.yosys) or args.yosys).resolve()
    rtl = here.parent / 'rtl'
    sources = [rtl / name for name in ('drg5_control_pkg.sv', 'drg5_decoder.sv', 'drg5_decompress.sv',
               'drg5_immediate.sv', 'drg5_branch.sv', 'drg5_lsu.sv', 'drg5_shifter.sv', 'drg5_alu.sv', 'drg5_forward.sv', 'drg5_csr.sv', 'drg5_control.sv')]
    hash_sources = sources + [rtl / 'drg5_datapath_defs.svh', Path(__file__).resolve()]
    before = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in hash_sources}
    results = {}
    # frontend assertions are simulation checks; Verilator retains them separately.
    for compressed in (0, 1):
        name = f'c{compressed}'
        netlist = build / f'{name}.json'
        script = (f'read_slang --ignore-assertions --top drg5_control '
                  f'-G DIAGNOSTIC=0 -G FORWARDING=1 -G C_ENABLED={compressed} -I microcontroller/rtl '
                  + ' '.join(str(path.relative_to(root)) for path in sources)
                  + '; hierarchy -check; proc; opt; check -assert; '
                  'select -assert-none t:$dlatch t:$adlatch; '
                  'synth_ecp5 -noabc9 -top drg5_control; check -assert; stat; '
                  f'write_json "{netlist}"')
        command = [str(yosys), '-Q', '-T', '-m', 'slang', '-p', script]
        result = subprocess.run(command, cwd=root, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, timeout=300, check=False)
        (build / f'{name}.log').write_text('$ ' + ' '.join(command) + '\n' + result.stdout)
        # classic ABC extracts combinational logic; reject every other warning, including boxed fanout.
        allowed_warnings = {'ABC: Warning: The network is combinational.',
                            'ABC: Warning: The network is combinational (run \"fraig\" or \"fraig_sweep\").'}
        warnings = [line for line in result.stdout.splitlines() if 'Warning:' in line
                    and line not in allowed_warnings]
        # reject failed mapping or an unapproved diagnostic.
        if result.returncode or warnings:
            raise RuntimeError(f'control synthesis failed: {build / (name + ".log")}')
        cells = json.loads(netlist.read_text())['modules']['drg5_control']['cells']
        results[name] = {'exit': result.returncode,
                         'cells': dict(sorted(Counter(cell['type'] for cell in cells.values()).items())),
                         'netlist_sha256': hashlib.sha256(netlist.read_bytes()).hexdigest()}
        print(name, json.dumps(results[name]['cells'], sort_keys=True), flush=True)
    after = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
             for path in hash_sources}
    # changed source bytes invalidate a completed mapping result.
    if before != after:
        raise RuntimeError('control synthesis sources changed during qualification')
    # source and executable identities bind the measurements to the actual run.
    summary = {'scope': 'ECP5 classic-ABC synthesis of forwarded overlapping packet-control prototype; no route or timing claim',
               'assertions': 'ignored only by synthesis; active in separate simulation qualification',
               'results': results,
               'yosys': subprocess.check_output([str(yosys), '-V'], text=True).strip(),
               'yosys_wrapper_sha256': hashlib.sha256(yosys.read_bytes()).hexdigest(),
               'sources': after}
    (build / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')


# direct invocation never runs during module import.
if __name__ == '__main__':
    main()
