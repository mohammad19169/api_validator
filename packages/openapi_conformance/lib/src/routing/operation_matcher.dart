import 'package:meta/meta.dart';

import '../spec/openapi_spec.dart';
import '../spec/operation.dart';

/// The outcome of routing a request to an operation.
sealed class RouteResult {
  const RouteResult();
}

/// The request matched [operation].
@immutable
final class RouteMatched extends RouteResult {
  /// Creates a match.
  const RouteMatched(this.operation, this.pathParameters);

  /// The matched operation.
  final ApiOperation operation;

  /// Values of the templated path segments, percent-decoded.
  final Map<String, String> pathParameters;
}

/// A path template matched but not for the request method.
@immutable
final class RouteMethodNotAllowed extends RouteResult {
  /// Creates a method mismatch result.
  const RouteMethodNotAllowed(this.path, this.allowedMethods);

  /// The matched path template.
  final String path;

  /// Methods declared for [path].
  final List<String> allowedMethods;
}

/// No path template matched the request.
final class RouteNotFound extends RouteResult {
  /// Creates a not-found result.
  const RouteNotFound();
}

/// Maps request methods and URLs to [ApiOperation]s of a spec.
///
/// Server base paths are stripped first. When several templates match,
/// the one with the most literal segments wins, so `/users/me` beats
/// `/users/{id}`.
final class OperationMatcher {
  /// Compiles the path templates of [spec].
  OperationMatcher(this.spec) {
    final byPath = <String, List<ApiOperation>>{};
    for (final operation in spec.operations) {
      byPath.putIfAbsent(operation.path, () => []).add(operation);
    }
    _templates = [
      for (final MapEntry(:key, :value) in byPath.entries)
        _Template(key, value),
    ]..sort((a, b) => b.compareTo(a));
  }

  /// The spec whose operations are matched.
  final OpenApiSpec spec;

  late final List<_Template> _templates;

  /// Routes [method] and [uri] to an operation.
  RouteResult match(String method, Uri uri) {
    final upper = method.toUpperCase();
    RouteMethodNotAllowed? methodMismatch;
    for (final path in _candidatePaths(uri.path)) {
      final segments = _segments(path);
      for (final template in _templates) {
        final parameters = template.match(segments);
        if (parameters == null) continue;
        for (final operation in template.operations) {
          if (operation.method == upper) {
            return RouteMatched(operation, parameters);
          }
        }
        methodMismatch ??= RouteMethodNotAllowed(template.path, [
          for (final operation in template.operations) operation.method,
        ]);
      }
    }
    return methodMismatch ?? const RouteNotFound();
  }

  Iterable<String> _candidatePaths(String rawPath) sync* {
    final path = rawPath.isEmpty ? '/' : rawPath;
    var yieldedRaw = false;
    for (final base in spec.basePaths) {
      if (base.isEmpty) {
        yieldedRaw = true;
        yield path;
      } else if (path == base) {
        yield '/';
      } else if (path.startsWith('$base/')) {
        yield path.substring(base.length);
      }
    }
    if (!yieldedRaw) yield path;
  }
}

List<String> _segments(String path) {
  final parts = path.split('/').where((part) => part.isNotEmpty).toList();
  return parts;
}

final class _Template implements Comparable<_Template> {
  _Template(this.path, this.operations) {
    final segments = _segments(path);
    for (final segment in segments) {
      if (!segment.contains('{')) {
        _literals++;
        _matchers.add(_SegmentMatcher.literal(segment));
        continue;
      }
      final names = <String>[];
      final pattern = StringBuffer('^');
      var index = 0;
      for (final match in RegExp(r'\{([^}]+)\}').allMatches(segment)) {
        pattern.write(RegExp.escape(segment.substring(index, match.start)));
        pattern.write('([^/]+?)');
        names.add(match[1]!);
        index = match.end;
      }
      pattern
        ..write(RegExp.escape(segment.substring(index)))
        ..write(r'$');
      _matchers.add(_SegmentMatcher.pattern(RegExp(pattern.toString()), names));
    }
  }

  final String path;
  final List<ApiOperation> operations;
  final List<_SegmentMatcher> _matchers = [];
  int _literals = 0;

  Map<String, String>? match(List<String> segments) {
    if (segments.length != _matchers.length) return null;
    final parameters = <String, String>{};
    for (var i = 0; i < segments.length; i++) {
      if (!_matchers[i].match(segments[i], parameters)) return null;
    }
    return parameters;
  }

  @override
  int compareTo(_Template other) {
    final byLiterals = _literals.compareTo(other._literals);
    if (byLiterals != 0) return byLiterals;
    return other._matchers.length.compareTo(_matchers.length);
  }
}

final class _SegmentMatcher {
  _SegmentMatcher.literal(this.literal) : regExp = null, names = const [];

  _SegmentMatcher.pattern(RegExp this.regExp, this.names) : literal = null;

  final String? literal;
  final RegExp? regExp;
  final List<String> names;

  bool match(String segment, Map<String, String> parameters) {
    if (literal != null) {
      return _decode(segment) == _decode(literal!);
    }
    final match = regExp!.firstMatch(segment);
    if (match == null) return false;
    for (var i = 0; i < names.length; i++) {
      parameters[names[i]] = _decode(match[i + 1]!);
    }
    return true;
  }
}

String _decode(String value) {
  try {
    return Uri.decodeComponent(value);
  } on ArgumentError {
    return value;
  }
}
