import 'dart:convert';

import 'package:Cuplivo/core/services/workspace/linux_sandbox_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LinuxSandboxService.boundOutput', () {
    test('leaves short output untouched', () {
      const value = 'hello';
      expect(LinuxSandboxService.boundOutput(value), value);
    });

    test('truncates long ASCII output with a marker', () {
      final value = 'x' * (LinuxSandboxService.maxOutputChars + 100);
      final out = LinuxSandboxService.boundOutput(value);
      expect(out.length, lessThanOrEqualTo(LinuxSandboxService.maxOutputChars));
      expect(out, contains('...[truncated]...'));
      expect(() => jsonEncode(out), returnsNormally);
    });

    test('never splits a surrogate pair at the head cut', () {
      const marker = '\n...[truncated]...\n';
      final head = (LinuxSandboxService.maxOutputChars - marker.length) ~/ 2;
      // '😀' is U+1F600 = \uD83D\uDE00, a true surrogate pair (two code
      // units). Its high surrogate lands at head-1 and its low at head, so
      // the head cut falls exactly between them.
      final value =
          '${'a' * (head - 1)}😀'
          '${'b' * (LinuxSandboxService.maxOutputChars - head + 20)}';
      final out = LinuxSandboxService.boundOutput(value);
      expectValidUtf16(out);
      expect(() => jsonEncode(out), returnsNormally);
    });

    test('never splits a surrogate pair at the tail cut', () {
      const marker = '\n...[truncated]...\n';
      final available = LinuxSandboxService.maxOutputChars - marker.length;
      final head = available ~/ 2;
      final tail = available - head;
      final total = LinuxSandboxService.maxOutputChars + 24;
      final tailStart = total - tail;
      // '😀' straddles the tail start: its high surrogate is at tailStart-1
      // and its low at tailStart, so the tail cut falls exactly between them.
      final value =
          '${'a' * (tailStart - 1)}😀${'b' * (total - tailStart - 1)}';
      final out = LinuxSandboxService.boundOutput(value);
      expectValidUtf16(out);
      expect(() => jsonEncode(out), returnsNormally);
    });
  });
}

void expectValidUtf16(String value) {
  for (var i = 0; i < value.length; i++) {
    final codeUnit = value.codeUnitAt(i);
    if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF) {
      expect(
        i + 1 < value.length &&
            value.codeUnitAt(i + 1) >= 0xDC00 &&
            value.codeUnitAt(i + 1) <= 0xDFFF,
        isTrue,
        reason: 'lone high surrogate at $i',
      );
      i++;
    } else if (codeUnit >= 0xDC00 && codeUnit <= 0xDFFF) {
      fail('lone low surrogate at $i');
    }
  }
}
