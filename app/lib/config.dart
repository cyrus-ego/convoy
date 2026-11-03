import 'dart:io';

/// Cấu hình qua --dart-define, ví dụ:
///   flutter run --dart-define=API_BASE=http://192.168.1.10:8080
class AppConfig {
  static const _apiBase = String.fromEnvironment('API_BASE');

  /// Mặc định cho môi trường dev: Android emulator thấy máy host qua 10.0.2.2
  static Uri get apiBase {
    if (_apiBase.isNotEmpty) return Uri.parse(_apiBase);
    return Uri.parse(Platform.isAndroid ? 'http://10.0.2.2:8080' : 'http://localhost:8080');
  }

  static Uri get wsBase => apiBase.replace(scheme: apiBase.scheme == 'https' ? 'wss' : 'ws');

  /// Tile OpenStreetMap chỉ dùng cho dev (chính sách của OSM không cho dùng tải lớn).
  /// Lên production thay bằng nhà cung cấp tile Việt Nam.
  static const tileUrl = String.fromEnvironment('TILE_URL', defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png');
  static const tileAttribution = String.fromEnvironment('TILE_ATTRIBUTION', defaultValue: '© OpenStreetMap');
}
