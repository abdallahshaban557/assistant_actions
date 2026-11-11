part of '../install.dart';

/// The widget extension `--widgets` adds to the iOS project.
const _widgets = 'AssistantWidgets';

/// Files copied from the runtime on every run, so they follow upgrades.
const _ownedWidgetFiles = {
  'AssistantActivityAttributes.swift': 'darwin/assistant_actions/Sources/assistant_actions/AssistantActivityAttributes.swift',
  'AssistantLiveActivityWidget.swift': 'darwin/widgets/AssistantLiveActivityWidget.swift',
};

/// Files written once, then the app's to edit.
const _userWidgetFiles = {
  'AssistantWidgets.swift': 'darwin/widgets/AssistantWidgets.swift',
  'Info.plist': 'darwin/widgets/Info.plist',
  'AssistantWidgets.xcconfig': 'darwin/widgets/AssistantWidgets.xcconfig',
};

/// Adds the `AssistantWidgets` widget extension to `ios/`: its sources, an
/// Xcode target embedded in Runner, and `NSSupportsLiveActivities` in the
/// app's Info.plist. Live Activities are iOS-only, so macOS is untouched.
Future<void> _installWidgets(Directory root) async {
  final project = File('${root.path}/ios/Runner.xcodeproj/project.pbxproj');
  if (!project.existsSync()) {
    stderr.writeln('--widgets: no ios/Runner.xcodeproj. Live Activities are iOS-only.');
    return;
  }
  final package = await _packageRoot();
  final dir = '${root.path}/ios/$_widgets';
  for (final MapEntry(key: name, value: source) in _ownedWidgetFiles.entries) {
    _write(File('$dir/$name'), File('$package/$source').readAsStringSync());
  }
  for (final MapEntry(key: name, value: source) in _userWidgetFiles.entries) {
    _write(File('$dir/$name'), File('$package/$source').readAsStringSync(), overwrite: false);
  }

  final plist = File('${root.path}/ios/Runner/Info.plist');
  if (plist.existsSync()) {
    final text = plist.readAsStringSync();
    final updated = supportLiveActivities(text);
    if (updated == null) {
      stderr.writeln('ios: could not read Runner/Info.plist; add NSSupportsLiveActivities = YES yourself.');
    } else if (updated == text) {
      _report('ios: Runner/Info.plist already supports Live Activities');
    } else {
      plist.writeAsStringSync(updated);
      _report('ios: added NSSupportsLiveActivities to Runner/Info.plist');
    }
  }

  final before = project.readAsStringSync();
  final result = addWidgetTarget(before, _id);
  if (result.problem case final problem?) {
    stderr.writeln('ios: $problem. Add the target in Xcode instead:\n$_manualSteps');
  } else if (result.pbx == before) {
    _report('ios: the $_widgets target is already there');
  } else {
    project.writeAsStringSync(result.pbx!);
    _report('ios: added the $_widgets widget extension target, embedded in Runner');
  }
  stdout.writeln('''

Widget extension: ios/$_widgets draws the Live Activities that
AssistantLiveActivity starts. For a device build, open ios/Runner.xcworkspace,
select the $_widgets target, and pick your team under Signing & Capabilities
(the simulator needs none). Edit ios/$_widgets/AssistantWidgets.swift to add
widgets of your own; running this again refreshes the other Swift files.''');
}

const _manualSteps = '''
  1. File > New > Target… > Widget Extension, named $_widgets, with
     "Include Live Activity" off; embed it in Runner.
  2. Delete the Swift files Xcode generated, and add the ones in
     ios/$_widgets to the $_widgets target. Use ios/$_widgets/Info.plist.
  3. Set the target's iOS deployment target to 17.0.
  4. In Runner > Build Phases, drag "Embed Foundation Extensions" above
     "Thin Binary" (Flutter's build otherwise reports a cycle).''';

/// The installed assistant_actions package, whose templates are copied.
Future<String> _packageRoot() async {
  final library = await Isolate.resolvePackageUri(Uri.parse('package:assistant_actions/assistant_actions.dart'));
  // Run as `dart bin/install.dart` without a package config: bin/.. is the package.
  return library == null ? File.fromUri(Platform.script).parent.parent.path : File.fromUri(library).parent.parent.path;
}

/// [plist] with `NSSupportsLiveActivities` turned on, unchanged if it already
/// is, or null if it has no top-level dictionary.
String? supportLiveActivities(String plist) {
  if (plist.contains('<key>NSSupportsLiveActivities</key>')) return plist;
  final dict = RegExp(r'<plist[^>]*>\s*<dict>\n').firstMatch(plist);
  if (dict == null) return null;
  return plist.replaceRange(dict.end, dict.end, '\t<key>NSSupportsLiveActivities</key>\n\t<true/>\n');
}

/// What [addWidgetTarget] did: the new project text, or why it couldn't.
class WidgetTargetResult {
  const WidgetTargetResult({this.pbx, this.problem});

  final String? pbx;
  final String? problem;
}

/// Adds the `AssistantWidgets` app extension target to a Flutter iOS
/// project: its files and group, Sources/Frameworks/Resources phases, one
/// build configuration per Runner configuration (bundle id
/// `<Runner's>.AssistantWidgets`, Runner's team, iOS 17), and an "Embed
/// Foundation Extensions" phase plus a dependency in Runner. The embed phase
/// goes before Flutter's "Thin Binary" script, which otherwise makes a build
/// cycle. All or nothing: if any part of the project isn't where a Flutter
/// project has it, nothing changes and [WidgetTargetResult.problem] says
/// what. [id] makes object ids.
WidgetTargetResult addWidgetTarget(String pbx, String Function() id) {
  if (RegExp('/\\* $_widgets \\*/ = \\{\\s*isa = PBXNativeTarget;').hasMatch(pbx)) {
    return WidgetTargetResult(pbx: pbx);
  }
  WidgetTargetResult fail(String what) => WidgetTargetResult(problem: 'could not find $what in project.pbxproj');

  final projectId = RegExp(r'rootObject = (\w{24})').firstMatch(pbx)?.group(1);
  final runner = RegExp(r'(\w{24}) /\* Runner \*/ = \{\s*isa = PBXNativeTarget;[\s\S]*?\n\t\t\};').firstMatch(pbx);
  if (projectId == null) return fail('the project object');
  if (runner == null) return fail('the Runner target');
  final project = RegExp('$projectId /\\* Project object \\*/ = \\{\\s*isa = PBXProject;[\\s\\S]*?\\n\\t\\t\\};').firstMatch(pbx);
  if (project == null) return fail('the PBXProject');
  final mainGroup = RegExp(r'mainGroup = (\w{24})').firstMatch(project.group(0)!)?.group(1);
  final productsGroup = RegExp(r'productRefGroup = (\w{24})').firstMatch(project.group(0)!)?.group(1);
  if (mainGroup == null || productsGroup == null) return fail('the main and Products groups');

  // Runner's configurations: name, bundle id and team.
  final listId = RegExp(r'buildConfigurationList = (\w{24})').firstMatch(runner.group(0)!)?.group(1);
  final list = listId == null
      ? null
      : RegExp('$listId /\\*[^*]*\\*/ = \\{\\s*isa = XCConfigurationList;\\s*buildConfigurations = \\(([\\s\\S]*?)\\);')
          .firstMatch(pbx);
  if (list == null) return fail("Runner's build configurations");
  final configs = <(String name, String? bundle, String? team)>[];
  for (final m in RegExp(r'(\w{24}) /\* ([^*]+) \*/').allMatches(list.group(1)!)) {
    final block = RegExp('${m.group(1)} /\\*[^*]*\\*/ = \\{\\s*isa = XCBuildConfiguration;[\\s\\S]*?\\n\\t\\t\\};')
        .firstMatch(pbx)
        ?.group(0);
    if (block == null) return fail('the ${m.group(2)} configuration');
    String? setting(String key) => RegExp('\\b$key = "?([^";\\n]+)"?;').firstMatch(block)?.group(1);
    configs.add((m.group(2)!.trim(), setting('PRODUCT_BUNDLE_IDENTIFIER'), setting('DEVELOPMENT_TEAM')));
  }
  if (configs.isEmpty) return fail("Runner's build configurations");
  final fallbackBundle = configs.map((c) => c.$2).nonNulls.firstOrNull;
  if (fallbackBundle == null) return fail("Runner's PRODUCT_BUNDLE_IDENTIFIER");

  final ids = {
    for (final key in [
      'target', 'product', 'group', 'sources', 'frameworks', 'resources', 'configList', 'proxy', 'dependency',
      'embed', 'embedFile', 'plist', 'xcconfig', for (final f in _ownedWidgetFiles.keys) f, 'AssistantWidgets.swift',
      for (final f in [..._ownedWidgetFiles.keys, 'AssistantWidgets.swift']) '$f build', for (final c in configs) 'config ${c.$1}',
    ])
      key: id(),
  };
  final swift = [..._ownedWidgetFiles.keys, 'AssistantWidgets.swift']..sort();
  const t3 = '\t\t\t', t4 = '\t\t\t\t';

  final sections = <String, String>{
    'PBXBuildFile': [
      for (final f in swift)
        '\t\t${ids['$f build']} /* $f in Sources */ = {isa = PBXBuildFile; fileRef = ${ids[f]} /* $f */; };\n',
      '\t\t${ids['embedFile']} /* $_widgets.appex in Embed Foundation Extensions */ = {isa = PBXBuildFile; '
          'fileRef = ${ids['product']} /* $_widgets.appex */; settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };\n',
    ].join(),
    'PBXContainerItemProxy': '\t\t${ids['proxy']} /* PBXContainerItemProxy */ = {\n'
        '${t3}isa = PBXContainerItemProxy;\n'
        '${t3}containerPortal = $projectId /* Project object */;\n'
        '${t3}proxyType = 1;\n'
        '${t3}remoteGlobalIDString = ${ids['target']};\n'
        '${t3}remoteInfo = $_widgets;\n'
        '\t\t};\n',
    'PBXCopyFilesBuildPhase': '\t\t${ids['embed']} /* Embed Foundation Extensions */ = {\n'
        '${t3}isa = PBXCopyFilesBuildPhase;\n'
        '${t3}buildActionMask = 2147483647;\n'
        '${t3}dstPath = "";\n'
        '${t3}dstSubfolderSpec = 13;\n'
        '${t3}files = (\n'
        '$t4${ids['embedFile']} /* $_widgets.appex in Embed Foundation Extensions */,\n'
        '$t3);\n'
        '${t3}name = "Embed Foundation Extensions";\n'
        '${t3}runOnlyForDeploymentPostprocessing = 0;\n'
        '\t\t};\n',
    'PBXFileReference': [
      '\t\t${ids['product']} /* $_widgets.appex */ = {isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; '
          'includeInIndex = 0; path = $_widgets.appex; sourceTree = BUILT_PRODUCTS_DIR; };\n',
      for (final f in swift)
        '\t\t${ids[f]} /* $f */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = $f; sourceTree = "<group>"; };\n',
      '\t\t${ids['plist']} /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };\n',
      '\t\t${ids['xcconfig']} /* $_widgets.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; '
          'path = $_widgets.xcconfig; sourceTree = "<group>"; };\n',
    ].join(),
    'PBXFrameworksBuildPhase': _phase(ids['frameworks']!, 'Frameworks', 'PBXFrameworksBuildPhase', const []),
    'PBXGroup': '\t\t${ids['group']} /* $_widgets */ = {\n'
        '${t3}isa = PBXGroup;\n'
        '${t3}children = (\n'
        '${[for (final f in swift) '$t4${ids[f]} /* $f */,\n'].join()}'
        '$t4${ids['plist']} /* Info.plist */,\n'
        '$t4${ids['xcconfig']} /* $_widgets.xcconfig */,\n'
        '$t3);\n'
        '${t3}path = $_widgets;\n'
        '${t3}sourceTree = "<group>";\n'
        '\t\t};\n',
    'PBXNativeTarget': '\t\t${ids['target']} /* $_widgets */ = {\n'
        '${t3}isa = PBXNativeTarget;\n'
        '${t3}buildConfigurationList = ${ids['configList']} /* Build configuration list for PBXNativeTarget "$_widgets" */;\n'
        '${t3}buildPhases = (\n'
        '$t4${ids['sources']} /* Sources */,\n'
        '$t4${ids['frameworks']} /* Frameworks */,\n'
        '$t4${ids['resources']} /* Resources */,\n'
        '$t3);\n'
        '${t3}buildRules = (\n$t3);\n'
        '${t3}dependencies = (\n$t3);\n'
        '${t3}name = $_widgets;\n'
        '${t3}productName = $_widgets;\n'
        '${t3}productReference = ${ids['product']} /* $_widgets.appex */;\n'
        '${t3}productType = "com.apple.product-type.app-extension";\n'
        '\t\t};\n',
    'PBXResourcesBuildPhase': _phase(ids['resources']!, 'Resources', 'PBXResourcesBuildPhase', const []),
    'PBXSourcesBuildPhase': _phase(ids['sources']!, 'Sources', 'PBXSourcesBuildPhase',
        [for (final f in swift) '${ids['$f build']} /* $f in Sources */']),
    'PBXTargetDependency': '\t\t${ids['dependency']} /* PBXTargetDependency */ = {\n'
        '${t3}isa = PBXTargetDependency;\n'
        '${t3}target = ${ids['target']} /* $_widgets */;\n'
        '${t3}targetProxy = ${ids['proxy']} /* PBXContainerItemProxy */;\n'
        '\t\t};\n',
    'XCBuildConfiguration': [
      for (final (name, bundle, team) in configs) _widgetConfig(ids['config $name']!, name, bundle ?? fallbackBundle, team, ids['xcconfig']!),
    ].join(),
    'XCConfigurationList': '\t\t${ids['configList']} /* Build configuration list for PBXNativeTarget "$_widgets" */ = {\n'
        '${t3}isa = XCConfigurationList;\n'
        '${t3}buildConfigurations = (\n'
        '${[for (final c in configs) '$t4${ids['config ${c.$1}']} /* ${c.$1} */,\n'].join()}'
        '$t3);\n'
        '${t3}defaultConfigurationIsVisible = 0;\n'
        '${t3}defaultConfigurationName = Release;\n'
        '\t\t};\n',
  };

  // Runner embeds the extension (before Thin Binary) and depends on it.
  var runnerBlock = runner.group(0)!;
  final phases = RegExp(r'buildPhases = \(\n([\s\S]*?)\t\t\t\);').firstMatch(runnerBlock);
  final dependencies = RegExp(r'dependencies = \(\n').firstMatch(runnerBlock);
  if (phases == null || dependencies == null) return fail("Runner's build phases and dependencies");
  final thin = RegExp(r'\t\t\t\t\w{24} /\* Thin Binary \*/,\n').firstMatch(phases.group(1)!);
  final embedAt = phases.start + 'buildPhases = (\n'.length + (thin?.start ?? phases.group(1)!.length);
  final edits = [
    (embedAt, '$t4${ids['embed']} /* Embed Foundation Extensions */,\n'),
    (dependencies.end, '$t4${ids['dependency']} /* PBXTargetDependency */,\n'),
  ]..sort((a, b) => b.$1.compareTo(a.$1));
  for (final (at, text) in edits) {
    runnerBlock = runnerBlock.replaceRange(at, at, text);
  }

  // The project lists the target; the main and Products groups show it.
  var projectBlock = project.group(0)!;
  final targets = RegExp(r'targets = \(\n[\s\S]*?\t\t\t\);').firstMatch(projectBlock);
  if (targets == null) return fail("the project's target list");
  final listEnd = targets.end - '\t\t\t);'.length;
  projectBlock = projectBlock.replaceRange(listEnd, listEnd, '$t4${ids['target']} /* $_widgets */,\n');
  final attributes = RegExp(r'TargetAttributes = \{\n').firstMatch(projectBlock);
  if (attributes != null) {
    projectBlock = projectBlock.replaceRange(attributes.end, attributes.end,
        '\t\t\t\t\t${ids['target']} = {\n\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n\t\t\t\t\t};\n');
  }

  var out = pbx.replaceRange(project.start, project.end, projectBlock);
  out = out.replaceFirst(runner.group(0)!, runnerBlock);
  for (final (group, child) in [
    (mainGroup, '${ids['group']} /* $_widgets */'),
    (productsGroup, '${ids['product']} /* $_widgets.appex */'),
  ]) {
    final children = RegExp('$group (/\\*[^*]*\\*/ )?= \\{\\s*isa = PBXGroup;\\s*children = \\(\\n').firstMatch(out);
    if (children == null) return fail('the group $group');
    out = out.replaceRange(children.end, children.end, '$t4$child,\n');
  }
  for (final MapEntry(key: section, value: text) in sections.entries) {
    final begin = '/* Begin $section section */\n';
    final at = out.indexOf(begin);
    if (at >= 0) {
      out = out.replaceRange(at + begin.length, at + begin.length, text);
    } else {
      // Xcode sorts sections when it next saves; any place inside objects works.
      final end = out.lastIndexOf('\t};\n\trootObject');
      if (end < 0) return fail('the end of the objects');
      out = out.replaceRange(end, end, '\n$begin$text/* End $section section */\n');
    }
  }
  return WidgetTargetResult(pbx: out);
}

String _phase(String id, String name, String isa, List<String> files) => '\t\t$id /* $name */ = {\n'
    '\t\t\tisa = $isa;\n'
    '\t\t\tbuildActionMask = 2147483647;\n'
    '\t\t\tfiles = (\n'
    '${[for (final f in files) '\t\t\t\t$f,\n'].join()}'
    '\t\t\t);\n'
    '\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
    '\t\t};\n';

String _widgetConfig(String id, String name, String bundle, String? team, String xcconfig) {
  final debug = name.toLowerCase().startsWith('debug');
  final settings = {
    'CODE_SIGN_STYLE': 'Automatic',
    if (team != null) 'DEVELOPMENT_TEAM': team,
    'INFOPLIST_FILE': '$_widgets/Info.plist',
    'IPHONEOS_DEPLOYMENT_TARGET': '17.0',
    'LD_RUNPATH_SEARCH_PATHS':
        '(\n\t\t\t\t\t"\$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t\t"@executable_path/../../Frameworks",\n\t\t\t\t)',
    'PRODUCT_BUNDLE_IDENTIFIER': '$bundle.$_widgets',
    'PRODUCT_NAME': '"\$(TARGET_NAME)"',
    'SKIP_INSTALL': 'YES',
    if (debug) 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG',
    if (!debug) 'SWIFT_COMPILATION_MODE': 'wholemodule',
    'SWIFT_EMIT_LOC_STRINGS': 'YES',
    'SWIFT_OPTIMIZATION_LEVEL': debug ? '"-Onone"' : '"-O"',
    'SWIFT_VERSION': '5.0',
    'TARGETED_DEVICE_FAMILY': '"1,2"',
  };
  return '\t\t$id /* $name */ = {\n'
      '\t\t\tisa = XCBuildConfiguration;\n'
      '\t\t\tbaseConfigurationReference = $xcconfig /* $_widgets.xcconfig */;\n'
      '\t\t\tbuildSettings = {\n'
      '${[for (final MapEntry(:key, :value) in settings.entries) '\t\t\t\t$key = $value;\n'].join()}'
      '\t\t\t};\n'
      '\t\t\tname = ${name.contains(' ') ? '"$name"' : name};\n'
      '\t\t};\n';
}
