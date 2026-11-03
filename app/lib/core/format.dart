/// "850 m", "1,2 km", "12 km"
String formatDistance(double meters) {
  // Làm tròn trước rồi mới chọn đơn vị: 996 m phải ra "1,0 km", không phải "1000 m"
  final rounded = (meters / 10).round() * 10;
  if (rounded < 1000) return '$rounded m';
  if (meters < 10000) return '${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
  return '${(meters / 1000).round()} km';
}

/// "vừa xong", "45 giây", "3 phút", "2 giờ"
String formatAge(Duration age) {
  if (age.inSeconds < 10) return 'vừa xong';
  if (age.inSeconds < 60) return '${age.inSeconds} giây';
  if (age.inMinutes < 60) return '${age.inMinutes} phút';
  return '${age.inHours} giờ';
}

/// Mã mời hiển thị dạng "ABCD-EF23" cho dễ đọc
String formatInviteCode(String code) =>
    code.length == 8 ? '${code.substring(0, 4)}-${code.substring(4)}' : code;

/// Mô tả hướng của người khác so với hướng mình đang đi.
/// [relativeDeg] = hướng tới người đó − hướng đi của mình.
String describeDirection(double relativeDeg) {
  final r = ((relativeDeg % 360) + 540) % 360 - 180; // về khoảng [-180, 180)
  final a = r.abs();
  final side = r >= 0 ? 'bên phải' : 'bên trái';
  if (a < 25) return 'phía trước';
  if (a > 155) return 'phía sau';
  if (a < 65) return 'phía trước $side';
  if (a > 115) return 'phía sau $side';
  return side;
}
