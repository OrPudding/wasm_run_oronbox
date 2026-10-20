import 'dart:typed_data';

import 'package:test/test.dart';

import '../hook/native_library.dart';

Uint8List _elf({int machine = 183, int alignment = 16384}) {
  final data = ByteData(120);
  data.setUint32(0, 0x7f454c46, Endian.big);
  data.setUint8(4, 2);
  data.setUint8(5, 1);
  data.setUint16(16, 3, Endian.little);
  data.setUint16(18, machine, Endian.little);
  data.setUint64(32, 64, Endian.little);
  data.setUint16(54, 56, Endian.little);
  data.setUint16(56, 1, Endian.little);
  data.setUint32(64, 1, Endian.little);
  data.setUint64(112, alignment, Endian.little);
  return data.buffer.asUint8List();
}

void main() {
  const target = 'aarch64-linux-android';
  test('rejects Apple library renamed to so', () {
    final bytes = Uint8List(128)..setRange(0, 4, [0xca, 0xfe, 0xba, 0xbe]);
    expect(() => validateNativeLibrary(bytes, target), throwsFormatException);
  });
  test('rejects library for a different Android ABI', () {
    expect(
      () => validateNativeLibrary(_elf(machine: 62), target),
      throwsFormatException,
    );
  });
  test('rejects upstream 4 KiB load segment alignment', () {
    expect(
      () => validateNativeLibrary(_elf(alignment: 4096), target),
      throwsFormatException,
    );
  });
  test('accepts matching Android shared library header', () {
    expect(() => validateNativeLibrary(_elf(), target), returnsNormally);
  });
}
