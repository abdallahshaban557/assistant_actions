// Checks that a pull request which changes a package also releases it: the
// version in its pubspec.yaml goes up and CHANGELOG.md has an entry for it.
//
//   dart run tool/check_versions.dart origin/main
//
// Changes only under a package's test/ or tool/ don't need a release.
// Exits non-zero and prints GitHub annotations when a check fails.

import 'dart:io';

const _exempt = ['test/', 'tool/'];

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/check_versions.dart <base-ref>');
    exit(64);
  }
  final base = args.single;
  final packages = Directory('packages').listSync().whereType<Directory>().map((d) => d.path).toList()..sort();
  var failed = false;

  for (final dir in packages) {
    final pubspec = File('$dir/pubspec.yaml');
    if (!pubspec.existsSync()) continue;
    final changed = _git(['diff', '--name-only', '$base...HEAD', '--', '$dir/'])
        .split('\n')
        .where((f) => f.isNotEmpty && !_exempt.any((e) => f.startsWith('$dir/$e')))
        .toList();
    final name = dir.split('/').last;
    if (changed.isEmpty) {
      stdout.writeln('$name: no release needed (no package changes)');
      continue;
    }

    final version = _version(pubspec.readAsStringSync());
    if (version == null) {
      _fail('$dir/pubspec.yaml', '$name has no valid version.');
      failed = true;
      continue;
    }
    var ok = true;
    final baseText = _gitOrNull(['show', '$base:$dir/pubspec.yaml']);
    final baseVersion = baseText == null ? null : _version(baseText);
    if (baseVersion != null && _compare(version, baseVersion) <= 0) {
      _fail('$dir/pubspec.yaml',
          '$name changed (${changed.length} file(s)) but its version is still ${baseVersion.text}. Bump it.');
      ok = false;
    }

    final changelog = File('$dir/CHANGELOG.md');
    final headings = changelog.existsSync()
        ? RegExp(r'^##\s+(\S+)', multiLine: true).allMatches(changelog.readAsStringSync()).map((m) => m[1])
        : const <String>[];
    if (headings.firstOrNull != version.text) {
      _fail('$dir/CHANGELOG.md', '$name ${version.text} needs a "## ${version.text}" entry at the top of CHANGELOG.md.');
      ok = false;
    }

    failed |= !ok;
    if (ok) {
      stdout.writeln('$name: ${baseVersion?.text ?? '(new)'} → ${version.text}; '
          'after merging, release with: git tag $name-v${version.text} && git push origin $name-v${version.text}');
    }
  }
  exit(failed ? 1 : 0);
}

class _Version {
  _Version(this.text, this.parts, this.prerelease);
  final String text;
  final List<int> parts;
  final String? prerelease;
}

_Version? _version(String pubspec) {
  final raw = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec)?.group(1);
  final m = raw == null ? null : RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+\S+)?$').firstMatch(raw);
  if (m == null) return null;
  return _Version(raw!, [for (var i = 1; i <= 3; i++) int.parse(m[i]!)], m[4]);
}

/// Semver order, enough for releases: numbers first, and a prerelease
/// (`1.0.0-dev`) comes before its release (`1.0.0`).
int _compare(_Version a, _Version b) {
  for (var i = 0; i < 3; i++) {
    final c = a.parts[i].compareTo(b.parts[i]);
    if (c != 0) return c;
  }
  if (a.prerelease == b.prerelease) return 0;
  if (a.prerelease == null) return 1;
  if (b.prerelease == null) return -1;
  return a.prerelease!.compareTo(b.prerelease!);
}

void _fail(String file, String message) {
  stdout.writeln('::error file=$file::$message');
}

String _git(List<String> args) {
  final result = Process.runSync('git', args);
  if (result.exitCode != 0) {
    stderr.writeln('git ${args.join(' ')} failed: ${result.stderr}');
    exit(2);
  }
  return result.stdout as String;
}

String? _gitOrNull(List<String> args) {
  final result = Process.runSync('git', args);
  return result.exitCode == 0 ? result.stdout as String : null;
}
