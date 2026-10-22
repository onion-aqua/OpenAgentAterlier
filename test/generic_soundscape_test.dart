import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/soundscape_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a generic workspace never starts audio from the old character world',
    () async {
      SharedPreferences.setMockInitialValues({
        'bgm_enabled': true,
        'ambient_enabled': true,
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final support = await Directory.systemTemp.createTemp(
        'generic_soundscape_',
      );
      final channels = <String>{
        'plugins.flutter.io/path_provider',
        'xyz.luan/audioplayers.global',
        'xyz.luan/audioplayers.global/events',
        'xyz.luan/audioplayers',
      };
      final calls = <MethodCall>[];
      for (final channel in channels.toList()) {
        messenger.setMockMethodCallHandler(MethodChannel(channel), (
          call,
        ) async {
          if (channel == 'plugins.flutter.io/path_provider') {
            return support.path;
          }
          calls.add(call);
          if (call.method == 'create') {
            final id = (call.arguments as Map)['playerId'];
            final events = 'xyz.luan/audioplayers/events/$id';
            channels.add(events);
            messenger.setMockMethodCallHandler(
              MethodChannel(events),
              (_) async => null,
            );
          }
          return null;
        });
      }
      final controller = await AppController.load();
      final sound = SoundscapeController();
      try {
        expect(controller.usesBuiltInCharacterWorld, isFalse);
        await sound.sync(controller, worldMapVisible: false);
        await sound.sync(controller, worldMapVisible: true);
        expect(
          calls.where(
            (call) =>
                call.method.startsWith('setSource') || call.method == 'resume',
          ),
          isEmpty,
        );
      } finally {
        await sound.dispose();
        await controller.flushModelSession();
        controller.dispose();
        for (final channel in channels) {
          messenger.setMockMethodCallHandler(MethodChannel(channel), null);
        }
        await support.delete(recursive: true);
      }
    },
  );
}
