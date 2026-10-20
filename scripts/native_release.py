#!/usr/bin/env python3
"""Build exact-target libraries and assemble a verified release manifest."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import struct
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / 'packages/wasm_run'
TARGETS = {
    'aarch64-linux-android', 'armv7-linux-androideabi', 'x86_64-linux-android',
    'x86_64-pc-windows-msvc', 'x86_64-unknown-linux-gnu', 'aarch64-unknown-linux-gnu',
    'aarch64-apple-darwin', 'x86_64-apple-darwin', 'aarch64-apple-ios',
    'aarch64-apple-ios-sim', 'x86_64-apple-ios',
}

def backend(target):
    return 'wasmi' if 'apple-ios' in target or target.startswith(('armv7-', 'i686-')) or target == 'x86_64-linux-android' else 'wasmtime'

def source_files():
    native = PACKAGE / 'native'
    paths = [PACKAGE / 'native_release.json']
    paths += list((native / 'src').rglob('*'))
    paths += list((native / 'locks').glob('*.lock'))
    paths += list(native.glob('Cargo.*.toml'))
    return sorted((p for p in paths if p.is_file() and p != native / 'src/api.rs'), key=lambda p: p.relative_to(PACKAGE).as_posix())

def fingerprint():
    digest = hashlib.sha256()
    for path in source_files():
        digest.update(path.relative_to(PACKAGE).as_posix().encode() + b'\0')
        digest.update(path.read_bytes().replace(b'\r\n', b'\n'))
        digest.update(b'\0')
    return digest.hexdigest()

def validate_binary(data, target):
    def read(fmt, offset):
        try: return struct.unpack_from('<' + fmt, data, offset)[0]
        except struct.error as error: raise ValueError('Truncated native library') from error
    if len(data) < 64: raise ValueError('Truncated native library')
    if 'android' in target or 'linux' in target:
        machine = 183 if target.startswith('aarch64-') else 40 if target.startswith('armv7-') else 62
        wide = machine != 40
        if data[:4] != b'\x7fELF' or data[4] != (2 if wide else 1) or data[5] != 1 or read('H', 16) != 3 or read('H', 18) != machine:
            raise ValueError('Wrong ELF architecture/type')
        if 'android' in target:
            offset = read('Q' if wide else 'I', 32 if wide else 28)
            stride, count = read('H', 54 if wide else 42), read('H', 56 if wide else 44)
            if not count or stride < (56 if wide else 32) or offset + stride * count > len(data):
                raise ValueError('Invalid ELF program headers')
            loads = [offset + i * stride for i in range(count) if read('I', offset + i * stride) == 1]
            if not loads or any(read('Q' if wide else 'I', item + (48 if wide else 28)) < 16384 for item in loads):
                raise ValueError('Android library is not 16 KB aligned')
    elif 'apple' in target:
        machine = 0x100000c if target.startswith('aarch64-') else 0x1000007
        if read('I', 0) != 0xfeedfacf or read('I', 4) != machine or read('I', 12) != 6:
            raise ValueError('Wrong Mach-O architecture/type')
        expected = 7 if target.endswith('ios-sim') or target == 'x86_64-apple-ios' else 2 if 'ios' in target else 1
        cursor, found = 32, False
        for _ in range(read('I', 16)):
            command, size = read('I', cursor), read('I', cursor + 4)
            if size < 8 or cursor + size > len(data): raise ValueError('Invalid Mach-O commands')
            if command == 0x32:
                if size < 24 or read('I', cursor + 8) != expected: raise ValueError('Wrong Apple platform')
                found = True
            elif command in (0x24, 0x25):
                if (command == 0x24 and expected != 1) or (command == 0x25 and expected != 2):
                    raise ValueError('Wrong legacy Apple platform')
                found = True
            cursor += size
        if not found: raise ValueError('Missing Apple platform metadata')
    elif 'windows' in target:
        offset = read('I', 60)
        if data[:2] != b'MZ' or data[offset:offset + 4] != b'PE\0\0' or read('H', offset + 4) != 0x8664 or not read('H', offset + 22) & 0x2000:
            raise ValueError('Wrong PE architecture/type')
    else: raise ValueError('Unsupported native target')

def build(target, output):
    if target not in TARGETS:
        raise ValueError('Unsupported target')
    runtime = backend(target)
    env = os.environ.copy()
    with tempfile.TemporaryDirectory(prefix='wasm-run-native-') as temporary:
        work = Path(temporary) / 'native'
        shutil.copytree(PACKAGE / 'native', work, ignore=shutil.ignore_patterns('target'))
        shutil.copyfile(work / f'Cargo.{runtime}.toml', work / 'Cargo.toml')
        shutil.copyfile(work / f'src/api_{runtime}.rs', work / 'src/api.rs')
        shutil.copyfile(work / f'locks/{runtime}.lock', work / 'Cargo.lock')
        if 'android' in target:
            ndk = Path(env['ANDROID_NDK_HOME'])
            prebuilt = next((ndk / 'toolchains/llvm/prebuilt').iterdir()) / 'bin'
            clang_target = 'armv7a-linux-androideabi' if target.startswith('armv7-') else target
            cc = str(prebuilt / f'{clang_target}24-clang')
            key = target.replace('-', '_')
            env.update({f'CC_{key}': cc, f'CXX_{key}': cc + '++',
                        f'AR_{key}': str(prebuilt / 'llvm-ar'),
                        f'CARGO_TARGET_{key.upper()}_LINKER': cc})
            env['RUSTFLAGS'] = env.get('RUSTFLAGS', '') + ' -C link-arg=-Wl,-z,max-page-size=16384'
        if 'apple-ios' in target:
            env['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
        if 'apple-darwin' in target:
            env['MACOSX_DEPLOYMENT_TARGET'] = '11.0'
        env['CARGO_TARGET_DIR'] = str(work / 'target')
        subprocess.run(['cargo', 'rustc', '--locked', '--release', '--target', target,
                        '--lib', '--crate-type', 'cdylib'], cwd=work, env=env, check=True)
        filename = 'wasm_run_dart.dll' if 'windows' in target else 'libwasm_run_dart.dylib' if 'apple' in target else 'libwasm_run_dart.so'
        output.mkdir(parents=True, exist_ok=True)
        asset = f'wasm_run-{target}-{runtime}' + Path(filename).suffix
        shutil.copyfile(work / 'target' / target / 'release' / filename, output / asset)
        data = (output / asset).read_bytes()
        validate_binary(data, target)
        metadata = dict(target=target, backend=runtime, asset=asset, size=len(data),
                        sha256=hashlib.sha256(data).hexdigest(), sourceFingerprint=fingerprint(),
                        rustVersion=subprocess.check_output(['rustc', '--version'], text=True).strip())
        (output / f'{target}.json').write_text(json.dumps(metadata, indent=2) + '\n')

def manifest(directory, tag):
    config = json.loads((PACKAGE / 'native_release.json').read_text())
    if tag != config['tag']:
        raise ValueError('Tag must match native_release.json')
    entries = [json.loads(p.read_text()) for p in sorted(directory.glob('*.json')) if p.name != 'manifest.json']
    if len(entries) != len(TARGETS) or {e['target'] for e in entries} != TARGETS:
        raise ValueError('Incomplete or duplicate release targets')
    expected_fingerprint = fingerprint()
    for entry in entries:
        path = directory / entry['asset']
        if entry['sourceFingerprint'] != expected_fingerprint:
            raise ValueError(f"Source fingerprint mismatch for {entry['target']}: expected {expected_fingerprint}, got {entry['sourceFingerprint']}")
        if entry['backend'] != backend(entry['target']):
            raise ValueError(f"Runtime mismatch for {entry['target']}: expected {backend(entry['target'])}, got {entry['backend']}")
        data = path.read_bytes()
        validate_binary(data, entry['target'])
        if len(data) != entry['size'] or hashlib.sha256(data).hexdigest() != entry['sha256']:
            raise ValueError('Artifact checksum mismatch')
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    result = dict(schema=1, tag=tag, sourceCommit=commit, sourceFingerprint=expected_fingerprint,
                  libraries={e['target']: e for e in entries})
    (directory / 'manifest.json').write_text(json.dumps(result, indent=2) + '\n')
    (directory / 'SHA256SUMS').write_text(''.join(f"{e['sha256']}  {e['asset']}\n" for e in entries))

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='operation', required=True)
    command = sub.add_parser('build'); command.add_argument('target'); command.add_argument('output', type=Path)
    command = sub.add_parser('manifest'); command.add_argument('directory', type=Path); command.add_argument('tag')
    sub.add_parser('fingerprint')
    args = parser.parse_args()
    if args.operation == 'build': build(args.target, args.output)
    elif args.operation == 'manifest': manifest(args.directory, args.tag)
    else: print(fingerprint())
