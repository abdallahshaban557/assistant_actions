import 'dart:convert';

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'catalog.dart';
import 'model.dart';

const _package = 'assistant_actions';

/// Reads the app's annotations from the definitions library and everything
/// it imports from the app's own package.
class ModelReader {
  ModelReader(this.step);

  final BuildStep step;
  final _catalogs = <String, DomainCatalog>{};

  Future<AppModel?> read(LibraryElement library) async {
    final app = _annotation(library, 'AssistantActionsApp');
    if (app == null) {
      log.warning('${library.uri} has no @AssistantActionsApp(name: ...) library annotation; '
          'nothing generated.');
      return null;
    }
    final libraries = _ownLibraries(library);
    final entities = <EntityModel>[];
    final schemaEntities = <SchemaEntityModel>[];
    for (final lib in libraries) {
      for (final cls in lib.classes) {
        if (_annotation(cls, 'AssistantEntity') case final a?) entities.add(_entity(cls, a));
        if (_schemaAnnotation(cls) case final a?) schemaEntities.add(await _schemaEntity(cls, a));
      }
    }
    final actions = <ActionModel>[];
    for (final lib in libraries) {
      for (final fn in lib.topLevelFunctions) {
        if (_annotation(fn, 'AssistantAction') case final a?) actions.add(_action(fn, a, entities));
      }
    }
    final ids = <String>{};
    for (final a in actions) {
      if (!ids.add(a.id)) {
        throw InvalidGenerationSourceError('Two @AssistantAction functions are named ${a.id}.');
      }
    }
    return AppModel(
      appName: app.read('name').stringValue,
      actions: actions,
      entities: entities,
      schemaEntities: schemaEntities,
    );
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
    return EntityModel(
      className: cls.displayName,
      library: cls.library.uri,
      title: annotation.read('title').stringValue,
      idField: id.$1.displayName,
      titleGetter: title.$1.displayName,
      subtitleGetter: subtitle?.$1.displayName,
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
        final type = _valueType(field.type);
        final expected = dartTypeFor(property.type)?.replaceAll('?', '');
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

    return SchemaEntityModel(
      className: cls.displayName,
      library: cls.library.uri,
      catalog: catalog,
      schema: schema,
      idField: id.$1.displayName,
      mapping: mapping,
      intents: intents,
      containers: containers,
    );
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
        'enum' => catalog.enums[type.ref]?.cases.isNotEmpty ?? false,
        _ => false,
      };

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

  // ── Actions ───────────────────────────────────────────────────────────

  ActionModel _action(TopLevelFunctionElement fn, ConstantReader annotation, List<EntityModel> entities) {
    final params = [
      for (final p in fn.formalParameters) _param(fn, p, entities),
    ];
    final runs = RunsModel.values[annotation.read('runs').objectValue.getField('index')!.toIntValue()!];
    final dialog = annotation.peek('dialog')?.stringValue;
    if (dialog != null) {
      for (final match in RegExp(r'\{(\w+)\}').allMatches(dialog)) {
        if (!params.any((p) => p.name == match.group(1))) {
          throw InvalidGenerationSourceError('dialog uses {${match.group(1)}}, which is not a parameter.',
              element: fn);
        }
      }
    }
    ShortcutModel? shortcut;
    if (annotation.peek('shortcut') case final s? when !s.isNull) {
      final phrases = [for (final p in s.read('phrases').listValue) p.toStringValue()!];
      for (final phrase in phrases) {
        if (!phrase.contains('{app}')) {
          throw InvalidGenerationSourceError('Shortcut phrase "$phrase" must contain {app}.', element: fn);
        }
        final other = RegExp(r'\{(\w+)\}').allMatches(phrase).map((m) => m.group(1)).where((n) => n != 'app');
        if (other.isNotEmpty) {
          throw InvalidGenerationSourceError(
              'Shortcut phrase "$phrase": only {app} is supported in phrases for now.', element: fn);
        }
      }
      shortcut = ShortcutModel(
        phrases: phrases,
        shortTitle: s.read('shortTitle').stringValue,
        systemImage: s.read('systemImage').stringValue,
      );
    }

    var result = fn.returnType;
    if (result.isDartAsyncFuture || result.isDartAsyncFutureOr) {
      result = (result as InterfaceType).typeArguments.single;
    }
    final returnsString = result.isDartCoreString;
    if (!returnsString && result is! VoidType && !result.isDartCoreNull) {
      throw InvalidGenerationSourceError(
          'An @AssistantAction returns void or String (optionally in a Future), not ${result.getDisplayString()}.',
          element: fn);
    }
    if (runs == RunsModel.deferred && returnsString) {
      log.warning('${fn.displayName} runs deferred, so Siri says its dialog, not the String it returns.');
    }
    return ActionModel(
      functionName: fn.displayName,
      library: fn.library.uri,
      title: annotation.read('title').stringValue,
      description: annotation.peek('description')?.stringValue,
      runs: runs,
      dialog: dialog,
      shortcut: shortcut,
      params: params,
      returnsString: returnsString,
    );
  }

  ParamModel _param(TopLevelFunctionElement fn, FormalParameterElement p, List<EntityModel> entities) {
    final meta = _annotation(p, 'Param');
    final name = p.displayName;
    final title = meta?.peek('title')?.stringValue ?? _titleCase(name);
    final prompt = meta?.peek('prompt')?.stringValue;
    final type = p.type;
    final nullable = type.nullabilitySuffix == NullabilitySuffix.question;
    if (type is InterfaceType) {
      final entity = entities.where((e) => e.className == type.element.displayName).firstOrNull;
      if (entity != null) {
        return ParamModel(
            name: name, title: title, prompt: prompt, named: p.isNamed, entity: entity, entityNullable: nullable);
      }
    }
    final value = _valueType(type);
    if (value == null) {
      throw InvalidGenerationSourceError(
          'Parameter $name: ${type.getDisplayString()} is not supported. Use String, int, double, bool, '
          'DateTime, Uri or an @AssistantEntity class.',
          element: fn);
    }
    return ParamModel(name: name, title: title, prompt: prompt, named: p.isNamed, value: value);
  }

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

  ConstantReader? _schemaAnnotation(ClassElement cls) {
    for (final a in cls.metadata.annotations) {
      final value = a.computeConstantValue();
      if (value != null && _isFrom(value.type, 'SchemaEntity')) return ConstantReader(value);
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
