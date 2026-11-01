#!/usr/bin/env python3
"""Compare the two bundled FFmpeg copies: the prepared ffmpeg/ffprobe helpers and the
FFmpeg linked into libNativePlaybackRuntime.dylib.

Reports versions, licences, whether both come from one FFmpeg build (same version and
configure line), coverage of Configuration/FFmpegRequirements.json per feature, and
codecs/demuxers only the runtime reads (media the runtime could admit that the helpers
could not export). With --check, a version or licence mismatch, a nonfree build or a
helper lacking a required component fails; --require-same-build also fails when the
configurations differ. Helper listings come from the prepared directory; nothing is
executed.
"""
import argparse
import ctypes
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
KINDS = ('encoders', 'decoders', 'filters', 'muxers', 'demuxers')


def load_requirements(path=ROOT / 'Configuration/FFmpegRequirements.json'):
    """{feature: {kind: (required set, optional set)}}."""
    document = json.loads(Path(path).read_text())
    if document.get('schemaVersion') != 1 or not isinstance(document.get('features'), dict):
        raise ValueError('Unsupported FFmpeg requirements file')
    features = {}
    for name, entry in document['features'].items():
        features[name] = {kind: (set(entry.get(kind, [])), set(entry.get('optional' + kind.capitalize(), [])))
                          for kind in KINDS}
    return features


def required(requirements):
    """Every non-optional component, by kind."""
    return {kind: set().union(*(feature[kind][0] for feature in requirements.values())) for kind in KINDS}


def entries(text):
    """Rows of an `ffmpeg -encoders/-decoders/-filters/-muxers/-demuxers` listing: (flags, name, line).
    The legend above the dashed separator is skipped."""
    lines = text.splitlines()
    start = next((index + 1 for index, line in enumerate(lines) if re.fullmatch(r'\s*-{3,}\s*', line)), 0)
    for line in lines[start:]:
        fields = line.split()
        if len(fields) >= 2:
            yield fields[0], fields[1], line


def listing_names(text):
    return {name for _, name, _ in entries(text)}


def demuxer_names(text):
    """Input formats and input devices from an `ffmpeg -demuxers` listing. Its flags are fixed
    columns (`D`, `E`, `d` for devices), and one row can name several formats (`mov,mp4,…`)."""
    lines = text.splitlines()
    start = next((index + 1 for index, line in enumerate(lines) if re.fullmatch(r'\s*-{3,}\s*', line)), 0)
    names = set()
    for line in lines[start:]:
        match = re.match(r'^ ([D ])([E ])([d ]) (\S+)', line)
        if match and match[1] == 'D':
            names.update(match[4].split(','))
    return names


def names(kind, text):
    return demuxer_names(text) if kind == 'demuxers' else listing_names(text)


def decodable_codecs(text):
    """Codec names from a `-decoders` listing; FFmpeg appends `(codec x)` when they differ."""
    codecs = set()
    for _, name, line in entries(text):
        match = re.search(r'\(codec (\S+)\)\s*$', line)
        codecs.add(match.group(1) if match else name)
    return codecs


def licence(configuration):
    flags = configuration.split()
    if '--enable-nonfree' in flags:
        return 'nonfree'
    if '--enable-gpl' in flags:
        return 'GPL version 3 or later' if '--enable-version3' in flags else 'GPL version 2 or later'
    return 'LGPL version 3 or later' if '--enable-version3' in flags else 'LGPL version 2.1 or later'


def normalised_version(version):
    """`n9.0.2` (git tag) and `9.0.2` (release tarball) are the same release."""
    return version[1:] if re.fullmatch(r'n\d.*', version) else version


def helper_inventory(directory):
    directory = Path(directory)
    manifest = json.loads((directory / 'manifest.json').read_text())
    helper = manifest['helpers']['ffmpeg']
    if not (directory / 'demuxers.txt').is_file():
        raise ValueError(f'{directory} has no demuxers.txt; prepare it again with scripts/prepare-media-helpers.py')
    listings = {kind: (directory / f'{kind}.txt').read_text() for kind in KINDS}
    # The manifest keeps the whole `configuration:` line of `ffmpeg -version`.
    configuration = helper['configuration'].strip().removeprefix('configuration:').strip()
    return dict(version=helper['version'], configuration=configuration,
                **{kind: sorted(names(kind, text)) for kind, text in listings.items()},
                decodableCodecs=sorted(decodable_codecs(listings['decoders'])))


class AVCodec(ctypes.Structure):
    # Leading public fields, stable across FFmpeg major versions.
    _fields_ = [('name', ctypes.c_char_p), ('long_name', ctypes.c_char_p), ('type', ctypes.c_int), ('id', ctypes.c_int)]


def _iterate(library, function):
    iterate = getattr(library, function)
    iterate.restype = ctypes.c_void_p
    iterate.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
    state, pointers = ctypes.c_void_p(), []
    while pointer := iterate(ctypes.byref(state)):
        pointers.append(pointer)
    return pointers


def _name(pointer):
    return ctypes.cast(pointer, ctypes.POINTER(ctypes.c_char_p))[0].decode()


def runtime_inventory_in_process(dylib):
    library = ctypes.CDLL(str(dylib))
    # As the ffmpeg program does, so input devices such as lavfi are listed with the demuxers.
    if hasattr(library, 'avdevice_register_all'):
        library.avdevice_register_all()
    for function in ('av_version_info', 'avcodec_configuration', 'avcodec_get_name'):
        getattr(library, function).restype = ctypes.c_char_p
    library.av_codec_is_encoder.argtypes = library.av_codec_is_decoder.argtypes = [ctypes.c_void_p]
    codecs = _iterate(library, 'av_codec_iterate')
    decoders = [pointer for pointer in codecs if library.av_codec_is_decoder(pointer)]
    return dict(
        version=library.av_version_info().decode(), configuration=library.avcodec_configuration().decode(),
        encoders=sorted({_name(pointer) for pointer in codecs if library.av_codec_is_encoder(pointer)}),
        decoders=sorted({_name(pointer) for pointer in decoders}),
        decodableCodecs=sorted({library.avcodec_get_name(ctypes.cast(pointer, ctypes.POINTER(AVCodec))[0].id).decode()
                                for pointer in decoders}),
        filters=sorted({_name(pointer) for pointer in _iterate(library, 'av_filter_iterate')}),
        muxers=sorted({_name(pointer) for pointer in _iterate(library, 'av_muxer_iterate')}),
        demuxers=sorted({name for pointer in _iterate(library, 'av_demuxer_iterate') for name in _name(pointer).split(',')}))


def runtime_inventory(dylib):
    """Loads the runtime in a separate isolated interpreter, never in the caller."""
    output = subprocess.check_output([sys.executable, '-I', str(Path(__file__).resolve()), '--runtime-inventory', str(dylib)],
                                     text=True, timeout=120)
    return json.loads(output)


def compare(helper, runtime, requirements, require_same_build=False):
    report = dict(
        versions=dict(helper=helper['version'], runtime=runtime['version'],
                      match=normalised_version(helper['version']) == normalised_version(runtime['version'])),
        licences=dict(helper=licence(helper['configuration']), runtime=licence(runtime['configuration'])),
        # One build: the same version string and the same configure line (whitespace aside; configure
        # applies flags in order), which includes the build's own --prefix, so two builds of one
        # recipe in different places differ here too.
        build=dict(sameVersion=helper['version'] == runtime['version'],
                   sameConfiguration=helper['configuration'].split() == runtime['configuration'].split()),
        features={}, errors=[])
    report['build']['same'] = report['build']['sameVersion'] and report['build']['sameConfiguration']
    if not report['build']['sameConfiguration']:
        helper_flags, runtime_flags = set(helper['configuration'].split()), set(runtime['configuration'].split())
        report['build']['helperOnlyFlags'] = sorted(helper_flags - runtime_flags)
        report['build']['runtimeOnlyFlags'] = sorted(runtime_flags - helper_flags)
    report['licences']['match'] = report['licences']['helper'] == report['licences']['runtime']
    for name, feature in requirements.items():
        entry = {}
        for copy, inventory in (('helper', helper), ('runtime', runtime)):
            missing = {kind: sorted((needed | optional) - set(inventory[kind]))
                       for kind, (needed, optional) in feature.items() if (needed | optional) - set(inventory[kind])}
            entry[copy + 'Missing'] = missing
            if copy == 'helper':
                hard = {kind: sorted(feature[kind][0] - set(inventory[kind])) for kind in KINDS}
                for kind, names in hard.items():
                    if names:
                        report['errors'].append(f'Helper lacks {kind} required by {name}: {", ".join(names)}')
        report['features'][name] = entry
    report['runtimeOnlyDecodableCodecs'] = sorted(set(runtime['decodableCodecs']) - set(helper['decodableCodecs']))
    report['runtimeOnlyDemuxers'] = sorted(set(runtime['demuxers']) - set(helper['demuxers']))
    report['counts'] = {copy: {kind: len(inventory[kind]) for kind in KINDS}
                        for copy, inventory in (('helper', helper), ('runtime', runtime))}
    if not report['versions']['match']:
        report['errors'].append(f'FFmpeg versions differ: helpers {helper["version"]}, runtime {runtime["version"]}')
    if not report['licences']['match']:
        report['errors'].append(f'FFmpeg licences differ: helpers {report["licences"]["helper"]}, runtime {report["licences"]["runtime"]}')
    if 'nonfree' in (report['licences']['helper'], report['licences']['runtime']):
        report['errors'].append('A nonfree FFmpeg build cannot be distributed')
    if require_same_build and not report['build']['same']:
        report['errors'].append('The helpers and the runtime are not the same FFmpeg build'
                                + ('' if report['build']['sameVersion'] else ' (version strings differ)')
                                + ('' if report['build']['sameConfiguration'] else ' (configurations differ)'))
    return report


def configuration_difference(build):
    helper_only, runtime_only = len(build['helperOnlyFlags']), len(build['runtimeOnlyFlags'])
    if not helper_only and not runtime_only:
        return ' (the same configure flags in a different order)'
    return f' ({helper_only} configure flags only in the helpers, {runtime_only} only in the runtime)'


def summary(report):
    lines = [f'FFmpeg versions: helpers {report["versions"]["helper"]}, runtime {report["versions"]["runtime"]}'
             f' ({"same release" if report["versions"]["match"] else "DIFFERENT"})',
             f'Licences: helpers {report["licences"]["helper"]}, runtime {report["licences"]["runtime"]}',
             'Build: ' + ('one FFmpeg build (same version and configuration)' if report['build']['same'] else
                          'different builds' + ('' if report['build']['sameConfiguration'] else configuration_difference(report['build']))),
             'Component counts: ' + '; '.join(f'{copy} ' + ', '.join(f'{count} {kind}' for kind, count in counts.items())
                                              for copy, counts in report['counts'].items())]
    for name, entry in report['features'].items():
        for copy in ('helper', 'runtime'):
            missing = entry[copy + 'Missing']
            lines.append(f'{name}: {copy} ' + ('complete' if not missing else
                         'lacks ' + '; '.join(f'{kind} {", ".join(names)}' for kind, names in missing.items())))
    lines.append('Codecs only the runtime decodes: ' + (', '.join(report['runtimeOnlyDecodableCodecs']) or 'none'))
    lines.append('Demuxers only the runtime has: ' + (', '.join(report['runtimeOnlyDemuxers']) or 'none'))
    lines += [f'error: {error}' for error in report['errors']]
    return '\n'.join(lines)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '--runtime-inventory':
        json.dump(runtime_inventory_in_process(sys.argv[2]), sys.stdout)
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helpers', type=Path, required=True, help='Prepared helper directory (or an app bundle Helpers copy)')
    parser.add_argument('--runtime', type=Path, required=True, help='libNativePlaybackRuntime.dylib')
    parser.add_argument('--requirements', type=Path, default=ROOT / 'Configuration/FFmpegRequirements.json')
    parser.add_argument('--json', type=Path, help='Write the full report here')
    parser.add_argument('--check', action='store_true', help='Exit nonzero on version/licence drift or missing helper components')
    parser.add_argument('--require-same-build', action='store_true',
                        help='With --check, also fail unless both copies have the same version and configuration')
    args = parser.parse_args()
    try:
        report = compare(helper_inventory(args.helpers), runtime_inventory(args.runtime),
                         load_requirements(args.requirements), args.require_same_build)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'FFmpeg copies audit failed: {error}\n')
    if args.json:
        args.json.write_text(json.dumps(report, indent=2) + '\n')
    print(summary(report))
    if args.check and report['errors']:
        sys.exit(1)


if __name__ == '__main__':
    main()
