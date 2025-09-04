import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:code_builder/code_builder.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:firestore_odm_annotation/firestore_odm_annotation.dart';
import 'package:firestore_odm_builder/src/utils/reference_utils.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:source_gen/source_gen.dart';

class CustomConverter {
  final InterfaceType type;
  final DartType jsonType;

  Expression get toJson => type.reference.constInstance([]).property('toJson');

  Expression get fromJson =>
      type.reference.constInstance([]).property('fromJson');

  CustomConverter({required this.type, required this.jsonType});
}

class FieldInfo {
  final String parameterName;
  final String jsonName;
  final DartType type;
  final Element element;
  final bool isDocumentId;
  final CustomConverter? customConverter;
  final bool isNullable;

  const FieldInfo({
    required this.parameterName,
    required this.jsonName,
    required this.type,
    required this.element,
    required this.isDocumentId,
    required this.customConverter,
    required this.isNullable,
  });
}

bool isHandledType(DartType type) {
  // Check if the type is a known Firestore ODM type
  return isPrimitive(type) ||
      TypeChecker.fromRuntime(Iterable).isAssignableFromType(type) ||
      TypeChecker.fromRuntime(Map).isAssignableFromType(type) ||
      TypeChecker.fromRuntime(IMap).isAssignableFromType(type) ||
      TypeChecker.fromRuntime(DateTime).isExactlyType(type) ||
      TypeChecker.fromRuntime(Duration).isExactlyType(type) ||
      // Treat enums as handled (serialized via name or @JsonValue)
      (type is InterfaceType && type.element is EnumElement);
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

Map<String, FieldInfo> getFields(InterfaceType type) {
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
    final customConverter =
        TypeChecker.fromRuntime(
              JsonConverter,
            ).annotationsOf(parameter).firstOrNull?.type
            as InterfaceType?;

    fields[parameter.name] = FieldInfo(
      parameterName: parameter.name,
      jsonName: jsonName,
      type: parameter.type,
      element: parameter,
      customConverter: customConverter != null
          ? CustomConverter(
              type: customConverter,
              jsonType: customConverter
                  .lookUpMethod3('toJson', customConverter.element3.library2)!
                  .returnType,
            )
          : null,
      isDocumentId: parameter.name == documentIdParamName,
      isNullable:
          parameter.type.nullabilitySuffix == NullabilitySuffix.question,
    );
  }

  return fields;
}

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

  final params = constructor.parameters.where((p) {
    return TypeChecker.fromRuntime(DocumentIdField).annotationsOf(p).isNotEmpty;
  });

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

TypeReference getJsonType({required DartType type}) {
  if (isPrimitive(type)) {
    return type.reference;
  }

  // Enum -> underlying JSON primitive type (String by default, or @JsonValue type)
  final el = (type is InterfaceType) ? type.element : null;
  if (el is EnumElement) {
    // Inspect @JsonValue types across constants
    final constants = el.fields.where((f) => f.isEnumConstant).toList();
    var allString = true;
    var allInt = true;

    for (final c in constants) {
      final ann = TypeChecker.fromRuntime(
        JsonValue,
      ).annotationsOf(c).firstOrNull;
      if (ann == null) {
        // default = name -> String
        continue;
      }
      final reader = ConstantReader(ann);
      final raw = reader.read('value').literalValue;
      if (raw is String) {
        // ok
      } else if (raw is int) {
        allString = false;
      } else if (raw is double || raw is bool) {
        allString = false;
        allInt = false;
      } else {
        allString = false;
        allInt = false;
      }
    }

    final base = allString
        ? TypeReferences.string
        : allInt
        ? TypeReferences.int
        : TypeReferences.dynamic;
    return base.withNullability(type.isNullable);
  }

  if (TypeChecker.fromRuntime(DateTime).isAssignableFromType(type)) {
    return TypeReferences.string.withNullability(type.isNullable);
  }

  if (TypeChecker.fromRuntime(Duration).isAssignableFromType(type)) {
    return TypeReferences.int.withNullability(type.isNullable);
  }

  if (TypeChecker.fromRuntime(Iterable).isAssignableFromType(type)) {
    return TypeReferences.listOf(
      getJsonType(type: type.typeArguments.first),
    ).withNullability(type.isNullable);
  }

  if (TypeChecker.fromRuntime(Map).isAssignableFromType(type) ||
      TypeChecker.fromRuntime(IMap).isAssignableFromType(type)) {
    return TypeReferences.mapOf(
      TypeReferences.string,
      getJsonType(type: type.typeArguments.last),
    ).withNullability(type.isNullable);
  }

  if (type is InterfaceType) {
    return TypeReferences.mapOf(
      TypeReferences.string,
      TypeReferences.dynamic,
    ).withNullability(type.isNullable);
  }

  return TypeReferences.dynamic;
}
