import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/ryza_loading_indicator.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';

void main() {
  testWidgets('loading panel is centered and follows the interface language', (
    tester,
  ) async {
    for (final language in AppLanguage.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: RyzaLoadingPanel(language: language)),
          ),
        ),
      );
      expect(
        find.text(language.text('加载中…', 'Loading…', '読み込み中…')),
        findsOneWidget,
      );
      expect(
        tester.getCenter(find.byType(RyzaLoadingPanel)),
        const Offset(400, 300),
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('legacy loading wrapper uses a neutral progress indicator', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: RyzaLoadingIndicator(semanticsLabel: '正在加载')),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.bySemanticsLabel('正在加载'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 170));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy loading wrapper honors reduced motion', (tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: MaterialApp(home: Scaffold(body: RyzaLoadingIndicator())),
      ),
    );

    await tester.pump(const Duration(seconds: 1));

    expect(find.byIcon(Icons.hourglass_top_rounded), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
