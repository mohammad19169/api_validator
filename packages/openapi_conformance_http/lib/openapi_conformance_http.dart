/// A `package:http` client that checks every request and response against
/// an OpenAPI spec using `package:openapi_conformance`.
///
/// ```dart
/// final checker = ConformanceChecker(OpenApiSpec.fromString(specYaml));
/// final client = ConformanceClient(checker, inner: MockClient(handler));
/// ```
library;

export 'package:openapi_conformance/openapi_conformance.dart';

export 'src/conformance_client.dart' show ConformanceClient;
