part of '../flutter_live2d.dart';

// ---------------------------------------------------------------------------
// Asset cache — internal helpers for resolving model directories.
// ---------------------------------------------------------------------------
//
// `Live2DViewController.loadModel` accepts either an absolute filesystem
// path or an asset directory declared in `pubspec.yaml`. The native side
// only understands filesystem paths, so asset directories must be extracted
// to disk first. This file owns that resolution logic plus a
// per-app-launch cache so each asset directory is extracted at most once.
// ---------------------------------------------------------------------------

/// Per-process cache mapping asset directory → resolved on-disk path.
///
/// Entries are inserted lazily on first call to [_resolveModelDir] and live
/// for the lifetime of the app. Filesystem-side caching uses a `.ready`
/// marker so subsequent app launches that hit an already-populated
/// directory skip the actual copy.
final Map<String, Future<String>> _resolvedAssetDirs = {};

/// Returns `true` for absolute Unix or Windows-style paths.
bool _isAbsolutePath(String path) {
  if (path.startsWith('/')) return true;
  return RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path);
}

/// Appends a trailing slash if missing.
String _ensureTrailingSlash(String path) {
  if (path.endsWith('/')) return path;
  return '$path/';
}

/// Resolves [modelDir] to a platform-specific model base path.
///
/// Native platforms receive an absolute filesystem path. Web receives an
/// asset or network URL that preserves relative references in model JSON.
///
/// Throws [Live2DException] code `INVALID_ARGS` when [modelDir] is empty
/// or refers to an asset directory with no declared assets.
Future<String> _resolveModelDir(String modelDir) async {
  final normalized = modelDir.trim();
  if (normalized.isEmpty) {
    throw Live2DException(
      'INVALID_ARGS',
      'modelDir must not be empty.',
    );
  }
  if (kIsWeb) {
    return _resolvedAssetDirs.putIfAbsent(
      normalized,
      () => _resolveWebModelDir(normalized),
    );
  }
  if (_isAbsolutePath(normalized)) {
    return _ensureTrailingSlash(normalized);
  }
  return _resolvedAssetDirs.putIfAbsent(
    normalized,
    () => _extractAssetDirToCache(normalized),
  );
}

Future<String> _resolveWebModelDir(String modelDir) async {
  final uri = Uri.tryParse(modelDir);
  if (modelDir.startsWith('/') || (uri != null && uri.hasScheme)) {
    return _ensureTrailingSlash(modelDir);
  }

  final normalizedAssetDir = _ensureTrailingSlash(modelDir);
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final hasAssets = manifest
      .listAssets()
      .any((asset) => asset.startsWith(normalizedAssetDir));
  if (!hasAssets) {
    throw Live2DException(
      'INVALID_ARGS',
      'No assets found under "$modelDir". '
          'Did you declare it under flutter.assets in pubspec.yaml?',
    );
  }
  return _ensureTrailingSlash('assets/$normalizedAssetDir');
}

/// Copies every asset under [assetDir] into a per-app cache directory and
/// returns the resolved on-disk path.
///
/// A `.ready` marker file lets the function skip extraction on subsequent
/// runs that find an already-populated directory. The cache key is the
/// base64 of the asset directory name to avoid collisions on the disk.
Future<String> _extractAssetDirToCache(String assetDir) async {
  final normalizedAssetDir = _ensureTrailingSlash(assetDir);
  final tempPath = await FlutterLive2dPlatform.instance.getTempDirectory();
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final assetKeys = manifest
      .listAssets()
      .where((k) => k.startsWith(normalizedAssetDir))
      .toList();
  if (assetKeys.isEmpty) {
    throw Live2DException(
      'INVALID_ARGS',
      'No assets found under "$assetDir". '
          'Did you declare it under flutter.assets in pubspec.yaml?',
    );
  }

  return native_asset_writer.writeAssetDirectory(
    assetDir: normalizedAssetDir,
    assetKeys: assetKeys,
    tempPath: tempPath,
    bundle: rootBundle,
  );
}
