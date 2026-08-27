import 'package:flutter/material.dart';

import 'scan_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WxScanApp());
}

class WxScanApp extends StatelessWidget {
  const WxScanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'wxscan',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF07C160), // WeChat green
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const ScanPage(),
    );
  }
}
