import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:Cuplivo/core/services/backup/kelivo_v2_exception.dart';
import 'package:Cuplivo/core/services/backup/kelivo_v2_importer.dart';

void main() {
  late Directory root;
  late Directory extractDir;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('kelivo_v2_importer_test');
    extractDir = Directory(p.join(root.path, 'extracted'));
    await extractDir.create(recursive: true);
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  /// 创建模拟 kelivo v2 备份目录（kelivo.db + settings.json + 媒体）。
  void buildKelivoBackup({
    bool withSettings = true,
    bool withMedia = true,
  }) {
    // --- kelivo.db（drift snake_case 表结构） ---
    final dbPath = p.join(extractDir.path, 'database', 'kelivo.db');
    File(dbPath).parent.createSync(recursive: true);
    final db = sqlite3.open(dbPath);
    try {
      db.execute('''
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
          part_id TEXT, conversation_id TEXT, revision_id TEXT, ordinal INTEGER,
          kind TEXT, payload TEXT
        );
        CREATE TABLE provider_artifact_rows (
          revision_id TEXT, kind TEXT, payload TEXT
        );
        CREATE TABLE asset_rows (
          id TEXT PRIMARY KEY, content_hash TEXT, path TEXT, byte_size INTEGER
        );
        CREATE TABLE message_asset_rows (
          revision_id TEXT, asset_id TEXT
        );
      ''');
      final now = DateTime.utc(2026, 8, 17, 12, 34, 56, 789).millisecondsSinceEpoch;
      final nowUs = now * 1000; // kelivo 存微秒
      db.execute(
        'INSERT INTO conversation_rows VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
        ['c1', 'Test Conv', nowUs, nowUs, 0, 'a1', -1, '{"m1":1}', null, null,
         '[]', null, null],
      );
      db.execute(
        'INSERT INTO conversation_mcp_server_rows VALUES (?,?,?)',
        ['c1', 'mcp_server_1', 0],
      );
      db.execute(
        'INSERT INTO message_rows VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        ['m1', 'c1', 'user', nowUs, 'model-x', 'provider-x', 10, 0, null, null,
         null, null, null, 1, 5, 5, 0, 100, 0],
      );
      db.execute(
        'INSERT INTO message_rows VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        ['m2', 'c1', 'assistant', nowUs, 'model-y', 'provider-y', 20, 0,
         nowUs, nowUs, null, null, null, 1, 10, 8, 2, 200, 1],
      );
      db.execute(
        'INSERT INTO message_rows VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        ['m3', 'c1', 'user', nowUs, 'model-x', 'provider-x', 5, 0, null, null,
         null, null, null, 1, 2, 1, 1, 50, 2],
      );
      // m2 的 parts：text + reasoning + tool_call
      db.execute(
        'INSERT INTO message_part_rows VALUES (?,?,?,?,?,?)',
        ['p1', 'c1', 'm2', 0, 'text', 'Answer text'],
      );
      db.execute(
        'INSERT INTO message_part_rows VALUES (?,?,?,?,?,?)',
        ['p2', 'c1', 'm2', 1, 'reasoning', 'Deep thinking'],
      );
      db.execute(
        'INSERT INTO message_part_rows VALUES (?,?,?,?,?,?)',
        ['p3', 'c1', 'm2', 2, 'tool_call',
         '{"name":"search","args":{"q":"hello"}}'],
      );
      // m3 的 image part
      db.execute(
        'INSERT INTO message_part_rows VALUES (?,?,?,?,?,?)',
        ['p4', 'c1', 'm3', 0, 'image',
         '{"uri":"kelivo-file://upload/test.png","assetId":"asset1"}'],
      );
      // 资产
      db.execute(
        'INSERT INTO asset_rows VALUES (?,?,?,?)',
        ['asset1', 'hash1', 'upload/test.png', 10],
      );
      db.execute(
        'INSERT INTO message_asset_rows VALUES (?,?)',
        ['m3', 'asset1'],
      );
      // gemini 签名
      db.execute(
        'INSERT INTO provider_artifact_rows VALUES (?,?,?)',
        ['m2', 'gemini_thought_signature', 'sig-payload-1'],
      );
    } finally {
      db.close();
    }

    // --- settings.json（assistants_v1 为 JSON 字符串） ---
    if (withSettings) {
      File(p.join(extractDir.path, 'settings.json')).writeAsStringSync(
        jsonEncode({
          'some_key': 'v',
          'assistants_v1': jsonEncode([
            {
              'id': 'a1',
              'name': 'Helper',
              'presetMessages': '["hi","hello"]',
              'allowPastConversationRecall': true,
            },
          ]),
        }),
      );
    }

    // --- manifest.json + 媒体 ---
    File(p.join(extractDir.path, 'manifest.json')).writeAsStringSync(
      jsonEncode({
        'format': 'kelivo-backup',
        'formatVersion': 2,
        'payloadKind': 'sqlite',
        'entries': {'database/kelivo.db': 1},
      }),
    );
    if (withMedia) {
      final uploadDir = Directory(p.join(extractDir.path, 'upload'));
      uploadDir.createSync(recursive: true);
      File(p.join(uploadDir.path, 'test.png')).writeAsBytesSync([1, 2, 3]);
    }
  }

  test('converts kelivo.db + settings into chats.json + settings.json', () async {
    buildKelivoBackup();

    await KelivoV2Importer.convertBackup(extractDir);

    // chats.json
    final chatsFile = File(p.join(extractDir.path, 'chats.json'));
    expect(chatsFile.existsSync(), isTrue);
    final chats = jsonDecode(await chatsFile.readAsString()) as Map<String, dynamic>;
    expect(chats['version'], 2);

    final convs = (chats['conversations'] as List).cast<Map<String, dynamic>>();
    expect(convs, hasLength(1));
    expect(convs[0]['id'], 'c1');
    expect(convs[0]['title'], 'Test Conv');
    expect(convs[0]['messageIds'], ['m1', 'm2', 'm3']);
    expect(convs[0]['mcpServerIds'], ['mcp_server_1']);
    expect(convs[0]['conversationKind'], 'normal');
    expect(convs[0]['parentConversationId'], isNull);
    expect(convs[0]['createdAt'], '2026-08-17T12:34:56.789000Z');

    final msgs = (chats['messages'] as List).cast<Map<String, dynamic>>();
    expect(msgs, hasLength(3));
    final m1 = msgs.firstWhere((m) => m['id'] == 'm1');
    expect(m1['role'], 'user');
    expect(m1['content'], '');
    expect(m1['conversationId'], 'c1');
    expect(m1['timestamp'], '2026-08-17T12:34:56.789000Z');

    final m2 = msgs.firstWhere((m) => m['id'] == 'm2');
    expect(m2['content'], 'Answer text');
    expect(m2['reasoningText'], 'Deep thinking');
    expect(m2['isPreset'], false);
    expect(m2['speakerAssistantId'], isNull);
    expect(m2['modelId'], 'model-y');
    expect(m2['providerId'], 'provider-y');
    expect(m2['reasoningStartAt'], '2026-08-17T12:34:56.789000Z');

    // image part -> [image:upload/test.png]（kelivo-file URI 解析 + 文件存在）
    final m3 = msgs.firstWhere((m) => m['id'] == 'm3');
    expect(m3['content'], '\n[image:/upload/test.png]');

    // toolEvents（tool_call part）
    final toolEvents = chats['toolEvents'] as Map<String, dynamic>;
    expect(toolEvents.containsKey('m2'), isTrue);
    final ev = (toolEvents['m2'] as List).cast<Map<String, dynamic>>();
    expect(ev, hasLength(1));
    expect(ev[0]['name'], 'search');

    // gemini 签名
    final sigs = chats['geminiThoughtSigs'] as Map<String, dynamic>;
    expect(sigs['m2'], 'sig-payload-1');

    // groupChats 为空（kelivo 无群聊）
    expect(chats['groupChats'], isEmpty);
    expect(chats['groupMembers'], isEmpty);

    // settings.json：assistants_v1 保持 String 原样（cuplivo 恢复流程只认 String）
    final settings = jsonDecode(
      await File(p.join(extractDir.path, 'settings.json')).readAsString(),
    ) as Map<String, dynamic>;
    expect(settings['assistants_v1'], isA<String>());
    final assistants = jsonDecode(settings['assistants_v1'] as String) as List;
    expect(assistants, hasLength(1));
    expect(assistants[0]['id'], 'a1');
  });

  test('unknown part kinds are preserved into content', () async {
    buildKelivoBackup();
    // 加一个未知类型的 part
    final db = sqlite3.open(p.join(extractDir.path, 'database', 'kelivo.db'));
    try {
      db.execute(
        'INSERT INTO message_part_rows VALUES (?,?,?,?,?,?)',
        ['p5', 'c1', 'm1', 0, 'mystery_kind', 'raw payload'],
      );
    } finally {
      db.close();
    }

    await KelivoV2Importer.convertBackup(extractDir);
    final chats = jsonDecode(
      await File(p.join(extractDir.path, 'chats.json')).readAsString(),
    ) as Map<String, dynamic>;
    final msgs = (chats['messages'] as List).cast<Map<String, dynamic>>();
    final m1 = msgs.firstWhere((m) => m['id'] == 'm1');
    expect(m1['content'], 'raw payload');
  });

  test('missing kelivo.db throws KelivoV2BackupException', () async {
    File(p.join(extractDir.path, 'manifest.json'))
        .writeAsStringSync('{"format":"kelivo-backup"}');
    await expectLater(
      KelivoV2Importer.convertBackup(extractDir),
      throwsA(isA<KelivoV2BackupException>()),
    );
  });
}
