#!/usr/bin/env python3
"""bind every ACT4 candidate and built artifact to an explicit disposition."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re

from act.parse_test_constraints import generate_test_dict
from act.parse_udb_config import get_config_params
from act.select_tests import check_test_extensions, check_test_params
from ruamel.yaml import YAML


# fingerprints distinguish changed inputs even when test names are reused.
def digest(path):
    """return the SHA-256 of an existing artifact."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


# selection uses the pinned ACT4 predicates rather than a separate ISA guess.
def main():
    """record exclusions, capacity failures, reference failures and available ELFs."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--tests', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--build-log', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    config_path = Path(__file__).with_name('drg5.yaml')
    config = YAML(typ='safe').load(config_path.read_text())
    extensions = frozenset(item['name'] for item in config['implemented_extensions'])
    params = get_config_params(config_path)
    records = []
    log = args.build_log.read_text()
    failures = {}
    # each failing DAG output has its own diagnostic and reproducible command in the log.
    for block in re.split(r'✗ FAILED:', log)[1:]:
        found = re.search(r'Output: ([^\n]+)', block)
        # setup failures without an output remain visible in the complete log.
        if found:
            failures[found.group(1).strip()] = block.split('Reproduce with:')[0].strip()
    # the inventory includes every candidate present in the selected source catalog.
    for name, meta in sorted(generate_test_dict(args.tests, 'all').items()):
        item = {'test': name, 'source_sha256': digest(meta.test_path)}
        applicable = check_test_extensions(meta.required_extensions, meta.forbidden_extensions, extensions)
        # unsupported extensions and forbidden combinations are explicit exclusions.
        if not applicable:
            item.update(status='not_applicable', reason='extension constraints',
                        required=sorted(str(x) for x in meta.required_extensions),
                        forbidden=sorted(meta.forbidden_extensions))
        # privilege, XLEN and implementation parameters further constrain applicability.
        elif not check_test_params(meta.params, params) or meta.min_harts > 1:
            item.update(status='not_applicable', reason='parameter or hart constraints',
                        required_params=meta.params, minimum_harts=meta.min_harts)
        # applicable tests require their generated reference and DUT artifacts.
        else:
            elf = args.work / 'elfs' / Path(name).with_suffix('.elf')
            reference = args.work / 'build' / Path(name).with_suffix('.sig.elf')
            signature = reference.with_suffix('')
            # a built self-checking ELF is availability evidence, never a DUT verdict.
            if elf.exists():
                item.update(status='built', elf=str(elf), elf_sha256=digest(elf))
                # signature-based tests require the actual reference execution artifact.
                if meta.needs_signature:
                    item.update(reference_elf_sha256=digest(reference), signature_sha256=digest(signature))
            # missing ELFs retain the failed compilation or reference diagnostic.
            else:
                diagnostic = failures.get(str(reference), failures.get(str(elf), 'missing output; inspect build log'))
                status = 'capacity_rejected' if ('exceed' in diagnostic or 'will not fit' in diagnostic) else 'build_or_reference_failed'
                item.update(status=status, diagnostic=diagnostic)
        records.append(item)
    report = {'config_sha256': digest(config_path), 'build_log_sha256': digest(args.build_log),
              'test_catalog': str(args.tests), 'counts': dict(Counter(x['status'] for x in records)),
              'records': records}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print(json.dumps(report['counts'], sort_keys=True))


# imports expose no filesystem mutation.
if __name__ == '__main__':
    main()
