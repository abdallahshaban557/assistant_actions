# assistant_actions_generator

The `build_runner` generator for
[`assistant_actions`](https://pub.dev/packages/assistant_actions). It reads
`@AssistantAction`, `@AssistantEntity`, `@AssistantFocusFilter` and App Schema annotations from
`lib/assistant_actions.dart` and writes:

- `lib/assistant_actions.g.dart` — the registry for `AssistantActions.start`,
  a typed handler interface per schema entity, and, with an
  `@AssistantBackground()` function, the entrypoint of the headless engine
  that answers Siri on iOS without opening the app;
- `packages/assistant_actions_app/.../AssistantActions.g.swift` — the App
  Intents, entities, queries and schema containers, with what Apple
  Intelligence uses in context: `Transferable` entities (and the exports and
  `IntentValueQuery`s of Apple's query schemas), deep links, predictions,
  donations, on-screen entities and Visual Intelligence search;
- `apple/AssistantShortcuts.g.swift` — the App Shortcuts (for plain actions,
  snapshot answers and `@IntentShortcut` schema intents), for the Runner
  targets. Generated types the Runner refers to are made `public`.

It checks what Apple's metadata step would reject at build time instead:
phrases without `{app}` or naming parameters that aren't entities or enums,
more than 10 App Shortcuts, hidden actions as shortcuts, unsupported parameter
and result types, shortcuts for intents a class doesn't turn on, Shortcuts
`summary` sentences naming parameters an intent doesn't have, and unlock
policies below what Apple's schema for an intent requires (which it raises).

```bash
flutter pub add assistant_actions dev:build_runner dev:assistant_actions_generator
```

```bash
dart run build_runner build
```

The Swift is written for the deployment target of the generated plugin
(`packages/assistant_actions_app/darwin/assistant_actions_app/Package.swift`):
from iOS 26 / macOS 26 it uses `supportedModes` instead of the deprecated
`ForegroundContinuableIntent`. Override it in `build.yaml`:

```yaml
targets:
  $default:
    builders:
      assistant_actions_generator:assistant_actions:
        options:
          ios_deployment_target: "26.0"
          macos_deployment_target: "26.0"
```

Schema definitions come from the catalog bundled with `assistant_actions`
(exported from Xcode's `AppIntentSchemas.sqlite`), so generation doesn't need
Xcode and works on any CI. See the `assistant_actions` README for usage.

Maintainers refresh the catalog with `tool/export_catalog.dart` and check
every schema against Apple's metadata processor with
`tool/validate_schemas.dart` (macOS with Xcode).
