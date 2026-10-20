import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'native_library.dart';

String runtimeForTarget(String target) =>
    target.contains('apple-ios') ||
        target.startsWith('armv7-') ||
        target.startsWith('i686-') ||
        target == 'x86_64-linux-android'
    ? 'wasmi'
    : 'wasmtime';

Future<String> nativeSourceFingerprint(Directory package) async {
  final files = <File>[
    File.fromUri(package.uri.resolve('native_release.json')),
  ];
  for (final directory in ['native/src/', 'native/locks/']) {
    await for (final file in Directory.fromUri(
      package.uri.resolve(directory),
    ).list(recursive: true)) {
      if (file is File &&
          !file.path.endsWith('${Platform.pathSeparator}api.rs'))
        files.add(file);
    }
  }
  await for (final file in Directory.fromUri(
    package.uri.resolve('native/'),
  ).list()) {
    if (file is File &&
        RegExp(r'^Cargo\..+\.toml$').hasMatch(file.uri.pathSegments.last))
      files.add(file);
  }
  String relative(File file) => file.path
      .substring(
        package.path.length +
            (package.path.endsWith(Platform.pathSeparator) ? 0 : 1),
      )
      .replaceAll(Platform.pathSeparator, '/');
  files.sort((a, b) => relative(a).compareTo(relative(b)));
  final chunks = BytesBuilder(copy: false);
  for (final file in files) {
    chunks.add(utf8.encode(relative(file)));
    chunks.addByte(0);
    chunks.add(_canonicalSourceBytes(await file.readAsBytes()));
    chunks.addByte(0);
  }
  return sha256.convert(chunks.takeBytes()).toString();
}

// Git may check out the same text as LF or CRLF. Preserve every other byte.
Uint8List _canonicalSourceBytes(Uint8List bytes) {
  final output = BytesBuilder(copy: false);
  var start = 0;
  for (var index = 0; index + 1 < bytes.length; index++) {
    if (bytes[index] == 13 && bytes[index + 1] == 10) {
      output.add(Uint8List.sublistView(bytes, start, index));
      start = index + 1;
    }
  }
  if (start == 0) return bytes;
  output.add(Uint8List.sublistView(bytes, start));
  return output.takeBytes();
}

/// Downloads build-time artifacts. No application runtime networking is used.
Future<File> precompiledLibrary({
  required Directory package,
  required Directory output,
  required String target,
  Uri? releaseBase,
}) async {
  final config = jsonDecode(
    await File.fromUri(package.uri.resolve('native_release.json'))
        .readAsString(),
  ) as Map<String, dynamic>;
  final tag = config['tag'] as String;
  final repository = config['repository'] as String;
  if (!RegExp(r'^wasm_run-v[0-9A-Za-z.+_-]+$').hasMatch(tag) ||
      !RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository)) {
    throw const FormatException('Invalid native release configuration');
  }
  final base =
      releaseBase ??
      Uri.https('github.com', '/$repository/releases/download/$tag/');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  final cache = Directory.fromUri(output.uri.resolve('precompiled/'));
  await cache.create(recursive: true);
  final fingerprint = await nativeSourceFingerprint(package);
  final manifestFile = File.fromUri(cache.uri.resolve('manifest.json'));
  try {
    Map<String, dynamic>? manifest;
    if (await manifestFile.exists()) {
      try {
        final candidate = jsonDecode(
          await manifestFile.readAsString(),
        ) as Map<String, dynamic>;
        if (candidate['tag'] == tag &&
            candidate['sourceFingerprint'] == fingerprint)
          manifest = candidate;
      } on FormatException {
        // Replace an interrupted cache entry.
      } on TypeError {
        // Replace structurally invalid cached JSON.
      }
    }
    if (manifest == null) {
      final bytes = await _download(
        client,
        base.resolve('manifest.json'),
        1024 * 1024,
      );
      manifest = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      await _atomicWrite(manifestFile, bytes);
    }
    if (manifest['schema'] != 1 ||
        manifest['tag'] != tag ||
        manifest['sourceFingerprint'] != fingerprint) {
      throw StateError(
        'Native release does not match these sources. Set WASM_RUN_BUILD_FROM_SOURCE=1 for local changes.',
      );
    }
    final entries = manifest['libraries'] as Map<String, dynamic>;
    final entry = entries[target] as Map<String, dynamic>?;
    if (entry == null)
      throw UnsupportedError(
        'No precompiled library for $target. Set WASM_RUN_BUILD_FROM_SOURCE=1.',
      );
    final asset = entry['asset'] as String;
    final expectedHash = entry['sha256'] as String;
    final size = entry['size'] as int;
    final suffix = target.contains('windows')
        ? '.dll'
        : target.contains('apple')
        ? '.dylib'
        : '.so';
    if (entry['target'] != target ||
        entry['backend'] != runtimeForTarget(target) ||
        entry['sourceFingerprint'] != fingerprint ||
        asset != 'wasm_run-$target-${runtimeForTarget(target)}$suffix' ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedHash) ||
        size <= 0 ||
        size > 256 * 1024 * 1024) {
      throw const FormatException('Invalid native artifact metadata');
    }
    final libraryName = target.contains('windows')
        ? 'wasm_run_dart.dll'
        : 'libwasm_run_dart$suffix';
    final file = File.fromUri(cache.uri.resolve(libraryName));
    bool valid(List<int> bytes) =>
        bytes.length == size &&
        sha256.convert(bytes).toString() == expectedHash;
    if (await file.exists() && !valid(await file.readAsBytes()))
      await file.delete();
    if (!await file.exists()) {
      final bytes = await _download(client, base.resolve(asset), size);
      if (!valid(bytes))
        throw const FormatException('Native artifact checksum mismatch');
      await _atomicWrite(file, bytes);
    }
    validateNativeLibrary(await file.readAsBytes(), target);
    return file;
  } finally {
    client.close(force: true);
  }
}

Future<List<int>> _download(HttpClient client, Uri uri, int limit) async {
  final request = await client.getUrl(uri).timeout(const Duration(seconds: 30));
  final response = await request.close().timeout(const Duration(seconds: 30));
  if (response.statusCode != 200) {
    await response.drain<void>().timeout(const Duration(seconds: 30));
    throw HttpException(
      'Native artifact HTTP ${response.statusCode}. Set WASM_RUN_BUILD_FROM_SOURCE=1 to build locally.',
      uri: uri,
    );
  }
  if (response.contentLength > limit)
    throw const FormatException('Native artifact exceeds size limit');
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in response.timeout(const Duration(seconds: 30))) {
    if (bytes.length + chunk.length > limit)
      throw const FormatException('Native artifact exceeds size limit');
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Future<void> _atomicWrite(File destination, List<int> bytes) async {
  final temporary = File('${destination.path}.$pid.tmp');
  try {
    await temporary.writeAsBytes(bytes, flush: true);
    if (await destination.exists()) await destination.delete();
    await temporary.rename(destination.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}
