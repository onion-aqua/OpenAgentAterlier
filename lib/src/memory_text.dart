import 'chat_segments.dart' show speechDeliveryTags, speechEmotionTags;
import 'fish_drama3_tags.dart';

final _privateMemoryBlocks = RegExp(
  r'\\?<(think|tool_call|function_call|horae|horaeevent)\b[^>]*>[\s\S]*?\\?</\1\s*>',
  caseSensitive: false,
);
final _unfinishedPrivateMemoryBlock = RegExp(
  r'\\?<(?:think|tool_call|function_call|horae|horaeevent)\b[^>]*>[\s\S]*$',
  caseSensitive: false,
);
final _memoryMarkup = RegExp(
  r'\\?</?(?:answer|code)\b[^>]*>|<[^>]+>',
  caseSensitive: false,
);
final _memoryCue = RegExp(r'\[([^\[\]\r\n]+)\]');

/// Removes delivery/control metadata without treating ordinary bracketed
/// names or facts as tags. Memory must describe events, not speech direction.
String cleanMemoryText(String value, {bool preserveLines = false}) {
  final cleaned = value
      .replaceAll(_privateMemoryBlocks, ' ')
      .replaceAll(_unfinishedPrivateMemoryBlock, ' ')
      .replaceAll(_memoryMarkup, '')
      .replaceAllMapped(_memoryCue, (match) {
        final cue = match.group(1)!.trim().toLowerCase();
        final emotion = cue.replaceFirst(
          RegExp(r'^(?:slightly|very|extremely)\s+'),
          '',
        );
        if (speechEmotionTags.contains(emotion) ||
            speechDeliveryTags.contains(cue) ||
            fishDrama3DeliveryCueNames.contains(cue) ||
            RegExp(
              r'^(?:face|action|posture|emotion|delivery|think|answer|code|tool_call|function_call)(?:\s*:|$)',
            ).hasMatch(cue)) {
          return '';
        }
        return match.group(0)!;
      });
  return preserveLines
      ? cleaned
            .replaceAll(RegExp(r'[ \t]+'), ' ')
            .replaceAll(RegExp(r' *\r?\n *'), '\n')
            .trim()
      : cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
}
