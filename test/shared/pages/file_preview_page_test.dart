import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/pages/file_preview_page.dart';

/// The page reads via real dart:io; each future completes on the real event
/// loop, so pump+runAsync must cycle until the state lands.
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $finder');
}

void main() {
  Directory tempDir() {
    // Sync creation: async dart:io futures never complete in the test's
    // FakeAsync zone without runAsync.
    final tmp = Directory.systemTemp.createTempSync('preview_page_test_');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    return tmp;
  }

  testWidgets('binary file error state offers the system-open escape hatch', (
    tester,
  ) async {
    final tmp = tempDir();
    final path = '${tmp.path}/blob.dat';
    // Null byte in the pilot window — the binary probe must reject it.
    File(path).writeAsBytesSync([0x00, 0x01, 0x02, 0x03]);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: FilePreviewPage(hostPath: path, displayName: 'blob.dat'),
      ),
    );

    final l10n = AppLocalizations.of(
      tester.element(find.byType(FilePreviewPage)),
    )!;
    await pumpUntilFound(
      tester,
      find.text(l10n.mountFilesPreviewBinary('blob.dat')),
    );
    // The dead-end is removed: a system-open action is offered.
    expect(find.text(l10n.filePreviewOpenWithSystem), findsOneWidget);
  });

  testWidgets('text preview state shows no system-open button (no escape '
      'hatch needed)', (tester) async {
    final tmp = tempDir();
    final path = '${tmp.path}/notes.txt';
    File(path).writeAsStringSync('plain text');

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: FilePreviewPage(hostPath: path, displayName: 'notes.txt'),
      ),
    );

    final l10n = AppLocalizations.of(
      tester.element(find.byType(FilePreviewPage)),
    )!;
    await pumpUntilFound(tester, find.text('plain text'));
    expect(find.text(l10n.filePreviewOpenWithSystem), findsNothing);
  });
}
