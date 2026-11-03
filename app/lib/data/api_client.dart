import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/protocol.dart';
import 'session.dart';

class ApiException implements Exception {
  ApiException(this.status, this.code, this.message);
  final int status;
  final String code;
  final String message;

  @override
  String toString() => message;
}

class MemberInfo {
  const MemberInfo({required this.uid, required this.name, required this.role, required this.color});
  final String uid;
  final String name;
  final Role role;
  final String color;
}

class TripDetail {
  const TripDetail({required this.trip, required this.members, required this.myRole});
  final TripInfo trip;
  final List<MemberInfo> members;
  final Role myRole;

  factory TripDetail.fromJson(Map<String, dynamic> j) => TripDetail(
        trip: TripInfo.fromJson(j),
        members: [
          for (final m in j['members'] as List)
            MemberInfo(
              uid: m['uid'] as String,
              name: m['name'] as String,
              role: Role.parse(m['role'] as String),
              color: m['color'] as String,
            ),
        ],
        myRole: Role.parse(j['myRole'] as String),
      );
}

class ApiClient {
  ApiClient(this.session, {http.Client? client}) : _http = client ?? http.Client();

  final Session session;
  final http.Client _http;

  Future<TripDetail> createTrip(String name) async =>
      TripDetail.fromJson(await _send('POST', '/v1/trips', body: {'name': name}) as Map<String, dynamic>);

  Future<TripDetail> joinTrip(String code) async =>
      TripDetail.fromJson(await _send('POST', '/v1/trips/join', body: {'code': code}) as Map<String, dynamic>);

  Future<List<TripInfo>> myTrips() async =>
      [for (final t in await _send('GET', '/v1/trips') as List) TripInfo.fromJson(t as Map<String, dynamic>)];

  Future<TripDetail> trip(String id) async =>
      TripDetail.fromJson(await _send('GET', '/v1/trips/$id') as Map<String, dynamic>);

  Future<void> leave(String tripId) => _send('POST', '/v1/trips/$tripId/leave');

  Future<void> endTrip(String tripId) => _send('POST', '/v1/trips/$tripId/end');

  Future<void> setRole(String tripId, String uid, Role role) =>
      _send('PATCH', '/v1/trips/$tripId/members/$uid', body: {'role': role.name});

  Future<void> kick(String tripId, String uid) => _send('DELETE', '/v1/trips/$tripId/members/$uid');

  Future<void> setRegroup(String tripId, double lat, double lng, {String? title}) =>
      _send('PUT', '/v1/trips/$tripId/regroup', body: {'lat': lat, 'lng': lng, 'title': ?title});

  Future<void> clearRegroup(String tripId) => _send('DELETE', '/v1/trips/$tripId/regroup');

  Future<Object?> _send(String method, String path, {Map<String, Object?>? body, bool retried = false}) async {
    final token = await session.accessToken(forceRefresh: retried);
    final req = http.Request(method, session.apiBase.resolve(path))
      ..headers['authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 15)));
    } on TimeoutException {
      throw ApiException(0, 'timeout', 'Mạng chậm, thử lại sau');
    } on Exception {
      throw ApiException(0, 'network', 'Không kết nối được máy chủ');
    }
    if (res.statusCode == 401 && !retried) return _send(method, path, body: body, retried: true);
    final decoded = res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      final err = (decoded is Map ? decoded['error'] : null) as Map?;
      throw ApiException(res.statusCode, err?['code'] as String? ?? 'error', err?['message'] as String? ?? 'Lỗi ${res.statusCode}');
    }
    return decoded;
  }
}
