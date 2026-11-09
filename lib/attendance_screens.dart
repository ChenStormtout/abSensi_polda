import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'admin_screens.dart';
import 'app_settings.dart';
import 'database_helper.dart';
import 'face_matcher.dart';
import 'face_recognition_service.dart';
import 'image_converter.dart';

// ---- Pengetatan verifikasi ----
/// Jumlah pencocokan berurutan (orang yang sama) sebelum absen dicatat
const int _kConfirmFrames = 2;
const Duration _kConfirmWindow = Duration(seconds: 3);

/// Jumlah penolakan berurutan sebelum ditampilkan "tidak dikenali"
const int _kRejectFrames = 2;
const Duration _kRejectWindow = Duration(seconds: 4);

/// Hasil tampil sampai ditekan OK; bila tidak ada yang menekan, tertutup otomatis
/// setelah hitung mundur (ditampilkan di layar).
const int _kOverlayOkSeconds = 15;
const int _kOverlayErrorSeconds = 20;

String _two(int n) => n.toString().padLeft(2, '0');
String _hm(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

// ============================================================================
// HASIL VERIFIKASI (selalu ditampilkan penuh agar tidak ambigu)
// ============================================================================
enum _OutcomeKind {
  success,
  late,
  already,
  noMasuk,
  tooEarly,
  notRecognized,
  ambiguous,
  clock,
}

class _Outcome {
  final _OutcomeKind kind;
  final String title;
  final String subtitle;
  final UserModel? user;
  final Uint8List? photo;
  final double? score;

  const _Outcome({
    required this.kind,
    required this.title,
    this.subtitle = '',
    this.user,
    this.photo,
    this.score,
  });

  bool get isOk =>
      kind == _OutcomeKind.success || kind == _OutcomeKind.late;

  Color get color {
    switch (kind) {
      case _OutcomeKind.success:
        return const Color(0xFF1B5E20);
      case _OutcomeKind.late:
        return const Color(0xFFE65100);
      case _OutcomeKind.already:
        return const Color(0xFF0D47A1);
      case _OutcomeKind.noMasuk:
      case _OutcomeKind.tooEarly:
        return const Color(0xFF8D5A00);
      case _OutcomeKind.notRecognized:
        return const Color(0xFFB71C1C);
      case _OutcomeKind.ambiguous:
        return const Color(0xFFBF360C);
      case _OutcomeKind.clock:
        return const Color(0xFF37474F);
    }
  }

  IconData get icon {
    switch (kind) {
      case _OutcomeKind.success:
      case _OutcomeKind.late:
        return Icons.verified_rounded;
      case _OutcomeKind.already:
        return Icons.info_rounded;
      case _OutcomeKind.noMasuk:
        return Icons.login_rounded;
      case _OutcomeKind.tooEarly:
        return Icons.schedule_rounded;
      case _OutcomeKind.notRecognized:
      case _OutcomeKind.ambiguous:
        return Icons.cancel_rounded;
      case _OutcomeKind.clock:
        return Icons.schedule_rounded;
    }
  }
}

// ============================================================================
// DIALOG PIN ADMIN (StatefulWidget sendiri agar controller aman di-dispose)
// ============================================================================
class _PinDialog extends StatefulWidget {
  const _PinDialog();

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _controller = TextEditingController();
  String? _error;
  int _attempts = 0;
  DateTime? _lockedUntil;

  void _submit() {
    final now = DateTime.now();
    if (_lockedUntil != null && now.isBefore(_lockedUntil!)) {
      final sisa = _lockedUntil!.difference(now).inSeconds + 1;
      setState(() => _error = "Terkunci. Coba lagi dalam $sisa detik.");
      return;
    }

    if (AppSettings.instance.verifyPin(_controller.text)) {
      Navigator.of(context).pop(true);
      return;
    }

    _attempts++;
    _controller.clear();
    if (_attempts >= 5) {
      _attempts = 0;
      _lockedUntil = now.add(const Duration(seconds: 30));
      setState(() => _error = "Terlalu banyak percobaan. Terkunci 30 detik.");
    } else {
      setState(() => _error = "PIN Admin salah!");
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.lock_outline, color: Color(0xFF1B365D)),
          SizedBox(width: 8),
          Text("Otorisasi Admin"),
        ],
      ),
      content: TextField(
        controller: _controller,
        obscureText: true,
        autofocus: true,
        keyboardType: TextInputType.number,
        maxLength: 6,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: "Masukkan Master PIN",
          border: const OutlineInputBorder(),
          errorText: _error,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text("Batal"),
        ),
        FilledButton(onPressed: _submit, child: const Text("Masuk")),
      ],
    );
  }
}

// ============================================================================
// HALAMAN UTAMA: KIOSK ABSENSI LIVE CAMERA
// ============================================================================
class KioskAttendanceScreen extends StatefulWidget {
  final CameraDescription frontCamera;
  const KioskAttendanceScreen({super.key, required this.frontCamera});

  @override
  State<KioskAttendanceScreen> createState() => _KioskAttendanceScreenState();
}

class _KioskAttendanceScreenState extends State<KioskAttendanceScreen>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  bool _isProcessingFrame = false;
  bool _isCameraInitialized = false;
  bool _inAdmin = false;
  DateTime _lastProcessTime = DateTime.now();
  DateTime _lastActivityTime = DateTime.now();

  String _statusMessage = "Arahkan wajah ke dalam bingkai";
  String? _promptText; // instruksi besar di tengah bingkai
  String _selectedType = "MASUK";
  bool _manualType = false;
  bool _faceDetectedInFrame = false;
  bool _isIdleMode = false;
  bool _verifying = false;
  Timer? _idleTimer;

  // Hasil verifikasi (overlay layar penuh)
  _Outcome? _overlay;
  Timer? _overlayTimer;
  int _overlaySecondsLeft = 0;

  // Setelah hasil final, wajah harus menjauh dulu agar tidak diproses ulang
  bool _requireFaceLeave = false;
  DateTime? _noFaceSince;

  // Konfirmasi multi-frame
  int? _confirmUserId;
  int _confirmCount = 0;
  DateTime? _confirmAt;
  final List<double> _confirmScores = [];
  int _rejectCount = 0;
  DateTime? _rejectAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selectedType = _typeByClock();
    _initCameraAndStream();
    _startIdleWatcher();
  }

  String _typeByClock() =>
      DateTime.now().hour < AppSettings.instance.switchHour ? "MASUK" : "PULANG";

  void _startIdleWatcher() {
    _idleTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;

      if (!_manualType) {
        final t = _typeByClock();
        if (t != _selectedType) setState(() => _selectedType = t);
      }

      final inactiveSeconds =
          DateTime.now().difference(_lastActivityTime).inSeconds;
      if (inactiveSeconds >= 60 && !_isIdleMode) {
        setState(() {
          _isIdleMode = true;
          _statusMessage = "Mode Hemat Daya (Sentuh layar atau hadapkan wajah)";
        });
      }
    });
  }

  void _wakeUpFromIdle() {
    _lastActivityTime = DateTime.now();
    if (_isIdleMode) setState(() => _isIdleMode = false);
  }

  void _resetConfirm() {
    _confirmUserId = null;
    _confirmCount = 0;
    _confirmAt = null;
    _confirmScores.clear();
    _rejectCount = 0;
    _rejectAt = null;
  }

  Future<void> _initCameraAndStream() async {
    final controller = CameraController(
      widget.frontCamera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup:
          Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );
    _cameraController = controller;

    try {
      await controller.initialize();
      if (!mounted) return;
      setState(() => _isCameraInitialized = true);
      await controller.startImageStream(_onCameraFrame);
    } catch (e) {
      debugPrint("Error inisialisasi kamera: $e");
      if (mounted) {
        setState(
            () => _statusMessage = "Kamera gagal dibuka. Periksa izin kamera.");
      }
    }
  }

  Future<void> _stopCameraStreamSafely() async {
    final c = _cameraController;
    try {
      if (c != null && c.value.isInitialized && c.value.isStreamingImages) {
        await c.stopImageStream();
      }
    } catch (e) {
      debugPrint("Gagal menghentikan stream: $e");
    }
  }

  Future<void> _resumeCameraStreamSafely() async {
    final c = _cameraController;
    try {
      if (c != null && c.value.isInitialized && !c.value.isStreamingImages) {
        await c.startImageStream(_onCameraFrame);
      }
    } catch (e) {
      debugPrint("Gagal melanjutkan stream: $e");
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _cameraController;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _stopCameraStreamSafely();
    } else if (state == AppLifecycleState.resumed && !_inAdmin) {
      _resumeCameraStreamSafely();
    }
  }

  // --------------------------------------------------------------------------
  // PEMROSESAN FRAME
  // --------------------------------------------------------------------------
  void _onCameraFrame(CameraImage image) async {
    // Saat panel admin terbuka atau hasil sedang ditampilkan: abaikan frame
    if (_inAdmin || _overlay != null) return;

    final throttleMs = _isIdleMode ? 1500 : 150;
    if (_isProcessingFrame ||
        DateTime.now().difference(_lastProcessTime).inMilliseconds < throttleMs) {
      return;
    }

    _isProcessingFrame = true;
    _lastProcessTime = DateTime.now();

    try {
      final result = await FaceRecognitionService.instance.processCameraImage(
        cameraImage: image,
        camera: widget.frontCamera,
        requireLiveness: AppSettings.instance.requireLiveness,
        consumeChallenge: false,
        detectOnly: _requireFaceLeave, // cepat: hanya cek apakah wajah sudah pergi
      );

      if (!mounted || _inAdmin || _overlay != null) return;

      // --- Tidak ada wajah ---
      if (!result.faceFound) {
        _noFaceSince ??= DateTime.now();
        if (_requireFaceLeave &&
            DateTime.now().difference(_noFaceSince!).inMilliseconds >= 1200) {
          _requireFaceLeave = false;
          FaceRecognitionService.instance.resetLiveness();
        }
        _resetConfirm();
        if (!mounted) return;
        setState(() {
          _faceDetectedInFrame = false;
          _verifying = false;
          _promptText = null;
          if (!_isIdleMode) {
            _statusMessage = _requireFaceLeave
                ? "Selesai. Silakan antrean berikutnya"
                : result.message;
          }
        });
        return;
      }

      _noFaceSince = null;
      _wakeUpFromIdle();

      // --- Wajah masih di depan kamera setelah hasil final ---
      if (_requireFaceLeave) {
        setState(() {
          _faceDetectedInFrame = true;
          _promptText = null;
          _statusMessage = "Selesai. Mundur sebentar untuk antrean berikutnya";
        });
        return;
      }

      // --- Wajah ada, tapi belum memenuhi syarat (liveness/pose/kualitas) ---
      if (result.vector == null) {
        if (_confirmAt != null &&
            DateTime.now().difference(_confirmAt!) > _kConfirmWindow) {
          _resetConfirm();
          _verifying = false;
        }
        setState(() {
          _faceDetectedInFrame = true;
          _promptText = result.message;
          _statusMessage = result.message;
        });
        return;
      }

      // --- Vector didapat: cocokkan ---
      setState(() {
        _faceDetectedInFrame = true;
        _promptText = null;
      });
      await _handleVector(result);
    } catch (e) {
      debugPrint("Kesalahan pemrosesan frame: $e");
    } finally {
      _isProcessingFrame = false;
    }
  }

  Future<void> _handleVector(FaceProcessResult r) async {
    final users = DatabaseHelper.instance.cachedUsers;
    if (users.isEmpty) {
      if (mounted) {
        setState(() => _statusMessage = "Belum ada data personel. Hubungi Admin.");
      }
      return;
    }

    final s = AppSettings.instance;
    final m = FaceMatcher.match(r.vector!, users);
    final now = DateTime.now();

    // ---------- Ditolak ----------
    if (!m.accepts(s.matchThreshold, s.matchMargin)) {
      _confirmUserId = null;
      _confirmCount = 0;
      _confirmScores.clear();

      if (_rejectAt == null || now.difference(_rejectAt!) > _kRejectWindow) {
        _rejectCount = 0;
      }
      _rejectCount++;
      _rejectAt = now;

      if (_rejectCount >= _kRejectFrames) {
        final ambiguous = m.passesThreshold(s.matchThreshold);
        _showOutcome(
          _Outcome(
            kind: ambiguous
                ? _OutcomeKind.ambiguous
                : _OutcomeKind.notRecognized,
            title: ambiguous ? "WAJAH BELUM PASTI" : "WAJAH TIDAK DIKENALI",
            subtitle: ambiguous
                ? "Perbaiki pencahayaan lalu coba lagi."
                : "Kemiripan ${(m.bestScore * 100).clamp(0, 100).toStringAsFixed(0)}%. Coba lagi atau hubungi admin.",
          ),
          requireLeave: false,
        );
      } else if (mounted) {
        setState(() {
          _verifying = true;
          _statusMessage = "Memverifikasi identitas...";
        });
      }
      return;
    }

    // ---------- Diterima: butuh konfirmasi beberapa frame ----------
    _rejectCount = 0;
    final id = m.best!.id;
    if (_confirmUserId == id &&
        _confirmAt != null &&
        now.difference(_confirmAt!) <= _kConfirmWindow) {
      _confirmCount++;
    } else {
      _confirmUserId = id;
      _confirmCount = 1;
      _confirmScores.clear();
    }
    _confirmAt = now;
    _confirmScores.add(m.bestScore);

    if (_confirmCount < _kConfirmFrames) {
      if (mounted) {
        setState(() {
          _verifying = true;
          _statusMessage = "Memverifikasi identitas...";
        });
      }
      return;
    }

    final avg =
        _confirmScores.reduce((a, b) => a + b) / _confirmScores.length;
    await _finalize(m.best!, avg, r.faceRgb, r.faceSize);
  }

  String _statusFor(DateTime now) {
    if (_selectedType != "MASUK") return "PULANG";
    final late = AppSettings.instance.lateTime;
    final limit = DateTime(now.year, now.month, now.day, late.hour, late.minute);
    return now.isAfter(limit) ? "TERLAMBAT" : "HADIR";
  }

  Future<void> _finalize(
      UserModel user, double score, Uint8List? rgb, int size) async {
    final settings = AppSettings.instance;
    final db = DatabaseHelper.instance;
    final now = DateTime.now();

    if (settings.isClockTampered(now)) {
      _showOutcome(const _Outcome(
        kind: _OutcomeKind.clock,
        title: "JAM PERANGKAT TIDAK VALID",
        subtitle: "Jam perangkat mundur dari catatan terakhir. Hubungi admin.",
      ));
      return;
    }

    // Aturan: PULANG hanya bisa setelah MASUK pada hari yang sama
    if (_selectedType == "PULANG") {
      final masuk = await db.firstAttendanceTime(user.id!, "MASUK", now);
      if (!mounted) return;
      if (masuk == null) {
        _showOutcome(_Outcome(
          kind: _OutcomeKind.noMasuk,
          title: "BELUM ABSEN MASUK",
          subtitle:
              "Absen PULANG hanya bisa setelah MASUK hari ini.\nHubungi admin bila lupa absen MASUK.",
          user: user,
        ));
        return;
      }
    }

    // Aturan: batas jam paling awal PULANG
    if (_selectedType == "PULANG" && settings.pulangLimitEnabled) {
      final e = settings.pulangEarliest;
      final earliest =
          DateTime(now.year, now.month, now.day, e.hour, e.minute);
      if (now.isBefore(earliest)) {
        _showOutcome(_Outcome(
          kind: _OutcomeKind.tooEarly,
          title: "BELUM WAKTUNYA PULANG",
          subtitle: "Absen PULANG paling cepat pukul ${_hm(earliest)}.",
          user: user,
        ));
        return;
      }
    }

    // Cegah absen ganda
    final prev = await db.firstAttendanceTime(user.id!, _selectedType, now);
    if (!mounted) return;
    if (prev != null) {
      _showOutcome(_Outcome(
        kind: _OutcomeKind.already,
        title: "SUDAH ABSEN $_selectedType",
        subtitle: "Tercatat pukul ${_hm(prev)}. Tidak dicatat ulang.",
        user: user,
      ));
      return;
    }

    final status = _statusFor(now);

    Uint8List? jpeg;
    if (rgb != null) {
      try {
        jpeg = await ImageConverter.encodeJpeg(rgb, size);
      } catch (e) {
        debugPrint("Gagal encode foto: $e");
      }
    }

    await db.recordAttendance(
      user: user,
      type: _selectedType,
      status: status,
      photo: jpeg,
      at: now,
    );
    await settings.touchClock(now);

    if (!mounted) return;
    final isLate = status == "TERLAMBAT";
    _showOutcome(_Outcome(
      kind: isLate ? _OutcomeKind.late : _OutcomeKind.success,
      title: "PRESENSI $_selectedType BERHASIL",
      subtitle: isLate ? "TERLAMBAT • ${_hm(now)}" : "Pukul ${_hm(now)}",
      user: user,
      photo: jpeg,
      score: score,
    ));
  }

  /// Tampilkan hasil layar penuh. Selalu dipanggil untuk SETIAP hasil final.
  void _showOutcome(_Outcome o, {bool requireLeave = true}) {
    _resetConfirm();
    FaceRecognitionService.instance.resetLiveness();
    _requireFaceLeave = requireLeave;
    _noFaceSince = null;
    _overlayTimer?.cancel();

    if (o.isOk) {
      SystemSound.play(SystemSoundType.click);
      HapticFeedback.heavyImpact();
    } else {
      HapticFeedback.vibrate();
    }

    _overlaySecondsLeft = o.isOk ? _kOverlayOkSeconds : _kOverlayErrorSeconds;
    setState(() {
      _overlay = o;
      _verifying = false;
      _promptText = null;
    });

    _overlayTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_overlaySecondsLeft <= 1) {
        _dismissOverlay();
      } else {
        setState(() => _overlaySecondsLeft--);
      }
    });
  }

  /// Tutup layar hasil (ditekan OK atau hitung mundur habis)
  void _dismissOverlay() {
    _overlayTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _overlay = null;
      _statusMessage = _requireFaceLeave
          ? "Selesai. Mundur sebentar untuk antrean berikutnya"
          : "Arahkan wajah ke dalam bingkai";
    });
  }

  // --------------------------------------------------------------------------
  // ADMIN
  // --------------------------------------------------------------------------
  Future<void> _openAdminPinDialog() async {
    _wakeUpFromIdle();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => const _PinDialog(),
    );
    if (ok == true && mounted) {
      await _openAdminDashboard();
    }
  }

  Future<void> _openAdminDashboard() async {
    _inAdmin = true;
    _overlayTimer?.cancel();
    _overlay = null;
    _resetConfirm();
    await _stopCameraStreamSafely();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AdminDashboardScreen(
          cameraController: _cameraController!,
          frontCamera: widget.frontCamera,
        ),
      ),
    );
    if (!mounted) return;
    FaceRecognitionService.instance.resetLiveness();
    await _stopCameraStreamSafely();
    _requireFaceLeave = false;
    _inAdmin = false;
    setState(() {
      _verifying = false;
      _promptText = null;
      _statusMessage = "Arahkan wajah ke dalam bingkai";
    });
    await _resumeCameraStreamSafely();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _idleTimer?.cancel();
    _overlayTimer?.cancel();
    _cameraController?.dispose();
    super.dispose();
  }

  // --------------------------------------------------------------------------
  // UI
  // --------------------------------------------------------------------------
  Widget _buildOverlay(_Outcome o) {
    return Positioned.fill(
      child: Container(
        color: o.color.withValues(alpha: 0.97),
        padding: const EdgeInsets.all(24),
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(o.icon, color: Colors.white, size: 72),
                const SizedBox(height: 12),
                if (o.photo != null) ...[
                  ClipOval(
                    child: Image.memory(
                      o.photo!,
                      width: 132,
                      height: 132,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                Text(
                  o.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.amberAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                  ),
                ),
                if (o.user != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    o.user!.nama,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 24,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "NRP: ${o.user!.nrp}\n${o.user!.jabatan}",
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
                if (o.subtitle.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    o.subtitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (o.score != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      "Akurasi Biometrik: ${(o.score! * 100).toStringAsFixed(1)}%",
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  width: 240,
                  height: 54,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: o.color,
                      textStyle: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    onPressed: _dismissOverlay,
                    child: Text(
                        (o.kind == _OutcomeKind.notRecognized ||
                                o.kind == _OutcomeKind.ambiguous)
                            ? "COBA LAGI"
                            : "OK"),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  "Tertutup otomatis dalam $_overlaySecondsLeft detik",
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isCameraInitialized || _cameraController == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.amber),
              const SizedBox(height: 16),
              Text(
                _statusMessage,
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: _wakeUpFromIdle,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            CameraPreview(_cameraController!),

            // Bingkai wajah
            Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: 270,
                height: 360,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _verifying
                        ? Colors.lightBlueAccent
                        : _faceDetectedInFrame
                            ? Colors.greenAccent
                            : Colors.amberAccent,
                    width: _faceDetectedInFrame ? 4 : 2.5,
                  ),
                  borderRadius: BorderRadius.circular(180),
                ),
              ),
            ),

            // Spinner saat memverifikasi
            if (_verifying)
              const Center(
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: CircularProgressIndicator(
                    color: Colors.lightBlueAccent,
                    strokeWidth: 5,
                  ),
                ),
              ),

            // Instruksi besar (kedip / senyum / toleh / tatap lurus, dll.)
            if (_promptText != null && !_verifying)
              Align(
                alignment: const Alignment(0, -0.62),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 28),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    _promptText!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.amberAccent,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),

            // Header
            Positioned(
              top: 44,
              left: 16,
              right: 16,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  SegmentedButton<String>(
                    style: SegmentedButton.styleFrom(
                      backgroundColor: Colors.black87,
                      foregroundColor: Colors.white,
                      selectedBackgroundColor: const Color(0xFF1B365D),
                      selectedForegroundColor: Colors.amberAccent,
                    ),
                    segments: const [
                      ButtonSegment(
                        value: "MASUK",
                        label: Text("MASUK"),
                        icon: Icon(Icons.login, size: 18),
                      ),
                      ButtonSegment(
                        value: "PULANG",
                        label: Text("PULANG"),
                        icon: Icon(Icons.logout, size: 18),
                      ),
                    ],
                    selected: {_selectedType},
                    onSelectionChanged: (val) {
                      _wakeUpFromIdle();
                      _resetConfirm();
                      setState(() {
                        _selectedType = val.first;
                        _manualType = true;
                      });
                    },
                  ),
                  IconButton.filledTonal(
                    icon: const Icon(Icons.admin_panel_settings),
                    onPressed: _openAdminPinDialog,
                    tooltip: "Menu Admin",
                  ),
                ],
              ),
            ),

            // Footer status
            Positioned(
              bottom: 36,
              left: 20,
              right: 20,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.82),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white24),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "PERSONEL TERDAFTAR: ${DatabaseHelper.instance.cachedUsers.length}",
                      style: const TextStyle(
                        color: Colors.amberAccent,
                        fontSize: 11,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _statusMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Mode hemat daya
            if (_isIdleMode)
              Container(
                color: Colors.black.withValues(alpha: 0.85),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.nightlight_round,
                          color: Colors.amberAccent, size: 64),
                      SizedBox(height: 16),
                      Text(
                        "MODE SIAGA (HEMAT DAYA)\nSentuh layar atau hadapkan wajah ke kamera",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70, fontSize: 16),
                      ),
                    ],
                  ),
                ),
              ),

            // Hasil verifikasi (selalu paling atas)
            if (_overlay != null) _buildOverlay(_overlay!),
          ],
        ),
      ),
    );
  }
}