#!/usr/bin/env python3
"""Collect downloaded licenses for the backend's resolved host dependency graph.

Uses Cargo's locked, offline metadata only; never downloads missing sources.
The application package itself is excluded. Build dependencies are included.
"""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile


PREFIXES = ('LICENSE', 'LICENCE', 'COPYING', 'NOTICE')


def run(*args, env=None):
    return subprocess.check_output(args, text=True, env=env)


def supplemental(package, crate, manifest):
    """Allow only reviewed, version-pinned offline license evidence."""
    allowed = {
        ('ns-keyed-archive', '0.1.5'): (
            'f8cec65e865cb48301d33b2244bec45a2f3d2bc2',
            '1814f8c12537f5c89e96b579e855c1ee86fbf22b'),
        ('plist-macro', '0.1.6'): (
            'd1d48559ddc8e9bd263f36180bbe1d4f2a3d55e5',
            '31846481de7ea17d92f2f46fad76abe58b2e9bb0'),
    }
    key = (package['name'], package['version'])
    if key not in allowed:
        return {}, None
    directory = Path(manifest).resolve().parent / 'Licenses'
    entries = json.loads((directory / 'provenance.json').read_text())
    matches = [entry for entry in entries if (entry['name'], entry['version']) == key]
    if len(matches) != 1:
        raise ValueError(f'Expected one supplemental provenance entry: {key}')
    entry = matches[0]
    commit, license_commit = allowed[key]
    vcs = json.loads((crate / '.cargo_vcs_info.json').read_text())
    revision_field = 'license_commit' if key[0] == 'ns-keyed-archive' else 'spdx_commit'
    if vcs['git']['sha1'] != commit or entry['commit'] != commit or entry[revision_field] != license_commit:
        raise ValueError(f'Supplemental license revision mismatch: {key}')
    files = {}
    expected_paths = {'LICENSE-MIT', 'LICENSE-APACHE'}
    classification = 'upstream-license-only-successor'
    if key[0] == 'plist-macro':
        expected_paths = {'SPDX-MIT.txt', 'Cargo.toml.orig', 'README.md', 'cargo-vcs-info.json'}
        classification = 'published-crate-license-declaration-with-spdx-standard-text'
        checksum = '82c39e020f2d8d361e91a434cfe26bc7c3e21ae54414379816d0110f3f7ca121'
        crate_url = 'https://static.crates.io/crates/plist-macro/plist-macro-0.1.6.crate'
        lock = (Path(manifest).resolve().parent / 'Cargo.lock').read_text()
        matching = [block for block in lock.split('[[package]]')
                    if re.search(r'^name = "plist-macro"$', block, re.M)
                    and re.search(r'^version = "0.1.6"$', block, re.M)]
        if (entry['source_kind'] != classification or entry['crate_sha256'] != checksum
                or entry['crate_url'] != crate_url or len(matching) != 1
                or not re.search(r'^checksum = "' + checksum + r'"$', matching[0], re.M)
                or package.get('license') != 'MIT'):
            raise ValueError(f'Supplemental crate checksum or declaration mismatch: {key}')
    if {record['path'] for record in entry['files']} != expected_paths or len(entry['files']) != len(expected_paths):
        raise ValueError(f'Incomplete supplemental license set: {key}')
    for record in entry['files']:
        relative = Path(record['path'])
        source = directory / f'{key[0]}-{key[1]}' / relative
        data = source.read_bytes()
        if key[0] == 'ns-keyed-archive':
            expected_url = f'https://raw.githubusercontent.com/jkcoxson/ns_keyed_archive/{license_commit}/{relative.as_posix()}'
        elif relative.name == 'SPDX-MIT.txt':
            expected_url = f'https://raw.githubusercontent.com/spdx/license-list-data/{license_commit}/text/MIT.txt'
        else:
            original_name = '.cargo_vcs_info.json' if relative.name == 'cargo-vcs-info.json' else relative.name
            expected_url = crate_url + '#' + original_name
            if (crate / original_name).read_bytes() != data:
                raise ValueError(f'Supplemental published crate evidence mismatch: {key} {relative}')
        if record['url'] != expected_url or hashlib.sha256(data).hexdigest() != record['sha256']:
            raise ValueError(f'Supplemental license integrity mismatch: {key} {relative}')
        files[relative] = source
    return files, dict(entry, classification=classification)


def collect(args):
    target = args.target
    rustc = Path(shutil.which(args.cargo) or args.cargo).absolute().parent / 'rustc'
    rustc_command = os.environ.get('RUSTC') or (str(rustc) if os.access(rustc, os.X_OK) else 'rustc')
    cargo_env = dict(os.environ, RUSTC=rustc_command)
    if not target:
        target = next(line.split(': ', 1)[1] for line in run(rustc_command, '-vV').splitlines()
                      if line.startswith('host: '))
    metadata = json.loads(run(args.cargo, 'metadata', '--format-version', '1',
                              '--locked', '--offline', '--filter-platform', target,
                              '--manifest-path', str(Path(args.manifest_path).resolve()), env=cargo_env))
    resolve = metadata['resolve']
    root = resolve['root']
    if not root:
        raise ValueError('Manifest must select the backend package, not a virtual workspace')
    nodes = {node['id']: node for node in resolve['nodes']}
    packages = {package['id']: package for package in metadata['packages']}
    visited, pending = set(), [root]
    while pending:
        package_id = pending.pop()
        if package_id in visited:
            continue
        visited.add(package_id)
        # Cargo has already applied platform filtering. Keep every dependency
        # kind, including build dependencies and their transitive dependencies.
        pending.extend(dep['pkg'] for dep in nodes[package_id]['deps'])
    output = Path(args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.ios-usb-licenses-', dir=output.parent))
    try:
        index = []
        destinations = set()
        for package_id in sorted(visited - {root}, key=lambda key: (packages[key]['name'], packages[key]['version'], key)):
            package = packages[package_id]
            name, version = package['name'], package['version']
            key = f'{name}-{version}'
            if key in destinations:
                raise ValueError(f'Duplicate package output: {key}')
            destinations.add(key)
            crate = Path(package['manifest_path']).parent
            if not crate.is_dir():
                raise ValueError(f'Missing downloaded crate source: {key}')
            files = {path.relative_to(crate): path for path in crate.rglob('*')
                     if path.name.upper().startswith(PREFIXES) and path.is_file()}
            if package.get('license_file'):
                path = crate / package['license_file']
                if not path.is_file():
                    raise ValueError(f'Missing declared license_file: {key}')
                relative = Path(os.path.relpath(path, crate))
                # Keep outside-crate declarations safely inside this package.
                if '..' in relative.parts:
                    relative = Path('declared-license') / path.name
                files[relative] = path
            if not files and name == 'idevice' and package.get('license') == 'MIT':
                # The pinned idevice package inherits its workspace's MIT text.
                workspace = crate.parent
                if (workspace / 'Cargo.toml').is_file():
                    files.update({Path(path.name): path for path in workspace.iterdir()
                                  if path.is_file() and path.name.upper().startswith(PREFIXES)})
            provenance = None
            if not files:
                files, provenance = supplemental(package, crate, args.manifest_path)
            if not files:
                raise ValueError(f'No license source files found for {key}')
            copied = []
            for relative, source in sorted(files.items()):
                destination = staging / 'Dependencies' / key / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)
                copied.append(relative.as_posix())
            index.append({'name': name, 'version': version, 'SPDX': package.get('license'),
                          'source': package.get('source') or 'local', 'files': copied,
                          'license_provenance': provenance or {'classification': 'downloaded-crate-or-workspace'}})
        (staging / 'Dependencies').mkdir(exist_ok=True)
        (staging / 'Dependencies' / 'index.json').write_text(json.dumps({'target': target, 'dependencies': index}, indent=2) + '\n')
        if output.exists():
            shutil.rmtree(output)
        staging.rename(output)
        print(f'Collected licenses for {len(index)} dependencies into {output}')
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cargo', default='cargo', help='Cargo executable (default: cargo)')
    parser.add_argument('--manifest-path', required=True, help='Backend Cargo.toml')
    parser.add_argument('--target', help='Cargo target triple (default: rustc host)')
    parser.add_argument('--output', required=True, help='Destination license directory')
    args = parser.parse_args()
    try:
        collect(args)
    except (OSError, ValueError, KeyError, StopIteration, subprocess.CalledProcessError) as error:
        parser.exit(1, f'error: License collection failed: {error}\n')


if __name__ == '__main__':
    main()
