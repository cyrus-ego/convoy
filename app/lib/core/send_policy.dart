import 'geo.dart';
import 'protocol.dart';

/// Quyết định khi nào gửi vị trí lên server.
///
/// Đang chạy: tối đa mỗi [movingInterval], và chỉ khi đã đi được [minDistanceM].
/// Đứng yên: vẫn gửi mỗi [stationaryInterval] để server biết mình còn sóng
/// (server báo mất tín hiệu sau 90 giây không có vị trí mới).
class SendPolicy {
  SendPolicy({
    this.movingInterval = const Duration(seconds: 3),
    this.stationaryInterval = const Duration(seconds: 25),
    this.minDistanceM = 15,
  });

  final Duration movingInterval;
  final Duration stationaryInterval;
  final double minDistanceM;

  Pos? _last;
  DateTime? _lastAt;

  bool shouldSend(Pos candidate, DateTime now) {
    final last = _last;
    final lastAt = _lastAt;
    if (last == null || lastAt == null) return true;
    if (candidate.ts <= last.ts) return false;
    final elapsed = now.difference(lastAt);
    if (elapsed >= stationaryInterval) return true;
    return elapsed >= movingInterval && distanceM(last.lat, last.lng, candidate.lat, candidate.lng) >= minDistanceM;
  }

  void markSent(Pos pos, DateTime now) {
    _last = pos;
    _lastAt = now;
  }

  /// Sau khi kết nối lại: gửi ngay vị trí mới nhất.
  void reset() {
    _last = null;
    _lastAt = null;
  }
}
