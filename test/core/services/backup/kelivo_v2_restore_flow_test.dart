import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/backup/kelivo_v2_importer.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';

/// 端到端模拟测试（全部模拟数据，不含真实对话）：
/// 模拟 kelivo v2 备份 → convertBackup → chats.json → fromJson 解析 →
/// restoreConversationsBatch 写入 drift → 读回验证。
/// 用于定位"导入后数据未恢复"的断点。
void main() {
  late Directory root;
  late Directory extractDir;
  late AppDatabase db;
  late ChatDatabaseRepository repo;
  late ChatService chatService;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('kelivo_flow_test');
    extractDir = Directory(p.join(root.path, 'extracted'));
    await extractDir.create(recursive: true);

    db = AppDatabase(NativeDatabase.memory());
    repo = ChatDatabaseRepository(db);
    chatService = ChatService();
  });

  tearDown(() async {
    try {
      await repo.close();
    } catch (_) {}
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  /// 构造模拟 kelivo v2 备份（2 会话 / 4 消息，覆盖 text/reasoning/tool_call）。
  void buildKelivoBackup() {
    final dbPath = p.join(extractDir.path, 'database', 'kelivo.db');
    File(dbPath).parent.createSync(recursive: true);
    final kdb = sqlite3.open(dbPath);
    try {
      kdb.execute('''
        CREATE TABLE conversation_rows (
          id TEXT PRIMARY KEY, title TEXT, created_at INTEGER, updated_at INTEGER,
          is_pinned INTEGER, assistant_id TEXT, truncate_index INTEGER,
          version_selections_json TEXT, summary TEXT,
          last_summarized_message_count INTEGER, chat_suggestions_json TEXT,
          injected_memory_hash TEXT, last_memory_extracted_order INTEGER
        );
        CREATE TABLE conversation_mcp_server_rows (
          conversation_id TEXT, server_id TEXT, ordinal INTEGER
        );
        CREATE TABLE message_rows (
          id TEXT PRIMARY KEY, conversation_id TEXT, role TEXT, timestamp INTEGER,
          model_id TEXT, provider_id TEXT, total_tokens INTEGER, is_streaming INTEGER,
          reasoning_start_at INTEGER, reasoning_finished_at INTEGER,
          translation TEXT, reasoning_segments_json TEXT, group_id TEXT,
          version INTEGER, prompt_tokens INTEGER, completion_tokens INTEGER,
          cached_tokens INTEGER, duration_ms INTEGER, message_order INTEGER
        );
        CREATE TABLE message_part_rows (
          part_id INTEGER, conversation_id TEXT, revision_id TEXT, ordinal INTEGER,
          kind TEXT, payload TEXT, created_at INTEGER, updated_at INTEGER
        );
        CREATE TABLE provider_artifact_rows (
          conversation_id TEXT, revision_id TEXT, kind TEXT, payload TEXT,
          created_at INTEGER, updated_at INTEGER
        );
        CREATE TABLE asset_rows (
          id TEXT PRIMARY KEY, content_hash TEXT, path TEXT, byte_size INTEGER,
          width INTEGER, height INTEGER, thumbnail_path TEXT,
          created_at INTEGER, last_referenced_at INTEGER
        );
        CREATE TABLE message_asset_rows (
          conversation_id TEXT, revision_id TEXT, asset_id TEXT, kind TEXT
        );
      ''');
      final now = 1787034896789000; // 微秒
      kdb.execute(
        'INSERT INTO conversation_rows VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
        ['c1', '会话一', now, now, 0, 'a1', -1, '{}', null, 0, '[]', null, -1],
      );
      kdb.execute(
        'INSERT INTO conversation_rows VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
        ['c2', '会话二', now, now, 1, 'a1', -1, '{}', null, 0, '[]', null, -1],
      );
      for (final (id, conv, role, order) in [
        ('m1', 'c1', 'user', 0),
        ('m2', 'c1', 'assistant', 1),
        ('m3', 'c2', 'user', 0),
        ('m4', 'c2', 'assistant', 1),
      ]) {
        kdb.execute(
          'INSERT INTO message_rows VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
          [id, conv, role, now, 'model-x', 'provider-x', 10, 0, null, null,
           null, null, null, 1, 5, 5, 0, 100, order],
        );
      }
      kdb.execute(
        'INSERT INTO message_part_rows VALUES (?,?,?,?,?,?,?,?)',
        [1, 'c1', 'm1', 0, 'text', '你好', now, now],
      );
      kdb.execute(
        'INSERT INTO message_part_rows VALUES (?,?,?,?,?,?,?,?)',
        [2, 'c1', 'm2', 0, 'text', '回答内容', now, now],
      );
      kdb.execute(
        'INSERT INTO message_part_rows VALUES (?,?,?,?,?,?,?,?)',
        [3, 'c1', 'm2', 1, 'reasoning', '思考过程', now, now],
      );
      kdb.execute(
        'INSERT INTO message_part_rows VALUES (?,?,?,?,?,?,?,?)',
        [4, 'c1', 'm2', 2, 'tool_call', '{"name":"search","args":{"q":"x"}}', now, now],
      );
      kdb.execute(
        'INSERT INTO message_part_rows VALUES (?,?,?,?,?,?,?,?)',
        [5, 'c2', 'm3', 0, 'text', '第二个会话消息', now, now],
      );
      kdb.execute(
        'INSERT INTO message_part_rows VALUES (?,?,?,?,?,?,?,?)',
        [6, 'c2', 'm4', 0, 'text', '回复二', now, now],
      );
      // gemini 签名
      kdb.execute(
        'INSERT INTO provider_artifact_rows VALUES (?,?,?,?,?,?)',
        ['c1', 'm2', 'gemini_thought_signature', 'sig1', now, now],
      );
    } finally {
      kdb.close();
    }

    File(p.join(extractDir.path, 'manifest.json'))
        .writeAsStringSync(jsonEncode({'format': 'kelivo-backup', 'formatVersion': 2}));
    File(p.join(extractDir.path, 'settings.json')).writeAsStringSync(
      jsonEncode({
        'some_key': 'v',
        'assistants_v1': jsonEncode([
          {'id': 'a1', 'name': '助手一'},
        ]),
      }),
    );
  }

  test('完整链路：转换 -> 解析 -> drift 写入 -> 读回', () async {
    buildKelivoBackup();

    // 1) 转换
    await KelivoV2Importer.convertBackup(extractDir);
    final chatsFile = File(p.join(extractDir.path, 'chats.json'));
    expect(chatsFile.existsSync(), isTrue, reason: '转换必须生成 chats.json');

    // 2) 解析（与恢复流程相同的严格类型转换）
    final chats =
        jsonDecode(await chatsFile.readAsString()) as Map<String, dynamic>;
    final convs = ((chats['conversations'] as List?) ?? const [])
        .map((e) => Conversation.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    final msgs = ((chats['messages'] as List?) ?? const [])
        .map((e) => ChatMessage.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    final toolEvents =
        ((chats['toolEvents'] as Map?) ?? const <String, dynamic>{}).map(
          (k, v) => MapEntry(
            k.toString(),
            (v as List).cast<Map>().map((e) => e.cast<String, dynamic>()).toList(),
          ),
        );
    final geminiThoughtSigs =
        ((chats['geminiThoughtSigs'] as Map?) ?? const <String, dynamic>{})
            .map((k, v) => MapEntry(k.toString(), v.toString()));

    expect(convs, hasLength(2));
    expect(msgs, hasLength(4));
    expect(toolEvents.containsKey('m2'), isTrue);
    expect(geminiThoughtSigs['m2'], 'sig1');

    // 3) 组装 byConv（恢复流程同款逻辑）
    final byConv = <String, List<ChatMessage>>{};
    for (final m in msgs) {
      (byConv[m.conversationId] ??= <ChatMessage>[]).add(m);
    }
    expect(byConv.length, 2, reason: '消息必须能分到 2 个会话');
    expect(byConv['c1']!.length, 2);
    expect(byConv['c2']!.length, 2);

    // 4) 写入 drift（restoreConversationsBatch 同款）
    await chatService.init();
    await repo.putRestoreBatch(
      conversations: convs,
      messagesByConversation: byConv,
      toolEventsByMessageId: toolEvents,
      geminiSignaturesByMessageId: geminiThoughtSigs,
    );

    // 5) 读回验证
    final readConvs = await repo.getAllCompleteConversations();
    expect(readConvs, hasLength(2), reason: 'drift 中应有 2 个会话');
    for (final c in readConvs) {
      final ms = await repo.getMessages(c.id);
      expect(ms, hasLength(2), reason: '每个会话应有 2 条消息（会话 ${c.id}）');
    }
    final m2 = (await repo.getMessages('c1')).firstWhere((m) => m.id == 'm2');
    expect(m2.content, '回答内容');
    expect(m2.reasoningText, '思考过程');
    expect(m2.reasoningStartAt, isNull); // kelivo 无 reasoning 时间戳
    expect(m2.role, 'assistant');
  });
}
