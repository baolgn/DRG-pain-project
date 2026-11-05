#!/usr/bin/env python3
"""bound fetch safety and require both a wrap witness and a failing detector."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    """retain exact proof commands, assumptions, bounds and source identities."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--yosys', required=True)
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-fetch-formal'))
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    rtl = here.parent / 'rtl'
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    yosys = shutil.which(args.yosys) or str(Path(args.yosys).resolve())
    sources = [rtl / (name + '.sv') for name in
               ['drg5_fetch_guard', 'drg5_fetch_buffer', 'drg5_fetch']]
    sources.append(here / 'drg5_fetch_formal.sv')
    results = {}
    # the witness prevents a proof horizon that never permits live generation wrap.
    for name, compressed, mutation, witness in [('c0', 0, 0, False), ('c1', 1, 0, False),
                                                ('negative', 0, 1, False), ('wrap', 0, 0, True)]:
        script = ('read_verilog -D SYNTHESIS -formal -sv ' + ' '.join(map(str, sources)) +
                  f'; chparam -set C_FETCH {compressed} -set MUTATE_DROP {mutation} drg5_fetch_formal; '
                  'prep -top drg5_fetch_formal -flatten; async2sync; chformal -lower; '
                  'opt_clean; check -assert; select -assert-count 12 t:$assert; '
                  'select -assert-count 1 t:$assume; ')
        # both proof and witness use arbitrary defined inputs after initial isolation.
        if witness:
            script += ('sat -seq 20 -set-assumes -set-def-inputs -set-init-undef '
                       '-set-at 20 wrap_live_seen_o 1 -show-inputs -show-outputs -timeout 45')
        # a failed safety proof is mandatory only for the deliberately corrupted check.
        else:
            script += ('sat -seq 20 -verify -prove-asserts -set-assumes -set-def-inputs '
                       '-set-init-undef -show-inputs -timeout 45')
        command = [yosys, '-Q', '-T', '-p', script]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, check=False)
        (build / (name + '.log')).write_text('$ ' + ' '.join(command) + '\n' + result.stdout)
        expected = 'SAT solving finished - model found:' if witness else \
                   'ERROR: Called with -verify and proof did fail!' if mutation else \
                   'SAT proof finished - no model found: SUCCESS!'
        correct_status = result.returncode != 0 if mutation else result.returncode == 0
        # syntax errors, timeouts and missing checks cannot qualify the run.
        if not correct_status or expected not in result.stdout:
            raise RuntimeError(f'{name}: expected outcome missing; see {build}')
        results[name] = {'exit_code': result.returncode, 'expected_outcome_seen': True}
        print('FETCH_FORMAL_PASS', name)
    sources.append(Path(__file__).resolve())
    summary = {'scope': 'bounded safety for 20 synchronous transitions; not an unbounded liveness proof',
               'generation_bits': 2, 'tag_bits': 4, 'deadline_clocks': 8,
               'assertions': 12, 'assumptions': ['initial qualified cold reset only'],
               'witness': 'same revoked owner returns to its launch generation and completes with a nonfatal drop',
               'results': results,
               'sources': {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                           for path in sources}}
    (build / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')


# permit inspection without starting solver processes.
if __name__ == '__main__':
    main()
