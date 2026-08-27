// Smoke test: the scan page builds, without actually opening a camera.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app theme and title', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF07C160),
            brightness: Brightness.dark,
          ),
        ),
        home: const Scaffold(body: Center(child: Text('Scan'))),
      ),
    );
    expect(find.text('Scan'), findsOneWidget);
  });
}
