import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/repair_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late RepairService svc;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    svc = RepairService();
  });

  tearDown(() async {
    await db.close();
  });

  group('RepairService.reindexAndAnalyze', () {
    test('runs REINDEX over every user table', () async {
      // Insert a row so the tables have at least one indexable page.
      await db.customStatement(
        "INSERT INTO assistant_rows (id, name, system_prompt, message_template, custom_headers_json, custom_body_json, version_selections_json, chat_suggestions_json, skill_ids_json, max_message_count, ocr_mode, docx_mode, pdf_mode, other_office_mode, memory_mode, prompt_injection_group_id_v1) "
        "VALUES ('a1', 'Test', '', '', '[]', '[]', '{}', '[]', '[]', 64, 'auto', 'extract', 'extract', 'direct', 'injection', NULL)",
      );

      final report = await svc.reindexAndAnalyze(db);

      expect(report.vacuumed, isFalse);
      expect(report.analyzed, isTrue);
      expect(report.reindexedTables, isNotEmpty);
      expect(report.reindexedTableCount, report.reindexedTables.length);
      // The core tables from the schema must appear in the reindex list.
      expect(report.reindexedTables, contains('assistant_rows'));
    });

    test('userTableNames excludes sqlite_* internal tables', () async {
      final names = await RepairService.userTableNames(db);
      expect(names, isNotEmpty);
      expect(names.any((n) => n.startsWith('sqlite_')), isFalse);
      expect(names, contains('assistant_rows'));
    });
  });

  group('RepairService.vacuum', () {
    test('VACUUM returns a report marking vacuumed=true', () async {
      final report = await svc.vacuum(db);
      expect(report.vacuumed, isTrue);
      expect(report.analyzed, isFalse);
      expect(report.reindexedTables, isEmpty);
    });
  });

  group('RepairService.fullRepair', () {
    test('runs REINDEX, ANALYZE and VACUUM in one call', () async {
      final report = await svc.fullRepair(db);
      expect(report.vacuumed, isTrue);
      expect(report.analyzed, isTrue);
      expect(report.reindexedTableCount, greaterThan(0));
    });
  });

  group('RepairService.sweepOrphans', () {
    test('removes conversation with non-existent assistant', () async {
      // Insert a conversation referencing assistant 'missing' that does not
      // exist. The orphan sweep should delete it.
      await db.customStatement(
        "INSERT INTO conversation_rows (id, title, created_at, updated_at, assistant_id) "
        "VALUES ('c-orphan', 'Orphan', 0, 0, 'missing')",
      );
      await db.customStatement(
        "INSERT INTO conversation_rows (id, title, created_at, updated_at, assistant_id) "
        "VALUES ('c-keep', 'Keep', 0, 0, NULL)",
      );

      final report = await svc.sweepOrphans(db);
      expect(report.conversations, 1);

      final remaining = await db.customSelect(
        "SELECT id FROM conversation_rows",
      ).get();
      final ids = remaining.map((r) => r.read<String>('id')).toSet();
      expect(ids, contains('c-keep'));
      expect(ids, isNot(contains('c-orphan')));
    });

    test('removes message whose conversation was deleted', () async {
      // Insert an assistant + a conversation referencing it, then a message
      // referencing the conversation. Delete the conversation out-of-band
      // (FK off) — the orphan sweep should detect the message and clean it.
      await db.customStatement(
        "INSERT INTO assistant_rows (id, name, system_prompt, message_template, custom_headers_json, custom_body_json, version_selections_json, chat_suggestions_json, skill_ids_json, max_message_count, ocr_mode, docx_mode, pdf_mode, other_office_mode, memory_mode, prompt_injection_group_id_v1) "
        "VALUES ('a1', 'Test', '', '', '[]', '[]', '{}', '[]', '[]', 64, 'auto', 'extract', 'extract', 'direct', 'injection', NULL)",
      );
      await db.customStatement(
        "INSERT INTO conversation_rows (id, title, created_at, updated_at, assistant_id) "
        "VALUES ('c1', 'C1', 0, 0, 'a1')",
      );
      await db.customStatement(
        "INSERT INTO message_rows (id, conversation_id, role, content, timestamp, message_order) "
        "VALUES ('m1', 'c1', 'user', 'hi', 0, 0)",
      );
      // Disable FK enforcement so the test scenario is real-world (the sweep
      // exists precisely for cases where FKs were off or bypassed).
      await db.customStatement('PRAGMA foreign_keys = OFF;');
      await db.customStatement("DELETE FROM conversation_rows WHERE id = 'c1'");

      final report = await svc.sweepOrphans(db);
      expect(report.messages, 1);
    });
  });
}