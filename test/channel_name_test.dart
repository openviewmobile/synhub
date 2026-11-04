// 频道名 / 标签名合法性校验（照抄原版 `ChatUtil` 的 `validateChannelName` /
// `validateHashtag` 与三个界面里的 `afterInputChanged` 判定）。
//
// 为什么值得单独测：真机实测（`tool/probe_promote.dart`）服务端对**带空格**的
// 频道名直接回 407 CHAT_ERR_INVALID_RECORD（promote 的 "cannot promote"），
// 对纯中文（无空格、无特殊字符）则成功。原版客户端正是拿这套规则先拦一道。
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/chat/channel_name.dart';

void main() {
  group('频道名合法性（原版 ChatUtil.INVALID_CHANNEL_NAME_PATTERN）', () {
    test('普通名字（含中文、数字、- . _ ）都合法', () {
      for (final ok in [
        '项目讨论',
        'probe-pm-1789642297903',
        'a_b.c',
        '验收专用频道1789642297856',
        '频道-1_v2.0',
      ]) {
        expect(validateChannelName(ok), isTrue, reason: ok);
        expect(channelNameError(ok), isNull, reason: ok);
      }
    });

    test('原版图案里的特殊字符一律不合法', () {
      // [~!@{}<>`|?#$%^&*()+\['":;,/=]
      for (final bad in [
        'a]b',
        'a~b',
        'a@b',
        'a{b',
        'a<b',
        r'a\b',
        'a[b',
        'a"b',
        "a'b",
        'a:b',
        'a;b',
        'a,b',
        'a/b',
        'a=b',
        'a#b',
        'a?b',
        'a*b',
        'a(b',
        'a+b',
        'a|b',
        'a^b',
        'a%b',
        'a\$b',
        'a!b',
        'a}b',
        'a>b',
        'a`b',
      ]) {
        expect(validateChannelName(bad), isFalse, reason: bad);
        expect(channelNameError(bad), '不可用空格和特殊字符。', reason: bad);
      }
    });

    test('空格单独判（不在图案里，但客户端也拦）', () {
      expect(validateChannelName('a b'), isTrue, reason: '空格不在图案里');
      expect(channelNameError('a b'), '不可用空格和特殊字符。');
      expect(channelNameError('  '), '不可用空格和特殊字符。');
    });

    test(r'空名 = 必填文案（原版 is_required: "%1$s 不可为空。"）', () {
      expect(channelNameError(''), '频道名称 不可为空。');
    });

    test('标签名用同一套图案（原版 HashtagFragment：空串不报错）', () {
      expect(validateHashtag('flt-tag'), isTrue);
      expect(hashtagError('flt-tag'), isNull);
      expect(hashtagError('a b'), '不可用空格和特殊字符。');
      expect(hashtagError('a@b'), '不可用空格和特殊字符。');
      expect(hashtagError(''), isNull);
    });
  });
}
