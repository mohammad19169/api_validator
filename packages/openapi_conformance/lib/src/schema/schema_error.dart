import 'package:meta/meta.dart';

/// A single reason why a value does not match a schema.
@immutable
final class SchemaError {
  /// Creates a schema error.
  const SchemaError({
    required this.path,
    required this.keyword,
    required this.message,
    this.expected,
    this.actual,
    this.isUndeclaredProperty = false,
    this.causes = const [],
  });

  /// JSON path of the offending value, for example `$.address.zip`.
  final String path;

  /// The schema keyword that failed, for example `type` or `required`.
  final String keyword;

  /// Human readable description of the failure.
  final String message;

  /// What the schema expected, when it can be expressed as a value.
  final Object? expected;

  /// The value that was found, when relevant.
  final Object? actual;

  /// Whether this error reports a property the schema does not declare.
  ///
  /// Such errors only appear when undeclared property checks are enabled,
  /// and are reported with a lower severity in lenient mode.
  final bool isUndeclaredProperty;

  /// For `oneOf`/`anyOf` failures, the errors of the closest alternative.
  final List<SchemaError> causes;

  @override
  String toString() => '$path: $message';
}

/// Builds JSON path strings such as `$.items[0]['odd key']`.
abstract final class JsonPath {
  /// The root path.
  static const root = r'$';

  static final _identifier = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');

  /// Appends a property name to [path].
  static String property(String path, String name) => _identifier.hasMatch(name)
      ? '$path.$name'
      : "$path['${name.replaceAll("'", r"\'")}']";

  /// Appends an array index to [path].
  static String index(String path, int index) => '$path[$index]';
}
