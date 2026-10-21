part of 'core.dart';

final class Field {
  Field(
    this.name,
    this.type, {
    this.nullable = true,
    Map<Object, Object>? metadata,
  }) : metadata = metadata == null ? null : ByteMetadata(metadata);
  final String name;
  final DataType type;
  final bool nullable;
  final ByteMetadata? metadata;
  Field withMetadata(Map<Object, Object>? metadata) =>
      Field(name, type, nullable: nullable, metadata: metadata);
  Field removeMetadata() => withMetadata(null);
  Field withName(String name) =>
      Field(name, type, nullable: nullable, metadata: metadata);
  Field withType(DataType type) =>
      Field(name, type, nullable: nullable, metadata: metadata);
  Field withNullable(bool nullable) =>
      Field(name, type, nullable: nullable, metadata: metadata);
  bool equals(Field other, {bool checkMetadata = false}) =>
      name == other.name &&
      type.equals(other.type, checkMetadata: checkMetadata) &&
      nullable == other.nullable &&
      (!checkMetadata || _metadataEquals(metadata, other.metadata));
  @override
  bool operator ==(Object other) => other is Field && equals(other);
  @override
  int get hashCode => Object.hash(name, type, nullable);
  Map<String, Object?> toJson() => {
    'name': name,
    'dtype': type.toJson(),
    'nullable': nullable,
    if (metadata != null) 'metadata': metadata!.toJson(),
  };
  factory Field.fromJson(Map<String, Object?> json) {
    final name = json['name'];
    final dtype = json['dtype'] ?? json['type'];
    if (name is! String ||
        dtype is! Map ||
        (json.containsKey('nullable') && json['nullable'] is! bool))
      throw const FormatException('Invalid field');
    return Field(
      name,
      DataType.fromJson(Map<String, Object?>.from(dtype)),
      nullable: json['nullable'] as bool? ?? true,
      metadata: ByteMetadata.fromJson(json['metadata']),
    );
  }
}

final class Schema {
  Schema(Iterable<Object> fields, {Map<Object, Object>? metadata})
    : fields = List.unmodifiable(fields.map(_field)),
      metadata = metadata == null ? null : ByteMetadata(metadata);
  final List<Field> fields;
  final ByteMetadata? metadata;
  int get length => fields.length;
  List<String> get names => List.unmodifiable(fields.map((f) => f.name));
  List<DataType> get types => List.unmodifiable(fields.map((f) => f.type));
  Field field(Object indexOrName) => fields[_fieldIndex(this, indexOrName)];
  Field operator [](Object indexOrName) => field(indexOrName);
  int getFieldIndex(String name) {
    var found = -1;
    for (var i = 0; i < length; i++) {
      if (fields[i].name == name) {
        if (found != -1) return -1;
        found = i;
      }
    }
    return found;
  }

  List<int> getAllFieldIndices(String name) => [
    for (var i = 0; i < length; i++)
      if (fields[i].name == name) i,
  ];
  Schema withMetadata(Map<Object, Object>? metadata) =>
      Schema(fields, metadata: metadata);
  Schema removeMetadata() => withMetadata(null);
  bool equals(Schema other, {bool checkMetadata = false}) {
    if (length != other.length ||
        (checkMetadata && !_metadataEquals(metadata, other.metadata)))
      return false;
    for (var i = 0; i < length; i++) {
      if (!fields[i].equals(other.fields[i], checkMetadata: checkMetadata))
        return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) => other is Schema && equals(other);
  @override
  int get hashCode => Object.hashAll(fields);
  Map<String, Object?> toJson() => {
    'fields': fields.map((f) => f.toJson()).toList(),
    if (metadata != null) 'metadata': metadata!.toJson(),
  };
  factory Schema.fromJson(Map<String, Object?> json) {
    final fields = json['fields'];
    if (fields is! List)
      throw const FormatException('schema.fields must be a list');
    return Schema(
      fields.map((f) {
        if (f is! Map || f.keys.any((key) => key is! String)) {
          throw const FormatException('schema.fields entries must be objects');
        }
        return Field.fromJson(Map<String, Object?>.from(f));
      }),
      metadata: ByteMetadata.fromJson(json['metadata']),
    );
  }
}

Field _field(Object value) => switch (value) {
  Field f => f,
  (String name, DataType type) => Field(name, type),
  _ => throw ArgumentError.value(
    value,
    'fields',
    'Expected Field or (String, DataType)',
  ),
};
bool _metadataEquals(ByteMetadata? a, ByteMetadata? b) =>
    (a?.isEmpty ?? true) && (b?.isEmpty ?? true) || (a != null && a.equals(b));
int _fieldIndex(Schema schema, Object value) {
  if (value is int) {
    final i = value < 0 ? value + schema.length : value;
    RangeError.checkValidIndex(i, schema.fields);
    return i;
  }
  if (value is String) {
    final i = schema.getFieldIndex(value);
    if (i < 0)
      throw ArgumentError('Field name "$value" is missing or ambiguous');
    return i;
  }
  throw ArgumentError.value(value, 'indexOrName', 'Expected int or String');
}

Field field(
  String name,
  DataType type, {
  bool nullable = true,
  Map<Object, Object>? metadata,
}) => Field(name, type, nullable: nullable, metadata: metadata);
Schema schema(Iterable<Object> fields, {Map<Object, Object>? metadata}) =>
    Schema(fields, metadata: metadata);
