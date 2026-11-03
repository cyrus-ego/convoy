import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/geo.dart';
import '../core/protocol.dart';
import '../data/api_client.dart';
import '../state/trip_controller.dart';
import 'trip_map.dart' show initials, parseHex;

/// Danh sách thành viên: gần trước, xa sau, kèm hướng so với hướng mình đang đi.
class MemberSheet extends StatelessWidget {
  const MemberSheet({super.key, required this.controller, required this.onLeft});

  final TripController controller;

  /// Gọi khi mình rời chuyến hoặc kết thúc chuyến thành công
  final VoidCallback onLeft;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final me = c.myLatLng;
        final rows = c.members.values.toList()
          ..sort((a, b) {
            if (a.uid == c.myUid) return -1;
            if (b.uid == c.myUid) return 1;
            return (_distance(c, a) ?? double.infinity).compareTo(_distance(c, b) ?? double.infinity);
          });

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.95,
          builder: (context, scroll) => ListView(
            controller: scroll,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text('${c.members.length} người trong đoàn', style: Theme.of(context).textTheme.titleMedium),
              ),
              for (final m in rows) _row(context, c, m, me),
              const Divider(height: 32),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: c.myRole == Role.leader
                    ? OutlinedButton.icon(
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: const Text('Kết thúc chuyến đi'),
                        style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                        onPressed: () => _confirm(
                          context,
                          'Kết thúc chuyến đi?',
                          'Mọi người sẽ ngừng chia sẻ vị trí và không vào lại được chuyến này.',
                          'Kết thúc',
                          () async {
                            await c.endTrip();
                            onLeft();
                          },
                        ),
                      )
                    : OutlinedButton.icon(
                        icon: const Icon(Icons.logout),
                        label: const Text('Rời chuyến đi'),
                        onPressed: () => _confirm(context, 'Rời chuyến đi?', 'Đồng đội sẽ không còn thấy vị trí của bạn.', 'Rời đoàn', () async {
                          await c.leave();
                          onLeft();
                        }),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  double? _distance(TripController c, MemberState m) => m.pos == null ? null : c.distanceTo(m.pos!.lat, m.pos!.lng);

  Widget _row(BuildContext context, TripController c, MemberState m, ({double lat, double lng})? me) {
    final isMe = m.uid == c.myUid;
    final stale = c.isStale(m);
    final parts = <String>[
      if (m.role != Role.member) m.role.label,
      if (isMe) 'Bạn',
    ];
    String subtitle;
    if (!m.sharing) {
      subtitle = 'Đang tạm dừng chia sẻ vị trí';
    } else if (m.pos == null) {
      subtitle = 'Chưa có vị trí';
    } else if (isMe) {
      subtitle = 'Đang chia sẻ vị trí';
    } else {
      final d = _distance(c, m)!;
      final dir = me != null && c.heading != null
          ? ' · ${describeDirection(bearingDeg(me.lat, me.lng, m.pos!.lat, m.pos!.lng) - c.heading!)}'
          : '';
      final age = c.ageOf(m)!;
      subtitle = '${formatDistance(d)}$dir · ${stale ? 'mất sóng ${formatAge(age)}' : 'cập nhật ${formatAge(age)}'}';
    }

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: m.sos ? Colors.red : (stale && !isMe ? Colors.grey : parseHex(m.color)),
        foregroundColor: Colors.white,
        child: Text(m.sos ? 'SOS' : initials(m.name), style: TextStyle(fontSize: m.sos ? 11 : 16, fontWeight: FontWeight.w700)),
      ),
      title: Text([m.name, if (parts.isNotEmpty) '(${parts.join(', ')})'].join(' ')),
      subtitle: Text(subtitle),
      trailing: c.myRole == Role.leader && !isMe ? _leaderMenu(context, c, m) : null,
    );
  }

  Widget _leaderMenu(BuildContext context, TripController c, MemberState m) {
    return PopupMenuButton<String>(
      onSelected: (action) async {
        switch (action) {
          case 'sweeper':
            await _run(context, () => c.setRole(m.uid, Role.sweeper));
          case 'member':
            await _run(context, () => c.setRole(m.uid, Role.member));
          case 'kick':
            await _confirm(context, 'Mời ${m.name} ra khỏi đoàn?', 'Người này sẽ không vào lại được bằng mã mời cũ.', 'Mời ra', () => c.kick(m.uid));
        }
      },
      itemBuilder: (_) => [
        if (m.role != Role.sweeper) const PopupMenuItem(value: 'sweeper', child: Text('Đặt làm chốt đoàn')),
        if (m.role == Role.sweeper) const PopupMenuItem(value: 'member', child: Text('Bỏ vai trò chốt đoàn')),
        const PopupMenuItem(value: 'kick', child: Text('Mời ra khỏi đoàn')),
      ],
    );
  }

  Future<void> _confirm(BuildContext context, String title, String body, String action, Future<void> Function() run) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Thôi')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    );
    if (ok == true && context.mounted) await _run(context, run);
  }

  Future<void> _run(BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } on ApiException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}
