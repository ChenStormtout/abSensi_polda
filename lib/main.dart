import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app_settings.dart';
import 'attendance_screens.dart';
import 'database_helper.dart';
import 'face_recognition_service.dart';

void main() async {
  // Wajib dipanggil sebelum mengakses plugin native
  WidgetsFlutterBinding.ensureInitialized();

  // Portrait saja agar perhitungan rotasi kamera konsisten
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // Mode kiosk: layar penuh dan tetap menyala
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await WakelockPlus.enable();

  // 1. Pengaturan (PIN ter-hash, threshold, jam kerja)
  await AppSettings.instance.load();

  // 2. Database & cache vector ke RAM
  await DatabaseHelper.instance.loadUsersToCache();

  // 3. Model AI (ML Kit + MobileFaceNet TFLite)
  await FaceRecognitionService.instance.initialize();

  // 4. Kamera depan
  final cameras = await availableCameras();
  if (cameras.isEmpty) {
    runApp(const _NoCameraApp());
    return;
  }
  final frontCamera = cameras.firstWhere(
    (camera) => camera.lensDirection == CameraLensDirection.front,
    orElse: () => cameras.first,
  );

  runApp(PoldaAttendanceApp(frontCamera: frontCamera));
}

class PoldaAttendanceApp extends StatelessWidget {
  final CameraDescription frontCamera;

  const PoldaAttendanceApp({super.key, required this.frontCamera});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Presensi Personel Offline',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B365D)),
        useMaterial3: true,
      ),
      home: KioskAttendanceScreen(frontCamera: frontCamera),
    );
  }
}

class _NoCameraApp extends StatelessWidget {
  const _NoCameraApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              "Kamera tidak ditemukan atau izin kamera ditolak.\nPeriksa perangkat dan izin aplikasi.",
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}