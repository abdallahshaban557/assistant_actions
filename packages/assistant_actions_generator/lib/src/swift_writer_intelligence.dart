part of 'swift_writer.dart';

/// Apple Intelligence in context: `Transferable` entities (with the exports
/// Apple's query schemas ask for), deep links, predictions and donations,
/// on-screen entities, importing queries and Visual Intelligence search.
extension _Intelligence on SwiftWriter {
  static const _none = <String, num>{'iOS': 0, 'macOS': 0};

  /// `IntentValueRepresentation`, which exports system values.
  static const _valueRepresentation = <String, num>{'iOS': 26.4, 'macOS': 26.4};

  /// `URLRepresentableEntity` and `URLRepresentableIntent`.
  static const _urlFloor = <String, num>{'iOS': 18, 'macOS': 15};

  /// `IntentValueQuery`.
  static const _queryFloor = <String, num>{'iOS': 26, 'macOS': 26};

  /// `SemanticContentDescriptor` (VisualIntelligence).
  static const _visualFloor = <String, num>{'iOS': 26, 'macOS': 27};

  /// The system value types an exporting query can hand over.
  static const _exportable = {'placeDescriptor', 'person'};

  /// A Swift condition that Dart can take a call now: with
  /// `@AssistantBackground()`, the headless engine starts if the app has
  /// none (iOS); otherwise wait briefly for the app's own Dart.
  String get _dartReady => _background
      ? 'await AssistantBackground.shared.prepare()'
      : 'await AssistantBridge.shared.waitUntilReady(timeout: 3)';

  /// The schema id of the adopted entity class [className], if it is one.
  String? _schemaOf(String className) =>
      app.schemaEntities.where((s) => s.className == className).firstOrNull?.schema.id;

  /// Makes the `EntityIdentifier` of the item with Dart id `[id]`.
  String _identifierOf(String swift, String className, String id) => _isFileEntity(_schemaOf(className))
      ? 'EntityIdentifier(for: $swift.self, identifier: AssistantFileIDs.identifier($id))'
      : 'EntityIdentifier(for: $swift.self, identifier: $id)';

  /// The actions the user runs: not Focus filters, which the system sets.
  Iterable<ActionModel> get _userActions => app.actions.where((a) => a.focusFilter == null);

  void _intelligence() {
    for (final e in app.entities) {
      _plainTransferable(e);
      if (e.url case final url?) _urlEntity(e.swiftName, url, 'public ', _none);
    }
    for (final s in app.schemaEntities) {
      _schemaTransferable(s);
      if (s.url case final url?) _urlEntity(s.swiftName, url, '', _entityFloor(s.schema));
    }
    // Focus filters are set by the system, not run by the user: not predicted or donated.
    for (final a in _userActions) {
      _prediction(a);
    }
    for (final a in app.snapshotActions) {
      _out.writeln('''
extension ${a.swiftName}: PredictableIntent {
  public static var predictionConfiguration: some IntentPredictionConfiguration {
    IntentPrediction(displayRepresentation: { DisplayRepresentation(title: "${SwiftWriter._escape(a.title)}") })
  }
}
''');
    }
    for (final s in app.schemaEntities) {
      for (final q in s.queries) {
        _importQuery(s, q);
      }
    }
    _visualSearch();
    _hostCalls();
  }

  // ── Transferable ──

  void _plainTransferable(EntityModel e) {
    final name = e.swiftName;
    final parts = [
      'title',
      'AssistantValues.encode(subtitle)',
      for (final q in _plainQueryables(e))
        if (q.kind == 'string') 'AssistantValues.encode(${q.member})',
    ];
    _out.writeln('''
/// Apple Intelligence can hand a `${e.className}` to other apps, as text.
extension $name: Transferable {
  public static var transferRepresentation: some TransferRepresentation {
    ProxyRepresentation(exporting: { (item: $name) in item.transferText })
  }

  /// The item as text: its title, subtitle and text fields.
  public var transferText: String { AssistantValues.text([${parts.join(', ')}]) }
}
''');
  }

  /// The exporting queries of [s] the generated entity can serve: those whose
  /// member is mapped and has the exported type.
  List<QuerySchema> _exports(SchemaEntityModel s) => [
        for (final q in s.catalog.queriesFor(s.schema))
          if (q.exports &&
              q.property != null &&
              s.mapping.containsKey(q.property) &&
              _exportable.contains(q.type.kind) &&
              s.schema.property(q.property!)?.type.base.kind == q.type.kind)
            q,
      ];

  void _schemaTransferable(SchemaEntityModel s) {
    final schema = s.schema;
    final name = s.swiftName;
    final exports = _exports(s);
    var floor = _entityFloor(schema);
    for (final q in exports) {
      floor = SwiftWriter._max(SwiftWriter._max(floor, _valueRepresentation), q.availability);
    }
    if (_availability(floor) != _availability(_entityFloor(schema))) {
      // Transferable implies Sendable; declared only in the later extension,
      // Sendable would be later than the entity itself.
      _out
        ..writeln(_availability(_entityFloor(schema)))
        ..writeln('extension $name: Sendable {}')
        ..writeln();
    }
    final parts = [
      _titleExpr(schema, ''),
      for (final p in schema.properties)
        if (p.name != schema.titleProperty?.name &&
            s.mapping.containsKey(p.name) &&
            const {'string', 'attributedString', 'person', 'placeDescriptor'}.contains(p.type.base.kind))
          'AssistantValues.encode(${swiftName(p.name)})',
    ];
    _out
      ..writeln('/// Apple Intelligence can hand a `${s.className}` to other apps, as text'
          '${exports.isEmpty ? '' : ' and its ${exports.map((q) => '`${q.property}`').join(', ')} (${exports.map((q) => '`${q.id}`').join(', ')})'}.')
      ..writeln(_availability(floor))
      ..writeln('extension $name: Transferable {')
      ..writeln('  static var transferRepresentation: some TransferRepresentation {')
      ..writeln('    ProxyRepresentation(exporting: { (item: $name) in item.transferText })');
    if (s.isFile) {
      // A file entity hands over the file itself, too.
      _out
        ..writeln('    FileRepresentation(exportedContentType: .data) { (item: $name) in')
        ..writeln('      guard let url = AssistantFileIDs.url(item.dartID) else { throw AssistantTransferError.noValue("file") }')
        ..writeln('      return SentTransferredFile(url)')
        ..writeln('    }');
    }
    for (final q in exports) {
      final member = swiftName(q.property!);
      final type = _swiftType(q.type);
      if (schema.property(q.property!)!.type.isOptional) {
        _out
          ..writeln(_newSdkStart)
          ..writeln('    IntentValueRepresentation(exporting: { (item: $name) throws -> $type in')
          ..writeln('      guard let value = item.$member else { throw AssistantTransferError.noValue("${q.property}") }')
          ..writeln('      return value')
          ..writeln('    })')
          ..writeln(_newSdkEnd);
      } else {
        _out
          ..writeln(_newSdkStart)
          ..writeln('    IntentValueRepresentation(exporting: { (item: $name) -> $type in item.$member })')
          ..writeln(_newSdkEnd);
      }
    }
    _out
      ..writeln('  }')
      ..writeln()
      ..writeln('  /// The item as text: its title and text, people and places.')
      ..writeln('  var transferText: String { AssistantValues.text([${parts.join(', ')}]) }')
      ..writeln('}')
      ..writeln();
  }

  // ── Deep links ──

  /// A Swift `EntityURLRepresentation` literal for [template]: `{id}` →
  /// `\(.id)`.
  static String _urlLiteral(String template) =>
      '"${template.split('{id}').map(SwiftWriter._escape).join(r'\(.id)')}"';

  void _urlEntity(String name, String url, String access, Map<String, num> floor) {
    _out.writeln('''
/// Items link to `${SwiftWriter._escape(url)}`, which the app opens as a deep link.
${_availability(SwiftWriter._max(floor, _urlFloor))}
extension $name: URLRepresentableEntity {
  ${access}static var urlRepresentation: URLRepresentation { ${_urlLiteral(url)} }
}
''');
  }

  /// `system.open` for an entity with a deep link: the system opens the link
  /// (`URLRepresentableIntent`), and the app routes it.
  void _urlOpenIntent(String className, String swift, Map<String, num> floor) {
    _out.writeln('''
/// `system.open` for `$className` → opens the item's link, which the app handles as a deep link.
${_availability(SwiftWriter._max(floor, _urlFloor))}
@AppIntent(schema: .system.open)
struct Open${className}Intent: URLRepresentableIntent {
${_unlockMember(_entityUnlock(className).forSchema(_systemOpen))}  var target: $swift
}
''');
  }

  // ── Predictions and donations ──

  /// A Swift `String` expression describing parameter [p], for predictions.
  /// A Swift `String` expression describing parameter [p], for
  /// predictions; null for values with no short text.
  String? _predictionText(ParamModel p) {
    final n = swiftName(p.name);
    final optional = _optional(p);
    if (p.entity != null) {
      if (p.entityList) {
        return optional ? '$n?.map(\\.title).joined(separator: ", ") ?? ""' : '$n.map(\\.title).joined(separator: ", ")';
      }
      return optional ? '$n?.title ?? ""' : '$n.title';
    }
    if (p.schemaEntity != null) {
      const display = r'String(localized: $0.displayRepresentation.title)';
      if (p.entityList) {
        return optional
            ? '$n?.map { $display }.joined(separator: ", ") ?? ""'
            : '$n.map { $display }.joined(separator: ", ")';
      }
      return optional ? '$n.map { $display } ?? ""' : 'String(localized: $n.displayRepresentation.title)';
    }
    final v = p.value!;
    String? one(String x) => switch (v.kind) {
          ValueKind.string => x,
          ValueKind.dateTime => '$x.formatted(date: .abbreviated, time: .shortened)',
          ValueKind.uri => '$x.absoluteString',
          ValueKind.duration ||
          ValueKind.length ||
          ValueKind.mass ||
          ValueKind.temperature ||
          ValueKind.volume ||
          ValueKind.speed ||
          ValueKind.energy =>
            '$x.formatted()',
          ValueKind.currency => '$x.amount.formatted(.currency(code: $x.currencyCode))',
          ValueKind.enumeration => '$x.rawValue',
          ValueKind.integer || ValueKind.decimal || ValueKind.boolean => '"\\($x)"',
          // People, places and files have no short text.
          _ => null,
        };
    final each = one(r'$0');
    if (each == null) return null;
    if (v.list) {
      final joined = '.map { $each }.joined(separator: ", ")';
      return optional ? '$n?$joined ?? ""' : '$n$joined';
    }
    if (!optional) return one(n);
    return v.kind == ValueKind.string ? '$n ?? ""' : '$n.map { $each } ?? ""';
  }

  /// `PredictableIntent`, so Siri suggests the action with the values the
  /// app donated (`AssistantDonations`).
  void _prediction(ActionModel a) {
    final title = '"${SwiftWriter._escape(a.title)}"';
    final floor = _actionFloor(a);
    if (_above(floor)) _out.writeln(_availability(floor));
    _out
      ..writeln('extension ${a.swiftName}: PredictableIntent {')
      ..writeln('  public static var predictionConfiguration: some IntentPredictionConfiguration {');
    // IntentPrediction takes up to 15 parameters.
    if (a.params.isEmpty || a.params.length > 15) {
      _out.writeln('    IntentPrediction(displayRepresentation: { DisplayRepresentation(title: $title) })');
    } else {
      final paths = [for (final p in a.params) '\\.\$${swiftName(p.name)}'];
      final keys = paths.length == 1 ? paths.single : '(${paths.join(', ')})';
      _out
        ..writeln('    IntentPrediction(parameters: $keys) { ${a.params.map((p) => swiftName(p.name)).join(', ')} in')
        ..writeln('      DisplayRepresentation(')
        ..writeln('        title: $title,')
        ..writeln('        subtitle: "\\(AssistantValues.text([${a.params.map(_predictionText).nonNulls.join(', ')}], separator: ", "))")')
        ..writeln('    }');
    }
    _out
      ..writeln('  }')
      ..writeln('}')
      ..writeln();
  }

  /// A Swift expression (optional) of [p]'s parameter type, without `?`,
  /// decoded from [raw]: what Dart's `AssistantDonations` sent, encoded the
  /// way the registry decodes it.
  String _decodeDonated(ParamModel p, String raw) {
    if (p.isEntity) {
      final className = p.entityClassName;
      final swift = p.entitySwiftName;
      String find(String id) => 'AssistantSnapshot.records("$className").first(where: { \$0.id == $id })';
      if (p.entityList) {
        return 'AssistantValues.strings($raw)?.compactMap({ id in ${find('id')}.map($swift.init(record:)) })';
      }
      return 'AssistantValues.string($raw).flatMap({ id in ${find('id')} }).map($swift.init(record:))';
    }
    final v = p.value!;
    String one(String x) => switch (v.kind) {
          ValueKind.duration => 'AssistantValues.double($x).map({ Measurement(value: \$0, unit: UnitDuration.seconds) })',
          ValueKind.enumeration =>
            'AssistantValues.string($x).flatMap(${v.enumRef == null ? '${v.appEnum}Enum' : _enumName(v.enumRef!)}.init(rawValue:))',
          _ => 'AssistantValues.${v.swiftDecoder}($x)',
        };
    return v.list ? 'AssistantValues.items($raw)?.compactMap({ ${one(r'$0')} })' : one(raw);
  }

  /// Entities with an open intent (`system.open` on), with its availability.
  List<(String, String, Map<String, num>)> get _openTargets => [
        if (app.opensEntities) ...[
          for (final s in app.schemaEntities)
            if (!s.hasOwnOpen) (s.className, s.swiftName, SwiftWriter._max(_systemOpen.availability, _entityFloor(s.schema))),
          for (final e in app.entities) (e.className, e.swiftName, SwiftWriter._max(_systemOpen.availability, _urlFloor)),
        ],
      ];

  IntentSchema get _systemOpen => app.schemaDomains.expand((d) => d.intents).firstWhere((i) => i.id == 'system.open');

  /// A Swift guard condition list making sure [floor] is available.
  String _available(Map<String, num> floor) {
    final (iOS, macOS) = _versions(floor);
    if (iOS.isInfinite) return '#available(macOS ${SwiftWriter._version(macOS)}, *)';
    if (macOS.isInfinite) return '#available(iOS ${SwiftWriter._version(iOS)}, *)';
    return '#available(iOS ${SwiftWriter._version(iOS)}, macOS ${SwiftWriter._version(macOS)}, *)';
  }

  /// Whether [floor] needs no check at the iOS 17 / macOS 14 deployment
  /// targets.
  bool _always(Map<String, num> floor) {
    final (iOS, macOS) = _versions(floor);
    return iOS <= 17 && macOS <= 14;
  }

  /// Default Swift value for an unmapped required parameter on a donated schema intent.
  String _donatedFallback(SchemaType t, EntitySchema owner, FixedInstance? fixed) {
    if (t.kind == 'entity') {
      if (fixed != null) return _default(t, owner, fixed);
      if (_adopted[t.ref] case final s?) return '${s.swiftName}.reference("", resolve: false)';
    }
    return _fallback(t, owner);
  }

  /// Swift lines populating and donating a schema [intent] of [kind] on [owner].
  List<String> _donateSchemaLines(SchemaEntityModel? owner, IntentSchema intent, IntentKind kind) {
    final structName = '${owner?.className ?? pascal(intent.domain)}${pascal(intent.name)}Intent';
    switch (kind) {
      case IntentKind.record:
        return [
          'let intent = $structName()',
          'IntentDonationManager.shared.donate(intent: intent)',
          'return true',
        ];
      case IntentKind.delete:
        final s = owner!;
        return [
          'guard let id = AssistantValues.string(values["id"]) else { return false }',
          'let intent = $structName()',
          'intent.entities = [${s.swiftName}.reference(id, resolve: true)]',
          'IntentDonationManager.shared.donate(intent: intent)',
          'return true',
        ];
      case IntentKind.create:
        final s = owner!;
        final lines = <String>['let intent = $structName()'];
        for (final p in intent.parameters) {
          final n = swiftName(p.name);
          if (s.mapping[p.name] case final field?) {
            if (p.type.isOptional) {
              lines.add('if let raw = values["${field.name}"], !(raw is NSNull) { intent.$n = ${_decode(p.type, 'raw', s.schema)} }');
            } else {
              lines.add('intent.$n = ${_decode(p.type, 'values["${field.name}"]', s.schema)}');
            }
          } else {
            final fixed = s.containers[p.name] ?? _fixed[p.type.base.ref];
            if (!p.type.isOptional) {
              lines.add('intent.$n = ${_donatedFallback(p.type, s.schema, fixed)}');
            } else if (fixed != null) {
              lines.add('intent.$n = ${_default(p.type, s.schema, fixed)}');
            }
          }
        }
        lines.addAll([
          'IntentDonationManager.shared.donate(intent: intent)',
          'return true',
        ]);
        return lines;
      case IntentKind.update || IntentKind.append:
        final s = owner!;
        final sets = <String>[];
        var usesFields = false;
        for (final p in intent.parameters) {
          if (p.name == 'target') continue;
          final n = swiftName(p.name);
          if (s.mapping[p.name] case final field?) {
            usesFields = true;
            if (p.type.isOptional) {
              sets.add('if let raw = fields["${field.name}"], !(raw is NSNull) { intent.$n = ${_decode(p.type, 'raw', s.schema)} }');
            } else {
              sets.add('intent.$n = ${_decode(p.type, 'fields["${field.name}"]', s.schema)}');
            }
          } else {
            final fixed = s.containers[p.name] ?? _fixed[p.type.base.ref];
            if (!p.type.isOptional) {
              sets.add('intent.$n = ${_donatedFallback(p.type, s.schema, fixed)}');
            } else if (fixed != null) {
              sets.add('intent.$n = ${_default(p.type, s.schema, fixed)}');
            }
          }
        }
        return [
          'guard let id = AssistantValues.string(values["id"]) else { return false }',
          if (usesFields) 'let fields = values["fields"] as? [String: Any] ?? [:]',
          'let intent = $structName()',
          'intent.target = ${s.swiftName}.reference(id, resolve: true)',
          ...sets,
          'IntentDonationManager.shared.donate(intent: intent)',
          'return true',
        ];
      case IntentKind.call:
        final guards = <String>[];
        final sets = <String>[];
        for (final p in intent.parameters) {
          final n = swiftName(p.name);
          final raw = 'values["${p.name}"]';
          if (callArg(p) == null) {
            if (!p.type.isOptional && p.type.base.isList) sets.add('intent.$n = []');
            continue;
          }
          final base = p.type.base;
          if (!base.isList && base.kind == 'entity') {
            final ref = base.ref!;
            if (_adopted[ref] case final s?) {
              final decode = 'AssistantValues.string($raw).map({ ${s.swiftName}.reference(\$0, resolve: true) })';
              if (p.type.isOptional) {
                sets.add('intent.$n = $decode');
              } else {
                guards.add('guard let ${p.name}Value = $decode else { return false }');
                sets.add('intent.$n = ${p.name}Value');
              }
            } else if (_fixed.containsKey(ref)) {
              if (p.type.isOptional) {
                sets.add('if AssistantValues.string($raw) != nil { intent.$n = ${_containerName(ref)}.fixed }');
              } else {
                sets.add('intent.$n = ${_containerName(ref)}.fixed');
              }
            }
            continue;
          }
          if (base.isList && base.of!.base.kind == 'entity') {
            final ref = base.of!.base.ref!;
            if (_adopted[ref] case final s?) {
              var decode = 'AssistantValues.strings($raw)?.map({ ${s.swiftName}.reference(\$0, resolve: true) })';
              if (base.kind == 'set') decode = '($decode).map(Set.init)';
              if (p.type.isOptional) {
                sets.add('intent.$n = $decode');
              } else {
                guards.add('guard let ${p.name}Value = $decode else { return false }');
                sets.add('intent.$n = ${p.name}Value');
              }
            } else if (_fixed.containsKey(ref)) {
              final fixedItem = '${_containerName(ref)}.fixed';
              var decode = 'AssistantValues.strings($raw)?.map({ _ in $fixedItem })';
              if (base.kind == 'set') decode = '($decode).map(Set.init)';
              if (p.type.isOptional) {
                sets.add('intent.$n = $decode');
              } else {
                sets.add('intent.$n = $decode ?? []');
              }
            } else if (!p.type.isOptional) {
              sets.add('intent.$n = []');
            }
            continue;
          }
          if (base.isList) {
            final each = _decodeSchemaScalar(base.of!.base, r'$0');
            if (each == null) {
              if (!p.type.isOptional) sets.add('intent.$n = []');
              continue;
            }
            var decode = 'AssistantValues.items($raw)?.compactMap({ $each })';
            if (base.kind == 'set') decode = '($decode).map(Set.init)';
            if (p.type.isOptional) {
              sets.add('intent.$n = $decode');
            } else {
              guards.add('guard let ${p.name}Value = $decode else { return false }');
              sets.add('intent.$n = ${p.name}Value');
            }
            continue;
          }
          final decode = _decodeSchemaScalar(base, raw);
          if (decode != null) {
            if (p.type.isOptional) {
              sets.add('intent.$n = $decode');
            } else {
              guards.add('guard let ${p.name}Value = $decode else { return false }');
              sets.add('intent.$n = ${p.name}Value');
            }
          }
        }
        return [
          ...guards,
          'let intent = $structName()',
          ...sets,
          'IntentDonationManager.shared.donate(intent: intent)',
          'return true',
        ];
    }
  }

  /// The generated host calls (`AssistantActionsAppHostCalls`): how
  /// collections' ids become `EntityIdentifier`s for on-screen entities,
  /// and donations.
  void _hostCalls() {
    final opens = _openTargets;
    final focusFilter = app.actions.where((a) => a.focusFilter != null).firstOrNull;
    final actions = [
      for (final a in _userActions) (a.id, a.swiftName, a.params, _actionFloor(a)),
      for (final a in app.snapshotActions) (a.id, a.swiftName, const <ParamModel>[], _none),
    ];
    final schemaDonations = [
      for (final s in app.schemaEntities)
        for (final (intent, kind) in s.intents)
          if (canDonateSchemaIntent(app, s, intent, kind))
            (
              key: kind == IntentKind.record ? recordActionId(s, intent) : callActionId(s, intent),
              owner: s as SchemaEntityModel?,
              intent: intent,
              kind: kind,
            ),
      for (final d in app.schemaDomains)
        for (final intent in d.intents)
          if (canDonateSchemaIntent(app, null, intent, IntentKind.call))
            (
              key: callActionId(null, intent),
              owner: null as SchemaEntityModel?,
              intent: intent,
              kind: IntentKind.call,
            ),
    ];
    final hasActionDonations = actions.isNotEmpty || schemaDonations.isNotEmpty;
    _out
      ..writeln('/// Found by name by `AssistantHostCalls` in the runtime: what Dart\'s')
      ..writeln('/// `AssistantActions.showing`, `donate` and `AssistantDonations` need.')
      ..writeln('@objc(AssistantActionsAppHostCalls)')
      ..writeln('public final class AssistantActionsAppHostCalls: NSObject, AssistantHostCallsProvider {')
      ..writeln('  @MainActor')
      ..writeln('  public static func registerAll() {');
    final identified = [
      for (final e in app.entities) (e.className, e.swiftName, _none),
      for (final s in app.schemaEntities) (s.className, s.swiftName, _entityFloor(s.schema)),
    ];
    for (final (collection, swift, floor) in identified) {
      if (_always(floor)) {
        _out.writeln('    AssistantContext.register("$collection") { ${_identifierOf(swift, collection, r'$0')} }');
      } else {
        _out
          ..writeln('    AssistantContext.register("$collection") { id in')
          ..writeln('      guard ${_available(floor)} else { return nil }')
          ..writeln('      return ${_identifierOf(swift, collection, 'id')}')
          ..writeln('    }');
      }
    }
    if (opens.isNotEmpty) _out.writeln('    AssistantHostCalls.register("donate.entity") { args in donateEntity(args) }');
    if (hasActionDonations) _out.writeln('    AssistantHostCalls.register("donate.action") { args in donateAction(args) }');
    if (focusFilter != null) {
      _out.writeln('    AssistantHostCalls.register("focusFilter.current") { args in queryFocusFilter(args) }');
    }
    _out.writeln('  }');

    if (opens.isNotEmpty) {
      _out
        ..writeln()
        ..writeln('  /// Donates the open intent of the item Dart named: the user opened it.')
        ..writeln('  @MainActor')
        ..writeln('  private static func donateEntity(_ args: [String: Any]) -> Bool {')
        ..writeln('    guard let collection = args["collection"] as? String, let id = args["id"] as? String else { return false }')
        ..writeln('    switch collection {');
      for (final (className, swift, floor) in opens) {
        _out
          ..writeln('    case "$className":')
          ..writeln(_always(floor) ? '      guard' : '      guard ${_available(floor)},')
          ..writeln('        let record = AssistantSnapshot.records("$className").first(where: { \$0.id == id })')
          ..writeln('      else { return false }')
          ..writeln('      let intent = Open${className}Intent()')
          ..writeln('      intent.target = $swift(record: record)')
          ..writeln('      IntentDonationManager.shared.donate(intent: intent)')
          ..writeln('      return true');
      }
      _out
        ..writeln('    default:')
        ..writeln('      return false')
        ..writeln('    }')
        ..writeln('  }');
    }

    if (hasActionDonations) {
      final cases = StringBuffer();
      for (final (id, swift, params, floor) in actions) {
        cases.writeln('    case "$id":');
        if (_above(floor)) cases.writeln('      guard ${_available(floor)} else { return false }');
        final sets = <String>[];
        for (final p in params) {
          final n = swiftName(p.name);
          final decode = _decodeDonated(p, 'values["${p.name}"]');
          if (_optional(p)) {
            // Dart sent null, or left a default Swift can't state to Dart.
            sets.add('intent.$n = $decode');
          } else if (p.swiftDefault != null && p.options == null) {
            sets.add('if let value = $decode { intent.$n = value }');
          } else {
            cases.writeln('      guard let ${p.name}Value = $decode else { return false }');
            sets.add('intent.$n = ${p.name}Value');
          }
        }
        cases.writeln('      let intent = $swift()');
        for (final line in sets) {
          cases.writeln('      $line');
        }
        cases
          ..writeln('      IntentDonationManager.shared.donate(intent: intent)')
          ..writeln('      return true');
      }
      for (final d in schemaDonations) {
        final floor = _schemaIntentFloor(d.owner, d.intent, d.kind);
        final (iOS, macOS) = _versions(floor);
        final osGuard = macOS.isInfinite ? 'iOS' : (iOS.isInfinite ? 'macOS' : null);
        final bodyLines = <String>[
          if (osGuard == 'iOS' && iOS > _baseFloor['iOS']!)
            'guard #available(iOS ${SwiftWriter._version(iOS)}, *) else { return false }'
          else if (osGuard == 'macOS' && macOS > _baseFloor['macOS']!)
            'guard #available(macOS ${SwiftWriter._version(macOS)}, *) else { return false }'
          else if (osGuard == null && _above(floor))
            'guard ${_available(floor)} else { return false }',
          ..._donateSchemaLines(d.owner, d.intent, d.kind),
        ];
        var wrapped = bodyLines;
        if (osGuard != null) {
          wrapped = ['#if os($osGuard)', for (final l in wrapped) '  $l', '#else', '  return false', '#endif'];
        }
        final framework = _optionalFramework(d.intent);
        if (framework != null) {
          wrapped = ['#if canImport($framework)', for (final l in wrapped) '  $l', '#else', '  return false', '#endif'];
        }
        cases.writeln('    case "${d.key}":');
        for (final line in wrapped) {
          cases.writeln('      $line');
        }
      }
      final casesText = cases.toString();
      _out
        ..writeln()
        ..writeln('  /// Donates the action Dart ran, with its arguments.')
        ..writeln('  @MainActor')
        ..writeln('  private static func donateAction(_ args: [String: Any]) -> Bool {')
        ..writeln('    guard let action = args["action"] as? String else { return false }');
      if (casesText.contains('values[')) _out.writeln('    let values = args["args"] as? [String: Any] ?? [:]');
      _out
        ..writeln('    switch action {')
        ..write(casesText)
        ..writeln('    default:')
        ..writeln('      return false')
        ..writeln('    }')
        ..writeln('  }');
    }
    if (focusFilter != null) {
      final focusFloor = _actionFloor(focusFilter);
      _out
        ..writeln()
        ..writeln('  /// Queries `${focusFilter.swiftName}.current` on cold start.')
        ..writeln('  @MainActor')
        ..writeln('  private static func queryFocusFilter(_ args: [String: Any]) -> [String: Any] {');
      if (_above(focusFloor)) {
        _out.writeln('    guard ${_available(focusFloor)} else { return ["none": true] }');
      }
      _out
        ..writeln('    let requestId = args["requestId"] as? String ?? ""')
        ..writeln('    Task { @MainActor in')
        ..writeln('      do {')
        ..writeln('        let current = try await ${focusFilter.swiftName}.current')
        ..writeln(focusFilter.params.isEmpty ? '        let params: [String: Any] = [:]' : '        let params: [String: Any] = [');
      for (final p in focusFilter.params) {
        final expr = _encodeFocusCurrentParam(p);
        _out.writeln('          "${p.name}": $expr,');
      }
      if (focusFilter.params.isNotEmpty) _out.writeln('        ]');
      _out
        ..writeln('        _ = try? await AssistantBridge.shared.perform(')
        ..writeln('          "assistant_actions.focusFilterResult",')
        ..writeln('          args: ["requestId": requestId, "action": "${focusFilter.id}", "params": params])')
        ..writeln('      } catch {')
        ..writeln('        _ = try? await AssistantBridge.shared.perform(')
        ..writeln('          "assistant_actions.focusFilterResult",')
        ..writeln('          args: ["requestId": requestId, "none": true])')
        ..writeln('      }')
        ..writeln('    }')
        ..writeln('    return ["pending": true]')
        ..writeln('  }');
    }
    _out
      ..writeln('}')
      ..writeln();
  }

  String _encodeFocusCurrentParam(ParamModel p) {
    final n = 'current.${swiftName(p.name)}';
    final optional = _optional(p);
    if (p.entity != null) {
      if (p.entityList) return optional ? 'AssistantValues.encode($n?.map(\\.id))' : '$n.map(\\.id)';
      return optional ? 'AssistantValues.encode($n?.id)' : '$n.id';
    }
    if (p.schemaEntity case final s?) {
      final idPath = _dartIDPath(s.schema.id);
      if (p.entityList) return optional ? 'AssistantValues.encode($n?.map($idPath))' : '$n.map($idPath)';
      return optional ? 'AssistantValues.encode(${_dartID(s.schema.id, '$n?')})' : _dartID(s.schema.id, n);
    }
    if (p.value!.list) {
      return optional
          ? '$n.map { \$0.map { AssistantValues.encode(\$0) } as Any } ?? NSNull()'
          : '$n.map { AssistantValues.encode(\$0) }';
    }
    return 'AssistantValues.encode($n)';
  }

  // ── Queries ──

  /// An importing query (`maps.placeIntentValueQuery`): the Dart handler
  /// finds the items when Flutter is running; otherwise the published items
  /// that match.
  void _importQuery(SchemaEntityModel s, QuerySchema q) {
    final name = s.swiftName;
    final input = _swiftType(q.type);
    final floor = SwiftWriter._max(SwiftWriter._max(SwiftWriter._max(_entityFloor(s.schema), q.availability), _queryFloor), _typeFloor(q.type, const {}));
    final arg = queryArgName(q);
    // The mapped member of the input's type, to match published items by.
    final member = s.schema.properties
        .where((p) => p.type.base.kind == q.type.kind && s.mapping.containsKey(p.name))
        .firstOrNull;
    final fallback = q.type.kind == 'placeDescriptor' && member != null
        ? 'AssistantMatch.records(\n'
            '      AssistantSnapshot.records("${s.collection}"), matchingPlace: value, field: "${s.mapping[member.name]!.name}",\n'
            '      ignoring: ${name}Query.typeWords\n'
            '    ).map($name.init(record:))'
        : '[]';
    _out.writeln('''
/// `${q.id}`: finds `${s.className}` items for a ${q.type.kind}, with `${q.name}` on the
/// `${s.className}` handler while Flutter runs; otherwise from the published items.
${_availability(floor)}
struct ${s.className}${pascal(q.name)}: IntentValueQuery {
  func values(for input: $input) async throws -> [$name] {
    let value = AssistantValues.encode(input)
    if $_dartReady,
      let reply = try? await AssistantBridge.shared.perform("${queryActionId(s, q)}", args: ["$arg": value])
    {
      let ids = AssistantValues.stringList(reply)
      let found = ${_lookup(name, s.schema.id, 'ids')}
      return ids.compactMap { id in found.first { ${_dartID(s.schema.id, r"$0")} == id } }
    }
    return $fallback
  }
}
''');
  }

  /// Visual Intelligence's search (`IntentValueQuery` over a
  /// `SemanticContentDescriptor`; one per app): the registry's
  /// `visualSearch` picks items while Flutter runs; otherwise the published
  /// items matching the image's labels. Several entity types make a union
  /// (iOS 27).
  void _visualSearch() {
    final types = app.visualSearchTypes;
    if (types.isEmpty) return;
    _imports.add('VisualIntelligence');
    Map<String, num> floorOf(String className) =>
        app.schemaEntities.where((s) => s.className == className).map((s) => _entityFloor(s.schema)).firstOrNull ?? _none;
    var floor = types.length > 1 ? SwiftWriter._max(_visualFloor, SwiftWriter._typeFloors['union']!) : _visualFloor;
    for (final (className, _) in types) {
      floor = SwiftWriter._max(floor, floorOf(className));
    }
    final single = types.length == 1;
    final result = single ? types.single.$2 : 'AssistantVisualSearchResult';
    String caseName(String className) => swiftName(camel(className));
    final collections = types.map((t) => '"${t.$1}"').join(', ');
    // Like the runtime's `AssistantVisualIntelligence.swift`: Xcode 27 only.
    _out.writeln('#if canImport(VisualIntelligence) && compiler(>=6.4)');
    if (!single) {
      _out
        ..writeln('/// What Visual Intelligence search returns: an item of one of the types.')
        ..writeln(_availability(floor))
        ..writeln('@UnionValue')
        ..writeln('enum AssistantVisualSearchResult {');
      for (final (className, swift) in types) {
        _out.writeln('  case ${caseName(className)}($swift)');
      }
      _out
        ..writeln('}')
        ..writeln();
    }
    _out
      ..writeln('/// Visual Intelligence\'s search: `visualSearch` in Dart picks ${types.map((t) => '`${t.$1}`').join(', ')} items')
      ..writeln('/// for what the camera or a screenshot shows while Flutter runs; otherwise the')
      ..writeln('/// published items matching the image\'s labels.')
      ..writeln(_availability(floor))
      ..writeln('struct AssistantVisualSearchQuery: IntentValueQuery {')
      ..writeln('  func values(for input: SemanticContentDescriptor) async throws -> [$result] {')
      ..writeln('    var results: [$result] = []')
      ..writeln('    if $_dartReady,')
      ..writeln('      let reply = try? await AssistantBridge.shared.perform(')
      ..writeln('        "$visualSearchActionId", args: ["content": AssistantValues.encode(input), "collections": [$collections]])')
      ..writeln('    {')
      ..writeln('      for item in AssistantValues.references(reply) {')
      ..writeln('        switch item.collection {');
    for (final (className, swift) in types) {
      _out
        ..writeln('        case "$className":')
        ..writeln('          if let found = ${_lookup(swift, _schemaOf(className), '[item.id]')}.first {')
        ..writeln('            results.append(${single ? 'found' : '.${caseName(className)}(found)'})')
        ..writeln('          }');
    }
    _out
      ..writeln('        default:')
      ..writeln('          break')
      ..writeln('        }')
      ..writeln('      }')
      ..writeln('      return results')
      ..writeln('    }');
    for (final (className, swift) in types) {
      _out
        ..writeln('    results += AssistantMatch.records(')
        ..writeln('      AssistantSnapshot.records("$className"), matchingLabels: input.labels, ignoring: ${swift}Query.typeWords')
        ..writeln('    ).map { ${single ? '$swift(record: \$0)' : '.${caseName(className)}($swift(record: \$0))'} }');
    }
    _out
      ..writeln('    return results')
      ..writeln('  }')
      ..writeln('}')
      ..writeln('#endif')
      ..writeln();
  }
}
