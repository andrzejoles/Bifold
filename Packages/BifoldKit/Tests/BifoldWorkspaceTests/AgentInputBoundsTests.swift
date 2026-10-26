import BifoldCore
import Testing
@testable import BifoldWorkspace

/// Wartości spoza zakresu z argumentów (np. od agenta) dają błąd, nie awarię.
@Suite struct AgentInputBoundsTests {
    @Test func parseSizeRejectsOutOfRangeValues() {
        #expect(parseSize("1E30K") == nil)
        #expect(parseSize("INFB") == nil)
        #expect(parseSize("NANM") == nil)
        #expect(parseSize("-5K") == nil)
        #expect(parseSize("99999999999999999999") == nil)
        #expect(parseSize("1,5G") == 1_610_612_736)
    }

    @Test func renameCounterIsBounded() {
        #expect(throws: CommandError.self) { try RenameRule(arguments: CommandArguments(["counterStep": .int(Int64.max)])) }
        #expect(throws: CommandError.self) { try RenameRule(arguments: CommandArguments(["counterStart": .int(Int64.min)])) }
        #expect(throws: CommandError.self) { try RenameRule(arguments: CommandArguments(["counterDigits": .int(1_000_000)])) }
        #expect((try? RenameRule(arguments: CommandArguments(["counterStart": 10, "counterStep": 5, "counterDigits": 3]))) != nil)
    }
}
