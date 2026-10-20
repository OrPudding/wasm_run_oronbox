import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../hook/precompiled.dart';

Uint8List _library() {
  final data = ByteData(120);
  data.setUint32(0, 0x7f454c46, Endian.big);
  data.setUint8(4, 2);
  data.setUint8(5, 1);
  data.setUint16(16, 3, Endian.little);
  data.setUint16(18, 183, Endian.little);
  data.setUint64(32, 64, Endian.little);
  data.setUint16(54, 56, Endian.little);
  data.setUint16(56, 1, Endian.little);
  data.setUint32(64, 1, Endian.little);
  data.setUint64(112, 16384, Endian.little);
  return data.buffer.asUint8List();
}

void main() {
  late Directory temporary, package, output;
  late HttpServer server;
  late Map<String, Object> manifest;
  late Uint8List bytes;
  var downloads = 0;
  const target = 'aarch64-linux-android';
  const asset = 'wasm_run-$target-wasmtime.so';
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('wasm-precompiled-test-');
    package = Directory('${temporary.path}/package');
    output = Directory('${temporary.path}/output');
    for (final path in ['native/src', 'native/locks']) {
      await Directory('${package.path}/$path').create(recursive: true);
    }
    await File('${package.path}/native_release.json').writeAsString(
      jsonEncode({
        'tag': 'wasm_run-v0.2.0-test',
        'repository': 'OrPudding/wasm_run_oronbox',
      }),
    );
    await File('${package.path}/native/src/lib.rs').writeAsString('source');
    final fingerprint = await nativeSourceFingerprint(package);
    bytes = _library();
    downloads = 0;
    manifest = {
      'schema': 1,
      'tag': 'wasm_run-v0.2.0-test',
      'sourceFingerprint': fingerprint,
      'libraries': {
        target: {
          'target': target,
          'backend': 'wasmtime',
          'asset': asset,
          'sourceFingerprint': fingerprint,
          'size': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        },
      },
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      downloads++;
      if (request.uri.path.endsWith('manifest.json'))
        request.response.write(jsonEncode(manifest));
      else
        request.response.add(bytes);
      await request.response.close();
    });
  });
  tearDown(() async {
    await server.close(force: true);
    await temporary.delete(recursive: true);
  });
  Future<File> fetch() => precompiledLibrary(
    package: package,
    output: output,
    target: target,
    releaseBase: Uri.parse('http://127.0.0.1:${server.port}/'),
  );
  test(
    'verified cache supports subsequent builds without network access',
    () async {
      final file = await fetch();
      expect(file.uri.pathSegments.last, 'libwasm_run_dart.so');
      expect(await file.readAsBytes(), bytes);
      expect(downloads, 2);
      await fetch();
      expect(downloads, 2);
    },
  );
  test(
    'source edits reject the old release instead of silently using it',
    () async {
      await File('${package.path}/native/src/lib.rs').writeAsString('changed');
      await expectLater(fetch(), throwsStateError);
      expect(downloads, 1);
    },
  );
  test('corrupted download never becomes a cached native library', () async {
    bytes[40] = 1;
    await expectLater(fetch(), throwsFormatException);
    expect(await File('${output.path}/precompiled/$asset').exists(), isFalse);
  });
  test(
    'wrong architecture is rejected even with a matching checksum',
    () async {
      ByteData.sublistView(bytes).setUint16(18, 62, Endian.little);
      final libraries = manifest['libraries'] as Map;
      (libraries[target] as Map)['sha256'] = sha256.convert(bytes).toString();
      await expectLater(fetch(), throwsFormatException);
    },
  );
  test('cache corruption is replaced with a verified download', () async {
    final file = await fetch();
    await file.writeAsString('broken');
    await fetch();
    expect(file.uri.pathSegments.last, 'libwasm_run_dart.so');
      expect(await file.readAsBytes(), bytes);
    expect(downloads, 3);
  });
  test('checkout line endings do not change the source fingerprint', () async {
    final source = File('${package.path}/native/src/lib.rs');
    await source.writeAsString('fn main() {\n}\n');
    final original = await nativeSourceFingerprint(package);
    await source.writeAsString('fn main() {\r\n}\r\n');
    expect(await nativeSourceFingerprint(package), original);
    await source.writeAsString('fn changed() {\r\n}\r\n');
    expect(await nativeSourceFingerprint(package), isNot(original));
  });
}
