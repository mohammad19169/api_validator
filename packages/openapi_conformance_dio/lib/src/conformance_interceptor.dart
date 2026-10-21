import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:openapi_conformance/openapi_conformance.dart';

/// A dio [Interceptor] that sends every exchange to a [ConformanceChecker].
///
/// Responses produced by mock adapters (any custom `HttpClientAdapter`)
/// pass through interceptors too, so stubbed responses are checked like
/// real ones.
///
/// ```dart
/// final dio = Dio()
///   ..httpClientAdapter = myMockAdapter
///   ..interceptors.add(ConformanceInterceptor(checker));
/// ```
///
/// Add it after interceptors that change the request (auth headers, base
/// URL rewriting) so the checker sees the request as it is actually sent.
class ConformanceInterceptor extends Interceptor {
  /// Creates an interceptor reporting to [checker].
  ///
  /// When [throwOnViolation] is `true`, exchanges with errors are turned
  /// into a [DioException] whose [DioException.error] is a
  /// [ConformanceException]. By default violations are only recorded, so
  /// application error handling cannot swallow them; inspect the checker
  /// (or use `openapi_conformance_test`) to fail tests instead.
  ConformanceInterceptor(this.checker, {this.throwOnViolation = false});

  /// The checker exchanges are reported to.
  final ConformanceChecker checker;

  /// Whether non-conforming exchanges fail the request.
  final bool throwOnViolation;

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final result = checker.check(
      exchangeFromDio(response.requestOptions, response),
    );
    if (throwOnViolation && !result.isConforming) {
      handler.reject(
        DioException(
          requestOptions: response.requestOptions,
          response: response,
          error: ConformanceException(result.errors),
          message: 'The exchange does not conform to the OpenAPI spec',
        ),
        true,
      );
      return;
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.error is ConformanceException) {
      handler.next(err);
      return;
    }
    final result = checker.check(
      exchangeFromDio(err.requestOptions, err.response),
    );
    if (throwOnViolation && !result.isConforming) {
      handler.next(
        err.copyWith(
          error: ConformanceException(result.errors),
          message:
              'The exchange does not conform to the OpenAPI spec '
              '(original error: ${err.message ?? err.type.name})',
        ),
      );
      return;
    }
    handler.next(err);
  }
}

/// Converts a dio request and optional response into an [Exchange].
///
/// Useful when you want to check traffic captured some other way, for
/// example from a custom logging interceptor.
Exchange exchangeFromDio(
  RequestOptions options, [
  Response<dynamic>? response,
]) {
  final headers = <String, String>{};
  options.headers.forEach((name, value) {
    if (value == null) return;
    headers[name] = value is Iterable ? value.join(', ') : '$value';
  });
  final contentType = options.contentType;
  if (contentType != null &&
      !headers.keys.any((name) => name.toLowerCase() == 'content-type')) {
    headers['content-type'] = contentType;
  }
  final request = ExchangeRequest(
    method: options.method,
    uri: options.uri,
    headers: headers,
    body: _requestBody(options.data),
    bodyCaptured: options.data is! Stream<Object?>,
  );
  if (response == null || response.statusCode == null) {
    return Exchange(request: request);
  }
  return Exchange(
    request: request,
    response: ExchangeResponse(
      statusCode: response.statusCode!,
      headers: {
        for (final MapEntry(:key, :value) in response.headers.map.entries)
          key: value.join(', '),
      },
      body: _responseBody(response.data),
      bodyCaptured:
          response.data is! ResponseBody && response.data is! Stream<Object?>,
    ),
  );
}

Object? _requestBody(Object? data) => switch (data) {
  null => null,
  final FormData form => <String, Object?>{
    for (final field in form.fields) field.key: field.value,
    for (final file in form.files) file.key: file.value.filename ?? 'file',
  },
  final Uint8List bytes => bytes,
  final List<int> bytes => Uint8List.fromList(bytes),
  Stream<Object?>() => null,
  _ => data,
};

Object? _responseBody(Object? data) => switch (data) {
  null => null,
  final Uint8List bytes => bytes,
  final List<int> bytes => Uint8List.fromList(bytes),
  ResponseBody() || Stream<Object?>() => null,
  _ => data,
};

/// Adds conformance checking to a [Dio] instance.
extension ConformanceDio on Dio {
  /// Appends a [ConformanceInterceptor] reporting to [checker] and returns
  /// this instance.
  Dio addConformance(
    ConformanceChecker checker, {
    bool throwOnViolation = false,
  }) {
    interceptors.add(
      ConformanceInterceptor(checker, throwOnViolation: throwOnViolation),
    );
    return this;
  }
}
