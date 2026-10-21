import 'package:meta/meta.dart';

/// A request as seen by the conformance checker.
///
/// Adapters (dio, http, ...) convert their own request type into this one.
///
/// [body] may be `null` (no body), a `String`, a `Uint8List` of UTF-8 bytes,
/// or an already decoded JSON value (`Map`, `List`, `num`, `bool`). Strings
/// and bytes are decoded as JSON when the content type is JSON.
@immutable
final class ExchangeRequest {
  /// Creates a request. Header names are matched case-insensitively.
  ExchangeRequest({
    required String method,
    required this.uri,
    Map<String, String> headers = const {},
    this.body,
    this.bodyCaptured = true,
  }) : method = method.toUpperCase(),
       headers = _lowerCaseKeys(headers);

  /// Upper-case HTTP method.
  final String method;

  /// The full request URL, including the query string.
  final Uri uri;

  /// Request headers with lower-case names. Repeated headers are joined
  /// with `, `.
  final Map<String, String> headers;

  /// The request body, see [ExchangeRequest].
  final Object? body;

  /// Whether [body] reflects what was sent. Adapters set this to `false`
  /// for bodies they cannot read (streams), which skips body validation.
  final bool bodyCaptured;

  /// The value of [name], case-insensitive.
  String? header(String name) => headers[name.toLowerCase()];

  /// The `Content-Type` header, if any.
  String? get contentType => header('content-type');

  @override
  String toString() => '$method $uri';
}

/// A response as seen by the conformance checker.
///
/// See [ExchangeRequest] for the accepted [body] representations.
@immutable
final class ExchangeResponse {
  /// Creates a response. Header names are matched case-insensitively.
  ExchangeResponse({
    required this.statusCode,
    Map<String, String> headers = const {},
    this.body,
    this.bodyCaptured = true,
  }) : headers = _lowerCaseKeys(headers);

  /// The HTTP status code.
  final int statusCode;

  /// Response headers with lower-case names.
  final Map<String, String> headers;

  /// The response body.
  final Object? body;

  /// Whether [body] reflects what was received. Adapters set this to
  /// `false` for bodies they cannot read (streams, server-sent events),
  /// which skips body validation.
  final bool bodyCaptured;

  /// The value of [name], case-insensitive.
  String? header(String name) => headers[name.toLowerCase()];

  /// The `Content-Type` header, if any.
  String? get contentType => header('content-type');

  @override
  String toString() => '$statusCode';
}

/// A request and, when one was received, its response.
@immutable
final class Exchange {
  /// Creates an exchange.
  const Exchange({required this.request, this.response});

  /// The request that was sent.
  final ExchangeRequest request;

  /// The response, or `null` when the request failed before one arrived.
  final ExchangeResponse? response;

  @override
  String toString() =>
      response == null ? '$request' : '$request -> ${response!.statusCode}';
}

Map<String, String> _lowerCaseKeys(Map<String, String> headers) {
  if (headers.isEmpty) return const {};
  final result = <String, String>{};
  for (final MapEntry(:key, :value) in headers.entries) {
    final name = key.toLowerCase();
    final existing = result[name];
    result[name] = existing == null ? value : '$existing, $value';
  }
  return Map.unmodifiable(result);
}
