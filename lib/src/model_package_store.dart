import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/dart.dart';
import 'package:path_provider/path_provider.dart';

class ModelPackageMetadata {
  const ModelPackageMetadata({
    required this.modelId,
    required this.format,
    required this.label,
    required this.ownerCharacterId,
    required this.sourceFingerprint,
  });

  final String modelId;
  final String format;
  final String label;
  final String ownerCharacterId;
  final String sourceFingerprint;

  factory ModelPackageMetadata._fromManifest(Map<String, dynamic> value) =>
      ModelPackageMetadata(
        modelId: value['modelId'] as String,
        format: value['format'] as String,
        label: value['label'] as String,
        ownerCharacterId: value['ownerCharacterId'] as String,
        sourceFingerprint: value['sourceFingerprint'] as String,
      );
}

class DecodedModelPackage {
  const DecodedModelPackage._({
    required this.manifest,
    required this.modelFiles,
    required this.session,
    required this.saveSlots,
    required this.attachments,
  });

  final Map<String, dynamic> manifest;
  final Map<String, Uint8List> modelFiles;
  final Map<String, dynamic>? session;
  final Map<String, dynamic>? saveSlots;
  final Map<String, Uint8List> attachments;

  /// A resource-only ZIP for the existing inspection and mapping import path.
  Uint8List get modelZip => ModelPackageStore.encodeModelZip(modelFiles);
}

/// A model and its portable, model-scoped application state are one ZIP.
/// Runtime adapters may maintain extracted caches, but the ZIP is authoritative.
/// Service credentials and global connection preferences are never accepted.
class ModelPackageStore {
  ModelPackageStore._();
  ModelPackageStore.forTesting();

  static final instance = ModelPackageStore._();
  static const packageType = 'agent-atelier-model-package';
  static const version = 1;
  static const maxPackageBytes = 256 * 1024 * 1024;
  static const maxExpandedBytes = 512 * 1024 * 1024;
  static const maxModelFileBytes = 128 * 1024 * 1024;
  static const maxStateBytes = 32 * 1024 * 1024;
  static const maxEntries = 1024;

  static const sessionDataKeys = <String>{
    'format',
    'version',
    'characterId',
    'exportedAt',
    'messages',
    'memorySummary',
    'recentMemories',
    'recentMemoryCheckpoints',
    'lastRecentMemoryMessageId',
    'longTermMemoryConsolidatedCount',
    'memoryEditRevision',
    'characterState',
    'virtualPhoneCarrier',
    'npcChats',
    'settingsSlots',
    'userProfile',
    'characterMood',
    'relationshipPoints',
    'preciousItems',
    'sceneTime',
    'automaticSceneTime',
    'storyClockEnabled',
    'storyClock',
    'lastAtelierFoodDay',
    'selectedAreaId',
    'selectedStageId',
    'selectedAreaName',
    'selectedStageName',
    'selectedCharacterAppearanceId',
    'progress',
    'dynamicQuests',
    'alchemy',
    'preferences',
    'narratorLanguage',
    'characterReplyLanguage',
    'translationLanguage',
    'npcReplyLanguageOverride',
    'npcTranslationLanguageOverride',
    'modelId',
    'modelDisplayName',
    'translationOnly',
    'independentTranslation',
  };

  static const sessionPreferenceKeys = <String>{
    'agentEnabled',
    'characterPersonaInjectionEnabled',
    'worldSettingInjectionEnabled',
    'characterPersona',
    'worldSetting',
    'npcInteractionFrequency',
    'fishAudioReferenceId',
    'fishAudioAsmrReferenceId',
    'fishMcpVoice',
    'fishMcpAsmrVoice',
    'dashScopeTtsVoice',
    'dashScopeTtsAsmrVoice',
    'dashScopeTtsLanguage',
    'dashScopeTtsInstructions',
    'genericTtsVoice',
    'genericTtsAsmrVoice',
    'localTtsVoiceProfileId',
    'asmrModeEnabled',
    'ttsVoiceMode',
    'ttsEmotionIntensity',
    'ttsCueDensity',
    'ttsPreviewText',
    'longTermMemoryEnabled',
    'memoryConsolidationPrompt',
    'mimoTts',
    'independentSpeechPerformance',
    'fishAudioSpeed',
  };

  static const _gameStateKeys = <String>{...sessionDataKeys, 'roleSettings'};
  static const _manifestKeys = <String>{
    'type',
    'version',
    'modelId',
    'format',
    'label',
    'ownerCharacterId',
    'sourceFingerprint',
    'createdAt',
    'updatedAt',
    'files',
  };

  Directory? _directory;
  Future<void>? _initializing;
  Future<void> _tail = Future.value();
  final _metadata = <String, ModelPackageMetadata>{};
  final _loaded = <String, _LoadedPackage>{};
  int _writeSequence = 0;

  List<ModelPackageMetadata> get models => List.unmodifiable(_metadata.values);

  Future<void> initialize({Directory? storageDirectory}) {
    if (_directory != null) return Future.value();
    final pending = _initializing;
    if (pending != null) return pending;
    final operation = _initialize(storageDirectory);
    _initializing = operation;
    return operation.whenComplete(() => _initializing = null);
  }

  Future<void> _initialize(Directory? storageDirectory) async {
    final support = storageDirectory ?? await getApplicationSupportDirectory();
    final normalized = support.path.replaceAll('\\', '/');
    final directory = normalized.split('/').last == 'model_packages'
        ? support
        : Directory('${support.path}${Platform.pathSeparator}model_packages');
    await directory.create(recursive: true);
    final metadata = <String, ModelPackageMetadata>{};
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File || !entry.path.endsWith('.zip')) continue;
      try {
        if (await entry.length() > maxPackageBytes) continue;
        final decoded = decodePackage(await entry.readAsBytes());
        final id = decoded.manifest['modelId'] as String;
        if (entry.uri.pathSegments.last != '$id.zip') continue;
        metadata[id] = ModelPackageMetadata._fromManifest(decoded.manifest);
      } on Object {
        // Leave damaged packages intact for recovery; never overwrite them
        // with a newly initialized empty session.
      }
    }
    _metadata.addAll(metadata);
    _directory = directory;
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> flush() => _tail;

  Future<bool> exists(String modelId) async {
    _validateId(modelId);
    await initialize();
    return _metadata.containsKey(modelId) && await _file(modelId).exists();
  }

  Future<ModelPackageMetadata> ensureModel({
    required String modelId,
    required String format,
    required String label,
    required String ownerCharacterId,
    required Map<String, Uint8List> files,
  }) async {
    _validateId(modelId);
    _validateFormat(format);
    _boundedText(label, 'label', maximum: 256);
    _boundedText(ownerCharacterId, 'ownerCharacterId', maximum: 128);
    final ownFiles = _validateModelFiles(files);
    await initialize();
    return _serialize(() async {
      final file = _file(modelId);
      final previous = await file.exists() ? await _load(modelId) : null;
      if (previous != null &&
          (previous.manifest['format'] != format ||
              previous.manifest['ownerCharacterId'] != ownerCharacterId)) {
        throw const FormatException(
          'A model package cannot change its owner or format.',
        );
      }
      final now = DateTime.now().toUtc().toIso8601String();
      final manifest = <String, dynamic>{
        'type': packageType,
        'version': version,
        'modelId': modelId,
        'format': format,
        'label': label,
        'ownerCharacterId': ownerCharacterId,
        'sourceFingerprint': _fingerprint(ownFiles),
        'createdAt': previous?.manifest['createdAt'] ?? now,
        'updatedAt': now,
        'files': _fileManifest(ownFiles),
      };
      final sameAssets =
          previous != null &&
          previous.manifest['sourceFingerprint'] ==
              manifest['sourceFingerprint'];
      final archive = Archive();
      if (sameAssets) {
        for (final entry in previous.archive.files) {
          if (entry.name.startsWith('model/')) archive.add(entry);
        }
      } else {
        for (final entry in ownFiles.entries) {
          archive.add(ArchiveFile.bytes('model/${entry.key}', entry.value));
        }
      }
      _addJson(archive, 'manifest.json', manifest);
      if (previous?.session != null) {
        _addJson(archive, 'app/session.json', previous!.session!);
      }
      if (previous?.saveSlots != null) {
        _addJson(archive, 'app/save_slots.json', previous!.saveSlots!);
      }
      if (previous != null) {
        for (final entry in previous.archive.files) {
          if (entry.name.startsWith('app/attachments/')) archive.add(entry);
        }
      }
      await _commit(
        modelId,
        archive,
        manifest: manifest,
        session: previous?.session,
        saveSlots: previous?.saveSlots,
      );
      return _metadata[modelId]!;
    });
  }

  Future<void> saveSession(
    String modelId,
    Map<String, dynamic> session, {
    Map<String, dynamic>? saveSlots,
  }) async {
    _validateId(modelId);
    final ownSession = _copyJson(session);
    _validateSession(ownSession, modelId: modelId);
    final ownSlots = saveSlots == null ? null : _copyJson(saveSlots);
    if (ownSlots != null) _validateSaveSlots(ownSlots, modelId: modelId);
    await initialize();
    await _serialize(() async {
      final previous = await _load(modelId);
      final manifest = Map<String, dynamic>.of(previous.manifest)
        ..['updatedAt'] = DateTime.now().toUtc().toIso8601String();
      final archive = Archive();
      // Keep the original compressed resource streams, avoiding texture
      // recompression on each durable conversation or settings save.
      for (final entry in previous.archive.files) {
        if (entry.name.startsWith('model/') ||
            entry.name.startsWith('app/attachments/')) {
          archive.add(entry);
        }
      }
      _addJson(archive, 'manifest.json', manifest);
      _addJson(archive, 'app/session.json', ownSession);
      final slots = ownSlots ?? previous.saveSlots;
      if (slots != null) _addJson(archive, 'app/save_slots.json', slots);
      await _commit(
        modelId,
        archive,
        manifest: manifest,
        session: ownSession,
        saveSlots: slots,
      );
    });
  }

  Future<void> saveAttachment(String modelId, String name, Uint8List? bytes) =>
      saveAttachments(modelId, {name: bytes});

  Future<void> saveAttachments(
    String modelId,
    Map<String, Uint8List?> files,
  ) async {
    _validateId(modelId);
    final ownFiles = <String, Uint8List?>{};
    for (final entry in files.entries) {
      _validateAttachment(entry.key, entry.value);
      ownFiles[entry.key] = entry.value == null
          ? null
          : Uint8List.fromList(entry.value!);
    }
    await initialize();
    await _serialize(() async {
      final previous = await _load(modelId);
      final manifest = Map<String, dynamic>.of(previous.manifest)
        ..['updatedAt'] = DateTime.now().toUtc().toIso8601String();
      final archive = Archive();
      for (final entry in previous.archive.files) {
        if (entry.name == 'manifest.json') continue;
        if (entry.name.startsWith('app/attachments/') &&
            ownFiles.containsKey(entry.name.substring(16))) {
          continue;
        }
        archive.add(entry);
      }
      for (final entry in ownFiles.entries) {
        if (entry.value != null) {
          archive.add(
            ArchiveFile.bytes('app/attachments/${entry.key}', entry.value!),
          );
        }
      }
      _addJson(archive, 'manifest.json', manifest);
      await _commit(
        modelId,
        archive,
        manifest: manifest,
        session: previous.session,
        saveSlots: previous.saveSlots,
      );
    });
  }

  Future<Uint8List?> readAttachment(String modelId, String name) async {
    _validateId(modelId);
    _validateAttachment(name, null);
    await initialize();
    await flush();
    if (!await _file(modelId).exists()) return null;
    final entry = (await _load(modelId)).archive.find('app/attachments/$name');
    final bytes = entry?.readBytes();
    return bytes == null ? null : Uint8List.fromList(bytes);
  }

  Future<Map<String, dynamic>?> readSession(String modelId) async {
    _validateId(modelId);
    await initialize();
    await flush();
    if (!await _file(modelId).exists()) return null;
    final session = (await _load(modelId)).session;
    return session == null ? null : _copyJson(session);
  }

  Future<Map<String, dynamic>?> readSaveSlots(String modelId) async {
    _validateId(modelId);
    await initialize();
    await flush();
    if (!await _file(modelId).exists()) return null;
    final slots = (await _load(modelId)).saveSlots;
    return slots == null ? null : _copyJson(slots);
  }

  Future<Map<String, Uint8List>> modelFiles(String modelId) async {
    _validateId(modelId);
    await initialize();
    await flush();
    final package = await _load(modelId);
    final files = <String, Uint8List>{};
    for (final entry in package.archive.files) {
      if (!entry.name.startsWith('model/')) continue;
      files[entry.name.substring(6)] = Uint8List.fromList(entry.readBytes()!);
    }
    return files;
  }

  Future<Uint8List> packageBytes(String modelId) async {
    _validateId(modelId);
    await initialize();
    await flush();
    final file = _file(modelId);
    if (await file.length() > maxPackageBytes) {
      throw const FormatException('Model package exceeds 256 MB.');
    }
    final bytes = await file.readAsBytes();
    decodePackage(bytes);
    return bytes;
  }

  Future<void> deleteModel(String modelId) async {
    _validateId(modelId);
    await initialize();
    await _serialize(() async {
      final file = _file(modelId);
      if (await file.exists()) await file.delete();
      _metadata.remove(modelId);
      _loaded.remove(modelId);
    });
  }

  File _file(String id) =>
      File('${_directory!.path}${Platform.pathSeparator}$id.zip');

  Future<_LoadedPackage> _load(String modelId) async {
    final cached = _loaded[modelId];
    if (cached != null) return cached;
    final file = _file(modelId);
    if (await file.length() > maxPackageBytes) {
      throw const FormatException('Model package exceeds 256 MB.');
    }
    final bytes = await file.readAsBytes();
    final validated = decodePackage(bytes);
    if (validated.manifest['modelId'] != modelId) {
      throw const FormatException(
        'Model package identity does not match its filename.',
      );
    }
    final loaded = _LoadedPackage(
      validated.manifest,
      ZipDecoder().decodeBytes(bytes),
      validated.session,
      validated.saveSlots,
    );
    _loaded[modelId] = loaded;
    return loaded;
  }

  Future<void> _commit(
    String modelId,
    Archive archive, {
    required Map<String, dynamic> manifest,
    Map<String, dynamic>? session,
    Map<String, dynamic>? saveSlots,
  }) async {
    var expanded = 0;
    if (archive.length > maxEntries) {
      throw const FormatException('Too many model package entries.');
    }
    for (final entry in archive.files) {
      expanded += entry.size;
    }
    if (expanded > maxExpandedBytes) {
      throw const FormatException('Expanded model package exceeds its limit.');
    }
    final bytes = ZipEncoder().encodeBytes(archive);
    if (bytes.length > maxPackageBytes) {
      throw const FormatException('Model package exceeds 256 MB.');
    }
    final target = _file(modelId);
    final pending = File('${target.path}.pending.${++_writeSequence}');
    try {
      await pending.writeAsBytes(bytes, flush: true);
      // File.rename replaces the destination atomically on supported local
      // Android/Windows filesystems. No delete-before-rename data loss window.
      await pending.rename(target.path);
    } finally {
      if (await pending.exists()) await pending.delete();
    }
    _metadata[modelId] = ModelPackageMetadata._fromManifest(manifest);
    _loaded[modelId] = _LoadedPackage(
      manifest,
      ZipDecoder().decodeBytes(bytes),
      session,
      saveSlots,
    );
  }

  static Uint8List encodeModelZip(Map<String, Uint8List> files) {
    final checked = _validateModelFiles(files);
    final archive = Archive();
    for (final entry in checked.entries) {
      archive.add(ArchiveFile.bytes(entry.key, entry.value));
    }
    final result = ZipEncoder().encodeBytes(archive);
    if (result.length > maxPackageBytes) {
      throw const FormatException('Model ZIP exceeds 256 MB.');
    }
    return result;
  }

  static DecodedModelPackage decodePackage(Uint8List bytes) {
    final files = _decodeBoundedZip(bytes);
    final manifest = _readJson(files.remove('manifest.json'), 'manifest');
    _allowedKeys(manifest, _manifestKeys, 'manifest');
    if (manifest['type'] != packageType || manifest['version'] != version) {
      throw const FormatException('Unsupported model package type or version.');
    }
    final modelId = manifest['modelId'];
    if (modelId is! String) {
      throw const FormatException('Invalid model identity.');
    }
    _validateId(modelId);
    _validateFormat(manifest['format']);
    _boundedText(manifest['label'], 'label', maximum: 256);
    _boundedText(
      manifest['ownerCharacterId'],
      'ownerCharacterId',
      maximum: 128,
    );
    for (final field in ['createdAt', 'updatedAt']) {
      final value = manifest[field];
      if (value is! String || DateTime.tryParse(value) == null) {
        throw FormatException('Invalid model package $field.');
      }
    }
    final sessionBytes = files.remove('app/session.json');
    final slotsBytes = files.remove('app/save_slots.json');
    final attachments = <String, Uint8List>{};
    final modelFiles = <String, Uint8List>{};
    for (final entry in files.entries) {
      if (entry.key.startsWith('app/attachments/')) {
        final name = entry.key.substring(16);
        _validateAttachment(name, entry.value);
        attachments[name] = entry.value;
        continue;
      }
      if (!entry.key.startsWith('model/')) {
        throw const FormatException(
          'Unexpected file outside model package namespaces.',
        );
      }
      modelFiles[entry.key.substring(6)] = entry.value;
    }
    _validateModelFiles(modelFiles, copy: false);
    if (manifest['sourceFingerprint'] != _fingerprint(modelFiles) ||
        jsonEncode(manifest['files']) !=
            jsonEncode(_fileManifest(modelFiles))) {
      // Compare field content independently of source JSON key ordering.
      final expected = _fileManifest(modelFiles);
      if (manifest['sourceFingerprint'] != _fingerprint(modelFiles) ||
          !_equalFileManifest(manifest['files'], expected)) {
        throw const FormatException(
          'Model package resource integrity check failed.',
        );
      }
    }
    final session = sessionBytes == null
        ? null
        : _readJson(sessionBytes, 'session');
    if (session != null) _validateSession(session, modelId: modelId);
    final saveSlots = slotsBytes == null
        ? null
        : _readJson(slotsBytes, 'save slots');
    if (saveSlots != null) _validateSaveSlots(saveSlots, modelId: modelId);
    return DecodedModelPackage._(
      manifest: Map.unmodifiable(manifest),
      modelFiles: Map.unmodifiable(modelFiles),
      session: session,
      saveSlots: saveSlots,
      attachments: Map.unmodifiable(attachments),
    );
  }

  static bool _equalFileManifest(
    Object? actual,
    Map<String, dynamic> expected,
  ) {
    if (actual is! Map || actual.length != expected.length) return false;
    for (final entry in expected.entries) {
      final item = actual[entry.key];
      final wanted = entry.value as Map;
      if (item is! Map ||
          item.length != 2 ||
          item['size'] != wanted['size'] ||
          item['sha256'] != wanted['sha256']) {
        return false;
      }
    }
    return true;
  }

  static Map<String, dynamic> _fileManifest(Map<String, Uint8List> files) => {
    for (final path in files.keys.toList()..sort())
      path: {'size': files[path]!.length, 'sha256': _sha256(files[path]!)},
  };

  static String _fingerprint(Map<String, Uint8List> files) =>
      _sha256(utf8.encode(jsonEncode(_fileManifest(files))));

  static String _sha256(List<int> bytes) => const DartSha256()
      .hashSync(bytes)
      .bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();

  static Map<String, Uint8List> _validateModelFiles(
    Map<String, Uint8List> files, {
    bool copy = true,
  }) {
    if (files.isEmpty || files.length > maxEntries - 3) {
      throw const FormatException(
        'Model package must contain 1–1021 model files.',
      );
    }
    final seen = <String>{};
    var size = 0;
    final output = <String, Uint8List>{};
    for (final entry in files.entries) {
      final path = _safePath(entry.key);
      if (!seen.add(path.toLowerCase())) {
        throw const FormatException('Duplicate model resource path.');
      }
      size += entry.value.length;
      if (entry.value.length > maxModelFileBytes || size > maxExpandedBytes) {
        throw const FormatException(
          'Model resources exceed the package size limit.',
        );
      }
      output[path] = copy ? Uint8List.fromList(entry.value) : entry.value;
    }
    for (final path in seen) {
      final parts = path.split('/');
      for (var index = 1; index < parts.length; index++) {
        if (seen.contains(parts.take(index).join('/'))) {
          throw const FormatException(
            'Model file and directory paths conflict.',
          );
        }
      }
    }
    return output;
  }

  static void _validateSession(
    Map<String, dynamic> session, {
    required String modelId,
  }) {
    _allowedKeys(session, const {
      'format',
      'version',
      'modelId',
      'identity',
      'data',
    }, 'session');
    if (session['format'] != 'agent-atelier-model-session' ||
        session['version'] != 1 ||
        session['modelId'] != modelId) {
      throw const FormatException('Invalid or mismatched model session.');
    }
    final identity = _object(session['identity'], 'identity');
    _allowedKeys(identity, const {'displayName'}, 'identity');
    _boundedText(identity['displayName'], 'displayName', maximum: 256);
    final data = _object(session['data'], 'session data');
    if (data['modelId'] != null && data['modelId'] != modelId) {
      throw const FormatException(
        'Model session data belongs to another model.',
      );
    }
    _validateSessionData(data);
  }

  static void _validateAttachment(String name, Uint8List? bytes) {
    _safePath(name);
    if (name != 'texture.png' &&
        name != 'texture-state.json' &&
        !RegExp(
          r'^collections/[a-zA-Z0-9_.-]+\.(png|jpg|jpeg|webp|wav|mp3|json)$',
        ).hasMatch(name)) {
      throw const FormatException('Unsupported model attachment path.');
    }
    if (bytes == null) return;
    if (bytes.length > maxModelFileBytes) {
      throw const FormatException('Model attachment is too large.');
    }
    if (name.endsWith('.json')) {
      final value = _readJson(bytes, 'attachment');
      _validateJsonTree(value);
      if (name == 'texture-state.json') {
        _allowedKeys(value, const {'enabled'}, 'texture state');
        if (value['enabled'] is! bool) {
          throw const FormatException('Invalid model texture state.');
        }
      }
    }
  }

  static void _validateSessionData(
    Map<String, dynamic> data, {
    bool gameState = false,
  }) {
    _allowedKeys(
      data,
      gameState ? _gameStateKeys : sessionDataKeys,
      'session data',
    );
    final preferences = data['preferences'];
    if (preferences != null) {
      _allowedKeys(
        _object(preferences, 'session preferences'),
        sessionPreferenceKeys,
        'session preferences',
      );
      if (preferences is Map && preferences['mimoTts'] != null) {
        _allowedKeys(_object(preferences['mimoTts'], 'Mimo voice'), const {
          'voice',
          'referenceName',
          'instructions',
          'asmrInstructions',
        }, 'Mimo voice');
      }
    }
    final role = data['roleSettings'];
    if (role != null) {
      _allowedKeys(_object(role, 'role settings'), const {
        'userProfile',
        'activeSlots',
        'characterPersona',
        'worldSetting',
        'characterPersonaInjectionEnabled',
        'worldSettingInjectionEnabled',
      }, 'role settings');
    }
    _validateJsonTree(data);
  }

  static void _validateSaveSlots(
    Map<String, dynamic> saveSlots, {
    required String modelId,
  }) {
    _allowedKeys(saveSlots, const {'active', 'slots'}, 'save slots');
    final active = saveSlots['active'];
    if (active != null && (active is! int || active < 0 || active >= 6)) {
      throw const FormatException('Invalid active model save slot.');
    }
    final slots = _object(saveSlots['slots'], 'save slots');
    if (slots.length > 6) {
      throw const FormatException('Too many model save slots.');
    }
    for (final entry in slots.entries) {
      if (!RegExp(r'^[0-5]$').hasMatch(entry.key)) {
        throw const FormatException('Invalid model save slot index.');
      }
      final slot = _object(entry.value, 'save slot');
      _allowedKeys(slot, const {
        'format',
        'version',
        'savedAt',
        'location',
        'messageCount',
        'preview',
        'snapshot',
        'name',
      }, 'save slot');
      if (slot['format'] != 'agent-atelier-r-save-slot' ||
          slot['version'] != 1) {
        throw const FormatException('Invalid model save slot version.');
      }
      final snapshot = _object(slot['snapshot'], 'save slot snapshot');
      if (snapshot['modelId'] != null && snapshot['modelId'] != modelId) {
        throw const FormatException('Save slot belongs to another model.');
      }
      _validateSessionData(snapshot, gameState: true);
    }
    _validateJsonTree(saveSlots);
  }

  static void _validateJsonTree(Object? value, [int depth = 0]) {
    if (depth > 64) {
      throw const FormatException('Model app data nesting is too deep.');
    }
    if (value == null || value is String || value is bool || value is int) {
      return;
    }
    if (value is double && value.isFinite) return;
    if (value is List) {
      for (final child in value) {
        _validateJsonTree(child, depth + 1);
      }
      return;
    }
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is! String) {
          throw const FormatException('Model app data keys must be strings.');
        }
        final key = (entry.key as String)
            .replaceAll(RegExp(r'[^a-zA-Z]'), '')
            .toLowerCase();
        if (const {
          'apikey',
          'accesstoken',
          'refreshtoken',
          'authorization',
          'pairingsecret',
          'devicetoken',
          'registrationtoken',
          'clientsecret',
          'password',
        }.contains(key)) {
          throw const FormatException(
            'Credentials cannot be stored in model app data.',
          );
        }
        _validateJsonTree(entry.value, depth + 1);
      }
      return;
    }
    throw const FormatException('Model app data must be finite JSON values.');
  }

  static Map<String, dynamic> _copyJson(Map<String, dynamic> value) {
    _validateJsonTree(value);
    final encoded = utf8.encode(jsonEncode(value));
    if (encoded.length > maxStateBytes) {
      throw const FormatException('Model app data exceeds 32 MB.');
    }
    return _readJson(Uint8List.fromList(encoded), 'app data');
  }

  static void _addJson(
    Archive archive,
    String path,
    Map<String, dynamic> value,
  ) => archive.add(ArchiveFile.string(path, jsonEncode(value)));

  static Map<String, dynamic> _readJson(Uint8List? bytes, String label) {
    if (bytes == null || bytes.length > maxStateBytes) {
      throw FormatException('Missing or oversized model package $label.');
    }
    try {
      return _object(jsonDecode(utf8.decode(bytes)), label);
    } on FormatException {
      throw FormatException('Invalid model package $label JSON.');
    }
  }

  static Map<String, dynamic> _object(Object? value, String label) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw FormatException('Expected an object for model package $label.');
    }
    return Map<String, dynamic>.from(value);
  }

  static void _allowedKeys(
    Map<String, dynamic> value,
    Set<String> allowed,
    String label,
  ) {
    if (value.keys.any((key) => !allowed.contains(key))) {
      throw FormatException(
        'Unsupported or global configuration in model $label.',
      );
    }
  }

  static void _boundedText(
    Object? value,
    String label, {
    required int maximum,
  }) {
    if (value is! String ||
        value.trim().isEmpty ||
        value.length > maximum ||
        value.contains('\u0000')) {
      throw FormatException('Invalid model $label.');
    }
  }

  static void _validateId(String id) {
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$').hasMatch(id) ||
        id.endsWith('.') ||
        RegExp(
          r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
          caseSensitive: false,
        ).hasMatch(id)) {
      throw const FormatException('Unsafe model identity.');
    }
  }

  static void _validateFormat(Object? value) {
    if (!const {'spine', 'live2d', 'vrm'}.contains(value)) {
      throw const FormatException('Unsupported model package format.');
    }
  }

  static String _safePath(String value) {
    final path = value.replaceAll('\\', '/');
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.length > 1024 ||
        path
            .split('/')
            .any(
              (part) =>
                  part.isEmpty ||
                  part == '.' ||
                  part == '..' ||
                  part.endsWith('.') ||
                  part.endsWith(' ') ||
                  RegExp(r'[\x00-\x1f\x7f<>:"|?*]').hasMatch(part) ||
                  RegExp(
                    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
                    caseSensitive: false,
                  ).hasMatch(part),
            )) {
      throw const FormatException('Unsafe model package path.');
    }
    return path;
  }

  static Map<String, Uint8List> _decodeBoundedZip(Uint8List bytes) {
    if (bytes.length > maxPackageBytes || bytes.length < 22) {
      throw const FormatException('Invalid or oversized model package ZIP.');
    }
    try {
      final directory = ZipDirectory()..read(InputMemoryStream(bytes));
      if (directory.filePosition < 0 ||
          directory.numberOfThisDisk != 0 ||
          directory.diskWithTheStartOfTheCentralDirectory != 0 ||
          directory.fileHeaders.length !=
              directory.totalCentralDirectoryEntries ||
          directory.totalCentralDirectoryEntriesOnThisDisk !=
              directory.totalCentralDirectoryEntries ||
          directory.fileHeaders.length > maxEntries ||
          directory.centralDirectoryOffset + directory.centralDirectorySize >
              directory.filePosition) {
        throw const FormatException('Invalid model package ZIP directory.');
      }
      final names = <String>{};
      final fileNames = <String>{};
      final directoryNames = <String>{};
      final entries = <(String, ZipFileHeader)>[];
      final ranges = <(int, int)>[];
      final raw = ByteData.sublistView(bytes);
      var expanded = 0;
      for (final header in directory.fileHeaders) {
        final offset = header.localHeaderOffset;
        if (offset < 0 ||
            offset + 30 > directory.centralDirectoryOffset ||
            raw.getUint32(offset, Endian.little) != 0x04034b50 ||
            raw.getUint16(offset + 6, Endian.little) !=
                header.generalPurposeBitFlag ||
            raw.getUint16(offset + 8, Endian.little) !=
                header.compressionMethod ||
            header.diskNumberStart != 0) {
          throw const FormatException('Inconsistent model ZIP local header.');
        }
        final nameLength = raw.getUint16(offset + 26, Endian.little);
        final extraLength = raw.getUint16(offset + 28, Endian.little);
        final dataStart = offset + 30 + nameLength + extraLength;
        var rangeEnd = dataStart + header.compressedSize;
        if (dataStart > directory.centralDirectoryOffset ||
            rangeEnd > directory.centralDirectoryOffset ||
            header.compressedSize < 0 ||
            nameLength == 0) {
          throw const FormatException('Truncated model ZIP local data.');
        }
        if ((header.generalPurposeBitFlag & 8) == 0) {
          if (raw.getUint32(offset + 14, Endian.little) != header.crc32 ||
              raw.getUint32(offset + 18, Endian.little) !=
                  header.compressedSize ||
              raw.getUint32(offset + 22, Endian.little) !=
                  header.uncompressedSize) {
            throw const FormatException(
              'Model ZIP local sizes disagree with its directory.',
            );
          }
        } else {
          var descriptor = rangeEnd;
          if (descriptor + 4 <= directory.centralDirectoryOffset &&
              raw.getUint32(descriptor, Endian.little) == 0x08074b50) {
            descriptor += 4;
          }
          if (descriptor + 12 > directory.centralDirectoryOffset ||
              raw.getUint32(descriptor, Endian.little) != header.crc32 ||
              raw.getUint32(descriptor + 4, Endian.little) !=
                  header.compressedSize ||
              raw.getUint32(descriptor + 8, Endian.little) !=
                  header.uncompressedSize) {
            throw const FormatException('Invalid model ZIP data descriptor.');
          }
          rangeEnd = descriptor + 12;
        }
        ranges.add((offset, rangeEnd));
        final isDirectory =
            header.filename.endsWith('/') || header.filename.endsWith('\\');
        final path = _safePath(
          isDirectory
              ? header.filename.substring(0, header.filename.length - 1)
              : header.filename,
        );
        final canonical = path.toLowerCase();
        if (!names.add(canonical)) {
          throw const FormatException('Duplicate model package ZIP path.');
        }
        final local = header.file;
        final mode = (header.externalFileAttributes >> 16) & 0xf000;
        if (local == null ||
            (mode != 0 && mode != 0x8000 && mode != 0x4000) ||
            (header.generalPurposeBitFlag & 1) != 0 ||
            (local.flags & 1) != 0 ||
            (header.compressionMethod != 0 && header.compressionMethod != 8) ||
            local.filename.replaceAll('\\', '/') !=
                header.filename.replaceAll('\\', '/') ||
            local.compressedSize != header.compressedSize ||
            local.uncompressedSize != header.uncompressedSize ||
            header.compressedSize < 0 ||
            header.uncompressedSize < 0) {
          throw const FormatException(
            'Unsafe or inconsistent model package ZIP header.',
          );
        }
        if (isDirectory) {
          if (mode == 0x8000) {
            throw const FormatException('Model ZIP entry type mismatch.');
          }
          directoryNames.add(canonical);
          continue;
        }
        if (mode == 0x4000) {
          throw const FormatException('Model ZIP entry type mismatch.');
        }
        final isAppData = path == 'manifest.json' || path.startsWith('app/');
        final limit = isAppData ? maxStateBytes : maxModelFileBytes;
        expanded += header.uncompressedSize;
        if (header.uncompressedSize > limit || expanded > maxExpandedBytes) {
          throw const FormatException(
            'Expanded model package exceeds its limit.',
          );
        }
        fileNames.add(canonical);
        final parts = canonical.split('/');
        for (var index = 1; index < parts.length; index++) {
          directoryNames.add(parts.take(index).join('/'));
        }
        entries.add((path, header));
      }
      if (fileNames.any(directoryNames.contains)) {
        throw const FormatException(
          'Model ZIP file and directory paths conflict.',
        );
      }
      ranges.sort((a, b) => a.$1.compareTo(b.$1));
      for (var index = 1; index < ranges.length; index++) {
        if (ranges[index].$1 < ranges[index - 1].$2) {
          throw const FormatException('Overlapping model ZIP entries.');
        }
      }
      final result = <String, Uint8List>{};
      for (final (path, header) in entries) {
        final output = _BoundedPackageOutput(header.uncompressedSize);
        header.file!.decompress(output);
        final data = output.getBytes();
        if (data.length != header.uncompressedSize ||
            getCrc32(data) != header.crc32) {
          throw const FormatException('Model package ZIP checksum failed.');
        }
        result[path] = data;
      }
      return result;
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Unreadable model package ZIP.');
    }
  }
}

class _LoadedPackage {
  const _LoadedPackage(
    this.manifest,
    this.archive,
    this.session,
    this.saveSlots,
  );
  final Map<String, dynamic> manifest;
  final Archive archive;
  final Map<String, dynamic>? session;
  final Map<String, dynamic>? saveSlots;
}

class _BoundedPackageOutput extends OutputMemoryStream {
  _BoundedPackageOutput(this.maximum) : super(size: min(maximum, 32 * 1024));
  final int maximum;
  void _check(int count) {
    if (count < 0 || length + count > maximum) {
      throw const FormatException(
        'Model ZIP expands beyond its declared size.',
      );
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }
}
