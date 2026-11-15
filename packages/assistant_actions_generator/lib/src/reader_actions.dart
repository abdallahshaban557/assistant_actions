part of 'reader.dart';

/// The App Shortcuts an app can have (Apple's limit).
const _maxShortcuts = 10;

/// Reads plain `@AssistantAction` functions, `@AssistantEnum` enums and App
/// Shortcuts.
extension _Actions on ModelReader {
  // ── App enums ─────────────────────────────────────────────────────────

  void _readAppEnums(List<LibraryElement> libraries) {
    for (final lib in libraries) {
      for (final e in lib.enums) {
        final annotation = _annotation(e, 'AssistantEnum');
        if (annotation == null) continue;
        if (_openEnums.values.any((o) => o.className == e.displayName)) {
          throw InvalidGenerationSourceError(
              '${e.displayName} gives a schema enum\'s cases, so it can\'t also be an @AssistantEnum: '
              'actions can take it as it is.',
              element: e);
        }
        final cases = <AppEnumCase>[];
        for (final c in e.fields) {
          if (!c.isEnumConstant) continue;
          final name = c.displayName;
          if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) {
            throw InvalidGenerationSourceError('${e.displayName}.$name: Swift case names can\'t contain \$.',
                element: c);
          }
          final title = _annotation(c, 'CaseTitle');
          cases.add(AppEnumCase(
            name: name,
            title: title?.read('title').stringValue ?? ModelReader._titleCase(name),
            synonyms: [for (final s in title?.read('synonyms').listValue ?? const []) s.toStringValue()!],
            systemImage: _systemImage(title, c),
          ));
        }
        if (cases.isEmpty) {
          throw InvalidGenerationSourceError('@AssistantEnum ${e.displayName} has no cases.', element: e);
        }
        _appEnums[e.displayName] = AppEnumModel(
          className: e.displayName,
          library: e.library.uri,
          title: annotation.read('title').stringValue,
          cases: cases,
        );
      }
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────

  Future<ActionModel> _action(TopLevelFunctionElement fn, ConstantReader annotation, List<EntityModel> entities,
      List<SchemaEntityModel> schemaEntities) async {
    final rawParams = [
      for (final p in fn.formalParameters) await _param(fn, p, entities, schemaEntities),
    ];
    final params = _resolveOptionsDependencies(fn, rawParams);
    final runs = RunsModel.values[annotation.read('runs').objectValue.getField('index')!.toIntValue()!];
    final dialog = annotation.peek('dialog')?.stringValue;
    final confirm = annotation.peek('confirm')?.stringValue;
    for (final (field, template) in [('dialog', dialog), ('confirm', confirm)]) {
      if (template == null) continue;
      for (final match in RegExp(r'\{(\w+)\}').allMatches(template)) {
        final p = params.where((p) => p.name == match.group(1)).firstOrNull;
        if (p == null) {
          throw InvalidGenerationSourceError('$field uses {${match.group(1)}}, which is not a parameter.',
              element: fn);
        }
        if (!_speakable(p)) {
          throw InvalidGenerationSourceError(
              '$field uses {${p.name}}, but Siri can\'t say a ${p.value?.dart ?? 'list of items'}: '
              'leave it out${field == 'dialog' ? ', or return the dialog from the function' : ''}.',
              element: fn);
        }
      }
    }
    final discoverable = annotation.read('isDiscoverable').boolValue;
    final shortcut = _shortcut(annotation.peek('shortcut'), fn, {
      for (final p in params)
        if ((p.isEntity && !p.entityList) || (p.value?.kind == ValueKind.enumeration && !p.value!.list)) p.name,
    });
    if (shortcut != null && !discoverable) {
      throw InvalidGenerationSourceError(
          '${fn.displayName} has isDiscoverable: false, so it can\'t be an App Shortcut.', element: fn);
    }

    var type = fn.returnType;
    if (type.isDartAsyncFuture || type.isDartAsyncFutureOr) {
      type = (type as InterfaceType).typeArguments.single;
    }
    final returnsString = type.isDartCoreString;
    // `AssistantReply<T>`: a dialog and a card, plus a value [T] for Shortcuts
    // unless it's `void`.
    final returnsReply = _isFrom(type, 'AssistantReply', exact: true);
    final liveActivity = annotation.peek('liveActivity')?.boolValue ?? false;
    ResultModel? result;
    if (returnsReply) {
      final value = (type as InterfaceType).typeArguments.single;
      if (value is! VoidType && !value.isDartCoreNull && value is! DynamicType) {
        result = await _result(fn, value, entities, schemaEntities, reply: true);
      }
    } else if (!returnsString && type is! VoidType && !type.isDartCoreNull) {
      result = await _result(fn, type, entities, schemaEntities);
    }
    if (runs == RunsModel.deferred && returnsReply) {
      throw InvalidGenerationSourceError(
          '${fn.displayName} returns an AssistantReply, but it runs deferred: Siri answers before it runs. '
          'Use runs: Runs.withFlutter, or return void and set dialog.',
          element: fn);
    }
    if (runs == RunsModel.deferred && result != null) {
      throw InvalidGenerationSourceError(
          '${fn.displayName} returns ${type.getDisplayString()}, but runs deferred, after Siri has answered. '
          'Use runs: Runs.withFlutter to return a value to Shortcuts.',
          element: fn);
    }
    if (liveActivity && result != null) {
      throw InvalidGenerationSourceError(
          '${fn.displayName} has liveActivity: true, so it can\'t return a value to Shortcuts: a Live Activity '
          'intent may run in the background without Siri. Return void, a String or AssistantReply<void>.',
          element: fn);
    }
    if (runs == RunsModel.deferred && returnsString) {
      log.warning('${fn.displayName} runs deferred, so Siri says its dialog, not the String it returns.');
    }
    final opensApp = annotation.peek('opensApp')?.boolValue ?? false;
    if (opensApp && runs != RunsModel.withFlutter) {
      throw InvalidGenerationSourceError(
          '${fn.displayName}: opensApp needs runs: Runs.withFlutter; a deferred action runs later, not in the app.',
          element: fn);
    }
    if (opensApp && liveActivity) {
      throw InvalidGenerationSourceError(
          '${fn.displayName}: liveActivity and opensApp don\'t go together: a Live Activity intent runs without '
          'opening the app.',
          element: fn);
    }
    final longRunning = annotation.peek('longRunning')?.boolValue ?? false;
    if (longRunning && runs != RunsModel.withFlutter && !liveActivity) {
      throw InvalidGenerationSourceError(
          '${fn.displayName}: longRunning needs runs: Runs.withFlutter (deferred actions return at once).',
          element: fn);
    }
    final cardButtons = annotation.peek('cardButtons')?.boolValue ?? false;
    if (cardButtons && !returnsReply) {
      throw InvalidGenerationSourceError(
          '${fn.displayName}: cardButtons needs a Runs.withFlutter function that returns an AssistantReply '
          '(its card has the buttons).',
          element: fn);
    }
    final flatSummary = _summary(annotation, params, fn);
    final conditionalSummary = _conditionalSummary(annotation, flatSummary, params, fn);
    return ActionModel(
      functionName: fn.displayName,
      library: fn.library.uri,
      title: annotation.read('title').stringValue,
      description: annotation.peek('description')?.stringValue,
      runs: runs,
      dialog: dialog,
      confirm: confirm,
      shortcut: shortcut,
      params: params,
      returnsString: returnsString,
      returnsReply: returnsReply,
      liveActivity: liveActivity,
      result: result,
      searchKeywords: _strings(annotation, 'searchKeywords'),
      isDiscoverable: discoverable,
      opensApp: opensApp,
      longRunning: longRunning,
      unlock: _unlock(annotation),
      summary: conditionalSummary == null ? flatSummary : null,
      conditionalSummary: conditionalSummary,
      cardButtons: cardButtons,
    );
  }

  /// Parameters a dialog can say.
  static bool _speakable(ParamModel p) {
    if (p.isEntity) return true;
    final v = p.value!;
    if (v.list) return v.kind == ValueKind.string;
    return !const {ValueKind.person, ValueKind.place, ValueKind.file}.contains(v.kind);
  }

  List<String> _strings(ConstantReader annotation, String field) =>
      [for (final s in annotation.peek(field)?.listValue ?? const <DartObject>[]) s.toStringValue()!];

  /// What an action returning [type] (a `Future`'s value) gives Shortcuts.
  /// [reply]: [type] is the `T` of an `AssistantReply<T>`.
  Future<ResultModel> _result(TopLevelFunctionElement fn, DartType type, List<EntityModel> entities,
      List<SchemaEntityModel> schemaEntities, {bool reply = false}) async {
    InvalidGenerationSourceError error() => InvalidGenerationSourceError(
        '${fn.displayName} returns ${type.getDisplayString()}. An @AssistantAction returns void, a String '
        '(what Siri says), an AssistantReply, or a value for Shortcuts, optionally as ActionResult<T> or '
        'AssistantReply<T>: a String, int, double, '
        'bool, DateTime, Uri, Duration, @AssistantEnum or schema enum, AssistantPerson, AssistantFile, '
        '@AssistantEntity or schema entity class, or a List of one of these.',
        element: fn);
    var t = type;
    var wrapped = reply;
    if (!reply && t is InterfaceType && _isFrom(t, 'ActionResult', exact: true)) {
      if (t.nullabilitySuffix == NullabilitySuffix.question) {
        throw InvalidGenerationSourceError(
            '${fn.displayName} returns ${type.getDisplayString()}: return an ActionResult, not null.', element: fn);
      }
      wrapped = true;
      t = t.typeArguments.single;
    }
    final nullable = t.nullabilitySuffix == NullabilitySuffix.question;
    var list = false;
    var element = t;
    if (t is InterfaceType && t.isDartCoreList) {
      list = true;
      element = t.typeArguments.single;
    }
    if (element is InterfaceType) {
      final name = element.element.displayName;
      final entity = entities.where((e) => e.className == name).firstOrNull;
      final schemaEntity = schemaEntities.where((e) => e.className == name).firstOrNull;
      if (entity != null || schemaEntity != null) {
        if (list && element.nullabilitySuffix == NullabilitySuffix.question) throw error();
        return ResultModel(
            entity: entity, schemaEntity: schemaEntity, list: list, nullable: nullable, wrapped: wrapped);
      }
    }
    final value = await _actionValue(t, fn);
    if (value == null) throw error();
    return ResultModel(value: value, nullable: nullable, wrapped: wrapped);
  }

  Future<ParamModel> _param(
    TopLevelFunctionElement fn,
    FormalParameterElement p,
    List<EntityModel> entities,
    List<SchemaEntityModel> schemaEntities,
  ) async {
    final meta = _annotation(p, 'Param');
    final name = p.displayName;
    final title = meta?.peek('title')?.stringValue ?? ModelReader._titleCase(name);
    final prompt = meta?.peek('prompt')?.stringValue;

    InvalidGenerationSourceError paramError(String message) =>
        InvalidGenerationSourceError('${fn.displayName} parameter $name: $message', element: fn);

    final minObj = meta?.peek('min')?.objectValue;
    final maxObj = meta?.peek('max')?.objectValue;
    final num? min = minObj == null || minObj.isNull ? null : (minObj.toIntValue() ?? minObj.toDoubleValue());
    final num? max = maxObj == null || maxObj.isNull ? null : (maxObj.toIntValue() ?? maxObj.toDoubleValue());
    final csObj = meta?.peek('controlStyle');
    final controlStyle = csObj == null || csObj.isNull
        ? null
        : ControlStyleModel.values[csObj.objectValue.getField('index')!.toIntValue()!];
    final multiline = meta?.peek('multiline')?.boolValue ?? false;
    final capObj = meta?.peek('capitalization');
    final capitalization = capObj == null || capObj.isNull
        ? null
        : CapitalizationModel.values[capObj.objectValue.getField('index')!.toIntValue()!];
    final kbObj = meta?.peek('keyboardType');
    final keyboardType = kbObj == null || kbObj.isNull
        ? null
        : KeyboardTypeModel.values[kbObj.objectValue.getField('index')!.toIntValue()!];
    final contentTypesReader = meta?.peek('supportedContentTypes');
    final supportedContentTypes = contentTypesReader == null || contentTypesReader.isNull
        ? null
        : [for (final s in contentTypesReader.listValue) s.toStringValue()!];
    final optionsObj = meta?.peek('options')?.objectValue;
    final optionsExec = optionsObj == null || optionsObj.isNull ? null : optionsObj.toFunctionValue();
    final snapshotFieldRaw = meta?.peek('snapshotField')?.stringValue;
    if (snapshotFieldRaw != null && optionsExec == null) {
      throw paramError('snapshotField requires options: to be set.');
    }

    final type = p.type;
    final nullable = type.nullabilitySuffix == NullabilitySuffix.question;
    final listed = type is InterfaceType && type.isDartCoreList ? type.typeArguments.single : null;
    final target = listed ?? type;
    if (target is InterfaceType) {
      final entity = entities.where((e) => e.className == target.element.displayName).firstOrNull;
      final schemaEntity = schemaEntities.where((s) => s.className == target.element.displayName).firstOrNull;
      if (entity != null || schemaEntity != null) {
        final className = entity?.className ?? schemaEntity!.className;
        if (listed != null && listed.nullabilitySuffix == NullabilitySuffix.question) {
          throw InvalidGenerationSourceError(
              'Parameter $name: use List<$className>, not ${type.getDisplayString()}.', element: fn);
        }
        String? swiftDefault;
        String? dartDefault;
        if (p.hasDefaultValue) {
          final defVal = p.computeConstantValue();
          if (listed != null && (defVal?.toListValue()?.isEmpty ?? false)) {
            swiftDefault = '[]';
            dartDefault = 'const <$className>[]';
          } else if (!(defVal?.isNull ?? true)) {
            throw InvalidGenerationSourceError('Parameter $name: entity parameters can\'t have a default.',
                element: fn);
          }
        }
        if (min != null || max != null || controlStyle != null) {
          throw paramError('min, max and controlStyle are only supported on int and double parameters.');
        }
        if (multiline || capitalization != null || keyboardType != null) {
          throw paramError('multiline, capitalization and keyboardType are only supported on String parameters.');
        }
        if (supportedContentTypes != null) {
          throw paramError('supportedContentTypes is only supported on AssistantFile parameters.');
        }
        final options = optionsExec == null
            ? null
            : _readEntityOptions(
                fn,
                name,
                optionsExec,
                className: className,
                fields: entity?.fields ?? schemaEntity!.fields,
                snapshotFieldRaw: snapshotFieldRaw,
              );
        return ParamModel(
          name: name,
          title: title,
          prompt: prompt,
          named: p.isNamed,
          entity: entity,
          schemaEntity: schemaEntity,
          entityNullable: nullable,
          entityList: listed != null,
          swiftDefault: swiftDefault,
          defaultDart: dartDefault,
          options: options,
        );
      }
    }
    final value = await _actionValue(type, fn);
    if (value == null) {
      throw InvalidGenerationSourceError(
          'Parameter $name: ${type.getDisplayString()} is not supported. Use String, int, double, bool, '
          'DateTime, Uri, Duration, an @AssistantEnum or schema enum, AssistantPerson, AssistantPlace, '
          'AssistantFile, AssistantCurrency, AssistantLength/Mass/Temperature/Volume/Speed/Energy, '
          'an @AssistantEntity or schema entity class, or a List of one of these.',
          element: fn);
    }

    // Validate numeric constraints.
    if (min != null || max != null || controlStyle != null) {
      if (value.list || (value.kind != ValueKind.integer && value.kind != ValueKind.decimal)) {
        throw paramError('min, max and controlStyle are only supported on int and double parameters.');
      }
      if ((min == null) != (max == null)) {
        throw paramError('set both min and max for an inclusiveRange.');
      }
      if (value.kind == ValueKind.integer && ((min != null && min is! int) || (max != null && max is! int))) {
        throw paramError('int parameter bounds min and max must be integers.');
      }
      if (min != null && max != null && min > max) {
        throw paramError('min ($min) must be <= max ($max).');
      }
      if (controlStyle == ControlStyleModel.slider && value.kind == ValueKind.integer) {
        throw paramError(
            'ParamControlStyle.slider is only supported on double parameters in App Intents (use stepper or field for int).');
      }
    }

    // Validate String input options.
    if (multiline || capitalization != null || keyboardType != null) {
      if (value.list || value.kind != ValueKind.string) {
        throw paramError('multiline, capitalization and keyboardType are only supported on String parameters.');
      }
    }

    // Validate file UTType constraints.
    if (supportedContentTypes != null) {
      if (value.kind != ValueKind.file) {
        throw paramError('supportedContentTypes is only supported on AssistantFile and List<AssistantFile> parameters.');
      }
      if (supportedContentTypes.isEmpty || supportedContentTypes.any((t) => t.trim().isEmpty)) {
        throw paramError('supportedContentTypes must list at least one non-empty UTType identifier.');
      }
    }

    final (swiftDefault, dartDefault) = _defaults(fn, p, value);
    if (min != null && max != null && p.hasDefaultValue) {
      final defVal = p.computeConstantValue();
      final defNum = defVal?.toIntValue() ?? defVal?.toDoubleValue();
      if (defNum != null && (defNum < min || defNum > max)) {
        throw paramError('default ($defNum) is outside [$min, $max].');
      }
    }

    final options = optionsExec == null
        ? null
        : _readValueOptions(
            fn,
            name,
            optionsExec,
            value: value,
            entities: entities,
            schemaEntities: schemaEntities,
            snapshotFieldRaw: snapshotFieldRaw,
          );

    return ParamModel(
      name: name,
      title: title,
      prompt: prompt,
      named: p.isNamed,
      value: value,
      swiftDefault: swiftDefault,
      defaultDart: dartDefault,
      min: min,
      max: max,
      controlStyle: controlStyle,
      multiline: multiline,
      capitalization: capitalization,
      keyboardType: keyboardType,
      supportedContentTypes: supportedContentTypes,
      options: options,
    );
  }

  ParamOptionsModel _readEntityOptions(
    TopLevelFunctionElement actionFn,
    String paramName,
    ExecutableElement exec, {
    required String className,
    required List<FieldModel> fields,
    required String? snapshotFieldRaw,
  }) {
    InvalidGenerationSourceError err(String message) =>
        InvalidGenerationSourceError('${actionFn.displayName} parameter $paramName: $message', element: actionFn);

    if (exec is! TopLevelFunctionElement) {
      throw err('options must be a top-level function.');
    }
    final elem = _optionsElementType(exec.returnType) ?? (throw err('options ${exec.displayName} must return List<$className> or Future<List<$className>>.'));
    if (elem is! InterfaceType ||
        elem.element.displayName != className ||
        elem.nullabilitySuffix == NullabilitySuffix.question) {
      throw err('options ${exec.displayName} must return List<$className> (not ${exec.returnType.getDisplayString()}).');
    }
    String? filterField;
    if (snapshotFieldRaw != null) {
      final parts = snapshotFieldRaw.split('.');
      final fieldName = parts.length == 2 && parts.first == className
          ? parts[1]
          : (parts.length == 1 ? parts.first : null);
      final field = fieldName == null ? null : fields.where((f) => f.name == fieldName).firstOrNull;
      if (field == null || field.type.kind != ValueKind.boolean) {
        throw err('snapshotField "$snapshotFieldRaw" on an entity parameter must name a published bool field of $className.');
      }
      filterField = field.name;
    }
    return ParamOptionsModel(
      functionName: exec.displayName,
      library: exec.library.uri,
      snapshotCollection: className,
      snapshotField: filterField,
    );
  }

  ParamOptionsModel _readValueOptions(
    TopLevelFunctionElement actionFn,
    String paramName,
    ExecutableElement exec, {
    required ValueType value,
    required List<EntityModel> entities,
    required List<SchemaEntityModel> schemaEntities,
    required String? snapshotFieldRaw,
  }) {
    InvalidGenerationSourceError err(String message) =>
        InvalidGenerationSourceError('${actionFn.displayName} parameter $paramName: $message', element: actionFn);

    if (exec is! TopLevelFunctionElement) {
      throw err('options must be a top-level function.');
    }
    final elemKind = value.element.kind;
    if (elemKind != ValueKind.string && elemKind != ValueKind.integer && elemKind != ValueKind.decimal) {
      throw err('options is supported on String, int, double, @AssistantEntity and schema entity parameters.');
    }
    final expectedDart = value.element.dart;
    final retElem = _optionsElementType(exec.returnType) ??
        (throw err('options ${exec.displayName} must return List<$expectedDart> or Future<List<$expectedDart>>.'));
    final matches = retElem.nullabilitySuffix != NullabilitySuffix.question &&
        switch (elemKind) {
          ValueKind.string => retElem.isDartCoreString,
          ValueKind.integer => retElem.isDartCoreInt,
          ValueKind.decimal => retElem.isDartCoreDouble,
          _ => false,
        };
    if (!matches) {
      throw err('options ${exec.displayName} must return List<$expectedDart> (not ${exec.returnType.getDisplayString()}).');
    }

    String? snapCollection;
    String? snapField;
    if (snapshotFieldRaw != null) {
      final parts = snapshotFieldRaw.split('.');
      if (parts.length != 2) {
        throw err('snapshotField "$snapshotFieldRaw" must be "Collection.field" (such as "Recipe.category").');
      }
      final colName = parts[0];
      final fldName = parts[1];
      final ent = entities.where((e) => e.className == colName).firstOrNull;
      final sch = schemaEntities.where((s) => s.className == colName).firstOrNull;
      if (ent == null && sch == null) {
        throw err('snapshotField "$snapshotFieldRaw" names "$colName", which is not an entity class.');
      }
      final fields = ent?.fields ?? sch!.fields;
      if (fldName == 'title') {
        if (elemKind != ValueKind.string) {
          throw err('snapshotField "$snapshotFieldRaw": title is a String, not $expectedDart.');
        }
      } else {
        final f = fields.where((x) => x.name == fldName).firstOrNull;
        if (f == null || f.type.list || f.type.kind != elemKind) {
          throw err('snapshotField "$snapshotFieldRaw" must name a published $expectedDart field of $colName.');
        }
      }
      snapCollection = colName;
      snapField = fldName;
    }

    return ParamOptionsModel(
      functionName: exec.displayName,
      library: exec.library.uri,
      snapshotCollection: snapCollection,
      snapshotField: snapField,
    );
  }

  static DartType? _optionsElementType(DartType returnType) {
    var t = returnType;
    if (t.isDartAsyncFuture || t.isDartAsyncFutureOr) {
      t = (t as InterfaceType).typeArguments.single;
    }
    if (t.nullabilitySuffix == NullabilitySuffix.question) return null;
    if (t is InterfaceType && (t.isDartCoreList || t.isDartCoreIterable)) {
      return t.typeArguments.single;
    }
    return null;
  }

  /// Resolves `@IntentParameterDependency` parameters for any `options:`
  /// functions on [fn], checking names, types and circular dependencies.
  List<ParamModel> _resolveOptionsDependencies(TopLevelFunctionElement fn, List<ParamModel> params) {
    if (params.every((p) => p.options == null)) return params;
    final byName = {for (final p in params) p.name: p};
    final resolved = <ParamModel>[];
    final edges = <String, List<String>>{};

    for (var i = 0; i < params.length; i++) {
      final p = params[i];
      if (p.options == null) {
        resolved.add(p);
        continue;
      }
      final formal = fn.formalParameters[i];
      final exec = _annotation(formal, 'Param')!.peek('options')!.objectValue.toFunctionValue()! as TopLevelFunctionElement;
      final deps = <OptionsDependency>[];
      for (final dep in exec.formalParameters) {
        final depName = dep.displayName;
        if (depName == p.name) {
          throw InvalidGenerationSourceError(
              '${fn.displayName}: options ${exec.displayName} for parameter $depName cannot depend on itself.',
              element: fn);
        }
        final other = byName[depName];
        if (other == null) {
          throw InvalidGenerationSourceError(
              '${fn.displayName}: options ${exec.displayName} takes "$depName", which is not another parameter of ${fn.displayName}.',
              element: fn);
        }
        final expectedBase = other.isEntity
            ? (other.entityList ? 'List<${other.entityClassName}>' : other.entityClassName)
            : other.value!.dart.replaceAll('?', '');
        final actualBase = dep.type.getDisplayString().replaceFirst(RegExp(r'\?$'), '');
        if (actualBase != expectedBase) {
          throw InvalidGenerationSourceError(
              '${fn.displayName}: options ${exec.displayName} parameter $depName is ${dep.type.getDisplayString()}, '
              'but ${fn.displayName}.$depName is $expectedBase.',
              element: fn);
        }
        String? depDefault;
        if (dep.hasDefaultValue && !other.isEntity) {
          final val = dep.computeConstantValue();
          if (val != null && !val.isNull) {
            depDefault = _dartLiteral(val, other.value!, exec, depName);
          }
        } else if (dep.type.nullabilitySuffix != NullabilitySuffix.question && !dep.hasDefaultValue) {
          // Allow non-nullable dep parameter: if Swift hasn't collected `other` yet, options returns [].
          depDefault = null;
        }
        deps.add(OptionsDependency(
          name: depName,
          named: dep.isNamed,
          nullable: dep.type.nullabilitySuffix == NullabilitySuffix.question,
          defaultDart: depDefault,
        ));
      }
      edges[p.name] = [for (final d in deps) d.name];
      resolved.add(p.copyWith(options: p.options!.withDependencies(deps)));
    }

    // Check for circular parameter dependencies.
    final state = <String, int>{}; // 1 = visiting, 2 = done
    void visit(String node) {
      final s = state[node] ?? 0;
      if (s == 2) return;
      if (s == 1) {
        throw InvalidGenerationSourceError(
            '${fn.displayName}: circular @Param(options:) parameter dependency involving "$node".',
            element: fn);
      }
      state[node] = 1;
      for (final next in edges[node] ?? const <String>[]) {
        visit(next);
      }
      state[node] = 2;
    }

    for (final k in edges.keys) {
      visit(k);
    }
    return resolved;
  }

  /// The value type of an action parameter or result: what [_valueType]
  /// reads, plus enums, people, places, files, currency, measurements and lists
  /// of these.
  Future<ValueType?> _actionValue(DartType type, Element at) async {
    final nullable = type.nullabilitySuffix == NullabilitySuffix.question;
    if (type is InterfaceType && type.isDartCoreList) {
      final element = type.typeArguments.single;
      if (element.nullabilitySuffix == NullabilitySuffix.question) return null;
      final value = await _actionValue(element, at);
      return value == null || value.list ? null : value.asList(nullable: nullable);
    }
    if (_valueType(type) case final v?) return v;
    if (type is! InterfaceType) return null;
    for (final (name, kind) in const [
      ('AssistantPerson', ValueKind.person),
      ('AssistantPlace', ValueKind.place),
      ('AssistantFile', ValueKind.file),
      ('AssistantCurrency', ValueKind.currency),
      ('AssistantLength', ValueKind.length),
      ('AssistantMass', ValueKind.mass),
      ('AssistantTemperature', ValueKind.temperature),
      ('AssistantVolume', ValueKind.volume),
      ('AssistantSpeed', ValueKind.speed),
      ('AssistantEnergy', ValueKind.energy),
    ]) {
      if (_isFrom(type, name, exact: true)) return ValueType(kind, nullable: nullable);
    }
    final element = type.element;
    if (element is! EnumElement) return null;
    final name = element.displayName;
    if (_appEnums.containsKey(name)) return ValueType(ValueKind.enumeration, nullable: nullable, appEnum: name);
    if (_openEnums.values.where((o) => o.className == name).firstOrNull case final open?) {
      return ValueType(ValueKind.enumeration, nullable: nullable, enumRef: open.schema, appEnum: name);
    }
    // A schema enum from `package:assistant_actions/schemas/<domain>.dart`.
    final uri = element.library.uri;
    if (uri.scheme == 'package' &&
        uri.pathSegments.length == 3 &&
        uri.pathSegments.first == _package &&
        uri.pathSegments[1] == 'schemas') {
      final domain = uri.pathSegments[2]
          .replaceFirst(RegExp(r'\.dart$'), '')
          .replaceAllMapped(RegExp('_([a-z])'), (m) => m[1]!.toUpperCase());
      final catalog = await _catalog(domain, at);
      for (final e in catalog.enums.values) {
        if (dartEnumName(e.id) == name && e.cases.isNotEmpty) {
          return ValueType(ValueKind.enumeration, nullable: nullable, enumRef: e.id);
        }
      }
    }
    if (uri.scheme == 'package' && uri.pathSegments.first == _package) return null;
    throw InvalidGenerationSourceError(
        '$name is an enum, but not an App Enum: annotate it @AssistantEnum(title: ...).', element: at);
  }

  /// [p]'s Dart default as (a Swift `default:` literal, a Dart expression).
  /// Swift gets a literal only for strings, numbers, bools and enum cases;
  /// for other types the Swift parameter is optional and Dart fills in the
  /// default.
  (String?, String?) _defaults(Element at, FormalParameterElement p, ValueType type) {
    if (!p.hasDefaultValue) return (null, null);
    final value = p.computeConstantValue();
    if (value == null || value.isNull) return (null, null);
    final dart = _dartLiteral(value, type, at, p.displayName);
    if (type.list) return (null, dart);
    final swift = switch (type.kind) {
      ValueKind.string => ModelReader._swiftLiteral(value.toStringValue()!),
      ValueKind.integer => '${value.toIntValue()}',
      ValueKind.decimal => _swiftDouble(value.toDoubleValue()!),
      ValueKind.boolean => '${value.toBoolValue()}',
      ValueKind.enumeration => '.${swiftName(_schemaCase(_caseName(value)))}',
      _ => null,
    };
    return (swift, dart);
  }

  static String _swiftDouble(double d) {
    final s = '$d';
    return s.contains('.') || s.contains('e') ? s : '$s.0';
  }

  /// The schema case name of Dart enum case [name] (`this$` → `this`).
  static String _schemaCase(String name) => name.endsWith(r'$') ? name.substring(0, name.length - 1) : name;

  String _caseName(DartObject value) {
    final index = value.getField('index')!.toIntValue()!;
    final element = (value.type as InterfaceType).element as EnumElement;
    return [for (final f in element.fields) if (f.isEnumConstant) f.displayName][index];
  }

  String _dartLiteral(DartObject value, ValueType type, Element at, String name) {
    if (type.list) {
      final items = [for (final e in value.toListValue()!) _dartLiteral(e, type.element, at, name)];
      return 'const <${type.element.dart}>[${items.join(', ')}]';
    }
    return switch (type.kind) {
      ValueKind.string => _dartString(value.toStringValue()!),
      ValueKind.integer => '${value.toIntValue()}',
      ValueKind.decimal => '${value.toDoubleValue()}',
      ValueKind.boolean => '${value.toBoolValue()}',
      ValueKind.enumeration => '${type.dart.replaceAll('?', '')}.${_caseName(value)}',
      ValueKind.duration => 'const Duration(microseconds: ${value.getField('_duration')!.toIntValue()})',
      ValueKind.currency =>
        'const AssistantCurrency(amount: ${value.getField('amount')!.toDoubleValue()}, currencyCode: ${_dartString(value.getField('currencyCode')!.toStringValue()!)})',
      ValueKind.length ||
      ValueKind.mass ||
      ValueKind.temperature ||
      ValueKind.volume ||
      ValueKind.speed ||
      ValueKind.energy =>
        _measurementLiteral(value, type),
      _ => throw InvalidGenerationSourceError(
          'Parameter $name: a default ${type.dart} isn\'t supported; make it nullable instead.',
          element: at),
    };
  }

  String _measurementLiteral(DartObject value, ValueType type) {
    final cls = type.dart.replaceAll('?', '');
    final numVal = value.getField('value')!.toDoubleValue()!;
    final unitObj = value.getField('unit')!;
    final unitType = (unitObj.type as InterfaceType).element.displayName;
    final unitCase = _caseName(unitObj);
    return 'const $cls(value: $numVal, unit: $unitType.$unitCase)';
  }

  static String _dartString(String s) =>
      "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$').replaceAll('\n', r'\n')}'";

  // ── Shortcuts ─────────────────────────────────────────────────────────

  /// An `AppShortcut` value. Phrases need `{app}`, and may name the
  /// parameters in [params] (entities and enums, which Siri can list).
  ShortcutModel? _shortcut(ConstantReader? s, Element element, Set<String> params) {
    if (s == null || s.isNull) return null;
    final phrases = [for (final p in s.read('phrases').listValue) p.toStringValue()!];
    if (phrases.isEmpty) throw InvalidGenerationSourceError('A shortcut needs at least one phrase.', element: element);
    for (final phrase in phrases) {
      if (!phrase.contains('{app}')) {
        throw InvalidGenerationSourceError('Shortcut phrase "$phrase" must contain {app}.', element: element);
      }
      for (final m in RegExp(r'\{(\w+)\}').allMatches(phrase)) {
        final name = m.group(1)!;
        if (name == 'app' || params.contains(name)) continue;
        throw InvalidGenerationSourceError(
            'Shortcut phrase "$phrase" uses {$name}, but phrases can only name entity and enum parameters '
            '(not lists)${params.isEmpty ? ', and there are none' : ': ${params.map((p) => '{$p}').join(', ')}'}.',
            element: element);
      }
    }
    return ShortcutModel(
      phrases: phrases,
      shortTitle: s.read('shortTitle').stringValue,
      systemImage: s.read('systemImage').stringValue,
    );
  }

  /// A snapshot answer's shortcut: it has no parameters to name.
  ShortcutModel? _snapshotShortcut(ConstantReader annotation, Element element) {
    final shortcut = _shortcut(annotation.peek('shortcut'), element, const {});
    if (shortcut != null && !annotation.read('isDiscoverable').boolValue) {
      throw InvalidGenerationSourceError(
          '${element.displayName} has isDiscoverable: false, so it can\'t be an App Shortcut.', element: element);
    }
    return shortcut;
  }

  /// `@IntentShortcut(...)` annotations on the app's classes.
  List<IntentShortcutModel> _intentShortcuts(List<LibraryElement> libraries, List<SchemaEntityModel> schemaEntities,
      List<SchemaDomainModel> domains, List<EntityModel> entities) {
    final result = <IntentShortcutModel>[];
    final opens = domains.any((d) => d.opensEntities);
    final open = domains.expand((d) => d.intents).where((i) => i.id == 'system.open').firstOrNull;
    for (final lib in libraries) {
      for (final cls in lib.classes) {
        for (final a in cls.metadata.annotations) {
          final value = a.computeConstantValue();
          if (value == null || !_isFrom(value.type, 'IntentShortcut', exact: true)) continue;
          final reader = ConstantReader(value);
          final id = reader.read('intent').stringValue;
          final name = cls.displayName;
          final owner = schemaEntities.where((s) => s.className == name).firstOrNull;
          final domain = domains.where((d) => d.className == name).firstOrNull;
          final plain = entities.where((e) => e.className == name).firstOrNull;
          final turnedOn = <String>[
            for (final (i, _) in owner?.intents ?? const <(IntentSchema, IntentKind)>[]) i.id,
            for (final i in domain?.intents ?? const <IntentSchema>[])
              if (i.id != 'system.open') i.id,
            if (opens && ((owner != null && !owner.hasOwnOpen) || plain != null)) 'system.open',
          ];
          if (!turnedOn.contains(id)) {
            throw InvalidGenerationSourceError(
                '@IntentShortcut(\'$id\') on $name, which doesn\'t turn $id on'
                '${id == 'system.open' ? ' (put system.open\'s shortcut on the entity class it opens, and turn it on with @SystemIntents(open: true))' : ''}. '
                '${turnedOn.isEmpty ? 'It turns on no schema intents.' : 'It turns on ${turnedOn.join(', ')}.'}',
                element: cls);
          }
          final IntentSchema intent;
          String? openClass;
          if (id == 'system.open') {
            intent = open!;
            openClass = name;
          } else {
            intent = owner?.intents.firstWhere((e) => e.$1.id == id).$1 ??
                domain!.intents.firstWhere((i) => i.id == id);
          }
          final optional = intent.parameters.where((p) => p.type.element.kind == 'sceneDescriptor');
          if (optional.isNotEmpty) {
            throw InvalidGenerationSourceError('$id takes ${optional.first.name}, which some platforms lack, so it '
                'can\'t be an App Shortcut.', element: cls);
          }
          final adopted = {for (final s in schemaEntities) s.schema.id};
          final params = id == 'system.open'
              ? {'target'}
              : {
                  for (final p in intent.parameters)
                    if (!p.type.base.isList &&
                        !swiftReserved.contains(p.name) &&
                        ((p.type.base.kind == 'entity' && adopted.contains(p.type.base.ref)) ||
                            p.type.base.kind == 'enum' ||
                            p.type.base.kind == 'openEnum'))
                      p.name,
                };
          final shortcut = _shortcut(reader, cls, params)!;
          result.add(IntentShortcutModel(
              className: name,
              intent: intent,
              shortcut: shortcut,
              owner: id == 'system.open' ? null : owner,
              openClass: openClass));
        }
      }
    }
    return result;
  }

  /// Fails for more App Shortcuts than Apple allows, or two for one intent.
  void _checkShortcuts(List<ActionModel> actions, List<SnapshotActionModel> snapshots,
      List<IntentShortcutModel> intents, Element element) {
    final count = actions.where((a) => a.shortcut != null).length +
        snapshots.where((a) => a.shortcut != null).length +
        intents.length;
    if (count > _maxShortcuts) {
      throw InvalidGenerationSourceError(
          'The app has $count App Shortcuts; Apple allows $_maxShortcuts.', element: element);
    }
    final seen = <String>{};
    for (final s in intents) {
      final key = '${s.intent.id} ${s.openClass ?? ''}';
      if (!seen.add(key)) {
        throw InvalidGenerationSourceError('${s.intent.id} has two @IntentShortcut annotations; use one with '
            'more phrases.', element: element);
      }
    }
  }

  /// `@AssistantActionsApp(shortcutTileColor: ...)` as a Swift case name.
  String? _tileColor(ConstantReader app) {
    final color = app.peek('shortcutTileColor');
    if (color == null || color.isNull) return null;
    return _caseName(color.objectValue);
  }
}
