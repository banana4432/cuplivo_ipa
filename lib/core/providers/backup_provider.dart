import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/backup.dart';
import '../models/incremental_backup.dart';
import '../services/chat/chat_service.dart';
import '../services/backup/data_sync.dart';
import '../services/trash_restore_coordinator.dart';

/// 本地备份导入导出（WebDAV/S3/LAN 远程同步已移除）。
class BackupProvider extends ChangeNotifier {
  final DataSync _dataSync;
  BackupExportOptions _options;
  bool _busy = false;
  String? _message;

  BackupProvider({
    required ChatService chatService,
    required TrashRestoreCoordinator trashRestoreCoordinator,
    BackupExportOptions? initialOptions,
  }) : _dataSync = DataSync(
         chatService: chatService,
         localIdResolver: trashRestoreCoordinator.getLocalIds,
       ),
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
}
