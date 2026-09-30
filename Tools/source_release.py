#!/usr/bin/env python3
"""Create a privacy-checked, source-only release. Never exports Git history."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import socket
import zipfile

ROOT = Path(__file__).resolve().parents[1]
NAME = 'perifit-edge-v1.0.0-source'
TOP = ('.gitignore', '.gitattributes', 'LICENSE', 'README.md', 'Package.swift',
       'PROVENANCE.md', 'USB_PROTOCOL.md', 'ARDUINO_HANDOFF.md')
TREES = ('Sources', 'Resources', 'Tests', 'Tools', 'Firmware', 'Vendor', 'docs')
EXTENSIONS = {'.swift', '.c', '.h', '.cpp', '.ino', '.py', '.sh', '.txt', '.md', '.plist', '.yaml'}
FORBIDDEN = re.compile(r'(^|/)(\.git|\.build|\.swiftpm|\.serena|dist|__pycache__|\.DS_Store)(/|$)|\.(app|dmg|pkg|o|a|dylib|hex|elf|log|zip)$|(^|/)(preferences|profiles|session-[^/]+)\.json$', re.I)
PRIVATE = re.compile(r'/(?:Users|home)/[A-Za-z0-9_.-]+/|/dev/cu\.usbmodem[0-9]+|(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{20,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----')


def audit(path, data):
    if FORBIDDEN.search(path):
        raise ValueError('Forbidden release artifact: ' + path)
    text = data.decode('utf-8')  # Binary files never qualify as public source.
    if PRIVATE.search(text):
        raise ValueError('Possible private path/credential in ' + path)
    # Do not publish this computer's account or hostname. Never print their values.
    for value in (Path.home().name, socket.gethostname()):
        if len(value) >= 4 and re.search(r'(?<![\w.-])' + re.escape(value) + r'(?![\w.-])', text, re.I):
            raise ValueError('Local machine identifier in ' + path)


def source_files():
    paths = [ROOT / name for name in TOP]
    for tree in TREES:
        for path in sorted((ROOT / tree).rglob('*')):
            if any(part.startswith('.') or part == '__pycache__' for part in path.relative_to(ROOT).parts):
                continue
            if path.is_symlink():
                raise ValueError('Symlinks are not permitted in a source release')
            if path.is_file() and (path.suffix in EXTENSIONS or path.name == 'LICENSE'):
                paths.append(path)
    return sorted(set(paths))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Audit only; create no output')
    args = parser.parse_args()
    files = []
    for path in source_files():
        if not path.is_file() or path.is_symlink():
            raise ValueError('Missing/invalid public source file')
        relative = path.relative_to(ROOT).as_posix()
        data = path.read_bytes(); audit(relative, data)
        files.append((relative, data, path.suffix in ('.sh', '.py')))
    if args.check:
        print(f'PASS privacy/source audit: {len(files)} text files; no binaries or Git history')
        return
    destination = ROOT / 'dist' / NAME
    archive = ROOT / 'dist' / (NAME + '.zip')
    # Replace only this tool's fixed generated output, never a source or data directory.
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as package:
        for relative, data, executable in files:
            mode = 0o755 if executable else 0o644
            target = destination / relative; target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data); target.chmod(mode)
            entry = zipfile.ZipInfo(NAME + '/' + relative, (1980, 1, 1, 0, 0, 0))
            entry.create_system = 3; entry.external_attr = (0o100000 | mode) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            package.writestr(entry, data)
    with zipfile.ZipFile(archive) as package:
        assert len(package.infolist()) == len(files)
        for entry in package.infolist():
            audit(entry.filename, package.read(entry))
            assert not entry.extra and not entry.comment
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix('.zip.sha256').write_text(digest + '  ' + archive.name + '\n')
    print(f'PASS {len(files)} source files → dist/{archive.name}')


if __name__ == '__main__':
    main()
