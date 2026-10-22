import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live2d_flutter/flutter_live2d_method_channel.dart';
import 'package:live2d_flutter/live2d_flutter.dart';

class _IdleCall {
  const _IdleCall(this.viewId, this.group, this.index);

  final int viewId;
  final String group;
  final int index;
}

class _IdlePlatform extends FlutterLive2dPlatform {
  final calls = <_IdleCall>[];
  bool reject = false;

  @override
  Future<void> setIdleMotion({
    required int viewId,
    required String group,
    required int index,
  }) async {
    if (reject) {
      throw Live2DException(
        'INVALID_MOTION',
        'The idle motion is not present in the loaded model.',
      );
    }
    calls.add(_IdleCall(viewId, group, index));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FlutterLive2dPlatform previousPlatform;
  late _IdlePlatform platform;

  setUp(() {
    previousPlatform = FlutterLive2dPlatform.instance;
    platform = _IdlePlatform();
    FlutterLive2dPlatform.instance = platform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform_views,
          (_) async => null,
        );
  });

  tearDown(() {
    FlutterLive2dPlatform.instance = previousPlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null);
  });

  testWidgets(
    'controller accepts unnamed idle groups and keeps the last accepted value',
    (tester) async {
      final controller = Live2DViewController();
      await tester.pumpWidget(
        MaterialApp(home: Live2DView(controller: controller)),
      );
      for (
        var attempt = 0;
        attempt < 40 && !controller.value.isAttached;
        attempt++
      ) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
      }
      expect(controller.value.isAttached, isTrue);

      await controller.setIdleMotion(group: '', index: 2);
      expect(platform.calls, hasLength(1));
      expect(platform.calls.single.group, '');
      expect(platform.calls.single.index, 2);
      expect(controller.idleMotionGroup, '');
      expect(controller.idleMotionIndex, 2);

      platform.reject = true;
      await expectLater(
        controller.setIdleMotion(group: 'Missing', index: 0),
        throwsA(
          isA<Live2DException>().having(
            (error) => error.code,
            'code',
            'INVALID_MOTION',
          ),
        ),
      );
      expect(controller.idleMotionGroup, '');
      expect(controller.idleMotionIndex, 2);

      await expectLater(
        controller.setIdleMotion(group: 'Idle', index: -1),
        throwsA(
          isA<Live2DException>().having(
            (error) => error.code,
            'code',
            'INVALID_MOTION',
          ),
        ),
      );
      expect(platform.calls, hasLength(1));

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      expect(controller.idleMotionGroup, 'Idle');
      expect(controller.idleMotionIndex, 0);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  test('method channel forwards the exact idle group and index', () async {
    final implementation = MethodChannelFlutterLive2d();
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(implementation.methodChannel, (call) async {
          captured = call;
          return null;
        });

    await implementation.setIdleMotion(viewId: 7, group: '', index: 3);

    expect(captured?.method, 'setIdleMotion');
    expect(captured?.arguments, {'viewId': 7, 'group': '', 'index': 3});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(implementation.methodChannel, null);
  });
}
