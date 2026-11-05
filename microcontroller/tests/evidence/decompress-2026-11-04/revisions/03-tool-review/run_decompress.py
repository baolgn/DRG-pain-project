#!/usr/bin/env python3
"""enumerate semantic RV32C forms independently, then check all halfwords and synthesis."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


# scatter semantic immediate bits into the compressed format's documented positions.
def scatter(value, positions):
    return sum(((value >> source) & 1) << dest for source, dest in positions)


# standard instructions use arithmetic field placement rather than RTL concatenations.
def standard_i(opcode, funct3, rd, rs1, immediate):
    return ((immediate & 4095) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


# form a register operation from the semantic operands.
def standard_r(funct7, funct3, rd, rs1, rs2):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x33


# word stores use the standard split signed-immediate layout.
def standard_s(rs1, rs2, offset):
    return ((offset >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | 0x2000 | ((offset & 31) << 7) | 0x23


# the standard branch displacement is independent of the compressed field permutation.
def standard_b(funct3, rs1, offset):
    value = offset & 8191
    return ((value >> 12) << 31) | (((value >> 5) & 63) << 25) | (rs1 << 15) | (funct3 << 12) | (((value >> 1) & 15) << 8) | (((value >> 11) & 1) << 7) | 0x63


# direct jumps retain the semantic displacement rather than a decoder-extracted value.
def standard_j(rd, offset):
    value = offset & 0x1fffff
    return ((value >> 20) << 31) | (((value >> 1) & 1023) << 21) | (((value >> 11) & 1) << 20) | (((value >> 12) & 255) << 12) | (rd << 7) | 0x6f


# build the oracle by encoding every legal semantic form, not by decoding input bits.
def oracle():
    table = [(3 if code % 4 == 3 else 0, 0, "wide" if code % 4 == 3 else "illegal") for code in range(65536)]
    assigned = set()
    ci = [(0, 2), (1, 3), (2, 4), (3, 5), (4, 6), (5, 12)]
    ciw = [(2, 6), (3, 5), (4, 11), (5, 12), (6, 7), (7, 8), (8, 9), (9, 10)]
    cl = [(2, 6), (3, 10), (4, 11), (5, 12), (6, 5)]
    sp16 = [(4, 6), (5, 2), (6, 5), (7, 3), (8, 4), (9, 12)]
    cj = [(1, 3), (2, 4), (3, 5), (4, 11), (5, 2), (6, 7), (7, 6), (8, 9), (9, 10), (10, 8), (11, 12)]
    cb = [(1, 3), (2, 4), (3, 10), (4, 11), (5, 2), (6, 5), (7, 6), (8, 12)]
    lwsp = [(2, 4), (3, 5), (4, 6), (5, 12), (6, 2), (7, 3)]
    swsp = [(2, 9), (3, 10), (4, 11), (5, 12), (6, 7), (7, 8)]

    # reject overlaps so one format cannot silently overwrite another's oracle entry.
    def add(code, expanded, family, hint=False):
        assert code not in assigned and code % 4 != 3, (hex(code), family, table[code])
        assert 0 <= expanded <= 0xffffffff
        assigned.add(code)
        table[code] = (2 if hint else 1, 0x13 if hint else expanded, family)

    # enumerate nonzero stack offsets and the eight compact destinations.
    for rd in range(8, 16):
        # the specification scales the nonzero immediate by four.
        for offset in range(4, 1024, 4):
            add(scatter(offset, ciw) | ((rd - 8) << 2), standard_i(0x13, 0, rd, 2, offset), "C.ADDI4SPN")
    # compact word loads and stores share address fields but different data direction.
    for rs1 in range(8, 16):
        # all eight compact data registers are legal.
        for data in range(8, 16):
            # every word-aligned seven-bit byte offset is represented.
            for offset in range(0, 128, 4):
                encoding = scatter(offset, cl) | ((rs1 - 8) << 7) | ((data - 8) << 2)
                add(0x4000 | encoding, standard_i(3, 2, data, rs1, offset), "C.LW")
                add(0xc000 | encoding, standard_s(rs1, data, offset), "C.SW")
    # CI arithmetic and constants enumerate signed semantic values directly.
    for rd in range(32):
        # every six-bit signed value has one encoding.
        for immediate in range(-32, 32):
            encoding = scatter(immediate, ci) | (rd << 7) | 1
            add(encoding, standard_i(0x13, 0, rd, rd, immediate), "C.NOP" if rd == 0 else "C.ADDI",
                (rd == 0) != (immediate == 0))
            add(0x4000 | encoding, standard_i(0x13, 0, rd, 0, immediate), "C.LI", rd == 0)
            # rd=x2 belongs exclusively to the separate scaled stack form.
            if rd != 2 and immediate != 0:
                add(0x6000 | encoding, ((immediate & 0xfffff) << 12) | (rd << 7) | 0x37, "C.LUI", rd == 0)
    # stack adjustment reserves zero, even though other zero arithmetic can be HINTs.
    for offset in range(-512, 512, 16):
        # zero is intentionally absent from the legal oracle.
        if offset:
            add(0x6101 | scatter(offset, sp16), standard_i(0x13, 0, 2, 2, offset), "C.ADDI16SP")
    # direct jump ranges include both signed endpoints and zero displacement.
    for offset in range(-2048, 2048, 2):
        add(0x2001 | scatter(offset, cj), standard_j(1, offset), "C.JAL")
        add(0xa001 | scatter(offset, cj), standard_j(0, offset), "C.J")
    # compact branch and arithmetic operations use x8 through x15.
    for rd in range(8, 16):
        # branch semantic offsets are signed multiples of two.
        for offset in range(-256, 256, 2):
            encoding = ((rd - 8) << 7) | scatter(offset, cb)
            add(0xc001 | encoding, standard_b(0, rd, offset), "C.BEQZ")
            add(0xe001 | encoding, standard_b(1, rd, offset), "C.BNEZ")
        # RV32 shift amounts never include the custom sixth bit.
        for amount in range(32):
            encoding = ((rd - 8) << 7) | (amount << 2)
            add(0x8001 | encoding, standard_i(0x13, 5, rd, rd, amount), "C.SRLI", amount == 0)
            add(0x8401 | encoding, standard_i(0x13, 5, rd, rd, 1024 + amount), "C.SRAI", amount == 0)
        # ANDI alone treats the shared high bit as an immediate sign.
        for immediate in range(-32, 32):
            add(0x8801 | ((rd - 8) << 7) | scatter(immediate, ci), standard_i(0x13, 7, rd, rd, immediate), "C.ANDI")
        # every compact register pair is supported by the four integer ALU forms.
        for rs2 in range(8, 16):
            # operation identities are enumerated from the semantic standard instruction.
            for field, funct7, funct3, family in [(0, 32, 0, "C.SUB"), (1, 0, 4, "C.XOR"), (2, 0, 6, "C.OR"), (3, 0, 7, "C.AND")]:
                add(0x8c01 | ((rd - 8) << 7) | (field << 5) | ((rs2 - 8) << 2), standard_r(funct7, funct3, rd, rd, rs2), family)
    # full-register shifts and stack memory use their independent format maps.
    for rd in range(32):
        # rd=x0 and zero amounts are legal ignored custom-use HINTs.
        for amount in range(32):
            add(2 | (rd << 7) | (amount << 2), standard_i(0x13, 1, rd, rd, amount), "C.SLLI", rd == 0 or amount == 0)
        # stack loads exclude x0, whereas stores retain x0 as meaningful zero data.
        for offset in range(0, 256, 4):
            # x0 load encodings stay reserved and produce no memory effects.
            if rd:
                add(0x4002 | (rd << 7) | scatter(offset, lwsp), standard_i(3, 2, rd, 2, offset), "C.LWSP")
            add(0xc002 | (rd << 2) | scatter(offset, swsp), standard_s(2, rd, offset), "C.SWSP")
        # the zero source encodings belong to jumps, not MV or ADD.
        for rs2 in range(1, 32):
            add(0x8002 | (rd << 7) | (rs2 << 2), standard_r(0, 0, rd, 0, rs2), "C.MV", rd == 0)
            add(0x9002 | (rd << 7) | (rs2 << 2), standard_r(0, 0, rd, rd, rs2), "C.ADD", rd == 0)
        # JR x0 is reserved and JALR x0 is the dedicated breakpoint.
        if rd:
            add(0x8002 | (rd << 7), standard_i(0x67, 0, 0, rd, 0), "C.JR")
            add(0x9002 | (rd << 7), standard_i(0x67, 0, 1, rd, 0), "C.JALR")
    add(0x9002, 0x00100073, "C.EBREAK")
    counts = Counter(row[0] for row in table)
    assert counts == {0: 20329, 1: 28461, 2: 362, 3: 16384}, counts
    return table


# record commands before execution and preserve full diagnostics for every attempt.
def execute(command, log, root):
    result = subprocess.run(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
    log.write_text("$ " + " ".join(command) + "\n" + result.stdout)
    return result


# qualify the exhaustive combinational module with strict diagnostics and targeted mutations.
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verilator", default="verilator")
    parser.add_argument("--yosys", default="yosys")
    parser.add_argument("--build", type=Path, default=Path("/tmp/drg5-decompress-tests"))
    parser.add_argument("--evidence-dir", type=Path, default=Path("microcontroller/tests/evidence/decompress-2026-11-04"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    evidence = (root / args.evidence_dir).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    sources = ["microcontroller/rtl/drg5_decompress.sv", "microcontroller/tests/drg5_decompress_tb.sv"]
    names = sources + [str(Path(__file__).relative_to(root))]
    before = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}
    table = oracle()
    oracle_path = build / "oracle.hex"
    oracle_path.write_text("".join(f"{(kind << 32) | expanded:09x}\n" for kind, expanded, _ in table))
    command = [args.verilator, "--binary", "--timing", "--assert", "-Wall", "-j", "2", "--top-module", "drg5_decompress_tb", "--Mdir", str(build / "obj"), *sources]
    result = execute(command, build / "build.log", root)
    assert result.returncode == 0 and "%Warning" not in result.stdout, "strict simulation build failed"
    runs = {}
    # each injected observation error must fail exactly its intended comparator.
    for name, flag, detector in [("positive", None, "DECOMPRESS_PASS"), ("class", "mutate_class", "classification"), ("expansion", "mutate_expansion", "expansion"), ("hint", "mutate_hint", "HINT flag")]:
        command = [str(build / "obj/Vdrg5_decompress_tb"), "+verilator+seed+1", "+oracle=" + str(oracle_path)]
        # the ordinary pass observes untouched device outputs.
        if flag:
            command.append("+" + flag)
        result = execute(command, build / (name + ".log"), root)
        assert (result.returncode != 0 and "DECOMPRESS_CHECK_FAILED " + detector in result.stdout) if flag else (result.returncode == 0 and detector in result.stdout), name
        runs[name] = {"exit": result.returncode, "expected": detector, "pass": True}
    netlist = build / "decompress.json"
    script = "read_slang --top drg5_decompress microcontroller/rtl/drg5_decompress.sv; hierarchy -check -top drg5_decompress; proc; opt; check -assert; select -assert-none t:$dlatch t:$adlatch; synth_ecp5 -top drg5_decompress; check -assert; stat; write_json " + str(netlist)
    result = execute([args.yosys, "-Q", "-T", "-m", "slang", "-p", script], build / "mapping.log", root)
    assert result.returncode == 0 and "Warning:" not in result.stdout, "strict synthesis failed"
    cells = Counter(cell["type"] for cell in json.loads(netlist.read_text())["modules"]["drg5_decompress"]["cells"].values())
    assert before == {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}, "source changed during qualification"
    summary = {"scope": "all RV32C2.0 integer halfwords; F/D/Zc/custom instructions absent; HINTs ignored", "spec": "https://docs.riscv.org/reference/isa/v20260120/unpriv/c-st-ext.html", "sources": before, "classes": dict(sorted(Counter(row[0] for row in table).items())), "families": dict(sorted(Counter(row[2] for row in table).items())), "oracle_sha256": hashlib.sha256(oracle_path.read_bytes()).hexdigest(), "runs": runs, "cells": dict(sorted(cells.items())), "verilator": subprocess.check_output([args.verilator, "--version"], text=True).strip(), "yosys": subprocess.check_output([args.yosys, "-V"], text=True).strip(), "limits": ["component simulation and synthesis only; no routing or ACT4/Sail claim"]}
    (build / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    # retain exact source, logs and oracle beside the source-bound summary.
    for name in names:
        target = evidence / "sources" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, target)
    # generated simulator objects are excluded from the retained engineering evidence.
    for path in build.iterdir():
        # logs, the deterministic oracle and the summary are sufficient for reproduction.
        if path.is_file() and path.suffix in {".log", ".hex", ".json"} and path.name != "decompress.json":
            shutil.copy2(path, evidence / path.name)
    print(json.dumps(summary["classes"]), flush=True)
    print("PASS exhaustive decompression, calibrated detectors and ECP5 mapping", flush=True)


# importing exposes the oracle without running tools or changing evidence.
if __name__ == "__main__":
    main()
