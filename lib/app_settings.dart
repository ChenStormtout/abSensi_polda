import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:shared_preferences/shared_preferences.dart';

/// Pengaturan aplikasi (disimpan lokal). PIN disimpan sebagai hash + salt.
class AppSettings {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  static const String defaultPin = '123456';
  late SharedPreferences _p;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    if (_p.getString('pin_hash') == null) {
      await setPin(defaultPin);
    }
  }

  // ---------------- Pengenalan wajah ----------------
  /// Ambang kemiripan minimal. Kalibrasi lewat menu "Uji Pengenalan".
  double get matchThreshold => _p.getDouble('match_threshold') ?? 0.70;
  Future<void> setMatchThreshold(double v) =>
      _p.setDouble('match_threshold', v);

  /// Selisih minimal antara kandidat terbaik dan kandidat kedua.
  double get matchMargin => _p.getDouble('match_margin') ?? 0.05;
  Future<void> setMatchMargin(double v) => _p.setDouble('match_margin', v);

  bool get requireLiveness => _p.getBool('require_liveness') ?? true;
  Future<void> setRequireLiveness(bool v) =>
      _p.setBool('require_liveness', v);

  // ---------------- Jam kerja ----------------
  /// Lewat jam ini, absen MASUK dicatat TERLAMBAT.
  TimeOfDay get lateTime => TimeOfDay(
        hour: _p.getInt('late_hour') ?? 7,
        minute: _p.getInt('late_minute') ?? 30,
      );
  Future<void> setLateTime(TimeOfDay t) async {
    await _p.setInt('late_hour', t.hour);
    await _p.setInt('late_minute', t.minute);
  }

  /// Sebelum jam ini default MASUK, sesudahnya default PULANG.
  int get switchHour => _p.getInt('switch_hour') ?? 12;
  Future<void> setSwitchHour(int h) => _p.setInt('switch_hour', h);

  /// Batas jam paling awal absen PULANG diterima di kiosk (bila diaktifkan).
  bool get pulangLimitEnabled => _p.getBool('pulang_limit_enabled') ?? false;
  Future<void> setPulangLimitEnabled(bool v) =>
      _p.setBool('pulang_limit_enabled', v);

  TimeOfDay get pulangEarliest => TimeOfDay(
        hour: _p.getInt('pulang_hour') ?? 15,
        minute: _p.getInt('pulang_minute') ?? 0,
      );
  Future<void> setPulangEarliest(TimeOfDay t) async {
    await _p.setInt('pulang_hour', t.hour);
    await _p.setInt('pulang_minute', t.minute);
  }

  // ---------------- PIN admin ----------------
  String _hash(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  Future<void> setPin(String pin) async {
    final rnd = Random.secure();
    final salt =
        base64Url.encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
    await _p.setString('pin_salt', salt);
    await _p.setString('pin_hash', _hash(pin, salt));
  }

  bool verifyPin(String pin) {
    final salt = _p.getString('pin_salt') ?? '';
    return _hash(pin, salt) == _p.getString('pin_hash');
  }

  bool get isDefaultPin => verifyPin(defaultPin);

  // ---------------- Proteksi jam perangkat ----------------
  /// True bila jam perangkat mundur dibanding catatan terakhir (indikasi diubah).
  bool isClockTampered(DateTime now) {
    final last = _p.getInt('last_seen_ms');
    return last != null && now.millisecondsSinceEpoch < last - 120000;
  }

  Future<void> touchClock(DateTime now) async {
    final last = _p.getInt('last_seen_ms') ?? 0;
    if (now.millisecondsSinceEpoch > last) {
      await _p.setInt('last_seen_ms', now.millisecondsSinceEpoch);
    }
  }
}