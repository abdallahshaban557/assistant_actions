part of 'swift_writer.dart';

/// Siri polish: `authenticationPolicy` (`requiresUnlock`), Shortcuts
/// sentences (`parameterSummary`) and item images in
/// `DisplayRepresentation`s and Spotlight.
extension _Polish on SwiftWriter {
  // ── Unlock ────────────────────────────────────────────────────────────

  /// Whether intents about the entity class [className] run on a locked
  /// device: its `requiresUnlock`, else the app's.
  UnlockModel _entityUnlock(String className) =>
      app.entities.where((e) => e.className == className).firstOrNull?.unlock ??
      app.schemaEntities.where((s) => s.className == className).firstOrNull?.unlock ??
      app.unlock;

  /// A plain action's policy: its own, else the app's, raised to the
  /// strictest `requiresUnlock` an entity it takes or returns sets.
  UnlockModel _actionUnlock(ActionModel a) {
    if (a.unlock case final u?) return u;
    var unlock = app.unlock;
    final explicit = [
      for (final p in a.params) p.entity?.unlock,
      a.result?.entity?.unlock,
      a.result?.schemaEntity?.unlock,
    ];
    for (final u in explicit.nonNulls) {
      unlock = unlock.atLeast(u);
    }
    return unlock;
  }

  /// A snapshot answer's policy: its own, else its entity's.
  UnlockModel _snapshotUnlock(SnapshotActionModel a) => a.unlock ?? _entityUnlock(a.collection);

  /// A schema [intent]'s policy: its entity's ([owner]) or its domain
  /// annotation's, else the app's, at least what Apple's schema asks.
  UnlockModel _intentUnlock(SchemaEntityModel? owner, IntentSchema intent) {
    final set = owner != null
        ? owner.unlock
        : app.schemaDomains.where((d) => d.intents.contains(intent)).firstOrNull?.unlock;
    return (set ?? app.unlock).forSchema(intent);
  }

  /// The `authenticationPolicy` member for [unlock], or nothing for Apple's
  /// default (`.alwaysAllowed`).
  String _unlockMember(UnlockModel unlock, {String access = ''}) => unlock == UnlockModel.notRequired
      ? ''
      : '  ${access}static let authenticationPolicy: IntentAuthenticationPolicy = ${unlock.swift}\n';

  // ── Shortcuts sentences ───────────────────────────────────────────────

  /// The `parameterSummary` member for [summary] (with `{param}`
  /// placeholders) of an intent with [params], or nothing. Parameters the
  /// sentence leaves out are listed under it: Apple's processor accepts a
  /// summary without them, but its metadata then gives Shortcuts nowhere to
  /// edit them.
  String _summaryMember(String? summary, List<String> params, {String access = ''}) {
    if (summary == null) return '';
    final named = summaryPlaceholders(summary).toSet();
    final text = SwiftWriter._escape(summary).replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) => '\\(\\.\$${m[1]})');
    final rest = [for (final p in params) if (!named.contains(p)) p];
    final out = StringBuffer('  ${access}static var parameterSummary: some ParameterSummary {\n');
    if (rest.isEmpty) {
      out.writeln('    Summary("$text")');
    } else {
      out
        ..writeln('    Summary("$text") {')
        ..writeln(rest.map((p) => '      \\.\$$p').join('\n'))
        ..writeln('    }');
    }
    out.writeln('  }');
    return out.toString();
  }

  /// The `parameterSummary` of schema [intent], from its entity's ([owner])
  /// or domain's `summaries`.
  String _intentSummary(SchemaEntityModel? owner, IntentSchema intent) {
    final summary = owner != null
        ? owner.summaries[intent.name]
        : app.schemaDomains.where((d) => d.intents.contains(intent)).firstOrNull?.summaries[intent.name];
    return _summaryMember(summary, [for (final p in intent.parameters) p.name]);
  }

  /// Both members for schema [intent], then a blank line; or nothing.
  String _intentPolish(SchemaEntityModel? owner, IntentSchema intent) {
    final members = '${_unlockMember(_intentUnlock(owner, intent))}${_intentSummary(owner, intent)}';
    return members.isEmpty ? '' : '$members\n';
  }

  // ── Images ────────────────────────────────────────────────────────────

  /// The stored member holding an item's `@EntityImage()` value.
  static const _imageMember = 'assistantImage';

  /// The member declaration, when the entity has an image field.
  String _imageDeclaration(FieldModel? image, {String access = ''}) =>
      image == null ? '' : '  ${access}let $_imageMember: String?\n';

  /// The `init(record:)` line setting it.
  String _imageInit(FieldModel? image) =>
      image == null ? '' : '    $_imageMember = AssistantValues.string(record.fields["${image.name}"])\n';

  /// A `DisplayRepresentation.Image?` expression, or null without an image.
  String? _displayImage(String? systemImage, FieldModel? image) {
    final symbol = systemImage == null ? 'nil' : '"${SwiftWriter._escape(systemImage)}"';
    if (image != null) return 'assistantDisplayImage($_imageMember, systemName: $symbol)';
    if (systemImage != null) return '.init(systemName: $symbol)';
    return null;
  }

  /// The Spotlight line giving the item's thumbnail, for a local file.
  String _spotlightImage(FieldModel? image) =>
      image == null ? '' : '    attributes.thumbnailData = assistantImageData($_imageMember)\n';

  /// The helpers `@EntityImage()` values go through, once.
  void _imageHelpers() {
    final any = app.entities.any((e) => e.image != null) || app.schemaEntities.any((s) => s.image != null);
    if (!any) return;
    _out.writeln(r'''
/// An `@EntityImage()` that is a local file (an absolute path or a `file:`
/// URL), read here in the app's process, so Siri, Shortcuts and Spotlight,
/// which draw in other processes, can show a file in the app's sandbox.
private func assistantImageData(_ value: String?) -> Data? {
  guard let value, !value.isEmpty else { return nil }
  guard let url = value.hasPrefix("/") ? URL(fileURLWithPath: value) : URL(string: value), url.isFileURL else {
    return nil
  }
  return try? Data(contentsOf: url)
}

/// What Siri and Shortcuts show with an item: its `@EntityImage()` (a local
/// file's bytes, or a remote URL the system loads), else the type's SF Symbol.
private func assistantDisplayImage(_ value: String?, systemName: String?) -> DisplayRepresentation.Image? {
  if let data = assistantImageData(value) { return .init(data: data) }
  if let value, let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
    return .init(url: url)
  }
  return systemName.map { .init(systemName: $0) }
}
''');
  }
}
