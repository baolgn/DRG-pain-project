/* check acquisition boundaries independently of CPU execution and external storage models. */
#include "Vdrg5_acquisition_guard.h"
#include "verilated.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <iostream>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

/* use the F-80 clock unless the runner selects a rejected-profile test. */
#ifndef TEST_CLOCK_HZ
#define TEST_CLOCK_HZ 80000000
#endif
/* zero selects full counters; reduced limits exercise saturation separately. */
#ifndef TEST_COUNTER_LIMIT
#define TEST_COUNTER_LIMIT 0
#endif

/* retain immutable descriptors at actual FIFO acceptance edges. */
struct Record {
    uint64_t epoch, slot, tick;
    bool invalid;
    std::array<uint32_t, 12> data;
};

/* a deterministic harness owns only explicit frame completion and FIFO/drain acknowledgements. */
struct Bench {
    std::unique_ptr<Vdrg5_acquisition_guard> dut = std::make_unique<Vdrg5_acquisition_guard>();
    uint64_t cycles = 0, checks = 0, trigger_cycle = 0, trigger_tick = 0;
    uint64_t reported_checks = 0, reported_cycles = 0;
    uint64_t event_accepts = 0, blocks = 0;
    std::vector<Record> records;
    std::map<std::pair<uint64_t, uint64_t>, bool> identities;
    std::map<std::pair<uint64_t, uint64_t>, std::array<uint32_t, 12>> captured;

    /* stop immediately on a violated independent expectation. */
    void check(bool condition, const std::string &message) {
        ++checks;
        /* preserve the cycle and predicate in the failure log. */
        if (!condition) throw std::runtime_error(message + " cycle=" + std::to_string(cycles));
    }

    /* sample transfers before the edge and observations after registered updates. */
    void tick() {
        dut->clk_i = 0; dut->eval();
        const uint64_t old_tick = dut->tick_o;
        /* only external acceptance moves the offered record into the scoreboard. */
        if (!dut->power_reset_i && dut->record_valid_o && dut->record_ready_i) {
            Record value{dut->record_epoch_o, dut->record_slot_o, dut->record_tick_o,
                         bool(dut->record_invalid_o), {}};
            /* every payload lane must remain part of the same immutable descriptor. */
            for (unsigned i = 0; i < 12; ++i) value.data[i] = dut->record_data_o[i];
            check(!identities.contains({value.epoch, value.slot}), "duplicate record");
            identities[{value.epoch, value.slot}] = true;
            /* available raw evidence survives integrity failure with a separate invalid flag. */
            if (captured.contains({value.epoch, value.slot})) {
                check(value.data == captured.at({value.epoch, value.slot}), "raw diagnostic evidence discarded");
            /* missing data must never expose stale sample bytes. */
            } else if (value.invalid) {
                /* the full 48-byte placeholder is deterministic. */
                for (auto word : value.data) check(word == 0, "nonzero placeholder");
            }
            records.push_back(value);
        }
        /* notification delivery does not clear the independent sticky registers. */
        if (!dut->power_reset_i && dut->event_valid_o && dut->event_ready_i) ++event_accepts;
        dut->clk_i = 1; dut->eval(); ++cycles;
        /* all accounting invariants are checked on every non-reset clock. */
        if (!dut->power_reset_i) {
            check(dut->tick_o == old_tick + 1, "timebase stopped");
            check(dut->scheduled_o == dut->emitted_o + dut->not_triggered_o, "slot conservation");
            check(dut->invalid_o <= dut->scheduled_o, "invalid count exceeds schedule");
            check(dut->retained_o == records.size(), "FIFO acceptance count");
            check(dut->delivered_events_o == event_accepts, "event delivery count");
            /* recognition of a stop never shares an edge with a new trigger. */
            if (dut->trigger_o) {
                check(!dut->debug_halt_i && !dut->cpu_reset_i && !dut->stop_i &&
                      !dut->memory_deadline_i && !dut->lease_overrun_i && dut->qualified_i &&
                      dut->memory_available_i && dut->ring_space_i && dut->fifo_occupancy_i < 192,
                      "trigger after recognized stop");
                trigger_cycle = cycles; trigger_tick = dut->trigger_tick_o;
            }
            /* one block reference represents 256 scheduled slots, never a byte-copy completion. */
            if (dut->block_reference_o) ++blocks;
        }
    }

    /* reset only the whole guard domain, with healthy external ownership inputs. */
    void reset() {
        dut->power_reset_i = 1; dut->arm_i = 0; dut->stop_i = 0; dut->qualified_i = 1;
        dut->debug_halt_i = 0; dut->cpu_reset_i = 0; dut->memory_available_i = 1;
        dut->memory_deadline_i = 0; dut->lease_overrun_i = 0; dut->ring_space_i = 1;
        dut->record_credit_i = 1; dut->fifo_occupancy_i = 0; dut->clear_reasons_i = 0;
        dut->frame_valid_i = 0; dut->frame_good_i = 1; dut->frame_slot_i = 0; dut->frame_epoch_i = 0;
        dut->record_ready_i = 1; dut->drain_ack_i = 0; dut->drain_error_i = 0; dut->drain_lost_i = 0;
        dut->event_ready_i = 1;
        tick(); tick(); dut->power_reset_i = 0;
        records.clear(); identities.clear(); captured.clear(); event_accepts = 0; blocks = 0; trigger_cycle = 0;
        tick(); check(dut->closed_o && dut->scheduled_o == 0 && dut->accounting_exact_o, "power reset state");
    }

    /* a successful arm creates a fresh epoch before its first trigger. */
    void arm() {
        const uint64_t previous = dut->epoch_o;
        dut->arm_i = 1; tick(); dut->arm_i = 0;
        check(dut->running_o && dut->epoch_o == previous + 1, "arm rejected");
        check(!dut->trigger_o, "trigger on arm edge");
    }

    /* bounded waiting catches deadlock and accidental stretched sample cadence. */
    void trigger() {
        /* the caller has consumed any previous trigger pulse. */
        for (unsigned i = 0; i < 1602; ++i) {
            tick();
            /* stop at the first new scheduler pulse. */
            if (dut->trigger_o) return;
        }
        check(false, "missing scheduled trigger");
    }

    /* derive payload values from immutable epoch and slot identities. */
    uint32_t pattern(unsigned lane) const {
        return uint32_t(dut->trigger_slot_o) ^ (uint32_t(dut->trigger_epoch_o) << 24) ^ (0x19283745U * (lane + 1));
    }

    /* deliver one matching complete frame, including every payload lane. */
    void complete(bool good = true) {
        dut->frame_slot_i = dut->trigger_slot_o; dut->frame_epoch_i = dut->trigger_epoch_o;
        dut->frame_good_i = good;
        /* all sample bytes are recognizable in the independently captured record. */
        for (unsigned i = 0; i < 12; ++i) {
            dut->frame_data_i[i] = pattern(i);
            captured[{dut->trigger_epoch_o, dut->trigger_slot_o}][i] = pattern(i);
        }
        dut->frame_valid_i = 1; tick(); dut->frame_valid_i = 0;
        check(dut->record_valid_o && bool(dut->record_invalid_o) == !good, "frame disposition");
        /* complete records preserve raw bytes even when their integrity result is invalid. */
        for (unsigned i = 0; i < 12; ++i) check(dut->record_data_o[i] == pattern(i), "payload corruption");
    }

    /* wait for the capture boundary without pretending tail storage has drained. */
    void close_boundary(uint64_t recognized) {
        /* the guard must resolve the existing slot within the 1600-clock limit. */
        for (unsigned i = 0; i <= 1600 && !dut->close_valid_o; ++i) tick();
        check(dut->close_valid_o && cycles - recognized <= 1600, "stop boundary deadline");
    }

    /* acknowledge only after the test's accepted-record sink owns every offered record. */
    void drain(bool error = false, uint64_t lost = 0) {
        dut->record_ready_i = 1;
        /* resolve an outstanding FIFO transfer before closure acknowledgement. */
        if (dut->record_valid_o) tick();
        check(dut->close_valid_o, "drain without close watermark");
        dut->drain_error_i = error; dut->drain_lost_i = lost; dut->drain_ack_i = 1;
        tick(); dut->drain_ack_i = 0; dut->drain_error_i = 0; dut->drain_lost_i = 0;
        check(dut->closed_o && !dut->running_o, "external close acknowledgement");
    }

    /* print a machine-readable case verdict without hiding earlier failures. */
    void pass(const std::string &name) {
        std::cout << "GUARD_CASE_PASS {\"case\":\"" << name << "\",\"checks\":" << checks - reported_checks
                  << ",\"cycles\":" << cycles - reported_cycles << "}" << std::endl;
        reported_checks = checks; reported_cycles = cycles;
    }
};

/* exercise full-rate scheduling, complete record integrity and randomized sink backpressure. */
static void normal_stream() {
    Bench b; b.reset(); b.arm(); uint32_t rng = 0x46ad2U; uint64_t previous_tick = 0;
    /* 300 frames cross both a block boundary and an 8-bit slot index wrap. */
    for (unsigned frame = 0; frame < 300; ++frame) {
        b.trigger();
        /* cadence is independent of the completion and acceptance phases. */
        if (frame) b.check(b.dut->trigger_tick_o - previous_tick == 1600, "sample cadence");
        previous_tick = b.dut->trigger_tick_o;
        rng = rng * 1664525U + 1013904223U;
        /* formation remains within the 1040-clock normal capture allowance. */
        for (unsigned i = 0; i < 1 + rng % 1000; ++i) b.tick();
        b.dut->record_ready_i = 0; b.complete();
        /* a held record cannot change or repeat when the consumer applies backpressure. */
        for (unsigned i = 0; i < rng % 200; ++i) b.tick();
        b.dut->record_ready_i = 1; b.tick();
    }
    b.dut->stop_i = 1; const uint64_t start = b.cycles + 1; b.tick(); b.dut->stop_i = 0;
    b.close_boundary(start); b.drain();
    b.check(b.dut->scheduled_o == 300 && b.dut->emitted_o == 300 && !b.dut->invalid_o &&
            b.records.size() == 300 && b.blocks == 1, "normal stream ledger");
    b.pass("300-frames-variable-formation-and-backpressure");
}

/* stop at the 192-record boundary while preserving the already-triggered frame. */
static void watermarks() {
    Bench b; b.reset(); b.arm(); b.trigger(); b.complete(); b.tick();
    b.dut->fifo_occupancy_i = 191; b.trigger();
    b.check(b.dut->running_o, "191-record boundary");
    b.dut->fifo_occupancy_i = 192; const uint64_t start = b.cycles + 1; b.tick();
    b.check(b.dut->stopping_o && (b.dut->sticky_reasons_o & 8), "192-record stop");
    b.complete(); b.close_boundary(start); b.drain();
    b.check(b.dut->emitted_o == 2 && b.dut->invalid_o == 0, "highwater tail");
    b.pass("191-to-192-highwater-current-frame-completes");
    b.reset(); b.arm(); b.dut->fifo_occupancy_i = 256; b.dut->record_credit_i = 0; b.tick();
    b.check(!b.dut->trigger_o && b.dut->scheduled_o == 1 && b.dut->not_triggered_o == 1 &&
            b.dut->invalid_o == 1 && b.dut->lost_tail_o == 1 && !b.dut->record_valid_o, "full ingress ledger");
    b.drain(); b.pass("256-full-no-trigger-no-overwrite-exact-loss");
}

/* CPU reset and debug halt are stop causes, never monitor reset inputs. */
static void cpu_events() {
    /* both run-control causes must preserve the same lifetime observations. */
    for (bool reset : {false, true}) {
        Bench b; b.reset(); b.arm(); b.trigger();
        /* recognize the request in the middle of an outstanding capture. */
        for (unsigned i = 0; i < 73; ++i) b.tick();
        b.dut->cpu_reset_i = reset; b.dut->debug_halt_i = !reset;
        const uint64_t start = b.cycles + 1, before_tick = b.dut->tick_o; b.tick();
        /* holding the level cannot erase state or emit repeated triggers. */
        for (unsigned i = 0; i < 42; ++i) b.tick();
        b.check(b.dut->tick_o == before_tick + 43 && b.dut->scheduled_o == 1, "run-control reset lifetime");
        b.complete(); b.close_boundary(start); b.drain();
        b.dut->cpu_reset_i = 0; b.dut->debug_halt_i = 0; b.tick(); b.arm();
        b.check(b.dut->epoch_o == 2 && b.dut->retained_o == 1, "new epoch preserves totals");
        b.pass(reset ? "CPU-reset-mid-frame-retains-counters" : "debug-halt-mid-frame-retains-counters");
    }
}

/* distinguish a last-edge valid completion from timeout and discard later obsolete replies. */
static void deadlines() {
    /* the final permitted edge is inclusive for a matching completion. */
    for (bool timely : {false, true}) {
        Bench b; b.reset(); b.arm(); b.trigger(); const uint64_t launched = b.cycles;
        b.dut->stop_i = 1; const uint64_t start = b.cycles + 1; b.tick(); b.dut->stop_i = 0;
        /* position the response exactly at trigger plus 1600 clocks. */
        while (b.cycles < launched + 1599) b.tick();
        /* a timely response has priority over the watchdog on this edge. */
        if (timely) b.complete();
        else b.tick();
        b.close_boundary(start);
        b.check(b.dut->invalid_o == unsigned(!timely), "deadline edge priority");
        b.drain();
        const uint64_t retained = b.dut->retained_o, invalid = b.dut->invalid_o;
        b.dut->frame_valid_i = 1; b.dut->frame_epoch_i = 1; b.dut->frame_slot_i = 0;
        b.tick(); b.dut->frame_valid_i = 0;
        b.check(b.dut->retained_o == retained && b.dut->invalid_o == invalid &&
                (b.dut->sticky_reasons_o & 0x400), "stale completion reused");
        b.pass(timely ? "inclusive-deadline-success-and-duplicate-drain" : "timeout-invalid-and-late-drain");
    }
    Bench b; b.reset(); b.arm(); b.trigger(); const uint64_t launched = b.cycles;
    /* without a stop request, a missing frame collides with the next scheduled slot. */
    while (b.cycles < launched + 1600) b.tick();
    b.check(b.dut->scheduled_o == 2 && b.dut->emitted_o == 1 && b.dut->not_triggered_o == 1 &&
            b.dut->invalid_o == 2 && b.dut->lost_tail_o == 1, "concurrent timeout and missing-slot accounting");
    b.pass("timeout-next-slot-collision-counts-both-outcomes");
}

/* delay closure after memory failure without turning a late drain into normal success. */
static void memory_faults() {
    /* a deadline violation and an outage are separately observable causes. */
    for (bool deadline : {false, true}) {
        Bench b; b.reset(); b.arm(); b.trigger();
        b.dut->memory_deadline_i = deadline; b.dut->memory_available_i = deadline;
        const uint64_t start = b.cycles + 1; b.tick(); b.dut->memory_deadline_i = 0;
        b.complete(); b.close_boundary(start); b.tick();
        const uint64_t boundary = b.dut->stop_tick_o;
        /* unknown external ownership keeps closure pending even after capture has stopped. */
        for (unsigned i = 0; i < 2000; ++i) b.tick();
        b.check(b.dut->close_valid_o && b.dut->stop_tick_o == boundary && b.dut->scheduled_o == 1,
                "late drain changed stop boundary");
        b.drain(true, 1);
        b.check(b.dut->lost_tail_o == 1 && (b.dut->sticky_reasons_o & (deadline ? 0x40 : 0x80)),
                "memory fault evidence lost");
        b.pass(deadline ? "memory-deadline-late-fault-drain" : "memory-outage-late-fault-drain");
    }
}

/* enforce external capacity/lease ownership rather than silently extending the epoch. */
static void capacity_faults() {
    /* each externally detected unsafe condition ends new admission. */
    for (unsigned mode = 0; mode < 3; ++mode) {
        Bench b; b.reset(); b.arm();
        /* a missing reservation at the first due edge creates a counted untriggered slot. */
        if (mode == 0) b.dut->record_credit_i = 0;
        else if (mode == 1) b.dut->ring_space_i = 0;
        else b.dut->lease_overrun_i = 1;
        b.tick(); b.dut->lease_overrun_i = 0;
        b.check(!b.dut->trigger_o && b.dut->scheduled_o == 1 && b.dut->not_triggered_o == 1,
                "unsafe capacity trigger");
        b.drain(); b.pass(mode == 0 ? "no-credit-before-trigger" : mode == 1 ? "ring-capacity-stop" : "lease-overrun-stop");
    }
}

/* a bounded event queue retains overflow evidence in independent status registers. */
static void events() {
    Bench b; b.reset(); b.dut->event_ready_i = 0;
    b.dut->memory_deadline_i = 1; b.tick(); b.dut->memory_deadline_i = 0;
    const uint64_t first_tick = b.dut->first_reason_tick_o;
    b.dut->lease_overrun_i = 1; b.dut->clear_reasons_i = 0xffff; b.tick(); b.dut->lease_overrun_i = 0;
    b.check(b.dut->lost_events_o == 1 && (b.dut->sticky_reasons_o & 0x820) == 0x820,
            "new event must win W1C");
    b.dut->cpu_reset_i = 1; b.tick(); b.dut->cpu_reset_i = 0; b.dut->clear_reasons_i = 0;
    b.check(b.dut->lost_events_o == 2 && b.dut->first_reason_tick_o == first_tick &&
            b.dut->event_reasons_o == 0x40, "event queue overwrite");
    b.dut->event_ready_i = 1; b.dut->memory_deadline_i = 1; b.tick(); b.dut->memory_deadline_i = 0;
    b.check(b.dut->delivered_events_o == 1 && b.dut->event_valid_o && b.dut->lost_events_o == 2,
            "simultaneous event dequeue and enqueue");
    b.tick(); b.check(b.dut->delivered_events_o == 2, "event delivery disappeared");
    b.pass("event-overflow-exact-loss-W1C-and-concurrent-transfer");
}

/* preserve a record under malformed early closure and accept a later real transfer. */
static void close_ownership() {
    Bench b; b.reset(); b.arm(); b.trigger(); b.dut->record_ready_i = 0;
    b.complete(false); b.check(b.dut->running_o, "marked integrity failure unexpectedly stopped");
    b.check(b.dut->event_epoch_o == 1 && b.dut->event_slot_o == 0, "frame event identity");
    b.dut->stop_i = 1; b.tick(); b.dut->stop_i = 0;
    b.dut->drain_ack_i = 1; b.tick(); b.dut->drain_ack_i = 0;
    b.check(b.dut->close_valid_o && b.dut->record_valid_o && !b.dut->closed_o &&
            (b.dut->sticky_reasons_o & 0x4000), "premature closure discarded record");
    b.dut->record_ready_i = 1; b.dut->drain_ack_i = 1; b.tick(); b.dut->drain_ack_i = 0;
    b.check(b.dut->closed_o && b.dut->retained_o == 1 && b.dut->invalid_o == 1, "same-edge final transfer and closure");
    b.pass("offered-record-survives-premature-close");
}

/* cover every recognition phase against the same absolute capture watchdog. */
static void stop_phase_sweep() {
    Bench b; uint64_t maximum = 0;
    /* the last phase also overlaps timeout and the following scheduled aperture. */
    for (unsigned phase = 0; phase < 1600; ++phase) {
        b.reset(); b.arm(); b.trigger(); const uint64_t launched_tick = b.dut->trigger_tick_o;
        /* move the request across all 1600 frame-lifetime edges. */
        for (unsigned i = 0; i < phase; ++i) b.tick();
        const uint64_t start = b.cycles + 1; b.dut->stop_i = 1; b.tick(); b.dut->stop_i = 0;
        b.close_boundary(start); maximum = std::max(maximum, b.cycles - start);
        b.check(b.dut->stop_tick_o == launched_tick + 1600, "absolute watchdog boundary");
        b.check(b.dut->stop_slot_o == unsigned(phase == 1599) && b.dut->stop_slot_tick_o ==
                launched_tick + (phase == 1599 ? 1600 : 0), "final scheduled aperture metadata");
    }
    b.check(maximum == 1599, "phase sweep maximum");
    b.pass("all-1600-stop-phases-and-final-aperture");
}

/* old-epoch replies must not resolve a newly armed slot with the same local index. */
static void epoch_identity() {
    Bench b; b.reset(); b.arm(); b.trigger(); b.complete(); b.tick();
    b.dut->stop_i = 1; b.tick(); b.dut->stop_i = 0; b.drain(); b.arm(); b.trigger();
    b.dut->frame_valid_i = 1; b.dut->frame_epoch_i = 1; b.dut->frame_slot_i = 0;
    b.tick(); b.dut->frame_valid_i = 0;
    b.check(b.dut->stopping_o && !b.dut->record_valid_o && b.dut->retained_o == 1, "obsolete epoch resolved new frame");
    b.complete(); b.tick(); b.drain();
    b.check(b.dut->epoch_o == 2 && b.dut->retained_o == 2 && b.dut->invalid_o == 0, "epoch ownership ledger");
    b.pass("obsolete-epoch-completion-cannot-resolve-new-slot");
}

/* overflowing notifications also stops otherwise recoverable invalid-frame traffic. */
static void active_event_overflow() {
    Bench b; b.reset(); b.arm(); b.trigger(); b.dut->event_ready_i = 0;
    b.complete(false); b.tick(); b.trigger(); b.complete(false);
    b.check(b.dut->close_valid_o && b.dut->lost_events_o == 1 && b.dut->invalid_o == 2 &&
            (b.dut->sticky_reasons_o & 0x800), "event overflow failed to stop active acquisition");
    b.drain(); b.pass("event-overflow-stops-active-epoch");
}

/* closure cannot invent losses beyond the records transferred to the external owner. */
static void impossible_tail_loss() {
    Bench b; b.reset(); b.arm(); b.trigger(); b.complete(); b.tick();
    b.dut->stop_i = 1; b.tick(); b.dut->stop_i = 0;
    b.dut->drain_ack_i = 1; b.dut->drain_error_i = 1; b.dut->drain_lost_i = 2;
    b.tick(); b.dut->drain_ack_i = 0;
    b.check(b.dut->close_valid_o && !b.dut->lost_tail_o && (b.dut->sticky_reasons_o & 0x4000),
            "impossible external tail count accepted");
    b.drain(true, 1); b.check(b.dut->lost_tail_o == 1, "corrected tail count rejected");
    b.pass("external-loss-count-cannot-exceed-accepted-records");
}

/* reject a lower-frequency build rather than borrowing the F-80 timing claims. */
static void wrong_profile() {
    Bench b; b.reset(); b.dut->arm_i = 1; b.tick(); b.dut->arm_i = 0;
    /* no number of elapsed P25 clocks can silently authorize this fixed profile. */
    for (unsigned i = 0; i < 2000; ++i) b.tick();
    b.check(!b.dut->profile_ok_o && !b.dut->running_o && !b.dut->scheduled_o &&
            (b.dut->sticky_reasons_o & 0x2000), "P25 wrongly admitted");
    b.pass("P25-profile-rejected");
}

/* reduced counter limits exercise production saturation logic without impractical runtimes. */
static void counter_limits() {
    Bench b; b.reset(); b.arm();
    /* the last representable schedule entry is legal and stops subsequent admission. */
    for (unsigned i = 0; i < TEST_COUNTER_LIMIT; ++i) {
        b.trigger(); b.complete(); b.tick();
    }
    b.check(b.dut->scheduled_o == TEST_COUNTER_LIMIT && b.dut->emitted_o == TEST_COUNTER_LIMIT &&
            b.dut->close_valid_o && b.dut->accounting_exact_o, "counter limit wrap");
    b.drain(); b.dut->arm_i = 1; b.tick(); b.dut->arm_i = 0;
    b.check(!b.dut->running_o && b.dut->scheduled_o == TEST_COUNTER_LIMIT, "counter exhaustion restarted");
    b.pass("scheduled-counter-limit-stops-without-wrap");
    b.reset(); b.dut->event_ready_i = 0; b.dut->memory_deadline_i = 1;
    /* overflow is explicit even if external faults persist after acquisition has stopped. */
    for (unsigned i = 0; i < TEST_COUNTER_LIMIT + 2; ++i) b.tick();
    b.dut->memory_deadline_i = 0;
    b.check(b.dut->lost_events_o == TEST_COUNTER_LIMIT && !b.dut->accounting_exact_o &&
            (b.dut->sticky_reasons_o & 0x1000), "lost-event saturation unreported");
    b.pass("event-counter-saturation-flags-inexact-accounting");
}

/* run every selected profile with assertion checking enabled. */
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    /* retain a nonzero process status and precise failure text for each failed campaign. */
    try {
        /* test builds select only the exceptional configuration they actually elaborate. */
        if (TEST_CLOCK_HZ != 80000000) wrong_profile();
        else if (TEST_COUNTER_LIMIT) counter_limits();
        /* the full profile covers timing, ownership, faults and record integrity. */
        else {
            normal_stream(); watermarks(); cpu_events(); deadlines(); memory_faults();
            capacity_faults(); events(); close_ownership();
            stop_phase_sweep(); epoch_identity(); active_event_overflow(); impossible_tail_loss();
        }
        std::cout << "ACQUISITION_GUARD_PASS" << std::endl;
        return 0;
    /* failed expectations must survive as nonzero runner status. */
    } catch (const std::exception &error) {
        std::cerr << "ACQUISITION_GUARD_FAIL " << error.what() << std::endl;
        return 1;
    }
}
