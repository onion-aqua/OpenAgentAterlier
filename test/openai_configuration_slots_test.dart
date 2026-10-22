import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/openai_configuration_slots.dart';
import 'package:ryza_chat_mvp/src/openai_settings_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secrets = SecretStore();
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'openai_base_url': 'https://legacy.example/v1',
      'openai_model': 'legacy-model',
    });
    FlutterSecureStorage.setMockInitialValues({
      'openai_api_key': 'test-legacy-key',
    });
  });

  test(
    'legacy config migrates, three slots persist and backup excludes keys',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      final slots = controller.openAiConfigurations;
      expect(slots.active, 0);
      expect(slots.entries[0]?['model'], 'legacy-model');
      expect(slots.entries.skip(1), everyElement(isNull));
      slots.entries[1] = {
        'baseUrl': 'https://two.example/v1',
        'model': 'two-model',
        'apiKey': 'must-not-export',
      };
      slots.entries[2] = {
        'baseUrl': 'https://three.example/v1',
        'model': 'three-model',
      };
      slots.active = 2;
      await secrets.writeOpenAiSlotKeys({
        1: 'test-key-two',
        2: 'test-key-three',
      });
      controller.saveOpenAiConfigurations(slots, enabled: true);
      expect(controller.activeOpenAiSlot, 2);
      expect(controller.activeLlmBaseUrl, 'https://three.example/v1');
      expect(
        await secrets.readLlmKey(
          controller.llmProvider,
          openAiSlot: controller.activeOpenAiSlot,
        ),
        'test-key-three',
      );
      await Future<void>.delayed(Duration.zero);
      final reloaded = await AppController.load();
      addTearDown(reloaded.dispose);
      expect(reloaded.activeOpenAiSlot, 2);
      expect(reloaded.openAiConfigurations.entries[1]?['model'], 'two-model');
      final backup = controller.exportData();
      final json = jsonEncode(backup);
      for (final secret in [
        'test-legacy-key',
        'test-key-two',
        'test-key-three',
        'must-not-export',
      ]) {
        expect(json, isNot(contains(secret)));
      }
      await reloaded.importData(backup);
      expect(reloaded.activeLlmModel, 'three-model');
      final first = reloaded.openAiConfigurations..active = 0;
      reloaded.saveOpenAiConfigurations(first, enabled: true);
      expect(reloaded.activeLlmModel, 'legacy-model');
      expect(await secrets.readOpenAiKey(slot: 0), 'test-legacy-key');
    },
  );

  test(
    'empty slots never inherit keys and clearing one preserves the others',
    () async {
      expect(await secrets.readOpenAiKey(slot: 1), isEmpty);
      await secrets.writeOpenAiSlotKeys({1: 'test-two', 2: 'test-three'});
      await secrets.writeOpenAiSlotKeys({0: ''});
      expect(await secrets.readOpenAiKey(), isEmpty);
      expect(await secrets.readOpenAiKey(slot: 1), 'test-two');
      expect(await secrets.readOpenAiKey(slot: 2), 'test-three');
      await expectLater(secrets.readOpenAiKey(slot: 3), throwsRangeError);
      final slots = OpenAiConfigurationSlots.fromJson({
        'active': 9,
        'entries': List.filled(5, {'baseUrl': 'url', 'model': 'model'}),
      });
      expect(slots.entries.length, 3);
      expect(slots.active, 2);
    },
  );

  for (final save in [false, true]) {
    testWidgets('slot drafts and clear key commit only on Save: $save', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = (await tester.runAsync(() => AppController.load()))!;
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => OpenAiSettingsDialog(controller: controller),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(ChoiceChip), findsNWidgets(3));
      await tester.tap(find.text('清除 Key'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('openai-slot-1')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('openai-url-1')),
        'https://second.example/v1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('openai-model-1')),
        'second-model',
      );
      await tester.enterText(
        find.byKey(const ValueKey('openai-key-1')),
        'test-second-key',
      );
      await tester.tap(find.byKey(const ValueKey('openai-slot-0')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('openai-slot-1')));
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('openai-model-1')))
            .controller!
            .text,
        'second-model',
      );
      expect(controller.activeLlmModel, 'legacy-model');
      await tester.tap(find.text(save ? '保存' : '取消'));
      await tester.pumpAndSettle();
      expect(find.byType(OpenAiSettingsDialog), findsNothing);
      expect(controller.activeOpenAiSlot, save ? 1 : 0);
      expect(await secrets.readOpenAiKey(), save ? '' : 'test-legacy-key');
      expect(
        await secrets.readOpenAiKey(slot: 1),
        save ? 'test-second-key' : '',
      );
      expect(tester.takeException(), isNull);
    });
  }
}
