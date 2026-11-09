import 'dart:io';
import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'database_helper.dart';
import 'recap_matrix.dart';

class ExcelExporterService {
  static String _two(int n) => n.toString().padLeft(2, '0');

  static bool _isWorkday(DateTime d) =>
      d.weekday >= DateTime.monday && d.weekday <= DateTime.friday;

  static void _styleHeader(Sheet sheet, int columns) {
    final style = CellStyle(
      bold: true,
      fontColorHex: ExcelColor.white,
      backgroundColorHex: ExcelColor.fromHexString('#1B365D'),
    );
    for (int c = 0; c < columns; c++) {
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0))
          .cellStyle = style;
    }
  }

  static void _widths(Sheet sheet, List<double> widths) {
    for (int i = 0; i < widths.length; i++) {
      sheet.setColumnWidth(i, widths[i]);
    }
  }

  /// Ekspor sesuai filter. Sheet "Rekap Per Personel" memakai semua jenis absen
  /// pada rentang tanggal (hanya mengikuti filter personel).
  static Future<void> exportAndShareAttendance({
    required DateTime startDate,
    required DateTime endDate,
    int? userId,
    String? type,
    String? query,
  }) async {
    final db = DatabaseHelper.instance;

    final records = await db.getAttendance(
      start: startDate,
      end: endDate,
      userId: userId,
      type: type,
      query: query,
    );
    final allForSummary =
        await db.getAttendance(start: startDate, end: endDate, userId: userId);
    final leaves = await db.getLeaves(startDate, endDate);
    final audits = await db.getAudit(startDate, endDate);

    final excel = Excel.createExcel();

    // ---------------- Sheet 1: detail ----------------
    const detailName = 'Rekap Presensi';
    final defaultSheet = excel.getDefaultSheet();
    if (defaultSheet != null && defaultSheet != detailName) {
      excel.rename(defaultSheet, detailName);
    }
    final detail = excel[detailName];
    excel.setDefaultSheet(detailName);

    detail.appendRow([
      TextCellValue('No'),
      TextCellValue('NRP / NIP'),
      TextCellValue('Nama Personel'),
      TextCellValue('Jabatan / Satker'),
      TextCellValue('Tanggal'),
      TextCellValue('Jam'),
      TextCellValue('Jenis'),
      TextCellValue('Status'),
      TextCellValue('Keterangan'),
      TextCellValue('Manual'),
    ]);
    _styleHeader(detail, 10);

    for (int i = 0; i < records.length; i++) {
      final r = records[i];
      final d = DateTime.tryParse(r['timestamp'].toString());
      final tgl = d == null
          ? r['day'].toString()
          : '${_two(d.day)}-${_two(d.month)}-${d.year}';
      final jam = d == null
          ? ''
          : '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
      detail.appendRow([
        IntCellValue(i + 1),
        TextCellValue(r['nrp'].toString()),
        TextCellValue(r['nama'].toString()),
        TextCellValue(r['jabatan'].toString()),
        TextCellValue(tgl),
        TextCellValue(jam),
        TextCellValue(r['type'].toString()),
        TextCellValue((r['status'] ?? '').toString()),
        TextCellValue((r['note'] ?? '').toString()),
        TextCellValue(r['manual'] == 1 ? 'Ya' : ''),
      ]);
    }
    _widths(detail, [6, 18, 30, 26, 14, 12, 10, 14, 30, 8]);

    // ---------------- Sheet: rekap harian (matriks tanggal) ----------------
    final spanDays = endDate.difference(startDate).inDays + 1;
    if (spanDays <= 62) {
      final matrix =
          await RecapBuilder.build(startDate, endDate, userId: userId);
      final grid = excel['Rekap Harian'];

      final header = <CellValue>[
        TextCellValue('No'),
        TextCellValue('Nama Personel'),
        TextCellValue('NRP'),
        ...matrix.dates.map((d) => TextCellValue('${d.day}')),
        TextCellValue('Hadir'),
        TextCellValue('Terlambat'),
        TextCellValue('Izin'),
        TextCellValue('Sakit'),
        TextCellValue('Dinas'),
        TextCellValue('Alpa'),
      ];
      grid.appendRow(header);
      _styleHeader(grid, header.length);

      for (int i = 0; i < matrix.rows.length; i++) {
        final r = matrix.rows[i];
        grid.appendRow(<CellValue>[
          IntCellValue(i + 1),
          TextCellValue(r.user.nama),
          TextCellValue(r.user.nrp),
          ...r.days.map((c) => TextCellValue(c.code)),
          IntCellValue(r.hadir),
          IntCellValue(r.telat),
          IntCellValue(r.izin),
          IntCellValue(r.sakit),
          IntCellValue(r.dinas),
          IntCellValue(r.alpa),
        ]);
        for (int j = 0; j < r.days.length; j++) {
          final code = r.days[j].code;
          if (!RecapBuilder.colors.containsKey(code)) continue;
          grid
              .cell(CellIndex.indexByColumnRow(
                  columnIndex: 3 + j, rowIndex: i + 1))
              .cellStyle = CellStyle(
            backgroundColorHex:
                ExcelColor.fromHexString(RecapBuilder.hexFor(code)),
            horizontalAlign: HorizontalAlign.Center,
          );
        }
      }

      grid.appendRow(<CellValue>[]);
      grid.appendRow(<CellValue>[
        TextCellValue(
            'Keterangan: H=Hadir, T=Terlambat, I=Izin, S=Sakit, D=Dinas, A=Alpa (tanpa keterangan), L=Libur, kosong=belum/berjalan'),
      ]);

      grid.setColumnWidth(0, 5);
      grid.setColumnWidth(1, 28);
      grid.setColumnWidth(2, 16);
      for (int j = 0; j < matrix.dates.length; j++) {
        grid.setColumnWidth(3 + j, 4);
      }
      final tail = 3 + matrix.dates.length;
      for (int k = 0; k < 6; k++) {
        grid.setColumnWidth(tail + k, 10);
      }
    }

    // ---------------- Sheet 2: rekap per personel ----------------
    final summary = excel['Rekap Per Personel'];
    summary.appendRow([
      TextCellValue('NRP / NIP'),
      TextCellValue('Nama Personel'),
      TextCellValue('Jabatan / Satker'),
      TextCellValue('Hari Kerja'),
      TextCellValue('Hadir'),
      TextCellValue('Terlambat'),
      TextCellValue('Izin'),
      TextCellValue('Sakit'),
      TextCellValue('Dinas'),
      TextCellValue('Tanpa Keterangan'),
    ]);
    _styleHeader(summary, 10);

    // userId -> {day -> status MASUK}
    final masuk = <int, Map<String, String>>{};
    for (final r in allForSummary) {
      if (r['type'] != 'MASUK') continue;
      final uid = r['user_id'] as int;
      masuk.putIfAbsent(uid, () => {})[r['day'].toString()] =
          (r['status'] ?? 'HADIR').toString();
    }
    // userId -> {day -> kind}
    final leaveMap = <int, Map<String, String>>{};
    for (final l in leaves) {
      final uid = l['user_id'] as int;
      leaveMap.putIfAbsent(uid, () => {})[l['day'].toString()] =
          l['kind'].toString();
    }

    final today = DateTime.now();
    final todayKey = DatabaseHelper.dayKey(today);
    final lastDay = endDate.isAfter(today) ? today : endDate;

    final users = DatabaseHelper.instance.cachedUsers
        .where((u) => userId == null || u.id == userId)
        .toList();

    for (final u in users) {
      int workdays = 0, hadir = 0, telat = 0, izin = 0, sakit = 0, dinas = 0;
      int alpa = 0;

      var d = DateTime(startDate.year, startDate.month, startDate.day);
      final end = DateTime(lastDay.year, lastDay.month, lastDay.day);
      while (!d.isAfter(end)) {
        final key = DatabaseHelper.dayKey(d);
        final m = masuk[u.id]?[key];
        final lv = leaveMap[u.id]?[key];

        if (_isWorkday(d)) {
          if (m != null) {
            workdays++;
            hadir++;
            if (m == 'TERLAMBAT') telat++;
          } else if (lv != null) {
            workdays++;
            if (lv == 'IZIN') izin++;
            if (lv == 'SAKIT') sakit++;
            if (lv == 'DINAS') dinas++;
          } else if (key != todayKey) {
            // Hari ini belum dihitung alpa karena masih berjalan
            workdays++;
            alpa++;
          }
        } else if (m != null) {
          // Absen di hari libur tetap dihitung hadir
          hadir++;
          if (m == 'TERLAMBAT') telat++;
        }
        d = DateTime(d.year, d.month, d.day + 1);
      }

      summary.appendRow([
        TextCellValue(u.nrp),
        TextCellValue(u.nama),
        TextCellValue(u.jabatan),
        IntCellValue(workdays),
        IntCellValue(hadir),
        IntCellValue(telat),
        IntCellValue(izin),
        IntCellValue(sakit),
        IntCellValue(dinas),
        IntCellValue(alpa),
      ]);
    }
    _widths(summary, [18, 30, 26, 12, 8, 10, 8, 8, 8, 18]);

    // ---------------- Sheet: izin / sakit / dinas ----------------
    final leaveSheet = excel['Izin Sakit Dinas'];
    leaveSheet.appendRow([
      TextCellValue('Tanggal'),
      TextCellValue('NRP / NIP'),
      TextCellValue('Nama Personel'),
      TextCellValue('Jenis'),
      TextCellValue('Keterangan'),
    ]);
    _styleHeader(leaveSheet, 5);
    for (final l in leaves) {
      if (userId != null && l['user_id'] != userId) continue;
      final p = l['day'].toString().split('-');
      leaveSheet.appendRow([
        TextCellValue(
            p.length == 3 ? '${p[2]}-${p[1]}-${p[0]}' : l['day'].toString()),
        TextCellValue(l['nrp'].toString()),
        TextCellValue(l['nama'].toString()),
        TextCellValue(l['kind'].toString()),
        TextCellValue((l['note'] ?? '').toString()),
      ]);
    }
    _widths(leaveSheet, [14, 18, 30, 10, 40]);

    // ---------------- Sheet 3: log audit ----------------
    final audit = excel['Log Audit'];
    audit.appendRow([
      TextCellValue('Waktu'),
      TextCellValue('Aksi'),
      TextCellValue('Detail'),
    ]);
    _styleHeader(audit, 3);
    for (final a in audits) {
      audit.appendRow([
        TextCellValue(a['timestamp'].toString().replaceFirst('T', ' ')),
        TextCellValue(a['action'].toString()),
        TextCellValue((a['detail'] ?? '').toString()),
      ]);
    }
    _widths(audit, [22, 22, 80]);

    // ---------------- Simpan & bagikan ----------------
    final directory = await getTemporaryDirectory();
    final fileName =
        "Rekap_Absensi_${startDate.year}${_two(startDate.month)}${_two(startDate.day)}"
        "_${endDate.year}${_two(endDate.month)}${_two(endDate.day)}.xlsx";
    final filePath = "${directory.path}/$fileName";

    final fileBytes = excel.save();
    if (fileBytes == null) {
      throw Exception("Gagal membuat file Excel");
    }

    final file = File(filePath)
      ..createSync(recursive: true)
      ..writeAsBytesSync(fileBytes);

    await Share.shareXFiles(
      [XFile(file.path)],
      text: 'Rekapitulasi Presensi Personel',
    );
  }
}