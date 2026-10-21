import 'dart:convert';
import 'dart:math';

const _firstNames = ['Ada', 'Grace', 'Alan', 'Katherine', 'Linus', 'Margaret'];
const _lastNames = [
  'Lovelace',
  'Hopper',
  'Turing',
  'Johnson',
  'Torvalds',
  'Hamilton',
];
const _cities = ['London', 'Lagos', 'Lahore', 'Lisbon', 'Lima', 'Lyon'];
const _countries = ['United Kingdom', 'Nigeria', 'Pakistan', 'Portugal'];
const _words = [
  'friendly',
  'quick',
  'bright',
  'calm',
  'brave',
  'gentle',
  'clever',
];
const _colors = ['teal', 'amber', 'indigo', 'coral', 'olive'];
const _sentences = [
  'A short description.',
  'Everything is working as expected.',
  'Created during onboarding.',
  'Updated by the nightly job.',
];

String _pick(Random random, List<String> values) =>
    values[random.nextInt(values.length)];

String _hex(Random random, int length) => [
  for (var i = 0; i < length; i++) random.nextInt(16).toRadixString(16),
].join();

String _two(int value) => value.toString().padLeft(2, '0');

/// Generators for well-known string formats.
abstract final class FormatValues {
  /// A value for [format], or `null` when the format is unknown.
  static String? generate(String format, Random random) => switch (format) {
    'date-time' => dateTime(random),
    'date' => date(random),
    'time' =>
      '${_two(random.nextInt(24))}:${_two(random.nextInt(60))}:'
          '${_two(random.nextInt(60))}Z',
    'email' => email(random),
    'uuid' => uuid(random),
    'uri' || 'url' || 'iri' => 'https://example.com/${_pick(random, _words)}',
    'uri-reference' || 'iri-reference' => '/${_pick(random, _words)}',
    'uri-template' => 'https://example.com/{id}',
    'hostname' || 'idn-hostname' => '${_pick(random, _words)}.example.com',
    'ipv4' => '192.168.${random.nextInt(256)}.${1 + random.nextInt(254)}',
    'ipv6' => '2001:db8::${random.nextInt(0xffff).toRadixString(16)}',
    'byte' => base64Encode([for (var i = 0; i < 6; i++) random.nextInt(256)]),
    'binary' => 'binary-data',
    'password' => 'S3cure!${_hex(random, 4)}',
    'json-pointer' => '/${_pick(random, _words)}',
    'regex' => '^[a-z]+\$',
    _ => null,
  };

  /// An RFC 3339 timestamp in UTC.
  static String dateTime(Random random) {
    final value = DateTime.utc(
      2020 + random.nextInt(6),
      1 + random.nextInt(12),
      1 + random.nextInt(28),
      random.nextInt(24),
      random.nextInt(60),
      random.nextInt(60),
    );
    return value.toIso8601String();
  }

  /// A calendar date such as `2024-03-15`.
  static String date(Random random) =>
      '${2020 + random.nextInt(6)}-${_two(1 + random.nextInt(12))}-'
      '${_two(1 + random.nextInt(28))}';

  /// A plausible e-mail address.
  static String email(Random random) =>
      '${_pick(random, _firstNames).toLowerCase()}.'
      '${_pick(random, _lastNames).toLowerCase()}@example.com';

  /// A random version 4 UUID.
  static String uuid(Random random) =>
      '${_hex(random, 8)}-${_hex(random, 4)}-4${_hex(random, 3)}-'
      '${'89ab'[random.nextInt(4)]}${_hex(random, 3)}-${_hex(random, 12)}';
}

/// Plausible strings chosen from a property name.
abstract final class NamedValues {
  /// A value that suits a property called [name], or a generic word.
  static String string(String? name, Random random) {
    final key = (name ?? '').toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    bool has(String part) => key.contains(part);
    if (has('email')) return FormatValues.email(random);
    if (has('firstname') || key == 'given' || key == 'givenname') {
      return _pick(random, _firstNames);
    }
    if (has('lastname') || has('surname') || has('familyname')) {
      return _pick(random, _lastNames);
    }
    if (has('username') || key == 'login' || key == 'handle') {
      return '${_pick(random, _firstNames).toLowerCase()}'
          '${random.nextInt(100)}';
    }
    if (has('url') ||
        has('uri') ||
        has('link') ||
        has('website') ||
        has('href') ||
        has('avatar') ||
        has('image') ||
        has('photo')) {
      return 'https://example.com/${_pick(random, _words)}';
    }
    if (has('phone') || has('mobile') || has('tel')) {
      return '+1-555-01${_two(random.nextInt(100))}';
    }
    if (has('city') || has('town')) return _pick(random, _cities);
    if (has('country')) return _pick(random, _countries);
    if (has('street') || has('address')) {
      return '${1 + random.nextInt(250)} Baker Street';
    }
    if (has('zip') || has('postal') || has('postcode')) {
      return '${10000 + random.nextInt(89999)}';
    }
    if (has('currency')) return 'USD';
    if (has('color') || has('colour')) return _pick(random, _colors);
    if (has('password') || has('secret')) return 'S3cure!${_hex(random, 4)}';
    if (has('token') || has('hash') || has('key')) return _hex(random, 24);
    if (key == 'id' || key.endsWith('id')) return 'id_${_hex(random, 8)}';
    if (has('title')) return 'Getting started';
    if (has('description') ||
        has('summary') ||
        has('message') ||
        has('comment') ||
        has('note') ||
        has('bio') ||
        has('text')) {
      return _pick(random, _sentences);
    }
    if (has('date') && !has('update')) return FormatValues.date(random);
    if (has('name')) {
      return '${_pick(random, _firstNames)} ${_pick(random, _lastNames)}';
    }
    return _pick(random, _words);
  }

  /// A default integer range for a property called [name].
  static (int, int) integerRange(String? name) {
    final key = (name ?? '').toLowerCase();
    if (key.contains('age')) return (18, 90);
    if (key.contains('year')) return (2000, 2025);
    if (key == 'id' || key.endsWith('id')) return (1, 9999);
    if (key.contains('count') ||
        key.contains('total') ||
        key.contains('quantity') ||
        key.contains('size')) {
      return (0, 100);
    }
    return (1, 100);
  }
}
