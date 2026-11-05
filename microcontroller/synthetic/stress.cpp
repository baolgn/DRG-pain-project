/* exercise complete synthetic records with reserved memory service and independent host checks. */
#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <limits>
#include <queue>
#include <stdexcept>
#include <string>
#include <vector>
#include <zlib.h>
#include "../firmware/synthetic/kernel.h"

using Tick = uint64_t;
constexpr Tick hz = 80000000, period = 1600, block_ticks = 409600;
constexpr size_t record_bytes = 48, header_bytes = 64, block_bytes = 12352;

/* fail the ordinary checker with a named invariant, including injected defects. */
static void check(bool value, const std::string &reason) {
    if (!value) throw std::runtime_error(reason);
}

/* serialize all multibyte fields explicitly as little endian. */
static void put(uint8_t *bytes, uint64_t value, unsigned count) {
    /* byte stores avoid host alignment and endian assumptions. */
    for (unsigned i = 0; i < count; ++i) bytes[i] = uint8_t(value >> (8 * i));
}

/* deserialize independently from the field construction operations. */
static uint64_t get(const uint8_t *bytes, unsigned count) {
    uint64_t value = 0;
    /* reverse iteration also handles unaligned fields. */
    for (unsigned i = count; i; --i) value = value * 256 + bytes[i - 1];
    return value;
}

/* independent widened arithmetic defines the signed eighteen-bit source oracle. */
static int32_t expected_sample(uint32_t epoch, uint32_t block, uint32_t frame, uint32_t channel) {
    uint64_t word = (uint64_t(epoch) * 0x9e3779b9ULL & 0xffffffffULL) ^
                    (uint64_t(block) * 0x045d9f3bULL & 0xffffffffULL) ^
                    (uint64_t(frame) * 0x27d4eb2dULL & 0xffffffffULL) ^
                    (uint64_t(channel) * 0x165667b1ULL & 0xffffffffULL);
    word ^= word / 8192;
    word = word * 0x85ebca6bULL & 0xffffffffULL;
    word ^= word / 65536;
    return int32_t(word % 262144) - 131072;
}

/* construct the provisional synthetic wire CRC table, without claiming ADC qualification. */
static std::array<uint16_t, 256> crc_table() {
    std::array<uint16_t, 256> table{};
    /* MSB-first taps are 0x755b, initial zero and no final complement. */
    for (unsigned byte = 0; byte < 256; ++byte) {
        uint16_t value = uint16_t(byte << 8);
        /* exactly eight recurrence steps define each table entry. */
        for (unsigned bit = 0; bit < 8; ++bit) value = uint16_t((value << 1) ^ ((value & 0x8000) ? 0x755b : 0));
        table[byte] = value;
    }
    return table;
}

/* preserve eight sample/status pairs as their exact 208-bit synthetic serial sequence. */
static uint16_t wire_crc(const uint8_t *record) {
    static const auto table = crc_table();
    uint64_t shift = 0;
    unsigned bits = 0;
    uint16_t value = 0;
    /* each channel contributes eighteen raw bits followed by its complete status byte. */
    for (unsigned channel = 0; channel < 8; ++channel) {
        shift = (shift << 26) | ((get(record + 4 * channel, 4) & 0x3ffff) << 8) | record[32 + channel];
        bits += 26;
        /* consume complete bytes in wire order; two-bit parcel boundaries are retained. */
        while (bits >= 8) {
            bits -= 8;
            unsigned byte = unsigned(shift >> bits) & 255;
            value = uint16_t((value << 8) ^ table[(value >> 8) ^ byte]);
        }
    }
    check(bits == 0, "wire-length");
    return value;
}

/* feed each channel bit directly, independently of the producer's byte-packing accumulator. */
static uint16_t wire_reference(const uint8_t *record) {
    uint32_t remainder = 0;
    /* raw sample and status fields are separate bit sequences in this oracle. */
    for (unsigned channel = 0; channel < 8; ++channel) {
        uint32_t sample = uint32_t(get(record + channel * 4, 4));
        /* sample bits precede status bits, with no byte-boundary assumption. */
        for (int bit = 25; bit >= 0; --bit) {
            unsigned input = bit >= 8 ? (sample >> (bit - 8)) & 1 : (record[32 + channel] >> bit) & 1;
            unsigned feedback = (remainder >> 15) ^ input;
            remainder = (remainder << 1) & 65535;
            if (feedback) remainder ^= 0x755b;
        }
    }
    return uint16_t(remainder);
}

/* check serial CRC mathematics using a separate bit recurrence and the published division vector. */
static void crc_checks() {
    uint32_t polynomial = 0x064e0000;
    /* long division includes the implicit degree-sixteen term. */
    for (int bit = 31; bit >= 16; --bit) if (polynomial & (1U << bit)) polynomial ^= 0x1755bU << (bit - 16);
    check(polynomial == 0x2137, "CRC-division-vector");
    /* every one-byte table entry is compared with an independent input-bit recurrence. */
    auto table = crc_table();
    /* cover every possible input byte. */
    for (unsigned byte = 0; byte < 256; ++byte) {
        uint32_t remainder = 0;
        /* feed each incoming bit into the high end before reducing the divisor. */
        for (int bit = 7; bit >= 0; --bit) {
            unsigned feedback = ((remainder >> 15) ^ (byte >> bit)) & 1;
            remainder = (remainder << 1) & 65535;
            if (feedback) remainder ^= 0x755b;
        }
        check(table[byte] == remainder, "CRC-table-oracle");
    }
    /* every wire bit crosses the independent byte-packing and bit-feeding implementations. */
    for (unsigned bit = 0; bit < 208; ++bit) {
        std::array<uint8_t, 48> record{};
        unsigned channel = bit / 26, field = bit % 26;
        if (field < 18) put(record.data() + channel * 4, 1U << field, 4);
        else record[32 + channel] = uint8_t(1U << (field - 18));
        check(wire_crc(record.data()) == wire_reference(record.data()), "CRC-wire-packing");
    }
    const int32_t examples[5][8] = {{0,0,0,0,0,0,0,0}, {-131072,-131072,-131072,-131072,-131072,-131072,-131072,-131072},
        {131071,131071,131071,131071,131071,131071,131071,131071}, {-131072,-1,0,1,131071,-131071,65535,-65536}, {0,0,0,0,0,0,0,0}};
    const uint16_t expected[5] = {0x3ead, 0xb7e7, 0x773e, 0x489b, 0xcfe0};
    const uint8_t statuses[8] = {0,255,128,127,1,254,85,170};
    /* these whole-frame vectors were derived separately by a Python bit-at-a-time oracle. */
    for (unsigned vector = 0; vector < 5; ++vector) {
        std::array<uint8_t, 48> record{};
        /* all sample boundaries and every status bit participate in the known checksums. */
        for (unsigned channel = 0; channel < 8; ++channel) {
            put(record.data() + channel * 4, uint32_t(examples[vector][channel]), 4);
            record[32 + channel] = vector == 4 ? statuses[channel] : uint8_t(channel);
        }
        check(wire_crc(record.data()) == expected[vector] && wire_reference(record.data()) == expected[vector], "CRC-whole-frame-vector");
    }
}

/* generate one record without using the host's widened sample oracle. */
static void record_make(uint8_t *record, uint32_t epoch, uint32_t block, uint32_t frame, bool invalid) {
    uint32_t flags = 0x80000000U | (invalid ? 0x00020000U : 255U);
    /* invalid placeholders have deterministic samples and no valid channel bits. */
    for (unsigned channel = 0; channel < 8; ++channel) {
        int32_t value = invalid ? 0 : synthetic_sample(epoch, block, frame, channel);
        put(record + 4 * channel, uint32_t(value), 4);
        record[32 + channel] = uint8_t(channel);
        if (!invalid && (value <= -131000 || value >= 131000)) flags |= 1U << (8 + channel);
    }
    put(record + 40, invalid ? 0 : wire_crc(record), 2);
    put(record + 42, 0, 2);
    put(record + 44, flags, 4);
}

/* model one physical ring slot; reuse requires every independent consumer to release it. */
struct Slot {
    std::array<uint8_t, block_bytes> bytes{};
    std::array<uint8_t, block_bytes> received{};
    uint64_t generation = 0, block = 0, first_tick = 0;
    uint32_t epoch = 0, frames = 0;
    bool occupied = false, published = false, cpu_done = false, transport_done = false;
    Tick reference = 0, publication = 0;
};

/* ordered event identities prevent late responses from reaching a reused slot. */
struct Event {
    Tick tick;
    unsigned kind, index;
    uint64_t generation;
    /* ties use a stable order and never rely on heap implementation details. */
    bool operator>(const Event &other) const {
        if (tick != other.tick) return tick > other.tick;
        if (kind != other.kind) return kind > other.kind;
        return index > other.index;
    }
};

/* run a finite schedule with actual record bytes and explicit modeled service. */
class Campaign {
    std::array<Slot, 64> ring{};
    std::priority_queue<Event, std::vector<Event>, std::greater<Event>> events;
    std::queue<unsigned> ready;
    std::vector<std::pair<Tick, Tick>> stalls;
    std::vector<Tick> restored;
    std::vector<unsigned> stall_free;
    std::vector<unsigned> stall_minimum;
    std::vector<uint64_t> released_after_stall;
    std::vector<Tick> service_idle;
    std::vector<unsigned> pending_at_idle;
    std::ofstream ledger;
    std::string scenario, mutation;
    Tick finish, now = 0, capture_cursor = 0, epoch_base = 39 * block_ticks, phase;
    Tick last_wire_finish = 0, worst_publication = 0, worst_firmware = 0, worst_restore = 0;
    uint64_t generated = 0, delivered = 0, initial_delivered = 0, blocks = 0;
    uint64_t capture_words = 0, transport_words = 0, retry_words = 0, cpu_words = 0;
    uint64_t effects = 0, kernel_jobs = 0, irq_episodes = 0;
    uint64_t raw_bytes = 0, wire_bytes = 0, lost_tail = 0, invalid_frames = 0;
    uint64_t next_host_block = 0, next_initial_block = 0, fingerprint = 1469598103934665603ULL;
    unsigned minimum_free = 64, peak_owned = 0, next_slot = 0, staging = 0, peak_staging = 0, pending_acks = 0;
    uint64_t peak_capture_work = 0;
    bool transport_busy = false, injected = false, stopped = false, admitted = true;
    Tick stop_tick = 0, late_tick = 0;
    Tick request_offer = 0, last_trigger = 0;
    bool request_owned = false, request_accepted = false, request_acted = false, request_responded = false;
    unsigned request_effects = 0, request_responses = 0, request_offset = 0, request_launches = 0;
    uint32_t request_data = 0;
    std::string stop_reason = "none";

    /* select the next eligible reservation; no master borrows another master's slot. */
    static Tick next_start(Tick eligible, const std::vector<unsigned> &slots) {
        Tick base = eligible / 160 * 160;
        /* reservations repeat without refresh blackouts outside the maintenance slot. */
        for (unsigned slot : slots) if (base + slot * 16 >= eligible) return base + slot * 16;
        return base + 160 + slots.front() * 16;
    }

    /* aggregate consecutive reservations algebraically while retaining exact word counts. */
    static Tick burst(Tick offer, uint64_t words, const std::vector<unsigned> &slots) {
        check(words > 0, "empty-burst");
        Tick first = next_start(offer + 4, slots);
        auto position = std::find(slots.begin(), slots.end(), unsigned(first % 160 / 16));
        check(position != slots.end(), "reservation-owner");
        uint64_t last = uint64_t(position - slots.begin()) + words - 1;
        return first / 160 * 160 + last / slots.size() * 160 + slots[last % slots.size()] * 16 + 12;
    }

    /* count one reserved class over a closed interval, including partial TDMA periods. */
    static uint64_t reservations(Tick first, Tick last, unsigned slot) {
        Tick offset = slot * 16;
        uint64_t through = last < offset ? 0 : (last - offset) / 160 + 1;
        uint64_t before = first <= offset ? 0 : (first - 1 - offset) / 160 + 1;
        return through - before;
    }

    /* count genuinely free slots, excluding active capture and all consumer leases. */
    unsigned free_slots() const {
        unsigned count = 0;
        for (const auto &slot : ring) count += !slot.occupied;
        return count;
    }

    /* only capture may write an unpublished owned block; all consumers are read-only. */
    static void memory_access(const Slot &slot, unsigned master, bool write) {
        check(slot.occupied, "unowned-memory-access");
        if (write) check(master == 0 && !slot.published, "raw-write-denied");
        else check(slot.published && master != 0, "unpublished-read");
    }

    /* capture a free descriptor without overwriting any owned generation. */
    unsigned allocate(uint64_t block, uint32_t count, uint32_t epoch, Tick first) {
        /* a circular search may skip owned slots but can never steal one. */
        for (unsigned offset = 0; offset < 64; ++offset) {
            unsigned index = (next_slot + offset) % 64;
            auto &slot = ring[index];
            /* generation exhaustion stops reuse instead of wrapping a stale response into validity. */
            if (!slot.occupied) {
                check(slot.generation != UINT64_MAX, "generation-exhausted");
                ++slot.generation; slot.block = block; slot.epoch = epoch; slot.frames = count;
                slot.first_tick = first; slot.occupied = true; slot.published = false;
                slot.cpu_done = epoch == 0 || count != 256; slot.transport_done = false;
                slot.bytes.fill(0); next_slot = (index + 1) % 64;
                minimum_free = std::min(minimum_free, free_slots());
                peak_owned = std::max(peak_owned, 64 - free_slots());
                /* capacity is sampled throughout each actual stall and its recovery interval. */
                for (size_t i = 0; i < stalls.size(); ++i) {
                    if (stall_free[i] && !restored[i] && now >= stalls[i].first) stall_minimum[i] = std::min(stall_minimum[i], free_slots());
                }
                return index;
            }
        }
        throw std::runtime_error("ring-no-free");
    }

    /* finalize a header only after the modeled payload write completions. */
    void header(Slot &slot) {
        auto *data = slot.bytes.data();
        put(data, 0x31534744, 4); put(data + 4, 1, 2); put(data + 6, 64, 2);
        put(data + 8, slot.epoch, 4); put(data + 12, 1, 4); put(data + 16, slot.block, 8);
        put(data + 24, slot.block * 256, 8); put(data + 32, slot.first_tick, 8);
        put(data + 40, period, 4); put(data + 44, slot.frames, 2); put(data + 46, 48, 2);
        put(data + 48, slot.frames * 48, 4); put(data + 52, 0x80000000U | (slot.frames < 256 ? 3U : 0U), 4);
        put(data + 56, crc32(0, data + 64, slot.frames * 48), 4);
        put(data + 60, crc32(0, data, 60), 4);
    }

    /* validate each delivered frame independently of its stored checksums. */
    void host_check(const Slot &slot) {
        const uint8_t *data = slot.received.data();
        check(get(data, 4) == 0x31534744 && get(data + 4, 2) == 1 && get(data + 6, 2) == 64, "header-format");
        check(get(data + 8, 4) == slot.epoch && get(data + 12, 4) == 1 && get(data + 16, 8) == slot.block, "header-identity");
        check(get(data + 24, 8) == slot.block * 256 && get(data + 32, 8) == slot.first_tick && get(data + 40, 4) == 1600, "timestamp-sequence");
        check(get(data + 32, 8) == (slot.epoch ? epoch_base + phase : 0) + slot.block * block_ticks, "scheduled-timestamp");
        check(get(data + 44, 2) == slot.frames && get(data + 46, 2) == 48 && get(data + 48, 4) == slot.frames * 48, "payload-length");
        check(get(data + 52, 4) == (0x80000000U | (slot.frames < 256 ? 3U : 0U)), "header-flags");
        check(get(data + 60, 4) == crc32(0, data, 60), "header-crc");
        check(get(data + 56, 4) == crc32(0, data + 64, slot.frames * 48), "payload-crc");
        /* delivered ordering includes the independently initialized pre-stall backlog. */
        if (slot.epoch == 0) check(slot.block == next_initial_block++, "initial-block-sequence");
        else check(slot.block == next_host_block++, "block-sequence");
        /* frame identity is implicit in the retained scheduled slot, never inferred from arrival time. */
        for (uint32_t frame = 0; frame < slot.frames; ++frame) {
            const auto *record = data + 64 + frame * 48;
            uint32_t flags = uint32_t(get(record + 44, 4));
            bool invalid = false;
            uint32_t expected_flags = 0x80000000U | (invalid ? 0x20000U : 255U);
            check(!invalid || (slot.frames < 256 && frame + 1 == slot.frames && (scenario == "debug-halt" || scenario == "cpu-reset")), "unexpected-invalid");
            /* all eight channels, status bytes and reserved bytes are checked before release. */
            for (uint32_t channel = 0; channel < 8; ++channel) {
                int32_t value = invalid ? 0 : expected_sample(slot.epoch, uint32_t(slot.block), frame, channel);
                check(get(record + 4 * channel, 4) == uint32_t(value), "sample-or-slot");
                check(record[32 + channel] == channel, "channel-status");
                if (!invalid && (value <= -131000 || value >= 131000)) expected_flags |= 1U << (channel + 8);
            }
            check(flags == expected_flags && get(record + 42, 2) == 0, "record-flags");
            check(get(record + 40, 2) == (invalid ? 0 : wire_crc(record)), "wire-crc");
            /* a bitwise oracle checks every block boundary independently of byte packing. */
            if (frame == 0 || frame + 1 == slot.frames) check(get(record + 40, 2) == wire_reference(record), "wire-packing-reference");
        }
        /* a compact binary ledger records every checked block, including the final partial block. */
        std::array<uint8_t, 64> row{};
        put(row.data(), slot.epoch, 4); put(row.data() + 4, slot.frames, 4);
        put(row.data() + 8, slot.block, 8); put(row.data() + 16, slot.generation, 8);
        put(row.data() + 24, slot.first_tick, 8); put(row.data() + 32, slot.publication, 8);
        put(row.data() + 40, now, 8); put(row.data() + 48, get(data + 56, 4), 4);
        put(row.data() + 52, get(data + 60, 4), 4); put(row.data() + 56, slot.frames * 48 + 64, 8);
        ledger.write(reinterpret_cast<const char *>(row.data()), row.size());
        check(bool(ledger), "ledger-write");
        /* this fingerprint is diagnostic; the runner additionally seals the whole ledger with SHA-256. */
        for (uint8_t byte : row) { fingerprint ^= byte; fingerprint *= 1099511628211ULL; }
    }

    /* run the same native DSP kernel as firmware, with a separate widened reference. */
    void analyze(Slot &slot) {
        check(slot.published && !slot.cpu_done && slot.frames == 256, "analysis-lease");
        memory_access(slot, 1, false);
        int32_t samples[16];
        int64_t previous = 0, earlier = 0;
        uint64_t energy = 0, signature = 0;
        /* only sixteen leased sample words are read; hardware owns all raw movement. */
        for (unsigned index = 0; index < 16; ++index) {
            samples[index] = int32_t(uint32_t(get(slot.bytes.data() + 64 + index * 16 * 48, 4)));
            int64_t sample = expected_sample(slot.epoch, uint32_t(slot.block), index * 16, 0);
            int64_t filtered = sample - previous * 2 + earlier;
            energy = (energy + uint64_t(filtered * filtered)) & 0xffffffffULL;
            signature = (signature + uint64_t(filtered * int64_t(index + 1))) & 0xffffffffULL;
            earlier = previous; previous = sample;
        }
        auto result = synthetic_kernel(samples, 17);
        check(result.energy == energy && result.signature == signature && result.quotient == energy / 17, "DSP-result");
        Tick memory_done = burst(slot.publication + 1024, 16, {2, 6});
        check(memory_done <= now && now - slot.reference <= 320000, "firmware-deadline");
        worst_firmware = std::max(worst_firmware, now - slot.reference);
        cpu_words += 16; ++kernel_jobs; irq_episodes += 9; slot.cpu_done = true;
    }

    /* pause only consumer service; capture and all reserved memory slots keep running. */
    Tick service_finish(Tick start, Tick work) const {
        Tick cursor = start;
        /* each outage in this list is a host outage, never a memory-service outage. */
        for (const auto &[begin, end] : stalls) {
            if (end + 80000 <= cursor) continue;
            if (begin >= cursor + work) break;
            /* completed service before an outage is never charged twice. */
            if (begin > cursor) { work -= begin - cursor; cursor = begin; }
            cursor = std::max(cursor, end + 80000);
        }
        return cursor + work;
    }

    /* a stopped host cannot acknowledge a block merely because memory readback finished. */
    Tick acknowledgement(Tick wire) const {
        Tick ack = wire + 80000;
        for (const auto &[begin, end] : stalls) if (ack >= begin && ack < end) ack = end + 80000;
        return ack;
    }

    /* schedule serialized unique payload at five MB/s while reserving retry traffic separately. */
    void kick() {
        if (transport_busy || staging == 2 || ready.empty()) return;
        unsigned index = ready.front(); ready.pop();
        auto &slot = ring[index];
        check(slot.occupied && slot.published && !slot.transport_done, "transport-owner");
        memory_access(slot, 2, false);
        Tick start = now;
        /* service restart is bounded to one millisecond after consumer availability. */
        for (const auto &[begin, end] : stalls) if (start >= begin && start < end + 80000) start = end + 80000;
        uint64_t bytes = slot.frames * 48 + 64, words = bytes / 4 + 16;
        Tick memory_done = burst(start, words, {1, 3, 5});
        /* the transport master arbitrates unique versus retry work before each first-valid offer. */
        Tick first_bus_completion = burst(start, 1, {1, 3, 5, 7});
        check(first_bus_completion - start <= 96, "transport-first-offer");
        Tick first_buffered = burst(start, 16, {1, 3, 5});
        Tick wire = service_finish(std::max(last_wire_finish, first_buffered), bytes * 16);
        check(memory_done <= wire, "transport-underrun");
        transport_words += words;
        retry_words += reservations(next_start(start + 4, {1, 3, 5, 7}), memory_done, 7);
        wire_bytes += bytes; transport_busy = true; last_wire_finish = wire;
        slot.received = slot.bytes;
        ++staging; peak_staging = std::max(peak_staging, staging);
        ++pending_acks;
        events.push({memory_done, 2, index, slot.generation});
        events.push({wire, 4, index, slot.generation});
        events.push({acknowledgement(wire), 3, index, slot.generation});
    }

    /* actual slot reuse follows both transport acknowledgement and the analysis lease. */
    void release(Slot &slot) {
        if (slot.transport_done && slot.cpu_done) slot.occupied = false;
    }

    /* enforce the completed-release service curve before each next acknowledgement. */
    void release_envelope(Tick tick) const {
        if (scenario != "healthy" && scenario != "host100") return;
        /* reserve restoration or observed source starvation ends this backlogged service window. */
        for (size_t i = 0; i < stalls.size(); ++i) {
            if (!stall_free[i] || restored[i] || service_idle[i] || tick <= stalls[i].second + 365632) continue;
            /* retain exact service evidence when the ordinary inequality fails. */
            if (released_after_stall[i] * 16 < tick - stalls[i].second - 365632) {
                std::cerr << "SERVICE_CONTEXT tick=" << tick << " stall=" << i << " return=" << stalls[i].second
                          << " bytes=" << released_after_stall[i] << " free=" << free_slots() << " baseline=" << stall_free[i]
                          << " ready=" << ready.size() << " staging=" << staging << '\n';
            }
            check(released_after_stall[i] * 16 >= tick - stalls[i].second - 365632, "consumer-service-envelope");
        }
    }

    /* process only visible completions, checking every response against its original generation. */
    void advance(Tick target) {
        /* publication, firmware work and transport complete concurrently in virtual time. */
        while (!events.empty() && events.top().tick <= target) {
            auto event = events.top(); events.pop(); now = event.tick;
            release_envelope(now ? now - 1 : 0);
            /* later stall admission uses the exact onset, not a following block boundary. */
            if (event.kind == 8) {
                check(restored[event.index - 1] != 0, "stall-overlaps-recovery");
                stall_free[event.index] = free_slots(); stall_minimum[event.index] = free_slots();
                check(free_slots() >= 24, "stall-readmission");
                continue;
            }
            auto &slot = ring[event.index];
            if (event.kind == 3 && slot.generation == event.generation) check(!slot.transport_done, "duplicate-acknowledgement");
            check(slot.occupied && slot.generation == event.generation, "stale-generation");
            /* late memory activity belongs only to the original retained faulting request. */
            if (event.kind >= 5 && event.kind <= 7) {
                check(request_owned && !request_responded, "unowned-memory-response");
                /* acceptance cannot repeat even when it occurs after the deadline. */
                if (event.kind == 5) { check(!request_accepted, "duplicate-memory-accept"); request_accepted = true; }
                /* effect and response are separate events, including a lost-response outage. */
                else if (event.kind == 6) {
                    check(request_accepted && !request_acted, "duplicate-memory-effect");
                    memory_access(slot, 0, true);
                    put(slot.bytes.data() + request_offset, request_data, 4);
                    request_acted = true; ++request_effects; ++effects;
                /* a response drains the original owner without reviving its epoch. */
                } else {
                    check(request_accepted, "response-before-acceptance");
                    request_responded = true; request_owned = false; ++request_responses;
                    if (scenario != "memory-error") check(now > request_offer + 128 && stopped && !slot.published, "late-response-published");
                }
                continue;
            }
            /* publication is the sole transition that authorizes host or CPU reads. */
            if (event.kind == 0) {
                check(!slot.published && now >= slot.publication, "publish-before-completion");
                slot.published = true; ready.push(event.index);
                /* only complete blocks receive optional analysis jobs. */
                if (!slot.cpu_done) events.push({slot.reference + 64000, 1, event.index, slot.generation});
                kick();
            /* native analysis has an explicitly modeled elapsed-time reservation. */
            } else if (event.kind == 1) {
                analyze(slot); release(slot);
            /* RAM-read completion permits another prefetch without releasing the raw descriptor. */
            } else if (event.kind == 2) {
                transport_busy = false; kick();
            /* two explicit staging buffers cover streaming and one block of prefetch. */
            } else if (event.kind == 4) {
                check(staging > 0, "transport-staging-owner"); --staging; kick();
                /* an empty eligible source ends this backlogged recovery-service window, never the reserve deadline. */
                if (!staging && !transport_busy && ready.empty()) {
                    /* queued acknowledgements retain their own independently scheduled deadline. */
                    for (size_t i = 0; i < stalls.size(); ++i) {
                        /* retain the first source-empty boundary after this consumer outage. */
                        if (stall_free[i] && !service_idle[i] && now >= stalls[i].second) {
                            service_idle[i] = now; pending_at_idle[i] = pending_acks;
                        }
                    }
                }
            /* acknowledgement is counted once and the complete data are independently checked. */
            } else {
                check(!slot.transport_done, "duplicate-acknowledgement");
                check(pending_acks > 0, "acknowledgement-owner"); --pending_acks;
                host_check(slot); slot.transport_done = true;
                /* retries do not enter unique acknowledged-payload accounting. */
                for (size_t i = 0; i < stalls.size(); ++i) {
                    if (now >= stalls[i].second) released_after_stall[i] += slot.frames * 48 + 64;
                }
                if (slot.epoch == 0) initial_delivered += slot.frames;
                /* measured output excludes the separately identified initial backlog. */
                else { delivered += slot.frames; raw_bytes += slot.frames * 48 + 64; ++blocks; }
                /* injecting a repeated acknowledgement must trip the ordinary owner check. */
                if (mutation == "duplicate-ack" && !injected && slot.epoch == 1) {
                    injected = true; events.push(event);
                }
                release(slot);
            }
            /* record the first restoration of the consumed pre-stall reservation. */
            for (size_t i = 0; i < stalls.size(); ++i) {
                if (stall_free[i] && !restored[i] && now >= stalls[i].second && free_slots() >= stall_free[i]) restored[i] = now;
            }
        }
        now = target;
        release_envelope(now);
    }

    /* preexisting completed blocks are readable and cannot obstruct consumer progress. */
    void preload(unsigned count) {
        /* the initial backlog is identified as epoch zero and excluded from measurement totals. */
        for (unsigned block = 0; block < count; ++block) {
            unsigned index = allocate(block, 256, 0, block * block_ticks);
            auto &slot = ring[index];
            for (unsigned frame = 0; frame < 256; ++frame) record_make(slot.bytes.data() + 64 + frame * 48, 0, block, frame, false);
            header(slot); slot.published = true; ready.push(index);
        }
    }

public:
    /* every run has a fresh ledger and explicit deterministic input schedule. */
    Campaign(Tick duration, const std::string &mode, const std::string &defect, const std::string &path, uint64_t seed)
        : ledger(path, std::ios::binary), scenario(mode), mutation(defect), finish(duration), phase(seed % 160) {
        check(bool(ledger), "ledger-open");
        check(duration > 0 && duration <= hz * 1800 && duration % period == 0, "unsupported-duration");
        if (mutation == "generation-wrap") ring[0].generation = UINT64_MAX;
        if (scenario == "healthy" || scenario == "host100" || scenario == "insufficient-reserve") stalls.push_back({phase, phase + hz / 10});
        if (scenario == "host-starve") stalls.push_back({phase, phase + hz * 10});
        /* repeated stalls are widely separated and must each requalify free capacity. */
        if (scenario == "healthy") for (Tick tick = hz * 60; tick + hz < finish; tick += hz * 60) stalls.push_back({tick, tick + hz / 10});
        restored.assign(stalls.size(), 0); stall_free.assign(stalls.size(), 0); stall_minimum.assign(stalls.size(), 64);
        released_after_stall.assign(stalls.size(), 0);
        service_idle.assign(stalls.size(), 0); pending_at_idle.assign(stalls.size(), 0);
        /* noninitial stall onset remains an event even when it falls inside a frame or DMA burst. */
        for (unsigned i = 1; i < stalls.size(); ++i) events.push({stalls[i].first, 8, i, 0});
    }

    /* sweep every reservation phase independently of the particular long-run phase. */
    static void service_checks() {
        /* completion includes four readiness clocks and twelve clocks of target service. */
        for (Tick phase = 0; phase < 160; ++phase) {
            check(burst(phase, 1, {0, 4}) - phase <= 128, "capture-service-bound");
            check(burst(phase, 1, {1, 3, 5, 7}) - phase <= 96, "transport-service-bound");
            check(burst(phase, 1, {2, 6}) - phase <= 128, "CPU-service-bound");
            check(burst(phase, 1, {8}) - phase <= 192, "debug-service-bound");
            Tick preceding = burst(phase, 1, {1, 3, 5, 7});
            /* every later transport descriptor, including retries, launches after the previous reply. */
            for (unsigned request = 0; request < 12; ++request) {
                Tick offered = preceding + 1;
                Tick completed = burst(offered, 1, {1, 3, 5, 7});
                check(completed - offered <= 96, "transport-interleaved-offer"); preceding = completed;
            }
            /* an explicit interleaver checks the algebraic unique/retry schedule for every initial phase. */
            for (unsigned unique = 1; unique <= 32; ++unique) {
                Tick cursor = next_start(phase + 4, {1, 3, 5, 7}), last = 0;
                unsigned data = 0, retries = 0;
                /* class choice precedes request launch; queued unique work is not yet bus-valid. */
                while (data < unique) {
                    if (cursor % 160 == 112) ++retries;
                    else ++data;
                    last = cursor + 12;
                    cursor = next_start(last + 4, {1, 3, 5, 7});
                }
                check(last == burst(phase, unique, {1, 3, 5}), "transport-interleave-completion");
                check(retries == reservations(next_start(phase + 4, {1, 3, 5, 7}), last, 7), "retry-traffic-accounting");
            }
        }
    }

    /* generate actual byte records while all completion schedules remain independently owned. */
    void run() {
        service_checks(); crc_checks();
        unsigned old = (scenario == "healthy" || scenario == "host100" || scenario == "host-starve") ? 39 : scenario == "insufficient-reserve" ? 40 : 0;
        preload(old);
        uint64_t total = finish / period;
        /* one iteration creates a block, but every frame and word count is retained and checked. */
        for (uint64_t block = 0, first = 0; first < total && !stopped; ++block, first += 256) {
            Tick start = first * period + phase; advance(start);
            /* capacity exhaustion is visible and cannot authorize overwrite or fictitious frames. */
            if (!free_slots()) { stopped = true; stop_tick = start; stop_reason = "ring-exhausted"; break; }
            uint32_t count = uint32_t(std::min<uint64_t>(256, total - first));
            unsigned index = allocate(block, count, 1, epoch_base + start);
            auto &slot = ring[index];
            /* the first active capture owner is excluded from the required free-buffer count. */
            if (block == 0 && !stalls.empty()) {
                stall_free[0] = free_slots();
                stall_minimum[0] = free_slots();
                /* reject the request before admitting a single new frame. */
                if (free_slots() < 24) { admitted = false; stopped = true; stop_reason = "stall-reserve-rejected"; stop_tick = 0; slot.occupied = false; break; }
            }
            /* an active ring block owns its payload throughout all DMA completions. */
            for (uint32_t frame = 0; frame < count; ++frame) {
                Tick aperture = start + frame * period, ready_tick = aperture + 1040;
                bool interrupted = (scenario == "debug-halt" || scenario == "cpu-reset") && block == 3 && frame == 127;
                std::array<uint8_t, 48> assembled{};
                record_make(assembled.data(), 1, uint32_t(block), frame, false);
                ++generated; last_trigger = aperture;
                uint64_t queued = 12 + (frame + 1 == count || interrupted ? 32 : 0);
                /* previous queued writes occupy only the remaining reserved completion slots. */
                if (capture_cursor > ready_tick) {
                    queued += reservations(ready_tick > 11 ? ready_tick - 11 : 0, capture_cursor - 12, 0);
                    queued += reservations(ready_tick > 11 ? ready_tick - 11 : 0, capture_cursor - 12, 4);
                }
                peak_capture_work = std::max(peak_capture_work, queued * 4);
                check(peak_capture_work <= 252, "healthy-capture-backlog");
                Tick offer = std::max(ready_tick, capture_cursor);
                /* injected memory failure is detected by its transaction deadline, not FIFO capacity. */
                if (scenario.starts_with("memory-") && block == 2 && frame == 17) {
                    stopped = true; stop_reason = scenario; stop_tick = offer + (scenario == "memory-error" ? 16 : 132);
                    lost_tail = frame + 1; slot.frames = frame + 1;
                    late_tick = scenario == "memory-error" ? 0 : offer + 2016;
                    check(!request_owned && request_launches == 0, "uncertain-request-replay");
                    request_owned = true; request_offer = offer; ++request_launches;
                    request_offset = 64 + frame * 48; request_data = uint32_t(get(assembled.data(), 4));
                    Tick acceptance = scenario == "memory-outage" ? offer + 2004 : offer + 4;
                    events.push({acceptance, 5, index, slot.generation});
                    /* an error responder guarantees no effect; uncertain replies do not. */
                    if (scenario != "memory-error") events.push({scenario == "memory-outage" ? offer + 2012 : offer + 16, 6, index, slot.generation});
                    events.push({scenario == "memory-error" ? offer + 16 : late_tick, 7, index, slot.generation});
                    break;
                }
                memory_access(slot, 0, true);
                std::copy(assembled.begin(), assembled.end(), slot.bytes.data() + 64 + frame * 48);
                capture_cursor = burst(offer, 12, {0, 4}); capture_words += 12; effects += 12;
                /* reset and halt finish the already-triggered good frame before closing the epoch. */
                if (interrupted) {
                    stopped = true; stop_reason = scenario; stop_tick = aperture + 500;
                    slot.frames = frame + 1; break;
                }
            }
            if (lost_tail) break;
            slot.reference = start + (slot.frames - 1) * period;
            header(slot);
            capture_cursor = burst(capture_cursor, 32, {0, 4}); capture_words += 32; effects += 32;
            slot.publication = capture_cursor;
            worst_publication = std::max(worst_publication, slot.publication - slot.reference);
            check(slot.publication - slot.reference <= 8000, "publication-deadline");
            /* an interrupted partial block does not keep an optional CPU lease alive. */
            if (slot.frames != 256) slot.cpu_done = true;
            Tick publication_event = slot.publication;
            uint64_t generation = slot.generation;
            /* ordinary checks must detect altered data even when checksums are recomputed. */
            if (!injected && block == 2 && mutation != "none" && mutation != "duplicate-ack") {
                injected = true;
                /* a fresh checksum cannot excuse a changed source value. */
                if (mutation == "wrong-sample") { slot.bytes[112] ^= 1; header(slot); }
                /* replacing a record keeps its length while violating scheduled-slot identity. */
                else if (mutation == "drop-record") { std::copy_n(slot.bytes.data() + 160, 48, slot.bytes.data() + 112); header(slot); }
                else if (mutation == "crc-corruption") slot.bytes[112] ^= 1;
                else if (mutation == "duplicate-write") ++effects;
                else if (mutation == "stale-generation") --generation;
                else if (mutation == "publish-early") --publication_event;
                else if (mutation == "raw-write") memory_access(slot, 1, true);
                else check(false, "unknown-mutation");
            }
            events.push({publication_event, 0, index, generation});
            kick();
            if (block && block % 50000 == 0) std::cout << "SYNTHETIC_PROGRESS frames=" << generated << '\n' << std::flush;
        }
        /* all issued publications and consumer effects drain before assessing final accounting. */
        while (!events.empty()) advance(events.top().tick);
        advance(std::max(now, finish + phase));
        check(capture_words == (generated - (lost_tail ? 1 : 0)) * 12 + blocks * 32, "capture-word-accounting");
        check(effects == capture_words + request_effects, "duplicate-memory-effect");
        check(!stopped || !generated || last_trigger <= stop_tick, "trigger-after-stop");
        if (stopped && !lost_tail) check(capture_cursor <= stop_tick + 256000, "stop-drain-deadline");
        /* uncommitted tail loss is explicit; every other generated record must be delivered once. */
        check(delivered + lost_tail == generated, "silent-record-loss");
        if (scenario == "healthy" || scenario == "host100") check(!stopped && generated == total, "healthy-run-stopped");
        if (scenario == "host-starve") check(stopped && stop_reason == "ring-exhausted", "overload-not-observable");
        if (scenario.starts_with("memory-")) check(stopped && lost_tail == 18 && blocks == 2 && request_responses == 1 && !request_owned, "memory-containment");
        if (scenario == "debug-halt" || scenario == "cpu-reset") check(stopped && invalid_frames == 0 && generated == 896, "stop-boundary");
        /* test every qualified consumer outage against the independent reserve-recovery deadline. */
        for (size_t i = 0; i < stalls.size(); ++i) {
            if (scenario != "healthy" && scenario != "host100") break;
            check(restored[i] >= stalls[i].second && restored[i] - stalls[i].second <= hz * 110 / 1000, "reserve-recovery-deadline");
            check(stall_free[i] - stall_minimum[i] <= 22, "incremental-backlog-bound");
            worst_restore = std::max(worst_restore, restored[i] - stalls[i].second);
        }
        check(!mutation.compare("none") || injected, "mutation-not-exercised");
        ledger.close();
    }

    /* report scope and exact integer counts, never a hardware or CPU WCET claim. */
    void report(const std::string &path) const {
        std::ofstream out(path);
        out << "{\n\"status\":\"passed\",\"scope\":\"discrete-event full-record model; native DSP, modeled firmware timing; no physical or 1800-second RTL claim\","
            << "\n\"scenario\":\"" << scenario << "\",\"admitted\":" << (admitted ? "true" : "false")
            << ",\"stopped\":" << (stopped ? "true" : "false") << ",\"stop_reason\":\"" << stop_reason << "\","
            << "\n\"duration_ticks\":" << finish << ",\"generated_frames\":" << generated << ",\"delivered_frames\":" << delivered
            << ",\"initial_backlog_frames\":" << initial_delivered << ",\"blocks\":" << blocks << ",\"raw_bytes\":" << raw_bytes
            << ",\"lost_tail_frames\":" << lost_tail << ",\"invalid_frames\":" << invalid_frames << ",\"stop_tick\":" << stop_tick
            << ",\"late_original_completion_tick\":" << late_tick << ",\"transaction_replays\":" << (request_launches ? request_launches - 1 : 0)
            << ",\"future_triggers_after_stop\":" << unsigned(stopped && generated && last_trigger > stop_tick)
            << ",\"timebase_final_ticks\":" << now << ",\"last_trigger_tick\":" << last_trigger << ','
            << "\n\"fault_request_effects\":" << request_effects << ",\"fault_request_responses\":" << request_responses
            << ",\"fault_first_valid_tick\":" << request_offer << ",\"capture_final_completion_tick\":" << capture_cursor
            << ",\"tail_drain_fault\":" << (lost_tail ? "true" : "false")
            << ",\"peak_queued_capture_bytes_including_metadata\":" << peak_capture_work
            << ",\"maximum_transport_staging_bytes\":" << peak_staging * block_bytes << ",\"phase_seed_mod160\":" << phase
            << ",\n\"capture_words\":" << capture_words << ",\"transport_words_including_prehistory\":" << transport_words
            << ",\"retry_words\":" << retry_words << ",\"CPU_sample_words\":" << cpu_words << ",\"native_DSP_jobs\":" << kernel_jobs
            << ",\"reserved_IRQ_episodes\":" << irq_episodes << ",\"minimum_free_slots\":" << minimum_free << ",\"peak_owned_slots\":" << peak_owned
            << ",\"maximum_publication_cycles\":" << worst_publication << ",\"modeled_firmware_response_cycles\":" << worst_firmware
            << ",\"maximum_reserve_restore_cycles\":" << worst_restore << ",\"host_stalls\":" << stalls.size()
            << ",\"first_stall_free_slots\":" << (stall_free.empty() ? 0 : stall_free[0]) << ",\"ledger_fingerprint\":" << fingerprint << ",\"stalls\":[";
        /* retain every exact admission snapshot and reserve-restoration observation. */
        for (size_t i = 0; i < stalls.size(); ++i) {
            if (i) out << ',';
            out << "{\"onset\":" << stalls[i].first << ",\"return\":" << stalls[i].second << ",\"free_at_onset\":" << stall_free[i]
                << ",\"minimum_free\":" << stall_minimum[i] << ",\"restored\":" << restored[i]
                << ",\"eligible_source_empty_tick\":" << service_idle[i] << ",\"pending_ACKs_at_empty\":" << pending_at_idle[i] << '}';
        }
        out << "]\n}\n";
        check(bool(out), "summary-write");
    }
};

/* a failed detector keeps its named reason and never emits a passing summary. */
int main(int argc, char **argv) {
    /* the runner records every invocation and maps negative cases to exact invariant names. */
    try {
        check(argc == 7, "arguments: ticks scenario mutation ledger summary seed");
        Campaign campaign(std::stoull(argv[1]), argv[2], argv[3], argv[4], std::stoull(argv[6]));
        campaign.run(); campaign.report(argv[5]);
        std::cout << "SYNTHETIC_MODEL_PASS\n";
        return 0;
    /* unexpected failures remain distinguishable from expected overload outcomes. */
    } catch (const std::exception &error) {
        std::cerr << "SYNTHETIC_MODEL_FAILURE " << error.what() << '\n';
        return 1;
    }
}
