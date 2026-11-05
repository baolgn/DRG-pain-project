#!/usr/bin/env python3
"""run the verification families together and report their evidence without a blanket pass."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[2]
EVIDENCE=ROOT/'microcontroller/verification/evidence/verification-2026-11-04'


# each command keeps its own failure semantics and a retained complete transcript.
def invoke(name,command,directory):
    """run one family while allowing independent families to finish after a failure."""
    log=directory/(name+'.log')
    # the saved command and complete output are sufficient to repeat the same invocation.
    with log.open('w') as stream:
        stream.write('$ '+shlex.join(command)+'\n');stream.flush()
        process=subprocess.run(command,cwd=ROOT,stdout=stream,stderr=subprocess.STDOUT,check=False)
    print(f'VERIFICATION_FAMILY {name} exit={process.returncode} log={log}',flush=True)
    return {'name':name,'command':command,'exit_code':process.returncode,'log':str(log.relative_to(ROOT))}


# collection is a separate evidence operation and cannot be confused with executing tests.
def collect(directory,runs):
    """summarize individual requirement gates after the independent integrity audit."""
    comments=invoke('comments',[sys.executable,str(EVIDENCE/'comment-audit/run.py')],directory)
    runs.append(comments)
    audit=invoke('audit',[sys.executable,'microcontroller/verification/audit.py'],directory)
    runs.append(audit)
    ledger=json.loads((ROOT/'microcontroller/verification/requirements.json').read_text())
    requirements=ledger['requirements'];catalog=ledger['evidence'];entries=[]
    # absent evidence is an explicit missing record, never an implicit successful test.
    for key,entry in catalog.items():
        path=ROOT/entry['path']
        record=json.loads(path.read_text()) if path.is_file() else {}
        entries.append({'id':key,'path':entry['path'],'kind':entry['kind'],
                        'declared_status':entry.get('status','unspecified'),
                        'observed_status':record.get('status','scoped_results_without_global_status') if path.is_file() else 'missing'})
    open_gates=[{'id':item['id'],'requirement':item['requirement'],'limits':item['limits']}
                for item in requirements if item['release_gate']=='open' or item['release_gate'].startswith('failed')]
    report={'status':'evidence_consistent' if audit['exit_code']==0 else 'evidence_inconsistent',
            'release_qualified':False,'mode':'executed_and_collected' if any(item['name'] not in ('audit','comments') for item in runs) else 'collected_existing_evidence',
            'commands':runs,'requirements':len(requirements),'evidence':entries,'open_release_gates':open_gates,
            'scope':'individual fresh checks, attributed historical reuse and explicit open qualification gates',
            'interpretation':'zero audit exit establishes evidence integrity only; underlying failures and bounded scopes remain authoritative'}
    path=directory/'summary.json';path.write_text(json.dumps(report,indent=2)+'\n')
    shutil.copyfile(path,EVIDENCE/'summary.json')
    print(f'VERIFICATION_EVIDENCE requirements={len(requirements)} open_release_gates={len(open_gates)} '
          f'integrity_exit={audit["exit_code"]} release_qualified=false',flush=True)
    return audit['exit_code']


# the default workflow executes suites; --collect only audits already retained results.
def main():
    """retain every family outcome, including partial architectural qualification."""
    parser=argparse.ArgumentParser()
    parser.add_argument('--build',type=Path,default=Path('/tmp/drg5-verification'))
    parser.add_argument('--collect',action='store_true')
    args=parser.parse_args();args.build=args.build.resolve();args.build.mkdir(parents=True,exist_ok=True)
    tools=Path('/tmp/drg5-control-tools-20260301/oss-cad-suite');arch_tools=Path('/tmp/drg5-arch-tools')
    stamp=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    directory=EVIDENCE/'campaigns'/stamp;directory.mkdir(parents=True)
    runs=[]
    # serialized builds avoid quota pressure while all checks share the same production sources.
    if not args.collect:
        python=sys.executable;verilator=str(tools/'bin/verilator');yosys=str(tools/'bin/yosys')
        commands=[('units',[python,'microcontroller/verification/run_units.py']),
                  ('directed',[python,'microcontroller/verification/run_directed.py','--build',str(args.build/'directed'),
                               '--verilator',verilator,'--yosys',yosys]),
                  ('counters',[python,'microcontroller/tests/run_counter_execution.py','--build',str(args.build/'counters'),
                               '--verilator',verilator,'--evidence-dir',str(EVIDENCE/'counter-execution')]),
                  ('random-sail',[python,'microcontroller/verification/execution/run_random.py','--build',str(args.build/'random'),
                                  '--verilator',verilator]),
                  ('formal',[python,'microcontroller/verification/formal/run_formal.py','--tools',str(tools),
                             '--build',str(EVIDENCE/'formal'/('campaign-'+stamp))]),
                  ('formal-admission',[python,'microcontroller/verification/formal/run_admission_formal.py',
                                       '--tools',str(tools),'--build',str(EVIDENCE/'formal'/('admission-campaign-'+stamp))]),
                  ('act4',[python,'microcontroller/verification/act4/run_campaign.py','--tools',str(arch_tools),
                           '--work',str(args.build/('act4-'+stamp)),'--build',str(args.build/'act4-simulator'),
                           '--evidence',str(EVIDENCE/'act4'/'campaigns'/stamp)]),
                  ('reuse',[python,'microcontroller/verification/run_reuse_audit.py'])]
        # failed suites do not prevent unrelated directed, reference or formal evidence collection.
        for name,command in commands:
            runs.append(invoke(name,command,directory))
            # catalog paths retain each aggregate's own base for relative artifact references.
            if name in ('formal','formal-admission','act4'):
                locations={'formal':EVIDENCE/'formal'/('campaign-'+stamp)/'summary.json',
                           'formal-admission':EVIDENCE/'formal'/('admission-campaign-'+stamp)/'summary.json',
                           'act4':EVIDENCE/'act4'/'campaigns'/stamp/'manifest.json'}
                produced=locations[name]
                # a missing result cannot silently preserve an older passing catalog entry.
                if not produced.is_file():
                    produced.parent.mkdir(parents=True,exist_ok=True)
                    produced.write_text(json.dumps({'status':'infrastructure_failed','command':command})+'\n')
                ledger_path=ROOT/'microcontroller/verification/requirements.json'
                ledger=json.loads(ledger_path.read_text())
                ledger['evidence'][name]['path']=str(produced.relative_to(ROOT))
                ledger['evidence'][name]['status']=json.loads(produced.read_text()).get('status','unspecified')
                ledger_path.write_text(json.dumps(ledger,indent=2)+'\n')
            (directory/'commands.json').write_text(json.dumps(runs,indent=2)+'\n')
    integrity=collect(directory,runs)
    # full execution is strict: even a documented ACT4 gap leaves a nonzero overall test status.
    raise SystemExit(1 if integrity or any(item['exit_code'] for item in runs) else 0)


# importing the orchestrator cannot run or overwrite a verification campaign.
if __name__=='__main__':
    main()
