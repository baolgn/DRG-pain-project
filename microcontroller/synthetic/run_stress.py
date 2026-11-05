#!/usr/bin/env python3
"""run source-bound synthetic endurance, containment and detector campaigns."""
import argparse
from datetime import datetime, timezone
import gzip
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
HZ = 80000000


def digest(path):
    """hash exact inputs or retained outputs."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def ledger_check(path, result):
    """independently reconstruct ordered block, timestamp and final partial accounting."""
    data = path.read_bytes()
    assert len(data) % 64 == 0, 'ledger framing'
    expected = {0: 0, 1: 0}
    frames = raw_bytes = 0
    previous_release = 0
    # each fixed-size row is one unique complete host observation.
    for offset in range(0, len(data), 64):
        epoch, count, block, generation, first, published, released, payload_crc, header_crc, size = struct.unpack_from('<IIQQQQQIIQ', data, offset)
        assert epoch in expected and block == expected[epoch], 'ledger block ordering'
        expected[epoch] += 1
        assert 0 < count <= 256 and generation > 0 and size == 64 + count * 48, 'ledger count'
        tick = block * 409600 + (39 * 409600 + result['phase_seed_mod160'] if epoch else 0)
        assert first == tick, 'ledger independent aperture'
        assert released >= published and released >= previous_release, 'release ordering'
        previous_release = released
        # only the measured epoch contributes to the requested duration and byte count.
        if epoch == 1:
            frames += count
            raw_bytes += size
    assert frames == result['delivered_frames'] and raw_bytes == result['raw_bytes'], 'ledger totals'
    assert expected[1] == result['blocks'], 'ledger block total'
    return {'rows': len(data) // 64, 'measured_frames': frames, 'measured_bytes': raw_bytes,
            'uncompressed_sha256': digest(path)}


def main():
    """preserve failed attempts and distinguish healthy service from expected containment."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--skip-endurance', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    sources = [Path(__file__), ROOT / 'microcontroller/synthetic/stress.cpp', ROOT / 'microcontroller/firmware/synthetic/kernel.h']
    identities = {str(path.relative_to(ROOT)): digest(path) for path in sources}
    # compile private immutable copies rather than a file still being edited.
    for source in sources:
        target = output / 'sources' / source.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(source, target)
    binary = output / 'synthetic-stress'
    compiler = Path(shutil.which('g++')).resolve()
    command = [str(compiler), '-std=c++20', '-O3', '-Wall', '-Wextra', '-Werror',
               str(output / 'sources/microcontroller/synthetic/stress.cpp'), '-lz', '-o', str(binary)]
    result = {'created_utc': datetime.now(timezone.utc).isoformat(), 'source_sha256': identities,
              'compiler': subprocess.check_output([str(compiler), '--version'], text=True),
              'compiler_sha256': digest(compiler), 'build_command': command, 'cases': [],
              'scope': 'full-record event model and native DSP; firmware elapsed time is a 64000-cycle assumption, not a 30-minute RTL execution',
              'hardware_tested': False, 'full_soc_30_minute_pass': False}
    # a warning is a failed build, never a suppressed qualification finding.
    with (output / 'build.log').open('w') as log:
        built = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=False)
    result['build_exit'] = built.returncode
    cases = [('host100-0', 0.35, 'host100', 'none', 0, None),
             ('host100-305419896', 0.35, 'host100', 'none', 305419896, None),
             ('reserve-rejected', 0.1, 'insufficient-reserve', 'none', 0, None),
             ('host-overload', 1, 'host-starve', 'none', 0, None),
             ('memory-before-accept', 0.1, 'memory-outage', 'none', 0, None),
             ('memory-response-lost', 0.1, 'memory-response-lost', 'none', 0, None),
             ('memory-no-effect-error', 0.1, 'memory-error', 'none', 0, None),
             ('debug-halt', 0.05, 'debug-halt', 'none', 0, None),
             ('CPU-reset', 0.05, 'cpu-reset', 'none', 0, None)]
    negatives = {'wrong-sample': 'sample-or-slot', 'drop-record': 'sample-or-slot',
                 'crc-corruption': 'payload-crc', 'duplicate-write': 'duplicate-memory-effect',
                 'stale-generation': 'stale-generation', 'publish-early': 'publish-before-completion',
                 'duplicate-ack': 'duplicate-acknowledgement', 'raw-write': 'raw-write-denied',
                 'generation-wrap': 'generation-exhausted'}
    # each mutation must fail its intended ordinary check, not an unrelated crash.
    for mutation, reason in negatives.items():
        cases.append(('detector-' + mutation, 0.05, 'steady', mutation, 1, reason))
    # exactly 1800 simulated seconds include 90 million frames and a terminal partial block.
    if not args.skip_endurance:
        cases.append(('endurance-1800s', 1800, 'healthy', 'none', 0, None))
    passed = built.returncode == 0
    # a failed build cannot supply detector or endurance evidence.
    if passed:
        result['executable_sha256'] = digest(binary)
        linkage = subprocess.check_output(['ldd', str(binary)], text=True)
        (output / 'runtime-linkage.txt').write_text(linkage)
        result['runtime_sha256'] = {name: digest(name) for name in re.findall(r'(?:=>\s+|^\s*)(/\S+)', linkage, re.MULTILINE)}
        # each case receives a distinct input/output directory and an independently checked ledger.
        for name, seconds, scenario, mutation, seed, failure in cases:
            directory = output / name; directory.mkdir()
            invocation = [str(binary), str(round(seconds * HZ)), scenario, mutation,
                          str(directory / 'ledger.bin'), str(directory / 'result.json'), str(seed)]
            started = time.monotonic()
            # logs survive a model failure or an interrupted endurance run.
            with (directory / 'run.log').open('w') as log:
                run = subprocess.run(invocation, stdout=log, stderr=subprocess.STDOUT, check=False, timeout=3600)
            text = (directory / 'run.log').read_text()
            row = {'name': name, 'scenario': scenario, 'seed': seed, 'simulated_seconds': seconds,
                   'command': invocation, 'exit': run.returncode, 'wall_seconds': time.monotonic() - started}
            # expected containment is reported separately from healthy operation.
            if failure:
                row['expected_failure'] = failure
                row['passed'] = run.returncode != 0 and text.count('SYNTHETIC_MODEL_FAILURE ' + failure + '\n') == 1
            # positive cases must pass both native invariants and independent ledger replay.
            else:
                row['passed'] = run.returncode == 0 and text.count('SYNTHETIC_MODEL_PASS') == 1
                # an ordinary failure retains all artifacts and its actual reason.
                if row['passed']:
                    observed = json.loads((directory / 'result.json').read_text())
                    row['observed'] = observed
                    row['ledger'] = ledger_check(directory / 'ledger.bin', observed)
                    row['healthy_service_pass'] = scenario in ['healthy', 'host100'] and not observed['stopped']
                    # exact finite-duration storage differs from rate times duration by the terminal header fraction.
                    if scenario == 'healthy':
                        assert observed['generated_frames'] == 90000000 and observed['raw_bytes'] == 4342500032
                        assert observed['blocks'] == 351563 and observed['native_DSP_jobs'] == 351562
                        assert observed['host_stalls'] == 30
            ledger = directory / 'ledger.bin'
            # compression retains the complete per-block evidence rather than only aggregate counts.
            if ledger.exists():
                packed = gzip.compress(ledger.read_bytes(), mtime=0)
                ledger.with_suffix('.bin.gz').write_bytes(packed)
                assert gzip.decompress(packed) == ledger.read_bytes()
                ledger.unlink()
            row['artifact_sha256'] = {p.name: digest(p) for p in directory.iterdir() if p.is_file()}
            result['cases'].append(row); passed &= row['passed']
            (output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
            print(('PASS ' if row['passed'] else 'FAIL ') + name, flush=True)
    result['source_stable'] = identities == {str(path.relative_to(ROOT)): digest(path) for path in sources}
    passed &= result['source_stable']
    result['status'] = 'passed' if passed else 'failed'
    result['endurance_executed'] = not args.skip_endurance and passed
    (output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    # no workload or detector failure is hidden by later successful cases.
    if not passed:
        raise RuntimeError('synthetic campaign failed: ' + str(output))
    print('SYNTHETIC_CAMPAIGN_PASS')


# importing the runner does not start a long campaign.
if __name__ == '__main__':
    main()
