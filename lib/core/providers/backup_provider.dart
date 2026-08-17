import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../database/app_database.dart';
import '../database/repair_service.dart';
import '../models/backup.dart';
import '../models/incremental_backup.dart';
import '../services/chat/chat_service.dart';
import '../services/backup/data_sync.dart';
import '../services/trash_restore_coordinator.dart';
import '../../utils/app_directories.dart';

/// 本地备份导入导出（WebDAV/S3/LAN 远程同步已移除）。
class BackupProvider extends ChangeNotifier {
  final DataSync _dataSync;
  final ChatService _chatService;
  final RepairService _repairService;
  BackupExportOptions _options;
  bool _busy = false;
  String? _message;

  BackupProvider({
    required ChatService chatService,
    required TrashRestoreCoordinator trashRestoreCoordinator,
    BackupExportOptions? initialOptions,
    RepairService? repairService,
  }) : _dataSync = DataSync(
         chatService: chatService,
         localIdResolver: trashRestoreCoordinator.getLocalIds,
       ),
       _chatService = chatService,
       _repairService = repairService ?? RepairService(),
       _options = initialOptions ?? const BackupExportOptions();

  BackupExportOptions get options => _options;
  bool get busy => _busy;
  String? get message => _message;

  void updateOptions(BackupExportOptions options) {
    _options = options;
    notifyListeners();
  }

  Future<File> exportToFile() async {
    _busy = true;
    _message = null;
    notifyListeners();
    try {
      return await _dataSync.exportToFile(_options);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<File> incrementalExportToFile(IncrementalBackupConfig config) async {
    _busy = true;
    _message = null;
    notifyListeners();
    try {
      return await _dataSync.exportToFile(_options, incremental: config);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> restoreFromLocalFile(
    File file, {
    RestoreMode mode = RestoreMode.overwrite,
  }) => _dataSync.restoreFromLocalFile(file, _options, mode: mode);

  // ---------------------------------------------------------------------------
  // Repair / Maintenance — exposed to the "Repair & Maintenance" section on the
  // backup page and the recovery page. All operations run on the live Drift
  // connection and never delete user data; for a destructive reset use
  // [rebuildLocalDatabase].
  // ---------------------------------------------------------------------------

  /// Run REINDEX over every user table, then ANALYZE (statistics) and VACUUM
  /// (defragment the file). Safe to run on a live database.
  Future<RepairReport> repairLocalDatabase() async {
    _busy = true;
    _message = null;
    notifyListeners();
    try {
      final db = _chatService.appDatabase;
      if (db == null) {
        throw StateError('ChatService not initialized; cannot repair.');
      }
      return await _repairService.fullRepair(db);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Sweep orphan rows whose parent was deleted under a disabled FK.
  Future<OrphanReport> sweepOrphans() async {
    _busy = true;
    _message = null;
    notifyListeners();
    try {
      final db = _chatService.appDatabase;
      if (db == null) {
        throw StateError('ChatService not initialized; cannot sweep.');
      }
      return await _repairService.sweepOrphans(db);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Destructive: deletes the SQLite file (and WAL/SHM) and recreates the
  /// schema from scratch. All local conversations, messages, assistants and
  /// chat-side metadata are lost. Callers MUST prompt the user first.
  Future<void> rebuildLocalDatabase() async {
    _busy = true;
    _message = null;
    notifyListeners();
    try {
      // Close the live connection before deleting the file. Drift's
      // NativeDatabase holds an exclusive lock on WAL mode.
      await _chatService.close();
      final appDataDir = await AppDirectories.getAppDataDirectory();
      if (!await appDataDir.exists()) {
        await appDataDir.create(recursive: true);
      }
      final dbFile = File(p.join(appDataDir.path, AppDatabase.databaseFileName));
      await _repairService.deleteDatabaseFile(dbFile);
      // Reopen from scratch — runs all migrations on a fresh schema.
      await _chatService.reInit();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
