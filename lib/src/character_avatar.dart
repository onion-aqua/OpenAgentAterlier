import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app_localization.dart';
import 'character_appearance.dart';
import 'character_runtime_profile.dart';
import 'protected_character_assets.dart';

/// The current model's preview, with its name as a fallback. Legacy storage
/// owner IDs never select a bundled character portrait.
class CharacterAvatar extends StatelessWidget {
  const CharacterAvatar({
    super.key,
    required this.profile,
    required this.language,
    this.size = 28,
    this.foreground,
    this.background,
  });

  final CharacterRuntimeProfile profile;
  final AppLanguage language;
  final double size;
  final Color? foreground;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final name = profile.names.forLocale(language.name).trim();
    final model = profile.resourceNamespace.startsWith('model/')
        ? importedModelAppearances()
              .where((item) => item.id == profile.defaultAppearanceId)
              .firstOrNull
        : null;
    final fallback = Center(
      child: model == null || name.isEmpty
          ? Icon(
              Icons.person_outline_rounded,
              size: size * .6,
              color: foreground ?? colors.onSurface,
            )
          : Text(
              name.characters.first.toUpperCase(),
              key: const ValueKey('character-avatar-initial'),
              style: TextStyle(
                fontSize: size * .48,
                fontWeight: FontWeight.w700,
                color: foreground ?? colors.onSurface,
              ),
            ),
    );
    return Semantics(
      image: true,
      label: name,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: background ?? colors.onSurface.withValues(alpha: .12),
          border: Border.all(color: colors.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: model?.hasPreview == true
            ? FutureBuilder<Uint8List>(
                key: ValueKey('character-avatar-${model!.id}'),
                future: ProtectedCharacterAssets.previewFor(
                  model.assetName,
                  characterId: model.characterId,
                ),
                builder: (context, snapshot) => snapshot.hasData
                    ? Image.memory(
                        snapshot.data!,
                        fit: BoxFit.cover,
                        excludeFromSemantics: true,
                        errorBuilder: (_, _, _) => fallback,
                      )
                    : fallback,
              )
            : fallback,
      ),
    );
  }
}
