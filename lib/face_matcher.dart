import 'database_helper.dart';
import 'face_math_utils.dart';

class MatchResult {
  final UserModel? best;
  final double bestScore;

  /// Skor terbaik dari personel LAIN (bukan yang terbaik)
  final double secondScore;

  const MatchResult(this.best, this.bestScore, this.secondScore);

  double get margin => bestScore - secondScore;

  bool passesThreshold(double threshold) =>
      best != null && bestScore >= threshold;

  bool accepts(double threshold, double minMargin) =>
      passesThreshold(threshold) && margin >= minMargin;
}

class FaceMatcher {
  static MatchResult match(List<double> live, List<UserModel> users) {
    UserModel? bestUser;
    double best = -1.0;
    double second = -1.0;

    for (final user in users) {
      double userBest = -1.0;
      for (final sample in user.faceVectors) {
        if (sample.length != live.length) continue;
        final s = FaceMathUtils.cosineSimilarity(live, sample);
        if (s > userBest) userBest = s;
      }
      if (userBest > best) {
        second = best;
        best = userBest;
        bestUser = user;
      } else if (userBest > second) {
        second = userBest;
      }
    }
    return MatchResult(bestUser, best, second);
  }
}
