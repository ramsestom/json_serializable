// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:source_helper/source_helper.dart';
import 'method_config.dart';

import 'constants.dart';
import 'helper_core.dart';
import 'type_helpers/generic_factory_helper.dart';
import 'type_helpers/json_converter_helper.dart';
import 'unsupported_type_error.dart';

abstract class EncodeHelper implements HelperCore {
  String _fieldAccess(FieldElement field) => '$_toJsonParamName.${field.name}';

  Iterable<String> createToJson(Set<FieldElement> accessibleFields) sync* {
    assert(config.createToJson);

    final buffer = StringBuffer();

    final functionName = '${prefix}ToJson${genericClassArgumentsImpl(true)}'; 
    buffer.write('Map<String, dynamic> $functionName'
        '($targetClassReference $_toJsonParamName');

    if (config.genericArgumentFactories) {
      for (var arg in element.typeParameters) {
        final helperName = toJsonForType(
          arg.instantiate(nullabilitySuffix: NullabilitySuffix.none),
        );
        buffer.write(',Object? Function(${arg.name} value) $helperName');
      }
      if (element.typeParameters.isNotEmpty) {
        buffer.write(',');
      }
    }
    buffer.write(', {bool explicitToJson=${config.explicitToJson}}) ');

    final writeNaive = accessibleFields.every(_writeJsonValueNaive);

    if (writeNaive) {
      // write simple `toJson` method that includes all keys...
      _writeToJsonSimple(buffer, accessibleFields);
    } else {
      // At least one field should be excluded if null
      _writeToJsonWithNullChecks(buffer, accessibleFields);
    }

    yield buffer.toString();
  }

  void _writeToJsonSimple(StringBuffer buffer, Iterable<FieldElement> fields) {
    buffer.writeln('{');
    buffer.writeln('    if (explicitToJson) {');
    buffer.writeln('        final $generatedLocalVarName = <String, dynamic>{');
    buffer.writeAll(fields.map((field) {
      final access = _fieldAccess(field);
      final value = '${safeNameAccess(field)}: ${_serializeField(field, access, true)}';
      return '            $value,\n';
    }));
    buffer.writeln('        };');
    buffer.writeln('        return $generatedLocalVarName;');
    buffer.writeln('    }');
    buffer.writeln('    else {');
    buffer.writeln('        final $generatedLocalVarName = <String, dynamic>{');
    buffer.writeAll(fields.map((field) {
      final access = _fieldAccess(field);
      final value = '${safeNameAccess(field)}: ${_serializeField(field, access, false)}';
      return '            $value,\n';
    }));
    buffer.writeln('        };');
    buffer.writeln('        return $generatedLocalVarName;');
    buffer.writeln('    }');
    buffer.writeln('}');
  }

  static const _toJsonParamName = 'instance';

  void _writeToJsonWithNullChecks(
    StringBuffer buffer,
    Iterable<FieldElement> fields,
  ) {
    buffer
      ..writeln('{')
      ..writeln('    final $generatedLocalVarName = <String, dynamic>{');
    buffer.writeln('    if (explicitToJson) {');
    buffer.writeln('        final $generatedLocalVarName = <String, dynamic>{');

    // Note that the map literal is left open above. As long as target fields
    // don't need to be intercepted by the `only if null` logic, write them
    // to the map literal directly. In theory, should allow more efficient
    // serialization.
    var directWrite = true;

    for (final field in fields) {
      var safeFieldAccess = _fieldAccess(field);
      final safeJsonKeyString = safeNameAccess(field);

      // If `fieldName` collides with one of the local helpers, prefix
      // access with `this.`.
      if (safeFieldAccess == generatedLocalVarName || safeFieldAccess == toJsonMapHelperName) {
        safeFieldAccess = 'this.$safeFieldAccess';
      }

      final expression = _serializeField(field, safeFieldAccess, true);
      if (_writeJsonValueNaive(field)) {
        if (directWrite) {
          buffer.writeln('          $safeJsonKeyString: $expression,');
        } else {
          buffer.writeln('        $generatedLocalVarName[$safeJsonKeyString] = $expression;');
        }
      } else {
        if (directWrite) {
          // close the still-open map literal
          buffer.writeln('        };');
          buffer.writeln();

            // write the helper to be used by all following null-excluding
            // fields
          buffer..writeln('''
              void $toJsonMapHelperName(String key, dynamic value) {
                if (value != null) {
                  $generatedLocalVarName[key] = value;
                }
              }
          ''');
          directWrite = false;
        }
        buffer.writeln('        $toJsonMapHelperName($safeJsonKeyString, $expression);');
      }
    }
    buffer.writeln('        return $generatedLocalVarName;');
    buffer.writeln('    }');
    buffer.writeln('    else {');
    buffer.writeln('        final $generatedLocalVarName = <String, dynamic>{');
    for (final field in fields) {
      var safeFieldAccess = _fieldAccess(field);
      final safeJsonKeyString = safeNameAccess(field);
      if (safeFieldAccess == generatedLocalVarName || safeFieldAccess == toJsonMapHelperName) {
        safeFieldAccess = 'this.$safeFieldAccess';
      }
      final expression = _serializeField(field, safeFieldAccess, false);
      if (_writeJsonValueNaive(field)) {
        if (directWrite) {
          buffer.writeln('          $safeJsonKeyString: $expression,');
        } else {
          buffer.writeln('        $generatedLocalVarName[$safeJsonKeyString] = $expression;');
        }
      } else {
        if (directWrite) {
          buffer.writeln('        };');
          buffer.writeln();
          buffer.writeln('''
        void $toJsonMapHelperName(String key, dynamic value) {
          if (value != null) {
            $generatedLocalVarName[key] = value;
          }
        }
    ''');
          directWrite = false;
        }
        buffer.writeln('        $toJsonMapHelperName($safeJsonKeyString, $expression);');
      }
    }
    buffer.writeln('        return $generatedLocalVarName;');
    buffer.writeln('    }');
    buffer.writeln('  }');
  }

  String _serializeField(FieldElement field, String accessExpression, bool explicitToJson) {
    try {
      return getHelperContext(field, MethodConfig()..explicitToJson=explicitToJson)
          .serialize(field.type, accessExpression)
          .toString();
    } on UnsupportedTypeError catch (e) // ignore: avoid_catching_errors
    {
      throw createInvalidGenerationError('toJson', field, e);
    }
  }

  /// Returns `true` if the field can be written to JSON 'naively' – meaning
  /// we can avoid checking for `null`.
  bool _writeJsonValueNaive(FieldElement field) {
    final jsonKey = jsonKeyFor(field);

    return jsonKey.includeIfNull ||
        (!field.type.isNullableType && !_fieldHasCustomEncoder(field));
  }

  /// Returns `true` if [field] has a user-defined encoder.
  ///
  /// This can be either a `toJson` function in [JsonKey] or a [JsonConverter]
  /// annotation.
  bool _fieldHasCustomEncoder(FieldElement field) {
    final helperContext = getHelperContext(field, null);
    return helperContext.serializeConvertData != null ||
        const JsonConverterHelper()
                .serialize(field.type, 'test', helperContext) !=
            null;
  }
}
