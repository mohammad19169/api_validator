import 'package:api_validator_flutter/api_validator_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

const _spec = r'''
openapi: 3.0.3
info: {title: Demo, version: '1'}
paths:
  /users/{id}:
    get:
      parameters:
        - {name: id, in: path, required: true, schema: {type: integer}}
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                type: object
                required: [id, name]
                properties:
                  id: {type: integer}
                  name: {type: string}
                  email: {type: string, format: email}
''';

/// In a real app you would install `ApiValidatorInterceptor` (dio) or
/// `ApiValidatorClient` (http) with this checker instead of calling
/// `check` by hand.
final checker = ApiValidator(
  OpenApiSpec.fromString(_spec),
  options: const ValidatorOptions.runtime(),
)..enabled = kDebugMode;

void main() => runApp(const DemoApp());

/// A tiny app that records fake API calls and shows the inspector.
class DemoApp extends StatelessWidget {
  /// Creates the demo app.
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'API validator demo',
      builder: ApiValidatorInspector.builder(checker),
      home: const DemoPage(),
    );
  }
}

/// Buttons that simulate a good and a bad API response.
class DemoPage extends StatelessWidget {
  /// Creates the page.
  const DemoPage({super.key});

  void _call(Object body) {
    checker.check(
      Exchange(
        request: ExchangeRequest(
          method: 'GET',
          uri: Uri.parse('https://api.example.com/users/42'),
        ),
        response: ExchangeResponse(
          statusCode: 200,
          headers: const {'content-type': 'application/json'},
          body: body,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Inspector demo')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(
              onPressed: () => _call({'id': 42, 'name': 'Ada'}),
              child: const Text('Matching response'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => _call({'id': '42', 'email': 'not-an-email'}),
              child: const Text('Broken response'),
            ),
            const SizedBox(height: 24),
            const Text('Tap the badge in the corner to inspect calls.'),
          ],
        ),
      ),
    );
  }
}
