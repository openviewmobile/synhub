// 阅读器**内置词表**（E2「查词」的本地实现）。
//
// 为什么不用在线词典、也不调 AI：
//   * 「查词」是阅读里最高频、最要求"点一下就有"的动作，等网络/等模型都不合适；
//   * 词表很小（常见词 + 这本书里出现的词），放进包里零成本；
//   * AI 只作为**后置兜底**：查不到时界面给"换个 AI 通道解释"的入口（见 §3）。
//
// 这一层是纯数据 + 纯函数（只 import `l10n` 给枚举取译文，不 import flutter
// 控件），所以能直接单测：
//   * `lookupWord('Books')` 能命中 `book`（大小写 + 简单形态还原）；
//   * 命中给**词性 + 释义**；查不到返回 null，由界面给明确提示。
import '../../core/i18n/l10n.dart';

/// 词性（枚举给中文 `label` 当回落、`labelIn(t)` 给界面用 —— 见 i18n 约定）
enum DictPos {
  noun('名词'),
  verb('动词'),
  adjective('形容词'),
  adverb('副词'),
  pronoun('代词'),
  preposition('介词'),
  conjunction('连词'),
  interjection('感叹词'),
  numeral('数词'),
  phrase('短语'),
  other('其他');

  const DictPos(this.label);

  /// 中文标签（**回落**；界面走 [labelIn]）
  final String label;

  /// 本地化标签
  String labelIn(AppText t) => switch (this) {
    DictPos.noun => t.dictPosNoun,
    DictPos.verb => t.dictPosVerb,
    DictPos.adjective => t.dictPosAdjective,
    DictPos.adverb => t.dictPosAdverb,
    DictPos.pronoun => t.dictPosPronoun,
    DictPos.preposition => t.dictPosPreposition,
    DictPos.conjunction => t.dictPosConjunction,
    DictPos.interjection => t.dictPosInterjection,
    DictPos.numeral => t.dictPosNumeral,
    DictPos.phrase => t.dictPosPhrase,
    DictPos.other => t.dictPosOther,
  };
}

/// 一条释义（一个词性可以有多条）
class DictSense {
  const DictSense(this.pos, this.meaning);

  final DictPos pos;
  final String meaning;
}

/// 一个词条：拼写 + 音标（可空）+ 若干释义
class DictEntry {
  const DictEntry(this.word, {this.phonetic = '', this.senses = const []});

  final String word;
  final String phonetic;
  final List<DictSense> senses;

  bool get isEmpty => senses.isEmpty;
}

/// 内置词表：`词 → (音标, 释义)`。
///
/// 量刻意很小（够覆盖常见书与测试用例），命中率靠 [lookupWord] 的形态还原
/// （复数 / 过去式 / 进行时 / 副词）补足；其余让用户走 AI 解释。
const Map<String, ({String phonetic, List<DictSense> senses})>
kBookDictionary = {
  'alpha': (
    phonetic: '/ˈælfə/',
    senses: [
      DictSense(DictPos.noun, '希腊字母表的第一个字母（Α、α）'),
      DictSense(DictPos.noun, '（一系列事物的）开端、起始'),
    ],
  ),
  'beta': (
    phonetic: '/ˈbiːtə/',
    senses: [
      DictSense(DictPos.noun, '希腊字母表的第二个字母（Β、β）'),
      DictSense(DictPos.noun, '（软件等的）测试版、试用版'),
    ],
  ),
  'book': (
    phonetic: '/bʊk/',
    senses: [
      DictSense(DictPos.noun, '书；书籍；卷'),
      DictSense(DictPos.verb, '预订；预约'),
    ],
  ),
  'read': (
    phonetic: '/riːd/',
    senses: [
      DictSense(DictPos.verb, '读；阅读；朗读'),
      DictSense(DictPos.verb, '看懂；理解（含义）'),
    ],
  ),
  'reader': (
    phonetic: '/ˈriːdə/',
    senses: [
      DictSense(DictPos.noun, '读者；阅读者'),
      DictSense(DictPos.noun, '读本；读物'),
    ],
  ),
  'page': (
    phonetic: '/peɪdʒ/',
    senses: [
      DictSense(DictPos.noun, '页；页面'),
      DictSense(DictPos.noun, '（历史上的）侍从、page'),
    ],
  ),
  'chapter': (
    phonetic: '/ˈtʃæptə/',
    senses: [DictSense(DictPos.noun, '章；回；篇')],
  ),
  'story': (
    phonetic: '/ˈstɔːri/',
    senses: [
      DictSense(DictPos.noun, '故事；小说'),
      DictSense(DictPos.noun, '（新闻）报道'),
    ],
  ),
  'word': (
    phonetic: '/wɜːd/',
    senses: [
      DictSense(DictPos.noun, '词；单词；话语'),
      DictSense(DictPos.verb, '用言语表达'),
    ],
  ),
  'time': (
    phonetic: '/taɪm/',
    senses: [DictSense(DictPos.noun, '时间；时刻'), DictSense(DictPos.noun, '次；回')],
  ),
  'light': (
    phonetic: '/laɪt/',
    senses: [
      DictSense(DictPos.noun, '光；光线；灯'),
      DictSense(DictPos.adjective, '轻的；浅色的'),
      DictSense(DictPos.verb, '点燃；照亮'),
    ],
  ),
  'note': (
    phonetic: '/nəʊt/',
    senses: [
      DictSense(DictPos.noun, '笔记；便条；注释'),
      DictSense(DictPos.verb, '注意；记下'),
    ],
  ),
  'run': (
    phonetic: '/rʌn/',
    senses: [
      DictSense(DictPos.verb, '跑；奔跑；经营'),
      DictSense(DictPos.noun, '奔跑；一段时期'),
    ],
  ),
  'make': (
    phonetic: '/meɪk/',
    senses: [
      DictSense(DictPos.verb, '制作；使得；赚得'),
      DictSense(DictPos.noun, '牌子；型号'),
    ],
  ),
  'write': (phonetic: '/raɪt/', senses: [DictSense(DictPos.verb, '写；书写；写作')]),
  'think': (phonetic: '/θɪŋk/', senses: [DictSense(DictPos.verb, '想；思考；认为')]),
  'know': (phonetic: '/nəʊ/', senses: [DictSense(DictPos.verb, '知道；认识；了解')]),
  'see': (
    phonetic: '/siː/',
    senses: [
      DictSense(DictPos.verb, '看见；明白'),
      DictSense(DictPos.verb, '会见；拜访'),
    ],
  ),
  'come': (phonetic: '/kʌm/', senses: [DictSense(DictPos.verb, '来；来到；出现')]),
  'go': (phonetic: '/ɡəʊ/', senses: [DictSense(DictPos.verb, '去；走；进行')]),
  'take': (phonetic: '/teɪk/', senses: [DictSense(DictPos.verb, '拿；取；花费；乘坐')]),
  'give': (phonetic: '/ɡɪv/', senses: [DictSense(DictPos.verb, '给；提供；让步')]),
  'find': (phonetic: '/faɪnd/', senses: [DictSense(DictPos.verb, '找到；发现；认为')]),
  'tell': (phonetic: '/tel/', senses: [DictSense(DictPos.verb, '告诉；讲述；辨别')]),
  'ask': (phonetic: '/ɑːsk/', senses: [DictSense(DictPos.verb, '问；询问；请求')]),
  'work': (
    phonetic: '/wɜːk/',
    senses: [
      DictSense(DictPos.noun, '工作；作品'),
      DictSense(DictPos.verb, '工作；运转；奏效'),
    ],
  ),
  'play': (
    phonetic: '/pleɪ/',
    senses: [
      DictSense(DictPos.verb, '玩；演奏；扮演'),
      DictSense(DictPos.noun, '游戏；戏剧'),
    ],
  ),
  'live': (phonetic: '/lɪv/', senses: [DictSense(DictPos.verb, '居住；活着；生活')]),
  'dream': (
    phonetic: '/driːm/',
    senses: [DictSense(DictPos.noun, '梦；梦想'), DictSense(DictPos.verb, '做梦；梦想')],
  ),
  'hope': (
    phonetic: '/həʊp/',
    senses: [
      DictSense(DictPos.noun, '希望；期望'),
      DictSense(DictPos.verb, '希望；盼望'),
    ],
  ),
  'fear': (
    phonetic: '/fɪə/',
    senses: [
      DictSense(DictPos.noun, '害怕；恐惧'),
      DictSense(DictPos.verb, '害怕；担心'),
    ],
  ),
  'voice': (phonetic: '/vɔɪs/', senses: [DictSense(DictPos.noun, '声音；嗓音；发言权')]),
  'music': (phonetic: '/ˈmjuːzɪk/', senses: [DictSense(DictPos.noun, '音乐；乐曲')]),
  'silence': (
    phonetic: '/ˈsaɪləns/',
    senses: [
      DictSense(DictPos.noun, '寂静；沉默'),
      DictSense(DictPos.verb, '使安静；压制'),
    ],
  ),
  'journey': (
    phonetic: '/ˈdʒɜːni/',
    senses: [DictSense(DictPos.noun, '旅行；旅程'), DictSense(DictPos.verb, '旅行')],
  ),
  'river': (phonetic: '/ˈrɪvə/', senses: [DictSense(DictPos.noun, '河；江；河流')]),
  'mountain': (
    phonetic: '/ˈmaʊntɪn/',
    senses: [DictSense(DictPos.noun, '山；山脉')],
  ),
  'forest': (phonetic: '/ˈfɒrɪst/', senses: [DictSense(DictPos.noun, '森林；林地')]),
  'garden': (phonetic: '/ˈɡɑːdn/', senses: [DictSense(DictPos.noun, '花园；菜园')]),
  'house': (phonetic: '/haʊs/', senses: [DictSense(DictPos.noun, '房子；住宅；议院')]),
  'friend': (phonetic: '/frend/', senses: [DictSense(DictPos.noun, '朋友；友人')]),
  'love': (
    phonetic: '/lʌv/',
    senses: [DictSense(DictPos.noun, '爱；爱情'), DictSense(DictPos.verb, '爱；喜欢')],
  ),
  'life': (phonetic: '/laɪf/', senses: [DictSense(DictPos.noun, '生命；生活；一生')]),
  'death': (phonetic: '/deθ/', senses: [DictSense(DictPos.noun, '死；死亡')]),
  'king': (phonetic: '/kɪŋ/', senses: [DictSense(DictPos.noun, '国王；君主')]),
  'queen': (phonetic: '/kwiːn/', senses: [DictSense(DictPos.noun, '女王；王后')]),
  'war': (phonetic: '/wɔː/', senses: [DictSense(DictPos.noun, '战争；斗争')]),
  'peace': (phonetic: '/piːs/', senses: [DictSense(DictPos.noun, '和平；安宁')]),
  'night': (phonetic: '/naɪt/', senses: [DictSense(DictPos.noun, '夜晚；夜间')]),
  'day': (phonetic: '/deɪ/', senses: [DictSense(DictPos.noun, '天；白天；日子')]),
  'hand': (
    phonetic: '/hænd/',
    senses: [
      DictSense(DictPos.noun, '手；指针；帮助'),
      DictSense(DictPos.verb, '递给；交给'),
    ],
  ),
  'eye': (phonetic: '/aɪ/', senses: [DictSense(DictPos.noun, '眼睛；眼光')]),
  'heart': (phonetic: '/hɑːt/', senses: [DictSense(DictPos.noun, '心；心脏；核心')]),
  'mind': (
    phonetic: '/maɪnd/',
    senses: [
      DictSense(DictPos.noun, '头脑；思想；介意'),
      DictSense(DictPos.verb, '介意；照看'),
    ],
  ),
  'water': (phonetic: '/ˈwɔːtə/', senses: [DictSense(DictPos.noun, '水；水域')]),
  'fire': (
    phonetic: '/ˈfaɪə/',
    senses: [DictSense(DictPos.noun, '火；火灾'), DictSense(DictPos.verb, '开火；解雇')],
  ),
  'moon': (phonetic: '/muːn/', senses: [DictSense(DictPos.noun, '月亮；卫星')]),
  'sun': (phonetic: '/sʌn/', senses: [DictSense(DictPos.noun, '太阳；阳光')]),
  'star': (
    phonetic: '/stɑː/',
    senses: [DictSense(DictPos.noun, '星；明星'), DictSense(DictPos.verb, '主演')],
  ),
  'child': (phonetic: '/tʃaɪld/', senses: [DictSense(DictPos.noun, '孩子；儿童')]),
  'mother': (phonetic: '/ˈmʌðə/', senses: [DictSense(DictPos.noun, '母亲；妈妈')]),
  'father': (phonetic: '/ˈfɑːðə/', senses: [DictSense(DictPos.noun, '父亲；爸爸')]),
  'brother': (phonetic: '/ˈbrʌðə/', senses: [DictSense(DictPos.noun, '兄弟；同事')]),
  'sister': (phonetic: '/ˈsɪstə/', senses: [DictSense(DictPos.noun, '姐妹；修女')]),
};

/// 把选中文本归一化成"查词用的词"：去掉首尾标点、取单个词。
///
/// 选中一句话时取其中**第一个**词，避免把整段当成词去查（查不到会误导用户）。
String normalizeLookupWord(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return '';
  // 英文里最常见的撇号变体统一一下（`it’s` → `it's`）
  s = s.replaceAll('\u2019', "'");
  if (s.contains(RegExp(r'\s'))) {
    // 多词：取第一个"像词"的片段（跳过引号、破折号等）
    final m = RegExp(r"[A-Za-z][A-Za-z'\-]*").firstMatch(s);
    if (m != null) return m.group(0)!;
    final cjk = RegExp(r'[\u4e00-\u9fff]+').firstMatch(s);
    return cjk?.group(0) ?? '';
  }
  return s.replaceAll(RegExp(r"^[^\w\u4e00-\u9fff'-]+|[\W_]+$"), '');
}

/// 形态还原的候选序列（先去撇号后缀，再依次剥离常见屈折词尾）。
///
/// 顺序很重要：`studies` 要先试 `study`（-ies），再试 `studie`/`stud`；
/// `loved` 要能回落到 `love`。返回的候选**去重且不含空串**。
List<String> lookupCandidates(String word) {
  final w = word.toLowerCase();
  final out = <String>[w];
  void add(String s) {
    if (s.isNotEmpty && !out.contains(s)) out.add(s);
  }

  // 所有格/缩写：`it's` → `it`
  final apostrophe = w.indexOf("'");
  if (apostrophe > 0) add(w.substring(0, apostrophe));

  for (final base in out.toList()) {
    if (base.endsWith('ies') && base.length > 4) {
      add('${base.substring(0, base.length - 3)}y');
    }
    if (base.endsWith('es') && base.length > 3) {
      add(base.substring(0, base.length - 2));
    }
    if (base.endsWith('s') && !base.endsWith('ss') && base.length > 3) {
      add(base.substring(0, base.length - 1));
    }
    if (base.endsWith('ing') && base.length > 5) {
      final stem = base.substring(0, base.length - 3);
      add(stem);
      add('${stem}e');
      // `running` → `run`（双写辅音）
      if (stem.length > 2 && stem[stem.length - 1] == stem[stem.length - 2]) {
        add(stem.substring(0, stem.length - 1));
      }
    }
    if (base.endsWith('ed') && base.length > 4) {
      final stem = base.substring(0, base.length - 2);
      add(stem);
      add('${stem}e');
      if (stem.length > 2 && stem[stem.length - 1] == stem[stem.length - 2]) {
        add(stem.substring(0, stem.length - 1));
      }
    }
    if (base.endsWith('er') && base.length > 4) {
      add(base.substring(0, base.length - 2));
    }
    if (base.endsWith('ly') && base.length > 4) {
      add(base.substring(0, base.length - 2));
    }
    if (base.endsWith("'s")) add(base.substring(0, base.length - 2));
  }
  return out;
}

/// 查词：命中返回词条（**词条里的 word 是词表原形**），否则 null。
///
/// 大小写不敏感；`Books`/`books`/`book's` 都能命中 `book`。
DictEntry? lookupWord(String raw) {
  final word = normalizeLookupWord(raw);
  if (word.isEmpty) return null;
  for (final candidate in lookupCandidates(word)) {
    final hit = kBookDictionary[candidate];
    if (hit != null) {
      return DictEntry(candidate, phonetic: hit.phonetic, senses: hit.senses);
    }
  }
  return null;
}

/// 词表里的词数（自检/测试用）
int get kBookDictionarySize => kBookDictionary.length;
