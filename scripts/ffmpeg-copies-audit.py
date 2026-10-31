#!/usr/bin/env python3
"""Compare the two bundled FFmpeg copies: the prepared ffmpeg/ffprobe helpers and the
FFmpeg linked into libNativePlaybackRuntime.dylib.

Reports versions, licences, coverage of Configuration/FFmpegRequirements.json per
feature, and codecs/demuxers only the runtime reads (media the runtime could admit
that the helpers could not export). With --check, a version or licence mismatch, a
nonfree build or a helper lacking a required component fails. Helper listings come from
the prepared directory; nothing is executed unless --helper-demuxers is given.
"""
import argparse
import ctypes
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
KINDS = ('encoders', 'decoders', 'filters', 'muxers')


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


def helper_inventory(directory, executable_demuxers=False):
    directory = Path(directory)
    manifest = json.loads((directory / 'manifest.json').read_text())
    helper = manifest['helpers']['ffmpeg']
    listings = {kind: (directory / f'{kind}.txt').read_text() for kind in KINDS}
    inventory = dict(version=helper['version'], configuration=helper['configuration'],
                     **{kind: sorted(listing_names(text)) for kind, text in listings.items()},
                     decodableCodecs=sorted(decodable_codecs(listings['decoders'])), demuxers=None)
    if executable_demuxers:
        # Only for unsigned/notarized prepared copies: app copies inherit the app sandbox.
        output = subprocess.check_output([str(directory / 'ffmpeg'), '-hide_banner', '-demuxers'], text=True)
        inventory['demuxers'] = sorted({name for flags, names, _ in entries(output) if 'D' in flags
                                        for name in names.split(',')})
    return inventory


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


def compare(helper, runtime, requirements):
    report = dict(
        versions=dict(helper=helper['version'], runtime=runtime['version'],
                      match=normalised_version(helper['version']) == normalised_version(runtime['version'])),
        licences=dict(helper=licence(helper['configuration']), runtime=licence(runtime['configuration'])),
        features={}, errors=[])
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
    report['runtimeOnlyDemuxers'] = (None if helper['demuxers'] is None
                                     else sorted(set(runtime['demuxers']) - set(helper['demuxers'])))
    report['counts'] = {copy: {kind: len(inventory[kind]) for kind in (*KINDS, 'demuxers') if inventory[kind] is not None}
                        for copy, inventory in (('helper', helper), ('runtime', runtime))}
    if not report['versions']['match']:
        report['errors'].append(f'FFmpeg versions differ: helpers {helper["version"]}, runtime {runtime["version"]}')
    if not report['licences']['match']:
        report['errors'].append(f'FFmpeg licences differ: helpers {report["licences"]["helper"]}, runtime {report["licences"]["runtime"]}')
    if 'nonfree' in (report['licences']['helper'], report['licences']['runtime']):
        report['errors'].append('A nonfree FFmpeg build cannot be distributed')
    return report


def summary(report):
    lines = [f'FFmpeg versions: helpers {report["versions"]["helper"]}, runtime {report["versions"]["runtime"]}'
             f' ({"same release" if report["versions"]["match"] else "DIFFERENT"})',
             f'Licences: helpers {report["licences"]["helper"]}, runtime {report["licences"]["runtime"]}',
             'Component counts: ' + '; '.join(f'{copy} ' + ', '.join(f'{count} {kind}' for kind, count in counts.items())
                                              for copy, counts in report['counts'].items())]
    for name, entry in report['features'].items():
        for copy in ('helper', 'runtime'):
            missing = entry[copy + 'Missing']
            lines.append(f'{name}: {copy} ' + ('complete' if not missing else
                         'lacks ' + '; '.join(f'{kind} {", ".join(names)}' for kind, names in missing.items())))
    lines.append('Codecs only the runtime decodes: ' + (', '.join(report['runtimeOnlyDecodableCodecs']) or 'none'))
    if report['runtimeOnlyDemuxers'] is not None:
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
    parser.add_argument('--helper-demuxers', action='store_true', help='Run the prepared ffmpeg to list its demuxers')
    parser.add_argument('--json', type=Path, help='Write the full report here')
    parser.add_argument('--check', action='store_true', help='Exit nonzero on version/licence drift or missing helper components')
    args = parser.parse_args()
    try:
        report = compare(helper_inventory(args.helpers, args.helper_demuxers), runtime_inventory(args.runtime),
                         load_requirements(args.requirements))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f'FFmpeg copies audit failed: {error}\n')
    if args.json:
        args.json.write_text(json.dumps(report, indent=2) + '\n')
    print(summary(report))
    if args.check and report['errors']:
        sys.exit(1)


if __name__ == '__main__':
    main()
