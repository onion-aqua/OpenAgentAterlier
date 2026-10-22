import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/android_companion_runtime.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/continuous_asmr_page.dart';
import 'package:ryza_chat_mvp/src/model_package_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'model switch cancels pending ASMR, clears its topic and serializes old audio stop',
    (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      final channels = <String>{
        'xyz.luan/audioplayers',
        'xyz.luan/audioplayers.global',
        'xyz.luan/audioplayers.global/events',
        'agent_atelier_r/companion_runtime',
        'agent_atelier_r/companion_runtime/events',
        'plugins.flutter.io/path_provider',
        'plugins.it_nomads.com/flutter_secure_storage',
      };
      final nativeMethods = <String>[];
      final stopGate = Completer<void>();
      final oldRead = Completer<String?>();
      final newRead = Completer<String?>();
      var keyRequests = 0;
      messenger.setMockMethodCallHandler(
        const MethodChannel('agent_atelier_r/companion_runtime'),
        (_) async => {'running': true, 'stopRequested': false, 'muted': false},
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('agent_atelier_r/companion_runtime/events'),
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers.global'),
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers.global/events'),
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'),
        (call) async {
          nativeMethods.add(call.method);
          if (call.method == 'create') {
            final id = (call.arguments as Map)['playerId'];
            final events = 'xyz.luan/audioplayers/events/$id';
            channels.add(events);
            messenger.setMockMethodCallHandler(
              MethodChannel(events),
              (_) async => null,
            );
          }
          if (call.method == 'stop') await stopGate.future;
          return 0;
        },
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async {
          if (call.method == 'read' &&
              (call.arguments as Map)['key'] == 'openai_slot_keys_v1') {
            return ++keyRequests == 1 ? oldRead.future : newRead.future;
          }
          return null;
        },
      );
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('asmr_model_scope_'),
      ))!;
      late final ModelPackageStore packages;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => directory.path,
      );
      const models = [
        CharacterAppearance(
          id: 'asmr_scope_a',
          label: '月见',
          description: '',
          promptDescription: '',
          assetName: 'asmr_scope_a',
          animated: true,
          idleAnimations: [],
          live2dModelDirectory: 'test/a',
          live2dModelFileName: 'a.model3.json',
        ),
        CharacterAppearance(
          id: 'asmr_scope_b',
          label: '星见',
          description: '',
          promptDescription: '',
          assetName: 'asmr_scope_b',
          animated: true,
          idleAnimations: [],
          live2dModelDirectory: 'test/b',
          live2dModelFileName: 'b.model3.json',
        ),
      ];
      characterAppearances.addAll(models);
      SharedPreferences.setMockInitialValues({});
      final controller = (await tester.runAsync(() async {
        packages = ModelPackageStore.forTesting();
        await packages.initialize(storageDirectory: directory);
        for (final model in models) {
          await packages.ensureModel(
            modelId: model.id,
            format: 'live2d',
            label: model.label,
            ownerCharacterId: model.characterId,
            files: {'model.json': Uint8List.fromList(utf8.encode('{}'))},
          );
        }
        final controller = await AppController.load(modelPackages: packages);
        await controller.setCharacterAppearance(models.first.id);
        return controller;
      }))!;
      addTearDown(() async {
        if (!oldRead.isCompleted) oldRead.complete(null);
        if (!newRead.isCompleted) newRead.complete(null);
        if (!stopGate.isCompleted) stopGate.complete();
        controller.dispose();
        characterAppearances.removeWhere(
          (item) => models.any((model) => model.id == item.id),
        );
        await tester.runAsync(() => packages.flush());
        for (final channel in channels) {
          messenger.setMockMethodCallHandler(MethodChannel(channel), null);
        }
        await tester.runAsync(() => directory.delete(recursive: true));
      });
      controller.aiEnabled = true;
      controller.fishTtsEnabled = true;
      await AndroidCompanionRuntime.instance.refresh();
      await tester.pumpWidget(
        MaterialApp(home: ContinuousAsmrPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '月见的旧主题');
      await tester.tap(find.widgetWithText(FilledButton, '确定'));
      await tester.pump();
      expect(keyRequests, 1);
      expect(find.widgetWithText(FilledButton, '取消'), findsOneWidget);

      await tester.runAsync(
        () => controller.setCharacterAppearance(models.last.id),
      );
      await tester.pump();
      expect(controller.activeModelId, models.last.id);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(find.widgetWithText(FilledButton, '确定'), findsOneWidget);
      expect(find.text('确定主题后，语音会显示在这里'), findsOneWidget);
      expect(nativeMethods, contains('stop'));
      expect(nativeMethods.where((method) => method == 'resume'), isEmpty);

      // A language-only change stays in this model and preserves its new topic.
      await tester.enterText(find.byType(TextField), '星见的新主题');
      await tester.runAsync(() async {
        controller.configureLanguages(
          interface: AppLanguage.chinese,
          narrator: AppLanguage.chinese,
          characterReply: AppLanguage.japanese,
          translation: TranslationLanguage.none,
        );
        await controller.flushModelSession();
      });
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '星见的新主题',
      );
      controller.aiEnabled = true;
      controller.fishTtsEnabled = true;
      await tester.tap(find.widgetWithText(FilledButton, '确定'));
      await tester.pump();
      expect(
        keyRequests,
        1,
        reason: 'New preparation waits for the old player stop',
      );
      oldRead.complete(null);
      await tester.pump();
      expect(
        find.textContaining('准备失败'),
        findsNothing,
        reason: 'Old model errors must not replace the new model UI',
      );
      stopGate.complete();
      for (var i = 0; i < 10 && keyRequests < 2; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(keyRequests, 2);
      expect(find.widgetWithText(FilledButton, '取消'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '星见的新主题',
      );
      newRead.complete(null);
      await tester.pumpAndSettle();
      expect(find.textContaining('准备失败'), findsOneWidget);
      expect(nativeMethods.where((method) => method == 'resume'), isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 10 && !nativeMethods.contains('dispose'); i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(nativeMethods, contains('dispose'));
      final stopsAfterDispose = nativeMethods
          .where((method) => method == 'stop')
          .length;
      await tester.runAsync(
        () => controller.setCharacterAppearance(models.first.id),
      );
      await tester.pumpAndSettle();
      expect(
        nativeMethods.where((method) => method == 'stop').length,
        stopsAfterDispose,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ASMR stops only for companion stop and rejects new preparation',
    (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      final channels = <String>{
        'xyz.luan/audioplayers',
        'xyz.luan/audioplayers.global',
        'agent_atelier_r/companion_runtime',
        'agent_atelier_r/companion_runtime/events',
        'plugins.flutter.io/path_provider',
      };
      final state = <String, Object>{
        'running': true,
        'stopRequested': false,
        'muted': false,
        'callActive': false,
        'notificationsAllowed': true,
      };
      messenger.setMockMethodCallHandler(
        const MethodChannel('agent_atelier_r/companion_runtime'),
        (_) async => Map<String, Object>.from(state),
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('agent_atelier_r/companion_runtime/events'),
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => Directory.systemTemp.path,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers.global'),
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'),
        (call) async {
          if (call.method == 'create') {
            final id = (call.arguments as Map)['playerId'];
            final events = 'xyz.luan/audioplayers/events/$id';
            channels.add(events);
            messenger.setMockMethodCallHandler(
              MethodChannel(events),
              (_) async => null,
            );
          }
          return 0;
        },
      );
      addTearDown(() {
        for (final channel in channels) {
          messenger.setMockMethodCallHandler(MethodChannel(channel), null);
        }
      });
      SharedPreferences.setMockInitialValues({});
      final controller = (await tester.runAsync(() => AppController.load()))!;
      addTearDown(controller.dispose);
      final runtime = AndroidCompanionRuntime.instance;
      await runtime.refresh();
      await tester.pumpWidget(
        MaterialApp(home: ContinuousAsmrPage(controller: controller)),
      );
      await tester.pumpAndSettle();

      state.addAll({'muted': true, 'callActive': true});
      await runtime.refresh();
      await tester.pumpAndSettle();
      expect(find.text('后台陪伴已停止'), findsNothing);

      state['stopRequested'] = true;
      await runtime.refresh();
      await tester.pumpAndSettle();
      expect(find.text('后台陪伴已停止'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '雨声');
      await tester.tap(find.widgetWithText(FilledButton, '确定'));
      await tester.pumpAndSettle();
      const instruction = '后台陪伴已停止，请在“设置 → 声音”中恢复陪伴通知后重试';
      expect(find.text(instruction), findsOneWidget);
      expect(find.text('请先启用并配置 LLM 和语音合成'), findsNothing);

      // Further native updates while already stopped do not stop the session again.
      state.addAll({'muted': false, 'callActive': false});
      await runtime.refresh();
      await tester.pumpAndSettle();
      expect(find.text(instruction), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      state['stopRequested'] = false;
      await runtime.refresh();
      expect(tester.takeException(), isNull);
    },
  );
}
