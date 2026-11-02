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

if failures > 0 {
  print("\(failures) failed")
  exit(1)
}
print("All Swift tests passed")
