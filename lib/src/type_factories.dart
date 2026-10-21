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
BinaryType binary() => const BinaryType();
BinaryType largeBinary() => const BinaryType(OffsetWidth.large);
DecimalType decimal128(int precision, [int scale = 0]) =>
    DecimalType(precision, scale);
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
  final field = switch (valueType) {
    Field field => field,
    DataType type => Field('item', type),
    _ => throw ArgumentError.value(
      valueType,
      'valueType',
      'Expected DataType or Field',
    ),
  };
  if (listSize == -1) return ListType(field);
  return FixedSizeListType(field, listSize);
}

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
