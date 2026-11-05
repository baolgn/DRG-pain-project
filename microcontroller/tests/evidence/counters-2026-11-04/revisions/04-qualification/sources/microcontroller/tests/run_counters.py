#!/usr/bin/env python3
"""qualify machine counters against explicit event ledgers, induction and native mapping."""
import argparse
from collections import Counter
import csv
import gzip
import hashlib
import io
import json
from pathlib import Path
import shlex
import shutil
import subprocess


# retain exact command lines and complete diagnostics before judging each result.
def execute(command, path, root, timeout=300):
    """run one bounded tool invocation and preserve its output."""
    result=subprocess.run(command,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                          text=True,timeout=timeout,check=False)
    path.write_text('$ '+shlex.join(command)+'\n'+result.stdout)
    return result


# independently replay public CSR and event inputs rather than accepting fixture reference totals.
def replay_ledger(path):
    """reconstruct both 64-bit counters from each recorded input edge."""
    values=[0,0]; inhibit=5; edges=0; mask=(1<<64)-1
    mapping={0xb00:(0,0),0xb80:(0,32),0xb02:(1,0),0xb82:(1,32)}
    data=path.read_text()
    # each CSV row is an independently timestamped bank edge.
    for row in csv.DictReader(io.StringIO(data)):
        before=values[:]; next_values=before[:]; before_inhibit=inhibit
        # reset dominates counter writes, debug stops and implicit increments.
        if int(row['reset']):
            next_values=[0,0]; inhibit=5
        # all other edges use pre-edge debug and inhibit state.
        else:
            stopped=int(row['debug']) or int(row['debug_ebreak'])
            next_values[0]=(before[0]+int(not stopped and not before_inhibit&1))&mask
            next_values[1]=(before[1]+int(not stopped and not before_inhibit&4 and
                                        int(row['retire']) and not int(row['trap'])))&mask
            selected=int(row['addr'],16)
            commits=all(int(row[name]) for name in ['access','commit','write']) and not int(row['trap']) and not int(row['mret'])
            # only an actual counter or inhibit commit can replace automatic counting.
            if commits and (selected in mapping or selected==0x320):
                old_word=before_inhibit if selected==0x320 else (before[mapping[selected][0]]>>mapping[selected][1])&0xffffffff
                operand=int(row['source'],16); operation=int(row['op'])
                requested={0:old_word,1:operand,2:old_word|operand,3:old_word&~operand}[operation]&0xffffffff
                # inhibit writes take effect after this edge's automatic counts.
                if selected==0x320:
                    inhibit=requested&5
                # a half-write preserves the other pre-edge half, defeating any carry or wrap.
                else:
                    counter,shift=mapping[selected]
                    next_values[counter]=(before[counter]&~(0xffffffff<<shift))|(requested<<shift)
        values=next_values; edges+=1
        assert int(row['edge'])==edges,(path,edges,'edge numbering')
        assert [int(row['expected_cycle'],16),int(row['expected_instret'],16)]==values,(path,edges,'SV ledger')
        assert [int(row['observed_cycle'],16),int(row['observed_instret'],16)]==values,(path,edges,'DUT state')
        assert int(row['inhibit'],16)==inhibit,(path,edges,'inhibit state')
    compressed=gzip.compress(data.encode(),mtime=0)
    path.with_suffix('.csv.gz').write_bytes(compressed)
    path.unlink()
    return {'edges':edges,'final_mcycle':values[0],'final_minstret':values[1],
            'compressed_ledger_sha256':hashlib.sha256(compressed).hexdigest()}


# every qualification attempt preserves the exact source before building or executing it.
def main():
    """run two alignment banks, seeded ledgers, calibrated failures and independent formal checks."""
    parser=argparse.ArgumentParser()
    parser.add_argument('--verilator',default='verilator')
    parser.add_argument('--yosys',default='yosys')
    parser.add_argument('--build',type=Path,default=Path('/tmp/drg5-counters'))
    parser.add_argument('--evidence-dir',type=Path)
    parser.add_argument('--smoke',action='store_true')
    args=parser.parse_args(); root=Path(__file__).resolve().parents[2]
    build=args.build.resolve(); build.mkdir(parents=True,exist_ok=True)
    evidence=(args.evidence_dir or root/'microcontroller/tests/evidence/counters-2026-11-04').resolve()
    revisions=evidence/'revisions'; revisions.mkdir(parents=True,exist_ok=True)
    revision=max([int(p.name.split('-')[0]) for p in revisions.iterdir() if p.is_dir()]+[0])+1
    attempt=revisions/f'{revision:02d}-qualification'; attempt.mkdir()
    sources=['microcontroller/rtl/drg5_csr.sv','microcontroller/tests/drg5_counters_tb.sv',
             'microcontroller/tests/drg5_csr_formal.sv','microcontroller/tests/run_counters.py']
    before={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in sources}
    # failed attempts remain reproducible after a later source correction.
    for name in sources:
        target=attempt/'sources'/name; target.parent.mkdir(parents=True,exist_ok=True); shutil.copyfile(root/name,target)
    (attempt/'source-sha256.json').write_text(json.dumps(before,indent=2)+'\n')
    command=[args.verilator,'--binary','--timing','--assert','-Wall','-j','2','-CFLAGS','-O0',
             '--top-module','drg5_counters_tb','--Mdir',str(build/'obj'),*sources[:2]]
    result=execute(command,attempt/'build.log',root,600)
    assert result.returncode==0 and '%Warning' not in result.stdout,str(attempt/'build.log')
    results=[]; seeds=[1] if args.smoke else [0,1,305419896]
    # each deterministic generator seed retains a complete independently replayable event stream.
    for seed in seeds:
        ledger=attempt/f'seed-{seed}.csv'
        command=[str(build/'obj/Vdrg5_counters_tb'),'+verilator+seed+1',f'+seed={seed}',f'+ledger={ledger}']
        result=execute(command,attempt/f'seed-{seed}.log',root)
        marker=f'COUNTERS_PASS seed={seed} '
        assert result.returncode==0 and result.stdout.count(marker)==1,str(attempt/f'seed-{seed}.log')
        terminal=next(line for line in result.stdout.splitlines() if line.startswith(marker))
        replay=replay_ledger(ledger)
        results.append({'seed':seed,'command':command,'terminal':terminal,'exit_code':result.returncode,'python_replay':replay})
        print(terminal,flush=True)
    detectors=[('mutate_carry','COUNTER_CHECK_FAILED cycle ledger'),('mutate_debug','COUNTER_CHECK_FAILED cycle ledger'),
               ('mutate_trap','COUNTER_CHECK_FAILED retirement ledger'),('mutate_write','COUNTER_CHECK_FAILED retirement ledger'),
               ('mutate_suppression','COUNTER_CHECK_FAILED suppressed or pre-retirement read')]
    # intended corruptions must fail an ordinary comparator rather than an unrelated assertion.
    if not args.smoke:
        # preserve each detector's exact command and failing edge history.
        for name,marker in detectors:
            command=[str(build/'obj/Vdrg5_counters_tb'),'+verilator+seed+1','+seed=1','+'+name]
            result=execute(command,attempt/f'{name}.log',root)
            assert result.returncode!=0 and marker in result.stdout and 'COUNTERS_PASS' not in result.stdout,name
            results.append({'negative_control':name,'command':command,'exit_code':result.returncode,'detector':marker})
    structures=[]; proofs=[]
    # the unchanged normalized CSR proof exercises arbitrary values and event collisions.
    if not args.smoke:
        # both IALIGN selections retain all seven assertions and both caller assumptions.
        for compressed,mutation in [(0,0),(1,0),(1,1)]:
            name=f'proof-c{compressed}'+('-negative' if mutation else '')
            script=(f'read_verilog -formal -sv -D SYNTHESIS {sources[0]} {sources[2]}; '
                    f'chparam -set C_ENABLED {compressed} -set MUTATE_COUNTER {mutation} drg5_csr_formal; '
                    'prep -top drg5_csr_formal -flatten; async2sync; chformal -lower; check -assert; '
                    'select -assert-count 7 t:$assert; select -assert-count 2 t:$assume; '
                    'sat -seq 4 -tempinduct -prove-asserts -set-assumes -verify -show-inputs -timeout 90')
            command=[args.yosys,'-Q','-T','-p',script]
            result=execute(command,attempt/f'{name}.log',root)
            # mutation requires a counterexample, while positive profiles require induction success.
            if mutation:
                assert result.returncode!=0 and 'ERROR: Called with -verify and proof did fail!' in result.stdout,name
            # success must establish induction rather than only a finite base case.
            else:
                assert result.returncode==0 and 'Induction step proven: SUCCESS!' in result.stdout and 'Warning:' not in result.stdout,name
            proofs.append({'name':name,'command':command,'exit_code':result.returncode,'expected_terminal_seen':True})
        # native mapping separately checks latch absence and recognized FPGA primitives.
        for compressed in [0,1]:
            name=f'map-c{compressed}'; netlist=build/f'{name}.json'
            script=(f'read_verilog -sv -D SYNTHESIS {sources[0]}; chparam -set C_ENABLED {compressed} drg5_csr; '
                    'hierarchy -check -top drg5_csr; proc; opt; check -assert; select -assert-none t:$dlatch t:$adlatch; '
                    f'synth_ecp5 -noabc9 -top drg5_csr -json {netlist}; check -assert; stat')
            command=[args.yosys,'-Q','-T','-p',script]; result=execute(command,attempt/f'{name}.log',root)
            allowed={'ABC: Warning: The network is combinational (run "fraig" or "fraig_sweep").'}
            warnings=[line for line in result.stdout.splitlines() if 'Warning:' in line and line not in allowed]
            assert result.returncode==0 and not warnings and 'ERROR:' not in result.stdout,name
            data=netlist.read_bytes(); cells=Counter(cell['type'] for cell in json.loads(data)['modules']['drg5_csr']['cells'].values())
            assert not set(cells)-{'LUT4','L6MUX21','PFUMX','CCU2C','TRELLIS_FF'},cells
            (attempt/f'{name}.json.gz').write_bytes(gzip.compress(data,mtime=0))
            structures.append({'c_enabled':compressed,'command':command,'cells':dict(sorted(cells.items())),
                               'netlist_sha256':hashlib.sha256(data).hexdigest()})
    assert before=={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in sources},'sources changed'
    summary={'status':'passed','smoke':args.smoke,'source_sha256':before,'revision':str(attempt.relative_to(evidence)),
             'results':results,'proofs':proofs,'structural':structures,
             'versions':{'verilator':subprocess.check_output([args.verilator,'--version'],text=True).strip(),
                         'yosys':subprocess.check_output([args.yosys,'-V'],text=True).strip()},
             'scope':'normalized machine CSR bank counter behavior; both C settings; synthetic execution/debug event records',
             'formal_assumptions':['first clock resets bank','non-reset trap cause belongs to implemented caller contract'],
             'limits':['no architectural debug controller or halt/step execution qualification',
                       'encoded pipeline CSR suppression and real compressed retirement are separate integration checks',
                       'native component mapping is not whole-core routing or clock qualification']}
    (attempt/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    (evidence/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print('COUNTERS_QUALIFICATION_PASS smoke='+str(args.smoke),flush=True)


# importing the runner never starts tools or changes evidence.
if __name__=='__main__':
    main()
