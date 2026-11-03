import 'dart:math' as math;

/// Hướng đi để xoay bản đồ (đỉnh màn hình = phía trước).
///
/// Đang chạy thì dùng hướng di chuyển của GPS: la bàn trên xe máy bị nhiễu do rung và từ trường
/// của máy xe. Đứng yên thì GPS không cho hướng, chuyển sang la bàn (nếu có).
/// Làm mượt trên vector (sin, cos) để không giật khi vượt mốc 359° → 0°.
class HeadingFilter {
  HeadingFilter({this.minCourseSpeedMs = 2.5, this.gpsAlpha = 0.5, this.compassAlpha = 0.15});

  /// ~9 km/h: chậm hơn thì hướng GPS không tin được
  final double minCourseSpeedMs;
  final double gpsAlpha;
  final double compassAlpha;

  double? _sin;
  double? _cos;
  double _lastSpeed = 0;

  double? get heading {
    final s = _sin;
    final c = _cos;
    if (s == null || c == null || (s == 0 && c == 0)) return null;
    return (math.atan2(s, c) * 180 / math.pi + 360) % 360;
  }

  bool get usingCompass => _lastSpeed < minCourseSpeedMs;

  void addGps({required double? speedMs, required double? courseDeg}) {
    _lastSpeed = speedMs ?? 0;
    if (courseDeg == null || courseDeg < 0 || _lastSpeed < minCourseSpeedMs) return;
    _blend(courseDeg, gpsAlpha);
  }

  void addCompass(double? headingDeg) {
    if (headingDeg == null || !usingCompass) return;
    _blend(headingDeg, compassAlpha);
  }

  void _blend(double deg, double alpha) {
    final r = deg * math.pi / 180;
    final s = math.sin(r);
    final c = math.cos(r);
    if (_sin == null) {
      _sin = s;
      _cos = c;
      return;
    }
    _sin = _sin! * (1 - alpha) + s * alpha;
    _cos = _cos! * (1 - alpha) + c * alpha;
  }
}
