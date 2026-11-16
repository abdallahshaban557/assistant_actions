part of 'reader.dart';

/// System surfaces beyond Siri: Focus filters, Control Center / Lock Screen /
/// Action Button controls (`@AssistantControl`), and configurable widget
/// intents (`@AssistantWidgetConfig`).
extension _Surfaces on ModelReader {
  /// `@AssistantFocusFilter` on a top-level function: a `SetFocusFilterIntent`
  /// whose parameters are the function's. The system creates the filter with
  /// its parameters' defaults (and runs it with them when the Focus turns
  /// off), so each one is nullable or has a constant default Swift can state.
  Future<ActionModel> _focusFilter(TopLevelFunctionElement fn, ConstantReader annotation, List<EntityModel> entities,
      List<SchemaEntityModel> schemaEntities) async {
    InvalidGenerationSourceError error(String message) =>
        InvalidGenerationSourceError('${fn.displayName}: $message', element: fn);

    if (_annotation(fn, 'AssistantAction') != null) {
      throw error('a function is either an @AssistantAction or an @AssistantFocusFilter, not both.');
    }
    final result = fn.returnType;
    final inner = result.isDartAsyncFuture || result.isDartAsyncFutureOr
        ? (result as InterfaceType).typeArguments.single
        : result;
    if (inner is! VoidType && !inner.isDartCoreNull) {
      throw error('a Focus filter returns void (optionally in a Future), not ${result.getDisplayString()}.');
    }
    final rawParams = <ParamModel>[];
    for (final p in fn.formalParameters) {
      final param = await _param(fn, p, entities, schemaEntities);
      // `_param` gives defaults App Intents can state as Swift literals; for a
      // non-nullable entity list, an empty list is the Focus-off default.
      final swiftDefault = param.swiftDefault ?? (param.isEntity && param.entityList && !param.entityNullable ? '[]' : null);
      if (p.hasDefaultValue) {
        final value = p.computeConstantValue();
        // `= null` on a nullable parameter says nothing more.
        if (swiftDefault == null && !(param.nullable && (value?.isNull ?? false))) {
          throw error('the default of ${p.displayName} must be a bool, int, double, String or enum constant; '
              'make it nullable instead.');
        }
      }
      if (!param.nullable && swiftDefault == null) {
        throw error('${p.displayName} needs a default value or a nullable type: the system creates the '
            'filter with its defaults, and runs it with them when the Focus turns off.');
      }
      rawParams.add(param.copyWith(swiftDefault: swiftDefault));
    }
    final params = _resolveOptionsDependencies(fn, rawParams);
    final summary = annotation.peek('summary')?.stringValue;
    for (final match in RegExp(r'\{(\w+)\}').allMatches(summary ?? '')) {
      final p = params.where((p) => p.name == match.group(1)).firstOrNull;
      if (p == null) throw error('summary uses {${match.group(1)}}, which is not a parameter.');
      if (!_Actions._speakable(p)) throw error('summary uses {${p.name}}, which Settings can\'t show as text.');
    }
    final filterCriteriaParam = annotation.peek('filterCriteriaParam')?.stringValue;
    if (filterCriteriaParam != null) {
      final p = params.where((p) => p.name == filterCriteriaParam).firstOrNull;
      if (p == null) {
        throw error('filterCriteriaParam "$filterCriteriaParam" is not a parameter.');
      }
      final validCriteria = p.isEntity ||
          (p.value != null &&
              const {
                ValueKind.string,
                ValueKind.enumeration,
                ValueKind.integer,
                ValueKind.decimal,
                ValueKind.boolean,
              }.contains(p.value!.kind));
      if (!validCriteria) {
        throw error('filterCriteriaParam "${p.name}" must be a String, enum, entity, number or bool '
            '(or a List of one of those) so it can match notification filterCriteria.');
      }
    }
    return ActionModel(
      functionName: fn.displayName,
      library: fn.library.uri,
      title: annotation.read('title').stringValue,
      description: annotation.peek('description')?.stringValue,
      runs: RunsModel.deferred,
      params: params,
      returnsString: false,
      focusFilter: FocusFilterModel(summary: summary, filterCriteriaParam: filterCriteriaParam),
    );
  }

  /// `@AssistantControl(...)` on an `@AssistantAction` function.
  ControlModel? _control(
    TopLevelFunctionElement fn,
    ConstantReader? annotation,
    List<ParamModel> params,
    List<EntityModel> entities,
    List<SchemaEntityModel> schemaEntities,
  ) {
    if (annotation == null) return null;
    InvalidGenerationSourceError error(String message) =>
        InvalidGenerationSourceError('${fn.displayName}: $message', element: fn);

    final id = annotation.read('id').stringValue.trim();
    if (id.isEmpty || !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(id)) {
      throw error('@AssistantControl id "$id" must be a non-empty identifier (letters, digits, _, ., -).');
    }
    final title = annotation.read('title').stringValue.trim();
    if (title.isEmpty) {
      throw error('@AssistantControl title cannot be empty.');
    }
    final systemImage = _systemImage(annotation, fn)!;
    final subtitle = annotation.peek('subtitle')?.stringValue;

    final valueParam = params.where((p) => p.name == 'value').firstOrNull;
    final hasToggleValue = valueParam != null &&
        valueParam.value != null &&
        !valueParam.value!.list &&
        valueParam.value!.kind == ValueKind.boolean &&
        !valueParam.value!.nullable;
    final otherRequired = params.where(
      (p) => (!hasToggleValue || p.name != 'value') && !p.nullable && p.defaultDart == null && p.swiftDefault == null,
    );
    if (otherRequired.isNotEmpty) {
      throw error(
        '@AssistantControl actions cannot take required parameters (${otherRequired.map((p) => p.name).join(', ')}); '
        'use optional/defaulted parameters for a button control, or `bool value` for a toggle control.',
      );
    }

    final collection = annotation.peek('toggleSnapshotCollection')?.stringValue;
    final entityId = annotation.peek('toggleEntityId')?.stringValue;
    final field = annotation.peek('toggleField')?.stringValue;

    if (!hasToggleValue && (collection != null || entityId != null || field != null)) {
      throw error('toggleSnapshotCollection / toggleField require a `bool value` parameter on the action.');
    }
    if ((collection == null) != (field == null)) {
      throw error('toggleSnapshotCollection and toggleField must be specified together.');
    }
    if (entityId != null && collection == null) {
      throw error('toggleEntityId requires toggleSnapshotCollection and toggleField.');
    }
    if (collection != null && field != null) {
      final entity = entities.where((e) => e.className == collection).firstOrNull;
      final schemaEntity = schemaEntities.where((e) => e.className == collection).firstOrNull;
      if (entity == null && schemaEntity == null) {
        throw error('toggleSnapshotCollection "$collection" is not an @AssistantEntity or schema entity class.');
      }
      final fields = entity?.fields ?? schemaEntity!.fields;
      final matched = fields.where((f) => f.name == field).firstOrNull;
      if (matched == null || matched.type.kind != ValueKind.boolean || matched.type.list) {
        throw error('toggleField "$field" must be a bool field on $collection.');
      }
    }

    return ControlModel(
      id: id,
      title: title,
      systemImage: systemImage,
      subtitle: subtitle,
      isToggle: hasToggleValue,
      toggleSnapshotCollection: collection,
      toggleEntityId: entityId,
      toggleField: field,
    );
  }

  /// `@AssistantWidgetConfig(...)` on top-level functions and classes.
  Future<List<WidgetConfigModel>> _widgetConfigs(
    List<LibraryElement> libraries,
    List<EntityModel> entities,
    Element root,
  ) async {
    final result = <WidgetConfigModel>[];
    final ids = <String>{};
    final swiftNames = <String>{};

    void register(WidgetConfigModel config, Element at) {
      if (!ids.add(config.id)) {
        throw InvalidGenerationSourceError(
            'Two @AssistantWidgetConfig declarations share id "${config.id}".', element: at);
      }
      if (!swiftNames.add(config.swiftName)) {
        throw InvalidGenerationSourceError(
            'Two @AssistantWidgetConfig declarations produce ${config.swiftName}.', element: at);
      }
      result.add(config);
    }

    for (final lib in libraries) {
      for (final fn in lib.topLevelFunctions) {
        final annotation = _annotation(fn, 'AssistantWidgetConfig');
        if (annotation == null) continue;
        final id = annotation.read('id').stringValue.trim();
        if (id.isEmpty) {
          throw InvalidGenerationSourceError('${fn.displayName}: @AssistantWidgetConfig id cannot be empty.',
              element: fn);
        }
        final title = annotation.read('title').stringValue.trim();
        if (title.isEmpty) {
          throw InvalidGenerationSourceError('${fn.displayName}: @AssistantWidgetConfig title cannot be empty.',
              element: fn);
        }
        final params = [
          for (final p in fn.formalParameters) await _widgetFormalParam(fn, p, _annotation(p, 'Param'), entities),
        ];
        register(
          WidgetConfigModel(
            id: id,
            name: fn.displayName,
            library: fn.library.uri,
            title: title,
            description: annotation.peek('description')?.stringValue,
            params: params,
          ),
          fn,
        );
      }

      for (final cls in lib.classes) {
        final annotation = _annotation(cls, 'AssistantWidgetConfig');
        if (annotation == null) continue;
        final id = annotation.read('id').stringValue.trim();
        if (id.isEmpty) {
          throw InvalidGenerationSourceError('${cls.displayName}: @AssistantWidgetConfig id cannot be empty.',
              element: cls);
        }
        final title = annotation.read('title').stringValue.trim();
        if (title.isEmpty) {
          throw InvalidGenerationSourceError('${cls.displayName}: @AssistantWidgetConfig title cannot be empty.',
              element: cls);
        }
        final params = <ParamModel>[];
        final ctor = cls.unnamedConstructor;
        if (ctor != null && ctor.formalParameters.isNotEmpty) {
          for (final p in ctor.formalParameters) {
            final backingField = cls.getField(p.displayName);
            final meta = _annotation(p, 'Param') ?? (backingField == null ? null : _annotation(backingField, 'Param'));
            params.add(await _widgetFormalParam(cls, p, meta, entities));
          }
        } else {
          for (final f in cls.fields) {
            if (f.isStatic || !f.isOriginDeclaration) continue;
            params.add(await _widgetFieldParam(cls, f, entities));
          }
        }
        register(
          WidgetConfigModel(
            id: id,
            name: cls.displayName,
            library: cls.library.uri,
            title: title,
            description: annotation.peek('description')?.stringValue,
            params: params,
          ),
          cls,
        );
      }
    }
    return result;
  }

  Future<ParamModel> _widgetFormalParam(
    Element owner,
    FormalParameterElement p,
    ConstantReader? meta,
    List<EntityModel> entities,
  ) async {
    final name = p.displayName;
    final title = meta?.peek('title')?.stringValue ?? ModelReader._titleCase(name);
    final prompt = meta?.peek('prompt')?.stringValue;
    final type = p.type;
    final nullable = type.nullabilitySuffix == NullabilitySuffix.question;
    final listed = type is InterfaceType && type.isDartCoreList ? type.typeArguments.single : null;
    final target = listed ?? type;
    if (target is InterfaceType) {
      final entity = entities.where((e) => e.className == target.element.displayName).firstOrNull;
      if (entity != null) {
        if (listed != null && listed.nullabilitySuffix == NullabilitySuffix.question) {
          throw InvalidGenerationSourceError(
              'Parameter $name: use List<${entity.className}>, not ${type.getDisplayString()}.', element: owner);
        }
        String? swiftDefault;
        String? dartDefault;
        if (p.hasDefaultValue) {
          final defVal = p.computeConstantValue();
          if (listed != null && (defVal?.toListValue()?.isEmpty ?? false)) {
            swiftDefault = '[]';
            dartDefault = 'const []';
          } else if (!(defVal?.isNull ?? true)) {
            throw InvalidGenerationSourceError('Parameter $name: entity parameters can\'t have a default.',
                element: owner);
          }
        }
        return ParamModel(
          name: name,
          title: title,
          prompt: prompt,
          named: p.isNamed,
          entity: entity,
          entityNullable: nullable,
          entityList: listed != null,
          swiftDefault: swiftDefault,
          defaultDart: dartDefault,
        );
      }
    }
    final value = await _actionValue(type, owner);
    if (value == null || !_isWidgetSupportedValue(value)) {
      throw InvalidGenerationSourceError(
        '${owner.displayName} parameter $name (${type.getDisplayString()}): @AssistantWidgetConfig supports '
        '@AssistantEntity, @AssistantEnum, String, bool, int, and double parameters.',
        element: owner,
      );
    }
    final (swiftDefault, dartDefault) = _defaults(owner, p, value);
    return ParamModel(
      name: name,
      title: title,
      prompt: prompt,
      named: p.isNamed,
      value: value,
      swiftDefault: swiftDefault,
      defaultDart: dartDefault,
    );
  }

  Future<ParamModel> _widgetFieldParam(
    ClassElement owner,
    FieldElement f,
    List<EntityModel> entities,
  ) async {
    final meta = _annotation(f, 'Param');
    final name = f.displayName;
    final title = meta?.peek('title')?.stringValue ?? ModelReader._titleCase(name);
    final prompt = meta?.peek('prompt')?.stringValue;
    final type = f.type;
    final nullable = type.nullabilitySuffix == NullabilitySuffix.question;
    final listed = type is InterfaceType && type.isDartCoreList ? type.typeArguments.single : null;
    final target = listed ?? type;
    if (target is InterfaceType) {
      final entity = entities.where((e) => e.className == target.element.displayName).firstOrNull;
      if (entity != null) {
        return ParamModel(
          name: name,
          title: title,
          prompt: prompt,
          named: true,
          entity: entity,
          entityNullable: nullable,
          entityList: listed != null,
        );
      }
    }
    final value = await _actionValue(type, owner);
    if (value == null || !_isWidgetSupportedValue(value)) {
      throw InvalidGenerationSourceError(
        '${owner.displayName}.$name (${type.getDisplayString()}): @AssistantWidgetConfig supports '
        '@AssistantEntity, @AssistantEnum, String, bool, int, and double fields.',
        element: f,
      );
    }
    return ParamModel(
      name: name,
      title: title,
      prompt: prompt,
      named: true,
      value: value,
    );
  }

  static bool _isWidgetSupportedValue(ValueType value) => const {
        ValueKind.string,
        ValueKind.boolean,
        ValueKind.integer,
        ValueKind.decimal,
        ValueKind.enumeration,
      }.contains(value.kind);
}
