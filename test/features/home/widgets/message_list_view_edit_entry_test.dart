import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/tts_provider.dart';
import 'package:Cuplivo/core/providers/user_provider.dart';
import 'package:Cuplivo/features/home/controllers/stream_controller.dart'
    as stream_ctrl;
import 'package:Cuplivo/features/home/services/ask_user_interaction_service.dart';
import 'package:Cuplivo/features/home/services/tool_approval_service.dart';
import 'package:Cuplivo/features/home/widgets/message_list_view.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:scrollview_observer/scrollview_observer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // iOS text selection (PR #5 / 9d308a10) wrapped user-message content in
  // SelectionArea so the user can select their own text. After that change a
  // long-press on the text bubbles up to SelectableRegion and starts text
  // selection — it no longer reaches the outer GestureDetector that used to
  // open the action menu. Edit is still exposed through the always-visible
  // action row below the bubble (Pencil button when showUserMessageActions
  // is on, Ellipsis → more-sheet otherwise), which this test exercises.
  testWidgets('all user messages expose edit from action row', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final editedMessages = <String>[];
      final messages = <ChatMessage>[
        ChatMessage(
          id: 'user-old',
          role: 'user',
          content: 'old question',
          conversationId: 'conversation-1',
        ),
        ChatMessage(
          id: 'assistant-answer',
          role: 'assistant',
          content: 'answer',
          conversationId: 'conversation-1',
        ),
        ChatMessage(
          id: 'user-latest',
          role: 'user',
          content: 'latest question',
          conversationId: 'conversation-1',
        ),
      ];

      await tester.pumpWidget(
        _MessageListHarness(
          messages: messages,
          onEditMessage: (message) => editedMessages.add(message.id),
        ),
      );

      // The Pencil (Edit) button is the primary edit affordance after the
      // iOS text-selection change — settings.showUserMessageActions defaults
      // to true, so it is visible on every user message.
      for (final text in const ['old question', 'latest question']) {
        await tester.tap(find.descendant(
          of: find.ancestor(
            of: find.text(text),
            matching: find.byType(MessageListView),
          ),
          matching: find.byIcon(Lucide.Pencil),
        ));
        await tester.pumpAndSettle();
      }

      expect(editedMessages, <String>['user-old', 'user-latest']);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // After iOS text selection (PR #5 / 9d308a10) long-pressing text on a user
  // message enters text-selection mode rather than the action menu. Lock that
  // behaviour in so we don't regress back to the old "long press = menu" path.
  testWidgets('user message long press enters text selection mode',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(
        _MessageListHarness(
          messages: [
            ChatMessage(
              id: 'user-1',
              role: 'user',
              content: 'selectable body',
              conversationId: 'conversation-1',
            ),
          ],
          onEditMessage: (_) {},
        ),
      );

      await tester.longPress(find.text('selectable body'));
      await tester.pumpAndSettle();

      // Selection toolbar from the fork's contextMenuBuilder is present.
      expect(
        find.text(AppLocalizations.of(
          tester.element(find.text('selectable body')),
        ).chatMessageWidgetCopyAsPlainText),
        findsOneWidget,
      );
      expect(find.text('Edit'), findsNothing,
          reason: 'Edit must not be reachable via long-press on the text now');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

class _MessageListHarness extends StatefulWidget {
  const _MessageListHarness({
    required this.messages,
    required this.onEditMessage,
  });

  final List<ChatMessage> messages;
  final ValueChanged<ChatMessage> onEditMessage;

  @override
  State<_MessageListHarness> createState() => _MessageListHarnessState();
}

class _MessageListHarnessState extends State<_MessageListHarness> {
  late final ScrollController scrollController;
  late final ListObserverController observerController;
  late final ValueNotifier<bool> isProcessingFiles;

  @override
  void initState() {
    super.initState();
    scrollController = ScrollController();
    observerController = ListObserverController(controller: scrollController);
    isProcessingFiles = ValueNotifier<bool>(false);
  }

  @override
  void dispose() {
    scrollController.dispose();
    isProcessingFiles.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ChangeNotifierProvider(create: (_) => AssistantProvider()),
        ChangeNotifierProvider(create: (_) => UserProvider()),
        ChangeNotifierProvider(create: (_) => TtsProvider()),
        ChangeNotifierProvider(create: (_) => AskUserInteractionService()),
        ChangeNotifierProvider(create: (_) => ToolApprovalService()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MessageListView(
            scrollController: scrollController,
            observerController: observerController,
            messages: widget.messages,
            byGroup: const {},
            versionSelections: const {},
            reasoning: const <String, stream_ctrl.ReasoningData>{},
            reasoningSegments:
                const <String, List<stream_ctrl.ReasoningSegmentData>>{},
            contentSplits: const <String, stream_ctrl.ContentSplitData>{},
            toolParts: const {},
            translations: const {},
            selecting: false,
            selectedItems: const {},
            dividerPadding: EdgeInsets.zero,
            isProcessingFiles: isProcessingFiles,
            onEditMessage: widget.onEditMessage,
          ),
        ),
      ),
    );
  }
}
