import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/acceptance_record.dart';
import 'database_service.dart';

final offlineCacheServiceProvider = Provider<OfflineCacheService>((ref) {
  final dbService = ref.read(databaseServiceProvider);
  return OfflineCacheService(dbService: dbService);
});

class OfflineCacheService {
  final DatabaseService dbService;

  const OfflineCacheService({required this.dbService});

  Future<int> saveRecord(AcceptanceRecord record) async {
    final db = await dbService.database;
    return db.insert('acceptance_record', record.toMap());
  }

  Future<int> updateRecord(AcceptanceRecord record) async {
    final db = await dbService.database;
    if (record.id == null) {
      return saveRecord(record);
    }
    final map = Map<String, Object?>.from(record.toMap());
    map.remove('id');
    return db.update(
      'acceptance_record',
      map,
      where: 'id = ?',
      whereArgs: [record.id],
    );
  }

  Future<List<AcceptanceRecord>> getPendingUploadRecords() async {
    final db = await dbService.database;
    final rows = await db.query(
      'acceptance_record',
      where: 'uploaded = 0',
      orderBy: 'created_at DESC',
    );
    return rows.map(AcceptanceRecord.fromMap).toList();
  }

  Future<void> markUploaded(int id) async {
    final db = await dbService.database;
    await db.update(
      'acceptance_record',
      {'uploaded': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
