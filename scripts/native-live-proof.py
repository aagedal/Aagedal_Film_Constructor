#!/usr/bin/env python3
"""Build the isolated native live monitor with explicitly selected local libraries.

This records development linkage, not device latency or display conformance.
--launch opens a standalone AppKit window; close it to finish the recorded run.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pkg-config', type=Path, required=True)
    parser.add_argument('--project', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--launch', action='store_true')
    args = parser.parse_args()
    pkg = args.pkg_config.resolve(strict=True)
    project = args.project.resolve(strict=True)
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    repo = Path(__file__).resolve().parent.parent
    env = os.environ.copy()
    env['PATH'] = str(pkg.parent) + os.pathsep + env.get('PATH', '')
    env['CLANG_MODULE_CACHE_PATH'] = str(output / 'module-cache')
    env['SWIFTPM_MODULECACHE_OVERRIDE'] = str(output / 'module-cache')
    libraries = ['libavformat', 'libavcodec', 'libavutil', 'libswscale', 'libswresample']
    flags = []
    for option, forwarded in [('--cflags', '-Xcc'), ('--libs', '-Xlinker')]:
        values = subprocess.check_output([str(pkg), option, *libraries], env=env, text=True)
        for item in shlex.split(values):
            flags += [forwarded, item]
    common = ['--package-path', str(repo / 'Packages/NativePlaybackProof'),
              '--scratch-path', str(output / 'build'), '--cache-path', str(output / 'cache'),
              '--disable-sandbox', *flags]
    commands = [['swift', 'build', '--product', 'NativeLiveProof', *common],
                ['swift', 'test', *common]]
    manifest = {'commands': commands, 'project': str(project),
                'projectSHA256': hashlib.sha256(project.read_bytes()).hexdigest(),
                'hardwareQualified': False, 'launched': False}
    for command, log in zip(commands, ['build.log', 'tests.log']):
        with (output / log).open('w') as handle:
            subprocess.run(command, env=env, stdout=handle, stderr=subprocess.STDOUT, check=True)
    executable = output / 'build/debug/NativeLiveProof'
    manifest['executableSHA256'] = hashlib.sha256(executable.read_bytes()).hexdigest()
    manifest['dependencies'] = subprocess.check_output(['otool', '-L', str(executable)], text=True)
    dependencies = {}
    for library in libraries:
        libdir = Path(subprocess.check_output([str(pkg), '--variable=libdir', library], env=env, text=True).strip())
        dylib = (libdir / (library + '.dylib')).resolve(strict=True)
        dependencies[library] = {'path': str(dylib), 'sha256': hashlib.sha256(dylib.read_bytes()).hexdigest()}
    manifest['libraries'] = dependencies
    manifest_path = output / 'manifest.json'
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    launch = [str(executable), str(project)]
    print(shlex.join(launch), flush=True)
    if args.launch:
        manifest['launched'] = True
        with (output / 'live-observations.log').open('w') as handle:
            result = subprocess.run(launch, env=env, stdout=handle, stderr=subprocess.STDOUT)
        manifest['exitCode'] = result.returncode
        manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
        raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
