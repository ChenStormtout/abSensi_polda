import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

class AlignedFace {
  /// Tensor [size*size*3] ternormalisasi, siap di-reshape ke [1,size,size,3]
  final Float32List tensor;

  /// Rata-rata kecerahan 0..255
  final double brightness;

  /// Variansi Laplacian (semakin kecil = semakin buram)
  final double sharpness;

  /// Piksel RGB wajah ter-align (size*size*3)
  final Uint8List rgb;
  final int size;

  AlignedFace({
    required this.tensor,
    required this.brightness,
    required this.sharpness,
    required this.rgb,
    required this.size,
  });
}

class ImageConverter {
  // Template 5-titik standar ArcFace/MobileFaceNet untuk 112x112 (posisi mata)
  static const double _tplX1 = 38.2946;
  static const double _tplY1 = 51.6963;
  static const double _tplX2 = 73.5318;
  static const double _tplY2 = 51.5014;

  // PENTING: harus sama dengan preprocessing saat model dilatih.
  // Umumnya MobileFaceNet: (pixel - 127.5) / 128.0 (atau / 127.5).
  static const double _normOffset = 127.5;
  static const double _normScale = 128.0;

  // Ubah ke true bila model Anda dilatih dengan urutan BGR.
  static const bool _swapRB = false;

  /// Encode piksel RGB wajah menjadi JPEG kecil (dipanggil hanya saat absen berhasil).
  static Future<Uint8List> encodeJpeg(Uint8List rgb, int size) {
    final copy = Uint8List.fromList(rgb);
    return Isolate.run(() {
      final image = img.Image.fromBytes(
        width: size,
        height: size,
        bytes: copy.buffer,
        numChannels: 3,
      );
      return Uint8List.fromList(img.encodeJpg(image, quality: 75));
    });
  }

  /// Meluruskan wajah berdasarkan posisi kedua mata (rotasi + skala + translasi),
  /// lalu mengambil sampel langsung dari frame kamera mentah ke tensor.
  /// Koordinat mata ada pada ruang gambar "tegak" (setelah rotasi sensor),
  /// sama seperti koordinat yang dikembalikan ML Kit.
  /// Dijalankan di background isolate.
  static Future<AlignedFace?> alignFace({
    required CameraImage cameraImage,
    required double eyeAx,
    required double eyeAy,
    required double eyeBx,
    required double eyeBy,
    required int sensorOrientation,
    int inputSize = 112,
  }) async {
    final plane = cameraImage.planes.first;
    final bytes = Uint8List.fromList(plane.bytes);
    final stride = plane.bytesPerRow;
    final width = cameraImage.width;
    final height = cameraImage.height;
    final isBgra = cameraImage.format.group == ImageFormatGroup.bgra8888;
    final rot = sensorOrientation % 360;

    return Isolate.run<AlignedFace?>(() {
      final len = bytes.length;
      final uw = (rot == 90 || rot == 270) ? height : width;
      final uh = (rot == 90 || rot == 270) ? width : height;

      // Stride aman: bila buffer tidak cukup untuk stride yang dilaporkan, pakai width
      final needed = stride * height + (stride * height) ~/ 2;
      final effStride = (!isBgra && len < needed) ? width : stride;
      final uvStart = effStride * height;

      int rawRgb(int xr, int yr) {
        if (isBgra) {
          final i = yr * stride + xr * 4;
          if (i + 2 >= len) return 0;
          return (bytes[i + 2] << 16) | (bytes[i + 1] << 8) | bytes[i];
        }
        final yIdx = yr * effStride + xr;
        if (yIdx >= len) return 0;
        final yp = bytes[yIdx];
        final uvIndex = uvStart + (yr >> 1) * effStride + (xr & ~1);
        int vp = 0;
        int up = 0;
        if (uvIndex + 1 < len) {
          vp = bytes[uvIndex] - 128;
          up = bytes[uvIndex + 1] - 128;
        }
        final r = (yp + 1.402 * vp).round().clamp(0, 255);
        final g = (yp - 0.344136 * up - 0.714136 * vp).round().clamp(0, 255);
        final b = (yp + 1.772 * up).round().clamp(0, 255);
        return (r << 16) | (g << 8) | b;
      }

      // Koordinat tegak (upright) -> koordinat mentah sensor
      int uprightRgb(int xu, int yu) {
        xu = xu.clamp(0, uw - 1);
        yu = yu.clamp(0, uh - 1);
        int xr, yr;
        switch (rot) {
          case 90:
            xr = yu;
            yr = height - 1 - xu;
            break;
          case 180:
            xr = width - 1 - xu;
            yr = height - 1 - yu;
            break;
          case 270:
            xr = width - 1 - yu;
            yr = xu;
            break;
          default:
            xr = xu;
            yr = yu;
        }
        return rawRgb(xr.clamp(0, width - 1), yr.clamp(0, height - 1));
      }

      double bil(int p00, int p10, int p01, int p11, double fx, double fy,
          int shift) {
        final a = ((p00 >> shift) & 255).toDouble();
        final b = ((p10 >> shift) & 255).toDouble();
        final c = ((p01 >> shift) & 255).toDouble();
        final d = ((p11 >> shift) & 255).toDouble();
        return a * (1 - fx) * (1 - fy) +
            b * fx * (1 - fy) +
            c * (1 - fx) * fy +
            d * fx * fy;
      }

      // Urutkan mata: yang ada di kiri gambar = mata kiri template
      double x1 = eyeAx, y1 = eyeAy, x2 = eyeBx, y2 = eyeBy;
      if (x1 > x2) {
        final tx = x1, ty = y1;
        x1 = x2;
        y1 = y2;
        x2 = tx;
        y2 = ty;
      }

      final f = inputSize / 112.0;
      final t1x = _tplX1 * f, t1y = _tplY1 * f;
      final t2x = _tplX2 * f, t2y = _tplY2 * f;

      final tvx = t2x - t1x, tvy = t2y - t1y;
      final evx = x2 - x1, evy = y2 - y1;
      final tLen = math.sqrt(tvx * tvx + tvy * tvy);
      final eLen = math.sqrt(evx * evx + evy * evy);
      if (eLen < 8) return null; // mata terlalu berdekatan / tidak valid

      final s = eLen / tLen;
      final theta = math.atan2(evy, evx) - math.atan2(tvy, tvx);
      final cosT = math.cos(theta), sinT = math.sin(theta);

      final n = inputSize * inputSize;
      final tensor = Float32List(n * 3);
      final rgb = Uint8List(n * 3);
      final gray = Uint8List(n);
      double sumGray = 0;

      for (int v = 0; v < inputSize; v++) {
        for (int u = 0; u < inputSize; u++) {
          final dx = u - t1x, dy = v - t1y;
          final sx = (dx * cosT - dy * sinT) * s + x1;
          final sy = (dx * sinT + dy * cosT) * s + y1;

          final x0 = sx.floor(), y0 = sy.floor();
          final fx = sx - x0, fy = sy - y0;
          final p00 = uprightRgb(x0, y0);
          final p10 = uprightRgb(x0 + 1, y0);
          final p01 = uprightRgb(x0, y0 + 1);
          final p11 = uprightRgb(x0 + 1, y0 + 1);

          final r = bil(p00, p10, p01, p11, fx, fy, 16).round().clamp(0, 255);
          final g = bil(p00, p10, p01, p11, fx, fy, 8).round().clamp(0, 255);
          final b = bil(p00, p10, p01, p11, fx, fy, 0).round().clamp(0, 255);

          final idx = v * inputSize + u;
          rgb[idx * 3] = r;
          rgb[idx * 3 + 1] = g;
          rgb[idx * 3 + 2] = b;

          final c0 = _swapRB ? b : r;
          final c2 = _swapRB ? r : b;
          tensor[idx * 3] = (c0 - _normOffset) / _normScale;
          tensor[idx * 3 + 1] = (g - _normOffset) / _normScale;
          tensor[idx * 3 + 2] = (c2 - _normOffset) / _normScale;

          final gv = (0.299 * r + 0.587 * g + 0.114 * b).round();
          gray[idx] = gv;
          sumGray += gv;
        }
      }

      final brightness = sumGray / n;

      // Ketajaman: variansi Laplacian
      double lapSum = 0, lapSumSq = 0;
      int lapN = 0;
      for (int y = 1; y < inputSize - 1; y++) {
        for (int x = 1; x < inputSize - 1; x++) {
          final i = y * inputSize + x;
          final lap = 4 * gray[i] -
              gray[i - 1] -
              gray[i + 1] -
              gray[i - inputSize] -
              gray[i + inputSize];
          lapSum += lap;
          lapSumSq += lap * lap;
          lapN++;
        }
      }
      final mean = lapSum / lapN;
      final sharpness = lapSumSq / lapN - mean * mean;

      return AlignedFace(
        tensor: tensor,
        brightness: brightness,
        sharpness: sharpness,
        rgb: rgb,
        size: inputSize,
      );
    });
  }
}
