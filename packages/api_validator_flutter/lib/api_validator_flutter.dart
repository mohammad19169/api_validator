/// A debug overlay for Flutter apps that lists API calls and shows which
/// ones break your OpenAPI spec, field by field.
///
/// Wrap your app with [ApiValidatorInspector] (or pass
/// [ApiValidatorInspector.builder] to `MaterialApp.builder`) and feed the
/// same [ApiValidator] to an adapter such as `api_validator_dio`
/// or `api_validator_http`.
///
/// This library also re-exports `package:api_validator`, so a single
/// import is enough.
library;

export 'package:api_validator/api_validator.dart';

export 'src/api_validator_inspector.dart' show ApiValidatorInspector;
export 'src/inspector_model.dart' show exchangeReport, formatBody;
