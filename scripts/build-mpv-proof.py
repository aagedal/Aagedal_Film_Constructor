#!/usr/bin/env python3
"""Build a development-only headless MPV from an explicit local Git checkout.

Uses installed dependencies without downloading, installing, or changing the
source checkout. This does not produce a redistributable app media bundle.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('meson', type=Path)
    parser.add_argument('ninja', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if not args.source.is_absolute() or not (args.source / 'meson.build').is_file():
        parser.error('Source must be an absolute local MPV Git checkout')
    for executable in (args.meson, args.ninja):
        if not executable.is_absolute() or not os.access(executable, os.X_OK):
            parser.error('Supply explicit absolute Meson and Ninja executable paths')
    if not args.output.is_absolute() or args.output.exists():
        parser.error('Output must be a new absolute directory')
    if args.output.is_relative_to(args.source):
        parser.error('Output must be outside the source checkout')

    def git(*arguments):
        return subprocess.check_output(['git', '-C', str(args.source), *arguments])

    revision = git('rev-parse', 'HEAD').decode().strip()
    names = git('ls-files', '-z', '--cached', '--others', '--exclude-standard').split(b'\0')
    args.output.mkdir(parents=True)
    snapshot = args.output / 'source'
    hashes = {}
    restored = []
    for name in names:
        if not name:
            continue
        relative = Path(os.fsdecode(name))
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Invalid source path')
        original = args.source / relative
        destination = snapshot / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if original.is_file():
            shutil.copy2(original, destination)
        elif not original.exists():
            # Local packaging checkouts can delete the tracked icon bundle,
            # although Meson still requires it at configure time.
            destination.write_bytes(git('show', 'HEAD:' + relative.as_posix()))
            restored.append(relative.as_posix())
        else:
            raise ValueError('Unsupported source entry: ' + str(relative))
        hashes[relative.as_posix()] = hashlib.sha256(destination.read_bytes()).hexdigest()
    provenance = {'sourceDirectory': str(args.source), 'revision': revision,
                  'status': git('status', '--porcelain').decode(),
                  'restoredTrackedFiles': restored, 'sourceFileHashes': hashes,
                  'pkgConfigPath': os.environ.get('PKG_CONFIG_PATH', '')}
    (args.output / 'source-manifest.json').write_text(json.dumps(provenance, indent=2) + '\n')
    commands = [
        [str(args.meson), 'setup', str(args.output / 'build'), str(snapshot),
         '--buildtype=release', '--wrap-mode=nofallback', '-Dauto_features=disabled',
         '-Dcplayer=true', '-Dlibmpv=false', '-Dtests=false', '-Dgl=disabled'],
        [str(args.ninja), '-C', str(args.output / 'build')]
    ]
    (args.output / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
    for command, name in zip(commands, ['configure.log', 'build.log']):
        with (args.output / name).open('wb') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
    executable = args.output / 'build/mpv'
    (args.output / 'mpv.sha256').write_text(hashlib.sha256(executable.read_bytes()).hexdigest() + '\n')
    (args.output / 'version.txt').write_bytes(subprocess.check_output([str(executable), '--version']))
    (args.output / 'linked-libraries.txt').write_bytes(subprocess.check_output(['otool', '-L', str(executable)]))
    print(executable)


if __name__ == '__main__':
    main()
