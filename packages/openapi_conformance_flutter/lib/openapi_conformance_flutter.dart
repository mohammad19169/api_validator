/// A debug overlay for Flutter apps that lists API calls and shows which
/// ones break your OpenAPI spec, field by field.
///
/// Wrap your app with [ConformanceInspector] (or pass
/// [ConformanceInspector.builder] to `MaterialApp.builder`) and feed the
/// same [ConformanceChecker] to an adapter such as `openapi_conformance_dio`
/// or `openapi_conformance_http`.
///
/// This library also re-exports `package:openapi_conformance`, so a single
/// import is enough.
library;

export 'package:openapi_conformance/openapi_conformance.dart';

export 'src/conformance_inspector.dart' show ConformanceInspector;
export 'src/inspector_model.dart' show exchangeReport, formatBody;
