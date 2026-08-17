import 'dart:convert';

enum RestoreMode {
  overwrite, // 完全覆盖：清空本地后恢复
  merge, // 增量合并：智能去重
}

/// 本地备份导出的包含选项（精简版，原 WebDavConfig 仅保留 include 标志）。
class BackupExportOptions {
  final bool includeChats; // Hive boxes
  final bool includeFiles; // uploads/

  const BackupExportOptions({
    this.includeChats = true,
    this.includeFiles = true,
  });

  BackupExportOptions copyWith({
    bool? includeChats,
    bool? includeFiles,
  }) {
    return BackupExportOptions(
      includeChats: includeChats ?? this.includeChats,
      includeFiles: includeFiles ?? this.includeFiles,
    );
  }

  Map<String, dynamic> toJson() => {
        'includeChats': includeChats,
        'includeFiles': includeFiles,
      };

  static BackupExportOptions fromJson(Map<String, dynamic> json) {
    return BackupExportOptions(
      includeChats: json['includeChats'] as bool? ?? true,
      includeFiles: json['includeFiles'] as bool? ?? true,
    );
  }

  static BackupExportOptions fromJsonString(String s) {
    try {
      final map = jsonDecode(s) as Map<String, dynamic>;
      return BackupExportOptions.fromJson(map);
    } catch (_) {
      return const BackupExportOptions();
    }
  }

  String toJsonString() => jsonEncode(toJson());
}
