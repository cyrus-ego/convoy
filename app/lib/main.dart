import 'package:flutter/material.dart';

import 'config.dart';
import 'data/api_client.dart';
import 'data/session.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final session = Session(AppConfig.apiBase);
  await session.load();
  runApp(BamDoanApp(session: session, api: ApiClient(session)));
}

class BamDoanApp extends StatefulWidget {
  const BamDoanApp({super.key, required this.session, required this.api});

  final Session session;
  final ApiClient api;

  @override
  State<BamDoanApp> createState() => _BamDoanAppState();
}

class _BamDoanAppState extends State<BamDoanApp> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bám Đoàn',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF0F6E56), useMaterial3: true),
      home: widget.session.isRegistered
          ? HomeScreen(session: widget.session, api: widget.api)
          : OnboardingScreen(session: widget.session, onDone: () => setState(() {})),
    );
  }
}
