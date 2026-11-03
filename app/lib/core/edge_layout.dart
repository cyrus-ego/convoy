import 'dart:math' as math;
import 'dart:ui';

/// Một điểm cần hiển thị, đã chiếu ra toạ độ màn hình (qua camera bản đồ).
class LayoutItem {
  const LayoutItem({required this.id, required this.screen, required this.distanceM, this.clusterable = true});

  final String id;
  final Offset screen;
  final double distanceM;

  /// Điểm tập kết không gộp chung với người.
  final bool clusterable;
}

sealed class Indicator {
  const Indicator();
}

/// Nằm trong vùng nhìn thấy: vẽ đúng vị trí trên bản đồ.
class InnerMarker extends Indicator {
  const InnerMarker({required this.id, required this.position, required this.distanceM});
  final String id;
  final Offset position;
  final double distanceM;
}

/// Ngoài vùng nhìn thấy: ghim lên rìa theo đúng hướng nhìn từ tâm.
class EdgeBubble extends Indicator {
  const EdgeBubble({required this.ids, required this.position, required this.direction, required this.distancesM});

  /// Gần trước, xa sau.
  final List<String> ids;
  final Offset position;

  /// Vector đơn vị từ tâm ra phía người đó (để vẽ mũi tên).
  final Offset direction;
  final List<double> distancesM;

  bool get isCluster => ids.length > 1;
}

/// Tính chỗ đặt chỉ báo cho từng người.
///
/// [center] là vị trí của mình trên màn hình. [frame] là hình chữ nhật đã trừ lề, safe area,
/// thanh trên và thanh dưới: chỉ báo rìa nằm trên cạnh của nó. Người nằm trong [frame] thu nhỏ
/// thêm [innerMargin] thì vẽ đúng chỗ; còn lại bắn tia từ tâm theo hướng người đó, lấy giao
/// điểm với [frame]. Tia giữ nguyên hướng nhìn từ tâm nên "dưới bên trái" vẫn là phía sau bên trái.
/// Các chỉ báo rìa cách nhau dưới [clusterRadius] thì gộp lại.
List<Indicator> computeEdgeLayout({
  required Offset center,
  required Rect frame,
  required List<LayoutItem> items,
  double innerMargin = 18,
  double clusterRadius = 40,
}) {
  final visible = frame.deflate(innerMargin);
  final result = <Indicator>[];
  final edge = <_EdgeHit>[];

  for (final item in items) {
    final d = item.screen - center;
    if (visible.contains(item.screen) || d.distance < 1e-6) {
      result.add(InnerMarker(id: item.id, position: item.screen, distanceM: item.distanceM));
      continue;
    }
    final dir = d / d.distance;
    edge.add(_EdgeHit(item, dir, _rayToFrame(center, dir, frame)));
  }

  // Gộp tham lam theo thứ tự gần trước: người gần nhất làm mốc cho nhóm
  edge.sort((a, b) => a.item.distanceM.compareTo(b.item.distanceM));
  final groups = <List<_EdgeHit>>[];
  for (final hit in edge) {
    final group = hit.item.clusterable
        ? groups.where((g) => g.first.item.clusterable && (g.first.point - hit.point).distance < clusterRadius).firstOrNull
        : null;
    if (group != null) {
      group.add(hit);
    } else {
      groups.add([hit]);
    }
  }

  for (final g in groups) {
    var sum = Offset.zero;
    for (final h in g) {
      sum += h.dir;
    }
    // Hai hướng ngược nhau cộng ra 0: lấy hướng của người gần nhất
    final dir = sum.distance < 1e-6 ? g.first.dir : sum / sum.distance;
    result.add(EdgeBubble(
      ids: [for (final h in g) h.item.id],
      position: g.length == 1 ? g.first.point : _rayToFrame(center, dir, frame),
      direction: dir,
      distancesM: [for (final h in g) h.item.distanceM],
    ));
  }
  return result;
}

/// Giao điểm của tia (center, dir) với cạnh hình chữ nhật [frame] (center nằm trong frame).
Offset _rayToFrame(Offset center, Offset dir, Rect frame) {
  var t = double.infinity;
  if (dir.dx > 0) t = math.min(t, (frame.right - center.dx) / dir.dx);
  if (dir.dx < 0) t = math.min(t, (frame.left - center.dx) / dir.dx);
  if (dir.dy > 0) t = math.min(t, (frame.bottom - center.dy) / dir.dy);
  if (dir.dy < 0) t = math.min(t, (frame.top - center.dy) / dir.dy);
  return center + dir * t;
}

class _EdgeHit {
  _EdgeHit(this.item, this.dir, this.point);
  final LayoutItem item;
  final Offset dir;
  final Offset point;
}

enum Edge { left, right, top, bottom }

/// Bong bóng nằm trên cạnh nào của [frame] (xét theo điểm chạm, không theo hướng tia:
/// màn hình dọc thì tia khá dốc vẫn chạm cạnh trái/phải).
Edge edgeOf(Offset p, Rect frame) {
  if (p.dx <= frame.left + 0.5) return Edge.left;
  if (p.dx >= frame.right - 0.5) return Edge.right;
  return p.dy <= frame.center.dy ? Edge.top : Edge.bottom;
}

class LabelRequest {
  const LabelRequest({required this.anchor, required this.edge, required this.size});

  /// Tâm bong bóng
  final Offset anchor;
  final Edge edge;
  final Size size;
}

/// Đặt nhãn cho các bong bóng rìa sao cho không đè lên nhau và không che bong bóng khác.
///
/// Rìa trái/phải: nhãn nằm cạnh bong bóng về phía trong, đụng nhau thì dời lên/xuống.
/// Rìa trên/dưới: nhãn nằm phía trong bong bóng, đụng nhau thì đẩy tiếp vào trong.
/// [labels] theo thứ tự ưu tiên (người gần trước): nhãn đặt trước giữ chỗ tốt hơn.
List<Rect> placeEdgeLabels({
  required List<LabelRequest> labels,
  required Size screen,
  required double bubbleRadius,
  /// Những thứ khác đã chiếm chỗ (người đang vẽ bên trong bản đồ và nhãn của họ)
  List<Rect> obstacles = const [],
  double gap = 6,
  int maxShifts = 6,
}) {
  final bubbles = [for (final l in labels) Rect.fromCircle(center: l.anchor, radius: bubbleRadius)];
  final placed = <Rect>[];

  for (var i = 0; i < labels.length; i++) {
    final l = labels[i];
    final w = l.size.width;
    final h = l.size.height;
    final p = l.anchor;
    var rect = switch (l.edge) {
      Edge.left => Rect.fromLTWH(p.dx + bubbleRadius + gap, p.dy - h / 2, w, h),
      Edge.right => Rect.fromLTWH(p.dx - bubbleRadius - gap - w, p.dy - h / 2, w, h),
      Edge.top => Rect.fromLTWH(p.dx - w / 2, p.dy + bubbleRadius + gap, w, h),
      Edge.bottom => Rect.fromLTWH(p.dx - w / 2, p.dy - bubbleRadius - gap - h, w, h),
    };
    rect = _clampInto(rect, screen);

    for (var shift = 0; shift < maxShifts; shift++) {
      final blocker = [...placed, ...obstacles, for (var j = 0; j < bubbles.length; j++) if (j != i) bubbles[j]]
          .where((r) => r.overlaps(rect))
          .firstOrNull;
      if (blocker == null) break;
      final step = switch (l.edge) {
        // Dời ra khỏi vật cản theo chiều dọc
        Edge.left || Edge.right => blocker.center.dy > rect.center.dy
            ? -(rect.bottom - blocker.top + gap)
            : blocker.bottom - rect.top + gap,
        Edge.top => blocker.bottom - rect.top + gap,
        Edge.bottom => -(rect.bottom - blocker.top + gap),
      };
      rect = _clampInto(rect.shift(Offset(0, step)), screen);
    }
    placed.add(rect);
  }
  return placed;
}

Rect _clampInto(Rect r, Size screen) {
  const margin = 4.0;
  final dx = r.left < margin ? margin - r.left : (r.right > screen.width - margin ? screen.width - margin - r.right : 0.0);
  final dy = r.top < margin ? margin - r.top : (r.bottom > screen.height - margin ? screen.height - margin - r.bottom : 0.0);
  return r.shift(Offset(dx, dy));
}
