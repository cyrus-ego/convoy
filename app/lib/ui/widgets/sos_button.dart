import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Giữ 2 giây mới bật SOS để tránh bấm nhầm khi đang lái. Tắt thì phải xác nhận.
class SosButton extends StatefulWidget {
  const SosButton({super.key, required this.active, required this.onChanged});
  final bool active;
  final ValueChanged<bool> onChanged;

  @override
  State<SosButton> createState() => _SosButtonState();
}

class _SosButtonState extends State<SosButton> with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(vsync: this, duration: const Duration(seconds: 2))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        HapticFeedback.heavyImpact();
        widget.onChanged(true);
        _hold.reset();
      }
    });

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  Future<void> _confirmOff() async {
    final off = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tắt SOS?'),
        content: const Text('Cả đoàn sẽ được báo là bạn đã ổn.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vẫn bật')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Tắt SOS'),
          ),
        ],
      ),
    );
    if (off == true) widget.onChanged(false);
  }

  @override
  Widget build(BuildContext context) {
    // Key khác nhau cho hai trạng thái: nếu không, Flutter dùng lại bộ nhận cử chỉ và lần nhấc tay
    // sau khi giữ đủ 2 giây bị tính là một lần chạm vào nút "đang bật" → SOS tắt ngay khi vừa bật.
    if (widget.active) {
      return GestureDetector(
        key: const ValueKey('sos-active'),
        onTap: _confirmOff,
        child: const _SosCircle(fill: Colors.red, label: 'Tắt SOS', progress: 1),
      );
    }
    return GestureDetector(
      key: const ValueKey('sos-idle'),
      onTapDown: (_) => _hold.forward(),
      onTapUp: (_) => _cancel(),
      onTapCancel: _cancel,
      child: AnimatedBuilder(
        animation: _hold,
        builder: (_, _) => _SosCircle(fill: Colors.white, label: 'Giữ để SOS', progress: _hold.value),
      ),
    );
  }

  void _cancel() {
    if (_hold.isAnimating) _hold.reverse();
  }
}

class _SosCircle extends StatelessWidget {
  const _SosCircle({required this.fill, required this.label, required this.progress});
  final Color fill;
  final String label;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final active = fill == Colors.red;
    return SizedBox(
      width: 84,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(alignment: Alignment.center, children: [
            SizedBox(
              width: 46,
              height: 46,
              child: CircularProgressIndicator(value: progress, strokeWidth: 4, color: Colors.red, backgroundColor: Colors.red.shade100),
            ),
            CircleAvatar(
              radius: 19,
              backgroundColor: fill,
              child: Text('SOS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: active ? Colors.white : Colors.red)),
            ),
          ]),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.red)),
        ],
      ),
    );
  }
}
