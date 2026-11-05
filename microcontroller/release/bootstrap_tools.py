#!/usr/bin/env python3
"""install hash-pinned release tools into a fresh user-owned directory."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
COMMIT = 'e7fe80bfcea852562e6561e14fca2e4010cfb5ad'


def digest(path):
    """hash complete artifact bytes before use."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, directory, log, environment):
    """retain one invocation and reject any failed phase."""
    # a command is logged before execution, including a failed installer.
    with log.open('w') as stream:
        stream.write('$ ' + shlex.join(map(str, command)) + '\n')
        stream.flush()
        result = subprocess.run(list(map(str, command)), cwd=directory,
                                env=environment, stdout=stream, stderr=subprocess.STDOUT)
    # process success is necessary, but final independent smoke checks still follow.
    if result.returncode:
        raise RuntimeError(f'command failed ({result.returncode}): {log}')


def acquire(item, cache, destination, download, logs, environment):
    """resolve an exact cached file or fetch its recorded HTTPS URL."""
    name = item['file']
    # artifact names cannot escape the fresh installation cache.
    if Path(name).name != name or not item['url'].startswith('https://'):
        raise ValueError('invalid artifact name or URL')
    candidates = [directory / name for directory in cache]
    source = next((path for path in candidates if path.is_file()), None)
    # an offered cache file with incorrect bytes is never replaced silently.
    if source:
        # reject the supplied copy instead of silently fetching another artifact.
        if digest(source) != item['sha256']:
            raise ValueError('cache checksum mismatch: ' + str(source))
        shutil.copyfile(source, destination)
    # network access is explicit; HTTPS failures cannot become missing-file skips.
    elif download:
        run(['curl', '--fail', '--location', '--retry', '2', '--proto', '=https',
             '--tlsv1.2', '--output', destination, item['url']], destination.parent,
            logs / (name + '.download.log'), environment)
    # offline mode must contain every artifact needed by this installation.
    else:
        raise FileNotFoundError('missing cached artifact: ' + name)
    # redirects and mutable release tags do not override the frozen digest.
    if digest(destination) != item['sha256']:
        raise ValueError('download checksum mismatch: ' + name)


def wrappers(arch):
    """bind the private ruby interpreter and gems to the selected install prefix."""
    directory = arch / 'bin'
    directory.mkdir(parents=True, exist_ok=True)
    prefix = str(arch / 'ruby/usr')
    ruby_libs = [prefix + suffix for suffix in ['/lib/ruby/vendor_ruby', '/lib/ruby/3.3.0',
                 '/lib/x86_64-linux-gnu/ruby/3.3.0', '/lib/x86_64-linux-gnu/ruby/vendor_ruby/3.3.0']]
    body = '#!/bin/sh\n# select the pinned ruby runtime and private gem directories.\n'
    body += 'export LD_LIBRARY_PATH=' + shlex.quote(prefix + '/lib/x86_64-linux-gnu') + '\n'
    body += 'export RUBYLIB=' + shlex.quote(':'.join(ruby_libs)) + '\n'
    body += 'export GEM_HOME=' + shlex.quote(str(arch / 'gems')) + '\n'
    body += 'export GEM_PATH=' + shlex.quote(str(arch / 'gems') + ':' + prefix + '/share/rubygems-integration/all') + '\n'
    body += 'exec ' + shlex.quote(prefix + '/bin/ruby3.3') + ' "$@"\n'
    # both interpreter names are used by upstream executable shebangs.
    for name in ['ruby', 'ruby3.3']:
        path = directory / name
        path.write_text(body)
        path.chmod(0o755)
    bundle = directory / 'bundle'
    bundle.write_text('#!/bin/sh\n# execute the pinned bundler with the private ruby runtime.\nexec ' +
                      shlex.quote(str(directory / 'ruby')) + ' ' +
                      shlex.quote(str(arch / 'gems/bin/bundle')) + ' "$@"\n')
    bundle.chmod(0o755)


def install(args, report):
    """unpack verified tools, build private dependencies and validate the CPU profile."""
    lock = json.loads(args.manifest.read_text())
    prefix = args.root
    logs = prefix / 'logs'
    logs.mkdir(parents=True)
    cache = prefix / 'cache'
    cache.mkdir()
    environment = os.environ.copy()
    temporary = prefix / 'tmp'
    temporary.mkdir()
    environment['TMPDIR'] = str(temporary)
    report['dependency_manifest_sha256'] = digest(args.manifest)
    report['bootstrap_source_sha256'] = digest(Path(__file__))
    report['downloads'] = {}
    # each archive and dependency is checked before extraction or execution.
    for item in lock['downloads']:
        archive = cache / item['file']
        acquire(item, args.cache, archive, args.download, logs, environment)
        destination = (prefix / item['target']).resolve()
        # install destinations remain inside the explicitly selected prefix.
        if not destination.is_relative_to(prefix):
            raise ValueError('target escapes installation prefix')
        kind = item['kind']
        # Python's data filter rejects escaping links and special-device members.
        if kind == 'tar':
            destination.mkdir(parents=True, exist_ok=True)
            # only regular data and internal links from the verified archive are unpacked.
            with tarfile.open(archive) as package:
                package.extractall(destination, filter='data')
            # ACT4 verifies the original three archives as well as extracted executables.
            if item['file'] in ['gcc.tar.gz', 'sail.tar.gz', 'act4.tar.gz']:
                shutil.copyfile(archive, prefix / 'arch' / item['file'])
        # extraction does not install packages into the operating system.
        elif kind == 'deb':
            destination.mkdir(parents=True, exist_ok=True)
            run(['dpkg-deb', '--extract', archive, destination], prefix,
                logs / (item['file'] + '.extract.log'), environment)
        # immutable executable assets occupy their versioned UDB cache locations.
        elif kind == 'file':
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(archive, destination)
            destination.chmod(0o755)
        # wheels and gems are installed offline from their verified cache bytes.
        elif kind in ['wheel', 'gem']:
            destination.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(archive, destination / item['file'])
        # unexpected artifact kinds require a reviewed installer change.
        else:
            raise ValueError('unsupported artifact kind: ' + kind)
        report['downloads'][item['file']] = digest(archive)
    arch = prefix / 'arch'
    act4 = arch / 'act4' / ('riscv-arch-test-' + COMMIT)
    data = act4 / 'framework/src/act/data'
    wrappers(arch)
    environment.update(PATH=os.pathsep.join(map(str, [arch / 'venv/bin', arch / 'bin'])) + os.pathsep + environment['PATH'],
                       XDG_DATA_HOME=str(arch / 'xdg-data'), XDG_CACHE_HOME=str(arch / 'xdg-cache'),
                       BUNDLE_USER_HOME=str(arch / 'bundle-user'), BUNDLE_PATH=str(arch / 'gems'))
    run([args.python, '-m', 'venv', arch / 'venv'], prefix, logs / 'python-venv.log', environment)
    python = arch / 'venv/bin/python'
    wheels = sorted((prefix / 'wheels').glob('*.whl'))
    run([python, '-m', 'pip', 'install', '--no-index', '--no-deps', *wheels], prefix,
        logs / 'python-wheels.log', environment)
    # upstream package builds use the newly pinned backend without dependency downloads.
    for name in ['framework', 'generators/coverage', 'generators/testgen']:
        run([python, '-m', 'pip', 'install', '--no-index', '--no-deps', '--no-build-isolation',
             '-e', act4 / name], prefix, logs / (name.replace('/', '-') + '.install.log'), environment)
    run([python, '-m', 'pip', 'check'], prefix, logs / 'python-check.log', environment)
    run([arch / 'bin/ruby', arch / 'ruby/usr/bin/gem', 'install', '--local', '--no-document',
         '--ignore-dependencies', cache / 'bundler-4.0.23.gem'], prefix, logs / 'bundler-install.log', environment)
    # a private lock copy can record the local ruby version without changing archived ACT4 input.
    bundle = arch / 'bundle-project'
    bundle.mkdir()
    # preserve the original upstream bytes for later source verification.
    for name in ['Gemfile', 'Gemfile.lock']:
        shutil.copyfile(data / name, bundle / name)
    gem_cache = bundle / 'vendor/cache'
    gem_cache.mkdir(parents=True)
    # bundler's offline resolver reads uninstalled packages from the project cache.
    for package in sorted(cache.glob('*.gem')):
        shutil.copyfile(package, gem_cache / package.name)
    environment['BUNDLE_GEMFILE'] = str(bundle / 'Gemfile')
    run([arch / 'bin/bundle', 'install', '--local'], bundle, logs / 'gems-install.log', environment)
    environment['BUNDLE_GEMFILE'] = str(data / 'Gemfile')
    run([arch / 'bin/bundle', 'check'], prefix, logs / 'bundle-check.log', environment)
    run([arch / 'bin/bundle', 'exec', 'udb', 'validate', 'cfg',
         ROOT / 'microcontroller/verification/act4/drg5.yaml'], prefix, logs / 'udb-validate.log', environment)
    # package setup must leave the immutable upstream lock untouched.
    if digest(data / 'Gemfile.lock') != lock['upstream_Gemfile_lock_sha256']:
        raise ValueError('upstream ACT4 lock changed during bootstrap')
    binary = prefix / 'bin'
    binary.mkdir()
    debugger = binary / 'gdb-multiarch'
    debugger.write_text('#!/bin/sh\n# keep GDB data and native Python libraries aligned.\nunset PYTHONHOME PYTHONPATH\nexec ' +
                        shlex.quote(str(prefix / 'gdb/usr/bin/gdb-multiarch')) + ' --data-directory=' +
                        shlex.quote(str(prefix / 'gdb/usr/share/gdb')) + ' "$@"\n')
    debugger.chmod(0o755)
    checks = {'verilator': [prefix / 'oss-cad-suite/bin/verilator', '--version'],
              'yosys-slang': [prefix / 'oss-cad-suite/bin/yosys', '-Q', '-T', '-m', 'slang', '-p', 'help read_slang'],
              'gcc': [arch / 'gcc/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-gcc', '--version'],
              'gdb': [debugger, '-q', '-nx', '-batch', '-iex', 'set auto-load off',
                      '-ex', 'set architecture riscv:rv32', '-ex', 'set osabi none',
                      '-ex', 'python import sys; print(sys.version)', '-ex', 'show data-directory'],
              'sail': [arch / 'sail/sail-riscv-Linux-x86_64/bin/sail_riscv_sim', '--config',
                       ROOT / 'microcontroller/verification/act4/sail.json', '--validate-config']}
    # launches and actual profile validation supplement version banners.
    for name, command in checks.items():
        run(command, prefix, logs / (name + '.log'), environment)
    report['status'] = 'bootstrap-and-profile-validation-pass'
    report['clean_machine_qualified'] = False
    report['full_architectural_suite_pass'] = False
    report['installed_root'] = str(prefix)
    report['python_version'] = subprocess.check_output([python, '--version'], text=True).strip()
    report['log_sha256'] = {str(path.relative_to(prefix)): digest(path) for path in sorted(logs.glob('*'))}


def main():
    """refuse existing prefixes and leave a failed bootstrap's evidence intact."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--cache', type=Path, action='append', default=[])
    parser.add_argument('--download', action='store_true')
    parser.add_argument('--python', type=Path, default=Path('/usr/bin/python3'))
    args = parser.parse_args()
    args.root = args.root.resolve()
    # an existing prefix can contain independently qualified tools and is never overwritten.
    if args.root.exists():
        raise SystemExit('bootstrap requires a nonexistent --root directory')
    args.root.mkdir(parents=True)
    report = {'status': 'failed', 'hardware_accessed': False, 'system_packages_installed': False}
    # retain partial acquisition and logs when any dependency or validation fails.
    try:
        install(args, report)
    # preserve the actual failed phase instead of emitting a setup pass.
    except Exception as error:
        report['error'] = str(error)
        raise
    # final status remains available even when an installation step raises.
    finally:
        (args.root / 'bootstrap.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print('BOOTSTRAP_PASS ' + str(args.root / 'bootstrap.json'))


# importing the installer never downloads files or creates tool aliases.
if __name__ == '__main__':
    main()
