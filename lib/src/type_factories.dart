part of 'core.dart';

IntegerType int8() => IntegerType(8);
IntegerType int16() => IntegerType(16);
IntegerType int32() => IntegerType(32);
IntegerType int64() => IntegerType(64);
IntegerType uint8() => IntegerType(8, signed: false);
IntegerType uint16() => IntegerType(16, signed: false);
IntegerType uint32() => IntegerType(32, signed: false);
IntegerType uint64() => IntegerType(64, signed: false);
IntegerType bindingInt128() => IntegerType(128);
IntegerType bindingUint128() => IntegerType(128, signed: false);
FloatingType float16() => FloatingType(16);
FloatingType float32() => FloatingType(32);
FloatingType float64() => FloatingType(64);
BooleanType boolType() => const BooleanType();
NullType nullType() => const NullType();
Utf8Type string() => const Utf8Type();
Utf8Type largeString() => const Utf8Type(OffsetWidth.large);
Utf8Type stringView() => const Utf8Type(OffsetWidth.view);

/// Variable-length binary, or [FixedSizeBinaryType] when [length] is given,
/// as PyArrow's `binary(length=-1)`.
DataType binary([int length = -1]) {
  if (length == -1) return const BinaryType();
  return FixedSizeBinaryType(length);
}

BinaryType binaryView() => const BinaryType(OffsetWidth.view);
BinaryType largeBinary() => const BinaryType(OffsetWidth.large);
DecimalType decimal32(int precision, [int scale = 0]) =>
    DecimalType(precision, scale, bitWidth: 32);
DecimalType decimal64(int precision, [int scale = 0]) =>
    DecimalType(precision, scale, bitWidth: 64);
DecimalType decimal128(int precision, [int scale = 0]) =>
    DecimalType(precision, scale);
DecimalType decimal256(int precision, [int scale = 0]) =>
    DecimalType(precision, scale, bitWidth: 256);
IntervalType monthDayNanoInterval() =>
    const IntervalType(IntervalUnit.monthDayNano);
DateType date32() => const DateType();
DateType date64() => const DateType(DateUnit.millisecond);

TimeType time32(Object unit) {
  final parsed = _timeUnit(unit);
  if (parsed != TimeUnit.second && parsed != TimeUnit.millisecond) {
    throw ArgumentError.value(unit, 'unit', 'time32 requires s or ms');
  }
  return TimeType(parsed);
}

TimeType time64(Object unit) {
  final parsed = _timeUnit(unit);
  if (parsed != TimeUnit.microsecond && parsed != TimeUnit.nanosecond) {
    throw ArgumentError.value(unit, 'unit', 'time64 requires us or ns');
  }
  return TimeType(parsed);
}

TimestampType timestamp(Object unit, {String? tz}) =>
    TimestampType(_timeUnit(unit), timeZone: tz);
DurationType duration(Object unit) => DurationType(_timeUnit(unit));

DataType listType(Object valueType, {int listSize = -1}) {
  final field = _itemField(valueType);
  if (listSize == -1) return ListType(field);
  return FixedSizeListType(field, listSize);
}

ListType largeList(Object valueType) =>
    ListType(_itemField(valueType), offsetWidth: OffsetWidth.large);
ListType listView(Object valueType) =>
    ListType(_itemField(valueType), view: true);
ListType largeListView(Object valueType) =>
    ListType(_itemField(valueType), offsetWidth: OffsetWidth.large, view: true);

/// PyArrow's `map_`: a non-nullable `key` field and a nullable `value` field.
MapType mapType(Object keyType, Object itemType, {bool keysSorted = false}) =>
    MapType(
      switch (keyType) {
        Field field => field,
        DataType type => Field('key', type, nullable: false),
        _ => throw ArgumentError.value(keyType, 'keyType'),
      },
      _namedField(itemType, 'value'),
      keysSorted: keysSorted,
    );

UnionType union(
  Iterable<Field> childFields,
  UnionMode mode, {
  List<int>? typeCodes,
}) => UnionType(childFields.toList(), mode: mode, typeIds: typeCodes);
UnionType sparseUnion(Iterable<Field> childFields, {List<int>? typeCodes}) =>
    union(childFields, UnionMode.sparse, typeCodes: typeCodes);
UnionType denseUnion(Iterable<Field> childFields, {List<int>? typeCodes}) =>
    union(childFields, UnionMode.dense, typeCodes: typeCodes);

/// PyArrow's `run_end_encoded`: non-nullable `run_ends` and `values` fields.
RunEndEncodedType runEndEncoded(DataType runEndType, DataType valueType) =>
    RunEndEncodedType(
      Field('run_ends', runEndType, nullable: false),
      Field('values', valueType),
    );

Field _itemField(Object valueType) => _namedField(valueType, 'item');
Field _namedField(Object valueType, String name) => switch (valueType) {
  Field field => field,
  DataType type => Field(name, type),
  _ => throw ArgumentError.value(
    valueType,
    'valueType',
    'Expected DataType or Field',
  ),
};

StructType struct(Iterable<Field> fields) => StructType(fields.toList());
DictionaryType dictionary(
  DataType indexType,
  DataType valueType, {
  bool ordered = false,
}) => DictionaryType(indexType, valueType, ordered: ordered);
ExtensionType extension(
  String name,
  DataType storageType, {
  String? metadata,
}) => ExtensionType(name, storageType, metadata: metadata);

TimeUnit _timeUnit(Object unit) => switch (unit) {
  TimeUnit value => value,
  String value => TimeUnit.parse(value),
  _ => throw ArgumentError.value(unit, 'unit', 'Expected String or TimeUnit'),
};
