/// The iOS and macOS versions the generated Swift is compiled for.
library;

/// Where the builder finds the app's deployment target, relative to the
/// app's root: the generated plugin's package, which compiles
/// `AssistantActions.g.swift`.
const pluginPackageSwift = 'packages/assistant_actions_app/darwin/assistant_actions_app/Package.swift';

/// The iOS and macOS versions the generated Swift is compiled for: the
/// `platforms` of the app's `assistant_actions_app` package (which
/// `dart run assistant_actions:install` takes from the Runner targets), or
/// the builder's `ios_deployment_target` / `macos_deployment_target` options.
///
/// From iOS 26 / macOS 26, `ForegroundContinuableIntent` is deprecated, so
/// the writer uses `supportedModes` for the platforms at 26 or later.
class DeploymentTarget {
  const DeploymentTarget({required this.iOS, required this.macOS});

  /// What App Intents here need: iOS 17, macOS 14.
  static const minimum = DeploymentTarget(iOS: 17, macOS: 14);

  /// The targets in a `Package.swift`'s `platforms: [.iOS("26.0"), .macOS("26.0")]`
  /// (or `.v26`), or null when it names neither.
  static DeploymentTarget? fromPackageSwift(String text) {
    num? version(String platform) {
      final m = RegExp(r'\.' + platform + r'\(\s*(?:"([0-9.]+)"|\.v([0-9_]+))\s*\)').firstMatch(text);
      if (m == null) return null;
      return parseVersion(m[1] ?? m[2]!.replaceAll('_', '.'));
    }

    final iOS = version('iOS'), macOS = version('macOS');
    if (iOS == null && macOS == null) return null;
    return DeploymentTarget(iOS: iOS ?? minimum.iOS, macOS: macOS ?? minimum.macOS).atLeastMinimum;
  }

  /// The builder's options (`build.yaml`), over [fallback].
  static DeploymentTarget fromOptions(Map<String, Object?> options, DeploymentTarget fallback) {
    final iOS = parseVersion(options['ios_deployment_target']?.toString());
    final macOS = parseVersion(options['macos_deployment_target']?.toString());
    return DeploymentTarget(iOS: iOS ?? fallback.iOS, macOS: macOS ?? fallback.macOS).atLeastMinimum;
  }

  /// `26.0` → 26, `26.4.1` → 26.4; null when it isn't a version.
  static num? parseVersion(String? v) {
    if (v == null) return null;
    final parts = v.trim().split('.');
    final major = int.tryParse(parts.first);
    if (major == null) return null;
    final minor = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    return minor == 0 ? major : num.parse('$major.$minor');
  }

  final num iOS;
  final num macOS;

  /// Never below [minimum].
  DeploymentTarget get atLeastMinimum => DeploymentTarget(
        iOS: iOS < minimum.iOS ? minimum.iOS : iOS,
        macOS: macOS < minimum.macOS ? minimum.macOS : macOS,
      );

  /// [platform]'s target (`iOS` or `macOS`).
  num operator [](String platform) => platform == 'iOS' ? iOS : macOS;

  @override
  bool operator ==(Object other) => other is DeploymentTarget && other.iOS == iOS && other.macOS == macOS;

  @override
  int get hashCode => Object.hash(iOS, macOS);

  @override
  String toString() => 'iOS $iOS, macOS $macOS';
}
