part of 'reader.dart';

/// Reads the Siri polish options: `requiresUnlock`, Shortcuts `summary` /
/// `summaries`, `systemImage` and `@EntityImage()` (see `polish.dart`).
extension _Polish on ModelReader {
  /// The `requiresUnlock` enum of [annotation], or null when unset.
  UnlockModel? _unlock(ConstantReader? annotation) {
    final value = annotation?.peek('requiresUnlock');
    if (value == null || value.isNull) return null;
    return UnlockModel.values[value.objectValue.getField('index')!.toIntValue()!];
  }

  /// An action's checked `summary:`: each `{name}` is one of [params].
  String? _summary(ConstantReader annotation, List<ParamModel> params, Element at) {
    final summary = annotation.peek('summary')?.stringValue;
    if (summary == null) return null;
    if (summaryError(summary, [for (final p in params) p.name], 'summary') case final error?) {
      throw InvalidGenerationSourceError('${at.displayName}: $error', element: at);
    }
    return summary;
  }

  /// An action's checked `summaries:` (`SummaryWhen` / `SummarySwitch`).
  SummaryNode? _conditionalSummary(
    ConstantReader annotation,
    String? flatSummary,
    List<ParamModel> params,
    Element at,
  ) {
    final items = annotation.peek('summaries')?.listValue ?? const <DartObject>[];
    if (items.isEmpty) return null;

    InvalidGenerationSourceError err(String message) =>
        InvalidGenerationSourceError('${at.displayName}: $message', element: at);

    final paramNames = [for (final p in params) p.name];
    void checkTemplate(String template, String what) {
      if (summaryError(template, paramNames, what) case final problem?) {
        throw err(problem);
      }
    }

    SummaryNode? trailing = flatSummary == null ? null : SummaryLeaf(flatSummary);
    var consumedFlat = false;

    for (var i = items.length - 1; i >= 0; i--) {
      final obj = items[i];
      final isLast = i == items.length - 1;
      final r = ConstantReader(obj);
      if (_isFrom(obj.type, 'SummaryWhen', exact: true)) {
        final pName = r.read('param').stringValue;
        final p = params.where((x) => x.name == pName).firstOrNull;
        if (p == null) {
          throw err('summaries names "$pName", which is not a parameter.');
        }
        final compIdx = r.read('comparison').objectValue.getField('index')!.toIntValue()!;
        final comparison = SummaryComparisonModel.values[compIdx];
        final thenStr = r.read('then').stringValue;
        checkTemplate(thenStr, 'SummaryWhen("$pName")');

        final otherwiseStr = r.peek('otherwise')?.stringValue;
        final SummaryNode otherwiseNode;
        if (otherwiseStr != null) {
          if (!isLast) {
            throw err('SummaryWhen("$pName") sets otherwise, so conditions after it in summaries are unreachable.');
          }
          if (flatSummary != null) {
            throw err('set either summary or SummaryWhen.otherwise, not both.');
          }
          checkTemplate(otherwiseStr, 'SummaryWhen("$pName").otherwise');
          otherwiseNode = SummaryLeaf(otherwiseStr);
        } else {
          if (trailing == null) {
            throw err('SummaryWhen("$pName") needs an otherwise summary (set otherwise: or summary: on @AssistantAction).');
          }
          if (isLast && flatSummary != null) consumedFlat = true;
          otherwiseNode = trailing;
        }

        String? swiftVal;
        final rawVal = r.peek('value')?.objectValue;
        if (!comparison.takesValue) {
          if (rawVal != null && !rawVal.isNull) {
            throw err('SummaryWhen("$pName") with ${comparison.name} takes no value.');
          }
        } else {
          if (rawVal == null || rawVal.isNull) {
            throw err('SummaryWhen("$pName") needs a value for ${comparison.name}.');
          }
          final v = p.value;
          if (v == null || v.list) {
            throw err('SummaryWhen("$pName"): ${comparison.name} compares a bool, int, double, String or enum parameter.');
          }
          final ordering = const {
            SummaryComparisonModel.lessThan,
            SummaryComparisonModel.lessThanOrEqualTo,
            SummaryComparisonModel.greaterThan,
            SummaryComparisonModel.greaterThanOrEqualTo,
          }.contains(comparison);
          if (ordering && v.kind != ValueKind.integer && v.kind != ValueKind.decimal) {
            throw err('SummaryWhen("$pName"): ${comparison.name} requires an int or double parameter.');
          }
          swiftVal = switch (v.kind) {
            ValueKind.boolean when rawVal.toBoolValue() != null => '${rawVal.toBoolValue()}',
            ValueKind.integer when rawVal.toIntValue() != null => '${rawVal.toIntValue()}',
            ValueKind.decimal when rawVal.toDoubleValue() != null || rawVal.toIntValue() != null =>
              _Actions._swiftDouble(rawVal.toDoubleValue() ?? rawVal.toIntValue()!.toDouble()),
            ValueKind.string when rawVal.toStringValue() != null =>
              ModelReader._swiftLiteral(rawVal.toStringValue()!),
            ValueKind.enumeration
                when rawVal.type is InterfaceType &&
                    (rawVal.type as InterfaceType).element.displayName == v.dart.replaceAll('?', '') =>
              '.${swiftName(_Actions._schemaCase(_caseName(rawVal)))}',
            _ => throw err('SummaryWhen("$pName"): value does not match parameter type ${v.dart}.'),
          };
        }

        trailing = SummaryWhenModel(
          param: pName,
          comparison: comparison,
          swiftValue: swiftVal,
          then: SummaryLeaf(thenStr),
          otherwise: otherwiseNode,
        );
      } else if (_isFrom(obj.type, 'SummarySwitch', exact: true)) {
        final pName = r.read('param').stringValue;
        if (!isLast) {
          throw err('SummarySwitch("$pName") must be the last condition in summaries.');
        }
        final p = params.where((x) => x.name == pName).firstOrNull;
        if (p == null) {
          throw err('summaries names "$pName", which is not a parameter.');
        }
        final v = p.value;
        if (v == null || v.kind != ValueKind.enumeration || v.list) {
          throw err('SummarySwitch("$pName") requires an enum parameter.');
        }
        final rawCases = r.read('cases').mapValue;
        if (rawCases.isEmpty) {
          throw err('SummarySwitch("$pName") needs at least one case.');
        }
        final expectedEnum = v.dart.replaceAll('?', '');
        final parsedCases = <String, String>{};
        for (final MapEntry(:key, :value) in rawCases.entries) {
          if (key == null ||
              key.type is! InterfaceType ||
              (key.type as InterfaceType).element.displayName != expectedEnum) {
            throw err('SummarySwitch("$pName") case must be a $expectedEnum value.');
          }
          final swiftCase = swiftName(_Actions._schemaCase(_caseName(key)));
          final tmpl = value!.toStringValue()!;
          checkTemplate(tmpl, 'SummarySwitch("$pName.$swiftCase")');
          parsedCases[swiftCase] = tmpl;
        }
        final explicitDef = r.peek('defaultSummary')?.stringValue;
        if (explicitDef != null && flatSummary != null) {
          throw err('set either summary or SummarySwitch.defaultSummary, not both.');
        }
        final defStr = explicitDef ?? flatSummary;
        if (explicitDef == null && flatSummary != null) consumedFlat = true;
        if (defStr != null) {
          checkTemplate(defStr, 'SummarySwitch("$pName").defaultSummary');
        } else {
          final totalCases = _appEnums[expectedEnum]?.cases.length ??
              (v.enumRef != null
                  ? (_openEnums[v.enumRef]?.cases.length ??
                      _catalogs[v.enumRef!.split('.').first]?.enums[v.enumRef]?.cases.length ??
                      0)
                  : 0);
          if (parsedCases.length < totalCases) {
            throw err('SummarySwitch("$pName") omits cases of $expectedEnum; set defaultSummary (or cover every case).');
          }
        }
        trailing = SummarySwitchModel(param: pName, cases: parsedCases, defaultSummary: defStr);
      } else {
        throw err('Unsupported SummaryCondition in summaries.');
      }
    }

    if (flatSummary != null && !consumedFlat) {
      throw err('set either summary or summaries, not both.');
    }
    return trailing;
  }

  /// A checked `systemImage:` of [annotation], if set.
  String? _systemImage(ConstantReader? annotation, Element at) {
    final name = annotation?.peek('systemImage')?.stringValue;
    if (name == null) return null;
    if (systemImageError(name) case final error?) {
      throw InvalidGenerationSourceError('${at.displayName}: $error', element: at);
    }
    return name;
  }

  /// The `@EntityImage()` field or getter of [cls]: a `String` or `Uri`,
  /// nullable or not.
  FieldModel? _imageField(ClassElement cls) {
    final marked = [
      for (final f in cls.fields)
        if (!f.isStatic && f.isOriginDeclaration && _annotation(f, 'EntityImage') != null) (f as Element, f.type),
      for (final g in cls.getters)
        if (!g.isStatic && g.isOriginDeclaration && _annotation(g, 'EntityImage') != null) (g as Element, g.returnType),
    ];
    if (marked.isEmpty) return null;
    if (marked.length > 1) {
      throw InvalidGenerationSourceError(
          '${cls.displayName} has ${marked.length} @EntityImage() members '
          '(${marked.map((m) => m.$1.displayName).join(', ')}); an item has one image.',
          element: marked[1].$1);
    }
    final (member, type) = marked.single;
    final value = _valueType(type);
    if (value == null || (value.kind != ValueKind.string && value.kind != ValueKind.uri)) {
      throw InvalidGenerationSourceError(
          '${cls.displayName}.${member.displayName} is ${type.getDisplayString()}, but an @EntityImage() is a '
          'String or Uri: an absolute file path, a file: URL or an https: URL.',
          element: member);
    }
    return FieldModel(member.displayName, value);
  }

  /// A schema annotation's checked `summaries:`, by intent name.
  Map<String, String> _summaries(
      ConstantReader annotation, List<(IntentSchema, IntentKind)> intents, String name, Element element) {
    final summaries = {
      for (final MapEntry(:key, :value) in annotation.peek('summaries')?.mapValue.entries ?? const <Never, Never>{}.entries)
        key!.toStringValue()!: value!.toStringValue()!,
    };
    if (checkSummaries(summaries, intents, name) case final problem?) {
      throw InvalidGenerationSourceError(problem, element: element);
    }
    return summaries;
  }
}
