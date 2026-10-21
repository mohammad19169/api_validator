# openapi_conformance

Validate the HTTP traffic of Dart and Flutter apps against an OpenAPI 3.0 / 3.1
spec: in unit tests, in CI, and in debug builds of the running app.

| Package | Description |
|---|---|
| [`openapi_conformance`](packages/openapi_conformance) | Core: spec loading, validation, coverage, fake data, edge cases, spec diff, CLI. |
| [`openapi_conformance_dio`](packages/openapi_conformance_dio) | Dio interceptor. |
| [`openapi_conformance_http`](packages/openapi_conformance_http) | `package:http` client wrapper. |
| [`openapi_conformance_test`](packages/openapi_conformance_test) | Test matchers and setup helpers. |
| [`openapi_conformance_flutter`](packages/openapi_conformance_flutter) | In-app debug overlay. |

## Development

This repository is a [pub workspace](https://dart.dev/tools/pub/workspaces).

```sh
flutter pub get                       # resolves every package
dart format .
flutter analyze
(cd packages/openapi_conformance && dart test)
(cd packages/openapi_conformance_flutter && flutter test)
```

### Publishing

Publish the core first, then the packages that depend on it:

```sh
(cd packages/openapi_conformance && dart pub publish)
(cd packages/openapi_conformance_dio && dart pub publish)
(cd packages/openapi_conformance_http && dart pub publish)
(cd packages/openapi_conformance_test && dart pub publish)
(cd packages/openapi_conformance_flutter && flutter pub publish)
```

Then move each package to the `solaxsoftwares.com` verified publisher:
pub.dev → package page → **Admin** → **Transfer to publisher**.

## License

MIT
