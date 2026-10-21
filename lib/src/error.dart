part of 'core.dart';

/// Invalid Arrow values or a conversion that would violate the target type.
/// Distinct from argument-shape errors such as a negative slice length.
class ArrowInvalid extends ArgumentError {
  ArrowInvalid(String message) : super(message);
}

/// An incompatible Arrow datatype or collection of datatypes.
class ArrowTypeError extends ArgumentError {
  ArrowTypeError(String message) : super(message);
}
