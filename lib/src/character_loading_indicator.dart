import 'package:flutter/material.dart';

import 'app_localization.dart';

/// A model-independent loading surface; no character artwork is bundled here.
class CharacterLoadingPanel extends StatelessWidget {
  const CharacterLoadingPanel({
    super.key,
    required this.language,
    this.characterName,
  });
  final AppLanguage language;
  final String? characterName;

  @override
  Widget build(BuildContext context) {
    final name = characterName?.trim() ?? '';
    final label = name.isEmpty
        ? language.text('加载中…', 'Loading…', '読み込み中…')
        : language.text('正在加载$name…', 'Loading $name…', '$nameを読み込み中…');
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xB3000000),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CharacterLoadingIndicator(size: 52),
              const SizedBox(height: 16),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CharacterLoadingIndicator extends StatelessWidget {
  const CharacterLoadingIndicator({
    super.key,
    this.size = 52,
    this.semanticsLabel = 'Loading',
  });
  final double size;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: MediaQuery.maybeOf(context)?.disableAnimations == true
        ? Icon(
            Icons.hourglass_top_rounded,
            size: size,
            semanticLabel: semanticsLabel,
          )
        : CircularProgressIndicator(semanticsLabel: semanticsLabel),
  );
}
