#!/usr/bin/env python3
"""qualify the real JTAG RTL with pinned OpenOCD and GDB over local remote_bitbang."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import socket
import struct
import subprocess
import time
from replay_counter_trace import make_schema
from replay_debug_trace import replay


# complete captures must fail their normal checker when architectural evidence is corrupted.
def calibrate_replay(capture, schema, attempt):
    """preserve five independent corruptions and require their intended detector."""
    original = [json.loads(line) for line in capture.read_text().splitlines()]
    results = []
    # each mutation starts from the same complete passing record.
    for name, expected in [('lost_event', 'event sequence'), ('duplicate_effect', 'duplicate bus effect'),
                           ('wrong_register', 'abstract GPR value'), ('wrong_halt', 'halt continuation'),
                           ('missing_footer', 'missing footer')]:
        rows = json.loads(json.dumps(original))
        # remove an interior event without repairing its sequence.
        if name == 'lost_event':
            del rows[2]
        # duplicate a physical acceptance while preserving event numbering.
        elif name == 'duplicate_effect':
            index = next(i for i, row in enumerate(rows) if row.get('event') == 'accept')
            rows.insert(index + 1, rows[index].copy())
            # maintain sequence identity so the bus checker must detect the duplicated effect.
            for sequence, row in enumerate(rows[1:-1], 1):
                row['sequence'] = sequence
            rows[-1]['events'] += 1
        # corrupt a known x5 read after its architectural value is seven.
        elif name == 'wrong_register':
            index = next(i for i, row in enumerate(rows) if row.get('event') == 'abstract' and
                         ((int(row['packed'], 16) >> 64) & 0xffff) == 0x1005 and
                         (int(row['packed'], 16) & 0xffffffff) == 7 and
                         ((int(row['packed'], 16) >> 80) & 15) == 0)
            rows[index]['packed'] = f"{int(rows[index]['packed'], 16) ^ 1:024x}"
        # change the stop PC while preserving all prior terminal records.
        elif name == 'wrong_halt':
            index = next(i for i, row in enumerate(rows) if row.get('event') == 'state' and row['halted'])
            rows[index]['dpc'] ^= 4
        # remove the completion footer to expose capture truncation.
        else:
            rows.pop()
        path = attempt / (name + '.jsonl.gz')
        path.write_bytes(gzip.compress((''.join(json.dumps(row) + '\n' for row in rows)).encode(), mtime=0))
        # a different exception is a broken calibration, not successful detection.
        try:
            replay(path, schema)
        # only the intended named failure proves this mutation was detected.
        except ValueError as error:
            # unexpected replay failures invalidate the calibration.
            if str(error) != 'DEBUG_REPLAY_FAILED ' + expected:
                raise
            results.append({'mutation': name, 'detector': expected})
        # accepting corrupted evidence is a checker failure.
        else:
            raise RuntimeError('replay accepted mutation ' + name)
    return results


# local endpoints are selected before launching the mutually connected tools.
def free_port():
    """return a currently unused loopback port."""
    # release the temporary listener before starting the real server.
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


# Tcl reports command failures separately from the transport connection itself.
def command(sock, text):
    """execute one OpenOCD command and require Tcl success."""
    sock.sendall(('set code [catch {' + text + '} result]; list $code $result\x1a').encode())
    result = b''
    # OpenOCD terminates one Tcl response with the protocol delimiter.
    while not result.endswith(b'\x1a'):
        part = sock.recv(65536)
        # a disconnected control socket cannot return a successful command.
        if not part:
            raise RuntimeError('OpenOCD Tcl disconnected')
        result += part
    reply = result[:-1].decode()
    # reject Tcl errors even when the socket itself remains healthy.
    if not reply.startswith('0 '):
        raise RuntimeError(f'OpenOCD command failed: {text}: {reply}')
    return reply


# every attempt keeps its input sources, host scripts and exact diagnostic logs.
def main():
    """build the actual RTL transport and exercise it through the selected host tools."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--verilator', default='/tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator')
    parser.add_argument('--openocd', default='/tmp/drg5-control-tools-20260301/oss-cad-suite/bin/openocd')
    parser.add_argument('--gdb', default='/tmp/drg5-debug-gdb/usr/bin/gdb-multiarch')
    parser.add_argument('--build', type=Path, default=Path('/tmp/drg5-debug-remote'))
    parser.add_argument('--evidence-dir', type=Path)
    parser.add_argument('--seed', type=int, default=1)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    build = args.build.resolve(); build.mkdir(parents=True, exist_ok=True)
    evidence = (args.evidence_dir or root / 'microcontroller/tests/evidence/debug-remote-2026-11-04').resolve()
    revisions = evidence / 'revisions'; revisions.mkdir(parents=True, exist_ok=True)
    revision = max([int(p.name.split('-')[0]) for p in revisions.iterdir() if p.is_dir()] + [0]) + 1
    attempt = revisions / f'{revision:02d}-qualification'; attempt.mkdir()
    rtl = [root / 'microcontroller/rtl/drg5_control_pkg.sv'] + [
        path for path in sorted((root / 'microcontroller/rtl').glob('*.sv')) if path.name != 'drg5_control_pkg.sv']
    sources = rtl + [root / 'microcontroller/rtl/drg5_datapath_defs.svh',
                     Path(__file__).resolve(), root / 'microcontroller/tests/drg5_debug_remote.cpp',
                     root / 'microcontroller/tests/replay_counter_trace.py', root / 'microcontroller/tests/replay_debug_trace.py']
    before = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
    # failed elaborations remain reproducible from their original inputs.
    for path in sources:
        destination = attempt / 'sources' / path.relative_to(root)
        destination.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(path, destination)
    (attempt / 'source-sha256.json').write_text(json.dumps(before, indent=2) + '\n')
    schema = make_schema(root / 'microcontroller/rtl/drg5_control_pkg.sv')
    fields = {key.removeprefix('terminal.'): value.copy() for key, value in schema['fields'].items() if key.startswith('terminal.')}
    base = min(value['lsb'] for value in fields.values())
    # terminal serialization is independent of observer placement in its enclosing structure.
    for value in fields.values():
        value['lsb'] -= base
    bits = max(value['lsb'] + value['width'] for value in fields.values())
    header = '/* packed offsets are generated from the retained terminal schema. */\n'
    # C++ only needs event framing; the complete packed terminal remains in the capture.
    for macro, name in [('VALID', 'valid'), ('TRAP', 'trap'), ('PC', 'packet.pc')]:
        header += f'#define TRACE_{macro}_LSB {fields[name]["lsb"]}\n'
    header += f'#define TRACE_WORDS {(bits + 31) // 32}\n'
    (build / 'debug_trace_fields.h').write_text(header)
    (attempt / 'terminal-schema.json').write_text(json.dumps({'packed_bits': bits, 'fields': fields}, indent=2) + '\n')
    compile_command = [args.verilator, '--cc', '--exe', '--build', '--assert', '-Wall', '-j', '2',
                       '-CFLAGS', '-O1 -I' + str(build), '-Imicrocontroller/rtl', '--top-module', 'drg5_debug_system',
                       '--Mdir', str(build / 'build'), *map(str, rtl), str(root / 'microcontroller/tests/drg5_debug_remote.cpp')]
    # no HDL warning is waived by the host-interoperability test.
    with (attempt / 'build.log').open('w') as stream:
        stream.write('$ ' + shlex.join(compile_command) + '\n'); stream.flush()
        result = subprocess.run(compile_command, cwd=root, stdout=stream, stderr=subprocess.STDOUT, timeout=600)
    # fail strict elaboration on either warnings or process errors.
    if result.returncode or '%Warning' in (attempt / 'build.log').read_text():
        raise RuntimeError('strict debug-system build failed: ' + str(attempt / 'build.log'))
    remote_port, tcl_port, gdb_port = free_port(), free_port(), free_port()
    config = f'''# exercise a simulation-only TAP identity through the actual RTL pins.
adapter driver remote_bitbang
remote_bitbang host 127.0.0.1
remote_bitbang port {remote_port}
transport select jtag
jtag newtap drg5 cpu -irlen 5 -expected-id 0x00000001
target create drg5.cpu riscv -chain-position drg5.cpu
riscv set_mem_access sysbus
gdb_port {gdb_port}
tcl_port {tcl_port}
telnet_port disabled
init
halt
'''
    (attempt / 'openocd.cfg').write_text(config)
    image = bytearray(0x200)
    # original instruction bytes are deliberately independent of the hardware decoder.
    words = {0: 0x00700293, 4: 0x00900313, 8: 0x00528463, 12: 0x06300393,
             16: 0x008000ef, 20: 0x06300393, 24: 0x00b00393, 30: 0x02100413,
             34: 0x00100073, 38: 0x10500073, 42: 0x00000073,
             0x80: 0x03700493, 0x84: 0x00100073,
             0xa0: 0x40000537, 0xa4: 0x00052583, 0xa8: 0x00b52023,
             0xac: 0x00100073, 0xb0: 0x10500073, 0xb4: 0xffdff06f,
             0xc0: 0x00000013, 0xc4: 0x00100073}
    # include a compressed instruction and a following word starting at a halfword boundary.
    for offset, value in words.items():
        image[offset:offset + 4] = struct.pack('<I', value)
    image[28:30] = struct.pack('<H', 0x0385)
    (attempt / 'program.bin').write_bytes(image)
    script = f'''# access the implemented system through OpenOCD's GDB server.
set pagination off
set confirm off
set architecture riscv:rv32
set osabi none
set remotetimeout 15
target extended-remote 127.0.0.1:{gdb_port}
monitor halt
monitor reset halt
maintenance flush register-cache
python assert int(gdb.parse_and_eval('$pc')) == 0
monitor riscv dmi_write 0x10 0x9
monitor riscv dmi_write 0x10 0xb
monitor riscv dmi_write 0x10 0x1
monitor halt
maintenance flush register-cache
python assert int(gdb.parse_and_eval('$pc')) == 0
python assert (int(gdb.parse_and_eval('$dcsr')) >> 6) & 7 == 5
monitor riscv dmi_write 0x10 0x5
restore {attempt / 'program.bin'} binary 0x10000
set {{unsigned int}}0x20000000=0x12345678
set {{unsigned short}}0x20000002=0xabcd
set {{unsigned char}}0x20000001=0xef
python assert int(gdb.parse_and_eval('*(unsigned int*)0x20000000')) == 0xabcdef78
python assert int(gdb.parse_and_eval('*(unsigned short*)0x20000002')) == 0xabcd
python assert int(gdb.parse_and_eval('*(unsigned char*)0x20000001')) == 0xef
set $pc=0x10000
set $t0=0x12345678
python assert int(gdb.parse_and_eval('$t0')) == 0x12345678
stepi
python assert int(gdb.parse_and_eval('$t0')) == 7
python assert int(gdb.parse_and_eval('$pc')) == 0x10004
python assert (int(gdb.parse_and_eval('$dcsr')) >> 6) & 7 == 4
stepi
python assert int(gdb.parse_and_eval('$t1')) == 9
stepi
python assert int(gdb.parse_and_eval('$pc')) == 0x10010
stepi
python assert int(gdb.parse_and_eval('$pc')) == 0x10018
python assert int(gdb.parse_and_eval('$ra')) == 0x10014
stepi
stepi
python assert int(gdb.parse_and_eval('$t2')) == 12
python assert int(gdb.parse_and_eval('$pc')) == 0x1001e
stepi
python assert int(gdb.parse_and_eval('$s0')) == 33
python assert int(gdb.parse_and_eval('$pc')) == 0x10022
set $pc=0x10026
stepi
python assert int(gdb.parse_and_eval('$pc')) == 0x1002a
set $mtvec=0x10080
set $s1=0
stepi
python assert int(gdb.parse_and_eval('$pc')) == 0x10080
python assert int(gdb.parse_and_eval('$mepc')) == 0x1002a
python assert int(gdb.parse_and_eval('$mcause')) == 11
python assert int(gdb.parse_and_eval('$s1')) == 0
python assert (int(gdb.parse_and_eval('$dcsr')) >> 6) & 7 == 4
set $pc=0x10000
break *0x10018
continue
python assert int(gdb.parse_and_eval('$pc')) == 0x10018
delete breakpoints
stepi
python assert int(gdb.parse_and_eval('$t2')) == 11
set $pc=0x100a0
stepi
stepi
python assert int(gdb.parse_and_eval('$a1')) == 1
python assert int(gdb.parse_and_eval('*(unsigned int*)0x40000008')) == 1
stepi
python assert int(gdb.parse_and_eval('*(unsigned int*)0x4000000c')) == 1
set $pc=0x100c0
continue
python assert int(gdb.parse_and_eval('$pc')) == 0x100c4
python assert int(gdb.parse_and_eval('*(unsigned int*)0x40000008')) == 1
python assert int(gdb.parse_and_eval('*(unsigned int*)0x4000000c')) == 1
set $pc=0x100b0
monitor resume 0x100b0
monitor halt
maintenance flush register-cache
python assert int(gdb.parse_and_eval('$pc')) == 0x100b4
set $mtvec=0x10080
set $s1=0
set $mie=0x800
set $mstatus=0x1808
set {{unsigned int}}0x40000004=0x800
set $pc=0x100c0
stepi
python assert int(gdb.parse_and_eval('$pc')) == 0x100c4
python assert int(gdb.parse_and_eval('$s1')) == 0
python assert int(gdb.parse_and_eval('$mip')) & 0x800
continue
python assert int(gdb.parse_and_eval('$pc')) == 0x10084
python assert int(gdb.parse_and_eval('$mcause')) & 0xffffffff == 0x8000000b
python assert int(gdb.parse_and_eval('$mepc')) == 0x100c4
python assert int(gdb.parse_and_eval('$s1')) == 55
set {{unsigned int}}0x40000004=0
python print('DEBUG_GDB_PASS reset_register_memory_branch_link_compressed_wfi_trap_breakpoint_mmio_irq')
disconnect
quit
'''
    (attempt / 'gdb.cmd').write_text(script)
    simulator = server = None
    capture = attempt / 'capture.jsonl'
    # cleanup never converts a killed process or missing marker into a pass.
    try:
        # retain simulator and OpenOCD diagnostics in separate files.
        with (attempt / 'simulator.log').open('w') as simulation_log, (attempt / 'openocd.log').open('w') as server_log:
            simulator = subprocess.Popen([str(build / 'build/Vdrg5_debug_system'), str(remote_port), str(capture), str(args.seed)],
                                         cwd=root, stdout=simulation_log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 15
            # wait for the advertised listener without consuming its one allowed client.
            while 'DEBUG_REMOTE_READY' not in (attempt / 'simulator.log').read_text():
                # bound listener startup and detect early simulator exit.
                if simulator.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('RTL transport listener failed')
                time.sleep(0.05)
            server = subprocess.Popen([args.openocd, '-f', str(attempt / 'openocd.cfg')], cwd=root,
                                      stdout=server_log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 30
            # the Tcl listener is used only after OpenOCD completes initialization.
            while True:
                # bound initialization before issuing debugger commands.
                if server.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('OpenOCD initialization failed: ' + str(attempt / 'openocd.log'))
                # connect only through the advertised local Tcl port.
                try:
                    control = socket.create_connection(('127.0.0.1', tcl_port), timeout=1)
                    control.settimeout(20); break
                # retry while initialization still owns its deadline.
                except OSError:
                    time.sleep(0.1)
            # close the control connection after ordered tool shutdown.
            with control:
                initial = command(control, 'halt')
                (attempt / 'tcl.log').write_text(initial + '\n')
                # retain every GDB assertion and target stop in the host log.
                with (attempt / 'gdb.log').open('w') as gdb_log:
                    result = subprocess.run([args.gdb, '-q', '-nx', '-batch', '-x', str(attempt / 'gdb.cmd')],
                                            cwd=root, stdout=gdb_log, stderr=subprocess.STDOUT, text=True, timeout=600)
                # require both successful exit and the complete positive marker.
                if result.returncode or (attempt / 'gdb.log').read_text().count('DEBUG_GDB_PASS') != 1:
                    raise RuntimeError('GDB interoperability failed: ' + str(attempt / 'gdb.log'))
                negative = f'''# deliberately reject a wrong GPR expectation through the actual GDB path.
set pagination off
set confirm off
set architecture riscv:rv32
set osabi none
target extended-remote 127.0.0.1:{gdb_port}
monitor halt
set $t0=0x12345678
python assert int(gdb.parse_and_eval('$t0')) == 0x12345679, 'DEBUG_GDB_CALIBRATION'
'''
                (attempt / 'gdb-negative.cmd').write_text(negative)
                # a real host assertion must fail; a disconnected or unexamined target is insufficient.
                with (attempt / 'gdb-negative.log').open('w') as negative_log:
                    rejected = subprocess.run([args.gdb, '-q', '-nx', '-batch', '-x', str(attempt / 'gdb-negative.cmd')],
                                              cwd=root, stdout=negative_log, stderr=subprocess.STDOUT, timeout=120)
                # require the deliberate host assertion to fail by name.
                if rejected.returncode == 0 or 'DEBUG_GDB_CALIBRATION' not in (attempt / 'gdb-negative.log').read_text():
                    raise RuntimeError('GDB negative control failed its intended detector')
                command(control, 'halt')
                control.sendall(b'shutdown\x1a')
            # both endpoints must acknowledge clean shutdown.
            if server.wait(timeout=20) != 0 or simulator.wait(timeout=20) != 0:
                raise RuntimeError('debug transport shutdown failed')
        # a missing footer producer marker prevents qualification.
        if 'DEBUG_REMOTE_COMPLETE' not in (attempt / 'simulator.log').read_text():
            raise RuntimeError('missing simulator completion marker')
        replay_result = replay(capture, {'packed_bits': bits, 'fields': fields})
        mutations = calibrate_replay(capture, {'packed_bits': bits, 'fields': fields}, attempt)
        after = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
        # qualification applies only to unchanged input sources.
        if before != after:
            raise RuntimeError('debug source changed during qualification')
        summary = {'status': 'passed', 'seed': args.seed, 'revision': revision, 'source_sha256': before,
                   'scope': 'real RTL JTAG/DM/core with OpenOCD and GDB over loopback; no physical board qualification',
                   'gdb_checks': 'reset-halt, register/memory modification, branches, links, mixed widths, WFI, trap step, software breakpoint, MMIO effects, interrupt masking/service',
                   'gdb_osabi': 'none', 'gdb_negative_control': 'DEBUG_GDB_CALIBRATION',
                   'offline_detectors': mutations, 'replay': replay_result,
                   'capture_sha256': hashlib.sha256(capture.read_bytes()).hexdigest(),
                   'capture_gzip_sha256': hashlib.sha256(gzip.compress(capture.read_bytes(), mtime=0)).hexdigest()}
        (attempt / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
        shutil.copyfile(attempt / 'summary.json', evidence / 'summary.json')
        print('DEBUG_REMOTE_PASS ' + str(attempt))
    # release host processes even when a qualification stage fails.
    finally:
        # failed sessions are terminated without changing their retained diagnostic files.
        for process in [server, simulator]:
            # terminate only children that are still running.
            if process is not None and process.poll() is None:
                process.terminate()
                # allow a bounded graceful process exit.
                try:
                    process.wait(timeout=5)
                # kill a child that cannot finish graceful termination.
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=5)
        # retain deterministic compressed capture bytes for later replay.
        if capture.exists():
            capture.with_suffix('.jsonl.gz').write_bytes(gzip.compress(capture.read_bytes(), mtime=0))
            capture.unlink()


# run only when invoked as the qualification entrypoint.
if __name__ == '__main__':
    main()
