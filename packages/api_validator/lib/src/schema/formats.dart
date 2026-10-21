import 'schema_validator.dart';

final _dateTime = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})[Tt ](\d{2}):(\d{2}):(\d{2})(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$',
);
final _date = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
final _time = RegExp(
  r'^(\d{2}):(\d{2}):(\d{2})(\.\d+)?([Zz]|[+-]\d{2}:\d{2})?$',
);
final _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final _ipv4 = RegExp(
  r'^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$',
);
final _hostname = RegExp(
  r'^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$',
);
final _base64 = RegExp(
  r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
);

bool _validDate(String year, String month, String day) {
  final y = int.parse(year);
  final m = int.parse(month);
  final d = int.parse(day);
  if (m < 1 || m > 12 || d < 1) return false;
  final date = DateTime.utc(y, m, d);
  return date.month == m && date.day == d;
}

bool _validClock(String hour, String minute, String second) =>
    int.parse(hour) < 24 && int.parse(minute) < 60 && int.parse(second) <= 60;

bool _strings(Object? value, bool Function(String value) test) =>
    value is! String || test(value);

bool _integers(Object? value, bool Function(num value) test) =>
    value is! num || test(value);

/// The formats validated out of the box.
///
/// Unknown formats are ignored, as JSON Schema recommends.
final Map<String, FormatValidator> builtInFormats = {
  'date-time': (value) => _strings(value, (s) {
    final match = _dateTime.firstMatch(s);
    return match != null &&
        _validDate(match[1]!, match[2]!, match[3]!) &&
        _validClock(match[4]!, match[5]!, match[6]!);
  }),
  'date': (value) => _strings(value, (s) {
    final match = _date.firstMatch(s);
    return match != null && _validDate(match[1]!, match[2]!, match[3]!);
  }),
  'time': (value) => _strings(value, (s) {
    final match = _time.firstMatch(s);
    return match != null && _validClock(match[1]!, match[2]!, match[3]!);
  }),
  'email': (value) => _strings(value, _email.hasMatch),
  'uuid': (value) => _strings(value, _uuid.hasMatch),
  'uri': (value) => _strings(value, (s) => Uri.tryParse(s)?.hasScheme ?? false),
  'uri-reference': (value) => _strings(value, (s) => Uri.tryParse(s) != null),
  'ipv4': (value) => _strings(value, _ipv4.hasMatch),
  'ipv6': (value) => _strings(value, (s) {
    try {
      Uri.parseIPv6Address(s);
      return true;
    } on FormatException {
      return false;
    }
  }),
  'hostname': (value) => _strings(value, _hostname.hasMatch),
  'byte': (value) => _strings(value, _base64.hasMatch),
  'int32': (value) => _integers(
    value,
    (n) => n == n.truncate() && n >= -2147483648 && n <= 2147483647,
  ),
  'int64': (value) => _integers(value, (n) => n == n.truncate()),
};
