part of 'swift_writer.dart';

/// File entities (`files.file`): Apple's `FileEntity` requires
/// `FileEntityIdentifier` ids, while Dart and the snapshot use the file's
/// path. The generated entity keeps both: `id` for Siri, `dartID` for Dart.
extension _Files on SwiftWriter {
  /// Whether [ref] (a schema id) is an adopted file entity.
  bool _isFileEntity(String? ref) => _adopted[ref]?.isFile ?? false;

  /// The id members of adopted entity [s].
  String _idMembers(SchemaEntityModel s) => s.isFile
      ? '  let id: FileEntityIdentifier\n'
          '  /// The id Dart gave the item: the file\'s path.\n'
          '  let dartID: String'
      : '  let id: String';

  /// Static members a file entity needs: the content types it holds.
  String _fileStatics(SchemaEntityModel s) {
    if (!s.isFile) return '';
    _imports.add('UniformTypeIdentifiers');
    return '  static let supportedContentTypes: [UTType] = [.item]\n';
  }

  /// `init(record:resolve:)`'s id lines.
  String _initID(SchemaEntityModel s) =>
      s.isFile ? '    id = AssistantFileIDs.identifier(record.id)\n    dartID = record.id' : '    id = record.id';

  /// The Swift expression of the Dart id of [expr], an item of entity [ref].
  String _dartID(String? ref, String expr) => _isFileEntity(ref) ? '$expr.dartID' : '$expr.id';

  /// `\.id` (or `\.dartID`) for mapping a list of [ref] items to Dart ids.
  String _dartIDPath(String? ref) => _isFileEntity(ref) ? r'\.dartID' : r'\.id';

  /// The query's `entities(for:)`, which for a file entity matches Siri's
  /// identifiers to published paths.
  String _entitiesFor(SchemaEntityModel s) {
    final name = s.swiftName;
    if (!s.isFile) {
      return '''
  func entities(for identifiers: [String]) async throws -> [$name] {
    let wanted = Set(identifiers)
    return all().filter { wanted.contains(\$0.id) }
  }''';
    }
    return '''
  func entities(for identifiers: [FileEntityIdentifier]) async throws -> [$name] {
    await AssistantFileIDs.records(AssistantSnapshot.records("${s.collection}"), for: identifiers).map($name.init(record:))
  }

  /// The items with these Dart ids (paths).
  func entities(dartIDs: [String]) -> [$name] {
    let wanted = Set(dartIDs)
    return all().filter { wanted.contains(\$0.dartID) }
  }''';
  }

  /// The items of [resultType] (adopted schema [ref]) with Dart ids [ids].
  String _lookup(String resultType, String? ref, String ids) => _isFileEntity(ref)
      ? '${resultType}Query().entities(dartIDs: $ids)'
      : 'try await ${resultType}Query().entities(for: $ids)';

  /// What Siri shows for a file item: its file name.
  String _fileTitle() => r'(dartID as NSString).lastPathComponent';

  /// The Spotlight helper file entities need: their ids aren't strings.
  String _spotlightFiles() => app.schemaEntities.any((s) => s.isFile)
      ? '''

  @available(iOS 18.0, macOS 15.0, *)
  private static func updateFiles<E: IndexedEntity>(_ entities: [E], removed: [String], clearFirst: Bool) async throws
  where E.ID == FileEntityIdentifier {
    let index = CSSearchableIndex.default()
    if clearFirst {
      try await index.deleteAppEntities(ofType: E.self)
    } else if !removed.isEmpty {
      try await index.deleteAppEntities(identifiedBy: removed.map(AssistantFileIDs.identifier), ofType: E.self)
    }
    if !entities.isEmpty {
      try await index.indexAppEntities(entities)
    }
  }'''
      : '';
}
