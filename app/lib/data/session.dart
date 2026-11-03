import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Tài khoản ẩn danh theo thiết bị: giữ userId + deviceSecret trong secure storage,
/// đổi lấy access token (sống 1 giờ) khi cần.
class Session {
  Session(this.apiBase, {FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  final Uri apiBase;
  final FlutterSecureStorage _storage;

  String? userId;
  String? displayName;
  String? _deviceSecret;
  String? _token;
  DateTime? _tokenExpiresAt;
  Future<String>? _refreshing;

  bool get isRegistered => userId != null && _deviceSecret != null;

  Future<void> load() async {
    userId = await _storage.read(key: 'userId');
    _deviceSecret = await _storage.read(key: 'deviceSecret');
    displayName = await _storage.read(key: 'displayName');
  }

  Future<void> register(String name) async {
    final body = await _post('/v1/auth/anonymous', {'displayName': name});
    userId = body['userId'] as String;
    _deviceSecret = body['deviceSecret'] as String;
    displayName = name.trim();
    _setToken(body);
    await _storage.write(key: 'userId', value: userId);
    await _storage.write(key: 'deviceSecret', value: _deviceSecret);
    await _storage.write(key: 'displayName', value: displayName);
  }

  Future<String> accessToken({bool forceRefresh = false}) {
    final token = _token;
    final exp = _tokenExpiresAt;
    if (!forceRefresh && token != null && exp != null && DateTime.now().isBefore(exp.subtract(const Duration(minutes: 1)))) {
      return Future.value(token);
    }
    // Nhiều request cùng lúc chỉ đổi token một lần
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<String> _refresh() async {
    if (!isRegistered) throw StateError('Chưa đăng ký');
    final body = await _post('/v1/auth/token', {'userId': userId, 'deviceSecret': _deviceSecret});
    return _setToken(body);
  }

  String _setToken(Map<String, dynamic> body) {
    _token = body['accessToken'] as String;
    _tokenExpiresAt = DateTime.fromMillisecondsSinceEpoch((body['expiresAt'] as num).toInt());
    return _token!;
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, Object?> body) async {
    final res = await http
        .post(apiBase.resolve(path), headers: {'content-type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
    final decoded = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      throw Exception((decoded['error'] as Map?)?['message'] ?? 'Lỗi ${res.statusCode}');
    }
    return decoded;
  }
}
