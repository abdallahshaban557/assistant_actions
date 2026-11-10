// Tests for the Swift that runs without Flutter (snapshot answers). Run with
// tool/test_swift.sh, which compiles this with the runtime's Foundation-only
// sources; no Flutter, Xcode project or simulator involved.
import AppIntents
import Foundation

var failures = 0
func check(_ actual: String, _ expected: String, _ name: String, line: Int = #line) {
  if actual == expected { print("ok   \(name)") } else {
    failures += 1
    print("FAIL \(name) (line \(line))\n  expected: \(expected)\n  actual:   \(actual)")
  }
}

/// Records the way Swift reads them: from the JSON Dart publishes.
func records(_ json: String) -> [AssistantRecord] {
  let items = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
  return items.map {
    AssistantRecord(id: $0["id"] as! String, title: $0["title"] as? String ?? "", fields: $0["fields"] as! [String: Any])
  }
}

func answer(_ recs: [AssistantRecord], limit: Int = 5, sortBy: String? = "due", descending: Bool = false) -> AssistantQuery.Answer {
  AssistantQuery.answer(
    records: recs, where: ["done": false], sortBy: sortBy, descending: descending, limit: limit,
    dateFields: ["due"], titleField: "title", item: "{title}[ ({due})]",
    dialog: "You have {count} {count|task|tasks}: {items}[, and {rest} more].",
    empty: "Your list is clear.", separator: ", ")
}

let nine = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9))!
let midnight = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 4))!
let nineText = nine.formatted(date: .abbreviated, time: .shortened)
let midnightText = midnight.formatted(date: .abbreviated, time: .omitted)

// Mira's "Show Mira Tasks": open tasks, soonest first, undated last, 5 at most.
let tasks = records("""
  [{"id":"a","title":"","fields":{"title":"Buy milk","done":false}},
   {"id":"b","title":"Call mum","fields":{"title":"Call mum","due":\(nine.timeIntervalSince1970),"done":false}},
   {"id":"c","title":"Done one","fields":{"title":"Done one","done":true}},
   {"id":"d","title":"Pay rent","fields":{"title":"Pay rent","due":\(midnight.timeIntervalSince1970),"done":false}}]
  """)
check(answer(tasks).dialog, "You have 3 tasks: Call mum (\(nineText)), Pay rent (\(midnightText)), Buy milk.",
  "filters done, sorts by due with undated last, drops empty segments, falls back to the title field")
check(answer(tasks, limit: 1).dialog, "You have 3 tasks: Call mum (\(nineText)), and 2 more.", "{rest} segment")
check(answer(Array(tasks.prefix(1))).dialog, "You have 1 task: Buy milk.", "singular")
check(answer([]).dialog, "Your list is clear.", "empty")
check(answer(tasks, sortBy: "due", descending: true).items.joined(separator: "|"),
  "Pay rent (\(midnightText))|Call mum (\(nineText))|Buy milk", "descending keeps undated last")

// JSON numbers 0 and 1 are NSNumbers, not Bools.
let numbers = records(#"[{"id":"x","title":"One","fields":{"n":1,"flag":true}},{"id":"y","title":"Zero","fields":{"n":0,"flag":false}}]"#)
check(
  AssistantQuery.answer(records: numbers, where: ["n": 1], sortBy: nil, descending: false, limit: 5, dateFields: [],
    titleField: nil, item: "{title} {n} {flag}", dialog: "{items}", empty: "-", separator: ","
  ).dialog, "One 1 yes", "int filter matches NSNumber 1; bools print as yes/no")

check(AssistantQuery.render("a[ b {x}] c[ d {y}]", ["x": "", "y": 2]), "a c d 2", "optional segments")
check(AssistantQuery.render("{n|item|items}", ["n": 1]), "item", "plural one")

// Spotlight: what a reindex removes.
func plan(_ previous: [String]?, _ current: [String]) -> String {
  let p = AssistantSpotlight.plan(previous: previous, current: current)
  return p.clearFirst ? "clear" : p.removed.joined(separator: ",")
}
check(plan(nil, ["a"]), "clear", "first run clears what earlier installs indexed")
check(plan(["a", "b", "c"], ["c", "a"]), "b", "removes ids no longer published")
check(plan(["a"], ["a", "new"]), "", "adds without removing")
check(plan(["a", "b"], []), "a,b", "an empty collection removes everything")
check(AssistantSpotlight.indexer() == nil ? "none" : "found", "none",
  "no generated indexer here, so updates are no-ops")

// Entity queries: forgiving matching (Mira's "do I have any tasks in Mira").
let miraTasks = records(#"[{"id":"1","title":"Remember laundry","fields":{"title":"Remember laundry","done":false}},{"id":"2","title":"","fields":{"title":"Call Zoë about the café","done":false}}]"#)
let taskWords: Set<String> = ["task", "item", "taskitem", "reminder", "reminders", "mira"]
func ids(_ string: String) -> String {
  AssistantMatch.records(miraTasks, matching: string, ignoring: taskWords).map(\.id).joined(separator: ",")
}
check(ids("tasks"), "1,2", "a word naming the type lists everything")
check(ids("do I have any tasks in Mira"), "1,2", "filler, type and app words are ignored")
check(ids("my reminders"), "1,2", "schema words are ignored too")
check(ids(""), "1,2", "an empty search lists everything")
check(ids("laundry"), "1", "matches a word in the title")
check(ids("laundry task"), "1", "type words don't narrow a real term")
check(ids("zoe cafe"), "2", "ignores case and accents, reads fields when the title is empty (inbox-created)")
check(ids("laundry zoe"), "1,2", "falls back to any word when no item has all of them")
check(ids("groceries"), "", "an unrelated word finds nothing")

// Entity property queries: Siri's comparators ("open tasks", "due today").
struct TaskEntity {
  let id: String
  var title: String
  var note: AttributedString?
  var due: DateComponents?
  var done: Bool
  var minutes: Int?
}
func day(_ d: Int, hour: Int? = nil) -> DateComponents {
  hour == nil ? DateComponents(year: 2026, month: 11, day: d) : DateComponents(year: 2026, month: 11, day: d, hour: hour)
}
let entityTasks = [
  TaskEntity(id: "a", title: "Buy milk", note: AttributedString("Oat, not cow"), due: day(3), done: false, minutes: 10),
  TaskEntity(id: "b", title: "Call Zoë", note: nil, due: day(3, hour: 17), done: false, minutes: 30),
  TaskEntity(id: "c", title: "Pay rent", note: nil, due: day(5, hour: 9), done: true, minutes: nil),
  TaskEntity(id: "d", title: "Laundry", note: nil, due: nil, done: false, minutes: 45),
]
typealias P = AssistantPredicate<TaskEntity>
func found(_ predicates: [P], all: Bool = true,
  sortedBy sorts: [(key: (TaskEntity) -> AssistantKey?, ascending: Bool)] = [], limit: Int? = nil) -> String {
  P.apply(predicates, all: all, to: entityTasks, sortedBy: sorts, limit: limit).map(\.id).joined(separator: ",")
}
check(found([P({ $0.done }, .equal, false)]), "a,b,d", "open tasks: bool equal")
check(found([P({ $0.done }, .notEqual, false)]), "c", "bool not equal")
check(found([P({ $0.due }, .equal, day(3))]), "a,b", "due today: a whole day equals any time that day")
check(found([P({ $0.due }, .equal, day(3, hour: 17))]), "b", "a timed date equals that time")
check(found([P({ $0.due }, .equal, nil)]), "d", "equal to nil finds items with no value")
check(found([P({ $0.due }, .notEqual, day(3))]), "c,d", "not equal to a day")
check(found([P({ $0.due }, .less, day(5))]), "a,b", "before a day means before it starts; missing values never match")
check(found([P({ $0.due }, .lessOrEqual, day(5))]), "a,b,c", "on or before a day includes all of it")
check(found([P({ $0.due }, .greater, day(3))]), "c", "after a day means after it ends")
check(found([P({ $0.due }, .greaterOrEqual, day(3, hour: 12))]), "b,c", "on or after a time")
check(found([P({ $0.due }, .between, day(3), day(4))]), "a,b", "between two days includes both whole days")
check(found([P({ $0.due }, .between, day(3, hour: 12), day(5, hour: 9))]), "b,c", "between two times is inclusive")
check(found([P({ $0.title }, .contains, "zoe")]), "b", "contains ignores case and accents")
check(found([P({ $0.note }, .contains, AttributedString("OAT"))]), "a", "contains on attributed strings")
check(found([P({ $0.minutes }, .less, 30)]), "a", "numbers compare")
check(found([P({ $0.done }, .equal, false), P({ $0.due }, .equal, day(3))]), "a,b", "all comparators must pass")
check(found([P({ $0.done }, .equal, true), P({ $0.title }, .contains, "milk")], all: false), "a,c", "or mode: any passes")
check(found([]), "a,b,c,d", "no comparators lists everything")
check(found([], sortedBy: [({ $0.due?.assistantKey }, false)]), "c,b,a,d", "sorts descending, missing values last")
check(found([], sortedBy: [({ $0.title.assistantKey }, true)], limit: 2), "a,b", "sorts by text and limits")
check(found([], sortedBy: [({ $0.done.assistantKey }, true), ({ $0.minutes?.assistantKey }, false)]), "d,b,a,c",
  "sorts by each key in turn")
check(day(3) < day(3, hour: 17) ? "yes" : "no", "yes", "DateComponents are Comparable by the date they name")

// Values for schema intents: enums by case name, durations in seconds, id lists.
enum Mode: String { case photo, `repeat` }
check("\(AssistantValues.encode(Mode.repeat))", "repeat", "enums encode as their case name")
check("\(AssistantValues.encode(Optional<Mode>.none))", "<null>", "a missing enum is null")
check("\(AssistantValues.encode(Duration.milliseconds(1500)))", "1.5", "durations encode as seconds")
check("\(AssistantValues.duration(90.0)!)", "\(Duration.seconds(90))", "durations decode from seconds")
check(AssistantValues.stringList(#"["a","b",3]"#).joined(separator: ","), "a,b", "handler id lists decode from JSON")
check((AssistantValues.strings(["x", 1, "y"]) ?? []).joined(separator: ","), "x,y", "referenced ids decode")

// People, files and recurrence rules cross as maps.
let sam = AssistantValues.person(["name": "Sam", "email": "sam@example.com", "id": "s1"])!
let samMap = AssistantValues.encode(sam) as! [String: Any]
check("\(samMap["name"]!),\(samMap["email"]!),\(samMap["id"]!)", "Sam,sam@example.com,s1", "people round-trip")
let note = IntentFile(data: Data("hi".utf8), filename: "note.txt", type: .plainText)
let saved = AssistantValues.encode(note) as! [String: Any]
let savedPath = saved["path"] as! String
check(try! String(contentsOfFile: savedPath, encoding: .utf8), "hi", "files are copied to Application Support")
check(AssistantValues.file(saved)!.filename, "note.txt", "files decode from their path")
try? FileManager.default.removeItem(atPath: (savedPath as NSString).deletingLastPathComponent)
if #available(macOS 15.0, *) {
  let weekly = Calendar.RecurrenceRule.weekly(calendar: .current, interval: 2)
  let back = AssistantValues.recurrence(AssistantValues.encode(weekly))
  check(back == weekly ? "same" : "different", "same", "recurrence rules round-trip through JSON")
}
check("\(AssistantValues.items([1, "a"])!.count)", "2", "lists decode their items")

// Host calls: Dart runs Swift features by name over one FFI method.
MainActor.assumeIsolated {
  AssistantHostCalls.register("double") { args in (args["n"] as? Int ?? 0) * 2 }
  check((try? AssistantHostCalls.invoke("double", argsJson: #"{"n":21}"#)) ?? "nil", "42", "host calls return JSON")
  check((try? AssistantHostCalls.invoke("missing", argsJson: "{}")) == nil ? "threw" : "ran", "threw",
    "unknown host calls throw")
}

// Replies: what a live Dart handler returned as an AssistantReply.
let reply = AssistantReply(json: #"""
  {"value":"t1","dialog":"Opened it.","card":{"title":"Pancakes","subtitle":"20 min",
   "rows":[["Serves","4"],["bad"]],"systemImage":"fork.knife"}}
  """#)
check(reply.dialog ?? "nil", "Opened it.", "replies carry a dialog")
check(reply.ids.joined(separator: ","), "t1", "a reply's value is the one id")
check(reply.card?.title ?? "nil", "Pancakes", "cards have a title")
check(reply.card.map { $0.rows.map { "\($0.label)=\($0.value)" }.joined(separator: ",") } ?? "nil", "Serves=4",
  "card rows are label and value pairs; malformed rows are dropped")
check(reply.card?.systemImage ?? "nil", "fork.knife", "cards take an SF Symbol")
let choose = AssistantReply(json: #"{"choices":["a","b"],"prompt":"Which one?"}"#)
check(choose.ids.joined(separator: ","), "a,b", "choices are the ids to ask about")
check(choose.prompt ?? "nil", "Which one?", "choices carry the question")
check(choose.card == nil ? "none" : "card", "none", "no card without one")
let empty = AssistantReply(json: nil)
check("\(empty.ids.count) \(empty.dialog ?? "nil") \(empty.value == nil)", "0 nil true", "an empty reply")
check(AssistantReply(json: #"{"value":null}"#).value == nil ? "nil" : "value", "nil", "a null value is none")

// Dialogs: parameters read aloud in dialogs and confirmations.
enum Delay: String { case threeSeconds }
check(AssistantDialog.text("Milk"), "Milk", "text reads as is")
check(AssistantDialog.text(nil as String?), "", "nil reads as nothing")
check(AssistantDialog.text(AttributedString("Note")), "Note", "attributed text")
check(AssistantDialog.text(3), "3", "ints")
check(AssistantDialog.text(2.0), "2", "whole doubles read without a fraction")
check(AssistantDialog.text(true), "yes", "bools read yes or no")
check(AssistantDialog.text(Delay.threeSeconds), "three seconds", "enum cases read as words")
check(AssistantDialog.text(nine), nineText, "dates read like snapshot answers")
check(AssistantDialog.text(midnight), midnightText, "midnight reads as the date alone")
check(AssistantDialog.text(Duration.seconds(300)),
  Duration.seconds(300).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)), "durations")
check(AssistantDialog.list(["Milk", "", "Eggs"]), ["Milk", "Eggs"].formatted(.list(type: .and)),
  "lists read as a sentence, skipping empty items")
check(AssistantDialog.list(nil), "", "a nil list reads as nothing")
check(AssistantDialog.items(["Milk"]), "Milk", "items read by title")
check(AssistantDialog.items([""]), "this item", "an untitled item")
check(AssistantDialog.items(["Milk", ""]), "these 2 items", "items when any is untitled")

// Live Activities: the content state Dart sends, and macOS reporting them
// unavailable (ActivityKit is iOS-only).
do {
  let state = AssistantActivityAttributes.ContentState(json: [
    "title": "Recording", "subtitle": "Journal", "systemImage": "mic.fill", "progress": 1.5,
    "timerStart": 1_700_000_000.5, "data": #"{"entry":"j1"}"#,
  ])
  check(state.title, "Recording", "activity content keeps its title")
  check("\(state.progress!)", "1.0", "activity progress is clamped to 0...1")
  check("\(state.timerStart!.timeIntervalSince1970)", "1700000000.5", "activity dates are Unix seconds")
  check("\(state.timerEnd == nil)", "true", "missing dates stay nil")
  check(state.dataObject["entry"] as? String ?? "nil", "j1", "activity data decodes")
  let encoded = try! JSONEncoder().encode(state)
  check(
    try! JSONDecoder().decode(AssistantActivityAttributes.ContentState.self, from: encoded) == state ? "same" : "different",
    "same", "activity content round-trips through Codable")
  check(AssistantActivityAttributes(kind: "recording", data: nil).dataObject.isEmpty ? "empty" : "data", "empty",
    "activities without data decode to an empty object")
  check(AssistantActivityAttributes.ContentState(json: [:]).title, "", "content without a title is blank")
}
MainActor.assumeIsolated {
  AssistantLiveActivities.register()
  check((try? AssistantHostCalls.invoke("liveActivity.enabled", argsJson: "{}")) ?? "nil", "false",
    "Live Activities are off on macOS")
  check((try? AssistantHostCalls.invoke("liveActivity.start", argsJson: #"{"content":{"title":"x"}}"#)) ?? "nil",
    "nil", "starting one on macOS gives nothing")
  check((try? AssistantHostCalls.invoke("liveActivity.list", argsJson: "{}")) ?? "nil", "[]", "none run on macOS")
}

// Action parameters and results: durations as Measurement, results as JSON.
check("\(AssistantValues.encode(Measurement(value: 2, unit: UnitDuration.minutes)))", "120.0",
  "duration parameters encode as seconds")
check("\(AssistantValues.measurement(90)!.converted(to: .minutes).value)", "1.5", "duration results decode from seconds")
let returned = AssistantValues.result(#"{"value":["a","b"],"dialog":"Two."}"#)
check("\(AssistantValues.strings(returned.value)!.joined(separator: ",")) \(returned.dialog!)", "a,b Two.",
  "action results carry a value and a dialog")
let bare = AssistantValues.result(#"{"value":null}"#)
check("\(bare.value == nil) \(bare.dialog == nil)", "true true", "a null result has no value or dialog")

// App Shortcut parameters: the app's generated class is found by name.
check(AssistantShortcutParameters.provider(named: "NoSuchShortcuts") == nil ? "none" : "found", "none",
  "no generated shortcuts class: nothing to update")
@objc(AssistantActionsAppShortcuts)
final class FakeShortcuts: NSObject {
  nonisolated(unsafe) static var calls = 0
  @objc static func updateAppShortcutParameters() { calls += 1 }
}
_ = FakeShortcuts.self
check(AssistantShortcutParameters.updateNow() ? "updated \(FakeShortcuts.calls)" : "none", "updated 1",
  "a generated shortcuts class updates its parameters")
// Background execution: the headless engine's lifecycle, with a fake engine
// whose "Dart" claims and reports ready the way startInBackground does.
@MainActor
final class FakeLauncher: AssistantEngineLauncher {
  var background: AssistantBackground!
  var starts = 0, stops = 0
  var dartStarts = true
  var claimed: Bool?
  func start() -> Bool {
    starts += 1
    if dartStarts {
      Task { @MainActor in
        claimed = background.claim()
        if claimed == true { background.ready() }
      }
    }
    return true
  }
  func stop() { stops += 1 }
}

@MainActor
func backgroundTests() async {
  func make(_ launcher: FakeLauncher?) -> (AssistantBackground, AssistantBridge) {
    let bridge = AssistantBridge()
    let background = AssistantBackground(bridge: bridge)
    background.launcher = launcher
    launcher?.background = background
    return (background, bridge)
  }
  func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

  // Without @AssistantBackground there's no launcher: the intent foregrounds.
  let (plain, _) = make(nil)
  check("\(await plain.prepare(timeout: 0.2))", "false", "no launcher: prepare says to foreground")

  // No engine: prepare starts the headless one and waits for Dart.
  let launcher = FakeLauncher()
  let (headless, bridge) = make(launcher)
  headless.keepAlive = 0.3
  check("\(await headless.prepare(timeout: 2))", "true", "prepare starts a headless engine")
  check("\(launcher.starts),\(bridge.isReady),\(headless.state == .ready)", "1,true,true", "headless Dart claims and is ready")
  check("\(await headless.prepare(timeout: 2)),\(launcher.starts)", "true,1", "a ready engine is reused")
  await sleep(0.6)
  check("\(launcher.stops),\(bridge.isReady),\(headless.isRunning)", "1,false,false", "stops after keepAlive")
  check("\(await headless.prepare(timeout: 2)),\(launcher.starts)", "true,2", "starts again on the next request")

  // The app's engine starts: the idle headless one stops; the app's Dart serves.
  bridge.engineStarted()
  headless.engineRegistered()
  await sleep(0.2)
  check("\(launcher.stops),\(headless.isRunning),\(bridge.isReady)", "2,false,false", "app engine retires the headless one")
  bridge.markReady()
  check("\(await headless.prepare(timeout: 1)),\(launcher.starts)", "true,2", "then the app's Dart answers")

  // The app's engine registers before headless Dart claims: Dart stands down.
  let late = FakeLauncher()
  late.dartStarts = false
  let (racing, racingBridge) = make(late)
  async let prepared = racing.prepare(timeout: 1)
  await sleep(0.1)
  racingBridge.engineStarted()
  racing.engineRegistered()
  check("\(racing.claim()),\(racing.state == .declined)", "false,true", "claim is declined once the app engine started")
  racingBridge.markReady()
  check("\(await prepared)", "true", "prepare waits for the app engine instead")

  // A headless engine that never gets ready: prepare times out (foreground).
  let stuck = FakeLauncher()
  stuck.dartStarts = false
  let (slow, _) = make(stuck)
  check("\(await slow.prepare(timeout: 0.2))", "false", "times out when Dart doesn't start")

  // The host calls Dart makes.
  AssistantBackground.registerHostCalls()
  check((try? AssistantHostCalls.invoke("background.claim", argsJson: "{}")) ?? "nil", "false",
    "background.claim answers JSON false with no headless engine")
}
// Top-level code stays synchronous (assumeIsolated above): run the main
// run loop until the async tests finish.
var backgroundDone = false
Task { @MainActor in
  await backgroundTests()
  backgroundDone = true
}
while !backgroundDone { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
// Undo: each change queues its inverse.
let before = AssistantRecord(id: "t1", title: "Call mum", fields: ["title": "Call mum", "due": 100.0])
let undoUpdate = AssistantUndo.update(
  "TaskItem", id: "t1", before: before, fields: ["title": "Call dad", "done": true], cleared: ["due"]
).first!
check("\(undoUpdate["kind"]!) \((undoUpdate["fields"] as! [String: Any]).keys.sorted()) \(undoUpdate["cleared"]!)",
  "update [\"due\", \"title\"] [\"done\"]", "undoing an update restores changed fields and clears new ones")
check((undoUpdate["fields"] as! [String: Any])["title"] as! String, "Call mum", "restores the published value")
check("\(AssistantUndo.create("TaskItem", id: "n")[0]["kind"]!)", "delete", "undoing a create deletes")
let undoDelete = AssistantUndo.delete("TaskItem", records: [before])[0]
check("\(undoDelete["kind"]!) \(undoDelete["id"]!)", "create t1", "undoing a delete creates the item with its id")
check("\(AssistantUndo.call("Countdown.pauseTimer", args: ["timer": "c1"])[0]["action"]!)",
  "Countdown.pauseTimer.undo", "undoing a call calls <action>.undo")
UserDefaults.standard.removeObject(forKey: "assistant_actions.inbox")
AssistantUndo.apply(#"[{"kind":"create","collection":"Undo","id":"x","fields":{"title":"Back"}}]"#)
check(AssistantInbox.pending("Undo").first?["id"] as? String ?? "nil", "x", "undo items are queued in the inbox")
_ = AssistantInbox.drain()

// Live calls: Dart reports progress into the intent's Progress.
MainActor.assumeIsolated {
  let progress = Progress(totalUnitCount: 1)
  let call = AssistantLiveCall(progress: progress)
  var sent: [String: Any] = [:]
  let semaphore = DispatchSemaphore(value: 0)
  Task { @MainActor in
    _ = try? await call.run("export", args: ["n": 1]) { action, args in
      sent = args
      _ = try? AssistantHostCalls.invoke("call.progress", argsJson: #"{"call":"\#(call.id)","completed":3,"total":4}"#)
      return action
    }
    semaphore.signal()
  }
  while semaphore.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
  check("\(progress.completedUnitCount)/\(progress.totalUnitCount)", "3/4", "Dart's progress reaches the intent")
  check(sent[AssistantLiveCall.argument] as? String ?? "nil", call.id, "the call id goes to Dart")
  check((try? AssistantHostCalls.invoke("call.progress", argsJson: #"{"call":"\#(call.id)"}"#)) ?? "nil", "false",
    "finished calls take no progress")
}

// File entities: Dart paths ↔ FileEntityIdentifier.
if #available(macOS 15.0, *) {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aa-files-\(UUID().uuidString)")
  try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let file = dir.appendingPathComponent("Plan.txt")
  try! "plan".write(to: file, atomically: true, encoding: .utf8)
  check(AssistantFileIDs.identifier(file.path).isDraft ? "draft" : "file", "file", "existing paths get file identifiers")
  check(AssistantFileIDs.identifier("note-1").draftIdentifier ?? "nil", "note-1", "other ids become drafts")
  check(AssistantFileIDs.url("file://\(file.path)")?.path ?? "nil", file.path, "file URLs are paths too")
  let semaphore = DispatchSemaphore(value: 0)
  var found: [String] = []
  let recs = [AssistantRecord(id: file.path, title: "", fields: [:]), AssistantRecord(id: "/other", title: "", fields: [:])]
  Task {
    found = await AssistantFileIDs.records(recs, for: [AssistantFileIDs.identifier(file.path), .draft(identifier: "x")]).map(\.id)
    semaphore.signal()
  }
  semaphore.wait()
  check(found.joined(separator: ","), file.path, "Siri's identifiers find the published items by path")
  try? FileManager.default.removeItem(at: dir)
}
// On-screen entities: a collection's ids become the activity's entity identifier.
struct NoteEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Note"
  static let defaultQuery = NoteQuery()
  let id: String
  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}
struct NoteQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [NoteEntity] { [] }
}
MainActor.assumeIsolated {
  AssistantContext.register("Note") { EntityIdentifier(for: NoteEntity.self, identifier: $0) }
  if #available(macOS 15.2, *) {
    let activity = AssistantContext.activity(collection: "Note", id: "n1")
    check(activity?.appEntityIdentifier?.identifier ?? "nil", "n1", "on-screen items name their entity")
    check(activity?.activityType.hasSuffix(".assistant_actions.showing") == true ? "yes" : "no", "yes",
      "the activity type is the app's")
  }
  check(AssistantContext.activity(collection: "Unknown", id: "x") == nil ? "nil" : "activity", "nil",
    "unknown collections show nothing")
  AssistantContext.registerHostCalls()
  check((try? AssistantHostCalls.invoke("context.showing", argsJson: #"{"collection":"Unknown","id":"x"}"#)) ?? "nil",
    "false", "showing an unknown collection says so")
  check((try? AssistantHostCalls.invoke("context.stopShowing", argsJson: "{}")) ?? "nil", "nil",
    "stopping with nothing shown is fine")
}

// Text for Transferable exports and predictions.
check(AssistantValues.text(["Walk", NSNull(), "  ", "Walk", ["name": "Lake"], ["email": "a@b.c"], 3]), "Walk\nLake\na@b.c",
  "text joins strings and names, skipping empty, repeated and other values")
check(AssistantValues.text(["a", "b"], separator: ", "), "a, b", "text takes a separator")
check(AssistantValues.references(#"[{"collection":"Recipe","id":"r1"},{"id":"x"},{"collection":"Note","id":"n"}]"#)
  .map { "\($0.collection)/\($0.id)" }.joined(separator: ","), "Recipe/r1,Note/n", "visual search results decode")
let image = AssistantValues.saveFile(named: "image.png", type: .png) { try Data([1, 2]).write(to: $0) } as! [String: Any]
check("\(image["name"]!) \(image["type"]!)", "image.png public.png", "saved files are AssistantFile maps")
try? FileManager.default.removeItem(atPath: ((image["path"] as! String) as NSString).deletingLastPathComponent)

// Visual Intelligence and place queries answered from the snapshot.
let dishes = records("""
  [{"id":"p","title":"Pancakes","fields":{}},{"id":"d","title":"Dog biscuits","fields":{"note":"golden retriever"}},
   {"id":"s","title":"Soup","fields":{}}]
  """)
check(AssistantMatch.records(dishes, matchingLabels: ["golden retriever", "dog"], ignoring: []).map(\.id).joined(),
  "d", "labels find items")
check(AssistantMatch.records(dishes, matchingLabels: ["pancake", "dog"], ignoring: []).map(\.id).joined(), "pd",
  "items matching more label words come first")
check("\(AssistantMatch.records(dishes, matchingLabels: ["the", "recipe"], ignoring: ["recipe"]).count)", "0",
  "labels that only name the type find nothing")
let spots = records("""
  [{"id":"far","title":"Far","fields":{"where":{"name":"Far","latitude":48.0,"longitude":-122.3}}},
   {"id":"near","title":"Cafe","fields":{"where":{"name":"Blue Cafe","address":"1 Lake St","latitude":47.6001,"longitude":-122.3}}},
   {"id":"here","title":"Here","fields":{"where":{"latitude":47.6,"longitude":-122.3}}}]
  """)
check(AssistantMatch.records(spots, matchingPlace: ["latitude": 47.6, "longitude": -122.3], field: "where", ignoring: [])
  .map(\.id).joined(separator: ","), "here,near", "places match by distance, nearest first")
check(AssistantMatch.records(spots, matchingPlace: ["name": "blue cafe"], field: "where", ignoring: []).map(\.id).joined(),
  "near", "places without a coordinate match by name")
check("\(AssistantMatch.records(spots, matchingPlace: [String: Any](), field: "where", ignoring: []).count)", "0",
  "an empty place matches nothing")
check("\(Int(AssistantMatch.distance((47.6, -122.3), (47.61, -122.3))))", "1111", "distances are in metres")

if failures > 0 {
  print("\(failures) failed")
  exit(1)
}
print("All Swift tests passed")
