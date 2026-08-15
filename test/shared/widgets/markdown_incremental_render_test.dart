import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/markdown_with_highlight.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

Widget _streamingHarness(
  ValueListenable<String> text, {
  Map<String, Object>? preferences,
}) {
  SharedPreferences.setMockInitialValues(preferences ?? const {});
  return ChangeNotifierProvider(
    create: (_) => SettingsProvider(),
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: ValueListenableBuilder<String>(
            valueListenable: text,
            builder: (context, value, _) =>
                MarkdownWithCodeHighlight(text: value, streaming: true),
          ),
        ),
      ),
    ),
  );
}

Finder _stableBlockFinder() =>
    find.byWidgetPredicate((w) => w.key.toString().contains('stable-md-block'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('stableBlockBoundaries', () {
    test('commits blocks separated by blank lines', () {
      expect(stableBlockBoundaries('one'), isEmpty);
      expect(stableBlockBoundaries('one\n\n'), isEmpty);
      expect(stableBlockBoundaries('one\n\ntwo'), [5]);
      expect(stableBlockBoundaries('one\n\ntwo\n\nthree'), [5, 10]);
    });

    test('does not commit at a trailing newline (chunk edge)', () {
      // A single newline at the stream edge may be followed by more tokens.
      expect(stableBlockBoundaries('line1\n'), isEmpty);
      expect(
        stableBlockBoundaries('| a | b |\n| - | - |\n| 1 | 2 |\n'),
        isEmpty,
      );
    });

    test('keeps growing table rows in the tail', () {
      expect(
        stableBlockBoundaries(
          'intro\n\n| a | b |\n| - | - |\n| 1 | 2 |\n| 3 | 4 |\n',
        ),
        [7],
      );
      // Table still open (no blank line yet): nothing before it is safe.
      expect(stableBlockBoundaries('| a | b |\n| - | - |\n| 1 | 2 |'), isEmpty);
    });

    test('does not split inside fenced code', () {
      expect(
        stableBlockBoundaries(
          'para\n\n```dart\nvoid f() {}\n\nvoid g() {}\n```\n\nafter',
        ),
        hasLength(2),
      );
      // Inside an unclosed fence nothing is committed.
      expect(stableBlockBoundaries('para\n\n```dart\nvoid f() {}\n'), [6]);
    });

    test('does not split inside block math', () {
      expect(
        stableBlockBoundaries('before\n\n\$\$\n1 + 1\n\n2 + 2\n\$\$\n\nafter'),
        hasLength(2),
      );
      expect(
        stableBlockBoundaries('before\n\n\\[\n1 + 1\n\\]\n\nafter'),
        hasLength(2),
      );
      expect(stableBlockBoundaries('before\n\n\$\$\n1 + 1\n'), [8]);
    });

    test('does not split inside details HTML blocks', () {
      expect(
        stableBlockBoundaries(
          'before\n\n<details>\n<summary>x</summary>\n\ntext\n</details>\n\nafter',
        ),
        hasLength(2),
      );
      expect(stableBlockBoundaries('<details>\n\ntext\n'), isEmpty);
    });

    test('keeps list and quote lazy continuation in the tail', () {
      expect(stableBlockBoundaries('- item one\n\n  continuation'), isEmpty);
      expect(stableBlockBoundaries('> quote one\n\n> quote two'), isEmpty);
      expect(
        stableBlockBoundaries('- item one\n\n- item two\n\n- item three'),
        isEmpty,
      );
      // A fresh paragraph after a list is a safe boundary.
      expect(stableBlockBoundaries('- item one\n\nfresh paragraph'), [12]);
    });

    test('does not commit before a possible indented code block', () {
      expect(stableBlockBoundaries('paragraph\n\n    code line'), isEmpty);
    });

    test('list inside code fence is ignored', () {
      // The "- item" lines are inside the fence and must not mark a list.
      expect(stableBlockBoundaries('```\n- a\n- b\n```\n\nafter'), [17]);
    });
  });

  group('incremental streaming rendering', () {
    testWidgets('commits stable blocks and renders the tail live', (
      tester,
    ) async {
      final text = ValueNotifier<String>('first paragraph\n\nsecond');

      await tester.pumpWidget(_streamingHarness(text));
      await tester.pump();

      // first paragraph committed as one stable block, "second" is live tail.
      expect(_stableBlockFinder(), findsOneWidget);
      expect(find.textContaining('first paragraph'), findsOneWidget);
      expect(find.textContaining('second'), findsOneWidget);
    });

    testWidgets('stable blocks are not rebuilt when only the tail grows', (
      tester,
    ) async {
      final text = ValueNotifier<String>(
        'stable one\n\nstable two\n\nold-tail',
      );

      await tester.pumpWidget(_streamingHarness(text));
      await tester.pump();

      expect(_stableBlockFinder(), findsNWidgets(2));
      final blockText = tester
          .widgetList<GptMarkdown>(
            find.descendant(
              of: _stableBlockFinder().first,
              matching: find.byType(GptMarkdown),
            ),
          )
          .single
          .data;

      text.value = 'stable one\n\nstable two\n\nnew-tail';
      await tester.pump();

      // Same two cached blocks, identical text; only the tail moved on.
      expect(_stableBlockFinder(), findsNWidgets(2));
      final blockTextAfter = tester
          .widgetList<GptMarkdown>(
            find.descendant(
              of: _stableBlockFinder().first,
              matching: find.byType(GptMarkdown),
            ),
          )
          .single
          .data;
      expect(blockTextAfter, blockText);
      expect(find.textContaining('new-tail'), findsOneWidget);
    });

    testWidgets('shrinking the stream clears the block cache', (tester) async {
      final text = ValueNotifier<String>('first paragraph\n\nsecond');

      await tester.pumpWidget(_streamingHarness(text));
      await tester.pump();
      expect(_stableBlockFinder(), findsOneWidget);

      // Content shortened: cache must be dropped and rebuilt from scratch.
      text.value = 'first';
      await tester.pump();
      expect(_stableBlockFinder(), findsNothing);
      expect(find.textContaining('first'), findsOneWidget);
    });

    testWidgets('rewriting the committed prefix clears the block cache', (
      tester,
    ) async {
      final text = ValueNotifier<String>('original words\n\nsecond');

      await tester.pumpWidget(_streamingHarness(text));
      await tester.pump();
      expect(_stableBlockFinder(), findsOneWidget);

      text.value = 'REWRITTEN words\n\nsecond';
      await tester.pump();

      expect(_stableBlockFinder(), findsOneWidget);
      expect(find.textContaining('REWRITTEN words'), findsOneWidget);
      expect(find.textContaining('original words'), findsNothing);
    });

    testWidgets('final render merges blocks and tail into one full pass', (
      tester,
    ) async {
      final text = ValueNotifier<String>('first paragraph\n\nsecond');

      await tester.pumpWidget(_streamingHarness(text));
      await tester.pump();
      expect(_stableBlockFinder(), findsOneWidget);

      // Streaming ends: the widget re-renders the full text without cache.
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(),
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(
                child: MarkdownWithCodeHighlight(
                  text: 'first paragraph\n\nsecond',
                  streaming: false,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(_stableBlockFinder(), findsNothing);
      expect(find.textContaining('first paragraph'), findsOneWidget);
      expect(find.textContaining('second'), findsOneWidget);
    });

    testWidgets('incomplete structures stay fully in the live tail', (
      tester,
    ) async {
      final text = ValueNotifier<String>(
        'intro\n\n```dart\nvoid f() {\n  var x = 1;\n',
      );

      await tester.pumpWidget(_streamingHarness(text));
      await tester.pump();

      // The unclosed fence keeps everything after "intro" in the tail.
      expect(_stableBlockFinder(), findsOneWidget);
      expect(find.textContaining('var x = 1;'), findsOneWidget);
    });
  });
}
