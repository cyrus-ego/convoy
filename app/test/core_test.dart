import 'dart:convert';
import 'dart:ui';

import 'package:convoy/core/course_tracker.dart';
import 'package:convoy/core/edge_layout.dart';
import 'package:convoy/core/format.dart';
import 'package:convoy/core/geo.dart';
import 'package:convoy/core/heading_filter.dart';
import 'package:convoy/core/protocol.dart';
import 'package:convoy/core/send_policy.dart';
import 'package:convoy/ui/trip_map.dart' show mapRotationForHeading;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  const hn = (lat: 21.0285, lng: 105.8542);

  group('geo', () {
    test('khoảng cách và hướng khớp với destination', () {
      final p = destination(hn.lat, hn.lng, 135, 2500);
      expect(distanceM(hn.lat, hn.lng, p.lat, p.lng), closeTo(2500, 1));
      expect(bearingDeg(hn.lat, hn.lng, p.lat, p.lng), closeTo(135, 0.1));
    });
  });

  group('computeEdgeLayout', () {
    // Màn hình 400x800, khung chỉ báo cách mép 20 px
    const center = Offset(200, 400);
    final frame = Rect.fromLTRB(20, 20, 380, 780);

    LayoutItem item(String id, Offset screen, double d, {bool clusterable = true}) =>
        LayoutItem(id: id, screen: screen, distanceM: d, clusterable: clusterable);

    test('trong khung thì vẽ đúng chỗ', () {
      final out = computeEdgeLayout(center: center, frame: frame, items: [item('a', const Offset(250, 300), 100)]);
      expect(out.single, isA<InnerMarker>());
      expect((out.single as InnerMarker).position, const Offset(250, 300));
    });

    test('ngoài khung thì nằm trên cạnh, giữ đúng hướng nhìn từ tâm', () {
      final cases = {
        const Offset(200, -5000): const Offset(200, 20), // thẳng phía trước → cạnh trên
        const Offset(200, 9000): const Offset(200, 780), // phía sau → cạnh dưới
        const Offset(5000, 400): const Offset(380, 400), // bên phải → cạnh phải
        const Offset(-3000, 400): const Offset(20, 400), // bên trái → cạnh trái
      };
      cases.forEach((screen, expected) {
        final b = computeEdgeLayout(center: center, frame: frame, items: [item('a', screen, 5000)]).single as EdgeBubble;
        expect(b.position.dx, closeTo(expected.dx, 1e-6));
        expect(b.position.dy, closeTo(expected.dy, 1e-6));
      });

      // Chéo phía trước bên phải: điểm trên rìa phải thẳng hàng với tâm và người đó
      const far = Offset(1200, -600);
      final b = computeEdgeLayout(center: center, frame: frame, items: [item('a', far, 5000)]).single as EdgeBubble;
      final want = (far - center) / (far - center).distance;
      final got = (b.position - center) / (b.position - center).distance;
      expect((want - got).distance, lessThan(1e-9));
      expect(b.position.dx, closeTo(380, 1e-6)); // chạm cạnh phải trước cạnh trên
    });

    test('nhiều người cùng hướng thì gộp, người gần đứng đầu', () {
      final out = computeEdgeLayout(
        center: center,
        frame: frame,
        items: [
          item('xa', const Offset(205, 9000), 3000),
          item('gan', const Offset(198, 5000), 800),
          item('ngang', const Offset(5000, 400), 2000),
        ],
      );
      final bubbles = out.whereType<EdgeBubble>().toList();
      expect(bubbles, hasLength(2));
      final cluster = bubbles.firstWhere((b) => b.isCluster);
      expect(cluster.ids, ['gan', 'xa']);
      expect(cluster.distancesM, [800, 3000]);
      expect(cluster.position.dy, closeTo(780, 1e-6));
    });

    test('điểm tập kết không bị gộp với người', () {
      final out = computeEdgeLayout(
        center: center,
        frame: frame,
        items: [item('a', const Offset(200, -5000), 900), item('regroup', const Offset(201, -6000), 1000, clusterable: false)],
      );
      expect(out.whereType<EdgeBubble>().every((b) => !b.isCluster), isTrue);
    });
  });

  group('placeEdgeLabels', () {
    const screen = Size(400, 800);
    const r = 22.0;
    bool anyOverlap(List<Rect> rects, List<Offset> bubbles) {
      for (var i = 0; i < rects.length; i++) {
        for (var j = 0; j < rects.length; j++) {
          if (i != j && rects[i].overlaps(rects[j])) return true;
        }
        for (var j = 0; j < bubbles.length; j++) {
          if (i != j && rects[i].overlaps(Rect.fromCircle(center: bubbles[j], radius: r))) return true;
        }
      }
      return false;
    }

    test('ba người dồn về rìa trái: nhãn không đè nhau, không che bong bóng khác', () {
      // Đúng tình huống chụp được trên emulator: các bong bóng cách nhau ~50 px theo chiều dọc
      final anchors = [const Offset(42, 400), const Offset(42, 452), const Offset(42, 505)];
      final rects = placeEdgeLabels(
        labels: [for (final a in anchors) LabelRequest(anchor: a, edge: Edge.left, size: const Size(150, 40))],
        screen: screen,
        bubbleRadius: r,
      );
      expect(anyOverlap(rects, anchors), isFalse);
      for (final rect in rects) {
        expect(rect.left, greaterThanOrEqualTo(42 + r)); // nằm phía trong, cạnh bong bóng
      }
    });

    test('rìa dưới: nhãn đụng nhau thì đẩy vào trong', () {
      final anchors = [const Offset(180, 750), const Offset(240, 750)];
      final rects = placeEdgeLabels(
        labels: [for (final a in anchors) LabelRequest(anchor: a, edge: Edge.bottom, size: const Size(140, 40))],
        screen: screen,
        bubbleRadius: r,
      );
      expect(anyOverlap(rects, anchors), isFalse);
      expect(rects[1].bottom, lessThan(rects[0].top + 1));
    });

    test('né cả người đang vẽ bên trong bản đồ', () {
      const inner = Rect.fromLTWH(60, 380, 120, 60);
      final rect = placeEdgeLabels(
        labels: [const LabelRequest(anchor: Offset(42, 400), edge: Edge.left, size: Size(150, 40))],
        screen: screen,
        bubbleRadius: r,
        obstacles: [inner],
      ).single;
      expect(rect.overlaps(inner), isFalse);
    });

    test('nhãn sát mép bị kéo vào trong màn hình', () {
      final rect = placeEdgeLabels(
        labels: [const LabelRequest(anchor: Offset(370, 42), edge: Edge.top, size: Size(160, 40))],
        screen: screen,
        bubbleRadius: r,
      ).single;
      expect(rect.right, lessThanOrEqualTo(396));
    });

    test('edgeOf xét theo điểm chạm', () {
      final frame = Rect.fromLTRB(40, 100, 360, 700);
      expect(edgeOf(const Offset(40, 650), frame), Edge.left);
      expect(edgeOf(const Offset(360, 120), frame), Edge.right);
      expect(edgeOf(const Offset(200, 100), frame), Edge.top);
      expect(edgeOf(const Offset(200, 700), frame), Edge.bottom);
    });
  });

  group('xoay bản đồ theo hướng đi', () {
    test('hướng đi luôn ở đỉnh màn hình', () {
      const center = LatLng(21.0285, 105.8542);
      for (final heading in [0.0, 90.0, 200.0, 315.0]) {
        final camera = MapCamera(
          crs: const Epsg3857(),
          center: center,
          zoom: 14,
          rotation: mapRotationForHeading(heading),
          nonRotatedSize: const Size(400, 800),
        );
        final ahead = destination(center.latitude, center.longitude, heading, 500);
        final right = destination(center.latitude, center.longitude, heading + 90, 500);
        final pAhead = camera.latLngToScreenOffset(LatLng(ahead.lat, ahead.lng));
        final pRight = camera.latLngToScreenOffset(LatLng(right.lat, right.lng));
        expect(pAhead.dx, closeTo(200, 1), reason: 'heading $heading');
        expect(pAhead.dy, lessThan(400), reason: 'phía trước phải ở trên, heading $heading');
        expect(pRight.dx, greaterThan(200), reason: 'bên phải phải ở bên phải, heading $heading');
        expect(pRight.dy, closeTo(400, 1), reason: 'heading $heading');
      }
    });
  });

  group('HeadingFilter', () {
    test('đang chạy dùng hướng GPS, bỏ qua la bàn', () {
      final f = HeadingFilter(gpsAlpha: 1);
      f.addGps(speedMs: 10, courseDeg: 90);
      f.addCompass(200);
      expect(f.heading, closeTo(90, 1e-9));
    });

    test('đứng yên chuyển sang la bàn', () {
      final f = HeadingFilter(gpsAlpha: 1, compassAlpha: 1);
      f.addGps(speedMs: 10, courseDeg: 90);
      f.addGps(speedMs: 0.5, courseDeg: 10); // GPS chậm: không tin hướng
      expect(f.heading, closeTo(90, 1e-9));
      f.addCompass(180);
      expect(f.heading, closeTo(180, 1e-9));
    });

    test('làm mượt không giật khi vượt mốc 359° → 0°', () {
      final f = HeadingFilter(gpsAlpha: 0.5);
      f.addGps(speedMs: 10, courseDeg: 350);
      f.addGps(speedMs: 10, courseDeg: 10);
      final h = f.heading!;
      expect(h < 5 || h > 355, isTrue, reason: 'được $h, không được ra ~180');
    });
  });

  group('CourseTracker', () {
    test('tính hướng và tốc độ từ quãng đường, bỏ qua rung GPS tại chỗ', () {
      final t = CourseTracker();
      final t0 = DateTime(2026, 11, 3).millisecondsSinceEpoch;
      t.add(hn.lat, hn.lng, t0);
      final jitter = destination(hn.lat, hn.lng, 200, 5);
      t.add(jitter.lat, jitter.lng, t0 + 1000);
      expect(t.course, isNull);
      final east = destination(hn.lat, hn.lng, 90, 30);
      t.add(east.lat, east.lng, t0 + 3000);
      expect(t.course, closeTo(90, 0.5));
      expect(t.speedMs, closeTo(10, 0.1));
      expect(t.recentCourse(t0 + 5000), closeTo(90, 0.5));
      expect(t.recentCourse(t0 + 20000), isNull);
    });

    test('đứng yên lâu thì tốc độ về gần 0', () {
      final t = CourseTracker();
      final t0 = DateTime(2026, 11, 3).millisecondsSinceEpoch;
      t.add(hn.lat, hn.lng, t0);
      final p = destination(hn.lat, hn.lng, 90, 30);
      t.add(p.lat, p.lng, t0 + 3000);
      t.add(p.lat, p.lng, t0 + 40000);
      expect(t.speedMs, lessThan(0.1));
    });
  });

  group('SendPolicy', () {
    final t0 = DateTime(2026, 11, 3, 8);
    Pos at(int sec, double meters) {
      final p = destination(hn.lat, hn.lng, 0, meters);
      return Pos(ts: t0.millisecondsSinceEpoch + sec * 1000, lat: p.lat, lng: p.lng, acc: 5);
    }

    test('gửi ngay lần đầu, sau đó theo nhịp và quãng đường', () {
      final p = SendPolicy();
      expect(p.shouldSend(at(0, 0), t0), isTrue);
      p.markSent(at(0, 0), t0);
      expect(p.shouldSend(at(1, 50), t0.add(const Duration(seconds: 1))), isFalse); // quá sớm
      expect(p.shouldSend(at(4, 5), t0.add(const Duration(seconds: 4))), isFalse); // đi chưa đủ xa
      expect(p.shouldSend(at(4, 40), t0.add(const Duration(seconds: 4))), isTrue);
    });

    test('đứng yên vẫn gửi định kỳ để không bị coi là mất sóng', () {
      final p = SendPolicy();
      p.markSent(at(0, 0), t0);
      expect(p.shouldSend(at(20, 0), t0.add(const Duration(seconds: 20))), isFalse);
      expect(p.shouldSend(at(26, 0), t0.add(const Duration(seconds: 26))), isTrue);
    });
  });

  group('protocol', () {
    test('đọc snapshot, delta, sự kiện; bỏ qua loại lạ', () {
      final snap = ServerMsg.tryParse(jsonDecode('''
        {"t":"snapshot","serverTime":1,"trip":{"id":"t","name":"Hà Giang","status":"active","inviteCode":"ABCD2345","lagThresholdM":3000},
         "members":[{"uid":"a","name":"An","role":"leader","color":"#E53935","online":true,"sharing":true,"sos":false,
                     "pos":{"ts":5,"lat":21.1,"lng":105.2,"acc":4,"spd":12.5}}],
         "regroup":null}''') as Map<String, dynamic>);
      expect(snap, isA<SnapshotMsg>());
      final m = (snap as SnapshotMsg).members.single;
      expect(m.role, Role.leader);
      expect(m.pos!.spd, 12.5);
      expect(m.pos!.hdg, isNull);

      final ev = ServerMsg.tryParse({'t': 'event', 'event': {'id': 3, 'type': 'lagging', 'uid': 'a', 'at': 9, 'data': {'distanceM': 3400}}});
      expect((ev as EventMsg).event.data['distanceM'], 3400);
      expect(ServerMsg.tryParse({'t': 'future_thing'}), isNull);
      expect(ServerMsg.tryParse({'t': 'delta'}), isNull);
    });

    test('bản tin vị trí bỏ các trường không có', () {
      expect(const Pos(ts: 1, lat: 2, lng: 3, acc: 4).toMsg(), {'t': 'pos', 'ts': 1, 'lat': 2.0, 'lng': 3.0, 'acc': 4.0});
    });
  });

  group('format', () {
    test('khoảng cách, thời gian, mã mời', () {
      expect(formatDistance(843), '840 m');
      expect(formatDistance(1234), '1,2 km');
      expect(formatDistance(996), '1,0 km');
      expect(formatDistance(23456), '23 km');
      expect(formatAge(const Duration(minutes: 3, seconds: 5)), '3 phút');
      expect(formatInviteCode('ABCD2345'), 'ABCD-2345');
      expect(describeDirection(0), 'phía trước');
      expect(describeDirection(-170), 'phía sau');
      expect(describeDirection(45), 'phía trước bên phải');
      expect(describeDirection(270), 'bên trái');
      expect(describeDirection(-130), 'phía sau bên trái');
    });
  });
}
