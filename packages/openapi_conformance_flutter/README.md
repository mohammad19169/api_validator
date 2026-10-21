# openapi_conformance_flutter

A debug overlay for Flutter apps that shows every API call your app makes and
whether it matches your OpenAPI spec.

You use the app as usual, and a small badge in the corner counts the calls:

- **✓** calls that match the spec
- **⚠** calls with warnings (for example a deprecated endpoint)
- **✗** calls that break the spec

Tap the badge to see the list of calls, newest first. Tap a call to see
exactly what is wrong (`$.address.zip: expected string, got integer`), along
with the request and response bodies. **Copy report** puts a plain-text
summary on the clipboard, ready to paste into a bug report for the backend
team.

The overlay is only for developers. It is off in release builds by default,
so your users never see it.

This package is part of
[openapi_conformance](https://pub.dev/packages/openapi_conformance), which
also checks your API traffic in tests.

## Install

```sh
flutter pub add openapi_conformance_flutter
# plus the adapter for your HTTP client:
flutter pub add openapi_conformance_dio   # or openapi_conformance_http
```

Add your spec as an asset (in `pubspec.yaml`):

```yaml
flutter:
  assets:
    - openapi.yaml
```

## Set up

Create one checker, give it to your HTTP client and to the inspector:

```dart
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:openapi_conformance_dio/openapi_conformance_dio.dart';
import 'package:openapi_conformance_flutter/openapi_conformance_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final spec = OpenApiSpec.fromString(
    await rootBundle.loadString('openapi.yaml'),
  );
  final checker = ConformanceChecker(
    spec,
    options: const ConformanceOptions.runtime(),
  )..enabled = kDebugMode;

  final dio = Dio()..interceptors.add(ConformanceInterceptor(checker));

  runApp(
    MaterialApp(
      builder: ConformanceInspector.builder(checker),
      home: HomePage(dio: dio),
    ),
  );
}
```

`ConformanceInspector.builder` wraps the whole app, including every route
and dialog. If you prefer, wrap a single widget instead:

```dart
ConformanceInspector(
  checker: checker,
  child: const HomePage(),
)
```

With `package:http`, use `ConformanceClient` from `openapi_conformance_http`
instead of the dio interceptor.

## Runtime options

`ConformanceOptions.runtime()` is tuned for a running app:

- lenient mode: extra fields the spec does not mention are warnings, not
  errors;
- calls to URLs that are not in the spec (analytics, images, ...) are
  ignored;
- only the latest 200 calls are kept in memory;
- every problem is also written to the debug console.

## Release builds

Two switches keep release builds clean:

- `ConformanceInspector.enabled` defaults to `kDebugMode`. When it is
  `false`, the widget returns your app untouched and listens to nothing.
- Set `checker.enabled = kDebugMode` too. A disabled checker skips all
  validation, so your HTTP calls carry no extra work.

## Options

| Parameter            | Default                 | Meaning                                          |
| -------------------- | ----------------------- | ------------------------------------------------ |
| `checker`            | required                | Where results come from.                         |
| `enabled`            | `kDebugMode`            | Show the overlay at all.                         |
| `initialAlignment`   | `Alignment.bottomRight` | Where the badge starts. Drag it anywhere.        |
| `showWhenConforming` | `true`                  | Keep the badge visible when nothing is wrong.    |

## Also exported

- `exchangeReport(result)`: the plain-text report used by **Copy report**.
- `formatBody(body)`: pretty-prints JSON bodies.
- Everything from `package:openapi_conformance`, so one import is enough.
