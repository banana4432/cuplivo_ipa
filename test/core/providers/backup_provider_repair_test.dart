import 'package:Cuplivo/core/database/repair_service.dart';
import 'package:Cuplivo/core/providers/backup_provider.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/trash_restore_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BackupProvider.repairLocalDatabase', () {
    late ChatService chatService;
    late TrashRestoreCoordinator trash;
    late BackupProvider provider;

    setUp(() {
      chatService = ChatService();
      trash = TrashRestoreCoordinator(chatService: chatService);
      provider = BackupProvider(
        chatService: chatService,
        trashRestoreCoordinator: trash,
        repairService: RepairService(),
      );
    });

    test('throws StateError when ChatService is not initialized', () async {
      // ChatService has not been init()ed — appDatabase is null.
      await expectLater(
        () => provider.repairLocalDatabase(),
        throwsA(isA<StateError>()),
      );
    });

    test('sweepOrphans throws when ChatService is not initialized', () async {
      await expectLater(
        () => provider.sweepOrphans(),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('RepairReport / OrphanReport', () {
    test('RepairReport.toString contains all flags', () {
      final r = RepairReport(
        elapsed: const Duration(milliseconds: 42),
        reindexedTables: const ['assistant_rows', 'conversation_rows'],
        vacuumed: true,
        analyzed: true,
      );
      final s = r.toString();
      expect(s, contains('42'));
      expect(s, contains('reindexed=2'));
      expect(s, contains('vacuumed=true'));
      expect(s, contains('analyzed=true'));
    });

    test('OrphanReport.total sums across fields', () {
      final r = OrphanReport(
        assistants: 1,
        conversations: 2,
        messages: 3,
        mcpServers: 4,
      );
      expect(r.total, 10);
    });
  });
}