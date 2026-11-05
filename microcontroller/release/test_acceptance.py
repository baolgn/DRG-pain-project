#!/usr/bin/env python3
"""check plan isolation, output protection and termination without accessing hardware."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('release_acceptance', HERE / 'acceptance.py')
acceptance = importlib.util.module_from_spec(spec); spec.loader.exec_module(acceptance)


class AcceptanceChecks(unittest.TestCase):
    """exercise actual admission and command construction, including rejected inputs."""
    def setUp(self):
        """each fixture owns a fresh scratch directory."""
        self.temp = tempfile.TemporaryDirectory(prefix='drg5-acceptance-test-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)

    def test_fresh_external(self):
        """a new external destination is valid and remains uncreated."""
        path = self.base / 'new'
        self.assertEqual(acceptance.checked_output(path), path)
        self.assertFalse(path.exists())

    def test_existing_rejected(self):
        """an existing output cannot receive another run."""
        # even an empty existing directory is not a fresh result destination.
        with self.assertRaisesRegex(ValueError, 'new path'):
            acceptance.checked_output(self.base)

    def test_unsupported_path_syntax(self):
        """legacy script paths cannot contain whitespace or command punctuation."""
        # these concrete names are rejected before directory creation or execution.
        for name in ['space path', 'semi;colon', 'newline\npath']:
            # every invalid spelling must reach the declared path-admission check.
            with self.assertRaisesRegex(ValueError, 'qualified paths require'):
                acceptance.checked_output(self.base / name)

    def test_checkout_rejected(self):
        """ordinary source and historical evidence directories remain protected."""
        root = self.base / 'checkout'; root.mkdir()
        # a new path under old evidence is still an impermissible output.
        with self.assertRaisesRegex(ValueError, 'repository outputs'):
            acceptance.checked_output(root / 'microcontroller/verification/evidence/new', root)

    def test_checkout_scratch(self):
        """only the named scratch subtree is admitted inside a checkout."""
        root = self.base / 'checkout'; root.mkdir()
        path = root / '.release-runs' / 'new'
        self.assertEqual(acceptance.checked_output(path, root), path)

    def test_sealed_external_rejected(self):
        """a relocated evidence seal also protects nested output paths."""
        (self.base / 'SHA256SUMS').write_text('retained seal\n')
        # external paths cannot bypass an ancestor's evidence seal.
        with self.assertRaisesRegex(ValueError, 'sealed evidence'):
            acceptance.checked_output(self.base / 'new')

    def test_symlink_rejected(self):
        """a linked parent cannot redirect a nominal scratch destination."""
        actual = self.base / 'actual'; actual.mkdir()
        linked = self.base / 'linked'; linked.symlink_to(actual, target_is_directory=True)
        # resolve the destination before admitting any output writes.
        with self.assertRaisesRegex(ValueError, 'symlink'):
            acceptance.checked_output(linked / 'new')

    def test_plan_read_only(self):
        """the real default CLI prints a plan without constructing its output."""
        target = self.base / 'planned'
        result = subprocess.run([sys.executable, str(HERE / 'acceptance.py'), '--output', str(target)],
                                check=True, capture_output=True, text=True)
        report = json.loads(result.stdout)
        self.assertFalse(target.exists())
        self.assertFalse(report['hardware_operations'])
        self.assertEqual([item['name'] for item in report['commands']], acceptance.SUITES['smoke'])

    def test_all_command_boundaries(self):
        """all families write staged outputs and omit hardware and legacy aggregate commands."""
        report = acceptance.plan(self.base / 'new', 'all')
        names = [item['name'] for item in report['commands']]
        self.assertEqual(len(names), len(set(names)))
        self.assertLess(names.index('firmware'), names.index('image'))
        # only inspected runners belong to the fixed acceptance catalog.
        for item in report['commands']:
            text = ' '.join(item['argv'])
            runner = Path(item['argv'][1]).name
            self.assertNotEqual(runner, 'program_board.py')
            self.assertNotEqual(runner, 'run_verification.py')
            self.assertNotEqual(runner, 'run_units.py')
            self.assertIn(str(self.base / 'new'), text)

    def test_fixed_tool_override_rejected(self):
        """a runner with fixed tools cannot claim to have used an override."""
        # mixed CLI support is explicit rather than silently ignored.
        with self.assertRaisesRegex(ValueError, 'fixed OSS CAD'):
            acceptance.plan(self.base / 'new', 'smoke', tools=self.base / 'tools')

    def test_supported_tool_override(self):
        """formal families receive the actual requested tool path."""
        tools = self.base / 'tools'
        report = acceptance.plan(self.base / 'new', 'formal', tools=tools)
        # every formal command exposes and consumes the tool override.
        for entry in report['commands']:
            self.assertEqual(entry['argv'][entry['argv'].index('--tools') + 1], str(tools))

    def test_debug_tool_override(self):
        """the simulated remote debugger receives its explicit GDB runtime wrapper."""
        gdb = self.base / 'gdb-wrapper'
        report = acceptance.plan(self.base / 'new', 'debug', gdb=gdb)
        command = next(item['argv'] for item in report['commands'] if item['name'] == 'debug-remote')
        self.assertEqual(command[command.index('--gdb') + 1], str(gdb))
        self.assertIn('--evidence-dir', command)
        self.assertFalse(report['hardware_operations'])

    def test_inventory_excludes_evidence(self):
        """staging copies active source bytes without recursively importing test records."""
        source = self.base / 'microcontroller/rtl/core.sv'; source.parent.mkdir(parents=True)
        source.write_text('module core; endmodule\n')
        old = self.base / 'microcontroller/tests/evidence/old.py'; old.parent.mkdir(parents=True)
        old.write_text('historical bytes\n')
        (self.base / 'docs').mkdir(parents=True, exist_ok=True)
        inventory = acceptance.source_inventory(self.base)
        self.assertEqual(inventory, {'microcontroller/rtl/core.sv': acceptance.digest(source)})

    def test_active_symlink_rejected(self):
        """an external file cannot enter the staged implementation through a symlink."""
        source = self.base / 'microcontroller/rtl/core.sv'; source.parent.mkdir(parents=True)
        external = self.base / 'outside'; external.write_text('external bytes\n')
        source.symlink_to(external)
        (self.base / 'docs').mkdir(parents=True, exist_ok=True)
        # source admission is strict before any copy or compilation.
        with self.assertRaisesRegex(ValueError, 'active source symlink'):
            acceptance.source_inventory(self.base)

    def test_source_root_symlinks_rejected(self):
        """top-level and ancestor directory links cannot import an external source tree."""
        external = self.base / 'external'; external.mkdir()
        # cover both public input roots and the architecture root's intermediate ancestors.
        for relative in ['microcontroller', 'docs']:
            # each fixture starts with a complete ordinary source-root structure.
            with tempfile.TemporaryDirectory(prefix='rootcase-', dir=self.base) as directory:
                root = Path(directory); (root / 'microcontroller').mkdir()
                (root / 'docs').mkdir(parents=True)
                target = root / relative; shutil.rmtree(target); target.symlink_to(external, target_is_directory=True)
                # rejection occurs before traversing the linked directory's contents.
                with self.assertRaisesRegex(ValueError, 'source root symlink'):
                    acceptance.source_inventory(root)

    def test_executable_mode_preserved(self):
        """a staged tool wrapper retains its executable permission and bytes."""
        source = self.base / 'microcontroller/tool'; source.parent.mkdir(parents=True)
        source.write_text('#!/bin/sh\nexit 0\n'); source.chmod(0o755)
        name = 'microcontroller/tool'; stage = self.base / 'stage'
        modes = acceptance.stage_sources(stage, {name: acceptance.digest(source)}, self.base)
        self.assertEqual(modes[name], 0o755)
        self.assertEqual((stage / name).stat().st_mode & 0o777, 0o755)
        self.assertEqual(subprocess.run([str(stage / name)], check=False).returncode, 0)

    def test_nonzero_retained(self):
        """a native checker failure remains a nonzero recorded result."""
        result = acceptance.invoke([sys.executable, '-c', 'raise SystemExit(7)'], self.base, self.base / 'exit.log', 5)
        self.assertEqual(result['exit_code'], 7)
        self.assertFalse(result['timeout'])

    def test_child_temporary_directory(self):
        """compiler and Python temporaries use the recorded output-owned directory."""
        temporary = self.base / 'owned-temporary'; temporary.mkdir()
        command = 'import pathlib,tempfile;assert pathlib.Path(tempfile.gettempdir())==pathlib.Path(' + repr(str(temporary)) + ')'
        result = acceptance.invoke([sys.executable, '-c', command], self.base, self.base / 'temporary.log', 5,
                                   {'TMPDIR': str(temporary)})
        self.assertEqual(result['exit_code'], 0)

    def test_private_temporary_alias(self):
        """the short alias targets owned storage and cleanup preserves its real data."""
        storage = self.base / 'long-workspace-owned-temporary-directory'; storage.mkdir()
        # the alias must remain literal and short for the pinned ABC server protocol.
        with acceptance.temporary_alias(storage) as alias:
            self.assertTrue(alias.is_symlink())
            self.assertLess(len(str(alias)), 32)
            self.assertEqual(alias.resolve(), storage)
            (alias / 'retained').write_text('owned data')
            parent = alias.parent
        self.assertFalse(parent.exists())
        self.assertEqual((storage / 'retained').read_text(), 'owned data')

    def test_successful_parent_leaking_child(self):
        """an exited parent cannot leave a descendant appending after completion."""
        target = self.base / 'orphan-output'
        child = 'import time,pathlib;time.sleep(1);pathlib.Path(' + repr(str(target)) + ').write_text("late")'
        command = 'import subprocess,time;subprocess.Popen([' + repr(sys.executable) + ',"-c",' + repr(child) + ']);time.sleep(0.1)'
        result = acceptance.invoke([sys.executable, '-c', command], self.base, self.base / 'orphan.log', 5)
        self.assertEqual(result['exit_code'], 125)
        self.assertTrue(result['orphan_group_terminated'])
        subprocess.run([sys.executable, '-c', 'import time;time.sleep(1.1)'], check=True)
        self.assertFalse(target.exists())

    def test_timeout_kills_descendant(self):
        """a child ignoring termination cannot append after the parent deadline."""
        target = self.base / 'late'
        child = 'import signal,time,pathlib;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(1);pathlib.Path(' + repr(str(target)) + ').write_text("late")'
        command = 'import subprocess,time;subprocess.Popen([' + repr(sys.executable) + ',"-c",' + repr(child) + ']);time.sleep(10)'
        result = acceptance.invoke([sys.executable, '-c', command], self.base, self.base / 'timeout.log', 0.2)
        self.assertEqual(result['exit_code'], 124)
        self.assertTrue(result['timeout'])
        subprocess.run([sys.executable, '-c', 'import time;time.sleep(1.1)'], check=True)
        self.assertFalse(target.exists())


def main():
    """retain the real fixture outcomes and exact tested helper bytes."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); output = acceptance.checked_output(args.output)
    output.mkdir(parents=True, exist_ok=False)
    # the complete unittest transcript remains available for failed as well as passing fixtures.
    with (output / 'tests.log').open('w') as stream:
        result = unittest.TextTestRunner(stream=stream, verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(AcceptanceChecks))
    report = {'schema': 'DRG5-RELEASE-ACCEPTANCE-TEST-1', 'status': 'pass' if result.wasSuccessful() else 'fail',
              'cases': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors),
              'source_sha256': {str(path.relative_to(acceptance.ROOT)): acceptance.digest(path)
                  for path in [HERE / 'acceptance.py', Path(__file__).resolve()]},
              'hardware_accessed': False}
    (output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))
    raise SystemExit(0 if result.wasSuccessful() else 1)


# importing fixtures performs no test execution or device access.
if __name__ == '__main__':
    main()
