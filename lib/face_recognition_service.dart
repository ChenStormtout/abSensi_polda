import 'dart:io';
import 'dart:math';
import 'dart:ui' show Size;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'face_math_utils.dart';
import 'image_converter.dart';

class FaceProcessResult {
  final bool faceFound;
  final List<double>? vector;

  /// Piksel RGB wajah ter-align (untuk bukti foto; di-encode JPEG hanya saat absen berhasil)
  final Uint8List? faceRgb;
  final int faceSize;
  final String message;

  FaceProcessResult({
    required this.faceFound,
    this.vector,
    this.faceRgb,
    this.faceSize = 112,
    required this.message,
  });
}

enum _Challenge { blink, smile, turn }

class FaceRecognitionService {
  static final FaceRecognitionService instance = FaceRecognitionService._init();
  FaceRecognitionService._init();

  // ---- Batas kualitas (sesuaikan dengan hasil uji lapangan) ----
  static const double kMinBrightness = 50;
  static const double kMaxBrightness = 215;
  static const double kMinSharpness = 25;
  static const double kMinFaceWidthRatio = 0.28; // lebar wajah / lebar gambar
  static const double kMaxHeadAngle = 12; // derajat (yaw / roll)

  FaceDetector? _faceDetector;
  Interpreter? _interpreter;
  bool _initialized = false;

  int _vectorDimension = 192;
  int _inputSize = 112;
  int get vectorDimension => _vectorDimension;
  bool get modelReady => _interpreter != null;

  // ---- State liveness: tantangan acak ----
  final Random _rng = Random.secure();
  _Challenge? _challenge;
  DateTime? _challengeStartAt;
  DateTime? _challengeDoneAt;

  void resetLiveness() {
    _challenge = null;
    _challengeStartAt = null;
    _challengeDoneAt = null;
  }

  Future<void> initialize() async {
    if (_initialized) return;

    final options = FaceDetectorOptions(
      enableClassification: true, // mata terbuka & senyum
      enableLandmarks: true, // posisi mata untuk alignment
      enableContours: false,
      performanceMode: FaceDetectorMode.fast,
      minFaceSize: 0.25,
    );
    _faceDetector = FaceDetector(options: options);

    try {
      final interpreterOptions = InterpreterOptions()..threads = 4;
      _interpreter = await Interpreter.fromAsset(
        'assets/models/mobilefacenet.tflite',
        options: interpreterOptions,
      );
      _vectorDimension = _interpreter!.getOutputTensor(0).shape.last;
      final inShape = _interpreter!.getInputTensor(0).shape;
      if (inShape.length >= 3) _inputSize = inShape[1];
      debugPrint(
          "Model dimuat. Input: $inShape, dimensi output: $_vectorDimension");
    } catch (e) {
      debugPrint("Gagal memuat model TFLite: $e");
    }
    _initialized = true;
  }

  String _challengePrompt(_Challenge c) {
    switch (c) {
      case _Challenge.blink:
        return "Verifikasi: KEDIPKAN MATA";
      case _Challenge.smile:
        return "Verifikasi: TERSENYUMLAH";
      case _Challenge.turn:
        return "Verifikasi: TOLEH KEPALA ke samping, lalu hadap depan";
    }
  }

  /// Mengembalikan pesan bila tantangan belum selesai, null bila sudah lulus.
  String? _runChallenge(Face face) {
    final now = DateTime.now();

    // Kedaluwarsa
    if (_challengeDoneAt != null &&
        now.difference(_challengeDoneAt!).inSeconds >= 6) {
      _challenge = null;
      _challengeDoneAt = null;
    }
    if (_challenge != null &&
        _challengeDoneAt == null &&
        now.difference(_challengeStartAt!).inSeconds >= 12) {
      _challenge = null;
    }

    if (_challenge == null) {
      _challenge = _Challenge.values[_rng.nextInt(_Challenge.values.length)];
      _challengeStartAt = now;
      _challengeDoneAt = null;
    }

    if (_challengeDoneAt != null) return null;

    final l = face.leftEyeOpenProbability ?? 1.0;
    final r = face.rightEyeOpenProbability ?? 1.0;
    final passed = switch (_challenge!) {
      _Challenge.blink => l < 0.3 && r < 0.3,
      _Challenge.smile => (face.smilingProbability ?? 0) > 0.75,
      _Challenge.turn => (face.headEulerAngleY ?? 0).abs() > 20,
    };

    if (passed) {
      _challengeDoneAt = now;
      return "Bagus! Sekarang hadap lurus ke kamera";
    }
    return _challengePrompt(_challenge!);
  }

  /// CameraImage -> deteksi wajah -> liveness -> alignment -> kualitas -> vector
  Future<FaceProcessResult> processCameraImage({
    required CameraImage cameraImage,
    required CameraDescription camera,
    bool requireLiveness = true,

    /// false = tantangan liveness tidak dihapus setelah vector diambil
    /// (dipakai kiosk untuk konfirmasi beberapa frame)
    bool consumeChallenge = true,

    /// true = hanya deteksi wajah (cepat), tanpa liveness/inferensi
    bool detectOnly = false,

    /// true = syarat pendaftaran: wajah netral, tegak, di tengah, mata terbuka lebar
    bool strict = false,
  }) async {
    final detector = _faceDetector;
    if (detector == null) {
      return FaceProcessResult(
          faceFound: false, message: "Layanan wajah belum siap");
    }

    final inputImage = _convertCameraImageToInputImage(cameraImage, camera);
    if (inputImage == null) {
      return FaceProcessResult(
          faceFound: false, message: "Format kamera tidak didukung");
    }

    // 1. Deteksi wajah
    final faces = await detector.processImage(inputImage);
    if (faces.isEmpty) {
      resetLiveness();
      return FaceProcessResult(
          faceFound: false, message: "Arahkan wajah ke dalam bingkai");
    }
    if (faces.length > 1) {
      resetLiveness();
      return FaceProcessResult(
        faceFound: true,
        message: "Terdeteksi lebih dari 1 wajah. Harap antre satu per satu.",
      );
    }
    if (detectOnly) {
      return FaceProcessResult(faceFound: true, message: "Wajah terdeteksi");
    }
    final face = faces.first;

    // 2. Ukuran wajah
    final rot = camera.sensorOrientation % 360;
    final uprightWidth =
        (rot == 90 || rot == 270) ? cameraImage.height : cameraImage.width;
    if (face.boundingBox.width <
        uprightWidth * (strict ? 0.35 : kMinFaceWidthRatio)) {
      return FaceProcessResult(
          faceFound: true, message: "Dekatkan wajah ke kamera");
    }
    if (strict) {
      final uprightHeight =
          (rot == 90 || rot == 270) ? cameraImage.width : cameraImage.height;
      final cx = face.boundingBox.center.dx / uprightWidth;
      final cy = face.boundingBox.center.dy / uprightHeight;
      if (cx < 0.35 || cx > 0.65 || cy < 0.30 || cy > 0.70) {
        return FaceProcessResult(
            faceFound: true, message: "Posisikan wajah tepat di tengah bingkai");
      }
    }

    // 3. Landmark mata (wajib untuk alignment)
    final leftEye = face.landmarks[FaceLandmarkType.leftEye]?.position;
    final rightEye = face.landmarks[FaceLandmarkType.rightEye]?.position;
    if (leftEye == null || rightEye == null) {
      return FaceProcessResult(
          faceFound: true, message: "Mata tidak terdeteksi jelas");
    }

    // 4. Liveness (tantangan acak)
    if (requireLiveness) {
      final msg = _runChallenge(face);
      if (msg != null) {
        return FaceProcessResult(faceFound: true, message: msg);
      }
    }

    // 5. Pose harus lurus
    final maxAngle = strict ? 8.0 : kMaxHeadAngle;
    if ((face.headEulerAngleY ?? 0).abs() > maxAngle ||
        (face.headEulerAngleZ ?? 0).abs() > maxAngle ||
        (face.headEulerAngleX ?? 0).abs() > (strict ? 10 : 15)) {
      return FaceProcessResult(
          faceFound: true, message: "Tatap lurus ke kamera");
    }

    // 6. Mata terbuka & ekspresi netral (agar vector konsisten)
    final lp = face.leftEyeOpenProbability ?? 1.0;
    final rp = face.rightEyeOpenProbability ?? 1.0;
    final eyeMin = strict ? 0.8 : 0.6;
    if (lp < eyeMin || rp < eyeMin) {
      return FaceProcessResult(
          faceFound: true, message: "Buka mata dan tatap kamera");
    }
    if ((face.smilingProbability ?? 0) > (strict ? 0.25 : 0.6)) {
      return FaceProcessResult(
          faceFound: true,
          message: "Wajah harus NETRAL: jangan tersenyum, mulut tertutup");
    }

    if (_interpreter == null) {
      return FaceProcessResult(faceFound: true, message: "Model AI belum siap");
    }

    // 7. Alignment + ekstraksi tensor di background isolate
    final aligned = await ImageConverter.alignFace(
      cameraImage: cameraImage,
      eyeAx: leftEye.x.toDouble(),
      eyeAy: leftEye.y.toDouble(),
      eyeBx: rightEye.x.toDouble(),
      eyeBy: rightEye.y.toDouble(),
      sensorOrientation: camera.sensorOrientation,
      inputSize: _inputSize,
    );
    if (aligned == null) {
      return FaceProcessResult(
          faceFound: true, message: "Posisi mata tidak valid, coba lagi");
    }

    // 8. Kualitas gambar
    if (aligned.brightness < kMinBrightness) {
      return FaceProcessResult(
          faceFound: true, message: "Terlalu gelap. Cari cahaya lebih terang");
    }
    if (aligned.brightness > kMaxBrightness) {
      return FaceProcessResult(
          faceFound: true, message: "Terlalu silau. Kurangi cahaya dari belakang");
    }
    if (aligned.sharpness < kMinSharpness) {
      return FaceProcessResult(
          faceFound: true, message: "Gambar buram. Diamkan wajah sejenak");
    }

    // 9. Inferensi TFLite
    final input = aligned.tensor.reshape([1, _inputSize, _inputSize, 3]);
    final output = [List<double>.filled(_vectorDimension, 0.0)];
    _interpreter!.run(input, output);

    final vector = FaceMathUtils.l2Normalize(List<double>.from(output[0]));

    if (consumeChallenge) resetLiveness(); // tantangan dipakai sekali
    return FaceProcessResult(
      faceFound: true,
      vector: vector,
      faceRgb: aligned.rgb,
      faceSize: _inputSize,
      message: "Memverifikasi identitas...",
    );
  }

  /// Android wajib NV21 (1 plane), iOS wajib BGRA8888 (1 plane).
  InputImage? _convertCameraImageToInputImage(
      CameraImage image, CameraDescription camera) {
    final rotation =
        InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null ||
        (Platform.isAndroid && format != InputImageFormat.nv21) ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) {
      return null;
    }
    if (image.planes.length != 1) return null;
    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  void dispose() {
    _faceDetector?.close();
    _interpreter?.close();
    _faceDetector = null;
    _interpreter = null;
    _initialized = false;
  }
}