import 'geo.dart';

/// Ước lượng hướng đi và tốc độ từ chính các điểm GPS.
///
/// Nhiều máy (và emulator) trả heading = 0 khi không biết hướng, không phân biệt được với
/// "đang đi về hướng Bắc". Lấy hai điểm cách nhau đủ xa thì hướng đi luôn đáng tin.
class CourseTracker {
  CourseTracker({this.minDistanceM = 15, this.maxWindow = const Duration(seconds: 30)});

  /// Đi được ít nhất chừng này mới tính hướng (nhỏ hơn thì nhiễu GPS lấn át)
  final double minDistanceM;

  /// Đứng yên quá lâu thì dời mốc, để tốc độ ước lượng về gần 0
  final Duration maxWindow;

  ({double lat, double lng, int ts})? _anchor;
  double? course;
  double? speedMs;

  /// Thời điểm (ms) tính ra [course] gần nhất
  int? courseTs;

  /// Hướng tính được trong khoảng [maxAge] gần đây, không thì null
  double? recentCourse(int nowTs, {Duration maxAge = const Duration(seconds: 10)}) {
    final at = courseTs;
    return at != null && nowTs - at <= maxAge.inMilliseconds ? course : null;
  }

  void add(double lat, double lng, int ts) {
    final a = _anchor;
    if (a == null || ts <= a.ts) {
      _anchor ??= (lat: lat, lng: lng, ts: ts);
      return;
    }
    final d = distanceM(a.lat, a.lng, lat, lng);
    final dt = (ts - a.ts) / 1000;
    if (d >= minDistanceM) {
      course = bearingDeg(a.lat, a.lng, lat, lng);
      courseTs = ts;
      speedMs = d / dt;
      _anchor = (lat: lat, lng: lng, ts: ts);
    } else if (dt * 1000 >= maxWindow.inMilliseconds) {
      speedMs = d / dt;
      _anchor = (lat: lat, lng: lng, ts: ts);
    }
  }
}
