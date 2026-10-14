#!/usr/bin/env python3
"""Relocate an explicit development native dylib closure into an app bundle.

Standalone packaging signs ad-hoc; Xcode embedding signs nested libraries with
the supplied development identity before Xcode seals the app. Neither certifies a release.
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


def version_key(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d+(?:\.\d+){0,2}', value):
        raise ValueError(f'Invalid macOS deployment version: {value!r}')
    components = tuple(map(int, value.split('.')))
    return components + (0,) * (3 - len(components))


def deployment_versions(output, path):
    """Read modern and legacy deployment commands from otool -l, failing closed."""
    versions = []
    for block in re.split(r'^\s*Load command \d+\s*$', output, flags=re.MULTILINE):
        command = re.search(r'^\s*cmd (LC_\w+)\s*$', block, re.MULTILINE)
        if command is None:
            continue
        kind = command.group(1)
        if kind == 'LC_BUILD_VERSION':
            platform = re.search(r'^\s*platform (\S+)\s*$', block, re.MULTILINE)
            if platform is None or platform.group(1).upper() not in ('1', 'MACOS', 'MACOSX'):
                raise ValueError(f'Non-macOS or missing deployment platform in {path}')
            version = re.search(r'^\s*minos (\S+)\s*$', block, re.MULTILINE)
        elif kind == 'LC_VERSION_MIN_MACOSX':
            version = re.search(r'^\s*version (\S+)\s*$', block, re.MULTILINE)
        elif kind.startswith('LC_VERSION_MIN_'):
            raise ValueError(f'Non-macOS deployment command {kind} in {path}')
        else:
            continue
        if version is None:
            raise ValueError(f'Missing deployment version in {path}')
        value = version.group(1)
        version_key(value)
        versions.append(value)
    if not versions:
        raise ValueError(f'Missing macOS deployment metadata in {path}')
    return versions


def bundle_minimum_os(info, architecture, binary_minimum, deployment_target=None):
    """Preserve stricter app requirements, and never advertise below the closure floor."""
    candidates = [binary_minimum]
    if 'LSMinimumSystemVersion' in info:
        candidates.append(info['LSMinimumSystemVersion'])
    by_architecture = info.get('LSMinimumSystemVersionByArchitecture', {})
    if not isinstance(by_architecture, dict):
        raise ValueError('Invalid LSMinimumSystemVersionByArchitecture')
    if architecture in by_architecture:
        candidates.append(by_architecture[architecture])
    minimum = max(candidates, key=version_key)
    if deployment_target is not None and version_key(minimum) > version_key(deployment_target):
        raise ValueError(f'Bundle requires macOS {minimum}, exceeding deployment target {deployment_target}')
    info['LSMinimumSystemVersion'] = minimum
    if architecture in by_architecture:
        by_architecture[architecture] = minimum
    return minimum


def validate_output_location(output, input_trees):
    parent = output.parent.resolve()
    for tree in input_trees:
        if parent.is_relative_to(tree.resolve()):
            raise ValueError(f'Output staging directory must be outside input tree: {tree}')


def validate_embedding_inputs(destinations, input_trees, input_files):
    for destination in destinations:
        resolved = destination.resolve()
        for tree in input_trees:
            tree = tree.resolve()
            if resolved.is_relative_to(tree) or tree.is_relative_to(resolved):
                raise ValueError('Embedding output must not overlap an input tree')
        for source in input_files:
            source = source.resolve()
            if source.is_relative_to(resolved) or resolved.is_relative_to(source):
                raise ValueError('Embedding output must not contain an input file')


def embed_runtime(args):
    """Embed a development closure before Xcode seals the containing app.

    Build outputs are replaced only when empty or owned by our prior manifest.
    This deliberately does not sign the outer app or change its deployment floor.
    """
    runtime = args.runtime_only
    if not runtime.is_absolute() or not runtime.is_file() or runtime.is_symlink() or runtime.name != 'libNativePlaybackRuntime.dylib':
        raise ValueError('Supply an absolute libNativePlaybackRuntime.dylib')
    if not args.deployment_target:
        raise ValueError('Xcode embedding requires an explicit deployment target')
    version_key(args.deployment_target)
    if not args.notices.is_dir() or not any(p.is_file() for p in args.notices.rglob('*')):
        raise ValueError('Supply nonempty dependency notices')
    if not args.provenance.is_file() or args.provenance.is_symlink():
        raise ValueError('Supply explicit build provenance')
    if any(p.is_symlink() for p in args.notices.rglob('*')):
        raise ValueError('Notices must not contain symbolic links')
    frameworks, resources = args.frameworks, args.resources
    for destination in [frameworks, resources]:
        if not destination.is_absolute() or destination.is_symlink():
            raise ValueError('Embedding destinations must be absolute, non-symlink paths')
        validate_output_location(destination, [args.notices, runtime.parent])
    if frameworks.resolve().is_relative_to(resources.resolve()) or resources.resolve().is_relative_to(frameworks.resolve()):
        raise ValueError('Embedding destinations must not overlap')
    libraries = [p.resolve(strict=True) for p in args.library_dir]
    if any(not p.is_dir() for p in libraries):
        raise ValueError('Library search paths must be directories')
    runtime = runtime.resolve(strict=True)
    nodes = discover(runtime, libraries)
    validate_embedding_inputs([frameworks, resources], [args.notices], [args.provenance, *nodes])
    architecture = require_thin_architecture(capture('/usr/bin/lipo', '-archs', runtime).split())
    names = [p.name for p in nodes]
    if len(set(names)) != len(names):
        raise ValueError('Different libraries have the same bundle filename')
    for source, metadata in nodes.items():
        metadata['architectures'] = capture('/usr/bin/lipo', '-archs', source).split()
        require_thin_architecture(metadata['architectures'], architecture)
        metadata['buildVersionOutput'] = capture('/usr/bin/otool', '-l', source)
        metadata['minimumOSVersions'] = deployment_versions(metadata['buildVersionOutput'], source)
    minimum = max((v for m in nodes.values() for v in m['minimumOSVersions']), key=version_key)
    bundle_minimum_os({}, architecture, minimum, args.deployment_target)
    # Never replace unrelated frameworks or resource directories during a rebuild.
    validate_embedded_outputs(frameworks, resources)
    frameworks.parent.mkdir(parents=True, exist_ok=True)
    resources.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix='.native-runtime-', dir=frameworks.parent))
    try:
        staged = temporary / 'Frameworks'
        staged.mkdir()
        staged_resources = temporary / 'NativeRuntime'
        staged_resources.mkdir()
        observations = []
        for source, metadata in nodes.items():
            target = staged / source.name
            shutil.copyfile(source, target)
            target.chmod(0o755)
            command = ['/usr/bin/install_name_tool', '-id', '@rpath/' + target.name]
            for old, dependency in metadata['resolved'].items():
                command += ['-change', old, '@rpath/' + dependency.name]
            for rpath in metadata['rpaths']:
                if rpath != '@loader_path':
                    command += ['-delete_rpath', rpath]
            if '@loader_path' not in metadata['rpaths']:
                command += ['-add_rpath', '@loader_path']
            subprocess.run([*command, str(target)], check=True, capture_output=True)
            relocated = inspect(target)
            allowed = {'@rpath/' + name for name in names}
            if any(not system_dependency(d) and d not in allowed for d in relocated['dependencies']):
                raise ValueError(f'External dependency survived relocation: {target}')
            identity = args.sign_identity or '-'
            signing = ['/usr/bin/codesign', '--force', '--sign', identity]
            if identity != '-':
                signing += ['--options', 'runtime']
            subprocess.run([*signing, str(target)], check=True, capture_output=True)
            subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(target)], check=True, capture_output=True)
            observations.append(dict(inputPath=str(source), inputSHA256=digest(source),
                bundledPath='Contents/Frameworks/' + source.name, dependencies=relocated['dependencies'],
                originalRpaths=metadata['rpaths'], architectures=metadata['architectures'],
                minimumOSVersions=metadata['minimumOSVersions'], buildVersionOutput=metadata['buildVersionOutput']))
        shutil.copytree(args.notices, staged_resources / 'notices')
        shutil.copyfile(args.provenance, staged_resources / 'provenance.txt')
        manifest = dict(schemaVersion=1, embeddingMode='xcode-development', libraries=observations,
            minimumOS=minimum, binaryMinimumOS=minimum, deploymentTarget=args.deployment_target,
            signing='ad-hoc development' if not args.sign_identity or args.sign_identity == '-' else 'Xcode development identity',
            licenseReview='unreviewed', provenanceReview='unreviewed', releaseCertified=False,
            files={p.name: digest(p) for p in sorted(staged.iterdir())})
        (staged_resources / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        # Fully prepare and verify both trees before touching previously built outputs.
        if frameworks.exists():
            shutil.rmtree(frameworks)
        if resources.exists():
            shutil.rmtree(resources)
        staged.rename(frameworks)
        staged_resources.rename(resources)
    finally:
        shutil.rmtree(temporary)
    print(f'Embedded {len(nodes)} development libraries; macOS floor {minimum}; releaseCertified=false')


def validate_embedded_outputs(frameworks, resources):
    for directory in [frameworks, resources]:
        if directory.exists() and (not directory.is_dir() or directory.is_symlink() or any(p.is_symlink() for p in directory.rglob('*'))):
            raise ValueError('Existing native outputs contain links or are not directories')
    if resources.exists():
        manifest = json.loads((resources / 'manifest.json').read_text())
        if manifest.get('schemaVersion') != 1 or manifest.get('embeddingMode') != 'xcode-development':
            raise ValueError('Existing native resources are not owned development outputs')
        files = manifest.get('files')
        if not isinstance(files, dict) or not files or any(Path(name).name != name or name in ('.', '..') for name in files):
            raise ValueError('Invalid prior native output manifest')
        actual = {p.name for p in frameworks.iterdir()} if frameworks.exists() else set()
        if actual and actual != set(files):
            raise ValueError('Existing Frameworks directory contains unrelated or incomplete files')
        if frameworks.exists() and any(not p.is_file() for p in frameworks.iterdir()):
            raise ValueError('Existing Frameworks directory contains unrelated entries')
    elif frameworks.exists() and any(frameworks.iterdir()):
        raise ValueError('Existing Frameworks directory is not an owned native output')


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
        metadata['buildVersionOutput'] = capture('/usr/bin/otool', '-l', path)
        metadata['minimumOSVersions'] = deployment_versions(metadata['buildVersionOutput'], path)
    if not any(p.name == 'libNativePlaybackRuntime.dylib' for p in nodes):
        raise ValueError('App does not link NativePlaybackRuntime')
    binary_minimum = max((v for metadata in nodes.values() for v in metadata['minimumOSVersions']), key=version_key)
    minimum_os = bundle_minimum_os(info, architecture, binary_minimum, getattr(args, 'deployment_target', None))
    validate_output_location(args.output, [args.app, args.notices])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix='.native-runtime-', dir=args.output.parent))
    try:
        staged = temporary / args.output.name
        shutil.copytree(args.app, staged)
        (staged / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
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
        manifest = dict(schemaVersion=1, libraries=observations, minimumOS=minimum_os,
            binaryMinimumOS=binary_minimum, deploymentTarget=getattr(args, 'deployment_target', None),
            buildVersionTool='otool -l', signing='ad-hoc development',
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
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument('--app', type=Path)
    selection.add_argument('--runtime-only', type=Path, help='Embed a development library closure into Xcode output before outer signing')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--frameworks', type=Path)
    parser.add_argument('--resources', type=Path)
    parser.add_argument('--sign-identity', default='-')
    for option in ['notices', 'provenance']:
        parser.add_argument('--' + option, required=True, type=Path)
    parser.add_argument('--library-dir', action='append', required=True, type=Path)
    parser.add_argument('--deployment-target', help='Maximum permitted minimum macOS version; reject incompatible inputs before staging')
    try:
        arguments = parser.parse_args()
        if arguments.runtime_only:
            if not arguments.frameworks or not arguments.resources or arguments.output:
                parser.error('--runtime-only requires --frameworks/--resources and does not accept --output')
            embed_runtime(arguments)
        else:
            if not arguments.output or arguments.frameworks or arguments.resources:
                parser.error('--app requires --output and does not accept --frameworks/--resources')
            package(arguments)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        detail = error.stderr.decode(errors='replace') if isinstance(error, subprocess.CalledProcessError) and isinstance(error.stderr, bytes) else ''
        parser.exit(1, f'Native runtime packaging failed: {error}\n{detail}')
