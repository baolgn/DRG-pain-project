#!/usr/bin/env python3
"""qualify JTAG-only wrapper reset, ownership, acquisition guards and containment."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


# complete commands and source snapshots remain available even after a failed attempt.
def main():
    """execute the complete system fixture against a stable source revision."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verilator', required=True)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--evidence-dir', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    evidence = args.evidence_dir.resolve() if args.evidence_dir else root / 'microcontroller/tests/evidence/debug-system-2026-11-04'
    revisions = evidence / 'revisions'
    revisions.mkdir(parents=True, exist_ok=True)
    revision = revisions / f'{len(list(revisions.iterdir()))+1:02d}-qualification'
    revision.mkdir()
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    package = 'microcontroller/rtl/drg5_control_pkg.sv'
    rtl = [package] + [str(path.relative_to(root)) for path in sorted((root/'microcontroller/rtl').glob('*.sv'))
                       if str(path.relative_to(root)) != package]
    fixture = 'microcontroller/tests/drg5_debug_system_tb.sv'
    names = rtl + [fixture, 'microcontroller/tests/run_debug_system.py', 'microcontroller/rtl/drg5_datapath_defs.svh']
    hashes = {}
    # archive exact input bytes before compiling or exercising any target behavior.
    for name in names:
        source = root / name
        target = revision / 'sources' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        hashes[name] = hashlib.sha256(source.read_bytes()).hexdigest()
    summary = {'status':'running', 'source_sha256':hashes, 'revision':revision.name,
               'runs':[], 'negative_controls':[],
               'scope':'JTAG transport, DM, CPU/frontend and independent memory models; physical tools tested separately'}

    # ordinary checks keep each bounded command and its diagnostics together.
    def run(command, name, detector=None):
        """execute one command and reject warnings or unrelated failures."""
        result = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=600)
        (revision / f'{name}.log').write_text(result.stdout)
        (revision / f'{name}.command.json').write_text(json.dumps(command, indent=2)+'\n')
        # a mutation passes only through its named ordinary assertion.
        if detector:
            assert result.returncode != 0 and detector in result.stdout and 'SYSTEM_PASS' not in result.stdout, (name, result.stdout[-3000:])
        # normal builds and simulations retain strict warning handling.
        else:
            assert result.returncode == 0 and '%Warning' not in result.stdout, (name, result.stdout[-3000:])
        return result.stdout

    # incomplete runs retain a running record and never overwrite their own revision.
    try:
        summary['verilator'] = run([args.verilator, '--version'], 'version').strip()
        command = [args.verilator, '--binary', '--timing', '--assert', '-Wall', '-j', '2', '-CFLAGS', '-O0',
                   '-Imicrocontroller/rtl', '--top-module', 'drg5_debug_system_tb', '--Mdir', str(build), *rtl, fixture]
        run(command, 'build')
        # seeds vary the delayed code-write/resume overlap without changing the directed obligations.
        for seed in [0, 1, 305419896]:
            output = run([str(build/'Vdrg5_debug_system_tb'), f'+seed={seed}'], f'seed-{seed}')
            match = re.search(r'SYSTEM_PASS (.*)', output)
            assert match, output[-3000:]
            metrics = {key:int(value) for key, value in re.findall(r'(\w+)=(\d+)', match[1])}
            summary['runs'].append(metrics)
            print('SYSTEM_PASS '+match[1], flush=True)
        wrapper_name = 'microcontroller/rtl/drg5_debug_system.sv'
        original = (root/wrapper_name).read_text()
        mutations = [
            ('acquisition_guard', '(!sb_req_write_o || (!acquisition_active_i && !buffer_owned_i)) &&',
             '((!sb_req_write_o || (!acquisition_active_i && !buffer_owned_i)) || halted_o) &&',
             'SBA completion status mismatch'),
            ('early_resume', 'dm_resume && !sb_owned_q && !dm_sb_valid && !dm_reset',
             'dm_resume && !dm_reset', 'resume bypassed an unfinished code write'),
            ('lost_reset', 'if (dm_reset) reset_pending_q <= 1;',
             'if (dm_reset) reset_pending_q <= 0;', 'short ndmreset request lost'),
        ]
        # mutations alter only a temporary production copy and reuse the unchanged checker.
        for name, before, after, detector in mutations:
            assert original.count(before) == 1, name
            mutant_dir = build/'mutations'/name
            mutant_dir.mkdir(parents=True, exist_ok=True)
            mutant = mutant_dir/'drg5_debug_system.sv'
            mutant.write_text(original.replace(before, after))
            shutil.copyfile(mutant, revision/f'{name}.sv')
            mutant_sources = [str(mutant) if item == wrapper_name else item for item in rtl]
            mutated_build = [args.verilator, '--binary', '--timing', '--assert', '-Wall', '-j', '2', '-CFLAGS', '-O0',
                             '-Imicrocontroller/rtl', '--top-module', 'drg5_debug_system_tb', '--Mdir', str(mutant_dir),
                             *mutant_sources, fixture]
            run(mutated_build, name+'-build')
            run([str(mutant_dir/'Vdrg5_debug_system_tb'), '+seed=1'], name, detector)
            summary['negative_controls'].append({'name':name, 'detector':detector, 'detected':True})
        # source stability prevents a matrix from spanning unrecorded production revisions.
        for name, expected in hashes.items():
            assert hashlib.sha256((root/name).read_bytes()).hexdigest() == expected, name
        summary['status'] = 'passed'
    # retain full partial results if elaboration, assertions or source attribution fail.
    finally:
        (revision/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
        (evidence/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')


# importing the runner must not launch simulator processes.
if __name__ == '__main__':
    main()
