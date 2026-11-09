import XCTest
@testable import AISwitchboard

final class PlanUsageTests: XCTestCase {
    func testParsesSessionAndWeekWithResets() throws {
        let text = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 22% used · resets Nov 9 at 1:59pm (Europe/Rome)
        Current week (all models): 70% used · resets Nov 10 at 7:59pm (Europe/Rome)
        Current week (Opus): 12% used · resets Nov 10 at 7:59pm (Europe/Rome)
        """
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 11))!
        let usage = PlanUsage.parse(text, now: now)
        XCTAssertEqual(usage.session?.percent, 22)
        XCTAssertEqual(usage.week?.percent, 70)
        XCTAssertEqual(usage.others["Opus"]?.percent, 12)
        XCTAssertEqual(usage.session?.resets, calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 13, minute: 59)))
        XCTAssertEqual(usage.week?.resets, calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 19, minute: 59)))
        XCTAssertEqual(PlanUsage.countdown(to: usage.session!.resets!, now: now), "tra 2 h 59 min")
    }

    func testResetEarlyNextYearAndTimeOnly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 12, day: 30, hour: 23))!
        let zone = calendar.timeZone
        XCTAssertEqual(PlanUsage.date(from: "Jan 2 at 9am", zone: zone, now: now),
                       calendar.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 9)))
        XCTAssertEqual(PlanUsage.date(from: "1:30am", zone: zone, now: now),
                       calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 1, minute: 30)))
    }
}
