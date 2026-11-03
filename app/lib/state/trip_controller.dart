import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config.dart';
import '../core/course_tracker.dart';
import '../core/geo.dart';
import '../core/heading_filter.dart';
import '../core/protocol.dart';
import '../core/send_policy.dart';
import '../data/api_client.dart';
import '../data/location_service.dart';
import '../data/realtime_client.dart';
import '../data/session.dart';

/// Server báo mất tín hiệu sau 90 giây; app dùng cùng ngưỡng để làm mờ người đó
const staleAfter = Duration(seconds: 90);

/// Trạng thái của màn hình chuyến đi: vị trí cả đoàn, hướng đi của mình, kết nối.
class TripController extends ChangeNotifier {
  TripController({
    required this.tripId,
    required this.api,
    required this.session,
    LocationService? location,
    RealtimeClient? realtime,
  })  : location = location ?? LocationService(),
        realtime = realtime ??
            RealtimeClient(wsBase: AppConfig.wsBase, tripId: tripId, getToken: session.accessToken);

  final String tripId;
  final ApiClient api;
  final Session session;
  final LocationService location;
  final RealtimeClient realtime;

  final _heading = HeadingFilter();
  final _course = CourseTracker();
  final _policy = SendPolicy();
  final _events = StreamController<TripEvent>.broadcast();
  final _subs = <StreamSubscription<Object?>>[];
  /// Tên của mọi người từng thấy, để sự kiện "rời đoàn" vẫn có tên
  final _knownNames = <String, String>{};

  TripInfo? trip;
  final Map<String, MemberState> members = {};
  Regroup? regroup;
  Position? myPosition;
  double? heading;
  ConnectionStatus connection = ConnectionStatus.connecting;
  LocationAccess? locationAccess;
  FatalReason? fatal;
  bool sharing = true;
  bool sos = false;
  int _serverOffsetMs = 0;
  bool _disposed = false;

  Stream<TripEvent> get events => _events.stream;
  String get myUid => session.userId!;
  Role get myRole => members[myUid]?.role ?? Role.member;
  bool get canSetRegroup => myRole == Role.leader || myRole == Role.sweeper;
  Iterable<MemberState> get others => members.values.where((m) => m.uid != myUid);

  /// Giờ theo đồng hồ server (bù lệch giờ của máy)
  int get serverNow => DateTime.now().millisecondsSinceEpoch + _serverOffsetMs;

  /// Vị trí của mình: ưu tiên GPS trên máy, chưa có thì lấy bản server đang giữ
  ({double lat, double lng})? get myLatLng {
    final p = myPosition;
    if (p != null) return (lat: p.latitude, lng: p.longitude);
    final s = members[myUid]?.pos;
    return s == null ? null : (lat: s.lat, lng: s.lng);
  }

  bool isStale(MemberState m) => m.pos == null || serverNow - m.pos!.ts > staleAfter.inMilliseconds;

  Duration? ageOf(MemberState m) => m.pos == null ? null : Duration(milliseconds: serverNow - m.pos!.ts);

  double? distanceTo(double lat, double lng) {
    final me = myLatLng;
    return me == null ? null : distanceM(me.lat, me.lng, lat, lng);
  }

  String nameOf(String? uid) {
    if (uid == null) return 'Ai đó';
    if (uid == myUid) return 'Bạn';
    return members[uid]?.name ?? _knownNames[uid] ?? 'Một thành viên';
  }

  Future<void> start() async {
    _subs
      ..add(realtime.messages.listen(_onMessage))
      ..add(realtime.status.listen(_onStatus))
      ..add(realtime.fatal.listen(_onFatal));
    realtime.start();
    final compass = FlutterCompass.events;
    if (compass != null) {
      _subs.add(compass.listen((e) {
        _heading.addCompass(e.heading);
        _refreshHeading();
      }, onError: (_) {}));
    }
    await WakelockPlus.enable();
    await startLocation();
  }

  /// Gọi lại sau khi người dùng cấp quyền trong Cài đặt
  Future<void> startLocation() async {
    locationAccess = await location.ensureAccess();
    _notify();
    if (locationAccess != LocationAccess.granted || _disposed) return;
    _subs.add(location.positions().listen(_onPosition, onError: (_) async {
      locationAccess = await location.ensureAccess();
      _notify();
    }));
  }

  void setSharing(bool on) {
    sharing = on;
    realtime.send({'t': 'sharing', 'on': on});
    if (on) {
      _policy.reset();
      _sendPosition();
    }
    _notify();
  }

  void setSos(bool on) {
    sos = on;
    realtime.send({'t': 'sos', 'on': on});
    _notify();
  }

  Future<void> setRegroupHere() async {
    final me = myLatLng;
    if (me == null) throw ApiException(0, 'no_location', 'Chưa có vị trí của bạn');
    await api.setRegroup(tripId, me.lat, me.lng, title: 'Điểm tập kết');
  }

  Future<void> clearRegroup() => api.clearRegroup(tripId);
  Future<void> setRole(String uid, Role role) => api.setRole(tripId, uid, role);
  Future<void> kick(String uid) => api.kick(tripId, uid);
  Future<void> leave() => api.leave(tripId);
  Future<void> endTrip() => api.endTrip(tripId);

  void _onPosition(Position p) {
    myPosition = p;
    _course.add(p.latitude, p.longitude, p.timestamp.millisecondsSinceEpoch);
    _heading.addGps(speedMs: _speedOf(p), courseDeg: _courseOf(p));
    _refreshHeading(notify: false);
    if (sharing) _sendPosition();
    _notify();
  }

  /// Tốc độ máy báo; không có thì ước lượng từ quãng đường đã đi
  double? _speedOf(Position p) => p.speed > 0 ? p.speed : _course.speedMs;

  /// Ưu tiên hướng tính từ quãng đường vừa đi: hướng máy báo có khi sai hẳn dù kèm độ chính xác
  /// trông đáng tin (đã gặp trên Android: báo ~0° ± 30° khi đang chạy về hướng đông).
  /// Chưa tính được thì mới dùng hướng máy báo.
  double? _courseOf(Position p) {
    final computed = _course.recentCourse(p.timestamp.millisecondsSinceEpoch);
    if (computed != null) return computed;
    final reliable = p.heading >= 0 && p.heading <= 360 && p.headingAccuracy > 0 && p.headingAccuracy < 45;
    return reliable ? p.heading : null;
  }

  void _sendPosition({bool force = false}) {
    final p = myPosition;
    if (p == null) return;
    final speed = _speedOf(p);
    final course = _courseOf(p);
    final pos = Pos(
      ts: p.timestamp.millisecondsSinceEpoch,
      lat: p.latitude,
      lng: p.longitude,
      acc: p.accuracy,
      spd: speed != null && speed <= 150 ? speed : null,
      // Hướng đi chỉ có nghĩa khi đang di chuyển
      hdg: speed != null && speed >= 1 ? course : null,
    );
    final now = DateTime.now();
    if (!force && !_policy.shouldSend(pos, now)) return;
    if (realtime.send(pos.toMsg())) _policy.markSent(pos, now);
  }

  void _refreshHeading({bool notify = true}) {
    final h = _heading.heading;
    if (h == null || (heading != null && (h - heading!).abs() < 0.5)) return;
    heading = h;
    if (notify) _notify();
  }

  void _onStatus(ConnectionStatus s) {
    connection = s;
    if (s == ConnectionStatus.connected) {
      // Nối lại: gửi ngay vị trí mới nhất và trạng thái SOS (SOS chỉ nằm trong RAM của server)
      _policy.reset();
      if (sharing) _sendPosition(force: true);
      if (sos) realtime.send({'t': 'sos', 'on': true});
    }
    _notify();
  }

  void _onMessage(ServerMsg msg) {
    switch (msg) {
      case SnapshotMsg():
        _serverOffsetMs = msg.serverTime - DateTime.now().millisecondsSinceEpoch;
        trip = msg.trip;
        members
          ..clear()
          ..addEntries(msg.members.map((m) => MapEntry(m.uid, m)));
        regroup = msg.regroup;
        final me = members[myUid];
        if (me != null) {
          sharing = me.sharing;
          // App mở lại khi SOS còn bật trên server: hiện đúng để người dùng tắt được.
          // Server khởi động lại thì mất SOS, còn app vẫn giữ: app đã gửi lại lúc kết nối.
          sos = sos || me.sos;
        }
      case DeltaMsg():
        _serverOffsetMs = msg.serverTime - DateTime.now().millisecondsSinceEpoch;
        for (final m in msg.members) {
          members[m.uid] = m;
        }
      case RegroupMsg():
        regroup = msg.regroup;
      case EventMsg():
        if (msg.event.type == 'trip_ended') fatal = FatalReason.ended;
        _events.add(msg.event);
    }
    for (final m in members.values) {
      _knownNames[m.uid] = m.name;
    }
    _notify();
  }

  Future<void> _onFatal(FatalReason reason) async {
    if (reason == FatalReason.removed && fatal == null) {
      // 4403 có thể do bị mời ra hoặc chuyến vừa kết thúc: hỏi lại server
      try {
        final detail = await api.trip(tripId);
        reason = detail.trip.ended ? FatalReason.ended : FatalReason.removed;
      } on ApiException {
        reason = FatalReason.removed;
      }
    }
    fatal ??= reason;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(realtime.dispose());
    unawaited(_events.close());
    unawaited(WakelockPlus.disable());
    super.dispose();
  }
}
