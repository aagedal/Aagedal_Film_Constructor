#!/usr/bin/env python3
"""Xcode phases for opt-in Debug runtime compilation and nested-library embedding.

The app's normal outer signing phase runs after embedding. This path is local
attributed development only and explicitly rejects Release/archive opt-in.
"""
import argparse
import json
import importlib.util
import hashlib
import os
from pathlib import Path
import shlex
import shutil
import subprocess

LIBRARIES = ('libavformat', 'libavcodec', 'libavutil', 'libswscale', 'libswresample')


def selection(env):
    enabled = env.get('AFC_NATIVE_PLAYBACK', 'NO')
    if enabled not in ('YES', 'NO', ''):
        raise ValueError('AFC_NATIVE_PLAYBACK must be YES or NO')
    if enabled != 'YES':
        return None
    if env.get('CONFIGURATION') != 'Debug' or env.get('ACTION') == 'install':
        raise ValueError('Native playback selection is supported only for Debug development builds')
    archs = env.get('ARCHS', '').split()
    if archs != ['arm64']:
        raise ValueError('Native development integration currently requires thin arm64 builds')
    target = env.get('MACOSX_DEPLOYMENT_TARGET', '')
    if target != '27.0':
        raise ValueError('Native development integration requires macOS deployment target 27.0')
    paths = {}
    for name in ('SRCROOT', 'DERIVED_FILE_DIR', 'SDKROOT', 'AFC_NATIVE_PKG_CONFIG',
                 'AFC_NATIVE_NOTICES', 'AFC_NATIVE_PROVENANCE'):
        path = Path(env.get(name, ''))
        if not path.is_absolute():
            raise ValueError(f'{name} must be an explicit absolute path')
        paths[name] = path
    tool = paths['AFC_NATIVE_PKG_CONFIG']
    if not tool.is_file() or not os.access(tool, os.X_OK):
        raise ValueError('Selected pkg-config must be an executable file')
    if not paths['AFC_NATIVE_NOTICES'].is_dir() or not any(p.is_file() for p in paths['AFC_NATIVE_NOTICES'].rglob('*')):
        raise ValueError('Selected notices must be a nonempty directory')
    if not paths['AFC_NATIVE_PROVENANCE'].is_file() or not paths['AFC_NATIVE_PROVENANCE'].read_bytes().strip():
        raise ValueError('Selected provenance must be a nonempty file')
    return paths


def compile_runtime(paths, env):
    root = paths['DERIVED_FILE_DIR'] / 'native-playback'
    root.mkdir(parents=True, exist_ok=True)
    tool = paths['AFC_NATIVE_PKG_CONFIG']
    build_env = dict(env)
    # SwiftPM's system-library discovery uses this same selected tool.
    build_env['PATH'] = str(tool.parent) + os.pathsep + env.get('PATH', '/usr/bin:/bin')
    build_env['PKG_CONFIG'] = str(tool)
    flags = []
    queries = {}
    for option, forwarded in [('--cflags', '-Xcc'), ('--libs', '-Xlinker')]:
        output = subprocess.check_output([str(tool), option, *LIBRARIES], text=True)
        queries[option] = output.strip()
        for flag in shlex.split(output):
            flags += [forwarded, flag]
    swift = subprocess.check_output(['/usr/bin/xcrun', '--find', 'swift'], text=True).strip()
    command = [swift, 'build', '--package-path', str(paths['SRCROOT'] / 'Packages/NativePlaybackProof'),
        '--scratch-path', str(root / 'build'), '--cache-path', str(root / 'cache'),
        '--disable-sandbox', '--configuration', 'debug', '--triple', 'arm64-apple-macosx27.0',
        '--sdk', str(paths['SDKROOT']), '--product', 'NativePlaybackRuntime', *flags]
    (root / 'build-selection.json').write_text(json.dumps(dict(
        releaseCertified=False, command=command, pkgConfig=str(tool), pkgConfigQueries=queries,
        architecture='arm64', deploymentTarget='27.0',
        sourceHashes={str(path.relative_to(paths['SRCROOT'])): hashlib.sha256(path.read_bytes()).hexdigest()
            for package in ('EditorCore', 'NativePlaybackProof')
            for path in [paths['SRCROOT'] / 'Packages' / package / 'Package.swift',
                *sorted((paths['SRCROOT'] / 'Packages' / package / 'Sources').rglob('*'))]
            if path.is_file()},
        swiftVersion=subprocess.check_output([swift, '--version'], text=True).strip()), indent=2) + '\n')
    subprocess.run(command, env=build_env, check=True)
    # Resolve SwiftPM's actual target-triple output rather than assuming its layout.
    products = Path(subprocess.check_output([*command, '--show-bin-path'], env=build_env, text=True).strip())
    if not (products / 'libNativePlaybackRuntime.dylib').is_file():
        raise ValueError('SwiftPM did not produce the selected native runtime')
    alias = root / 'products'
    if alias.is_symlink():
        alias.unlink()
    elif alias.exists():
        raise ValueError('Unexpected native products directory; refusing to replace it')
    alias.symlink_to(products, target_is_directory=True)
    header = paths['SRCROOT'] / 'Packages/NativePlaybackProof/Sources/CNativeDecoder/include/CNativeDecoder.h'
    if '"' in str(header) or '\n' in str(header):
        raise ValueError('Repository path cannot be expressed in the C module map')
    (root / 'CNativeDecoder.modulemap').write_text('module CNativeDecoder { header "' + str(header) + '" export * }\n')


def embed_runtime(paths, env):
    build_dir = Path(env['TARGET_BUILD_DIR'])
    frameworks = build_dir / env['FRAMEWORKS_FOLDER_PATH']
    resources = build_dir / env['UNLOCALIZED_RESOURCES_FOLDER_PATH'] / 'NativeRuntime'
    identity = '-'
    if env.get('CODE_SIGNING_ALLOWED') == 'YES':
        identity = env.get('EXPANDED_CODE_SIGN_IDENTITY', '')
        if not identity:
            raise ValueError('Xcode did not provide a nested-library signing identity')
    subprocess.run(['python3', str(paths['SRCROOT'] / 'scripts/package-native-runtime.py'),
        '--runtime-only', str(paths['DERIVED_FILE_DIR'] / 'native-playback/products/libNativePlaybackRuntime.dylib'),
        '--library-dir', str(paths['DERIVED_FILE_DIR'] / 'native-playback/products'),
        '--frameworks', str(frameworks), '--resources', str(resources),
        '--notices', str(paths['AFC_NATIVE_NOTICES']), '--provenance', str(paths['AFC_NATIVE_PROVENANCE']),
        '--deployment-target', '27.0', '--sign-identity', identity], check=True)
    shutil.copyfile(paths['DERIVED_FILE_DIR'] / 'native-playback/build-selection.json', resources / 'build-selection.json')


def clean_disabled_outputs(env):
    # A selection change must not leave a previously linked native closure behind.
    build_dir = Path(env['TARGET_BUILD_DIR'])
    frameworks = build_dir / env['FRAMEWORKS_FOLDER_PATH']
    resources = build_dir / env['UNLOCALIZED_RESOURCES_FOLDER_PATH'] / 'NativeRuntime'
    if not resources.exists():
        return
    script = Path(__file__).with_name('package-native-runtime.py')
    spec = importlib.util.spec_from_file_location('native_packager', script)
    packager = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packager)
    packager.validate_embedded_outputs(frameworks, resources)
    for directory in (frameworks, resources):
        if directory.exists():
            shutil.rmtree(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('build', 'embed'))
    args = parser.parse_args()
    try:
        paths = selection(os.environ)
        if paths is None:
            if args.phase == 'embed':
                clean_disabled_outputs(os.environ)
            print('Native playback development integration is not selected.')
            return
        if args.phase == 'build':
            compile_runtime(paths, os.environ)
        else:
            embed_runtime(paths, os.environ)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'error: {error}\n')


if __name__ == '__main__':
    main()
