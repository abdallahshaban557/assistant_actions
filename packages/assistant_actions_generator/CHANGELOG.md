## 0.0.3

* Generates snapshot-answer actions (`@AssistantAction` on a
  `const SnapshotAnswer<T>`) and checks their fields and value types at build
  time.
* Update intents read `$param.valueState`, so Siri clearing an optional field
  arrives as cleared, not unchanged; `…Values` classes get `cleared` and
  `<field>Cleared`.
* `@AssistantEntity` classes publish their String, int, double, bool,
  DateTime and Uri fields, so snapshot answers can use them.
* Needs assistant_actions 0.0.5 or later, and says so if it's older.
* README: install with `flutter pub add`.

## 0.0.2

* Add repository and issue tracker links.

## 0.0.1

* First preview: iOS 17+ / macOS 14+.
* Actions (`@AssistantAction`), entities (`@AssistantEntity`) and App Schema
  adoption for `reminders.*` and `notes.*` with typed annotations.
* Deferred actions and schema changes work without Flutter running, through a
  UserDefaults inbox that Dart applies on start and resume.
