#!/usr/bin/env python3
"""shard ACT4 testcases for the real memory capacities without deleting cases."""
import argparse
import os
from pathlib import Path
import re
import shutil

from testgen import constants

# only packaging and guarded trap-buffer capacity differ from upstream defaults.
constants.TESTCASES_PER_FILE = 128
constants.TESTCASES_PER_PRIV_FILE = 64
constants.PRIV_TRAP_SIGUPD_COUNT = 256

from testgen.cli import generate_all_tests
from testgen.io import writer

SUITES = 'I,M,Zca,Zicsr,Zifencei,Zmmul,Sm,InterruptsSm,Exceptions'


# a new shard must initialize the source of pending allocator moves, before they execute.
def reinitialize_pointers(chunk):
    """repair upstream's post-allocation pointer snapshot at a file boundary."""
    signature, data = chunk.start_sig_reg, chunk.start_data_reg
    moves = []
    # inspect only allocator setup before the first testcase; testcase code is untouched.
    for line in '\n'.join(chunk.code).splitlines():
        # later testcase shuffles rely on execution state and must remain unchanged.
        if line.lstrip().startswith('# Testcase'):
            break
        found = re.match(r'\s*mv x(\d+), x(\d+) # switch (signature|data) pointer register', line)
        # recorded moves identify which incoming register held the pointer.
        if found:
            moves.append((int(found[1]), int(found[2]), found[3]))
    # reverse the moves to recover the pre-allocation register identities.
    for destination, source, kind in reversed(moves):
        # signature restoration precedes any pending signature-pointer move.
        if kind == 'signature' and destination == signature:
            signature = source
        # data restoration follows the same incoming-register rule.
        elif kind == 'data' and destination == data:
            data = source
    lines = []
    # explicit independent loads avoid cross-register initialization dependencies.
    if signature != 2:
        lines += [f'  LA(x{signature}, signature_base) # restore signature pointer base',
                  f'  addi x{signature}, x{signature}, SIG_STRIDE # advance past canary']
    # RVTEST_BEGIN already initializes the default data register.
    if data != 3:
        lines.append(f'  LA(x{data}, rvtest_data_begin) # restore data pointer')
    return '\n'.join(lines)


# the pinned generator remains unmodified; this adapter changes boundary setup only.
writer._reinit_pointer_registers = reinitialize_pointers


# preserve handwritten tests and replace only generated suites through upstream APIs.
def main():
    """run the pinned generator with an explicit finite-memory adaptation."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--act4', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    args.act4 = args.act4.resolve()
    args.output = args.output.resolve()
    # output must be separate so the baseline source tree and its failures survive.
    if args.output == args.act4 / 'tests':
        raise SystemExit('use a separate generated test directory')
    shutil.copytree(args.act4 / 'tests/env', args.output / 'env', dirs_exist_ok=True)
    # keep handwritten inputs only in suites whose architectural requirements can apply.
    for directory in [*(f'rv32i/{name}' for name in SUITES.split(',')[:6]),
                      'priv/Sm', 'priv/InterruptsSm', 'priv/Exceptions']:
        source = args.act4 / 'tests' / directory
        # fresh archives omit generated privileged files; testgen creates them below.
        if source.exists():
            shutil.copytree(source, args.output / directory, dirs_exist_ok=True)
    os.chdir(args.act4)
    generate_all_tests(Path('testplans'), args.output, extensions=SUITES,
                       exclude='', jobs=args.jobs)
    # these two indivisible chunks fit DRAM with a smaller guarded trap buffer.
    for name, entries in [('priv/Exceptions/Exceptions_Sm-00.S', 112),
                          ('priv/Sm/Sm_mcsr_cntr-00.S', 128)]:
        path = args.output / name
        original = path.read_text()
        marker = '#define TRAP_SIGUPD_COUNT 256'
        # a changed upstream definition requires review rather than a silent replacement.
        if original.count(marker) != 1:
            raise ValueError(f'unexpected trap-buffer definition: {name}')
        path.write_text(original.replace(marker, f'#define TRAP_SIGUPD_COUNT {entries}'))
    # RV32E and RV64 are unsupported profiles; keep only the generated RV32I candidates.
    for architecture in ['rv32e', 'rv64e', 'rv64i']:
        shutil.rmtree(args.output / architecture, ignore_errors=True)


# spawned generator workers inherit the same explicit capacity settings.
if __name__ == '__main__':
    main()
