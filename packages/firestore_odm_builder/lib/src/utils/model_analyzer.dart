import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:firestore_odm_annotation/firestore_odm_annotation.dart';
import 'package:source_gen/source_gen.dart';
import 'package:json_annotation/json_annotation.dart';

class FieldInfo {
  final String parameterName;
  final String jsonName;
  final DartType type;
  final Element element;
  final bool isDocumentId;
  // final TypeConverter converter;
  final bool isNullable;

  const FieldInfo({
    required this.parameterName,
    required this.jsonName,
    required this.type,
    required this.element,
    required this.isDocumentId,
    // required this.converter,
    required this.isNullable,
  });
}

/// Analyzer for complete model structure including JSON field mapping
class ModelAnalyzer {
  // Add public constructor for creating fresh instances
  ModelAnalyzer();

  final Map<InterfaceType, Map<String, FieldInfo>> _cachedFields = {};

  ConstructorElement? getDefaultConstructor(InterfaceType type) {
    final constructor = type.constructors
        .where((c) => c.name.isEmpty)
        .firstOrNull;

    return constructor;
  }

  String getDocumentIdFieldName(InterfaceType type) {
    final constructor = getDefaultConstructor(type);

    if (constructor == null) {
      throw ArgumentError(
        'No default constructor found in ${type.getDisplayString(withNullability: false)}',
      );
    }

    final params = constructor.parameters.where(
      (p) =>
          TypeChecker.fromRuntime(DocumentIdField).annotationsOf(p).isNotEmpty,
    );

    if (params.length > 1) {
      throw ArgumentError(
        'Multiple document ID fields found in ${type.getDisplayString(withNullability: false)}',
      );
    }

    final documentIdParam = params.length == 1
        ? params.single
        : constructor.parameters.where((p) => p.name == 'id').firstOrNull;

    // Check type
    if (documentIdParam != null && !documentIdParam.type.isDartCoreString) {
      throw ArgumentError(
        'Document ID field must be a String in ${type.getDisplayString(withNullability: false)}',
      );
    }

    return documentIdParam?.name ?? 'id';
  }

  Map<String, FieldInfo> getFields(InterfaceType type) {
    return _cachedFields.putIfAbsent(type, () => _getFields(type));
  }

  Map<String, FieldInfo> _getFields(InterfaceType type) {
    final constructor = getDefaultConstructor(type);

    if (constructor == null) {
      return {};
    }

    final documentIdParamName = getDocumentIdFieldName(type);

    // Second pass: analyze all parameters
    final fields = Map<String, FieldInfo>();

    // Simplified field analysis
    for (final parameter in constructor.parameters) {
      if (parameter.isStatic) continue;

      var jsonName = parameter.name;
      // check JsonKey annotation for custom names
      if (parameter.metadata.isNotEmpty) {
        final jsonKey = TypeChecker.fromRuntime(
          JsonKey,
        ).annotationsOf(parameter).firstOrNull;
        if (jsonKey != null) {
          final reader = ConstantReader(jsonKey);

          jsonName =
              reader.read('name').literalValue as String? ?? parameter.name;

          final includeFromJson =
              reader.read('includeFromJson').literalValue as bool? ?? true;
          final includeToJson =
              reader.read('includeToJson').literalValue as bool? ?? true;
          if (!includeFromJson || !includeToJson) {
            continue;
          }
        }
      }

      fields[parameter.name] = FieldInfo(
        parameterName: parameter.name,
        jsonName: jsonName,
        type: parameter.type,
        element: parameter,
        isDocumentId: parameter.name == documentIdParamName,
        isNullable:
            parameter.type.nullabilitySuffix == NullabilitySuffix.question,
      );
    }

    return fields;
  }
}

bool isHandledType(DartType type) {
  // Check if the type is a known Firestore ODM type
  return isPrimitive(type) ||
      TypeChecker.fromRuntime(DateTime).isExactlyType(type) ||
      TypeChecker.fromRuntime(Duration).isExactlyType(type);
}

bool isUserType(DartType type) {
  // Check if the type is a user-defined model type
  return !isHandledType(type);
}

bool isPrimitive(DartType type) {
  return type.isDartCoreBool ||
      type.isDartCoreInt ||
      type.isDartCoreDouble ||
      type.isDartCoreString ||
      type.isDartCoreNull ||
      type.name == 'dynamic';
}
