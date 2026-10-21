/// A `package:http` client that checks every request and response against
/// an OpenAPI spec using `package:api_validator`.
///
/// ```dart
/// final checker = ApiValidator(OpenApiSpec.fromString(specYaml));
/// final client = ApiValidatorClient(checker, inner: MockClient(handler));
/// ```
library;

export 'package:api_validator/api_validator.dart';

export 'src/api_validator_client.dart' show ApiValidatorClient;
