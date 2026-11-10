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
dart run tool/export_catalog.dart reminders notes journal
```

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
