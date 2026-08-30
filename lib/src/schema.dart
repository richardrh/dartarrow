import 'dart:collection';

import 'type.dart';

Map<String, String> _metadata(Map<String, String> value) =>
    UnmodifiableMapView(Map<String, String>.of(value));

final class ArrowField {
  ArrowField(
    this.name,
    this.type, {
    this.nullable = true,
    Map<String, String> metadata = const {},
  }) : metadata = _metadata(metadata) {
    if (name.isEmpty)
      throw ArgumentError.value(name, 'name', 'must not be empty');
  }
  final String name;
  final ArrowDataType type;
  final bool nullable;
  final Map<String, String> metadata;

  Map<String, Object?> toJson() => {
    'name': name,
    'dtype': type.toJson(),
    'nullable': nullable,
    if (metadata.isNotEmpty) 'metadata': metadata,
  };

  factory ArrowField.fromJson(Map<String, Object?> json) {
    try {
      final name = json['name'];
      final dtype = json['dtype'] ?? json['type'];
      if (name is! String || dtype is! Map) {
        throw const FormatException('Invalid Arrow field');
      }
      final nullable = json['nullable'];
      if (nullable != null || json.containsKey('nullable')) {
        if (nullable is! bool) {
          throw const FormatException('field.nullable must be a boolean');
        }
      }
      return ArrowField(
        name,
        ArrowDataType.fromJson(_stringObjectMap(dtype, 'field.dtype')),
        nullable: nullable as bool? ?? true,
        metadata: _metadataFromJson(
          json['metadata'],
          'field.metadata',
          present: json.containsKey('metadata'),
        ),
      );
    } on FormatException {
      rethrow;
    } on ArgumentError catch (error) {
      throw FormatException('Invalid Arrow field: $error');
    } on TypeError catch (error) {
      throw FormatException('Invalid Arrow field shape: $error');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ArrowField &&
      name == other.name &&
      type == other.type &&
      nullable == other.nullable &&
      _mapEquals(metadata, other.metadata);
  @override
  int get hashCode => Object.hash(
    name,
    type,
    nullable,
    Object.hashAllUnordered(
      metadata.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );
}

final class ArrowSchema {
  ArrowSchema(
    List<ArrowField> fields, {
    Map<String, String> metadata = const {},
  }) : fields = List.unmodifiable(fields),
       metadata = _metadata(metadata) {
    final names = <String>{};
    for (final field in fields) {
      if (!names.add(field.name))
        throw ArgumentError('Duplicate schema field: ${field.name}');
    }
  }
  final List<ArrowField> fields;
  final Map<String, String> metadata;

  Map<String, Object?> toJson() => {
    'fields': fields.map((f) => f.toJson()).toList(),
    if (metadata.isNotEmpty) 'metadata': metadata,
  };

  factory ArrowSchema.fromJson(Map<String, Object?> json) {
    try {
      final fields = json['fields'];
      if (fields is! List) {
        throw const FormatException('schema.fields must be a list');
      }
      return ArrowSchema(
        fields.indexed
            .map(
              (entry) => ArrowField.fromJson(
                _stringObjectMap(entry.$2, 'schema.fields[${entry.$1}]'),
              ),
            )
            .toList(),
        metadata: _metadataFromJson(
          json['metadata'],
          'schema.metadata',
          present: json.containsKey('metadata'),
        ),
      );
    } on FormatException {
      rethrow;
    } on ArgumentError catch (error) {
      throw FormatException('Invalid Arrow schema: $error');
    } on TypeError catch (error) {
      throw FormatException('Invalid Arrow schema shape: $error');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ArrowSchema &&
      _listEquals(fields, other.fields) &&
      _mapEquals(metadata, other.metadata);
  @override
  int get hashCode => Object.hash(
    Object.hashAll(fields),
    Object.hashAllUnordered(
      metadata.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );
}

bool _mapEquals<K, V>(Map<K, V> a, Map<K, V> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
bool _listEquals<T>(List<T> a, List<T> b) =>
    a.length == b.length &&
    List.generate(a.length, (i) => i).every((i) => a[i] == b[i]);

Map<String, Object?> _stringObjectMap(Object? value, String path) {
  if (value is! Map) throw FormatException('$path must be an object');
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$path keys must be strings');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

Map<String, String> _metadataFromJson(
  Object? value,
  String path, {
  required bool present,
}) {
  if (!present) return const {};
  if (value is! Map) throw FormatException('$path must be an object');
  final result = <String, String>{};
  for (final entry in value.entries) {
    if (entry.key is! String || entry.value is! String) {
      throw FormatException('$path keys and values must be strings');
    }
    result[entry.key as String] = entry.value as String;
  }
  return result;
}
