/* exercise compiled DSP on real CPU/debug RTL with independent acquisition, bus and result records. */
#include "Vdrg5_synthetic_debug.h"
#include "verilated.h"
#include "synthetic_trace_fields.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <deque>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <zlib.h>

/* physical offers retain identity independently from architectural retirement. */
struct Owner {
    bool live = false, accepted = false, write = false, shared = false;
    uint32_t address = 0, value = 0, tag = 0, reply = 0;
    unsigned size = 0, strobes = 0, parcels = 0, delay = 0, response = 0, status = 0;
    uint64_t offer = 0, accepted_at = 0;
};

/* a block retains raw bytes until both CPU and host-transport consumers release it. */
struct Block {
    uint64_t epoch = 0, ordinal = 0, first_tick = 0, rk = 0, publication = 0, ack = 0, begin = 0, end = 0;
    uint32_t id = 0, reads = 0, energy = 0, signature = 0, quotient = 0;
    uint16_t seen = 0;
    bool released = false, cut = false, aborted = false;
    unsigned transported = 0, records = 0;
    std::array<uint32_t, 3088> raw{};
};

/* DMA eligibility begins at the queue head, not when an entire frame enters its FIFO. */
struct Job { uint32_t block, index, value; bool last; };

/* independently calculated expected samples use explicit modular arithmetic at every mixing step. */
static int32_t reference_sample(uint64_t epoch, uint64_t ordinal, unsigned frame, unsigned channel) {
    uint32_t mixed = uint32_t(epoch * UINT64_C(0x9e3779b9)) ^ uint32_t(ordinal * UINT64_C(0x045d9f3b)) ^
                     uint32_t(uint64_t(frame) * UINT64_C(0x27d4eb2d)) ^ uint32_t(uint64_t(channel) * UINT64_C(0x165667b1));
    mixed = uint32_t(uint64_t(mixed ^ (mixed >> 13)) * UINT64_C(0x85ebca6b));
    mixed ^= mixed >> 16;
    return int32_t(mixed & 262143u) - 131072;
}

/* model one real instruction stream alongside retained hardware ownership and clock observations. */
class Simulation {
    Vdrg5_synthetic_debug dut;
    Owner instruction, data, sba;
    std::array<uint8_t, 8192> rom{};
    std::array<uint8_t, 65536> iram{};
    std::array<uint8_t, 32768> ram{};
    std::map<uint32_t, Block> blocks;
    std::map<std::pair<uint64_t, uint64_t>, uint32_t> identities;
    std::deque<Job> capture, transport;
    Job capture_job{}, transport_job{};
    bool capture_active = false, transport_active = false, frame_pending = false, close_queued = false;
    uint64_t capture_ready = 0, transport_ready = 0, capture_done = 0, transport_done = 0;
    uint64_t frame_due = 0, frame_slot = 0, frame_epoch = 0, frame_tick = 0;
    uint64_t cycle = 0, trace_count = 0, event_count = 0, last_tick = 0;
    uint64_t stall_begin = 0, stall_until = 0, max_instruction = 0, max_local = 0, max_mmio = 0;
    uint64_t max_shared = 0, max_capture = 0, max_transport = 0, max_dsp = 0, max_response = 0;
    uint64_t max_ack = 0, max_isr = 0, irq_start = 0, stop_start = 0, max_stop = 0, halt_start = 0, max_halt = 0;
    uint64_t capture_words = 0, transport_words = 0, debug_slots = 0, maintenance_slots = 0;
    uint32_t pending = 0, current = 0, boot_count = 0, released = 0, timer_ack = 0, software_ack = 0, exceptions = 0;
    uint32_t rng;
    bool timer_pending = false, software_pending = false, old_halt = false, old_reset = false, old_stop = false;
    bool active_reset_observed = false;
    std::array<unsigned, 160> shared_phases{};
    std::ofstream events, result;
    gzFile terminals;
    std::string mutation;

    /* checker failures identify the actual cycle and never become a successful completion footer. */
    void check(bool condition, const std::string &reason) {
        if (!condition) throw std::runtime_error(reason + " cycle=" + std::to_string(cycle));
    }

    /* timing variation is deterministic and independent of firmware values. */
    uint32_t random_word() {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
        return rng;
    }

    /* retain every noninstruction event in an ordered side-effect ledger. */
    void event(const std::string &body) {
        events << "{\"sequence\":" << ++event_count << ",\"cycle\":" << cycle << ',' << body << "}\n";
    }

    /* packed architectural fields come from the retained production trace schema. */
    uint64_t field(unsigned start, unsigned width) {
        uint64_t value = 0;
        /* each requested scalar fits sixty-four bits. */
        for (unsigned bit = 0; bit < width; ++bit)
            value |= uint64_t((dut.trace_o[(start + bit) / 32] >> ((start + bit) % 32)) & 1) << bit;
        return value;
    }

    /* only valid local storage has a CPU-visible byte pointer. */
    uint8_t *local(uint32_t address) {
        if (address < rom.size()) return rom.data() + address;
        if (address >= 0x10000 && address < 0x20000) return iram.data() + address - 0x10000;
        if (address >= 0x20000000 && address < 0x20008000) return ram.data() + address - 0x20000000;
        return nullptr;
    }

    /* preload only physical ROM and executable load bytes; startup must initialize poisoned data RAM. */
    void load_hex(const std::string &path, uint8_t *target, unsigned length) {
        std::ifstream input(path); std::string word;
        /* exact image sizes prevent hidden zero padding or truncation. */
        for (unsigned offset = 0; offset < length; offset += 4) {
            check(bool(input >> word), "short word image");
            uint32_t value = uint32_t(std::stoul(word, nullptr, 16));
            /* preserve each little-endian byte independently. */
            for (unsigned lane = 0; lane < 4; ++lane) target[offset + lane] = uint8_t(value >> (8 * lane));
        }
        check(!(input >> word), "long word image");
    }

    /* compare derived results with a separate widened arithmetic implementation. */
    void validate_result(Block &block) {
        uint64_t energy = 0, signature = 0;
        int64_t last = 0, earlier = 0;
        /* the oracle does not invoke the compiled firmware kernel or read its output buffers. */
        for (unsigned index = 0; index < 16; ++index) {
            int64_t sample = reference_sample(block.epoch, block.ordinal, index * 16, 0);
            int64_t filtered = sample - 2 * last + earlier;
            energy = (energy + uint64_t(filtered * filtered)) & UINT64_C(0xffffffff);
            signature = (signature + uint32_t(filtered) * uint64_t(index + 1)) & UINT64_C(0xffffffff);
            earlier = last; last = sample;
        }
        check(block.reads == 16 && block.seen == 0xffff, "DSP sample access count");
        check(block.energy == energy && block.signature == signature && block.quotient == energy / 17, "DSP independent result mismatch");
    }

    /* derive transport bytes from scheduled identities rather than trusting the DMA-written RAM. */
    uint32_t expected_raw(const Block &block, unsigned index) {
        if (index < 16) return uint32_t(block.epoch + (block.rk ? block.ordinal * 256 + 255 : block.records) + index);
        unsigned frame = (index - 16) / 12, lane = (index - 16) % 12;
        if (lane < 8) return uint32_t(reference_sample(block.epoch, block.ordinal, frame, lane));
        if (lane == 8) return uint32_t(block.ordinal * 256 + frame);
        if (lane == 9) return uint32_t(block.first_tick + frame * 1600);
        if (lane == 10) return uint32_t(block.epoch);
        return 0;
    }

    /* MMIO effects occur once at acceptance, never by observing a retiring instruction. */
    void mmio(Owner &owner) {
        check(owner.size == 2, "MMIO width");
        unsigned offset = owner.address - 0x40000000;
        owner.reply = 0;
        /* reads are bounded status operations; the DSP divisor remains a runtime operand. */
        if (!owner.write) {
            if (offset == 0) owner.reply = pending;
            else if (offset == 60) owner.reply = 17;
            else owner.status = 1;
            return;
        }
        event("\"event\":\"MMIO\",\"offset\":" + std::to_string(offset) + ",\"value\":" + std::to_string(owner.value));
        /* descriptor acknowledgement clears only the matching retained external event. */
        if (offset == 4) {
            check(pending && owner.value == pending, "duplicate or mismatched block acknowledgement");
            Block &block = blocks.at(pending); check(!block.ack, "duplicate block acknowledgement");
            block.ack = cycle; max_ack = std::max(max_ack, cycle - block.publication); current = pending; pending = 0;
        /* entry marks the first foreground instruction-owned DSP interval. */
        } else if (offset == 8) {
            check(owner.value == current && current && !blocks.at(current).begin, "duplicate DSP dispatch");
            blocks.at(current).begin = cycle;
        /* independent output registers retain values until the explicit lease release. */
        } else if (offset >= 12 && offset <= 20) {
            check(current && blocks.at(current).begin, "result without DSP owner");
            Block &block = blocks.at(current);
            if (offset == 12) block.energy = owner.value ^ (mutation == "wrong-result" ? 1u : 0u);
            if (offset == 16) block.signature = owner.value;
            if (offset == 20) block.quotient = owner.value;
        /* release proves actual results and does not release the transport consumer's lease. */
        } else if (offset == 24) {
            check(current && owner.value == current, "wrong DSP release");
            Block &block = blocks.at(current); check(!block.released, "duplicate DSP release");
            validate_result(block); block.end = cycle; block.released = true; ++released;
            /* debug intentionally terminates the healthy deadline interval for its interrupted block. */
            if (!block.cut) {
                max_dsp = std::max(max_dsp, block.end - block.begin);
                max_response = std::max(max_response, block.end - block.rk);
                check(block.end - block.begin <= 64000 && block.end - block.rk <= 320000, "block response deadline");
            }
            event("\"event\":\"DSP-release\",\"block\":" + std::to_string(current) + ",\"cut\":" + std::to_string(block.cut));
        /* startup records every CPU epoch without resetting the acquisition timebase. */
        } else if (offset == 28) {
            check(owner.value == 0x51a7c0de, "firmware startup marker"); ++boot_count;
        /* each retained timer event requires one explicit acknowledgement. */
        } else if (offset == 32) {
            check(timer_pending, "duplicate timer acknowledgement"); timer_pending = false; ++timer_ack;
        /* each retained software event requires one explicit acknowledgement. */
        } else if (offset == 36) {
            check(software_pending, "duplicate software acknowledgement"); software_pending = false; ++software_ack;
        /* the boot ECALL proves precise trap recovery before arming an epoch. */
        } else if (offset == 40) {
            ++exceptions;
        /* unsupported commands and unexpected traps are visible failures. */
        } else {
            check(false, "firmware fault or unsupported MMIO");
        }
    }

    /* stabilize requests before their independently scheduled acceptance. */
    void offer(Owner &owner, bool valid, uint32_t address, uint32_t value, uint32_t tag,
               bool write, unsigned size, unsigned strobes, unsigned parcels) {
        check(!(owner.live && !owner.accepted && !valid), "withdrawn bus offer");
        /* first presentation fixes the descriptor and its wall-clock deadline. */
        if (valid && !owner.live) {
            owner = Owner{}; owner.live = true; owner.address = address; owner.value = value; owner.tag = tag;
            owner.write = write; owner.size = size; owner.strobes = strobes; owner.parcels = parcels;
            owner.offer = cycle; owner.shared = address >= 0x50001000 && address < 0x50002000;
            owner.delay = random_word() & 1; owner.response = random_word() & 1;
            /* the independent register bridge has a larger bounded acceptance and response delay. */
            if (address >= 0x40000000 && address < 0x40001000) { owner.delay += 2; owner.response += 2; }
            if (owner.shared) ++shared_phases[cycle % 160];
        }
        /* no later instruction may substitute an unaccepted owner's bits. */
        if (valid && !owner.accepted)
            check(owner.address == address && owner.value == value && owner.tag == tag && owner.write == write &&
                  owner.size == size && owner.strobes == strobes && owner.parcels == parcels, "unstable bus offer");
    }

    /* shared transfers can begin only at the CPU's two reserved slot starts. */
    bool ready(const Owner &owner) {
        return owner.live && !owner.accepted && (owner.shared ? cycle % 160 == 32 || cycle % 160 == 96 : cycle - owner.offer >= owner.delay);
    }

    /* responses remain fixed until the owner consumes them. */
    bool response(const Owner &owner) {
        return owner.live && owner.accepted && cycle - owner.accepted_at >= (owner.shared ? 14u : owner.response);
    }

    /* perform exactly one physical read or write for each accepted request. */
    void accept(Owner &owner, bool fetch) {
        owner.accepted = true; owner.accepted_at = cycle; owner.reply = 0;
        uint8_t *bytes = local(owner.address & ~3u);
        /* local memory uses byte enables and never shares acquisition slots. */
        if (bytes) {
            /* lane updates precede the saved reply; no response retries the write. */
            for (unsigned lane = 0; lane < 4; ++lane) {
                if (owner.write && (owner.strobes & (1u << lane))) bytes[lane] = uint8_t(owner.value >> (8 * lane));
                owner.reply |= uint32_t(bytes[lane]) << (8 * lane);
            }
        /* the simulation-only aperture exposes channel-zero words of the leased block. */
        } else if (owner.shared) {
            check(!owner.write && owner.size == 2 && current, "shared aperture permission");
            unsigned index = (owner.address - 0x50001000) / 4;
            check(index <= 240 && index % 16 == 0, "unadmitted DSP sample access");
            Block &block = blocks.at(current);
            check(!(block.seen & (1u << (index / 16))), "duplicate shared sample read");
            block.seen |= uint16_t(1u << (index / 16)); ++block.reads;
            owner.reply = block.raw[16 + index * 12];
            event("\"event\":\"shared-read\",\"block\":" + std::to_string(current) + ",\"frame\":" + std::to_string(index) + ",\"value\":" + std::to_string(owner.reply));
        /* only bounded control registers are reachable in the peripheral region. */
        } else if (owner.address >= 0x40000000 && owner.address < 0x40001000) {
            mmio(owner);
        /* deliberate no-effect responders reject all other addresses. */
        } else {
            owner.status = 1;
        }
        /* instruction fetch returns only requested parcels; it cannot access a peripheral. */
        if (fetch) {
            check(bytes && !owner.write, "instruction fetch region");
            owner.reply &= (owner.parcels & 1 ? 0xffffu : 0u) | (owner.parcels & 2 ? 0xffff0000u : 0u);
        /* CPU narrow loads expose only their enabled little-endian lanes. */
        } else {
            uint32_t mask = owner.size == 0 ? 255u : owner.size == 1 ? 65535u : 0xffffffffu;
            owner.reply = owner.write || owner.status ? 0 : owner.reply & (mask << (8 * (owner.address & 3)));
        }
    }

    /* measure offer through captured response without excluding arbitration or acceptance stalls. */
    void complete(Owner &owner, bool fetch) {
        uint64_t elapsed = cycle - owner.offer;
        unsigned bound = owner.shared ? 128 : owner.address >= 0x40000000 ? 16 : 4;
        check(elapsed <= bound, "memory response deadline");
        if (fetch) max_instruction = std::max(max_instruction, elapsed);
        else if (owner.shared) max_shared = std::max(max_shared, elapsed);
        else if (bound == 16) max_mmio = std::max(max_mmio, elapsed);
        else max_local = std::max(max_local, elapsed);
        owner = Owner{};
    }

    /* publish only after the final capture write and header are globally committed. */
    void publish(Block &block) {
        check(!pending && (!current || blocks.at(current).released), "CPU descriptor overrun");
        block.publication = cycle; check(cycle - block.rk <= 8000, "publication deadline");
        pending = block.id; timer_pending = true; software_pending = true;
        /* transport has its own lease and can be blocked before launching by host credit. */
        for (unsigned index = 0; index < block.raw.size(); ++index) transport.push_back({block.id, index, expected_raw(block, index), false});
        /* stop host credit for exactly one hundred milliseconds at the declared synthetic clock. */
        if (block.id == 3 && mutation != "active-reset") { stall_begin = cycle; stall_until = cycle + 8000000; }
        event("\"event\":\"publish\",\"block\":" + std::to_string(block.id) + ",\"rk\":" + std::to_string(block.rk));
    }

    /* each reserved DMA slot includes target work and completes within sixteen core clocks. */
    void dma() {
        /* accepted capture writes complete even if a stop arrives meanwhile. */
        if (capture_active && cycle == capture_done) {
            Block &block = blocks.at(capture_job.block); block.raw[capture_job.index] = capture_job.value;
            max_capture = std::max(max_capture, cycle - capture_ready); check(cycle - capture_ready <= 128, "capture bus deadline");
            ++capture_words; capture_active = false; capture_ready = cycle + 1;
            /* complete blocks notify the CPU; partial stop tails retain separate metadata and transport ownership. */
            if (capture_job.last && block.rk) publish(block);
            /* a partial header is visible only after all accepted tail words have completed. */
            else if (capture_job.last) {
                block.publication = cycle;
                for (unsigned index = 0; index < 16 + block.records * 12; ++index)
                    transport.push_back({block.id, index, expected_raw(block, index), false});
                event("\"event\":\"partial-publish\",\"block\":" + std::to_string(block.id) + ",\"records\":" + std::to_string(block.records));
            }
        }
        /* host stalls never delay an accepted transport operation. */
        if (transport_active && cycle == transport_done) {
            Block &block = blocks.at(transport_job.block);
            check(block.raw[transport_job.index] == transport_job.value, "transport raw-data mismatch");
            ++block.transported; ++transport_words;
            max_transport = std::max(max_transport, cycle - transport_ready); check(cycle - transport_ready <= 96, "transport bus deadline");
            transport_active = false; transport_ready = cycle + 1;
        }
        unsigned phase = cycle % 160;
        /* the entire host stall must occur during the same uninterrupted acquisition epoch. */
        if (stall_until && cycle == stall_until)
            check(dut.guard_running_o && !dut.halted_o && boot_count == 1, "host stall ended outside continuous recording");
        /* an empty queue has no eligible bus request or latency obligation. */
        if (capture.empty() && !capture_active) capture_ready = cycle;
        if ((transport.empty() || cycle < stall_until) && !transport_active) transport_ready = cycle;
        /* capture owns slots zero and four, regardless of other masters' demand. */
        if (!capture_active && !capture.empty() && (phase == 0 || phase == 64)) {
            capture_job = capture.front(); capture.pop_front(); capture_active = true; capture_done = cycle + 15;
        }
        /* transport owns slots one, three, five and seven; a host stall prevents new launches. */
        if (!transport_active && !transport.empty() && cycle >= stall_until && (phase == 16 || phase == 48 || phase == 80 || phase == 112)) {
            transport_job = transport.front(); transport.pop_front(); transport_active = true; transport_done = cycle + 15;
        }
        if (phase == 128) ++debug_slots;
        if (phase == 144) ++maintenance_slots;
    }

public:
    /* power reset is isolated; later CPU resets cannot reset monitors or abandon physical bus owners. */
    Simulation(const std::string &directory, uint32_t seed, const std::string &change) : rng(seed ? seed : 1),
        events(directory + "/events.jsonl"), result(directory + "/result.json"), mutation(change) {
        terminals = gzopen((directory + "/retirement.bin.gz").c_str(), "wb1");
        check(terminals && events && result, "output open");
        load_hex(directory + "/rom.hex", rom.data(), rom.size()); load_hex(directory + "/iram.hex", iram.data(), iram.size());
        std::fill(ram.begin(), ram.end(), uint8_t(seed ^ 0xa5));
        dut.clk_i = 0; dut.tck_i = 0; dut.tms_i = 1; dut.tdi_i = 0; dut.power_reset_i = 1; dut.isolated_i = 1;
        dut.guard_qualified_i = 1; dut.guard_memory_available_i = 1; dut.guard_ring_space_i = 1;
        dut.guard_record_credit_i = 1; dut.guard_record_ready_i = 1; dut.guard_event_ready_i = 1;
        /* shared reset starts both domains; CPU-only resets never revisit these edges. */
        for (unsigned index = 0; index < 8; ++index) tick();
        dut.power_reset_i = 0;
        for (unsigned index = 0; index < 4; ++index) tick();
        dut.isolated_i = 0;
    }

    /* clock hardware continuously, including every JTAG bit and every host-credit stall. */
    void tick() {
        dma();
        /* a stop acknowledgement requires committed partial headers, never only an empty payload FIFO. */
        if (dut.guard_close_valid_o && !close_queued && !frame_pending && !dut.guard_record_valid_o) {
            close_queued = true;
            /* retained incomplete blocks still need a final descriptor and transport lease. */
            for (const auto &entry : blocks) {
                const Block &block = entry.second;
                /* only this unsealed epoch can contribute a partial closure. */
                if (block.epoch == dut.guard_epoch_o && block.records && !block.rk && !block.publication)
                    for (unsigned word = 0; word < 16; ++word) capture.push_back({block.id, word, uint32_t(block.epoch + block.records + word), word == 15});
            }
        }
        dut.clk_i = 0; dut.mip_levels_i = (pending ? 0x800 : 0) | (timer_pending ? 0x80 : 0) | (software_pending ? 8 : 0);
        dut.buffer_owned_i = pending || (current && !blocks.at(current).released);
        dut.guard_fifo_occupancy_i = unsigned((capture.size() + 11) / 12);
        dut.guard_drain_ack_i = close_queued && !capture_active && capture.empty() && !frame_pending;
        dut.guard_frame_valid_i = frame_pending && cycle >= frame_due;
        dut.guard_frame_good_i = 1; dut.guard_frame_slot_i = frame_slot; dut.guard_frame_epoch_i = frame_epoch;
        dut.eval();
        offer(instruction, dut.i_req_valid_o, dut.i_req_addr_o, 0, dut.i_req_tag_o, false, 2, 0, dut.i_req_parcels_o);
        offer(data, dut.d_req_valid_o, dut.d_req_addr_o, dut.d_req_wdata_o, dut.d_req_tag_o, dut.d_req_write_o, dut.d_req_size_o, dut.d_req_wstrb_o, 0);
        offer(sba, dut.sb_req_valid_o, dut.sb_req_addr_o, dut.sb_req_wdata_o, 0, dut.sb_req_write_o, dut.sb_req_size_o, dut.sb_req_wstrb_o, 0);
        dut.i_req_ready_i = ready(instruction); dut.d_req_ready_i = ready(data); dut.sb_req_ready_i = ready(sba);
        dut.i_rsp_valid_i = response(instruction); dut.i_rsp_tag_i = instruction.tag; dut.i_rsp_data_i = instruction.reply;
        dut.i_rsp_parcels_i = instruction.parcels; dut.i_rsp_fault_i = 0; dut.i_rsp_status_i = instruction.status;
        dut.d_rsp_valid_i = response(data); dut.d_rsp_tag_i = data.tag; dut.d_rsp_rdata_i = data.reply; dut.d_rsp_status_i = data.status;
        dut.sb_rsp_valid_i = response(sba); dut.sb_rsp_rdata_i = sba.reply; dut.sb_rsp_error_i = sba.status ? 2 : 0;
        dut.eval();
        bool ia = dut.i_req_valid_o && dut.i_req_ready_i, da = dut.d_req_valid_o && dut.d_req_ready_i, sa = dut.sb_req_valid_o && dut.sb_req_ready_i;
        bool ir = dut.i_rsp_valid_i && dut.i_rsp_ready_o, dr = dut.d_rsp_valid_i && dut.d_rsp_ready_o, sr = dut.sb_rsp_valid_i && dut.sb_rsp_ready_o;
        bool frame_taken = dut.guard_frame_valid_i && dut.guard_frame_ready_o;
        /* raw records enter the modeled FIFO only on the guard's actual ready/valid transfer. */
        if (dut.guard_record_valid_o && dut.guard_record_ready_i) {
            check(!dut.guard_record_invalid_o, "unexpected invalid synthetic frame");
            uint64_t slot = dut.guard_record_slot_o, epoch = dut.guard_record_epoch_o;
            uint32_t id = identities.at({epoch, slot / 256});
            check(blocks.at(id).records == slot % 256, "duplicate or lost capture record");
            ++blocks.at(id).records;
            /* every physical channel value is checked independently before queueing DMA writes. */
            for (unsigned channel = 0; channel < 8; ++channel)
                check(dut.guard_record_data_o[channel] == uint32_t(reference_sample(epoch, slot / 256, slot % 256, channel)), "capture sample mismatch");
            check(dut.guard_record_data_o[8] == uint32_t(slot) && dut.guard_record_data_o[9] == uint32_t(dut.guard_record_tick_o) &&
                  dut.guard_record_data_o[10] == uint32_t(epoch) && dut.guard_record_data_o[11] == 0, "capture metadata mismatch");
            for (unsigned word = 0; word < 12; ++word)
                capture.push_back({id, 16 + unsigned(slot % 256) * 12 + word, dut.guard_record_data_o[word], false});
            /* final headers follow all payload writes; their last word publishes the block. */
            if (slot % 256 == 255)
                for (unsigned word = 0; word < 16; ++word) capture.push_back({id, word, uint32_t(epoch + slot + word), word == 15});
        }
        dut.clk_i = 1; dut.eval(); ++cycle;
        if (ia) accept(instruction, true);
        if (da) accept(data, false);
        if (sa) accept(sba, false);
        if (ir) complete(instruction, true);
        if (dr) complete(data, false);
        if (sr) complete(sba, false);
        if (ir) dut.i_rsp_valid_i = 0;
        if (dr) dut.d_rsp_valid_i = 0;
        if (sr) dut.sb_rsp_valid_i = 0;
        if (frame_taken) frame_pending = false;
        dut.eval();
        /* each real scheduler pulse owns one subsequent pin-level frame completion. */
        if (dut.guard_trigger_o) {
            check(!frame_pending, "overlapping synthetic conversion");
            frame_pending = true; frame_due = cycle + 64; frame_slot = dut.guard_trigger_slot_o;
            frame_epoch = dut.guard_trigger_epoch_o; frame_tick = dut.guard_trigger_tick_o;
            /* each epoch starts an independent block ordinal and globally unique descriptor. */
            if (frame_slot % 256 == 0) {
                check(blocks.size() < 64, "finite synthetic ring exhausted");
                uint32_t id = uint32_t(blocks.size() + 1); Block block;
                block.id = id; block.epoch = frame_epoch; block.ordinal = frame_slot / 256; block.first_tick = frame_tick;
                blocks.emplace(id, block); identities[{frame_epoch, frame_slot / 256}] = id;
            }
            for (unsigned channel = 0; channel < 8; ++channel)
                dut.guard_frame_data_i[channel] = uint32_t(reference_sample(frame_epoch, frame_slot / 256, frame_slot % 256, channel));
            dut.guard_frame_data_i[8] = uint32_t(frame_slot); dut.guard_frame_data_i[9] = uint32_t(frame_tick);
            dut.guard_frame_data_i[10] = uint32_t(frame_epoch); dut.guard_frame_data_i[11] = 0;
            if (dut.guard_block_reference_o) blocks.at(identities.at({frame_epoch, frame_slot / 256})).rk = frame_tick;
        }
        /* retain every original terminal packet, including killed/trapping outcomes represented by the core trace. */
        if (field(TRACE_VALID_LSB, 1)) {
            check(gzwrite(terminals, &cycle, sizeof(cycle)) == int(sizeof(cycle)), "trace timestamp write");
            check(gzwrite(terminals, dut.trace_o.data(), TRACE_WORDS * 4) == TRACE_WORDS * 4, "terminal trace write");
            ++trace_count;
            /* actual MRET retirement ends the measured interrupt interval after register restoration. */
            if (field(TRACE_INSN_LSB, 32) == 0x30200073 && irq_start) { max_isr = std::max(max_isr, cycle - irq_start); irq_start = 0; }
        }
        /* IRQ entry and acknowledgement are independent measured events, including register saving. */
        if (dut.irq_event_o[3] & 1) {
            check(!irq_start, "nested synthetic IRQ"); irq_start = cycle;
            event("\"event\":\"IRQ-entry\",\"cause\":" + std::to_string(dut.irq_event_o[1]));
        }
        /* the acquisition timebase must not reset or stop with the CPU. */
        if (!dut.power_reset_i && cycle > 12) check(dut.guard_tick_o == last_tick + 1, "acquisition timebase discontinuity");
        last_tick = dut.guard_tick_o;
        /* a debug or reset request stops the epoch before firmware can observe it. */
        if (dut.acquisition_stop_o && !old_stop && !dut.power_reset_i) {
            stop_start = cycle; halt_start = cycle;
            if (current && !blocks.at(current).released) blocks.at(current).cut = true;
            /* require the active-reset request to overlap actual acquisition and an exposed physical owner. */
            if (mutation == "active-reset" && !active_reset_observed) {
                check(dut.guard_running_o && ((data.live && data.shared) || frame_pending), "active reset missed concurrent owner");
                active_reset_observed = true;
                event("\"event\":\"active-reset-observed\",\"shared_owner\":" + std::to_string(data.live && data.shared) +
                      ",\"frame_owner\":" + std::to_string(frame_pending) + ",\"tick\":" + std::to_string(dut.guard_tick_o));
            }
            event("\"event\":\"debug-stop-request\"");
        }
        /* halted state must follow completion of all exposed CPU requests. */
        if (dut.halted_o && !old_halt) { max_halt = std::max(max_halt, cycle - halt_start); check(!data.live && !instruction.live, "halt abandoned bus owner"); }
        /* closure includes the hardware stop boundary and external FIFO/header drain. */
        if (stop_start && dut.guard_closed_o) { max_stop = std::max(max_stop, cycle - stop_start); stop_start = 0; }
        /* CPU reset clears only CPU-facing notification state after every bus owner has drained. */
        if (dut.system_reset_o && !old_reset) {
            check(!data.live && !instruction.live && !sba.live, "reset abandoned owner");
            check(!pending && !timer_pending && !software_pending, "reset dropped an unacknowledged peripheral event");
            /* reset terminates foreground ownership explicitly; raw transport remains independently owned. */
            if (current && !blocks.at(current).released) {
                blocks.at(current).aborted = true;
                event("\"event\":\"CPU-reset-abandon\",\"block\":" + std::to_string(current));
            }
            current = 0;
        }
        old_halt = dut.halted_o; old_reset = dut.system_reset_o; old_stop = dut.acquisition_stop_o;
        check(!dut.fatal_o, "unexpected CPU containment");
    }

    /* JTAG transitions always advance the fabric; no internal debug signal is forced by the host. */
    bool tap(bool mode, bool bit) {
        dut.tms_i = mode; dut.tdi_i = bit; dut.tck_i = 0; tick();
        bool reply = dut.tdo_o; dut.tck_i = 1; tick(); return reply;
    }

    /* select the actual RTL transport's five-bit DMI instruction. */
    void initialize_jtag() {
        for (unsigned index = 0; index < 6; ++index) tap(true, false);
        tap(false, false); tap(true, false); tap(true, false); tap(false, false); tap(false, false);
        unsigned capture_ir = 0;
        for (unsigned index = 0; index < 5; ++index) capture_ir |= unsigned(tap(index == 4, (0x11 >> index) & 1)) << index;
        tap(true, false); tap(false, false); check(capture_ir == 1, "JTAG IR capture");
    }

    /* one forty-one-bit DMI scan carries operation, data and address. */
    uint64_t scan(uint64_t value) {
        tap(true, false); tap(false, false); tap(false, false); uint64_t reply = 0;
        for (unsigned index = 0; index < 41; ++index) reply |= uint64_t(tap(index == 40, (value >> index) & 1)) << index;
        tap(true, false); tap(false, false); return reply;
    }

    /* complete each DMI request before starting another command. */
    uint32_t dmi(unsigned operation, unsigned address, uint32_t value) {
        scan((uint64_t(address) << 34) | (uint64_t(value) << 2) | operation);
        for (unsigned index = 0; index < 8; ++index) tick();
        for (unsigned index = 0; index < 5; ++index) tap(false, false);
        uint64_t reply = scan(0); check((reply & 3) == 0 && (reply >> 34) == address, "DMI response");
        return uint32_t(reply >> 2);
    }

    /* every wait has an explicit simulation limit and retains ongoing hardware service. */
    template <typename Predicate> void until(Predicate predicate, uint64_t limit, const char *reason) {
        uint64_t end = cycle + limit;
        while (!predicate() && cycle < end) tick();
        check(predicate(), reason);
    }

    /* arm only after prior DMA ownership and guard closure have finished. */
    void arm() {
        check(dut.guard_closed_o && !capture_active && capture.empty(), "arm before DMA close");
        close_queued = false;
        dut.guard_arm_i = 1; tick(); dut.guard_arm_i = 0; tick(); check(dut.guard_running_o, "epoch arm");
    }

    /* a live shared owner and acquisition epoch must survive reset entry until their proper boundaries. */
    void run_active_reset() {
        initialize_jtag(); dmi(2, 0x10, 1);
        until([&] { return boot_count == 1; }, 20000, "active-reset firmware boot"); arm();
        until([&] { return current >= 2 && data.live && data.shared && !data.accepted &&
                           cycle % 160 >= 97 && cycle % 160 <= 102; }, 12000000, "active shared reset phase");
        uint32_t prior_released = released, abandoned = current;
        uint64_t prior_tick = dut.guard_tick_o, prior_scheduled = dut.guard_scheduled_o, prior_emitted = dut.guard_emitted_o;
        dmi(2, 0x10, 3); dmi(2, 0x10, 1);
        until([&] { return boot_count == 2 && !dut.system_reset_o && dut.guard_closed_o; }, 256000, "active reset drain and reboot");
        check(active_reset_observed && blocks.at(abandoned).aborted && !blocks.at(abandoned).released,
              "active reset did not terminate the interrupted CPU lease");
        check(dut.guard_epoch_o == 1 && dut.guard_tick_o > prior_tick && dut.guard_scheduled_o >= prior_scheduled &&
              dut.guard_emitted_o >= prior_emitted && (dut.guard_sticky_reasons_o & 4), "active reset erased hardware observations");
        arm();
        until([&] { return released == prior_released + 2; }, 1000000, "active-reset new epoch firmware");
        dut.guard_stop_i = 1; tick(); dut.guard_stop_i = 0;
        until([&] { return dut.guard_closed_o && transport.empty() && !transport_active; }, 256000, "active-reset final drain");
        finish(prior_released + 2);
    }

    /* execute healthy blocks, a bounded host stall, actual debug pause and a fresh CPU epoch. */
    void run() {
        /* reset concurrency is a separately identified case with the same real RTL and firmware. */
        if (mutation == "active-reset") { run_active_reset(); return; }
        initialize_jtag(); dmi(2, 0x10, 1);
        until([&] { return boot_count == 1; }, 20000, "first firmware boot"); arm();
        until([&] { return current && blocks.at(current).id == 28 && blocks.at(current).begin && !blocks.at(current).released; }, 12000000, "twenty-eight-block workload");
        check(cycle > stall_until && dut.guard_running_o, "halt preceded complete host stall");
        dmi(2, 0x10, 0x80000001);
        until([&] { return dut.halted_o; }, 256, "debug halt deadline");
        until([&] { return dut.guard_closed_o; }, 256000, "debug stop drain");
        check(dut.guard_sticky_reasons_o & 2, "missing hardware debug reason");
        uint64_t retained_tick = dut.guard_tick_o, retained_cycles = dut.mcycle_o;
        until([&] { return cycle >= stall_until && transport.empty() && !transport_active; }, 9000000, "bounded host stall recovery");
        check(dut.guard_tick_o > retained_tick && dut.mcycle_o == retained_cycles, "debug stopped hardware clock or advanced CPU counter");
        dmi(2, 0x17, 0x002207b1); check((dmi(1, 0x16, 0) & 0x1700) == 0, "abstract DPC command");
        check(dmi(1, 4, 0) == dut.debug_dpc_o, "abstract DPC value");
        dmi(2, 0x38, 0x00140000); dmi(2, 0x39, 0x20000000);
        check((dmi(1, 0x38, 0) & 0x207000) == 0, "local SBA read status");
        uint32_t local_value = uint32_t(ram[0]) | (uint32_t(ram[1]) << 8) | (uint32_t(ram[2]) << 16) | (uint32_t(ram[3]) << 24);
        check(dmi(1, 0x3c, 0) == local_value, "local SBA read value");
        dmi(2, 0x38, 0x00040000); dmi(2, 0x39, 0x20000000); dmi(2, 0x3c, 0x12345678);
        check(((dmi(1, 0x38, 0) >> 12) & 7) == 2, "owned-buffer debug write not rejected");
        check((uint32_t(ram[0]) | (uint32_t(ram[1]) << 8) | (uint32_t(ram[2]) << 16) | (uint32_t(ram[3]) << 24)) == local_value, "rejected SBA write produced an effect");
        dmi(2, 0x38, 0x00447000);
        dmi(2, 0x10, 0x40000001); dmi(2, 0x10, 1);
        until([&] { return released == 28; }, 64000, "resume duplicated or lost DSP block");
        dmi(2, 0x10, 3); dmi(2, 0x10, 1);
        until([&] { return boot_count == 2 && !dut.system_reset_o; }, 20000, "CPU reset recovery");
        check(dut.guard_epoch_o == 1 && dut.guard_tick_o > retained_tick, "CPU reset erased hardware epoch");
        arm();
        until([&] { return released == 30; }, 1000000, "second-epoch DSP blocks");
        dut.guard_stop_i = 1; tick(); dut.guard_stop_i = 0;
        until([&] { return dut.guard_closed_o && transport.empty() && !transport_active; }, 256000, "final drain");
        finish(30);
    }

    /* one common footer checks every completed consumer and distinguishes deliberately aborted CPU work. */
    void finish(unsigned expected_released) {
        check(max_ack <= 2048 && max_isr <= 800 && max_halt <= 224 && max_stop <= 256000, "service latency budget");
        unsigned published = 0, aborted = 0;
        /* complete raw blocks receive interrupts even when a later CPU reset aborts their optional DSP lease. */
        for (const auto &entry : blocks) { published += entry.second.rk != 0; aborted += entry.second.aborted; }
        check(released == expected_released && timer_ack == published && software_ack == published && exceptions == 2,
              "retained interrupt or exception count");
        check(dut.guard_accounting_exact_o && dut.guard_lost_tail_o == 0 && dut.guard_lost_events_o == 0, "hardware accounting loss");
        uint64_t record_count = 0;
        /* independent final ownership checks include partial tails and both consumers. */
        for (const auto &entry : blocks) {
            const Block &block = entry.second; record_count += block.records;
            check(block.publication && block.transported == 16 + block.records * 12, "unpublished or untransported raw tail");
        }
        check(dut.guard_emitted_o == record_count && dut.guard_retained_o == record_count && !dut.guard_invalid_o,
              "guard and physical capture count disagree");
        check(capture_words == transport_words && capture_words == record_count * 12 + blocks.size() * 16, "raw DMA transfer count");
        check(gzclose(terminals) == Z_OK, "terminal trace close"); terminals = nullptr;
        result << "{\"status\":\"pass\",\"profile\":\"SYNTH80\",\"mode\":\"" << (mutation == "active-reset" ? "active-reset" : "continuous-stall")
               << "\",\"aborted_blocks\":" << aborted << ",\"active_reset_observed\":" << active_reset_observed
               << ",\"cycles\":" << cycle << ",\"retirement_records\":" << trace_count
               << ",\"blocks_released\":" << released << ",\"epochs\":" << dut.guard_epoch_o << ",\"timer_ack\":" << timer_ack
               << ",\"software_ack\":" << software_ack << ",\"exceptions\":" << exceptions << ",\"host_stall_cycles\":" << stall_until - stall_begin
               << ",\"max_instruction\":" << max_instruction << ",\"max_local\":" << max_local << ",\"max_MMIO\":" << max_mmio
               << ",\"max_shared\":" << max_shared << ",\"max_capture\":" << max_capture << ",\"max_transport\":" << max_transport
               << ",\"max_DSP\":" << max_dsp << ",\"max_response\":" << max_response << ",\"max_ack\":" << max_ack
               << ",\"max_ISR\":" << max_isr << ",\"max_halt\":" << max_halt << ",\"max_stop_drain\":" << max_stop
               << ",\"capture_words\":" << capture_words << ",\"transport_words\":" << transport_words
               << ",\"reserved_debug_slots\":" << debug_slots << ",\"maintenance_slots\":" << maintenance_slots << ",\"blocks\":[";
        bool first = true;
        /* each completed block retains exact independent results, timing and consumer progress. */
        for (const auto &entry : blocks) {
            const Block &block = entry.second;
            if (!first) result << ',';
            first = false;
            result << "{\"id\":" << block.id << ",\"epoch\":" << block.epoch << ",\"ordinal\":" << block.ordinal
                   << ",\"rk\":" << block.rk << ",\"published\":" << block.publication << ",\"ack\":" << block.ack
                   << ",\"DSP_begin\":" << block.begin << ",\"DSP_end\":" << block.end << ",\"cut\":" << block.cut << ",\"aborted\":" << block.aborted
                   << ",\"reads\":" << block.reads << ",\"energy\":" << block.energy << ",\"signature\":" << block.signature
                   << ",\"quotient\":" << block.quotient << ",\"records\":" << block.records << ",\"transported\":" << block.transported << '}';
        }
        result << "],\"shared_phase_coverage\":[";
        for (unsigned index = 0; index < 160; ++index) result << (index ? "," : "") << shared_phases[index];
        result << "]}\n";
        std::cout << "SYNTHETIC_CPU_PASS blocks=" << released << " cycles=" << cycle << " DSP=" << max_dsp << " response=" << max_response << '\n';
    }

    /* failures still close the partial compressed trace for diagnosis. */
    ~Simulation() { if (terminals) gzclose(terminals); }
};

/* retain reproducible process status for both normal and deliberately corrupted runs. */
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    /* malformed invocations cannot silently select a default firmware image. */
    try {
        if (argc < 3) throw std::runtime_error("usage: simulator directory seed [mutation]");
        Simulation run(argv[1], uint32_t(std::stoul(argv[2])), argc > 3 ? argv[3] : ""); run.run();
        return 0;
    /* ordinary checker failures are retained in the launcher's complete log. */
    } catch (const std::exception &error) {
        std::cerr << "SYNTHETIC_CPU_FAILED " << error.what() << '\n'; return 1;
    }
}
