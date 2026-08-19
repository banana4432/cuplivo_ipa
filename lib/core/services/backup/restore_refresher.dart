import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../providers/assistant_provider.dart';
import '../../providers/group_chat_provider.dart';
import '../../providers/mcp_provider.dart';
import '../../providers/workspace_provider.dart';
import '../chat/chat_service.dart';

/// Re-reads every provider that mirrors persisted state after a restore /
/// import rewrote SQLite or SharedPreferences, so the UI does not keep a
/// cleared or pre-restore in-memory snapshot.
///
/// Note: SettingsProvider is intentionally NOT refreshed here. data_sync
/// restore rewrites every SharedPreferences key via SharedPreferencesAsync
/// `.restore(map)` (overwrite mode) or per-key merge, but SettingsProvider
/// is built around dozens of display/theme/haptics/settings toggles whose
/// side effects (Haptics.setEnabled, RequestLogger.setEnabled, font
/// re-registration, one-shot migrations) should NOT re-fire on every
/// import. Instead, the backup flow shows a "restart to apply" dialog so
/// the user cold-starts the app — only then does `SettingsProvider._load()`
/// read the freshly restored prefs in full.
///
/// Single shared refresh list for all restore entry points (mobile backup
/// page, desktop backup pane, LAN sync). Any new SQLite-backed provider
/// must subscribe here.
Future<void> refreshProvidersAfterRestore(BuildContext context) async {
  final chatService = context.read<ChatService>();
  final assistantProvider = context.read<AssistantProvider>();
  final groupChatProvider = context.read<GroupChatProvider>();
  final mcpProvider = context.read<McpProvider>();
  final workspaceProvider = context.read<WorkspaceProvider>();
  try {
    await chatService.reloadCachesFromDb();
  } catch (e) {
    debugPrint('refreshProvidersAfterRestore: ChatService: $e');
  }
  try {
    await workspaceProvider.reloadFromPrefs();
  } catch (e) {
    debugPrint('refreshProvidersAfterRestore: WorkspaceProvider: $e');
  }
  try {
    // Reload MCP BEFORE assistants: reloading assistants can fire provider
    // change notifications that read the server list. If the old client
    // were still live at that point it would write the pre-restore list
    // over the restored mcp_servers_v1; reloading MCP first means any such
    // refresh runs against the new client (or no client) and stays
    // harmless.
    await mcpProvider.reloadFromPrefs();
  } catch (e) {
    debugPrint('refreshProvidersAfterRestore: McpProvider: $e');
  }
  try {
    await assistantProvider.reloadFromRepo();
  } catch (e) {
    debugPrint('refreshProvidersAfterRestore: AssistantProvider: $e');
  }
  try {
    await groupChatProvider.load();
  } catch (e) {
    debugPrint('refreshProvidersAfterRestore: GroupChatProvider: $e');
  }
}