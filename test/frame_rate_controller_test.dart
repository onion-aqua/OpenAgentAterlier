import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/frame_rate_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('frame rate slider order follows high, adaptive, low', () {
    expect(AppFrameRateModeData.fromSliderValue(0), AppFrameRateMode.high);
    expect(AppFrameRateModeData.fromSliderValue(1), AppFrameRateMode.adaptive);
    expect(AppFrameRateModeData.fromSliderValue(2), AppFrameRateMode.low);
  });

  test('adaptive mode raises and restores frame rate by activity', () async {
    final requests = <({double fps, bool maximum})>[];
    final controller = AdaptiveFrameRateController(
      requestPreferredFrameRate: (fps, maximum) async {
        requests.add((fps: fps, maximum: maximum));
        return fps;
      },
    );

    controller.setMode(AppFrameRateMode.adaptive, force: true);
    expect(controller.effectiveFramesPerSecond, 24);

    controller.setActivity(FrameRateActivity.speech, true);
    expect(controller.effectiveFramesPerSecond, 90);

    controller.setActivity(FrameRateActivity.touch, true);
    expect(controller.effectiveFramesPerSecond, 120);

    controller.setActivity(FrameRateActivity.touch, false);
    expect(controller.effectiveFramesPerSecond, 90);

    controller.setActivity(FrameRateActivity.speech, false);
    expect(controller.effectiveFramesPerSecond, 24);
    await Future<void>.delayed(Duration.zero);

    expect(requests.last, (fps: 24, maximum: false));
    controller.dispose();
  });

  test('fixed modes ignore adaptive activities', () async {
    final requests = <({double fps, bool maximum})>[];
    final controller = AdaptiveFrameRateController(
      requestPreferredFrameRate: (fps, maximum) async {
        requests.add((fps: fps, maximum: maximum));
        return maximum ? 144 : fps;
      },
    );

    controller.setMode(AppFrameRateMode.low);
    controller.setActivity(FrameRateActivity.touch, true);
    expect(controller.effectiveFramesPerSecond, 30);

    controller.setMode(AppFrameRateMode.high);
    expect(controller.effectiveFramesPerSecond, 120);
    await Future<void>.delayed(Duration.zero);
    expect(requests.last, (fps: 120, maximum: true));

    controller.setActivity(FrameRateActivity.touch, false);
    expect(controller.effectiveFramesPerSecond, 120);
    controller.dispose();
  });

  test('temporary boost returns adaptive mode to idle', () async {
    final controller = AdaptiveFrameRateController(
      requestPreferredFrameRate: (fps, maximum) async => fps,
    );
    controller.setMode(AppFrameRateMode.adaptive, force: true);

    controller.boost(
      FrameRateActivity.characterMotion,
      duration: const Duration(milliseconds: 10),
    );
    expect(controller.effectiveFramesPerSecond, 120);
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(controller.effectiveFramesPerSecond, 24);
    controller.dispose();
  });

  test('selected frame rate mode persists across app reload', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    expect(controller.frameRateMode, AppFrameRateMode.adaptive);

    controller.setFrameRateMode(AppFrameRateMode.low);
    await Future<void>.delayed(Duration.zero);

    final restored = await AppController.load();
    expect(restored.frameRateMode, AppFrameRateMode.low);
    expect(restored.frameRate.effectiveFramesPerSecond, 30);
    controller.dispose();
    restored.dispose();
  });
}
