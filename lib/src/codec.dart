part of 'core.dart';

/// Encodes an exact physical scalar value in the owned-JSON value format.
/// Dictionary scalars encode their index; dictionary storage is supplied
/// separately. This custom representation is not Arrow IPC.
Object? scalarToJson(Scalar value) =>
    value._rawValue == null ? null : _valueToJson(value.type, value._rawValue);

/// Decodes and validates a scalar in the owned-JSON physical value format.
Scalar scalarFromJson(DataType type, Object? json, {Array? dictionary}) =>
    Array._fromRaw(type, [
      json == null ? null : _valueFromJson(type, json),
    ], dictionary: dictionary)[0];

/// JSON codec for the protocol's copied, binding-owned logical column batches.
///
/// Wide integers and temporal counters are decimal strings. Floating-point
/// values carry raw hexadecimal IEEE bits, preserving all bit patterns.
final class OwnedBatchJsonCodec {
  const OwnedBatchJsonCodec({
    this.maxNestingDepth = 64,
    this.maxCollectionSize = 100000,
    this.maxSourceLength = 16 * 1024 * 1024,
  });

  final int maxNestingDepth;
  final int maxCollectionSize;
  final int maxSourceLength;

  String encode(RecordBatch batch) => jsonEncode(toJson(batch));

  RecordBatch decode(String source) {
    if (source.length > maxSourceLength) {
      throw const FormatException('Batch JSON exceeds the source-size limit');
    }
    final value = jsonDecode(source);
    if (value is! Map)
      throw const FormatException('Batch must be a JSON object');
    return fromJson(value.cast<String, Object?>());
  }

  Map<String, Object?> toJson(RecordBatch batch) {
    // Logical nested values carry dictionary indices, not the child dictionary
    // storage. Do not serialize an apparently complete but lossy payload.
    bool hasDictionary(Array array) =>
        array.dictionary != null || array.children.any(hasDictionary);
    void checkDictionaries(Array array) {
      if (array.children.any(hasDictionary)) {
        throw UnsupportedError(
          'Owned JSON does not encode nested dictionary storage; use physical Arrow buffers',
        );
      }
      if (array.dictionary case final dictionary?)
        checkDictionaries(dictionary);
    }

    batch.columns.forEach(checkDictionaries);
    return {
      'schema': batch.schema.toJson(),
      'length': batch.numRows,
      'columns': [
        for (var i = 0; i < batch.columns.length; i++)
          _columnToJson(batch.schema.fields[i], batch.columns[i]),
      ],
    };
  }

  RecordBatch fromJson(Map<String, Object?> json) {
    _checkJsonLimits(json);
    try {
      final schemaJson = json['schema'];
      final columnsJson = json['columns'];
      if (schemaJson is! Map || columnsJson is! List) {
        throw const FormatException('Batch requires schema and columns');
      }
      final declaredLength = json['length'];
      if (json.containsKey('length') && declaredLength is! int) {
        throw const FormatException('Batch length must be an integer');
      }
      if (declaredLength is int && declaredLength < 0) {
        throw const FormatException('Batch length must be non-negative');
      }
      final schema = Schema.fromJson(schemaJson.cast<String, Object?>());
      if (columnsJson.length != schema.fields.length) {
        throw const FormatException('Batch column count does not match schema');
      }
      final columns = <Array>[];
      for (var i = 0; i < columnsJson.length; i++) {
        final raw = columnsJson[i];
        if (raw is! Map) {
          throw FormatException('columns[$i] must be an object');
        }
        columns.add(
          _columnFromJson(schema.fields[i], raw.cast<String, Object?>()),
        );
      }
      final length =
          declaredLength as int? ??
          (columns.isEmpty ? 0 : columns.first.length);
      if (columns.any((column) => column.length != length)) {
        throw const FormatException(
          'Batch length does not match column length',
        );
      }
      if (columns.isEmpty) {
        return RecordBatch.fromStructArray(
          Array.fromBuffers(StructType(const []), length, [null]),
        ).replaceSchemaMetadata(schema.metadata);
      }
      return RecordBatch.fromArrays(columns, schema: schema);
    } on FormatException {
      rethrow;
    } on ArgumentError catch (error) {
      throw FormatException('Invalid batch: $error');
    } on TypeError catch (error) {
      throw FormatException('Invalid batch shape: $error');
    }
  }

  Map<String, Object?> _columnToJson(Field field, Array array) => {
    'name': field.name,
    'dtype': array.type.toJson(),
    'validity': array._validity,
    'values': array._rawValues
        .map((value) => value == null ? null : _valueToJson(array.type, value))
        .toList(),
    if (array.dictionary case final dictionary?)
      'dictionary': _anonymousArrayToJson(dictionary),
  };

  Map<String, Object?> _anonymousArrayToJson(Array array) => {
    'dtype': array.type.toJson(),
    'validity': array._validity,
    'values': array._rawValues
        .map((value) => value == null ? null : _valueToJson(array.type, value))
        .toList(),
    if (array.dictionary case final dictionary?)
      'dictionary': _anonymousArrayToJson(dictionary),
  };

  Array _columnFromJson(Field field, Map<String, Object?> json) {
    if (json['name'] != field.name) {
      throw FormatException(
        'Column name ${json['name']} does not match ${field.name}',
      );
    }
    final dtype = _dtype(json);
    if (dtype != field.type)
      throw FormatException(
        'Column ${field.name} datatype does not match schema',
      );
    return _arrayFromParts(dtype, json);
  }

  Array _anonymousArrayFromJson(Map<String, Object?> json) =>
      _arrayFromParts(_dtype(json), json);

  DataType _dtype(Map<String, Object?> json) {
    final raw = json['dtype'];
    if (raw is! Map)
      throw const FormatException('Column dtype must be an object');
    return DataType.fromJson(raw.cast<String, Object?>());
  }

  Array _arrayFromParts(DataType dtype, Map<String, Object?> json) {
    final _rawValues = json['values'];
    final rawValidity = json['validity'];
    if (_rawValues is! List || rawValidity is! List) {
      throw const FormatException('Column values and validity must be lists');
    }
    final validity = rawValidity.map((v) {
      if (v is! bool)
        throw const FormatException('Validity entries must be booleans');
      return v;
    }).toList();
    if (validity.length != _rawValues.length) {
      throw const FormatException(
        'Validity length does not match values length',
      );
    }
    final values = <_Value?>[];
    for (var i = 0; i < _rawValues.length; i++) {
      if (!validity[i]) {
        if (_rawValues[i] != null)
          throw FormatException('Invalid value at index $i must be null');
        values.add(null);
      } else {
        if (_rawValues[i] == null)
          throw FormatException('Valid value at index $i is null');
        values.add(_valueFromJson(dtype, _rawValues[i]));
      }
    }
    Array? dictionary;
    final rawDictionary = json['dictionary'];
    if (rawDictionary != null) {
      if (rawDictionary is! Map)
        throw const FormatException('dictionary must be an object');
      dictionary = _anonymousArrayFromJson(
        rawDictionary.cast<String, Object?>(),
      );
    }
    return Array._fromRaw(
      dtype,
      values,
      validity: validity,
      dictionary: dictionary,
    );
  }

  void _checkJsonLimits(Object? root) {
    if (maxNestingDepth < 1 || maxCollectionSize < 1 || maxSourceLength < 1) {
      throw ArgumentError('JSON decoding limits must be positive');
    }
    var elementCount = 0;
    final active = HashSet<Object>.identity();

    void visit(Object? value, int depth) {
      if (value is! Map && value is! List) return;
      if (depth > maxNestingDepth) {
        throw const FormatException(
          'Batch JSON exceeds the nesting-depth limit',
        );
      }
      if (!active.add(value as Object)) {
        throw const FormatException('Batch JSON contains a collection cycle');
      }
      final length = value is Map ? value.length : (value as List).length;
      elementCount += length;
      if (length > maxCollectionSize || elementCount > maxCollectionSize) {
        throw const FormatException(
          'Batch JSON exceeds the collection-size limit',
        );
      }
      if (value is Map) {
        for (final entry in value.entries) {
          if (entry.key is! String) {
            throw const FormatException('JSON object keys must be strings');
          }
          visit(entry.value, depth + 1);
        }
      } else {
        for (final child in value as List) {
          visit(child, depth + 1);
        }
      }
      active.remove(value);
    }

    visit(root, 1);
  }
}

Object _valueToJson(DataType type, _Value value) {
  switch (type) {
    case NullType():
      throw StateError('Null datatype cannot contain a value');
    case BooleanType():
      return (value as _BooleanValue).value;
    case IntegerType():
      return (value as _IntegerValue).value.toString();
    case FloatingType():
      return {'floatBits': (value as _FloatingValue).hexadecimalBits};
    case DecimalType():
      return {'unscaled': (value as _DecimalValue).unscaled.toString()};
    case Utf8Type():
      return (value as _StringValue).value;
    case BinaryType():
      return {'base64': base64Encode((value as _BinaryValue).bytes)};
    case DateType() || TimestampType() || DurationType() || TimeType():
      return (value as _TemporalValue).value.toString();
    case final ListType list:
      return (value as _ListValue).values
          .map(
            (child) =>
                child == null ? null : _valueToJson(list.field.type, child),
          )
          .toList();
    case final FixedSizeListType list:
      return (value as _ListValue).values
          .map(
            (child) =>
                child == null ? null : _valueToJson(list.field.type, child),
          )
          .toList();
    case final StructType struct:
      final actual = (value as _StructValue).fields;
      return [
        for (var i = 0; i < actual.length; i++)
          {
            'name': actual[i].name,
            'value': actual[i].value == null
                ? null
                : _valueToJson(struct.fields[i].type, actual[i].value!),
          },
      ];
    case DictionaryType():
      return (value as _DictionaryIndexValue).index.toString();
    case FixedSizeBinaryType():
      return {'base64': base64Encode((value as _BinaryValue).bytes)};
    case final MapType map:
      return [
        for (final entry in (value as _MapValue).entries)
          {
            'key': _valueToJson(map.keyField.type, entry.key),
            'value': entry.value == null
                ? null
                : _valueToJson(map.valueField.type, entry.value!),
          },
      ];
    case final UnionType union:
      final tagged = value as _UnionValue;
      return {
        'typeId': tagged.typeId,
        'value': tagged.value == null
            ? null
            : _valueToJson(
                union.fields[union.childIndexForTypeId(tagged.typeId)].type,
                tagged.value!,
              ),
      };
    case IntervalType():
      final interval = (value as _IntervalValue).value;
      return switch (interval.unit) {
        IntervalUnit.yearMonth => {'months': interval.months},
        IntervalUnit.dayTime => {
          'days': interval.days,
          'milliseconds': interval.milliseconds,
        },
        IntervalUnit.monthDayNano => {
          'months': interval.months,
          'days': interval.days,
          'nanoseconds': interval.nanoseconds.toString(),
        },
      };
    case final RunEndEncodedType ree:
      return _valueToJson(ree.valuesField.type, value);
    case final ExtensionType extension:
      return {
        'storage': _valueToJson(
          extension.storageType,
          (value as _ExtensionValue).storage,
        ),
      };
  }
}

_Value _valueFromJson(DataType type, Object? json) {
  Map<String, Object?> object() {
    if (json is! Map)
      throw FormatException('Value for $type must be an object');
    return json.cast<String, Object?>();
  }

  switch (type) {
    case NullType():
      throw const FormatException('Null datatype cannot contain a valid value');
    case BooleanType():
      if (json is! bool)
        throw const FormatException('Boolean value must be a boolean');
      return _BooleanValue(json);
    case IntegerType():
      return _IntegerValue(_canonicalInteger(json, 'Integer value'));
    case final FloatingType floating:
      final bits = object()['floatBits'];
      if (bits is! String)
        throw const FormatException('floatBits must be a string');
      return _FloatingValue(
        floating.bitWidth,
        _floatBits(bits, floating.bitWidth),
      );
    case DecimalType():
      return _DecimalValue(
        _canonicalInteger(object()['unscaled'], 'Decimal unscaled value'),
      );
    case Utf8Type():
      if (json is! String)
        throw const FormatException('String value must be a string');
      return _StringValue(json);
    case BinaryType():
      final encoded = object()['base64'];
      if (encoded is! String)
        throw const FormatException('base64 must be a string');
      return _BinaryValue(base64Decode(encoded));
    case DateType() || TimestampType() || DurationType() || TimeType():
      return _TemporalValue(_canonicalInteger(json, 'Temporal counter'));
    case final ListType list:
      if (json is! List)
        throw const FormatException('List value must be a list');
      return _ListValue(
        json
            .map(
              (child) =>
                  child == null ? null : _valueFromJson(list.field.type, child),
            )
            .toList(),
      );
    case final FixedSizeListType list:
      if (json is! List)
        throw const FormatException('Fixed list value must be a list');
      return _ListValue(
        json
            .map(
              (child) =>
                  child == null ? null : _valueFromJson(list.field.type, child),
            )
            .toList(),
      );
    case final StructType struct:
      if (json is! List)
        throw const FormatException('Struct value must be a list');
      if (json.length != struct.fields.length)
        throw const FormatException('Struct field count mismatch');
      return _StructValue([
        for (var i = 0; i < json.length; i++)
          () {
            final raw = json[i];
            if (raw is! Map)
              throw const FormatException('Struct entry must be an object');
            final entry = raw.cast<String, Object?>();
            final name = entry['name'];
            if (name is! String)
              throw const FormatException('Struct entry name must be a string');
            final _rawValue = entry['value'];
            return _StructEntry(
              name,
              _rawValue == null
                  ? null
                  : _valueFromJson(struct.fields[i].type, _rawValue),
            );
          }(),
      ]);
    case DictionaryType():
      return _DictionaryIndexValue(_canonicalInteger(json, 'Dictionary index'));
    case FixedSizeBinaryType():
      final encoded = object()['base64'];
      if (encoded is! String)
        throw const FormatException('base64 must be a string');
      return _BinaryValue(base64Decode(encoded));
    case final MapType map:
      if (json is! List)
        throw const FormatException('Map value must be a list');
      return _MapValue([
        for (final raw in json)
          () {
            if (raw is! Map)
              throw const FormatException('Map entry must be an object');
            final key = raw['key'];
            if (key == null)
              throw const FormatException('Map keys cannot be null');
            final item = raw['value'];
            return _MapEntry(
              _valueFromJson(map.keyField.type, key),
              item == null ? null : _valueFromJson(map.valueField.type, item),
            );
          }(),
      ]);
    case final UnionType union:
      final tagged = object();
      final typeId = tagged['typeId'];
      if (typeId is! int)
        throw const FormatException('typeId must be an integer');
      final child = union.childIndexForTypeId(typeId);
      if (child < 0) throw FormatException('Undeclared union type id $typeId');
      final item = tagged['value'];
      return _UnionValue(
        typeId,
        item == null ? null : _valueFromJson(union.fields[child].type, item),
      );
    case final IntervalType interval:
      final parts = object();
      int part(String name) {
        final value = parts[name];
        if (value is! int) throw FormatException('$name must be an integer');
        return value;
      }

      return _IntervalValue(switch (interval.unit) {
        IntervalUnit.yearMonth => IntervalValue.yearMonth(part('months')),
        IntervalUnit.dayTime => IntervalValue.dayTime(
          part('days'),
          part('milliseconds'),
        ),
        IntervalUnit.monthDayNano => () {
          return IntervalValue.monthDayNano(
            part('months'),
            part('days'),
            _canonicalInteger(parts['nanoseconds'], 'nanoseconds'),
          );
        }(),
      });
    case final RunEndEncodedType ree:
      return _valueFromJson(ree.valuesField.type, json);
    case final ExtensionType extension:
      final storage = object()['storage'];
      if (storage == null)
        throw const FormatException('Extension storage cannot be null');
      return _ExtensionValue(_valueFromJson(extension.storageType, storage));
  }
}

/// Longest accepted decimal integer string: a sign plus the 78 digits of the
/// widest supported magnitude (2^256). Rejecting longer input before parsing
/// bounds BigInt.parse, whose cost grows super-linearly with length.
const int _maxIntegerStringLength = 79;

final RegExp _canonicalIntegerPattern = RegExp(r'^-?(0|[1-9][0-9]*)$');
final RegExp _hexPattern = RegExp(r'^[0-9a-fA-F]+$');

/// Parses a canonical base-10 integer string: no whitespace, plus sign,
/// leading zeros, radix prefix, or negative zero. Range checks against the
/// declared datatype happen during value validation.
BigInt _canonicalInteger(Object? json, String what) {
  if (json is! String) {
    throw FormatException('$what must be a decimal string');
  }
  if (json.length > _maxIntegerStringLength) {
    throw FormatException('$what exceeds $_maxIntegerStringLength characters');
  }
  if (_canonicalIntegerPattern.firstMatch(json)?.end != json.length ||
      json == '-0') {
    throw FormatException('$what must be a canonical decimal integer: $json');
  }
  return BigInt.parse(json);
}

BigInt _floatBits(String bits, int bitWidth) {
  final digits = bitWidth ~/ 4;
  if (bits.length != digits ||
      _hexPattern.firstMatch(bits)?.end != bits.length) {
    throw FormatException(
      'floatBits for float$bitWidth must be exactly $digits hexadecimal digits',
    );
  }
  return BigInt.parse(bits, radix: 16);
}
