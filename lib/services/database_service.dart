import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/region.dart';
import '../models/library.dart';
import '../models/target.dart';

final databaseServiceProvider = Provider<DatabaseService>((ref) {
  return DatabaseService();
});

class DatabaseService {
  static const _dbName = 'acceptance_demo.db';
  static const _dbVersion = 1;

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _openDb();
    return _db!;
  }

  Future<Database> _openDb() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, _dbName);
    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await _createTables(db);
        await _insertMockData(db);
      },
    );
  }

  Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE rc_ou_region (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        id_code TEXT NOT NULL,
        name TEXT NOT NULL,
        parent_id_code TEXT
      );
    ''');

    await db.execute('''
      CREATE TABLE rc_library_library (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        id_code TEXT NOT NULL,
        name TEXT NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE rc_library_librarytarget (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        id_code TEXT NOT NULL,
        library_code TEXT NOT NULL,
        name TEXT NOT NULL,
        description TEXT
      );
    ''');

    await db.execute('''
      CREATE TABLE acceptance_record (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        region_code TEXT NOT NULL,
        region_text TEXT NOT NULL,
        library_code TEXT NOT NULL,
        library_name TEXT NOT NULL,
        target_code TEXT NOT NULL,
        target_name TEXT NOT NULL,
        result INTEGER NOT NULL,
        photo_path TEXT,
        remark TEXT,
        created_at TEXT NOT NULL,
        uploaded INTEGER NOT NULL DEFAULT 0
      );
    ''');
  }

  Future<void> _insertMockData(Database db) async {
    // rc_ou_region
    await db.insert('rc_ou_region', {
      'id_code': '00001',
      'name': '测试项目',
      'parent_id_code': '',
    });
    await db.insert('rc_ou_region', {
      'id_code': '0000100001',
      'name': '1期',
      'parent_id_code': '00001',
    });
    await db.insert('rc_ou_region', {
      'id_code': '000010000100001',
      'name': '1栋',
      'parent_id_code': '0000100001',
    });
    await db.insert('rc_ou_region', {
      'id_code': '00001000010000100006',
      'name': '6层',
      'parent_id_code': '000010000100001',
    });

    // rc_library_library
    await db.insert('rc_library_library', {
      'id_code': 'A001',
      'name': '钢筋工程',
    });
    await db.insert('rc_library_library', {
      'id_code': 'A002',
      'name': '模板工程',
    });

    // rc_library_librarytarget for 钢筋工程
    final targets = [
      {
        'id_code': 'A001001',
        'name': '钢筋规格型号',
        'description': '钢筋规格、型号、级别符合设计要求',
      },
      {
        'id_code': 'A001002',
        'name': '钢筋绑扎',
        'description': '钢筋绑扎牢固、节点搭接满足规范',
      },
      {
        'id_code': 'A001003',
        'name': '保护层厚度',
        'description': '钢筋保护层厚度满足规范要求',
      },
      {
        'id_code': 'A001004',
        'name': '钢筋间距',
        'description': '钢筋间距均匀、符合设计',
      },
      {
        'id_code': 'A001005',
        'name': '钢筋锚固及搭接',
        'description': '钢筋锚固长度、搭接长度符合规范',
      },
    ];

    for (final t in targets) {
      await db.insert('rc_library_librarytarget', {
        'id_code': t['id_code'],
        'library_code': 'A001',
        'name': t['name'],
        'description': t['description'],
      });
    }
  }

  String _normalizeText(String input) {
    var text = input.trim();
    // Remove common whitespace to handle STT inserting spaces between tokens.
    text = text.replaceAll(RegExp(r'\s+'), '');

    // Common STT homophones for construction terms.
    // These are intentionally conservative replacements.
    text = text.replaceAll('刚进', '钢筋');
    text = text.replaceAll('刚劲', '钢筋');
    text = text.replaceAll('干净', '钢筋');
    text = text.replaceAll('模版', '模板');

    // Normalize common homophones for region units.
    // "1动" -> "1栋", "6成/6城/6曾" -> "6层".
    text = text.replaceAllMapped(RegExp(r'(\d+)动'), (m) => '${m.group(1)}栋');
    text = text.replaceAllMapped(
      RegExp(r'(\d+)(成|城|曾)'),
      (m) => '${m.group(1)}层',
    );
    text = text.replaceAllMapped(
      RegExp(r'([一二三四五六七八九十两]+)动'),
      (m) => '${m.group(1)}栋',
    );
    text = text.replaceAllMapped(
      RegExp(r'([一二三四五六七八九十两]+)(成|城|曾)'),
      (m) => '${m.group(1)}层',
    );

    // Convert common Chinese numerals in building/floor mentions to Arabic digits.
    // Examples: "一栋六层" -> "1栋6层", "二十层" -> "20层"
    text = text.replaceAllMapped(
      RegExp(r'([一二三四五六七八九十两]+)(栋|楼|层)'),
      (m) {
        final n = _parseChineseNumber(m.group(1)!);
        if (n == null) return m.group(0)!;
        final unit = m.group(2)!;
        return '$n$unit';
      },
    );

    return text;
  }

  int? _parseChineseNumber(String s) {
    const map = {
      '零': 0,
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    if (s.isEmpty) return null;
    if (s == '十') return 10;

    final idx = s.indexOf('十');
    if (idx == -1) {
      // Single digit.
      return map[s];
    }

    // Tens or "x十y".
    final left = s.substring(0, idx);
    final right = s.substring(idx + 1);
    final tens = left.isEmpty ? 1 : (map[left] ?? -1);
    if (tens < 0) return null;
    final ones = right.isEmpty ? 0 : (map[right] ?? -1);
    if (ones < 0) return null;
    return tens * 10 + ones;
  }

  Future<Region?> getRegionByCode(String code) async {
    final db = await database;
    final rows = await db.query(
      'rc_ou_region',
      where: 'id_code = ?',
      whereArgs: [code],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Region.fromMap(rows.first);
  }

  Future<Region?> findRegionByText(String text) async {
    final db = await database;
    // 简化：尝试按名称模糊匹配，例如“1栋6层”包含“1栋”和“6层”
    String? foundCode;

    final normalized = _normalizeText(text);

    final buildingMatch = RegExp(r'(\d+)(?:栋|楼)').firstMatch(normalized);
    final floorMatch = RegExp(r'(\d+)(?:层|楼)').firstMatch(normalized);

    final buildingName =
        buildingMatch != null ? '${buildingMatch.group(1)}栋' : null;
    final floorName = floorMatch != null ? '${floorMatch.group(1)}层' : null;

    // 允许不在本地库中的任意“几栋几层”也能继续流程：返回一个虚拟 Region。
    // 这样语音说“2栋8层”也能进入验收/巡检，而不是被本地数据范围卡住。
    Region virtualRegion() {
      final name = [
        if (buildingName != null) buildingName,
        if (floorName != null) floorName
      ].join('');
      return Region(
        id: '',
        idCode: 'virtual:$name',
        name: name,
        parentIdCode: '',
      );
    }

    if (buildingMatch != null) {
      final rows = await db.query(
        'rc_ou_region',
        where: 'name LIKE ?',
        whereArgs: ['%$buildingName%'],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        foundCode = rows.first['id_code'] as String;
      }
    }

    if (floorMatch != null) {
      final rows = await db.query(
        'rc_ou_region',
        where: 'name LIKE ?',
        whereArgs: ['%$floorName%'],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        foundCode = rows.first['id_code'] as String;
      }
    }

    if (foundCode == null) {
      if (buildingName != null || floorName != null) {
        return virtualRegion();
      }
      return null;
    }
    return getRegionByCode(foundCode);
  }

  Future<LibraryItem?> getLibraryByCode(String code) async {
    final db = await database;
    final rows = await db.query(
      'rc_library_library',
      where: 'id_code = ?',
      whereArgs: [code],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return LibraryItem.fromMap(rows.first);
  }

  Future<LibraryItem?> findLibraryByName(String text) async {
    final db = await database;

    final normalized = _normalizeText(text);

    // 常见别名 -> 标准分项
    if (normalized.contains('钢筋') || normalized.contains('绑筋')) {
      return getLibraryByCode('A001');
    }
    if (normalized.contains('模板') || normalized.contains('模版')) {
      return getLibraryByCode('A002');
    }

    final rows = await db.query(
      'rc_library_library',
      where: 'name LIKE ?',
      whereArgs: ['%$normalized%'],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return LibraryItem.fromMap(rows.first);
  }

  Future<List<TargetItem>> getTargetsByLibraryCode(String libraryCode) async {
    final db = await database;
    final rows = await db.query(
      'rc_library_librarytarget',
      where: 'library_code = ?',
      whereArgs: [libraryCode],
      orderBy: 'id_code ASC',
    );
    return rows.map(TargetItem.fromMap).toList();
  }
}
