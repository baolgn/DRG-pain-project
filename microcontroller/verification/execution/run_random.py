#!/usr/bin/env python3
"""qualify seeded programs against Sail, bus effects and occupancy-independent execution."""
import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path
import random
import shlex
import shutil
import subprocess
import sys

from comparison import compare, read_dut, read_sail, require
from run_elf import ROOT, DEFAULT_VERILATOR, execute, sha, load_elf, NAMES

GCC=Path('/tmp/drg5-arch-tools/gcc/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-gcc')
SAIL=Path('/tmp/drg5-arch-tools/sail/sail-riscv-Linux-x86_64/bin/sail_riscv_sim')
PROFILES=[('rv32imc-forwarded',1,1,0,1),('rv32imc-interlocked',1,1,0,0),
          ('rv32imc-diagnostic',1,1,1,1),('rv32i-machine-prototype',0,0,0,1)]
LINK='''/* exact production instruction and data capacities. */
OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { iram (rwx) : ORIGIN = 0x10000, LENGTH = 0x10000
         dram (rw) : ORIGIN = 0x20000000, LENGTH = 0x8000 }
/* generated programs use only initialized IRAM and zero-filled DRAM. */
SECTIONS { .text : { *(.text.init) *(.text*) } > iram
           .data : { *(.data*) } > dram
           .bss (NOLOAD) : { *(.bss*) } > dram }
'''


# instruction-generation randomness is independent of target service and pipeline stalls.
def program(seed,c,m):
    """generate terminating programs with arithmetic, hazards, branches, CSRs and traps."""
    rng=random.Random(seed);registers=[n for n in range(1,24)]
    text=['/* real firmware initializes reference state and trap handling. */','.section .text.init',
          '.option norelax','.globl _start,reference_stop','_start:', 'li x5,5','csrw mcountinhibit,x5',
          'li x25,0x20000000','la x26,trap_handler','csrw mtvec,x26','li x29,0']
    # randomized constants include signed and unsigned extrema before dependent operations.
    boundaries=[0,1,0x7fffffff,0x80000000,0xffffffff,0x55555555,0xaaaaaaaa,31,32,63]
    # initialize every operand register before random reads.
    for rd in registers:
        text.append(f'li x{rd},0x{rng.choice(boundaries) if rd<12 else rng.getrandbits(32):08x}')
    # every initialized data word has an independent known compiler-emitted store.
    for offset in range(0,128,4):
        text.append(f'sw x{rng.choice(registers)},{offset}(x25)')
    text.append('/* deliberate arithmetic corners precede randomized dependency chains. */')
    # every M operation sees zero divisors and the signed overflow operands.
    if m:
        # exercise each multiply and divide operation with both corner inputs.
        for op in ['mul','mulh','mulhsu','mulhu','div','divu','rem','remu']:
            text += ['li x4,0x80000000','li x5,-1',f'{op} x6,x4,x5',f'{op} x7,x4,x0']
    # bounded forward branches and fixed loop counts cannot silently run forever.
    for index in range(384):
        rd,rs1,rs2=[rng.choice(registers) for _ in range(3)]
        choice=index%12
        text.append(f'/* generated dependency group {index}. */')
        # register arithmetic stresses newest-producer selection across several distances.
        if choice in (0,1):
            op=rng.choice(['add','sub','sll','slt','sltu','xor','srl','sra','or','and'])
            text.append(f'{op} x{rd},x{rs1},x{rs2}')
        # immediate arithmetic and shift amounts cover signed encodings and all five shift bits.
        elif choice==2:
            op=rng.choice(['addi','slti','sltiu','xori','ori','andi','slli','srli','srai'])
            value=rng.randrange(32) if op in ['slli','srli','srai'] else rng.randrange(-2048,2048)
            text.append(f'{op} x{rd},x{rs1},{value}')
        # stores followed immediately by loads exercise address, data and load-use hazards.
        elif choice==3:
            size=rng.randrange(3);offset=rng.randrange(128//(1<<size))*(1<<size)
            store=['sb','sh','sw'][size];load=rng.choice([['lb','lbu'],['lh','lhu'],['lw']][size])
            text += [f'{store} x{rs1},{offset}(x25)',f'{load} x{rd},{offset}(x25)',f'add x{rs2},x{rd},x{rs1}']
        # each condition gets both data-dependent and guaranteed-taken variants across seeds.
        elif choice==4:
            op=rng.choice(['beq','bne','blt','bge','bltu','bgeu'])
            text += [f'{op} x{rs1},x{rs2},branch_{index}',f'addi x{rd},x{rd},1',f'branch_{index}:']
        # repeated writes create newer unready producers that must shadow older matches.
        elif choice==5 and m:
            op=rng.choice(['mul','mulh','mulhsu','mulhu','div','divu','rem','remu'])
            text += [f'addi x{rd},x0,7',f'{op} x{rd},x{rs1},x{rs2}',f'xor x{rs2},x{rd},x{rs1}']
        # jump links and JALR bit-zero clearing are observable register results.
        elif choice==6:
            text += [f'jal x{rd},jump_{index}',f'addi x{rd},x0,-1',f'jump_{index}:',
                     f'la x24,indirect_{index}','ori x24,x24,1',f'jalr x{rs2},0(x24)',
                     f'addi x{rd},x0,-2',f'indirect_{index}:']
        # all six CSR forms include nonzero source indices holding zero and suppressed x0 accesses.
        elif choice==7:
            text += [f'csrrw x{rd},mscratch,x{rs1}',f'csrrs x{rs2},mscratch,x0','li x24,0',
                     f'csrrc x{rd},mscratch,x24','csrrwi x0,mscratch,0',
                     f'csrrsi x{rd},mscratch,0',f'csrrci x{rs2},mscratch,3']
        # compressed halfwords deliberately put following 32-bit instructions across word boundaries.
        elif choice==8 and c:
            text += ['c.nop','c.li x8,-1','c.slli x8,31','.option push','.option norvc',
                     'addi x9,x8,1','.option pop','c.add x9,x8','c.mv x10,x9']
        # fences exercise fetch invalidation with delayed, already exposed requests.
        elif choice==9:
            text += ['fence iorw,iorw','fence.i']
        # a load to x0 remains an actual memory access.
        elif choice==10:
            text += [f'lw x0,{rng.randrange(32)*4}(x25)',f'lui x{rd},0x{rng.randrange(1<<20):x}']
        # short counted loops exercise backward redirects without unbounded random control flow.
        else:
            text += ['li x24,3',f'loop_{index}:',f'addi x{rd},x{rd},-1','addi x24,x24,-1',f'bne x24,x0,loop_{index}']
    text += ['/* precise traps preserve the instruction-start PC and advance by its actual length. */',
             '.option push','.option norvc','ecall','ebreak','.word 0x0200000b','csrr x5,0x7c0',
             'lw x6,1(x25)','sw x7,2(x25)','li x24,0x60000000','lw x0,0(x24)','.option pop']
    # compressed traps require a two-byte return increment.
    if c:
        text += ['c.ebreak','.hword 0x0000']
    text += ['j reference_stop','.balign 4','trap_handler:',
             'csrr x26,mepc','lhu x27,0(x26)','andi x27,x27,3','li x28,3','bne x27,x28,short_trap',
             'addi x26,x26,4','j trap_return','short_trap:','addi x26,x26,2','trap_return:',
             'addi x29,x29,1','csrw mepc,x26','mret',
             '/* reference comparison ends before device-specific destructive MMIO self-checks. */',
             'reference_stop:','li x25,0x40000000','lw x0,32(x25)','lw x5,32(x25)','li x6,2',
             'bne x5,x6,failed','sw x5,36(x25)','sw x5,36(x25)','lw x5,40(x25)',
             'bne x5,x6,failed','lw x5,44(x25)','bne x5,x6,failed','li x5,1','sw x5,0(x25)',
             'finished:','j finished','failed:','li x5,3','sw x5,0(x25)','j finished']
    return '\n'.join(text)+'\n'


# every external command retains its complete diagnostics and exact invocation.
def command(argv,log):
    """run one deterministic tool step and require success."""
    result=subprocess.run([str(x) for x in argv],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                          text=True,timeout=300,check=False)
    Path(log).write_text('$ '+shlex.join([str(x) for x in argv])+'\n'+result.stdout)
    require(result.returncode==0,'tool failed: '+str(log))
    return result.stdout


# damaged observations must fail the relevant detector, not merely exit for unrelated reasons.
def controls(trace,schema,terminals,reference,stop_pc,directory):
    """calibrate wrong results, missing terminals, stale PCs, duplicate effects and truncation."""
    results=[]
    # retirement mutations preserve every independent Sail expectation.
    for mutation,reason in [('wrong_result','register result'),('lost_instruction','instruction identity'),
                            ('stale_instruction','instruction identity')]:
        damaged=copy.deepcopy(terminals)
        # choose a nonboot register-writing instruction for an observable arithmetic corruption.
        if mutation=='wrong_result':
            index=next(n for n in range(32,len(damaged)) if damaged[n]['rd_write'])
            damaged[index]['value']^=1
        # removing a terminal shifts all subsequent reference identities.
        elif mutation=='lost_instruction':
            del damaged[40]
        # an obsolete fetch PC cannot match the expected instruction sequence.
        else:
            damaged[40]['packet.pc']^=2
        # an exact failure reason demonstrates the intended checker fired.
        try:
            compare(damaged,reference,stop_pc)
        # require the intended architectural comparison failure.
        except ValueError as error:
            require(reason in str(error),'wrong mutation detector')
            results.append({'mutation':mutation,'detected':str(error)})
        # successful comparison of a mutation is a verification failure.
        else:
            require(False,'undetected '+mutation)
    rows=[json.loads(line) for line in Path(trace).read_text().splitlines()]
    # physical effects and trace completeness are calibrated separately from architectural comparison.
    for mutation in ['duplicate_mmio','lost_tail']:
        damaged=copy.deepcopy(rows)
        # a second accepted destructive effect must have no valid unused owner.
        if mutation=='duplicate_mmio':
            offers={row['tag'] for row in damaged if row.get('event')=='offer' and
                    row.get('bus')=='d' and row['address']==0x40000020}
            index=next(n for n,row in enumerate(damaged) if row.get('event')=='accept' and
                       row.get('bus')=='d' and row['tag'] in offers)
            damaged.insert(index+1,copy.deepcopy(damaged[index]))
            # maintain sequence metadata so only the ownership detector explains rejection.
            for n,row in enumerate(damaged[1:-1],1):
                row['sequence']=n
            damaged[-1]['events']+=1
        # a valid prefix without its required end record cannot qualify.
        else:
            damaged.pop()
        path=directory/(mutation+'.jsonl');path.write_text(''.join(json.dumps(row)+'\n' for row in damaged))
        reason='duplicate or unowned acceptance' if mutation=='duplicate_mmio' else 'trace completeness'
        # the independent bus checker supplies a stable expected failure.
        try:
            read_dut(path,schema)
        # require the intended ownership or completeness failure.
        except ValueError as error:
            require(reason in str(error),'wrong bus mutation detector')
            results.append({'mutation':mutation,'detected':str(error)})
        # absence of a failure means the calibration did not establish detection.
        else:
            require(False,'undetected '+mutation)
    return results


# full qualification retains generated assembly, compiler products and both independent traces.
def main():
    """run reproducible program seeds in all separately compiled occupancy profiles."""
    parser=argparse.ArgumentParser()
    parser.add_argument('--build',type=Path,default=Path('/tmp/drg5-random-programs'))
    parser.add_argument('--evidence',type=Path,default=ROOT/'microcontroller/verification/evidence/verification-2026-11-04/execution')
    parser.add_argument('--verilator',default=DEFAULT_VERILATOR)
    parser.add_argument('--smoke',action='store_true')
    args=parser.parse_args();args.build.mkdir(parents=True,exist_ok=True);args.evidence.mkdir(parents=True,exist_ok=True)
    evidence_root=args.evidence
    revisions=evidence_root/'revisions';revisions.mkdir(exist_ok=True)
    number=max([int(path.name[:2]) for path in revisions.iterdir() if path.is_dir() and path.name[:2].isdigit()]+[0])+1
    args.evidence=revisions/f'{number:02d}-qualification';args.evidence.mkdir()
    seeds=[1] if args.smoke else [0,1,2,7,31,255,0x12345678,0xffffffff]
    profiles=PROFILES[:1] if args.smoke else PROFILES
    results=[];negative=[];reference_cache={};mode_digests={}
    owned=[path for path in Path(__file__).parent.iterdir() if path.suffix in ('.py','.cpp','.sv')]
    owned += [ROOT/f'microcontroller/rtl/{name}.sv' for name in NAMES]
    owned += [ROOT/'microcontroller/rtl/drg5_datapath_defs.svh',
              ROOT/'microcontroller/tests/replay_counter_trace.py',ROOT/'microcontroller/verification/act4/sail-retirement.json']
    before={str(path.relative_to(ROOT)):sha(path) for path in owned}
    # retain every transitive source before execution, including the exact model configuration.
    for path in owned:
        target=args.evidence/'sources'/path.relative_to(ROOT);target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(path,target)
    tools=[GCC,GCC.with_name('riscv-none-elf-as'),GCC.with_name('riscv-none-elf-ld'),SAIL,
           Path(args.verilator),Path(args.verilator).with_name('verilator_bin')]
    tool_hashes={str(path):sha(path) for path in tools}
    # each profile has matching compiler flags, CPU parameters and Sail capabilities.
    for name,c,m,diagnostic,forwarding in profiles:
        cfg=json.loads((ROOT/'microcontroller/verification/act4/sail-retirement.json').read_text())
        cfg['extensions']['M']['supported']=bool(m);cfg['extensions']['Zmmul']['supported']=bool(m)
        cfg['extensions']['Zca']['supported']=bool(c)
        cfgpath=args.build/f'sail-c{c}-m{m}.json';cfgpath.write_text(json.dumps(cfg,indent=2)+'\n')
        # program seeds are reused across timing and occupancy profiles without changing assembly.
        for seed in seeds:
            directory=args.build/name/f'seed-{seed}';directory.mkdir(parents=True,exist_ok=True)
            asm=directory/'program.S';asm.write_text(program(seed,c,m))
            linker=directory/'link.ld';linker.write_text(LINK)
            elf=directory/'program.elf'
            march='rv32i2p1'+('_m2p0' if m else '')+('_c2p0' if c else '')+'_zicsr2p0_zifencei2p0'
            command([GCC,f'-march={march}','-mabi=ilp32','-mstrict-align','-mno-relax',
                     '-Wa,-mpriv-spec=1.13,-mcsr-check','-nostdlib','-Wl,--no-relax',f'-Wl,-T,{linker}',
                     '-o',elf,asm],directory/'gcc.log')
            symbols=command([GCC.with_name('riscv-none-elf-nm'),elf],directory/'symbols.log')
            stop_pc=int(next(line.split()[0] for line in symbols.splitlines() if line.endswith(' reference_stop')),16)
            sailtrace=directory/'sail.trace';key=(seed,c,m)
            # identical load images reuse a reference only with matching entry and configuration.
            if key in reference_cache:
                old_elf,old_trace,old_config=reference_cache[key]
                require(load_elf(old_elf)==load_elf(elf) and old_config==sha(cfgpath),'occupancy loaded-image and reference identity')
                shutil.copyfile(old_trace,sailtrace)
            # every distinct ISA/program pair executes the pinned independent Sail model.
            else:
                command([SAIL,'--config',cfgpath,'--stop-at-pc',hex(stop_pc),'--inst-limit','100000',
                         '--trace-output',sailtrace,'--trace-instr','--trace-gpr','--trace-csr','--trace-mem',
                         '--trace-exception','--trace-interrupt','--trace-step',elf],directory/'sail.log')
                reference_cache[key]=(elf,sailtrace,sha(cfgpath))
            observed=execute(elf,args.build/'simulators',directory/'dut',seed^0x9e3779b9,True,
                             2000000,args.verilator,c,m,diagnostic,forwarding)
            require(observed['status']=='passed','DUT execution '+name)
            schema=json.loads((args.build/'simulators'/f'c{c}-m{m}-d{diagnostic}-f{forwarding}'/'trace-schema.json').read_text())
            terminals,footer=read_dut(directory/'dut/trace.jsonl',schema)
            reference=read_sail(sailtrace);counts=compare(terminals,reference,stop_pc)
            require(footer['mmio_reads']==2 and footer['mmio_writes']==2,'destructive MMIO self-check counts')
            digest=hashlib.sha256(json.dumps([{key:value for key,value in item.items() if key not in ('uid','order')}
                                             for item in terminals],sort_keys=True).encode()).hexdigest()
            # identical programs have identical full architectural outcomes in every occupancy mode.
            if (seed,c,m) in mode_digests:
                require(digest==mode_digests[(seed,c,m)],'occupancy architectural equivalence')
            mode_digests[(seed,c,m)]=digest
            # one complete passing capture calibrates the independent detectors.
            if not negative:
                negative=controls(directory/'dut/trace.jsonl',schema,terminals,reference,stop_pc,directory)
            target=args.evidence/name/f'seed-{seed}';target.mkdir(parents=True,exist_ok=True)
            # retain compact evidence, including original firmware and exact expected instruction sequence.
            for path in [asm,linker,elf,cfgpath,directory/'gcc.log',directory/'symbols.log',directory/'dut/summary.json',
                         directory/'dut/execution.log']:
                shutil.copyfile(path,target/path.name)
            # long event traces are losslessly compressed, not replaced by aggregate pass markers.
            for path in [sailtrace,directory/'dut/trace.jsonl']:
                # compress each complete reference or DUT stream losslessly.
                with path.open('rb') as source,gzip.open(target/(path.name+'.gz'),'wb') as destination:
                    shutil.copyfileobj(source,destination)
            (target/'trace-schema.json').write_text(json.dumps(schema,indent=2)+'\n')
            results.append({'profile':name,'seed':seed,'timing_seed':seed^0x9e3779b9,'march':march,
                            'elf_sha256':sha(elf),'architectural_sha256':digest,'sail_config_sha256':sha(cfgpath),'comparison':counts,
                            'bus':footer,'evidence':str(target.relative_to(ROOT))})
            print('RANDOM_SAIL_PASS '+name+' '+str(seed)+' '+json.dumps(counts),flush=True)
    require(before=={str(path.relative_to(ROOT)):sha(path) for path in owned},'execution source changed during qualification')
    summary={'status':'passed','smoke':args.smoke,'results':results,'negative_controls':negative,'source_sha256':before,'tool_sha256':tool_hashes,
             'gcc':command([GCC,'--version'],args.evidence/'gcc-version.log').splitlines()[0],
             'sail':command([SAIL,'--version'],args.evidence/'sail-version.log').strip(),
             'assumptions':['single outstanding request per bus; acceptance stalls0..7 and response delays1..12 clocks',
                            'one random stage hold per cycle with probability1/8; maximum bus wait128clocks',
                            'ROM explicitly clears x1..x31; compared firmware initializes mcountinhibit=5',
                            'Sail uses the exact memory regions and no independent interrupt injection',
                            'completion freezes younger stages and drains exposed requests before final trace footer'],
             'limitations':['finite randomized programs, not exhaustive ISA proof or ACT4 certification',
                            'Sail comparison ends before platform-specific destructive MMIO; physical bus accounting covers the full run',
                            'no timed IRQ, debug or counter-tick equivalence to Sail; separately directed verification covers those behaviors',
                            'Sail mcountinhibit reset is0 versus DUT5; explicit initial write reconciles execution state',
                            'no FPGA timing, routing, hardware programming or acquisition deadline qualification']}
    require(tool_hashes=={str(path):sha(path) for path in tools},'tool binaries changed during qualification')
    # strict compiler logs are retained for each separately elaborated occupancy configuration.
    for path in (args.build/'simulators').glob('*/build.log'):
        target=args.evidence/'build-logs'/path.parent.name;target.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(path,target/path.name)
    # calibrated bus mutations remain inspectable instead of existing only as a pass count.
    first=args.build/profiles[0][0]/f'seed-{seeds[0]}'
    # each retained mutation is a complete reproducible checker input.
    for name in ['duplicate_mmio.jsonl','lost_tail.jsonl']:
        # compression preserves exact damaged bytes for later inspection.
        with (first/name).open('rb') as source,gzip.open(args.evidence/(name+'.gz'),'wb') as target:
            shutil.copyfileobj(source,target)
    summary_path=args.evidence/'summary.json';summary_path.write_text(json.dumps(summary,indent=2)+'\n')
    shutil.copyfile(summary_path,evidence_root/('smoke-summary.json' if args.smoke else 'summary.json'))


# importing the generator cannot launch tools or overwrite evidence.
if __name__=='__main__':
    main()
