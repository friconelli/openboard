import XCTest
@testable import OpenBoard

final class AgentTeamsTests: XCTestCase {
    func testParsesAgentBlocks() {
        let text = """
        Divido il lavoro in due.
        <agente titolo="Header">
        Sistema l'header in header.php.
        </agente>
        Poi:
        <AGENTE titolo = "Footer" >
        Sistema il footer.
        </agente>
        <agente></agente>
        """
        XCTAssertEqual(AgentTeams.parseTasks(text), [
            .init(title: "Header", task: "Sistema l'header in header.php."),
            .init(title: "Footer", task: "Sistema il footer."),
        ])
    }

    func testUntitledBlockTakesFirstLine() {
        XCTAssertEqual(AgentTeams.parseTasks("<agente>\nControlla i link\ne le immagini\n</agente>").first?.title, "Controlla i link")
    }

    func testDisplayTextHidesTags() {
        let shown = AgentTeams.displayText("<agente titolo=\"Header\">\nfai X\n</agente>")
        XCTAssertFalse(shown.contains("<agente"))
        XCTAssertTrue(shown.contains("Agente: Header"))
    }

    func testReportCountsRemaining() {
        var team = AgentTeam(directory: "/tmp")
        var done = AgentWorker(title: "A", task: "a"); done.status = .done; done.report = "fatto"
        var running = AgentWorker(title: "B", task: "b"); running.status = .running
        team.workers = [done, running]
        XCTAssertTrue(AgentTeams.reportMessage(done, team: team).contains("Ancora al lavoro: 1"))
        team.workers[1].status = .done
        XCTAssertTrue(AgentTeams.reportMessage(done, team: team).contains("Tutti gli agenti hanno finito"))
    }
}
