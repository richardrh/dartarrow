import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'api_probe.dart' as api;

void main() {
  final fixture = api.object(
    jsonDecode(
      File('test/conformance/fixtures/api_pyarrow.json').readAsStringSync(),
    ),
  );
  for (final raw in fixture['cases'] as List) {
    final c = api.object(raw);
    test('PyArrow 26 API ${c['id']}', () {
      final result = api.runCase(c);
      expect(result['status'], 'pass', reason: jsonEncode(result));
    });
  }
  test('differential oracle rejects corrupted independent expected value', () {
    final c = api.object((fixture['cases'] as List).first);
    final corrupt = {
      ...c,
      'expected': {
        'ok': {'deliberately': 'not an Array'},
      },
    };
    expect(api.runCase(corrupt)['status'], 'fail');
  });
}
