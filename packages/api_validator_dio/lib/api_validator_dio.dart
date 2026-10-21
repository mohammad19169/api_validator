/// A dio interceptor that checks every request and response against an
/// OpenAPI spec using `package:api_validator`.
///
/// ```dart
/// final checker = ApiValidator(OpenApiSpec.fromString(specYaml));
/// final dio = Dio()..addApiValidator(checker);
/// ```
library;

export 'package:api_validator/api_validator.dart';

export 'src/api_validator_interceptor.dart'
    show ApiValidatorDio, ApiValidatorInterceptor, exchangeFromDio;
