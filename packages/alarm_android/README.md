# Android alarm audio integration

This is the Android module from the MIT-licensed `alarm` 5.12.0 dependency,
including the existing boot/snooze fixes in this checkout. The Dart package and
generated platform channel API remain unchanged. `android/settings.gradle.kts`
selects this controlled module instead of the mutable Pub cache.

Local changes:

- Native alarm playback observes communication audio modes and, when already
  permitted, phone state even if the process starts without Flutter.
- Players start at zero gain. The current fade envelope is applied only after
  audio focus is granted and no call is active. A call or focus loss/duck mutes
  the player; focus restoration restores the current fade envelope.
- Polling runs every 300 ms only while an alarm player exists, with immediate
  Android 12+ audio mode callbacks. Disposal removes monitoring and focus.
- Alarm volume applies to app player gain. No system stream volume is changed
  or enforced, so the device alarm/media volume still limits loudness.

Public Android APIs cannot identify a private VoIP call exposing neither a
communication audio mode nor audio focus. OEM background restrictions and
notification/foreground-service permissions still apply.

Only source files and tests are copied; no Pub build output is included.
Retain `LICENSE` when redistributing. Unit tests can run with
`android/gradlew.bat :alarm:testDebugUnitTest`. A successful APK build alone
does not verify real telephone or VoIP calls.
