import XCTest
@testable import OpenBoard

final class TaskTests: XCTestCase {
    func testPlistScheduleAndNextRun() throws {
        var task = ScheduledTask(title: "Prova", folder: "/tmp", prompt: "di' ciao")
        task.repeatRule = .weekdays
        task.hour = 9
        task.minute = 30
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: TaskScheduler.plistData(for: task), format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, task.label)
        let intervals = try XCTUnwrap(plist["StartCalendarInterval"] as? [[String: Int]])
        XCTAssertEqual(intervals.map { $0["Weekday"]! }, [1, 2, 3, 4, 5])
        XCTAssertTrue(intervals.allSatisfy { $0["Hour"] == 9 && $0["Minute"] == 30 })

        // Friday 18:00 → next weekday run is Monday 09:30.
        let calendar = Calendar.current
        let friday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 18))!
        let next = try XCTUnwrap(task.nextRun(after: friday))
        XCTAssertEqual(calendar.component(.weekday, from: next), 2)
        XCTAssertEqual(calendar.component(.hour, from: next), 9)

        task.repeatRule = .weekly
        task.weekday = 7
        let weekly = try XCTUnwrap(PropertyListSerialization.propertyList(from: TaskScheduler.plistData(for: task), format: nil) as? [String: Any])
        XCTAssertEqual((weekly["StartCalendarInterval"] as? [String: Int])?["Weekday"], 0, "Sunday is 0 for launchd")
    }

    func testScriptRunsTheAgentInTheFolder() throws {
        var task = ScheduledTask(title: "Prova 'virgolette'", folder: "/tmp/cartella con spazi", prompt: "scrivi 'ok'")
        task.model = "haiku"
        let script = TaskScheduler.scriptText(for: task, account: nil)
        XCTAssertTrue(script.contains("cd '/tmp/cartella con spazi'"))
        XCTAssertTrue(script.contains("-p 'scrivi '\\''ok'\\''' --permission-mode acceptEdits --model haiku"))
        if let out = ProcessInfo.processInfo.environment["OB_TASK_SCRIPT"] {
            var live = ScheduledTask(title: "Prova OpenBoard", folder: URL(fileURLWithPath: out).deletingLastPathComponent().path,
                                     prompt: "Rispondi solo: attività ok")
            live.model = "haiku"
            try TaskScheduler.scriptText(for: live, account: nil).write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}
