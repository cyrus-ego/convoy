import 'package:flutter/material.dart';

import '../core/protocol.dart';
import '../data/api_client.dart';
import '../data/session.dart';
import 'trip_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.session, required this.api});

  final Session session;
  final ApiClient api;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<List<TripInfo>> _trips = widget.api.myTrips();

  void _reload() => setState(() => _trips = widget.api.myTrips());

  Future<void> _open(String tripId) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => TripScreen(tripId: tripId, api: widget.api, session: widget.session)),
    );
    if (mounted) _reload();
  }

  Future<void> _create() async {
    final name = await _ask(title: 'Tạo chuyến đi', hint: 'Hà Giang 3 ngày', action: 'Tạo');
    if (name == null) return;
    await _guard(() async {
      final detail = await widget.api.createTrip(name);
      if (!mounted) return;
      await showInviteDialog(context, detail.trip.inviteCode);
      await _open(detail.trip.id);
    });
  }

  Future<void> _join() async {
    final code = await _ask(title: 'Vào đoàn bằng mã', hint: 'ABCD-2345', action: 'Vào đoàn', caps: true);
    if (code == null) return;
    await _guard(() async {
      final detail = await widget.api.joinTrip(code);
      await _open(detail.trip.id);
    });
  }

  Future<void> _guard(Future<void> Function() run) async {
    try {
      await run();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<String?> _ask({required String title, required String hint, required String action, bool caps = false}) {
    final text = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        void submit() {
          if (text.text.trim().isNotEmpty) Navigator.pop(ctx, text.text.trim());
        }

        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: text,
            autofocus: true,
            textCapitalization: caps ? TextCapitalization.characters : TextCapitalization.sentences,
            decoration: InputDecoration(hintText: hint),
            onSubmitted: (_) => submit(),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Thôi')),
            FilledButton(onPressed: submit, child: Text(action)),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bám Đoàn')),
      body: RefreshIndicator(
        onRefresh: () async => _reload(),
        child: FutureBuilder<List<TripInfo>>(
          future: _trips,
          builder: (context, snap) {
            final trips = snap.data ?? const [];
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text('Chào ${widget.session.displayName ?? 'bạn'}', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 4),
                const Text('Cả đoàn cùng thấy nhau trên bản đồ, không lo lạc.'),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _create,
                  icon: const Icon(Icons.add_road),
                  label: const Text('Tạo chuyến đi'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _join,
                  icon: const Icon(Icons.group_add),
                  label: const Text('Vào đoàn bằng mã'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                ),
                const SizedBox(height: 32),
                if (snap.connectionState == ConnectionState.waiting)
                  const Center(child: CircularProgressIndicator())
                else if (snap.hasError)
                  ListTile(
                    leading: const Icon(Icons.cloud_off),
                    title: Text(snap.error.toString()),
                    trailing: TextButton(onPressed: _reload, child: const Text('Thử lại')),
                  )
                else if (trips.isNotEmpty) ...[
                  Text('Chuyến đang đi', style: Theme.of(context).textTheme.titleMedium),
                  for (final t in trips)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.two_wheeler),
                        title: Text(t.name),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(t.id),
                      ),
                    ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.session, required this.onDone});

  final Session session;
  final VoidCallback onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Nhập tên để đồng đội nhận ra bạn');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.register(name);
      widget.onDone();
    } on Object catch (e) {
      setState(() => _error = 'Không kết nối được máy chủ: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.two_wheeler, size: 72, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text('Bám Đoàn', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              const Text('Đi phượt cả đoàn, ai ở đâu cũng thấy.', textAlign: TextAlign.center),
              const SizedBox(height: 40),
              TextField(
                controller: _name,
                maxLength: 40,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(labelText: 'Tên của bạn', hintText: 'Nam', errorText: _error),
                onSubmitted: (_) => _submit(),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _submit,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                child: _busy ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Bắt đầu'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
