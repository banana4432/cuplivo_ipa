import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/group_chat_provider.dart';
import 'package:Cuplivo/core/providers/mcp_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/providers/workspace_provider.dart';
import 'package:Cuplivo/core/services/backup/restore_refresher.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';

/// Spy variants that record which reload path was invoked and short-circuit
/// the real implementations (which would otherwise need a Drift DB, MCP
/// transport, settings prefs boot, etc.). We only care about ordering and
/// that SettingsProvider gets its reload — that's what the bug was.

class _SpyChatService extends ChatService {
  int reloadCalls = 0;
  @override
  Future<void> reloadCachesFromDb() async {
    reloadCalls++;
  }
}

class _SpyAssistantProvider extends AssistantProvider {
  int reloadCalls = 0;
  @override
  Future<void> reloadFromRepo() async {
    reloadCalls++;
  }
}

class _SpyGroupChatProvider extends GroupChatProvider {
  _SpyGroupChatProvider() : super(chatService: _DummyChatService());
  int loadCalls = 0;
  @override
  Future<void> load() async {
    loadCalls++;
  }
}

class _DummyChatService extends ChatService {
  @override
  bool get initialized => false;
}

class _SpyMcpProvider extends McpProvider {
  _SpyMcpProvider() : super(contextProvider: _nullContextProvider);
  int reloadCalls = 0;
  @override
  Future<void> reloadFromPrefs() async {
    reloadCalls++;
  }
}

/// McpProvider's `contextProvider` callback is only invoked when an OAuth
/// flow needs a BuildContext; the spy never reaches that path (it stubs
/// reloadFromPrefs), so a never-called stub is fine.
BuildContext _nullContextProvider() =>
    throw StateError('contextProvider should not be invoked in this spy');

class _SpyWorkspaceProvider extends WorkspaceProvider {
  int reloadCalls = 0;
  @override
  Future<void> reloadFromPrefs() async {
    reloadCalls++;
  }
}

class _SpySettingsProvider extends SettingsProvider {
  int reloadCalls = 0;
  @override
  Future<void> reloadFromPrefs() async {
    reloadCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'refreshProvidersAfterRestore reloads SettingsProvider so imported '
    'providers appear without restart',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final chatService = _SpyChatService();
      final assistant = _SpyAssistantProvider();
      final groupChat = _SpyGroupChatProvider();
      final mcp = _SpyMcpProvider();
      final workspace = _SpyWorkspaceProvider();
      final settings = _SpySettingsProvider();

      late BuildContext capturedContext;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ChatService>.value(value: chatService),
            ChangeNotifierProvider<AssistantProvider>.value(value: assistant),
            ChangeNotifierProvider<GroupChatProvider>.value(value: groupChat),
            ChangeNotifierProvider<McpProvider>.value(value: mcp),
            ChangeNotifierProvider<WorkspaceProvider>.value(value: workspace),
            ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ],
          child: Builder(
            builder: (context) {
              capturedContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      await refreshProvidersAfterRestore(capturedContext);

      // Every provider in the shared refresh list was hit exactly once.
      expect(chatService.reloadCalls, 1);
      expect(workspace.reloadCalls, 1);
      expect(mcp.reloadCalls, 1);
      expect(settings.reloadCalls, 1,
          reason:
              'SettingsProvider.reloadFromPrefs is what was missing before '
              'fix/restore-refresh-settings — without it, imported provider '
              'configs stayed invisible until the user force-killed the app.');
      expect(assistant.reloadCalls, 1);
      expect(groupChat.loadCalls, 1);
    },
  );

  testWidgets(
    'refreshProvidersAfterRestore tolerates a failing SettingsProvider '
    'and still completes the other reloads',
    (tester) async {
      // Real SettingsProvider.reloadFromPrefs can throw if a corrupt
      // provider_configs_v1 sneaks past decoding. The refresher's contract
      // is "log and move on", so the rest of the chain must still run.
      SharedPreferences.setMockInitialValues({});
      final chatService = _SpyChatService();
      final assistant = _SpyAssistantProvider();
      final groupChat = _SpyGroupChatProvider();
      final mcp = _SpyMcpProvider();
      final workspace = _SpyWorkspaceProvider();

      late BuildContext capturedContext;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ChatService>.value(value: chatService),
            ChangeNotifierProvider<AssistantProvider>.value(value: assistant),
            ChangeNotifierProvider<GroupChatProvider>.value(value: groupChat),
            ChangeNotifierProvider<McpProvider>.value(value: mcp),
            ChangeNotifierProvider<WorkspaceProvider>.value(value: workspace),
            // Use a SettingsProvider that throws on reloadFromPrefs. The
            // real one catches internal decode failures; this throws from
            // the override itself so the try/catch in refresher engages.
            ChangeNotifierProvider<SettingsProvider>(
              create: (_) => _ThrowingSettingsProvider(),
            ),
          ],
          child: Builder(
            builder: (context) {
              capturedContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      await refreshProvidersAfterRestore(capturedContext);

      expect(chatService.reloadCalls, 1);
      expect(workspace.reloadCalls, 1);
      expect(mcp.reloadCalls, 1);
      expect(assistant.reloadCalls, 1);
      expect(groupChat.loadCalls, 1);
    },
  );
}

class _ThrowingSettingsProvider extends SettingsProvider {
  @override
  Future<void> reloadFromPrefs() async {
    throw StateError('boom');
  }
}