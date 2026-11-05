#!/usr/bin/env python3
"""audit synthetic evidence while keeping modeled, RTL and physical claims separate."""
import argparse
from bisect import bisect_left, bisect_right
from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path
import re
import runpy
import struct
import zlib

ROOT = Path(__file__).resolve().parents[2]
HZ, PERIOD, BLOCK_TICKS = 80000000, 1600, 409600
DETECTORS = {'wrong-sample': 'sample-or-slot', 'drop-record': 'sample-or-slot',
    'crc-corruption': 'payload-crc', 'duplicate-write': 'duplicate-memory-effect',
    'stale-generation': 'stale-generation', 'publish-early': 'publish-before-completion',
    'duplicate-ack': 'duplicate-acknowledgement', 'raw-write': 'raw-write-denied',
    'generation-wrap': 'generation-exhausted'}
SCENARIOS = {'host100-0': 'host100', 'host100-305419896': 'host100', 'reserve-rejected': 'insufficient-reserve',
    'host-overload': 'host-starve', 'memory-before-accept': 'memory-outage',
    'memory-response-lost': 'memory-response-lost', 'memory-no-effect-error': 'memory-error',
    'debug-halt': 'debug-halt', 'CPU-reset': 'cpu-reset', 'endurance-1800s': 'healthy'}
HEALTHY = {'host100-0', 'host100-305419896', 'endurance-1800s'}
GUARD_CASES = {'300-frames-variable-formation-and-backpressure', '191-to-192-highwater-current-frame-completes',
    '256-full-no-trigger-no-overwrite-exact-loss', 'debug-halt-mid-frame-retains-counters',
    'CPU-reset-mid-frame-retains-counters', 'timeout-invalid-and-late-drain',
    'inclusive-deadline-success-and-duplicate-drain', 'timeout-next-slot-collision-counts-both-outcomes',
    'memory-outage-late-fault-drain', 'memory-deadline-late-fault-drain', 'no-credit-before-trigger',
    'ring-capacity-stop', 'lease-overrun-stop', 'event-overflow-exact-loss-W1C-and-concurrent-transfer',
    'offered-record-survives-premature-close', 'all-1600-stop-phases-and-final-aperture',
    'obsolete-epoch-completion-cannot-resolve-new-slot', 'event-overflow-stops-active-epoch',
    'external-loss-count-cannot-exceed-accepted-records', 'scheduled-counter-limit-stops-without-wrap',
    'event-counter-saturation-flags-inexact-accounting', 'P25-profile-rejected'}


def require(condition, reason):
    """reject incomplete or internally inconsistent evidence."""
    # a failed check never emits a passing aggregate report.
    if not condition:
        raise ValueError(reason)


def digest(path):
    """identify exact source or artifact bytes."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read(path):
    """read an existing structured observation without modifying it."""
    return json.loads(Path(path).read_text())


def sources(mapping, snapshot=None):
    """bind current implementation and retained source copies."""
    require(bool(mapping), 'empty source attribution')
    # source snapshots must match both current code and their recorded identity.
    for name, expected in mapping.items():
        require(digest(ROOT / name) == expected, 'changed source: ' + name)
        # only explicitly retained snapshots satisfy historical source attribution.
        if snapshot is not None:
            require(digest(snapshot / name) == expected, 'changed snapshot: ' + name)


def artifacts(directory, mapping):
    """verify every attributed file instead of trusting a status label."""
    require(bool(mapping), 'empty artifact attribution')
    # changed logs, ledgers and executable images invalidate their observations.
    for name, expected in mapping.items():
        require(digest(directory / name) == expected, 'changed artifact: ' + str(directory / name))


def ledger_audit(directory, case):
    """reconstruct block order, header CRC, timing and finite-duration byte accounting."""
    observed = case['observed']; data = gzip.decompress((directory / 'ledger.bin.gz').read_bytes())
    require(len(data) % 64 == 0 and hashlib.sha256(data).hexdigest() == case['ledger']['uncompressed_sha256'], 'ledger framing/hash')
    indexes = {0: 0, 1: 0}; frames = raw_bytes = old_frames = 0; previous_release = 0
    releases = []; publications = []; release_bytes = [0]; measured = []; max_publication = 0
    # every ledger row describes one host-validated block, including the explicit prehistory epoch.
    for epoch, count, block, generation, first, published, released, payload_crc, header_crc, size in struct.iter_unpack('<IIQQQQQIIQ', data):
        require(epoch in indexes and block == indexes[epoch], 'ledger block order')
        indexes[epoch] += 1
        require(0 < count <= 256 and generation > 0 and size == 64 + count * 48, 'ledger record size')
        base = 39 * BLOCK_TICKS + observed['phase_seed_mod160'] if epoch else 0
        require(first == base + block * BLOCK_TICKS, 'ledger aperture')
        require(released >= published and released >= previous_release, 'ledger release order')
        previous_release = released; releases.append(released); release_bytes.append(release_bytes[-1] + size)
        require(not publications or published >= publications[-1], 'ledger publication order')
        publications.append(published)
        header = struct.pack('<IHHIIQQQIHHIII', 0x31534744, 1, 64, epoch, 1, block, block * 256,
                             first, PERIOD, count, 48, count * 48, 0x80000000 | (3 if count < 256 else 0), payload_crc)
        require(len(header) == 60 and zlib.crc32(header) == header_crc, 'ledger header CRC')
        # measured frame clocks are relative to the active epoch, not its prehistory timestamp offset.
        if epoch:
            reference = block * BLOCK_TICKS + observed['phase_seed_mod160'] + (count - 1) * PERIOD
            require(0 <= published - reference <= 8000, 'publication deadline')
            max_publication = max(max_publication, published - reference)
            require(count != 256 or released >= reference + 64000, 'release before modeled CPU lease')
            frames += count; raw_bytes += size; measured.append((block, count, released))
        # initial backlog consumes capacity and transport service but is excluded from duration totals.
        else:
            old_frames += count
    require(frames == observed['delivered_frames'] == case['ledger']['measured_frames'] and
            raw_bytes == observed['raw_bytes'] == case['ledger']['measured_bytes'], 'ledger totals')
    require(indexes[1] == observed['blocks'] and old_frames == observed['initial_backlog_frames'] and
            len(data) // 64 == case['ledger']['rows'], 'ledger epoch totals')
    require(max_publication == observed['maximum_publication_cycles'], 'publication maximum attribution')
    return {'rows': len(data) // 64, 'frames': frames, 'bytes': raw_bytes, 'prehistory_frames': old_frames,
            'measured': measured, 'releases': releases, 'publications': publications, 'release_bytes': release_bytes,
            'max_publication_cycles': max_publication}


def stall_audit(observed, ledger):
    """derive free capacity from modeled allocations and actual ledger release times."""
    stalls = observed['stalls']; blocks = observed['blocks']; phase = observed['phase_seed_mod160']
    require(len(stalls) == observed['host_stalls'] and stalls and stalls[0]['free_at_onset'] == 24, 'stall admission')
    old = ledger['prehistory_frames'] // 256
    releases = ledger['releases']; release_bytes = ledger['release_bytes']; worst = peak = checks = 0

    def free_at(tick, after_allocation):
        """release completions precede capture allocation on a shared model edge."""
        numerator = tick - phase + (BLOCK_TICKS if after_allocation else BLOCK_TICKS - 1)
        allocated = min(blocks, max(0, numerator // BLOCK_TICKS))
        return 64 - old - allocated + bisect_right(releases, tick)

    # later outages must restore their actual baseline, even when it exceeds 24 free slots.
    for index, stall in enumerate(stalls):
        onset, returned, restored = stall['onset'], stall['return'], stall['restored']
        require(returned - onset == HZ // 10 and restored >= returned and restored - returned <= 8800000, 'stall recovery deadline')
        baseline = free_at(onset, index == 0)
        require(baseline == stall['free_at_onset'] and baseline >= 24, 'actual stall baseline')
        require(free_at(restored, False) >= baseline, 'actual reserve restoration')
        require(index == 0 or onset > stalls[index - 1]['restored'], 'overlapping stall recovery')
        first = max(0, (onset - phase + BLOCK_TICKS - 1) // BLOCK_TICKS)
        last = min(blocks - 1, (restored - phase) // BLOCK_TICKS)
        minimum = min([baseline] + [free_at(block * BLOCK_TICKS + phase, True) for block in range(first, last + 1)])
        require(minimum == stall['minimum_free'] and baseline - minimum <= 22, 'incremental occupied capacity')
        idle = stall['eligible_source_empty_tick']
        require(idle > returned and 0 < stall['pending_ACKs_at_empty'] <= 2, 'eligible-source-empty attribution')
        eligible = bisect_right(ledger['publications'], idle)
        require(eligible > 0 and releases[eligible - 1] == idle + 80000 and
                eligible - bisect_right(releases, idle) == stall['pending_ACKs_at_empty'], 'source-empty ledger reconstruction')
        end = min(restored, idle); latency = 365632
        begin_index = bisect_left(releases, returned)
        end_index = bisect_left(releases, end)
        ticks = [tick - 1 for tick in releases[begin_index:end_index]] + [end - 1]
        # the minimum service slack occurs immediately before an ACK, or when backlog ends.
        for tick in ticks:
            # no positive service is required during the documented initial latency.
            if tick <= returned + latency:
                continue
            delivered = release_bytes[bisect_right(releases, tick)] - release_bytes[begin_index]
            require(delivered * 16 >= tick - returned - latency, 'backlogged 5 MB/s service curve')
            checks += 1
        peak = max(peak, baseline - minimum); worst = max(worst, restored - returned)
    require(worst == observed['maximum_reserve_restore_cycles'], 'reserve maximum attribution')
    return {'interruptions': len(stalls), 'max_restore_clocks': worst, 'max_incremental_blocks': peak,
            'actual_baselines': [stall['free_at_onset'] for stall in stalls], 'service_curve_checks': checks}


def model_audit(evidence, cohort):
    """verify the long full-record model without promoting assumed CPU timing to RTL evidence."""
    directory = evidence / cohort; report = read(directory / 'summary.json')
    require(report['status'] == 'passed' and report['source_stable'] and report['endurance_executed'], 'model campaign incomplete')
    require(report['build_exit'] == 0 and not report['hardware_tested'] and not report['full_soc_30_minute_pass'], 'model scope')
    require(set(report['source_sha256']) == {'microcontroller/synthetic/run_stress.py',
            'microcontroller/synthetic/stress.cpp', 'microcontroller/firmware/synthetic/kernel.h'}, 'model source inventory')
    sources(report['source_sha256'], directory / 'sources')
    artifacts(directory, {'synthetic-stress': report['executable_sha256']})
    require(digest(report['build_command'][0]) == report['compiler_sha256'], 'native compiler identity')
    artifacts(Path('/'), report['runtime_sha256'])
    require(all(flag in report['build_command'] for flag in ['-Wall', '-Wextra', '-Werror']), 'strict native build')
    names = [case['name'] for case in report['cases']]
    require(len(names) == len(set(names)) == 19 and set(names) == set(SCENARIOS) | {'detector-' + name for name in DETECTORS}, 'model case coverage')
    observations = {}; endurance = None
    # each named case must retain its own logs and complete compressed ledger, including failures.
    for case in report['cases']:
        name = case['name']; location = directory / name
        require(case['passed'] and 'run.log' in case['artifact_sha256'], 'model case failed: ' + name)
        artifacts(location, case['artifact_sha256'])
        log = (location / 'run.log').read_text()
        require(int(case['command'][1]) == round(case['simulated_seconds'] * HZ), 'case duration invocation')
        seed = 305419896 if name == 'host100-305419896' else int(name.startswith('detector-'))
        require(len(case['command']) == 7 and case['seed'] == int(case['command'][6]) == seed, 'model seed identity')
        require(Path(case['command'][0]).resolve() == (directory / 'synthetic-stress').resolve() and
                Path(case['command'][4]).resolve() == (location / 'ledger.bin').resolve() and
                Path(case['command'][5]).resolve() == (location / 'result.json').resolve(), 'model invocation paths')
        # every detector must fail its ordinary checker for its intended reason, never by crashing.
        if name.startswith('detector-'):
            reason = DETECTORS[name.removeprefix('detector-')]
            require(case['scenario'] == 'steady' and case['command'][2:4] == ['steady', name.removeprefix('detector-')], 'detector scenario invocation')
            require(case['expected_failure'] == reason and case['exit'] != 0 and
                    log.count('SYNTHETIC_MODEL_FAILURE ' + reason + '\n') == 1 and 'SYNTHETIC_MODEL_PASS' not in log, 'wrong detector reason')
            observations[name] = {'detected': reason}
            continue
        require(case['exit'] == 0 and log.count('SYNTHETIC_MODEL_PASS') == 1 and
                {'result.json', 'ledger.bin.gz'} <= set(case['artifact_sha256']), 'positive model result')
        observed = read(location / 'result.json'); require(observed == case['observed'] and observed['status'] == 'passed', 'model observation attribution')
        require(case['scenario'] == observed['scenario'] == SCENARIOS[name] and
                case['command'][2:4] == [SCENARIOS[name], 'none'], 'model scenario identity')
        require(observed['phase_seed_mod160'] == seed % 160, 'model seed phase')
        require(observed['duration_ticks'] == round(case['simulated_seconds'] * HZ), 'observed model duration')
        require(observed['generated_frames'] == observed['delivered_frames'] + observed['lost_tail_frames'], 'frame loss accounting')
        require(observed['transaction_replays'] == observed['future_triggers_after_stop'] == 0, 'containment replay/trigger')
        require(observed['maximum_publication_cycles'] <= 8000 and observed['maximum_transport_staging_bytes'] <= 32768, 'model service capacity')
        require(observed['peak_queued_capture_bytes_including_metadata'] <= 252, 'capture FIFO capacity')
        require(observed['modeled_firmware_response_cycles'] in [0, 64000], 'model CPU timing assumption')
        ledger = ledger_audit(location, case)
        item = {key: value for key, value in ledger.items() if key not in ['measured', 'releases', 'publications', 'release_bytes']}
        item['peak_capture_queued_bytes'] = observed['peak_queued_capture_bytes_including_metadata']
        item['peak_transport_staging_bytes'] = observed['maximum_transport_staging_bytes']
        # healthy cases must satisfy the stated stall assumptions and complete the entire scheduled interval.
        if name in HEALTHY:
            require(case['healthy_service_pass'] and not observed['stopped'] and observed['admitted'] and
                    observed['generated_frames'] == observed['duration_ticks'] // PERIOD, 'healthy acquisition interval')
            require(observed['capture_words'] == observed['generated_frames'] * 12 + observed['blocks'] * 32,
                    'capture payload and descriptor word counts')
            require(observed['transport_words_including_prehistory'] ==
                    (observed['generated_frames'] + ledger['prehistory_frames']) * 12 + ledger['rows'] * 32,
                    'transport payload and descriptor word counts')
            require(observed['CPU_sample_words'] == observed['native_DSP_jobs'] * 16 and
                    observed['reserved_IRQ_episodes'] == observed['native_DSP_jobs'] * 9, 'modeled firmware work accounting')
            item['stall'] = stall_audit(observed, ledger)
        # intentional containment does not satisfy an uninterrupted healthy-service pass.
        else:
            stop_reason = {'reserve-rejected': 'stall-reserve-rejected', 'host-overload': 'ring-exhausted'}.get(name, SCENARIOS[name])
            require(not case['healthy_service_pass'] and observed['stopped'] and observed['stop_reason'] == stop_reason and
                    observed['admitted'] == (name != 'reserve-rejected'), 'containment classification')
        # rejected reserve admission must perform no new capture or native analysis work.
        if name == 'reserve-rejected':
            require(observed['generated_frames'] == observed['delivered_frames'] == observed['blocks'] ==
                    observed['native_DSP_jobs'] == observed['capture_words'] == 0 and
                    observed['first_stall_free_slots'] == 23, 'reserve rejection accounting')
        # uncertain memory service preserves the original owner and drains exactly one late result.
        if name in ['memory-before-accept', 'memory-response-lost']:
            require(observed['fault_request_effects'] == observed['fault_request_responses'] == 1 and
                    observed['stop_tick'] - observed['fault_first_valid_tick'] == 132 and
                    observed['late_original_completion_tick'] > observed['stop_tick'] and observed['tail_drain_fault'], 'uncertain memory containment')
        # a timely error is separately required to guarantee no memory effect.
        if name == 'memory-no-effect-error':
            require(observed['fault_request_effects'] == 0 and observed['fault_request_responses'] == 1 and
                    observed['stop_tick'] - observed['fault_first_valid_tick'] == 16, 'no-effect error response')
        # these exact totals include the final 128-record block and exclude all initial backlog.
        if name == 'endurance-1800s':
            require(case['simulated_seconds'] == 1800 and observed['duration_ticks'] == 144000000000 and
                    observed['generated_frames'] == observed['delivered_frames'] == 90000000 and
                    observed['blocks'] == 351563 and observed['raw_bytes'] == 4342500032 and
                    observed['native_DSP_jobs'] == 351562 and observed['host_stalls'] == 30, '1800-second exact totals')
            require(ledger['measured'][-1][:2] == (351562, 128) and ledger['prehistory_frames'] == 9984, 'terminal partial/prehistory')
            endurance = item
        observations[name] = item
    require(endurance is not None, 'missing endurance evidence')
    return {'cohort': cohort, 'cases': 19, 'detectors': DETECTORS, 'endurance': endurance,
            'observations': observations, 'source_sha256': report['source_sha256'], 'firmware_cycles_are_assumed': 64000}


def guard_audit(evidence):
    """verify source-bound guard fixtures and standalone synthesis without a route claim."""
    directory = evidence / 'guard-final-r4'; report = read(directory / 'summary.json')
    require(report['status'] == 'passed' and report['source_stable'] and report['cases'] == 22, 'guard campaign')
    require(set(report['source_sha256']) == {'microcontroller/rtl/drg5_acquisition_guard.sv',
        'microcontroller/tests/acquisition_guard_sim.cpp', 'microcontroller/tests/run_acquisition_guard.py',
        'microcontroller/acquisition/README.md'}, 'guard source inventory')
    sources(report['source_sha256'], directory / 'sources')
    require({profile['profile'] for profile in report['profiles']} == {'F80', 'counter-limit', 'P25-rejected'}, 'guard profiles')
    names = []; checks = cycles = 0
    # log rows and campaign summaries must describe the same executed fixtures.
    for profile in report['profiles']:
        require(profile['passed'] and profile['build_exit'] == profile['run_exit'] == 0, 'guard profile failure')
        require(digest(profile['command'][0]) == report['verilator_sha256'], 'guard simulator identity')
        require('--assert' in profile['command'] and '-Wall' in profile['command'] and
                not any(arg.startswith('-Wno') for arg in profile['command']), 'guard strict build')
        log = (directory / profile['profile'] / 'run.log').read_text()
        actual = [json.loads(line.split(' ', 1)[1]) for line in log.splitlines() if line.startswith('GUARD_CASE_PASS ')]
        require(actual == profile['cases'] and log.count('ACQUISITION_GUARD_PASS') == 1, 'guard log attribution')
        names += [case['case'] for case in actual]; checks += sum(case['checks'] for case in actual)
        cycles += sum(case['cycles'] for case in actual)
    require(len(names) == len(set(names)) == 22 and set(names) == GUARD_CASES, 'guard fixture uniqueness')
    require(checks == 15356629 and cycles == 3071207, 'guard measurement totals')
    mapped = evidence / 'guard-synthesis'; synthesis = read(mapped / 'summary.json')
    require(synthesis['status'] == 'passed' and synthesis['exit'] == 0, 'guard synthesis')
    require(digest(synthesis['command'][0]) == synthesis['yosys_sha256'], 'guard synthesis tool identity')
    sources(synthesis['source_sha256'])
    require(digest(mapped / 'drg5_acquisition_guard.sv') == digest(ROOT / 'microcontroller/rtl/drg5_acquisition_guard.sv'), 'synthesized guard snapshot')
    artifacts(mapped, {'mapped.json': synthesis['mapped_sha256']})
    cells = read(mapped / 'mapped.json')['modules']['drg5_acquisition_guard']['cells']
    counts = dict(Counter(cell['type'] for cell in cells.values()))
    require(counts == synthesis['cells'] and not any('latch' in name.lower() for name in counts), 'guard mapping/latches')
    return {'cases': 22, 'checks': checks, 'clocks': cycles, 'max_stop_clocks': 1599,
            'stop_limit_clocks': 1600, 'mapping': counts, 'source_sha256': report['source_sha256']}


def terminal_counts(path, schema):
    """recount executed operations and terminal order directly from compressed trace bytes."""
    counts = Counter(); previous_cycle = -1; fields = schema['fields']
    data = gzip.decompress(path.read_bytes())
    require(len(data) % 96 == 0, 'CPU trace framing/count')
    # fixed-width records prevent a successful prefix from hiding a truncated execution.
    for offset in range(0, len(data), 96):
        cycle = int.from_bytes(data[offset:offset + 8], 'little')
        packed = int.from_bytes(data[offset + 8:offset + 96], 'little')

        def field(name):
            """extract fields from the retained verification schema."""
            item = fields[name]
            return packed >> item['lsb'] & ((1 << item['width']) - 1)

        require(cycle > previous_cycle and field('valid') and field('order') == counts['records'], 'CPU terminal ordering')
        previous_cycle = cycle
        bits = field('packet.raw'); length = field('packet.length'); address = field('packet.mem_addr')
        require(length in [2, 4], 'CPU instruction length')
        counts['records'] += 1; counts['compressed'] += length == 2; counts['traps'] += field('trap')
        counts['MUL'] += bits & 0xfe00707f == 0x02000033
        counts['DIVU'] += bits & 0xfe00707f == 0x02005033
        counts['MRET'] += bits == 0x30200073
        counts['shared_loads'] += 0x50001000 <= address < 0x50002000
    return dict(counts)


def cpu_audit(evidence, cohort, model, guard):
    """check real CPU/debug/guard execution independently of the long-run scheduling model."""
    directory = evidence / cohort; report = read(directory / 'summary.json')
    require(report['schema'] == 'DRG5-SYNTHETIC-CPU-1' and report['status'] == 'pass' and not report['hardware_tested'], 'CPU campaign scope')
    sources(report['source_sha256'], directory / 'sources')
    firmware = report['firmware']; require(firmware == read(directory / 'firmware/build.json'), 'firmware manifest attribution')
    sources(firmware['source_sha256'], directory / 'firmware-sources')
    artifacts(directory / 'firmware', firmware['artifact_sha256'])
    provenance = read(directory / 'provenance.json')
    require(provenance['schema'] == 'DRG5-SYNTHETIC-CPU-PROVENANCE-1' and
            provenance['firmware_source_sha256'] == firmware['source_sha256'] and
            provenance['firmware_snapshot_prefix'] == 'firmware-sources' and
            provenance['replay_snapshot_prefix'] == 'replay-sources', 'CPU dependency provenance')
    replay_source = 'microcontroller/tests/replay_synthetic_cpu.py'
    require(set(provenance['replay_source_sha256']) == {replay_source}, 'CPU replay provenance inventory')
    sources(provenance['replay_source_sha256'], directory / 'replay-sources')
    oracle = 'microcontroller/tests/run_decompress.py'
    require(set(provenance['supplemental_dependency_source_sha256']) == {oracle} and
            provenance['supplemental_dependency_snapshot_prefix'] == 'supplemental-dependencies', 'CPU supplemental dependency inventory')
    sources(provenance['supplemental_dependency_source_sha256'], directory / 'supplemental-dependencies')
    prior = provenance['supplemental_dependency_prior_evidence'][oracle]
    oracle_hash = provenance['supplemental_dependency_source_sha256'][oracle]
    require(prior['byte_identical'] and digest(ROOT / prior['snapshot']) == oracle_hash and
            digest(ROOT / prior['manifest']) == prior['manifest_sha256'] and
            oracle_hash + '  ' + prior['entry'] in (ROOT / prior['manifest']).read_text().splitlines(), 'CPU dependency historical identity')
    kernel = 'microcontroller/firmware/synthetic/kernel.h'; guard_name = 'microcontroller/rtl/drg5_acquisition_guard.sv'
    require(firmware['source_sha256'][kernel] == model['source_sha256'][kernel] and
            report['source_sha256'][guard_name] == guard['source_sha256'][guard_name], 'shared implementation identity')
    require(firmware['status'] == 'built' and firmware['profile'] == 'SYNTH80' and firmware['abi'] == 'ilp32' and
            firmware['march'] == 'rv32i2p1_m2p0_c2p0_zicsr2p0_zifencei2p0', 'firmware ISA/ABI')
    require(firmware['ISA_audit']['profile'] == 'imc' and not firmware['ISA_audit']['intentional_exceptions'], 'firmware instruction audit')
    compiler = Path(firmware['commands'][0]['command'][0]); prefix = str(compiler).removesuffix('gcc')
    require(set(firmware['tool_sha256']) == {'gcc', 'as', 'ld', 'objdump', 'readelf', 'nm'}, 'firmware tool inventory')
    # every retained firmware tool is bound to its installed binary, including the ISA inspector.
    for tool, expected in firmware['tool_sha256'].items():
        require(digest(prefix + tool) == expected, 'firmware tool identity: ' + tool)
    require(all(item['exit_code'] == 0 for item in firmware['commands']), 'firmware build failure')
    command = report['command']
    compiled = {str(Path(arg).relative_to(ROOT)) for arg in command if arg.endswith(('.sv', '.cpp'))}
    require(set(report['source_sha256']) == compiled | {'microcontroller/rtl/drg5_datapath_defs.svh',
            'microcontroller/tests/run_synthetic_cpu.py', 'microcontroller/tests/replay_counter_trace.py'}, 'CPU source inventory')
    require('--assert' in command and '-Wall' in command and not any(arg.startswith('-Wno') for arg in command), 'CPU strict build')
    require('%Warning' not in (directory / 'build.log').read_text(), 'CPU build warnings')
    wrapper = ROOT / 'microcontroller/tests/synthetic/drg5_synthetic_debug.sv'
    require('TEST_REGIONS(1' in wrapper.read_text(), 'simulation permission profile')
    labels = [(run['name'], run['seed'], run['metrics']['mode']) for run in report['runs']]
    require(len(labels) == 3 and set(labels) == {('1', 1, 'continuous-stall'),
            ('305419896', 305419896, 'continuous-stall'), ('active-reset', 1, 'active-reset')}, 'CPU seed/reset coverage')
    schema = read(directory / 'trace-schema.json')
    require(schema['schema'] == 'DRG5-SYNTHETIC-TERMINAL-1' and schema['words'] == 22, 'CPU trace schema')
    layout = runpy.run_path(str(ROOT / 'microcontroller/tests/replay_counter_trace.py'))['make_schema'](
        ROOT / 'microcontroller/rtl/drg5_control_pkg.sv')
    fields = {name.removeprefix('terminal.'): item.copy() for name, item in layout['fields'].items() if name.startswith('terminal.')}
    base = min(item['lsb'] for item in fields.values())
    # the retained decoder must describe the actual packed RTL terminal structure.
    for item in fields.values():
        item['lsb'] -= base
    require(schema['fields'] == fields, 'CPU packed trace layout')
    contract = read(directory / 'contract.json')
    limits = {'instruction': 4, 'local': 4, 'MMIO': 16, 'shared': 128, 'capture': 128, 'transport': 96,
              'DSP': 64000, 'response': 320000, 'ack': 2048, 'ISR': 800, 'halt': 224, 'stop_drain': 256000}
    require(contract['schema'] == 'DRG5-SYNTHETIC-CPU-CONTRACT-1' and
            contract['status'] == 'simulation-qualified-physical-unqualified' and
            contract['profile'] == 'SYNTH80' and contract['core_clock_hz_assumed'] == HZ and
            contract['frame_period_clocks'] == PERIOD and contract['block_period_clocks'] == BLOCK_TICKS and
            contract['block_frames'] == 256 and contract['ring_blocks'] == 64 and
            contract['guard_source_sha256'] == guard['source_sha256'][guard_name] and
            contract['deadline_clocks'] == limits, 'CPU contract profile')
    results = []; maximum = {}; profiles = set(); reset_result = None
    # every run binds retained code, bus events and all architectural terminals to independent replay.
    for run in report['runs']:
        location = directory / run['name']; metrics = read(location / 'result.json')
        require(metrics == run['metrics'] and metrics['status'] == 'pass' and metrics['profile'] == 'SYNTH80', 'CPU run attribution')
        resetting = metrics['mode'] == 'active-reset'; completed = 4 if resetting else 30
        require(metrics['blocks_released'] == completed and metrics['epochs'] == 2 and
                metrics['host_stall_cycles'] == (0 if resetting else 8000000) and
                metrics['aborted_blocks'] == metrics['active_reset_observed'] == int(resetting), 'CPU workload coverage')
        artifacts(location, {'retirement.bin.gz': run['trace_sha256'], 'events.jsonl': run['events_sha256'],
            'rom.hex': firmware['artifact_sha256']['rom.hex'], 'iram.hex': firmware['artifact_sha256']['iram.hex']})
        replay = read(location / 'replay.json')
        require(replay['schema'] == 'DRG5-SYNTHETIC-REPLAY-1' and replay['status'] == 'pass' and replay['blocks'] == completed, 'CPU replay')
        require(set(replay['inputs_sha256']) == {'result.json', 'events.jsonl', 'retirement.bin.gz', 'rom.hex', 'iram.hex'}, 'CPU replay input inventory')
        artifacts(location, replay['inputs_sha256'])
        require(replay['source_sha256'] == provenance['replay_source_sha256'][replay_source], 'CPU replay source')
        counts = terminal_counts(location / 'retirement.bin.gz', schema)
        require(counts == replay['counts'] and counts['records'] == metrics['retirement_records'], 'CPU trace count attribution')
        require(counts['shared_loads'] == completed * 16 + int(resetting) and counts['MUL'] == completed * 32 and
                counts['DIVU'] == completed and counts['traps'] == 2 and counts['compressed'] > 0, 'executed arithmetic/trap counts')
        blocks = metrics['blocks']; words = sum(16 + block['records'] * 12 for block in blocks)
        require([block['id'] for block in blocks] == list(range(1, len(blocks) + 1)), 'CPU block identity')
        require(words == metrics['capture_words'] == metrics['transport_words'] and
                all(block['transported'] == 16 + block['records'] * 12 for block in blocks), 'CPU raw movement word counts')
        complete = [block for block in blocks if block['DSP_end']]
        aborted = [block for block in blocks if block['aborted']]
        uninterrupted = [block for block in complete if not block['cut']]
        require(len(complete) == completed and len(aborted) == int(resetting) and
                all(block['records'] == 256 and block['reads'] == 16 for block in complete), 'CPU block completion')
        require([block['records'] for block in blocks if block['records'] < 256] == [1, 3], 'CPU stop tail accounting')
        require(max(block['DSP_end'] - block['DSP_begin'] for block in uninterrupted) == metrics['max_DSP'] and
                max(block['DSP_end'] - block['rk'] for block in uninterrupted) == metrics['max_response'] and
                max(block['ack'] - block['published'] for block in blocks if block['ack']) == metrics['max_ack'], 'CPU timing attribution')
        require(all(0 < block['published'] - block['rk'] <= 8000 for block in blocks if block['records'] == 256), 'CPU publication deadline')
        # observed finite maxima are checked against limits without claiming a universal WCET proof.
        for name, limit in limits.items():
            value = metrics['max_' + name]
            require(0 < value <= limit, 'CPU timing limit: ' + name)
            maximum[name] = max(maximum.get(name, 0), value)
        require(metrics['timer_ack'] == metrics['software_ack'] == completed + int(resetting) and metrics['exceptions'] == 2, 'CPU peripheral exercise')
        events = [json.loads(line) for line in (location / 'events.jsonl').read_text().splitlines()]
        require([event['sequence'] for event in events] == list(range(1, len(events) + 1)) and
                all(a['cycle'] <= b['cycle'] for a, b in zip(events, events[1:])), 'CPU event continuity')
        require(sum(event['event'] == 'debug-stop-request' for event in events) == (1 if resetting else 2), 'actual debug stop missing')
        require(len(metrics['shared_phase_coverage']) == 160 and
                sum(metrics['shared_phase_coverage']) == counts['shared_loads'], 'CPU contention phase shape')
        profiles |= {phase for phase, count in enumerate(metrics['shared_phase_coverage']) if count}
        result = {'name': run['name'], 'seed': run['seed'], 'retirement_records': metrics['retirement_records'],
                  'blocks': completed, 'epochs': 2, 'actual_cycles': metrics['cycles'], 'raw_words': words, 'replay_counts': counts}
        # reset is accepted only with a real exposed shared owner and one explicit aborted DSP lease.
        if resetting:
            requests = [event for event in events if event['event'] == 'active-reset-observed']
            abandon = [event for event in events if event['event'] == 'CPU-reset-abandon']
            require(len(requests) == len(abandon) == 1 and requests[0]['shared_owner'] == 1 and
                    requests[0]['cycle'] < abandon[0]['cycle'] and abandon[0]['block'] == aborted[0]['id'], 'CPU active reset ownership')
            require(aborted[0]['reads'] == 1 and aborted[0]['cut'] and not aborted[0]['DSP_end'] and
                    sum(block['epoch'] == 2 for block in complete) == 2, 'CPU reset recovery sequence')
            require(not any(event['event'] == 'MMIO' and event.get('offset') == 24 and
                            event.get('value') == aborted[0]['id'] for event in events), 'aborted CPU result release')
            result['exposed_owner_reset_cycle'] = requests[0]['cycle']; result['owner_drained_cycle'] = abandon[0]['cycle']
            result['aborted_DSP_leases'] = 1; reset_result = result
        # halt interrupts an active DSP block and must resume that same unique result.
        else:
            require([block['id'] for block in complete if block['cut']] == [28], 'CPU mid-block halt coverage')
            results.append(result)
    require(contract['observed_max_clocks'] == maximum and contract['shared_phase_coverage_union'] == sorted(profiles), 'CPU contract measurement attribution')
    require(contract['normal_runs'] == 2 and contract['normal_blocks_each'] == 30 and
            contract['continuous_host_stall_clocks'] == 8000000 and contract['normal_halt_mid_block'] == 28 and
            contract['active_reset'] == {'blocks_completed': 4, 'aborted_CPU_leases': 1, 'epochs': 2,
                'actual_exposed_shared_owner_at_reset_request': True}, 'CPU contract coverage attribution')
    negative = report['negative_controls']
    require(len(negative) == 1 and negative[0]['name'] == 'wrong-result' and negative[0]['detected'] and
            negative[0]['detector'] == 'DSP independent result mismatch' and
            'DSP independent result mismatch' in (directory / 'wrong-result/run.log').read_text(), 'CPU detector')
    return {'cohort': cohort, 'normal_runs': results, 'active_reset': reset_result, 'observed_maxima': maximum,
            'shared_phases_observed': len(profiles), 'shared_phases_total': 160,
            'firmware_sha256': firmware['artifact_sha256']['firmware.elf'], 'dependency_provenance': provenance}


def requirements(model, cpu):
    """give every claim an explicit evidence level and retain unfulfilled system gates."""
    entries = [
        ('SYN-INTERVAL', '1800-second scheduled acquisition interval', 'event-model', [model + '/endurance-1800s']),
        ('SYN-RECORDS', '90 million eight-channel records with raw status and integrity checks', 'event-model', [model]),
        ('SYN-FORMAT', 'ordered headers, timestamps and final 128-record partial block', 'ledger-replay', [model + '/endurance-1800s']),
        ('SYN-STALL', '100 ms host stalls with at least 24 genuinely free slots', 'event-model-and-RTL-harness', [model, cpu]),
        ('SYN-RECOVERY', 'actual pre-stall reserve restored within 110 ms; at most 22 added occupied slots', 'event-model-and-ledger', [model]),
        ('SYN-MEMORY', 'capture, transport and CPU service with reserved maintenance/debug slots; bounded local JTAG/SBA activity', 'model-and-bounded-RTL', [model, cpu]),
        ('SYN-UNCERTAIN', 'late original response drains without replay or republishing failed data', 'event-model', [model]),
        ('SYN-DSP', 'shared kernel executes MUL/DIVU and preserves independent results', 'native-and-actual-RV32IMC-RTL', [model, cpu]),
        ('SYN-IRQ', 'timer, software and block notifications obey measured service limits', 'bounded-RTL', [cpu]),
        ('SYN-HALT', 'JTAG halt and guard stop preserve ownership', 'bounded-RTL', [cpu, 'guard-final-r4']),
        ('SYN-RESET', 'active CPU reset ends epoch while independent monitors persist', 'bounded-RTL', [cpu, 'guard-final-r4']),
        ('SYN-GUARD', 'all 1600 stop phases, stale frame rejection and raw invalid evidence', 'standalone-RTL', ['guard-final-r4']),
        ('SYN-EVENTS', 'overflow and concurrent clear/set remain externally observable', 'standalone-RTL', ['guard-final-r4']),
        ('SYN-COUNTERS', 'nonwrapping lifetime counters and explicit exhaustion', 'standalone-RTL', ['guard-final-r4']),
        ('SYN-DETECTORS', 'nine model defects and corrupted firmware results are detected', 'negative-controls', [model, cpu]),
        ('SYN-TRACE', 'all retained instruction records match replay inputs and bus observations', 'bounded-retirement-replay', [cpu]),
        ('SYN-MAPPING', 'guard synthesizes without unintended latches', 'standalone-synthesis', ['guard-synthesis']),
        ('SYN-FULL-SOC', '30-minute execution of the complete RTL acquisition SoC', 'unverified', []),
        ('SYN-PHYSICAL', 'physical 80 MHz acquisition timing, ADC, external memory and transport', 'unverified', []),
    ]
    return [{'id': identity, 'requirement': requirement, 'evidence_level': level, 'artifacts': paths,
             'verified_within_scope': level != 'unverified', 'physical_pass': False}
            for identity, requirement, level, paths in entries]


def audit(evidence, model_cohort, cpu_cohort):
    """read the explicitly selected final cohorts; never choose whichever attempt passes."""
    evidence = Path(evidence).resolve()
    require(all(re.fullmatch('[a-zA-Z0-9_-]+', name) for name in [model_cohort, cpu_cohort]), 'cohort directory name')
    model = model_audit(evidence, model_cohort); guard = guard_audit(evidence)
    cpu = cpu_audit(evidence, cpu_cohort, model, guard)
    records = [model_cohort + '/summary.json', 'guard-final-r4/summary.json', 'guard-synthesis/summary.json',
        cpu_cohort + '/summary.json', cpu_cohort + '/contract.json', cpu_cohort + '/provenance.json',
        cpu_cohort + '/trace-schema.json'] + [cpu_cohort + '/' + name + '/replay.json' for name in ['1', '305419896', 'active-reset']]
    return {'schema': 'DRG5-SYNTHETIC-AUDIT-1', 'artifact_consistency_passed': True,
        'overall_pass': False, 'model_30_minute_pass': True, 'bounded_RTL_pass': True,
        'full_soc_30_minute_pass': False, 'hardware_tested': False, 'physical_80mhz_qualified': False,
        'source_sha256': {str(Path(__file__).resolve().relative_to(ROOT)): digest(__file__)},
        'input_sha256': {name: digest(evidence / name) for name in records},
        'model': model, 'guard': guard, 'CPU': cpu, 'requirements': requirements(model_cohort, cpu_cohort),
        'limitations': ['the 1800-second campaign uses an event model and an assumed 64000-cycle firmware reservation',
            'actual CPU/debug/guard RTL runs cover bounded intervals, not 30 minutes',
            'external debug contention is a reserved model slot; actual local JTAG/SBA does not qualify a physical shared 192-clock service bound',
            'the CPU campaign observes 61 of 160 shared-service phases; its coverage is not an exhaustive phase sweep',
            'ledgers retain checked block identities and checksums, not every raw payload or physical ring index',
            'finite observed CPU timing maxima are not a universal firmware WCET proof',
            'external FIFO/DMA and memory/transport service are modeled; physical implementations remain unqualified',
            'no physical 80 MHz timing closure, ADC electrical timing or analog qualification is established']}


def main():
    """write only explicitly requested aggregate and requirement-matrix files."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--model-cohort', required=True)
    parser.add_argument('--cpu-cohort', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--matrix-output', type=Path)
    args = parser.parse_args(); report = audit(args.evidence, args.model_cohort, args.cpu_cohort)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    # the optional separate matrix contains exactly the same scoped requirement rows.
    if args.matrix_output:
        args.matrix_output.parent.mkdir(parents=True, exist_ok=True)
        args.matrix_output.write_text(json.dumps({'schema': 'DRG5-SYNTHETIC-MATRIX-1',
            'overall_pass': False, 'requirements': report['requirements']}, indent=2, sort_keys=True) + '\n')
    print('SYNTHETIC_ARTIFACT_AUDIT_PASS full_soc_30_minute_pass=false hardware_tested=false')


# imports never modify campaign evidence or access hardware.
if __name__ == '__main__':
    main()
