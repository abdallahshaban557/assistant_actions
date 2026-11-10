/// Base types for the generated schema libraries in `package:assistant_actions/schemas/`.
library;

/// An annotation that adopts one of Apple's App Schema entities, such as
/// `@RemindersReminder(...)`. Each schema's subclass is generated from Apple's
/// schema catalog.
abstract class SchemaEntity {
  const SchemaEntity(this.schema);

  /// The schema's identifier, such as `reminders.reminder`.
  final String schema;
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
  const SchemaIntents(this.domain);

  /// The schema domain, such as `camera`.
  final String domain;
}
