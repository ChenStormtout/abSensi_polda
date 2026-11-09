import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'app_settings.dart';
import 'database_helper.dart';
import 'enrollment_screen.dart';
import 'excel_exporter_service.dart';
import 'face_matcher.dart';
import 'face_recognition_service.dart';
import 'recap_matrix.dart';

const Color _kNavy = Color(0xFF1B365D);

String _two(int n) => n.toString().padLeft(2, '0');
String _fmtDay(DateTime d) => '${_two(d.day)}-${_two(d.month)}-${d.year}';
String _fmtDayKey(String key) {
  final p = key.split('-');
  return p.length == 3 ? '${p[2]}-${p[1]}-${p[0]}' : key;
}

String _fmtClock(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
}

void _snack(BuildContext context, String msg, {Color? color}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg), backgroundColor: color),
  );
}

// ============================================================================
// DIALOG-DIALOG KECIL (semua StatefulWidget agar controller aman di-dispose)
// ============================================================================

/// Dialog input teks wajib (mis. alasan penghapusan)
class _ReasonDialog extends StatefulWidget {
  final String title;
  final String label;
  const _ReasonDialog({required this.title, required this.label});

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _c = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _c,
        autofocus: true,
        decoration: InputDecoration(
          labelText: widget.label,
          border: const OutlineInputBorder(),
          errorText: _error,
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text("Batal")),
        FilledButton(
          onPressed: () {
            if (_c.text.trim().isEmpty) {
              setState(() => _error = "Wajib diisi");
            } else {
              Navigator.pop(context, _c.text.trim());
            }
          },
          child: const Text("OK"),
        ),
      ],
    );
  }
}

class _EditPersonelDialog extends StatefulWidget {
  final UserModel user;
  const _EditPersonelDialog({required this.user});

  @override
  State<_EditPersonelDialog> createState() => _EditPersonelDialogState();
}

class _EditPersonelDialogState extends State<_EditPersonelDialog> {
  late final TextEditingController _nama =
      TextEditingController(text: widget.user.nama);
  late final TextEditingController _jabatan =
      TextEditingController(text: widget.user.jabatan);
  String? _error;

  @override
  void dispose() {
    _nama.dispose();
    _jabatan.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Edit Personel"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text("NRP ${widget.user.nrp} (tidak dapat diubah)",
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 12),
          TextField(
            controller: _nama,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
                labelText: "Nama Lengkap & Pangkat",
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _jabatan,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
                labelText: "Jabatan / Satker",
                border: const OutlineInputBorder(),
                errorText: _error),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text("Batal")),
        FilledButton(
          onPressed: () {
            if (_nama.text.trim().isEmpty || _jabatan.text.trim().isEmpty) {
              setState(() => _error = "Nama dan Satker wajib diisi");
              return;
            }
            Navigator.pop(context, [_nama.text.trim(), _jabatan.text.trim()]);
          },
          child: const Text("Simpan"),
        ),
      ],
    );
  }
}

class _ChangePinDialog extends StatefulWidget {
  const _ChangePinDialog();

  @override
  State<_ChangePinDialog> createState() => _ChangePinDialogState();
}

class _ChangePinDialogState extends State<_ChangePinDialog> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final s = AppSettings.instance;
    if (!s.verifyPin(_old.text)) {
      setState(() => _error = "PIN lama salah");
      return;
    }
    if (_new.text.length != 6 || int.tryParse(_new.text) == null) {
      setState(() => _error = "PIN baru harus 6 digit angka");
      return;
    }
    if (_new.text == AppSettings.defaultPin) {
      setState(() => _error = "Jangan memakai PIN bawaan");
      return;
    }
    if (_new.text != _confirm.text) {
      setState(() => _error = "Konfirmasi PIN tidak sama");
      return;
    }
    await s.setPin(_new.text);
    await DatabaseHelper.instance.audit('GANTI_PIN', 'PIN admin diganti');
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    InputDecoration deco(String l) =>
        InputDecoration(labelText: l, border: const OutlineInputBorder(), counterText: '');
    return AlertDialog(
      title: const Text("Ganti PIN Admin"),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: _old,
                obscureText: true,
                maxLength: 6,
                keyboardType: TextInputType.number,
                decoration: deco("PIN lama")),
            const SizedBox(height: 12),
            TextField(
                controller: _new,
                obscureText: true,
                maxLength: 6,
                keyboardType: TextInputType.number,
                decoration: deco("PIN baru (6 digit)")),
            const SizedBox(height: 12),
            TextField(
                controller: _confirm,
                obscureText: true,
                maxLength: 6,
                keyboardType: TextInputType.number,
                decoration: deco("Ulangi PIN baru")),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text("Batal")),
        FilledButton(onPressed: _save, child: const Text("Simpan")),
      ],
    );
  }
}

class _ManualInput {
  final UserModel user;
  final String type;
  final DateTime at;
  final String note;
  _ManualInput(this.user, this.type, this.at, this.note);
}

class _ManualAttendanceDialog extends StatefulWidget {
  const _ManualAttendanceDialog();

  @override
  State<_ManualAttendanceDialog> createState() =>
      _ManualAttendanceDialogState();
}

class _ManualAttendanceDialogState extends State<_ManualAttendanceDialog> {
  UserModel? _user;
  String _type = 'MASUK';
  DateTime _date = DateTime.now();
  TimeOfDay _time = TimeOfDay.now();
  final _note = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final users = DatabaseHelper.instance.cachedUsers;
    return AlertDialog(
      title: const Text("Absensi Manual"),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<UserModel>(
              isExpanded: true,
              initialValue: _user,
              decoration: const InputDecoration(
                  labelText: "Personel", border: OutlineInputBorder()),
              items: [
                for (final u in users)
                  DropdownMenuItem(
                      value: u,
                      child: Text("${u.nama} (${u.nrp})",
                          overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _user = v),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'MASUK', label: Text("MASUK")),
                ButtonSegment(value: 'PULANG', label: Text("PULANG")),
              ],
              selected: {_type},
              onSelectionChanged: (v) => setState(() => _type = v.first),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.calendar_today, size: 16),
                    label: Text(_fmtDay(_date)),
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: _date,
                        firstDate: DateTime(2024),
                        lastDate: DateTime.now(),
                      );
                      if (d != null) setState(() => _date = d);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.access_time, size: 16),
                    label: Text("${_two(_time.hour)}:${_two(_time.minute)}"),
                    onPressed: () async {
                      final t = await showTimePicker(
                          context: context, initialTime: _time);
                      if (t != null) setState(() => _time = t);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              decoration: InputDecoration(
                labelText: "Alasan koreksi (wajib)",
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text("Batal")),
        FilledButton(
          onPressed: () {
            if (_user == null) {
              setState(() => _error = "Pilih personel");
              return;
            }
            if (_note.text.trim().isEmpty) {
              setState(() => _error = "Alasan wajib diisi");
              return;
            }
            final at = DateTime(_date.year, _date.month, _date.day,
                _time.hour, _time.minute);
            if (at.isAfter(DateTime.now())) {
              setState(() => _error = "Waktu tidak boleh di masa depan");
              return;
            }
            Navigator.pop(
                context, _ManualInput(_user!, _type, at, _note.text.trim()));
          },
          child: const Text("Simpan"),
        ),
      ],
    );
  }
}

// ============================================================================
// DASHBOARD ADMIN
// ============================================================================
class AdminDashboardScreen extends StatefulWidget {
  final CameraController cameraController;
  final CameraDescription frontCamera;

  const AdminDashboardScreen({
    super.key,
    required this.cameraController,
    required this.frontCamera,
  });

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  Future<void> _go(Widget page) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    if (mounted) setState(() {});
  }

  Future<void> _confirmDeletePersonel(UserModel user) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Hapus Personel?"),
        content: Text(
          "${user.nama} (NRP ${user.nrp}) akan dihapus dari daftar. "
          "Riwayat absensi tetap tersimpan di laporan.",
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Batal")),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Hapus"),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await DatabaseHelper.instance.deleteUser(user.id!);
    } catch (e) {
      if (!mounted) return;
      _snack(context, "Gagal menghapus personel: $e");
      return;
    }
    if (mounted) setState(() {});
  }

  Future<void> _editPersonel(UserModel user) async {
    final r = await showDialog<List<String>>(
      context: context,
      builder: (_) => _EditPersonelDialog(user: user),
    );
    if (r == null) return;
    try {
      await DatabaseHelper.instance.updateUserInfo(user.id!, r[0], r[1]);
    } catch (e) {
      if (!mounted) return;
      _snack(context, "Gagal menyimpan: $e");
      return;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final users = DatabaseHelper.instance.cachedUsers;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Panel Admin Presensi"),
        backgroundColor: _kNavy,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          if (AppSettings.instance.isDefaultPin)
            Container(
              width: double.infinity,
              color: Colors.orange.shade100,
              padding: const EdgeInsets.all(10),
              child: const Text(
                "PIN admin masih bawaan (123456). Segera ganti di menu Pengaturan.",
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => _go(EnrollmentScreen(
                    cameraController: widget.cameraController,
                    frontCamera: widget.frontCamera,
                  )),
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text("Daftar Personel"),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => _go(const MonthlyRecapScreen()),
                  icon: const Icon(Icons.calendar_month),
                  label: const Text("Rekap Kalender"),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => _go(const AttendanceReportScreen()),
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text("Rekap Absensi"),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => _go(const LeaveScreen()),
                  icon: const Icon(Icons.event_busy_outlined),
                  label: const Text("Izin / Sakit / Dinas"),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => _go(CalibrationScreen(
                    cameraController: widget.cameraController,
                    frontCamera: widget.frontCamera,
                  )),
                  icon: const Icon(Icons.tune),
                  label: const Text("Uji Pengenalan"),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => _go(const SettingsScreen()),
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text("Pengaturan"),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                "Daftar Personel Terdaftar (${users.length})",
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
            ),
          ),
          Expanded(
            child: users.isEmpty
                ? const Center(child: Text("Belum ada personel terdaftar."))
                : ListView.separated(
                    itemCount: users.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (ctx, i) {
                      final u = users[i];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: _kNavy,
                          foregroundColor: Colors.white,
                          child: Text(
                              u.nama.isNotEmpty ? u.nama[0].toUpperCase() : "?"),
                        ),
                        title: Text(u.nama,
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                            "NRP: ${u.nrp} • ${u.jabatan} • ${u.faceVectors.length} sampel"),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _editPersonel(u),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: Colors.red),
                              onPressed: () => _confirmDeletePersonel(u),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// REKAP ABSENSI SEMUA ANGGOTA + EXPORT EXCEL
// ============================================================================
class AttendanceReportScreen extends StatefulWidget {
  const AttendanceReportScreen({super.key});

  @override
  State<AttendanceReportScreen> createState() => _AttendanceReportScreenState();
}

class _AttendanceReportScreenState extends State<AttendanceReportScreen> {
  late DateTimeRange _range;
  int? _userId;
  String? _type;
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  List<Map<String, Object?>> _records = [];
  bool _loading = true;
  bool _exporting = false;

  int _presentToday = 0;
  int _leaveToday = 0;
  List<UserModel> _absentToday = [];

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    _range = DateTimeRange(start: today, end: today);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  DateTime get _endOfRange => DateTime(
      _range.end.year, _range.end.month, _range.end.day, 23, 59, 59, 999);

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final db = DatabaseHelper.instance;
      final onlyLeave = _type == 'LEAVE';
      final attendance = onlyLeave
          ? <Map<String, Object?>>[]
          : await db.getAttendance(
              start: _range.start,
              end: _endOfRange,
              userId: _userId,
              type: _type,
              query: _searchCtrl.text,
            );
      final rows = <Map<String, Object?>>[...attendance];

      // Izin / Sakit / Dinas ikut tampil di daftar (bila filter Semua atau Izin/Sakit/Dinas)
      if (_type == null || onlyLeave) {
        final q = _searchCtrl.text.trim().toLowerCase();
        final leaveRows = await db.getLeaves(_range.start, _endOfRange);
        for (final l in leaveRows) {
          if (_userId != null && l['user_id'] != _userId) continue;
          if (q.isNotEmpty &&
              !(l['nama'].toString().toLowerCase().contains(q) ||
                  l['nrp'].toString().toLowerCase().contains(q))) {
            continue;
          }
          rows.add({
            'id': l['id'],
            'is_leave': true,
            'user_id': l['user_id'],
            'nrp': l['nrp'],
            'nama': l['nama'],
            'jabatan': '-',
            'timestamp': '${l['day']}T00:00:00',
            'day': l['day'],
            'type': l['kind'],
            'status': l['kind'],
            'note': l['note'],
            'manual': 0,
            'has_photo': 0,
          });
        }
        rows.sort((a, b) {
          final c = b['day'].toString().compareTo(a['day'].toString());
          if (c != 0) return c;
          return b['timestamp'].toString().compareTo(a['timestamp'].toString());
        });
      }

      // Ringkasan hari ini
      final today = DateTime.now();
      final hadir = await db.attendedUserIds(today, 'MASUK');
      final leaves = await db.getLeaves(today, today);
      final leaveIds = leaves.map((l) => l['user_id'] as int).toSet();
      final users = db.cachedUsers;
      final absent = users
          .where((u) => !hadir.contains(u.id) && !leaveIds.contains(u.id))
          .toList();

      if (!mounted) return;
      setState(() {
        _records = rows;
        _presentToday = users.where((u) => hadir.contains(u.id)).length;
        _leaveToday = users.where((u) => leaveIds.contains(u.id)).length;
        _absentToday = absent;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack(context, "Gagal memuat data: $e");
    }
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: now,
      initialDateRange: _range,
      helpText: "Pilih Rentang Tanggal",
    );
    if (picked == null) return;
    setState(() => _range = picked);
    _load();
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      await ExcelExporterService.exportAndShareAttendance(
        startDate: _range.start,
        endDate: _endOfRange,
        userId: _userId,
        type: _type == 'LEAVE' ? null : _type,
        query: _searchCtrl.text,
      );
    } catch (e) {
      if (mounted) _snack(context, "Gagal mengekspor Excel: $e");
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _addManual() async {
    final input = await showDialog<_ManualInput>(
      context: context,
      builder: (_) => const _ManualAttendanceDialog(),
    );
    if (input == null) return;
    try {
      final db = DatabaseHelper.instance;
      if (await db.hasAttendedOn(input.user.id!, input.type, input.at)) {
        if (mounted) {
          _snack(context,
              "${input.user.nama} sudah punya absen ${input.type} pada tanggal itu.",
              color: Colors.red);
        }
        return;
      }
      // Aturan: PULANG hanya setelah MASUK pada hari yang sama
      final masukAt =
          await db.firstAttendanceTime(input.user.id!, 'MASUK', input.at);
      final pulangAt =
          await db.firstAttendanceTime(input.user.id!, 'PULANG', input.at);
      if (input.type == 'PULANG') {
        if (masukAt == null) {
          if (mounted) {
            _snack(context,
                "Belum ada absen MASUK pada tanggal itu. Tambahkan MASUK terlebih dahulu.",
                color: Colors.red);
          }
          return;
        }
        if (!input.at.isAfter(masukAt)) {
          if (mounted) {
            _snack(context,
                "Jam PULANG harus setelah jam MASUK (${_two(masukAt.hour)}:${_two(masukAt.minute)}).",
                color: Colors.red);
          }
          return;
        }
      } else if (pulangAt != null && !input.at.isBefore(pulangAt)) {
        if (mounted) {
          _snack(context,
              "Jam MASUK harus sebelum jam PULANG (${_two(pulangAt.hour)}:${_two(pulangAt.minute)}).",
              color: Colors.red);
        }
        return;
      }

      String status = 'PULANG';
      if (input.type == 'MASUK') {
        final lt = AppSettings.instance.lateTime;
        final limit = DateTime(
            input.at.year, input.at.month, input.at.day, lt.hour, lt.minute);
        status = input.at.isAfter(limit) ? 'TERLAMBAT' : 'HADIR';
      }
      await db.recordAttendance(
        user: input.user,
        type: input.type,
        status: status,
        manual: true,
        note: input.note,
        at: input.at,
      );
      if (mounted) _snack(context, "Absensi manual tersimpan");
      _load();
    } catch (e) {
      if (mounted) _snack(context, "Gagal menyimpan: $e");
    }
  }

  Future<void> _deleteRecord(Map<String, Object?> r) async {
    // MASUK tidak boleh dihapus bila PULANG di hari yang sama masih ada
    if (r['type'] == 'MASUK') {
      final day = DateTime.tryParse(r['day'].toString());
      if (day != null &&
          await DatabaseHelper.instance
              .hasAttendedOn(r['user_id'] as int, 'PULANG', day)) {
        if (mounted) {
          _snack(context, "Hapus absensi PULANG pada tanggal itu terlebih dahulu.",
              color: Colors.red);
        }
        return;
      }
    }
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _ReasonDialog(
        title: "Hapus Absensi",
        label: "Alasan penghapusan (wajib)",
      ),
    );
    if (reason == null) return;
    try {
      await DatabaseHelper.instance.deleteAttendance(r['id'] as int, reason);
      if (mounted) Navigator.of(context).maybePop(); // tutup bottom sheet
      _load();
    } catch (e) {
      if (mounted) _snack(context, "Gagal menghapus: $e");
    }
  }

  void _showLeaveDetail(Map<String, Object?> r) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(r['nama'].toString(),
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              Text("NRP ${r['nrp']}"),
              const SizedBox(height: 8),
              Text(_fmtDayKey(r['day'].toString()),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Chip(
                label: Text(r['type'].toString(),
                    style: TextStyle(
                        color: _statusColor(r['type'].toString()),
                        fontWeight: FontWeight.bold)),
              ),
              if ((r['note'] ?? '').toString().isNotEmpty)
                Text("Keterangan: ${r['note']}"),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () async {
                    await DatabaseHelper.instance.deleteLeave(r['id'] as int);
                    if (ctx.mounted) Navigator.pop(ctx);
                    _load();
                  },
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  label:
                      const Text("Hapus", style: TextStyle(color: Colors.red)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDetail(Map<String, Object?> r) {
    if (r['is_leave'] == true) {
      _showLeaveDetail(r);
      return;
    }
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final id = r['id'] as int;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (r['has_photo'] == 1)
                  Center(
                    child: FutureBuilder<Uint8List?>(
                      future: DatabaseHelper.instance.getPhoto(id),
                      builder: (c, snap) {
                        final bytes = snap.data;
                        if (bytes == null) {
                          return const SizedBox(
                              height: 112,
                              child: Center(child: CircularProgressIndicator()));
                        }
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.memory(bytes,
                              width: 112, height: 112, fit: BoxFit.cover),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 12),
                Text(r['nama'].toString(),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                Text("NRP ${r['nrp']} • ${r['jabatan']}"),
                const SizedBox(height: 8),
                Text(
                    "${r['type']} • ${_fmtDayKey(r['day'].toString())} ${_fmtClock(r['timestamp'].toString())}"),
                Text("Status: ${r['status'] ?? '-'}"),
                if (r['manual'] == 1)
                  Text("Dibuat manual oleh admin. Alasan: ${r['note'] ?? '-'}",
                      style: const TextStyle(color: Colors.deepOrange)),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => _deleteRecord(r),
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    label: const Text("Hapus",
                        style: TextStyle(color: Colors.red)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'TERLAMBAT':
        return Colors.orange.shade800;
      case 'IZIN':
        return const Color(0xFF1565C0);
      case 'SAKIT':
        return const Color(0xFF7B1FA2);
      case 'DINAS':
        return const Color(0xFF00796B);
      case 'PULANG':
        return Colors.blue.shade700;
      default:
        return Colors.green.shade700;
    }
  }

  @override
  Widget build(BuildContext context) {
    final users = DatabaseHelper.instance.cachedUsers;
    final sameDay = _range.start == _range.end;
    final rangeLabel = sameDay
        ? _fmtDay(_range.start)
        : "${_fmtDay(_range.start)} s/d ${_fmtDay(_range.end)}";

    return Scaffold(
      appBar: AppBar(
        title: const Text("Rekap Absensi"),
        backgroundColor: _kNavy,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: "Absensi manual",
            icon: const Icon(Icons.edit_calendar_outlined),
            onPressed: _addManual,
          ),
          IconButton(
            tooltip: "Export Excel",
            icon: _exporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.table_view),
            onPressed: _exporting ? null : _export,
          ),
        ],
      ),
      body: Column(
        children: [
          // Ringkasan hari ini
          Card(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: ExpansionTile(
              leading: const Icon(Icons.today_outlined),
              title: Text(
                  "Hari ini: $_presentToday hadir • $_leaveToday izin/sakit/dinas • ${_absentToday.length} belum absen",
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              children: [
                if (_absentToday.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text("Semua personel sudah tercatat."),
                  )
                else
                  for (final u in _absentToday)
                    ListTile(
                      dense: true,
                      title: Text(u.nama),
                      subtitle: Text("NRP ${u.nrp} • ${u.jabatan}"),
                    ),
              ],
            ),
          ),

          // Filter
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickRange,
                        icon: const Icon(Icons.date_range, size: 18),
                        label: Text(rangeLabel),
                      ),
                    ),
                    const SizedBox(width: 8),
                    DropdownButton<String?>(
                      value: _type,
                      hint: const Text("Jenis"),
                      items: const [
                        DropdownMenuItem(value: null, child: Text("Semua")),
                        DropdownMenuItem(value: 'MASUK', child: Text("Masuk")),
                        DropdownMenuItem(value: 'PULANG', child: Text("Pulang")),
                        DropdownMenuItem(
                            value: 'LEAVE', child: Text("Izin/Sakit/Dinas")),
                      ],
                      onChanged: (v) {
                        setState(() => _type = v);
                        _load();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int?>(
                        isExpanded: true,
                        initialValue: _userId,
                        decoration: const InputDecoration(
                          labelText: "Personel",
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          const DropdownMenuItem<int?>(
                              value: null, child: Text("Semua personel")),
                          for (final u in users)
                            DropdownMenuItem<int?>(
                                value: u.id,
                                child: Text(u.nama,
                                    overflow: TextOverflow.ellipsis)),
                        ],
                        onChanged: (v) {
                          setState(() => _userId = v);
                          _load();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _searchCtrl,
                        decoration: const InputDecoration(
                          labelText: "Cari nama / NRP",
                          prefixIcon: Icon(Icons.search),
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (_) {
                          _debounce?.cancel();
                          _debounce = Timer(
                              const Duration(milliseconds: 400), _load);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text("${_records.length} catatan",
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
          const Divider(height: 1),

          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _records.isEmpty
                    ? const Center(child: Text("Tidak ada data absensi."))
                    : ListView.separated(
                        itemCount: _records.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (ctx, i) {
                          final r = _records[i];
                          final type = r['type'].toString();
                          final status = (r['status'] ?? '').toString();
                          final color = _statusColor(status);
                          return ListTile(
                            onTap: () => _showDetail(r),
                            leading: CircleAvatar(
                              backgroundColor: color.withValues(alpha: 0.12),
                              foregroundColor: color,
                              child: Icon(r['is_leave'] == true
                                  ? Icons.event_busy
                                  : (type == 'MASUK'
                                      ? Icons.login
                                      : Icons.logout)),
                            ),
                            title: Text(r['nama'].toString(),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            subtitle: Text(r['is_leave'] == true
                                ? "NRP ${r['nrp']} • ${_fmtDayKey(r['day'].toString())}${(r['note'] ?? '').toString().isEmpty ? '' : ' • ${r['note']}'}"
                                : "NRP ${r['nrp']} • ${_fmtDayKey(r['day'].toString())} ${_fmtClock(r['timestamp'].toString())}"
                                    "${r['manual'] == 1 ? ' • manual' : ''}"),
                            trailing: Chip(
                              label: Text(status.isEmpty ? type : status,
                                  style: TextStyle(
                                      color: color,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold)),
                              backgroundColor: color.withValues(alpha: 0.10),
                              side: BorderSide.none,
                              visualDensity: VisualDensity.compact,
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// IZIN / SAKIT / DINAS
// ============================================================================
class LeaveScreen extends StatefulWidget {
  const LeaveScreen({super.key});

  @override
  State<LeaveScreen> createState() => _LeaveScreenState();
}

class _LeaveScreenState extends State<LeaveScreen> {
  UserModel? _user;
  String _kind = 'IZIN';
  DateTimeRange? _range;
  final _note = TextEditingController();
  List<Map<String, Object?>> _leaves = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final now = DateTime.now();
    final rows = await DatabaseHelper.instance.getLeaves(
        now.subtract(const Duration(days: 60)),
        now.add(const Duration(days: 60)));
    if (mounted) setState(() => _leaves = rows);
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: now.add(const Duration(days: 365)),
      initialDateRange: _range,
    );
    if (picked != null) setState(() => _range = picked);
  }

  Future<void> _save() async {
    if (_user == null || _range == null) {
      _snack(context, "Pilih personel dan tanggal terlebih dahulu",
          color: Colors.red);
      return;
    }
    try {
      await DatabaseHelper.instance.addLeave(
        userId: _user!.id!,
        start: _range!.start,
        end: _range!.end,
        kind: _kind,
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      );
      _note.clear();
      if (mounted) _snack(context, "Tersimpan", color: Colors.green.shade700);
      _load();
    } catch (e) {
      if (mounted) _snack(context, "Gagal menyimpan: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final users = DatabaseHelper.instance.cachedUsers;
    return Scaffold(
      appBar: AppBar(
        title: const Text("Izin / Sakit / Dinas"),
        backgroundColor: _kNavy,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<UserModel>(
            isExpanded: true,
            initialValue: _user,
            decoration: const InputDecoration(
                labelText: "Personel", border: OutlineInputBorder()),
            items: [
              for (final u in users)
                DropdownMenuItem(
                    value: u,
                    child: Text("${u.nama} (${u.nrp})",
                        overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _user = v),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'IZIN', label: Text("Izin")),
              ButtonSegment(value: 'SAKIT', label: Text("Sakit")),
              ButtonSegment(value: 'DINAS', label: Text("Dinas")),
            ],
            selected: {_kind},
            onSelectionChanged: (v) => setState(() => _kind = v.first),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _pickRange,
            icon: const Icon(Icons.date_range),
            label: Text(_range == null
                ? "Pilih tanggal"
                : _range!.start == _range!.end
                    ? _fmtDay(_range!.start)
                    : "${_fmtDay(_range!.start)} s/d ${_fmtDay(_range!.end)}"),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            decoration: const InputDecoration(
                labelText: "Keterangan (opsional)",
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text("Simpan"),
          ),
          const SizedBox(height: 24),
          const Text("Riwayat (±60 hari)",
              style: TextStyle(fontWeight: FontWeight.bold)),
          const Divider(),
          if (_leaves.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: Text("Belum ada data.")),
            ),
          for (final l in _leaves)
            ListTile(
              dense: true,
              title: Text("${l['nama']} • ${l['kind']}"),
              subtitle: Text(
                  "${_fmtDayKey(l['day'].toString())}${(l['note'] ?? '').toString().isEmpty ? '' : ' • ${l['note']}'}"),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                onPressed: () async {
                  await DatabaseHelper.instance.deleteLeave(l['id'] as int);
                  _load();
                },
              ),
            ),
        ],
      ),
    );
  }
}

// ============================================================================
// PENGATURAN
// ============================================================================
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final s = AppSettings.instance;
  late double _threshold = s.matchThreshold;
  late double _margin = s.matchMargin;
  late bool _liveness = s.requireLiveness;
  late TimeOfDay _lateTime = s.lateTime;
  late int _switchHour = s.switchHour;
  late bool _pulangLimit = s.pulangLimitEnabled;
  late TimeOfDay _pulangEarliest = s.pulangEarliest;
  bool _busy = false;

  Future<void> _changePin() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => const _ChangePinDialog(),
    );
    if (ok == true && mounted) {
      _snack(context, "PIN berhasil diganti", color: Colors.green.shade700);
    }
  }

  Future<void> _pickLateTime() async {
    final t = await showTimePicker(context: context, initialTime: _lateTime);
    if (t == null) return;
    await s.setLateTime(t);
    setState(() => _lateTime = t);
  }

  Future<void> _pickPulangTime() async {
    final t =
        await showTimePicker(context: context, initialTime: _pulangEarliest);
    if (t == null) return;
    await s.setPulangEarliest(t);
    setState(() => _pulangEarliest = t);
  }

  Future<void> _backup() async {
    setState(() => _busy = true);
    try {
      final f = await DatabaseHelper.instance.createBackupFile();
      await Share.shareXFiles([XFile(f.path)], text: 'Backup database presensi');
    } catch (e) {
      if (mounted) _snack(context, "Backup gagal: $e");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Pengaturan"),
        backgroundColor: _kNavy,
        foregroundColor: Colors.white,
      ),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text("Keamanan",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ListTile(
              leading: const Icon(Icons.lock_reset),
              title: const Text("Ganti PIN Admin"),
              subtitle: const Text("PIN disimpan dalam bentuk hash"),
              onTap: _changePin,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.face_retouching_natural),
              title: const Text("Verifikasi liveness (anti foto/video)"),
              subtitle: const Text("Tantangan acak: kedip / senyum / toleh"),
              value: _liveness,
              onChanged: (v) async {
                await s.setRequireLiveness(v);
                setState(() => _liveness = v);
              },
            ),
            const Divider(height: 32),
            const Text("Pengenalan Wajah",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            Text("Ambang kemiripan: ${(_threshold * 100).toStringAsFixed(0)}%"),
            Slider(
              value: _threshold,
              min: 0.50,
              max: 0.90,
              divisions: 40,
              label: "${(_threshold * 100).toStringAsFixed(0)}%",
              onChanged: (v) => setState(() => _threshold = v),
              onChangeEnd: (v) => s.setMatchThreshold(v),
            ),
            Text("Selisih minimal antar kandidat: ${(_margin * 100).toStringAsFixed(0)}%"),
            Slider(
              value: _margin,
              min: 0.0,
              max: 0.15,
              divisions: 15,
              label: "${(_margin * 100).toStringAsFixed(0)}%",
              onChanged: (v) => setState(() => _margin = v),
              onChangeEnd: (v) => s.setMatchMargin(v),
            ),
            const Text(
              "Gunakan menu \"Uji Pengenalan\" untuk melihat skor wajah asli lalu atur nilai di atas.",
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const Divider(height: 32),
            const Text("Jam Kerja",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text("Batas terlambat"),
              subtitle: Text(
                  "Masuk setelah ${_two(_lateTime.hour)}:${_two(_lateTime.minute)} dicatat TERLAMBAT"),
              onTap: _pickLateTime,
            ),
            ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: const Text("Pergantian otomatis MASUK → PULANG"),
              subtitle: Text("Mulai pukul ${_two(_switchHour)}:00"),
              trailing: DropdownButton<int>(
                value: _switchHour,
                items: [
                  for (int h = 9; h <= 16; h++)
                    DropdownMenuItem(value: h, child: Text("${_two(h)}:00")),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  await s.setSwitchHour(v);
                  setState(() => _switchHour = v);
                },
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.timer_outlined),
              title: const Text("Batasi jam paling awal PULANG"),
              subtitle: Text(_pulangLimit
                  ? "PULANG baru diterima mulai ${_two(_pulangEarliest.hour)}:${_two(_pulangEarliest.minute)}"
                  : "Tidak dibatasi"),
              value: _pulangLimit,
              onChanged: (v) async {
                await s.setPulangLimitEnabled(v);
                setState(() => _pulangLimit = v);
              },
            ),
            if (_pulangLimit)
              ListTile(
                leading: const Icon(Icons.schedule),
                title: const Text("Jam paling awal PULANG"),
                subtitle: Text(
                    "${_two(_pulangEarliest.hour)}:${_two(_pulangEarliest.minute)} (ketuk untuk ubah)"),
                onTap: _pickPulangTime,
              ),
            const Divider(height: 32),
            const Text("Data",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ListTile(
              leading: const Icon(Icons.backup_outlined),
              title: const Text("Backup database"),
              subtitle: const Text("Bagikan file .db ke penyimpanan / WhatsApp"),
              onTap: _backup,
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// UJI PENGENALAN (KALIBRASI) - tidak mencatat absensi
// ============================================================================
class CalibrationScreen extends StatefulWidget {
  final CameraController cameraController;
  final CameraDescription frontCamera;

  const CalibrationScreen({
    super.key,
    required this.cameraController,
    required this.frontCamera,
  });

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  bool _busy = false;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  String _msg = "Hadapkan wajah ke kamera";
  MatchResult? _match;

  @override
  void initState() {
    super.initState();
    FaceRecognitionService.instance.resetLiveness();
    _start();
  }

  Future<void> _start() async {
    final c = widget.cameraController;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
      await c.startImageStream(_onFrame);
    } catch (e) {
      if (mounted) setState(() => _msg = "Kamera gagal: $e");
    }
  }

  void _onFrame(CameraImage image) async {
    if (_busy ||
        DateTime.now().difference(_last).inMilliseconds < 300) {
      return;
    }
    _busy = true;
    _last = DateTime.now();
    try {
      final r = await FaceRecognitionService.instance.processCameraImage(
        cameraImage: image,
        camera: widget.frontCamera,
        requireLiveness: false,
      );
      if (!mounted) return;
      MatchResult? m;
      if (r.vector != null) {
        m = FaceMatcher.match(r.vector!, DatabaseHelper.instance.cachedUsers);
      }
      setState(() {
        _msg = r.message;
        if (m != null) _match = m;
      });
    } catch (e) {
      debugPrint("Kalibrasi error: $e");
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    final c = widget.cameraController;
    try {
      if (c.value.isInitialized && c.value.isStreamingImages) {
        c.stopImageStream().catchError((_) {});
      }
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    final m = _match;
    final hasUsers = DatabaseHelper.instance.cachedUsers.isNotEmpty;

    String verdict = "-";
    Color verdictColor = Colors.black54;
    if (m != null && m.best != null) {
      if (m.accepts(s.matchThreshold, s.matchMargin)) {
        verdict = "DITERIMA sebagai ${m.best!.nama}";
        verdictColor = Colors.green.shade700;
      } else if (m.passesThreshold(s.matchThreshold)) {
        verdict = "DITOLAK: selisih kandidat terlalu kecil (ambigu)";
        verdictColor = Colors.orange.shade800;
      } else {
        verdict = "DITOLAK: di bawah ambang kemiripan";
        verdictColor = Colors.red;
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("Uji Pengenalan"),
        backgroundColor: _kNavy,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: SizedBox(
                width: 220,
                height: 280,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: CameraPreview(widget.cameraController),
                ),
              ),
            ),
          ),
          Text(_msg, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          if (!hasUsers)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text("Belum ada personel terdaftar."),
            )
          else
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        "Kandidat terbaik: ${m?.best?.nama ?? '-'}",
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 6),
                    Text(
                        "Skor terbaik: ${m == null ? '-' : '${(m.bestScore * 100).toStringAsFixed(1)}%'}"),
                    Text(
                        "Skor kandidat kedua: ${m == null || m.secondScore < -0.5 ? '-' : '${(m.secondScore * 100).toStringAsFixed(1)}%'}"),
                    Text(
                        "Selisih: ${m == null || m.secondScore < -0.5 ? '-' : '${(m.margin * 100).toStringAsFixed(1)}%'}"),
                    const Divider(),
                    Text(
                        "Ambang: ${(s.matchThreshold * 100).toStringAsFixed(0)}% • Selisih min: ${(s.matchMargin * 100).toStringAsFixed(0)}%",
                        style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 6),
                    Text(verdict,
                        style: TextStyle(
                            color: verdictColor, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              "Tips kalibrasi: ujilah wajah yang sama di beberapa hari/pencahayaan, "
              "lalu wajah orang lain. Atur ambang di antara skor 'orang yang sama' "
              "(terendah) dan skor 'orang berbeda' (tertinggi).",
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
        ],
      ),
    );
  }
}


// ============================================================================
// REKAP KALENDER (matriks personel x tanggal)
// ============================================================================
class MonthlyRecapScreen extends StatefulWidget {
  const MonthlyRecapScreen({super.key});

  @override
  State<MonthlyRecapScreen> createState() => _MonthlyRecapScreenState();
}

class _MonthlyRecapScreenState extends State<MonthlyRecapScreen> {
  static const double _nameW = 140;
  static const double _totW = 46;
  static const double _headH = 54;
  static const List<String> _wd = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];
  static const List<String> _monthNames = [
    'Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni',
    'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember',
  ];
  static const Color _border = Color(0xFFE3E7EF);

  late DateTime _month;
  RecapMatrix? _matrix;
  bool _loading = true;
  bool _exporting = false;
  bool _showTimes = false; // false = huruf ringkas, true = jam masuk/pulang
  final _search = TextEditingController();
  final _vLeft = ScrollController();
  final _vRight = ScrollController();
  bool _syncing = false;

  double get _dayW => _showTimes ? 58 : 36;
  double get _rowH => _showTimes ? 50 : 44;

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    _month = DateTime(n.year, n.month);
    _vLeft.addListener(() => _sync(_vLeft, _vRight));
    _vRight.addListener(() => _sync(_vRight, _vLeft));
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    _vLeft.dispose();
    _vRight.dispose();
    super.dispose();
  }

  /// Gulir vertikal kolom nama dan kolom tanggal dibuat selalu sejajar
  void _sync(ScrollController from, ScrollController to) {
    if (_syncing || !to.hasClients || !from.hasClients) return;
    _syncing = true;
    final target =
        from.offset.clamp(0.0, to.position.maxScrollExtent).toDouble();
    if ((to.offset - target).abs() > 0.5) to.jumpTo(target);
    _syncing = false;
  }

  DateTime get _start => _month;
  DateTime get _end => DateTime(_month.year, _month.month + 1, 0);

  bool get _canGoNext {
    final n = DateTime.now();
    return DateTime(_month.year, _month.month + 1)
        .isBefore(DateTime(n.year, n.month + 1));
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final m = await RecapBuilder.build(_start, _end);
      if (!mounted) return;
      setState(() {
        _matrix = m;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack(context, "Gagal memuat rekap: $e");
    }
  }

  void _shift(int delta) {
    setState(() => _month = DateTime(_month.year, _month.month + delta));
    _load();
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      await ExcelExporterService.exportAndShareAttendance(
        startDate: _start,
        endDate: DateTime(_end.year, _end.month, _end.day, 23, 59, 59, 999),
      );
    } catch (e) {
      if (mounted) _snack(context, "Gagal mengekspor Excel: $e");
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Color _color(String code) => Color(RecapBuilder.colors[code] ?? 0xFFFFFFFF);

  BoxDecoration _cellDeco(Color? bg) => BoxDecoration(
        color: bg ?? Colors.white,
        border: Border.all(color: _border, width: 0.5),
      );

  String _hm(DateTime? d, {String empty = '--:--'}) =>
      d == null ? empty : '${_two(d.hour)}:${_two(d.minute)}';

  void _showCell(UserRecap r, DateTime date, DayCell c) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(r.user.nama,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              Text("NRP ${r.user.nrp} • ${r.user.jabatan}"),
              const SizedBox(height: 8),
              Text(_fmtDay(date),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: _color(c.code),
                    borderRadius: BorderRadius.circular(8)),
                child: Text(RecapBuilder.legend[c.code] ?? '-',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              if (c.code == 'H' || c.code == 'T') ...[
                const SizedBox(height: 10),
                Text("MASUK : ${c.masuk == null ? '-' : '${_hm(c.masuk)}:${_two(c.masuk!.second)}'}"),
                Text(
                    "PULANG: ${c.pulang == null ? 'belum absen PULANG' : '${_hm(c.pulang)}:${_two(c.pulang!.second)}'}"),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _dayHeader(DateTime d, String todayKey) {
    final weekend = d.weekday >= DateTime.saturday;
    final isToday = DatabaseHelper.dayKey(d) == todayKey;
    return Container(
      width: _dayW,
      height: _headH,
      alignment: Alignment.center,
      decoration: _cellDeco(isToday
          ? const Color(0xFFF2B134)
          : (weekend ? const Color(0xFFCFD8DC) : const Color(0xFFE8EDF5))),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('${d.day}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          Text(_wd[d.weekday - 1],
              style: const TextStyle(fontSize: 10, color: Colors.black54)),
        ],
      ),
    );
  }

  Widget _dayCell(UserRecap r, int i, RecapMatrix m, String todayKey) {
    final c = r.days[i];
    final date = m.dates[i];
    final isAttend = c.code == 'H' || c.code == 'T';
    final missingOut = isAttend &&
        c.pulang == null &&
        DatabaseHelper.dayKey(date).compareTo(todayKey) < 0;

    Widget content;
    if (_showTimes && isAttend) {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(_hm(c.masuk),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          Text(_hm(c.pulang),
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: c.pulang == null
                      ? Colors.red.shade700
                      : Colors.black54)),
        ],
      );
    } else {
      content = Text(
        c.code == 'L' ? '' : c.code,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: c.code == 'A' ? Colors.red.shade800 : const Color(0xFF1F2937),
        ),
      );
    }

    final tappable = c.code.isNotEmpty && c.code != 'L';
    return GestureDetector(
      onTap: tappable ? () => _showCell(r, date, c) : null,
      child: Container(
        width: _dayW,
        height: _rowH,
        alignment: Alignment.center,
        decoration: _cellDeco(c.code.isEmpty ? null : _color(c.code)),
        child: Stack(
          alignment: Alignment.center,
          children: [
            content,
            if (missingOut && !_showTimes)
              Positioned(
                right: 3,
                bottom: 3,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                      color: Colors.deepOrange, shape: BoxShape.circle),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _totalCell(int v, Color bg) => Container(
        width: _totW,
        height: _rowH,
        alignment: Alignment.center,
        decoration: _cellDeco(bg),
        child: Text('$v',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
      );

  Widget _nameCell(UserRecap r) => Container(
        width: _nameW,
        height: _rowH,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: _cellDeco(null),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(r.user.nama,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            Text(r.user.nrp,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: Colors.black54)),
          ],
        ),
      );

  Widget _navyHead(String t, double w) => Container(
        width: w,
        height: _headH,
        alignment: Alignment.center,
        decoration: _cellDeco(_kNavy),
        child: Text(t,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
      );

  Widget _grid(RecapMatrix m, List<UserRecap> rows) {
    if (rows.isEmpty) {
      return const Center(child: Text("Tidak ada personel yang cocok."));
    }
    final todayKey = DatabaseHelper.dayKey(DateTime.now());
    final contentW = m.dates.length * _dayW + 6 * _totW;

    final headerRow = Row(children: [
      for (final d in m.dates) _dayHeader(d, todayKey),
      for (final t in const ['Hadir', 'Telat', 'Izin', 'Sakit', 'Dinas', 'Alpa'])
        _navyHead(t, _totW),
    ]);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Kolom nama: tetap di kiri saat digeser ke kanan
        SizedBox(
          width: _nameW,
          child: Column(
            children: [
              _navyHead('Nama / NRP', _nameW),
              Expanded(
                child: ListView.builder(
                  controller: _vLeft,
                  itemExtent: _rowH,
                  itemCount: rows.length,
                  itemBuilder: (_, i) => _nameCell(rows[i]),
                ),
              ),
            ],
          ),
        ),
        // Kolom tanggal: header tanggal tetap di atas saat digulir ke bawah
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: contentW,
              child: Column(
                children: [
                  headerRow,
                  Expanded(
                    child: ListView.builder(
                      controller: _vRight,
                      itemExtent: _rowH,
                      itemCount: rows.length,
                      itemBuilder: (_, i) {
                        final r = rows[i];
                        return Row(children: [
                          for (int k = 0; k < r.days.length; k++)
                            _dayCell(r, k, m, todayKey),
                          _totalCell(r.hadir, const Color(0xFFF1F8E9)),
                          _totalCell(r.telat, const Color(0xFFFFF3E0)),
                          _totalCell(r.izin, const Color(0xFFE3F2FD)),
                          _totalCell(r.sakit, const Color(0xFFF3E5F5)),
                          _totalCell(r.dinas, const Color(0xFFE0F2F1)),
                          _totalCell(r.alpa, const Color(0xFFFFEBEE)),
                        ]);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = _matrix;
    final q = _search.text.trim().toLowerCase();
    final rows = (m == null)
        ? <UserRecap>[]
        : m.rows
            .where((r) =>
                q.isEmpty ||
                r.user.nama.toLowerCase().contains(q) ||
                r.user.nrp.toLowerCase().contains(q))
            .toList();

    int sum(int Function(UserRecap) f) => rows.fold(0, (a, r) => a + f(r));

    return Scaffold(
      appBar: AppBar(
        title: const Text("Rekap Kalender"),
        backgroundColor: _kNavy,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: "Export Excel bulan ini",
            icon: _exporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.table_view),
            onPressed: _exporting ? null : _export,
          ),
        ],
      ),
      body: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => _shift(-1)),
              Text("${_monthNames[_month.month - 1]} ${_month.year}",
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _canGoNext ? () => _shift(1) : null),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      labelText: "Cari nama / NRP",
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text("Huruf")),
                    ButtonSegment(value: true, label: Text("Jam")),
                  ],
                  selected: {_showTimes},
                  onSelectionChanged: (v) =>
                      setState(() => _showTimes = v.first),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final e in RecapBuilder.legend.entries)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                        color: _color(e.key),
                        borderRadius: BorderRadius.circular(6)),
                    child: Text("${e.key} = ${e.value}",
                        style: const TextStyle(fontSize: 11)),
                  ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: _border),
                      borderRadius: BorderRadius.circular(6)),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.circle, size: 8, color: Colors.deepOrange),
                      SizedBox(width: 4),
                      Text("belum absen PULANG",
                          style: TextStyle(fontSize: 11)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                "${rows.length} personel • Hadir ${sum((r) => r.hadir)} • Terlambat ${sum((r) => r.telat)} • Izin ${sum((r) => r.izin)} • Sakit ${sum((r) => r.sakit)} • Dinas ${sum((r) => r.dinas)} • Alpa ${sum((r) => r.alpa)}",
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600, color: _kNavy),
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading || m == null
                ? const Center(child: CircularProgressIndicator())
                : _grid(m, rows),
          ),
        ],
      ),
    );
  }
}