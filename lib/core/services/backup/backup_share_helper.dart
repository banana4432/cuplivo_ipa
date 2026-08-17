import 'dart:io';

import 'package:flutter/foundation.dart';

import '../native_file_save.dart';

/// Shared helper that exports a backup zip and prompts the user to pick a
/// save location on mobile (via [NativeFileSave] → UIDocumentPickerViewController
/// on iOS, SAF on Android). Returns the file whether or not the share
/// dialog was completed — callers should not assume the user accepted.
///
/// On non-mobile platforms this is a no-op (callers use FilePicker.saveFile).
/// Always exported as a future so callers can `await` for snackbar timing.
class BackupShareHelper {
  /// Returns true on mobile when the user accepted the picker and the file
  /// was copied; false when the user cancelled or the platform is non-mobile.
  /// Never throws — share failures are caught and logged.
  static Future<bool> shareExportedBackup(File file) async {
    final isMobile = Platform.isAndroid || Platform.isIOS;
    if (!isMobile) return false;
    try {
      final saved = await NativeFileSave.saveFileFromPath(
        sourcePath: file.path,
        fileName: file.uri.pathSegments.last,
      );
      return saved;
    } catch (e, st) {
      debugPrint('[BackupShare] failed to share ${file.path}: $e\n$st');
      return false;
    }
  }
}
