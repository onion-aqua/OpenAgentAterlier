import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/fish_drama3_tags.dart';

void main() {
  test('only an explicit Drama 3 model enables the format', () {
    for (final model in ['drama-3', ' DRAMA-3 ', '\tdrama-3\n']) {
      expect(isFishDrama3Model(model), isTrue);
    }
    for (final model in [null, '', 's2.1-pro', 'drama-30', 'custom/drama-3']) {
      expect(isFishDrama3Model(model), isFalse);
    }
  });

  test('all seven official delivery controls compile as paired wrappers', () {
    expect(fishDrama3DeliveryCueNames, {
      'whisper',
      'emphasis',
      'soft',
      'fast',
      'slow',
      'stress',
      'forceful',
    });
    for (final name in fishDrama3DeliveryCueNames) {
      expect(compileFishDrama3Text('[$name]明日も会おう。'), '<$name>明日も会おう。</$name>');
    }
  });

  test('legacy delivery aliases use the declared official vocabulary', () {
    const aliases = {
      'whispering': 'whisper',
      'near-whisper': 'whisper',
      'unvoiced whispering': 'whisper',
      'soft tone': 'soft',
      'soft intimate voice': 'soft',
      'low volume': 'soft',
      'in a hurry tone': 'fast',
      'slow speech': 'slow',
    };
    for (final entry in aliases.entries) {
      expect(
        compileFishDrama3Text('[${entry.key}]你好。'),
        '<${entry.value}>你好。</${entry.value}>',
      );
    }
    expect(
      compileFishDrama3Text('[  SOFT   TONE ]Hello!'),
      '<soft>Hello!</soft>',
    );
  });

  test(
    'emotion and short pause cues are preserved without invented effects',
    () {
      expect(
        compileFishDrama3Text('[happy][whispering]你好，[short pause]明天见。'),
        '[happy]<whisper>你好，[short pause]明天见。</whisper>',
      );
      expect(
        compileFishDrama3Text('[sad]明日も会おう。[short pause]'),
        '[sad]明日も会おう。[short pause]',
      );
      expect(
        compileFishDrama3Text('[像是在强忍着眼泪，却努力笑着]我没事。'),
        '[像是在强忍着眼泪，却努力笑着]我没事。',
      );
    },
  );

  test('successive delivery changes close the preceding scope', () {
    expect(
      compileFishDrama3Text('[whispering]你好。[soft tone]再见。[fast]快走！'),
      '<whisper>你好。</whisper><soft>再见。</soft><fast>快走！</fast>',
    );
    expect(
      compileFishDrama3Text('[whisper]你好[whispering]呀。'),
      '<whisper>你好呀。</whisper>',
    );
    expect(
      compileFishDrama3Text('[whisper]A[emphasis]B[whispering]C'),
      '<whisper>A<emphasis>B</emphasis>C</whisper>',
    );
  });

  test(
    'emphasis covers one phrase and retains the surrounding quiet style',
    () {
      expect(
        compileFishDrama3Text('[whispering]先听我说。[emphasis]这里很重要，之后慢慢来。'),
        '<whisper>先听我说。<emphasis>这里很重要，</emphasis>之后慢慢来。</whisper>',
      );
      expect(
        compileFishDrama3Text('[stress]本当に？次の文は普通だよ。'),
        '<stress>本当に？</stress>次の文は普通だよ。',
      );
      expect(
        compileFishDrama3Text('[forceful]Stop! Then listen.'),
        '<forceful>Stop!</forceful> Then listen.',
      );
    },
  );

  test('unpunctuated emphasis is bounded without changing words', () {
    final text = 'あ' * 120;
    final result = compileFishDrama3Text('[emphasis]$text');
    expect(result, '<emphasis>${'あ' * 48}</emphasis>${'あ' * 72}');
    expect(stripFishDrama3Tags(result), text);
    const english =
        'The pronunciation pneumonoultramicroscopicsilicovolcanoconiosis stays intact';
    final englishResult = compileFishDrama3Text('[stress]$english');
    expect(stripFishDrama3Tags(englishResult), english);
    expect(
      englishResult,
      contains('pneumonoultramicroscopicsilicovolcanoconiosis'),
    );
  });

  test('English sentence scope keeps decimal numbers intact', () {
    expect(
      compileFishDrama3Text('[emphasis]First sentence. Then normal.'),
      '<emphasis>First sentence.</emphasis> Then normal.',
    );
    expect(
      compileFishDrama3Text('[stress]23.5℃，慢慢来。'),
      '<stress>23.5℃，</stress>慢慢来。',
    );
    final text = '${'x ' * 21}don’t stop';
    final compiled = compileFishDrama3Text('[emphasis]$text');
    expect(compiled, contains('don’t'));
    expect(stripFishDrama3Tags(compiled), text);
  });

  test('Chinese Japanese numbers whitespace and punctuation remain exact', () {
    const spoken = '  莱莎，温度 23.5℃。\r\nライザ、１２時に 123 個だよ！ 😀 ';
    final compiled = compileFishDrama3Text('[soft]$spoken');
    expect(stripFishDrama3Tags(compiled), spoken);
    expect(compileFishDrama3Text(spoken), spoken);
  });

  test('existing balanced wrappers survive and recompilation is idempotent', () {
    const existing =
        'I am fine. <whisper>Go on <emphasis>without</emphasis> me.</whisper>';
    expect(compileFishDrama3Text(existing), existing);
    for (final input in [
      '[happy][whispering]やっほー。[emphasis]また会おう。',
      '[fast]快走！[slow speech]先等等。',
      '<soft>[emphasis]Only this phrase. Then regular.</soft>',
      '[stress]${'字' * 90}',
      existing,
    ]) {
      final once = compileFishDrama3Text(input);
      expect(compileFishDrama3Text(once), once);
    }
  });

  test('aliases cannot cross or mismatch an existing official scope', () {
    expect(
      compileFishDrama3Text('[soft]A<whisper>[stress]B</whisper>C'),
      '<soft>A</soft><whisper><stress>B</stress></whisper>C',
    );
    expect(compileFishDrama3Text('<soft><emphasis>A</soft></emphasis>'), 'A');
    expect(compileFishDrama3Text('<soft>A'), 'A');
    expect(compileFishDrama3Text('A</whisper>'), 'A');
    expect(
      compileFishDrama3Text('<soft><emphasis>A</emphasis>'),
      '<emphasis>A</emphasis>',
    );
    expect(compileFishDrama3Text('A<whisper'), 'A');
  });

  test('control-only input does not turn into fake spoken content', () {
    for (final input in [
      '[whispering]',
      '[emphasis][stress]',
      '<soft></soft>',
      '<whisper>',
      '</forceful>',
    ]) {
      expect(stripFishDrama3Tags(compileFishDrama3Text(input)).trim(), isEmpty);
    }
  });

  test('unknown tags are not promoted to official Drama 3 controls', () {
    const text =
        '[robotic]Hello <robotic>world</robotic> <lang:ja>日本語</lang:ja>';
    expect(compileFishDrama3Text(text), text);
    expect(stripFishDrama3Tags(text), text);
    expect(stripFishDrama3Tags('<soft>A</soft><whisper>B</whisper>'), 'AB');
  });
}
