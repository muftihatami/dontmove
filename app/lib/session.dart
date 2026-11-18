import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Penyimpanan lokal: token sesi dan sidik perangkat.
///
/// Di web, sidik perangkat hanyalah angka acak yang disimpan di browser. Itu jauh lebih lemah
/// daripada di aplikasi asli dan hanya cukup untuk uji. Anti akun ganda yang sesungguhnya
/// diuji lewat TestFlight.
class Session {
  static late SharedPreferences _p;

  static Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    if (_p.getString('device') == null) {
      final r = Random.secure();
      final hex = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await _p.setString('device', hex);
    }
  }

  static String? get token => _p.getString('token');

  static String get device => _p.getString('device')!;

  static Future<void> setToken(String? value) async {
    if (value == null) {
      await _p.remove('token');
    } else {
      await _p.setString('token', value);
    }
  }
}
