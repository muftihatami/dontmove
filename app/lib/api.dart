import 'dart:convert';

import 'package:http/http.dart' as http;

import 'session.dart';

class ApiError implements Exception {
  ApiError(this.status, this.code, this.message, [this.retryAt]);

  final int status;
  final String code;
  final String message;
  final DateTime? retryAt;

  @override
  String toString() => message;
}

typedef Json = Map<String, dynamic>;

/// Klien HTTP untuk Layanan Identitas (/identity) dan Layanan Konten (/api).
/// Di web uji, keduanya berada di alamat yang sama dengan halaman (lihat demo/Caddyfile).
class Api {
  static const _envBase = String.fromEnvironment('API_BASE');

  static String get base => _envBase.isNotEmpty ? _envBase : Uri.base.origin;

  /// Dipanggil saat token ditolak, supaya aplikasi kembali ke layar pembuka.
  static void Function()? onUnauthorized;

  static Future<dynamic> _call(String method, String path, {Object? body, bool auth = true}) async {
    final req = http.Request(method, Uri.parse('$base$path'));
    req.headers['Content-Type'] = 'application/json';
    final token = Session.token;
    if (auth && token != null) {
      req.headers['Authorization'] = 'Bearer $token';
    }
    if (body != null) {
      req.body = jsonEncode(body);
    }
    http.Response res;
    try {
      res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 20)));
    } catch (_) {
      throw ApiError(0, 'network', 'Tidak bisa terhubung ke server. Periksa koneksi lalu coba lagi.');
    }
    dynamic data;
    if (res.bodyBytes.isNotEmpty) {
      try {
        data = jsonDecode(utf8.decode(res.bodyBytes));
      } catch (_) {
        data = null;
      }
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return data;
    }
    final m = data is Map<String, dynamic> ? data : <String, dynamic>{};
    if (res.statusCode == 401 && auth) {
      onUnauthorized?.call();
    }
    final retry = m['retry_at'];
    throw ApiError(
      res.statusCode,
      (m['code'] as String?) ?? 'error',
      (m['message'] as String?) ?? 'Terjadi kesalahan. Coba lagi sebentar lagi.',
      retry is String ? DateTime.tryParse(retry) : null,
    );
  }

  // ---------- Identitas ----------

  static Future<String> otpStart(String channel, String destination) async {
    final d = await _call('POST', '/identity/v1/otp/start',
        body: {'channel': channel, 'destination': destination}, auth: false) as Json;
    return d['challenge_id'] as String;
  }

  static Future<void> otpVerify(String challengeId, String code) async {
    await _call('POST', '/identity/v1/otp/verify', body: {'challenge_id': challengeId, 'code': code}, auth: false);
  }

  static Future<String> register({
    required String emailChallenge,
    required String email,
    required String phoneChallenge,
    required String phone,
    required String birthDate,
  }) async {
    final d = await _call('POST', '/identity/v1/register', auth: false, body: {
      'email_challenge_id': emailChallenge,
      'email': email,
      'phone_challenge_id': phoneChallenge,
      'phone': phone,
      'birth_date': birthDate,
      'device_fingerprint': Session.device,
    }) as Json;
    return d['token'] as String;
  }

  static Future<String> login({required String phoneChallenge, required String phone}) async {
    final d = await _call('POST', '/identity/v1/login', auth: false, body: {
      'challenge_id': phoneChallenge,
      'channel': 'phone',
      'destination': phone,
      'device_fingerprint': Session.device,
    }) as Json;
    return d['token'] as String;
  }

  // ---------- Konten ----------

  static Future<Json> feed(String tab, {String cursor = ''}) async =>
      await _call('GET', '/api/v1/feed?tab=$tab&limit=20&cursor=${Uri.encodeQueryComponent(cursor)}') as Json;

  static Future<Json> quota() async => await _call('GET', '/api/v1/quota') as Json;

  static Future<Json> createThread(String body) async =>
      await _call('POST', '/api/v1/threads', body: {'body': body}) as Json;

  static Future<Json> getThread(String id) async => await _call('GET', '/api/v1/threads/$id') as Json;

  static Future<void> deleteThread(String id) async {
    await _call('DELETE', '/api/v1/threads/$id');
  }

  static Future<Json> createComment(String threadId, String body, {String? parentId}) async =>
      await _call('POST', '/api/v1/threads/$threadId/comments',
          body: {'body': body, if (parentId != null) 'parent_id': parentId}) as Json;

  static Future<void> deleteComment(String id) async {
    await _call('DELETE', '/api/v1/comments/$id');
  }

  static Future<void> deleteAccount() async {
    await _call('POST', '/api/v1/account/delete');
  }
}
