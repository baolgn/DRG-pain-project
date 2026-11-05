#!/usr/bin/env python3
"""qualify observation alignment and explicit capture exhaustion with retained evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess


# preserve failing and passing attempts independently before any tool runs.
def main():
    """run normal and reduced-width captures with calibrated detector failures."""
    parser=argparse.ArgumentParser()
    parser.add_argument('--verilator',default='verilator')
    parser.add_argument('--build',type=Path,default=Path('/tmp/drg5-observe'))
    parser.add_argument('--evidence-dir',type=Path)
    args=parser.parse_args(); root=Path(__file__).resolve().parents[2]
    evidence=(args.evidence_dir or root/'microcontroller/tests/evidence/observe-2026-11-04').resolve()
    revisions=evidence/'revisions'; revisions.mkdir(parents=True,exist_ok=True)
    index=max([int(p.name.split('-')[0]) for p in revisions.iterdir() if p.is_dir()]+[0])+1
    attempt=revisions/f'{index:02d}-qualification'; attempt.mkdir()
    sources=['microcontroller/rtl/drg5_control_pkg.sv','microcontroller/rtl/drg5_observe.sv',
             'microcontroller/tests/drg5_observe_tb.sv']
    names=sources+['microcontroller/tests/run_observe.py']
    hashes={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in names}
    # attribution uses the exact source seen before build rather than a later replacement.
    for name in names:
        dest=attempt/'sources'/name; dest.parent.mkdir(parents=True,exist_ok=True); shutil.copyfile(root/name,dest)
    (attempt/'source-sha256.json').write_text(json.dumps(hashes,indent=2)+'\n')
    results=[]
    # one default capture and three independently reduced identities exercise each loss policy.
    for profile in range(4):
        build=args.build.resolve()/f'p{profile}'; build.mkdir(parents=True,exist_ok=True)
        command=[args.verilator,'--binary','--timing','--assert','-Wall','-j','2','-CFLAGS','-O0',
                 '--top-module','drg5_observe_tb',f'-GPROFILE={profile}','--Mdir',str(build),*sources]
        log=attempt/f'p{profile}-build.log'
        # fatal warnings preserve strict HDL acceptance without waivers.
        with log.open('w') as stream:
            stream.write('$ '+shlex.join(command)+'\n'); stream.flush()
            result=subprocess.run(command,cwd=root,stdout=stream,stderr=subprocess.STDOUT,timeout=300,check=False)
        assert result.returncode==0 and '%Warning' not in log.read_text(),str(log)
        # deterministic xorshift seeds change every sampled payload field.
        for seed in [0,1,305419896]:
            command=[str(build/'Vdrg5_observe_tb'),'+verilator+seed+1',f'+seed={seed}']
            result=subprocess.run(command,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=60,check=False)
            log=attempt/f'p{profile}-seed{seed}.log'; log.write_text('$ '+shlex.join(command)+'\n'+result.stdout)
            marker=f'OBSERVE_PASS profile={profile} seed={seed} '
            assert result.returncode==0 and result.stdout.count(marker)==1,str(log)
            terminal=next(line for line in result.stdout.splitlines() if line.startswith(marker))
            results.append({'profile':profile,'seed':seed,'command':command,'exit_code':0,'terminal':terminal})
            print(terminal,flush=True)
    cases=[(0,'mutate_phase','pre-state and post-state alignment'),
           (0,'mutate_retired','independent normal-retirement count'),
           (1,'mutate_overflow','capture loss policy'),
           (0,'unsafe_rearm','observation rearm requires isolated cold reset')]
    # each intentional defect must fail its actual comparator, not a timeout or generic crash.
    for profile,flag,detector in cases:
        command=[str(args.build.resolve()/f'p{profile}'/'Vdrg5_observe_tb'),'+verilator+seed+1','+seed=1','+'+flag]
        result=subprocess.run(command,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=60,check=False)
        log=attempt/(flag+'.log'); log.write_text('$ '+shlex.join(command)+'\n'+result.stdout)
        assert result.returncode!=0 and detector in result.stdout and 'OBSERVE_PASS ' not in result.stdout,str(log)
        results.append({'negative_control':flag,'detector':detector,'command':command,'exit_code':result.returncode})
    assert hashes=={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in names},'source changed'
    summary={'status':'passed','revision':str(attempt.relative_to(evidence)),'source_sha256':hashes,'results':results,
             'scope':'observation adapter synthetic phase/identity tests; core and CSR semantics are qualified separately'}
    (attempt/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    (evidence/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')


# importing helpers never launches simulations.
if __name__=='__main__':
    main()
