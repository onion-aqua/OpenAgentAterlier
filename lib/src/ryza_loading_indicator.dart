import 'package:flutter/material.dart';

import 'app_localization.dart';
import 'character_loading_indicator.dart';

/// Compatibility wrapper for integrations using the former class name.
/// The loading UI contains no bundled character artwork.
class RyzaLoadingPanel extends StatelessWidget {
  const RyzaLoadingPanel({
    super.key,
    required this.language,
    this.characterName,
  });

  final AppLanguage language;
  final String? characterName;

  @override
  Widget build(BuildContext context) =>
      CharacterLoadingPanel(language: language, characterName: characterName);
}

class RyzaLoadingIndicator extends StatelessWidget {
  const RyzaLoadingIndicator({
    super.key,
    this.size = 112,
    this.frameDuration = const Duration(milliseconds: 150),
    this.semanticsLabel = 'Loading',
  });

  final double size;
  // Retained for compatibility with older callers; no image frames are loaded.
  final Duration frameDuration;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) =>
      CharacterLoadingIndicator(size: size, semanticsLabel: semanticsLabel);
}
