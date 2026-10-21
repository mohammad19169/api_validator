import 'dart:typed_data';

import 'package:http/http.dart';
import 'package:openapi_conformance/openapi_conformance.dart';

/// An HTTP [Client] that reports every exchange to a [ConformanceChecker].
///
/// Wrap your real client, or a `MockClient` in tests:
///
/// ```dart
/// final client = ConformanceClient(
///   checker,
///   inner: MockClient((request) async => Response('{"id": 1}', 200)),
/// );
/// ```
///
/// Response bodies are buffered so they can be checked, then handed to the
/// caller unchanged. Server-sent event streams (`text/event-stream`) are
/// passed through without buffering; only their status and headers are
/// checked.
class ConformanceClient extends BaseClient {
  /// Creates a client reporting to [checker].
  ///
  /// [inner] performs the requests and defaults to a new [Client]. When
  /// [throwOnViolation] is `true`, a [ConformanceException] is thrown for
  /// exchanges with errors (after they have been recorded). Requests for
  /// which [skip] returns `true` are sent without being checked.
  ConformanceClient(
    this.checker, {
    Client? inner,
    this.throwOnViolation = false,
    this.skip,
  }) : inner = inner ?? Client();

  /// The checker exchanges are reported to.
  final ConformanceChecker checker;

  /// The client that actually sends requests.
  final Client inner;

  /// Whether non-conforming exchanges throw a [ConformanceException].
  final bool throwOnViolation;

  /// Returns `true` for requests that should not be checked.
  final bool Function(BaseRequest request)? skip;

  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    if (!checker.enabled || (skip?.call(request) ?? false)) {
      return inner.send(request);
    }
    final exchangeRequest = ExchangeRequest(
      method: request.method,
      uri: request.url,
      headers: request.headers,
      body: _requestBody(request),
      bodyCaptured: request is Request || request is MultipartRequest,
    );
    final StreamedResponse response;
    try {
      response = await inner.send(request);
    } catch (_) {
      checker.check(Exchange(request: exchangeRequest));
      rethrow;
    }

    final contentType = response.headers.entries
        .where((entry) => entry.key.toLowerCase() == 'content-type')
        .map((entry) => entry.value)
        .firstOrNull;
    if (contentType != null &&
        MediaTypes.essence(contentType) == 'text/event-stream') {
      _report(
        Exchange(
          request: exchangeRequest,
          response: ExchangeResponse(
            statusCode: response.statusCode,
            headers: response.headers,
            bodyCaptured: false,
          ),
        ),
      );
      return response;
    }

    final bytes = await response.stream.toBytes();
    _report(
      Exchange(
        request: exchangeRequest,
        response: ExchangeResponse(
          statusCode: response.statusCode,
          headers: response.headers,
          body: bytes,
        ),
      ),
    );
    return StreamedResponse(
      Stream<List<int>>.value(bytes),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  void _report(Exchange exchange) {
    final result = checker.check(exchange);
    if (throwOnViolation && !result.isConforming) {
      throw ConformanceException(result.errors);
    }
  }

  @override
  void close() => inner.close();
}

Object? _requestBody(BaseRequest request) => switch (request) {
  final Request plain =>
    plain.bodyBytes.isEmpty ? null : Uint8List.fromList(plain.bodyBytes),
  final MultipartRequest multipart => <String, Object?>{
    ...multipart.fields,
    for (final file in multipart.files) file.field: file.filename ?? 'file',
  },
  _ => null,
};
