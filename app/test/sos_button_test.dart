import 'package:bam_doan/ui/widgets/sos_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bọc nút trong một màn hình có trạng thái thật: onChanged đổi active như trong app
class _Harness extends StatefulWidget {
  const _Harness(this.calls);
  final List<bool> calls;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool active = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SosButton(
              active: active,
              onChanged: (on) {
                widget.calls.add(on);
                setState(() => active = on);
              },
            ),
          ),
        ),
      );
}

/// Giữ nút [ms] mili giây như ngón tay thật: chờ qua ngưỡng nhận chạm rồi cho animation chạy
Future<TestGesture> hold(WidgetTester tester, int ms) async {
  final gesture = await tester.startGesture(tester.getCenter(find.byType(SosButton)));
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pump(Duration(milliseconds: ms - 150));
  await tester.pump();
  return gesture;
}

void main() {
  testWidgets('giữ đủ 2 giây rồi nhấc tay: SOS bật và giữ nguyên', (tester) async {
    final calls = <bool>[];
    await tester.pumpWidget(_Harness(calls));
    final gesture = await hold(tester, 2200);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls, [true]);
    expect(find.text('Tắt SOS'), findsOneWidget);
  });

  testWidgets('nhấc tay trước 2 giây thì không bật', (tester) async {
    final calls = <bool>[];
    await tester.pumpWidget(_Harness(calls));
    final gesture = await hold(tester, 1200);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
  });

  testWidgets('tắt SOS phải xác nhận', (tester) async {
    final calls = <bool>[];
    await tester.pumpWidget(_Harness(calls));
    final gesture = await hold(tester, 2200);
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.byType(SosButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vẫn bật'));
    await tester.pumpAndSettle();
    expect(calls, [true]);

    await tester.tap(find.byType(SosButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tắt SOS').last);
    await tester.pumpAndSettle();
    expect(calls, [true, false]);
  });
}
