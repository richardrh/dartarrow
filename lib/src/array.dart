import 'type.dart';
import 'value.dart';
import 'schema.dart';

final class ArrowArray {
  ArrowArray(
    this.type,
    List<ArrowValue?> values, {
    List<bool>? validity,
    this.dictionary,
  }) : values = List.unmodifiable(values),
       validity = List.unmodifiable(validity ?? values.map((v) => v != null)) {
    if (this.validity.length != values.length) {
      throw ArgumentError(
        'Validity length ${this.validity.length} does not match value length ${values.length}',
      );
    }
    for (var i = 0; i < values.length; i++) {
      if (this.validity[i] != (values[i] != null)) {
        throw ArgumentError('Validity and value disagree at index $i');
      }
      final value = values[i];
      if (value != null) validateArrowValue(type, value, path: 'values[$i]');
    }
    if (type case final ArrowDictionaryType dictionaryType) {
      final dictionary = this.dictionary;
      if (dictionary == null)
        throw ArgumentError('Dictionary array requires dictionary values');
      if (dictionary.type != dictionaryType.valueType) {
        throw ArgumentError(
          'Dictionary value datatype does not match dictionary datatype',
        );
      }
      for (var i = 0; i < values.length; i++) {
        final value = values[i];
        if (value is ArrowDictionaryIndexValue &&
            (value.index.isNegative ||
                value.index >= BigInt.from(dictionary.length))) {
          throw RangeError(
            'Dictionary index ${value.index} at values[$i] is out of bounds',
          );
        }
      }
    } else if (dictionary != null) {
      throw ArgumentError('dictionary is only valid for a dictionary datatype');
    }
  }

  final ArrowDataType type;
  final List<ArrowValue?> values;
  final List<bool> validity;
  final ArrowArray? dictionary;
  int get length => values.length;
  ArrowValue? operator [](int index) => values[index];
}

final class ArrowArrayBuilder {
  ArrowArrayBuilder(this.type, {this.dictionary});
  final ArrowDataType type;
  final ArrowArray? dictionary;
  final List<ArrowValue?> _values = [];
  bool _built = false;

  int get length => _values.length;
  void append(ArrowValue? value) {
    if (_built) throw StateError('Builder has already been built');
    if (value != null) validateArrowValue(type, value, path: 'value');
    _values.add(value);
  }

  void appendNull() => append(null);
  ArrowArray build() {
    if (_built) throw StateError('Builder has already been built');
    _built = true;
    return ArrowArray(type, _values, dictionary: dictionary);
  }
}

void validateArrowValue(
  ArrowDataType type,
  ArrowValue value, {
  String path = 'value',
}) {
  Never mismatch() =>
      throw ArgumentError('$path is ${value.runtimeType}, not valid for $type');
  switch (type) {
    case ArrowNullType():
      mismatch();
    case ArrowBooleanType():
      if (value is! ArrowBooleanValue) mismatch();
    case final ArrowIntegerType integer:
      if (value is! ArrowIntegerValue) mismatch();
      if (value.value < integer.minimum || value.value > integer.maximum) {
        throw RangeError(
          '$path integer ${value.value} is outside ${integer.minimum}..${integer.maximum}',
        );
      }
    case final ArrowFloatingType floating:
      if (value is! ArrowFloatingValue || value.bitWidth != floating.bitWidth)
        mismatch();
    case final ArrowDecimalType decimal:
      if (value is! ArrowDecimalValue) mismatch();
      final digits = value.unscaled.abs().toString().length;
      if (digits > decimal.precision) {
        throw RangeError(
          '$path unscaled decimal has $digits digits; precision is ${decimal.precision}',
        );
      }
    case ArrowUtf8Type():
      if (value is! ArrowStringValue) mismatch();
    case ArrowBinaryType():
      if (value is! ArrowBinaryValue) mismatch();
    case final ArrowDateType date:
      if (value is! ArrowTemporalValue) mismatch();
      final width = date.unit == ArrowDateUnit.day ? 32 : 64;
      final minimum = -(BigInt.one << (width - 1));
      final maximum = (BigInt.one << (width - 1)) - BigInt.one;
      if (value.value < minimum || value.value > maximum) {
        throw RangeError('$path date counter does not fit int$width');
      }
    case ArrowTimestampType() || ArrowDurationType():
      if (value is! ArrowTemporalValue) mismatch();
      if (!_fitsSigned64(value.value)) {
        throw RangeError('$path temporal counter does not fit int64');
      }
    case final ArrowTimeType time:
      if (value is! ArrowTemporalValue) mismatch();
      final unitsPerSecond = switch (time.unit) {
        ArrowTimeUnit.second => BigInt.one,
        ArrowTimeUnit.millisecond => BigInt.from(1000),
        ArrowTimeUnit.microsecond => BigInt.from(1000000),
        ArrowTimeUnit.nanosecond => BigInt.from(1000000000),
      };
      final endOfDay = BigInt.from(86400) * unitsPerSecond;
      if (value.value.isNegative || value.value >= endOfDay) {
        throw RangeError('$path time counter must fall within one day');
      }
      if ((time.unit == ArrowTimeUnit.second ||
              time.unit == ArrowTimeUnit.millisecond) &&
          value.value > BigInt.from(0x7fffffff)) {
        throw RangeError('$path time counter does not fit int32');
      }
    case final ArrowListType list:
      if (value is! ArrowListValue) mismatch();
      _validateChildren(list.field, value.values, path);
    case final ArrowFixedSizeListType list:
      if (value is! ArrowListValue) mismatch();
      if (value.values.length != list.size) {
        throw ArgumentError(
          '$path has ${value.values.length} children; expected ${list.size}',
        );
      }
      _validateChildren(list.field, value.values, path);
    case final ArrowStructType struct:
      if (value is! ArrowStructValue) mismatch();
      if (value.fields.length != struct.fields.length) {
        throw ArgumentError(
          '$path has ${value.fields.length} fields; expected ${struct.fields.length}',
        );
      }
      for (var i = 0; i < struct.fields.length; i++) {
        final expected = struct.fields[i];
        final actual = value.fields[i];
        if (actual.name != expected.name) {
          throw ArgumentError(
            '$path field $i is ${actual.name}; expected ${expected.name}',
          );
        }
        if (actual.value == null) {
          if (!expected.nullable)
            throw ArgumentError('$path.${expected.name} is not nullable');
        } else {
          validateArrowValue(
            expected.type,
            actual.value!,
            path: '$path.${expected.name}',
          );
        }
      }
    case final ArrowDictionaryType dictionary:
      if (value is! ArrowDictionaryIndexValue) mismatch();
      validateArrowValue(
        dictionary.indexType,
        ArrowIntegerValue(value.index),
        path: path,
      );
    case final ArrowExtensionType extension:
      if (value is! ArrowExtensionValue) mismatch();
      validateArrowValue(
        extension.storageType,
        value.storage,
        path: '$path.storage',
      );
  }
}

bool _fitsSigned64(BigInt value) =>
    value >= -(BigInt.one << 63) && value <= (BigInt.one << 63) - BigInt.one;

void _validateChildren(
  ArrowField field,
  List<ArrowValue?> values,
  String path,
) {
  for (var i = 0; i < values.length; i++) {
    final child = values[i];
    if (child == null) {
      if (!field.nullable) throw ArgumentError('$path[$i] is not nullable');
    } else {
      validateArrowValue(field.type, child, path: '$path[$i]');
    }
  }
}
