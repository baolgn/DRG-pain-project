#!/usr/bin/env python3
"""qualify FENCE.I packet-event priorities with retained source and failure evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess


# retain each actual revision before elaboration so later fixes cannot inherit its result.
def main():
    """compile both alignment profiles and verify exact event coverage markers."""
    parser=argparse.ArgumentParser()
    parser.add_argument('--verilator',default='verilator')
    parser.add_argument('--build',type=Path,default=Path('/tmp/drg5-fence-events'))
    parser.add_argument('--evidence-dir',type=Path)
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[2]
    evidence=(args.evidence_dir or root/'microcontroller/tests/evidence/fence-events-2026-11-04').resolve()
    revisions=evidence/'revisions'; revisions.mkdir(parents=True,exist_ok=True)
    revision=max([int(p.name.split('-')[0]) for p in revisions.iterdir() if p.is_dir()]+[0])+1
    attempt=revisions/f'{revision:02d}-qualification'; attempt.mkdir()
    sources=['microcontroller/rtl/drg5_control_pkg.sv']
    sources += [str(p.relative_to(root)) for p in sorted((root/'microcontroller/rtl').glob('*.sv'))
                if p.name!='drg5_control_pkg.sv']
    sources += ['microcontroller/tests/drg5_fence_events_tb.sv']
    names=sources+['microcontroller/rtl/drg5_datapath_defs.svh','microcontroller/tests/run_fence_events.py']
    before={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in names}
    # every run preserves inputs, command lines and diagnostics before evaluating success.
    for name in names:
        target=attempt/'sources'/name; target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(root/name,target)
    (attempt/'source-sha256.json').write_text(json.dumps(before,indent=2)+'\n')
    records=[]
    # the same event sequence must respect both IALIGN choices.
    for compressed in [0,1]:
        build=args.build.resolve()/f'c{compressed}'; build.mkdir(parents=True,exist_ok=True)
        command=[args.verilator,'--binary','--timing','--assert','-Wall','-j','2','-CFLAGS','-O0',
                 '-Imicrocontroller/rtl','--top-module','drg5_fence_events_tb',f'-GC_ENABLED={compressed}',
                 '--Mdir',str(build),*sources]
        log=attempt/f'c{compressed}-build.log'
        # strict warnings and nonzero exits prevent any qualification claim.
        with log.open('w') as stream:
            stream.write('$ '+shlex.join(command)+'\n'); stream.flush()
            result=subprocess.run(command,cwd=root,stdout=stream,stderr=subprocess.STDOUT,timeout=600,check=False)
        assert result.returncode==0 and '%Warning' not in log.read_text(),str(log)
        command=[str(build/'Vdrg5_fence_events_tb'),'+verilator+seed+1']
        result=subprocess.run(command,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=120,check=False)
        (attempt/f'c{compressed}.log').write_text('$ '+shlex.join(command)+'\n'+result.stdout)
        marker=f'FENCE_EVENTS_PASS C={compressed} '
        assert result.returncode==0 and result.stdout.count(marker)==1,str(attempt/f'c{compressed}.log')
        terminal=next(line for line in result.stdout.splitlines() if line.startswith(marker))
        records.append({'c_enabled':compressed,'command':command,'terminal':terminal,'exit_code':result.returncode})
        print(terminal,flush=True)
    # changing even a comment invalidates attribution to this completed invocation.
    assert before=={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in names},'source changed'
    summary={'status':'passed','source_sha256':before,'revision':str(attempt.relative_to(evidence)),
             'results':records,'scope':'packet-event tests; fetch_busy is modeled, not a real frontend'}
    (attempt/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    (evidence/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')


# import preserves this runner without launching tools.
if __name__=='__main__':
    main()
