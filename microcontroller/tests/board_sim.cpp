/* verify compiled firmware, retirement continuity and actual serial output together. */
#include "Vdrg5_board_system.h"
#include "Vdrg5_board_system___024root.h"
#include "verilated.h"
#include "arch_trace_fields.h"
#include <array>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>

/* every failure retains a precise invariant and the last emitted execution records. */
static void check(bool condition, const std::string &reason) {
    if (!condition) throw std::runtime_error(reason);
}

/* extract generated packed fields without duplicating the production trace layout. */
static uint64_t field(const Vdrg5_board_system &dut, unsigned lsb, unsigned width) {
    uint64_t value = 0;
    /* trace fields can cross any packed-word boundary. */
    for (unsigned bit = 0; bit < width; ++bit)
        value |= uint64_t((dut.trace_o[(lsb + bit) / 32] >> ((lsb + bit) % 32)) & 1) << bit;
    return value;
}

/* decode center samples on the physical UART pin rather than trusting MMIO strobes. */
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    /* malformed invocations must not accidentally run an unbounded simulation. */
    if (argc != 4 && argc != 5) { std::cerr << "usage: board_sim trace frequency seed [repeat-loopback]\n"; return 2; }
    const bool mutate_loopback = argc == 5 && std::string(argv[4]) == "repeat-loopback";
    const uint64_t frequency = std::stoull(argv[2]);
    const uint64_t divisor = (frequency + 57600) / 115200;
    Verilated::randReset(2);
    Verilated::randSeed(std::stoi(argv[3]));
    Vdrg5_board_system dut;
    std::ofstream trace(argv[1]);
    std::array<uint32_t,32> registers{};
    std::array<bool,32> defined{};
    defined[0] = true;
    uint64_t cycles = 0, retired = 0, traps = 0, irqs = 0, order = 0, last_uid = 0;
    uint64_t sample_at = 0, receiving_since = 0, verdict_at = 0, idle_clocks = 0;
    uint32_t expected_pc = 0;
    unsigned serial_bit = 0, serial_byte = 0, status_effects = 0, high_water = 0;
    bool receiving = false, previous_tx = true, verdict_retired = false;
    std::string parallel, serial;
    const std::string expected = "RDRG5 firmware pass\n";
    dut.clk_i = 0; dut.reset_i = 1; dut.event_btn_i = 0;
    /* a reset initializes control; explicit poison, not this loop, initializes test DRAM. */
    for (unsigned n = 0; n < 4; ++n) {
        dut.clk_i = 0; dut.eval(); dut.clk_i = 1; dut.eval();
    }
    dut.reset_i = 0;
    /* preserve a failure trace even when serial output or the firmware never completes. */
    try {
        /* the bound covers boot, timer waiting and draining the entire UART burst. */
        while (cycles < 1000000) {
            dut.clk_i = 0;
            /* firmware requires all pending sources clear during self-test; exercise the masked button afterward. */
            dut.event_btn_i = verdict_retired && cycles < verdict_at + 20;
            /* a stuck-low one-shot latch must fail the independent event ledger. */
            if (mutate_loopback) dut.rootp->drg5_board_system__DOT__diagnostic_sent_q = 0;
            dut.eval(); dut.clk_i = 1; dut.eval(); ++cycles;
            check(!dut.fatal_o, "CPU fatal containment");
            check(!dut.uart_overflow_o, "unexpected UART overflow");
            check(dut.status_o != 3, "compiled firmware failure");
            /* this firmware leaves reset-inhibited counters unchanged; elapsed time uses fabric edges. */
            check(dut.mcycle_o == 0, "inhibited cycle counter changed");
            idle_clocks += dut.idle_o;
            if (dut.uart_queued_o > high_water) high_water = dut.uart_queued_o;
            /* record physical output effects independently of retirement. */
            if (dut.output_valid_o) {
                parallel.push_back(char(dut.output_data_o));
                check(expected.substr(0, parallel.size()) == parallel, "output effect order or duplication");
                trace << "{\"event\":\"output\",\"cycle\":" << cycles << ",\"byte\":" << unsigned(dut.output_data_o) << "}\n";
            }
            /* acceptance alone cannot establish the final architectural verdict. */
            if (dut.status_write_o) {
                ++status_effects; check(status_effects == 1 && dut.status_o == 1, "status effect count/value");
            }
            /* ordered terminals reconstruct architectural PC and actual operand history. */
            if (field(dut, TRACE_VALID_LSB, 1)) {
                const bool trap = field(dut, TRACE_TRAP_LSB, 1);
                const uint64_t uid = field(dut, TRACE_UID_LSB, 64);
                check(field(dut, TRACE_ORDER_LSB, 64) == order && (!order || uid > last_uid), "retirement identity/order");
                check(field(dut, TRACE_PC_LSB, 32) == expected_pc, "architectural PC continuity");
                ++order; last_uid = uid; expected_pc = uint32_t(field(dut, TRACE_NEXT_PC_LSB, 32));
                /* unreset registers acquire values only from a real operand observation. */
                for (unsigned n = 0; n < 2; ++n) {
                    const unsigned index = unsigned(field(dut, n ? TRACE_RS2_LSB : TRACE_RS1_LSB, 5));
                    const uint32_t value = uint32_t(field(dut, n ? TRACE_RS2_VALUE_LSB : TRACE_RS1_VALUE_LSB, 32));
                    /* unused encoding fields never become artificial dependencies. */
                    if (field(dut, n ? TRACE_RS2_USED_LSB : TRACE_RS1_USED_LSB, 1)) {
                        /* the first read learns an ordinary register's actual power-up value. */
                        if (!defined[index]) { defined[index] = true; registers[index] = value; }
                        check(registers[index] == value, "forwarded operand history");
                    }
                }
                if (trap) ++traps; else ++retired;
                /* only successful terminal writes can update the architectural register history. */
                if (field(dut, TRACE_RD_WRITE_LSB, 1)) {
                    const unsigned rd = unsigned(field(dut, TRACE_RD_LSB, 5));
                    check(rd && !trap, "killed or x0 register update");
                    registers[rd] = uint32_t(field(dut, TRACE_VALUE_LSB, 32)); defined[rd] = true;
                }
                /* the success store must itself retire before the UART can qualify the run. */
                if (!trap && field(dut, TRACE_PACKET_OP_LSB, 4) == 2 && field(dut, TRACE_MEM_ADDR_LSB, 32) == 0x40000000) {
                    check(status_effects == 1 && !verdict_retired, "missing or repeated verdict");
                    verdict_retired = true; verdict_at = cycles;
                }
                trace << "{\"event\":\"terminal\",\"cycle\":" << cycles << ",\"packed\":\"";
                /* retain every production trace bit for independent diagnosis. */
                for (int n = TRACE_WORDS - 1; n >= 0; --n)
                    trace << std::hex << std::setw(8) << std::setfill('0') << dut.trace_o[n];
                trace << std::dec << "\"}\n";
            }
            /* interrupts occur between terminal instructions and do not increment minstret. */
            if (dut.irq_event_o[3] & 1) {
                check(dut.irq_event_o[2] == expected_pc, "interrupt boundary");
                expected_pc = dut.irq_event_o[0]; ++irqs;
                trace << "{\"event\":\"irq\",\"cycle\":" << cycles << ",\"pc\":" << dut.irq_event_o[2]
                      << ",\"cause\":" << dut.irq_event_o[1] << "}\n";
            }
            check(dut.minstret_o == 0, "inhibited retired counter changed");
            /* a falling edge begins a ten-bit serial frame, independent of CPU timing. */
            if (!receiving && previous_tx && !dut.uart_tx_o) {
                receiving = true; receiving_since = cycles; sample_at = cycles + divisor / 2;
                serial_bit = 0; serial_byte = 0;
            }
            /* center sampling tolerates no missing start or stop bit. */
            if (receiving && cycles == sample_at) {
                if (serial_bit == 0) check(!dut.uart_tx_o, "UART start bit");
                else if (serial_bit <= 8) serial_byte |= unsigned(dut.uart_tx_o) << (serial_bit - 1);
                /* stop centers terminate one byte, after all eight data bits. */
                else {
                    check(dut.uart_tx_o && cycles - receiving_since == 9 * divisor + divisor / 2, "UART stop bit/period");
                    serial.push_back(char(serial_byte)); receiving = false;
                    check(expected.substr(0, serial.size()) == serial, "serial byte order/value");
                }
                ++serial_bit; sample_at += divisor;
            }
            previous_tx = dut.uart_tx_o;
            if (verdict_retired && !dut.uart_busy_o && serial == expected) break;
        }
        check(verdict_retired && parallel == expected && serial == expected && !dut.uart_busy_o, "incomplete firmware or serial output");
        check(traps == 8 && irqs == 4 && idle_clocks >= 19000, "missing traps, interrupts or timer-clocked WFI");
        check((dut.led_o & 0x78) == 8, "board verdict LEDs");
        /* the serviced loopback stays clear; the later masked button remains pending exactly once. */
        check(dut.rootp->drg5_board_system__DOT__ext_pending == 8, "diagnostic event duplicated or masked button lost");
        trace << "{\"end\":true,\"cycles\":" << cycles << ",\"retired\":" << retired << ",\"traps\":" << traps << ",\"irqs\":" << irqs << "}\n";
        std::cout << "BOARD_SIM_PASS {\"clock_hz\":" << frequency << ",\"cycles\":" << cycles << ",\"verdict_cycle\":" << verdict_at
                  << ",\"retired\":" << retired << ",\"traps\":" << traps << ",\"irqs\":" << irqs
                  << ",\"uart_bytes\":" << serial.size() << ",\"uart_high_water\":" << high_water << ",\"divisor\":" << divisor << "}\n";
        return 0;
    /* no failure receives a successful footer or a physical hardware claim. */
    } catch (const std::exception &error) {
        std::cerr << "BOARD_SIM_FAILURE " << error.what() << " cycle=" << cycles << "\n";
        return 1;
    }
}
