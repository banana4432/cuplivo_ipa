import 'dart:io';
import 'package:Cuplivo/theme/app_font_weights.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../shared/widgets/loading_dialog_card.dart';
import 'package:provider/provider.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../core/services/haptics.dart';
import '../../../core/models/backup.dart';
import '../../../core/providers/backup_provider.dart';
import '../../../core/providers/backup_reminder_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/trash_restore_coordinator.dart';
import '../../../core/services/backup/data_sync.dart';
import '../../../core/services/backup/restore_refresher.dart';
import '../../../core/services/native_file_save.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/dialogs/restart_required_dialog.dart';
import '../../../shared/dialogs/rikkahub_migrate_dialog.dart';
import '../../../shared/dialogs/kelivo_compat_dialog.dart';
import '../../../core/services/backup/cherry_importer.dart';
import '../../../core/services/backup/chatbox_importer.dart';
import '../../../utils/platform_utils.dart';
import '../widgets/backup_reminder_helpers.dart';

class BackupPage extends StatefulWidget {
  const BackupPage({super.key, this.trashRestoreCoordinator});

  final TrashRestoreCoordinator? trashRestoreCoordinator;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {

  Future<bool?> _confirmCherryImport(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final locale = Localizations.localeOf(context);
    final isZh = locale.languageCode.startsWith('zh');
    final String body = isZh
        ? '此功能目前仍处于实验阶段。\n目前仅能导入助手，对话内容，供应商和文件，\n一些供应商需要在baseurl后面添加/v1 or /v1beta。 \n为确保数据安全，建议在导入前先执行备份。\n是否已知晓并继续选择文件？'
        : 'This feature is experimental.\nTo keep your data safe, it is recommended to back up before importing.\nProceed to choose a file?';

    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final bottom = MediaQuery.of(ctx).viewInsets.bottom;
        final onSurface60 = cs.onSurface.withValues(alpha: 0.72);
        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, bottom + 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurface.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    l10n.backupPageImportFromCherryStudio,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: AppFontWeights.semibold,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Padding(
                    //   padding: const EdgeInsets.only(top: 2),
                    //   child: Icon(Lucide.BadgeInfo, size: 18, color: cs.primary),
                    // ),
                    // const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        body,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.35,
                          color: onSurface60,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _IosOutlineButton(
                        label: l10n.backupPageCancel,
                        onTap: () => Navigator.of(ctx).pop(false),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _IosFilledButton(
                        label: l10n.backupPageOK,
                        onTap: () => Navigator.of(ctx).pop(true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<RestoreMode?> _chooseImportModeDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? Colors.white10 : const Color(0xFFF7F7F9);

    return showDialog<RestoreMode>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.backupPageSelectImportMode),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ActionCard(
              color: cardColor,
              icon: Lucide.RotateCw,
              title: l10n.backupPageOverwriteMode,
              subtitle: l10n.backupPageOverwriteModeDescription,
              onTap: () => Navigator.of(ctx).pop(RestoreMode.overwrite),
            ),
            const SizedBox(height: 10),
            _ActionCard(
              color: cardColor,
              icon: Lucide.GitFork,
              title: l10n.backupPageMergeMode,
              subtitle: l10n.backupPageMergeModeDescription,
              onTap: () => Navigator.of(ctx).pop(RestoreMode.merge),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.backupPageCancel),
          ),
        ],
      ),
    );
  }

  Future<T> _runWithExportingOverlay<T>(
    BuildContext context,
    Future<T> Function() task,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    return _runWithLoadingOverlay(
      context,
      task,
      label: l10n.backupPageExporting,
    );
  }

  Future<T> _runWithLoadingOverlay<T>(
    BuildContext context,
    Future<T> Function() task, {
    String? label,
  }) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => LoadingDialogCard(label: label),
    );
    try {
      final res = await task();
      return res;
    } finally {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  Future<T> _runWithImportingOverlay<T>(
    BuildContext context,
    Future<T> Function() task,
  ) => _runWithLoadingOverlay(context, task);

  Future<void> _afterSuccessfulRestore(BuildContext context) async {
    if (!context.mounted) return;
    await _refreshProvidersAfterRestore(context);
    if (!context.mounted) return;
    await showRestartRequiredDialog(context);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();
    final coordinator =
        widget.trashRestoreCoordinator ??
        context.read<TrashRestoreCoordinator>();

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => BackupProvider(
            chatService: context.read<ChatService>(),
            trashRestoreCoordinator: coordinator,
            initialOptions: settings.backupExportOptions,
          ),
        ),
      ],
      child: Builder(
        builder: (context) {
          final vm = context.watch<BackupProvider>();
          final cfg = vm.options;

          // iOS-style section header
          Widget header(String text, {bool first = false}) => Padding(
            padding: EdgeInsets.fromLTRB(12, first ? 2 : 18, 12, 6),
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                fontWeight: AppFontWeights.semibold,
                color: cs.onSurface.withValues(alpha: 0.8),
              ),
            ),
          );

          return Scaffold(
            appBar: AppBar(
              leading: Tooltip(
                message: l10n.settingsPageBackButton,
                child: _TactileIconButton(
                  icon: Lucide.ArrowLeft,
                  color: cs.onSurface,
                  size: 22,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
              ),
              title: Text(l10n.backupPageTitle),
              actions: const [SizedBox(width: 12)],
            ),
            body: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                // Section 1: 备份管理
                header(l10n.backupPageBackupManagement, first: true),
                _iosSectionCard(
                  children: [
                    _iosSwitchRow(
                      context,
                      icon: Lucide.MessageSquare,
                      label: l10n.backupPageChatsLabel,
                      value: cfg.includeChats,
                      onChanged: (v) async {
                        final newCfg = cfg.copyWith(includeChats: v);
                        await settings.setBackupExportOptions(newCfg);
                        vm.updateOptions(newCfg);
                      },
                    ),
                    _iosDivider(context),
                    _iosSwitchRow(
                      context,
                      icon: Lucide.FileText,
                      label: l10n.backupPageFilesLabel,
                      value: cfg.includeFiles,
                      onChanged: (v) async {
                        final newCfg = cfg.copyWith(includeFiles: v);
                        await settings.setBackupExportOptions(newCfg);
                        vm.updateOptions(newCfg);
                      },
                    ),
                  ],
                ),

                header(l10n.backupReminderSectionTitle),
                const _BackupReminderMobileSection(),

                // Section 2: 本地备份
                ..._buildMobileLocalBackupSection(context, l10n, vm, header),

              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _buildMobileLocalBackupSection(
    BuildContext context,
    AppLocalizations l10n,
    BackupProvider vm,
    Widget Function(String text, {bool first}) header,
  ) {
    return [
      header(l10n.backupPageLocalBackup),
      _iosSectionCard(
        children: [
          _iosNavRow(
            context,
            icon: Lucide.Export,
            label: l10n.backupPageExportToFile,
            onTap: () => _doExport(context, vm),
          ),
          _iosDivider(context),
          _iosNavRow(
            context,
            icon: Lucide.Import2,
            label: l10n.backupPageImportBackupFile,
            onTap: () => _doImportLocal(context, vm),
          ),
          _iosDivider(context),
          _iosNavRow(
            context,
            icon: Lucide.Box,
            label: l10n.backupPageImportFromRikkaHub,
            onTap: () => showRikkaHubMigrateDialog(context: context),
          ),
          _iosDivider(context),
          _iosNavRow(
            context,
            icon: Lucide.Box,
            label: l10n.backupPageImportFromCherryStudio,
            onTap: () async {
              // 1) Warn user that Cherry import is experimental
              final acknowledged = await _confirmCherryImport(context);
              if (acknowledged != true) return;

              if (!context.mounted) return;
              // Pick Cherry Studio backup (.zip or .bak)
              final result = await FilePicker.platform.pickFiles(
                type: FileType.custom,
                allowedExtensions: ['zip', 'bak'],
              );
              final path = result?.files.single.path;
              if (path == null) return;
              if (!context.mounted) return;

              final mode = await _chooseImportModeDialog(context);
              if (mode == null) return;
              if (!context.mounted) return;

              await _runWithImportingOverlay(context, () async {
                try {
                  final settings = context.read<SettingsProvider>();
                  final cs = context.read<ChatService>();
                  final file = File(path);
                  // Defer import to service
                  final res = await CherryImporter.importFromCherryStudio(
                    file: file,
                    mode: mode,
                    settings: settings,
                    chatService: cs,
                  );
                  if (!context.mounted) return;
                  await showDialog(
                    context: context,
                    builder: (dctx) => AlertDialog(
                      title: Text(l10n.backupPageRestartRequired),
                      content: Text(
                        '${l10n.backupPageImportFromCherryStudio}:\n'
                        ' • Providers: ${res.providers}\n'
                        ' • Assistants: ${res.assistants}\n'
                        ' • Conversations: ${res.conversations}\n'
                        ' • Messages: ${res.messages}\n'
                        ' • Files: ${res.files}\n\n'
                        '${l10n.backupPageRestartContent}',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () async {
                            Navigator.of(dctx).pop();
                            PlatformUtils.restartApp();
                          },
                          child: Text(l10n.backupPageOK),
                        ),
                      ],
                    ),
                  );
                } catch (e) {
                  if (!context.mounted) return;
                  showAppSnackBar(
                    context,
                    message: e.toString(),
                    type: NotificationType.error,
                  );
                }
              });
            },
          ),
          _iosDivider(context),
          _iosNavRow(
            context,
            icon: Lucide.Box,
            label: l10n.backupPageImportFromChatbox,
            onTap: () async {
              // Pick Chatbox exported json
              final result = await FilePicker.platform.pickFiles(
                type: FileType.custom,
                allowedExtensions: ['json'],
              );
              final path = result?.files.single.path;
              if (path == null) return;
              if (!context.mounted) return;

              final mode = await _chooseImportModeDialog(context);
              if (mode == null) return;
              if (!context.mounted) return;

              await _runWithImportingOverlay(context, () async {
                try {
                  final cs = context.read<ChatService>();
                  final settings = context.read<SettingsProvider>();
                  final file = File(path);
                  final res = await ChatboxImporter.importFromChatbox(
                    file: file,
                    mode: mode,
                    settings: settings,
                    chatService: cs,
                  );
                  if (!context.mounted) return;
                  await showDialog(
                    context: context,
                    barrierDismissible: false,
                    builder: (dctx) => PopScope(
                      // Import contract matches restore: restart is required
                      // for the imported data to take effect.
                      canPop: false,
                      child: AlertDialog(
                        title: Text(l10n.backupPageRestartRequired),
                        content: Text(
                          '${l10n.backupPageImportFromChatbox}:\n'
                          ' • Providers: ${res.providers}\n'
                          ' • Assistants: ${res.assistants}\n'
                          ' • Conversations: ${res.conversations}\n'
                          ' • Messages: ${res.messages}\n\n'
                          '${l10n.backupPageRestartContent}',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () async {
                              Navigator.of(dctx).pop();
                              PlatformUtils.restartApp();
                            },
                            child: Text(l10n.backupPageOK),
                          ),
                        ],
                      ),
                    ),
                  );
                } catch (e) {
                  if (!context.mounted) return;
                  showAppSnackBar(
                    context,
                    message: e.toString(),
                    type: NotificationType.error,
                  );
                }
              });
            },
          ),
        ],
      ),
    ];
  }

  Future<void> _doExport(BuildContext context, BackupProvider vm) async {
    final l10n = AppLocalizations.of(context)!;
    final file = await _runWithExportingOverlay(
      context,
      () => vm.exportToFile(),
    );

    try {
      if (!context.mounted) return;
      final isMobile = Platform.isAndroid || Platform.isIOS;
      if (isMobile) {
        try {
          final saved = await NativeFileSave.saveFileFromPath(
            sourcePath: file.path,
            fileName: file.uri.pathSegments.last,
          );
          if (saved && context.mounted) {
            await context
                .read<BackupReminderProvider>()
                .recordBackupCompleted();
          }
        } catch (e) {
          if (!context.mounted) return;
          showAppSnackBar(
            context,
            message: e.toString(),
            type: NotificationType.error,
          );
        }
      } else {
        final savePath = await FilePicker.platform.saveFile(
          dialogTitle: l10n.backupPageExportToFile,
          fileName: file.uri.pathSegments.last,
          type: FileType.custom,
          allowedExtensions: ['zip'],
        );
        if (savePath != null) {
          try {
            await File(savePath).parent.create(recursive: true);
            await file.copy(savePath);
            if (context.mounted) {
              await context
                  .read<BackupReminderProvider>()
                  .recordBackupCompleted();
            }
          } catch (_) {}
        }
      }
    } finally {
      await DataSync.cleanupTemporaryBackupFile(file);
    }
  }

  /// After wipe/restore, providers must re-read SQLite; otherwise UI keeps a
  /// cleared or pre-restore in-memory snapshot (P0 empty chats/assistants).
  /// Delegates to the shared refresh list so every restore entry point
  /// (mobile page, desktop pane, LAN sync) stays in sync.
  Future<void> _refreshProvidersAfterRestore(BuildContext context) async {
    await refreshProvidersAfterRestore(context);
  }

  Future<void> _doImportLocal(BuildContext context, BackupProvider vm) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    if (!context.mounted) return;

    final mode = await _chooseImportModeDialog(context);
    if (mode == null) return;
    if (!context.mounted) return;

    try {
      await _runWithImportingOverlay(
        context,
        () => vm.restoreFromLocalFile(File(path), mode: mode),
      );
    } catch (e) {
      if (!context.mounted) return;
      if (await maybeShowKelivoCompatError(context, e)) return;
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        message: e.toString(),
        type: NotificationType.error,
      );
      return;
    }
    if (!context.mounted) return;
    await _afterSuccessfulRestore(context);
  }
}

class _BackupReminderMobileSection extends StatelessWidget {
  const _BackupReminderMobileSection();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final reminder = context.watch<BackupReminderProvider>();

    return _iosSectionCard(
      children: [
        _iosSwitchRow(
          context,
          icon: Lucide.Timer,
          label: l10n.backupReminderEnableTitle,
          value: reminder.enabled,
          onChanged: (value) async {
            final provider = context.read<BackupReminderProvider>();
            if (!value) {
              await provider.setEnabled(false);
              return;
            }
            final minutes = await showBackupReminderTimePicker(
              context,
              initialMinutes: provider.reminderMinutesOfDay,
            );
            if (minutes == null) return;
            await provider.saveSchedule(
              enabled: true,
              intervalDays: provider.intervalDays,
              reminderMinutesOfDay: minutes,
            );
          },
        ),
        if (reminder.enabled) ...[
          _iosDivider(context),
          _iosNavRow(
            context,
            icon: Lucide.Repeat,
            label: l10n.backupReminderFrequencyTitle,
            detailText: backupReminderFrequencyLabel(
              l10n,
              reminder.intervalDays,
            ),
            onTap: () => _showBackupReminderFrequencySheet(context),
          ),
          _iosDivider(context),
          _iosNavRow(
            context,
            icon: Lucide.clock,
            label: l10n.backupReminderTimeTitle,
            detailText: backupReminderTimeLabel(
              context,
              reminder.reminderMinutesOfDay,
            ),
            onTap: () async {
              final provider = context.read<BackupReminderProvider>();
              final minutes = await showBackupReminderTimePicker(
                context,
                initialMinutes: provider.reminderMinutesOfDay,
              );
              if (minutes == null) return;
              await provider.saveSchedule(
                enabled: true,
                intervalDays: provider.intervalDays,
                reminderMinutesOfDay: minutes,
              );
            },
          ),
          _iosDivider(context),
          _iosNavRow(
            context,
            icon: Lucide.CheckCircle,
            label: l10n.backupReminderLastBackupTitle,
            detailText: backupReminderDateTimeLabel(
              context,
              reminder.lastBackupAt,
            ),
          ),
          _iosDivider(context),
          _iosNavRow(
            context,
            icon: Lucide.Calendar,
            label: l10n.backupReminderNextReminderTitle,
            detailText: backupReminderNextLabel(
              context,
              reminder.nextReminderAt,
            ),
          ),
        ],
      ],
    );
  }
}

Future<void> _showBackupReminderFrequencySheet(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final provider = context.read<BackupReminderProvider>();
  final selected = await showModalBottomSheet<int>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      final options = <int>[
        ...BackupReminderProvider.presetIntervals,
        if (!BackupReminderProvider.presetIntervals.contains(
          provider.intervalDays,
        ))
          provider.intervalDays,
        0,
      ];
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final days in options)
                _ReminderFrequencyTile(
                  label: days == 0
                      ? l10n.backupReminderCustomOption
                      : backupReminderFrequencyLabel(l10n, days),
                  selected: days != 0 && days == provider.intervalDays,
                  onTap: () => Navigator.of(ctx).pop(days),
                ),
            ],
          ),
        ),
      );
    },
  );
  if (!context.mounted || selected == null) return;

  final days = selected == 0
      ? await showBackupReminderCustomDaysDialog(
          context,
          initialDays: provider.intervalDays,
        )
      : selected;
  if (!context.mounted || days == null) return;
  final providerAfterDialog = context.read<BackupReminderProvider>();
  var minutes = providerAfterDialog.reminderMinutesOfDay;
  minutes ??= await showBackupReminderTimePicker(context);
  if (!context.mounted || minutes == null) return;
  await context.read<BackupReminderProvider>().saveSchedule(
    enabled: true,
    intervalDays: days,
    reminderMinutesOfDay: minutes,
  );
}

class _ReminderFrequencyTile extends StatefulWidget {
  const _ReminderFrequencyTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ReminderFrequencyTile> createState() => _ReminderFrequencyTileState();
}

class _ReminderFrequencyTileState extends State<_ReminderFrequencyTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () {
        Haptics.soft();
        widget.onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: widget.selected
              ? cs.primary.withValues(alpha: 0.12)
              : _pressed
              ? cs.onSurface.withValues(alpha: 0.05)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.label,
                style: TextStyle(fontSize: 15, color: cs.onSurface),
              ),
            ),
            if (widget.selected)
              Icon(Lucide.Check, size: 18, color: cs.primary),
          ],
        ),
      ),
    );
  }
}

// --- iOS-style widgets ---

class _TactileIconButton extends StatefulWidget {
  const _TactileIconButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.size = 22,
  });
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final double size;
  @override
  State<_TactileIconButton> createState() => _TactileIconButtonState();
}

class _TactileIconButtonState extends State<_TactileIconButton> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final base = widget.color;
    final press = base.withValues(alpha: 0.7);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () {
        Haptics.light();
        widget.onTap();
      },
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(
          widget.icon,
          size: widget.size,
          color: _pressed ? press : base,
        ),
      ),
    );
  }
}

class _TactileRow extends StatefulWidget {
  const _TactileRow({
    required this.builder,
    this.onTap,
    this.pressedScale = 1.0,
  });
  final Widget Function(bool pressed) builder;
  final VoidCallback? onTap;
  final double pressedScale;
  @override
  State<_TactileRow> createState() => _TactileRowState();
}

class _TactileRowState extends State<_TactileRow> {
  bool _pressed = false;
  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => _set(true),
      onTapUp: widget.onTap == null ? null : (_) => _set(false),
      onTapCancel: widget.onTap == null ? null : () => _set(false),
      onTap: widget.onTap == null
          ? null
          : () {
              if (context.read<SettingsProvider>().hapticsOnListItemTap) {
                Haptics.soft();
              }
              widget.onTap!.call();
            },
      child: AnimatedScale(
        scale: _pressed ? widget.pressedScale : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: widget.builder(_pressed),
      ),
    );
  }
}

class _SmallTactileIcon extends StatefulWidget {
  const _SmallTactileIcon({
    required this.icon,
    required this.onTap,
  });
  final IconData icon;
  final VoidCallback onTap;
  @override
  State<_SmallTactileIcon> createState() => _SmallTactileIconState();
}

class _SmallTactileIconState extends State<_SmallTactileIcon> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.onSurface;
    final c = _pressed ? base.withValues(alpha: 0.7) : base;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () {
        Haptics.soft();
        widget.onTap();
      },
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(widget.icon, size: 18, color: c),
      ),
    );
  }
}

Widget _iosSectionCard({required List<Widget> children}) {
  return Builder(
    builder: (context) {
      final theme = Theme.of(context);
      final cs = theme.colorScheme;
      final isDark = theme.brightness == Brightness.dark;
      final Color bg = isDark
          ? Colors.white10
          : Colors.white.withValues(alpha: 0.96);
      return Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: cs.outlineVariant.withValues(alpha: isDark ? 0.08 : 0.06),
            width: 0.6,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: children),
        ),
      );
    },
  );
}

Widget _iosDivider(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return Divider(
    height: 6,
    thickness: 0.6,
    indent: 54,
    endIndent: 12,
    color: cs.outlineVariant.withValues(alpha: 0.18),
  );
}

class _AnimatedPressColor extends StatelessWidget {
  const _AnimatedPressColor({
    required this.pressed,
    required this.base,
    required this.builder,
  });
  final bool pressed;
  final Color base;
  final Widget Function(Color color) builder;
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final target = pressed
        ? (Color.lerp(base, isDark ? Colors.black : Colors.white, 0.55) ?? base)
        : base;
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: target),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, color, _) => builder(color ?? base),
    );
  }
}

Widget _iosNavRow(
  BuildContext context, {
  required IconData icon,
  required String label,
  VoidCallback? onTap,
  String? detailText,
}) {
  final cs = Theme.of(context).colorScheme;
  final interactive = onTap != null;
  return _TactileRow(
    onTap: onTap,
    pressedScale: 1.00,
    builder: (pressed) {
      final baseColor = cs.onSurface.withValues(alpha: 0.9);
      return _AnimatedPressColor(
        pressed: pressed,
        base: baseColor,
        builder: (c) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                SizedBox(width: 36, child: Icon(icon, size: 20, color: c)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 15, color: c),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (detailText != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      detailText,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                if (interactive) Icon(Lucide.ChevronRight, size: 16, color: c),
              ],
            ),
          );
        },
      );
    },
  );
}

// --- Local iOS-style buttons for sheets ---
class _IosOutlineButton extends StatefulWidget {
  const _IosOutlineButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
  @override
  State<_IosOutlineButton> createState() => _IosOutlineButtonState();
}

class _IosOutlineButtonState extends State<_IosOutlineButton> {
  bool _pressed = false;
  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) =>
          Future.delayed(const Duration(milliseconds: 80), () => _set(false)),
      onTapCancel: () => _set(false),
      onTap: () {
        Haptics.soft();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.primary.withValues(alpha: 0.5)),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: cs.primary,
              fontWeight: AppFontWeights.semibold,
            ),
          ),
        ),
      ),
    );
  }
}

class _IosFilledButton extends StatefulWidget {
  const _IosFilledButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
  @override
  State<_IosFilledButton> createState() => _IosFilledButtonState();
}

class _IosFilledButtonState extends State<_IosFilledButton> {
  bool _pressed = false;
  void _set(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) =>
          Future.delayed(const Duration(milliseconds: 80), () => _set(false)),
      onTapCancel: () => _set(false),
      onTap: () {
        Haptics.soft();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: cs.primary,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: cs.onPrimary,
              fontWeight: AppFontWeights.semibold,
            ),
          ),
        ),
      ),
    );
  }
}

Widget _iosSwitchRow(
  BuildContext context, {
  IconData? icon,
  required String label,
  required bool value,
  required ValueChanged<bool> onChanged,
}) {
  final cs = Theme.of(context).colorScheme;
  return _TactileRow(
    onTap: () => onChanged(!value),
    pressedScale: 1.00,
    builder: (pressed) {
      final baseColor = cs.onSurface.withValues(alpha: 0.9);
      return _AnimatedPressColor(
        pressed: pressed,
        base: baseColor,
        builder: (c) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Row(
              children: [
                if (icon != null) ...[
                  SizedBox(width: 36, child: Icon(icon, size: 20, color: c)),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Text(label, style: TextStyle(fontSize: 15, color: c)),
                ),
                IosSwitch(value: value, onChanged: onChanged),
              ],
            ),
          );
        },
      );
    },
  );
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.color,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final Color color;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _TactileRow(
      pressedScale: 0.98,
      onTap: onTap,
      builder: (pressed) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final overlay = pressed
            ? (isDark
                  ? Colors.black.withValues(alpha: 0.06)
                  : Colors.white.withValues(alpha: 0.05))
            : Colors.transparent;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: Color.alphaBlend(overlay, color),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: 0.18),
            ),
          ),
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Icon(icon, color: cs.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(fontWeight: AppFontWeights.semibold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Lucide.ChevronRight, size: 18),
            ],
          ),
        );
      },
    );
  }
}

