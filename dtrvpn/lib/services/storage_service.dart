import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/profile.dart';
import 'dtr_log.dart';

class StorageService {
  static const _tag = 'StorageService';
  static StorageService? _instance;
  static Database? _db;

  StorageService._();
  static StorageService get instance => _instance ??= StorageService._();

  Future<Database> get db async {
    _db ??= await _initDb();
    return _db!;
  }

  void warmUp() { db.ignore(); }

  Future<Database> _initDb() async {
    final path = join(await getDatabasesPath(), 'dtrvpn.db');
    DtrLog.i(_tag, 'Opening DB: $path');
    return openDatabase(
      path,
      version: 3, // bumped: added supportUrl, announceMsg, updateIntervalHours
      onCreate: (db, v) async {
        DtrLog.i(_tag, 'onCreate v=$v');
        await db.execute('''
          CREATE TABLE profiles (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            url TEXT NOT NULL,
            lastUpdated TEXT,
            proxyCount INTEGER,
            isActive INTEGER DEFAULT 0,
            rawConfig TEXT,
            username TEXT,
            trafficUsed INTEGER,
            trafficTotal INTEGER,
            expireDate TEXT,
            supportUrl TEXT,
            announceMsg TEXT,
            updateIntervalHours INTEGER
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        DtrLog.i(_tag, 'onUpgrade $oldVersion -> $newVersion');
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE profiles ADD COLUMN username TEXT');
          await db.execute('ALTER TABLE profiles ADD COLUMN trafficUsed INTEGER');
          await db.execute('ALTER TABLE profiles ADD COLUMN trafficTotal INTEGER');
          await db.execute('ALTER TABLE profiles ADD COLUMN expireDate TEXT');
          DtrLog.i(_tag, 'Migration 1->2 done');
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE profiles ADD COLUMN supportUrl TEXT');
          await db.execute('ALTER TABLE profiles ADD COLUMN announceMsg TEXT');
          await db.execute('ALTER TABLE profiles ADD COLUMN updateIntervalHours INTEGER');
          DtrLog.i(_tag, 'Migration 2->3 done (supportUrl, announceMsg, updateIntervalHours)');
        }
      },
    );
  }

  Future<List<Profile>> getProfiles() async {
    final d = await db;
    final rows = await d.query('profiles', orderBy: 'name ASC');
    DtrLog.d(_tag, 'getProfiles: ${rows.length} rows');
    return rows.map(Profile.fromMap).toList();
  }

  Future<Profile?> getActiveProfile() async {
    final d = await db;
    final rows = await d.query('profiles', where: 'isActive = 1', limit: 1);
    if (rows.isEmpty) { DtrLog.d(_tag, 'getActiveProfile: none'); return null; }
    final p = Profile.fromMap(rows.first);
    DtrLog.d(_tag, 'getActiveProfile: "${p.name}"');
    return p;
  }

  Future<Profile?> getProfile(String id) async {
    final d = await db;
    final rows = await d.query('profiles', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Profile.fromMap(rows.first);
  }

  Future<void> insertProfile(Profile p) async {
    DtrLog.i(_tag, 'insertProfile "${p.name}"');
    final d = await db;
    await d.insert('profiles', p.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateProfile(Profile p) async {
    DtrLog.d(_tag, 'updateProfile "${p.name}"');
    final d = await db;
    await d.update('profiles', p.toMap(), where: 'id = ?', whereArgs: [p.id]);
  }

  Future<void> deleteProfile(String id) async {
    DtrLog.i(_tag, 'deleteProfile $id');
    final d = await db;
    await d.delete('profiles', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setActiveProfile(String id) async {
    DtrLog.i(_tag, 'setActiveProfile $id');
    final d = await db;
    await d.transaction((txn) async {
      await txn.update('profiles', {'isActive': 0});
      await txn.update('profiles', {'isActive': 1},
          where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> clearActiveProfile() async {
    final d = await db;
    await d.update('profiles', {'isActive': 0});
  }
}
