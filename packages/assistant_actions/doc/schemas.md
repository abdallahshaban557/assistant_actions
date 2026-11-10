# App Schema support

Every App Schema in Xcode 27.2's catalog (27B52, hash c2d369abe24c) that the
SDK defines publicly has a typed library in `package:assistant_actions/schemas/`.
The generator was validated against all of them at once: a throwaway app that
adopts every entity it can, with every intent turned on, builds for macOS and
the iOS simulator, and Apple's `appintentsmetadataprocessor` accepts it with
no errors (`dart run tool/validate_schemas.dart` in the generator).

- **Full**: every public entity and intent can be adopted, and Dart gets every
  parameter.
- **Partial**: what's listed under gaps isn't supported yet. A dropped
  parameter still reaches the Swift intent, so the schema is valid; Dart just
  doesn't receive it.

| Domain | Support | Entities | Intents | Gaps |
|---|---|---|---|---|
| `assistant` | Full | 0/0 | 1/1 |  |
| `audio` | Partial | 18/18 | 6/7 | `recognizeAudio`: returns [union:audio.audioItem]; `addToLibrary` doesn't pass `audioEntity` (union) to Dart; `addToPlaylist` doesn't pass `audioEntity` (union) to Dart; `playAudio` doesn't pass `audioEntity` (union) to Dart; `updateAudioAffinity` doesn't pass `target` (union) to Dart; `warmupAudioQueue` doesn't pass `audioEntity` (union) to Dart; 3 schemas not adoptable (3 not public) |
| `books` | Full | 3/3 | 7/7 | 2 schemas not adoptable (2 deprecated) |
| `browser` | Full | 5/5 | 12/12 | 4 schemas not adoptable (3 not public, 1 deprecated) |
| `calendar` | Partial | 2/3 | 3/3 | `attendee`: person (person) is required and has no Dart mapping or default; `createEvent` doesn't pass `location` (union), `recurrence` (recurrenceRule) to Dart; `updateEvent` doesn't pass `recurrence` (recurrenceRule), `location` (union) to Dart |
| `camera` | Full | 0/0 | 5/5 |  |
| `clock` | Partial | 3/3 | 14/14 | `createAlarm` doesn't pass `recurrenceDays` (recurrenceRule) to Dart; `updateAlarm` doesn't pass `recurrenceDays` (recurrenceRule) to Dart |
| `files` | Partial | 0/1 | 0/5 | `file`: file entity (FileEntity ids); 1 schemas not adoptable (1 not public) |
| `journal` | Partial | 1/1 | 4/4 | `createEntry` doesn't pass `location` (placeDescriptor), `mediaItems` (file) to Dart; `updateEntry` doesn't pass `mediaItems` (file), `location` (placeDescriptor) to Dart; 1 schemas not adoptable (1 deprecated) |
| `mail` | Partial | 4/5 | 6/12 | `message`: sender (person) is required and has no Dart mapping or default; `createDraft` doesn't pass `to` (person), `cc` (person), `bcc` (person), `attachments` (file) to Dart; `updateDraft` doesn't pass `to` (person), `cc` (person), `bcc` (person), `attachments` (file) to Dart |
| `maps` | Partial | 5/6 | 6/6 | `place`: place (placeDescriptor) is required and has no Dart mapping or default; `shareETA` doesn't pass `person` (person) to Dart; `startNavigation` doesn't pass `origin` (union), `destinations` (union) to Dart; `stopShareETA` doesn't pass `person` (person) to Dart; `updateNavigationWaypoints` doesn't pass `waypoints` (union) to Dart; 17 schemas not adoptable (17 not public) |
| `messages` | Partial | 2/4 | 0/5 | `message`: author needs messages.messagePerson, which is not adopted (person (person) is required and has no Dart mapping or default); `messagePerson`: person (person) is required and has no Dart mapping or default; 1 schemas not adoptable (1 not public) |
| `notes` | Partial | 3/3 | 3/3 | `createNote` doesn't pass `attachments` (file) to Dart; `updateNote` doesn't pass `attachments` (file) to Dart |
| `phone` | Partial | 0/1 | 0/0 | `phonePerson`: person (person) is required and has no Dart mapping or default; 18 schemas not adoptable (17 not public, 1 uses a private schema) |
| `photos` | Partial | 3/3 | 26/26 | `createAssets` doesn't pass `files` (file) to Dart; `postToSharedAlbum` doesn't pass `files` (file) to Dart; 15 schemas not adoptable (13 not public, 2 deprecated) |
| `presentation` | Partial | 3/3 | 15/15 | `addImageToSlide` doesn't pass `image` (file) to Dart; `addVideoToSlide` doesn't pass `video` (file) to Dart; `addAudioToSlide` doesn't pass `audio` (file) to Dart |
| `reader` | Partial | 2/2 | 9/9 | `openDocument` doesn't pass `files` (file) to Dart; `insertPages` doesn't pass `files` (file) to Dart |
| `reminders` | Partial | 4/5 | 5/5 | `locationTrigger`: place (placeDescriptor) is required and has no Dart mapping or default; `createReminder` doesn't pass `images` (file), `recurrence` (recurrenceRule) to Dart; `updateReminder` doesn't pass `recurrence` (recurrenceRule) to Dart |
| `spreadsheet` | Partial | 3/3 | 14/14 | `addImageToSheet` doesn't pass `image` (file) to Dart; `addVideoToSheet` doesn't pass `video` (file) to Dart; `addAudioToSheet` doesn't pass `audio` (file) to Dart |
| `system` | Full | 0/0 | 2/2 | 1 schemas not adoptable (1 deprecated) |
| `visualIntelligence` | Partial | 0/0 | 1/1 | `semanticContentSearch` doesn't pass `semanticContent` (sceneDescriptor) to Dart; 1 schemas not adoptable (1 not public) |
| `whiteboard` | Partial | 2/2 | 7/7 | `createItem` doesn't pass `mediaItems` (file) to Dart |
| `wordProcessor` | Partial | 3/3 | 9/9 | `addVideoToPage` doesn't pass `video` (file) to Dart; `addImageToPage` doesn't pass `image` (file) to Dart; `addAudioToPage` doesn't pass `audio` (file) to Dart |

## Not adoptable

These domains are in the catalog, but the SDK defines none of their schemas
publicly, so no app can adopt them: `appLaunch`, `appStore`, `contacts`,
`findMy`, `health`, `home`, `imageGeneration`, `notifications`,
`playbackControls`, `video`, `voiceMemos`, `writingTools`.

Each catalog's `skipped` section (`lib/src/catalog/<domain>.json`) lists the
schemas left out of an adoptable domain and why: no public definition,
deprecated (for example `journal.search`, replaced by `system.searchInApp`),
or using a private schema (`phone.startCall` can take a private call group).

## Not supported yet

- **People** (`IntentPerson`), **files** (`IntentFile`), **places**
  (`PlaceDescriptor`), **unions** and **recurrence rules** have no Dart type.
  As intent parameters they are dropped. As entity members they get their
  empty value when optional, and an entity that requires one can't be adopted
  (calendar attendees, mail messages, message people, map places, phone
  people, reminder location triggers).
- **`files.file`** needs file-based ids (`FileEntity`).
- **`audio.recognizeAudio`** returns a union.
