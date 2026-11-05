/* model flash pins and completed memory writes independently of boot RTL. */
#include "Vdrg5_spi_boot.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

/* checker failures identify the first violated interface or validation rule. */
static void check(bool value, const std::string &reason) {
    if (!value) throw std::runtime_error(reason);
}

/* the independent reflected CRC oracle operates on complete byte arrays. */
static uint32_t crc(const uint8_t *data, size_t length) {
    uint32_t result = 0xffffffff;
    /* one host byte advances eight standard reflected polynomial steps. */
    for (size_t index = 0; index < length; ++index) {
        result ^= data[index];
        /* the unsigned mask expresses the conditional polynomial without RTL helper reuse. */
        for (unsigned bit = 0; bit < 8; ++bit) result = (result >> 1) ^ (0xedb88320u & (0u - (result & 1)));
    }
    return ~result;
}

/* fixture words are little-endian regardless of host architecture. */
static void put(std::vector<uint8_t> &bank, size_t offset, uint32_t word) {
    for (unsigned byte = 0; byte < 4; ++byte) bank.at(offset + byte) = uint8_t(word >> (8 * byte));
}

/* create one committed header and a full deterministic executable-memory payload. */
static std::vector<uint8_t> image(unsigned pattern, uint32_t generation) {
    std::vector<uint8_t> bank(0x20000, 0xff);
    /* the bank header reserves every unused field as zero. */
    for (unsigned byte = 0; byte < 256; ++byte) bank[byte] = 0;
    /* distinct patterns expose stale words and accidental bank/address aliasing. */
    for (unsigned byte = 0; byte < 65536; ++byte) bank[256 + byte] = uint8_t(byte * 17 + (byte >> 8) * 23 + pattern);
    put(bank, 0, 0x35475244); put(bank, 4, 1); put(bank, 8, 65536);
    put(bank, 12, 0x10000); put(bank, 16, 0x10000); put(bank, 20, generation);
    put(bank, 24, crc(bank.data() + 256, 65536)); put(bank, 28, 0x7309d786); put(bank, 32, 1);
    put(bank, 248, crc(bank.data(), 248)); put(bank, 0x1fffc, 0x54494d43);
    return bank;
}

/* each fixture supplies real mode-zero edges, independent write stalls and a poison IRAM. */
class Fixture {
public:
    Vdrg5_spi_boot dut;
    std::array<std::vector<uint8_t>,2> banks;
    std::array<uint8_t,65536> iram;
    uint64_t clocks = 0, checks = 0, writes = 0, transactions = 0;
    unsigned error_word = 0, timeout_word = 0;
    bool stuck_high = false;
private:
    bool selected = false, old_sck = false, owner = false;
    unsigned command_bits = 0, read_bit = 0;
    uint32_t command = 0, flash_address = 0, write_address = 0, write_data = 0;
    uint64_t offered = 0, edge_clock = 0;
    unsigned service_delay = 0;
    bool error = false;

    /* flash decoding recognizes exactly the two bank windows, never the FPGA configuration region. */
    uint8_t flash_byte(uint32_t address) {
        if (address < 0x400000 || address >= 0x440000) return 0xff;
        return banks[(address - 0x400000) / 0x20000][address & 0x1ffff];
    }

public:
    /* constructors initialize devices but never manufacture a successful boot result. */
    Fixture() : banks{image(0x31, 1), image(0x97, 2)} {
        iram.fill(0xa5);
        dut.clk_i = 0; dut.reset_i = 1; dut.force_a_i = 0; dut.flash_miso_i = 0;
        dut.write_ready_i = 0; dut.write_error_i = 0;
    }

    /* resetting the whole fixture isolates the local target before revoking an unfinished owner. */
    void reset(bool force = false) {
        dut.reset_i = 1; dut.force_a_i = force;
        owner = false; selected = false; old_sck = false;
        /* a held reset must return the flash pins to an idle, deselected state. */
        for (unsigned count = 0; count < 4; ++count) tick();
        dut.reset_i = 0;
    }

    /* all physical model actions use observed handshakes and pins, never the RTL state machine. */
    void tick() {
        dut.clk_i = 0; dut.eval();
        bool complete = false;
        /* a fresh exposed word reserves one immutable completion obligation. */
        if (!dut.reset_i && dut.write_valid_o && !owner) {
            owner = true; offered = clocks;
            write_address = dut.write_addr_o; write_data = dut.write_data_o;
            service_delay = 1 + unsigned((writes * 7) % 17);
            error = error_word && writes + 1 == error_word;
            if (timeout_word && writes + 1 == timeout_word) service_delay = 132;
            check(write_address >= 0x10000 && write_address < 0x20000 && !(write_address & 3), "unaligned or out-of-range write");
            check(!dut.done_o, "write exposed after CPU release");
        }
        /* timeout containment cannot withdraw or mutate the outstanding write. */
        if (owner && !dut.reset_i) {
            check(dut.write_valid_o && dut.write_addr_o == write_address && dut.write_data_o == write_data,
                  "boot write owner changed before completed response");
            complete = clocks - offered >= service_delay;
        }
        dut.write_ready_i = complete;
        dut.write_error_i = complete && error;
        dut.clk_i = 1; dut.eval(); ++clocks;
        /* the adapter gives one completed effect to exactly one owner. */
        if (complete) {
            ++writes;
            /* definite target errors are guaranteed to have no memory effect. */
            if (!error) {
                for (unsigned byte = 0; byte < 4; ++byte) iram[write_address - 0x10000 + byte] = uint8_t(write_data >> (8 * byte));
            }
            owner = false;
        }
        /* deselection resets only flash command decoding, not persistent storage. */
        if (dut.flash_cs_n_o) {
            selected = false; old_sck = false; dut.flash_miso_i = stuck_high;
        /* a selected flash observes instruction/address input and serial data output. */
        } else {
            /* the first selected clock starts one read transaction. */
            if (!selected) {
                selected = true; command = 0; command_bits = 0; read_bit = 0;
                edge_clock = clocks; old_sck = false; ++transactions;
            }
            /* no physical clock half-period may be shorter than the configured two CPU clocks. */
            if (dut.flash_sck_o != old_sck) {
                check(clocks - edge_clock >= 2, "SPI half-period shortened"); edge_clock = clocks;
                /* mode-zero flash latches command bits on rising edges. */
                if (dut.flash_sck_o) {
                    /* the 32-bit prefix contains the read command and exact 24-bit address. */
                    if (command_bits < 32) {
                        command = (command << 1) | dut.flash_mosi_o; ++command_bits;
                        /* every observed command must target a declared header, marker or payload. */
                        if (command_bits == 32) {
                            check((command >> 24) == 3, "flash command was not read-only 03h");
                            flash_address = command & 0xffffff;
                            check(flash_address >= 0x400000 && flash_address < 0x440000, "flash command escaped firmware banks");
                            const uint32_t offset = flash_address & 0x1ffff;
                            check(offset == 0 || offset == 0x100 || offset == 0x1fffc, "unexpected SPI read start");
                        }
                    /* the reader has consumed one returned bit at this rising edge. */
                    } else {
                        ++read_bit;
                        /* a completed data byte advances the flash's sequential address exactly once. */
                        if (read_bit == 8) { read_bit = 0; ++flash_address; }
                    }
                /* flash output changes only on the falling edge preceding its sampling edge. */
                } else if (command_bits == 32) {
                    dut.flash_miso_i = stuck_high ? 1 : ((flash_byte(flash_address) >> (7 - read_bit)) & 1);
                }
                old_sck = dut.flash_sck_o;
            }
        }
        dut.eval(); ++checks;
        check(!(dut.done_o && dut.fault_o), "CPU release and fault asserted together");
        if (owner) check(!dut.done_o, "CPU released with an outstanding memory response");
    }

    /* failures are allowed only at the requested validation boundary and never by a generic timeout. */
    void run(const std::string &name, int bank, unsigned reason, uint64_t expected_writes) {
        /* the two-bank bound includes both complete payloads and every admitted write response. */
        while ((!dut.done_o && !dut.fault_o) || owner || dut.write_valid_o) {
            check(clocks < 10000000, "boot exceeded finite fixture limit"); tick();
        }
        check(bool(dut.fault_o) == (reason != 0) && dut.reason_o == reason, "unexpected boot verdict: " + name);
        check(writes == expected_writes, "unexpected write count: " + name);
        /* a successful release exposes exactly the selected payload, including every padding byte. */
        if (!reason) {
            check(dut.done_o && dut.selected_bank_o == bank, "wrong selected bank: " + name);
            for (unsigned byte = 0; byte < 65536; ++byte) check(iram[byte] == banks[bank][256 + byte], "stale payload byte");
        }
        const uint64_t old_writes = writes, old_transactions = transactions;
        /* terminal states remain stable until an explicit isolated reset. */
        for (unsigned clock = 0; clock < 40; ++clock) tick();
        check(writes == old_writes && transactions == old_transactions && dut.flash_cs_n_o,
              "terminal boot state restarted work");
        std::cout << "BOOT_CASE_PASS " << name << " clocks=" << clocks << " writes=" << writes
                  << " transactions=" << transactions << " reason=" << reason << "\n";
    }
};

/* independent fixtures exercise precedence, fallback, corrupt fields, target errors and uncertain timeouts. */
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    unsigned cases = 0;
    /* preserve the first specific failure rather than reporting later consequential mismatches. */
    try {
        /* ordinary selection uses the newest committed bank. */
        { Fixture f; f.reset(); f.run("newer-b", 1, 0, 16384); ++cases; }
        /* equal unsigned generations choose bank A deterministically. */
        { Fixture f; f.banks[1] = image(0x97, 1); f.reset(); f.run("tie-a", 0, 0, 16384); ++cases; }
        /* forced golden recovery cannot fall through to a newer application. */
        { Fixture f; f.reset(true); f.run("forced-a", 0, 0, 16384); ++cases; }
        /* payload rejection overwrites all stale words before releasing a valid fallback. */
        { Fixture f; f.banks[1][0x1234] ^= 1; f.reset(); f.run("corrupt-b-fallback-a", 0, 0, 32768); ++cases; }
        /* both CRC failures remain halted after exactly two distinct candidate attempts. */
        { Fixture f; f.banks[0][0x2345] ^= 1; f.banks[1][0x1234] ^= 1; f.reset(); f.run("both-payloads-corrupt", -1, 3, 32768); ++cases; }
        /* an uncommitted image is never loaded into executable memory. */
        { Fixture f; f.banks[1][0x1fffc] = 0xff; f.reset(); f.run("torn-b-commit", 0, 0, 16384); ++cases; }
        /* header corruption invalidates its bank before any payload write. */
        { Fixture f; f.banks[1][248] ^= 1; f.reset(); f.run("header-crc", 0, 0, 16384); ++cases; }
        /* erased flash reaches a bounded failure without touching IRAM. */
        { Fixture f; f.banks[0].assign(0x20000, 0xff); f.banks[1].assign(0x20000, 0xff); f.reset(); f.run("erased", -1, 1, 0); ++cases; }
        /* a missing golden image does not defeat an explicitly held recovery request. */
        { Fixture f; f.banks[0].assign(0x20000, 0xff); f.reset(true); f.run("forced-a-invalid", -1, 2, 0); ++cases; }
        /* fixed fields remain enforced even when an attacker or broken tool recomputes header CRC. */
        for (unsigned offset : {0u, 4u, 8u, 12u, 16u, 28u, 32u, 36u, 244u, 252u}) {
            Fixture f; put(f.banks[1], offset, 0xdeadbeef); put(f.banks[1], 248, crc(f.banks[1].data(), 248));
            f.reset(); f.run("fixed-field-" + std::to_string(offset), 0, 0, 16384); ++cases;
        }
        /* unsigned ordering never silently wraps the maximum generation below one. */
        { Fixture f; f.banks[0] = image(0x31, 0xffffffff); f.reset(); f.run("unsigned-generation", 0, 0, 16384); ++cases; }
        /* a definite write error aborts instead of replaying into the fallback bank. */
        { Fixture f; f.error_word = 23; f.reset(); f.run("write-error", -1, 4, 23); ++cases; }
        /* a late response drains the same timed-out owner but never restores success. */
        { Fixture f; f.timeout_word = 23; f.reset(); f.run("write-timeout-late-drain", -1, 5, 23); ++cases; }
        /* a disconnected high input is rejected by metadata validation. */
        { Fixture f; f.stuck_high = true; f.reset(); f.run("miso-stuck-high", -1, 1, 0); ++cases; }
        /* whole-platform reset restarts a partially written application without retaining its old owner. */
        {
            Fixture f; f.reset();
            while (f.writes < 17) f.tick();
            f.reset(); f.writes = 0; f.run("reset-partial-load", 1, 0, 16384); ++cases;
        }
        std::cout << "SPI_BOOT_PASS cases=" << cases << "\n";
        return 0;
    /* no failed fixture prints the suite success marker. */
    } catch (const std::exception &error) {
        std::cerr << "SPI_BOOT_FAILURE " << error.what() << "\n";
        return 1;
    }
}
