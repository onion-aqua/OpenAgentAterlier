import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'local_skin_store.dart';

/// The selected model is not available in this character's imported resources.
/// This is an expected import state, not a reason to load another character.
class MissingImportedCharacterAssets implements Exception {
  const MissingImportedCharacterAssets(this.assetName, this.characterId);

  final String assetName;
  final String characterId;

  @override
  String toString() =>
      '尚未导入角色 $characterId 的模型资源（$assetName），请先导入 Spine 模型包并完成动作映射。';
}

class ProtectedCharacterAssetBundle extends CachingAssetBundle {
  ProtectedCharacterAssetBundle(this._files);

  factory ProtectedCharacterAssetBundle.withTexture(
    Map<String, Uint8List> original,
    Uint8List? texture,
  ) {
    // Decrypted packs deliberately expose an immutable map. Never mutate it.
    final files = Map<String, Uint8List>.of(original);
    if (texture != null) {
      final pages = files.keys.where((key) => key.endsWith('.png')).toList();
      if (pages.length != 1) {
        throw FlutterError('Expected one character texture page');
      }
      files[pages.single] = texture;
    }
    return ProtectedCharacterAssetBundle(files);
  }

  final Map<String, Uint8List> _files;

  @override
  Future<ByteData> load(String key) async {
    final normalized = key.replaceAll('\\', '/');
    final bytes = _files[normalized];
    if (bytes == null) {
      throw FlutterError('Protected character asset not found: $normalized');
    }
    return ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
  }
}

class ProtectedCharacterAssets {
  ProtectedCharacterAssets._();

  static String? _activeCacheKey;
  static Future<ProtectedCharacterAssetBundle>? _activeBundle;
  static final Map<String, Future<Uint8List>> _previews = {};

  static Future<ProtectedCharacterAssetBundle> bundleFor(
    String assetName, {
    String characterId = 'ryza',
  }) {
    final cacheKey = '$characterId/$assetName';
    if (_activeCacheKey == cacheKey && _activeBundle != null) {
      return _activeBundle!;
    }
    final future = _loadBundle(assetName, characterId);
    _activeCacheKey = cacheKey;
    _activeBundle = future;
    return future;
  }

  static Future<Uint8List> previewFor(
    String assetName, {
    String characterId = 'ryza',
  }) => _previews.putIfAbsent(
    '$characterId/$assetName',
    () => _loadPreview(assetName, characterId),
  );

  static Future<ProtectedCharacterAssetBundle> _loadBundle(
    String assetName,
    String characterId,
  ) async {
    final files = await originalFilesFor(assetName, characterId: characterId);
    final texture = await LocalSkinStore.instance.textureFor(assetName);
    return ProtectedCharacterAssetBundle.withTexture(files, texture);
  }

  static Future<Map<String, Uint8List>> originalFilesFor(
    String assetName, {
    String characterId = 'ryza',
  }) async {
    final local = await LocalSkinStore.instance.filesFor(
      assetName,
      characterId: characterId,
    );
    if (local != null) {
      return local;
    }
    throw MissingImportedCharacterAssets(assetName, characterId);
  }

  static Future<Uint8List> _loadPreview(
    String assetName,
    String characterId,
  ) async {
    final store = LocalSkinStore.instance;
    await store.initialize();
    if (!store.containsPackage(assetName, characterId: characterId)) {
      throw MissingImportedCharacterAssets(assetName, characterId);
    }
    final preview = await store.previewFor(assetName, characterId: characterId);
    if (preview == null) {
      throw FlutterError('Imported character preview not found: $assetName');
    }
    return preview;
  }

  static void clearCache() {
    _activeCacheKey = null;
    _activeBundle = null;
    _previews.clear();
  }
}
