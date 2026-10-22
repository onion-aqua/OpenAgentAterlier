import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_speech_driver.dart';

void main() {
  test('authored asymmetric ambient limits constrain each motion axis', () {
    final profile = CharacterPerformanceProfile.parse(
      jsonEncode({
        'projectConfig': {
          'ambientGaze': {
            'yawLimit': 0.8,
            'pitchDownLimit': -0.3,
            'pitchUpLimit': 0.6,
            'rollMinusLimit': -0.2,
            'rollPlusLimit': 0.4,
          },
        },
      }),
    );
    final positive = profile.constrainAmbient(const RigMotion(1, 1, 1));
    final negative = profile.constrainAmbient(const RigMotion(-1, -1, -1));
    expect([positive.yaw, positive.pitch, positive.roll], [0.8, 0.6, 0.4]);
    expect([negative.yaw, negative.pitch, negative.roll], [-0.8, -0.3, -0.2]);
  });

  test('skins without ambient configuration retain their motion', () {
    final motion = CharacterPerformanceProfile.fallback().constrainAmbient(
      const RigMotion(0.7, -0.5, 0.4),
    );
    expect([motion.yaw, motion.pitch, motion.roll], [0.7, -0.5, 0.4]);
  });
}
