import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/android_companion_runtime.dart';
import 'package:ryza_chat_mvp/src/app_audio_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  final channels = <String>{};
  late AndroidCompanionRuntime runtime;
  late Map<String, Object> state;
  final players = <AppAudioPlayer>[];
  Completer<void>? activation;

  Future<void> event(String channel, Map<String, Object> value) =>
      messenger.handlePlatformMessage(
        channel,
        const StandardMethodCodec().encodeSuccessEnvelope(value),
        (_) {},
      );
  Future<void> flush() async {
    for (var i = 0; i < 15; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> signal(Map<String, Object> change) async {
    state.addAll(change);
    await event('test/companion/events', state);
    await flush();
  }

  AppAudioPlayer player() {
    final result = AppAudioPlayer(runtime: runtime);
    result.positionUpdater = null;
    players.add(result);
    return result;
  }

  List<MethodCall> playerCalls(AppAudioPlayer player, String method) => calls
      .where(
        (call) =>
            call.method == method &&
            (call.arguments as Map?)?['playerId'] == player.playerId,
      )
      .toList();
  double gain(AppAudioPlayer player) =>
      (playerCalls(player, 'setVolume').last.arguments as Map)['volume']
          as double;

  setUpAll(() async {
    for (final channel in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(channel),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        calls.add(call);
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          final name = 'xyz.luan/audioplayers/events/$id';
          channels.add(name);
          messenger.setMockMethodCallHandler(
            MethodChannel(name),
            (_) async => null,
          );
        }
        if (call.method == 'getCurrentPosition') return 0;
        return null;
      },
    );
    await AudioPlayer.global.ensureInitialized();
  });
  setUp(() async {
    calls.clear();
    activation = null;
    state = {
      'running': true,
      'muted': false,
      'stopRequested': false,
      'notificationsAllowed': true,
    };
    messenger.setMockMethodCallHandler(
      const MethodChannel('test/companion/events'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(const MethodChannel('test/companion'), (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'setAudioActive') {
        await activation?.future;
        state['audioActive'] = (call.arguments as Map)['active'] as bool;
      }
      if (call.method == 'openBackgroundSettings') return {'opened': true};
      return Map<String, Object>.from(state);
    });
    runtime = AndroidCompanionRuntime(
      enabled: true,
      methods: const MethodChannel('test/companion'),
      events: const EventChannel('test/companion/events'),
    );
    await runtime.initialize();
  });
  tearDown(() async {
    activation?.complete();
    activation = null;
    for (final item in players) {
      await item.dispose();
    }
    players.clear();
    runtime.dispose();
    await flush();
  });
  tearDownAll(() {
    for (final name in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
      'xyz.luan/audioplayers',
      'test/companion',
      'test/companion/events',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  test('call suppresses every player and restores latest user gains', () async {
    final voice = player(), music = player();
    await voice.play(_Source(), volume: .7);
    await music.play(_Source(), volume: .3);
    await signal({'muted': true, 'callActive': true});
    expect(gain(voice), 0);
    expect(gain(music), 0);
    await voice.setVolume(.4);
    expect(voice.volume, .4);
    expect(gain(voice), 0);
    await signal({'muted': false, 'callActive': false});
    expect(gain(voice), .4);
    expect(gain(music), .3);
    expect(playerCalls(voice, 'resume'), hasLength(1));
  });
  test('new playback during a call never writes an audible gain', () async {
    await signal({'muted': true, 'callActive': true});
    final voice = player();
    await voice.play(_Source(), volume: .8);
    expect(
      playerCalls(
        voice,
        'setVolume',
      ).every((call) => (call.arguments as Map)['volume'] == 0),
      true,
    );
    await signal({'muted': false, 'callActive': false});
    expect(gain(voice), .8);
  });
  test(
    'audio focus snapshot is applied before resume, including denied focus',
    () async {
      final voice = player();
      state['muted'] = true;
      await voice.resume();
      expect(gain(voice), 0);
      final resume = calls.indexWhere((call) => call.method == 'resume');
      final focus = calls.indexWhere((call) => call.method == 'setAudioActive');
      expect(focus, lessThan(resume));
      await signal({'muted': false});
      expect(gain(voice), 1);
    },
  );
  test('pause while waiting for focus prevents a late resume', () async {
    final voice = player();
    activation = Completer<void>();
    final pending = voice.resume();
    await flush();
    await voice.pause();
    activation!.complete();
    activation = null;
    await pending;
    await flush();
    expect(playerCalls(voice, 'resume'), isEmpty);
    expect(state['audioActive'], false);
  });
  test('stop during source preparation cancels playback', () async {
    final voice = player();
    final source = _Source(Completer<void>());
    final pending = voice.play(source);
    await flush();
    await voice.stop();
    source.barrier!.complete();
    await pending;
    await signal({'muted': true});
    await signal({'muted': false});
    expect(playerCalls(voice, 'resume'), isEmpty);
  });
  test('completion releases focus except for a looping player', () async {
    final voice = player();
    await voice.resume();
    await event('xyz.luan/audioplayers/events/${voice.playerId}', {
      'event': 'audio.onComplete',
    });
    await flush();
    expect(state['audioActive'], false);
    await voice.setReleaseMode(ReleaseMode.loop);
    await voice.resume();
    await event('xyz.luan/audioplayers/events/${voice.playerId}', {
      'event': 'audio.onComplete',
    });
    await flush();
    expect(state['audioActive'], true);
  });
  test('stopping one player retains focus for another and notification stop stops both', () async {
    final voice = player(), music = player();
    await voice.resume();
    await music.resume();
    await voice.stop();
    await flush();
    expect(state['audioActive'], true);
    await signal({'stopRequested': true});
    expect(music.state, PlayerState.stopped);
    expect(gain(music), 0);
    expect(state['audioActive'], false);
    await expectLater(music.resume(), throwsStateError);
    expect(playerCalls(music, 'resume'), hasLength(1));
  });
  test(
    'disposing during a call cannot resume or update the disposed backend',
    () async {
      final voice = player();
      await voice.resume();
      await signal({'muted': true});
      await voice.dispose();
      final count = calls.length;
      await signal({'muted': false});
      expect(calls.length, count);
    },
  );
  test('opening vendor settings does not replace runtime state', () async {
    await runtime.openBackgroundSettings();
    expect(runtime.running, true);
    expect(runtime.notificationsAllowed, true);
  });
  test('finishing one player never reclaims focus for another', () async {
    final voice = player(), music = player();
    await voice.resume();
    await music.resume();
    await signal({'muted': true});
    calls.clear();
    await voice.stop();
    await flush();
    expect(calls.any((call) => call.method == 'setAudioActive'), false);
    expect(runtime.muted, true);
  });
  test('last player stops its backend before releasing focus', () async {
    final voice = player();
    await voice.resume();
    calls.clear();
    await voice.stop();
    await flush();
    final stopped = calls.indexWhere((call) => call.method == 'stop');
    final released = calls.indexWhere(
      (call) => call.method == 'setAudioActive',
    );
    expect(stopped, isNonNegative);
    expect(released, greaterThan(stopped));
  });
  test(
    'rejected playback in a stopped session leaves no phantom focus owner',
    () async {
      final voice = player();
      await signal({'stopRequested': true});
      await expectLater(voice.play(_Source()), throwsStateError);
      await signal({'stopRequested': false});
      final music = player();
      await music.resume();
      await music.stop();
      await flush();
      expect(state['audioActive'], false);
    },
  );
  test(
    'initialize preserves a session explicitly stopped from its notification',
    () async {
      runtime.dispose();
      state['running'] = false;
      state['stopRequested'] = true;
      calls.clear();
      runtime = AndroidCompanionRuntime(
        enabled: true,
        methods: const MethodChannel('test/companion'),
        events: const EventChannel('test/companion/events'),
      );
      await runtime.initialize();
      expect(calls.any((call) => call.method == 'start'), false);
    },
  );
  test(
    'desktop runtime leaves playback at requested volume without Android calls',
    () async {
      final desktop = AndroidCompanionRuntime(enabled: false);
      final voice = AppAudioPlayer(runtime: desktop)..positionUpdater = null;
      try {
        calls.clear();
        await voice.play(_Source(), volume: .6);
        expect(gain(voice), .6);
        expect(calls.any((call) => call.method == 'setAudioActive'), false);
      } finally {
        await voice.dispose();
        desktop.dispose();
      }
    },
  );
}

class _Source extends Source {
  _Source([this.barrier]);
  final Completer<void>? barrier;
  @override
  String? get mimeType => null;
  @override
  Future<void> setOnPlayer(AudioPlayer player) async {
    await barrier?.future;
  }
}
