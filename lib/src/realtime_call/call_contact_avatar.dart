import 'package:flutter/material.dart';

import '../app_localization.dart';
import '../character_avatar.dart';
import '../character_runtime_profile.dart';
import 'call_ui_models.dart';

/// Call contacts share the imported model preview and neutral fallback used
/// by chat; a legacy storage owner never selects a bundled character image.
class CallContactAvatar extends StatelessWidget {
  const CallContactAvatar({
    super.key,
    required this.contact,
    required this.language,
    this.size = 46,
  });

  final CallContact contact;
  final AppLanguage language;
  final double size;

  @override
  Widget build(BuildContext context) => CharacterAvatar(
    profile: characterRuntimeNeutralProfile(
      modelId: contact.modelId,
      displayName: contact.displayName,
    ),
    language: language,
    size: size,
    foreground: Colors.white,
    background: Colors.white.withValues(alpha: .14),
  );
}
