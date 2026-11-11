import 'dart:convert';

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'catalog.dart';
import 'interaction.dart';
import 'model.dart';
import 'polish.dart';
import 'schema_calls.dart';

part 'reader_actions.dart';
part 'reader_surfaces.dart';
part 'reader_polish.dart';

const _package = 'assistant_actions';

/// The `api` this generator needs in assistant_actions'
/// `lib/src/catalog/generator_api.json`.
const _runtimeApi = 12;

/// Reads the app's annotations from the definitions library and everything
/// it imports from the app's own package.
class ModelReader {
  ModelReader(this.step, {this.deployment = DeploymentTarget.minimum});

  final BuildStep step;

  /// What the generated Swift is compiled for.
  final DeploymentTarget deployment;
  final _catalogs = <String, DomainCatalog>{};
  final _openEnums = <String, OpenEnumModel>{};
  final _appEnums = <String, AppEnumModel>{};

  Future<AppModel?> read(LibraryElement library) async {
    final app = _annotation(library, 'AssistantActionsApp');
    if (app == null) {
      log.warning('${library.uri} has no @AssistantActionsApp(name: ...) library annotation; '
          'nothing generated.');
      return null;
    }
    await _checkRuntime(library);
    final libraries = _ownLibraries(library);
    final entities = <EntityModel>[];
    final schemaEntities = <SchemaEntityModel>[];
    final schemaDomains = <SchemaDomainModel>[];
    for (final lib in libraries) {
      for (final e in lib.enums) {
        for (final a in e.metadata.annotations) {
          final value = a.computeConstantValue();
          if (value == null || !_isFrom(value.type, 'SchemaEnumCases')) continue;
          final schema = ConstantReader(value).read('schema').stringValue;
          if (_openEnums.containsKey(schema)) {
            throw InvalidGenerationSourceError('Two enums give the cases of $schema.', element: e);
          }
          _openEnums[schema] = OpenEnumModel(
            schema: schema,
            className: e.displayName,
            library: e.library.uri,
            cases: [for (final c in e.fields) if (c.isEnumConstant) c.displayName],
          );
        }
      }
    }
    _readAppEnums(libraries);
    for (final lib in libraries) {
      for (final cls in lib.classes) {
        if (_annotation(cls, 'AssistantEntity') case final a?) entities.add(_entity(cls, a));
        if (_schemaAnnotation(cls) case final a?) schemaEntities.add(await _schemaEntity(cls, a));
        if (_schemaAnnotation(cls) == null && _schemaAnnotation(cls, 'SchemaIntents') == null) {
          _checkIntentFeatures(cls);
        }
        if (_schemaAnnotation(cls, 'SchemaIntents') case final a?) {
          final domain = await _schemaDomain(cls, a);
          if (schemaDomains.any((d) => d.domain == domain.domain)) {
            throw InvalidGenerationSourceError(
                'Only one class can have @${pascal(domain.domain)}Intents(...).', element: cls);
          }
          schemaDomains.add(domain);
        }
      }
    }
    _checkCalls(schemaEntities, schemaDomains, entities, library);
    // Apple allows one IntentValueQuery per input type.
    final importers = <String, String>{};
    for (final s in schemaEntities) {
      for (final q in s.queries) {
        if (importers[q.type.kind] case final other?) {
          throw InvalidGenerationSourceError(
              'Only one query can find items for a ${q.type.kind}: ${q.id} on ${s.className} and $other are both on.',
              element: library);
        }
        importers[q.type.kind] = '${q.id} on ${s.className}';
      }
    }
    await _loadReferenced(schemaEntities, schemaDomains, library);
    final actions = <ActionModel>[];
    for (final lib in libraries) {
      for (final fn in lib.topLevelFunctions) {
        if (_annotation(fn, 'AssistantAction') case final a?) {
          actions.add(await _action(fn, a, entities, schemaEntities));
        }
        if (_annotation(fn, 'AssistantFocusFilter') case final f?) {
          actions.add(await _focusFilter(fn, f, entities));
        }
      }
    }
    final snapshotActions = <SnapshotActionModel>[];
    for (final lib in libraries) {
      for (final variable in lib.topLevelVariables) {
        if (_annotation(variable, 'AssistantAction') case final a?) {
          snapshotActions.add(_snapshotAction(variable, a, entities, schemaEntities));
        }
      }
    }
    final background = _background(libraries, library);
    final ids = <String>{};
    for (final id in [for (final a in actions) a.id, for (final a in snapshotActions) a.id]) {
      if (!ids.add(id)) {
        throw InvalidGenerationSourceError('Two @AssistantAction declarations are named $id.');
      }
    }
    final intentShortcuts = _intentShortcuts(libraries, schemaEntities, schemaDomains, entities);
    _checkShortcuts(actions, snapshotActions, intentShortcuts, library);
    return AppModel(
      appName: app.read('name').stringValue,
      actions: actions,
      entities: entities,
      schemaEntities: schemaEntities,
      snapshotActions: snapshotActions,
      schemaDomains: schemaDomains,
      catalogs: Map.of(_catalogs),
      openEnums: Map.of(_openEnums),
      appEnums: Map.of(_appEnums),
      intentShortcuts: intentShortcuts,
      shortcutTileColor: _tileColor(app),
      background: background,
      deployment: deployment,
      unlock: _unlock(app) ?? UnlockModel.notRequired,
    );
  }

  /// The `@AssistantBackground()` registry function, if any: one, top-level,
  /// taking no arguments and returning `AssistantActionsRegistry` (or a
  /// `Future` of it).
  BackgroundModel? _background(List<LibraryElement> libraries, LibraryElement root) {
    final found = [
      for (final lib in libraries)
        for (final fn in lib.topLevelFunctions)
          if (_annotation(fn, 'AssistantBackground') case final a?) (fn, a),
    ];
    if (found.isEmpty) return null;
    if (found.length > 1) {
      throw InvalidGenerationSourceError(
          'Only one function can be @AssistantBackground(): ${found.map((f) => f.$1.displayName).join(', ')}.',
          element: found[1].$1);
    }
    final (fn, annotation) = found.single;
    if (fn.formalParameters.any((p) => p.isRequired)) {
      throw InvalidGenerationSourceError(
          '@AssistantBackground() ${fn.displayName} must take no arguments: the headless engine calls it as is.',
          element: fn);
    }
    var result = fn.returnType;
    if (result.isDartAsyncFuture || result.isDartAsyncFutureOr) {
      result = (result as InterfaceType).typeArguments.single;
    }
    if (!_isFrom(result, 'AssistantActionsRegistry', exact: true) ||
        result.nullabilitySuffix == NullabilitySuffix.question) {
      throw InvalidGenerationSourceError(
          '@AssistantBackground() ${fn.displayName} must return the AssistantActionsRegistry for '
          'AssistantActions.start (or a Future of it), not ${fn.returnType.getDisplayString()}.',
          element: fn);
    }
    return BackgroundModel(
      functionName: fn.displayName,
      library: fn.library.uri,
      entrypointLibrary: root.uri.replace(path: root.uri.path.replaceFirst(RegExp(r'\.dart$'), '.g.dart')),
      applyQueued: annotation.peek('applyQueued')?.boolValue ?? true,
    );
  }

  /// `@AssistantSyncable(…)` on [cls]: its value, or null without one.
  bool? _syncable(ClassElement cls) => _annotation(cls, 'AssistantSyncable')?.read('syncable').boolValue;

  /// Fails for `@AssistantUndoable()` / `@AssistantLongRunning()` on a class
  /// that has no schema intents to apply them to.
  void _checkIntentFeatures(ClassElement cls) {
    for (final name in ['AssistantUndoable', 'AssistantLongRunning']) {
      if (_annotation(cls, name) != null) {
        throw InvalidGenerationSourceError(
            '@$name() goes on a schema entity class (such as @RemindersReminder) or a domain\'s …Intents class. '
            'For an @AssistantAction, use longRunning: true.',
            element: cls);
      }
    }
  }

  /// Fails the build for turned-on intents the generator can't serve yet,
  /// and for id fields naming entities the app doesn't adopt.
  void _checkCalls(List<SchemaEntityModel> entities, List<SchemaDomainModel> domains, List<EntityModel> plain,
      Element element) {
    final adopted = {for (final s in entities) s.schema.id};
    for (final s in entities) {
      for (final MapEntry(key: member, value: field) in s.mapping.entries) {
        if (field.type.entityRef case final r? when !adopted.contains(r)) {
          throw InvalidGenerationSourceError(
              '${s.className}.${field.name} holds ids of $r items (${s.schema.id}.$member), but no class adopts $r.',
              element: element);
        }
      }
    }
    void check(IntentSchema intent, Element at) {
      if (callResult(intent) == CallResult.unsupported) {
        throw InvalidGenerationSourceError(
            '${intent.id} returns ${intent.result}, which assistant_actions can\'t produce from Dart yet. '
            'Turn it off.',
            element: at);
      }
      if (resultEntity(intent) case final r? when !adopted.contains(r)) {
        throw InvalidGenerationSourceError(
            '${intent.id} returns $r items: adopt $r on one of your classes too, so Siri gets an item back.',
            element: at);
      }
      for (final p in intent.parameters) {
        if (p.type.element.kind == 'openEnum' && !_openEnums.containsKey(p.type.element.ref)) {
          throw InvalidGenerationSourceError(
              '${intent.id} takes ${p.name}, a ${p.type.element.ref} whose cases the app defines: '
              'annotate one of your enums @${dartEnumName(p.type.element.ref!)}().',
              element: at);
        }
      }
    }

    for (final s in entities) {
      for (final (intent, kind) in s.intents) {
        if (kind == IntentKind.call) {
          check(intent, element);
        } else {
          for (final p in intent.parameters) {
            if (p.type.element.kind == 'openEnum' && !_openEnums.containsKey(p.type.element.ref)) {
              throw InvalidGenerationSourceError(
                  '${intent.id} takes ${p.name}, a ${p.type.element.ref} whose cases the app defines: '
                  'annotate one of your enums @${dartEnumName(p.type.element.ref!)}().',
                  element: element);
            }
          }
        }
      }
    }
    for (final d in domains) {
      for (final intent in d.intents) {
        if (intent.id == 'system.open') {
          if (entities.isEmpty && plain.isEmpty) {
            throw InvalidGenerationSourceError('system.open opens one of the app\'s entities, and there are none.',
                element: element);
          }
          continue;
        }
        check(intent, element);
      }
    }
  }

  /// Loads the catalogs of other domains the adopted schemas reference.
  Future<void> _loadReferenced(
      List<SchemaEntityModel> entities, List<SchemaDomainModel> domains, Element element) async {
    final pending = <SchemaType>[
      for (final s in entities) ...[
        SchemaType('entity', ref: s.schema.id),
        for (final (intent, _) in s.intents) ...[
          for (final p in intent.parameters) p.type,
          ?intent.result,
        ],
      ],
      for (final d in domains)
        for (final intent in d.intents) ...[
          for (final p in intent.parameters) p.type,
          ?intent.result,
        ],
    ];
    final seen = <String>{};
    while (pending.isNotEmpty) {
      final t = pending.removeLast();
      if (t.of case final of?) {
        pending.add(of);
        continue;
      }
      final ref = t.ref;
      if (ref == null || !seen.add(ref)) continue;
      final catalog = await _catalog(ref.split('.').first, element);
      switch (t.kind) {
        case 'entity':
          for (final p in catalog.entities[ref]?.properties ?? const <SchemaMember>[]) {
            pending.add(p.type);
          }
        case 'union':
          for (final c in catalog.unions[ref]?.cases ?? const <({String name, SchemaType type})>[]) {
            pending.add(c.type);
          }
      }
    }
  }

  /// The generated Swift and Dart use runtime APIs added in assistant_actions
  /// 0.0.12 (people, places, files, recurrence rules and unions; enum,
  /// duration and list values; catalogs with intent protocols), marked by `lib/src/catalog/generator_api.json`.
  Future<void> _checkRuntime(LibraryElement library) async {
    final marker = AssetId(_package, 'lib/src/catalog/generator_api.json');
    final api = await step.canRead(marker)
        ? ((jsonDecode(await step.readAsString(marker)) as Map)['api'] as num?)?.toInt() ?? 0
        : 0;
    if (api < _runtimeApi) {
      throw InvalidGenerationSourceError(
          'This version of assistant_actions_generator needs assistant_actions 0.0.19 or later. '
          'Run `flutter pub upgrade assistant_actions`.',
          element: library);
    }
  }

  /// [root] plus the libraries of the same package it imports, transitively.
  List<LibraryElement> _ownLibraries(LibraryElement root) {
    final package = root.uri.pathSegments.first;
    final seen = <Uri>{};
    final result = <LibraryElement>[];
    void visit(LibraryElement lib) {
      if (!seen.add(lib.uri)) return;
      result.add(lib);
      for (final fragment in lib.fragments) {
        for (final import in fragment.libraryImports) {
          final imported = import.importedLibrary;
          if (imported != null && imported.uri.scheme == 'package' && imported.uri.pathSegments.first == package) {
            visit(imported);
          }
        }
      }
    }

    visit(root);
    return result;
  }

  // ── Entities ──────────────────────────────────────────────────────────

  EntityModel _entity(ClassElement cls, ConstantReader annotation) {
    final id = _markedMember(cls, 'EntityId');
    final title = _markedMember(cls, 'DisplayTitle');
    if (id == null) {
      throw InvalidGenerationSourceError('@AssistantEntity needs a String field marked @EntityId().', element: cls);
    }
    if (title == null) {
      throw InvalidGenerationSourceError(
          '@AssistantEntity needs a String field or getter marked @DisplayTitle().',
          element: cls);
    }
    for (final (member, _) in [id, title]) {
      if (!_type(member).isDartCoreString) {
        throw InvalidGenerationSourceError('${member.displayName} must be a String.', element: member);
      }
    }
    final subtitle = _markedMember(cls, 'DisplaySubtitle');
    final image = _imageField(cls);
    return EntityModel(
      className: cls.displayName,
      library: cls.library.uri,
      title: annotation.read('title').stringValue,
      idField: id.$1.displayName,
      titleGetter: title.$1.displayName,
      subtitleGetter: subtitle?.$1.displayName,
      syncable: _syncable(cls) ?? false,
      url: _url(annotation, cls),
      visualSearch: annotation.peek('visualSearch')?.boolValue ?? false,
      unlock: _unlock(annotation),
      systemImage: _systemImage(annotation, cls),
      image: image,
      fields: [
        for (final f in cls.fields)
          if (!f.isStatic && f.isOriginDeclaration && f.displayName != id.$1.displayName && f.displayName != image?.name)
            if (_valueType(f.type) case final type?) FieldModel(f.displayName, type),
      ],
    );
  }

  /// The field or explicit getter of [cls] annotated with [marker].
  (Element, DartType)? _markedMember(ClassElement cls, String marker) {
    for (final f in cls.fields) {
      if (!f.isStatic && f.isOriginDeclaration && _annotation(f, marker) != null) return (f, f.type);
    }
    for (final g in cls.getters) {
      if (!g.isStatic && g.isOriginDeclaration && _annotation(g, marker) != null) return (g, g.returnType);
    }
    return null;
  }

  DartType _type(Element e) => switch (e) {
        FieldElement f => f.type,
        GetterElement g => g.returnType,
        _ => throw StateError('$e'),
      };

  // ── Schema entities ───────────────────────────────────────────────────

  Future<SchemaEntityModel> _schemaEntity(ClassElement cls, ConstantReader annotation) async {
    final schemaId = annotation.read('schema').stringValue;
    final catalog = await _catalog(schemaId.split('.').first, cls);
    final schema = catalog.entities[schemaId];
    if (schema == null) {
      throw InvalidGenerationSourceError('$schemaId is not in the bundled schema catalog.', element: cls);
    }
    final id = _markedMember(cls, 'EntityId');
    if (id == null || !_type(id.$1).isDartCoreString) {
      throw InvalidGenerationSourceError('A schema entity needs a String field marked @EntityId().', element: cls);
    }

    final mapping = <String, FieldModel>{};
    for (final field in cls.fields) {
      if (field.isStatic || !field.isOriginDeclaration) continue;
      for (final a in field.metadata.annotations) {
        final value = a.computeConstantValue();
        if (value == null || !_isFrom(value.type, 'SchemaMember')) continue;
        final member = ConstantReader(value);
        final owner = member.read('schema').stringValue;
        final name = member.read('name').stringValue;
        if (owner != schemaId) {
          throw InvalidGenerationSourceError(
              '${field.displayName} is mapped to $owner.$name, but ${cls.displayName} adopts $schemaId.',
              element: field);
        }
        final property = schema.property(name)!;
        final type = _fieldType(field, field.type, property.type.base, '$schemaId.$name');
        final expected = dartTypeFor(property.type, {for (final e in _openEnums.values) e.schema: e.className})
            ?.replaceAll('?', '');
        if (type == null || type.dart.replaceAll('?', '') != expected) {
          throw InvalidGenerationSourceError(
              '${field.displayName} is ${field.type.getDisplayString()}, but $schemaId.$name '
              'needs ${dartTypeFor(property.type)}.',
              element: field);
        }
        if (mapping.containsKey(name)) {
          throw InvalidGenerationSourceError('$schemaId.$name is mapped twice.', element: field);
        }
        mapping[name] = FieldModel(field.displayName, type);
      }
    }

    final intents = [
      for (final (intent, kind) in catalog.intentsFor(schema))
        if (annotation.peek(intent.name)?.boolValue ?? false) (intent, kind),
    ];

    final containers = <String, FixedInstance>{};
    for (final p in schema.properties) {
      if (p.type.base.kind != 'entity' || p.type.base.ref == schemaId) continue;
      final value = annotation.peek(p.name);
      if (value != null && !value.isNull) containers[p.name] = _fixed(value);
    }

    // Every member must get a value: mapped, a fixed container, or a default.
    for (final p in schema.properties) {
      if (mapping.containsKey(p.name) || containers.containsKey(p.name)) continue;
      if (_hasDefault(catalog, p.type, schemaId)) continue;
      throw InvalidGenerationSourceError(
          '$schemaId.${p.name} (${p.type}) is required and has no default: map a field to it.',
          element: cls);
    }

    final queries = [
      for (final q in catalog.queriesFor(schema))
        if (q.imports && (annotation.peek(q.name)?.boolValue ?? false)) q,
    ];
    for (final q in queries) {
      if (dartElementType(q.type) == null) {
        throw InvalidGenerationSourceError(
            '${q.id} finds items for a ${q.type}, which assistant_actions can\'t pass to Dart yet. Turn it off.',
            element: cls);
      }
    }

    return SchemaEntityModel(
      className: cls.displayName,
      library: cls.library.uri,
      catalog: catalog,
      schema: schema,
      idField: id.$1.displayName,
      mapping: mapping,
      intents: intents,
      containers: containers,
      interactions: _interactions(annotation, intents, '@${pascal(schema.domain)}${pascal(schema.name)}', cls),
      syncableOverride: _syncable(cls),
      undoable: _annotation(cls, 'AssistantUndoable') != null,
      longRunning: _annotation(cls, 'AssistantLongRunning') != null,
      queries: queries,
      url: _url(annotation, cls),
      visualSearch: annotation.peek('visualSearch')?.boolValue ?? false,
      unlock: _unlock(annotation),
      systemImage: _systemImage(annotation, cls),
      image: _imageField(cls),
      summaries: _summaries(annotation, intents, '@${pascal(schema.domain)}${pascal(schema.name)}', cls),
    );
  }

  /// The `url:` deep link template of an entity annotation, checked: an
  /// absolute URL whose only placeholder is `{id}`.
  String? _url(ConstantReader annotation, ClassElement cls) {
    final url = annotation.peek('url')?.stringValue;
    if (url == null) return null;
    if (urlTemplateError(url) case final error?) {
      throw InvalidGenerationSourceError('${cls.displayName}: $error', element: cls);
    }
    return url;
  }

  FixedInstance _fixed(ConstantReader value) {
    final schema = value.read('schema').stringValue;
    final catalog = _catalogs[schema.split('.').first]!;
    final entity = catalog.entities[schema]!;
    final strings = <String, String>{};
    final nested = <String, FixedInstance>{};
    for (final p in entity.properties) {
      final field = value.peek(p.name);
      if (field == null || field.isNull) continue;
      if (p.type.base.kind == 'string') strings[p.name] = field.stringValue;
      if (p.type.base.kind == 'entity') nested[p.name] = _fixed(field);
    }
    return FixedInstance(schema: schema, id: value.read('id').stringValue, strings: strings, nested: nested);
  }

  bool _hasDefault(DomainCatalog catalog, SchemaType type, String self) =>
      type.isOptional ||
      switch (type.kind) {
        'array' || 'set' || 'bool' || 'string' || 'attributedString' => true,
        'enum' => _enumHasCases(type.ref!),
        'openEnum' => _openEnums[type.ref]?.cases.isNotEmpty ?? false,
        _ => false,
      };

  /// The value type of [field] (or, for a list, its element type [t]) mapping
  /// a schema member whose type (without optional) is [member], or null when
  /// they don't fit.
  ValueType? _fieldType(FieldElement field, DartType t, SchemaType member, String id) {
    final nullable = t.nullabilitySuffix == NullabilitySuffix.question;
    if (member.isList) {
      if (t is! InterfaceType || !t.isDartCoreList) return null;
      final element = _fieldType(field, t.typeArguments.single, member.of!.base, id);
      return element?.asList(nullable: nullable);
    }
    switch (member.kind) {
      case 'entity':
        return t.isDartCoreString ? ValueType(ValueKind.entityId, nullable: nullable, entityRef: member.ref) : null;
      case 'person' || 'placeDescriptor' || 'file' || 'recurrenceRule' || 'union':
        // People, places, files, recurrence rules and unions: the runtime's types.
        final (className, kind) = switch (member.kind) {
          'person' => ('AssistantPerson', ValueKind.person),
          'placeDescriptor' => ('AssistantPlace', ValueKind.place),
          'file' => ('AssistantFile', ValueKind.file),
          'recurrenceRule' => ('AssistantRecurrence', ValueKind.recurrence),
          _ => ('AssistantUnion', ValueKind.union),
        };
        return _isFrom(t, className, exact: true) ? ValueType(kind, nullable: nullable) : null;
      case 'openEnum':
        final app = _openEnums[member.ref];
        if (app != null && t is InterfaceType && t.element.displayName == app.className) {
          return ValueType(ValueKind.enumeration, nullable: nullable, enumRef: member.ref, appEnum: app.className);
        }
        throw InvalidGenerationSourceError(
            '${field.displayName} maps $id, a ${member.ref} whose cases the app defines: '
            'make it an enum annotated @${dartEnumName(member.ref!)}().',
            element: field);
      case 'enum':
        return t is InterfaceType && t.element is EnumElement && t.element.displayName == dartEnumName(member.ref!)
            ? ValueType(ValueKind.enumeration, nullable: nullable, enumRef: member.ref)
            : null;
      default:
        return _valueType(t);
    }
  }

  bool _enumHasCases(String ref) => _catalogs[ref.split('.').first]?.enums[ref]?.cases.isNotEmpty ?? false;

  Future<SchemaDomainModel> _schemaDomain(ClassElement cls, ConstantReader annotation) async {
    final domain = annotation.read('domain').stringValue;
    final catalog = await _catalog(domain, cls);
    if (_syncable(cls) != null) {
      throw InvalidGenerationSourceError('@AssistantSyncable goes on an entity class, not on @${pascal(domain)}Intents.',
          element: cls);
    }
    final intents = [
      for (final intent in catalog.domainIntents)
        if (annotation.peek(intent.name)?.boolValue ?? false) intent,
    ];
    return SchemaDomainModel(
      className: cls.displayName,
      catalog: catalog,
      intents: intents,
      interactions: _interactions(
          annotation, [for (final i in intents) (i, IntentKind.call)], '@${pascal(domain)}Intents', cls),
      undoable: _annotation(cls, 'AssistantUndoable') != null,
      longRunning: _annotation(cls, 'AssistantLongRunning') != null,
      unlock: _unlock(annotation),
      summaries: _summaries(
          annotation, [for (final i in intents) (i, IntentKind.call)], '@${pascal(domain)}Intents', cls),
    );
  }

  /// The `dialogs`, `confirm`, `confirmDeletes` and `replies` of a schema
  /// annotation, checked against the [intents] it turned on.
  Interactions _interactions(
      ConstantReader annotation, List<(IntentSchema, IntentKind)> intents, String name, Element element) {
    Map<String, String> templates(String field) => {
          for (final MapEntry(:key, :value) in annotation.peek(field)?.mapValue.entries ?? const <Never, Never>{}.entries)
            key!.toStringValue()!: value!.toStringValue()!,
        };
    final interactions = Interactions(
      dialogs: templates('dialogs'),
      confirm: templates('confirm'),
      confirmDeletes: annotation.peek('confirmDeletes')?.boolValue ?? true,
      replies: {for (final r in annotation.peek('replies')?.setValue ?? const <Never>{}) r.toStringValue()!},
    );
    if (checkInteractions(interactions, intents, name) case final problem?) {
      throw InvalidGenerationSourceError(problem, element: element);
    }
    return interactions;
  }

  Future<DomainCatalog> _catalog(String domain, Element element) async {
    if (_catalogs[domain] case final cached?) return cached;
    final asset = AssetId(_package, 'lib/src/catalog/$domain.json');
    if (!await step.canRead(asset)) {
      throw InvalidGenerationSourceError(
          'This version of assistant_actions has no "$domain" schemas.', element: element);
    }
    final catalog = DomainCatalog.fromJson((jsonDecode(await step.readAsString(asset)) as Map).cast());
    return _catalogs[domain] = catalog;
  }

  // ── Snapshot answers ──────────────────────────────────────────────────

  SnapshotActionModel _snapshotAction(TopLevelVariableElement variable, ConstantReader annotation,
      List<EntityModel> entities, List<SchemaEntityModel> schemaEntities) {
    InvalidGenerationSourceError error(String message) =>
        InvalidGenerationSourceError('${variable.displayName}: $message', element: variable);

    final value = variable.isConst ? variable.computeConstantValue() : null;
    final type = value?.type;
    if (value == null || type is! InterfaceType || !_isFrom(type, 'SnapshotAnswer', exact: true)) {
      throw error('@AssistantAction on a variable needs a top-level `const` SnapshotAnswer<T>.');
    }
    if (annotation.peek('liveActivity')?.boolValue ?? false) {
      throw error('liveActivity is for functions; a SnapshotAnswer answers in Swift without Dart.');
    }
    if (annotation.peek('summary')?.stringValue != null) {
      throw error('summary is for functions: a SnapshotAnswer has no parameters for Shortcuts to show.');
    }
    final target = type.typeArguments.single;
    final name = target is InterfaceType ? target.element.displayName : null;
    final entity = entities.where((e) => e.className == name).firstOrNull;
    final schemaEntity = schemaEntities.where((e) => e.className == name).firstOrNull;
    if (entity == null && schemaEntity == null) {
      throw error('SnapshotAnswer<${target.getDisplayString()}> needs an @AssistantEntity or schema entity class.');
    }
    final fields = entity?.fields ?? schemaEntity!.fields;
    FieldModel field(String key, String use) =>
        fields.where((f) => f.name == key).firstOrNull ??
        (throw error('$use "$key" is not a published field of $name '
            '(${fields.map((f) => f.name).join(', ')}).'));

    final answer = ConstantReader(value);
    final where = <String, String>{};
    for (final MapEntry(:key, value: expected) in answer.read('where').mapValue.entries) {
      final fieldName = key!.toStringValue()!;
      final f = field(fieldName, 'where');
      final literal = switch (f.type.kind) {
        ValueKind.boolean when expected?.toBoolValue() != null => '${expected!.toBoolValue()}',
        ValueKind.string when expected?.toStringValue() != null => _swiftLiteral(expected!.toStringValue()!),
        ValueKind.integer when expected?.toIntValue() != null => '${expected!.toIntValue()}',
        _ => throw error('where "$fieldName" is ${f.type.dart}; compare it with a matching bool, String or int.'),
      };
      where[fieldName] = literal;
    }
    final sortBy = answer.peek('sortBy')?.stringValue;
    if (sortBy != null && field(sortBy, 'sortBy').type.kind == ValueKind.uri) {
      throw error('sortBy "$sortBy" is a Uri, which has no order.');
    }
    final limit = answer.read('limit').intValue;
    if (limit < 1) throw error('limit must be at least 1.');

    final item = answer.read('item').stringValue;
    final dialog = answer.read('dialog').stringValue;
    for (final placeholder in _placeholders(item)) {
      if (placeholder != 'title') field(placeholder, 'item uses {$placeholder}, but');
    }
    for (final placeholder in _placeholders(dialog)) {
      if (!const {'count', 'items', 'rest'}.contains(placeholder)) {
        throw error('dialog can use {count}, {items} and {rest}, not {$placeholder}.');
      }
    }
    final titleProperty = schemaEntity?.schema.titleProperty;
    return SnapshotActionModel(
      name: variable.displayName,
      title: annotation.read('title').stringValue,
      description: annotation.peek('description')?.stringValue,
      shortcut: _snapshotShortcut(annotation, variable),
      searchKeywords: _strings(annotation, 'searchKeywords'),
      isDiscoverable: annotation.read('isDiscoverable').boolValue,
      collection: entity?.className ?? schemaEntity!.collection,
      fields: fields,
      titleField: titleProperty == null ? null : schemaEntity!.mapping[titleProperty.name]?.name,
      where: where,
      sortBy: sortBy,
      descending: answer.read('descending').boolValue,
      limit: limit,
      item: item,
      dialog: dialog,
      empty: answer.read('empty').stringValue,
      separator: answer.read('separator').stringValue,
      unlock: _unlock(annotation),
    );
  }

  /// Placeholder names in a snapshot template: `{name}` and `{name|one|many}`.
  static Iterable<String> _placeholders(String template) =>
      RegExp(r'\{(\w+)(\|[^}]*)?\}').allMatches(template).map((m) => m.group(1)!);

  static String _swiftLiteral(String s) =>
      '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';

  // ── Helpers ───────────────────────────────────────────────────────────

  ValueType? _valueType(DartType type) {
    final nullable = type.nullabilitySuffix == NullabilitySuffix.question;
    final kind = switch (type) {
      _ when type.isDartCoreString => ValueKind.string,
      _ when type.isDartCoreInt => ValueKind.integer,
      _ when type.isDartCoreDouble => ValueKind.decimal,
      _ when type.isDartCoreBool => ValueKind.boolean,
      InterfaceType(:final element) when element.library.isDartCore && element.displayName == 'DateTime' =>
        ValueKind.dateTime,
      InterfaceType(:final element) when element.library.isDartCore && element.displayName == 'Uri' =>
        ValueKind.uri,
      InterfaceType(:final element) when element.library.isDartCore && element.displayName == 'Duration' =>
        ValueKind.duration,
      _ => null,
    };
    return kind == null ? null : ValueType(kind, nullable: nullable);
  }

  /// The first annotation on [element] whose class is [name] from this package.
  ConstantReader? _annotation(Element element, String name) {
    for (final a in element.metadata.annotations) {
      final value = a.computeConstantValue();
      if (value != null && _isFrom(value.type, name, exact: true)) return ConstantReader(value);
    }
    return null;
  }

  ConstantReader? _schemaAnnotation(ClassElement cls, [String base = 'SchemaEntity']) {
    for (final a in cls.metadata.annotations) {
      final value = a.computeConstantValue();
      if (value != null && _isFrom(value.type, base)) return ConstantReader(value);
    }
    return null;
  }

  /// Whether [type] is (or, unless [exact], extends) class [name] from
  /// `package:assistant_actions`.
  bool _isFrom(DartType? type, String name, {bool exact = false}) {
    if (type is! InterfaceType) return false;
    bool matches(InterfaceType t) =>
        t.element.displayName == name &&
        t.element.library.uri.scheme == 'package' &&
        t.element.library.uri.pathSegments.first == _package;
    return matches(type) || (!exact && type.allSupertypes.any(matches));
  }

  static String _titleCase(String name) {
    final words = name.replaceAllMapped(RegExp('([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}');
    return words.isEmpty ? words : words[0].toUpperCase() + words.substring(1).toLowerCase();
  }
}
