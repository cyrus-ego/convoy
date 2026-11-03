import 'format.dart';
import 'protocol.dart';

/// Câu thông báo cho một sự kiện. [nameOf] trả về tên (hoặc "Bạn" nếu là mình).
String? describeEvent(TripEvent e, String Function(String? uid) nameOf) {
  final who = nameOf(e.uid);
  final distance = (e.data['distanceM'] as num?)?.toDouble();
  return switch (e.type) {
    'member_joined' => '$who đã vào đoàn',
    'member_left' => e.data['kicked'] == true ? '$who đã bị mời ra khỏi đoàn' : '$who đã rời đoàn',
    'role_changed' => '$who giờ là ${Role.parse(e.data['role'] as String? ?? 'member').label.toLowerCase()}',
    'sos' => '$who bật SOS!',
    'sos_cleared' => '$who đã tắt SOS',
    'lagging' => distance == null ? '$who đang tụt lại' : '$who cách đoàn ${formatDistance(distance)}',
    'lagging_cleared' => '$who đã bám kịp đoàn',
    'stopped' => '$who đứng yên hơn 5 phút',
    'signal_lost' => '$who mất tín hiệu',
    'signal_restored' => '$who có tín hiệu trở lại',
    'trip_ended' => 'Chuyến đi đã kết thúc',
    _ => null,
  };
}

/// Sự kiện cần người lái chú ý ngay (hiện nổi bật hơn)
bool isUrgentEvent(TripEvent e) => const {'sos', 'lagging', 'signal_lost', 'stopped'}.contains(e.type);
