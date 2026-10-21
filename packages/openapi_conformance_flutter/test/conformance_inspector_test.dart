import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openapi_conformance_flutter/openapi_conformance_flutter.dart';

const _spec = r'''
openapi: 3.0.3
info: {title: Test, version: '1'}
paths:
  /users/{id}:
    get:
      operationId: getUser
      parameters:
        - {name: id, in: path, required: true, schema: {type: integer}}
      responses:
        '200':
          description: ok
          content:
            application/json:
              schema:
                type: object
                required: [id, email]
                properties:
                  id: {type: integer}
                  email: {type: string, format: email}
  /orders:
    get:
      operationId: listOrders
      deprecated: true
      responses:
        '200': {description: ok}
''';

Exchange _user(Object body, {int id = 1}) => Exchange(
  request: ExchangeRequest(
    method: 'GET',
    uri: Uri.parse('https://api.test/users/$id'),
  ),
  response: ExchangeResponse(
    statusCode: 200,
    headers: const {'content-type': 'application/json'},
    body: body,
  ),
);

Exchange _orders() => Exchange(
  request: ExchangeRequest(
    method: 'GET',
    uri: Uri.parse('https://api.test/orders'),
  ),
  response: ExchangeResponse(statusCode: 200),
);

void main() {
  late ConformanceChecker checker;

  setUp(() => checker = ConformanceChecker(OpenApiSpec.fromString(_spec)));

  Widget app({bool enabled = true, ConformanceChecker? with_}) => MaterialApp(
    home: ConformanceInspector(
      checker: with_ ?? checker,
      enabled: enabled,
      child: const Scaffold(body: Text('home')),
    ),
  );

  Future<void> record(WidgetTester tester, Exchange exchange) async {
    checker.check(exchange);
    await tester.pump();
    await tester.pump();
  }

  String badgeLabel(WidgetTester tester) {
    final semantics = tester.widget<Semantics>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('conformance-badge')),
            matching: find.byType(Semantics),
          )
          .first,
    );
    return semantics.properties.label!;
  }

  testWidgets('disabled returns the child only', (tester) async {
    await tester.pumpWidget(app(enabled: false));
    expect(find.text('home'), findsOneWidget);
    expect(find.byKey(const ValueKey('conformance-badge')), findsNothing);
    final inspector = tester.element(find.byType(ConformanceInspector));
    Widget? direct;
    inspector.visitChildren((child) => direct = child.widget);
    expect(direct, isA<Scaffold>());
  });

  testWidgets('badge counts follow new results', (tester) async {
    checker.check(_user({'id': 1, 'email': 'a@b.co'}));
    await tester.pumpWidget(app());
    expect(badgeLabel(tester), contains('0 with errors'));
    expect(badgeLabel(tester), contains('1 conforming'));

    await record(tester, _user({'id': 2, 'email': 'nope'}));
    await record(tester, _orders());
    expect(badgeLabel(tester), contains('1 with errors'));
    expect(badgeLabel(tester), contains('1 with warnings'));
    expect(badgeLabel(tester), contains('1 conforming'));
  });

  testWidgets('showWhenConforming false hides a clean badge', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ConformanceInspector(
          checker: checker,
          enabled: true,
          showWhenConforming: false,
          child: const SizedBox(),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('conformance-badge')), findsNothing);
    await record(tester, _user({'id': 2}));
    expect(find.byKey(const ValueKey('conformance-badge')), findsOneWidget);
  });

  testWidgets('panel lists, filters, searches and shows details', (
    tester,
  ) async {
    checker
      ..check(_user({'id': 1, 'email': 'a@b.co'}))
      ..check(_user({'id': 2, 'email': 'not-an-email'}, id: 2))
      ..check(_orders());
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('conformance-badge')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('conformance-panel')), findsOneWidget);
    expect(find.text('All (3)'), findsOneWidget);
    expect(find.byType(ListTile), findsNWidgets(3));
    expect(find.text('GET /orders'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('conformance-filter-errors')));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('conformance-filter-warnings')));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);
    expect(find.text('GET /orders'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('conformance-filter-all')));
    await tester.enterText(
      find.byKey(const ValueKey('conformance-search')),
      'users',
    );
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(2));

    await tester.tap(find.textContaining('1 issue'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('conformance-detail')), findsOneWidget);
    expect(find.text(r'$.email'), findsOneWidget);
    expect(find.textContaining('expected format "email"'), findsOneWidget);
    expect(find.textContaining('"not-an-email"'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('conformance-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('conformance-list')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('conformance-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('conformance-panel')), findsNothing);
    expect(find.byKey(const ValueKey('conformance-badge')), findsOneWidget);
  });

  testWidgets('copy report puts the exchange on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    checker.check(_user({'id': 2, 'email': 'bad'}));
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('conformance-badge')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('conformance-copy')));
    await tester.pumpAndSettle();
    expect(find.text('Copied'), findsOneWidget);
    expect(copied, contains('GET https://api.test/users/1 -> 200'));
    expect(copied, contains(r'$.email'));
    expect(copied, contains('Response body:'));
  });

  testWidgets('clear empties the list', (tester) async {
    checker.check(_user({'id': 1, 'email': 'a@b.co'}));
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('conformance-badge')));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('conformance-clear')));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNothing);
    expect(find.text('No API calls recorded yet'), findsOneWidget);
    expect(checker.results, isEmpty);
  });

  testWidgets('works from MaterialApp.builder without a Navigator above', (
    tester,
  ) async {
    checker.check(_user({'id': 1}));
    await tester.pumpWidget(
      MaterialApp(
        builder: ConformanceInspector.builder(checker, enabled: true),
        home: const Scaffold(body: Text('home')),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('conformance-badge')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('conformance-search')),
      'user',
    );
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);
    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();
    expect(find.textContaining('required property "email"'), findsOneWidget);
  });

  testWidgets('badge can be dragged and snaps to an edge', (tester) async {
    await tester.pumpWidget(app());
    final badge = find.byKey(const ValueKey('conformance-badge'));
    final before = tester.getTopLeft(badge);
    await tester.drag(badge, const Offset(-600, -200));
    await tester.pumpAndSettle();
    final after = tester.getTopLeft(badge);
    expect(after.dx, 8);
    expect(after.dy, lessThan(before.dy));
  });

  testWidgets('switching checkers and disposing stop listening', (
    tester,
  ) async {
    final other = ConformanceChecker(OpenApiSpec.fromString(_spec));
    await tester.pumpWidget(app());
    await tester.pumpWidget(app(with_: other));
    await record(tester, _user({'id': 1}));
    expect(badgeLabel(tester), contains('0 with errors'));
    other.check(_user({'id': 1}));
    await tester.pump();
    await tester.pump();
    expect(badgeLabel(tester), contains('1 with errors'));

    await tester.tap(find.byKey(const ValueKey('conformance-badge')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    other.check(_user({'id': 1}));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('toggling enabled creates and drops the overlay', (tester) async {
    await tester.pumpWidget(app(enabled: false));
    expect(find.byKey(const ValueKey('conformance-badge')), findsNothing);
    await tester.pumpWidget(app());
    expect(find.byKey(const ValueKey('conformance-badge')), findsOneWidget);
    await tester.pumpWidget(app(enabled: false));
    expect(find.byKey(const ValueKey('conformance-badge')), findsNothing);
  });

  test('formatBody pretty prints JSON and handles empty bodies', () {
    expect(formatBody(null), isNull);
    expect(formatBody('  '), isNull);
    expect(formatBody('{"a":1}'), '{\n  "a": 1\n}');
    expect(formatBody({'b': true}), '{\n  "b": true\n}');
    expect(formatBody('plain'), 'plain');
  });

  test('exchangeReport describes violations', () {
    final result = checker.check(_user({'id': 'x'}));
    final report = exchangeReport(result);
    expect(report, contains('Operation: GET /users/{id} (getUser)'));
    expect(report, contains('Response: 200 (declared as 200)'));
    expect(report, contains(r'$.id'));
  });
}
