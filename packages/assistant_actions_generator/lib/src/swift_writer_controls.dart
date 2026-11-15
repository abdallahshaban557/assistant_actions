part of 'swift_writer.dart';

/// Writes `apple/AssistantWidgets.g.swift`: extension-safe `ControlWidget`s
/// and `WidgetConfigurationIntent`s for the `AssistantWidgets` target.
String writeAppWidgets(AppModel app) => SwiftWriter(app).writeWidgets();

/// App Group provider, `AssistantIntentProvider` lookup for `AssistantSiriTip`,
/// `WidgetConfigurationIntent`s, and extension-safe `ControlWidget` generation.
extension _ControlsAndWidgets on SwiftWriter {
  void _appGroupProvider() {
    final group = app.appGroup;
    if (group == null) return;
    _out.writeln('''
/// Configured by `@AssistantActionsApp(appGroup: ...)`.
@objc(AssistantActionsAppGroup)
public final class AssistantActionsAppGroup: NSObject, AssistantAppGroupProvider {
  public static var appGroupIdentifier: String? { "${SwiftWriter._escape(group)}" }
}
''');
  }

  void _widgetConfigsMain() {
    if (app.controls.any((c) => c.$2.isToggle)) {
      _out.writeln('''
private func assistantReloadControl(_ kind: String) {
  if #available(iOS 18.0, macOS 26.0, *) {
    ControlCenter.shared.reloadControls(ofKind: kind)
  }
}
''');
    }
    for (final w in app.widgetConfigs) {
      var floor = const <String, num>{'iOS': 0, 'macOS': 0};
      for (final p in w.params) {
        if (p.value case final v?) floor = SwiftWriter._max(floor, _valueFloor(v));
      }
      _out.writeln('/// `${w.name}` (`@AssistantWidgetConfig`): configurable widget intent.');
      if (_above(floor)) _out.writeln(_availability(floor));
      _writeWidgetConfigStruct(_out, w);
    }
  }

  void _writeWidgetConfigStruct(StringBuffer buf, WidgetConfigModel w) {
    buf
      ..writeln('public struct ${w.swiftName}: WidgetConfigurationIntent {')
      ..writeln('  public static let title: LocalizedStringResource = "${SwiftWriter._escape(w.title)}"');
    if (w.description != null) {
      buf.writeln('  public static let description = IntentDescription("${SwiftWriter._escape(w.description!)}")');
    }
    buf.writeln();
    for (final p in w.params) {
      final options = [
        'title: "${SwiftWriter._escape(p.title)}"',
        if (p.swiftDefault case final d?) 'default: $d',
        if (p.prompt case final prompt?) 'requestValueDialog: "${SwiftWriter._escape(prompt)}"',
      ];
      buf.writeln('  @Parameter(${options.join(', ')})\n  public var ${swiftName(p.name)}: ${_paramSwift(p)}\n');
    }
    buf
      ..writeln('  public init() {}')
      ..writeln('}')
      ..writeln();
  }

  void _intentProvider() {
    final entries = <({String id, String structName, Map<String, num> floor, String? phrase, String title})>[];
    final seenIds = <String>{};

    String? cleanPhrase(String? raw) {
      if (raw == null) return null;
      return raw
          .replaceAll('{app}', app.appName)
          .replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) => m[1]!)
          .trim();
    }

    for (final a in _userActions) {
      if (!seenIds.add(a.id)) continue;
      entries.add((
        id: a.id,
        structName: a.swiftName,
        floor: _actionFloor(a),
        phrase: cleanPhrase(a.shortcut?.phrases.firstOrNull),
        title: a.title,
      ));
    }
    for (final a in app.snapshotActions) {
      if (!seenIds.add(a.id)) continue;
      entries.add((
        id: a.id,
        structName: a.swiftName,
        floor: const {'iOS': 0, 'macOS': 0},
        phrase: cleanPhrase(a.shortcut?.phrases.firstOrNull),
        title: a.title,
      ));
    }
    for (final s in app.intentShortcuts) {
      final id = s.openClass != null ? 'system.open.${s.openClass}' : callActionId(s.owner, s.intent);
      if (!seenIds.add(id)) continue;
      final Map<String, num> floor;
      if (s.openClass case final c?) {
        final schemaEntity = app.schemaEntities.where((e) => e.className == c).firstOrNull;
        final base = schemaEntity != null
            ? SwiftWriter._max(_systemOpen.availability, _entityFloor(schemaEntity.schema))
            : SwiftWriter._max(_systemOpen.availability, const {'iOS': 18, 'macOS': 15});
        floor = app.opensUrl(c) ? SwiftWriter._max(base, const {'iOS': 18, 'macOS': 15}) : base;
      } else {
        floor = s.owner != null
            ? SwiftWriter._max(_intentFloor(s.intent), _entityFloor(s.owner!.schema))
            : _intentFloor(s.intent);
      }
      entries.add((
        id: id,
        structName: _intentStruct(s),
        floor: floor,
        phrase: cleanPhrase(s.shortcut.phrases.firstOrNull),
        title: s.shortcut.shortTitle,
      ));
    }

    _out
      ..writeln('/// Found by name by `AssistantPlatformViews` in the runtime so')
      ..writeln('/// `AssistantSiriTip` can resolve generated intents by `actionId`.')
      ..writeln('@objc(AssistantActionsAppIntents)')
      ..writeln('public final class AssistantActionsAppIntents: NSObject, AssistantIntentProvider {')
      ..writeln('  @MainActor')
      ..writeln('  public static func intent(forActionId actionId: String) -> Any? {')
      ..writeln('    switch actionId {');
    for (final e in entries) {
      final (iOS, macOS) = _versions(e.floor);
      final os = iOS.isInfinite ? 'macOS' : (macOS.isInfinite ? 'iOS' : null);
      _out.writeln('    case "${SwiftWriter._escape(e.id)}":');
      if (os != null) _out.writeln('      #if os($os)');
      final indent = os != null ? '        ' : '      ';
      if (_above(e.floor)) {
        _out.writeln('${indent}guard ${_available(e.floor)} else { return nil }');
      }
      _out.writeln('${indent}return ${e.structName}()');
      if (os != null) {
        _out
          ..writeln('      #else')
          ..writeln('        return nil')
          ..writeln('      #endif');
      }
    }
    _out
      ..writeln('    default:')
      ..writeln('      return nil')
      ..writeln('    }')
      ..writeln('  }')
      ..writeln()
      ..writeln('  @MainActor')
      ..writeln('  public static func shortcutPhrase(forActionId actionId: String) -> String? {')
      ..writeln('    switch actionId {');
    for (final e in entries) {
      if (e.phrase == null) continue;
      _out.writeln('    case "${SwiftWriter._escape(e.id)}": return "${SwiftWriter._escape(e.phrase!)}"');
    }
    _out
      ..writeln('    default: return nil')
      ..writeln('    }')
      ..writeln('  }')
      ..writeln()
      ..writeln('  @MainActor')
      ..writeln('  public static func actionTitle(forActionId actionId: String) -> String? {')
      ..writeln('    switch actionId {');
    for (final e in entries) {
      _out.writeln('    case "${SwiftWriter._escape(e.id)}": return "${SwiftWriter._escape(e.title)}"');
    }
    _out
      ..writeln('    default: return nil')
      ..writeln('    }')
      ..writeln('  }')
      ..writeln('}')
      ..writeln();
  }

  /// Generates `apple/AssistantWidgets.g.swift` for the `AssistantWidgets`
  /// extension target (no `Flutter` or `assistant_actions` imports).
  String writeWidgets() {
    final buf = StringBuffer()
      ..writeln('// GENERATED by assistant_actions_generator. Do not edit.')
      ..writeln('// Extension-safe controls and widget configuration intents for AssistantWidgets')
      ..writeln('// (no FlutterFramework dependency).')
      ..writeln()
      ..writeln('import AppIntents')
      ..writeln('import Foundation')
      ..writeln('import SwiftUI')
      ..writeln('import WidgetKit')
      ..writeln();

    final groupLiteral = app.appGroup == null ? 'nil' : '"${SwiftWriter._escape(app.appGroup!)}"';
    buf.writeln('''
/// Shared snapshot and inbox storage for widget and control extensions.
public enum AssistantExtensionStorage {
  public static let configuredAppGroup: String? = $groupLiteral
  public static let infoPlistKey = "AssistantAppGroup"
  private static let inboxKey = "assistant_actions.inbox"

  public static var appGroupIdentifier: String? {
    if let configuredAppGroup, !configuredAppGroup.isEmpty {
      return configuredAppGroup
    }
    if let raw = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String {
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty && !trimmed.hasPrefix("\$(") {
        return trimmed
      }
    }
    return nil
  }

  public static var userDefaults: UserDefaults {
    guard let group = appGroupIdentifier, let suite = UserDefaults(suiteName: group) else {
      return .standard
    }
    return suite
  }

  public static func directoryURL() -> URL? {
    let base: URL?
    if let group = appGroupIdentifier,
      let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    {
      base = shared
    } else {
      base = try? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    }
    return base?.appendingPathComponent("assistant_actions", isDirectory: true)
  }

  public struct Record: @unchecked Sendable {
    public let id: String
    public var title: String
    public var subtitle: String?
    public var fields: [String: Any]

    public init(id: String, title: String, subtitle: String? = nil, fields: [String: Any] = [:]) {
      self.id = id
      self.title = title
      self.subtitle = subtitle
      self.fields = fields
    }
  }

  public static func records(_ collection: String) -> [Record] {
    var result: [Record] = []
    if let url = directoryURL()?.appendingPathComponent("\\(collection).json"),
      let data = try? Data(contentsOf: url),
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let items = json["records"] as? [[String: Any]]
    {
      result = items.compactMap { item in
        guard let id = item["id"] as? String else { return nil }
        return Record(
          id: id,
          title: item["title"] as? String ?? "",
          subtitle: item["subtitle"] as? String,
          fields: item["fields"] as? [String: Any] ?? [:])
      }
    }
    let pending = (userDefaults.stringArray(forKey: inboxKey) ?? []).compactMap { raw -> [String: Any]? in
      guard let data = raw.data(using: .utf8) else { return nil }
      return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }.filter { \$0["collection"] as? String == collection }

    for change in pending {
      guard let id = change["id"] as? String else { continue }
      let fields = change["fields"] as? [String: Any] ?? [:]
      switch change["kind"] as? String {
      case "create":
        result.insert(Record(id: id, title: "", fields: fields), at: 0)
      case "update":
        guard let i = result.firstIndex(where: { \$0.id == id }) else { continue }
        result[i].fields.merge(fields) { _, new in new }
        for cleared in change["cleared"] as? [String] ?? [] { result[i].fields[cleared] = nil }
      case "delete":
        result.removeAll { \$0.id == id }
      default:
        break
      }
    }
    return result
  }

  public static func matchRecords(_ records: [Record], matching query: String) -> [Record] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return records }
    return records.filter { r in
      r.title.localizedCaseInsensitiveContains(trimmed)
        || (r.subtitle?.localizedCaseInsensitiveContains(trimmed) ?? false)
    }
  }

  public static func enqueueCall(_ action: String, args: [String: Any] = [:]) {
    let entry: [String: Any] = [
      "kind": "call",
      "action": action,
      "args": args,
      "createdAt": Date().timeIntervalSince1970,
    ]
    guard JSONSerialization.isValidJSONObject(entry),
      let data = try? JSONSerialization.data(withJSONObject: entry),
      let json = String(data: data, encoding: .utf8)
    else { return }
    let defaults = userDefaults
    let existing = defaults.stringArray(forKey: inboxKey) ?? []
    defaults.set(existing + [json], forKey: inboxKey)
  }

  public static func toggleValue(
    controlId: String,
    collection: String? = nil,
    entityId: String? = nil,
    field: String? = nil
  ) -> Bool {
    if let collection, let field {
      let items = records(collection)
      let record = entityId == nil ? items.first : items.first(where: { \$0.id == entityId })
      if let raw = record?.fields[field] {
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
      }
    }
    return (userDefaults.object(forKey: "assistant_actions.control.\\(controlId)") as? Bool) ?? false
  }

  public static func setToggleValue(_ value: Bool, controlId: String) {
    userDefaults.set(value, forKey: "assistant_actions.control.\\(controlId)")
  }
}
''');

    // Extension-safe AppEnums.
    for (final e in app.appEnums.values) {
      _writeExtensionAppEnum(buf, e);
    }

    // Extension-safe schema enums referenced by widget configs or controls.
    final schemaEnumRefs = <String>{
      for (final w in app.widgetConfigs)
        for (final p in w.params) ?p.value?.enumRef,
      for (final (a, _) in app.controls)
        for (final p in a.params) ?p.value?.enumRef,
    };
    for (final ref in schemaEnumRefs) {
      final e = _enumSchema(ref);
      final name = _enumName(e.id);
      buf
        ..writeln(_availability(e.availability))
        ..writeln('@AppEnum(schema: .${e.id})')
        ..writeln('public enum $name: String, Sendable {');
      for (final c in e.cases) {
        buf.writeln('  case ${swiftName(c)}');
      }
      buf
        ..writeln()
        ..writeln('  public static let caseDisplayRepresentations: [$name: DisplayRepresentation] = [');
      for (final c in e.cases) {
        buf.writeln('    .${swiftName(c)}: "${SwiftWriter._escape(SwiftWriter._words(c))}",');
      }
      buf
        ..writeln('  ]')
        ..writeln('}')
        ..writeln();
    }

    // Extension-safe AppEntities for @AssistantEntity classes.
    for (final e in app.entities) {
      _writeExtensionEntity(buf, e);
    }

    // WidgetConfigurationIntents.
    for (final w in app.widgetConfigs) {
      var floor = const <String, num>{'iOS': 0, 'macOS': 0};
      for (final p in w.params) {
        if (p.value case final v?) floor = SwiftWriter._max(floor, _valueFloor(v));
      }
      buf.writeln('/// `${w.name}` (`@AssistantWidgetConfig`).');
      if (_above(floor)) buf.writeln(_availability(floor));
      _writeWidgetConfigStruct(buf, w);
    }

    // ControlWidget intents, value providers, and ControlWidget structs.
    for (final (action, control) in app.controls) {
      _writeExtensionControl(buf, action, control);
    }

    // Bundle of all generated controls.
    final controlWidgets = [for (final (_, c) in app.controls) c.swiftWidgetName];
    if (controlWidgets.isNotEmpty) {
      for (var groupIndex = 0; groupIndex * 10 < controlWidgets.length && controlWidgets.length > 10; groupIndex++) {
        final slice = controlWidgets.skip(groupIndex * 10).take(10);
        buf
          ..writeln('@available(iOS 18.0, macOS 26.0, *)')
          ..writeln('private struct _AssistantControlChunk$groupIndex: WidgetBundle {')
          ..writeln('  var body: some Widget {');
        for (final w in slice) {
          buf.writeln('    $w()');
        }
        buf
          ..writeln('  }')
          ..writeln('}')
          ..writeln();
      }
    }

    buf
      ..writeln('@WidgetBundleBuilder')
      ..writeln('public var assistantControlsBundle: some Widget {');
    if (controlWidgets.isNotEmpty) {
      buf.writeln('  if #available(iOS 18.0, macOS 26.0, *) {');
      if (controlWidgets.length <= 10) {
        for (final w in controlWidgets) {
          buf.writeln('    $w()');
        }
      } else {
        for (var groupIndex = 0; groupIndex * 10 < controlWidgets.length; groupIndex++) {
          buf.writeln('    _AssistantControlChunk$groupIndex()');
        }
      }
      buf.writeln('  }');
    }
    buf.writeln('}');

    return buf.toString();
  }

  void _writeExtensionAppEnum(StringBuffer buf, AppEnumModel e) {
    final name = e.swiftName;
    buf
      ..writeln('/// `${e.className}` in Dart.')
      ..writeln('public enum $name: String, AppEnum {');
    for (final c in e.cases) {
      buf.writeln(swiftName(c.name) == c.name ? '  case ${c.name}' : '  case ${swiftName(c.name)} = "${c.name}"');
    }
    buf
      ..writeln()
      ..writeln('  public static let typeDisplayRepresentation: TypeDisplayRepresentation = "${SwiftWriter._escape(e.title)}"')
      ..writeln('  public static let caseDisplayRepresentations: [$name: DisplayRepresentation] = [');
    for (final c in e.cases) {
      final title = '"${SwiftWriter._escape(c.title)}"';
      final image = c.systemImage == null ? '' : ', image: .init(systemName: "${SwiftWriter._escape(c.systemImage!)}")';
      buf.writeln(c.synonyms.isEmpty && image.isEmpty
          ? '    .${swiftName(c.name)}: $title,'
          : '    .${swiftName(c.name)}: DisplayRepresentation(title: $title$image'
              '${c.synonyms.isEmpty ? '' : ', synonyms: [${c.synonyms.map((s) => '"${SwiftWriter._escape(s)}"').join(', ')}]'}),');
    }
    buf
      ..writeln('  ]')
      ..writeln('}')
      ..writeln();
  }

  void _writeExtensionEntity(StringBuffer buf, EntityModel e) {
    final name = e.swiftName;
    final sysImg = e.systemImage == null ? null : '.init(systemName: "${SwiftWriter._escape(e.systemImage!)}")';
    buf.writeln('''
/// Extension-safe `${e.className}` entity reading from shared snapshots.
public struct $name: AppEntity {
  public static let typeDisplayRepresentation: TypeDisplayRepresentation = "${SwiftWriter._escape(e.title)}"
  public static let defaultQuery = ${name}Query()

  public let id: String
  public var title: String
  public let subtitle: String?

  public var displayRepresentation: DisplayRepresentation {
${sysImg != null ? '    DisplayRepresentation(title: "\\(title)", subtitle: subtitle.map { "\\(\$0)" }, image: $sysImg)' : '    if let subtitle { return DisplayRepresentation(title: "\\(title)", subtitle: "\\(subtitle)") }\n    return DisplayRepresentation(title: "\\(title)")'}
  }

  public init(id: String, title: String, subtitle: String? = nil) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
  }

  public init(record: AssistantExtensionStorage.Record) {
    self.id = record.id
    self.title = record.title
    self.subtitle = record.subtitle
  }
}

public struct ${name}Query: EntityStringQuery, EnumerableEntityQuery {
  public init() {}

  public func entities(for identifiers: [String]) async throws -> [$name] {
    let wanted = Set(identifiers)
    return AssistantExtensionStorage.records("${e.className}").filter { wanted.contains(\$0.id) }.map($name.init(record:))
  }

  public func entities(matching string: String) async throws -> [$name] {
    AssistantExtensionStorage.matchRecords(
      AssistantExtensionStorage.records("${e.className}"), matching: string
    ).map($name.init(record:))
  }

  public func suggestedEntities() async throws -> [$name] {
    AssistantExtensionStorage.records("${e.className}").prefix(20).map($name.init(record:))
  }

  public func allEntities() async throws -> [$name] {
    AssistantExtensionStorage.records("${e.className}").map($name.init(record:))
  }
}
''');
  }

  void _writeExtensionControl(StringBuffer buf, ActionModel a, ControlModel c) {
    final cid = SwiftWriter._escape(c.id);
    final ctitle = SwiftWriter._escape(c.title);
    final cimg = SwiftWriter._escape(c.systemImage);
    final descLine = c.subtitle == null ? '' : '\n    .description("${SwiftWriter._escape(c.subtitle!)}")';

    if (c.isToggle) {
      final collectionLit = c.toggleSnapshotCollection == null ? 'nil' : '"${SwiftWriter._escape(c.toggleSnapshotCollection!)}"';
      final entityIdLit = c.toggleEntityId == null ? 'nil' : '"${SwiftWriter._escape(c.toggleEntityId!)}"';
      final fieldLit = c.toggleField == null ? 'nil' : '"${SwiftWriter._escape(c.toggleField!)}"';
      buf.writeln('''
/// Extension-side toggle intent matching `${a.swiftName}` in the main app.
@available(iOS 18.0, macOS 26.0, *)
public struct ${a.swiftName}: SetValueIntent {
  public static let title: LocalizedStringResource = "${SwiftWriter._escape(a.title)}"

  @Parameter(title: "Value")
  public var value: Bool

  public init() {
    self.value = false
  }

  public init(value: Bool) {
    self.value = value
  }

  public func perform() async throws -> some IntentResult {
    AssistantExtensionStorage.setToggleValue(value, controlId: "$cid")
    AssistantExtensionStorage.enqueueCall("${SwiftWriter._escape(a.id)}", args: ["value": value])
    ControlCenter.shared.reloadControls(ofKind: "$cid")
    return .result()
  }
}

@available(iOS 18.0, macOS 26.0, *)
public struct ${c.swiftProviderName}: ControlValueProvider {
  public var previewValue: Bool { false }

  public init() {}

  public func currentValue() async throws -> Bool {
    AssistantExtensionStorage.toggleValue(
      controlId: "$cid",
      collection: $collectionLit,
      entityId: $entityIdLit,
      field: $fieldLit)
  }
}

@available(iOS 18.0, macOS 26.0, *)
public struct ${c.swiftWidgetName}: ControlWidget {
  public init() {}

  public var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "$cid", provider: ${c.swiftProviderName}()) { isOn in
      ControlWidgetToggle("$ctitle", isOn: isOn, action: ${a.swiftName}()) { _ in
        Label("$ctitle", systemImage: "$cimg")
      }
    }
    .displayName("$ctitle")$descLine
  }
}
''');
    } else {
      buf.writeln('''
/// Extension-side button intent matching `${a.swiftName}` in the main app.
@available(iOS 18.0, macOS 26.0, *)
public struct ${a.swiftName}: AppIntent {
  public static let title: LocalizedStringResource = "${SwiftWriter._escape(a.title)}"

  public init() {}

  public func perform() async throws -> some IntentResult {
    AssistantExtensionStorage.enqueueCall("${SwiftWriter._escape(a.id)}")
    return .result()
  }
}

@available(iOS 18.0, macOS 26.0, *)
public struct ${c.swiftWidgetName}: ControlWidget {
  public init() {}

  public var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "$cid") {
      ControlWidgetButton(action: ${a.swiftName}()) {
        Label("$ctitle", systemImage: "$cimg")
      }
    }
    .displayName("$ctitle")$descLine
  }
}
''');
    }
  }
}
