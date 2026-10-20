import 'dart:io';

import 'package:build_rust_binaries/build_rust_binaries.dart';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

import 'native_library.dart';
import 'precompiled.dart';

Future<void> main(List<String> args) => build(args, (input, output) async {
  if (!input.config.buildCodeAssets) return;
  final inferred = BuildInputParams.fromBuildInput(
    input,
    libraryName: 'wasm_run_dart',
  );
  final target = inferred.rustTarget;
  // Linking being enabled does not mean a dynamically loaded asset is static.
  final params = BuildInputParams(
    outputDirectory: input.outputDirectory,
    rustTarget: target,
    buildStatic: false,
    libraryName: 'wasm_run_dart',
    buildInput: input,
  );
  final package = Directory.fromUri(input.packageRoot);
  final sourceFiles = Directory.fromUri(input.packageRoot.resolve('native/'));
  output.dependencies.add(input.packageRoot.resolve('native_release.json'));
  for (final file in sourceFiles.listSync(recursive: true)) {
    if (file is File &&
        !file.path.contains(
          '${Platform.pathSeparator}target${Platform.pathSeparator}',
        )) {
      output.dependencies.add(file.uri);
    }
  }
  if (Platform.environment['WASM_RUN_BUILD_FROM_SOURCE'] != '1') {
    final library = await precompiledLibrary(
      package: package,
      output: Directory.fromUri(input.outputDirectory),
      target: target,
    );
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/rust/frb_generated.io.dart',
        linkMode: DynamicLoadingBundled(),
        file: library.uri,
      ),
    );
    return;
  }
  final source = Directory.fromUri(input.packageRoot.resolve('native/'));
  final working = Directory.fromUri(input.outputDirectory.resolve('native/'));
  await working.create(recursive: true);
  for (final entity in source.listSync(recursive: true)) {
    if (entity is! File ||
        entity.path.contains(
          '${Platform.pathSeparator}target${Platform.pathSeparator}',
        )) {
      continue;
    }
    final relative = entity.path.substring(
      source.path.length +
          (source.path.endsWith(Platform.pathSeparator) ? 0 : 1),
    );
    final destination = File.fromUri(
      working.uri.resolveUri(Uri.file(relative, windows: Platform.isWindows)),
    );
    await destination.parent.create(recursive: true);
    if (!destination.existsSync() ||
        !_same(entity.readAsBytesSync(), destination.readAsBytesSync())) {
      await entity.copy(destination.path);
    }
    output.dependencies.add(entity.uri);
  }
  final backend = runtimeForTarget(target);
  await File.fromUri(working.uri.resolve('Cargo.$backend.toml'))
      .copy(File.fromUri(working.uri.resolve('Cargo.toml')).path);
  await File.fromUri(working.uri.resolve('src/api_$backend.rs'))
      .copy(File.fromUri(working.uri.resolve('src/api.rs')).path);
  final lock = File.fromUri(source.uri.resolve('locks/$backend.lock'));
  if (!lock.existsSync()) {
    throw StateError('Missing locked Rust dependencies for $backend');
  }
  await lock.copy(File.fromUri(working.uri.resolve('Cargo.lock')).path);
  final builder =
      SourceBinariesParams(
        fetchAssetUrl: null,
        runProcess: (_, command) async {
          final flags = Platform.environment['RUSTFLAGS'] ?? '';
          final isCargo = command.executable == 'cargo';
          final androidEnvironment = <String, String>{};
          if (target.contains('android')) {
            final compiler = input.config.code.cCompiler?.compiler;
            if (compiler == null) {
              throw StateError('Android NDK compiler is missing');
            }
            final bin = compiler.resolve('./');
            final clangTarget = target.startsWith('armv7-')
                ? 'armv7a-linux-androideabi'
                : target;
            final cc = bin
                .resolve(
                  '$clangTarget'
                  '24-clang${Platform.isWindows ? '.cmd' : ''}',
                )
                .toFilePath();
            final cxx = bin
                .resolve(
                  '$clangTarget'
                  '24-clang++${Platform.isWindows ? '.cmd' : ''}',
                )
                .toFilePath();
            final key = target.replaceAll('-', '_');
            androidEnvironment.addAll({
              'CC_$key': cc,
              'CXX_$key': cxx,
              'AR_$key': bin
                  .resolve('llvm-ar${Platform.isWindows ? '.exe' : ''}')
                  .toFilePath(),
              'CARGO_TARGET_${key.toUpperCase()}_LINKER': cc,
            });
          }

          await CliCommand.defaultRunProcess(
            CliCommand(
              command.executable,
              [
                for (final arg in command.args) ...[
                  if (isCargo && arg == '--') '--locked',
                  arg,
                ],
              ],
              workingDirectory: command.workingDirectory,
              environment: {
                ...?command.environment,
                ...androidEnvironment,
                if (target.contains('android'))
                  'RUSTFLAGS': '$flags -C link-arg=-Wl,-z,max-page-size=16384',
              },
            ),
          );
        },
      ).createBuildMode(
        params,
        SourceBinariesOptions(
          buildMode: BuildModeEnum.checkout,
          checkoutPath: working.uri,
          libraryName: 'wasm_run_dart',
          androidVersion: '24',
        ),
      );
  final library = await builder.build();
  validateNativeLibrary(File.fromUri(library).readAsBytesSync(), target);
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'src/rust/frb_generated.io.dart',
      linkMode: DynamicLoadingBundled(),
      file: library,
    ),
  );
  output.dependencies.add(input.packageRoot.resolve('pubspec.yaml'));
});

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
