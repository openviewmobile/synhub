// 端侧 AI 的**离线可测部分**：正文提取、切句、抽取式摘要、检索、prompt 组装、
// 输出解析，以及"无模型兜底引擎"的完整链路。
//
// 这里一条都不碰推理库：模型那条路（`flutter_gemma` + LiteRT-LM）只能在真机上跑，
// 由 `docs/on-device-ai-integration.md` 的真机章节负责验证。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/ai/ai_prompts.dart';
import 'package:synhub/src/features/ai/ai_service.dart';
import 'package:synhub/src/features/ai/llm_engine.dart';
import 'package:synhub/src/features/ai/on_device_ai.dart';
import 'package:synhub/src/features/ai/text_ai.dart';

/// 一段"像书"的中文正文：主题句在开头，中间有细节，结尾有结论
const _chapter = '''
机器学习模型的大小与它的能力并不总是线性相关。一个参数量很小的模型，
只要训练数据干净、任务足够窄，也能给出可用的结果。
\n在手机上跑模型，最大的限制不是算力，而是内存带宽和发热。
实验表明，0.6B 级别的模型在中端手机上可以在两秒内生成一条百字左右的回答。
\n量化是端侧部署的关键手段。int4 量化能把 0.6B 模型的体积压到 600MB 以内，
代价是复杂推理任务的准确率下降大约百分之五。
\n需要强调的是，端侧推理的隐私收益是确定的：原文从不离开设备。
这也是我们在阅读器里优先做本地摘要的原因。
''';

void main() {
  group('正文提取（HTML → 纯文本）', () {
    test('标签换成换行、实体解码、空白归一', () {
      const html =
          '<h1>标题</h1><p>第一段</p><p>第二&nbsp;段 &amp; 更多</p>'
          '<ul><li>甲</li><li>乙</li></ul>';
      final text = bookPlainText(html);
      expect(text, contains('标题'));
      expect(text, contains('第一段'));
      expect(text, contains('第二 段 & 更多'));
      expect(text.split('\n'), hasLength(5), reason: '块级标签要断行，不能粘一起');
      expect(text, isNot(contains('<')));
    });

    test('script/style 整段丢掉；数字实体能解', () {
      const html =
          '<style>p{color:red}</style><p>正文&#39;s 内容</p>'
          '<script>var a=1;</script>';
      final text = bookPlainText(html);
      expect(text, "正文's 内容");
      expect(text, isNot(contains('color')));
      expect(text, isNot(contains('var a')));
    });

    test('空输入不炸', () {
      expect(bookPlainText(''), '');
    });
  });

  group('切句与候选句', () {
    test('中英句末都切；英文句点要求"空格+大写"才切', () {
      final zh = splitSentences('第一句。第二句！第三句？');
      expect(zh, ['第一句。', '第二句！', '第三句？']);
      final en = splitSentences('Version 1.2.3 is out. It works well.');
      expect(en, hasLength(2), reason: '版本号不能被切碎');
      expect(en.last.trim(), 'It works well.');
    });

    test('候选句：太短/太长/重复的都滤掉', () {
      final s = candidateSentences(
        '好的。\n'
        '这是一句长度合适、值得当要点的句子。\n'
        '这是一句长度合适、值得当要点的句子。\n'
        '${'很长的句子' * 60}。',
      );
      expect(s, hasLength(1));
    });
  });

  group('抽取式摘要（无模型兜底）', () {
    test('挑出有信息量的句子，条数不超上限，顺序按原文', () {
      final bullets = extractiveSummary(_chapter, maxBullets: 3);
      expect(bullets, hasLength(3));
      // 主题句（第一句）通常会在
      expect(bullets.first, contains('并不总是线性相关'));
      // 顺序：在原文里的下标递增
      final idx = [
        for (final b in bullets) _chapter.indexOf(b.substring(0, 10)),
      ];
      final sorted = [...idx]..sort();
      expect(idx, sorted, reason: '摘要要按原文顺序读起来才顺');
    });

    test('条数上限生效；句子本来就少时全给', () {
      expect(extractiveSummary(_chapter, maxBullets: 2), hasLength(2));
      expect(extractiveSummary('只有一句话，长度也够当要点了。'), hasLength(1));
    });

    test('没有标点的长文本：退化成截断而不是空', () {
      final out = extractiveSummary('没标点' * 100, maxBullets: 3);
      expect(out, hasLength(1));
      expect(out.first.length, lessThanOrEqualTo(201));
    });

    test('空输入给空列表', () {
      expect(extractiveSummary('   '), isEmpty);
    });
  });

  group('分词与检索', () {
    test('中文二元组 + 英文词；停用词滤掉', () {
      final t = tokenize('端侧模型的 the model 推理');
      expect(t, contains('端侧'));
      expect(t, contains('model'));
      expect(t, isNot(contains('的')));
      expect(t, isNot(contains('the')));
    });

    test('最相关的片段排第一，标题命中额外加权', () {
      final passages = [
        const AiPassage(index: 0, title: '序言 · 书', text: '这本书讲的是料理。'),
        const AiPassage(index: 1, title: '第 2 章 量化', text: '量化把模型压小。'),
        const AiPassage(index: 2, title: '第 3 章 隐私', text: '端侧推理不出设备。'),
      ];
      final top = rankPassages('量化是什么', passages);
      expect(top.first.index, 1);
      expect(rankPassages('端侧 隐私', passages).first.index, 2);
    });

    test('没有命中就返回空；空问题退化成取前几段', () {
      final passages = [
        const AiPassage(index: 0, title: 'a', text: '苹果香蕉'),
        const AiPassage(index: 1, title: 'b', text: '轮胎螺丝'),
      ];
      expect(rankPassages('量子纠缠', passages), isEmpty);
      expect(rankPassages('', passages, topK: 1).single.index, 0);
    });

    test('长章节会被切成多个可检索片段', () {
      final long = List.generate(30, (i) => '第 $i 段内容，' * 20).join('\n');
      final ps = passagesOfBook('书', const ['第 1 章'], [long], maxChars: 300);
      expect(ps.length, greaterThan(1));
      expect(ps.first.title, contains('第 1 章（1）'));
      expect(ps.every((p) => p.text.length <= 400), isTrue);
    });

    test('空章节不产出片段', () {
      expect(passagesOfBook('书', const ['空的'], const ['   ']), isEmpty);
    });

    test('输入过长会截断并给标记', () {
      final long = '字' * (kAiMaxInputChars + 100);
      final r = clampInput(long);
      expect(r.truncated, isTrue);
      expect(r.text.length, kAiMaxInputChars + 1);
      expect(clampInput('短').truncated, isFalse);
    });
  });

  group('prompt 与输出解析', () {
    test('系统提示按任务分化，都带"只依据原文"的约束', () {
      for (final k in AiTaskKind.values) {
        final sys = aiSystemPrompt(k);
        expect(sys, contains('只依据'));
        expect(sys, contains('简体中文'));
      }
      expect(aiSystemPrompt(AiTaskKind.summary), contains('要点'));
      expect(aiSystemPrompt(AiTaskKind.translate), contains('只输出译文'));
    });

    test('用户提示把原文嵌进去；问书带编号片段与问题', () {
      final summary = aiUserPrompt(
        const AiRequest(kind: AiTaskKind.summary, text: '正文内容', title: '书'),
      );
      expect(summary, contains('正文内容'));
      expect(summary, contains('《书》'));

      final ask = aiUserPrompt(
        AiRequest(
          kind: AiTaskKind.askBook,
          text: '',
          question: '核心观点是什么',
          contexts: const [
            AiPassage(index: 0, title: '第 1 章', text: '甲'),
            AiPassage(index: 1, title: '第 2 章', text: '乙'),
          ],
        ),
      );
      expect(ask, contains('[1] 第 1 章'));
      expect(ask, contains('[2] 第 2 章'));
      expect(ask, contains('问题：核心观点是什么'));
    });

    test('解析要点：剥前缀/去开场白/去 markdown，条数受控', () {
      const raw =
          '以下是要点：\n'
          '- **第一点**，很重要\n'
          '2. 第二点\n'
          '• 第三点\n'
          '希望这些有帮助。\n';
      final bullets = parseBullets(raw);
      expect(bullets, ['第一点，很重要', '第二点', '第三点']);
      expect(parseBullets(raw, max: 2), hasLength(2));
    });

    test('模型不按格式来时，整段当一条（不丢内容）', () {
      final out = parseBullets('这是一段没有任何前缀的散文式回答，也应该被用起来。');
      expect(out, hasLength(1));
      expect(out.first, contains('散文式回答'));
    });

    test('thinking 段与角标解析', () {
      expect(stripModelNoise('思考中...<think>abc</think>答案在此'), '思考中...答案在此');
      expect(citedPassages('如 [1] 所述，另见【2】与 [9]', 2), [0, 1]);
      expect(citedPassages('没有角标', 3), isEmpty);
    });
  });

  group('兜底引擎（无模型时的完整链路）', () {
    test('总结：输出要点、标注"内置摘要"', () async {
      final service = AiService(ExtractiveLlmEngine());
      final answer = await service.run(
        const AiRequest(kind: AiTaskKind.summary, text: _chapter, title: '书'),
      );
      expect(answer.engine, AiEngineKind.extractive);
      expect(answer.text, contains('- '));
      expect(answer.text, contains('端侧'));
      expect(answer.elapsedMs, greaterThanOrEqualTo(0));
    });

    test('问书：没有模型也给出最相关的原文片段', () async {
      final service = AiService(ExtractiveLlmEngine());
      final passages = passagesOfBook(
        '书',
        const ['第 1 章 量化', '第 2 章 隐私'],
        const ['量化把模型压到 600MB 以内，代价是准确率下降。', '端侧推理的隐私收益是确定的：原文从不离开设备。'],
      );
      final req = withRetrieval(
        const AiRequest(
          kind: AiTaskKind.askBook,
          text: '',
          title: '书',
          question: '隐私收益是什么',
        ),
        passages,
      );
      expect(req.contexts, isNotEmpty);
      final answer = await service.run(req);
      expect(answer.text, contains('原文最相关的几段'));
      expect(answer.text, contains('隐私'));
    });

    test('问答模式不会把检索片段当"问题"再塞一遍', () async {
      final service = AiService(ExtractiveLlmEngine());
      final answer = await service.run(
        withRetrieval(
          const AiRequest(kind: AiTaskKind.askBook, text: '', question: '轮胎'),
          passagesOfBook('书', const ['第 1 章'], const ['这段讲的是苹果。']),
        ),
      );
      expect(answer.text, contains('原文里没有提到'));
    });

    test('withRetrieval 只对问书生效', () {
      const req = AiRequest(kind: AiTaskKind.summary, text: 'x');
      expect(
        withRetrieval(req, const [
          AiPassage(index: 0, title: 'a', text: 'b'),
        ]).contexts,
        isEmpty,
      );
    });

    test('引擎状态：兜底引擎永远"可用"', () async {
      final st = await ExtractiveLlmEngine().status();
      expect(st.readiness, AiReadiness.ready);
      expect(st.modelName, '内置摘要');
    });
  });

  group('模型目录', () {
    test('id 唯一、恰好一个推荐档、url 与文件名对得上', () {
      final ids = kOnDeviceModels.map((m) => m.id).toSet();
      expect(ids, hasLength(kOnDeviceModels.length));
      expect(kOnDeviceModels.where((m) => m.recommended), hasLength(1));
      for (final m in kOnDeviceModels) {
        expect(m.url, endsWith(m.fileName));
        expect(m.url, startsWith('https://huggingface.co/litert-community/'));
        expect(m.sizeBytes, greaterThan(50 * 1000 * 1000));
        expect(m.note, isNotEmpty);
        expect(m.license, startsWith('https://'));
        expect(m.needsAuth, isFalse);
      }
    });

    test('体积文案按档位给人话', () {
      expect(kOnDeviceModels.first.sizeLabel, endsWith('MB'));
      expect(
        const AiModelInfo(
          id: 'x',
          name: 'x',
          fileName: 'x.litertlm',
          url: 'https://x/x.litertlm',
          sizeBytes: 3 * 1024 * 1024 * 1024,
          note: '',
          license: '',
        ).sizeLabel,
        '3.0 GB',
      );
    });

    test('镜像地址：只换域名、路径一致；非 HF 地址原样返回', () {
      final m = kOnDeviceModels.first;
      expect(
        mirrorUrlOf(m.url),
        m.url.replaceFirst('https://huggingface.co/', 'https://hf-mirror.com/'),
      );
      expect(downloadUrlsOf(m), hasLength(2), reason: '直连优先 + 镜像兜底');
      expect(downloadUrlsOf(m).first, m.url);
      expect(
        mirrorUrlOf('https://example.com/x.litertlm'),
        'https://example.com/x.litertlm',
      );
    });

    test('乱码修复：byte-level 词表按 Latin-1 解码要能还原', () {
      // 真机现象：Qwen3 0.6B 输出 `Ġç®\u0097力与内存带宽` —— 本意是 `算力与内存带宽`
      const broken = 'Ġç®\u0097力与内存带宽是端侧推理的瓶颈';
      expect(repairMojibake(broken), ' 算力与内存带宽是端侧推理的瓶颈');
      // 正常文本不动（法语 é、德语 ü 也落在 Latin-1 区，不能被误修）
      expect(repairMojibake('café 里的字'), 'café 里的字');
      expect(repairMojibake('纯中文，没有乱码'), '纯中文，没有乱码');
    });

    test('思考段：流式期间单独摘出来，结束后整段丢掉', () {
      expect(splitThinking('好的'), (text: '好的', thinking: false));
      expect(splitThinking(' thinking还在想').thinking, isTrue);
      expect(splitThinking(' thinking还在想').text, '');
      expect(splitThinking('\u003cthink\u003e想完了\u003c/think\u003e答案'), (
        text: '答案',
        thinking: false,
      ));
      expect(
        cleanModelText('\u003cthink\u003e想\u003c/think\u003e真正的答案'),
        '真正的答案',
      );
      // 没闭合的思考段 + 已出的正文：正文要留下
      expect(cleanModelText('正文\u003cthink\u003e还在想'), '正文');
    });

    test('要点行首的乱码残留会被清掉（模型吃掉字节时的兜底）', () {
      final out = parseBullets(
        '- \uFFFD9力与内存带宽是端侧推理的瓶颈\n'
        "- \uFFFD('存带宽决定推理速度",
      );
      expect(out.first, '力与内存带宽是端侧推理的瓶颈');
      expect(out[1], '存带宽决定推理速度');
    });

    test('按 id 查得到；查不到给 null', () {
      expect(aiModelById('qwen3-0.6b')?.name, contains('Qwen3'));
      expect(aiModelById('nope'), isNull);
      expect(aiModelById(null), isNull);
    });
  });
}
