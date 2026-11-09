import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_settings.dart';
import 'database_helper.dart';
import 'face_math_utils.dart';
import 'face_recognition_service.dart';

class EnrollmentScreen extends StatefulWidget {
  final CameraController cameraController;
  final CameraDescription frontCamera;

  const EnrollmentScreen({
    super.key,
    required this.cameraController,
    required this.frontCamera,
  });

  @override
  State<EnrollmentScreen> createState() => _EnrollmentScreenState();
}

class _EnrollmentScreenState extends State<EnrollmentScreen> {
  static const int _sampleTarget = 5;

  /// Rata-rata kemiripan terendah sebuah sampel terhadap sampel lain.
  /// Di bawah ini = sampel tidak konsisten (kualitas buruk / pipeline bermasalah).
  static const double _minConsistency = 0.55;

  final _formKey = GlobalKey<FormState>();
  final _nrpController = TextEditingController();
  final _namaController = TextEditingController();
  final _jabatanController = TextEditingController();

  List<List<double>> _samples = [];
  bool _isCapturing = false;
  String _captureInstruction =
      "Wajah NETRAL (tidak tersenyum), tegak, tanpa kacamata/masker/topi. Tekan Pindai ($_sampleTarget sampel)";

  bool get _hasSamples => _samples.length >= _sampleTarget;

  double _consistency(List<List<double>> s) {
    double minMean = 1.0;
    for (int i = 0; i < s.length; i++) {
      double sum = 0;
      int n = 0;
      for (int j = 0; j < s.length; j++) {
        if (i == j) continue;
        sum += FaceMathUtils.cosineSimilarity(s[i], s[j]);
        n++;
      }
      if (n > 0 && sum / n < minMean) minMean = sum / n;
    }
    return minMean;
  }

  Future<void> _captureSamples() async {
    if (_isCapturing) return;
    setState(() {
      _isCapturing = true;
      _samples = [];
      _captureInstruction = "Mendeteksi wajah... tatap lurus ke kamera";
    });

    FaceRecognitionService.instance.resetLiveness();

    final controller = widget.cameraController;
    final collected = <List<double>>[];
    final done = Completer<void>();
    bool busy = false;
    DateTime lastSample = DateTime.fromMillisecondsSinceEpoch(0);

    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }

      await controller.startImageStream((CameraImage image) async {
        if (busy || done.isCompleted) return;
        if (DateTime.now().difference(lastSample).inMilliseconds < 600) return;
        busy = true;
        try {
          final r = await FaceRecognitionService.instance.processCameraImage(
            cameraImage: image,
            camera: widget.frontCamera,
            // Sampel ke-1, 3, 5 wajib lolos tantangan liveness (anti foto/video)
            requireLiveness: collected.length % 2 == 0,
            strict: true, // wajah netral, tegak, di tengah
          );
          if (done.isCompleted) return;

          if (r.vector != null) {
            collected.add(r.vector!);
            lastSample = DateTime.now();
            HapticFeedback.selectionClick();
            if (mounted) {
              setState(() => _captureInstruction =
                  "Sampel ${collected.length}/$_sampleTarget berhasil. Tetap netral dan tatap kamera...");
            }
            if (collected.length >= _sampleTarget && !done.isCompleted) {
              done.complete();
            }
          } else if (mounted) {
            setState(() => _captureInstruction = r.message);
          }
        } catch (e) {
          debugPrint("Gagal memproses sampel: $e");
        } finally {
          busy = false;
        }
      });

      await done.future.timeout(
        const Duration(seconds: 45),
        onTimeout: () {},
      );
    } catch (e) {
      if (mounted) {
        setState(() => _captureInstruction = "Gagal memindai wajah: $e");
      }
    } finally {
      try {
        if (controller.value.isStreamingImages) {
          await controller.stopImageStream();
        }
      } catch (_) {}
    }

    if (!mounted) return;

    if (collected.length < _sampleTarget) {
      setState(() {
        _isCapturing = false;
        _captureInstruction =
            "Waktu habis (${collected.length}/$_sampleTarget sampel). Pastikan wajah terlihat jelas dan coba lagi.";
      });
      _snack("Pemindaian belum lengkap. Silakan ulangi.",
          Colors.orange.shade800);
      return;
    }

    final consistency = _consistency(collected);
    debugPrint("Konsistensi sampel pendaftaran: $consistency");
    if (consistency < _minConsistency) {
      setState(() {
        _isCapturing = false;
        _captureInstruction =
            "Sampel tidak konsisten (${(consistency * 100).toStringAsFixed(0)}%). "
            "Perbaiki pencahayaan, jangan bergerak, lalu pindai ulang.";
      });
      _snack("Kualitas sampel kurang baik. Ulangi pemindaian.",
          Colors.orange.shade800);
      return;
    }

    HapticFeedback.mediumImpact();
    setState(() {
      _samples = collected;
      _isCapturing = false;
      _captureInstruction =
          "Berhasil! $_sampleTarget sampel siap disimpan "
          "(konsistensi ${(consistency * 100).toStringAsFixed(0)}%).";
    });
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: color,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  Future<void> _saveUserToDatabase() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_hasSamples) {
      _snack("Wajib memindai wajah personel terlebih dahulu!", Colors.red);
      return;
    }

    final nrp = _nrpController.text.trim();
    final threshold = AppSettings.instance.matchThreshold;
    final users = DatabaseHelper.instance.cachedUsers;

    // 1. NRP harus unik
    for (final u in users) {
      if (u.nrp == nrp) {
        _snack(
            "NRP $nrp sudah terdaftar atas nama ${u.nama}. Hapus data lama dulu bila ingin mendaftar ulang.",
            Colors.red);
        return;
      }
    }

    // 2. Wajah harus unik
    for (final u in users) {
      for (final existing in u.faceVectors) {
        for (final sample in _samples) {
          if (existing.length != sample.length) continue;
          if (FaceMathUtils.cosineSimilarity(sample, existing) >= threshold) {
            _snack(
                "Wajah ini sudah terdaftar atas nama ${u.nama} (NRP ${u.nrp}).",
                Colors.red);
            return;
          }
        }
      }
    }

    final newUser = UserModel(
      nrp: nrp,
      nama: _namaController.text.trim(),
      jabatan: _jabatanController.text.trim(),
      faceVectors: _samples,
    );

    try {
      await DatabaseHelper.instance.registerUser(newUser);
    } catch (e) {
      _snack("Gagal menyimpan: $e", Colors.red);
      return;
    }
    if (!mounted) return;
    _snack("Personel ${newUser.nama} berhasil didaftarkan!",
        Colors.green.shade700);
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _nrpController.dispose();
    _namaController.dispose();
    _jabatanController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Registrasi Personel Baru"),
        backgroundColor: const Color(0xFF1B365D),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: SizedBox(
                  width: 220,
                  height: 280,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CameraPreview(widget.cameraController),
                        if (_hasSamples)
                          Container(
                            color: Colors.green.withValues(alpha: 0.35),
                            child: const Center(
                              child: Icon(
                                Icons.check_circle_rounded,
                                color: Colors.white,
                                size: 64,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _captureInstruction,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: _hasSamples ? Colors.green.shade800 : Colors.black87,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _isCapturing ? null : _captureSamples,
                icon: _isCapturing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(_hasSamples
                        ? Icons.refresh
                        : Icons.face_retouching_natural),
                label: Text(_hasSamples
                    ? "Pindai Ulang Wajah"
                    : "1. Pindai Wajah ($_sampleTarget sampel)"),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: _hasSamples ? Colors.green.shade50 : null,
                ),
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: _nrpController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: "NRP / NIP",
                  prefixIcon: Icon(Icons.badge_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? "NRP wajib diisi" : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _namaController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: "Nama Lengkap & Pangkat",
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? "Nama wajib diisi" : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _jabatanController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: "Jabatan / Satuan Kerja (Satker)",
                  prefixIcon: Icon(Icons.shield_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? "Satker wajib diisi" : null,
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: _isCapturing ? null : _saveUserToDatabase,
                icon: const Icon(Icons.save_rounded),
                label: const Text("2. SIMPAN DATA PERSONEL"),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1B365D),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}