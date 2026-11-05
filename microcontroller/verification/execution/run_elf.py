#!/usr/bin/env python3
"""run exact-map ELF files on the production CPU with independent bus accounting."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shlex
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[3]
DEFAULT_VERILATOR = '/tmp/drg5-control-tools-20260301/oss-cad-suite/bin/verilator'
NAMES = ['drg5_control_pkg', 'drg5_immediate', 'drg5_decoder', 'drg5_branch', 'drg5_lsu',
         'drg5_shifter', 'drg5_alu', 'drg5_forward', 'drg5_decompress', 'drg5_fetch_guard',
         'drg5_fetch_buffer', 'drg5_fetch', 'drg5_frontend', 'drg5_csr', 'drg5_muldiv',
         'drg5_control', 'drg5_irq_platform']


# hashes bind cached executables to every source and build option.
def sha(path):
    """return a source or artifact fingerprint."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


# terminal offsets come from packed RTL declarations, never guessed C++ layouts.
def schema(directory):
    """emit portable terminal metadata and its C++ field constants."""
    spec = importlib.util.spec_from_file_location('counter_schema', ROOT / 'microcontroller/tests/replay_counter_trace.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    original = module.make_schema(ROOT / 'microcontroller/rtl/drg5_control_pkg.sv')
    fields = {name.removeprefix('terminal.'): dict(item) for name, item in original['fields'].items()
              if name.startswith('terminal.')}
    base = min(item['lsb'] for item in fields.values())
    # each field becomes relative to trace_t rather than its enclosing observation.
    for item in fields.values():
        item['lsb'] -= base
    bits = max(item['lsb'] + item['width'] for item in fields.values())
    result = {'schema': 'DRG5-ARCH1', 'packed_bits': bits, 'fields': fields,
              'package_sha256': original['package_sha256']}
    (directory / 'trace-schema.json').write_text(json.dumps(result, indent=2) + '\n')
    aliases = {'PC':'packet.pc', 'MEM_ADDR':'packet.mem_addr', 'PACKET_OP':'packet.op'}
    # operand identities and values are carried by the original instruction packet.
    for name in ['rs1_used','rs2_used','rs1','rs2','rs1_value','rs2_value']:
        aliases[name.upper()] = 'packet.' + name
    # committed destination metadata is separate from the tentative packet.
    for name in ['valid','trap','uid','order','rd_write','rd','value']:
        aliases[name.upper()] = name
    header = ['/* packed trace offsets are generated from the production package. */', '#pragma once',
              f'#define TRACE_WORDS {(bits+31)//32}']
    header += [f'#define TRACE_{name}_LSB {fields[field]["lsb"]}' for name,field in aliases.items()]
    (directory / 'arch_trace_fields.h').write_text('\n'.join(header) + '\n')
    return result


# ELF loading rejects capacity, format and address discrepancies before simulation.
def load_elf(path):
    """return initialized bytes and the entry address from a bounded ELF32 image."""
    raw = Path(path).read_bytes()
    # only little-endian RV32 executable images match this platform.
    if len(raw)<52 or raw[:7]!=b'\x7fELF\x01\x01\x01':
        raise ValueError('expected little-endian ELF32')
    _,kind,machine,version,entry,phoff,_,_,ehsize,phsize,phnum,_,_,_ = struct.unpack_from('<16sHHIIIIIHHHHHH',raw)
    # executable entry must be a parcel within instruction RAM.
    if kind!=2 or machine!=243 or version!=1 or ehsize!=52 or phsize!=32 or not 0x10000<=entry<0x20000 or entry&1:
        raise ValueError('ELF architecture, entry or header mismatch')
    image = {}
    # load segments include explicit zero initialization for their BSS tails.
    for index in range(phnum):
        offset=phoff+index*phsize
        # truncated headers cannot become silent empty programs.
        if offset+phsize>len(raw):
            raise ValueError('truncated program header')
        ptype,offset,vaddr,paddr,filesz,memsz,flags,align=struct.unpack_from('<IIIIIIII',raw,offset)
        # non-load metadata does not initialize target memory.
        if ptype!=1 or memsz==0:
            continue
        # no relocation, alias expansion or implicit larger test RAM is permitted.
        if vaddr!=paddr or filesz>memsz or offset+filesz>len(raw) or not any(
                lo<=paddr and paddr+memsz<=hi for lo,hi in [(0x10000,0x20000),(0x20000000,0x20008000)]):
            raise ValueError('ELF segment exceeds declared physical memory')
        # exact bytes, including zero-fill, are retained for reproducibility.
        for n in range(memsz):
            address=paddr+n
            value=raw[offset+n] if n<filesz else 0
            # overlapping load segments are rejected even when their bytes agree.
            if address in image:
                raise ValueError('overlapping ELF segments')
            image[address]=value
    # firmware initialization makes all nonzero registers explicitly defined.
    words=[(rd<<7)|0x13 for rd in range(1,32)]
    displacement=entry-len(words)*4
    immediate=displacement&0x1fffff
    words.append(((immediate>>20)&1)<<31 | ((immediate>>1)&0x3ff)<<21 |
                 ((immediate>>11)&1)<<20 | ((immediate>>12)&0xff)<<12 | 0x6f)
    # boot writes are real executed instructions and remain in the retirement trace.
    for n,word in enumerate(words):
        image.update({n*4+lane:(word>>(lane*8))&255 for lane in range(4)})
    return image, entry


# strict builds are reused only while their complete source fingerprint matches.
def build_sim(directory,verilator=DEFAULT_VERILATOR,c=1,m=1,diagnostic=0,forwarding=1):
    """elaborate the actual frontend, core and interrupt platform."""
    directory=Path(directory)/f'c{c}-m{m}-d{diagnostic}-f{forwarding}'
    directory.mkdir(parents=True,exist_ok=True)
    sources=[f'microcontroller/rtl/{name}.sv' for name in NAMES]
    sources += ['microcontroller/verification/execution/drg5_arch_top.sv']
    attributed=sources+['microcontroller/rtl/drg5_datapath_defs.svh',
        'microcontroller/verification/execution/arch_sim.cpp',
        'microcontroller/verification/execution/run_elf.py','microcontroller/tests/replay_counter_trace.py']
    version=subprocess.check_output([verilator,'--version'],text=True).strip()
    fingerprint={'sources':{name:sha(ROOT/name) for name in attributed},'verilator':version,
                 'configuration':{'c':c,'m':m,'diagnostic':diagnostic,'forwarding':forwarding}}
    stamp=directory/'build-inputs.json'; executable=directory/'Vdrg5_arch_top'
    # a matching cache skips recompilation without weakening source attribution.
    if stamp.exists() and executable.exists() and json.loads(stamp.read_text())==fingerprint:
        return executable, fingerprint
    schema(directory)
    command=[verilator,'--cc','--exe','--build','--assert','-Wall','-j','2','-CFLAGS',f'-O0 -I{directory}',
             '-Imicrocontroller/rtl','--top-module','drg5_arch_top',f'-GC_ENABLED={c}',f'-GM_ENABLED={m}',
             f'-GDIAGNOSTIC={diagnostic}',f'-GFORWARDING={forwarding}','--Mdir',str(directory),*sources,
             str(ROOT/'microcontroller/verification/execution/arch_sim.cpp')]
    # preserve exact commands and every warning before reporting a failed build.
    with (directory/'build.log').open('w') as stream:
        stream.write('$ '+shlex.join(command)+'\n'); stream.flush()
        process=subprocess.run(command,cwd=ROOT,stdout=stream,stderr=subprocess.STDOUT,timeout=600,check=False)
    # warnings are qualification failures, not suppressed diagnostics.
    if process.returncode or '%Warning' in (directory/'build.log').read_text():
        raise RuntimeError('strict simulator build failed: '+str(directory/'build.log'))
    # edits during compilation invalidate the resulting executable.
    if fingerprint['sources']!={name:sha(ROOT/name) for name in attributed}:
        raise RuntimeError('source changed during simulator build')
    stamp.write_text(json.dumps(fingerprint,indent=2)+'\n')
    return executable,fingerprint


# the reusable runner keeps failing outcomes as explicit evidence.
def execute(elf,build,output,seed=1,trace=False,max_cycles=2000000,verilator=DEFAULT_VERILATOR,
            c=1,m=1,diagnostic=0,forwarding=1):
    """load one ELF, execute one schedule and retain its independently checked result."""
    output=Path(output);output.mkdir(parents=True,exist_ok=True)
    image,entry=load_elf(elf)
    # the non-C configuration requires word-aligned instruction entry.
    if not c and entry&3:
        raise ValueError('non-C entry is not word aligned')
    image_path=output/'image.hex'
    image_path.write_text(''.join(f'{address:08x} {value:02x}\n' for address,value in sorted(image.items())))
    executable,fingerprint=build_sim(build,verilator,c,m,diagnostic,forwarding)
    capture=output/'trace.jsonl'
    command=[str(executable),str(image_path),str(capture) if trace else '-',str(seed),str(max_cycles)]
    result=subprocess.run(command,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=300,check=False)
    (output/'execution.log').write_text('$ '+shlex.join(command)+'\n'+result.stdout)
    markers=[line.removeprefix('ARCH_EXEC_PASS ') for line in result.stdout.splitlines() if line.startswith('ARCH_EXEC_PASS ')]
    passed=result.returncode==0 and len(markers)==1
    summary={'status':'passed' if passed else 'failed','elf':str(Path(elf).resolve()),'elf_sha256':sha(elf),
             'entry':entry,'image_sha256':sha(image_path),'seed':seed,'max_cycles':max_cycles,'command':command,
             'exit_code':result.returncode,'build':fingerprint,'observed':json.loads(markers[0]) if passed else None,
             'trace':str(capture) if trace else None}
    (output/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    return summary


# the command interface supports ACT4 batches and independent random-program runs.
def main():
    """run one file and return failure unless its completion store retired successfully."""
    parser=argparse.ArgumentParser()
    parser.add_argument('--elf',type=Path,required=True)
    parser.add_argument('--build',type=Path,default=Path('/tmp/drg5-arch-exec'))
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--seed',type=int,default=1)
    parser.add_argument('--max-cycles',type=int,default=2000000)
    parser.add_argument('--trace',action='store_true')
    parser.add_argument('--verilator',default=DEFAULT_VERILATOR)
    parser.add_argument('--c',type=int,choices=[0,1],default=1)
    parser.add_argument('--m',type=int,choices=[0,1],default=1)
    parser.add_argument('--diagnostic',type=int,choices=[0,1],default=0)
    parser.add_argument('--forwarding',type=int,choices=[0,1],default=1)
    args=parser.parse_args()
    result=execute(**vars(args))
    print(json.dumps(result['observed'] or {'status':result['status']}),flush=True)
    raise SystemExit(0 if result['status']=='passed' else 1)


# imports expose reusable helpers without executing a test.
if __name__=='__main__':
    main()
