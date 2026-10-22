/// Delivery controls documented at
/// https://docs.fish.audio/features/text-to-speech/drama-3.md.
/// Other models continue
/// to use their own text format; selecting a model must be explicit.
bool isFishDrama3Model(String? model) =>
    model?.trim().toLowerCase() == 'drama-3';

const fishDrama3DeliveryCueNames = <String>{
  'whisper',
  'emphasis',
  'soft',
  'fast',
  'slow',
  'stress',
  'forceful',
};

const _deliveryAliases = <String, String>{
  'whisper': 'whisper',
  'whispering': 'whisper',
  'near-whisper': 'whisper',
  'unvoiced whispering': 'whisper',
  'soft': 'soft',
  'soft tone': 'soft',
  'soft intimate voice': 'soft',
  'low volume': 'soft',
  'emphasis': 'emphasis',
  'in a hurry tone': 'fast',
  'fast': 'fast',
  'slow': 'slow',
  'slow speech': 'slow',
  'stress': 'stress',
  'forceful': 'forceful',
};

const _shortDirections = {'emphasis', 'stress', 'forceful'};
const _tagNames = 'whisper|emphasis|soft|fast|slow|stress|forceful';
final _officialTag = RegExp(
  '<\\s*(/?)\\s*($_tagNames)\\s*>',
  caseSensitive: false,
);
final _tokens = RegExp(
  '<\\s*/?\\s*(?:$_tagNames)\\s*>|'
  r'\[[^\[\]\r\n]+\]|[0-9]+(?:[.,][0-9]+)+|'
  r"[A-Za-z0-9]+(?:['’][A-Za-z0-9]+)*|[\s\S]",
  caseSensitive: false,
  unicode: true,
);
final _unfinishedTag = RegExp(
  '<\\s*/?\\s*(?:$_tagNames)\\s*\u0024',
  caseSensitive: false,
);
final _phraseEnd = RegExp(r'^[。.!！？?；;，,、：:\r\n]$');

/// Compile the app's semantic square-bracket delivery cues into Drama 3's
/// official paired wrappers. This runs after the common breath/noise cleanup.
/// Emotion and pause cues remain in square brackets, and spoken text is copied
/// unchanged. No language, speaker, phoneme or SSML controls are introduced.
///
/// Whisper/soft/speed directions apply until the next delivery change. The
/// emphasis/stress/forceful directions cover only the next short phrase (at
/// most 48 visible units, without splitting an ASCII word). Existing balanced
/// official wrappers act as scope boundaries and are retained verbatim.
String compileFishDrama3Text(String text) {
  final input = text.replaceAll(_unfinishedTag, '');
  final tokens = _tokens
      .allMatches(input)
      .map((match) => match.group(0)!)
      .toList();
  final paired = _balancedTagIndices(tokens);
  final output = StringBuffer();
  String? delivery;
  String? shortDirection;
  var deliveryOpen = false;
  var shortOpen = false;
  var shortUnits = 0;

  void closeShort() {
    if (shortOpen) output.write('</$shortDirection>');
    shortDirection = null;
    shortOpen = false;
    shortUnits = 0;
  }

  void closeDelivery() {
    closeShort();
    if (deliveryOpen) output.write('</$delivery>');
    delivery = null;
    deliveryOpen = false;
  }

  for (var index = 0; index < tokens.length; index++) {
    final token = tokens[index];
    final official = _officialTag.firstMatch(token);
    if (official != null && official.group(0) == token) {
      if (paired.contains(index)) {
        // Generated wrappers must never cross an existing wrapper boundary.
        closeDelivery();
        output.write(token);
      }
      // Unmatched/crossed known control tags are discarded, not auto-completed
      // over unrelated text. Their enclosed words are still copied below.
      continue;
    }
    if (token.startsWith('[') && token.endsWith(']')) {
      final name = token
          .substring(1, token.length - 1)
          .trim()
          .toLowerCase()
          .replaceAll(RegExp(r'\s+'), ' ');
      final direction = _deliveryAliases[name];
      if (direction != null) {
        if (_shortDirections.contains(direction)) {
          closeShort();
          shortDirection = direction;
        } else if (direction != delivery) {
          closeDelivery();
          delivery = direction;
        } else {
          // Reaffirming the ongoing style also ends a preceding local accent.
          closeShort();
        }
        continue;
      }
      // Only declared aliases are compiled. Ordinary bracketed text, emotions
      // and pauses are neither guessed into controls nor treated as speech.
      output.write(token);
      continue;
    }

    final nonWhitespace = token.trim().isNotEmpty;
    if (nonWhitespace) {
      if (delivery != null && !deliveryOpen) {
        output.write('<$delivery>');
        deliveryOpen = true;
      }
      if (shortDirection != null && !shortOpen) {
        output.write('<$shortDirection>');
        shortOpen = true;
      }
    }
    output.write(token);
    if (shortOpen) {
      if (nonWhitespace) shortUnits += token.runes.length;
      if (_phraseEnd.hasMatch(token) || shortUnits >= 48) closeShort();
    }
  }
  closeDelivery();
  return output.toString();
}

/// Remove only Drama 3's seven known wrappers, keeping all enclosed words.
/// Use alongside the app's legacy cue cleanup for preflight and duration math.
String stripFishDrama3Tags(String text) =>
    text.replaceAll(_officialTag, '').replaceAll(_unfinishedTag, '');

Set<int> _balancedTagIndices(List<String> tokens) {
  final paired = <int>{};
  final stack = <({int index, String name})>[];
  for (var index = 0; index < tokens.length; index++) {
    final match = _officialTag.firstMatch(tokens[index]);
    if (match == null || match.group(0) != tokens[index]) continue;
    final name = match.group(2)!.toLowerCase();
    if (match.group(1)!.isEmpty) {
      stack.add((index: index, name: name));
    } else if (stack.isNotEmpty && stack.last.name == name) {
      paired.add(stack.removeLast().index);
      paired.add(index);
    } else {
      // A crossing close invalidates the still-open chain. Independent inner
      // pairs already completed remain safe after these outer tags disappear.
      stack.clear();
    }
  }
  return paired;
}
