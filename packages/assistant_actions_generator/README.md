# assistant_actions_generator

The `build_runner` generator for
[`assistant_actions`](https://pub.dev/packages/assistant_actions). It reads
`@AssistantAction`, `@AssistantEntity`, `@AssistantFocusFilter` and App Schema annotations from
`lib/assistant_actions.dart` and writes:

- `lib/assistant_actions.g.dart` — the registry for `AssistantActions.start` and
  a typed handler interface per schema entity;
- `packages/assistant_actions_app/.../AssistantActions.g.swift` — the App
  Intents, entities, queries and schema containers;
- `apple/AssistantShortcuts.g.swift` — the App Shortcuts, for the Runner targets.

```bash
flutter pub add assistant_actions dev:build_runner dev:assistant_actions_generator
```

```bash
dart run build_runner build
```

Schema definitions come from the catalog bundled with `assistant_actions`
(exported from Xcode's `AppIntentSchemas.sqlite`), so generation doesn't need
Xcode and works on any CI. See the `assistant_actions` README for usage.

Maintainers refresh the catalog with `tool/export_catalog.dart` and check
every schema against Apple's metadata processor with
`tool/validate_schemas.dart` (macOS with Xcode).
