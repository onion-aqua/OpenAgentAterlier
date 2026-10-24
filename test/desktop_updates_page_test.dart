import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/desktop_updates_page.dart';

void main() {
  testWidgets(
    'unconfigured desktop updater has no former app link or enabled launcher',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopUpdatesPage(
            language: AppLanguage.chinese,
            liquidGlass: false,
            openRelease: (_) async {
              calls++;
              return true;
            },
          ),
        ),
      );
      expect(DesktopUpdatesPage.releaseUrl, isNull);
      expect(find.text('OpenAgentAtelier Windows'), findsOneWidget);
      expect(find.textContaining('AgentAtelierR'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('desktop-release-download')),
            )
            .onPressed,
        isNull,
      );
      expect(calls, 0);
    },
  );

  testWidgets('configured desktop page opens only its supplied HTTPS release', (
    tester,
  ) async {
    final opened = <Uri>[];
    final release = Uri.parse('https://releases.example.test/openagentatelier');
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopUpdatesPage(
          language: AppLanguage.english,
          liquidGlass: false,
          releasePage: release,
          openRelease: (uri) async {
            opened.add(uri);
            return true;
          },
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('desktop-release-download')));
    await tester.pumpAndSettle();
    expect(opened, [release]);
  });
}
