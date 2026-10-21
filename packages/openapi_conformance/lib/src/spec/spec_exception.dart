/// Thrown when an OpenAPI document cannot be loaded or is structurally invalid.
final class OpenApiSpecException implements Exception {
  /// Creates an exception with a human readable [message].
  const OpenApiSpecException(this.message, {this.pointer});

  /// Description of what went wrong.
  final String message;

  /// JSON pointer (for example `#/paths/~1users/get`) of the offending node,
  /// when known.
  final String? pointer;

  @override
  String toString() => pointer == null
      ? 'OpenApiSpecException: $message'
      : 'OpenApiSpecException: $message (at $pointer)';
}
