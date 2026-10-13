#!/usr/bin/env python3
"""Fetch the pinned signed helper pair once; print the prepared directory for Xcode."""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    with path.open('rb') as source:
        checksum = hashlib.sha256()
        for block in iter(lambda: source.read(1024 * 1024), b''):
            checksum.update(block)
        return checksum.hexdigest()


def validate_prepared(directory, pin):
    try:
        manifest = json.loads((directory / 'manifest.json').read_text())
        if directory.is_symlink() or manifest['schemaVersion'] != 1:
            return False
        files = manifest['files']
        if not {'ffmpeg', 'ffprobe', 'provenance.txt'} <= files.keys():
            return False
        for name, expected in pin['binaries'].items():
            if files.get(name) != expected or manifest['helpers'][name]['inputSHA256'] != expected:
                return False
        if any(p.is_symlink() for p in directory.rglob('*')):
            return False
        if {str(p.relative_to(directory)) for p in directory.rglob('*') if p.is_file()} != set(files) | {'manifest.json'}:
            return False
        for name, expected in files.items():
            relative = Path(name)
            if relative.is_absolute() or '..' in relative.parts or digest(directory / relative) != expected:
                return False
        return True
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return False


def extract_verified(archive, destination, pin):
    if digest(archive) != pin['sha256']:
        raise ValueError('Downloaded helper archive SHA256 mismatch')
    # Only known files are extracted; archive paths/links never select destinations.
    names = ['ffmpeg', 'ffprobe', 'README.md', 'qualification.json', 'notarization.json']
    with zipfile.ZipFile(archive) as package:
        for name in names:
            info = package.getinfo('full/' + name)
            if info.file_size > 200_000_000:
                raise ValueError('Unexpected helper archive member size')
            with package.open(info) as source, (destination / name).open('wb') as output:
                shutil.copyfileobj(source, output)
    for name, expected in pin['binaries'].items():
        path = destination / name
        if digest(path) != expected:
            raise ValueError(f'{name} SHA256 mismatch')
        path.chmod(0o755)
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(path)], check=True)


def bootstrap(cache, pin, archive=None):
    cache.mkdir(parents=True, exist_ok=True)
    # Concurrent Xcode builds share admission and atomically published output.
    with (cache / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        prepared = cache / pin['sha256']
        if validate_prepared(prepared, pin):
            return prepared
        with tempfile.TemporaryDirectory(prefix='.bootstrap-', dir=cache) as temporary:
            staging = Path(temporary)
            downloaded = staging / 'helpers.zip'
            if archive is not None:
                shutil.copyfile(archive, downloaded)
            else:
                print(f"Downloading pinned FFmpeg {pin['version']} helpers…", file=sys.stderr)
                request = urllib.request.Request(pin['url'], headers={'User-Agent': 'Aagedal-Film-Constructor'})
                with urllib.request.urlopen(request, timeout=60) as response, downloaded.open('wb') as output:
                    shutil.copyfileobj(response, output)
            extracted = staging / 'input'
            extracted.mkdir()
            extract_verified(downloaded, extracted, pin)
            notices = staging / 'notices'
            notices.mkdir()
            for name in ('README.md', 'qualification.json', 'notarization.json'):
                shutil.copyfile(extracted / name, notices / name)
            provenance = staging / 'provenance.txt'
            provenance.write_text(
                f"Pinned helper URL: {pin['url']}\nArchive SHA256: {pin['sha256']}\n"
                "Executable hashes and macOS code signatures verified before preparation.\n"
                "Supplied build and notarization reports retained. Complete dependency notices,\n"
                "corresponding sources and release certification remain unreviewed.\n")
            result = staging / 'prepared'
            subprocess.run([sys.executable, str(ROOT / 'scripts/prepare-media-helpers.py'),
                            '--ffmpeg', str(extracted / 'ffmpeg'), '--ffprobe', str(extracted / 'ffprobe'),
                            '--notices', str(notices), '--provenance', str(provenance), '--output', str(result)],
                           check=True, stdout=sys.stderr)
            if not validate_prepared(result, pin):
                raise ValueError('Prepared helper validation failed')
            if prepared.is_symlink() or prepared.is_file():
                prepared.unlink()
            elif prepared.exists():
                shutil.rmtree(prepared)
            result.rename(prepared)
        return prepared


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, default=ROOT / '.local/downloaded-media-helpers')
    parser.add_argument('--archive', type=Path, help='Seed the cache offline with the exact pinned ZIP')
    args = parser.parse_args()
    try:
        pin = json.loads((ROOT / 'Configuration/MediaHelpers.json').read_text())
        print(bootstrap(args.cache.resolve(), pin, args.archive))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        parser.exit(1, f'Media helper bootstrap failed: {error}\n'
                    'Check network access, or seed with --archive. Use AFC_BUNDLE_MEDIA_HELPERS=NO to build without helpers.\n')
