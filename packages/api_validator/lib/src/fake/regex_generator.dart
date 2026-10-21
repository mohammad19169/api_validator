import 'dart:math';

/// Generates strings that match simple regular expressions.
///
/// Supports literals, escapes (`\d \w \s \D \W \S` and escaped
/// punctuation), `.`, character classes with ranges and negation, groups
/// (capturing and `(?:...)`), alternation, anchors and the quantifiers
/// `* + ? {n} {n,} {n,m}` (lazy forms too). Back-references and lookaround
/// are not supported; [generate] returns `null` for them.
final class RegexGenerator {
  /// Creates a generator that draws from [random].
  RegexGenerator(this.random);

  /// Source of randomness.
  final Random random;

  /// A string matching [pattern], or `null` when the pattern uses
  /// unsupported syntax or the result does not verify.
  String? generate(String pattern, {int? minLength, int? maxLength}) {
    final _Node node;
    try {
      node = _Parser(pattern).parse();
    } on _Unsupported {
      return null;
    }
    RegExp regExp;
    try {
      regExp = RegExp(pattern, unicode: true);
    } on FormatException {
      return null;
    }
    String? fallback;
    for (var attempt = 0; attempt < 25; attempt++) {
      final buffer = StringBuffer();
      node.emit(buffer, random);
      final value = buffer.toString();
      if (!regExp.hasMatch(value)) continue;
      fallback ??= value;
      final length = value.runes.length;
      if (minLength != null && length < minLength) continue;
      if (maxLength != null && length > maxLength) continue;
      return value;
    }
    return fallback;
  }
}

final class _Unsupported implements Exception {
  const _Unsupported();
}

abstract class _Node {
  void emit(StringBuffer out, Random random);
}

final class _Literal extends _Node {
  _Literal(this.text);

  final String text;

  @override
  void emit(StringBuffer out, Random random) => out.write(text);
}

final class _CharSet extends _Node {
  _CharSet(this.chars);

  final List<int> chars;

  @override
  void emit(StringBuffer out, Random random) {
    if (chars.isEmpty) throw const _Unsupported();
    out.writeCharCode(chars[random.nextInt(chars.length)]);
  }
}

final class _Sequence extends _Node {
  _Sequence(this.items);

  final List<_Node> items;

  @override
  void emit(StringBuffer out, Random random) {
    for (final item in items) {
      item.emit(out, random);
    }
  }
}

final class _Alternation extends _Node {
  _Alternation(this.options);

  final List<_Node> options;

  @override
  void emit(StringBuffer out, Random random) =>
      options[random.nextInt(options.length)].emit(out, random);
}

final class _Repeat extends _Node {
  _Repeat(this.node, this.min, this.max);

  final _Node node;
  final int min;
  final int max;

  @override
  void emit(StringBuffer out, Random random) {
    final count = min + random.nextInt(max - min + 1);
    for (var i = 0; i < count; i++) {
      node.emit(out, random);
    }
  }
}

final List<int> _digits = [for (var c = 0x30; c <= 0x39; c++) c];
final List<int> _lower = [for (var c = 0x61; c <= 0x7a; c++) c];
final List<int> _upper = [for (var c = 0x41; c <= 0x5a; c++) c];
final List<int> _word = [..._digits, ..._lower, ..._upper, 0x5f];
final List<int> _space = [0x20];
final List<int> _printable = [for (var c = 0x20; c <= 0x7e; c++) c];
final List<int> _safe = [..._lower, ..._digits];

final class _Parser {
  _Parser(this.source);

  final String source;
  int _index = 0;

  bool get _done => _index >= source.length;

  String get _peek => source[_index];

  _Node parse() {
    final node = _alternation();
    if (!_done) throw const _Unsupported();
    return node;
  }

  _Node _alternation() {
    final options = <_Node>[_sequence()];
    while (!_done && _peek == '|') {
      _index++;
      options.add(_sequence());
    }
    return options.length == 1 ? options.single : _Alternation(options);
  }

  _Node _sequence() {
    final items = <_Node>[];
    while (!_done && _peek != '|' && _peek != ')') {
      final atom = _atom();
      if (atom == null) continue;
      items.add(_quantified(atom));
    }
    return _Sequence(items);
  }

  _Node? _atom() {
    final char = _peek;
    _index++;
    switch (char) {
      case '^' || r'$':
        return null;
      case '.':
        return _CharSet(_safe);
      case '(':
        if (!_done && _peek == '?') {
          if (_index + 1 < source.length && source[_index + 1] == ':') {
            _index += 2;
          } else {
            throw const _Unsupported();
          }
        }
        final inner = _alternation();
        if (_done || _peek != ')') throw const _Unsupported();
        _index++;
        return inner;
      case '[':
        return _CharSet(_charClass());
      case r'\':
        return _escape(inClass: false);
      case '*' || '+' || '?' || '{' || ')':
        throw const _Unsupported();
      default:
        return _Literal(char);
    }
  }

  _Node _escape({required bool inClass}) {
    if (_done) throw const _Unsupported();
    final char = _peek;
    _index++;
    switch (char) {
      case 'd':
        return _CharSet(_digits);
      case 'w':
        return _CharSet(_word);
      case 's':
        return _CharSet(_space);
      case 'D':
        return _CharSet(_lower);
      case 'W':
        return _CharSet(const [0x2d]);
      case 'S':
        return _CharSet(_lower);
      case 'b' || 'B':
        if (inClass) return _Literal('\b');
        return _Sequence(const []);
      case 'n':
        return _Literal('\n');
      case 't':
        return _Literal('\t');
      case 'u':
        if (_index + 4 <= source.length) {
          final code = int.tryParse(
            source.substring(_index, _index + 4),
            radix: 16,
          );
          if (code != null) {
            _index += 4;
            return _Literal(String.fromCharCode(code));
          }
        }
        throw const _Unsupported();
      default:
        if (RegExp(r'[0-9]').hasMatch(char)) throw const _Unsupported();
        if (RegExp(r'[A-Za-z]').hasMatch(char)) throw const _Unsupported();
        return _Literal(char);
    }
  }

  List<int> _charClass() {
    var negated = false;
    if (!_done && _peek == '^') {
      negated = true;
      _index++;
    }
    final chars = <int>{};
    var first = true;
    while (!_done && (_peek != ']' || first)) {
      first = false;
      int? start;
      if (_peek == r'\') {
        _index++;
        final escaped = _escape(inClass: true);
        if (escaped is _CharSet) {
          chars.addAll(escaped.chars);
          continue;
        }
        start = (escaped as _Literal).text.codeUnitAt(0);
      } else {
        start = _peek.codeUnitAt(0);
        _index++;
      }
      if (_index + 1 < source.length &&
          _peek == '-' &&
          source[_index + 1] != ']') {
        _index++;
        int end;
        if (_peek == r'\') {
          _index++;
          final escaped = _escape(inClass: true);
          if (escaped is! _Literal) throw const _Unsupported();
          end = escaped.text.codeUnitAt(0);
        } else {
          end = _peek.codeUnitAt(0);
          _index++;
        }
        if (end < start) throw const _Unsupported();
        for (var c = start; c <= end && c - start < 5000; c++) {
          chars.add(c);
        }
      } else {
        chars.add(start);
      }
    }
    if (_done) throw const _Unsupported();
    _index++;
    if (!negated) return chars.toList()..sort();
    return [
      for (final c in _printable)
        if (!chars.contains(c)) c,
    ];
  }

  _Node _quantified(_Node atom) {
    if (_done) return atom;
    int min;
    int max;
    switch (_peek) {
      case '*':
        _index++;
        min = 0;
        max = 3;
      case '+':
        _index++;
        min = 1;
        max = 3;
      case '?':
        _index++;
        min = 0;
        max = 1;
      case '{':
        final match = RegExp(
          r'\{(\d+)(,(\d*))?\}',
        ).matchAsPrefix(source, _index);
        if (match == null) return atom;
        _index = match.end;
        min = int.parse(match[1]!);
        if (match[2] == null) {
          max = min;
        } else if (match[3]!.isEmpty) {
          max = min + 2;
        } else {
          max = int.parse(match[3]!);
        }
        if (max < min) throw const _Unsupported();
      default:
        return atom;
    }
    if (!_done && (_peek == '?' || _peek == '+')) _index++;
    return _Repeat(atom, min, max);
  }
}
