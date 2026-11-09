import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class UserModel {
  final int? id;
  final String nrp;
  final String nama;
  final String jabatan;

  /// Beberapa sampel wajah per personel (setiap sampel = 1 vector ter-normalisasi)
  final List<List<double>> faceVectors;

  UserModel({
    this.id,
    required this.nrp,
    required this.nama,
    required this.jabatan,
    required this.faceVectors,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'nrp': nrp,
      'nama': nama,
      'jabatan': jabatan,
      'face_vector': jsonEncode(faceVectors),
    };
  }

  factory UserModel.fromMap(Map<String, dynamic> map) {
    final decoded = jsonDecode(map['face_vector'] as String) as List;

    List<double> toDoubles(List l) =>
        l.map((v) => (v as num).toDouble()).toList();

    final List<List<double>> vectors;
    if (decoded.isNotEmpty && decoded.first is List) {
      vectors = decoded.map((e) => toDoubles(e as List)).toList();
    } else {
      vectors = [toDoubles(decoded)];
    }

    return UserModel(
      id: map['id'] as int?,
      nrp: map['nrp'] as String,
      nama: map['nama'] as String,
      jabatan: (map['jabatan'] as String?) ?? '',
      faceVectors: vectors,
    );
  }
}

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static const String _dbName = 'polda_attendance.db';
  static const int _dbVersion = 2;

  Database? _database;

  /// Cache RAM agar pencocokan wajah real-time cepat
  List<UserModel> cachedUsers = [];

  DatabaseHelper._init();

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// Kunci hari: yyyy-MM-dd (waktu lokal)
  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

  Future<Database> get database async => _database ??= await _initDB();

  Future<String> get dbPath async => join(await getDatabasesPath(), _dbName);

  Future<Database> _initDB() async {
    return openDatabase(
      await dbPath,
      version: _dbVersion,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        nrp TEXT UNIQUE NOT NULL,
        nama TEXT NOT NULL,
        jabatan TEXT,
        face_vector TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE attendances (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        timestamp TEXT NOT NULL,
        day TEXT NOT NULL,
        type TEXT NOT NULL,
        status TEXT,
        note TEXT,
        photo BLOB,
        manual INTEGER NOT NULL DEFAULT 0,
        nrp TEXT,
        nama TEXT,
        jabatan TEXT
      )
    ''');
    await _createExtra(db);
  }

  Future<void> _createExtra(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS leaves (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        day TEXT NOT NULL,
        kind TEXT NOT NULL,
        note TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS audit_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT NOT NULL,
        action TEXT NOT NULL,
        detail TEXT
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_att_user_day ON attendances(user_id, day, type)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_att_day ON attendances(day)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_leave_day ON leaves(user_id, day)');
  }

  Future<void> _upgradeDB(Database db, int oldV, int newV) async {
    if (oldV < 2) {
      for (final col in [
        'day TEXT',
        'status TEXT',
        'note TEXT',
        'photo BLOB',
        'manual INTEGER NOT NULL DEFAULT 0',
        'nrp TEXT',
        'nama TEXT',
        'jabatan TEXT',
      ]) {
        await db.execute('ALTER TABLE attendances ADD COLUMN $col');
      }
      await db.execute('UPDATE attendances SET day = substr(timestamp, 1, 10)');
      await db.execute('''
        UPDATE attendances SET
          nrp = (SELECT nrp FROM users WHERE users.id = attendances.user_id),
          nama = (SELECT nama FROM users WHERE users.id = attendances.user_id),
          jabatan = (SELECT jabatan FROM users WHERE users.id = attendances.user_id),
          status = CASE type WHEN 'MASUK' THEN 'HADIR' ELSE 'PULANG' END
      ''');
      await _createExtra(db);
    }
  }

  // ===================== PERSONEL =====================

  Future<void> loadUsersToCache() async {
    final db = await database;
    final result = await db.query('users', orderBy: 'nama COLLATE NOCASE');
    cachedUsers = result.map((json) => UserModel.fromMap(json)).toList();
  }

  /// Daftarkan personel baru. NRP harus unik (tidak menimpa data lama).
  Future<int> registerUser(UserModel user) async {
    final db = await database;
    final existing = await db.query('users',
        columns: ['id'], where: 'nrp = ?', whereArgs: [user.nrp]);
    if (existing.isNotEmpty) {
      throw StateError('NRP ${user.nrp} sudah terdaftar');
    }
    final map = user.toMap()..remove('id');
    final id = await db.insert('users', map);
    await loadUsersToCache();
    await audit('TAMBAH_PERSONEL', '${user.nrp} - ${user.nama}');
    return id;
  }

  Future<void> updateUserInfo(int id, String nama, String jabatan) async {
    final db = await database;
    await db.update('users', {'nama': nama, 'jabatan': jabatan},
        where: 'id = ?', whereArgs: [id]);
    await loadUsersToCache();
    await audit('EDIT_PERSONEL', 'id=$id nama=$nama jabatan=$jabatan');
  }

  /// Hapus personel. Riwayat absensi tetap utuh karena menyimpan snapshot nama/NRP.
  Future<void> deleteUser(int id) async {
    final db = await database;
    final rows = await db.query('users', where: 'id = ?', whereArgs: [id]);
    await db.delete('users', where: 'id = ?', whereArgs: [id]);
    await db.delete('leaves', where: 'user_id = ?', whereArgs: [id]);
    await loadUsersToCache();
    if (rows.isNotEmpty) {
      await audit('HAPUS_PERSONEL', '${rows.first['nrp']} - ${rows.first['nama']}');
    }
  }

  // ===================== ABSENSI =====================

  Future<int> recordAttendance({
    required UserModel user,
    required String type,
    required String status,
    Uint8List? photo,
    bool manual = false,
    String? note,
    DateTime? at,
  }) async {
    final db = await database;
    final t = at ?? DateTime.now();
    final id = await db.insert('attendances', {
      'user_id': user.id,
      'timestamp': t.toIso8601String(),
      'day': dayKey(t),
      'type': type,
      'status': status,
      'note': note,
      'photo': photo,
      'manual': manual ? 1 : 0,
      'nrp': user.nrp,
      'nama': user.nama,
      'jabatan': user.jabatan,
    });
    if (manual) {
      await audit('ABSEN_MANUAL',
          '${user.nrp} - ${user.nama} | $type | ${t.toIso8601String()} | ${note ?? ''}');
    }
    return id;
  }

  Future<bool> hasAttendedOn(int userId, String type, DateTime date) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM attendances WHERE user_id = ? AND type = ? AND day = ?',
      [userId, type, dayKey(date)],
    );
    return (Sqflite.firstIntValue(rows) ?? 0) > 0;
  }

  Future<bool> hasAttendedToday(int userId, String type) =>
      hasAttendedOn(userId, type, DateTime.now());

  /// Waktu absen pertama (jenis tertentu) pada hari tertentu, atau null bila belum ada
  Future<DateTime?> firstAttendanceTime(
      int userId, String type, DateTime date) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT timestamp FROM attendances WHERE user_id = ? AND type = ? AND day = ? ORDER BY timestamp LIMIT 1',
      [userId, type, dayKey(date)],
    );
    if (rows.isEmpty) return null;
    return DateTime.tryParse(rows.first['timestamp'].toString());
  }

  /// ID personel yang sudah absen jenis tertentu pada hari tertentu
  Future<Set<int>> attendedUserIds(DateTime date, String type) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT DISTINCT user_id FROM attendances WHERE day = ? AND type = ?',
      [dayKey(date), type],
    );
    return rows.map((r) => r['user_id'] as int).toSet();
  }

  Future<List<Map<String, Object?>>> getAttendance({
    required DateTime start,
    required DateTime end,
    int? userId,
    String? type,
    String? query,
  }) async {
    final db = await database;
    final where = <String>['day BETWEEN ? AND ?'];
    final args = <Object?>[dayKey(start), dayKey(end)];
    if (userId != null) {
      where.add('user_id = ?');
      args.add(userId);
    }
    if (type != null) {
      where.add('type = ?');
      args.add(type);
    }
    if (query != null && query.trim().isNotEmpty) {
      where.add('(nama LIKE ? OR nrp LIKE ?)');
      args.add('%${query.trim()}%');
      args.add('%${query.trim()}%');
    }
    return db.rawQuery('''
      SELECT id, user_id, COALESCE(nrp, '-') AS nrp,
             COALESCE(nama, '(Personel dihapus)') AS nama,
             COALESCE(jabatan, '-') AS jabatan,
             timestamp, day, type, status, note, manual,
             (photo IS NOT NULL) AS has_photo
      FROM attendances
      WHERE ${where.join(' AND ')}
      ORDER BY timestamp DESC
    ''', args);
  }

  Future<Uint8List?> getPhoto(int attendanceId) async {
    final db = await database;
    final rows = await db.query('attendances',
        columns: ['photo'], where: 'id = ?', whereArgs: [attendanceId]);
    if (rows.isEmpty) return null;
    final p = rows.first['photo'];
    return p is Uint8List ? p : null;
  }

  Future<void> deleteAttendance(int id, String reason) async {
    final db = await database;
    final rows = await db.query('attendances',
        columns: ['nrp', 'nama', 'type', 'timestamp'],
        where: 'id = ?',
        whereArgs: [id]);
    await db.delete('attendances', where: 'id = ?', whereArgs: [id]);
    if (rows.isNotEmpty) {
      final r = rows.first;
      await audit('HAPUS_ABSENSI',
          '${r['nrp']} - ${r['nama']} | ${r['type']} | ${r['timestamp']} | alasan: $reason');
    }
  }

  // ===================== IZIN / SAKIT / DINAS =====================

  Future<void> addLeave({
    required int userId,
    required DateTime start,
    required DateTime end,
    required String kind,
    String? note,
  }) async {
    final db = await database;
    final batch = db.batch();
    var d = DateTime(start.year, start.month, start.day);
    final last = DateTime(end.year, end.month, end.day);
    while (!d.isAfter(last)) {
      final key = dayKey(d);
      batch.delete('leaves',
          where: 'user_id = ? AND day = ?', whereArgs: [userId, key]);
      batch.insert('leaves',
          {'user_id': userId, 'day': key, 'kind': kind, 'note': note});
      d = DateTime(d.year, d.month, d.day + 1);
    }
    await batch.commit(noResult: true);
    await audit('TAMBAH_$kind',
        'user_id=$userId ${dayKey(start)} s/d ${dayKey(end)} ${note ?? ''}');
  }

  Future<List<Map<String, Object?>>> getLeaves(
      DateTime start, DateTime end) async {
    final db = await database;
    return db.rawQuery('''
      SELECT l.id, l.user_id, l.day, l.kind, l.note,
             COALESCE(u.nama, '(Personel dihapus)') AS nama,
             COALESCE(u.nrp, '-') AS nrp
      FROM leaves l LEFT JOIN users u ON l.user_id = u.id
      WHERE l.day BETWEEN ? AND ?
      ORDER BY l.day DESC, nama
    ''', [dayKey(start), dayKey(end)]);
  }

  Future<void> deleteLeave(int id) async {
    final db = await database;
    await db.delete('leaves', where: 'id = ?', whereArgs: [id]);
    await audit('HAPUS_IZIN', 'id=$id');
  }

  // ===================== AUDIT LOG =====================

  Future<void> audit(String action, String detail) async {
    final db = await database;
    await db.insert('audit_log', {
      'timestamp': DateTime.now().toIso8601String(),
      'action': action,
      'detail': detail,
    });
  }

  Future<List<Map<String, Object?>>> getAudit(
      DateTime start, DateTime end) async {
    final db = await database;
    return db.rawQuery('''
      SELECT timestamp, action, detail FROM audit_log
      WHERE substr(timestamp, 1, 10) BETWEEN ? AND ?
      ORDER BY timestamp DESC
    ''', [dayKey(start), dayKey(end)]);
  }

  // ===================== BACKUP / RESTORE =====================

  /// Salin database ke file sementara untuk dibagikan sebagai backup.
  Future<File> createBackupFile() async {
    final db = await database;
    try {
      await db.rawQuery('PRAGMA wal_checkpoint(FULL)');
    } catch (_) {}
    final now = DateTime.now();
    final name =
        'backup_presensi_${now.year}${_two(now.month)}${_two(now.day)}_${_two(now.hour)}${_two(now.minute)}.db';
    final dir = await getTemporaryDirectory();
    final dest = File(join(dir.path, name));
    await File(await dbPath).copy(dest.path);
    await audit('BACKUP_DB', name);
    return dest;
  }

  /// Ganti database dengan file backup. Melempar exception bila file tidak valid.
  Future<void> restoreFrom(File src) async {
    final probe = await openDatabase(src.path, readOnly: true);
    try {
      final tables = (await probe
              .rawQuery("SELECT name FROM sqlite_master WHERE type='table'"))
          .map((r) => r['name'] as String)
          .toSet();
      if (!tables.contains('users') || !tables.contains('attendances')) {
        throw const FormatException('File bukan backup presensi yang valid');
      }
    } finally {
      await probe.close();
    }

    await _database?.close();
    _database = null;

    final path = await dbPath;
    await src.copy(path);
    for (final s in ['-wal', '-shm', '-journal']) {
      final f = File('$path$s');
      if (await f.exists()) await f.delete();
    }

    await loadUsersToCache(); // membuka ulang DB (dan migrasi bila perlu)
    await audit('RESTORE_DB', basename(src.path));
  }
}
