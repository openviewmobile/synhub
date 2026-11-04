// `.osheet` **公式求值器**（纯 Dart；不 import flutter/l10n）。
//
// 背景（O3 批次）：真实 `.osheet` 的公式是**单元格 `v` 字符串以 `=` 开头**
// （`OSheetCell.isFormula`），此前渲染层**只把公式原文显示出来**（如 `=SUM(B13:B21)`、
// `=C7-C9`、`=I33`）。Excel/WPS 会算出数值并显示数值，本文件补上"算"。
//
// 设计要点：
//   * **自研、零依赖**：手写 tokenizer + 递归下降 parser + 求值器；
//   * **纯函数可单测**：[tokenizeOSheetFormula] / [parseOSheetFormula] /
//     [evaluateOSheetFormula] 都不碰 Flutter；
//   * **绝不崩**：解析失败/未支持的函数/跨表引用 → 抛 [OSheetFormulaUnsupported]
//     或返回 `null`，调用方**退化到"显示公式原文"**（现状行为）；
//   * **循环引用不死循环**：求值中维护"正在求值"集合，命中环 → 返回
//     `#CIRC!` 错误值（可读降级），环上所有单元格一致；
//   * **数字格式**：本文件只产出 `num`/`String`/`bool`/错误；`num` 由渲染层继续
//     走既有的 `numFmt`（`oSheetFormatNumber`），不破坏真机上已能出的 `$2,750.00`。
//
// 支持的运算符：`+ - * / ^ &`、一元 `+ -`、后缀 `%`、括号、比较
// `= <> < > <= >=`、参数分隔 `,`、区间 `:`。
// 支持的函数：`SUM AVERAGE MIN MAX COUNT COUNTA ROUND ABS IF AND OR NOT`
// 以及真实 `.osheet` 用到的 `SUMIF`（三参）`COUNTIF` `ISBLANK`
// （`Travel expenses.osheet`：`=SUMIF($F$17:$F$31,"="&F11,$I$17:$I$31)`、
//  `=IF(ISBLANK(H17),0,ISBLANK(H18)…)`）。
//
// ⚠️ **未支持**：`CONCATENATE`、跨表引用（`Sheet!A1`）、数组常量、查找类函数
// （`VLOOKUP`…）、日期函数。遇到即**整格退化显示公式原文**，不猜。

import 'osheet_model.dart';
import 'office_json.dart';

// ---------------------------------------------------------------------------
// 错误值 / 界面
// ---------------------------------------------------------------------------

/// Excel 风格的错误值（求值结果的一种，不是异常）。
class OSheetFormulaError {
  const OSheetFormulaError(this.code);

  /// `#CIRC!` / `#DIV/0!` / `#VALUE!` / `#NAME?` / `#REF!` / `#NUM!`。
  final String code;

  @override
  String toString() => code;

  @override
  bool operator ==(Object other) =>
      other is OSheetFormulaError && other.code == code;

  @override
  int get hashCode => code.hashCode;
}

/// 循环引用（求值环）→ 可读降级。
const OSheetFormulaError kOSheetFormulaCircular = OSheetFormulaError('#CIRC!');

/// 除零。
const OSheetFormulaError kOSheetFormulaDivZero = OSheetFormulaError('#DIV/0!');

/// 类型不对（文本参与算术且不能转数字等）。
const OSheetFormulaError kOSheetFormulaValue = OSheetFormulaError('#VALUE!');

/// 引用了越界/不存在的位置。
const OSheetFormulaError kOSheetFormulaRef = OSheetFormulaError('#REF!');

/// 数值域错误。
const OSheetFormulaError kOSheetFormulaNum = OSheetFormulaError('#NUM!');

/// 公式**当前无法求值**（解析失败 / 未支持函数 / 跨表）——调用方显示公式原文。
class OSheetFormulaUnsupported implements Exception {
  const OSheetFormulaUnsupported(this.reason);

  final String reason;

  @override
  String toString() => 'OSheetFormulaUnsupported($reason)';
}

/// 求值状态。
enum OSheetFormulaStatus {
  /// 算出了值（可能是 `null`=空）。
  value,

  /// 算出了 Excel 错误值（如 `#CIRC!`）。
  error,

  /// 当前无法求值 → 显示公式原文。
  unsupported,
}

/// 一个单元格的求值结果。
class OSheetFormulaResult {
  const OSheetFormulaResult._(this.status, this.value, this.reason);

  const OSheetFormulaResult.value(Object? value)
    : this._(OSheetFormulaStatus.value, value, null);

  const OSheetFormulaResult.error(OSheetFormulaError error)
    : this._(OSheetFormulaStatus.error, error, null);

  const OSheetFormulaResult.unsupported(String reason)
    : this._(OSheetFormulaStatus.unsupported, null, reason);

  final OSheetFormulaStatus status;
  final Object? value;
  final String? reason;

  bool get isError => status == OSheetFormulaStatus.error;
  bool get isUnsupported => status == OSheetFormulaStatus.unsupported;
  bool get hasValue => status == OSheetFormulaStatus.value;

  /// 错误码（非错误 → `null`）。
  String? get errorCode => isError ? (value! as OSheetFormulaError).code : null;

  @override
  String toString() => 'OSheetFormulaResult($status, $value, $reason)';
}

// ---------------------------------------------------------------------------
// 单元格坐标
// ---------------------------------------------------------------------------

/// 列字母 → 0 基列号（`A`→0、`Z`→25、`AA`→26）；非法 → `null`。
int? oSheetColumnIndex(String letters) {
  if (letters.isEmpty) return null;
  var value = 0;
  for (final unit in letters.toUpperCase().codeUnits) {
    if (unit < 65 || unit > 90) return null;
    value = value * 26 + (unit - 64);
  }
  return value - 1;
}

/// `A1` / `$A$1` → `(row, col)`（0 基）；非法 → `null`。绝对/相对都当普通引用。
({int row, int col})? oSheetParseA1(String text) {
  final s = text.trim().replaceAll('\$', '');
  final match = RegExp(r'^([A-Za-z]+)([0-9]+)$').firstMatch(s);
  if (match == null) return null;
  final col = oSheetColumnIndex(match.group(1)!);
  final row1 = int.tryParse(match.group(2)!);
  if (col == null || row1 == null || row1 < 1) return null;
  return (row: row1 - 1, col: col);
}

/// 区域 `A1:B2` → 已归一化的闭区间（`r1<=r2`、`c1<=c2`）；非法 → `null`。
///
/// 支持跨列并集里的**单段**（`displayRange` 的 `B8:B12,J8:J12` 由调用方先按
/// `,` 拆分）。
({int r1, int c1, int r2, int c2})? oSheetParseRange(String text) {
  final parts = text.split(':');
  if (parts.length != 2) {
    final single = oSheetParseA1(text);
    if (single == null) return null;
    return (r1: single.row, c1: single.col, r2: single.row, c2: single.col);
  }
  final a = oSheetParseA1(parts[0]);
  final b = oSheetParseA1(parts[1]);
  if (a == null || b == null) return null;
  return (
    r1: a.row <= b.row ? a.row : b.row,
    c1: a.col <= b.col ? a.col : b.col,
    r2: a.row >= b.row ? a.row : b.row,
    c2: a.col >= b.col ? a.col : b.col,
  );
}

/// `displayRange` / `SUM` 参数里的**并集**（`B8:B12,J8:J12`）→ 区间列表。
///
/// 逗号分隔；每段必须是合法区域/单元格；含非法段 → `null`（不猜）。
List<({int r1, int c1, int r2, int c2})>? oSheetParseRangeUnion(String text) {
  final out = <({int r1, int c1, int r2, int c2})>[];
  for (final raw in text.split(',')) {
    final segment = raw.trim();
    if (segment.isEmpty) continue;
    final range = oSheetParseRange(segment);
    if (range == null) return null;
    out.add(range);
  }
  return out.isEmpty ? null : out;
}

/// 把区域按**逐格**展开（行优先），返回 `(row, col)` 列表。
///
/// 上限保护：单次展开超过 [maxCells] 个格子 → 只取前 [maxCells] 个
/// （工作表可能声明 100 万行，区域求值必须封顶）。
List<({int row, int col})> oSheetExpandRange(
  ({int r1, int c1, int r2, int c2}) range, {
  int maxCells = 1 << 20,
}) {
  final out = <({int row, int col})>[];
  for (var r = range.r1; r <= range.r2; r++) {
    for (var c = range.c1; c <= range.c2; c++) {
      if (out.length >= maxCells) return out;
      out.add((row: r, col: c));
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

/// 词法单元种类。
enum OSheetFormulaTokenType {
  number,
  string,
  identifier,
  operator,
  lparen,
  rparen,
  comma,
  colon,
  percent,
  bang,
  end,
}

/// 一个词法单元。
class OSheetFormulaToken {
  const OSheetFormulaToken(this.type, this.text, [this.numberValue]);

  final OSheetFormulaTokenType type;
  final String text;

  /// [OSheetFormulaTokenType.number] 的数值。
  final double? numberValue;

  @override
  String toString() => '${type.name}($text)';
}

/// 把公式体（可带前导 `=`）切成词法单元。
///
/// 非法字符 → `null`（调用方退化为显示原文）；**不抛**。
List<OSheetFormulaToken>? tokenizeOSheetFormula(String source) {
  final text = source.startsWith('=') ? source.substring(1) : source;
  final out = <OSheetFormulaToken>[];
  var i = 0;
  while (i < text.length) {
    final ch = text[i];
    // 空白
    if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
      i++;
      continue;
    }
    // 数字（1 / 1.5 / .5 / 1e3）
    if (_isDigit(ch) ||
        (ch == '.' && i + 1 < text.length && _isDigit(text[i + 1]))) {
      final start = i;
      var seenDot = false;
      var seenExp = false;
      while (i < text.length) {
        final c = text[i];
        if (_isDigit(c)) {
          i++;
        } else if (c == '.' && !seenDot && !seenExp) {
          seenDot = true;
          i++;
        } else if ((c == 'e' || c == 'E') &&
            !seenExp &&
            i + 1 < text.length &&
            (_isDigit(text[i + 1]) ||
                ((text[i + 1] == '+' || text[i + 1] == '-') &&
                    i + 2 < text.length &&
                    _isDigit(text[i + 2])))) {
          seenExp = true;
          i++;
          if (text[i] == '+' || text[i] == '-') i++;
        } else {
          break;
        }
      }
      final raw = text.substring(start, i);
      final value = double.tryParse(raw);
      if (value == null) return null;
      out.add(OSheetFormulaToken(OSheetFormulaTokenType.number, raw, value));
      continue;
    }
    // 字符串字面量（Excel 用双引号，`""` 表示一个引号）
    if (ch == '"') {
      final buf = StringBuffer();
      i++;
      var closed = false;
      while (i < text.length) {
        if (text[i] == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            buf.write('"');
            i += 2;
            continue;
          }
          i++;
          closed = true;
          break;
        }
        buf.write(text[i]);
        i++;
      }
      if (!closed) return null;
      out.add(
        OSheetFormulaToken(OSheetFormulaTokenType.string, buf.toString()),
      );
      continue;
    }
    // 标识符 / 单元格引用 / 布尔
    if (_isIdentStart(ch)) {
      final start = i;
      while (i < text.length && _isIdentPart(text[i])) {
        i++;
      }
      out.add(
        OSheetFormulaToken(
          OSheetFormulaTokenType.identifier,
          text.substring(start, i),
        ),
      );
      continue;
    }
    // 运算符
    final two = i + 1 < text.length ? text.substring(i, i + 2) : '';
    if (two == '<=' || two == '>=' || two == '<>') {
      out.add(OSheetFormulaToken(OSheetFormulaTokenType.operator, two));
      i += 2;
      continue;
    }
    switch (ch) {
      case '+':
      case '-':
      case '*':
      case '/':
      case '^':
      case '&':
      case '=':
      case '<':
      case '>':
        out.add(OSheetFormulaToken(OSheetFormulaTokenType.operator, ch));
      case '(':
        out.add(const OSheetFormulaToken(OSheetFormulaTokenType.lparen, '('));
      case ')':
        out.add(const OSheetFormulaToken(OSheetFormulaTokenType.rparen, ')'));
      case ',':
        out.add(const OSheetFormulaToken(OSheetFormulaTokenType.comma, ','));
      case ':':
        out.add(const OSheetFormulaToken(OSheetFormulaTokenType.colon, ':'));
      case '%':
        out.add(const OSheetFormulaToken(OSheetFormulaTokenType.percent, '%'));
      case '!':
        out.add(const OSheetFormulaToken(OSheetFormulaTokenType.bang, '!'));
      default:
        return null;
    }
    i++;
  }
  out.add(const OSheetFormulaToken(OSheetFormulaTokenType.end, ''));
  return out;
}

bool _isDigit(String c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;

bool _isIdentStart(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 65 && u <= 90) ||
      (u >= 97 && u <= 122) ||
      u == 95 ||
      c == '\$' ||
      u > 127;
}

bool _isIdentPart(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 65 && u <= 90) ||
      (u >= 97 && u <= 122) ||
      (u >= 48 && u <= 57) ||
      u == 95 ||
      c == '\$' ||
      c == '.' ||
      u > 127;
}

// ---------------------------------------------------------------------------
// AST
// ---------------------------------------------------------------------------

/// 公式表达式（AST）。
sealed class OSheetFormulaExpression {
  const OSheetFormulaExpression();
}

/// 数字/字符串/布尔字面量。
class OSheetLiteral extends OSheetFormulaExpression {
  const OSheetLiteral(this.value);
  final Object value;
}

/// 单元格引用（0 基；绝对/相对对求值无差别）。
class OSheetRef extends OSheetFormulaExpression {
  const OSheetRef(this.row, this.col);
  final int row;
  final int col;
}

/// 区域引用（闭区间，已归一化）。
class OSheetRange extends OSheetFormulaExpression {
  const OSheetRange(this.r1, this.c1, this.r2, this.c2);
  final int r1;
  final int c1;
  final int r2;
  final int c2;
}

/// 一元运算（`-` / `+`）。
class OSheetUnary extends OSheetFormulaExpression {
  const OSheetUnary(this.op, this.operand);
  final String op;
  final OSheetFormulaExpression operand;
}

/// 后缀百分比。
class OSheetPercent extends OSheetFormulaExpression {
  const OSheetPercent(this.operand);
  final OSheetFormulaExpression operand;
}

/// 二元运算（`+ - * / ^ & = <> < > <= >=`）。
class OSheetBinary extends OSheetFormulaExpression {
  const OSheetBinary(this.op, this.left, this.right);
  final String op;
  final OSheetFormulaExpression left;
  final OSheetFormulaExpression right;
}

/// 函数调用。
class OSheetFunctionCall extends OSheetFormulaExpression {
  const OSheetFunctionCall(this.name, this.args);
  final String name;
  final List<OSheetFormulaExpression> args;
}

// ---------------------------------------------------------------------------
// Parser（递归下降）
// ---------------------------------------------------------------------------

/// 解析公式体；失败 → `null`（调用方显示原文）。
OSheetFormulaExpression? parseOSheetFormula(String source) {
  final tokens = tokenizeOSheetFormula(source);
  if (tokens == null) return null;
  final parser = _OSheetFormulaParser(tokens);
  try {
    final expr = parser.parseExpression();
    if (!parser.atEnd) return null;
    return expr;
  } on OSheetFormulaUnsupported {
    // 跨表引用等在解析期就判定"无法求值"。
    return null;
  }
}

class _OSheetFormulaParser {
  _OSheetFormulaParser(this.tokens);
  final List<OSheetFormulaToken> tokens;
  int _pos = 0;

  bool get atEnd => _peek.type == OSheetFormulaTokenType.end;

  OSheetFormulaToken get _peek => tokens[_pos];

  OSheetFormulaToken _next() => tokens[_pos++];

  bool _matchOperator(String op) {
    if (_peek.type == OSheetFormulaTokenType.operator && _peek.text == op) {
      _pos++;
      return true;
    }
    return false;
  }

  OSheetFormulaExpression parseExpression() => _parseComparison();

  OSheetFormulaExpression _parseComparison() {
    var left = _parseConcat();
    while (_peek.type == OSheetFormulaTokenType.operator &&
        const <String>{'=', '<>', '<', '>', '<=', '>='}.contains(_peek.text)) {
      final op = _next().text;
      left = OSheetBinary(op, left, _parseConcat());
    }
    return left;
  }

  OSheetFormulaExpression _parseConcat() {
    var left = _parseAdditive();
    while (_matchOperator('&')) {
      left = OSheetBinary('&', left, _parseAdditive());
    }
    return left;
  }

  OSheetFormulaExpression _parseAdditive() {
    var left = _parseMultiplicative();
    while (_peek.type == OSheetFormulaTokenType.operator &&
        (_peek.text == '+' || _peek.text == '-')) {
      final op = _next().text;
      left = OSheetBinary(op, left, _parseMultiplicative());
    }
    return left;
  }

  OSheetFormulaExpression _parseMultiplicative() {
    var left = _parseUnary();
    while (_peek.type == OSheetFormulaTokenType.operator &&
        (_peek.text == '*' || _peek.text == '/')) {
      final op = _next().text;
      left = OSheetBinary(op, left, _parseUnary());
    }
    return left;
  }

  OSheetFormulaExpression _parseUnary() {
    if (_peek.type == OSheetFormulaTokenType.operator &&
        (_peek.text == '-' || _peek.text == '+')) {
      final op = _next().text;
      return OSheetUnary(op, _parseUnary());
    }
    return _parsePower();
  }

  OSheetFormulaExpression _parsePower() {
    final base = _parsePostfix();
    if (_matchOperator('^')) {
      // 右结合：2^3^2 = 2^(3^2)。
      return OSheetBinary('^', base, _parseUnary());
    }
    return base;
  }

  OSheetFormulaExpression _parsePostfix() {
    var expr = _parsePrimary();
    while (_peek.type == OSheetFormulaTokenType.percent) {
      _next();
      expr = OSheetPercent(expr);
    }
    return expr;
  }

  OSheetFormulaExpression _parsePrimary() {
    final token = _peek;
    switch (token.type) {
      case OSheetFormulaTokenType.number:
        _next();
        return OSheetLiteral(token.numberValue!);
      case OSheetFormulaTokenType.string:
        _next();
        return OSheetLiteral(token.text);
      case OSheetFormulaTokenType.lparen:
        _next();
        final inner = parseExpression();
        if (_peek.type != OSheetFormulaTokenType.rparen) {
          throw const OSheetFormulaUnsupported('括号不匹配');
        }
        _next();
        return inner;
      case OSheetFormulaTokenType.identifier:
        return _parseIdentifier();
      default:
        throw const OSheetFormulaUnsupported('意外的词法单元');
    }
  }

  OSheetFormulaExpression _parseIdentifier() {
    final name = _next().text;
    // 函数调用
    if (_peek.type == OSheetFormulaTokenType.lparen) {
      _next();
      final args = <OSheetFormulaExpression>[];
      if (_peek.type != OSheetFormulaTokenType.rparen) {
        args.add(parseExpression());
        while (_peek.type == OSheetFormulaTokenType.comma) {
          _next();
          args.add(parseExpression());
        }
      }
      if (_peek.type != OSheetFormulaTokenType.rparen) {
        throw const OSheetFormulaUnsupported('函数参数括号不匹配');
      }
      _next();
      return OSheetFunctionCall(name.toUpperCase(), args);
    }
    // 跨表引用：`Sheet!A1` → 本求值器不支持（退化显示原文）。
    if (_peek.type == OSheetFormulaTokenType.bang) {
      throw const OSheetFormulaUnsupported('跨表引用');
    }
    final upper = name.toUpperCase();
    if (upper == 'TRUE') return const OSheetLiteral(true);
    if (upper == 'FALSE') return const OSheetLiteral(false);
    // 单元格 / 区域
    final head = oSheetParseA1(name);
    if (head == null) {
      throw OSheetFormulaUnsupported('无法识别的名称 $name');
    }
    if (_peek.type == OSheetFormulaTokenType.colon) {
      _next();
      if (_peek.type != OSheetFormulaTokenType.identifier) {
        throw const OSheetFormulaUnsupported('区域缺少末端引用');
      }
      final tailToken = _next();
      if (_peek.type == OSheetFormulaTokenType.bang) {
        throw const OSheetFormulaUnsupported('跨表引用');
      }
      final tail = oSheetParseA1(tailToken.text);
      if (tail == null) {
        throw const OSheetFormulaUnsupported('区域末端非法');
      }
      return OSheetRange(
        head.row <= tail.row ? head.row : tail.row,
        head.col <= tail.col ? head.col : tail.col,
        head.row >= tail.row ? head.row : tail.row,
        head.col >= tail.col ? head.col : tail.col,
      );
    }
    return OSheetRef(head.row, head.col);
  }
}

// ---------------------------------------------------------------------------
// 求值
// ---------------------------------------------------------------------------

/// 单元格求值解析器：给定 0 基坐标，返回该格的求值结果。
///
/// 实现方负责**循环引用检测**（见 [OSheetFormulaEngine]）。
abstract class OSheetFormulaResolver {
  OSheetFormulaResult resolveCell(int row, int col);
}

/// 基于内存映射的解析器（离线单测 / 图表数值来源）。
class OSheetMapFormulaResolver implements OSheetFormulaResolver {
  OSheetMapFormulaResolver(this.values, {this.formulas = const {}});

  /// `(row, col)` → 原始值（非公式单元格）。
  final Map<(int, int), Object?> values;

  /// `(row, col)` → 公式原文（`=…`）。
  final Map<(int, int), String> formulas;

  final Map<(int, int), OSheetFormulaResult> _cache = {};
  final Set<(int, int)> _active = {};

  @override
  OSheetFormulaResult resolveCell(int row, int col) {
    if (_cache.containsKey((row, col))) return _cache[(row, col)]!;
    if (_active.contains((row, col))) {
      return const OSheetFormulaResult.error(kOSheetFormulaCircular);
    }
    final formula = formulas[(row, col)];
    if (formula == null) {
      return OSheetFormulaResult.value(values[(row, col)]);
    }
    _active.add((row, col));
    OSheetFormulaResult result;
    try {
      result = evaluateOSheetFormula(formula, this);
    } finally {
      _active.remove((row, col));
    }
    _cache[(row, col)] = result;
    return result;
  }
}

/// 对一条公式求值；[resolver] 负责单元格/公式格的取值与环检测。
///
/// 解析失败 / 未支持 → 返回 [OSheetFormulaResult.unsupported]（显示原文）。
OSheetFormulaResult evaluateOSheetFormula(
  String formula,
  OSheetFormulaResolver resolver,
) {
  final ast = parseOSheetFormula(formula);
  if (ast == null) {
    return const OSheetFormulaResult.unsupported('解析失败');
  }
  try {
    final value = _OSheetFormulaEvaluator(resolver).eval(ast);
    if (value is OSheetFormulaError) {
      return OSheetFormulaResult.error(value);
    }
    return OSheetFormulaResult.value(value);
  } on OSheetFormulaUnsupported catch (e) {
    return OSheetFormulaResult.unsupported(e.reason);
  } on Object catch (e) {
    // 求值器自身的意外一律降级为"显示原文"，绝不冒泡成崩溃。
    return OSheetFormulaResult.unsupported('求值异常：$e');
  }
}

class _OSheetFormulaEvaluator {
  _OSheetFormulaEvaluator(this.resolver);
  final OSheetFormulaResolver resolver;

  Object? eval(OSheetFormulaExpression node) {
    switch (node) {
      case OSheetLiteral(:final value):
        return value;
      case OSheetRef(:final row, :final col):
        return _cellValue(row, col);
      case OSheetRange():
        return kOSheetFormulaValue; // 区域不能当标量用
      case OSheetUnary(:final op, :final operand):
        final v = _toNumber(eval(operand));
        if (v is OSheetFormulaError) return v;
        return op == '-' ? -(v as num) : v;
      case OSheetPercent(:final operand):
        final v = _toNumber(eval(operand));
        if (v is OSheetFormulaError) return v;
        return (v as num) / 100;
      case OSheetBinary(:final op, :final left, :final right):
        return _binary(op, left, right);
      case OSheetFunctionCall(:final name, :final args):
        return _call(name, args);
    }
  }

  // ---- 单元格取值 -----------------------------------------------------------

  Object? _cellValue(int row, int col) {
    if (row < 0 || col < 0) return kOSheetFormulaRef;
    final result = resolver.resolveCell(row, col);
    switch (result.status) {
      case OSheetFormulaStatus.value:
        return result.value;
      case OSheetFormulaStatus.error:
        return result.value;
      case OSheetFormulaStatus.unsupported:
        // 引用了无法求值的公式格 → 本格也无法求值（整体显示原文）。
        throw OSheetFormulaUnsupported(
          '引用的单元格 ${oSheetColumnLabel(col)}${row + 1} 无法求值',
        );
    }
  }

  /// 展开一个节点为**值列表**（区域 → 逐格；引用 → 单值；其它 → 单值）。
  List<Object?> _values(OSheetFormulaExpression node) {
    if (node is OSheetRange) {
      final out = <Object?>[];
      for (var r = node.r1; r <= node.r2; r++) {
        for (var c = node.c1; c <= node.c2; c++) {
          out.add(_cellValue(r, c));
        }
      }
      return out;
    }
    return <Object?>[eval(node)];
  }

  // ---- 类型强制 -------------------------------------------------------------

  /// 标量 → 数字（空=0、bool=1/0、数字文本可转；否则 `#VALUE!`）。
  Object _toNumber(Object? value) {
    if (value is OSheetFormulaError) return value;
    if (value == null) return 0;
    if (value is num) return value;
    if (value is bool) return value ? 1 : 0;
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return 0;
      final parsed = num.tryParse(trimmed);
      if (parsed != null) return parsed;
      return kOSheetFormulaValue;
    }
    return kOSheetFormulaValue;
  }

  bool _toBool(Object? value) {
    if (value is OSheetFormulaError) return false;
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final upper = value.trim().toUpperCase();
      if (upper == 'TRUE') return true;
      if (upper == 'FALSE') return false;
      return value.trim().isNotEmpty;
    }
    return false;
  }

  static String _text(Object? value) => asJsonScalarText(value) ?? '';

  // ---- 二元运算 -------------------------------------------------------------

  Object? _binary(
    String op,
    OSheetFormulaExpression left,
    OSheetFormulaExpression right,
  ) {
    // 比较 / 连接走各自路径。
    if (const <String>{'=', '<>', '<', '>', '<=', '>='}.contains(op)) {
      return _compare(op, eval(left), eval(right));
    }
    if (op == '&') {
      final l = eval(left);
      final r = eval(right);
      if (l is OSheetFormulaError) return l;
      if (r is OSheetFormulaError) return r;
      return _text(l) + _text(r);
    }
    final l = _toNumber(eval(left));
    if (l is OSheetFormulaError) return l;
    final r = _toNumber(eval(right));
    if (r is OSheetFormulaError) return r;
    final a = l as num;
    final b = r as num;
    switch (op) {
      case '+':
        return a + b;
      case '-':
        return a - b;
      case '*':
        return a * b;
      case '/':
        if (b == 0) return kOSheetFormulaDivZero;
        return a / b;
      case '^':
        if (a == 0 && b < 0) return kOSheetFormulaDivZero;
        final v = _pow(a, b);
        if (v.isNaN || v.isInfinite) return kOSheetFormulaNum;
        return v;
      default:
        return kOSheetFormulaValue;
    }
  }

  static num _pow(num a, num b) {
    if (b is int) {
      var result = 1.0;
      final negative = b < 0;
      var exp = negative ? -b : b;
      var baseV = a.toDouble();
      while (exp > 0) {
        if (exp & 1 == 1) result *= baseV;
        baseV *= baseV;
        exp >>= 1;
      }
      return negative ? 1 / result : result;
    }
    // 非整数指数需要浮点 pow；`dart:math` 允许（不是 Flutter 依赖）。
    return _mathPow(a.toDouble(), b.toDouble());
  }

  Object _compare(String op, Object? l, Object? r) {
    if (l is OSheetFormulaError) return l;
    if (r is OSheetFormulaError) return r;
    // 两边都能当数字 → 数值比较（Excel 语义）；否则文本比较（忽略大小写）。
    final ln = _tryNum(l);
    final rn = _tryNum(r);
    int cmp;
    if (ln != null && rn != null) {
      cmp = ln.compareTo(rn);
    } else {
      cmp = _text(l).toUpperCase().compareTo(_text(r).toUpperCase());
    }
    switch (op) {
      case '=':
        return cmp == 0;
      case '<>':
        return cmp != 0;
      case '<':
        return cmp < 0;
      case '>':
        return cmp > 0;
      case '<=':
        return cmp <= 0;
      case '>=':
        return cmp >= 0;
      default:
        return kOSheetFormulaValue;
    }
  }

  num? _tryNum(Object? value) {
    if (value == null) return null;
    if (value is num) return value;
    if (value is bool) return value ? 1 : 0;
    if (value is String) return num.tryParse(value.trim());
    return null;
  }

  // ---- 函数 -----------------------------------------------------------------

  Object? _call(String name, List<OSheetFormulaExpression> args) {
    switch (name) {
      case 'SUM':
        return _sum(args);
      case 'AVERAGE':
        return _average(args);
      case 'MIN':
        return _minMax(args, isMin: true);
      case 'MAX':
        return _minMax(args, isMin: false);
      case 'COUNT':
        return _count(args, countText: false);
      case 'COUNTA':
        return _count(args, countText: true);
      case 'ROUND':
        return _round(args);
      case 'ABS':
        return _abs(args);
      case 'IF':
        return _if(args);
      case 'AND':
        return _andOr(args, isAnd: true);
      case 'OR':
        return _andOr(args, isAnd: false);
      case 'NOT':
        if (args.length != 1) {
          throw const OSheetFormulaUnsupported('NOT 参数个数');
        }
        final v = eval(args.first);
        if (v is OSheetFormulaError) return v;
        return !_toBool(v);
      case 'ISBLANK':
        if (args.length != 1) {
          throw const OSheetFormulaUnsupported('ISBLANK 参数个数');
        }
        return _isBlank(args.first);
      case 'SUMIF':
        return _sumIf(args);
      case 'COUNTIF':
        return _countIf(args);
      default:
        throw OSheetFormulaUnsupported('未支持的函数 $name');
    }
  }

  /// 汇总参数里的**数值**（区域忽略文本/布尔/空 —— Excel `SUM` 语义）。
  List<num> _numbers(List<OSheetFormulaExpression> args) {
    final out = <num>[];
    for (final arg in args) {
      for (final value in _values(arg)) {
        if (value is OSheetFormulaError) {
          throw _FormulaErrorSignal(value);
        }
        if (value is num) out.add(value);
      }
    }
    return out;
  }

  Object? _sum(List<OSheetFormulaExpression> args) {
    try {
      final nums = _numbers(args);
      num total = 0;
      for (final n in nums) {
        total += n;
      }
      return _normalize(total);
    } on _FormulaErrorSignal catch (e) {
      return e.error;
    }
  }

  Object? _average(List<OSheetFormulaExpression> args) {
    try {
      final nums = _numbers(args);
      if (nums.isEmpty) return kOSheetFormulaDivZero;
      num total = 0;
      for (final n in nums) {
        total += n;
      }
      return _normalize(total / nums.length);
    } on _FormulaErrorSignal catch (e) {
      return e.error;
    }
  }

  Object? _minMax(List<OSheetFormulaExpression> args, {required bool isMin}) {
    try {
      final nums = _numbers(args);
      if (nums.isEmpty) return 0;
      var best = nums.first;
      for (final n in nums.skip(1)) {
        if (isMin ? n < best : n > best) best = n;
      }
      return _normalize(best);
    } on _FormulaErrorSignal catch (e) {
      return e.error;
    }
  }

  Object? _count(
    List<OSheetFormulaExpression> args, {
    required bool countText,
  }) {
    var count = 0;
    for (final arg in args) {
      for (final value in _values(arg)) {
        if (value is OSheetFormulaError) {
          if (value.code == '#CIRC!') return value;
          continue;
        }
        if (value == null) continue;
        if (value is num) {
          count++;
        } else if (countText) {
          count++;
        }
      }
    }
    return count;
  }

  Object? _round(List<OSheetFormulaExpression> args) {
    if (args.length != 2) {
      throw const OSheetFormulaUnsupported('ROUND 参数个数');
    }
    final value = _toNumber(eval(args[0]));
    if (value is OSheetFormulaError) return value;
    final digits = _toNumber(eval(args[1]));
    if (digits is OSheetFormulaError) return digits;
    final places = (digits as num).toInt();
    final factor = _pow10(places.abs());
    final scaled =
        (value as num).toDouble() * (places < 0 ? 1 / factor : factor);
    // Excel 的"四舍五入"（远离零）。
    final rounded = scaled < 0
        ? -((-scaled) + 0.5).floorToDouble()
        : (scaled + 0.5).floorToDouble();
    return _normalize(rounded * (places < 0 ? factor : 1 / factor));
  }

  static double _pow10(int n) {
    var v = 1.0;
    for (var i = 0; i < n; i++) {
      v *= 10;
    }
    return v;
  }

  Object? _abs(List<OSheetFormulaExpression> args) {
    if (args.length != 1) {
      throw const OSheetFormulaUnsupported('ABS 参数个数');
    }
    final value = _toNumber(eval(args.first));
    if (value is OSheetFormulaError) return value;
    return _normalize((value as num).abs());
  }

  Object? _if(List<OSheetFormulaExpression> args) {
    if (args.length < 2 || args.length > 3) {
      throw const OSheetFormulaUnsupported('IF 参数个数');
    }
    final condition = eval(args[0]);
    if (condition is OSheetFormulaError) return condition;
    if (_toBool(condition)) return eval(args[1]);
    return args.length == 3 ? eval(args[2]) : false;
  }

  Object? _andOr(List<OSheetFormulaExpression> args, {required bool isAnd}) {
    var sawAny = false;
    for (final arg in args) {
      for (final value in _values(arg)) {
        if (value is OSheetFormulaError) {
          if (value.code == '#CIRC!') return value;
          continue;
        }
        final boolValue = _toBool(value);
        sawAny = true;
        if (isAnd && !boolValue) return false;
        if (!isAnd && boolValue) return true;
      }
    }
    if (!sawAny) {
      // Excel：AND() / OR() 空参数 → #VALUE!。
      return kOSheetFormulaValue;
    }
    return isAnd;
  }

  /// `ISBLANK(ref)`：**空**指该格没有值（公式格先求值，`0` 不算空）。
  Object? _isBlank(OSheetFormulaExpression arg) {
    if (arg is OSheetRange) {
      for (var r = arg.r1; r <= arg.r2; r++) {
        for (var c = arg.c1; c <= arg.c2; c++) {
          if (!_isBlankCell(r, c)) return false;
        }
      }
      return true;
    }
    if (arg is OSheetRef) return _isBlankCell(arg.row, arg.col);
    final value = eval(arg);
    return value == null || value == '';
  }

  bool _isBlankCell(int row, int col) {
    final result = resolver.resolveCell(row, col);
    if (result.status == OSheetFormulaStatus.unsupported) {
      throw OSheetFormulaUnsupported('ISBLANK 的引用格无法求值');
    }
    return result.value == null;
  }

  /// `SUMIF(range, criteria, sumRange)`。
  Object? _sumIf(List<OSheetFormulaExpression> args) {
    if (args.length != 3) {
      throw const OSheetFormulaUnsupported('SUMIF 参数个数');
    }
    if (args[0] is! OSheetRange || args[2] is! OSheetRange) {
      throw const OSheetFormulaUnsupported('SUMIF 只支持区域参数');
    }
    final range = args[0] as OSheetRange;
    final sumRange = args[2] as OSheetRange;
    final criteriaValue = eval(args[1]);
    if (criteriaValue is OSheetFormulaError) return criteriaValue;
    final criteria = _text(criteriaValue);
    final (op, target) = _splitCriteria(criteria);
    final matches = <(int, int)>[];
    for (var r = range.r1; r <= range.r2; r++) {
      for (var c = range.c1; c <= range.c2; c++) {
        final value = _cellValue(r, c);
        if (value is OSheetFormulaError) {
          if (value.code == '#CIRC!') return value;
          continue;
        }
        if (_matchesCriteria(value, op, target)) matches.add((r, c));
      }
    }
    num total = 0;
    for (final (r, c) in matches) {
      // 与 `range` 同形偏移到 `sumRange`。
      final sr = sumRange.r1 + (r - range.r1);
      final sc = sumRange.c1 + (c - range.c1);
      if (sr < sumRange.r1 ||
          sr > sumRange.r2 ||
          sc < sumRange.c1 ||
          sc > sumRange.c2) {
        continue;
      }
      final value = _cellValue(sr, sc);
      if (value is OSheetFormulaError) {
        if (value.code == '#CIRC!') return value;
        continue;
      }
      if (value is num) total += value;
    }
    return _normalize(total);
  }

  /// `COUNTIF(range, criteria)`：与 [SUMIF] 同款条件匹配，只计数。
  Object? _countIf(List<OSheetFormulaExpression> args) {
    if (args.length != 2) {
      throw const OSheetFormulaUnsupported('COUNTIF 参数个数');
    }
    if (args[0] is! OSheetRange) {
      throw const OSheetFormulaUnsupported('COUNTIF 只支持区域参数');
    }
    final range = args[0] as OSheetRange;
    final criteriaValue = eval(args[1]);
    if (criteriaValue is OSheetFormulaError) return criteriaValue;
    final (op, target) = _splitCriteria(_text(criteriaValue));
    var count = 0;
    for (var r = range.r1; r <= range.r2; r++) {
      for (var c = range.c1; c <= range.c2; c++) {
        final value = _cellValue(r, c);
        if (value is OSheetFormulaError) {
          if (value.code == '#CIRC!') return value;
          continue;
        }
        if (_matchesCriteria(value, op, target)) count++;
      }
    }
    return count;
  }

  static (String, String) _splitCriteria(String criteria) {
    const operators = <String>['<=', '>=', '<>', '=', '<', '>'];
    for (final op in operators) {
      if (criteria.startsWith(op)) {
        return (op, criteria.substring(op.length));
      }
    }
    return ('=', criteria);
  }

  bool _matchesCriteria(Object? value, String op, String target) {
    final valueNum = _tryNum(value);
    final targetNum = num.tryParse(target.trim());
    if (valueNum != null && targetNum != null) {
      final cmp = valueNum.compareTo(targetNum);
      return _applyCmp(op, cmp);
    }
    final cmp = _text(
      value,
    ).toUpperCase().compareTo(target.trim().toUpperCase());
    return _applyCmp(op, cmp);
  }

  static bool _applyCmp(String op, int cmp) {
    switch (op) {
      case '=':
        return cmp == 0;
      case '<>':
        return cmp != 0;
      case '<':
        return cmp < 0;
      case '>':
        return cmp > 0;
      case '<=':
        return cmp <= 0;
      case '>=':
        return cmp >= 0;
      default:
        return false;
    }
  }

  /// 整数结果保持 int（避免 `SUM` 出 `2877.0` 这种噪声显示）。
  static Object _normalize(num value) {
    if (value is int) return value;
    if (value == value.roundToDouble() && value.abs() < 1e15) {
      return value.toInt();
    }
    return value;
  }
}

/// 把"区域里遇到错误值"变成受控信号（聚合函数捕获后返回该错误）。
class _FormulaErrorSignal implements Exception {
  const _FormulaErrorSignal(this.error);
  final OSheetFormulaError error;
}

double _mathPow(double a, double b) {
  if (b == b.roundToDouble() && b.abs() < 1e9) {
    return _OSheetFormulaEvaluator._pow(a, b.toInt()).toDouble();
  }
  // 非整数指数：用 `exp(b*ln(a))`，避免 import dart:math（保持本文件零依赖面）。
  if (a <= 0) return double.nan;
  return _exp(b * _ln(a));
}

double _ln(double x) {
  if (x <= 0) return double.nan;
  // 归一到 [1,2) 后用 atanh 级数。
  var exponent = 0;
  var v = x;
  while (v >= 2) {
    v /= 2;
    exponent++;
  }
  while (v < 1) {
    v *= 2;
    exponent--;
  }
  final z = (v - 1) / (v + 1);
  var term = z;
  var sum = 0.0;
  for (var k = 0; k < 60; k++) {
    sum += term / (2 * k + 1);
    term *= z * z;
  }
  return 2 * sum + exponent * 0.6931471805599453;
}

double _exp(double x) {
  var term = 1.0;
  var sum = 1.0;
  for (var k = 1; k < 120; k++) {
    term *= x / k;
    sum += term;
    if (term.abs() < 1e-18) break;
  }
  return sum;
}

// ---------------------------------------------------------------------------
// 工作表级求值引擎
// ---------------------------------------------------------------------------

/// 把一张 [OSheetSheet] 包成带缓存 + 环检测的求值器。
///
/// 用法：`final engine = OSheetFormulaEngine(sheet); engine.resultAt(r, c);`
///
/// [overrideAt] 是**可选的协作覆盖**：返回非 null 时该格的取值以它为准，**不再读
/// 文件**。`.osheet` 协作会话里远端广播 / 本地乐观值与文件快照可能不同（R17 修复：
/// 公式格在会话建立后要显示求值结果，引用也必须看得到协作改动，否则会停在文件
/// 快照上）。没有覆盖（默认 null）时行为**逐字不变**；离线只读路径不传它。
class OSheetFormulaEngine implements OSheetFormulaResolver {
  OSheetFormulaEngine(this.sheet, {this.overrideAt});

  final OSheetSheet sheet;

  /// `(row, col) → (true, value)` 时覆盖该格取值；`null` = 没有覆盖。
  final (bool, Object?)? Function(int row, int col)? overrideAt;

  final Map<int, OSheetFormulaResult> _cache = {};
  final Set<int> _active = {};
  final Set<int> _circularKeys = {};

  /// 求值过的公式格数量 / 无法求值的公式格数量 / 循环引用格数量（供报告用）。
  int formulaCellsEvaluated = 0;
  int formulaCellsFailed = 0;

  /// 命中循环引用（`#CIRC!`）的**去重**单元格数。
  int get circularCells => _circularKeys.length;

  static int _key(int row, int col) => row * 1000003 + col;

  @override
  OSheetFormulaResult resolveCell(int row, int col) {
    // 覆盖值**不进缓存**（远端/乐观值会变；缓存会让公式停在旧值上）。
    final override = overrideAt?.call(row, col);
    if (override != null && override.$1) {
      return OSheetFormulaResult.value(override.$2);
    }
    final cell = sheet.cellAt(row, col);
    if (cell == null) return const OSheetFormulaResult.value(null);
    if (!cell.isFormula) return OSheetFormulaResult.value(cell.value);

    final key = _key(row, col);
    final cached = _cache[key];
    if (cached != null) return cached;
    if (_active.contains(key)) {
      // 环：**不缓存**这个瞬时结果（环上首格最终会拿到自己的求值结果）。
      return const OSheetFormulaResult.error(kOSheetFormulaCircular);
    }
    _active.add(key);
    OSheetFormulaResult result;
    try {
      result = evaluateOSheetFormula(cell.formulaText!, this);
    } finally {
      _active.remove(key);
    }
    if (result.isError && result.errorCode == kOSheetFormulaCircular.code) {
      _circularKeys.add(key);
    } else if (result.isUnsupported) {
      formulaCellsFailed++;
    } else {
      formulaCellsEvaluated++;
    }
    _cache[key] = result;
    return result;
  }

  /// 单元格的**显示值**：公式算出的值；无法求值 → `null`（调用方显示原文）。
  Object? valueAt(int row, int col) {
    final result = resolveCell(row, col);
    return result.hasValue ? result.value : null;
  }

  /// 单元格的**显示文本**：算出数值用标量文本；无法求值 → `null`。
  String? textAt(int row, int col) {
    final result = resolveCell(row, col);
    if (result.isError) return result.errorCode;
    if (result.isUnsupported) return null;
    return asJsonScalarText(result.value);
  }

  /// 数字值（供图表取值）：非数字 → `null`。
  num? numberAt(int row, int col) {
    final result = resolveCell(row, col);
    if (!result.hasValue) return null;
    final value = result.value;
    if (value is num) return value;
    if (value is bool) return value ? 1 : 0;
    if (value is String) return num.tryParse(value.trim());
    return null;
  }
}
