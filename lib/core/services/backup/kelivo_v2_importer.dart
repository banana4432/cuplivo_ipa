import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'kelivo_v2_exception.dart';

/// 将 Kelivo v2 备份（`manifest.json` + `database/kelivo.db` 载荷）在应用内
/// 自动转换为 Cuplivo 可恢复的格式（`chats.json` + `settings.json`）。
///
/// 转换逻辑移植自 kelivo-helper 兼容工具（kelivo-helper.netlify.app/#/compat）：
/// 用 sqlite3 直接读取 kelivo.db，按表关系拼装成 chats.json v2 结构；
/// settings.json 中 assistants_v1 做兼容手术。转换失败抛
/// [KelivoV2BackupException]，由 UI 层引导用户走网页降级兜底。
class KelivoV2Importer {
  KelivoV2Importer._();

  /// 媒体目录白名单（与 kelivo-helper 一致）。
  static const List<String> _mediaDirs = ['upload', 'images', 'avatars', 'fonts'];

  /// 在解压目录上执行转换：
  /// 1. 读取 `database/kelivo.db`，生成 `chats.json`（v2 结构）写入解压目录；
  /// 2. 对 `settings.json` 做 assistants_v1 兼容手术。
  ///
  /// 媒体文件已随备份解压在 `upload/`、`images/`、`avatars/`、`fonts/`
  /// 目录中（与 Cuplivo 备份布局一致），无需移动。
  static Future<void> convertBackup(Directory extractDir) async {
    final dbPath = p.join(extractDir.path, 'database', 'kelivo.db');
    if (!File(dbPath).existsSync()) {
      throw const KelivoV2BackupException();
    }

    final db = sqlite3.open(dbPath);
    try {
      final chats = _buildChatsJson(db, extractDir);
      await File(p.join(extractDir.path, 'chats.json'))
          .writeAsString(jsonEncode(chats));

      final settingsPath = p.join(extractDir.path, 'settings.json');
      final settingsFile = File(settingsPath);
      if (await settingsFile.exists()) {
        try {
          final map =
              jsonDecode(await settingsFile.readAsString())
                  as Map<String, dynamic>;
          await settingsFile.writeAsString(jsonEncode(_processSettings(map)));
        } catch (_) {
          // settings.json 无法解析时保持原样，恢复流程会忽略它。
        }
      }
    } finally {
      db.close();
    }
  }

  // ===== settings.json 处理（移植自 kelivo-helper Qo/Xo） =====

  static Map<String, dynamic> _processSettings(Map<String, dynamic> settings) {
    final s = Map<String, dynamic>.from(settings);
    final raw = s['assistants_v1'];
    if (raw is String && raw.isNotEmpty) {
      try {
        final parsed = jsonDecode(raw);
        if (parsed is List) {
          final list = parsed.map((a) {
            if (a is! Map) return a;
            final o = Map<String, dynamic>.from(a);
            final preset = o['presetMessages'];
            if (preset is String) {
              try {
                final d = jsonDecode(preset);
                if (d is List) o['presetMessages'] = d;
              } catch (_) {}
            }
            final recall = o['allowPastConversationRecall'];
            if (recall is bool && o['enableRecentChatsReference'] == null) {
              o['enableRecentChatsReference'] = recall;
            }
            return o;
          }).toList();
          s['assistants_v1'] = list;
        }
      } catch (_) {}
    }
    return s;
  }

  // ===== chats.json 构建（移植自 kelivo-helper fl/tl/el/nl/rl/sl/il/al） =====

  /// 执行查询并按列名映射为 Map（sqlite3 的 Row 只支持 int 下标）。
  static List<Map<String, Object?>> _queryMaps(Database db, String sql) {
    final rs = db.select(sql);
    final names = List<String>.from(rs.columnNames);
    return rs.rows
        .map(
          (row) => {
            for (var i = 0; i < names.length; i++) names[i]: row[i],
          },
        )
        .toList();
  }

  static Map<String, dynamic> _buildChatsJson(
    Database db,
    Directory extractDir,
  ) {
    final convRows = _queryMaps(
      db,
      'SELECT id, title, created_at, updated_at, is_pinned, assistant_id, '
      'truncate_index, version_selections_json, summary, '
      'last_summarized_message_count, chat_suggestions_json, '
      'injected_memory_hash, last_memory_extracted_order '
      'FROM conversation_rows',
    );
    final mcpRows = _queryMaps(
      db,
      'SELECT conversation_id, server_id FROM conversation_mcp_server_rows '
      'ORDER BY conversation_id, ordinal',
    );
    final msgRows = _queryMaps(
      db,
      'SELECT id, conversation_id, role, timestamp, model_id, provider_id, '
      'total_tokens, is_streaming, reasoning_start_at, '
      'reasoning_finished_at, translation, reasoning_segments_json, '
      'group_id, version, prompt_tokens, completion_tokens, cached_tokens, '
      'duration_ms, message_order FROM message_rows '
      'ORDER BY conversation_id, message_order',
    );
    final partRows = _queryMaps(
      db,
      'SELECT part_id, conversation_id, revision_id, ordinal, kind, payload '
      'FROM message_part_rows ORDER BY revision_id, ordinal',
    );
    final artifactRows = _queryMaps(
      db,
      "SELECT revision_id, kind, payload FROM provider_artifact_rows "
      "WHERE kind = 'gemini_thought_signature'",
    );
    final assetRows = _queryMaps(
      db,
      'SELECT id, content_hash, path, byte_size FROM asset_rows',
    );
    final msgAssetRows = _queryMaps(
      db,
      'SELECT revision_id, asset_id FROM message_asset_rows '
      'ORDER BY revision_id',
    );

    // conversation_id -> [server_id]
    final mcpIds = <String, List<String>>{};
    for (final x in mcpRows) {
      final convId = x['conversation_id'] as String;
      (mcpIds[convId] ??= []).add(x['server_id'] as String);
    }
    // conversation_id -> [message id]
    final msgIds = <String, List<String>>{};
    for (final x in msgRows) {
      final convId = x['conversation_id'] as String;
      (msgIds[convId] ??= []).add(x['id'] as String);
    }
    // revision_id -> [message_part_rows]
    final partsByRevision = <String, List<Map<String, Object?>>>{};
    for (final x in partRows) {
      final revId = x['revision_id'] as String;
      (partsByRevision[revId] ??= []).add(x);
    }
    // asset_id -> asset
    final assetById = <String, Map<String, Object?>>{};
    for (final x in assetRows) {
      assetById[x['id'] as String] = x;
    }
    // asset_id -> path（zip 中存在时）
    final assetPathById = <String, String>{};
    for (final x in msgAssetRows) {
      final assetId = x['asset_id'] as String;
      final asset = assetById[assetId];
      if (asset != null && !assetPathById.containsKey(assetId)) {
        assetPathById[assetId] = asset['path'] as String;
      }
    }

    // 消息 -> {message, toolEvents}
    final toolEvents = <String, List<Map<String, dynamic>>>{};
    final messages = <Map<String, dynamic>>[];
    for (final x in msgRows) {
      final parts = partsByRevision[x['id'] as String] ?? const <Map<String, Object?>>[];
      final built = _buildMessage(x, parts, extractDir, assetPathById);
      if (built.toolEvents.isNotEmpty) {
        toolEvents[x['id'] as String] = built.toolEvents;
      }
      messages.add(built.message);
    }

    // gemini 签名
    final geminiThoughtSigs = <String, String>{};
    for (final x in artifactRows) {
      geminiThoughtSigs[x['revision_id'] as String] = x['payload'] as String;
    }

    // 会话
    final conversations = convRows
        .map(
          (x) => _buildConversation(
            x,
            mcpIds[x['id'] as String] ?? const <String>[],
            msgIds[x['id'] as String] ?? const <String>[],
          ),
        )
        .toList();

    return {
      'version': 2,
      'conversations': conversations,
      'messages': messages,
      'toolEvents': toolEvents,
      'geminiThoughtSigs': geminiThoughtSigs,
      'groupChats': const <Map<String, dynamic>>[],
      'groupMembers': const <Map<String, dynamic>>[],
    };
  }

  // ===== 会话转换（移植自 kelivo-helper ul） =====

  static Map<String, dynamic> _buildConversation(
    Map<String, Object?> row,
    List<String> mcpServerIds,
    List<String> messageIds,
  ) {
    return {
      'id': row['id'] as String,
      'title': row['title'] as String,
      'createdAt': _ts(row['created_at']),
      'updatedAt': _ts(row['updated_at']),
      'messageIds': messageIds,
      'isPinned': (row['is_pinned'] as int? ?? 0) != 0,
      'mcpServerIds': mcpServerIds,
      'assistantId': row['assistant_id'] as String?,
      'parentConversationId': null,
      'truncateIndex': row['truncate_index'] as int? ?? -1,
      'versionSelections': _jsonOr(row['version_selections_json'], <String, dynamic>{}),
      'summary': row['summary'] as String?,
      'lastSummarizedMessageCount': row['last_summarized_message_count'] as int?,
      'chatSuggestions': _jsonOr(row['chat_suggestions_json'], <dynamic>[]),
      'conversationKind': 'normal',
      'injectedMemoryHash': row['injected_memory_hash'] as String?,
      'lastMemoryExtractedOrder': row['last_memory_extracted_order'] as int?,
    };
  }

  // ===== 消息转换（移植自 kelivo-helper cl） =====

  static ({Map<String, dynamic> message, List<Map<String, dynamic>> toolEvents})
  _buildMessage(
    Map<String, Object?> row,
    List<Map<String, Object?>> parts,
    Directory extractDir,
    Map<String, String> assetPathById,
  ) {
    var content = '';
    final reasoning = <String>[];
    final toolEvents = <Map<String, dynamic>>[];
    for (final part in parts) {
      final built = _buildPart(
        part['kind'] as String,
        part['payload'] as String,
        extractDir,
        assetPathById,
      );
      if (built.isReasoning) {
        if (built.text.isNotEmpty) reasoning.add(built.text);
      } else {
        content += built.text;
      }
      if (built.toolEvent != null) toolEvents.add(built.toolEvent!);
    }
    final message = <String, dynamic>{
      'id': row['id'] as String,
      'role': row['role'] as String,
      'content': content,
      'timestamp': _ts(row['timestamp']),
      'modelId': row['model_id'] as String?,
      'providerId': row['provider_id'] as String?,
      'totalTokens': row['total_tokens'] as int?,
      'conversationId': row['conversation_id'] as String,
      'isStreaming': (row['is_streaming'] as int? ?? 0) != 0,
      'reasoningText': reasoning.isEmpty ? null : reasoning.join('\n'),
      'reasoningStartAt': row['reasoning_start_at'] == null
          ? null
          : _ts(row['reasoning_start_at']),
      'reasoningFinishedAt': row['reasoning_finished_at'] == null
          ? null
          : _ts(row['reasoning_finished_at']),
      'translation': row['translation'] as String?,
      'reasoningSegmentsJson': row['reasoning_segments_json'] as String?,
      'groupId': row['group_id'] as String?,
      'subgroupId': null,
      'version': row['version'] as int?,
      'promptTokens': row['prompt_tokens'] as int?,
      'completionTokens': row['completion_tokens'] as int?,
      'cachedTokens': row['cached_tokens'] as int?,
      'durationMs': row['duration_ms'] as int?,
      'isPreset': false,
      'speakerAssistantId': null,
    };
    return (message: message, toolEvents: toolEvents);
  }

  // ===== 消息部件转换（移植自 kelivo-helper ll） =====

  static ({String text, Map<String, dynamic>? toolEvent, bool isReasoning})
  _buildPart(
    String kind,
    String payload,
    Directory extractDir,
    Map<String, String> assetPathById,
  ) {
    switch (kind) {
      case 'text':
        return (text: payload, toolEvent: null, isReasoning: false);
      case 'reasoning':
        return (text: payload, toolEvent: null, isReasoning: true);
      case 'tool_call':
        try {
          final r = jsonDecode(payload);
          if (r is Map) {
            return (
              text: '',
              toolEvent: r.cast<String, dynamic>(),
              isReasoning: false,
            );
          }
        } catch (_) {}
        return (text: '', toolEvent: null, isReasoning: false);
      case 'image':
      case 'file':
        try {
          final r = jsonDecode(payload);
          if (r is! Map) return _dropped;
          final ref = _assetRef(
            (r['uri'] as String?) ?? '',
            (r['assetId'] as String?) ?? '',
            extractDir,
            assetPathById,
          );
          if (ref == null) return _dropped;
          if (kind == 'image') {
            return (text: '\n[image:$ref]', toolEvent: null, isReasoning: false);
          }
          final name = (r['name'] as String?)?.isNotEmpty == true
              ? r['name'] as String
              : 'file';
          final mime = (r['mime'] as String?)?.isNotEmpty == true
              ? r['mime'] as String
              : 'application/octet-stream';
          return (
            text: '\n[file:$ref|$name|$mime]',
            toolEvent: null,
            isReasoning: false,
          );
        } catch (_) {
          return _dropped;
        }
      default:
        // 未知部件类型：原样保留到 content
        return (text: payload, toolEvent: null, isReasoning: false);
    }
  }

  static const _dropped = (text: '', toolEvent: null, isReasoning: false);

  // ===== 媒体引用（移植自 kelivo-helper Wr/jr/$r/ol） =====

  static String? _assetRef(
    String uri,
    String assetId,
    Directory extractDir,
    Map<String, String> assetPathById,
  ) {
    if (uri.isEmpty) return null;
    if (RegExp(r'^(https?:|data:)', caseSensitive: false).hasMatch(uri)) {
      return uri;
    }
    final assetPath =
        assetId.isNotEmpty ? assetPathById[assetId] : null;

    final kelivoFile = RegExp(r'^kelivo-file:\/\/(.+)$').firstMatch(uri);
    if (kelivoFile != null) {
      String? o;
      try {
        final parts = kelivoFile
            .group(1)!
            .split('/')
            .map(Uri.decodeComponent)
            .toList();
        if (parts.length >= 2 &&
            !parts.any((v) => v.isEmpty || v == '.' || v == '..') &&
            _mediaDirs.contains(parts[0].toLowerCase())) {
          parts[0] = parts[0].toLowerCase();
          o = parts.join('/');
        }
      } catch (_) {}
      if (o == null) return uri;
      if (File(p.join(extractDir.path, o)).existsSync()) return '/$o';
      final f = _extractMediaPath(assetPath ?? '') ??
          _normalizeMediaPath(assetPath ?? '');
      if (f != null && File(p.join(extractDir.path, f)).existsSync()) {
        return '/$f';
      }
      return '/$o';
    }

    final l = _localPath(uri);
    if (l == null) return uri;
    final a = _extractMediaPath(l) ?? _normalizeMediaPath(l);
    if (a != null) return '/$a';
    return l;
  }

  /// 在路径中查找 `/upload/`、`/images/` 等媒体目录前缀并截取相对路径。
  static String? _extractMediaPath(String t) {
    final lower = t.toLowerCase();
    for (final dir in _mediaDirs) {
      final i = lower.indexOf('/$dir/');
      if (i != -1) {
        final r = t.substring(i + 1);
        if (r.length > dir.length + 1) return r;
      }
    }
    return null;
  }

  /// 校验 `dir/rest` 形式的媒体相对路径。
  static String? _normalizeMediaPath(String t) {
    final m = RegExp(r'^([A-Za-z0-9_-]+)/(.+)$').firstMatch(t);
    if (m == null) return null;
    final dir = m.group(1)!.toLowerCase();
    final rest = m.group(2)!;
    if (!_mediaDirs.contains(dir) || rest.isEmpty || rest.contains('..')) {
      return null;
    }
    return '$dir/$rest';
  }

  /// 本地文件路径规范化（file:// URI、Windows 盘符、反斜杠）。
  static String? _localPath(String t) {
    var n = t;
    if (RegExp(r'^file:', caseSensitive: false).hasMatch(n)) {
      try {
        final uri = Uri.parse(n);
        if (uri.host.isNotEmpty && uri.host != 'localhost') return null;
        n = Uri.decodeComponent(uri.path);
        if (RegExp(r'^\/[A-Za-z]:').hasMatch(n)) n = n.substring(1);
      } catch (_) {
        return null;
      }
    }
    if (n.startsWith('\\\\') || n.startsWith('//')) return null;
    if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(n)) {
      return n.replaceAll('\\', '/');
    }
    if (n.contains('\\')) return null;
    return n;
  }

  // ===== 工具 =====

  /// 微秒时间戳 -> ISO8601（6 位小数，与 kelivo-helper 一致）。
  /// kelivo.db 的时间戳列为微秒整数（drift 微秒模式）。
  static String _ts(Object? v) {
    if (v is int) {
      final ms = v ~/ 1000; // 微秒 -> 毫秒
      final us = ((v % 1000) + 1000) % 1000; // 微秒尾数
      final sec = ms ~/ 1000;
      final msPart = ((ms % 1000) + 1000) % 1000;
      final base = DateTime.fromMillisecondsSinceEpoch(
        sec * 1000,
        isUtc: true,
      ).toIso8601String().replaceFirst(RegExp(r'\.\d{3}Z$'), '');
      return '$base.${msPart.toString().padLeft(3, '0')}'
          '${us.toString().padLeft(3, '0')}Z';
    }
    if (v is String) {
      try {
        return DateTime.parse(v).toUtc().toIso8601String();
      } catch (_) {}
    }
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true).toIso8601String();
  }

  static dynamic _jsonOr(Object? raw, dynamic fallback) {
    if (raw == null) return fallback;
    if (raw is! String) return raw;
    try {
      return jsonDecode(raw) ?? fallback;
    } catch (_) {
      return fallback;
    }
  }
}
