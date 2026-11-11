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
