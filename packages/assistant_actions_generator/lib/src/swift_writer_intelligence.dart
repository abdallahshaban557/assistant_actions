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
  var target: $swift
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
    final v = p.value!;
    String? one(String x) => switch (v.kind) {
          ValueKind.string => x,
          ValueKind.dateTime => '$x.formatted(date: .abbreviated, time: .shortened)',
          ValueKind.uri => '$x.absoluteString',
          ValueKind.duration => '$x.formatted()',
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
      final paths = [for (final p in a.params) '\\.\$${p.name}'];
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
    if (p.entity case final e?) {
      String find(String id) => 'AssistantSnapshot.records("${e.className}").first(where: { \$0.id == $id })';
      if (p.entityList) {
        return 'AssistantValues.strings($raw)?.compactMap({ id in ${find('id')} }).map({ \$0.map(${e.swiftName}.init(record:)) })';
      }
      return 'AssistantValues.string($raw).flatMap({ id in ${find('id')} }).map(${e.swiftName}.init(record:))';
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

  /// The generated host calls (`AssistantActionsAppHostCalls`): how
  /// collections' ids become `EntityIdentifier`s for on-screen entities,
  /// and donations.
  void _hostCalls() {
    final opens = _openTargets;
    final actions = [
      for (final a in _userActions) (a.id, a.swiftName, a.params, _actionFloor(a)),
      for (final a in app.snapshotActions) (a.id, a.swiftName, const <ParamModel>[], _none),
    ];
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
    if (actions.isNotEmpty) _out.writeln('    AssistantHostCalls.register("donate.action") { args in donateAction(args) }');
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

    if (actions.isNotEmpty) {
      _out
        ..writeln()
        ..writeln('  /// Donates the action Dart ran, with its arguments.')
        ..writeln('  @MainActor')
        ..writeln('  private static func donateAction(_ args: [String: Any]) -> Bool {')
        ..writeln('    guard let action = args["action"] as? String else { return false }');
      if (actions.any((a) => a.$3.isNotEmpty)) _out.writeln('    let values = args["args"] as? [String: Any] ?? [:]');
      _out.writeln('    switch action {');
      for (final (id, swift, params, floor) in actions) {
        _out.writeln('    case "$id":');
        if (_above(floor)) _out.writeln('      guard ${_available(floor)} else { return false }');
        final sets = <String>[];
        for (final p in params) {
          final n = swiftName(p.name);
          final decode = _decodeDonated(p, 'values["${p.name}"]');
          if (_optional(p)) {
            // Dart sent null, or left a default Swift can't state to Dart.
            sets.add('intent.$n = $decode');
          } else if (p.swiftDefault != null) {
            sets.add('if let value = $decode { intent.$n = value }');
          } else {
            _out.writeln('      guard let ${p.name}Value = $decode else { return false }');
            sets.add('intent.$n = ${p.name}Value');
          }
        }
        _out.writeln('      let intent = $swift()');
        for (final line in sets) {
          _out.writeln('      $line');
        }
        _out
          ..writeln('      IntentDonationManager.shared.donate(intent: intent)')
          ..writeln('      return true');
      }
      _out
        ..writeln('    default:')
        ..writeln('      return false')
        ..writeln('    }')
        ..writeln('  }');
    }
    _out
      ..writeln('}')
      ..writeln();
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
