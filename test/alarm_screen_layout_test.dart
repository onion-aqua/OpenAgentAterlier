import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:alarm/alarm.dart';
import 'package:alarm/service/alarm_storage.dart';
import 'package:alarm/src/generated/platform_bindings.g.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/alarm_screen.dart';
import 'package:ryza_chat_mvp/src/alarm_audio.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/model_package_store.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var nativeSetCalls = 0;
  const model = CharacterAppearance(
    id: 'alarm_ui_model',
    label: 'Imported Model',
    description: '',
    promptDescription: '',
    assetName: 'alarm_ui_model',
    animated: true,
    idleAnimations: [],
    live2dModelDirectory: 'test/a',
    live2dModelFileName: 'a.model3.json',
  );

  Future<AppController> importedController(WidgetTester tester) async {
    return (await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('alarm-ui-');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => call.method == 'getApplicationSupportDirectory'
                ? directory.path
                : null,
          );
      final packages = ModelPackageStore.forTesting();
      await packages.initialize(storageDirectory: directory);
      characterAppearances.add(model);
      await packages.ensureModel(
        modelId: model.id,
        format: 'live2d',
        label: model.label,
        ownerCharacterId: model.characterId,
        files: {'model.json': Uint8List.fromList(utf8.encode('{}'))},
      );
      final controller = await AppController.load(modelPackages: packages);
      await controller.setCharacterAppearance(model.id);
      await ModelAlarmAudioStore.instance.importBytes(model.id, [
        1,
        2,
        3,
        4,
      ], 'wav');
      addTearDown(() async {
        controller.dispose();
        characterAppearances.removeWhere((item) => item.id == model.id);
        await packages.flush();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      });
      return controller;
    }))!;
  }

  const nativeSetChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.alarm.AlarmApi.setAlarm',
    AlarmApi.pigeonChannelCodec,
  );
  const nativeStopChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.alarm.AlarmApi.stopAlarm',
    AlarmApi.pigeonChannelCodec,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AlarmStorage.resetForTesting();
    Alarm.resetForTesting();
    nativeSetCalls = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      (call) async => call.method == 'requestPermissions'
          ? {for (final permission in call.arguments as List) permission: 1}
          : 1,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.ajinasokan.flutter_fgbg/events'),
      (_) async => null,
    );
    messenger.setMockDecodedMessageHandler<Object?>(nativeSetChannel, (
      _,
    ) async {
      nativeSetCalls++;
      return ['1', 'Native alarm unavailable', null];
    });
    messenger.setMockDecodedMessageHandler<Object?>(
      nativeStopChannel,
      (_) async => [null],
    );
  });

  tearDown(() {
    AlarmStorage.resetForTesting();
    Alarm.resetForTesting();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.ajinasokan.flutter_fgbg/events'),
      null,
    );
    messenger.setMockDecodedMessageHandler<Object?>(nativeSetChannel, null);
    messenger.setMockDecodedMessageHandler<Object?>(nativeStopChannel, null);
  });

  Future<void> showAlarmPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = await importedController(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: AlarmScreen(
          controller: controller,
          embedded: true,
          onMenuPressed: () {},
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
  }

  test('confirmed alarm time uses next day when picker target has passed', () {
    const target = Duration(hours: 12, minutes: 30);
    expect(
      nextVoiceAlarmTime(target, DateTime(2026, 10, 12, 12, 29)),
      DateTime(2026, 10, 12, 12, 30),
    );
    expect(
      nextVoiceAlarmTime(target, DateTime(2026, 10, 12, 12, 31)),
      DateTime(2026, 10, 13, 12, 30),
    );
    expect(
      nextVoiceAlarmTime(Duration.zero, DateTime(2026, 12, 31, 23, 59)),
      DateTime(2027, 1, 1),
    );
  });

  for (final legacySelection in [false, true]) {
    testWidgets(
      'Windows disables scheduling and keeps neutral empty model notice $legacySelection',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        var permissionCalls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('flutter.baseflow.com/permissions/methods'),
              (_) async {
                permissionCalls++;
                throw StateError('No permission requests on Windows');
              },
            );
        tester.view.physicalSize = const Size(320, 480);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        if (legacySelection) {
          SharedPreferences.setMockInitialValues({
            'active_character_id_v1': 'sophie',
          });
        }
        final controller = (await tester.runAsync(() => AppController.load()))!;
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: AlarmScreen(
              controller: controller,
              embedded: true,
              onMenuPressed: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        final notice = find.text('本平台暂不支持定时语音闹钟');
        expect(notice, findsOneWidget);
        expect(tester.getTopLeft(notice).dy, greaterThanOrEqualTo(0));
        expect(tester.getBottomLeft(notice).dy, lessThanOrEqualTo(480));
        expect(find.byTooltip('添加闹钟'), findsNothing);
        expect(find.byType(GlassIconButton), findsNothing);
        expect(find.text('苏菲的语音闹钟资源尚未提供'), findsNothing);
        expect(find.text('请先导入并选择模型'), findsOneWidget);
        expect(permissionCalls, 0);
        expect(nativeSetCalls, 0);
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets(
    'adding an alarm is guarded while permission request is pending',
    (tester) async {
      final permission = Completer<Map<int, int>>();
      var permissionCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('flutter.baseflow.com/permissions/methods'),
            (call) async {
              permissionCalls++;
              if (permissionCalls == 1) return permission.future;
              return {for (final id in call.arguments as List) id: 1};
            },
          );
      await showAlarmPage(tester);
      final add = tester
          .widget<GlassIconButton>(find.byType(GlassIconButton))
          .onPressed!;
      add();
      add();
      await tester.pump();
      expect(permissionCalls, 1);
      expect(
        tester.widget<GlassIconButton>(find.byType(GlassIconButton)).onPressed,
        isNull,
      );
      permission.complete({17: 1});
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoTimerPicker), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await Alarm.getAlarms(), isEmpty);
      expect(nativeSetCalls, 0);
      expect(
        tester.widget<GlassIconButton>(find.byType(GlassIconButton)).onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancelling the reminder choice never persists an alarm', (
    tester,
  ) async {
    await showAlarmPage(tester);
    await tester.tap(find.byTooltip('添加闹钟'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('选择提醒类型'), findsOneWidget);
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();
    expect(await Alarm.getAlarms(), isEmpty);
    expect(nativeSetCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'native alarm failure shows feedback and leaves no duplicate saves when retried',
    (tester) async {
      await showAlarmPage(tester);
      for (var attempt = 1; attempt <= 2; attempt++) {
        await tester.tap(find.byTooltip('添加闹钟'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('早安唤醒'));
        await tester.pumpAndSettle();
        expect(find.text('闹钟设置失败，请重试'), findsOneWidget);
        expect(await Alarm.getAlarms(), isEmpty);
        expect(nativeSetCalls, attempt);
        expect(
          tester
              .widget<GlassIconButton>(find.byType(GlassIconButton))
              .onPressed,
          isNotNull,
        );
        expect(tester.takeException(), isNull);
        ScaffoldMessenger.of(tester.element(find.byType(AlarmScreen)))
            .clearSnackBars();
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'alarm time picker remains usable in a short large-text viewport',
    (tester) async {
      tester.view.physicalSize = const Size(390, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = await importedController(tester);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: AlarmScreen(
            controller: controller,
            embedded: true,
            onMenuPressed: () {},
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('添加闹钟'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoTimerPicker), findsOneWidget);
      tester.view.physicalSize = const Size(320, 330);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('取消'));
      expect(find.text('取消').hitTestable(), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoTimerPicker), findsNothing);
      expect(await Alarm.getAlarms(), isEmpty);
      expect(nativeSetCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
