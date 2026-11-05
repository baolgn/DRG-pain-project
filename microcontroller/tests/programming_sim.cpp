/* boot real compiled firmware through SPI pins and recover without a CPU debug transport. */
#include "Vdrg5_programmable_system.h"
#include "Vdrg5_programmable_system___024root.h"
#include "arch_trace_fields.h"
#include "verilated.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

/* failed checks identify the violated boot or execution invariant. */
static void check(bool value, const std::string &why) {
    if (!value) throw std::runtime_error(why);
}

/* the independent flash model responds only to physical command and clock edges. */
class Flash {
public:
    std::vector<uint8_t> bytes = std::vector<uint8_t>(0x1000000, 0xff);
    bool previous_cs = true, previous_sck = false, data_phase = false;
    unsigned command_bits = 0, data_bits = 0;
    uint32_t command = 0, address = 0;
    uint64_t reads = 0;

    /* replacing a bank models an external programmer while the whole FPGA is held reset. */
    void load(const std::string &name, uint32_t base) {
        std::ifstream stream(name, std::ios::binary);
        check(bool(stream), "missing flash bank");
        stream.read(reinterpret_cast<char *>(bytes.data() + base), 0x20000);
        check(stream.gcount() == 0x20000 && stream.peek() == EOF, "flash bank size");
    }

    /* edge order models stable mode-zero data from the preceding falling SCK. */
    void settle(Vdrg5_programmable_system &dut) {
        const bool cs = dut.flash_cs_n_o, sck = dut.flash_sck_o;
        /* each falling chip-select edge begins a new command, never a memory side effect. */
        if (previous_cs && !cs) {
            command_bits = 0; data_bits = 0; command = 0; data_phase = false;
        }
        /* only selected rising edges transfer command or read bits. */
        if (!cs && !previous_sck && sck) {
            /* exactly one command byte and three address bytes precede the payload. */
            if (!data_phase) {
                command = (command << 1) | unsigned(dut.flash_mosi_o);
                /* writes and unexpected reads fail independently of the boot result. */
                if (++command_bits == 32) {
                    check((command >> 24) == 3, "unexpected flash command");
                    address = command & 0xffffff;
                    check(address == 0x400000 || address == 0x420000 || address == 0x41fffc ||
                          address == 0x43fffc || address == 0x400100 || address == 0x420100, "flash address outside boot contract");
                    data_phase = true; ++reads;
                }
            } else ++data_bits;
        }
        /* the flash changes its output after falling SCK, including the command's last fall. */
        if (!cs && previous_sck && !sck && data_phase) {
            check(address + data_bits / 8 < bytes.size(), "flash read overflow");
            dut.flash_miso_i = (bytes[address + data_bits / 8] >> (7 - data_bits % 8)) & 1;
        }
        if (cs) dut.flash_miso_i = 1;
        previous_cs = cs; previous_sck = sck;
    }
};

/* packed fields come from the production declaration rather than hand-coded offsets. */
static uint64_t field(const Vdrg5_programmable_system &dut, unsigned lsb, unsigned width) {
    uint64_t value = 0;
    /* fields may cross the simulator's packed-word boundaries. */
    for (unsigned bit = 0; bit < width; ++bit)
        value |= uint64_t((dut.trace_o[(lsb + bit) / 32] >> ((lsb + bit) % 32)) & 1) << bit;
    return value;
}

/* settle the external pins after each real CPU-clock edge. */
static void tick(Vdrg5_programmable_system &dut, Flash &flash) {
    dut.clk_i = 0; dut.eval(); flash.settle(dut); dut.eval();
    dut.clk_i = 1; dut.eval(); flash.settle(dut); dut.eval();
}

/* reset and replay one epoch while preserving persistent flash and ordinary RAM contents. */
static void epoch(Vdrg5_programmable_system &dut, Flash &flash, std::ofstream &trace,
                  unsigned number, bool force_a, const std::string &expect, unsigned expected_bank) {
    dut.reset_i = 1; dut.force_a_i = force_a; dut.flash_miso_i = 1;
    /* reset abandons only read-only SPI work and isolated local-memory owners. */
    for (unsigned n = 0; n < 5; ++n) tick(dut, flash);
    dut.reset_i = 0;
    std::array<uint32_t,32> registers{};
    std::array<bool,32> defined{};
    defined[0] = true;
    uint64_t cycle = 0, released_at = 0, retired = 0, traps = 0, irqs = 0, order = 0, uid = 0;
    uint64_t sample_at = 0, verdict_at = 0, boot_words = 0;
    uint32_t expected_pc = 0, next_boot_address = 0x10000;
    unsigned serial_bit = 0, serial_byte = 0, status_effects = 0;
    bool previous_tx = true, receiving = false, verdict = false;
    std::string console, serial;
    const std::string expected = "RDRG5 firmware pass\n";
    const unsigned divisor = (25000000 + 57600) / 115200;
    trace << "{\"epoch\":" << number << ",\"force_a\":" << force_a << ",\"expected\":\"" << expect << "\"}\n";
    /* the bound includes two maximum-latency payload attempts plus the finite firmware test. */
    while (++cycle <= 10000000) {
        auto *root = dut.rootp;
        /* boot write completion is observed before the edge changes the producer's descriptor. */
        if (root->drg5_programmable_system__DOT__boot_write_valid && root->drg5_programmable_system__DOT__boot_write_ready) {
            const uint32_t address = root->drg5_programmable_system__DOT__boot_write_addr;
            const uint32_t data = root->drg5_programmable_system__DOT__boot_write_data;
            /* a fallback starts a fresh complete overwrite, never a partially reused image. */
            if (address == 0x10000) {
                check(next_boot_address == 0x10000 || next_boot_address == 0x20000, "duplicate first boot word");
                next_boot_address = 0x10000;
            }
            check(address == next_boot_address && dut.cpu_reset_o, "boot write ownership/order");
            const uint32_t offset = (dut.boot_bank_o ? 0x420100 : 0x400100) + address - 0x10000;
            const uint32_t word = uint32_t(flash.bytes[offset]) | (uint32_t(flash.bytes[offset+1]) << 8) |
                (uint32_t(flash.bytes[offset+2]) << 16) | (uint32_t(flash.bytes[offset+3]) << 24);
            check(data == word, "SPI-to-IRAM word value");
            next_boot_address += 4; ++boot_words;
        }
        tick(dut, flash);
        /* an invalid image can neither retire nor issue an externally visible output. */
        if (dut.cpu_reset_o) {
            check(!field(dut, TRACE_VALID_LSB, 1) && !dut.output_valid_o && dut.status_o == 0, "execution before validated boot");
            check(!dut.uart_overflow_o && !dut.fatal_o, "unexpected containment during boot");
            /* no valid bank is a defined reset-held result, not a dead CPU mistaken for success. */
            if (dut.boot_fault_o) {
                check(expect == "fault" && cycle < 9000000 && !dut.boot_done_o, "unexpected boot failure");
                trace << "{\"boot_fault\":" << unsigned(dut.boot_reason_o) << ",\"cycle\":" << cycle << "}\n";
                std::cout << "PROGRAMMING_EPOCH_PASS {\"epoch\":" << number << ",\"outcome\":\"reset-held\",\"boot_cycles\":" << cycle << "}\n";
                return;
            }
            continue;
        }
        /* only a complete final word set and successful payload CRC may release reset. */
        if (!released_at) {
            released_at = cycle;
            check(cycle < 9000000 && dut.boot_done_o && !dut.boot_fault_o && dut.boot_bank_o == expected_bank,
                  "boot release or bank selection");
            check(boot_words >= 16384 && next_boot_address == 0x20000, "incomplete executable image");
        }
        check(!dut.fatal_o && !dut.uart_overflow_o && dut.status_o != 3, "application failure");
        /* output effects and actual serialized bytes have independent expected histories. */
        if (dut.output_valid_o) {
            console.push_back(char(dut.output_data_o));
            check(expected.substr(0, console.size()) == console, "output effect sequence");
        }
        /* count status effects independently of their later architectural retirement. */
        if (dut.status_write_o) { ++status_effects; check(status_effects == 1 && dut.status_o == 1, "status effect"); }
        /* retirement reconstruction catches stale, duplicate and incorrectly forwarded execution. */
        if (field(dut, TRACE_VALID_LSB, 1)) {
            const bool trap = field(dut, TRACE_TRAP_LSB, 1);
            const uint64_t next_uid = field(dut, TRACE_UID_LSB, 64);
            check(field(dut, TRACE_ORDER_LSB, 64) == order && (!order || next_uid > uid), "terminal identity/order");
            check(field(dut, TRACE_PC_LSB, 32) == expected_pc, "architectural PC continuity");
            ++order; uid = next_uid; expected_pc = uint32_t(field(dut, TRACE_NEXT_PC_LSB, 32));
            /* use masks distinguish real dependencies from unused encoding fields. */
            for (unsigned n = 0; n < 2; ++n) {
                /* unknown power-up values are learned only from real operands. */
                if (field(dut, n ? TRACE_RS2_USED_LSB : TRACE_RS1_USED_LSB, 1)) {
                    const unsigned reg = unsigned(field(dut, n ? TRACE_RS2_LSB : TRACE_RS1_LSB, 5));
                    const uint32_t value = uint32_t(field(dut, n ? TRACE_RS2_VALUE_LSB : TRACE_RS1_VALUE_LSB, 32));
                    /* observation must never manufacture a reset value. */
                    if (!defined[reg]) { defined[reg] = true; registers[reg] = value; }
                    check(registers[reg] == value, "operand history");
                }
            }
            if (trap) ++traps; else ++retired;
            /* only successful retirement may write a nonzero architectural destination. */
            if (field(dut, TRACE_RD_WRITE_LSB, 1)) {
                const unsigned reg = unsigned(field(dut, TRACE_RD_LSB, 5));
                check(!trap && reg, "invalid architectural update");
                registers[reg] = uint32_t(field(dut, TRACE_VALUE_LSB, 32)); defined[reg] = true;
            }
            /* the final accepted output store is not complete until it retires. */
            if (!trap && field(dut, TRACE_PACKET_OP_LSB, 4) == 2 && field(dut, TRACE_MEM_ADDR_LSB, 32) == 0x40000000) {
                check(!verdict && status_effects == 1, "duplicate/missing verdict"); verdict = true; verdict_at = cycle;
            }
            trace << "{\"cycle\":" << cycle << ",\"packed\":\"";
            /* full terminal records permit later architectural replay. */
            for (int n = TRACE_WORDS - 1; n >= 0; --n) trace << std::hex << std::setw(8) << std::setfill('0') << dut.trace_o[n];
            trace << std::dec << "\"}\n";
        }
        /* IRQ boundaries redirect the next architectural PC without ordinary retirement. */
        if (dut.irq_event_o[3] & 1) {
            check(dut.irq_event_o[2] == expected_pc, "IRQ boundary"); expected_pc = dut.irq_event_o[0]; ++irqs;
            trace << "{\"irq_cycle\":" << cycle << ",\"cause\":" << dut.irq_event_o[1] << "}\n";
        }
        /* a CRC-valid semantic failure demonstrates why manual golden recovery is required. */
        if (expect == "hang" && cycle - released_at >= 50000) {
            check(console.empty() && serial.empty() && !verdict && expected_pc == 0x10000 && retired > 1000,
                  "damaged application did not hang as expected");
            std::cout << "PROGRAMMING_EPOCH_PASS {\"epoch\":" << number << ",\"outcome\":\"damaged-app-hang\",\"boot_cycles\":" << released_at << "}\n";
            return;
        }
        /* UART center samples validate the physical pin independently of output stores. */
        if (!receiving && previous_tx && !dut.uart_tx_o) {
            receiving = true; sample_at = cycle + divisor / 2; serial_bit = 0; serial_byte = 0;
        }
        /* every frame requires a low start, eight data bits and a high stop bit. */
        if (receiving && cycle == sample_at) {
            if (!serial_bit) check(!dut.uart_tx_o, "UART start");
            else if (serial_bit <= 8) serial_byte |= unsigned(dut.uart_tx_o) << (serial_bit - 1);
            /* a complete frame contributes exactly one expected byte. */
            else {
                check(dut.uart_tx_o, "UART stop"); serial.push_back(char(serial_byte)); receiving = false;
                check(expected.substr(0, serial.size()) == serial, "UART byte sequence");
            }
            ++serial_bit; sample_at += divisor;
        }
        previous_tx = dut.uart_tx_o;
        /* valid application completion includes serial drainage and all directed trap exercises. */
        if (verdict && !dut.uart_busy_o && serial == expected) {
            check(expect == "good" && console == expected && traps == 8 && irqs == 4, "incomplete application coverage");
            trace << "{\"end_epoch\":" << number << ",\"cycles\":" << cycle << "}\n";
            std::cout << "PROGRAMMING_EPOCH_PASS {\"epoch\":" << number << ",\"outcome\":\"firmware-pass\",\"bank\":" << unsigned(dut.boot_bank_o)
                      << ",\"boot_cycles\":" << released_at << ",\"application_verdict_cycles\":" << verdict_at - released_at
                      << ",\"cycles\":" << cycle << ",\"boot_words\":" << boot_words << ",\"retired\":" << retired << ",\"traps\":" << traps << ",\"irqs\":" << irqs << "}\n";
            return;
        }
    }
    throw std::runtime_error("boot/application progress deadline");
}

/* recoverable scenarios keep the same flash model while resetting the whole local platform. */
int main(int argc, char **argv) {
    /* each invocation names both physical banks and its expected recovery scenario. */
    if (argc < 8) { std::cerr << "usage: sim A B trace seed mode bank replacement\n"; return 2; }
    Verilated::commandArgs(argc, argv); Verilated::randReset(2); Verilated::randSeed(std::stoi(argv[4]));
    Vdrg5_programmable_system dut; Flash flash; std::ofstream trace(argv[3]);
    /* failed runs retain their incomplete trace and never print the final pass marker. */
    try {
        flash.load(argv[1], 0x400000); flash.load(argv[2], 0x420000);
        const auto golden = std::vector<uint8_t>(flash.bytes.begin() + 0x400000, flash.bytes.begin() + 0x420000);
        const std::string mode = argv[5]; const unsigned bank = unsigned(std::stoul(argv[6]));
        /* a hanging but CRC-valid B cannot prevent the independent recovery switch from selecting A. */
        if (mode == "recover-hang") {
            epoch(dut, flash, trace, 0, false, "hang", 1);
            epoch(dut, flash, trace, 1, true, "good", 0);
            dut.reset_i = 1; tick(dut, flash); flash.load(argv[7], 0x420000);
            epoch(dut, flash, trace, 2, false, "good", 1);
        }
        /* an external configuration-port writer can repair both-invalid persistent storage. */
        else if (mode == "repair-empty") {
            epoch(dut, flash, trace, 0, false, "fault", 0);
            dut.reset_i = 1; tick(dut, flash); flash.load(argv[7], 0x400000);
            epoch(dut, flash, trace, 1, false, "good", 0);
        } else epoch(dut, flash, trace, 0, mode == "force-a", mode == "fault" ? "fault" : "good", bank);
        /* only the explicit both-invalid golden-restore fixture may replace bank A. */
        if (mode != "repair-empty")
            check(std::equal(golden.begin(), golden.end(), flash.bytes.begin() + 0x400000), "golden bank changed");
        std::cout << "PROGRAMMING_SIM_PASS\n"; return 0;
    /* the exact failure remains visible even when the CPU itself cannot report an error. */
    } catch (const std::exception &error) {
        std::cerr << "PROGRAMMING_SIM_FAILURE " << error.what() << "\n"; return 1;
    }
}
