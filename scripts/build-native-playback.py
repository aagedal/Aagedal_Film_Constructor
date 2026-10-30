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
import shutil
import subprocess

PACKAGE = 'Packages/NativePlaybackProof'


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
    for name in ('SRCROOT', 'DERIVED_FILE_DIR', 'SDKROOT'):
        path = Path(env.get(name, ''))
        if not path.is_absolute():
            raise ValueError(f'{name} must be an explicit absolute path')
        paths[name] = path
    return paths


def mpvkit_pin(package_dir):
    """The resolved MPVKit revision; Package.swift pins it exactly."""
    resolved = json.loads((package_dir / 'Package.resolved').read_text())
    pins = [pin for pin in resolved.get('pins', []) if pin.get('identity') == 'mpvkit']
    if len(pins) != 1 or not pins[0].get('state', {}).get('revision'):
        raise ValueError('Package.resolved does not pin exactly one MPVKit revision')
    return dict(location=pins[0]['location'], revision=pins[0]['state']['revision'])


def write_attribution(root, scratch, pin):
    """Notices and provenance for the statically linked MPVKit FFmpeg build."""
    license_file = scratch / 'checkouts/MPVKit/LICENSE'
    if not license_file.is_file() or not license_file.read_bytes().strip():
        raise ValueError('The resolved MPVKit checkout has no LICENSE')
    notices = root / 'notices'
    if notices.exists():
        shutil.rmtree(notices)
    notices.mkdir()
    shutil.copyfile(license_file, notices / 'MPVKit-LICENSE')
    (notices / 'README').write_text(
        'FFmpeg and its dependencies are statically linked from the GPL build of\n'
        f'{pin["location"]} at {pin["revision"]}.\n'
        'Corresponding source is published with that repository and its releases.\n')
    provenance = root / 'provenance.json'
    provenance.write_text(json.dumps(dict(mpvkit=pin, product='MPVKit-GPL', linkage='static'), indent=2) + '\n')
    return notices, provenance


def compile_runtime(paths, env):
    root = paths['DERIVED_FILE_DIR'] / 'native-playback'
    root.mkdir(parents=True, exist_ok=True)
    package_dir = paths['SRCROOT'] / PACKAGE
    swift = subprocess.check_output(['/usr/bin/xcrun', '--find', 'swift'], text=True).strip()
    command = [swift, 'build', '--package-path', str(package_dir),
        '--scratch-path', str(root / 'build'), '--cache-path', str(root / 'cache'),
        '--disable-sandbox', '--configuration', 'debug', '--triple', 'arm64-apple-macosx27.0',
        '--sdk', str(paths['SDKROOT']), '--product', 'NativePlaybackRuntime']
    pin = mpvkit_pin(package_dir)
    (root / 'build-selection.json').write_text(json.dumps(dict(
        releaseCertified=False, command=command, mpvkit=pin,
        architecture='arm64', deploymentTarget='27.0',
        sourceHashes={str(path.relative_to(paths['SRCROOT'])): hashlib.sha256(path.read_bytes()).hexdigest()
            for package in ('EditorCore', 'NativePlaybackProof')
            for path in [paths['SRCROOT'] / 'Packages' / package / 'Package.swift',
                *sorted((paths['SRCROOT'] / 'Packages' / package / 'Sources').rglob('*'))]
            if path.is_file()},
        swiftVersion=subprocess.check_output([swift, '--version'], text=True).strip()), indent=2) + '\n')
    subprocess.run(command, env=dict(env), check=True)
    write_attribution(root, root / 'build', pin)
    # Resolve SwiftPM's actual target-triple output rather than assuming its layout.
    products = Path(subprocess.check_output([*command, '--show-bin-path'], env=dict(env), text=True).strip())
    if not (products / 'libNativePlaybackRuntime.dylib').is_file():
        raise ValueError('SwiftPM did not produce the selected native runtime')
    alias = root / 'products'
    if alias.is_symlink():
        alias.unlink()
    elif alias.exists():
        raise ValueError('Unexpected native products directory; refusing to replace it')
    alias.symlink_to(products, target_is_directory=True)
    header = package_dir / 'Sources/CNativeDecoder/include/CNativeDecoder.h'
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
        '--notices', str(paths['DERIVED_FILE_DIR'] / 'native-playback/notices'),
        '--provenance', str(paths['DERIVED_FILE_DIR'] / 'native-playback/provenance.json'),
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
