# assistant_actions

Siri, Shortcuts, Spotlight and Apple Intelligence for Flutter on iOS and macOS.

| Path | What |
|---|---|
| `packages/assistant_actions` | Runtime plugin, annotations, typed App Schema libraries, `install` script |
| `packages/assistant_actions_generator` | `build_runner` builder; `tool/export_catalog.dart` refreshes the schema catalog from Xcode |
| `example` | App using every feature, built for iOS and macOS |

Refresh the schema catalog after a new Xcode:

```bash
cd packages/assistant_actions_generator
dart run tool/export_catalog.dart          # every domain the SDK defines publicly
dart run tool/validate_schemas.dart --report=../assistant_actions/doc/schemas_table.md
```

The validator adopts every schema at once in a throwaway app and runs the
builder, `flutter analyze`, and Apple's `appintentsmetadataprocessor` for macOS
and the iOS simulator. Every other intent also gets a spoken result, a
confirmation and, when it's live, a Dart reply with a result card, so both
shapes of each intent are checked. The app sets up background execution
(`@AssistantBackground()`); `--no-background` checks the output without it.
Paste its report into
`packages/assistant_actions/doc/schemas.md`.

## Releasing

Pull requests to `main` are checked by `.github/workflows/check.yml`. A PR that
changes a package (anything outside its `test/` and `tool/`) must bump that
package's `version` and add a matching `## <version>` entry at the top of its
`CHANGELOG.md`. Check locally with:

```bash
dart run tool/check_versions.dart origin/main
```

After merging, release each bumped package by pushing its tag. The check prints
the exact command:

```bash
git tag assistant_actions-v0.0.3 && git push origin assistant_actions-v0.0.3
git tag assistant_actions_generator-v0.0.3 && git push origin assistant_actions_generator-v0.0.3
```

`.github/workflows/publish.yml` then publishes it to pub.dev with pub.dev's
automated publishing (no stored secret), after approval in the `pub.dev`
environment.
