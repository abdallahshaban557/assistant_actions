## 0.0.3

* Dart and Swift now talk over FFI (Pigeon native interop) instead of a
  platform channel. No API changes. Apps pick up `ffi` and `objective_c` as
  dependencies.

## 0.0.2

* Add repository and issue tracker links.

## 0.0.1

* First preview: iOS 17+ / macOS 14+.
* Actions (`@AssistantAction`), entities (`@AssistantEntity`) and App Schema
  adoption for `reminders.*` and `notes.*` with typed annotations.
* Deferred actions and schema changes work without Flutter running, through a
  UserDefaults inbox that Dart applies on start and resume.
