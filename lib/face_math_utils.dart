import 'dart:math';

class FaceMathUtils {
  /// Normalisasi L2 (Wajib untuk output MobileFaceNet sebelum dibandingkan)
  static List<double> l2Normalize(List<double> vector) {
    double sumSquare = 0.0;
    for (final val in vector) {
      sumSquare += val * val;
    }
    final norm = sqrt(sumSquare);
    if (norm == 0) return vector;
    return vector.map((val) => val / norm).toList();
  }

  /// Menghitung Cosine Similarity antara 2 vector
  /// Output: -1.0 s/d 1.0 (Semakin mendekati 1.0 = semakin mirip)
  /// Threshold rekomendasi MobileFaceNet: >= 0.75 s/d 0.82
  static double cosineSimilarity(List<double> v1, List<double> v2) {
    if (v1.length != v2.length) {
      throw ArgumentError('Dimensi vector tidak sama!');
    }

    double dotProduct = 0.0;
    double normA = 0.0;
    double normB = 0.0;

    for (int i = 0; i < v1.length; i++) {
      dotProduct += v1[i] * v2[i];
      normA += v1[i] * v1[i];
      normB += v2[i] * v2[i];
    }

    if (normA == 0 || normB == 0) return 0.0;
    return dotProduct / (sqrt(normA) * sqrt(normB));
  }

  /// Menghitung Euclidean Distance antara 2 vector yang sudah di-normalisasi
  /// Output: Semakin mendekati 0.0 = semakin mirip (Threshold rekomendasi: <= 0.8)
  static double euclideanDistance(List<double> v1, List<double> v2) {
    if (v1.length != v2.length) {
      throw ArgumentError('Dimensi vector tidak sama!');
    }

    double sum = 0.0;
    for (int i = 0; i < v1.length; i++) {
      final diff = v1[i] - v2[i];
      sum += diff * diff;
    }
    return sqrt(sum);
  }
}