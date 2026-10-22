import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class AttachmentThumbnailStore {
  AttachmentThumbnailStore._();

  static const _directoryName = 'chat_attachment_thumbnails';
  static const _maxThumbnailBytes = 2 * 1024 * 1024;
  static final _validKey = RegExp(r'^thumb_[0-9]+_[0-9]+\.png$');
  static int _sequence = 0;

  @visibleForTesting
  static Directory? debugDirectoryOverride;

  static Future<String?> write(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > _maxThumbnailBytes) return null;
    try {
      final directory = await _directory();
      await directory.create(recursive: true);
      final key =
          'thumb_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}.png';
      final file = File('${directory.path}${Platform.pathSeparator}$key');
      await file.writeAsBytes(bytes, flush: true);
      return key;
    } on FileSystemException {
      return null;
    }
  }

  static Future<Uint8List?> read(String? key) async {
    if (key == null || !_validKey.hasMatch(key)) return null;
    try {
      final directory = await _directory();
      final file = File('${directory.path}${Platform.pathSeparator}$key');
      if (!await file.exists()) return null;
      final length = await file.length();
      if (length <= 0 || length > _maxThumbnailBytes) return null;
      return await file.readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  static Future<Directory> _directory() async {
    final override = debugDirectoryOverride;
    if (override != null) return override;
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}${Platform.pathSeparator}$_directoryName');
  }
}
