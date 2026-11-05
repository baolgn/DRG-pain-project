#!/usr/bin/env python3
"""replay retained compressed RTL and Sail captures without rebuilding the simulator."""
import gzip
import hashlib
import json
from pathlib import Path
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'microcontroller/verification/execution'))
from comparison import read_dut,read_sail,compare


# exact bytes identify both the checker and every retained capture it consumes.
def digest(path):
    """return the complete SHA-256 of an input file."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


# archived evidence must replay independently of simulator binaries or temporary build trees.
def main():
    """check all published random-program captures and preserve their replay result."""
    evidence=ROOT/'microcontroller/verification/evidence/verification-2026-11-04/execution'
    summary_path=evidence/'summary.json';summary=json.loads(summary_path.read_text())
    totals={'captures':0,'instructions':0,'bus_transactions':0};artifacts={str(summary_path.relative_to(ROOT)):digest(summary_path)}
    sources=[Path(__file__).resolve(),ROOT/'microcontroller/verification/execution/comparison.py']
    before={str(path.relative_to(ROOT)):digest(path) for path in sources}
    # every configuration and seed retains its own reference boundary and schema.
    for row in summary['results']:
        directory=ROOT/row['evidence'];schema_path=directory/'trace-schema.json'
        schema=json.loads(schema_path.read_text());symbols=directory/'symbols.log'
        stop_pc=int(next(line.split()[0] for line in symbols.read_text().splitlines() if line.endswith(' reference_stop')),16)
        # decompression uses an isolated directory that is removed after checking.
        with tempfile.TemporaryDirectory(prefix='drg5-replay-') as temporary:
            temporary=Path(temporary)
            # both independently produced streams must survive their lossless archival encoding.
            for name in ['trace.jsonl','sail.trace']:
                archive=directory/(name+'.gz');artifacts[str(archive.relative_to(ROOT))]=digest(archive)
                (temporary/name).write_bytes(gzip.decompress(archive.read_bytes()))
            terminals,footer=read_dut(temporary/'trace.jsonl',schema)
            counts=compare(terminals,read_sail(temporary/'sail.trace'),stop_pc)
            # publication must not change a count or invent a successful capture.
            if counts!=row['comparison']:
                raise ValueError('archived comparison differs from qualified result')
            totals['captures']+=1;totals['instructions']+=counts['instructions']
            totals['bus_transactions']+=footer['i_accepts']+footer['d_accepts']
        artifacts[str(schema_path.relative_to(ROOT))]=digest(schema_path)
        artifacts[str(symbols.relative_to(ROOT))]=digest(symbols)
    # source edits during replay invalidate the checker attribution.
    if before!={str(path.relative_to(ROOT)):digest(path) for path in sources}:
        raise ValueError('replay source changed during execution')
    record={'status':'passed','scope':'independent replay of every retained compressed capture, schema and Sail trace',
            'totals':totals,'source_sha256':before,'artifact_sha256':artifacts,
            'command':['python3','microcontroller/verification/replay_archives.py']}
    (evidence/'archived-replay.json').write_text(json.dumps(record,indent=2)+'\n')
    print('ARCHIVED_REPLAY_PASS '+json.dumps(totals),flush=True)


# imports never decompress or rewrite archived results.
if __name__=='__main__':
    main()
