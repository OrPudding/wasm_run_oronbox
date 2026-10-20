import 'dart:typed_data';

void validateNativeLibrary(Uint8List bytes, String target) {
  Never invalid(String reason) => throw FormatException('$target: $reason');
  if (bytes.length < 64) invalid('truncated native library');
  final data = ByteData.sublistView(bytes);
  if (target.contains('android') || target.contains('linux')) {
    if (data.getUint32(0, Endian.big) != 0x7f454c46) {
      invalid('expected ELF shared library');
    }
    if (bytes[5] != 1 || data.getUint16(16, Endian.little) != 3) {
      invalid('expected little-endian ET_DYN');
    }
    final is64 = bytes[4] == 2;
    final expectedMachine = target.startsWith('aarch64-')
        ? 183
        : target.startsWith('x86_64-')
        ? 62
        : target.startsWith('armv7-')
        ? 40
        : target.startsWith('i686-')
        ? 3
        : -1;
    if (data.getUint16(18, Endian.little) != expectedMachine) {
      invalid('wrong ELF architecture');
    }
    if (is64 != (expectedMachine == 183 || expectedMachine == 62)) {
      invalid('wrong ELF class');
    }
    if (target.contains('android')) {
      final offset = is64
          ? data.getUint64(32, Endian.little)
          : data.getUint32(28, Endian.little);
      final stride = data.getUint16(is64 ? 54 : 42, Endian.little);
      final count = data.getUint16(is64 ? 56 : 44, Endian.little);
      if (stride < (is64 ? 56 : 32) ||
          count == 0 ||
          offset + stride * count > bytes.length) {
        invalid('invalid program headers');
      }
      var loads = 0;
      for (var index = 0; index < count; index++) {
        final start = offset + index * stride;
        if (data.getUint32(start, Endian.little) != 1) continue;
        loads++;
        final alignment = is64
            ? data.getUint64(start + 48, Endian.little)
            : data.getUint32(start + 28, Endian.little);
        if (alignment < 16384) invalid('LOAD segment is not 16 KiB aligned');
      }
      if (loads == 0) invalid('missing load segments');
    }
  } else if (target.contains('apple')) {
    // Universal Apple libraries are not used: each hook builds one exact target.
    if (data.getUint32(0, Endian.little) != 0xfeedfacf) {
      invalid('expected 64-bit Mach-O');
    }
    final expectedCpu = target.startsWith('aarch64-') ? 0x0100000c : 0x01000007;
    if (data.getUint32(4, Endian.little) != expectedCpu) {
      invalid('wrong Mach-O architecture');
    }
    if (data.getUint32(12, Endian.little) != 6) {
      invalid('expected Mach-O dynamic library');
    }
    var cursor = 32;
    var platformFound = false;
    for (var index = 0; index < data.getUint32(16, Endian.little); index++) {
      if (cursor + 8 > bytes.length) invalid('truncated load commands');
      final command = data.getUint32(cursor, Endian.little);
      final length = data.getUint32(cursor + 4, Endian.little);
      if (length < 8 || cursor + length > bytes.length) {
        invalid('invalid load command');
      }
      if (command == 0x32 && length >= 24) {
        final expectedPlatform =
            target.contains('ios-sim') || target == 'x86_64-apple-ios'
            ? 7
            : target.contains('ios')
            ? 2
            : 1;
        if (data.getUint32(cursor + 8, Endian.little) != expectedPlatform) {
          invalid('wrong Apple platform');
        }
        platformFound = true;
      } else if (command == 0x24 && length >= 16) {
        if (!target.endsWith('apple-darwin')) {
          invalid('macOS library used for iOS');
        }
        platformFound = true;
      } else if (command == 0x25 && length >= 16) {
        if (!target.contains('apple-ios') || target.contains('ios-sim')) {
          invalid('wrong legacy Apple platform');
        }
        platformFound = true;
      }
      cursor += length;
    }
    if (!platformFound) invalid('missing Apple platform metadata');
  } else if (target.contains('windows')) {
    if (data.getUint16(0, Endian.little) != 0x5a4d) {
      invalid('expected PE library');
    }
    final pe = data.getUint32(60, Endian.little);
    if (pe + 24 > bytes.length || data.getUint32(pe, Endian.little) != 0x4550) {
      invalid('invalid PE header');
    }
    final expectedMachine = target.startsWith('aarch64-') ? 0xaa64 : 0x8664;
    if (data.getUint16(pe + 4, Endian.little) != expectedMachine ||
        data.getUint16(pe + 22, Endian.little) & 0x2000 == 0) {
      invalid('wrong PE architecture or not a DLL');
    }
  } else {
    invalid('unsupported native target');
  }
}
