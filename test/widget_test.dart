// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutterai/app.dart';

void main() {
  testWidgets('App boots and shows home title', (WidgetTester tester) async {
    // HomeScreen is content-heavy; give it enough room to avoid RenderFlex
    // overflow in the default test viewport.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 2400);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await tester.pumpWidget(
      const ProviderScope(
        child: AcceptanceApp(),
      ),
    );
    await tester.pumpAndSettle();

    // 基本冒烟测试：首页标题存在。
    expect(find.textContaining('河狸云工序验收'), findsOneWidget);
  });
}
