#!/usr/bin/env python3
"""check allocated ACQ-R1 timing margins without claiming physical closure."""

import argparse
from fractions import Fraction
import hashlib
import json
from math import ceil
from pathlib import Path
import sys


def require(condition, message):
    """keep all checks active under optimized Python."""
    # failed allocations must stop acceptance.
    if not condition:
        raise ValueError(message)


def digest(path):
    """bind the calculation to its exact source bytes."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def exact(value):
    """retain rational values alongside approximate nanoseconds."""
    value = Fraction(value)
    return {'numerator': value.numerator, 'denominator': value.denominator,
            'approx_ns': float(value)}


def calculate(extra_translator):
    """evaluate allocations over a superset of possible BUSY-fall positions."""
    require(extra_translator >= 0, 'additional translator delay must be nonnegative')
    billion = 1_000_000_000
    tolerance = Fraction(100, 1_000_000)
    acq_min = Fraction(billion, 80_000_000) / (1 + tolerance)
    acq_max = Fraction(billion, 80_000_000) / (1 - tolerance)
    sup_min = Fraction(billion, 10_000_000) / (1 + tolerance)
    sup_max = Fraction(billion, 10_000_000) / (1 - tolerance)
    values = {'acquisition_tick_min': acq_min, 'acquisition_tick_max': acq_max,
              'supervisor_tick_min': sup_min, 'supervisor_tick_max': sup_max,
              'slot_min': 1600 * acq_min, 'slot_max': 1600 * acq_max,
              'serial_224_periods_min': 896 * acq_min,
              'serial_224_periods_max': 896 * acq_max,
              'read_deadline_min': 1120 * acq_min,
              'read_deadline_max': 1120 * acq_max}
    margins = {}
    timelines = []
    # early positions are conservative arithmetic cases, not legal BUSY histories.
    for fall in range(161):
        cs = fall + 4
        first = cs + 4
        captures = [first + 4 * index for index in range(224)]
        last = captures[-1]
        high = last + 2
        release = high + 2
        complete = release + 4
        require(len(set(captures)) == 224, 'capture edges must be distinct')
        require(all(right - left == 4 for left, right in zip(captures, captures[1:])),
                'serial capture spacing changed')
        require(complete == fall + 908, 'exact serial edge accounting changed')
        require(complete <= 1072 < 1120 < 1600, 'read exceeds its reserved interval')
        timelines.append({'busy_fall_tick': fall, 'cs_assert_tick': cs,
                          'capture_ticks': captures, 'last_sclk_rise_tick': high,
                          'cs_release_tick': release, 'checks_complete_tick': complete})
    require(timelines[-1]['checks_complete_tick'] == 1068, 'latest completion changed')
    values.update({'read_exact_max': 1068 * acq_max,
                   'read_conservative_max': 1072 * acq_max,
                   'read_conservative_reserve_min': 48 * acq_min,
                   'next_slot_after_deadline_min': 480 * acq_min})
    margins['read_deadline_same_clock'] = 48 * acq_min
    margins['next_slot_after_deadline'] = 480 * acq_min

    # these path limits are allocations; no board or routed receiver has met them.
    fpga_out = Fraction(2)
    forward = Fraction(3, 4)
    adc_access = Fraction(157, 10)
    backward = Fraction(3, 4)
    fpga_in_setup = Fraction(2)
    uncertainty = Fraction(1)
    fpga_hold = Fraction(1)
    outgoing = fpga_out + forward
    other_capture = outgoing + backward + fpga_in_setup + uncertainty
    values['capture_half_cycle_min'] = 2 * acq_min
    values['capture_remaining_after_adc'] = 2 * acq_min - adc_access
    values['capture_non_adc_allocations'] = other_capture + extra_translator
    margins['dout_setup'] = 2 * acq_min - adc_access - other_capture - extra_translator
    margins['first_bit_setup'] = 4 * acq_min - 18 - other_capture - extra_translator
    margins['cs_setup'] = 4 * acq_min - outgoing - uncertainty - 2
    margins['cs_hold_after_final_rise'] = 2 * acq_min - outgoing - uncertainty - 2
    margins['sdi_setup'] = 2 * acq_min - outgoing - uncertainty - 9
    margins['sdi_hold'] = 2 * acq_min - outgoing - uncertainty
    margins['dout_hold_next_rise'] = 2 * acq_min + 5 - uncertainty - fpga_hold
    margins['dout_hold_cs_release'] = 4 * acq_min - uncertainty - fpga_hold
    # pulse distortion includes edge jitter; full-period distortion is separate.
    pulse_distortion = Fraction(3)
    period_distortion = Fraction(2)
    period_max = 4 * acq_max + period_distortion
    period_min = 4 * acq_min - period_distortion
    values['sclk_pin_period_max'] = period_max
    values['sclk_pin_period_min'] = period_min
    margins['sclk_high_and_low'] = 2 * acq_min - pulse_distortion - Fraction(2, 5) * period_max
    margins['sclk_max_frequency'] = period_min - Fraction(billion, 63_500_000)
    margins['convst_high'] = 8 * acq_min - pulse_distortion - 10
    margins['convst_low'] = (1600 - 8) * acq_min - pulse_distortion - 10
    margins['cs_high_before_next_transfer'] = (
        4 * acq_min - outgoing - 25 - backward - fpga_in_setup - uncertainty)

    # four ticks allocate phase, two synchronizer stages and registered recognition.
    busy_paths = Fraction(11, 2)
    busy_rise = busy_paths + 22 + 4 * acq_max + uncertainty
    busy_fall = busy_rise + 650
    values.update({'observed_busy_rise_max': busy_rise,
                   'observed_busy_fall_healthy_max': busy_fall,
                   'observed_busy_rise_deadline_min': 20 * acq_min,
                   'observed_busy_fall_deadline_min': 160 * acq_min})
    margins['observed_busy_rise'] = 20 * acq_min - busy_rise
    margins['observed_busy_fall'] = 160 * acq_min - busy_fall
    margins['healthy_fall_60_tick_ceiling'] = 60 * acq_min - busy_fall
    margins['minimum_busy_pulse_observation'] = 475 - 4 * acq_max
    margins['adc_acquisition_time'] = 1600 * acq_min - pulse_distortion - 160 * acq_max - 350
    values['healthy_read_conservative_max'] = (60 + 912) * acq_max
    values['register_transaction_max'] = 112 * acq_max
    values['register_command_budget_max'] = 160 * acq_max
    margins['register_command_same_clock'] = (160 - 112) * acq_min

    # supervisor clocks remain independent of acquisition-clock progress.
    supervision = {'clock_loss': (80, 1500, 10_000),
                   'service_cancellation': (135, 400, 14_000),
                   'drain': (99_000, 400, 10_000_000),
                   'configuration': (29_990_000, 400, 3_000_000_000)}
    # include noncounter detection and isolation latency in every hard bound.
    for name, (ticks, outside, deadline) in supervision.items():
        values[name + '_supervisor_expiry_min'] = ticks * sup_min
        values[name + '_supervisor_effect_max'] = ticks * sup_max + outside
        margins[name + '_supervisor_deadline'] = deadline - (ticks * sup_max + outside)
    margins['clean_service_cancellation'] = 135 * sup_min - 1072 * acq_max

    # all service phases consume the same accepted-command deadline.
    startup = (500_000_000 + 168_000_000 * acq_max + 800 * acq_max +
               80_000 * acq_max + 512 * 160 * acq_max + 3232 * acq_max +
               250_000_000 + 1_000_000)
    values['configuration_work_max'] = startup
    values['reset_high_min'] = 800 * acq_min - pulse_distortion
    values['post_reset_wait_min'] = 80_000 * acq_min
    values['stable_power_wait_min'] = 168_000_000 * acq_min
    margins['configuration_work'] = 29_990_000 * sup_min - startup
    margins['full_reset_pulse'] = values['reset_high_min'] - 3200
    margins['post_reset_setup'] = values['post_reset_wait_min'] - 274_000
    margins['first_power_setup_sum'] = values['stable_power_wait_min'] - 2_000_000_000

    # bandwidth covers raw records, headers and bounded publication metadata.
    bytes_per_second = 4_000_000
    full_block_bytes = 256 * 48 + 64 + 64
    publication = Fraction(full_block_bytes * billion, bytes_per_second) + 3 * 100_000
    block_period = 256 * 1600 * acq_min
    drain_records = 256 + 256 + 1 + 1
    drain_bytes = drain_records * 48 + 3 * 64 + 3 * 64
    drain = (Fraction(drain_bytes * billion, bytes_per_second) + 3 * 300_000 +
             1120 * acq_max + 2000)
    values.update({'full_block_publication_max': publication,
                   'full_block_production_min': block_period,
                   'drain_work_max': drain,
                   'host_24_block_capacity_span_min': 24 * block_period})
    margins['publication_deadline'] = 4_000_000 - publication
    margins['publication_before_next_full_block'] = block_period - 4_000_000
    margins['drain_work'] = 99_000 * sup_min - drain
    margins['host_100ms_stall_reserve'] = 24 * block_period - 100_000_000
    # normal progress must precede its watchdog instead of consuming all slack.
    values['record_handoff_work_max'] = 64 * acq_max
    values['record_handoff_deadline_max'] = 80 * acq_max
    values['frame_and_handoff_max'] = 1200 * acq_max
    margins['record_handoff_same_clock'] = (80 - 64) * acq_min
    margins['frame_and_handoff_before_slot'] = (1600 - 1200) * acq_min
    margins['normal_memory_phase_before_watchdog'] = Fraction(100_000 - 80_000)
    margins['normal_control_reply_before_deadline'] = Fraction(1000 - 800)
    margins['normal_analog_heartbeat_before_expiry'] = Fraction(2000 - 1000)

    # bounded latency variation covers arrivals while publication blocks refill.
    latency_variation = 1200 * acq_max
    publication_arrivals = ceil((publication + latency_variation) / (1600 * acq_min))
    refill = publication_arrivals * 80 * acq_max
    refill_arrivals = ceil((refill + latency_variation) / (1600 * acq_min))
    peak_records = publication_arrivals + refill_arrivals
    capacity = {'publication_arrivals': publication_arrivals,
                'refill_arrivals': refill_arrivals,
                'peak_records': peak_records,
                'high_water_records': 192,
                'margin_records': 192 - peak_records,
                'counting_scope': 'new arrivals after the prior handoff; bounded latency variation included'}
    values['fifo_refill_max'] = refill
    require(capacity['margin_records'] > 0, 'FIFO publication/refill reaches high water')

    # deliberate bad candidates must fail the actual arithmetic predicates.
    negative = {'13us_read_deadline': {'rejected': 1068 > 1040,
                                      'shortfall_ticks_exact': 1068 - 1040,
                                      'shortfall_ticks_conservative': 1072 - 1040},
                '3ns_extra_translator_path': {'rejected': 2 * acq_min - adc_access - other_capture - 3 < 0,
                                             'setup_margin_ns': exact(2 * acq_min - adc_access - other_capture - 3)}}
    # a failed negative control invalidates the checker result.
    for name, control in negative.items():
        require(control['rejected'], 'negative control unexpectedly passed: ' + name)
    result = {'status': 'arithmetic-pass-physical-unqualified',
              'assumptions': {'acquisition_clock_hz': 80_000_000,
                              'supervisor_clock_hz': 10_000_000,
                              'clock_tolerance_ppm': 100,
                              'sync_recognition_ticks': 4,
                              'extra_translator_ns': str(extra_translator),
                              'minimum_memory_bytes_per_second': bytes_per_second,
                              'publication_metadata_bytes_per_block_max': 64,
                              'full_block_bytes_with_metadata': full_block_bytes,
                              'maximum_drain_records': drain_records,
                              'maximum_drain_bytes_with_metadata': drain_bytes,
                              'normal_memory_phase_ns': 80_000,
                              'memory_phase_watchdog_ns': 100_000,
                              'memory_phases': ['grant', 'response', 'visibility', 'publication'],
                              'normal_control_reply_ns': 800,
                              'control_reply_deadline_ns': 1000,
                              'normal_analog_heartbeat_gap_ns': 1000,
                              'analog_heartbeat_earliest_expiry_ns': 2000},
              'values_ns': {name: exact(value) for name, value in values.items()},
              'margins_ns': {name: exact(value) for name, value in margins.items()},
              'fifo_capacity': capacity,
              'negative_controls': negative,
              'fall_enumeration_scope': '0..160 tick superset; not a declaration that every BUSY history is legal',
              'enumerated_fall_positions': len(timelines),
              'capture_edges_checked': len(timelines) * 224,
              'timelines': timelines}
    # zero margin cannot establish the required positive timing reserve.
    for name, margin in margins.items():
        require(margin > 0, 'nonpositive timing margin: ' + name)
    require(extra_translator == 0, 'direct profile requires zero translator allocation')
    return result


def main():
    """write source-bound arithmetic evidence, including rejected candidates."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--extra-translator-ns', type=Fraction, default=Fraction(0),
                        help='additional capture-path delay for an arithmetic failure control')
    args = parser.parse_args()
    source = Path(__file__).resolve()
    root = source.parents[2]
    inputs = [source, root / 'datasheets/ad7606c-18.pdf']
    before = {str(path.relative_to(root)): digest(path) for path in inputs}
    result = {'schema': 'DRG5-ACQUISITION-TIMING-1',
              'source_sha256': before,
              'physical_timing_qualified': False,
              'complete_acquisition_qualified': False,
              'limits': ['allocated requirements only; no FPGA I/O or board measurements',
                         'synchronizer allowance requires CDC and MTBF qualification, not an absolute metastability bound',
                         'ADC serial limits require the stated voltage and load conditions',
                         'supervisor, memory service and transport allocations remain unimplemented or unqualified']}
    code = 0
    # failed allocations remain evidence and return a nonzero status.
    try:
        result.update(calculate(args.extra_translator_ns))
        require(all(digest(path) == before[str(path.relative_to(root))] for path in inputs),
                'source changed during calculation')
        result['source_stable'] = True
    # record the failing predicate without claiming a physical test occurred.
    except ValueError as error:
        result.update({'status': 'arithmetic-failed', 'error': str(error),
                       'extra_translator_ns': str(args.extra_translator_ns)})
        code = 2
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # evidence is append-only by filename; existing attempts are never replaced.
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print(result['status'])
    return code


# run only the host arithmetic checker.
if __name__ == '__main__':
    sys.exit(main())
