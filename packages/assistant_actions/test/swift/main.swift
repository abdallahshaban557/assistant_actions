// Tests for the Swift that runs without Flutter (snapshot answers). Run with
// tool/test_swift.sh, which compiles this with the runtime's Foundation-only
// sources; no Flutter, Xcode project or simulator involved.
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

if failures > 0 {
  print("\(failures) failed")
  exit(1)
}
print("All Swift tests passed")
