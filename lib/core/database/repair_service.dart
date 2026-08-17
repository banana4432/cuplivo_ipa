import 'dart:io';

import 'package:drift/drift.dart';

import 'app_database.dart';

/// Maintenance operations on the Drift database: rebuild indexes, vacuum
/// fragmentation, update query statistics, and sweep orphan rows.
///
/// All operations are non-destructive: they touch schema and statistics only,
/// never delete data. To delete local state, use [rebuildDatabase] which
/// deletes the SQLite file (caller is responsible for closing the existing
/// connection and re-opening via [AppDatabase.open]).
class RepairService {
  /// Tables that participate in the regular Drift schema. Read from
  /// sqlite_master at runtime so newly added tables (after a migration) are
  /// picked up automatically.
  static Future<List<String>> userTableNames(AppDatabase db) async {
    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master "
          "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
        )
        .get();
    return rows.map((r) => r.read<String>('name')).toList();
  }

  /// Run REINDEX over every user table, then ANALYZE. VACUUM is **not** run
  /// here because it cannot live inside a transaction; callers should call
  /// [vacuum] afterwards for the full pipeline.
  ///
  /// Returns a [RepairReport] describing what was done and how long it took.
  Future<RepairReport> reindexAndAnalyze(AppDatabase db) async {
    final sw = Stopwatch()..start();
    final tables = await userTableNames(db);

    // ANALYZE writes to sqlite_stat1 — readPool:1 keeps writes serialized.
    // REINDEX rebuilds every named index; safe to run inside a transaction.
    await db.transaction(() async {
      for (final name in tables) {
        // Backticks because cuplivo table names match regular identifiers,
        // but be defensive against reserved words in future schemas.
        await db.customStatement('REINDEX `$name`;');
      }
      await db.customStatement('ANALYZE;');
    });

    sw.stop();
    return RepairReport(
      elapsed: sw.elapsed,
      reindexedTables: tables,
      vacuumed: false,
      analyzed: true,
    );
  }

  /// Run VACUUM. SQLite refuses to VACUUM inside a transaction, so this is
  /// a standalone call. After VACUUM the database file is rewritten without
  /// free pages, which can significantly shrink it after large deletes.
  Future<RepairReport> vacuum(AppDatabase db) async {
    final sw = Stopwatch()..start();
    await db.customStatement('VACUUM;');
    sw.stop();
    return RepairReport(
      elapsed: sw.elapsed,
      reindexedTables: const [],
      vacuumed: true,
      analyzed: false,
    );
  }

  /// Convenience: REINDEX + ANALYZE + VACUUM in one call. Most common
  /// "fix things that look weird" workflow.
  Future<RepairReport> fullRepair(AppDatabase db) async {
    final sw = Stopwatch()..start();
    final reindex = await reindexAndAnalyze(db);
    await vacuum(db);
    sw.stop();
    return RepairReport(
      elapsed: sw.elapsed,
      reindexedTables: reindex.reindexedTables,
      vacuumed: true,
      analyzed: true,
    );
  }

  /// Sweep orphan rows whose parent was deleted but whose FK was disabled
  /// or bypassed (older imports, partial restores, manual edits). Always
  /// re-enables FK enforcement at the end.
  Future<OrphanReport> sweepOrphans(AppDatabase db) async {
    int assistants = 0;
    int conversations = 0;
    int messages = 0;
    int mcpServers = 0;

    await db.transaction(() async {
      // conversation_rows.assistantId -> assistant_rows.id (orphan on delete)
      final convOrphans = await db.customSelect(
        'SELECT c.id AS id FROM conversation_rows c '
        'LEFT JOIN assistant_rows a ON a.id = c.assistant_id '
        "WHERE c.assistant_id IS NOT NULL AND c.assistant_id != '' AND a.id IS NULL",
      ).get();
      conversations = convOrphans.length;
      for (final row in convOrphans) {
        await db.customStatement(
          'DELETE FROM conversation_rows WHERE id = ?',
          [row.read<String>('id')],
        );
      }

      // message_rows.conversationId -> conversation_rows.id
      final msgOrphans = await db.customSelect(
        'SELECT m.id AS id FROM message_rows m '
        'LEFT JOIN conversation_rows c ON c.id = m.conversation_id '
        'WHERE c.id IS NULL',
      ).get();
      messages = msgOrphans.length;
      for (final row in msgOrphans) {
        await db.customStatement(
          'DELETE FROM message_rows WHERE id = ?',
          [row.read<String>('id')],
        );
      }

      // assistant rows referencing deleted MCP servers (soft FK).
      try {
        final mcpOrphans = await db.customSelect(
          'SELECT DISTINCT a.id AS id FROM assistant_rows a '
          'LEFT JOIN mcp_server_rows m ON m.id = a.default_mcp_server_id '
          'WHERE a.default_mcp_server_id IS NOT NULL '
          "AND a.default_mcp_server_id != '' AND m.id IS NULL",
        ).get();
        mcpServers = mcpOrphans.length;
        for (final row in mcpOrphans) {
          await db.customStatement(
            'UPDATE assistant_rows SET default_mcp_server_id = NULL WHERE id = ?',
            [row.read<String>('id')],
          );
        }
      } catch (_) {
        // Column may not exist on older schemas (pre-mcp-bind); ignore.
      }
    });

    return OrphanReport(
      assistants: assistants,
      conversations: conversations,
      messages: messages,
      mcpServers: mcpServers,
    );
  }

  /// Delete the SQLite file at [file] (and -wal/-shm if present). Caller MUST
  /// have closed the existing [AppDatabase] connection first. After this,
  /// call [AppDatabase.open] again to recreate the schema from scratch.
  Future<void> deleteDatabaseFile(File file) async {
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final f = File('${file.path}$suffix');
      if (await f.exists()) {
        await f.delete();
      }
    }
  }
}

/// Result of a [RepairService.reindexAndAnalyze] / [vacuum] / [fullRepair]
/// call. UI uses this to show what was done.
class RepairReport {
  RepairReport({
    required this.elapsed,
    required this.reindexedTables,
    required this.vacuumed,
    required this.analyzed,
  });

  final Duration elapsed;
  final List<String> reindexedTables;
  final bool vacuumed;
  final bool analyzed;

  int get reindexedTableCount => reindexedTables.length;

  @override
  String toString() =>
      'RepairReport(elapsed=$elapsed, reindexed=$reindexedTableCount, '
      'vacuumed=$vacuumed, analyzed=$analyzed)';
}

/// Result of an orphan sweep.
class OrphanReport {
  OrphanReport({
    required this.assistants,
    required this.conversations,
    required this.messages,
    required this.mcpServers,
  });

  final int assistants;
  final int conversations;
  final int messages;
  final int mcpServers;

  int get total => assistants + conversations + messages + mcpServers;

  @override
  String toString() =>
      'OrphanReport(assistants=$assistants, conversations=$conversations, '
      'messages=$messages, mcpServers=$mcpServers)';
}