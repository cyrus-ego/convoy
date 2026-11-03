import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/event_text.dart';
import '../core/format.dart';
import '../core/protocol.dart';
import '../data/api_client.dart';
import '../data/location_service.dart';
import '../data/realtime_client.dart';
import '../data/session.dart';
import '../state/trip_controller.dart';
import 'member_sheet.dart';
import 'trip_map.dart';
import 'widgets/sos_button.dart';

const _topBarHeight = 64.0;
const _bottomBarHeight = 92.0;

class TripScreen extends StatefulWidget {
  const TripScreen({super.key, required this.tripId, required this.api, required this.session});

  final String tripId;
  final ApiClient api;
  final Session session;

  @override
  State<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends State<TripScreen> with WidgetsBindingObserver {
  late final TripController _c;
  StreamSubscription<TripEvent>? _eventSub;
  bool _fatalShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _c = TripController(tripId: widget.tripId, api: widget.api, session: widget.session);
    _eventSub = _c.events.listen(_showEvent);
    _c.addListener(_checkFatal);
    unawaited(_c.start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_eventSub?.cancel());
    _c.removeListener(_checkFatal);
    _c.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Quay lại app: nối lại ngay thay vì chờ hết thời gian backoff
    if (state == AppLifecycleState.resumed) _c.realtime.reconnectNow();
  }

  void _showEvent(TripEvent e) {
    // Sự kiện của chính mình thì không cần báo (trừ khi bị coi là tụt lại)
    if (e.uid == _c.myUid && e.type != 'lagging') return;
    final text = describeEvent(e, _c.nameOf);
    if (text == null || !mounted) return;
    final urgent = isUrgentEvent(e);
    if (urgent) HapticFeedback.heavyImpact();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        backgroundColor: urgent ? Colors.red.shade700 : null,
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(bottom: _bottomBarHeight + MediaQuery.paddingOf(context).bottom + 8, left: 12, right: 12),
        duration: Duration(seconds: urgent ? 8 : 4),
      ));
  }

  void _checkFatal() {
    final reason = _c.fatal;
    if (reason == null || _fatalShown || !mounted) return;
    _fatalShown = true;
    final text = switch (reason) {
      FatalReason.ended => 'Chuyến đi đã kết thúc.',
      FatalReason.removed => 'Bạn không còn ở trong đoàn này.',
      FatalReason.notFound => 'Không tìm thấy chuyến đi.',
    };
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: Text(text),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Về trang chính'))],
      ),
    ).then((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  void _openMembers() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => MemberSheet(
        controller: _c,
        onLeft: () {
          _fatalShown = true;
          Navigator.of(context)
            ..pop()
            ..pop();
        },
      ),
    );
  }

  void _showInvite() {
    final code = _c.trip?.inviteCode;
    if (code == null) return;
    showInviteDialog(context, code);
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final chrome = EdgeInsets.only(top: pad.top + _topBarHeight, bottom: pad.bottom + _bottomBarHeight);
    return Scaffold(
      body: ListenableBuilder(
        listenable: _c,
        builder: (context, _) => Stack(
          children: [
            Positioned.fill(child: TripMap(controller: _c, chrome: chrome, onTapMember: (_) => _openMembers())),
            Positioned(top: 0, left: 0, right: 0, child: _topBar(context, pad)),
            if (_sosMembers().isNotEmpty) Positioned(top: chrome.top + 8, left: 12, right: 64, child: _sosBanner()),
            if (_c.locationAccess != null && _c.locationAccess != LocationAccess.granted)
              Positioned(top: chrome.top + 8, left: 12, right: 64, child: _locationBanner()),
            Positioned(bottom: 0, left: 0, right: 0, child: _bottomBar(context, pad)),
          ],
        ),
      ),
    );
  }

  List<MemberState> _sosMembers() => _c.others.where((m) => m.sos).toList();

  Widget _topBar(BuildContext context, EdgeInsets pad) {
    final (dot, status) = switch (_c.connection) {
      ConnectionStatus.connected => (Colors.green, '${_c.members.length} người'),
      ConnectionStatus.connecting => (Colors.amber, 'Đang kết nối…'),
      ConnectionStatus.disconnected => (Colors.red, 'Mất kết nối, đang thử lại'),
    };
    return Container(
      padding: EdgeInsets.only(top: pad.top, left: 4, right: 8),
      height: pad.top + _topBarHeight,
      color: Colors.white.withValues(alpha: 0.95),
      child: Row(
        children: [
          IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_c.trip?.name ?? 'Chuyến đi', style: Theme.of(context).textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                Row(children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Text(status, style: Theme.of(context).textTheme.bodySmall),
                ]),
              ],
            ),
          ),
          IconButton(tooltip: 'Mời bạn', icon: const Icon(Icons.person_add_alt_1), onPressed: _showInvite),
        ],
      ),
    );
  }

  Widget _sosBanner() {
    final names = _sosMembers().map((m) {
      final d = m.pos == null ? null : _c.distanceTo(m.pos!.lat, m.pos!.lng);
      return d == null ? m.name : '${m.name} (${formatDistance(d)})';
    }).join(', ');
    return Material(
      color: Colors.red.shade700,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          const Icon(Icons.sos, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(child: Text('$names đang cần trợ giúp', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
        ]),
      ),
    );
  }

  Widget _locationBanner() {
    final text = switch (_c.locationAccess) {
      LocationAccess.serviceDisabled => 'Định vị đang tắt. Bật định vị để đồng đội thấy bạn.',
      _ => 'Chưa có quyền vị trí. Đồng đội sẽ không thấy bạn.',
    };
    return Material(
      color: Colors.amber.shade100,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(children: [
          Expanded(child: Text(text)),
          TextButton(
            onPressed: () async {
              await _c.location.openSettings();
              await _c.startLocation();
            },
            child: const Text('Mở cài đặt'),
          ),
        ]),
      ),
    );
  }

  Widget _bottomBar(BuildContext context, EdgeInsets pad) {
    final hasRegroup = _c.regroup != null;
    return Container(
      padding: EdgeInsets.only(bottom: pad.bottom, left: 8, right: 8, top: 8),
      height: pad.bottom + _bottomBarHeight,
      color: Colors.white.withValues(alpha: 0.95),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _BarButton(icon: Icons.groups, label: 'Đoàn (${_c.members.length})', onTap: _openMembers),
          _BarButton(
            icon: _c.sharing ? Icons.location_on : Icons.location_off,
            label: _c.sharing ? 'Đang chia sẻ' : 'Đã tạm dừng',
            color: _c.sharing ? null : Colors.orange.shade800,
            onTap: () => _c.setSharing(!_c.sharing),
          ),
          SosButton(active: _c.sos, onChanged: _c.setSos),
          if (_c.canSetRegroup)
            _BarButton(
              icon: hasRegroup ? Icons.flag_outlined : Icons.flag,
              label: hasRegroup ? 'Bỏ tập kết' : 'Tập kết ở đây',
              onTap: () => _run(hasRegroup ? _c.clearRegroup : _c.setRegroupHere),
            ),
        ],
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({required this.icon, required this.label, required this.onTap, this.color});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 84,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 28, color: color),
            const SizedBox(height: 4),
            Text(label, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: color)),
          ],
        ),
      ),
    );
  }
}

Future<void> showInviteDialog(BuildContext context, String code) {
  final shown = formatInviteCode(code);
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Mời bạn vào đoàn'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Gửi mã này cho bạn đồng hành. Họ mở app, chọn "Vào đoàn bằng mã" rồi nhập mã.'),
          const SizedBox(height: 20),
          SelectableText(shown, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: 3)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: shown));
            Navigator.pop(ctx);
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã chép mã mời')));
          },
          child: const Text('Chép mã'),
        ),
        FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Xong')),
      ],
    ),
  );
}
