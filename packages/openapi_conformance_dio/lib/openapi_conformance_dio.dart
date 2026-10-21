/// A dio interceptor that checks every request and response against an
/// OpenAPI spec using `package:openapi_conformance`.
///
/// ```dart
/// final checker = ConformanceChecker(OpenApiSpec.fromString(specYaml));
/// final dio = Dio()..addConformance(checker);
/// ```
library;

export 'package:openapi_conformance/openapi_conformance.dart';

export 'src/conformance_interceptor.dart'
    show ConformanceDio, ConformanceInterceptor, exchangeFromDio;
