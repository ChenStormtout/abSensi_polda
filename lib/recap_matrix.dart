import 'database_helper.dart';

/// Satu kotak pada rekap kalender (1 personel x 1 tanggal).
/// Kode: H=Hadir, T=Terlambat, I=Izin, S=Sakit, D=Dinas, A=Alpa, L=Libur, ''=belum/berjalan
class DayCell {
  final String code;
  final DateTime? masuk;
  final DateTime? pulang;
  const DayCell(this.code, {this.masuk, this.pulang});
}

class UserRecap {
  final UserModel user;
  final List<DayCell> days;
  int hadir = 0; // termasuk yang terlambat
  int telat = 0;
  int izin = 0;
  int sakit = 0;
  int dinas = 0;
  int alpa = 0;
  UserRecap(this.user, this.days);
}

class RecapMatrix {
  final List<DateTime> dates;
  final List<UserRecap> rows;
  RecapMatrix(this.dates, this.rows);
}

class RecapBuilder {
  static const Map<String, String> legend = {
    'H': 'Hadir',
    'T': 'Terlambat',
    'I': 'Izin',
    'S': 'Sakit',
    'D': 'Dinas',
    'A': 'Alpa (tanpa keterangan)',
    'L': 'Libur',
  };

  static const Map<String, int> colors = {
    'H': 0xFFC8E6C9,
    'T': 0xFFFFE0B2,
    'I': 0xFFBBDEFB,
    'S': 0xFFE1BEE7,
    'D': 0xFFB2DFDB,
    'A': 0xFFFFCDD2,
    'L': 0xFFECEFF1,
  };

  /// Hex "#RRGGBB" untuk Excel
  static String hexFor(String code) {
    final c = colors[code] ?? 0xFFFFFFFF;
    return '#${(c & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  static Future<RecapMatrix> build(DateTime start, DateTime end,
      {int? userId}) async {
    final db = DatabaseHelper.instance;
    final s = DateTime(start.year, start.month, start.day);
    final e = DateTime(end.year, end.month, end.day);

    final records = await db.getAttendance(start: s, end: e, userId: userId);
    final leaves = await db.getLeaves(s, e);

    // Data diurutkan terbaru -> terlama.
    // MASUK: ambil yang paling awal (timpa terus). PULANG: ambil yang paling akhir (isi sekali).
    final masuk = <int, Map<String, Map<String, Object?>>>{};
    final pulang = <int, Map<String, Map<String, Object?>>>{};
    for (final r in records) {
      final uid = r['user_id'] as int;
      final day = r['day'].toString();
      if (r['type'] == 'MASUK') {
        masuk.putIfAbsent(uid, () => {})[day] = r;
      } else {
        pulang.putIfAbsent(uid, () => {}).putIfAbsent(day, () => r);
      }
    }

    final leaveMap = <int, Map<String, String>>{};
    for (final l in leaves) {
      final uid = l['user_id'] as int;
      leaveMap.putIfAbsent(uid, () => {})[l['day'].toString()] =
          l['kind'].toString();
    }

    final dates = <DateTime>[];
    for (var d = s; !d.isAfter(e); d = DateTime(d.year, d.month, d.day + 1)) {
      dates.add(d);
    }

    final todayKey = DatabaseHelper.dayKey(DateTime.now());
    final users = db.cachedUsers
        .where((u) => userId == null || u.id == userId)
        .toList();

    final rows = <UserRecap>[];
    for (final u in users) {
      final cells = <DayCell>[];
      final rec = UserRecap(u, cells);

      for (final d in dates) {
        final key = DatabaseHelper.dayKey(d);
        final weekend = d.weekday >= DateTime.saturday;
        final m = masuk[u.id]?[key];
        final p = pulang[u.id]?[key];
        final lv = leaveMap[u.id]?[key];

        if (m != null) {
          final late = m['status'] == 'TERLAMBAT';
          cells.add(DayCell(
            late ? 'T' : 'H',
            masuk: DateTime.tryParse(m['timestamp'].toString()),
            pulang:
                p == null ? null : DateTime.tryParse(p['timestamp'].toString()),
          ));
          rec.hadir++;
          if (late) rec.telat++;
        } else if (lv != null) {
          final code = lv == 'IZIN' ? 'I' : (lv == 'SAKIT' ? 'S' : 'D');
          cells.add(DayCell(code));
          if (!weekend) {
            if (code == 'I') rec.izin++;
            if (code == 'S') rec.sakit++;
            if (code == 'D') rec.dinas++;
          }
        } else if (weekend) {
          cells.add(const DayCell('L'));
        } else if (key.compareTo(todayKey) >= 0) {
          cells.add(const DayCell('')); // hari ini / belum tiba
        } else {
          cells.add(const DayCell('A'));
          rec.alpa++;
        }
      }
      rows.add(rec);
    }

    return RecapMatrix(dates, rows);
  }
}
