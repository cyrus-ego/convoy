import 'dart:math' as math;

const _earthRadiusM = 6371008.8;

double _rad(double d) => d * math.pi / 180;

/// Khoảng cách đường chim bay (haversine), mét.
double distanceM(double aLat, double aLng, double bLat, double bLng) {
  final dLat = _rad(bLat - aLat);
  final dLng = _rad(bLng - aLng);
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(_rad(aLat)) * math.cos(_rad(bLat)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * _earthRadiusM * math.asin(math.min(1, math.sqrt(h)));
}

/// Hướng từ A tới B, độ (0 = Bắc, theo chiều kim đồng hồ).
double bearingDeg(double aLat, double aLng, double bLat, double bLng) {
  final p1 = _rad(aLat);
  final p2 = _rad(bLat);
  final dl = _rad(bLng - aLng);
  final y = math.sin(dl) * math.cos(p2);
  final x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

/// Điểm cách (lat, lng) một khoảng [meters] theo hướng [bearing].
({double lat, double lng}) destination(double lat, double lng, double bearing, double meters) {
  final d = meters / _earthRadiusM;
  final t = _rad(bearing);
  final p1 = _rad(lat);
  final l1 = _rad(lng);
  final p2 = math.asin(math.sin(p1) * math.cos(d) + math.cos(p1) * math.sin(d) * math.cos(t));
  final l2 = l1 + math.atan2(math.sin(t) * math.sin(d) * math.cos(p1), math.cos(d) - math.sin(p1) * math.sin(p2));
  return (lat: p2 * 180 / math.pi, lng: ((l2 * 180 / math.pi + 540) % 360) - 180);
}
