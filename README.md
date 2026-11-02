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
dart run tool/export_catalog.dart reminders notes
```
