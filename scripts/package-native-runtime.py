#!/usr/bin/env python3
"""Relocate an explicit development app's native dylib closure into a new app bundle.

This creates an ad-hoc-signed development artifact, never a release certification.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile


def capture(*command):
    return subprocess.check_output(list(map(str, command)), text=True, stderr=subprocess.STDOUT)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def system_dependency(name):
    return name.startswith('/usr/lib/') or name.startswith('/System/Library/')


def inspect(path):
    lines = capture('/usr/bin/otool', '-L', path).splitlines()[1:]
    linked = [line.strip().split(' (compatibility')[0] for line in lines if line.strip()]
    identifiers = capture('/usr/bin/otool', '-D', path).splitlines()[1:]
    identifier = identifiers[0].strip() if identifiers else None
    if identifier in linked:
        linked.remove(identifier)
    commands = capture('/usr/bin/otool', '-l', path).splitlines()
    rpaths = []
    for index, line in enumerate(commands):
        if line.strip() == 'cmd LC_RPATH':
            entry = commands[index + 2].strip()
            if not entry.startswith('path '):
                raise ValueError(f'Cannot read runtime search path in {path}')
            rpaths.append(entry[5:].rsplit(' (offset ', 1)[0])
    return dict(dependencies=linked, identifier=identifier, rpaths=rpaths)


def resolve_dependency(name, owner, executable, search_dirs, rpaths):
    def expand(value):
        return value.replace('@loader_path', str(owner.parent)).replace('@executable_path', str(executable.parent))
    if name.startswith('@rpath/'):
        candidates = [Path(expand(p)) / name[7:] for p in rpaths]
        candidates += [p / name[7:] for p in search_dirs]
        existing = {p.resolve(strict=True) for p in candidates if p.is_file()}
        if len(existing) != 1:
            raise ValueError(f'Unresolved or ambiguous dependency {name} in {owner}: {sorted(map(str, existing))}')
        return existing.pop()
    candidate = Path(expand(name))
    if not candidate.is_absolute() or not candidate.is_file():
        raise ValueError(f'Unresolved dependency {name} in {owner}')
    return candidate.resolve(strict=True)


def discover(executable, search_dirs):
    executable = executable.resolve(strict=True)
    nodes, names = {}, {}
    queue = [executable]
    while queue:
        path = queue.pop()
        if path in nodes:
            continue
        metadata = inspect(path)
        metadata['resolved'] = {}
        nodes[path] = metadata
        if path != executable:
            # The actual file name is used consistently, even for symlink aliases.
            name = path.name
            if name in names and names[name] != path:
                raise ValueError(f'Different libraries have the same bundle filename: {name}')
            names[name] = path
        for name in metadata['dependencies']:
            if system_dependency(name):
                continue
            resolved = resolve_dependency(name, path, executable, search_dirs, metadata['rpaths'])
            if resolved == executable:
                raise ValueError('A library cannot depend on the app executable')
            metadata['resolved'][name] = resolved
            queue.append(resolved)
    return nodes


def require_thin_architecture(architectures, required=None):
    if len(architectures) != 1:
        raise ValueError('Development packaging requires thin Mach-O binaries; universal inputs are unsupported')
    if required is not None and architectures[0] != required:
        raise ValueError('Library architecture does not match the app')
    return architectures[0]


def validate_output_location(output, input_trees):
    parent = output.parent.resolve()
    for tree in input_trees:
        if parent.is_relative_to(tree.resolve()):
            raise ValueError(f'Output staging directory must be outside input tree: {tree}')


def package(args):
    if not args.app.is_absolute() or not args.app.is_dir() or args.app.is_symlink():
        raise ValueError('Supply an absolute existing development app bundle')
    if not args.output.is_absolute() or args.output.exists():
        raise ValueError('Output must be a new absolute app path')
    if not args.notices.is_dir() or not any(p.is_file() for p in args.notices.rglob('*')):
        raise ValueError('Supply nonempty notices for the runtime and every dependency')
    if not args.provenance.is_file() or args.provenance.is_symlink():
        raise ValueError('Supply explicit build provenance, recording unknown attribution')
    for directory in [args.app, args.notices]:
        if any(p.is_symlink() for p in directory.rglob('*')):
            raise ValueError(f'Input tree must not contain symbolic links: {directory}')
    info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
    name = info.get('CFBundleExecutable', '')
    if not name or Path(name).name != name or name in ('.', '..'):
        raise ValueError('Invalid bundle executable name')
    executable = args.app / 'Contents/MacOS' / name
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError('Bundle executable is missing or not executable')
    libraries = [p.resolve(strict=True) for p in args.library_dir]
    if any(not p.is_dir() for p in libraries):
        raise ValueError('Library search paths must be directories')
    nodes = discover(executable, libraries)
    executable = executable.resolve(strict=True)
    architecture = require_thin_architecture(capture('/usr/bin/lipo', '-archs', executable).split())
    for path, metadata in nodes.items():
        metadata['architectures'] = capture('/usr/bin/lipo', '-archs', path).split()
        require_thin_architecture(metadata['architectures'], architecture)
        metadata['buildVersionOutput'] = capture('/usr/bin/vtool', '-show-build', path)
        metadata['minimumOSVersions'] = re.findall(r'^\s*minos\s+(\d+\.\d+(?:\.\d+)?)', metadata['buildVersionOutput'], re.MULTILINE)
    if not any(p.name == 'libNativePlaybackRuntime.dylib' for p in nodes):
        raise ValueError('App does not link NativePlaybackRuntime')
    validate_output_location(args.output, [args.app, args.notices])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix='.native-runtime-', dir=args.output.parent))
    try:
        staged = temporary / args.output.name
        shutil.copytree(args.app, staged)
        frameworks = staged / 'Contents/Frameworks'
        if frameworks.exists():
            raise ValueError('Use a fresh development app without an existing Frameworks directory')
        frameworks.mkdir()
        destinations = {p: (staged / 'Contents/MacOS' / name if p == executable else frameworks / p.name) for p in nodes}
        observations = []
        for source, metadata in nodes.items():
            target = destinations[source]
            if source != executable:
                shutil.copyfile(source, target)
            target.chmod(0o755)
            command = ['/usr/bin/install_name_tool']
            if metadata['identifier']:
                command += ['-id', '@rpath/' + target.name]
            for old, dependency in metadata['resolved'].items():
                command += ['-change', old, '@rpath/' + destinations[dependency].name]
            bundled_rpath = '@executable_path/../Frameworks' if source == executable else '@loader_path'
            for rpath in metadata['rpaths']:
                if rpath != bundled_rpath:
                    command += ['-delete_rpath', rpath]
            if bundled_rpath not in metadata['rpaths']:
                command += ['-add_rpath', bundled_rpath]
            command += [str(target)]
            subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            relocated = inspect(target)
            allowed = {'@rpath/' + p.name for p in destinations.values() if p != destinations[executable]}
            if any(not system_dependency(d) and d not in allowed for d in relocated['dependencies']):
                raise ValueError(f'External dependency survived relocation: {target}')
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(target)], check=True, capture_output=True)
            observations.append(dict(inputPath=str(source), inputSHA256=digest(source),
                bundledPath=str(target.relative_to(staged)), dependencies=relocated['dependencies'],
                originalRpaths=metadata['rpaths'], architectures=metadata['architectures'],
                minimumOSVersions=metadata['minimumOSVersions'], buildVersionOutput=metadata['buildVersionOutput']))
        resources = staged / 'Contents/Resources/NativeRuntime'
        resources.mkdir(parents=True, exist_ok=False)
        shutil.copytree(args.notices, resources / 'notices')
        shutil.copyfile(args.provenance, resources / 'provenance.txt')
        minimum_versions = [v for metadata in nodes.values() for v in metadata['minimumOSVersions']]
        minimum_os = max(minimum_versions, key=lambda v: tuple(map(int, v.split('.')))) if minimum_versions else None
        manifest = dict(schemaVersion=1, libraries=observations, minimumOS=minimum_os, signing='ad-hoc development',
            licenseReview='unreviewed', provenanceReview='unreviewed', releaseCertified=False,
            files={str(p.relative_to(staged)): digest(p) for p in sorted(frameworks.iterdir())})
        (resources / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        # Seal the complete bundle after nested libraries and the executable.
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(staged)], check=True, capture_output=True)
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(staged)], check=True, capture_output=True)
        for relative, expected in manifest['files'].items():
            if digest(staged / relative) != expected:
                raise ValueError(f'Bundle signing changed a recorded library: {relative}')
        staged.rename(args.output)
    finally:
        shutil.rmtree(temporary)
    print(f'Packaged {len(nodes) - 1} native libraries in {args.output}; releaseCertified=false')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ['app', 'output', 'notices', 'provenance']:
        parser.add_argument('--' + option, required=True, type=Path)
    parser.add_argument('--library-dir', action='append', required=True, type=Path)
    try:
        package(parser.parse_args())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        detail = error.stderr.decode(errors='replace') if isinstance(error, subprocess.CalledProcessError) and isinstance(error.stderr, bytes) else ''
        parser.exit(1, f'Native runtime packaging failed: {error}\n{detail}')
