/// Makes a top-level function the app's Focus filter (Apple's
/// `SetFocusFilterIntent`): in Settings → Focus, a user adds it to a Focus
/// and picks values for its parameters, and the function runs with them
/// when that Focus turns on. When it turns off, it runs again with every
/// parameter at its default, so treat the defaults as "no Focus".
///
/// ```dart
/// @AssistantFocusFilter(title: 'Journal', summary: 'Only {tag}')
/// Future<void> applyFocus({bool hideTasks = false, String? tag}) async { … }
/// ```
///
/// Parameters are String, int, double, bool, DateTime, Uri, Duration or
/// `@AssistantEntity` values, each nullable or with a constant default (the
/// system creates the filter with its defaults). `@Param` sets their titles.
/// The function returns nothing.
///
/// The system can run the filter while the app is in the background or not
/// running. When Dart is running, the function runs at once; otherwise the
/// call is queued, like a `Runs.deferred` action, and runs when the app
/// next starts or resumes.
class AssistantFocusFilter {
  const AssistantFocusFilter({required this.title, this.description, this.summary});

  /// The filter's name in Settings.
  final String title;
  final String? description;

  /// What Settings shows under [title] for the chosen values. `{name}` is
  /// parameter `name` (empty when null).
  final String? summary;
}
