/* expose the actual RTL JTAG pins to OpenOCD remote_bitbang with independent memory effects. */
#include "Vdrg5_debug_system.h"
#include "verilated.h"
#include "debug_trace_fields.h"
#include <arpa/inet.h>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <netinet/tcp.h>
#include <poll.h>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <unistd.h>

/* each bus model keeps its own acceptance and response schedule. */
struct Owner {
    bool owned = false, accepted = false, write = false;
    uint32_t address = 0, data = 0, tag = 0, reply = 0;
    unsigned size = 0, strobes = 0, parcels = 0, age = 0, wait = 0, status = 0;
    unsigned accept_delay = 0, response_delay = 0;
};

/* model RAM and deliberate MMIO effects without referring to retiring instructions. */
class Platform {
    Vdrg5_debug_system dut;
    Owner instruction, data, system;
    std::map<uint32_t, uint8_t> memory;
    std::ofstream trace;
    uint64_t cycle = 0, events = 0, retired = 0, traps = 0, i_access = 0, d_access = 0, sb_access = 0;
    uint64_t mmio_reads = 0, mmio_writes = 0;
    uint32_t irq_levels = 0, rng;
    bool previous_halt = false, previous_reset = false;

    /* portable field offsets come from the same retained packed-type schema as the log. */
    uint64_t field(unsigned lsb, unsigned width) {
        uint64_t result = 0;
        /* no architectural field requested here is wider than sixty-four bits. */
        for (unsigned bit = 0; bit < width; ++bit) {
            result |= uint64_t((dut.trace_o[(lsb + bit) / 32] >> ((lsb + bit) % 32)) & 1) << bit;
        }
        return result;
    }

    /* xorshift changes service timing while preserving a reproducible architectural program. */
    uint32_t random_word() {
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        return rng;
    }

    /* memory starts with a WFI loop; debuggers load writable instruction RAM through SBA. */
    uint32_t read_word(uint32_t address) {
        uint32_t result = 0;
        /* reads return exactly four little-endian byte lanes. */
        for (unsigned lane = 0; lane < 4; ++lane) {
            auto found = memory.find((address & ~3u) + lane);
            if (found != memory.end()) result |= uint32_t(found->second) << (lane * 8);
        }
        return result;
    }

    /* a word write changes only explicitly enabled lanes. */
    void write_word(uint32_t address, uint32_t value, unsigned strobes) {
        /* narrow accesses never overwrite neighboring memory bytes. */
        for (unsigned lane = 0; lane < 4; ++lane) {
            if (strobes & (1u << lane)) memory[(address & ~3u) + lane] = value >> (lane * 8);
        }
    }

    /* record an exposed request once and independently check every stalled offer. */
    void offer(Owner &owner, bool valid, uint32_t address, uint32_t value, uint32_t tag,
               bool write, unsigned size, unsigned strobes, unsigned parcels, const char *bus) {
        /* a missing valid before acceptance violates physical ownership. */
        if (owner.owned && !owner.accepted && !valid) throw std::runtime_error("withdrawn request");
        /* first exposure fixes the entire descriptor until its acceptance. */
        if (valid && !owner.owned) {
            owner = Owner{};
            owner.owned = true;
            owner.address = address; owner.data = value; owner.tag = tag;
            owner.write = write; owner.size = size; owner.strobes = strobes; owner.parcels = parcels;
            owner.accept_delay = random_word() % 4;
            owner.response_delay = 1 + random_word() % 7;
            trace << "{\"sequence\":" << ++events << ",\"event\":\"offer\",\"cycle\":" << cycle << ",\"bus\":\"" << bus
                  << "\",\"address\":" << address << ",\"tag\":" << tag << ",\"write\":" << write
                  << ",\"size\":" << size << ",\"strobes\":" << strobes << ",\"data\":" << value << "}\n";
        }
        /* a second descriptor cannot replace an unaccepted first request. */
        if (valid && !owner.accepted && (owner.address != address || owner.data != value ||
                owner.tag != tag || owner.write != write || owner.size != size ||
                owner.strobes != strobes || owner.parcels != parcels)) throw std::runtime_error("unstable request");
    }

    /* apply peripheral effects on acceptance and preserve the result for one reply. */
    void accept(Owner &owner, const char *bus) {
        owner.accepted = true;
        owner.wait = 0;
        owner.reply = read_word(owner.address);
        owner.status = 0;
        /* unmapped responders guarantee no effect and return a definite error. */
        if (!((owner.address < 0x2000 && !owner.write) ||
                (owner.address >= 0x10000 && owner.address < 0x20000) ||
                (owner.address >= 0x20000000 && owner.address < 0x20008000) ||
                (owner.address >= 0x40000000 && owner.address < 0x40002000))) {
            owner.status = 1;
        /* deliberately destructive registers reveal duplicated transactions. */
        } else if (owner.address == 0x40000000) {
            if (owner.write) ++mmio_writes;
            else owner.reply = uint32_t(++mmio_reads);
        /* IRQ state is retained until software or SBA explicitly clears it. */
        } else if (owner.address == 0x40000004) {
            if (owner.write) irq_levels = owner.data & 0x888;
            owner.reply = irq_levels;
        /* non-destructive counters let GDB check effects independently of CPU registers. */
        } else if (owner.address == 0x40000008) {
            owner.reply = uint32_t(mmio_reads);
        /* report the write-effect count without changing the device. */
        } else if (owner.address == 0x4000000c) {
            owner.reply = uint32_t(mmio_writes);
        /* ordinary writes update only enabled RAM lanes. */
        } else if (owner.write) {
            write_word(owner.address, owner.data, owner.strobes);
        }
        /* CPU responses contain only valid load lanes; stores and errors carry no data. */
        if (std::string(bus) == "d") {
            uint32_t mask = owner.size == 0 ? 0xffu : owner.size == 1 ? 0xffffu : 0xffffffffu;
            owner.reply = owner.write || owner.status ? 0 : owner.reply & (mask << (8 * (owner.address & 3)));
        }
        /* fetch responders clear inaccessible or unrequested parcel lanes. */
        if (std::string(bus) == "i") {
            uint32_t mask = (owner.parcels & 1 ? 0xffffu : 0) | (owner.parcels & 2 ? 0xffff0000u : 0);
            owner.reply = owner.status ? 0 : owner.reply & mask;
        }
        trace << "{\"sequence\":" << ++events << ",\"event\":\"accept\",\"cycle\":" << cycle << ",\"bus\":\"" << bus
              << "\",\"address\":" << owner.address << ",\"tag\":" << owner.tag
              << ",\"status\":" << owner.status << ",\"reply\":" << owner.reply << "}\n";
    }

    /* response completion releases exactly the owner that produced its stored payload. */
    void complete(Owner &owner, const char *bus) {
        trace << "{\"sequence\":" << ++events << ",\"event\":\"response\",\"cycle\":" << cycle << ",\"bus\":\"" << bus
              << "\",\"address\":" << owner.address << ",\"tag\":" << owner.tag << "}\n";
        owner = Owner{};
    }

public:
    /* initial reset is positively isolated; later resets must drain actual owners. */
    Platform(const std::string &path, uint32_t seed) : trace(path), rng(seed ? seed : 0x6d2b79f5) {
        if (!trace) throw std::runtime_error("trace open failed");
        write_word(0, 0x10500073, 15);
        write_word(4, 0xffdff06f, 15);
        dut.clk_i = 0; dut.tck_i = 0; dut.tms_i = 1; dut.tdi_i = 0;
        dut.acquisition_active_i = 0; dut.buffer_owned_i = 0;
        dut.isolated_i = 1; dut.power_reset_i = 1;
        trace << "{\"schema\":\"DRG5-DEBUG1\",\"seed\":" << seed << "}\n";
        /* reset all clock domains without a fabricated JTAG command. */
        for (unsigned n = 0; n < 8; ++n) {
            dut.tck_i = n & 1; tick();
        }
        dut.tck_i = 0; dut.power_reset_i = 0;
        /* isolation remains asserted until the synchronized fabric reset releases. */
        for (unsigned n = 0; n < 4; ++n) tick();
        dut.isolated_i = 0;
    }

    /* advance the fabric independently from every JTAG edge and host polling interval. */
    void tick() {
        dut.clk_i = 0; dut.mip_levels_i = irq_levels; dut.eval();
        offer(instruction, dut.i_req_valid_o, dut.i_req_addr_o, 0, dut.i_req_tag_o, false, 2, 0, dut.i_req_parcels_o, "i");
        offer(data, dut.d_req_valid_o, dut.d_req_addr_o, dut.d_req_wdata_o, dut.d_req_tag_o,
              dut.d_req_write_o, dut.d_req_size_o, dut.d_req_wstrb_o, 0, "d");
        offer(system, dut.sb_req_valid_o, dut.sb_req_addr_o, dut.sb_req_wdata_o, 0,
              dut.sb_req_write_o, dut.sb_req_size_o, dut.sb_req_wstrb_o, 0, "sb");
        dut.i_req_ready_i = instruction.owned && !instruction.accepted && instruction.age >= instruction.accept_delay;
        dut.d_req_ready_i = data.owned && !data.accepted && data.age >= data.accept_delay;
        dut.sb_req_ready_i = system.owned && !system.accepted && system.age >= system.accept_delay;
        dut.i_rsp_valid_i = instruction.accepted && instruction.wait >= instruction.response_delay;
        dut.i_rsp_tag_i = instruction.tag; dut.i_rsp_data_i = instruction.reply;
        dut.i_rsp_parcels_i = instruction.parcels; dut.i_rsp_fault_i = instruction.status ? instruction.parcels : 0;
        dut.i_rsp_status_i = instruction.status;
        dut.d_rsp_valid_i = data.accepted && data.wait >= data.response_delay;
        dut.d_rsp_tag_i = data.tag; dut.d_rsp_rdata_i = data.reply; dut.d_rsp_status_i = data.status;
        dut.sb_rsp_valid_i = system.accepted && system.wait >= system.response_delay;
        dut.sb_rsp_rdata_i = system.reply; dut.sb_rsp_error_i = system.status ? 2 : 0;
        dut.eval();
        bool ia = dut.i_req_valid_o && dut.i_req_ready_i, da = dut.d_req_valid_o && dut.d_req_ready_i;
        bool sa = dut.sb_req_valid_o && dut.sb_req_ready_i;
        bool ir = dut.i_rsp_valid_i && dut.i_rsp_ready_o, dr = dut.d_rsp_valid_i && dut.d_rsp_ready_o;
        bool sr = dut.sb_rsp_valid_i && dut.sb_rsp_ready_o;
        bool reset_edge = dut.system_reset_o;
        dut.clk_i = 1; dut.eval(); ++cycle;
        /* these models have independent schedules and cannot infer a bus effect from retirement. */
        if (ia) { accept(instruction, "i"); ++i_access; }
        /* data acceptance commits one CPU bus effect. */
        if (da) { accept(data, "d"); ++d_access; }
        /* system-bus acceptance commits one debugger bus effect. */
        if (sa) { accept(system, "sb"); ++sb_access; }
        if (ir) complete(instruction, "i");
        if (dr) complete(data, "d");
        if (sr) complete(system, "sb");
        /* responders withdraw consumed replies before post-edge combinational checks settle. */
        if (ir) dut.i_rsp_valid_i = 0;
        if (dr) dut.d_rsp_valid_i = 0;
        if (sr) dut.sb_rsp_valid_i = 0;
        dut.eval();
        /* each owner ages only while physically live. */
        for (Owner *owner : {&instruction, &data, &system}) {
            /* advance latency only for a request that still has an owner. */
            if (owner->owned) { ++owner->age; if (owner->accepted) ++owner->wait; }
        }
        /* retain original terminal bits rather than reconstructing instructions from memory. */
        if (field(TRACE_VALID_LSB, 1)) {
            bool trap = field(TRACE_TRAP_LSB, 1);
            if (trap) ++traps; else ++retired;
            trace << "{\"sequence\":" << ++events << ",\"event\":\"terminal\",\"cycle\":" << cycle << ",\"trap\":" << trap
                  << ",\"pc\":" << field(TRACE_PC_LSB, 32) << ",\"packed\":\"";
            for (int word = TRACE_WORDS - 1; word >= 0; --word) trace << std::hex << std::setw(8) << std::setfill('0') << dut.trace_o[word];
            trace << std::dec << "\"}\n";
        }
        /* halted abstract writes have their own record and never masquerade as retirement. */
        if ((dut.debug_access_o[2] >> 20) & 1) {
            trace << "{\"sequence\":" << ++events << ",\"event\":\"abstract\",\"cycle\":" << cycle << ",\"packed\":\"";
            for (int word = 2; word >= 0; --word) trace << std::hex << std::setw(8) << std::setfill('0') << dut.debug_access_o[word];
            trace << std::dec << "\",\"dpc\":" << dut.debug_dpc_o << ",\"dcsr\":" << dut.debug_dcsr_o << "}\n";
        }
        /* interrupts change control flow without inventing an instruction retirement. */
        if (dut.irq_event_o[3] & 1) {
            trace << "{\"sequence\":" << ++events << ",\"event\":\"irq\",\"cycle\":" << cycle
                  << ",\"pc\":" << dut.irq_event_o[2] << ",\"cause\":" << dut.irq_event_o[1]
                  << ",\"next_pc\":" << dut.irq_event_o[0] << "}\n";
        }
        /* halted state cannot precede completion of a launched CPU data operation. */
        if (dut.halted_o && (data.owned || instruction.owned)) throw std::runtime_error("halt with live CPU request");
        /* record each halt or reset transition with architectural state. */
        if (dut.halted_o != previous_halt || reset_edge != previous_reset) {
            trace << "{\"sequence\":" << ++events << ",\"event\":\"state\",\"cycle\":" << cycle << ",\"halted\":" << unsigned(dut.halted_o)
                  << ",\"reset\":" << reset_edge << ",\"dpc\":" << dut.debug_dpc_o
                  << ",\"dcsr\":" << dut.debug_dcsr_o << ",\"mepc\":" << dut.mepc_o
                  << ",\"mcause\":" << dut.mcause_o << ",\"cycle_counter\":" << dut.mcycle_o
                  << ",\"instret_counter\":" << dut.minstret_o << "}\n";
            previous_halt = dut.halted_o; previous_reset = reset_edge;
        }
        if (dut.fatal_o) throw std::runtime_error("RTL fatal containment");
    }

    /* remote_bitbang affects only JTAG pins, never CPU state or memory. */
    char command(char value) {
        /* decode remote_bitbang pin writes without direct state access. */
        if (value >= '0' && value <= '7') {
            unsigned pins = value - '0';
            dut.tck_i = (pins >> 2) & 1; dut.tms_i = (pins >> 1) & 1; dut.tdi_i = pins & 1;
            dut.eval();
        }
        /* asynchronous bridge settling is a real sequence of fabric clocks. */
        for (unsigned n = 0; n < 4; ++n) tick();
        return value == 'R' ? (dut.tdo_o ? '1' : '0') : 0;
    }

    /* normal termination proves all effect records were flushed to the retained capture. */
    void finish() {
        if (!dut.halted_o || instruction.owned || data.owned || system.owned) throw std::runtime_error("unfinished debug session");
        trace << "{\"end\":true,\"events\":" << events << ",\"cycles\":" << cycle << ",\"retired\":" << retired
              << ",\"traps\":" << traps << ",\"i_accepts\":" << i_access
              << ",\"d_accepts\":" << d_access << ",\"sb_accepts\":" << sb_access
              << ",\"mmio_reads\":" << mmio_reads << ",\"mmio_writes\":" << mmio_writes << "}\n";
        trace.flush();
        std::cout << "DEBUG_REMOTE_COMPLETE cycles=" << cycle << " retired=" << retired << " traps=" << traps
                  << " mmio_reads=" << mmio_reads << " mmio_writes=" << mmio_writes << std::endl;
    }
};

/* accept one local OpenOCD connection and preserve failures as a nonzero exit. */
int main(int argc, char **argv) {
    /* retain any simulator or transport failure as a failing exit. */
    try {
        if (argc != 4) throw std::runtime_error("usage: simulator port trace seed");
        Verilated::commandArgs(argc, argv);
        Platform platform(argv[2], uint32_t(std::stoul(argv[3])));
        int server = socket(AF_INET, SOCK_STREAM, 0);
        if (server < 0) throw std::runtime_error("socket creation failed");
        int reuse = 1;
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
        sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        address.sin_port = htons(uint16_t(std::stoul(argv[1])));
        if (bind(server, reinterpret_cast<sockaddr *>(&address), sizeof(address)) || listen(server, 1))
            throw std::runtime_error("loopback listen failed");
        std::cout << "DEBUG_REMOTE_READY port=" << argv[1] << std::endl;
        int client = accept(server, nullptr, nullptr);
        if (client < 0) throw std::runtime_error("OpenOCD connection failed");
        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &reuse, sizeof(reuse));
        bool done = false;
        /* disconnected hosts cannot inject a hidden successful termination marker. */
        while (!done) {
            pollfd descriptor{client, POLLIN, 0};
            int available = poll(&descriptor, 1, 1);
            if (available < 0) throw std::runtime_error("poll failed");
            /* advance independent fabric clocks while no host bytes arrive. */
            if (!available) { for (unsigned n = 0; n < 32; ++n) platform.tick(); continue; }
            char buffer[4096];
            ssize_t count = read(client, buffer, sizeof(buffer));
            if (count <= 0) throw std::runtime_error("transport disconnected without quit");
            std::string replies;
            /* every sampled TDO bit is returned in the same command order. */
            for (ssize_t index = 0; index < count; ++index) {
                char command = buffer[index];
                /* only the explicit quit command ends a normal session. */
                if (command == 'Q') { done = true; break; }
                char reply = platform.command(command);
                if (reply) replies += reply;
            }
            /* batching a received command block preserves bit order without one packet per TDO bit. */
            size_t sent = 0;
            /* handle partial socket writes without losing sampled TDO bits. */
            while (sent < replies.size()) {
                ssize_t result = write(client, replies.data() + sent, replies.size() - sent);
                if (result <= 0) throw std::runtime_error("TDO response failed");
                sent += size_t(result);
            }
        }
        platform.finish(); close(client); close(server);
        return 0;
    /* report the original failure before returning a nonzero status. */
    } catch (const std::exception &error) {
        std::cerr << "DEBUG_REMOTE_FAILURE " << error.what() << std::endl;
        return 1;
    }
}
