import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' show LatLng;

import '../config.dart';
import '../core/edge_layout.dart';
import '../core/format.dart';
import '../core/protocol.dart';
import '../state/trip_controller.dart';

/// Góc xoay bản đồ để hướng đi nằm ở đỉnh màn hình (heading-up).
double mapRotationForHeading(double heading) => -heading;

const regroupId = '__regroup__';
const _bubble = 44.0;
const _innerDot = 30.0;

/// Bản đồ luôn lấy mình làm tâm và xoay theo hướng đi.
/// [chrome] là phần màn hình bị thanh trên/dưới che: chỉ báo rìa né phần đó.
class TripMap extends StatefulWidget {
  const TripMap({super.key, required this.controller, required this.chrome, required this.onTapMember});

  final TripController controller;
  final EdgeInsets chrome;
  final void Function(String id) onTapMember;

  @override
  State<TripMap> createState() => _TripMapState();
}

class _TripMapState extends State<TripMap> {
  final _map = MapController();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_follow);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_follow);
    super.dispose();
  }

  void _follow() {
    final me = widget.controller.myLatLng;
    if (!_ready || me == null) return;
    _map.moveAndRotate(
      LatLng(me.lat, me.lng),
      _map.camera.zoom,
      mapRotationForHeading(widget.controller.heading ?? 0),
    );
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.controller.myLatLng;
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: me == null ? const LatLng(21.0285, 105.8542) : LatLng(me.lat, me.lng),
        initialZoom: 15,
        minZoom: 4,
        maxZoom: 18,
        // Chỉ cho phóng to/thu nhỏ: kéo hay xoay tay sẽ làm mình không còn ở tâm
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.pinchZoom | InteractiveFlag.doubleTapZoom | InteractiveFlag.scrollWheelZoom,
        ),
        onMapReady: () {
          _ready = true;
          _follow();
        },
        // Phóng to bằng hai ngón làm lệch tâm: kéo về lại khi thao tác xong
        onMapEvent: (e) {
          if (e is MapEventMoveEnd || e is MapEventDoubleTapZoomEnd || e is MapEventScrollWheelZoom) _follow();
        },
      ),
      children: [
        TileLayer(urlTemplate: AppConfig.tileUrl, userAgentPackageName: 'vn.bamdoan.app'),
        EdgeOverlay(controller: widget.controller, chrome: widget.chrome, onTap: widget.onTapMember),
      ],
    );
  }
}

/// Lớp vẽ đồng đội: ai trong khung nhìn thì vẽ đúng chỗ, ai ngoài khung thì ghim lên rìa
/// theo đúng hướng nhìn từ mình (xem computeEdgeLayout).
class EdgeOverlay extends StatelessWidget {
  const EdgeOverlay({super.key, required this.controller, required this.chrome, required this.onTap});

  final TripController controller;
  final EdgeInsets chrome;
  final void Function(String id) onTap;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final size = camera.nonRotatedSize;
        final me = controller.myLatLng;
        final center = me == null ? size.center(Offset.zero) : camera.latLngToScreenOffset(LatLng(me.lat, me.lng));
        // Chừa chỗ cho cả bong bóng lẫn mũi tên phía ngoài nó
        const pad = _bubble / 2 + 18;
        final frame = Rect.fromLTRB(
          chrome.left + pad,
          chrome.top + pad,
          size.width - chrome.right - pad,
          size.height - chrome.bottom - pad,
        );

        final items = <LayoutItem>[
          for (final m in controller.others)
            if (m.pos != null)
              LayoutItem(
                id: m.uid,
                screen: camera.latLngToScreenOffset(LatLng(m.pos!.lat, m.pos!.lng)),
                distanceM: controller.distanceTo(m.pos!.lat, m.pos!.lng) ?? 0,
              ),
          if (controller.regroup case final r?)
            LayoutItem(
              id: regroupId,
              screen: camera.latLngToScreenOffset(LatLng(r.lat, r.lng)),
              distanceM: controller.distanceTo(r.lat, r.lng) ?? 0,
              clusterable: false,
            ),
        ];
        final indicators = computeEdgeLayout(center: center, frame: frame, items: items);
        final bubbles = indicators.whereType<EdgeBubble>().toList();
        final looks = [for (final b in bubbles) _lookForBubble(b, controller)];
        final scaler = MediaQuery.textScalerOf(context);
        final baseStyle = DefaultTextStyle.of(context).style;
        // Người đang vẽ bên trong bản đồ: chấm + nhãn bên dưới, nhãn ở rìa phải né chỗ này
        final innerRects = [
          for (final m in indicators.whereType<InnerMarker>()) ...[
            Rect.fromCircle(center: m.position, radius: _innerDot / 2),
            () {
              final sz = _measureLabel(_lookFor(m.id, m.distanceM, controller), baseStyle, scaler);
              return Rect.fromLTWH(m.position.dx - sz.width / 2, m.position.dy + _innerDot / 2 + 4, sz.width, sz.height);
            }(),
          ],
        ];
        final labelRects = placeEdgeLabels(
          labels: [
            for (var i = 0; i < bubbles.length; i++)
              LabelRequest(
                anchor: bubbles[i].position,
                edge: edgeOf(bubbles[i].position, frame),
                size: _measureLabel(looks[i], baseStyle, scaler),
              ),
          ],
          screen: size,
          bubbleRadius: _bubble / 2,
          obstacles: innerRects,
        );

        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (final m in indicators.whereType<InnerMarker>()) _InnerMarkerView(marker: m, controller: controller, onTap: onTap),
            for (var i = 0; i < bubbles.length; i++) _EdgeBubbleView(bubble: bubbles[i], look: looks[i], onTap: onTap),
            for (var i = 0; i < bubbles.length; i++)
              // Chỉ cố định vị trí và bề rộng; chiều cao để nhãn tự co theo chữ
              Positioned(
                left: labelRects[i].left,
                top: labelRects[i].top,
                width: labelRects[i].width,
                child: _Label(look: looks[i]),
              ),
            Positioned(left: center.dx - 20, top: center.dy - 20, child: _SelfMarker(hasHeading: controller.heading != null)),
            Positioned(
              right: chrome.right + 12,
              top: chrome.top + 12,
              child: _NorthBadge(rotationRad: camera.rotationRad),
            ),
            Positioned(
              left: chrome.left + 8,
              bottom: chrome.bottom + 4,
              child: Text(AppConfig.tileAttribution, style: TextStyle(fontSize: 11, color: Colors.black.withValues(alpha: 0.6))),
            ),
          ],
        );
      },
    );
  }
}

Color parseHex(String hex) => Color(int.parse(hex.substring(1), radix: 16) | 0xFF000000);

String initials(String name) {
  final words = name.replaceAll(RegExp(r'\(.*?\)'), '').trim().split(RegExp(r'\s+'));
  final last = words.isEmpty || words.last.isEmpty ? '?' : words.last;
  return last.characters.first.toUpperCase();
}

class _Look {
  const _Look({required this.color, required this.text, required this.label, required this.sub, this.sos = false, this.square = false});
  final Color color;
  final String text;
  final String label;
  final String? sub;
  final bool sos;
  final bool square;
}

_Look _lookFor(String id, double distanceM, TripController c) {
  if (id == regroupId) {
    return _Look(
      color: const Color(0xFFBA7517),
      text: '',
      label: c.regroup?.title ?? 'Điểm tập kết',
      sub: formatDistance(distanceM),
      square: true,
    );
  }
  final m = c.members[id];
  if (m == null) return _Look(color: Colors.grey, text: '?', label: '?', sub: null);
  final stale = c.isStale(m);
  final age = c.ageOf(m);
  final role = switch (m.role) {
    Role.leader => ' (trưởng)',
    Role.sweeper => ' (chốt)',
    Role.member => '',
  };
  return _Look(
    color: stale ? Colors.grey : parseHex(m.color),
    text: initials(m.name),
    label: '${m.name}$role',
    sub: stale && age != null ? '${formatDistance(distanceM)} · mất sóng ${formatAge(age)}' : formatDistance(distanceM),
    sos: m.sos,
  );
}

_Look _lookForBubble(EdgeBubble bubble, TripController c) {
  if (!bubble.isCluster) return _lookFor(bubble.ids.first, bubble.distancesM.first, c);
  return _Look(
    color: const Color(0xFF5F5E5A),
    text: '${bubble.ids.length}',
    label: bubble.ids.map((id) => c.members[id]?.name ?? '?').join(', '),
    sub: '${formatDistance(bubble.distancesM.first)} – ${formatDistance(bubble.distancesM.last)}',
    sos: bubble.ids.any((id) => c.members[id]?.sos ?? false),
  );
}

const _titleStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black87);
const _subStyle = TextStyle(fontSize: 12, color: Colors.black54);
const _labelMaxWidth = 200.0;
const _labelPadding = EdgeInsets.symmetric(horizontal: 7, vertical: 3);

/// Kích thước nhãn khi vẽ, để xếp chỗ trước khi dựng widget.
/// Phải đo bằng đúng style mà Text dùng khi vẽ (gộp với DefaultTextStyle của theme, vốn có
/// line height riêng), nếu không nhãn thật sẽ cao/rộng hơn số đo.
Size _measureLabel(_Look look, TextStyle base, TextScaler scaler) {
  TextPainter measure(String text, TextStyle style) => TextPainter(
        text: TextSpan(text: text, style: base.merge(style)),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        textScaler: scaler,
      )..layout(maxWidth: _labelMaxWidth - _labelPadding.horizontal);
  final title = measure(look.label, _titleStyle);
  final sub = look.sub == null ? null : measure(look.sub!, _subStyle);
  return Size(
    math.min(_labelMaxWidth, math.max(title.width, sub?.width ?? 0) + _labelPadding.horizontal + 2),
    title.height + (sub?.height ?? 0) + _labelPadding.vertical,
  );
}

class _EdgeBubbleView extends StatelessWidget {
  const _EdgeBubbleView({required this.bubble, required this.look, required this.onTap});

  final EdgeBubble bubble;
  final _Look look;
  final void Function(String id) onTap;

  @override
  Widget build(BuildContext context) {
    final p = bubble.position;
    final d = bubble.direction;
    final arrowAt = p + d * (_bubble / 2 + 7);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: arrowAt.dx - 8,
          top: arrowAt.dy - 8,
          child: Transform.rotate(
            angle: math.atan2(d.dy, d.dx) + math.pi / 2,
            child: CustomPaint(size: const Size(16, 16), painter: _ArrowPainter(look.sos ? Colors.red : look.color)),
          ),
        ),
        Positioned(
          left: p.dx - _bubble / 2,
          top: p.dy - _bubble / 2,
          child: GestureDetector(onTap: () => onTap(bubble.ids.first), child: _Badge(look: look, size: _bubble)),
        ),
      ],
    );
  }
}

class _InnerMarkerView extends StatelessWidget {
  const _InnerMarkerView({required this.marker, required this.controller, required this.onTap});

  final InnerMarker marker;
  final TripController controller;
  final void Function(String id) onTap;

  @override
  Widget build(BuildContext context) {
    final look = _lookFor(marker.id, marker.distanceM, controller);
    final p = marker.position;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: p.dx - _innerDot / 2,
          top: p.dy - _innerDot / 2,
          child: GestureDetector(onTap: () => onTap(marker.id), child: _Badge(look: look, size: _innerDot)),
        ),
        Positioned(
          left: p.dx,
          top: p.dy + _innerDot / 2 + 4,
          child: FractionalTranslation(translation: const Offset(-0.5, 0), child: _Label(look: look)),
        ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.look, required this.size});
  final _Look look;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fill = look.sos ? Colors.red : Colors.white;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        shape: look.square ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: look.square ? BorderRadius.circular(8) : null,
        border: Border.all(color: look.sos ? Colors.red.shade900 : look.color, width: 3.5),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4, offset: Offset(0, 1))],
      ),
      child: look.square
          ? Icon(Icons.flag, size: size * 0.5, color: look.color)
          : Text(
              look.sos ? 'SOS' : look.text,
              style: TextStyle(
                fontSize: look.sos ? size * 0.28 : size * 0.4,
                fontWeight: FontWeight.w700,
                color: look.sos ? Colors.white : Colors.black87,
              ),
            ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label({required this.look});
  final _Look look;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: _labelMaxWidth),
      padding: _labelPadding,
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(6)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(look.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: _titleStyle),
          if (look.sub != null) Text(look.sub!, maxLines: 1, overflow: TextOverflow.ellipsis, style: _subStyle),
        ],
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  _ArrowPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.color != color;
}

/// Mình ở tâm: mũi tên luôn chỉ lên vì bản đồ đã xoay theo hướng đi
class _SelfMarker extends StatelessWidget {
  const _SelfMarker({required this.hasHeading});
  final bool hasHeading;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: hasHeading
          ? const Icon(Icons.navigation, size: 40, color: Color(0xFF1E6FD9), shadows: [Shadow(color: Colors.white, blurRadius: 6)])
          : Center(
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: const Color(0xFF1E6FD9),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                ),
              ),
            ),
    );
  }
}

/// La bàn nhỏ: cho biết hướng Bắc đang nằm phía nào khi bản đồ xoay
class _NorthBadge extends StatelessWidget {
  const _NorthBadge({required this.rotationRad});
  final double rotationRad;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.92), shape: BoxShape.circle),
      child: Transform.rotate(
        angle: rotationRad,
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.arrow_drop_up, size: 18, color: Colors.red),
            Text('B', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, height: 0.9)),
          ],
        ),
      ),
    );
  }
}
