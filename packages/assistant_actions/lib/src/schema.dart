/// Base types for the generated schema libraries in `package:assistant_actions/schemas/`.
library;

/// An annotation that adopts one of Apple's App Schema entities, such as
/// `@RemindersReminder(...)`. Each schema's subclass is generated from Apple's
/// schema catalog.
abstract class SchemaEntity {
  const SchemaEntity(
    this.schema, {
    this.dialogs = const {},
    this.confirm = const {},
    this.confirmDeletes = true,
    this.replies = const {},
    this.url,
    this.visualSearch = false,
  });

  /// The schema's identifier, such as `reminders.reminder`.
  final String schema;

  /// What Siri says when a turned-on intent finishes, by intent name:
  /// `{'createReminder': 'Added {title}.'}`. `{name}` is the intent's
  /// parameter `name` (an item is its title, a list reads "A, B and C");
  /// `{result}` is the item an intent returns. Checked at build time.
  final Map<String, String> dialogs;

  /// Intents Siri asks the user to confirm before running, with the
  /// question, by intent name: `{'cancelTimer': 'Cancel {entities}?'}`.
  /// Placeholders work as in [dialogs]. Confirmation happens in Swift,
  /// before anything is queued or Dart runs.
  final Map<String, String> confirm;

  /// Delete intents (`deleteReminders`) ask "Delete …?" first, the way
  /// Apple's apps do. Set false to delete at once; a delete listed in
  /// [confirm] still asks, with that question.
  final bool confirmDeletes;

  /// Live intents whose Dart handler method returns an `AssistantReply`
  /// (what Siri says, a result card, or several items to choose from)
  /// instead of a plain value. Changes those methods' return types.
  final Set<String> replies;

  /// A deep link to an item, such as `'mira://tasks/{id}'`; see
  /// `AssistantEntity.url`.
  final String? url;

  /// Visual Intelligence shows these items for what the camera or a
  /// screenshot shows; see `AssistantEntity.visualSearch`.
  final bool visualSearch;
}

/// A member of schema entity [S] with Dart type [T], used as a field
/// annotation: `@ReminderField.dueDate DateTime? due;`.
class SchemaMember<S, T> {
  const SchemaMember(this.schema, this.name);

  /// The owning entity schema, such as `reminders.reminder`.
  final String schema;

  /// The member's name in the schema, such as `dueDate`.
  final String name;
}

/// A fixed instance of a container entity a schema requires, such as the one
/// list every reminder belongs to.
///
/// Each schema's subclass (such as `FixedList`) adds the members the schema
/// declares.
abstract class SchemaContainer {
  const SchemaContainer(this.schema, this.id);

  /// The container's schema, such as `reminders.list`.
  final String schema;

  /// A stable id for the instance.
  final String id;
}

/// An annotation giving the cases of a schema enum whose cases the app
/// defines, such as `@CameraCaptureMode()` on
/// `enum CaptureMode { photo, video }`. Each Dart case becomes one case of
/// the schema enum, by name.
abstract class SchemaEnumCases {
  const SchemaEnumCases(this.schema);

  /// The schema enum, such as `camera.captureMode`.
  final String schema;
}

/// An annotation that turns on a domain's App Schema intents that belong to
/// no entity, such as `@CameraIntents(startCapture: true)`. Put it on the
/// class implementing the generated handler (`CameraAssistantHandler`).
abstract class SchemaIntents {
  const SchemaIntents(this.domain, {this.dialogs = const {}, this.confirm = const {}, this.replies = const {}});

  /// The schema domain, such as `camera`.
  final String domain;

  /// What Siri says when a turned-on intent finishes, by intent name. See
  /// [SchemaEntity.dialogs].
  final Map<String, String> dialogs;

  /// Intents Siri asks the user to confirm first, with the question. See
  /// [SchemaEntity.confirm].
  final Map<String, String> confirm;

  /// Live intents whose handler method returns an `AssistantReply`. See
  /// [SchemaEntity.replies].
  final Set<String> replies;
}
