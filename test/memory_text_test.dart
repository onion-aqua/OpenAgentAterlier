import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/memory_text.dart';

void main() {
  test(
    'removes only recognized delivery cues and internal control metadata',
    () {
      expect(
        cleanMemoryText(
          '<think>内部推理不能记录</think><answer>[happy]收到[苹果]，'
          '[emphasis]明日一緒に出発。[action:wave][face:smile]</answer>',
        ),
        '收到[苹果]，明日一緒に出発。',
      );
    },
  );

  test('keeps line and speaker boundaries for memory extraction', () {
    expect(
      cleanMemoryText('用户：我喜欢苹果。\n莱莎：[very happy]我收到苹果。', preserveLines: true),
      '用户：我喜欢苹果。\n莱莎：我收到苹果。',
    );
  });

  test('retains code body but removes unfinished private blocks', () {
    expect(
      cleanMemoryText(
        r'\<answer>[pause]答应了。\</answer><code>42</code>'
        '<tool_call>尚未结束的内部请求',
      ),
      '答应了。42',
    );
  });

  test('ordinary brackets and similarly named text remain readable', () {
    expect(
      cleanMemoryText('记住[happy ending]、[苹果]和[章节二]。'),
      '记住[happy ending]、[苹果]和[章节二]。',
    );
  });
}
