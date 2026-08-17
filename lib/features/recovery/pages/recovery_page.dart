import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';

import '../../../core/database/repair_service.dart';
import '../../../core/providers/backup_provider.dart';
import '../../../core/models/backup.dart' show RestoreMode;
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/app_font_weights.dart';

/// Last-resort recovery surface. Reachable three ways:
///
/// 1. Startup hook in `main.dart` calls [open] when [ErrorWidget] fires or a
///    Provider throws during boot.
/// 2. Long-press the Settings page title for 5 seconds (hidden gesture).
/// 3. The "Repair & Maintenance" section on the Backup page links here for
///    the destructive actions (rebuild database).
class RecoveryPage extends StatefulWidget {
  const RecoveryPage({super.key, this.error});

  /// Optional startup error message shown in a banner. Null when the user
  /// navigated here voluntarily.
  final String? error;

  static Future<void> open(BuildContext context, {String? error}) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecoveryPage(error: error),
      ),
    );
  }

  @override
  State<RecoveryPage> createState() => _RecoveryPageState();
}

class _RecoveryPageState extends State<RecoveryPage> {
  bool _busy = false;
  String? _busyLabel;
  String? _result;
  String? _failedStep;

  Future<void> _runGuarded(
    String label,
    Future<void> Function() action,
  ) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyLabel = label;
      _failedStep = null;
      _result = null;
    });
    try {
      await action();
      if (!mounted) return;
      setState(() => _result = label);
    } catch (e, st) {
      debugPrint('[recovery] $label failed: $e\n$st');
      if (!mounted) return;
      setState(() => _failedStep = label);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = null;
        });
      }
    }
  }

  Future<void> _exportCurrent() => _runGuarded(
        AppLocalizations.of(context)!.recoveryActionExport,
        () async {
          final vm = context.read<BackupProvider>();
          await vm.exportToFile();
        },
      );

  Future<void> _restoreFromZip() => _runGuarded(
        AppLocalizations.of(context)!.recoveryActionImport,
        () async {
          final picked = await FilePicker.platform.pickFiles(
            type: FileType.custom,
            allowedExtensions: const ['zip', 'bak'],
          );
          if (picked == null || picked.files.isEmpty) return;
          final path = picked.files.first.path;
          if (path == null) return;
          final vm = context.read<BackupProvider>();
          await vm.restoreFromLocalFile(File(path), mode: RestoreMode.overwrite);
        },
      );

  Future<void> _repair() => _runGuarded(
        AppLocalizations.of(context)!.recoveryActionRepair,
        () async {
          final vm = context.read<BackupProvider>();
          final report = await vm.repairLocalDatabase();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                AppLocalizations.of(context)!.recoveryRepairDone(
                  report.reindexedTableCount,
                  report.elapsed.inMilliseconds,
                ),
              ),
            ),
          );
        },
      );

  Future<void> _sweepOrphans() => _runGuarded(
        AppLocalizations.of(context)!.recoveryActionSweep,
        () async {
          final vm = context.read<BackupProvider>();
          final report = await vm.sweepOrphans();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                AppLocalizations.of(context)!.recoverySweepDone(report.total),
              ),
            ),
          );
        },
      );

  Future<void> _rebuild() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.recoveryConfirmRebuildTitle),
        content: Text(l10n.recoveryConfirmRebuildBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.backupPageCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.recoveryConfirmRebuildAction),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    await _runGuarded(
      l10n.recoveryActionRebuild,
      () async {
        final vm = context.read<BackupProvider>();
        await vm.rebuildLocalDatabase();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Lucide.ArrowLeft),
          onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
        ),
        title: Text(l10n.recoveryPageTitle),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            if (widget.error != null) ...[
              _Banner(
                color: cs.errorContainer,
                textColor: cs.onErrorContainer,
                icon: Lucide.TriangleAlert,
                text: widget.error!,
              ),
              const SizedBox(height: 12),
            ],
            _Banner(
              color: cs.secondaryContainer,
              textColor: cs.onSecondaryContainer,
              icon: Lucide.info,
              text: l10n.recoveryPageDescription,
            ),
            const SizedBox(height: 20),

            _ActionCard(
              icon: Lucide.Export,
              title: l10n.recoveryActionExport,
              subtitle: l10n.recoveryActionExportSubtitle,
              onTap: _busy ? null : _exportCurrent,
              color: cs,
            ),
            const SizedBox(height: 12),
            _ActionCard(
              icon: Lucide.Import2,
              title: l10n.recoveryActionImport,
              subtitle: l10n.recoveryActionImportSubtitle,
              onTap: _busy ? null : _restoreFromZip,
              color: cs,
            ),
            const SizedBox(height: 12),
            _ActionCard(
              icon: Lucide.Wrench,
              title: l10n.recoveryActionRepair,
              subtitle: l10n.recoveryActionRepairSubtitle,
              onTap: _busy ? null : _repair,
              color: cs,
            ),
            const SizedBox(height: 12),
            _ActionCard(
              icon: Lucide.Brush,
              title: l10n.recoveryActionSweep,
              subtitle: l10n.recoveryActionSweepSubtitle,
              onTap: _busy ? null : _sweepOrphans,
              color: cs,
            ),
            const SizedBox(height: 12),
            _ActionCard(
              icon: Lucide.Trash2,
              title: l10n.recoveryActionRebuild,
              subtitle: l10n.recoveryActionRebuildSubtitle,
              onTap: _busy ? null : _rebuild,
              color: cs,
              destructive: true,
            ),

            if (_busy) ...[
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
                  const SizedBox(width: 12),
                  Text(_busyLabel ?? l10n.recoveryActionExport),
                ],
              ),
            ],
            if (_result != null) ...[
              const SizedBox(height: 16),
              _Banner(
                color: cs.tertiaryContainer,
                textColor: cs.onTertiaryContainer,
                icon: Lucide.Check,
                text: _result!,
              ),
            ],
            if (_failedStep != null) ...[
              const SizedBox(height: 16),
              _Banner(
                color: cs.errorContainer,
                textColor: cs.onErrorContainer,
                icon: Lucide.X,
                text: l10n.recoveryFailed(_failedStep!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.color,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final ColorScheme color;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final tint = destructive ? color.error : color.primary;
    return Material(
      color: color.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(icon, color: tint, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: AppFontWeights.semibold,
                        color: destructive ? color.error : color.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: color.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Lucide.ChevronRight,
                size: 18,
                color: color.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.color,
    required this.textColor,
    required this.icon,
    required this.text,
  });

  final Color color;
  final Color textColor;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: textColor, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                color: textColor,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}