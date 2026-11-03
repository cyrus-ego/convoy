import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../core/protocol.dart';

enum ConnectionStatus { connecting, connected, disconnected }

/// Lý do kết nối bị dừng hẳn (không thử lại nữa).
enum FatalReason { removed, notFound, ended }

/// WebSocket tới phòng của một chuyến đi, tự kết nối lại với backoff.
///
/// Vùng núi mất sóng liên tục nên kết nối lại là chuyện thường: mỗi lần nối lại
/// server gửi snapshot mới, client chỉ cần thay toàn bộ trạng thái.
class RealtimeClient {
  RealtimeClient({required this.wsBase, required this.tripId, required this.getToken});

  final Uri wsBase;
  final String tripId;
  final Future<String> Function({bool forceRefresh}) getToken;

  final _messages = StreamController<ServerMsg>.broadcast();
  final _status = StreamController<ConnectionStatus>.broadcast();
  final _fatal = StreamController<FatalReason>.broadcast();
  final _random = math.Random();

  WebSocket? _socket;
  bool _running = false;
  int _attempt = 0;
  Timer? _retryTimer;
  ConnectionStatus _current = ConnectionStatus.disconnected;

  Stream<ServerMsg> get messages => _messages.stream;
  Stream<ConnectionStatus> get status => _status.stream;
  Stream<FatalReason> get fatal => _fatal.stream;
  ConnectionStatus get currentStatus => _current;

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_connect());
  }

  Future<void> stop() async {
    _running = false;
    _retryTimer?.cancel();
    await _socket?.close(1000);
    _socket = null;
    _setStatus(ConnectionStatus.disconnected);
  }

  Future<void> dispose() async {
    await stop();
    await _messages.close();
    await _status.close();
    await _fatal.close();
  }

  /// Gửi nếu đang kết nối; mất kết nối thì bỏ (vị trí mới nhất sẽ được gửi lại khi nối lại).
  bool send(Map<String, Object?> msg) {
    final s = _socket;
    if (s == null || _current != ConnectionStatus.connected) return false;
    s.add(jsonEncode(msg));
    return true;
  }

  Future<void> _connect({bool refreshToken = false}) async {
    if (!_running) return;
    _setStatus(ConnectionStatus.connecting);
    try {
      final token = await getToken(forceRefresh: refreshToken);
      final uri = wsBase.replace(path: '/v1/ws', queryParameters: {'trip': tripId});
      final socket = await WebSocket.connect(uri.toString(), headers: {'authorization': 'Bearer $token'})
          .timeout(const Duration(seconds: 15));
      if (!_running) {
        await socket.close(1000);
        return;
      }
      socket.pingInterval = const Duration(seconds: 20);
      _socket = socket;
      _attempt = 0;
      _setStatus(ConnectionStatus.connected);
      socket.listen(
        (data) {
          if (data is! String) return;
          final msg = ServerMsg.tryParse(jsonDecode(data) as Map<String, dynamic>);
          if (msg != null) _messages.add(msg);
        },
        onDone: () => _onClosed(socket.closeCode),
        onError: (_) {},
        cancelOnError: false,
      );
    } on WebSocketException catch (e) {
      // Server từ chối nâng cấp: đọc HTTP status trong thông báo lỗi
      final status = int.tryParse(RegExp(r'status code: (\d+)').firstMatch(e.message)?.group(1) ?? '');
      if (status == 401 && !refreshToken) return _connect(refreshToken: true);
      if (status == 404) return _stopFatal(FatalReason.notFound);
      if (status == 409) return _stopFatal(FatalReason.ended);
      _scheduleRetry();
    } on Object {
      _scheduleRetry();
    }
  }

  void _onClosed(int? code) {
    _socket = null;
    if (!_running) return;
    // 4403: bị mời ra hoặc chuyến kết thúc. Kiểm lại qua REST để phân biệt.
    if (code == 4403) return _stopFatal(FatalReason.removed);
    _setStatus(ConnectionStatus.disconnected);
    _scheduleRetry();
  }

  void _stopFatal(FatalReason reason) {
    _running = false;
    _setStatus(ConnectionStatus.disconnected);
    _fatal.add(reason);
  }

  void _scheduleRetry() {
    if (!_running) return;
    _setStatus(ConnectionStatus.disconnected);
    // 1, 2, 4, 8, 16, 30 giây, cộng nhiễu ngẫu nhiên để cả đoàn không cùng nối lại một lúc
    final base = math.min(30, math.pow(2, _attempt).toInt());
    _attempt = math.min(_attempt + 1, 5);
    final delay = Duration(milliseconds: (base * 1000 * (0.75 + _random.nextDouble() * 0.5)).round());
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () => unawaited(_connect()));
  }

  /// Gọi khi mạng có lại (hoặc app quay lại foreground): nối lại ngay, không chờ backoff.
  void reconnectNow() {
    if (!_running || _current != ConnectionStatus.disconnected) return;
    _retryTimer?.cancel();
    _attempt = 0;
    unawaited(_connect());
  }

  void _setStatus(ConnectionStatus s) {
    if (_current == s) return;
    _current = s;
    if (!_status.isClosed) _status.add(s);
  }
}
