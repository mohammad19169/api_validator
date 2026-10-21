## 1.0.0

- Initial release.
- `ApiValidatorInspector` debug overlay with a draggable badge that counts
  conforming calls, warnings and errors.
- Full-screen panel with filters (all, errors, warnings), path search and a
  clear button.
- Detail view showing each violation with its JSON path, plus pretty-printed
  request and response bodies and a "Copy report" button.
- `ApiValidatorInspector.builder` for `MaterialApp.builder`; works without a
  `Navigator` above it.
- Off in release builds by default (`enabled: kDebugMode`).
