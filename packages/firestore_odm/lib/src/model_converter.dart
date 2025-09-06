import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firestore_odm/src/firestore_odm.dart';

typedef JsonDeserializer<T> = T Function(Map<String, dynamic>);
typedef JsonSerializer<T> = Map<String, dynamic> Function(T);

// Removed ModelConverter class - now using FirestoreConverter system exclusively

/// Base interface for Firestore field converters
/// T: Dart type, F: Firestore type
abstract interface class FirestoreConverter<T, F> {
  T fromJson(F data);
  F toJson(T data);

  factory FirestoreConverter.create({
    required T Function(F data) fromJson,
    required F Function(T data) toJson,
  }) => _FirestoreConverterImpl(fromJson: fromJson, toJson: toJson);
}

/// Converter for primitive types that need no conversion
class PrimitiveConverter<T> implements FirestoreConverter<T, T> {
  const PrimitiveConverter();

  @override
  T fromJson(T data) => data;

  @override
  T toJson(T data) => data;
}

class MapConverter<K, V>
    implements FirestoreConverter<Map<K, V>, Map<String, dynamic>> {
  final FirestoreConverter<K, dynamic> keyConverter;
  final FirestoreConverter<V, dynamic> valueConverter;

  const MapConverter(this.keyConverter, this.valueConverter);

  @override
  Map<K, V> fromJson(Map<String, dynamic> data) {
    return data.map(
      (key, value) =>
          MapEntry(keyConverter.fromJson(key), valueConverter.fromJson(value)),
    );
  }

  @override
  Map<String, dynamic> toJson(Map<K, V> data) {
    return data.map(
      (key, value) =>
          MapEntry(keyConverter.toJson(key), valueConverter.toJson(value)),
    );
  }
}

class IterableConverter<T>
    implements FirestoreConverter<Iterable<T>, List<dynamic>> {
  final FirestoreConverter<T, dynamic> elementConverter;

  const IterableConverter(this.elementConverter);

  @override
  Iterable<T> fromJson(List<dynamic> data) {
    return data.map((item) => elementConverter.fromJson(item));
  }

  @override
  List<dynamic> toJson(Iterable<T> data) {
    return data.map((item) => elementConverter.toJson(item)).toList();
  }
}

class ListConverter<T> implements FirestoreConverter<List<T>, List<dynamic>> {
  final FirestoreConverter<T, dynamic> elementConverter;
  const ListConverter(this.elementConverter);

  @override
  List<T> fromJson(List<dynamic> data) =>
      data.map((item) => elementConverter.fromJson(item)).toList();

  @override
  List<dynamic> toJson(Iterable<T> data) =>
      data.map((item) => elementConverter.toJson(item)).toList();
}

class SetConverter<T> extends IterableConverter<T> {
  const SetConverter(super.elementConverter);

  @override
  Set<T> fromJson(List<dynamic> data) => super.fromJson(data).toSet();
}

/// Converter for DateTime <-> Timestamp
class DateTimeConverter implements FirestoreConverter<DateTime, dynamic> {
  const DateTimeConverter();

  @override
  DateTime fromJson(dynamic data) {
    if (data is Timestamp) {
      return data.toDate();
    } else if (data is String) {
      // Handle test environment where Timestamp might be serialized as String
      return DateTime.parse(data);
    } else if (data is int) {
      // Handle milliseconds since epoch
      return DateTime.fromMillisecondsSinceEpoch(data);
    } else {
      throw ArgumentError(
        'Unsupported DateTime data type: ${data.runtimeType}',
      );
    }
  }

  @override
  dynamic toJson(DateTime data) {
    // Check if this is the special server timestamp constant
    // If so, return it as-is so _replaceServerTimestamps can handle it later
    if (data == FirestoreODM.serverTimestamp) {
      return data;
    }
    return Timestamp.fromDate(data);
  }
}

/// Converter for Duration <-> int (microseconds)
class DurationConverter implements FirestoreConverter<Duration, int> {
  const DurationConverter();

  @override
  Duration fromJson(int data) {
    return Duration(microseconds: data);
  }

  @override
  int toJson(Duration data) => data.inMicroseconds;
}

class NullableConverter<T, F> implements FirestoreConverter<T?, F?> {
  final FirestoreConverter<T?, F?> innerConverter;

  const NullableConverter(this.innerConverter);

  @override
  T? fromJson(F? data) {
    if (data == null) return null;
    return innerConverter.fromJson(data);
  }

  @override
  F? toJson(T? data) {
    if (data == null) return null;
    return innerConverter.toJson(data);
  }
}

/// Converter for Uint8List <-> Blob
class BytesConverter implements FirestoreConverter<Uint8List, Blob> {
  const BytesConverter();

  @override
  Uint8List fromJson(Blob data) => data.bytes;

  @override
  Blob toJson(Uint8List data) => Blob(data);
}

/// Converter for GeoPoint (no conversion needed, but provides consistency)
class GeoPointConverter implements FirestoreConverter<GeoPoint, GeoPoint> {
  const GeoPointConverter();

  @override
  GeoPoint fromJson(GeoPoint data) => data;

  @override
  GeoPoint toJson(GeoPoint data) => data;
}

/// Converter for DocumentReference (no conversion needed, but provides consistency)
class DocumentReferenceConverter
    implements FirestoreConverter<DocumentReference, DocumentReference> {
  const DocumentReferenceConverter();

  @override
  DocumentReference fromJson(DocumentReference data) => data;

  @override
  DocumentReference toJson(DocumentReference data) => data;
}

/// Generic converter for custom objects using fromJson/toJson functions
class _FirestoreConverterImpl<T, F> implements FirestoreConverter<T, F> {
  final F Function(T data) _toJson;
  final T Function(F data) _fromJson;

  const _FirestoreConverterImpl({
    required T Function(F data) fromJson,
    required F Function(T data) toJson,
  }) : _fromJson = fromJson,
       _toJson = toJson;

  @override
  T fromJson(F data) => _fromJson(data);

  @override
  F toJson(T data) => _toJson(data);
}

/// Predefined converter instances for common types
class FirestoreConverters {
  static const dateTime = DateTimeConverter();
  static const duration = DurationConverter();
  static const bytes = BytesConverter();
  static const geoPoint = GeoPointConverter();
  static const documentReference = DocumentReferenceConverter();
}
