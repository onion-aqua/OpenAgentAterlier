import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/model_package_store.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_audio.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_reply.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_records.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_session.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_settings.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_ui_models.dart';
import 'package:ryza_chat_mvp/src/realtime_call/local_call_asr.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final provider in [TtsProvider.fishAudio, TtsProvider.fishAudioMcp]) {
    test(
      '$provider requires an explicitly configured current model voice',
      () async {
        final fixture = await _ProviderFixture.create(provider);
        addTearDown(fixture.dispose);
        fixture.app.fishAudioReferenceId = '';
        fixture.app.fishMcpVoice = '';
        // Calls always use the ordinary voice, even if the chat was in ASMR.
        fixture.app.setTtsVoiceMode(TtsVoiceMode.asmr);
        await fixture.controller.startCall(
          'primary:${fixture.app.activeConversationScopeId}',
        );
        expect(fixture.controller.snapshot.phase, CallUiPhase.failed);
        expect(fixture.controller.snapshot.error, contains('普通音色 ID'));
        expect(fixture.mcpRequests, isEmpty);
        expect(fixture.restRequests, isEmpty);
        expect(fixture.asr.starts, 0);
      },
    );
  }

  test(
    'sleeping character explains how to unlock calls without starting audio',
    () async {
      final fixture = await _ProviderFixture.create(TtsProvider.fishAudioMcp);
      addTearDown(fixture.dispose);
      fixture.app.startColdLaunchGreeting();
      await fixture.controller.startCall(
        'primary:${fixture.app.activeConversationScopeId}',
      );
      expect(fixture.controller.snapshot.error, contains('唤醒'));
      expect(fixture.asr.starts, 0);
      expect(fixture.preparedModels, isEmpty);
      expect(fixture.keyReads, 0);
      expect(fixture.mcpRequests, isEmpty);
    },
  );

  test(
    'MCP Drama 3 inherits its own voice/model without reading REST key',
    () async {
      final fixture = await _ProviderFixture.create(TtsProvider.fishAudioMcp);
      addTearDown(fixture.dispose);
      await fixture.controller.startCall(
        'primary:${fixture.app.activeConversationScopeId}',
      );
      expect(fixture.controller.snapshot.phase, CallUiPhase.listening);
      expect(fixture.preparedModels, ['drama-3']);
      expect(fixture.keyReads, 0);
      await fixture.playTurn();
      expect(fixture.mcpRequests, hasLength(1));
      expect(fixture.mcpRequests.single, (
        text: '听得到。',
        voice: 'mcp-normal-voice',
        model: 'drama-3',
        key: '',
      ));
      expect(fixture.restRequests, isEmpty);
      expect(fixture.keyReads, 0);
    },
  );

  test('REST uses only its REST key and ordinary voice/model', () async {
    final fixture = await _ProviderFixture.create(TtsProvider.fishAudio);
    addTearDown(fixture.dispose);
    await fixture.controller.startCall(
      'primary:${fixture.app.activeConversationScopeId}',
    );
    expect(fixture.controller.snapshot.phase, CallUiPhase.listening);
    expect(fixture.keyReads, 1);
    expect(fixture.preparedModels, isEmpty);
    await fixture.playTurn();
    expect(fixture.restRequests.single, (
      text: '听得到。',
      voice: 'rest-normal-voice',
      model: 's2.1-pro',
      key: 'independent-rest-key',
    ));
    expect(fixture.mcpRequests, isEmpty);
  });

  test('legacy overrides cannot replace shared MCP model or voice', () async {
    final fixture = await _ProviderFixture.create(
      TtsProvider.fishAudioMcp,
      callModel: 'call-specific-backend',
      callVoice: 'call-specific-voice',
    );
    addTearDown(fixture.dispose);
    await fixture.controller.startCall(
      'primary:${fixture.app.activeConversationScopeId}',
    );
    await fixture.playTurn();
    expect(fixture.preparedModels, ['drama-3']);
    expect(fixture.mcpRequests.single.model, 'drama-3');
    expect(fixture.mcpRequests.single.voice, 'mcp-normal-voice');
    expect(fixture.keyReads, 0);
    expect(fixture.restRequests, isEmpty);
  });

  test(
    'MCP setup failure never reads REST key or starts a paid request',
    () async {
      final fixture = await _ProviderFixture.create(
        TtsProvider.fishAudioMcp,
        preparationError: StateError('MCP is not connected'),
      );
      addTearDown(fixture.dispose);
      await fixture.controller.startCall(
        'primary:${fixture.app.activeConversationScopeId}',
      );
      expect(fixture.controller.snapshot.phase, CallUiPhase.failed);
      expect(fixture.preparedModels, ['drama-3']);
      expect(fixture.keyReads, 0);
      expect(fixture.mcpRequests, isEmpty);
      expect(fixture.restRequests, isEmpty);
      expect(fixture.asr.starts, 0);
    },
  );

  test(
    'ending a call during MCP recovery never starts audio or generation',
    () async {
      final preparation = Completer<void>();
      final fixture = await _ProviderFixture.create(
        TtsProvider.fishAudioMcp,
        preparationWait: preparation.future,
      );
      addTearDown(fixture.dispose);
      final connecting = fixture.controller.startCall(
        'primary:${fixture.app.activeConversationScopeId}',
      );
      await _until(() => fixture.preparedModels.isNotEmpty);
      expect(fixture.controller.snapshot.phase, CallUiPhase.preparing);
      await fixture.controller.endCall();
      preparation.complete();
      await connecting;

      expect(fixture.controller.snapshot.isActive, isFalse);
      expect(fixture.asr.starts, 0);
      expect(fixture.keyReads, 0);
      expect(fixture.mcpRequests, isEmpty);
      expect(fixture.restRequests, isEmpty);
    },
  );

  test(
    'MCP synthesis error is attempted once without enabled REST fallback',
    () async {
      final fixture = await _ProviderFixture.create(
        TtsProvider.fishAudioMcp,
        synthesisError: StateError('submitted MCP generation result unknown'),
      );
      addTearDown(fixture.dispose);
      expect(fixture.app.fishMcpAutoFallback, isTrue);
      await fixture.controller.startCall(
        'primary:${fixture.app.activeConversationScopeId}',
      );
      await fixture.playTurn();
      expect(fixture.mcpRequests, hasLength(1));
      expect(fixture.restRequests, isEmpty);
      expect(fixture.keyReads, 0);
      expect(fixture.controller.snapshot.error, isNotEmpty);
      expect(fixture.output.drains, 0);
    },
  );

  test('missing REST key cannot borrow an MCP connection', () async {
    final fixture = await _ProviderFixture.create(
      TtsProvider.fishAudio,
      restKey: '',
    );
    addTearDown(fixture.dispose);
    await fixture.controller.startCall(
      'primary:${fixture.app.activeConversationScopeId}',
    );
    expect(fixture.controller.snapshot.phase, CallUiPhase.failed);
    expect(fixture.keyReads, 1);
    expect(fixture.preparedModels, isEmpty);
    expect(fixture.mcpRequests, isEmpty);
    expect(fixture.restRequests, isEmpty);
  });

  test(
    'unsupported provider is rejected without hidden Fish REST routing',
    () async {
      final fixture = await _ProviderFixture.create(TtsProvider.generic);
      addTearDown(fixture.dispose);
      await fixture.controller.startCall(
        'primary:${fixture.app.activeConversationScopeId}',
      );
      expect(fixture.controller.snapshot.phase, CallUiPhase.failed);
      expect(fixture.keyReads, 0);
      expect(fixture.preparedModels, isEmpty);
      expect(fixture.mcpRequests, isEmpty);
      expect(fixture.restRequests, isEmpty);
      expect(fixture.asr.starts, 0);
    },
  );

  for (final initial in [TtsProvider.fishAudioMcp, TtsProvider.fishAudio]) {
    test(
      'switching ${initial.name} while speaking closes the old route',
      () async {
        final fixture = await _ProviderFixture.create(initial, holdDrain: true);
        addTearDown(fixture.dispose);
        await fixture.controller.startCall(
          'primary:${fixture.app.activeConversationScopeId}',
        );
        await fixture.controller.sendText('能听到吗？');
        await fixture.output.drainStarted.future;
        expect(fixture.controller.snapshot.phase, CallUiPhase.speaking);
        fixture.app.setTtsProvider(
          initial == TtsProvider.fishAudioMcp
              ? TtsProvider.fishAudio
              : TtsProvider.fishAudioMcp,
        );
        await _until(() => !fixture.controller.snapshot.isActive);
        await fixture.controller.endCall();
        final attempts =
            fixture.mcpRequests.length + fixture.restRequests.length;
        expect(attempts, 1);
        expect(fixture.speechCancellations, greaterThanOrEqualTo(1));
        expect(fixture.asr.running, isFalse);
        expect(fixture.output.stops, greaterThanOrEqualTo(1));
        await fixture.controller.sendText('不应再生成');
        await Future<void>.delayed(Duration.zero);
        expect(
          fixture.mcpRequests.length + fixture.restRequests.length,
          attempts,
        );
        expect(
          fixture.preparedModels.length,
          initial == TtsProvider.fishAudioMcp ? 1 : 0,
        );
        expect(fixture.keyReads, initial == TtsProvider.fishAudio ? 1 : 0);
      },
    );
  }

  test(
    'contacts, transcripts and voices follow model scope and rename',
    () async {
      final fixture = await _ProviderFixture.create(TtsProvider.fishAudioMcp);
      addTearDown(fixture.dispose);
      final app = fixture.app;
      final id = app.activeConversationScopeId;
      expect(fixture.controller.contacts.single.id, 'primary:$id');
      expect(fixture.controller.contacts.single.modelId, id);
      expect(fixture.controller.contacts.single.displayName, '星见');
      expect(fixture.controller.contacts.single.avatarAsset, isNull);
      await expectLater(
        fixture.controller.startCall('primary:ryza'),
        throwsFormatException,
      );
      await fixture.controller.startCall('primary:$id');
      await fixture.playTurn();
      expect(app.messages.last.text, startsWith('主角：'));
      expect(fixture.controller.history.single.contactName, '星见');
      await fixture.controller.endCall();
      await app.setModelDisplayName('星见改名');
      expect(fixture.controller.contacts.single.id, 'primary:$id');
      expect(fixture.controller.contacts.single.displayName, '星见改名');
      expect(fixture.controller.history.single.contactName, '星见');
      await app.setCharacterAppearance('${id}_other');
      await _until(() => fixture.controller.snapshot.phase == CallUiPhase.idle);
      expect(fixture.controller.contacts.single.id, 'primary:${id}_other');
      expect(fixture.controller.contacts.single.displayName, '橘');
      expect(fixture.controller.history, isEmpty);
      expect(fixture.controller.snapshot.contact, isNull);
      expect(fixture.controller.snapshot.caption, isEmpty);
      expect(app.fishMcpVoice, isEmpty);
      expect(app.callRecords, isEmpty);
      expect(
        app.messages.any((message) => message.text.contains('听得到')),
        isFalse,
      );
      await app.setCharacterAppearance(id);
      expect(app.fishMcpVoice, 'mcp-normal-voice');
      expect(fixture.controller.history, hasLength(1));
    },
  );

  test('model switch cancels a pending MCP preparation without microphone or speech', () async {
    final pending = Completer<void>();
    final fixture = await _ProviderFixture.create(
      TtsProvider.fishAudioMcp,
      preparationWait: pending.future,
    );
    addTearDown(fixture.dispose);
    final id = fixture.app.activeConversationScopeId;
    final connecting = fixture.controller.startCall('primary:$id');
    await _until(() => fixture.preparedModels.isNotEmpty);
    await fixture.app.setCharacterAppearance('${id}_other');
    pending.complete();
    await connecting;
    await _until(() => fixture.controller.snapshot.phase == CallUiPhase.idle);
    expect(fixture.asr.starts, 0);
    expect(fixture.mcpRequests, isEmpty);
    expect(fixture.app.callRecords, isEmpty);
    expect(fixture.controller.history, isEmpty);
  });

  test('call prepares at most two sentences and plays in text order', () async {
    final first = StreamController<Uint8List>();
    final fixture = await _ProviderFixture.create(
      TtsProvider.fishAudioMcp,
      reply: '星见：第一句。第二句。第三句。',
      firstPcm: first.stream,
    );
    addTearDown(fixture.dispose);
    await fixture.controller.startCall(
      'primary:${fixture.app.activeConversationScopeId}',
    );
    await fixture.controller.sendText('继续说');
    await _until(() => fixture.mcpRequests.length == 2);
    expect(fixture.output.values, isEmpty);
    first.add(Uint8List.fromList([1, 0]));
    await first.close();
    await _until(
      () => fixture.controller.snapshot.phase == CallUiPhase.listening,
    );
    expect(fixture.mcpRequests.map((request) => request.text), [
      '第一句。',
      '第二句。',
      '第三句。',
    ]);
    expect(fixture.output.values, [1, 0, 0]);
    expect(
      fixture.app.callRecords.single.turns.single['assistant'],
      '第一句。第二句。第三句。',
    );
  });

  test('call record codec accepts the full current model name limit', () {
    final record = CallRecord(
      id: 'call',
      contactId: 'primary:model',
      contactName: '名' * 256,
      startedAt: DateTime.utc(2026),
      incoming: false,
    );
    expect(
      CallRecord.fromJson(record.toJson()).contactName,
      record.contactName,
    );
    expect(
      () =>
          CallRecord.fromJson({...record.toJson(), 'contact_name': '名' * 257}),
      throwsFormatException,
    );
  });

  testWidgets('MCP call settings explain OAuth without requiring a REST key', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(
        home: RealtimeCallSettingsPage(ttsProvider: TtsProvider.fishAudioMcp),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('call-voice-provider')),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    final notice = tester
        .widget<Text>(find.byKey(const ValueKey('call-voice-provider')))
        .data!;
    expect(notice, contains('Fish Audio MCP'));
    expect(notice, contains('不读取 REST API Key'));
    expect(notice, contains('不自动回退'));
    expect(find.byKey(const ValueKey('call-fish-model')), findsNothing);
    expect(find.byType(ActionChip), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
  });
}

typedef _SpeechRequest = ({
  String text,
  String voice,
  String model,
  String key,
});

class _ProviderFixture {
  _ProviderFixture(this.app, this.directory, this.asr, this.output);

  final AppController app;
  final Directory directory;
  final _ProviderAsr asr;
  final _ProviderOutput output;
  late final RealtimeCallController controller;
  final preparedModels = <String>[];
  final restRequests = <_SpeechRequest>[];
  final mcpRequests = <_SpeechRequest>[];
  int keyReads = 0;
  int speechCancellations = 0;

  static Future<_ProviderFixture> create(
    TtsProvider provider, {
    String callModel = '',
    String? callVoice,
    String restKey = 'independent-rest-key',
    Object? preparationError,
    Future<void>? preparationWait,
    Object? synthesisError,
    bool holdDrain = false,
    String reply = '星见：听得到。',
    Stream<Uint8List>? firstPcm,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp('call-provider-');
    final packages = ModelPackageStore.forTesting();
    await packages.initialize(storageDirectory: directory);
    final id = directory.path.split(Platform.pathSeparator).last;
    for (final (modelId, name) in [(id, '星见'), ('${id}_other', '橘')]) {
      final appearance = CharacterAppearance(
        id: modelId,
        label: name,
        description: '',
        promptDescription: '',
        assetName: modelId,
        animated: true,
        idleAnimations: const [],
        live2dModelDirectory: 'test/model',
        live2dModelFileName: 'model.model3.json',
      );
      characterAppearances.add(appearance);
      await packages.ensureModel(
        modelId: modelId,
        format: 'live2d',
        label: name,
        ownerCharacterId: 'ryza',
        files: {
          'model.json': Uint8List.fromList([123, 125]),
        },
      );
    }
    final app = await AppController.load(modelPackages: packages);
    await app.setCharacterAppearance(id);
    app.configureAi(
      enabled: true,
      baseUrl: 'https://example.test/v1',
      model: 'test-llm',
    );
    app.configureLanguages(
      interface: AppLanguage.chinese,
      narrator: AppLanguage.chinese,
      characterReply: AppLanguage.chinese,
      translation: TranslationLanguage.none,
    );
    app.fishAudioModel = 's2.1-pro';
    app.fishAudioReferenceId = 'rest-normal-voice';
    app.configureFishMcp(
      model: 'drama-3',
      voice: 'mcp-normal-voice',
      asmrVoice: 'mcp-asmr-voice',
      autoFallback: true,
    );
    app.setTtsProvider(provider);
    final files = [
      File('${directory.path}/model.int8.onnx'),
      File('${directory.path}/tokens.txt'),
      File('${directory.path}/silero_vad.onnx'),
    ];
    for (final file in files) {
      await file.writeAsBytes([1]);
    }
    final fixture = _ProviderFixture(
      app,
      directory,
      _ProviderAsr(),
      _ProviderOutput(holdDrain),
    );
    fixture.controller = RealtimeCallController(
      app: app,
      asr: fixture.asr,
      output: fixture.output,
      replies: _ProviderReplies(reply),
      settingsStore: _ProviderSettingsStore(
        CallSettings(
          asr: LocalCallAsrConfig(
            modelPath: files[0].path,
            tokensPath: files[1].path,
            vadModelPath: files[2].path,
          ),
          fishModel: callModel,
          voiceOverrides: {
            'primary:${app.activeConversationScopeId}': ?callVoice,
          },
        ),
      ),
      readFishKey: () async {
        fixture.keyReads++;
        return restKey;
      },
      prepareMcp: (model) async {
        fixture.preparedModels.add(model);
        if (preparationWait != null) await preparationWait;
        if (preparationError != null) throw preparationError;
      },
      speechFactory: (text, voice, model, key) {
        fixture.restRequests.add((
          text: text,
          voice: voice,
          model: model,
          key: key,
        ));
        return fixture.speech();
      },
      mcpSpeechFactory: (text, voice, model, key) {
        fixture.mcpRequests.add((
          text: text,
          voice: voice,
          model: model,
          key: key,
        ));
        if (firstPcm != null && fixture.mcpRequests.length == 1) {
          return CallSpeech(firstPcm, () async {
            fixture.speechCancellations++;
          });
        }
        return fixture.speech(error: synthesisError);
      },
    );
    return fixture;
  }

  CallSpeech speech({Object? error}) => CallSpeech(
    error == null
        ? Stream.value(Uint8List.fromList([0, 0, 0, 0]))
        : Stream<Uint8List>.error(error),
    () async {
      speechCancellations++;
    },
  );

  Future<void> playTurn() async {
    expect(controller.snapshot.phase, CallUiPhase.listening);
    await controller.sendText('能听到吗？');
    await _until(
      () =>
          controller.snapshot.phase == CallUiPhase.listening ||
          controller.snapshot.phase == CallUiPhase.failed,
    );
  }

  Future<void> dispose() async {
    await controller.endCall();
    controller.dispose();
    await app.flushModelSession();
    app.dispose();
    characterAppearances.removeWhere(
      (model) => model.id.startsWith(
        directory.path.split(Platform.pathSeparator).last,
      ),
    );
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

Future<void> _until(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100 && !predicate(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(predicate(), isTrue, reason: 'call provider operation did not settle');
}

class _ProviderSettingsStore extends CallSettingsStore {
  _ProviderSettingsStore(this.settings);
  final CallSettings settings;
  @override
  Future<CallSettings> load() async => settings;
}

class _ProviderReplies implements CallReplyBackend {
  const _ProviderReplies(this.text);
  final String text;
  @override
  Stream<String> reply(CallReplyRequest request) => Stream.value(text);
}

class _ProviderAsr extends LocalCallAsr {
  final _events = StreamController<LocalCallAsrEvent>.broadcast();
  bool running = false;
  int starts = 0;
  @override
  Stream<LocalCallAsrEvent> get events => _events.stream;
  @override
  Future<void> start(LocalCallAsrConfig config) async {
    starts++;
    running = true;
  }

  @override
  Future<void> stop() async {
    running = false;
  }

  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> setListeningEnabled(bool enabled) async {}
  @override
  Future<void> setPlaybackActive(
    bool active, {
    bool preserveSpeech = true,
  }) async {}
  @override
  void addPlaybackPcm(Uint8List pcm) {}
  @override
  Future<void> dispose() => _events.close();
}

class _ProviderOutput implements CallPcmOutput {
  _ProviderOutput(this.holdDrain);
  final bool holdDrain;
  final drainStarted = Completer<void>();
  final _pendingDrain = Completer<void>();
  int drains = 0, stops = 0;
  @override
  Future<void> start() async {}
  final values = <int>[];
  @override
  Future<void> write(Uint8List pcm) async {
    values.add(pcm.first);
  }

  @override
  Future<void> drain() {
    drains++;
    if (!drainStarted.isCompleted) drainStarted.complete();
    return holdDrain ? _pendingDrain.future : Future<void>.value();
  }

  @override
  Future<void> stop() async {
    stops++;
    if (holdDrain && drainStarted.isCompleted && !_pendingDrain.isCompleted) {
      _pendingDrain.completeError(StateError('playback cancelled'));
    }
  }

  @override
  Future<bool> setSpeaker(bool value) async => true;
}
